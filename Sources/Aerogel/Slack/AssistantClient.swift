import Foundation

/// A Slack draft (or other action) Assistant queued during a reply. Nothing reaches anyone until it's approved.
struct AssistantApproval: Identifiable, Hashable {
    let id: String
    let kind: String
    var status: String
    var text: String
    var to: String?
    var error: String?

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let kind = d["kind"] as? String else { return nil }
        let p = d["payload"] as? [String: Any] ?? [:]
        self.id = id
        self.kind = kind
        status = d["status"] as? String ?? "pending"
        text = p["text"] as? String ?? p["body"] as? String ?? p["subject"] as? String ?? ""
        to = p["to"] as? String ?? p["channel"] as? String
        error = d["error"] as? String
    }
}

/// Talks to an assistant server (see "Assistant API" in the README): streams `/ask/stream` and decides approvals.
struct AssistantClient {
    enum Event { case text(String), tool(String) }

    struct Answer {
        var conversationId: String?
        var text: String
        var approvals: [AssistantApproval]
    }

    let baseURL: URL
    let token: String

    /// The Mac Assistant app keeps its hosted address and token here (written by its installer).
    /// The token is a bearer secret: send it over HTTPS, or plain HTTP only to this Mac.
    static func isSafe(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return url.host != nil
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }

    private func request(_ path: String, json: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    /// Checks the address and the token (`/types` needs auth; `/health` doesn't).
    func check() async throws {
        let (data, resp) = try await URLSession.shared.data(for: request("types"))
        try Self.ensureOK(resp, data)
    }

    func ask(text: String, conversationId: String?, screen: String, slack: [String: Any],
             onEvent: @escaping @MainActor (Event) -> Void) async throws -> Answer {
        var body: [String: Any] = ["text": text, "screen": screen, "slack": slack]
        if let conversationId { body["conversationId"] = conversationId }
        var req = request("ask/stream", json: body)
        req.timeoutInterval = 600
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await b in bytes { data.append(b) }
            try Self.ensureOK(resp, data)
        }
        var event = ""
        for try await line in bytes.lines {
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:"),
                  let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch event {
            case "text":
                if let t = obj["text"] as? String { await onEvent(.text(t)) }
            case "tool":
                if let n = obj["name"] as? String { await onEvent(.tool(n)) }
            case "done":
                let approvals = (obj["approvals"] as? [[String: Any]] ?? []).compactMap(AssistantApproval.init)
                return Answer(conversationId: obj["conversationId"] as? String, text: obj["text"] as? String ?? "",
                              approvals: approvals)
            case "error":
                throw SlackError(code: obj["error"] as? String ?? "\(Prefs.assistantName) error")
            default:
                break
            }
        }
        throw SlackError(code: "\(Prefs.assistantName) closed the stream before finishing")
    }

    /// Approves (optionally with edited text) or discards a queued action. Returns its new status.
    func decide(_ id: String, approve: Bool, text: String?) async throws -> (status: String, error: String?) {
        var body: [String: Any] = ["approve": approve]
        if let text { body["edits"] = ["text": text] }
        let (data, resp) = try await URLSession.shared.data(for: request("approvals/\(id)/decide", json: body))
        try Self.ensureOK(resp, data)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (obj["status"] as? String ?? (approve ? "sent" : "rejected"), obj["error"] as? String)
    }

    private static func ensureOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw SlackError(code: http.statusCode == 401 ? "\(Prefs.assistantName) rejected the token" : (msg ?? "\(Prefs.assistantName) HTTP \(http.statusCode)"))
        }
    }
}
