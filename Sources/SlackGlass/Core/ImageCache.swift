import AppKit
import ImageIO
import SwiftUI

/// Loads avatars, custom emoji and file thumbnails. Private Slack file URLs
/// need the user token; it is only ever sent to *.slack.com hosts.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    var token: String?

    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.totalCostLimit = 150 << 20   // ~150 MB of decoded pixels; least-recently-used images go first
        return c
    }()
    private var inflight: [URL: Task<DecodedImage?, Never>] = [:]

    /// The file's raw bytes (for saving or copying), with the same auth rule as images.
    func data(for url: URL) async -> Data? {
        var req = URLRequest(url: url)
        if let token, let host = url.host, host == "slack.com" || host.hasSuffix(".slack.com") {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try? await URLSession.shared.data(for: req).0
    }

    /// Downloads a file to a private temp location (videos, which AVPlayer can't fetch with a token).
    func download(_ url: URL, ext: String, name: String? = nil) async -> URL? {
        var req = URLRequest(url: url)
        if let token, let host = url.host, host == "slack.com" || host.hasSuffix(".slack.com") {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (tmp, resp) = try? await URLSession.shared.download(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              (resp.mimeType ?? "").hasPrefix("text/html") == false else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SlackGlass-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        if let name, !name.isEmpty { // keep the real file name (it's what Preview shows as the title)
            let sub = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            dest = sub.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        }
        do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { return nil }
        return dest
    }

    /// Already-loaded image, without waiting. Lets rows draw a cached avatar in their first frame.
    func cached(_ url: URL?) -> NSImage? { url.flatMap { cache.object(forKey: $0 as NSURL) } }

    func image(for url: URL) async -> NSImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        if let until = failed[url], until > Date() { return nil }
        if let t = inflight[url] { return await t.value?.image }
        let token = self.token
        // Download and decode off the main thread; everyone waiting on this URL shares the one decode.
        let task = Task.detached(priority: .userInitiated) { () -> DecodedImage? in
            var req = URLRequest(url: url)
            if let token, let host = url.host, host == "slack.com" || host.hasSuffix(".slack.com") {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, _) = try? await ImageCache.session.data(for: req) else { return nil }
            return ImageCache.decode(data).map(DecodedImage.init)
        }
        inflight[url] = task
        let img = await task.value?.image
        inflight[url] = nil
        if let img {
            let px = img.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
            cache.setObject(img, forKey: url as NSURL, cost: max(px, 1) * 4)
        } else {
            failed[url] = Date().addingTimeInterval(120)   // don't re-download a broken image on every redraw
        }
        return img
    }

    private var failed: [URL: Date] = [:]

    /// Images keep a disk cache between launches, so avatars and emoji don't re-download every time.
    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20,
                              directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("SlackGlass-images"))
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()

    /// GIFs stay as they are so they animate. Everything else is decoded at most 1600 px on its long side,
    /// which still fills the image viewer but keeps a phone photo from costing 50 MB.
    nonisolated static func decode(_ data: Data) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return NSImage(data: data) }
        if let type = CGImageSourceGetType(src) as String?, type == "com.compuserve.gif" { return NSImage(data: data) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return NSImage(data: data) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// A freshly decoded image handed from the decoding thread to the main thread; nothing else holds it.
struct DecodedImage: @unchecked Sendable { let image: NSImage }

/// Like RemoteImage, but GIFs play. Scales to fit its frame.
struct AnimatedRemoteImage: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? ImageCache.shared.cached(url) {
                AnimatedImage(image: image)
            } else {
                Rectangle().fill(.white.opacity(0.08)).overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) {
            guard let url, ImageCache.shared.cached(url) == nil else { return }
            image = await ImageCache.shared.image(for: url)
        }
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? ImageCache.shared.cached(url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, ImageCache.shared.cached(url) == nil else { return }
            image = await ImageCache.shared.image(for: url)
        }
    }
}
