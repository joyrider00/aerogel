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
        catchUpTask?.cancel()
        if let demo {
            catchUpCards = demo.catchUpCards()
            return
        }
        guard let api else { return }
        catchUpScanning = true
        // Conversations with something in the last week, newest first. Slack only tells us each one's
        // read position one at a time, so the long tail of quiet channels is skipped.
        let weekAgo = Date().timeIntervalSince1970 - 7 * 24 * 3600
        let candidates = conversations.values
            .filter { $0.is_archived != true && !($0.is_im == true && users[$0.user ?? ""]?.deleted == true) }
            .map { (id: $0.id, latest: lastActivity[$0.id] ?? $0.estimatedActivity ?? 0, known: lastActivity[$0.id] != nil) }
            .filter { $0.latest > weekAgo }
            .sorted { $0.latest > $1.latest }
            .prefix(40)
        let me = meID
        catchUpTask = Task { [weak self] in
            defer { self?.catchUpScanning = false }
            for c in candidates {
                guard !Task.isCancelled else { return }
                guard let info = try? await api.call("conversations.info", ["channel": c.id]),
                      let ch = info["channel"] as? [String: Any],
                      let lastRead = (ch["last_read"] as? String).flatMap(Double.init) else { continue }
                // Known to be read already: skip the history call.
                if c.known, c.latest <= lastRead { continue }
                guard let h = try? await api.call("conversations.history",
                                                  ["channel": c.id, "oldest": String(format: "%.6f", lastRead), "limit": 20])
                else { continue }
                let msgs = SlackAPI.decodeList(SlackMessage.self, h["messages"])
                    .filter { $0.user != me && $0.subtype != "channel_join" && $0.subtype != "channel_leave" }
                    .reversed()
                guard !msgs.isEmpty, let self, !Task.isCancelled else { continue }
                msgs.compactMap(\.user).forEach { self.ensureUser($0) }
                self.catchUpCards.append(CatchUpCard(channel: c.id, messages: Array(msgs)))
            }
        }
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
