import AppKit
import Foundation

/// Socket Mode client: a WebSocket to Slack that delivers Events API payloads
/// without needing a public HTTP endpoint. All callbacks fire on the main thread.
final class SocketModeClient {
    enum Status: Equatable { case connecting, connected, disconnected(String) }

    var onEvent: (([String: Any]) -> Void)?
    var onStatus: ((Status) -> Void)?

    private var appToken: String
    /// Set when the app-level token rotates (xoxe.xapp-…).
    var refreshAppToken: (() async throws -> String)?
    private var refreshedThisAttempt = false
    private let api: SlackAPI
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var backoff: Double = 1
    private var pingTimer: Timer?
    private var seenEventIDs: [String] = []
    private var wakeObserver: NSObjectProtocol?

    init(appToken: String, api: SlackAPI) {
        self.appToken = appToken
        self.api = api
    }

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

    private func connect() {
        guard running else { return }
        onStatus?(.connecting)
        Task { @MainActor in
            do {
                let json = try await api.call("apps.connections.open", [:], token: appToken)
                guard let s = json["url"] as? String, let url = URL(string: s) else {
                    throw SlackError(code: "no_socket_url")
                }
                self.refreshedThisAttempt = false
                let t = URLSession.shared.webSocketTask(with: url)
                self.task = t
                t.resume()
                self.receive(t)
            } catch let e as SlackError where SlackAPI.authErrors.contains(e.code)
                        && self.refreshAppToken != nil && !self.refreshedThisAttempt {
                // Rotating app-level token expired: swap it and retry right away.
                self.refreshedThisAttempt = true
                do {
                    self.appToken = try await self.refreshAppToken!()
                    self.connect()
                } catch {
                    self.scheduleReconnect(error.localizedDescription)
                }
            } catch {
                self.scheduleReconnect(error.localizedDescription)
            }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, t === self.task else { return }
                switch result {
                case .failure(let e):
                    self.scheduleReconnect(e.localizedDescription)
                case .success(let msg):
                    var data: Data?
                    switch msg {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let d = data, let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                        self.handle(obj, t)
                    }
                    self.receive(t)
                }
            }
        }
    }

    private func handle(_ env: [String: Any], _ t: URLSessionWebSocketTask) {
        if let id = env["envelope_id"] as? String {
            t.send(.string("{\"envelope_id\":\"\(id)\"}")) { _ in }
        }
        switch env["type"] as? String {
        case "hello":
            backoff = 1
            onStatus?(.connected)
        case "disconnect":
            // Slack rotates connections periodically; just open a fresh one.
            reconnectNow()
        case "events_api":
            guard let payload = env["payload"] as? [String: Any],
                  let event = payload["event"] as? [String: Any] else { return }
            if let eid = payload["event_id"] as? String {
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
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connect()
    }

    private func scheduleReconnect(_ reason: String) {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard running else { return }
        onStatus?(.disconnected(reason))
        let delay = backoff
        backoff = min(backoff * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }
}
