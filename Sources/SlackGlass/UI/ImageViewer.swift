import AppKit
import SwiftUI

/// A full-size view of an image someone sent: opens centered over everything, Esc or a click outside closes it.
/// Shows the thumbnail at once and swaps in the full-resolution file when it arrives. GIFs animate.
@MainActor
final class ImageViewer: ObservableObject {
    static let shared = ImageViewer()

    @Published private(set) var file: SlackFile?
    @Published private(set) var image: NSImage?
    @Published var status: String?
    private let panel = HUDPanel(allowsKey: true)
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var previousKey: NSWindow?

    var isVisible: Bool { panel.isVisible }
    /// A click outside closes only the viewer; the HUD behind it stays open.
    var justClosed: Bool { Date().timeIntervalSince(closedAt) < 0.6 }
    private var closedAt = Date.distantPast

    private init() {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.contentView = FirstMouseHostingView(rootView: ImageViewerView(viewer: self))
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            let cmd = e.modifierFlags.contains(.command), c = e.charactersIgnoringModifiers?.lowercased()
            if e.keyCode == 53 || e.keyCode == 49 || (cmd && c == "w") { self.close(); return nil }
            if cmd, c == "c" { self.copy(); return nil }
            if cmd, c == "s" { self.save(); return nil }
            return e
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in if self?.isVisible == true { self?.close() } }
        }
    }

    func show(_ f: SlackFile) {
        file = f
        status = nil
        image = nil
        previousKey = NSApp.keyWindow
        let thumb = f.thumbURL
        let full = f.url_private.flatMap(URL.init(string:))
        Task {
            if let thumb, let t = await ImageCache.shared.image(for: thumb), self.file == f, self.image == nil {
                self.image = t
                self.layout(for: t.size)
            }
            if let full, let d = await ImageCache.shared.data(for: full), let img = NSImage(data: d), self.file == f {
                self.image = img
                self.layout(for: img.size)
            }
        }
        layout(for: NSSize(width: 800, height: 600))
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        if panel.isVisible { closedAt = Date() }
        panel.orderOut(nil)
        file = nil
        image = nil
        if let w = previousKey, w.isVisible { w.makeKey() }
        previousKey = nil
    }

    /// Fits the image within 85% of the screen, never enlarging past its own pixels.
    private func layout(for size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let vf = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
                  ?? NSScreen.screens[0]).visibleFrame
        let chrome: CGFloat = 52 // the bar under the image
        let maxW = vf.width * 0.85, maxH = vf.height * 0.85 - chrome
        let scale = min(1, maxW / size.width, maxH / size.height)
        let w = max(320, size.width * scale), h = max(200, size.height * scale) + chrome
        let frame = NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h).integral
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    func copy() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        status = "Copied"
    }

    func save() {
        guard let f = file, let url = f.url_private.flatMap(URL.init(string:)) else { return }
        status = "Saving…"
        Task {
            guard let data = await ImageCache.shared.data(for: url) else { self.status = "Couldn't download it"; return }
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let name = (f.name ?? "image").replacingOccurrences(of: "/", with: "-")
            var dest = downloads.appendingPathComponent(name)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                dest = downloads.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
                n += 1
            }
            if (try? data.write(to: dest)) != nil {
                self.status = "Saved to Downloads"
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } else {
                self.status = "Couldn't save it"
            }
        }
    }

    func openInSlack() {
        if let p = file?.permalink.flatMap(URL.init(string:)) { NSWorkspace.shared.open(p) }
        close()
    }
}

private struct ImageViewerView: View {
    @ObservedObject var viewer: ImageViewer

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let img = viewer.image {
                    AnimatedImage(image: img)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Text(viewer.file?.displayName ?? "").font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let s = viewer.status { Text(s).font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                IconButton(symbol: "doc.on.doc", help: "Copy image (⌘C)") { viewer.copy() }
                IconButton(symbol: "square.and.arrow.down", help: "Save to Downloads (⌘S)") { viewer.save() }
                IconButton(symbol: "arrow.up.forward.app", help: "Open in Slack") { viewer.openInSlack() }
                IconButton(symbol: "xmark", help: "Close (Esc)") { viewer.close() }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
        .padding(6)
        .background(GlassBackground(radius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.2)))
        .environment(\.colorScheme, .dark)
    }
}

/// NSImageView so GIFs play; scales to fit, never past the frame.
private struct AnimatedImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image !== image { v.image = image }
    }
}
