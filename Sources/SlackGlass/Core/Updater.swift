import AppKit
import Foundation

/// Checks GitHub for a newer release and installs it in place. Sign-in lives in
/// Application Support, so replacing the app never asks anyone to sign in again.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable { case idle, available(String), installing, failed(String) }
    @Published private(set) var state: State = .idle
    /// Release notes for the version that's ready to install (shown as the Update button's tooltip).
    @Published private(set) var availableNotes = ""
    /// Set once after an update: what changed in the version now running.
    @Published var whatsNew: (version: String, notes: String)?

    var isAvailable: Bool { if case .available = state { return true } else { return false } }

    private static let latestURL = URL(string: "https://api.github.com/repos/joyrider00/slack-glass/releases/latest")!
    private var zipURL: URL?
    private var lastCheck = Date.distantPast
    private var timer: Timer?

    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    func start(existingUser: Bool) {
        guard let current = Self.currentVersion else { return }   // `swift run` builds have no version
        let last = UserDefaults.standard.string(forKey: "lastRunVersion")
        UserDefaults.standard.set(current, forKey: "lastRunVersion")
        if last != current, existingUser { showWhatsNew(current) }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in Updater.shared.check() }
        }
    }

    /// Cheap enough to call whenever the HUD opens; throttled to once every 10 minutes.
    func checkSoon() {
        if Date().timeIntervalSince(lastCheck) > 600 { check() }
    }

    func check() {
        guard let current = Self.currentVersion, state != .installing else { return }
        lastCheck = Date()
        Task {
            var req = URLRequest(url: Self.latestURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })?["browser_download_url"] as? String
            else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Self.isNewer(latest, than: current) {
                zipURL = URL(string: zip)
                availableNotes = Self.notes(from: json["body"] as? String)
                if state != .installing { state = .available(latest) }
            } else if isAvailable {
                state = .idle
            }
        }
    }

    /// What changed in the version now running, from its GitHub release notes.
    private func showWhatsNew(_ version: String) {
        Task {
            let url = URL(string: "https://api.github.com/repos/joyrider00/slack-glass/releases/tags/v\(version)")!
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let notes = Self.notes(from: json["body"] as? String)
            if !notes.isEmpty { whatsNew = (version, notes) }
        }
    }

    /// Release notes are the text above a "---" line; below it is the install command for people browsing GitHub.
    static func notes(from body: String?) -> String {
        guard let body else { return "" }
        let top = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n---").first ?? ""
        return top.contains("curl ") ? "" : top.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Downloads the new build, swaps it in once this process exits, and reopens it.
    func install() {
        guard let zipURL, state != .installing else { return }
        state = .installing
        Task {
            do {
                let (tmpZip, resp) = try await URLSession.shared.download(from: zipURL)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed") }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slackglass-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let zip = dir.appendingPathComponent("app.zip")
                try FileManager.default.moveItem(at: tmpZip, to: zip)
                try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
                let newApp = dir.appendingPathComponent("Slack Glass.app")
                guard FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/SlackGlass").path)
                else { throw UpdateError("The download didn't contain the app") }

                let target = Bundle.main.bundlePath
                guard target.hasSuffix(".app"),
                      FileManager.default.isWritableFile(atPath: (target as NSString).deletingLastPathComponent)
                else { throw UpdateError("Can't write to \((target as NSString).deletingLastPathComponent)") }

                // A detached shell waits for us to quit, swaps the bundle and relaunches it.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", Self.swapScript, "sh", String(ProcessInfo.processInfo.processIdentifier),
                               target, newApp.path, dir.path]
                try p.run()
                NSApp.terminate(nil)
            } catch {
                state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// $1 pid to wait for, $2 installed app, $3 new app, $4 temp folder to remove.
    /// The new copy lands beside the old one first, then two renames swap them, so a failure
    /// at any step leaves a working app in place. Whatever happens, the app reopens.
    static let swapScript = """
    for _ in $(seq 150); do kill -0 "$1" 2>/dev/null || break; sleep 0.2; done
    rm -rf "$2.new" "$2.old"
    if /usr/bin/ditto "$3" "$2.new" && [ -x "$2.new/Contents/MacOS/SlackGlass" ]; then
      if mv "$2" "$2.old"; then
        if mv "$2.new" "$2"; then rm -rf "$2.old"; else mv "$2.old" "$2"; fi
      fi
    fi
    rm -rf "$2.new" "$4"
    /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
    /usr/bin/open "$2"
    """

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.terminationHandler = { p in
                p.terminationStatus == 0 ? c.resume() : c.resume(throwing: UpdateError("Couldn't unpack the update"))
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }
}

struct UpdateError: Error {
    let message: String
    init(_ m: String) { message = m }
}
