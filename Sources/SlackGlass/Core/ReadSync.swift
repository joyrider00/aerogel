import Foundation

/// Slack itself is the source of truth for what you've read. Handling something here marks it read in Slack,
/// and reading it in Slack (desktop, web, phone) takes it out of Activity here. Your other Macs follow both ways.
extension AppModel {
    /// Marks `ref` read in Slack up to `ts`. A channel's read line never moves backwards: if you've already
    /// read further in Slack, it's left alone. Threads use Slack's thread read marker (forward only).
    func markReadInSlack(_ ref: ConversationRef, upTo ts: String) {
        guard demo == nil, let api, let upTo = Double(ts) else { return }
        Task {
            if let thread = ref.threadTs, thread != ts {
                _ = try? await api.call("subscriptions.thread.mark",
                                        ["channel": ref.channel, "thread_ts": thread, "ts": ts, "read": 1])
            } else {
                let info = try? await api.call("conversations.info", ["channel": ref.channel])
                let lastRead = ((info?["channel"] as? [String: Any])?["last_read"] as? String).flatMap(Double.init) ?? 0
                guard lastRead < upTo else { return }
                _ = try? await api.call("conversations.mark", ["channel": ref.channel, "ts": ts])
            }
        }
    }

    /// Takes out of Activity whatever you've since read in Slack. Runs every minute and when the panel opens.
    func reconcileReadsWithSlack(force: Bool = false) {
        guard demo == nil, let api, connection == .connected, !readSyncRunning else { return }
        guard force || Date().timeIntervalSince(lastReadSync) > 20 else { return }
        let held = readSyncHold.filter { Date().timeIntervalSince($0.value) < 90 }
        readSyncHold = held
        let items = inbox.filter { item in
            // A thread you marked unread here can't be marked unread in Slack, so Slack would undo it at once.
            !(item.isMarkedUnread && item.threadTs != nil && item.threadTs != item.ts)
                && held[item.id] == nil
                && draft(for: item.ref).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.prefix(30)
        guard !items.isEmpty else { return }
        readSyncRunning = true
        lastReadSync = Date()
        Task {
            defer { readSyncRunning = false }
            var channelRead: [String: Double] = [:]
            func channelLastRead(_ ch: String) async -> Double {
                if let r = channelRead[ch] { return r }
                let info = try? await api.call("conversations.info", ["channel": ch])
                let r = ((info?["channel"] as? [String: Any])?["last_read"] as? String).flatMap(Double.init) ?? 0
                channelRead[ch] = r
                return r
            }
            var read: [String: String] = [:]   // item id → the ts Slack has read past
            for item in items {
                guard self.api != nil else { return }
                let ts = Double(item.ts) ?? 0
                if let thread = item.threadTs, thread != item.ts {
                    let r = try? await api.call("conversations.replies", ["channel": item.channel, "ts": thread, "limit": 1])
                    let parent = (r?["messages"] as? [[String: Any]])?.first
                    if let lastRead = (parent?["last_read"] as? String).flatMap(Double.init) {
                        if lastRead >= ts { read[item.id] = item.ts }
                    } else if parent?["subscribed"] as? Bool == false,
                              await channelLastRead(item.channel) >= (Double(thread) ?? .infinity) {
                        // A thread you don't follow: Slack never shows its replies as unread, so once you've read
                        // the conversation past where it starts, it's handled.
                        read[item.id] = item.ts
                    }
                } else if await channelLastRead(item.channel) >= ts {
                    read[item.id] = item.ts
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !read.isEmpty else { return }
            // Only what hasn't changed meanwhile: a newer message that arrived during the check stays.
            let gone = inbox.filter { read[$0.id] == $0.ts && readSyncHold[$0.id] == nil }
            guard !gone.isEmpty else { return }
            let ids = Set(gone.map(\.id))
            inbox.removeAll { ids.contains($0.id) }
            if let sel = selectedInboxID, ids.contains(sel) { selectedInboxID = inbox.first?.id }
            ids.forEach { onCleared?($0, true) }
            persistSoon()
        }
    }
}
