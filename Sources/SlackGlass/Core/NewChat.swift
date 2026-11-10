import Foundation

/// Starting chats from Chats search: Return on a person opens your DM with them right away, and every
/// further name you type and pick turns it into a group DM with everyone picked so far.
extension AppModel {
    /// The person a row stands for: a "New chat" row, or your existing DM with them.
    func personID(_ t: SwitchTarget) -> String? {
        switch t.kind {
        case .user(let u): return u
        case .conversation(let c):
            guard let conv = conversations[c], conv.is_im == true else { return nil }
            return conv.user
        }
    }

    /// Return (or a click) on a Chats row.
    func pickChat(_ t: SwitchTarget) {
        chatQuery = ""
        chatIndex = 0
        if let person = personID(t) {
            if !chatPeople.contains(person) { chatPeople.append(person) }
            openChat(with: chatPeople)
        } else if case .conversation(let c) = t.kind, conversations[c]?.is_mpim == true {
            // An existing group DM: open it, and typing more names adds to it.
            chatPeople = mpimMembers(c)
            open(ConversationRef(channel: c, threadTs: nil), fromPicker: true)
        } else {
            openSwitcherTarget(t)   // a channel: open it and go straight to writing
        }
    }

    /// The × on a picked name, or Backspace in the empty search box.
    func unpickChatPerson(_ u: String? = nil) {
        guard let u = u ?? chatPeople.last else { return }
        chatPeople.removeAll { $0 == u }
        if !chatPeople.isEmpty { openChat(with: chatPeople) }
    }

    /// Group DM members other than you, from its name (mpdm-alice--bob--you-1).
    func mpimMembers(_ channel: String) -> [String] {
        guard let name = conversations[channel]?.name else { return [] }
        let handles = Set(mpimHandles(name))
        return users.values.filter { u in u.name.map(handles.contains) ?? false && u.id != meID }
            .sorted { $0.displayName < $1.displayName }.map(\.id)
    }

    /// Opens the DM or group DM with exactly these people, creating it in Slack if it doesn't exist yet.
    func openChat(with people: [String]) {
        guard !people.isEmpty else { return }
        let wanted = Set(people)
        if let existing = conversations.values.first(where: { c in
            c.is_archived != true && (people.count == 1
                ? c.is_im == true && c.user == people[0]
                : c.is_mpim == true && Set(mpimMembers(c.id)) == wanted)
        }) {
            open(ConversationRef(channel: existing.id, threadTs: nil), fromPicker: true)
            return
        }
        if isDemo {
            let id = (people.count == 1 ? "D" : "G") + people.sorted().joined()
            var conv = SlackConversation(id: id)
            if people.count == 1 {
                conv.is_im = true
                conv.user = people[0]
            } else {
                conv.is_mpim = true
                conv.name = "mpdm-" + (people + [meID]).compactMap { users[$0]?.name }.joined(separator: "--") + "-1"
            }
            conversations[id] = conv
            open(ConversationRef(channel: id, threadTs: nil), fromPicker: true)
            return
        }
        guard let api else { return }
        Task {
            do {
                let r = try await api.call("conversations.open", ["users": people.joined(separator: ","), "return_im": true])
                guard let raw = r["channel"] as? [String: Any], let id = raw["id"] as? String else {
                    throw SlackError(code: "no_channel")
                }
                if conversations[id] == nil {
                    var conv = SlackAPI.decode(SlackConversation.self, raw) ?? SlackConversation(id: id)
                    if people.count > 1, conv.name == nil,
                       let info = try? await api.call("conversations.info", ["channel": id]),
                       let full = SlackAPI.decode(SlackConversation.self, info["channel"]) {
                        conv = full
                    }
                    if people.count == 1 {
                        conv.is_im = true
                        if conv.user == nil { conv.user = people[0] }
                    } else {
                        conv.is_mpim = true
                    }
                    conversations[id] = conv
                }
                // Typed another name while this one was opening: that newer chat wins.
                guard chatPeople == people else { return }
                open(ConversationRef(channel: id, threadTs: nil), fromPicker: true)
            } catch {
                lastError = "Couldn't start that chat: \((error as? SlackError)?.code ?? error.localizedDescription)"
            }
        }
    }
}
