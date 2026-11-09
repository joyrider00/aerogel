import AppKit
import AVKit
import SwiftUI

/// A full-size view of an image or video someone sent: opens centered over everything, Esc or a click outside
/// closes it. Images show the thumbnail at once and swap in the full-resolution file; GIFs animate. Videos show
/// their poster frame while the file downloads, then play with the standard controls.
@MainActor
final class ImageViewer: ObservableObject {
    static let shared = ImageViewer()

    @Published private(set) var file: SlackFile?
    @Published private(set) var image: NSImage?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var loadingVideo = false
    @Published var status: String?
    private var videoFile: URL?
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
            if e.keyCode == 49, let p = self.player { // Space plays and pauses a video
                if p.timeControlStatus == .playing { p.pause() } else { p.play() }
                return nil
            }
            if e.keyCode == 53 || e.keyCode == 49 || (cmd && c == "w") { self.close(); return nil }
            if cmd, c == "c" { self.copy(); return nil }
            if cmd, c == "s" { self.save(); return nil }
            return e
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in if self?.isVisible == true { self?.close() } }
        }
    }

    var isVideo: Bool { file?.isVideo == true }

    func show(_ f: SlackFile) {
        stopVideo()
        file = f
        status = nil
        image = nil
        previousKey = NSApp.keyWindow
        let thumb = f.thumbURL
        Task {
            if let thumb, let t = await ImageCache.shared.image(for: thumb), self.file == f, self.image == nil {
                self.image = t
                self.layout(for: t.size)
            }
        }
        if f.isVideo {
            loadVideo(f)
        } else if let full = f.url_private.flatMap(URL.init(string:)) {
            Task {
                if let d = await ImageCache.shared.data(for: full), let img = NSImage(data: d), self.file == f {
                    self.image = img
                    self.layout(for: img.size)
                }
            }
        }
        layout(for: NSSize(width: 800, height: 500))
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Slack's file URLs need your token, which AVPlayer can't send, so the video is downloaded first.
    private func loadVideo(_ f: SlackFile) {
        guard let url = (f.mp4 ?? f.url_private).flatMap(URL.init(string:)) else {
            status = "This video can only be played in Slack"
            return
        }
        loadingVideo = true
        Task {
            let ext = f.mp4 != nil ? "mp4" : (f.filetype ?? (f.name as NSString?)?.pathExtension ?? "mp4")
            let local = await ImageCache.shared.download(url, ext: ext.isEmpty ? "mp4" : ext)
            guard self.file == f else { if let local { try? FileManager.default.removeItem(at: local) }; return }
            self.loadingVideo = false
            guard let local else { self.status = "Couldn't download the video"; return }
            self.videoFile = local
            let asset = AVURLAsset(url: local)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(transform)
                self.layout(for: NSSize(width: abs(r.width), height: abs(r.height)))
            }
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = p
            p.play()
        }
    }

    private func stopVideo() {
        player?.pause()
        player = nil
        loadingVideo = false
        if let v = videoFile { try? FileManager.default.removeItem(at: v) }
        videoFile = nil
    }

    func close() {
        if panel.isVisible { closedAt = Date() }
        panel.orderOut(nil)
        stopVideo()
        file = nil
        image = nil
        if let w = previousKey, w.isVisible { w.makeKey() }
        previousKey = nil
    }

    /// Fits the media within 85% of the screen, never enlarging past its own pixels.
    private func layout(for size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let vf = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
                  ?? NSScreen.screens[0]).visibleFrame
        let chrome: CGFloat = 52 // the bar under the media
        let maxW = vf.width * 0.85, maxH = vf.height * 0.85 - chrome
        let scale = min(1, maxW / size.width, maxH / size.height)
        let w = max(320, size.width * scale), h = max(200, size.height * scale) + chrome
        let frame = NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h).integral
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    func copy() {
        NSPasteboard.general.clearContents()
        if isVideo {
            guard let v = videoFile else { return }
            NSPasteboard.general.writeObjects([v as NSURL])
        } else {
            guard let image else { return }
            NSPasteboard.general.writeObjects([image])
        }
        status = "Copied"
    }

    func save() {
        guard let f = file else { return }
        let name = (f.name ?? (isVideo ? "video.mp4" : "image")).replacingOccurrences(of: "/", with: "-")
        status = "Saving…"
        let already = videoFile
        Task {
            let data: Data?
            if let already { data = try? Data(contentsOf: already) }
            else if let url = f.url_private.flatMap(URL.init(string:)) { data = await ImageCache.shared.data(for: url) }
            else { data = nil }
            guard let data else { self.status = "Couldn't download it"; return }
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
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

    /// Set by the model so this opens the Slack app directly (slack://), not a browser tab.
    var openInSlackHandler: ((SlackFile) -> Void)?

    func openInSlack() {
        if let f = file { openInSlackHandler?(f) }
        close()
    }
}

private struct ImageViewerView: View {
    @ObservedObject var viewer: ImageViewer

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let p = viewer.player {
                    VideoView(player: p)
                } else if let img = viewer.image {
                    AnimatedImage(image: img)
                }
                if viewer.loadingVideo {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading video…").font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.55)))
                } else if viewer.player == nil && viewer.image == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Text(viewer.file?.displayName ?? "").font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let s = viewer.status { Text(s).font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                IconButton(symbol: "doc.on.doc", help: viewer.isVideo ? "Copy video file (⌘C)" : "Copy image (⌘C)") { viewer.copy() }
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

/// AVPlayerView with the standard inline controls (play/pause, scrub, volume, full screen).
private struct VideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = true
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// NSImageView so GIFs play; scales to fit, never past the frame.
struct AnimatedImage: NSViewRepresentable {
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
