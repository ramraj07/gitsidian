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
    var family: String         // small | medium | large | extraLarge | app | rectangular | circular | inline

    static let preview = WidgetFileContext(vaultID: nil, repo: "", branch: "", path: "preview" + WidgetFile.suffix, family: "app")

    /// `gitsidian.note("Daily/Today")` -> gitsidian://open?vault=…&path=Daily/Today
    /// Paths starting with "/" are vault-absolute; others resolve against the widget file's folder.
    /// `Note#Heading` / `Note#^block-id` also scroll to that section.
    func noteURL(_ target: String) -> URL? {
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
        return DeepLink.open(vault: vaultID, path: t, anchor: anchor)
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
