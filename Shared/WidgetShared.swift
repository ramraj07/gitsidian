import Foundation

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
    func noteURL(_ target: String) -> URL? {
        var t = target
        if t.hasPrefix("/") {
            t.removeFirst()
        } else {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty { t = ((dir as NSString).appendingPathComponent(t) as NSString).standardizingPath }
        }
        return DeepLink.open(vault: vaultID, path: t)
    }
}

/// gitsidian://open?vault=<uuid>&path=<vault-relative path>
enum DeepLink {
    static let scheme = "gitsidian"

    static func open(vault: UUID?, path: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: path)] + (vault.map { [URLQueryItem(name: "vault", value: $0.uuidString)] } ?? [])
        return c.url
    }

    static func parse(_ url: URL) -> (vault: UUID?, path: String)? {
        guard url.scheme == scheme, url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return nil }
        return (items.first(where: { $0.name == "vault" })?.value.flatMap(UUID.init(uuidString:)), path)
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
    var updatedAt: Date?

    var fullName: String { "\(owner)/\(repo)" }
    var name: String { WidgetFile.displayName(path) }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// The App Group cache shared by the app (writes what's on disk) and the widget (refreshes from GitHub).
final class WidgetStore: @unchecked Sendable {
    static let shared = WidgetStore()

    let defaults: UserDefaults
    private let url: URL
    private let lock = NSLock()

    init() {
        defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        let dir = (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
            ?? URL.applicationSupportDirectory).appendingPathComponent("Library/Caches/widgets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("widgets.json")
    }

    func load() -> [WidgetRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WidgetRecord].self, from: d)) ?? []
    }

    func save(_ records: [WidgetRecord]) {
        lock.lock(); defer { lock.unlock() }
        if let d = try? JSONEncoder().encode(records) { try? d.write(to: url, options: .atomic) }
    }

    func record(id: String) -> WidgetRecord? { load().first { $0.id == id } }

    /// Replaces one vault's records; returns true if anything changed.
    @discardableResult
    func replace(vault: UUID, with records: [WidgetRecord]) -> Bool {
        let all = load()
        let old = all.filter { $0.vaultID == vault }
        guard Set(old) != Set(records) else { return false }
        save(all.filter { $0.vaultID != vault } + records.sorted { $0.path < $1.path })
        return true
    }

    func update(_ record: WidgetRecord) {
        var all = load()
        if let i = all.firstIndex(where: { $0.id == record.id }) { all[i] = record } else { all.append(record) }
        save(all)
    }

    // Current page per widget file (1-based), set by the page buttons.
    func pageNumber(_ id: String) -> Int { max(1, defaults.integer(forKey: "page." + id)) }
    func setPageNumber(_ n: Int, _ id: String) { defaults.set(max(1, n), forKey: "page." + id) }

    /// A page switch reloads the timeline; it shouldn't wait on the network.
    func markSkipFetchOnce() { defaults.set(true, forKey: "skipFetchOnce") }
    func consumeSkipFetchOnce() -> Bool {
        let v = defaults.bool(forKey: "skipFetchOnce")
        if v { defaults.removeObject(forKey: "skipFetchOnce") }
        return v
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
