import Foundation

/// One row in the @mention popup.
struct MentionSuggestion: Identifiable, Hashable {
    let id: String          // user ID, or "here" / "channel" / "everyone"
    let title: String       // what's shown
    let detail: String      // handle or explanation
    let insert: String      // what goes into the text, without the "@"
    var userID: String?
}

private let mentionRegex = try! NSRegularExpression(pattern: #"(?:^|[\s(])@([\p{L}\p{N}._\-]*(?: [\p{L}\p{N}._\-]+)?)$"#)

extension AppModel {
    /// The "@que" being typed just before the caret, if any: its range in `text` (including the "@") and the query.
    static func mentionToken(in text: String, caret: Int) -> (range: NSRange, query: String)? {
        let ns = text as NSString
        guard caret <= ns.length else { return nil }
        let before = ns.substring(to: caret)
        guard let m = mentionRegex.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length))
        else { return nil }
        let q = (before as NSString).substring(with: m.range(at: 1))
        let at = m.range(at: 1).location - 1
        return (NSRange(location: at, length: caret - at), q)
    }

    /// People matching what's typed after "@": the conversation's participants first, then people you've
    /// talked to recently, then everyone else in the workspace.
    func mentionSuggestions(_ query: String, limit: Int = 6) -> [MentionSuggestion] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        func matches(_ u: SlackUser) -> Bool {
            guard !words.isEmpty else { return true }
            let names = [u.displayName, u.real_name ?? "", u.profile?.real_name ?? "", u.name ?? ""]
            let parts = names.flatMap { $0.lowercased().split(whereSeparator: { " ._-".contains($0) }).map(String.init) }
                + names.map { $0.lowercased() }
            return words.allSatisfy { w in parts.contains { $0.hasPrefix(w) } }
        }

        // Who's in this conversation (newest speakers first), and when you last DMed each person.
        var here: [String: Int] = [:]
        for (i, m) in messages.reversed().enumerated() { if let u = m.user, here[u] == nil { here[u] = i } }
        var dmActivity: [String: Double] = [:]
        for c in conversations.values where c.is_im == true {
            if let u = c.user { dmActivity[u] = lastActivity[c.id] ?? c.estimatedActivity ?? 0 }
        }

        let people = users.values
            .filter { $0.deleted != true && $0.is_bot != true && $0.id != meID && $0.id != "USLACKBOT" && matches($0) }
            .sorted { a, b in
                let ha = here[a.id], hb = here[b.id]
                if (ha != nil) != (hb != nil) { return ha != nil }
                if let ha, let hb, ha != hb { return ha < hb }
                let da = dmActivity[a.id] ?? 0, db = dmActivity[b.id] ?? 0
                if da != db { return da > db }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
            .prefix(limit)
            .map { u in
                MentionSuggestion(id: u.id, title: u.displayName,
                                  detail: u.real_name.flatMap { $0 != u.displayName && !$0.isEmpty ? $0 : nil } ?? "@\(u.name ?? "")",
                                  insert: u.displayName, userID: u.id)
            }

        var out = Array(people)
        if let c = current, !isDirect(c.channel) {
            let special = [("here", "Notify everyone online here"), ("channel", "Notify everyone in this channel"),
                           ("everyone", "Notify the whole workspace")]
            for (name, detail) in special where words.isEmpty ? false : name.hasPrefix(words[0]) && words.count == 1 {
                out.append(MentionSuggestion(id: name, title: "@\(name)", detail: detail, insert: name))
            }
        }
        return out
    }

    /// "@Kevin Yan" (as inserted by the popup) → "<@U123>". Longest names first so "@Kevin Yan" beats "@Kevin".
    func encodeDisplayNameMentions(_ text: String) -> String {
        guard text.contains("@") else { return text }
        var out = text
        let named = users.values.filter { $0.deleted != true && out.contains("@" + $0.displayName) }
            .sorted { $0.displayName.count > $1.displayName.count }
        for u in named {
            let pattern = #"(?<![<\w])@"# + NSRegularExpression.escapedPattern(for: u.displayName) + #"(?![\p{L}\p{N}_])"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: "<@\(u.id)>"))
        }
        return out
    }
}
