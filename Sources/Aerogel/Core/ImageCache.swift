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
