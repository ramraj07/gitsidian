import Foundation

/// Fetches the widget file straight from GitHub so the widget updates when someone
/// (or an agent) commits to it, even if the app hasn't been opened.
enum RemoteFile {
    struct Contents: Decodable { let sha: String; let content: String?; let encoding: String? }

    enum Outcome { case found(sha: String, text: String), missing }

    static func fetch(_ r: WidgetRecord, token: String) async throws -> Outcome {
        let path = r.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? r.path
        var c = URLComponents(string: "https://api.github.com/repos/\(r.owner)/\(r.repo)/contents/\(path)")!
        c.queryItems = [URLQueryItem(name: "ref", value: r.branch)]
        var req = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Gitsidian-iOS-Widget", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404 { return .missing }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        let body = try JSONDecoder().decode(Contents.self, from: data)
        guard body.encoding == "base64", let b64 = body.content,
              let bytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
            throw URLError(.cannotDecodeContentData)
        }
        return .found(sha: body.sha, text: String(decoding: bytes, as: UTF8.self))
    }
}
