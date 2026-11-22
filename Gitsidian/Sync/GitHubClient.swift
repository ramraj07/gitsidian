import Foundation

struct GitHubError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { "GitHub \(status): \(message)" }
}

struct GitHubUser: Decodable { let login: String; let name: String? }

struct GitHubRepo: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let full_name: String
    let `private`: Bool
    let default_branch: String?
    let description: String?
    let owner: Owner
    struct Owner: Decodable, Hashable { let login: String }
}

struct GitHubBranch: Decodable, Hashable { let name: String }

struct GitTreeEntry: Codable, Hashable {
    let path: String
    let mode: String
    let type: String
    let sha: String?
    let size: Int?
}

/// Thin wrapper over the GitHub REST API (Git Data endpoints + a few repo endpoints).
struct GitHubClient: Sendable {
    let token: String
    private let api = URL(string: "https://api.github.com")!

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], accept: String = "application/vnd.github+json", body: Data? = nil) -> URLRequest {
        var comps = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Gitsidian-iOS", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], accept: String = "application/vnd.github+json", json: Any? = nil) async throws -> Data {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let req = makeRequest(method, path, query: query, accept: accept, body: body)
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GitHubError(status: -1, message: "No response") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GitHubError(status: http.statusCode, message: msg)
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await raw("GET", path, query: query))
    }

    func send<T: Decodable>(_ method: String, _ path: String, json: Any) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await raw(method, path, json: json))
    }

    // MARK: Account / repos

    func currentUser() async throws -> GitHubUser { try await get("user") }

    func repos(page: Int) async throws -> [GitHubRepo] {
        try await get("user/repos", query: [
            .init(name: "per_page", value: "100"),
            .init(name: "page", value: String(page)),
            .init(name: "sort", value: "updated"),
            .init(name: "affiliation", value: "owner,collaborator,organization_member"),
        ])
    }

    func allRepos() async throws -> [GitHubRepo] {
        var out: [GitHubRepo] = []
        for page in 1...10 {
            let batch = try await repos(page: page)
            out += batch
            if batch.count < 100 { break }
        }
        return out
    }

    func branches(_ repo: String) async throws -> [GitHubBranch] {
        try await get("repos/\(repo)/branches", query: [.init(name: "per_page", value: "100")])
    }

    // MARK: Git data

    private struct RefResponse: Decodable { struct Obj: Decodable { let sha: String }; let object: Obj }
    private struct CommitResponse: Decodable { struct Tree: Decodable { let sha: String }; let sha: String; let tree: Tree }
    private struct TreeResponse: Decodable { let sha: String; let tree: [GitTreeEntry]; let truncated: Bool }
    private struct ShaResponse: Decodable { let sha: String }

    /// Returns nil if the branch does not exist or the repo is empty.
    func headCommit(_ repo: String, branch: String) async throws -> String? {
        do {
            let ref: RefResponse = try await get("repos/\(repo)/git/ref/heads/\(branch)")
            return ref.object.sha
        } catch let e as GitHubError where e.status == 404 || e.status == 409 {
            return nil
        }
    }

    func treeSha(ofCommit repo: String, _ commit: String) async throws -> String {
        let c: CommitResponse = try await get("repos/\(repo)/git/commits/\(commit)")
        return c.tree.sha
    }

    func tree(_ repo: String, sha: String) async throws -> [GitTreeEntry] {
        let t: TreeResponse = try await get("repos/\(repo)/git/trees/\(sha)", query: [.init(name: "recursive", value: "1")])
        if t.truncated { throw GitHubError(status: 0, message: "Repository tree is too large for the GitHub API (truncated).") }
        return t.tree
    }

    func blob(_ repo: String, sha: String) async throws -> Data {
        try await raw("GET", "repos/\(repo)/git/blobs/\(sha)", accept: "application/vnd.github.raw")
    }

    func tarball(_ repo: String, ref: String) async throws -> Data {
        try await raw("GET", "repos/\(repo)/tarball/\(ref)")
    }

    func createBlob(_ repo: String, data: Data) async throws -> String {
        let r: ShaResponse = try await send("POST", "repos/\(repo)/git/blobs", json: [
            "content": data.base64EncodedString(),
            "encoding": "base64",
        ])
        return r.sha
    }

    struct TreeChange { let path: String; let mode: String; let sha: String? }

    func createTree(_ repo: String, base: String?, changes: [TreeChange]) async throws -> String {
        let entries: [[String: Any]] = changes.map {
            ["path": $0.path, "mode": $0.mode, "type": "blob", "sha": $0.sha.map { $0 as Any } ?? NSNull()]
        }
        var body: [String: Any] = ["tree": entries]
        if let base { body["base_tree"] = base }
        let r: ShaResponse = try await send("POST", "repos/\(repo)/git/trees", json: body)
        return r.sha
    }

    func createCommit(_ repo: String, message: String, tree: String, parents: [String]) async throws -> String {
        let r: ShaResponse = try await send("POST", "repos/\(repo)/git/commits", json: [
            "message": message, "tree": tree, "parents": parents,
        ])
        return r.sha
    }

    /// Fast-forward only. Throws GitHubError(422) if the branch moved.
    func updateRef(_ repo: String, branch: String, sha: String) async throws {
        _ = try await raw("PATCH", "repos/\(repo)/git/refs/heads/\(branch)", json: ["sha": sha, "force": false])
    }

    func createRef(_ repo: String, branch: String, sha: String) async throws {
        _ = try await raw("POST", "repos/\(repo)/git/refs", json: ["ref": "refs/heads/\(branch)", "sha": sha])
    }

    /// Git Data API can't write to an empty repo, so seed it via the contents API.
    func seedEmptyRepo(_ repo: String, branch: String) async throws {
        let text = "# Welcome\n\nThis vault is synced by Gitsidian.\n"
        _ = try await raw("PUT", "repos/\(repo)/contents/Welcome.md", json: [
            "message": "Initialize vault",
            "content": Data(text.utf8).base64EncodedString(),
            "branch": branch,
        ])
    }
}
