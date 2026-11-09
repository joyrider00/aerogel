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
    var permalink: String?
    var size: Int?

    var isVideo: Bool { (mimetype ?? "").hasPrefix("video/") }
    var isImage: Bool { ((mimetype ?? "").hasPrefix("image/") || isVideo) && thumbURL != nil }
    var thumbURL: URL? { (thumb_video ?? thumb_480 ?? thumb_360).flatMap(URL.init(string:)) }
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

    struct Edited: Codable, Hashable { var user: String?; var ts: String? }
    struct BotProfile: Codable, Hashable { var name: String?; var icons: [String: String]? }
    struct Attachment: Codable, Hashable {
        var fallback: String?
        var pretext: String?
        var title: String?
        var title_link: String?
        var text: String?
        var footer: String?
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

    var label: String {
        switch self {
        case .dm: "DM"
        case .group: "Group"
        case .mention: "@you"
        case .thread: "Thread"
        case .keyword: "Keyword"
        }
    }

    var priority: Int {
        switch self {
        case .dm: 4
        case .mention: 3
        case .group: 2
        case .keyword: 1
        case .thread: 0
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

    static func makeID(_ channel: String, _ threadTs: String?) -> String { "\(channel):\(threadTs ?? "")" }
    var id: String { Self.makeID(channel, threadTs) }
    var ref: ConversationRef { ConversationRef(channel: channel, threadTs: threadTs) }
    var date: Date { Date(timeIntervalSince1970: Double(ts) ?? 0) }
}

enum SlackTS {
    static func now() -> String { String(format: "%.6f", Date().timeIntervalSince1970) }
}
