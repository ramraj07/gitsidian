import WidgetKit
import SwiftUI

/// The Lock Screen widget: runs a `*.gitsidian.lock` file, which builds one small layout per size
/// with `gitsidian.lockScreen()`. Separate from the Home Screen widget on purpose: a Lock Screen
/// widget is designed for its space, not shrunk from a bigger one.
struct GitsidianLockWidget: Widget {
    static let kind = "GitsidianLockWidget"   // WidgetReload.lockKind in the app

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectLockFileIntent.self, provider: LockProvider()) { entry in
            LockWidgetView(entry: entry)
        }
        .configurationDisplayName("Lock Screen widget")
        .description("Runs a .gitsidian.lock file from one of your vaults.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

extension LockFamily {
    init(_ f: WidgetFamily) {
        switch f {
        case .accessoryCircular: self = .circular
        case .accessoryInline: self = .inline
        default: self = .rectangular
        }
    }
}

struct LockEntry: TimelineEntry {
    enum Content {
        case program(LockProgram, record: WidgetRecord)
        case noFile
        case needsConfig
        case error(String, record: WidgetRecord?)
    }
    let date: Date
    let content: Content
}

struct LockProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LockEntry {
        let path = "Example" + WidgetFile.lockSuffix
        let record = WidgetRecord(vaultID: UUID(), owner: "", repo: "", branch: "", path: path)
        let ctx = WidgetFileContext(vaultID: nil, repo: "", branch: "", path: path, family: LockFamily(context.family).rawValue)
        if let program = try? ScriptRunner.runLock(script: LockTemplate.starter(title: "Example"), file: ctx) {
            return LockEntry(date: Date(), content: .program(program, record: record))
        }
        return LockEntry(date: Date(), content: .noFile)
    }

    func snapshot(for configuration: SelectLockFileIntent, in context: Context) async -> LockEntry {
        if context.isPreview && !WidgetStore.shared.load().contains(where: \.isLock) { return placeholder(in: context) }
        return await Self.makeEntry(id: configuration.file?.id, family: context.family, fetch: false)
    }

    func timeline(for configuration: SelectLockFileIntent, in context: Context) async -> Timeline<LockEntry> {
        let entry = await Self.makeEntry(id: configuration.file?.id, family: context.family, fetch: true)
        var minutes = Provider.defaultRefreshMinutes
        if case .program(let p, _) = entry.content, let m = p.refreshAfterMinutes { minutes = min(max(m, 5), 1440) }
        return Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(minutes * 60)))
    }

    static func makeEntry(id: String?, family: WidgetFamily, fetch: Bool) async -> LockEntry {
        let now = Date()
        let record: WidgetRecord
        switch RecordLoader.pick(id: id, lock: true) {
        case .record(let r): record = await RecordLoader.refreshed(r, now: now, fetch: fetch)
        case .needsConfig: return LockEntry(date: now, content: .needsConfig)
        case .noFile: return LockEntry(date: now, content: .noFile)
        case .gone: return LockEntry(date: now, content: .error("File gone. Edit the widget to pick another.", record: nil))
        }
        guard let script = record.script else {
            return LockEntry(date: now, content: .error("Open Gitsidian to load this widget.", record: record))
        }
        let ctx = WidgetFileContext(vaultID: record.vaultID, repo: record.fullName, branch: record.branch,
                                    path: record.path, family: LockFamily(family).rawValue)
        let result = await Task.detached(priority: .userInitiated) {
            Result { try ScriptRunner.runLock(script: script, file: ctx, now: now) }
        }.value
        switch result {
        case .success(let program): return LockEntry(date: now, content: .program(program, record: record))
        case .failure(let error): return LockEntry(date: now, content: .error(error.localizedDescription, record: record))
        }
    }
}

struct LockWidgetView: View {
    let entry: LockEntry
    @Environment(\.widgetFamily) private var widgetFamily

    private var family: LockFamily { LockFamily(widgetFamily) }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                if family == .circular && wantsBackground { AccessoryWidgetBackground() } else { Color.clear }
            }
    }

    private var wantsBackground: Bool {
        if case .program(let p, _) = entry.content { return p.circular?.wantsBackground ?? true }
        return true
    }

    @ViewBuilder private var content: some View {
        switch entry.content {
        case .program(let program, let record):
            LockProgramView(program: program, family: family)
                .widgetURL(DeepLink.open(vault: record.vaultID, path: record.path))
        case .noFile:
            status("No Lock Screen file", detail: "Add a .gitsidian.lock file in Gitsidian.", symbol: "lock.square")
        case .needsConfig:
            status("Choose a file", detail: "Edit the widget to pick one.", symbol: "hand.tap")
        case .error(let message, let record):
            status("Widget error", detail: message, symbol: "exclamationmark.triangle")
                .widgetURL(record.flatMap { DeepLink.open(vault: $0.vaultID, path: $0.path) })
        }
    }

    @ViewBuilder private func status(_ title: String, detail: String, symbol: String) -> some View {
        switch family {
        case .inline:
            Label(title, systemImage: symbol)
        case .circular:
            Image(systemName: symbol).font(.title2)
        case .rectangular:
            VStack(alignment: .leading, spacing: 0) {
                Label(title, systemImage: symbol).font(.headline).lineLimit(1)
                Text(detail).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
