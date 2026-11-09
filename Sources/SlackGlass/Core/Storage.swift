import Foundation

/// Tokens live in one private file (`~/Library/Application Support/Slack Glass/secrets.json`, readable only by
/// your macOS user; encrypted at rest when FileVault is on) instead of the Keychain. A self-built app has no Apple
/// team ID, so the Keychain ties access to each exact build and asks for your password after every rebuild.
enum Secrets {
    private static var cache: [String: String]?
    private static let lock = NSRecursiveLock() // token refresh can run off the main thread

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Slack Glass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }

    static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()[key]
    }

    static func set(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        var d = load()
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        d[key] = v.isEmpty ? nil : v
        save(d)
    }

    private static func load() -> [String: String] {
        if let cache { return cache }
        let d = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = d
        return d
    }

    private static func save(_ d: [String: String]) {
        cache = d
        guard let data = try? JSONEncoder().encode(d) else { return }
        let url = fileURL
        // Write a private (0600) temp file next to it, then swap it in, so no copy is ever world-readable.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".secrets-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { return }
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum TokenKey {
    static let user = "userToken"
    static let app = "appToken"
    static let userRefresh = "userRefreshToken"
    static let appRefresh = "appRefreshToken"
    static let clientID = "clientID"
    static let clientSecret = "clientSecret"
    static let assistant = "assistantToken"
    static let all = [user, app, userRefresh, appRefresh, clientID, clientSecret, assistant]
}

/// Slack can issue rotating tokens: an access token prefixed `xoxe.` (e.g. `xoxe.xapp-1-…`)
/// that expires, plus a single-use refresh token (`xoxe-1-…`). Exchanging the refresh token
/// via oauth.v2.access needs the app's Client ID and Client Secret.
enum TokenRotation {
    static func isRotating(_ token: String) -> Bool { token.hasPrefix("xoxe.") }

    static func canRefresh(_ refreshKey: String) -> Bool {
        [refreshKey, TokenKey.clientID, TokenKey.clientSecret].allSatisfy { !(Secrets.get($0) ?? "").isEmpty }
    }

    /// Exchanges the stored refresh token for a new access token and stores both.
    static func refresh(accessKey: String, refreshKey: String) async throws -> String {
        guard let rt = Secrets.get(refreshKey), let id = Secrets.get(TokenKey.clientID),
              let secret = Secrets.get(TokenKey.clientSecret) else {
            throw SlackError(code: "token_expired — add the refresh token, Client ID and Client Secret in Settings")
        }
        let r: [String: Any]
        do {
            r = try await SlackAPI(userToken: "").call(
                "oauth.v2.access",
                ["grant_type": "refresh_token", "refresh_token": rt, "client_id": id, "client_secret": secret],
                token: "")
        } catch let e as SlackError where e.code == "invalid_refresh_token" {
            // Refresh tokens are single-use, so a Mac linked to this setup may have renewed it first.
            throw SlackError(code: "tokens were renewed on another Mac. Paste a new link code from that Mac in Settings")
        }
        let user = r["authed_user"] as? [String: Any]
        let preferUser = accessKey == TokenKey.user
        let access = preferUser
            ? (user?["access_token"] as? String ?? r["access_token"] as? String)
            : (r["access_token"] as? String ?? user?["access_token"] as? String)
        let newRefresh = preferUser
            ? (user?["refresh_token"] as? String ?? r["refresh_token"] as? String)
            : (r["refresh_token"] as? String ?? user?["refresh_token"] as? String)
        guard let access else { throw SlackError(code: "token_refresh_failed") }
        Secrets.set(accessKey, access)
        if let newRefresh { Secrets.set(refreshKey, newRefresh) }
        return access
    }
}

/// A link code carries one Mac's Slack setup (tokens plus assistant settings) to another Mac, so a second Mac
/// can reuse the Slack app instead of creating its own. It's the secrets themselves, only encoded, not encrypted.
enum LinkCode {
    static let prefix = "sglink1."
    private static let tokenKeys = [TokenKey.user, TokenKey.app, TokenKey.userRefresh, TokenKey.appRefresh,
                                    TokenKey.clientID, TokenKey.clientSecret, TokenKey.assistant]

    static func export() -> String? {
        var d: [String: String] = [:]
        for k in tokenKeys { if let v = Secrets.get(k), !v.isEmpty { d[k] = v } }
        guard d[TokenKey.user] != nil, d[TokenKey.app] != nil else { return nil }
        for k in [PrefKey.assistantURL, PrefKey.assistantName] {
            if let v = UserDefaults.standard.string(forKey: k), !v.isEmpty { d[k] = v }
        }
        guard let json = try? JSONEncoder().encode(d) else { return nil }
        return prefix + json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func looksLike(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
    }

    /// Stores everything in the code. Returns false if it isn't a valid link code.
    @discardableResult
    static func apply(_ code: String) -> Bool {
        var b = String(code.filter { !$0.isWhitespace }.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        guard looksLike(code), let data = Data(base64Encoded: b),
              let d = try? JSONDecoder().decode([String: String].self, from: data),
              d[TokenKey.user] != nil, d[TokenKey.app] != nil else { return false }
        for k in tokenKeys { Secrets.set(k, d[k]) }
        for k in [PrefKey.assistantURL, PrefKey.assistantName] where d[k] != nil {
            UserDefaults.standard.set(d[k], forKey: k)
        }
        return true
    }

    /// With rotating tokens, each renewal invalidates the previous refresh token, so two Macs can't both stay signed in.
    static var setupRotates: Bool {
        [TokenKey.user, TokenKey.app].contains { TokenRotation.isRotating(Secrets.get($0) ?? "") }
    }
}

enum NotificationStyle: String, CaseIterable, Identifiable {
    case hud, native, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hud: "Glass toasts"
        case .native: "macOS notifications"
        case .off: "Off (badge only)"
        }
    }
}

enum PrefKey {
    static let style = "notificationStyle"
    static let sound = "playSound"
    static let channelWide = "notifyChannelWide"
    static let keywords = "keywords"
    static let glassTint = "glassTint"
    static let showBubble = "showBubble"
    static let assistantURL = "assistantURL"
    static let assistantName = "assistantName"
    static let bubbleOrigin = "bubbleOrigin.v2"
}

enum Prefs {
    private static var d: UserDefaults { .standard }
    static var style: NotificationStyle { NotificationStyle(rawValue: d.string(forKey: PrefKey.style) ?? "") ?? .hud }
    static var playSound: Bool { d.object(forKey: PrefKey.sound) as? Bool ?? true }
    static var notifyChannelWide: Bool { d.bool(forKey: PrefKey.channelWide) }
    /// What your assistant is called; its slash command is the same word (e.g. "Assistant" → /assistant).
    static var assistantName: String {
        let n = (d.string(forKey: PrefKey.assistantName) ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Assistant" : n
    }
    static var assistantCommand: String { assistantName.lowercased().filter { !$0.isWhitespace } }
    static var showBubble: Bool { d.object(forKey: PrefKey.showBubble) as? Bool ?? true }
    static var keywords: [String] {
        (d.string(forKey: PrefKey.keywords) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

/// Inbox + watched threads survive restarts. Tokens never go here (see Secrets).
struct PersistedState: Codable {
    var inbox: [InboxItem] = []
    var watched: [String] = []
    var recents: [String]? = []
    var snoozed: [InboxItem]? = []
    var drafts: [String: String]? = [:]
    /// Slack conversation → the Assistant conversation started from it, so follow-ups keep their context.
    var assistantChats: [String: String]? = [:]
    /// Conversation → timestamp of its latest message, so Chats can sort by recent activity like Slack.
    var lastActivity: [String: Double]? = [:]
}

/// Slash commands are just files: `~/Library/Application Support/Slack Glass/Commands/silence.mp4`
/// makes `/silence` upload that video. `.txt`/`.md` files send their text instead.
enum SlashCommands {
    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Slack Glass/Commands", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    struct Command: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: String { name }
        var isText: Bool { ["txt", "md"].contains(url.pathExtension.lowercased()) }
        var isBuiltin: Bool { url.scheme == "slackglass" }
        var isVideo: Bool { ["mp4", "mov", "m4v", "webm"].contains(url.pathExtension.lowercased()) }
    }

    static func all() -> [Command] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.map { Command(name: $0.deletingPathExtension().lastPathComponent.lowercased(), url: $0) }
            .sorted { $0.name < $1.name }
    }

    /// "/sil hi" → (silence, "hi"). Exact name wins; otherwise a unique prefix match.
    static func parse(_ text: String) -> (command: Command?, name: String, rest: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/"), t.count > 1 else { return nil }
        let body = t.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace }).lowercased()
        let rest = String(body.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let cmds = all()
        if let exact = cmds.first(where: { $0.name == name }) { return (exact, name, rest) }
        let matches = cmds.filter { $0.name.hasPrefix(name) }
        return (matches.count == 1 ? matches[0] : nil, name, rest)
    }

    /// `/assistant` (or `/jar`…) is built in: it asks Assistant instead of sending a file.
    static func isAssistant(_ name: String) -> Bool { name.count >= 3 && Prefs.assistantCommand.hasPrefix(name) }

    static var assistant: Command { Command(name: Prefs.assistantCommand, url: URL(string: "slackglass://assistant")!) }

    static func matching(_ text: String) -> [Command] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let q = text.dropFirst().lowercased()
        return ([assistant] + all()).filter { q.isEmpty || $0.name.hasPrefix(q) }
    }
}

enum Persistence {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Slack Glass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    static func load() -> PersistedState {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(PersistedState.self, from: d) else {
            return PersistedState()
        }
        return s
    }

    static func save(_ s: PersistedState) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
