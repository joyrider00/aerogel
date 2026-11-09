import AppKit
import Foundation

/// Where incoming Slack events come from: Slack's Socket Mode (your own Slack app) or the team relay.
protocol EventStream: AnyObject {
    func stop()
}

extension SocketModeClient: EventStream {}

/// The team relay (relay/ in this repo): "Sign in with Slack" once per Mac, and every Mac you're signed in on
/// gets every event. Sending, history and search still go straight to Slack with your own token.
enum Relay {
    static var server: URL? {
        guard let s = Prefs.relayURL, let u = URL(string: s), u.scheme == "https" || u.host == "localhost" else { return nil }
        return u
    }
    static var session: String? { Secrets.get(TokenKey.relaySession).flatMap { $0.isEmpty ? nil : $0 } }
    static var isSignedIn: Bool { server != nil && session != nil }

    static var signInURL: URL? { server?.appendingPathComponent("auth/start") }

    struct Me { let token: String; let userID: String }

    /// Your Slack token, held by the relay so every Mac you sign in on can use it.
    static func me() async throws -> Me {
        let r = try await request("v1/me")
        guard let token = r["token"] as? String, let user = r["user_id"] as? String else {
            throw SlackError(code: "the team server didn't return a token")
        }
        return Me(token: token, userID: user)
    }

    static func signOut() async {
        _ = try? await request("v1/signout", method: "POST")
    }

    /// Handles slackglass://signed-in?session=…&server=… from the browser after Slack approval.
    static func completeSignIn(_ url: URL) -> Bool {
        guard url.scheme == "slackglass", url.host == "signed-in",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let session = q.first(where: { $0.name == "session" })?.value, !session.isEmpty else { return false }
        if let server = q.first(where: { $0.name == "server" })?.value, URL(string: server)?.scheme == "https" {
            UserDefaults.standard.set(server, forKey: PrefKey.relayURL)
        }
        Secrets.set(TokenKey.relaySession, session)
        return true
    }

    struct SignedOut: LocalizedError { var errorDescription: String? { "Signed out. Sign in with Slack again." } }

    private static func request(_ path: String, method: String = "GET") async throws -> [String: Any] {
        guard let server, let session else { throw SignedOut() }
        var r = URLRequest(url: server.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: r)
        if (resp as? HTTPURLResponse)?.statusCode == 401 { throw SignedOut() }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// Live connection to the relay. Same shape as SocketModeClient; callbacks fire on the main thread.
/// Remembers the last event it saw so a reconnect (after sleep or a network change) replays what it missed.
final class RelayClient: EventStream {
    var onEvent: (([String: Any]) -> Void)?
    /// Read/snooze marks from your other Macs (and, on every connect, the ones you missed).
    var onMarks: (([[String: Any]]) -> Void)?
    var onStatus: ((SocketModeClient.Status) -> Void)?
    var onSignedOut: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private var running = false
    private var backoff: Double = 1
    private var pingTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastSeq = 0
    private var seenEventIDs: [String] = []
    private var connected = false
    /// Marks made while offline; sent once the relay says hello.
    private var outbox: [[String: Any]] = []

    func start() {
        guard !running else { return }
        running = true
        connect()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.ping() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reconnectNow() }
    }

    func stop() {
        running = false
        pingTimer?.invalidate()
        pingTimer = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Tells your other Macs you handled an Activity item. Queued while disconnected.
    func sendMark(_ mark: [String: Any]) {
        outbox.append(mark)
        if outbox.count > 200 { outbox.removeFirst(outbox.count - 200) }
        flush()
    }

    private func flush() {
        guard connected, let t = task else { return }
        let pending = outbox
        outbox.removeAll()
        for m in pending {
            guard let d = try? JSONSerialization.data(withJSONObject: ["type": "mark", "mark": m]),
                  let s = String(data: d, encoding: .utf8) else { continue }
            t.send(.string(s)) { [weak self] error in
                guard error != nil else { return }
                DispatchQueue.main.async { self?.outbox.insert(m, at: 0) } // resent after reconnecting
            }
        }
    }

    private func connect() {
        guard running else { return }
        connected = false
        guard let server = Relay.server, let session = Relay.session,
              var c = URLComponents(url: server.appendingPathComponent("v1/ws"), resolvingAgainstBaseURL: false) else {
            onSignedOut?()
            return
        }
        onStatus?(.connecting)
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.queryItems = [URLQueryItem(name: "after", value: String(lastSeq))]
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
        let t = URLSession.shared.webSocketTask(with: r)
        task = t
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, t === self.task else { return }
                switch result {
                case .failure(let e):
                    // 4401 = this Mac was signed out (here, on another device, or Slack access revoked).
                    if t.closeCode.rawValue == 4401 || (t.response as? HTTPURLResponse)?.statusCode == 401 {
                        self.stop()
                        self.onSignedOut?()
                    } else {
                        self.scheduleReconnect(e.localizedDescription)
                    }
                case .success(let msg):
                    var data: Data?
                    switch msg {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let d = data, let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                        self.handle(obj)
                    }
                    self.receive(t)
                }
            }
        }
    }

    private func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "hello":
            backoff = 1
            // The relay's counter restarted (e.g. everyone signed out): start counting from its value.
            if let seq = msg["seq"] as? Int, seq < lastSeq { lastSeq = seq }
            connected = true
            onStatus?(.connected)
            flush()
        case "marks":
            if let marks = msg["marks"] as? [[String: Any]], !marks.isEmpty { onMarks?(marks) }
        case "event":
            if let seq = msg["seq"] as? Int { lastSeq = max(lastSeq, seq) }
            guard let event = msg["event"] as? [String: Any] else { return }
            if let eid = msg["event_id"] as? String {
                if seenEventIDs.contains(eid) { return }
                seenEventIDs.append(eid)
                if seenEventIDs.count > 300 { seenEventIDs.removeFirst(100) }
            }
            onEvent?(event)
        default:
            break
        }
    }

    private func ping() {
        guard let t = task else { return }
        t.sendPing { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self, t === self.task else { return }
                self.scheduleReconnect("ping failed")
            }
        }
    }

    private func reconnectNow() {
        guard running else { return }
        connected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connect()
    }

    private func scheduleReconnect(_ reason: String) {
        connected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard running else { return }
        onStatus?(.disconnected(reason))
        let delay = backoff
        backoff = min(backoff * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }
}
