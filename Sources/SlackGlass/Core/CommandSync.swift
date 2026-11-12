import CryptoKit
import Foundation

/// Keeps the Commands folder the same on every Mac you're signed in on, through the team server.
/// Adding a file on one Mac adds it everywhere; deleting one deletes it everywhere; a changed file wins.
enum CommandSync {
    /// What each file looked like after the last sync (file name → SHA-256), to tell "added here" from
    /// "deleted elsewhere" and "changed here" from "changed elsewhere".
    private static let knownKey = "commandSyncKnown"
    private static var running = false
    private static var lastRun = Date.distantPast

    /// Cheap to call often: at most once a minute, and only with a team server sign-in.
    @MainActor
    static func syncSoon() {
        guard Relay.isSignedIn, !running, Date().timeIntervalSince(lastRun) > 60 else { return }
        running = true
        lastRun = Date()
        Task.detached(priority: .utility) {
            await sync()
            await MainActor.run { running = false }
        }
    }

    private struct Remote { let hash: String }

    static func sync() async {
        guard let server = Relay.server, let session = Relay.session else { return }
        let base = server.appendingPathComponent("v1/commands")
        func request(_ file: String?, method: String = "GET", body: Data? = nil, hash: String? = nil) async -> (Data, Int)? {
            var url = base
            if let file { url = base.appendingPathComponent(file) }
            var r = URLRequest(url: url)
            r.httpMethod = method
            r.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
            if let hash { r.setValue(hash, forHTTPHeaderField: "x-hash") }
            r.httpBody = body
            r.timeoutInterval = 60
            guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return nil }
            return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let (listData, status) = await request(nil), status == 200,
              let list = try? JSONSerialization.jsonObject(with: listData) as? [String: Any] else { return }
        var remote: [String: Remote] = [:]
        for f in list["files"] as? [[String: Any]] ?? [] {
            if let name = f["file"] as? String, let h = f["hash"] as? String { remote[name] = Remote(hash: h) }
        }
        let deletedRemotely = Set((list["deleted"] as? [[String: Any]] ?? []).compactMap { $0["file"] as? String })

        let folder = SlashCommands.folder
        var local: [String: (url: URL, hash: String)] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? [] {
            guard let d = try? Data(contentsOf: url), !d.isEmpty, d.count <= 15 * 1024 * 1024 else { continue }
            local[url.lastPathComponent] = (url, hash(d))
        }
        var known = UserDefaults.standard.dictionary(forKey: knownKey) as? [String: String] ?? [:]

        for (name, l) in local {
            if let r = remote[name] {
                if r.hash == l.hash { known[name] = l.hash; continue }
                if known[name] == l.hash {
                    // Unchanged here, changed on another Mac: take theirs.
                    if let (d, s) = await request(name), s == 200, hash(d) == r.hash {
                        try? d.write(to: l.url, options: .atomic)
                        known[name] = r.hash
                    }
                } else if let (_, s) = await request(name, method: "PUT", body: try? Data(contentsOf: l.url), hash: l.hash), s == 200 {
                    known[name] = l.hash   // changed here: ours wins
                }
            } else if deletedRemotely.contains(name), known[name] != nil {
                try? FileManager.default.removeItem(at: l.url)   // deleted on another Mac
                known[name] = nil
            } else if let (_, s) = await request(name, method: "PUT", body: try? Data(contentsOf: l.url), hash: l.hash), s == 200 {
                known[name] = l.hash   // new here
            }
        }
        for (name, r) in remote where local[name] == nil {
            if known[name] != nil {
                // Synced before and gone from this folder now: deleted here.
                if let (_, s) = await request(name, method: "DELETE"), s == 200 { known[name] = nil }
            } else if let (d, s) = await request(name), s == 200, hash(d) == r.hash {
                try? d.write(to: folder.appendingPathComponent(name), options: .atomic)   // new on another Mac
                known[name] = r.hash
            }
        }
        UserDefaults.standard.set(known, forKey: knownKey)
    }

    private static func hash(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}
