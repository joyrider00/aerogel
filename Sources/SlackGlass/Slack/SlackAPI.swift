import Foundation

struct SlackError: LocalizedError {
    let code: String
    var errorDescription: String? { "Slack: \(code)" }
}

/// Thin Web API client. Every call is a form-encoded POST with a bearer token,
/// with automatic retry on HTTP 429.
final class SlackAPI {
    var userToken: String
    /// Set when the user token rotates; called once when Slack says the token expired.
    var refreshUserToken: (() async throws -> String)?
    private let session: URLSession
    private let refreshLock = NSLock()
    private var refreshTask: Task<String, Error>?

    static let authErrors: Set<String> = ["token_expired", "invalid_auth", "not_authed"]

    init(userToken: String) {
        self.userToken = userToken
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], token: String? = nil) async throws -> [String: Any] {
        do {
            return try await perform(method, params, bearer: token ?? userToken)
        } catch let e as SlackError where token == nil && Self.authErrors.contains(e.code) && refreshUserToken != nil {
            userToken = try await sharedRefresh()
            return try await perform(method, params, bearer: userToken)
        }
    }

    /// Refresh tokens are single-use, so concurrent failures must share one refresh.
    private func sharedRefresh() async throws -> String {
        let task = currentRefreshTask()
        defer { clearRefreshTask() }
        return try await task.value
    }

    private func currentRefreshTask() -> Task<String, Error> {
        refreshLock.lock(); defer { refreshLock.unlock() }
        if let t = refreshTask { return t }
        let refresher = refreshUserToken!
        let t = Task { try await refresher() }
        refreshTask = t
        return t
    }

    private func clearRefreshTask() {
        refreshLock.lock(); defer { refreshLock.unlock() }
        refreshTask = nil
    }

    private func perform(_ method: String, _ params: [String: Any], bearer: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        req.httpMethod = "POST"
        if !bearer.isEmpty { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(params).data(using: .utf8)

        for attempt in 0..<4 {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 429 {
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(attempt + 1) * 2
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SlackError(code: "bad_response")
            }
            if json["ok"] as? Bool == true { return json }
            throw SlackError(code: json["error"] as? String ?? "unknown_error")
        }
        throw SlackError(code: "rate_limited")
    }

    /// Follows `response_metadata.next_cursor` and concatenates `key` arrays.
    func paginate(_ method: String, _ params: [String: Any], key: String, maxPages: Int = 40) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var cursor = ""
        for _ in 0..<maxPages {
            var p = params
            if !cursor.isEmpty { p["cursor"] = cursor }
            let json = try await call(method, p)
            out += json[key] as? [[String: Any]] ?? []
            cursor = (json["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
            if cursor.isEmpty { break }
        }
        return out
    }

    /// Slack's v2 upload flow: get an upload URL per file, PUT the bytes, then complete in one call.
    func uploadFiles(_ urls: [URL], channel: String, threadTs: String?, comment: String?) async throws {
        var ids: [[String: String]] = []
        for url in urls {
            let data = try Data(contentsOf: url)
            let r = try await call("files.getUploadURLExternal", ["filename": url.lastPathComponent, "length": data.count])
            guard let up = r["upload_url"] as? String, let uploadURL = URL(string: up), let fid = r["file_id"] as? String else {
                throw SlackError(code: "upload_url_missing")
            }
            var req = URLRequest(url: uploadURL)
            req.httpMethod = "POST"
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            let (_, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SlackError(code: "upload_failed") }
            ids.append(["id": fid, "title": url.lastPathComponent])
        }
        var p: [String: Any] = ["files": ids, "channel_id": channel]
        if let t = threadTs { p["thread_ts"] = t }
        if let c = comment, !c.isEmpty { p["initial_comment"] = c }
        try await call("files.completeUploadExternal", p)
    }

    // MARK: - Encoding helpers

    static func formEncode(_ params: [String: Any]) -> String {
        params.compactMap { key, value -> String? in
            let s: String
            switch value {
            case let v as String: s = v
            case let v as Bool: s = v ? "true" : "false"
            case let v as Int: s = String(v)
            case let v as Double: s = String(v)
            default:
                guard JSONSerialization.isValidJSONObject(value),
                      let d = try? JSONSerialization.data(withJSONObject: value),
                      let str = String(data: d, encoding: .utf8) else { return nil }
                s = str
            }
            return "\(escape(key))=\(escape(s))"
        }.joined(separator: "&")
    }

    private static let allowed: CharacterSet = {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: "-._~")
        return c
    }()

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func decode<T: Decodable>(_ type: T.Type, _ obj: Any?) -> T? {
        guard let obj, JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Decodes each element independently so one odd message doesn't drop the whole list.
    static func decodeList<T: Decodable>(_ type: T.Type, _ obj: Any?) -> [T] {
        (obj as? [[String: Any]] ?? []).compactMap { decode(T.self, $0) }
    }
}
