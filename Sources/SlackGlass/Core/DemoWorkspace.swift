import Foundation

/// A fake workspace so the HUD can be tried (and screenshotted) without Slack tokens.
final class DemoWorkspace {
    let meID = "UME"
    let users: [String: SlackUser]
    let conversations: [String: SlackConversation]
    private var store: [String: [SlackMessage]] = [:]
    private(set) var initialInbox: [InboxItem] = []

    private static func ago(_ minutes: Double) -> String {
        String(format: "%.6f", Date().timeIntervalSince1970 - minutes * 60)
    }

    private static func user(_ id: String, _ name: String, _ img: Int) -> SlackUser {
        SlackUser(id: id, name: name.lowercased().replacingOccurrences(of: " ", with: ""), real_name: name,
                  profile: .init(display_name: name, real_name: name,
                                 image_72: "https://i.pravatar.cc/144?img=\(img)"))
    }

    init() {
        let list = [
            Self.user("UME", "You", 68),
            Self.user("UMAYA", "Maya Chen", 47),
            Self.user("UDEV", "Dev Patel", 12),
            Self.user("USAM", "Sam Rivera", 33),
            Self.user("UALEX", "Alex Kim", 15),
            Self.user("UPRIYA", "Priya Shah", 45),
        ]
        users = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        let convs = [
            SlackConversation(id: "CENG", name: "eng-launch", is_channel: true),
            SlackConversation(id: "CDESIGN", name: "design", is_channel: true),
            SlackConversation(id: "CRANDOM", name: "random", is_channel: true),
            SlackConversation(id: "DALEX", is_im: true, user: "UALEX"),
            SlackConversation(id: "DPRIYA", is_im: true, user: "UPRIYA"),
            SlackConversation(id: "DDEV", is_im: true, user: "UDEV"),
        ]
        conversations = Dictionary(uniqueKeysWithValues: convs.map { ($0.id, $0) })

        let parent = Self.ago(29)
        let r1 = Self.ago(21), r2 = Self.ago(3)
        store[key(.init(channel: "CENG", threadTs: parent))] = [
            SlackMessage(ts: parent, user: "UMAYA",
                         text: "Rollout to *25%* is live :rocket: Error rate on `/checkout` ticked up to 0.4% — anyone seeing this locally?",
                         thread_ts: parent, reply_count: 2,
                         reactions: [.init(name: "eyes", users: ["UDEV", "USAM", "UPRIYA"], count: 3),
                                     .init(name: "rotating_light", users: ["USAM"], count: 1)]),
            SlackMessage(ts: r1, user: "UDEV",
                         text: "Looks like the retry path in <https://github.com/acme/web/pull/812|PR #812>. Rolling back the flag now.",
                         thread_ts: parent),
            SlackMessage(ts: r2, user: "USAM",
                         text: "<@UME> can you confirm the hotfix is in the 2.14 build before we re-enable?",
                         thread_ts: parent),
        ]
        store[key(.init(channel: "CENG", threadTs: nil))] = [
            SlackMessage(ts: Self.ago(90), user: "UPRIYA", text: "Standup notes are in the doc :memo:"),
            SlackMessage(ts: parent, user: "UMAYA",
                         text: "Rollout to *25%* is live :rocket: Error rate on `/checkout` ticked up to 0.4% — anyone seeing this locally?",
                         thread_ts: parent, reply_count: 2, reply_users: ["UDEV", "USAM"]),
        ]

        let a1 = Self.ago(9), a2 = Self.ago(8)
        store[key(.init(channel: "DALEX", threadTs: nil))] = [
            SlackMessage(ts: Self.ago(60 * 20), user: "UME", text: "thanks for covering yesterday :pray:"),
            SlackMessage(ts: a1, user: "UALEX", text: "lunch at 12:30? new ramen place on Valencia"),
            SlackMessage(ts: a2, user: "UALEX", text: "they have a _spicy miso_ that's supposed to be unreal :fire:"),
        ]

        let d1 = Self.ago(22)
        store[key(.init(channel: "CDESIGN", threadTs: d1))] = [
            SlackMessage(ts: d1, user: "UMAYA",
                         text: "<@UME> thoughts on the v3 onboarding flow? Mostly worried about step 3:\n&gt; Connect your workspace before you see any value\nFeels backwards.",
                         thread_ts: d1),
        ]

        let p1 = Self.ago(41)
        store[key(.init(channel: "DPRIYA", threadTs: nil))] = [
            SlackMessage(ts: Self.ago(50), user: "UME", text: "left a couple of nits on the PR, otherwise :shipit:"),
            SlackMessage(ts: p1, user: "UPRIYA", text: "Merged! Thanks for the review :raised_hands:"),
        ]

        initialInbox = [
            InboxItem(channel: "CENG", threadTs: parent, ts: r2, user: "USAM",
                      text: "<@UME> can you confirm the hotfix is in the 2.14 build before we re-enable?", reason: .mention, count: 2),
            InboxItem(channel: "DALEX", threadTs: nil, ts: a2, user: "UALEX",
                      text: "they have a _spicy miso_ that's supposed to be unreal :fire:", reason: .dm, count: 2),
            InboxItem(channel: "CDESIGN", threadTs: d1, ts: d1, user: "UMAYA",
                      text: "<@UME> thoughts on the v3 onboarding flow? Mostly worried about step 3", reason: .mention),
            InboxItem(channel: "DPRIYA", threadTs: nil, ts: p1, user: "UPRIYA",
                      text: "Merged! Thanks for the review :raised_hands:", reason: .dm, seen: true),
        ]
    }

    private func key(_ r: ConversationRef) -> String { "\(r.channel)|\(r.threadTs ?? "")" }

    /// Plain word search over the fake workspace, newest first (modifiers like from: are ignored).
    func search(_ q: String) -> [SearchHit] {
        let words = q.lowercased().split(separator: " ").filter { !$0.contains(":") }
        guard !words.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for (k, msgs) in store {
            let parts = k.split(separator: "|", omittingEmptySubsequences: false)
            let channel = String(parts[0]), thread = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
            for m in msgs where words.allSatisfy({ (m.text ?? "").lowercased().contains($0) }) {
                if thread != nil, m.ts == thread { continue } // the parent is also in the channel's list
                hits.append(SearchHit(channel: channel, message: m, threadTs: thread))
            }
        }
        return hits.sorted { $0.date > $1.date }
    }

    func messages(_ ref: ConversationRef) -> [SlackMessage] {
        if let m = store[key(ref)] { return m }
        if let t = ref.threadTs,
           let parent = store[key(.init(channel: ref.channel, threadTs: nil))]?.first(where: { $0.ts == t }) {
            return [parent]
        }
        return []
    }

    func post(ref: ConversationRef, user: String, text: String, files: [URL]) -> SlackMessage {
        let ts = SlackTS.now()
        let f = files.map { SlackFile(id: UUID().uuidString, name: $0.lastPathComponent, title: $0.lastPathComponent) }
        let m = SlackMessage(ts: ts, user: user, text: text, thread_ts: ref.threadTs, files: f.isEmpty ? nil : f)
        store[key(ref), default: messages(ref)].append(m)
        return m
    }

    func incomingDemoEvent() -> [String: Any] {
        let ts = SlackTS.now()
        let m = SlackMessage(ts: ts, user: "UDEV", text: "quick one — can you approve the 2.14 release? :pray:")
        store[key(.init(channel: "DDEV", threadTs: nil)), default: []].append(m)
        return ["type": "message", "channel": "DDEV", "channel_type": "im", "user": "UDEV", "ts": ts,
                "text": m.text ?? ""]
    }
}
