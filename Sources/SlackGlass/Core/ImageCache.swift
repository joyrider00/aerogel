import AppKit
import SwiftUI

/// Loads avatars, custom emoji and file thumbnails. Private Slack file URLs
/// need the user token; it is only ever sent to *.slack.com hosts.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    var token: String?

    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<Data?, Never>] = [:]

    /// The file's raw bytes (for saving or copying), with the same auth rule as images.
    func data(for url: URL) async -> Data? {
        var req = URLRequest(url: url)
        if let token, let host = url.host, host == "slack.com" || host.hasSuffix(".slack.com") {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try? await URLSession.shared.data(for: req).0
    }

    /// Downloads a file to a private temp location (videos, which AVPlayer can't fetch with a token).
    func download(_ url: URL, ext: String) async -> URL? {
        var req = URLRequest(url: url)
        if let token, let host = url.host, host == "slack.com" || host.hasSuffix(".slack.com") {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (tmp, resp) = try? await URLSession.shared.download(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              (resp.mimeType ?? "").hasPrefix("text/html") == false else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SlackGlass-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { return nil }
        return dest
    }

    func image(for url: URL) async -> NSImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        if let t = inflight[url] { return await t.value.flatMap(NSImage.init(data:)) }
        let token = self.token
        let task = Task<Data?, Never> {
            var req = URLRequest(url: url)
            if let token, let host = url.host, host == "slack.com" || host.hasSuffix(".slack.com") {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
            return data
        }
        inflight[url] = task
        let img = await task.value.flatMap(NSImage.init(data:))
        inflight[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await ImageCache.shared.image(for: url)
        }
    }
}
