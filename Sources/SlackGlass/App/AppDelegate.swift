import AppKit
import Carbon
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var hud: HUDController!
    private var toasts: ToastController!
    private var bubble: BubbleController!
    private var settingsWindow: NSWindow?
    private var hotKeys: [HotKey] = []
    private var bag = Set<AnyCancellable>()

    private var canUseUserNotifications: Bool { Bundle.main.bundleIdentifier != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        hud = HUDController(model: model)
        toasts = ToastController(model: model)
        toasts.onOpen = { [weak self] item in self?.hud.show(item.ref) }
        bubble = BubbleController(model: model)
        bubble.onClick = { [weak self] in self?.toggleHUD() }
        hud.onVisibilityChange = { [weak self] visible in self?.bubble.hudVisibilityChanged(visible) }
        model.onNotify = { [weak self] item in self?.notify(item) }
        model.onCleared = { [weak self] id, toast in
            if toast { self?.toasts.dismissIfIdle(id) }
            self?.removeBanners(id)
        }
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        model.onShowHUD = { [weak self] ref in
            self?.toasts.clear()
            self?.hud.show(ref)
        }

        setUpStatusItem()

        // ⌃⌥Space toggles the HUD; ⌃⌥R jumps straight into the newest item's composer.
        let mods = UInt32(controlKey | optionKey)
        hotKeys.append(HotKey(keyCode: UInt32(kVK_Space), modifiers: mods, id: 1) { [weak self] in
            self?.toasts.clear()
            self?.hud.toggle()
        })
        hotKeys.append(HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: mods, id: 2) { [weak self] in
            guard let self else { return }
            self.toasts.clear()
            if let first = self.model.inbox.first { self.hud.show(first.ref) } else { self.hud.show() }
        })

        if canUseUserNotifications {
            UNUserNotificationCenter.current().delegate = self
            if Prefs.style == .native {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }

        if CommandLine.arguments.contains("--demo") {
            model.startDemo()
            // --open shows the first thread; --peek does the same without taking keyboard focus.
            let peek = CommandLine.arguments.contains("--peek")
            if peek || CommandLine.arguments.contains("--open") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, let first = self.model.inbox.first else { return }
                    self.hud.show(first.ref, focus: !peek)
                    self.model.pinned = true
                }
            }
        } else if model.hasTokens {
            model.connect()
        } else {
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushPersist(sync: true)
    }

    /// slackglass://signed-in?… arrives from the browser once Slack approves "Sign in with Slack".
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where model.completeRelaySignIn(url) {
            openSettings()
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "Slack Glass")
            b.image?.isTemplate = true
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.$inbox
            .map { $0.filter { !$0.seen }.count }
            .removeDuplicates()
            .sink { [weak self] n in self?.statusItem.button?.title = n > 0 ? " \(n)" : "" }
            .store(in: &bag)
        Updater.shared.$state
            .map { if case .available = $0 { return true } else { return false } }
            .removeDuplicates()
            .sink { [weak self] available in self?.setStatusImage(updateDot: available) }
            .store(in: &bag)
        Updater.shared.start(existingUser: model.hasTokens)
    }

    /// The menu bar icon, with a small blue dot in its corner when an update is ready.
    private func setStatusImage(updateDot: Bool) {
        guard let base = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "Slack Glass")
        else { return }
        guard updateDot else {
            base.isTemplate = true
            statusItem.button?.image = base
            return
        }
        let dark = statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let size = base.size
        let img = NSImage(size: size, flipped: false) { rect in
            let tinted = base.copy() as! NSImage
            tinted.lockFocus()
            (dark ? NSColor.white : NSColor.black).set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: rect)
            let d: CGFloat = 6.5
            let dot = NSRect(x: rect.maxX - d + 0.5, y: rect.maxY - d + 0.5, width: d, height: d)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.2, dy: -1.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        img.isTemplate = false
        statusItem.button?.image = img
        statusItem.button?.toolTip = "Slack Glass: an update is ready"
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            if case .available(let v) = Updater.shared.state {
                menu.addItem(withTitle: "Update to \(v)", action: #selector(installUpdate), keyEquivalent: "").target = self
                menu.addItem(.separator())
            }
            menu.addItem(withTitle: "Show HUD  ⌃⌥Space", action: #selector(toggleHUD), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Slack Glass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleHUD()
        }
    }

    @objc private func toggleHUD() {
        toasts.clear()
        Updater.shared.checkSoon()
        hud.toggle()
    }

    @objc private func openSettingsAction() { openSettings() }
    @objc private func installUpdate() { Updater.shared.install() }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Slack Glass"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(model))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Notifications

    private func notify(_ item: InboxItem) {
        if Prefs.playSound, Prefs.style != .off { Prefs.playSound() }
        switch Prefs.style {
        case .hud:
            if !hud.isVisible { toasts.show(item) }
        case .native:
            postNative(item)
        case .off:
            break
        }
    }

    private func postNative(_ item: InboxItem) {
        guard canUseUserNotifications else { return }
        let c = UNMutableNotificationContent()
        c.title = model.userName(item.user)
        c.subtitle = model.isDirect(item.channel) && item.threadTs == nil ? "" : model.title(item.channel)
        c.body = model.plain(item.text)
        c.userInfo = ["channel": item.channel, "thread": item.threadTs ?? ""]
        c.threadIdentifier = item.id
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// Takes down Notification Center banners for an item you handled on another Mac.
    private func removeBanners(_ id: String) {
        guard canUseUserNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == id }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let channel = info["channel"] as? String ?? ""
        let thread = (info["thread"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        Task { @MainActor in
            self.hud.show(ConversationRef(channel: channel, threadTs: thread))
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }

    // MARK: - Menu (needed so ⌘C/⌘V/⌘Z work in text fields of a menu-bar app)

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Slack Glass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}
