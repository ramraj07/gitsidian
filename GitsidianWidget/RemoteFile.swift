import Foundation

/// Fetches the widget file straight from GitHub so the widget updates when someone
/// (or an agent) commits to it, even if the app hasn't been opened. Also commits
/// checkbox taps (contents API PUT), so the widget doesn't need the app to write back.
enum RemoteFile {
    struct Contents: Decodable { let sha: String; let content: String?; let encoding: String? }
    private struct PutResponse: Decodable {
        struct Content: Decodable { let sha: String }
        let content: Content
    }

    enum Outcome { case found(sha: String, text: String), missing }

    struct HTTPError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { "GitHub \(status): \(message)" }
        /// The file moved on between our read and our write: read again and retry.
        var isConflict: Bool { status == 409 || status == 422 }
    }

    static func fetch(_ r: WidgetRecord, token: String) async throws -> Outcome {
        try await fetch(owner: r.owner, repo: r.repo, branch: r.branch, path: r.path, token: token)
    }

    static func fetch(owner: String, repo: String, branch: String, path: String, token: String) async throws -> Outcome {
        var c = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/\(encode(path))")!
        c.queryItems = [URLQueryItem(name: "ref", value: branch)]
        let (data, status) = try await send(URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12), token: token)
        if status == 404 { return .missing }
        guard (200..<300).contains(status) else { throw HTTPError(status: status, message: message(data)) }
        let body = try JSONDecoder().decode(Contents.self, from: data)
        guard body.encoding == "base64", let b64 = body.content,
              let bytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
            throw URLError(.cannotDecodeContentData)
        }
        return .found(sha: body.sha, text: String(decoding: bytes, as: UTF8.self))
    }

    /// Commits `text` over the blob `sha` on `branch`. Returns the new blob sha.
    static func put(owner: String, repo: String, branch: String, path: String, text: String, sha: String,
                    message commitMessage: String, token: String) async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/\(encode(path))")!
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "message": commitMessage,
            "content": Data(text.utf8).base64EncodedString(),
            "sha": sha,
            "branch": branch,
        ])
        let (data, status) = try await send(req, token: token)
        guard (200..<300).contains(status) else { throw HTTPError(status: status, message: message(data)) }
        return try JSONDecoder().decode(PutResponse.self, from: data).content.sha
    }

    private static func encode(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    private static func send(_ request: URLRequest, token: String) async throws -> (Data, Int) {
        var req = request
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Gitsidian-iOS-Widget", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? -1)
    }

    private static func message(_ data: Data) -> String {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "request failed"
    }
}
