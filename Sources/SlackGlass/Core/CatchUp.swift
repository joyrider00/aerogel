import Foundation

/// One conversation with messages you haven't read, as a card in Catch up.
struct CatchUpCard: Identifiable, Equatable {
    let channel: String
    let messages: [SlackMessage]   // oldest first
    var id: String { channel }
    var latestTs: String { messages.last?.ts ?? "0" }
}

/// Catch up, like Slack's: go through every channel and chat with unread messages one at a time,
/// and mark each one read or keep it for later.
extension AppModel {
    var catchUpCard: CatchUpCard? { catchUpCards.indices.contains(catchUpIndex) ? catchUpCards[catchUpIndex] : nil }

    func startCatchUp() {
        showSearch = false
        showChats = false
        showCatchUp = true
        catchUpCards = []
        catchUpIndex = 0
        catchUpChecked = 0
        catchUpTotal = 0
        catchUpTask?.cancel()
        if let demo {
            catchUpCards = demo.catchUpCards()
            return
        }
        guard let api else { return }
        catchUpScanning = true
        let me = meID
        catchUpTask = Task { [weak self] in
            defer { self?.catchUpScanning = false }
            // 1. Where the newest messages are, across every conversation, from a few pages of search.
            //    (Slack's own "updated" field isn't message activity: it said a busy channel was quiet for months.)
            await self?.noteRecentActivityFromSearch(api)
            guard let self, !Task.isCancelled else { return }

            // 2. Every conversation you're in: ones with recent messages first, then the other channels,
            //    then DMs and group DMs Slack Glass hasn't seen activity in.
            let all = self.conversations.values.filter {
                $0.is_archived != true && !($0.is_im == true && self.users[$0.user ?? ""]?.deleted == true)
            }
            let monthAgo = Date().timeIntervalSince1970 - 30 * 86_400
            let active = all.filter { (self.lastActivity[$0.id] ?? 0) > monthAgo }
                .sorted { (self.lastActivity[$0.id] ?? 0) > (self.lastActivity[$1.id] ?? 0) }
            let activeIDs = Set(active.map(\.id))
            let rest = all.filter { !activeIDs.contains($0.id) }
            let order = active.map(\.id) + rest.filter { !$0.isDirect }.map(\.id) + rest.filter(\.isDirect).map(\.id)
            self.catchUpTotal = order.count

            // The recent ones a few at a time so the first cards show up fast; the long tail one at a time,
            // slowly enough that the rest of Slack Glass stays within Slack's rate limits.
            var i = 0
            while i < order.count, !Task.isCancelled {
                let fast = i < active.count
                let batch = Array(order[i..<min(i + (fast ? 4 : 1), fast ? active.count : order.count)])
                i += batch.count
                let checks = await withTaskGroup(of: UnreadCheck.self) { group in
                    for id in batch {
                        let known = self.lastActivity[id]
                        let readPos = self.catchUpReadPos[id]
                        group.addTask { await Self.checkUnread(api, id, me: me, latest: known, readPos: readPos) }
                    }
                    var out: [UnreadCheck] = []
                    for await c in group { out.append(c) }
                    return out
                }
                guard !Task.isCancelled else { return }
                self.catchUpChecked = i
                for c in checks {
                    if let pos = c.lastRead { self.catchUpReadPos[c.id] = pos }
                    if let ts = c.newest { self.noteActivity(c.id, ts: ts) }
                    if let card = c.card { self.addCatchUpCard(card) }
                }
                if !fast { try? await Task.sleep(nanoseconds: 700_000_000) }
            }
        }
    }

    /// A few pages of the newest messages anywhere, so busy conversations are checked first. Best effort.
    private func noteRecentActivityFromSearch(_ api: SlackAPI) async {
        let since = ISO8601DateFormatter.string(from: Date().addingTimeInterval(-3 * 86_400), timeZone: .current,
                                               formatOptions: [.withFullDate])
        for page in 1...4 {
            guard !Task.isCancelled,
                  let r = try? await api.call("search.messages", ["query": "after:\(since)", "sort": "timestamp",
                                                                  "sort_dir": "desc", "count": 100, "page": page]),
                  let m = r["messages"] as? [String: Any], let matches = m["matches"] as? [[String: Any]]
            else { return }
            for hit in matches {
                if let ch = (hit["channel"] as? [String: Any])?["id"] as? String, conversations[ch] != nil,
                   let ts = (hit["ts"] as? String).flatMap(Double.init) {
                    noteActivity(ch, ts: ts)
                }
            }
            let pages = (m["paging"] as? [String: Any])?["pages"] as? Int ?? 1
            if page >= pages { return }
        }
    }

    struct UnreadCheck: Sendable {
        let id: String
        var lastRead: Double?
        var newest: Double?
        var card: CatchUpCard?
    }

    /// The conversation's unread messages (not yours, not joins) as a card, plus its read position
    /// so the next Catch up can skip it while nothing new arrives.
    nonisolated private static func checkUnread(_ api: SlackAPI, _ id: String, me: String,
                                                latest: Double?, readPos: Double?) async -> UnreadCheck {
        var out = UnreadCheck(id: id)
        // Nothing new since Catch up last saw it read: no need to ask Slack.
        if let readPos, (latest ?? 0) <= readPos { return out }
        guard let info = try? await api.call("conversations.info", ["channel": id]),
              let ch = info["channel"] as? [String: Any],
              let lastReadStr = ch["last_read"] as? String, let lastRead = Double(lastReadStr) else { return out }
        out.lastRead = lastRead
        if let latest, latest <= lastRead { return out }
        guard let h = try? await api.call("conversations.history", ["channel": id, "oldest": lastReadStr, "limit": 20])
        else { return out }
        let msgs = SlackAPI.decodeList(SlackMessage.self, h["messages"])
        out.newest = msgs.first.flatMap { Double($0.ts) }
        let theirs = msgs.filter {
            $0.user != me && !["channel_join", "channel_leave", "group_join", "group_leave"].contains($0.subtype ?? "")
        }
        if !theirs.isEmpty { out.card = CatchUpCard(channel: id, messages: theirs.reversed()) }
        return out
    }

    /// Newest first, without moving the card you're looking at or the ones you've been through.
    private func addCatchUpCard(_ card: CatchUpCard) {
        guard !catchUpCards.contains(where: { $0.channel == card.channel }) else { return }
        card.messages.compactMap(\.user).forEach { if users[$0] == nil { ensureUser($0) } }
        let newest = Double(card.latestTs) ?? 0
        let from = min(catchUpIndex + 1, catchUpCards.count)
        let at = catchUpCards[from...].firstIndex { (Double($0.latestTs) ?? 0) < newest } ?? catchUpCards.count
        catchUpCards.insert(card, at: catchUpCards.isEmpty ? 0 : max(at, from))
    }

    func closeCatchUp() {
        catchUpTask?.cancel()
        showCatchUp = false
        catchUpScanning = false
    }

    /// Slack marks it read too (and your other Macs, through the team server).
    func catchUpMarkRead() {
        guard let card = catchUpCard else { return }
        let ref = ConversationRef(channel: card.channel, threadTs: nil)
        if let api, demo == nil {
            Task { _ = try? await api.call("conversations.mark", ["channel": card.channel, "ts": card.latestTs]) }
        }
        syncRead(ref, upTo: card.latestTs)
        catchUpReadPos[card.channel] = Double(card.latestTs)
        clearInbox(channel: card.channel, threadTs: nil)
        catchUpIndex += 1
    }

    func catchUpSkip() {
        guard catchUpCard != nil else { return }
        catchUpIndex += 1
    }

    func catchUpBack() {
        if catchUpIndex > 0 { catchUpIndex -= 1 }
    }

    /// Opening a conversation reads it, like anywhere else in Slack Glass.
    func catchUpOpen() {
        guard let card = catchUpCard else { return }
        catchUpIndex += 1
        open(ConversationRef(channel: card.channel, threadTs: nil))
    }
}

