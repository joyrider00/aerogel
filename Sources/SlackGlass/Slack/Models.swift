import Foundation

struct SlackUser: Codable, Hashable, Identifiable {
    let id: String
    var name: String?
    var real_name: String?
    var deleted: Bool?
    var is_bot: Bool?
    var profile: Profile?

    struct Profile: Codable, Hashable {
        var display_name: String?
        var real_name: String?
        var image_48: String?
        var image_72: String?
        var status_emoji: String?
        var status_text: String?
    }

    var displayName: String {
        if let d = profile?.display_name, !d.isEmpty { return d }
        if let r = profile?.real_name, !r.isEmpty { return r }
        if let r = real_name, !r.isEmpty { return r }
        return name ?? id
    }

    var avatarURL: URL? {
        (profile?.image_72 ?? profile?.image_48).flatMap(URL.init(string:))
    }
}

struct SlackConversation: Codable, Hashable, Identifiable {
    let id: String
    var name: String?
    var is_channel: Bool?
    var is_group: Bool?
    var is_im: Bool?
    var is_mpim: Bool?
    var is_private: Bool?
    var is_archived: Bool?
    var user: String?
    /// Milliseconds. Undocumented, but in practice it lands 30 days after the last message.
    var updated: Double?

    var isDirect: Bool { is_im == true || is_mpim == true }

    /// A first guess at when the last message was, until the real one is fetched.
    var estimatedActivity: Double? { updated.map { $0 / 1000 - 30 * 86_400 } }
}

struct SlackFile: Codable, Hashable, Identifiable {
    let id: String
    var name: String?
    var title: String?
    var mimetype: String?
    var filetype: String?
    var url_private: String?
    var thumb_360: String?
    var thumb_480: String?
    var thumb_video: String?
    /// Animated thumbnails Slack makes for uploaded GIFs (the plain thumbs are still frames).
    var thumb_360_gif: String?
    var thumb_480_gif: String?
    /// A playable MP4 Slack makes for some uploads (e.g. .mov files).
    var mp4: String?
    var permalink: String?
    var size: Int?

    var isVideo: Bool { (mimetype ?? "").hasPrefix("video/") }
    var isPDF: Bool { filetype == "pdf" || mimetype == "application/pdf" }
    var isImage: Bool { ((mimetype ?? "").hasPrefix("image/") || isVideo) && thumbURL != nil }
    var thumbURL: URL? { (thumb_video ?? thumb_480 ?? thumb_360).flatMap(URL.init(string:)) }
    var animatedThumbURL: URL? { (thumb_480_gif ?? thumb_360_gif).flatMap(URL.init(string:)) }
    var displayName: String { title ?? name ?? "file" }
}

struct SlackReaction: Codable, Hashable {
    var name: String
    var users: [String]?
    var count: Int
}

struct SlackMessage: Codable, Hashable, Identifiable {
    var ts: String
    var type: String?
    var subtype: String?
    var user: String?
    var bot_id: String?
    var username: String?
    var text: String?
    var thread_ts: String?
    var reply_count: Int?
    var reply_users: [String]?
    var files: [SlackFile]?
    var reactions: [SlackReaction]?
    var edited: Edited?
    var bot_profile: BotProfile?
    var attachments: [Attachment]?
    var blocks: [ImageBlock]?

    struct Edited: Codable, Hashable { var user: String?; var ts: String? }
    struct BotProfile: Codable, Hashable { var name: String?; var icons: [String: String]? }
    struct Attachment: Codable, Hashable {
        var fallback: String?
        var pretext: String?
        var title: String?
        var title_link: String?
        var text: String?
        var footer: String?
        var image_url: String?
        var image_width: Double?
        var image_height: Double?
        var blocks: [ImageBlock]?

        /// GIFs from Slack's GIF picker and link-preview images.
        var images: [ImageBlock] {
            var out = (blocks ?? []).filter(\.isImage)
            if let u = image_url {
                out.append(ImageBlock(type: "image", image_url: u, alt_text: title ?? fallback,
                                      image_width: image_width, image_height: image_height))
            }
            return out
        }
    }

    /// Any Block Kit block; only image blocks are drawn. Decoding never fails, whatever the block holds.
    struct ImageBlock: Codable, Hashable {
        var type: String?
        var image_url: String?
        var alt_text: String?
        var image_width: Double?
        var image_height: Double?

        init(type: String?, image_url: String?, alt_text: String?, image_width: Double?, image_height: Double?) {
            self.type = type; self.image_url = image_url; self.alt_text = alt_text
            self.image_width = image_width; self.image_height = image_height
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decode(String.self, forKey: .type)
            image_url = try? c.decode(String.self, forKey: .image_url)
            alt_text = try? c.decode(String.self, forKey: .alt_text)
            image_width = try? c.decode(Double.self, forKey: .image_width)
            image_height = try? c.decode(Double.self, forKey: .image_height)
        }

        var isImage: Bool { type == "image" && url != nil }

        /// Giphy's .webp doesn't animate in AppKit; the same GIF is also served as .gif.
        var url: URL? {
            guard var s = image_url else { return nil }
            if let u = URL(string: s), u.host?.hasSuffix("giphy.com") == true, u.path.hasSuffix(".webp") {
                s = s.replacingOccurrences(of: u.path, with: String(u.path.dropLast(5)) + ".gif")
            }
            return URL(string: s)
        }

        /// Shown at its own size, fitted inside the message column.
        var displaySize: CGSize {
            let w = image_width ?? 260, h = image_height ?? 180
            let scale = min(1, 300 / max(w, 1), 220 / max(h, 1))
            return CGSize(width: max(40, w * scale), height: max(30, h * scale))
        }
    }

    var id: String { ts }
    var date: Date { Date(timeIntervalSince1970: Double(ts) ?? 0) }

    /// Text suitable for a one-line preview.
    var previewText: String {
        if let t = text, !t.isEmpty { return t }
        if let f = files?.first { return "📎 \(f.displayName)" }
        if let a = attachments?.first { return a.fallback ?? a.title ?? a.text ?? "" }
        return ""
    }
}

enum InboxReason: String, Codable {
    case dm, group, mention, thread, keyword
    /// A channel you marked unread yourself.
    case channel

    var label: String {
        switch self {
        case .dm: "DM"
        case .group: "Group"
        case .mention: "@you"
        case .thread: "Thread"
        case .keyword: "Keyword"
        case .channel: "Channel"
        }
    }

    var priority: Int {
        switch self {
        case .dm: 4
        case .mention: 3
        case .group: 2
        case .keyword: 1
        case .thread, .channel: 0
        }
    }
}

/// Where the HUD is pointed: a channel/DM timeline (threadTs == nil) or a single thread.
struct ConversationRef: Hashable, Codable {
    var channel: String
    var threadTs: String?
}

struct InboxItem: Codable, Identifiable, Hashable {
    var channel: String
    var threadTs: String?
    var ts: String
    var user: String?
    var text: String
    var reason: InboxReason
    var count: Int = 1
    var seen: Bool = false
    var snoozeUntil: Date?
    /// You marked it unread ("come back to this"): a blue dot instead of red.
    var markedUnread: Bool?

    var isMarkedUnread: Bool { markedUnread == true }

    static func makeID(_ channel: String, _ threadTs: String?) -> String { "\(channel):\(threadTs ?? "")" }
    var id: String { Self.makeID(channel, threadTs) }
    var ref: ConversationRef { ConversationRef(channel: channel, threadTs: threadTs) }
    var date: Date { Date(timeIntervalSince1970: Double(ts) ?? 0) }
}

enum SlackTS {
    static func now() -> String { String(format: "%.6f", Date().timeIntervalSince1970) }
}
