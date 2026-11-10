import AppKit
import Foundation

/// Checks GitHub for a newer release and installs it in place. Sign-in lives in
/// Application Support, so replacing the app never asks anyone to sign in again.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable { case idle, available(String), installing, failed(String) }
    @Published private(set) var state: State = .idle

    var isAvailable: Bool { if case .available = state { return true } else { return false } }

    private static let latestURL = URL(string: "https://api.github.com/repos/joyrider00/slack-glass/releases/latest")!
    private var zipURL: URL?
    private var lastCheck = Date.distantPast
    private var timer: Timer?

    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    func start() {
        guard Self.currentVersion != nil else { return }   // `swift run` builds have no version
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
                if state != .installing { state = .available(latest) }
            } else if isAvailable {
                state = .idle
            }
        }
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
                let script = """
                while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
                rm -rf "$2.old" && mv "$2" "$2.old" && /usr/bin/ditto "$3" "$2" && rm -rf "$2.old" || { rm -rf "$2"; mv "$2.old" "$2"; }
                /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
                rm -rf "$4"
                /usr/bin/open "$2"
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                               target, newApp.path, dir.path]
                try p.run()
                NSApp.terminate(nil)
            } catch {
                state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
            }
        }
    }

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
