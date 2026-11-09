import Foundation

/// One message from Slack search.
struct SearchHit: Identifiable, Hashable {
    let channel: String
    let channelName: String?
    let user: String?
    let username: String?
    let ts: String
    let text: String
    let threadTs: String?

    var id: String { "\(channel):\(ts)" }
    var date: Date { Date(timeIntervalSince1970: Double(ts) ?? 0) }

    init?(_ d: [String: Any]) {
        guard let ts = d["ts"] as? String, let ch = d["channel"] as? [String: Any], let cid = ch["id"] as? String
        else { return nil }
        self.ts = ts
        channel = cid
        channelName = ch["name"] as? String
        user = d["user"] as? String
        username = d["username"] as? String
        text = d["text"] as? String ?? ""
        // Replies carry their thread in the permalink (…?thread_ts=…); search doesn't return it otherwise.
        threadTs = (d["permalink"] as? String).flatMap { URLComponents(string: $0) }?
            .queryItems?.first { $0.name == "thread_ts" }?.value
    }

    init(channel: String, message m: SlackMessage, threadTs: String?) {
        self.channel = channel
        channelName = nil
        user = m.user
        username = nil
        ts = m.ts
        text = m.text ?? ""
        self.threadTs = threadTs
    }
}

extension AppModel {
    /// Shortcuts shown under the search box; each toggles a Slack search modifier.
    var searchFilters: [(label: String, token: String)] {
        var f: [(String, String)] = [("From me", "from:me")]
        if let c = current, let conv = conversations[c.channel], conv.is_im != true, conv.is_mpim != true,
           let name = conv.name {
            f.append(("In #\(name)", "in:#\(name)"))
        } else if let c = current, let conv = conversations[c.channel], conv.is_im == true, let u = conv.user,
                  let handle = users[u]?.name {
            f.append(("With \(userName(u))", "in:@\(handle)"))
        }
        f += [("Has file", "has:file"), ("Has link", "has:link"), ("Threads", "is:thread")]
        return f
    }

    func hasSearchToken(_ token: String) -> Bool {
        searchQuery.split(separator: " ").contains { $0 == token }
    }

    func toggleSearchToken(_ token: String) {
        var parts = searchQuery.split(separator: " ").map(String.init)
        if parts.contains(token) { parts.removeAll { $0 == token } } else { parts.append(token) }
        searchQuery = parts.joined(separator: " ") + (parts.isEmpty ? "" : " ")
        searchSoon(delay: 0)
        searchFocusTick += 1
    }

    func clearSearchFields() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
        searchTotal = 0
        searchedQuery = ""
        searchError = nil
        searching = false
        searchIndex = 0
        chatQuery = ""
        chatIndex = 0
        switcherQuery = ""
        switcherIndex = 0
    }

    func openSearch() {
        showSearch = true
        searchFocusTick += 1
    }

    /// Waits for a pause in typing (Slack allows ~20 searches a minute), then searches.
    func searchSoon(delay: Double = 0.45) {
        searchTask?.cancel()
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searchResults = []
            searchTotal = 0
            searchError = nil
            searchedQuery = ""
            searching = false
            return
        }
        searchTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.runSearch(q)
        }
    }

    private func runSearch(_ q: String) async {
        searching = true
        defer { if !Task.isCancelled { searching = false } }
        if let demo {
            let hits = demo.search(q)
            searchedQuery = q
            searchResults = hits
            searchTotal = hits.count
            searchIndex = 0
            searchError = nil
            return
        }
        guard let api else { return }
        do {
            let r = try await api.call("search.messages",
                                       ["query": q, "count": 50, "sort": "timestamp", "sort_dir": "desc", "highlight": false])
            guard !Task.isCancelled else { return }
            let m = r["messages"] as? [String: Any] ?? [:]
            let hits = (m["matches"] as? [[String: Any]] ?? []).compactMap(SearchHit.init)
            hits.compactMap(\.user).forEach { if users[$0] == nil { ensureUser($0) } }
            searchedQuery = q
            searchResults = hits
            searchTotal = m["total"] as? Int ?? hits.count
            searchIndex = 0
            searchError = nil
        } catch let e as SlackError where e.code == "missing_scope" {
            searchError = "missing_scope"
        } catch {
            guard !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
    }

    func moveSearchSelection(_ d: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = max(0, min(searchResults.count - 1, searchIndex + d))
    }

    /// Enter: search now if the box changed since the last search, otherwise open the selected result.
    func searchEnter() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        if q != searchedQuery { searchSoon(delay: 0); return }
        if searchResults.indices.contains(searchIndex) { openHit(searchResults[searchIndex]) }
    }

    /// Opens the thread the message is in, or the conversation around it, scrolled to the message.
    func openHit(_ h: SearchHit) {
        if let i = searchResults.firstIndex(of: h) { searchIndex = i }
        open(ConversationRef(channel: h.channel, threadTs: h.threadTs), focus: h.ts)
    }

    func hitTitle(_ h: SearchHit) -> String {
        if conversations[h.channel] != nil { return title(h.channel) }
        if let n = h.channelName, !n.isEmpty, !n.hasPrefix("U"), !n.hasPrefix("D") { return "#\(n)" }
        return "Direct message"
    }

    func hitAuthor(_ h: SearchHit) -> String {
        if let u = h.user, users[u] != nil { return userName(u) }
        return h.username ?? userName(h.user)
    }
}
