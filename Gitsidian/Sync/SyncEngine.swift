import Foundation

struct VaultConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var owner: String
    var repo: String
    var branch: String
    var fullName: String { "\(owner)/\(repo)" }
    var displayName: String { repo }
}

/// What we last agreed with GitHub on, plus a stat cache so we only re-hash files that changed.
struct VaultState: Codable {
    struct Entry: Codable, Equatable { var sha: String; var mode: String }
    struct Stat: Codable { var mtime: Double; var size: Int; var sha: String }
    var headCommit: String?
    var headTree: String?
    var entries: [String: Entry] = [:]
    var stat: [String: Stat] = [:]
    var lastSync: Date?
}

struct SyncResult {
    var pulled: [String] = []
    var pushed: [String] = []
    var conflicts: [String] = []
    var commit: String?
}

enum SyncError: LocalizedError {
    case unsafePath(String), gaveUp
    var errorDescription: String? {
        switch self {
        case .unsafePath(let p): return "Refusing unsafe path from repository: \(p)"
        case .gaveUp: return "The branch kept moving while syncing. Try again."
        }
    }
}

/// Owns a vault's on-disk working copy and syncs it with a GitHub branch through the Git Data API.
/// The working copy is a plain folder of files; every sync = pull (with 3-way merge) + one batched commit.
actor SyncEngine {
    let config: VaultConfig
    let client: GitHubClient
    let root: URL
    private let stateURL: URL
    private(set) var state: VaultState
    private let fm = FileManager.default

    static func vaultDirectory(_ id: UUID) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("Vaults/\(id.uuidString)", isDirectory: true)
    }

    init(config: VaultConfig, client: GitHubClient) {
        self.config = config
        self.client = client
        let dir = Self.vaultDirectory(config.id)
        root = dir.appendingPathComponent("files", isDirectory: true)
        stateURL = dir.appendingPathComponent("state.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        state = (try? JSONDecoder().decode(VaultState.self, from: Data(contentsOf: stateURL))) ?? VaultState()
    }

    var isCloned: Bool { state.headCommit != nil }

    private func save() throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    // MARK: Paths

    static func isIgnored(_ rel: String) -> Bool {
        let name = (rel as NSString).lastPathComponent
        return name == ".DS_Store" || rel == ".git" || rel.hasPrefix(".git/") || name.hasSuffix(".gitsidian-tmp")
    }

    private func url(_ rel: String) throws -> URL {
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        guard !rel.isEmpty, !rel.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw SyncError.unsafePath(rel)
        }
        return root.appendingPathComponent(rel)
    }

    private func writeFile(_ rel: String, _ data: Data) throws {
        let u = try url(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u, options: .atomic)
        cacheStat(rel, sha: GitHash.blob(data))
    }

    private func removeFile(_ rel: String) throws {
        let u = try url(rel)
        if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        state.stat[rel] = nil
        // prune now-empty parent folders (git doesn't track them anyway)
        var dir = u.deletingLastPathComponent()
        while dir.path.count > root.path.count,
              let items = try? fm.contentsOfDirectory(atPath: dir.path), items.filter({ $0 != ".DS_Store" }).isEmpty {
            try? fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    private func cacheStat(_ rel: String, sha: String) {
        guard let u = try? url(rel), let a = try? fm.attributesOfItem(atPath: u.path) else { return }
        state.stat[rel] = .init(mtime: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                                size: (a[.size] as? NSNumber)?.intValue ?? 0, sha: sha)
    }

    /// Current working copy: path -> blob sha.
    func scanLocal() throws -> [String: String] {
        var out: [String: String] = [:]
        let subpaths = (try? fm.subpathsOfDirectory(atPath: root.path)) ?? []
        for rel in subpaths where !Self.isIgnored(rel) {
            let u = root.appendingPathComponent(rel)
            guard let a = try? fm.attributesOfItem(atPath: u.path), a[.type] as? FileAttributeType == .typeRegular else { continue }
            let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (a[.size] as? NSNumber)?.intValue ?? 0
            if let s = state.stat[rel], s.mtime == mtime, s.size == size {
                out[rel] = s.sha
            } else {
                let sha = GitHash.blob(try Data(contentsOf: u))
                state.stat[rel] = .init(mtime: mtime, size: size, sha: sha)
                out[rel] = sha
            }
        }
        for k in state.stat.keys where out[k] == nil { state.stat[k] = nil }
        return out
    }

    /// Paths that differ from the last synced commit.
    func pendingChanges() throws -> [String] {
        let local = try scanLocal()
        var changed = Set<String>()
        for (p, sha) in local where state.entries[p]?.sha != sha { changed.insert(p) }
        for p in state.entries.keys where local[p] == nil { changed.insert(p) }
        return changed.sorted()
    }

    // MARK: Remote

    private func remoteSnapshot() async throws -> (commit: String, tree: String, entries: [String: VaultState.Entry])? {
        guard let head = try await client.headCommit(config.fullName, branch: config.branch) else { return nil }
        if head == state.headCommit, let tree = state.headTree { return (head, tree, state.entries) }
        let tree = try await client.treeSha(ofCommit: config.fullName, head)
        var entries: [String: VaultState.Entry] = [:]
        for e in try await client.tree(config.fullName, sha: tree)
        where e.type == "blob" && (e.mode == "100644" || e.mode == "100755") && !Self.isIgnored(e.path) {
            if let sha = e.sha { entries[e.path] = .init(sha: sha, mode: e.mode) }
        }
        return (head, tree, entries)
    }

    /// Fetches contents for many blobs: tarball when it's a lot, individual blobs otherwise.
    private func fetch(_ wanted: [String: String], commit: String) async throws -> [String: Data] {
        if wanted.isEmpty { return [:] }
        var out: [String: Data] = [:]
        if wanted.count > 25 {
            let gz = try await client.tarball(config.fullName, ref: commit)
            try TarGz.extract(gz) { path, data in if wanted[path] != nil { out[path] = data } }
        }
        let missing = wanted.filter { out[$0.key] == nil }
        let repo = config.fullName, client = client
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var it = missing.makeIterator()
            func add() { if let (p, sha) = it.next() { group.addTask { (p, try await client.blob(repo, sha: sha)) } } }
            for _ in 0..<6 { add() }
            while let (p, d) = try await group.next() { out[p] = d; add() }
        }
        return out
    }

    // MARK: Clone

    func clone(progress: @Sendable (String) -> Void) async throws {
        progress("Reading branch…")
        var snap = try await remoteSnapshot()
        if snap == nil {
            progress("Initializing empty repository…")
            try await client.seedEmptyRepo(config.fullName, branch: config.branch)
            snap = try await remoteSnapshot()
        }
        guard let snap else { throw GitHubError(status: 404, message: "Branch \(config.branch) not found") }
        progress("Downloading \(snap.entries.count) files…")
        let data = try await fetch(snap.entries.mapValues(\.sha), commit: snap.commit)
        progress("Writing files…")
        for (p, d) in data { try writeFile(p, d) }
        state.entries = snap.entries.filter { data[$0.key] != nil }
        state.headCommit = snap.commit
        state.headTree = snap.tree
        state.lastSync = Date()
        try save()
    }

    // MARK: Sync

    func sync(commitTitle: String, progress: @Sendable (String) -> Void) async throws -> SyncResult {
        var result = SyncResult()
        for _ in 0..<4 {
            progress("Checking for remote changes…")
            guard let snap = try await remoteSnapshot() else { throw GitHubError(status: 404, message: "Branch \(config.branch) not found") }
            if snap.commit != state.headCommit {
                progress("Pulling…")
                let r = try await integrate(snap)
                result.pulled += r.pulled
                result.conflicts += r.conflicts
            }

            let local = try scanLocal()
            var changes: [GitHubClient.TreeChange] = []
            var newBlobs: [String: String] = [:]
            for (p, sha) in local where state.entries[p]?.sha != sha { newBlobs[p] = sha }
            for p in state.entries.keys where local[p] == nil { changes.append(.init(path: p, mode: state.entries[p]!.mode, sha: nil)) }
            if newBlobs.isEmpty && changes.isEmpty {
                state.lastSync = Date(); try save()
                return result
            }

            progress("Uploading \(newBlobs.count + changes.count) changes…")
            let repo = config.fullName, client = client, root = root
            try await withThrowingTaskGroup(of: (String, String).self) { group in
                var it = newBlobs.keys.makeIterator()
                func add() {
                    if let p = it.next() {
                        group.addTask { (p, try await client.createBlob(repo, data: try Data(contentsOf: root.appendingPathComponent(p)))) }
                    }
                }
                for _ in 0..<6 { add() }
                while let (p, sha) = try await group.next() { newBlobs[p] = sha; add() }
            }
            for (p, sha) in newBlobs { changes.append(.init(path: p, mode: state.entries[p]?.mode ?? "100644", sha: sha)) }

            progress("Committing…")
            let paths = changes.map(\.path).sorted()
            let tree = try await client.createTree(repo, base: state.headTree, changes: changes)
            let commit = try await client.createCommit(repo, message: Self.commitMessage(commitTitle, paths), tree: tree, parents: state.headCommit.map { [$0] } ?? [])
            do {
                try await client.updateRef(repo, branch: config.branch, sha: commit)
            } catch let e as GitHubError where e.status == 422 || e.status == 409 {
                continue // branch moved under us: pull again and retry
            }
            for c in changes {
                if let sha = c.sha { state.entries[c.path] = .init(sha: sha, mode: c.mode) } else { state.entries[c.path] = nil }
            }
            state.headCommit = commit
            state.headTree = tree
            state.lastSync = Date()
            try save()
            result.pushed = paths
            result.commit = commit
            return result
        }
        throw SyncError.gaveUp
    }

    /// Brings remote changes into the working copy, preserving local edits (3-way merge, conflict copies as a last resort).
    private func integrate(_ snap: (commit: String, tree: String, entries: [String: VaultState.Entry])) async throws -> (pulled: [String], conflicts: [String]) {
        let base = state.entries, remote = snap.entries
        let local = try scanLocal()
        var toFetch: [String: String] = [:], baseWanted: [String: String] = [:]
        var plan: [(path: String, kind: Int)] = [] // 0 overwrite/create, 1 delete, 2 merge
        for p in Set(base.keys).union(remote.keys) {
            let b = base[p]?.sha, r = remote[p]?.sha, l = local[p]
            if b == r { continue }
            if l == r { continue }
            if l == b {
                if let r { toFetch[p] = r; plan.append((p, 0)) } else { plan.append((p, 1)) }
            } else if r == nil {
                continue // remote deleted, local modified: keep local; it will be re-added
            } else if l == nil {
                toFetch[p] = r!; plan.append((p, 0)) // local deleted, remote modified: restore remote
            } else {
                toFetch[p] = r!
                if let b { baseWanted[p] = b }
                plan.append((p, 2))
            }
        }
        let fetched = try await fetch(toFetch, commit: snap.commit)
        let baseData = try await fetch(baseWanted, commit: state.headCommit ?? snap.commit)

        var pulled: [String] = [], conflicts: [String] = []
        for (p, kind) in plan {
            switch kind {
            case 0: if let d = fetched[p] { try writeFile(p, d); pulled.append(p) }
            case 1: try removeFile(p); pulled.append(p)
            default:
                guard let rd = fetched[p] else { continue }
                let ld = try Data(contentsOf: try url(p))
                let bd = baseData[p] ?? Data()
                if let bs = String(data: bd, encoding: .utf8), let ls = String(data: ld, encoding: .utf8),
                   let rs = String(data: rd, encoding: .utf8), let merged = Merge3.merge(base: bs, local: ls, remote: rs) {
                    try writeFile(p, Data(merged.utf8))
                    pulled.append(p)
                } else {
                    // Keep both: remote wins the original path, local edits go to a conflict copy.
                    let copy = conflictCopyPath(p)
                    try writeFile(copy, ld)
                    try writeFile(p, rd)
                    conflicts.append(copy)
                    pulled.append(p)
                }
            }
        }
        state.entries = remote
        state.headCommit = snap.commit
        state.headTree = snap.tree
        try save()
        return (pulled, conflicts)
    }

    static func commitMessage(_ title: String, _ paths: [String]) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        var msg = "\(title): \(f.string(from: Date())) (\(paths.count) file\(paths.count == 1 ? "" : "s"))"
        if paths.count > 1 || paths.first.map({ !$0.isEmpty }) == true {
            msg += "\n\n" + paths.prefix(50).map { "- \($0)" }.joined(separator: "\n")
            if paths.count > 50 { msg += "\n- …and \(paths.count - 50) more" }
        }
        return msg
    }

    private func conflictCopyPath(_ p: String) -> String {
        let ns = p as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        var candidate = "\(stem) (conflict \(f.string(from: Date())))" + (ext.isEmpty ? "" : ".\(ext)")
        var n = 2
        while fm.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(stem) (conflict \(f.string(from: Date())) \(n))" + (ext.isEmpty ? "" : ".\(ext)"); n += 1
        }
        return candidate
    }

    func deleteLocalCopy() {
        try? fm.removeItem(at: Self.vaultDirectory(config.id))
    }
}
