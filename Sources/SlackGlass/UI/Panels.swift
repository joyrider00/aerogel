import AppKit
import Combine
import SwiftUI

/// Borderless, transparent, floating panel that never activates the app,
/// so the app you were in keeps focus until you click into the composer.
final class HUDPanel: NSPanel {
    private let allowsKey: Bool

    init(allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Lets clicks land on the first click even though the panel isn't key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum HUDMetrics {
    static let inboxWidth: CGFloat = 330
    static let convWidth: CGFloat = 440
    static let gap: CGFloat = 12
    static let margin: CGFloat = 22   // room for shadows inside the transparent panel
    static let edgeInset: CGFloat = 8 // distance from screen edge to the glass
}

/// Top edge for the HUD and toasts: just below the bubble when it sits in their corner, else the screen top.
@MainActor
private func cardsTop(_ vf: NSRect, width: CGFloat) -> CGFloat {
    let top = vf.maxY - HUDMetrics.edgeInset
    guard let b = BubbleController.screenFrame else { return top }
    let cards = NSRect(x: vf.maxX - HUDMetrics.edgeInset - width, y: vf.minY, width: width, height: top - vf.minY)
    return cards.intersects(b) ? min(top, b.minY - 2) : top
}

private func screenUnderMouse() -> NSScreen {
    let p = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

@MainActor
final class HUDController {
    let model: AppModel
    let panel = HUDPanel(allowsKey: true)
    private var bag = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    var isVisible: Bool { panel.isVisible }
    var onVisibilityChange: ((Bool) -> Void)?

    init(model: AppModel) {
        self.model = model
        let drop = DropContainerView(host: FirstMouseHostingView(rootView: HUDRootView().environmentObject(model)))
        drop.canAccept = { [weak model] in model?.current != nil }
        drop.onHover = { [weak model] on in if model?.dropHover != on { model?.dropHover = on } }
        drop.onFiles = { [weak model] urls in model?.droppedFiles = (model?.droppedFiles ?? []) + urls }
        panel.contentView = drop
        model.$current
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] open in self?.layout(conversationOpen: open) }
            .store(in: &bag)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            return self.handleKey(e) ? nil : e
        }
        // Clicking another app closes the HUD, but only on a real click: pressing on something to drag it
        // (a screenshot thumbnail, a file in Finder) must leave the HUD open so it can be dropped here.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        ) { [weak self] e in
            let type = e.type, at = NSEvent.mouseLocation
            Task { @MainActor in self?.outsideMouse(type, at: at) }
        }
    }

    private var outsideDown: NSPoint?
    private var outsideDragged = false

    private func outsideMouse(_ type: NSEvent.EventType, at p: NSPoint) {
        switch type {
        case .leftMouseDown:
            outsideDown = p
            outsideDragged = false
        case .leftMouseDragged:
            if let d = outsideDown, hypot(p.x - d.x, p.y - d.y) > 4 { outsideDragged = true }
        case .leftMouseUp:
            defer { outsideDown = nil }
            guard outsideDown != nil, !outsideDragged else { return }
            hideIfUnpinned()
        default:
            hideIfUnpinned()
        }
    }

    private func hideIfUnpinned() {
        guard isVisible, !model.pinned, !ImageViewer.shared.isVisible, !ImageViewer.shared.justClosed else { return }
        hide()
    }

    func toggle() { isVisible ? hide() : show() }

    func show(_ ref: ConversationRef? = nil, focus: Bool = true) {
        if !isVisible {
            // Every open starts with empty search boxes…
            model.clearSearchFields()
            // …on Chats when nothing needs you, on Activity when something does…
            model.showChats = model.inbox.isEmpty
            model.showSearch = false
            // …and with the chat you last had open, even if you backed out of it before closing.
            if ref == nil, model.current == nil, let last = model.lastConversation { model.open(last, pushHistory: false) }
        }
        if let ref { model.open(ref) }
        layout(conversationOpen: model.current != nil)
        panel.orderFrontRegardless()
        if focus { panel.makeKey() }
        model.hudVisible = true
        onVisibilityChange?(true)
        if model.current == nil, model.selectedInboxID == nil { model.selectedInboxID = model.inbox.first?.id }
        model.focusComposerTick += 1
    }

    func hide() {
        panel.orderOut(nil)
        model.hudVisible = false
        onVisibilityChange?(false)
        model.switcherOpen = false
    }

    private func layout(conversationOpen: Bool) {
        let vf = screenUnderMouse().visibleFrame
        let m = HUDMetrics.margin
        let cards = HUDMetrics.inboxWidth + (conversationOpen ? HUDMetrics.gap + HUDMetrics.convWidth : 0)
        let w = cards + m * 2
        let top = cardsTop(vf, width: cards)
        let h = min(top - vf.minY + m, 780)
        let frame = NSRect(x: vf.maxX - w + m - HUDMetrics.edgeInset,
                           y: top + m - h,
                           width: w, height: h)
        panel.setFrame(frame, display: true)
    }

    /// Returns true when the key was consumed.
    private func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let editingText = panel.firstResponder is NSTextView

        // Escape peels back one layer at a time.
        if e.keyCode == 53 {
            if ImageViewer.shared.isVisible { ImageViewer.shared.close() }
            else if model.composerPopupOpen { model.composerDismissTick += 1 }
            else if model.switcherOpen { model.switcherOpen = false }
            else if model.assistantMode { model.closeAssistant() }
            else if model.editing != nil { model.editing = nil }
            else if model.current != nil { model.closeConversation() }
            else { hide() }
            return true
        }
        if flags == .command, chars == "k" {
            model.switcherOpen.toggle()
            model.switcherQuery = ""
            model.switcherIndex = 0
            return true
        }
        if flags == .command, chars == "w" { hide(); return true }
        if flags == .command, chars == "f" { model.openSearch(); return true }
        if flags == .command, chars == "[" { model.goBack(); return true }
        if flags == .command, chars == "o" { model.openInSlack(); return true }
        if flags.contains(.option), e.keyCode == 125 || e.keyCode == 126 {
            model.moveSelection(e.keyCode == 125 ? 1 : -1)
            model.openSelected()
            return true
        }

        if model.switcherOpen {
            let results = model.switcherResults
            switch e.keyCode {
            case 125: model.switcherIndex = min(model.switcherIndex + 1, max(results.count - 1, 0)); return true
            case 126: model.switcherIndex = max(model.switcherIndex - 1, 0); return true
            case 36, 76:
                if results.indices.contains(model.switcherIndex) { model.openSwitcherTarget(results[model.switcherIndex]) }
                return true
            default: return false
            }
        }

        if model.showSearch && model.searchFocused {
            switch e.keyCode {
            case 125: model.moveSearchSelection(1); return true
            case 126: model.moveSearchSelection(-1); return true
            case 36, 76: model.searchEnter(); return true
            default: return false
            }
        }

        if model.showChats && model.chatSearchFocused {
            switch e.keyCode {
            case 125: model.moveChatSelection(1); return true
            case 126: model.moveChatSelection(-1); return true
            case 36, 76: model.openSelectedChat(); return true
            default: return false
            }
        }

        guard !editingText, flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch (e.keyCode, chars) {
        case (125, _), (_, "j"): model.moveSelection(1); return true
        case (126, _), (_, "k"): model.moveSelection(-1); return true
        case (36, _), (76, _): model.openSelected(); return true
        case (_, "e"): model.markSelectedDone(); return true
        case (_, "s"): model.snoozeSelected(); return true
        case (_, "r"): model.focusComposerTick += 1; return true
        default: return false
        }
    }
}

// MARK: - Toasts

@MainActor
final class ToastController: ObservableObject {
    @Published var items: [InboxItem] = []
    /// Toasts being typed into never auto-dismiss.
    private var engaged: Set<String> = []
    let panel = HUDPanel(allowsKey: true)
    var onOpen: ((InboxItem) -> Void)?
    private static let rowHeight: CGFloat = 116
    private var keyMonitor: Any?

    init(model: AppModel) {
        panel.contentView = FirstMouseHostingView(rootView: ToastStackView(controller: self).environmentObject(model))
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow, e.keyCode == 53 else { return e }
            self.clear()
            return nil
        }
    }

    func setEngaged(_ id: String, _ on: Bool) {
        if on { engaged.insert(id) } else { engaged.remove(id) }
    }

    func show(_ item: InboxItem) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
            if items.count > 3 { items.removeLast(items.count - 3) }
        }
        layout()
        panel.orderFrontRegardless() // never steals focus; click the reply field to type
        scheduleDismiss(item.id, ts: item.ts, after: 8)
    }

    private func scheduleDismiss(_ id: String, ts: String, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            if self.engaged.contains(id) {
                self.scheduleDismiss(id, ts: ts, after: 4)
            } else {
                self.dismiss(id, onlyIfTs: ts)
            }
        }
    }

    func dismiss(_ id: String, onlyIfTs ts: String? = nil) {
        withAnimation(.easeOut(duration: 0.2)) {
            items.removeAll { $0.id == id && (ts == nil || $0.ts == ts) }
        }
        if !items.contains(where: { $0.id == id }) { engaged.remove(id) }
        if items.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                if self?.items.isEmpty == true { self?.panel.orderOut(nil) }
            }
        }
    }

    /// Handled on another Mac: dismiss, unless you're typing a reply into it here.
    func dismissIfIdle(_ id: String) {
        guard !engaged.contains(id) else { return }
        dismiss(id)
    }

    func clear() {
        items.removeAll()
        engaged.removeAll()
        panel.orderOut(nil)
    }

    private func layout() {
        let vf = screenUnderMouse().visibleFrame
        let m = HUDMetrics.margin
        let w = HUDMetrics.inboxWidth + m * 2
        let h = CGFloat(3) * (Self.rowHeight + 8) + m * 2
        let top = cardsTop(vf, width: HUDMetrics.inboxWidth)
        panel.setFrame(NSRect(x: vf.maxX - w + m - HUDMetrics.edgeInset,
                              y: top + m - h,
                              width: w, height: h), display: true)
    }
}
