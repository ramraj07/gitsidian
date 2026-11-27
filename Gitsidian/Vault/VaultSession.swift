import Foundation
import Observation
import UIKit

struct Backlink: Hashable { let path: String; let line: String }
struct SearchHit: Hashable { let path: String; let snippets: [String] }

enum SyncStatus: Equatable {
    case idle, syncing(String), error(String)
}

/// Everything about one open vault: file tree, navigation, file operations and auto-sync scheduling.
@Observable @MainActor
final class VaultSession {
    let config: VaultConfig
    let engine: SyncEngine
    let root: URL

    var tree = FileNode(name: "", path: "", isFolder: true, children: [])
    var files: [String] = []                // every file path, for linking & search
    var isCloned = false
    var cloneProgress: String?
    var cloneError: String?

    var currentPath: String?
    var recent: [String] = []
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []

    var status: SyncStatus = .idle
    var lastSync: Date?
    var hasLocalEdits = false
    var pendingCount = 0
    var notice: String?                     // transient message (conflicts etc.)
    var pendingOpen: String?                // from a gitsidian://open link, opened once the vault is ready
    @ObservationIgnored private var pendingAnchor: String?
    /// Set when a note should scroll to a heading/block; the note view consumes and clears it.
    var anchorRequest: AnchorRequest?

    /// Bumped whenever a sync rewrote files on disk; editors use it to reload.
    var diskVersion = 0
    var changedOnDisk: Set<String> = []

    @ObservationIgnored private var flushers: [UUID: () -> Void] = [:]
    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private let fm = FileManager.default
    private var lastOpenKey: String { "lastOpen-\(config.id.uuidString)" }
    private var recentKey: String { "recent-\(config.id.uuidString)" }

    init(config: VaultConfig, client: GitHubClient) {
        self.config = config
        engine = SyncEngine(config: config, client: client)
        root = SyncEngine.vaultDirectory(config.id).appendingPathComponent("files", isDirectory: true)
        Task { await start() }
    }

    private func start() async {
        isCloned = await engine.isCloned
        lastSync = await engine.state.lastSync
        recent = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        if isCloned {
            refreshTree()
            if let last = UserDefaults.standard.string(forKey: lastOpenKey), exists(last) { currentPath = last }
            openPending()
            pendingCount = (try? await engine.pendingChanges().count) ?? 0
            hasLocalEdits = pendingCount > 0
            if Pref.d.bool(forKey: Pref.syncOnOpen) { await sync() }
        } else {
            await clone()
        }
    }

    func clone() async {
        cloneError = nil
        cloneProgress = "Starting…"
        do {
            try await engine.clone { msg in Task { @MainActor in self.cloneProgress = msg } }
            isCloned = true
            lastSync = Date()
            refreshTree()
            currentPath = files.first(where: { ["readme.md", "home.md", "index.md"].contains($0.lowercased()) })
            openPending()
        } catch {
            cloneError = error.localizedDescription
        }
        cloneProgress = nil
    }

    // MARK: Tree

    func refreshTree() {
        tree = FileNode.build(root: root, showHidden: Pref.d.bool(forKey: Pref.showHidden))
        let all = FileNode.build(root: root, showHidden: true)
        files = all.allFiles.map(\.path)
        if let c = currentPath, !exists(c) { currentPath = nil }
        publishWidgets()
    }

    var widgetFiles: [String] { files.filter(WidgetFile.isAnyWidget) }

    /// Hands every `*.gitsidian.widget` and `*.gitsidian.lock` file, as it is on disk now, to the widgets.
    func publishWidgets() {
        guard isCloned else { return }
        let paths = widgetFiles
        let config = config
        let data = Dictionary(uniqueKeysWithValues: paths.map { ($0, (try? Data(contentsOf: url($0))) ?? Data()) })
        Task {
            let entries = await engine.state.entries
            let store = WidgetStore.shared
            let records = paths.map { p -> WidgetRecord in
                let synced = entries[p]?.sha
                let local = data[p] ?? Data()
                let id = WidgetRecord(vaultID: config.id, owner: "", repo: "", branch: "", path: p).id
                let old = store.record(id: id)
                if let old, old.appSha == synced, GitHash.blob(local) == synced, old.branch == config.branch {
                    return old   // nothing new from GitHub or local edits: keep what the widget may have fetched
                }
                var r = WidgetRecord(vaultID: config.id, owner: config.owner, repo: config.repo, branch: config.branch,
                                     path: p, script: String(decoding: local, as: UTF8.self), baseSha: synced,
                                     appSha: synced, updatedAt: old?.updatedAt)
                if r != old { r.updatedAt = Date() }
                return r
            }
            if WidgetStore.shared.replace(vault: config.id, with: records) { WidgetReload.all() }
        }
    }

    var visibleFiles: [String] {
        Pref.d.bool(forKey: Pref.showHidden) ? files : files.filter { !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func exists(_ path: String) -> Bool { fm.fileExists(atPath: url(path).path) }
    func isFolder(_ path: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: url(path).path, isDirectory: &d) && d.boolValue
    }

    // MARK: Navigation

    /// Opens a deep-linked path now if the vault is ready, else as soon as it is.
    func openDeepLink(_ path: String, anchor: String? = nil) {
        pendingOpen = path
        pendingAnchor = anchor
        if isCloned { openPending() }
    }

    private func openPending() {
        guard let p = pendingOpen else { return }
        pendingOpen = nil
        let anchor = pendingAnchor
        pendingAnchor = nil
        if let resolved = exists(p) ? p : resolve(p, from: nil) { open(resolved, anchor: anchor) }
    }

    func open(_ path: String, anchor: String? = nil) {
        if let anchor, !anchor.isEmpty { anchorRequest = AnchorRequest(path: path, subpath: anchor) }
        guard path != currentPath else { return }
        if let c = currentPath { backStack.append(c) }
        forwardStack.removeAll()
        currentPath = path
        UserDefaults.standard.set(path, forKey: lastOpenKey)
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > 20 { recent.removeLast() }
        UserDefaults.standard.set(recent, forKey: recentKey)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let p = backStack.popLast() else { return }
        if let c = currentPath { forwardStack.append(c) }
        currentPath = p
    }

    func goForward() {
        guard let p = forwardStack.popLast() else { return }
        if let c = currentPath { backStack.append(c) }
        currentPath = p
    }

    /// Opens a [[wikilink]] target, creating the note if it doesn't exist (like Obsidian).
    func openLink(_ target: String, from: String?) {
        let t = Links.stripSubpath(target)
        let sub = Links.subpath(target)
        if t.isEmpty {   // [[#Heading]] inside the same note
            if let from, let sub { open(from, anchor: sub) }
            return
        }
        if let p = resolve(t, from: from) { open(p, anchor: sub); return }
        let name = t.hasSuffix(".md") ? String(t.dropLast(3)) : t
        let folder = name.contains("/") ? (name as NSString).deletingLastPathComponent : ""
        if let p = createNote(in: folder, name: (name as NSString).lastPathComponent) { open(p) }
    }

    func resolve(_ link: String, from: String?) -> String? {
        let t = Links.stripSubpath(link).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return from }
        let lower = t.lowercased()
        let set = Set(files.map { $0.lowercased() })
        func match(_ lp: String) -> String? { files.first { $0.lowercased() == lp } }
        if set.contains(lower) { return match(lower) }
        if set.contains(lower + ".md") { return match(lower + ".md") }
        if let from {
            let dir = (from as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                let rel = ((dir as NSString).appendingPathComponent(t) as NSString).standardizingPath.lowercased()
                if set.contains(rel) { return match(rel) }
                if set.contains(rel + ".md") { return match(rel + ".md") }
            }
        }
        // Shortest-path match on file name, Obsidian style.
        let candidates = files.filter { f in
            let name = (f as NSString).lastPathComponent.lowercased()
            return name == lower || name == lower + ".md" || f.lowercased().hasSuffix("/" + lower) || f.lowercased().hasSuffix("/" + lower + ".md")
        }
        return candidates.min { $0.count < $1.count }
    }

    /// Every note name (without .md) — for link autocomplete and the quick switcher.
    func linkSuggestions(_ query: String, limit: Int = 8) -> [String] {
        let names = visibleFiles.map { FileKind(path: $0) == .markdown ? (($0 as NSString).lastPathComponent as NSString).deletingPathExtension : ($0 as NSString).lastPathComponent }
        if query.isEmpty { return Array(names.prefix(limit)) }
        return names.compactMap { n -> (String, Int)? in Fuzzy.score(query, n).map { (n, $0) } }
            .sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    // MARK: File IO

    func readText(_ path: String) -> String {
        guard let d = try? Data(contentsOf: url(path)) else { return "" }
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    func writeText(_ path: String, _ text: String) {
        let u = url(path)
        if let old = try? Data(contentsOf: u), old == Data(text.utf8) { return }
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: u, options: .atomic)
        localChange()
        if WidgetFile.isAnyWidget(path) { publishWidgets() }
    }

    func writeData(_ path: String, _ data: Data) {
        let u = url(path)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: u, options: .atomic)
        localChange(treeChanged: true)
    }

    private func localChange(treeChanged: Bool = false) {
        hasLocalEdits = true
        if treeChanged { refreshTree() }
        scheduleAutoSync()
    }

    // MARK: File operations

    func uniquePath(folder: String, base: String, ext: String) -> String {
        func p(_ n: String) -> String {
            let f = ext.isEmpty ? n : "\(n).\(ext)"
            return folder.isEmpty ? f : "\(folder)/\(f)"
        }
        var candidate = p(base)
        var i = 1
        while exists(candidate) { candidate = p("\(base) \(i)"); i += 1 }
        return candidate
    }

    @discardableResult
    func createNote(in folder: String, name: String? = nil, content: String = "") -> String? {
        let base = Links.sanitize(name ?? "Untitled")
        let path = name != nil && !exists(folder.isEmpty ? "\(base).md" : "\(folder)/\(base).md")
            ? (folder.isEmpty ? "\(base).md" : "\(folder)/\(base).md")
            : uniquePath(folder: folder, base: base, ext: "md")
        let u = url(path)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? Data(content.utf8).write(to: u, options: .withoutOverwriting)) != nil else { return nil }
        localChange(treeChanged: true)
        return path
    }

    /// Creates `<name>.gitsidian.widget` (or `<name>.gitsidian.lock`) from its starter template.
    @discardableResult
    func createWidget(in folder: String, name: String?, lock: Bool = false) -> String? {
        let base = Links.sanitize(name ?? (lock ? "Lock Screen" : "Widget"))
        let path = uniquePath(folder: folder, base: base, ext: String((lock ? WidgetFile.lockSuffix : WidgetFile.suffix).dropFirst()))
        let u = url(path)
        let text = lock ? LockTemplate.starter(title: base) : WidgetTemplate.starter(title: base)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? Data(text.utf8).write(to: u, options: .withoutOverwriting)) != nil else { return nil }
        localChange(treeChanged: true)
        return path
    }

    @discardableResult
    func createFolder(in parent: String, name: String = "Untitled") -> String? {
        let path = uniquePath(folder: parent, base: Links.sanitize(name), ext: "")
        guard (try? fm.createDirectory(at: url(path), withIntermediateDirectories: true)) != nil else { return nil }
        refreshTree()
        return path
    }

    /// Moves/renames a file or folder, keeping history, open note and (optionally) wikilinks pointing at it.
    @discardableResult
    func move(_ path: String, to newPath: String) -> Bool {
        guard path != newPath, !newPath.isEmpty, !exists(newPath) || path.lowercased() == newPath.lowercased() else { return false }
        flushEditors()
        let wasFolder = isFolder(path)
        let movedNotes: [(String, String)] = wasFolder
            ? files.filter { $0.hasPrefix(path + "/") }.map { ($0, newPath + $0.dropFirst(path.count)) }
            : [(path, newPath)]
        do {
            try fm.createDirectory(at: url(newPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            if path.lowercased() == newPath.lowercased() {
                // case-only rename on a case-insensitive file system
                let tmp = path + ".gitsidian-tmp"
                try fm.moveItem(at: url(path), to: url(tmp))
                try fm.moveItem(at: url(tmp), to: url(newPath))
            } else {
                try fm.moveItem(at: url(path), to: url(newPath))
            }
        } catch {
            notice = error.localizedDescription
            return false
        }
        func remap(_ p: String) -> String {
            if p == path { return newPath }
            if p.hasPrefix(path + "/") { return newPath + p.dropFirst(path.count) }
            return p
        }
        currentPath = currentPath.map(remap)
        backStack = backStack.map(remap)
        forwardStack = forwardStack.map(remap)
        refreshTree()
        if Pref.d.bool(forKey: Pref.updateLinksOnRename) { updateLinks(movedNotes) }
        localChange()
        return true
    }

    func rename(_ path: String, to newName: String) -> Bool {
        var name = Links.sanitize(newName)
        guard !name.isEmpty else { return false }
        if !isFolder(path), FileKind(path: path) == .markdown, !name.lowercased().hasSuffix(".md") { name += ".md" }
        if !isFolder(path), FileKind(path: path) == .widget, !WidgetFile.isWidget(name) { name += WidgetFile.suffix }
        if !isFolder(path), FileKind(path: path) == .lockWidget, !WidgetFile.isLock(name) { name += WidgetFile.lockSuffix }
        let dir = (path as NSString).deletingLastPathComponent
        return move(path, to: dir.isEmpty ? name : "\(dir)/\(name)")
    }

    func delete(_ path: String) {
        flushEditors()
        try? fm.removeItem(at: url(path))
        if let c = currentPath, c == path || c.hasPrefix(path + "/") { currentPath = nil }
        backStack.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        forwardStack.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        localChange(treeChanged: true)
    }

    private func updateLinks(_ moves: [(String, String)]) {
        let renames: [(String, String)] = moves.compactMap { old, new in
            guard FileKind(path: old) == .markdown else { return nil }
            let o = ((old as NSString).lastPathComponent as NSString).deletingPathExtension
            let n = ((new as NSString).lastPathComponent as NSString).deletingPathExtension
            return o == n ? nil : (o, n)
        }
        guard !renames.isEmpty else { return }
        for f in files where FileKind(path: f) == .markdown {
            let text = readText(f)
            var updated = text
            for (o, n) in renames { updated = Links.renameTarget(in: updated, from: o, to: n) }
            if updated != text { try? Data(updated.utf8).write(to: url(f), options: .atomic) }
        }
        diskVersion += 1
        changedOnDisk = Set(files)
    }

    func backlinks(for path: String) -> [Backlink] {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var out: [Backlink] = []
        for f in files where f != path && FileKind(path: f) == .markdown {
            for line in readText(f).split(separator: "\n") where line.contains("[[") {
                if Links.wikiTargets(in: String(line)).contains(where: { resolve($0, from: f) == path || Links.stripSubpath($0).lowercased() == name.lowercased() }) {
                    out.append(Backlink(path: f, line: line.trimmingCharacters(in: .whitespaces)))
                    break
                }
            }
        }
        return out
    }

    func search(_ query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var out: [SearchHit] = []
        for f in visibleFiles where [.markdown, .text, .widget, .lockWidget].contains(FileKind(path: f)) {
            let text = readText(f)
            let nameHit = f.localizedCaseInsensitiveContains(q)
            let lines = text.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(q) }.prefix(3).map {
                String($0.trimmingCharacters(in: .whitespaces).prefix(160))
            }
            if nameHit || !lines.isEmpty { out.append(SearchHit(path: f, snippets: Array(lines))) }
            if out.count >= 200 { break }
        }
        return out
    }

    // MARK: Sync

    func registerFlusher(_ id: UUID, _ f: @escaping () -> Void) { flushers[id] = f }
    func unregisterFlusher(_ id: UUID) { flushers[id] = nil }
    func flushEditors() { flushers.values.forEach { $0() } }

    func scheduleAutoSync() {
        autoSyncTask?.cancel()
        let delay = Pref.d.integer(forKey: Pref.autoSyncDelay)
        guard delay > 0 else { return }
        autoSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    var isSyncing: Bool { if case .syncing = status { return true }; return false }

    func sync() async {
        guard isCloned else { return }
        if isSyncing { syncAgain = true; return }
        autoSyncTask?.cancel()
        flushEditors()
        status = .syncing("Syncing…")
        do {
            let title = Pref.d.string(forKey: Pref.commitTitle) ?? "vault backup"
            let r = try await engine.sync(commitTitle: title.isEmpty ? "vault backup" : title) { msg in
                Task { @MainActor in if case .syncing = self.status { self.status = .syncing(msg) } }
            }
            if !r.pulled.isEmpty {
                refreshTree()
                changedOnDisk = Set(r.pulled)
                diskVersion += 1
            }
            if !r.conflicts.isEmpty {
                notice = "Conflicting edits were saved as: " + r.conflicts.joined(separator: ", ")
            }
            lastSync = Date()
            status = .idle
            publishWidgets()   // base shas moved even if no widget file changed
        } catch {
            status = .error(error.localizedDescription)
        }
        pendingCount = (try? await engine.pendingChanges().count) ?? 0
        hasLocalEdits = pendingCount > 0
        if syncAgain { syncAgain = false; await sync() }
    }

    /// Called when the app goes to background: push whatever is pending while iOS gives us time.
    func syncInBackground() {
        flushEditors()
        guard hasLocalEdits else { return }
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "gitsidian-sync") {
            UIApplication.shared.endBackgroundTask(taskId)
        }
        Task {
            await sync()
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }
}
