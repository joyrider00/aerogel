import AppKit
import SwiftUI

struct SwitchTarget: Identifiable, Hashable {
    enum Kind: Hashable { case conversation(String), user(String) }
    let kind: Kind
    let title: String
    let subtitle: String
    var id: String {
        switch kind {
        case .conversation(let c): "c:\(c)"
        case .user(let u): "u:\(u)"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Connection: Equatable { case idle, connecting, connected, failed(String) }

    // Workspace
    @Published var connection: Connection = .idle
    @Published var meID = ""
    @Published var teamID = ""
    @Published var users: [String: SlackUser] = [:] {
        didSet { renderCache.removeAll(); plainCache.removeAll(); chatCache = nil; handleIndex = nil }
    }
    @Published var conversations: [String: SlackConversation] = [:] { didSet { chatCache = nil } }
    @Published var customEmoji: [String: String] = [:]

    // HUD state
    @Published var inbox: [InboxItem] = [] {
        // Nothing needs you: show Chats instead of an empty list.
        didSet { if inbox.isEmpty && !oldValue.isEmpty { showChats = true } }
    }
    @Published var selectedInboxID: String?
    @Published var current: ConversationRef?
    @Published var messages: [SlackMessage] = []
    @Published var loadingConversation = false
    @Published var editing: SlackMessage?
    @Published var switcherOpen = false
    @Published var switcherQuery = ""
    @Published var switcherIndex = 0
    @Published var focusComposerTick = 0
    @Published var pinned = false
    @Published var history: [ConversationRef] = []
    @Published var showChats = false
    // Message search (the SEARCH tab).
    @Published var showSearch = false
    @Published var searchQuery = ""
    @Published var searchResults: [SearchHit] = []
    @Published var searchTotal = 0
    @Published var searchIndex = 0
    @Published var searchFocused = false
    @Published var searching = false
    @Published var searchError: String?
    @Published var searchFocusTick = 0
    var searchedQuery = ""
    var searchTask: Task<Void, Never>?
    /// The message to scroll to and highlight after opening a search result.
    @Published var focusTs: String?
    @Published var chatQuery = ""
    @Published private(set) var recents: [String] = []
    @Published var sendTick = 0
    @Published var chatIndex = 0
    @Published var chatSearchFocused = false
    @Published var publicChannels: [String: SlackConversation] = [:]
    @Published private(set) var snoozed: [InboxItem] = []
    /// Not @Published: saving a draft on every keystroke must not redraw the whole HUD.
    private(set) var drafts: [String: String] = [:]
    /// Which conversations have a draft (for the ✎ marker); changes only when one starts or empties.
    @Published private(set) var draftKeys: Set<String> = []
    @Published private(set) var presence: [String: Bool] = [:]
    @Published var notice: String?
    // Assistant: one chat per Slack conversation, shown in a panel above the composer.
    @Published var assistantSessions: [String: AssistantSession] = [:]
    @Published var assistantMode = false
    /// Text to drop into the reply box (Assistant's "Use as my reply").
    @Published var composerInsert: String?
    /// Files dropped anywhere on the HUD, picked up by the composer.
    @Published var droppedFiles: [URL]?
    @Published var dropHover = false
    var onShowHUD: ((ConversationRef) -> Void)?
    private var assistantChats: [String: String] = [:]
    private var timers: [Timer] = []
    private var renderCache: [String: AttributedString] = [:]
    private var plainCache: [String: String] = [:]
    private var chatCache: (key: String, sections: [ChatSection], index: [String: Int])?
    /// When each conversation last had a message (or was opened here). Drives Recent and the DM order.
    private(set) var lastActivity: [String: Double] = [:]
    @Published private(set) var activityVersion = 0
    private var activitySaveScheduled = false
    private var handleIndex: [String: String]?
    private var backfillTask: Task<Void, Never>?
    private var draftSaveWork: DispatchWorkItem?
    @Published var lastError: String?
    @Published private(set) var isDemo = false

    var hudVisible = false
    var onNotify: ((InboxItem) -> Void)?
    var onOpenSettings: (() -> Void)?

    private(set) var api: SlackAPI?
    private var socket: SocketModeClient?
    private var watched: [String] = []
    private var watchedSet: Set<String> = []
    private var pendingUsers: Set<String> = []
    private var pendingConversations: Set<String> = []
    private(set) var demo: DemoWorkspace?

    init() {
        let s = Persistence.load()
        inbox = s.inbox
        watched = s.watched
        watchedSet = Set(s.watched)
        recents = s.recents ?? []
        lastActivity = s.lastActivity ?? [:]
        snoozed = s.snoozed ?? []
        drafts = s.drafts ?? [:]
        draftKeys = Set(drafts.keys)
        assistantChats = s.assistantChats ?? [:]
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.wakeSnoozed() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPresence() }
        })
    }

    var hasTokens: Bool {
        !(Secrets.get(TokenKey.user) ?? "").isEmpty && !(Secrets.get(TokenKey.app) ?? "").isEmpty
    }

    var unseenCount: Int { inbox.filter { !$0.seen }.count }

    // MARK: - Connection

    func connect() {
        guard let userToken = Secrets.get(TokenKey.user), let appToken = Secrets.get(TokenKey.app) else {
            connection = .failed("Add your Slack tokens in Settings")
            return
        }
        stopDemoIfNeeded()
        socket?.stop()
        let api = SlackAPI(userToken: userToken)
        if TokenRotation.isRotating(userToken) || TokenRotation.canRefresh(TokenKey.userRefresh) {
            api.refreshUserToken = {
                let t = try await TokenRotation.refresh(accessKey: TokenKey.user, refreshKey: TokenKey.userRefresh)
                await MainActor.run { ImageCache.shared.token = t }
                return t
            }
        }
        self.api = api
        ImageCache.shared.token = userToken
        connection = .connecting

        Task {
            do {
                let auth = try await api.call("auth.test")
                meID = auth["user_id"] as? String ?? ""
                teamID = auth["team_id"] as? String ?? ""

                async let usersJSON = api.paginate("users.list", ["limit": 500], key: "members")
                async let convJSON = api.paginate(
                    "users.conversations",
                    ["types": "public_channel,private_channel,mpim,im", "exclude_archived": true, "limit": 999],
                    key: "channels")
                async let emojiJSON = api.call("emoji.list")

                var u: [String: SlackUser] = [:]
                for user in SlackAPI.decodeList(SlackUser.self, try await usersJSON) { u[user.id] = user }
                users = u
                var c: [String: SlackConversation] = [:]
                for conv in SlackAPI.decodeList(SlackConversation.self, try await convJSON) { c[conv.id] = conv }
                conversations = c
                customEmoji = (try? await emojiJSON)?["emoji"] as? [String: String] ?? [:]

                // Every public channel (not just joined ones) for Chats search. Best effort.
                Task {
                    if let all = try? await api.paginate(
                        "conversations.list",
                        ["types": "public_channel", "exclude_archived": true, "limit": 1000], key: "channels", maxPages: 10) {
                        var pc: [String: SlackConversation] = [:]
                        for c in SlackAPI.decodeList(SlackConversation.self, all) { pc[c.id] = c }
                        publicChannels = pc
                    }
                }
                refreshPresence()
                backfillActivity()

                let socket = SocketModeClient(appToken: appToken, api: api)
                if TokenRotation.isRotating(appToken) || TokenRotation.canRefresh(TokenKey.appRefresh) {
                    socket.refreshAppToken = {
                        try await TokenRotation.refresh(accessKey: TokenKey.app, refreshKey: TokenKey.appRefresh)
                    }
                }
                socket.onEvent = { [weak self] e in self?.handle(event: e) }
                socket.onStatus = { [weak self] s in
                    guard let self else { return }
                    switch s {
                    case .connecting: if self.connection != .connected { self.connection = .connecting }
                    case .connected: self.connection = .connected
                    case .disconnected(let why): self.connection = .failed("Reconnecting… (\(why))")
                    }
                }
                self.socket = socket
                socket.start()
            } catch {
                connection = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        socket?.stop()
        socket = nil
        api = nil
        connection = .idle
    }

    // MARK: - Names

    func userName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Someone" }
        if id == meID, let me = users[id] { return me.displayName }
        if let u = users[id] { return u.displayName }
        ensureUser(id)
        return "…"
    }

    func avatar(_ id: String?) -> URL? { id.flatMap { users[$0]?.avatarURL } }

    func author(of m: SlackMessage) -> (name: String, avatar: URL?) {
        if let u = m.user { return (userName(u), avatar(u)) }
        let icon = m.bot_profile?.icons?["image_72"] ?? m.bot_profile?.icons?["image_48"]
        return (m.bot_profile?.name ?? m.username ?? "App", icon.flatMap(URL.init(string:)))
    }

    func title(_ channel: String) -> String {
        guard let c = conversations[channel] ?? publicChannels[channel] else {
            ensureConversation(channel)
            return channel.hasPrefix("D") ? "Direct message" : "#…"
        }
        if c.is_im == true { return userName(c.user) }
        if c.is_mpim == true { return mpimTitle(c.name ?? "") }
        return "#" + (c.name ?? channel)
    }

    func isDirect(_ channel: String) -> Bool {
        conversations[channel]?.isDirect ?? channel.hasPrefix("D")
    }

    private func mpimHandles(_ name: String) -> [String] {
        var n = name
        if n.hasPrefix("mpdm-") { n.removeFirst(5) }
        if let r = n.range(of: #"-\d+$"#, options: .regularExpression) { n.removeSubrange(r) }
        return n.components(separatedBy: "--").filter { $0 != users[meID]?.name }
    }

    private func mpimTitle(_ name: String) -> String {
        var n = name
        if n.hasPrefix("mpdm-") { n.removeFirst(5) }
        if let r = n.range(of: #"-\d+$"#, options: .regularExpression) { n.removeSubrange(r) }
        if handleIndex == nil {
            var idx: [String: String] = [:]
            for u in users.values { if let h = u.name { idx[h] = u.id } }
            handleIndex = idx
        }
        // "mpdm-gianni--kevin.b--me-1" → "Gianni Rossi, Kevin Brown", using display names where known.
        return n.components(separatedBy: "--")
            .filter { $0 != users[meID]?.name }
            .map { h in handleIndex?[h].map { userName($0) } ?? h }
            .joined(separator: ", ")
    }

    var mrkdwnContext: Mrkdwn.Context {
        Mrkdwn.Context(
            userName: { [unowned self] in self.userName($0) },
            channelName: { [unowned self] id in self.conversations[id]?.name ?? id })
    }

    /// Parsing Slack's markup is regex work; views ask for the same text on every redraw, so it's remembered.
    func render(_ text: String) -> AttributedString {
        if let hit = renderCache[text] { return hit }
        let r = Mrkdwn.render(text, mrkdwnContext)
        if renderCache.count > 4000 { renderCache.removeAll() }
        renderCache[text] = r
        return r
    }

    func plain(_ text: String) -> String {
        if let hit = plainCache[text] { return hit }
        let r = Mrkdwn.plainText(text, mrkdwnContext)
        if plainCache.count > 4000 { plainCache.removeAll() }
        plainCache[text] = r
        return r
    }

    func emojiURL(_ name: String) -> URL? {
        var value = customEmoji[name]
        if let v = value, v.hasPrefix("alias:") { value = customEmoji[String(v.dropFirst(6))] }
        return value.flatMap(URL.init(string:))
    }

    func ensureUser(_ id: String) {
        guard let api, users[id] == nil, !pendingUsers.contains(id) else { return }
        pendingUsers.insert(id)
        Task {
            if let r = try? await api.call("users.info", ["user": id]), let u = SlackAPI.decode(SlackUser.self, r["user"]) {
                users[id] = u
            }
            pendingUsers.remove(id)
        }
    }

    private func ensureConversation(_ id: String) {
        guard let api, conversations[id] == nil, !pendingConversations.contains(id) else { return }
        pendingConversations.insert(id)
        Task {
            if let r = try? await api.call("conversations.info", ["channel": id]),
               let c = SlackAPI.decode(SlackConversation.self, r["channel"]) {
                conversations[id] = c
            }
            pendingConversations.remove(id)
        }
    }

    // MARK: - Realtime events

    func handle(event e: [String: Any]) {
        switch e["type"] as? String {
        case "message":
            handleMessageEvent(e)
        case "reaction_added", "reaction_removed":
            guard let item = e["item"] as? [String: Any],
                  let ch = item["channel"] as? String, let ts = item["ts"] as? String,
                  let name = e["reaction"] as? String, let user = e["user"] as? String else { return }
            applyReaction(channel: ch, ts: ts, name: name, user: user, added: e["type"] as? String == "reaction_added")
        default:
            break
        }
    }

    private static let visibleSubtypes: Set<String> = ["file_share", "thread_broadcast", "me_message", "bot_message"]

    private func handleMessageEvent(_ e: [String: Any]) {
        guard let ch = e["channel"] as? String else { return }
        let subtype = e["subtype"] as? String

        switch subtype {
        case "message_changed":
            guard let m = SlackAPI.decode(SlackMessage.self, e["message"]) else { return }
            if current?.channel == ch, let i = messages.firstIndex(where: { $0.ts == m.ts }) { messages[i] = m }
            if let i = inbox.firstIndex(where: { $0.channel == ch && $0.ts == m.ts }) { inbox[i].text = m.previewText }
            return
        case "message_deleted":
            guard let ts = e["deleted_ts"] as? String else { return }
            if current?.channel == ch { messages.removeAll { $0.ts == ts } }
            return
        case let s? where !Self.visibleSubtypes.contains(s):
            return
        default:
            break
        }

        guard let msg = SlackAPI.decode(SlackMessage.self, e) else { return }
        noteActivity(ch, ts: Double(msg.ts) ?? Date().timeIntervalSince1970)
        let channelType = e["channel_type"] as? String ?? (ch.hasPrefix("D") ? "im" : "channel")
        ensureConversation(ch)
        if let u = msg.user { ensureUser(u) }

        appendIfVisible(msg, channel: ch, subtype: subtype)

        // My own message: start watching that thread and clear it from the inbox.
        if msg.user == meID {
            watch(ch, msg.thread_ts ?? msg.ts)
            clearInbox(channel: ch, threadTs: msg.thread_ts)
            return
        }

        guard let reason = classify(msg, channel: ch, channelType: channelType) else { return }
        if reason == .mention { watch(ch, msg.thread_ts ?? msg.ts) }

        let isDMLike = channelType == "im" || channelType == "mpim"
        let threadKey = msg.thread_ts ?? (isDMLike ? nil : msg.ts)
        let item = upsertInbox(channel: ch, threadTs: threadKey, msg: msg, reason: reason)

        let viewing = hudVisible && current == item.ref
        if viewing {
            clearInbox(channel: item.channel, threadTs: item.threadTs) // you're looking at it
        } else {
            onNotify?(item)
        }
    }

    private func appendIfVisible(_ msg: SlackMessage, channel ch: String, subtype: String?) {
        guard let cur = current, cur.channel == ch else { return }
        let isReply = msg.thread_ts != nil && msg.thread_ts != msg.ts
        let belongs: Bool
        if let t = cur.threadTs {
            belongs = msg.thread_ts == t
        } else {
            belongs = !isReply || subtype == "thread_broadcast"
        }
        if belongs {
            if !messages.contains(where: { $0.ts == msg.ts }) { messages.append(msg) }
        } else if cur.threadTs == nil, let t = msg.thread_ts, let i = messages.firstIndex(where: { $0.ts == t }) {
            messages[i].reply_count = (messages[i].reply_count ?? 0) + 1
            var ru = messages[i].reply_users ?? []
            if let u = msg.user, !ru.contains(u) { ru.append(u) }
            messages[i].reply_users = ru
        }
    }

    private func classify(_ m: SlackMessage, channel: String, channelType: String) -> InboxReason? {
        let text = m.text ?? ""
        if channelType == "im" { return .dm }
        if !meID.isEmpty, text.contains("<@\(meID)") { return .mention }
        if Prefs.notifyChannelWide, text.contains("<!here") || text.contains("<!channel") || text.contains("<!everyone") {
            return .mention
        }
        if channelType == "mpim" { return .group }
        let lower = text.lowercased()
        if Prefs.keywords.contains(where: { lower.contains($0) }) { return .keyword }
        if let t = m.thread_ts, t != m.ts, watchedSet.contains("\(channel):\(t)") { return .thread }
        return nil
    }

    private func watch(_ channel: String, _ ts: String) {
        let key = "\(channel):\(ts)"
        guard !watchedSet.contains(key) else { return }
        watched.append(key)
        watchedSet.insert(key)
        if watched.count > 3000 {
            let drop = watched.prefix(500)
            watched.removeFirst(500)
            drop.forEach { watchedSet.remove($0) }
        }
        persist()
    }

    private func applyReaction(channel: String, ts: String, name: String, user: String, added: Bool) {
        guard current?.channel == channel, let i = messages.firstIndex(where: { $0.ts == ts }) else { return }
        var rs = messages[i].reactions ?? []
        if let j = rs.firstIndex(where: { $0.name == name }) {
            var r = rs[j]
            var us = r.users ?? []
            if added, !us.contains(user) { us.append(user); r.count += 1 }
            if !added, let k = us.firstIndex(of: user) { us.remove(at: k); r.count -= 1 }
            r.users = us
            if r.count <= 0 { rs.remove(at: j) } else { rs[j] = r }
        } else if added {
            rs.append(SlackReaction(name: name, users: [user], count: 1))
        }
        messages[i].reactions = rs.isEmpty ? nil : rs
    }

    // MARK: - Inbox

    @discardableResult
    private func upsertInbox(channel: String, threadTs: String?, msg: SlackMessage, reason: InboxReason) -> InboxItem {
        let id = InboxItem.makeID(channel, threadTs)
        var item: InboxItem
        if let j = snoozed.firstIndex(where: { $0.id == id }) {
            var woke = snoozed.remove(at: j)
            woke.snoozeUntil = nil
            inbox.removeAll { $0.id == id }
            inbox.insert(woke, at: 0)
        }
        if let i = inbox.firstIndex(where: { $0.id == id }) {
            item = inbox.remove(at: i)
            item.ts = msg.ts
            item.user = msg.user
            item.text = msg.previewText
            item.count += 1
            item.seen = false
            if reason.priority > item.reason.priority { item.reason = reason }
        } else {
            item = InboxItem(channel: channel, threadTs: threadTs, ts: msg.ts, user: msg.user, text: msg.previewText, reason: reason)
        }
        inbox.insert(item, at: 0)
        if inbox.count > 150 { inbox.removeLast(inbox.count - 150) }
        persist()
        return item
    }

    private func clearInbox(channel: String, threadTs: String?) {
        let before = inbox.count
        inbox.removeAll { $0.channel == channel && $0.threadTs == threadTs }
        if inbox.count != before { persist() }
    }

    func markDone(_ item: InboxItem) {
        let idx = inbox.firstIndex(of: item)
        inbox.removeAll { $0.id == item.id }
        if selectedInboxID == item.id, let idx {
            selectedInboxID = inbox.indices.contains(idx) ? inbox[idx].id : inbox.last?.id
        }
        persist()
    }

    func clearAll() {
        inbox.removeAll()
        persist()
    }

    /// Where the last opened item sat before it left the inbox.
    private var removedInboxIndex: Int?

    func moveSelection(_ delta: Int) {
        guard !inbox.isEmpty else { return }
        var i = inbox.firstIndex(where: { $0.id == selectedInboxID }) ?? (delta > 0 ? -1 : inbox.count)
        // The selected item was just opened and removed: the next one now sits at its old index.
        if !inbox.contains(where: { $0.id == selectedInboxID }), let r = removedInboxIndex { i = delta > 0 ? r - 1 : r }
        let n = max(0, min(inbox.count - 1, i + delta))
        selectedInboxID = inbox[n].id
    }

    func openSelected() {
        guard let item = inbox.first(where: { $0.id == selectedInboxID }) ?? inbox.first else { return }
        open(item.ref)
    }

    func markSelectedDone() {
        guard let item = inbox.first(where: { $0.id == selectedInboxID }) else { return }
        markDone(item)
    }

    private func persist() {
        guard !isDemo else { return }
        Persistence.save(PersistedState(inbox: inbox, watched: watched, recents: recents,
                                        snoozed: snoozed, drafts: drafts, assistantChats: assistantChats,
                                        lastActivity: lastActivity))
    }

    // MARK: - Conversation

    func open(_ ref: ConversationRef, pushHistory: Bool = true, focus: String? = nil) {
        if current != ref || focus != nil {
            if pushHistory, let cur = current, cur != ref {
                history.removeAll { $0 == ref }
                history.append(cur)
                if history.count > 30 { history.removeFirst() }
            }
            messages = []
            editing = nil
            assistantMode = false
            focusTs = focus
        }
        current = ref
        noteActivity(ref.channel, ts: Date().timeIntervalSince1970)
        recents.removeAll { $0 == ref.channel }
        recents.insert(ref.channel, at: 0)
        if recents.count > 20 { recents.removeLast() }
        persist()
        switcherOpen = false
        // Opening it is handling it: it leaves Activity. ⌥↓ continues from where it was.
        if let i = inbox.firstIndex(where: { $0.ref == ref }) {
            selectedInboxID = inbox[i].id
            removedInboxIndex = i
            inbox.remove(at: i)
            persist()
        }
        focusComposerTick += 1
        if let c = conversations[ref.channel], c.is_im == true, let u = c.user { fetchPresence([u]) }
        Task { await load(ref) }
    }

    var canGoBack: Bool { !history.isEmpty || current?.threadTs != nil }

    /// Back through history; from a thread with no history, back to its channel.
    func goBack() {
        if let prev = history.popLast() {
            open(prev, pushHistory: false)
        } else if let cur = current, cur.threadTs != nil {
            open(ConversationRef(channel: cur.channel, threadTs: nil), pushHistory: false)
        }
    }

    struct ChatSection: Identifiable {
        let id: String
        let title: String
        let items: [SwitchTarget]
    }

    private func chatTarget(_ c: SlackConversation, member: Bool = true) -> SwitchTarget {
        let sub = c.is_im == true ? "Direct message" : c.is_mpim == true ? "Group DM"
            : c.is_private == true ? "Private channel" : (member ? "Channel" : "Channel · not joined")
        return SwitchTarget(kind: .conversation(c.id), title: title(c.id), subtitle: sub)
    }

    /// Recent, Channels, Direct messages. With a query: matches, then public channels you haven't joined.
    /// Cached until conversations, people, recents, the query or the public channel list change.
    var chatSections: [ChatSection] { chatData().sections }

    var chatFlat: [SwitchTarget] { chatSections.flatMap(\.items) }

    /// Where a row sits in the arrow-key order.
    func chatPosition(_ id: String) -> Int { chatData().index[id] ?? -1 }

    private func chatData() -> (sections: [ChatSection], index: [String: Int]) {
        let key = "\(chatQuery)|\(recents.joined(separator: ","))|\(publicChannels.count)|\(activityVersion)"
        if let c = chatCache, c.key == key { return (c.sections, c.index) }
        let sections = buildChatSections()
        var index: [String: Int] = [:]
        for (i, t) in sections.flatMap(\.items).enumerated() where index[t.id] == nil { index[t.id] = i }
        chatCache = (key, sections, index)
        return (sections, index)
    }

    private func buildChatSections() -> [ChatSection] {
        let q = chatQuery.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            var out = [ChatSection(id: "results", title: "Results", items: results(for: q, limit: 40))]
            let needle = q.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            let others = publicChannels.values
                .filter { conversations[$0.id] == nil && ($0.name ?? "").lowercased().contains(needle) }
                .sorted { ($0.name ?? "") < ($1.name ?? "") }
                .prefix(20).map { chatTarget($0, member: false) }
            if !others.isEmpty { out.append(ChatSection(id: "browse", title: "Other channels", items: Array(others))) }
            return out.filter { !$0.items.isEmpty }
        }
        let activity = { (c: SlackConversation) in self.lastActivity[c.id] ?? c.estimatedActivity ?? 0 }
        // Recent: DMs and group DMs with the newest messages, plus channels you've opened here lately
        // (busy channels would otherwise crowd out the people you actually talk to).
        let openedChannels = Set(recents.prefix(8))
        let recentScore = { (c: SlackConversation) in c.isDirect || openedChannels.contains(c.id) ? activity(c) : 0 }
        let recent = conversations.values
            .filter { $0.is_archived != true && recentScore($0) > 0 && !(($0.is_im == true) && users[$0.user ?? ""]?.deleted == true) }
            .sorted { recentScore($0) > recentScore($1) }
            .prefix(10)
        let recentIDs = Set(recent.map(\.id))
        let live = conversations.values.filter { c in
            c.is_archived != true && !recentIDs.contains(c.id) && !(c.is_im == true && users[c.user ?? ""]?.deleted == true)
        }
        // One title lookup per conversation, then sort on the strings.
        let titled = live.map { (conv: $0, target: chatTarget($0)) }
        let chans = titled.filter { !$0.conv.isDirect }.sorted { $0.target.title.localizedCaseInsensitiveCompare($1.target.title) == .orderedAscending }
        // Like Slack: most recently active first, then alphabetical.
        let dms = titled.filter { $0.conv.isDirect }.sorted {
            let a = activity($0.conv), b = activity($1.conv)
            return a != b ? a > b : $0.target.title.localizedCaseInsensitiveCompare($1.target.title) == .orderedAscending
        }
        return [
            ChatSection(id: "recent", title: "Recent", items: recent.map { chatTarget($0) }),
            ChatSection(id: "channels", title: "Channels", items: chans.map(\.target)),
            ChatSection(id: "dms", title: "Direct messages", items: dms.map(\.target)),
        ].filter { !$0.items.isEmpty }
    }

    func moveChatSelection(_ d: Int) {
        let n = chatFlat.count
        guard n > 0 else { return }
        chatIndex = max(0, min(n - 1, chatIndex + d))
    }

    func openSelectedChat() {
        let flat = chatFlat
        guard flat.indices.contains(chatIndex) else { return }
        openSwitcherTarget(flat[chatIndex])
    }

    func closeConversation() {
        assistantMode = false
        history = []
        current = nil
        messages = []
        editing = nil
    }

    private func load(_ ref: ConversationRef) async {
        if let demo {
            messages = demo.messages(ref)
            return
        }
        guard let api else { return }
        loadingConversation = true
        defer { loadingConversation = false }
        do {
            var msgs: [SlackMessage]
            if let t = ref.threadTs {
                let r = try await api.call("conversations.replies", ["channel": ref.channel, "ts": t, "limit": 300])
                msgs = SlackAPI.decodeList(SlackMessage.self, r["messages"])
            } else {
                if let f = focusTs {
                    // Opened from search: the messages around that one, not the latest.
                    let older = try await api.call("conversations.history",
                                                   ["channel": ref.channel, "latest": f, "inclusive": true, "limit": 30])
                    let newer = try? await api.call("conversations.history",
                                                    ["channel": ref.channel, "oldest": f, "limit": 30])
                    let all = SlackAPI.decodeList(SlackMessage.self, older["messages"])
                        + SlackAPI.decodeList(SlackMessage.self, newer?["messages"])
                    var seen = Set<String>()
                    msgs = all.filter { seen.insert($0.ts).inserted }
                        .sorted { (Double($0.ts) ?? 0) < (Double($1.ts) ?? 0) }
                } else {
                    let r = try await api.call("conversations.history", ["channel": ref.channel, "limit": 60])
                    msgs = SlackAPI.decodeList(SlackMessage.self, r["messages"]).reversed()
                }
                if focusTs == nil, let last = msgs.last {
                    // Keeps the real Slack client's unread state in sync.
                    _ = try? await api.call("conversations.mark", ["channel": ref.channel, "ts": last.ts])
                }
            }
            guard current == ref else { return }
            msgs.compactMap(\.user).forEach { if users[$0] == nil { ensureUser($0) } }
            messages = msgs
        } catch let e as SlackError where e.code == "not_in_channel" || e.code == "channel_not_found" {
            lastError = "You're not in \(title(ref.channel)). Open it in Slack (⌘O) to join."
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Actions

    /// Handles "/name rest" by sending the command's file (or text). Returns nil when `text` isn't a command.
    func runSlashCommand(_ text: String, broadcast: Bool, to target: ConversationRef? = nil) async -> Bool? {
        guard let parsed = SlashCommands.parse(text) else { return nil }
        if SlashCommands.isAssistant(parsed.name) {
            guard let ref = target ?? current else { return false }
            if current != ref || !hudVisible { onShowHUD?(ref) }
            assistantMode = true
            if !parsed.rest.isEmpty { askAssistant(parsed.rest, about: ref) }
            return true
        }
        guard let cmd = parsed.command else {
            lastError = "No command /\(parsed.name). Add a file named \(parsed.name).mp4 (or .gif, .png, .txt…) to the Commands folder in Settings."
            return false
        }
        if cmd.isText {
            let body = (try? String(contentsOf: cmd.url, encoding: .utf8)) ?? ""
            let combined = parsed.rest.isEmpty ? body : parsed.rest + "\n" + body
            return await send(text: combined, files: [], broadcast: broadcast, to: target)
        }
        return await send(text: parsed.rest, files: [cmd.url], broadcast: broadcast, to: target)
    }

    func send(text: String, files: [URL], broadcast: Bool, to target: ConversationRef? = nil) async -> Bool {
        guard let ref = target ?? current else { return false }
        let body = encodeMentions(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !body.isEmpty || !files.isEmpty else { return false }

        if let demo {
            let m = demo.post(ref: ref, user: meID, text: body, files: files)
            sendTick += 1
            if current == ref { messages.append(m) }
            setDraft("", for: ref)
            clearInbox(channel: ref.channel, threadTs: ref.threadTs)
            return true
        }
        guard let api else { return false }
        do {
            if files.isEmpty {
                var p: [String: Any] = ["channel": ref.channel, "text": body, "link_names": true]
                if let t = ref.threadTs {
                    p["thread_ts"] = t
                    if broadcast { p["reply_broadcast"] = true }
                }
                let r = try await api.call("chat.postMessage", p)
                if var m = SlackAPI.decode(SlackMessage.self, r["message"]), current == ref,
                   !messages.contains(where: { $0.ts == m.ts }) {
                    if m.user == nil { m.user = meID }
                    messages.append(m)
                }
            } else {
                try await api.uploadFiles(files, channel: ref.channel, threadTs: ref.threadTs, comment: body)
            }
            if let t = ref.threadTs { watch(ref.channel, t) }
            clearInbox(channel: ref.channel, threadTs: ref.threadTs)
            setDraft("", for: ref)
            sendTick += 1
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func saveEdit(_ m: SlackMessage, text: String) async -> Bool {
        guard let ref = current else { return false }
        let body = encodeMentions(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !body.isEmpty else { return false }
        if let i = messages.firstIndex(where: { $0.ts == m.ts }) {
            messages[i].text = body
            messages[i].edited = .init(user: meID, ts: SlackTS.now())
        }
        editing = nil
        guard let api, demo == nil else { return true }
        do {
            try await api.call("chat.update", ["channel": ref.channel, "ts": m.ts, "text": body, "link_names": true])
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func delete(_ m: SlackMessage) {
        guard let ref = current else { return }
        messages.removeAll { $0.ts == m.ts }
        guard let api, demo == nil else { return }
        Task {
            do { try await api.call("chat.delete", ["channel": ref.channel, "ts": m.ts]) }
            catch { lastError = error.localizedDescription }
        }
    }

    func toggleReaction(_ m: SlackMessage, _ name: String) {
        guard let ref = current else { return }
        let mine = m.reactions?.first(where: { $0.name == name })?.users?.contains(meID) ?? false
        applyReaction(channel: ref.channel, ts: m.ts, name: name, user: meID, added: !mine)
        guard let api, demo == nil else { return }
        Task {
            do {
                try await api.call(mine ? "reactions.remove" : "reactions.add",
                                   ["channel": ref.channel, "timestamp": m.ts, "name": name])
            } catch {
                applyReaction(channel: ref.channel, ts: m.ts, name: name, user: meID, added: mine)
                lastError = error.localizedDescription
            }
        }
    }

    func copyLink(_ m: SlackMessage) {
        guard let ref = current else { return }
        Task {
            var link = "https://slack.com/archives/\(ref.channel)/p\(m.ts.replacingOccurrences(of: ".", with: ""))"
            if let api, demo == nil,
               let r = try? await api.call("chat.getPermalink", ["channel": ref.channel, "message_ts": m.ts]),
               let p = r["permalink"] as? String {
                link = p
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
    }

    /// Hands off to the real Slack app for things the API can't do (huddles, canvases, settings).
    func openInSlack(_ ref: ConversationRef? = nil) {
        guard let ref = ref ?? current else { return }
        var s = "slack://channel?team=\(teamID)&id=\(ref.channel)"
        if let t = ref.threadTs { s += "&message=\(t)&thread_ts=\(t)" }
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    /// Images open in Slack Glass's viewer; videos and other files open in Slack.
    func openFile(_ f: SlackFile) {
        if f.isImage, !f.isVideo {
            ImageViewer.shared.show(f)
        } else if let p = f.permalink.flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(p)
        }
    }

    /// Turns "@maya" into "<@U123>" for known users so mentions actually ping.
    private func encodeMentions(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(?<![<\w])@([\w.\-]+)"#) else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let handle = ns.substring(with: m.range(at: 1)).lowercased()
            let replacement: String?
            switch handle {
            case "here", "channel", "everyone": replacement = "<!\(handle)>"
            default:
                replacement = users.values.first { u in
                    u.deleted != true && (u.name?.lowercased() == handle
                        || u.displayName.lowercased().replacingOccurrences(of: " ", with: "") == handle)
                }.map { "<@\($0.id)>" }
            }
            if let replacement, let r = Range(m.range, in: out) { out.replaceSubrange(r, with: replacement) }
        }
        return out
    }

    // MARK: - Quick switcher

    var switcherResults: [SwitchTarget] { results(for: switcherQuery) }

    /// Matching conversations, most recently active first (like Slack's switcher), then people you could start
    /// a DM with. Group DMs match on any member's name or handle.
    func results(for query: String, limit: Int = 8) -> [SwitchTarget] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "#@"))
        let words = q.split(separator: " ").map(String.init)

        /// Every word must match the start of some word in one of the names.
        func matches(_ names: [String]) -> Bool {
            guard !words.isEmpty else { return true }
            let parts = names.flatMap { $0.lowercased().split(whereSeparator: { " ,._-".contains($0) }).map(String.init) }
                + names.map { $0.lowercased() }
            return words.allSatisfy { w in parts.contains { $0.hasPrefix(w) } }
        }

        var convs: [(activity: Double, target: SwitchTarget)] = []
        var dmUsers = Set<String>()
        for c in conversations.values where c.is_archived != true {
            let activity = lastActivity[c.id] ?? c.estimatedActivity ?? 0
            if c.is_im == true, let u = c.user {
                dmUsers.insert(u)
                guard users[u]?.deleted != true else { continue }
                let user = users[u]
                guard matches([userName(u), user?.name ?? "", user?.real_name ?? ""]) else { continue }
                convs.append((activity, SwitchTarget(kind: .conversation(c.id), title: userName(u), subtitle: "Direct message")))
            } else {
                let t = title(c.id)
                var names = [t.trimmingCharacters(in: CharacterSet(charactersIn: "#"))]
                if c.is_mpim == true { names += mpimHandles(c.name ?? "") }
                guard matches(names) else { continue }
                convs.append((activity, SwitchTarget(kind: .conversation(c.id), title: t,
                                                     subtitle: c.is_mpim == true ? "Group DM" : (c.is_private == true ? "Private channel" : "Channel"))))
            }
        }
        let byRecent = convs.sorted {
            $0.activity != $1.activity ? $0.activity > $1.activity : $0.target.title < $1.target.title
        }
        guard !q.isEmpty else { return Array(byRecent.map(\.target).prefix(limit)) }

        // A typed name first offers a 1:1 chat with that person (their DM, or a new one), then every
        // conversation they're in, most recent first.
        let dmFor = Dictionary(conversations.values.compactMap { c in c.is_im == true ? c.user.map { ($0, c.id) } : nil },
                               uniquingKeysWith: { a, _ in a })
        let people = users.values
            .filter { $0.deleted != true && $0.is_bot != true && $0.id != meID
                && matches([$0.displayName, $0.name ?? "", $0.real_name ?? ""]) }
            .sorted {
                let a = dmFor[$0.id].flatMap { lastActivity[$0] } ?? 0, b = dmFor[$1.id].flatMap { lastActivity[$0] } ?? 0
                return a != b ? a > b : $0.displayName < $1.displayName
            }
            .prefix(3)
        let chats = people.map { u in
            dmFor[u.id].map { SwitchTarget(kind: .conversation($0), title: u.displayName, subtitle: "Direct message") }
                ?? SwitchTarget(kind: .user(u.id), title: u.displayName, subtitle: "New chat")
        }
        let shownDMs = Set(people.compactMap { dmFor[$0.id] })
        let rest = byRecent.map(\.target).filter {
            if case .conversation(let id) = $0.kind { return !shownDMs.contains(id) }
            return true
        }
        return Array((chats + rest).prefix(limit))
    }

    func openSwitcherTarget(_ t: SwitchTarget) {
        switcherOpen = false
        switcherQuery = ""
        switch t.kind {
        case .conversation(let id):
            open(ConversationRef(channel: id, threadTs: nil))
        case .user(let uid):
            guard let api else { return }
            Task {
                do {
                    let r = try await api.call("conversations.open", ["users": uid, "return_im": true])
                    if let c = SlackAPI.decode(SlackConversation.self, r["channel"]) {
                        var conv = c
                        if conv.user == nil { conv.user = uid; conv.is_im = true }
                        conversations[conv.id] = conv
                        open(ConversationRef(channel: conv.id, threadTs: nil))
                    }
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Demo

    func startDemo() {
        disconnect()
        let d = DemoWorkspace()
        demo = d
        isDemo = true
        meID = d.meID
        teamID = "TDEMO"
        users = d.users
        conversations = d.conversations
        customEmoji = [:]
        inbox = d.initialInbox
        presence = ["UALEX": true, "USAM": true, "UMAYA": false, "UDEV": true, "UPRIYA": false]
        selectedInboxID = inbox.first?.id
        connection = .connected

        // A live message shortly after launch, so toasts can be seen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.demo != nil else { return }
            self.handle(event: d.incomingDemoEvent())
        }
    }

    private func stopDemoIfNeeded() {
        guard demo != nil else { return }
        demo = nil
        isDemo = false
        closeConversation()
        let s = Persistence.load()
        inbox = s.inbox
        users = [:]
        conversations = [:]
    }
}

// MARK: - Snooze, drafts, presence, scheduling, links
// (Same file so these can use the model's private state.)

extension AppModel {
    // Snooze

    static func snoozeOptions(now: Date = Date()) -> [(label: String, date: Date)] {
        let cal = Calendar.current
        let tomorrow9 = cal.date(bySettingHour: 9, minute: 0, second: 0,
                                 of: cal.date(byAdding: .day, value: 1, to: now)!)!
        let monday9 = cal.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2),
                                   matchingPolicy: .nextTime)!
        return [
            ("20 minutes", now.addingTimeInterval(20 * 60)),
            ("1 hour", now.addingTimeInterval(3600)),
            ("3 hours", now.addingTimeInterval(3 * 3600)),
            ("Tomorrow 9 AM", tomorrow9),
            ("Monday 9 AM", monday9),
        ]
    }

    func snooze(_ item: InboxItem, until date: Date) {
        inbox.removeAll { $0.id == item.id }
        var s = item
        s.snoozeUntil = date
        snoozed.removeAll { $0.id == item.id }
        snoozed.append(s)
        if selectedInboxID == item.id { selectedInboxID = inbox.first?.id }
        persist()
        notice = "Snoozed until \(Self.shortDate(date))"
    }

    func snoozeSelected() {
        guard let item = inbox.first(where: { $0.id == selectedInboxID }) else { return }
        snooze(item, until: Date().addingTimeInterval(3600))
    }

    func wake(_ item: InboxItem, notify: Bool = false) {
        snoozed.removeAll { $0.id == item.id }
        var w = item
        w.snoozeUntil = nil
        w.seen = false
        inbox.removeAll { $0.id == item.id }
        inbox.insert(w, at: 0)
        persist()
        if notify { onNotify?(w) }
    }

    func wakeSnoozed() {
        let now = Date()
        for item in snoozed where (item.snoozeUntil ?? now) <= now { wake(item, notify: true) }
    }

    static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .short
        f.timeStyle = .short
        return f.string(from: d)
    }

    // Drafts

    private static func draftKey(_ r: ConversationRef) -> String { "\(r.channel)|\(r.threadTs ?? "")" }

    func draft(for r: ConversationRef) -> String { drafts[Self.draftKey(r)] ?? "" }

    func hasDraft(_ r: ConversationRef) -> Bool { draftKeys.contains(Self.draftKey(r)) }

    func setDraft(_ text: String, for r: ConversationRef) {
        let k = Self.draftKey(r)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            guard drafts[k] != nil else { return }
            drafts[k] = nil
            draftKeys.remove(k)
        } else {
            guard drafts[k] != text else { return }
            drafts[k] = text
            if !draftKeys.contains(k) { draftKeys.insert(k) }
        }
        draftSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        draftSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // Presence (Slack's Events API has no presence or typing events, so we poll the people on screen)

    func isOnline(_ id: String?) -> Bool? { id.flatMap { presence[$0] } }

    func noteActivity(_ channel: String, ts: Double) {
        guard ts > (lastActivity[channel] ?? -1) else { return }
        lastActivity[channel] = ts
        activityVersion += 1
        guard !activitySaveScheduled else { return }
        activitySaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.activitySaveScheduled = false
            self?.persist()
        }
    }

    /// Slack's API doesn't say when a conversation last had a message, so after connecting this asks each one
    /// for its newest message, slowly in the background, likeliest-recent first. Live events
    /// keep it current after that.
    func backfillActivity() {
        guard demo == nil, let api else { return }
        backfillTask?.cancel()
        // Likeliest-recent first, so Recent is right within seconds; the long tail of old chats is skipped.
        let guess = { (c: SlackConversation) in max(self.lastActivity[c.id] ?? 0, c.estimatedActivity ?? 0) }
        let ordered = conversations.values
            .filter { $0.is_archived != true && !($0.is_im == true && users[$0.user ?? ""]?.deleted == true) }
            .sorted { guess($0) > guess($1) }
            .prefix(150)
            .map(\.id)
        backfillTask = Task { [weak self] in
            for id in ordered {
                guard !Task.isCancelled else { return }
                if let r = try? await api.call("conversations.history", ["channel": id, "limit": 1]) {
                    let ts = ((r["messages"] as? [[String: Any]])?.first?["ts"] as? String).flatMap(Double.init)
                    self?.noteActivity(id, ts: ts ?? 0)
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000) // stays under Slack's ~50 calls a minute
            }
        }
    }

    func refreshPresence() {
        guard api != nil, demo == nil else { return }
        var ids: [String] = []
        func add(_ id: String?) { if let id, id != meID, !ids.contains(id) { ids.append(id) } }
        if let cur = current, let c = conversations[cur.channel], c.is_im == true { add(c.user) }
        inbox.prefix(15).forEach { add($0.user) }
        recents.prefix(10).forEach { if let c = conversations[$0], c.is_im == true { add(c.user) } }
        messages.suffix(20).forEach { add($0.user) }
        fetchPresence(Array(ids.prefix(30)))
    }

    func fetchPresence(_ ids: [String]) {
        guard let api, demo == nil, !ids.isEmpty else { return }
        Task {
            for id in ids {
                if let r = try? await api.call("users.getPresence", ["user": id]) {
                    presence[id] = (r["presence"] as? String) == "active"
                }
            }
        }
    }

    // Scheduled send

    func schedule(text: String, at date: Date, broadcast: Bool) async -> Bool {
        guard let ref = current else { return false }
        let body = encodeMentions(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !body.isEmpty else { return false }
        guard date > Date().addingTimeInterval(30) else {
            lastError = "Pick a time at least a minute from now."
            return false
        }
        if demo == nil {
            guard let api else { return false }
            var p: [String: Any] = ["channel": ref.channel, "text": body, "link_names": true,
                                    "post_at": Int(date.timeIntervalSince1970)]
            if let t = ref.threadTs {
                p["thread_ts"] = t
                if broadcast { p["reply_broadcast"] = true }
            }
            do { try await api.call("chat.scheduleMessage", p) } catch {
                lastError = error.localizedDescription
                return false
            }
        }
        setDraft("", for: ref)
        notice = "Scheduled for \(Self.shortDate(date))"
        return true
    }

    // Links: Slack links go to the Slack desktop app instead of the browser.

    func handleLink(_ url: URL) -> OpenURLAction.Result {
        // Messages are written by other people: a link must not launch a local file or another app's URL scheme.
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "mailto", "slack"].contains(scheme) else { return .discarded }
        guard let host = url.host?.lowercased(), host == "slack.com" || host.hasSuffix(".slack.com") else {
            return .systemAction
        }
        let parts = url.pathComponents
        var channel: String?
        var message: String?
        if let i = parts.firstIndex(of: "archives"), parts.count > i + 1 {
            channel = parts[i + 1]
            if parts.count > i + 2, parts[i + 2].hasPrefix("p") {
                let digits = parts[i + 2].dropFirst()
                if digits.count > 6 { message = digits.dropLast(6) + "." + digits.suffix(6) }
            }
        } else if let i = parts.firstIndex(of: "client"), parts.count > i + 2 {
            channel = parts[i + 2]
        }
        guard let channel else {
            // Not a conversation link (e.g. a file or settings page). Hand it to the app anyway.
            NSWorkspace.shared.open(URL(string: "slack://open?team=\(teamID)")!)
            return .handled
        }
        let thread = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "thread_ts" }?.value
        var s = "slack://channel?team=\(teamID)&id=\(channel)"
        if let message { s += "&message=\(message)" }
        if let thread { s += "&thread_ts=\(thread)" }
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
        return .handled
    }
}

// MARK: - Assistant

struct AssistantTurn: Identifiable, Hashable {
    let id = UUID()
    let question: String
    var answer = ""
    var activity: String?
    var done = false
    var error: String?
    var approvals: [AssistantApproval] = []
}

struct AssistantSession: Hashable {
    var turns: [AssistantTurn] = []
}

extension AppModel {
    private static func refKey(_ r: ConversationRef) -> String { "\(r.channel)|\(r.threadTs ?? "")" }

    var assistantClient: AssistantClient? {
        let url = UserDefaults.standard.string(forKey: PrefKey.assistantURL) ?? ""
        guard let base = URL(string: url.trimmingCharacters(in: .whitespaces)), AssistantClient.isSafe(base),
              let token = Secrets.get(TokenKey.assistant), !token.isEmpty else { return nil }
        return AssistantClient(baseURL: base, token: token)
    }

    func assistantSession(_ r: ConversationRef?) -> AssistantSession? { r.flatMap { assistantSessions[Self.refKey($0)] } }

    /// Forget this Slack conversation's Assistant chat; the next question starts a fresh one.
    func newAssistantChat(_ r: ConversationRef) {
        assistantSessions[Self.refKey(r)] = nil
        assistantChats[Self.refKey(r)] = nil
        persist()
    }

    func closeAssistant() {
        assistantMode = false
        focusComposerTick += 1
    }

    /// Asks Assistant about a Slack conversation: the question, what's on screen, and which conversation it is.
    func askAssistant(_ question: String, about ref: ConversationRef) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let key = Self.refKey(ref)
        var session = assistantSessions[key] ?? AssistantSession()
        let turn = AssistantTurn(question: q)
        session.turns.append(turn)
        assistantSessions[key] = session
        guard let client = assistantClient else {
            update(key, turn.id) { $0.error = "Connect \(Prefs.assistantName) in Settings → Assistant first."; $0.done = true }
            return
        }
        Task {
            let screen = await transcript(for: ref)
            var slack: [String: Any] = ["channel": ref.channel, "name": assistantName(ref.channel)]
            if let t = ref.threadTs { slack["thread"] = t }
            do {
                let answer = try await client.ask(text: q, conversationId: assistantChats[key], screen: screen, slack: slack) { [weak self] e in
                    self?.update(key, turn.id) { t in
                        switch e {
                        case .text(let s): t.answer += s; t.activity = nil
                        case .tool(let name): t.activity = Self.describe(tool: name)
                        }
                    }
                }
                if let id = answer.conversationId {
                    assistantChats[key] = id
                    persist()
                }
                update(key, turn.id) { t in
                    if !answer.text.isEmpty { t.answer = answer.text }
                    t.approvals = answer.approvals.filter { $0.kind == "slack" || $0.status == "pending" }
                    t.activity = nil
                    t.done = true
                }
            } catch {
                update(key, turn.id) { $0.error = error.localizedDescription; $0.activity = nil; $0.done = true }
            }
        }
    }

    func decideAssistant(_ approval: AssistantApproval, approve: Bool, text: String?, ref: ConversationRef) {
        guard let client = assistantClient else { return }
        let key = Self.refKey(ref)
        Task {
            do {
                let r = try await client.decide(approval.id, approve: approve, text: text)
                setApproval(key, approval.id) { $0.status = r.status; $0.error = r.error; if let text { $0.text = text } }
            } catch {
                setApproval(key, approval.id) { $0.error = error.localizedDescription }
            }
        }
    }

    private func update(_ key: String, _ id: UUID, _ change: (inout AssistantTurn) -> Void) {
        guard var s = assistantSessions[key], let i = s.turns.firstIndex(where: { $0.id == id }) else { return }
        change(&s.turns[i])
        assistantSessions[key] = s
    }

    private func setApproval(_ key: String, _ id: String, _ change: (inout AssistantApproval) -> Void) {
        guard var s = assistantSessions[key] else { return }
        for i in s.turns.indices {
            if let j = s.turns[i].approvals.firstIndex(where: { $0.id == id }) { change(&s.turns[i].approvals[j]) }
        }
        assistantSessions[key] = s
    }

    private func assistantName(_ channel: String) -> String {
        guard let c = conversations[channel] else { return title(channel) }
        if c.is_im == true { return "a DM with \(userName(c.user))" }
        if c.is_mpim == true { return "a group DM with \(title(channel))" }
        return title(channel)
    }

    /// The conversation as text: what you are looking at, oldest first, capped to what's useful.
    private func transcript(for ref: ConversationRef) async -> String {
        var msgs = current == ref ? messages : []
        if msgs.isEmpty, let api, demo == nil {
            let r = ref.threadTs != nil
                ? try? await api.call("conversations.replies", ["channel": ref.channel, "ts": ref.threadTs!, "limit": 100])
                : try? await api.call("conversations.history", ["channel": ref.channel, "limit": 40])
            msgs = SlackAPI.decodeList(SlackMessage.self, r?["messages"])
            if ref.threadTs == nil { msgs.reverse() }
        }
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        var lines = msgs.suffix(60).map { m -> String in
            var line = "\(author(of: m).name) (\(f.string(from: m.date)), ts \(m.ts)): \(plain(m.text ?? ""))"
            if let files = m.files, !files.isEmpty { line += " [files: \(files.map(\.displayName).joined(separator: ", "))]" }
            if let n = m.reply_count, n > 0, ref.threadTs == nil { line += " [\(n) replies in thread \(m.ts)]" }
            return line
        }
        var total = lines.reduce(0) { $0 + $1.count }
        while total > 15000, lines.count > 1 { total -= lines.removeFirst().count }
        let header = "Slack: \(ref.threadTs != nil ? "thread in " : "")\(assistantName(ref.channel))"
        return ([header] + lines).joined(separator: "\n")
    }

    private static func describe(tool: String) -> String {
        switch tool {
        case let t where t.hasPrefix("slack_read"): "Reading Slack…"
        case let t where t.hasPrefix("slack_search"): "Searching Slack…"
        case let t where t.hasPrefix("draft_slack"): "Drafting a reply…"
        case let t where t.contains("search"): "Searching…"
        case let t where t.contains("calendar") || t.contains("agenda"): "Checking the calendar…"
        case let t where t.contains("email") || t.contains("gmail"): "Checking email…"
        case let t where t.contains("note"): "Looking through notes…"
        default: "Working (\(tool))…"
        }
    }
}
