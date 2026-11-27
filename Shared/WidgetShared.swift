import Foundation
import CryptoKit

enum AppGroup {
    /// Must match the App Groups capability of the app and the widget extension.
    static let identifier = "group.com.gitsidian.app"
}

/// `*.gitsidian.widget`: a JavaScript program (Kondai runtime API v1) that builds a home-screen widget.
enum WidgetFile {
    static let suffix = ".gitsidian.widget"

    static func isWidget(_ path: String) -> Bool { path.lowercased().hasSuffix(suffix) }

    /// "Tasks.gitsidian.widget" -> "Tasks"
    static func displayName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return isWidget(name) ? String(name.dropLast(suffix.count)) : name
    }
}

/// What a running script can learn about itself through `gitsidian.path / .repo / .branch / .family`.
struct WidgetFileContext: Sendable {
    var vaultID: UUID?
    var repo: String           // owner/name
    var branch: String
    var path: String
    var family: String         // small | medium | large | extraLarge | app

    static let preview = WidgetFileContext(vaultID: nil, repo: "", branch: "", path: "preview" + WidgetFile.suffix, family: "app")

    /// `gitsidian.note("Daily/Today")` -> gitsidian://open?vault=…&path=Daily/Today
    /// Paths starting with "/" are vault-absolute; others resolve against the widget file's folder.
    /// `Note#Heading` / `Note#^block-id` also scroll to that section.
    func noteURL(_ target: String) -> URL? {
        guard let r = resolve(target) else { return nil }
        return DeepLink.open(vault: vaultID, path: r.path, anchor: r.anchor)
    }

    /// The vault-relative file a checkbox's task line lives in. `nil` = this widget file.
    /// Same rules as `noteURL`, except the widget can't search the vault, so a name with no
    /// extension gets ".md" instead of resolving like a [[link]].
    func taskFilePath(_ target: String?) -> String? {
        guard let target, !target.trimmingCharacters(in: .whitespaces).isEmpty else { return path }
        guard var t = resolve(target)?.path, !t.isEmpty else { return nil }
        if (t as NSString).pathExtension.isEmpty { t += ".md" }
        return t
    }

    /// "/x/y#Heading" -> ("x/y", "Heading"); relative paths resolve against this file's folder.
    private func resolve(_ target: String) -> (path: String, anchor: String?)? {
        var t = target
        var anchor: String?
        if let i = t.firstIndex(of: "#") {
            let a = t[t.index(after: i)...].trimmingCharacters(in: .whitespaces)
            anchor = a.isEmpty ? nil : a
            t = String(t[..<i])
        }
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("/") {
            t.removeFirst()
        } else {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty { t = ((dir as NSString).appendingPathComponent(t) as NSString).standardizingPath }
        }
        return (t, anchor)
    }
}

/// gitsidian://open?vault=<uuid>&path=<vault-relative path>[&anchor=<Heading or ^block-id>]
enum DeepLink {
    static let scheme = "gitsidian"

    static func open(vault: UUID?, path: String, anchor: String? = nil) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "open"
        var items = [URLQueryItem(name: "path", value: path)]
        if let vault { items.append(URLQueryItem(name: "vault", value: vault.uuidString)) }
        if let anchor { items.append(URLQueryItem(name: "anchor", value: anchor)) }
        c.queryItems = items
        return c.url
    }

    static func parse(_ url: URL) -> (vault: UUID?, path: String, anchor: String?)? {
        guard url.scheme == scheme, url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return nil }
        return (items.first(where: { $0.name == "vault" })?.value.flatMap(UUID.init(uuidString:)), path,
                items.first(where: { $0.name == "anchor" })?.value)
    }
}

/// One widget file the app has seen in a vault, with the latest script it knows of.
struct WidgetRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(vaultID.uuidString)/\(path)" }
    var vaultID: UUID
    var owner: String
    var repo: String
    var branch: String
    var path: String
    var script: String?
    /// Git blob sha of the GitHub version `script` is based on. The widget refetches the file and
    /// replaces `script` only when GitHub's sha differs, so unpushed local edits are kept until then.
    var baseSha: String?
    /// The synced blob sha the app had when it last wrote this record. While it hasn't changed (the app
    /// hasn't pulled anything new) and the file has no local edits, the app leaves the widget's own,
    /// possibly newer, GitHub fetch alone instead of putting the older copy back.
    var appSha: String?
    var updatedAt: Date?

    var fullName: String { "\(owner)/\(repo)" }
    var name: String { WidgetFile.displayName(path) }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// The App Group cache shared by the app (writes what's on disk) and the widget (refreshes from GitHub).
/// One JSON file per widget file, so two processes (or two widgets refreshing at once) never
/// overwrite each other's records with a stale copy of the whole list.
final class WidgetStore: @unchecked Sendable {
    static let shared = WidgetStore()

    let defaults: UserDefaults
    private let dir: URL
    private let fm = FileManager.default

    init() {
        defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        let base = (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
            ?? URL.applicationSupportDirectory).appendingPathComponent("Library/Caches/widgets", isDirectory: true)
        dir = base.appendingPathComponent("records", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Pre-1.1 cache was a single widgets.json; it's rebuilt by the app on next launch.
        try? fm.removeItem(at: base.appendingPathComponent("widgets.json"))
    }

    private func fileURL(_ id: String) -> URL {
        let hex = SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(hex + ".json")
    }

    func load() -> [WidgetRecord] {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(WidgetRecord.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.fullName, $0.path) < ($1.fullName, $1.path) }
    }

    func record(id: String) -> WidgetRecord? {
        guard let d = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? JSONDecoder().decode(WidgetRecord.self, from: d)
    }

    func update(_ record: WidgetRecord) {
        if let d = try? JSONEncoder().encode(record) { try? d.write(to: fileURL(record.id), options: .atomic) }
    }

    /// Makes one vault's records exactly `records`; returns true if anything changed.
    @discardableResult
    func replace(vault: UUID, with records: [WidgetRecord]) -> Bool {
        var changed = false
        let keep = Set(records.map(\.id))
        for old in load() where old.vaultID == vault && !keep.contains(old.id) {
            try? fm.removeItem(at: fileURL(old.id))
            changed = true
        }
        for r in records where record(id: r.id) != r {
            update(r)
            changed = true
        }
        return changed
    }

    // Current page per widget file (1-based), set by the page buttons.
    func pageNumber(_ id: String) -> Int { max(1, defaults.integer(forKey: "page." + id)) }
    func setPageNumber(_ n: Int, _ id: String) { defaults.set(max(1, n), forKey: "page." + id) }

    /// A page switch reloads the timeline; that widget shouldn't wait on the network.
    func markSkipFetchOnce(_ id: String) { defaults.set(true, forKey: "skipFetchOnce." + id) }
    func consumeSkipFetchOnce(_ id: String) -> Bool {
        let key = "skipFetchOnce." + id
        let v = defaults.bool(forKey: key)
        if v { defaults.removeObject(forKey: key) }
        return v
    }
}

/// A checkbox tap in the widget, waiting to be committed to GitHub.
struct TaskToggle: Codable, Hashable, Sendable {
    var widgetID: String       // WidgetRecord.id of the widget it was tapped in
    var path: String           // vault file holding the task line
    var text: String
    var checked: Bool

    var key: String { TaskToggle.key(widgetID: widgetID, path: path, text: text) }
    static func key(widgetID: String, path: String, text: String) -> String { "\(widgetID)\n\(path)\n\(text)" }
}

/// What the widget shows for a checkbox after a tap, so it doesn't flip back while the commit is
/// in flight, or (for a task in another note) until the widget file itself is rewritten.
struct TaskOverride: Codable, Hashable, Sendable {
    var checked: Bool
    /// The widget file's sha when the override was made. Once the file changes on GitHub, the
    /// script's own `checked` values win again.
    var widgetSha: String?
}

extension WidgetStore {
    private static let pendingKey = "pendingTaskToggles"
    private static let overridesKey = "taskOverrides"

    func pendingToggles() -> [TaskToggle] {
        defaults.data(forKey: Self.pendingKey).flatMap { try? JSONDecoder().decode([TaskToggle].self, from: $0) } ?? []
    }

    func setPendingToggles(_ list: [TaskToggle]) {
        if list.isEmpty { defaults.removeObject(forKey: Self.pendingKey); return }
        if let d = try? JSONEncoder().encode(list) { defaults.set(d, forKey: Self.pendingKey) }
    }

    /// A newer tap on the same task replaces an older one that hasn't been sent yet.
    func enqueue(_ t: TaskToggle) {
        setPendingToggles(pendingToggles().filter { $0.key != t.key } + [t])
    }

    func overrides() -> [String: TaskOverride] {
        defaults.data(forKey: Self.overridesKey).flatMap { try? JSONDecoder().decode([String: TaskOverride].self, from: $0) } ?? [:]
    }

    func setOverride(_ o: TaskOverride?, for key: String) {
        var all = overrides()
        all[key] = o
        if let d = try? JSONEncoder().encode(all) { defaults.set(d, forKey: Self.overridesKey) }
    }

    /// The program with taps applied: pending ones always, committed ones while the widget file is
    /// still the version they were made against. Stale overrides for this widget are dropped.
    func applyingTaskState(_ program: WidgetProgram, record: WidgetRecord) -> WidgetProgram {
        let all = overrides()
        let pending = Dictionary(pendingToggles().filter { $0.widgetID == record.id }.map { ($0.key, $0.checked) },
                                 uniquingKeysWith: { _, new in new })
        var live = all
        for (k, o) in all where k.hasPrefix(record.id + "\n") && pending[k] == nil && o.widgetSha != record.baseSha {
            live[k] = nil
        }
        if live.count != all.count, let d = try? JSONEncoder().encode(live) { defaults.set(d, forKey: Self.overridesKey) }
        return program.mapCheckboxes { box in
            let k = TaskToggle.key(widgetID: record.id, path: box.path, text: box.text)
            var b = box
            if let c = pending[k] ?? live[k]?.checked { b.checked = c }
            return b
        }
    }
}

enum DateParsing {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    /// RFC 3339 with or without fractional seconds; date-only or zone-less times are UTC.
    static func parse(_ s: String) -> Date? {
        if let d = fractional.date(from: s) ?? plain.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
