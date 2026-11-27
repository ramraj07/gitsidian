import WidgetKit
import SwiftUI

struct GitsidianWidget: Widget {
    static let kind = "GitsidianWidget"   // WidgetReload.kind in the app

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectWidgetFileIntent.self, provider: Provider()) { entry in
            GitsidianWidgetView(entry: entry)
        }
        .configurationDisplayName("Vault widget")
        .description("Runs a .gitsidian.widget file from one of your vaults.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

struct WidgetEntry: TimelineEntry {
    enum Content {
        case program(WidgetProgram, page: Int, record: WidgetRecord)
        case noFile
        case needsConfig
        case error(String, record: WidgetRecord?)
    }
    let date: Date
    let content: Content
}

struct Provider: AppIntentTimelineProvider {
    static let defaultRefreshMinutes: Double = 30

    func placeholder(in context: Context) -> WidgetEntry {
        let record = WidgetRecord(vaultID: UUID(), owner: "", repo: "", branch: "", path: "Example" + WidgetFile.suffix)
        let ctx = WidgetFileContext(vaultID: nil, repo: "", branch: "", path: record.path, family: Self.family(context.family))
        do {
            let program = try ScriptRunner.run(script: WidgetTemplate.starter(title: "Example"), file: ctx)
            return WidgetEntry(date: Date(), content: .program(program, page: 1, record: record))
        } catch {
            return WidgetEntry(date: Date(), content: .noFile)
        }
    }

    func snapshot(for configuration: SelectWidgetFileIntent, in context: Context) async -> WidgetEntry {
        if context.isPreview && WidgetStore.shared.load().isEmpty { return placeholder(in: context) }
        return await Self.makeEntry(id: configuration.file?.id, family: context.family, fetch: false)
    }

    func timeline(for configuration: SelectWidgetFileIntent, in context: Context) async -> Timeline<WidgetEntry> {
        let fetch = !(configuration.file.map { WidgetStore.shared.consumeSkipFetchOnce($0.id) } ?? false)
        let entry = await Self.makeEntry(id: configuration.file?.id, family: context.family, fetch: fetch)
        var minutes = Self.defaultRefreshMinutes
        if case .program(let p, _, _) = entry.content, let m = p.refreshAfterMinutes { minutes = min(max(m, 5), 1440) }
        return Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(minutes * 60)))
    }

    static func family(_ f: WidgetFamily) -> String {
        switch f {
        case .systemSmall: return "small"
        case .systemMedium: return "medium"
        case .systemLarge: return "large"
        case .systemExtraLarge: return "extraLarge"
        default: return "medium"
        }
    }

    /// Picks the configured file, refreshes it from GitHub, runs it.
    static func makeEntry(id: String?, family: WidgetFamily, fetch: Bool) async -> WidgetEntry {
        let store = WidgetStore.shared
        let now = Date()
        let record: WidgetRecord
        switch RecordLoader.pick(id: id, lock: false) {
        case .record(let r): record = await RecordLoader.refreshed(r, now: now, fetch: fetch)
        case .needsConfig: return WidgetEntry(date: now, content: .needsConfig)
        case .noFile: return WidgetEntry(date: now, content: .noFile)
        case .gone: return WidgetEntry(date: now, content: .error("This widget file is no longer in any vault. Edit the widget to pick another.", record: nil))
        }

        guard let script = record.script else {
            return WidgetEntry(date: now, content: .error("Open Gitsidian to load this widget.", record: record))
        }
        let ctx = WidgetFileContext(vaultID: record.vaultID, repo: record.fullName, branch: record.branch,
                                    path: record.path, family: Self.family(family))
        let result = await Task.detached(priority: .userInitiated) {
            Result { try ScriptRunner.run(script: script, file: ctx, now: now) }
        }.value
        switch result {
        case .success(let program):
            return WidgetEntry(date: now, content: .program(program, page: program.clampedPageNumber(store.pageNumber(record.id)), record: record))
        case .failure(let error):
            return WidgetEntry(date: now, content: .error(error.localizedDescription, record: record))
        }
    }
}

struct GitsidianWidgetView: View {
    let entry: WidgetEntry

    var body: some View {
        Group {
            switch entry.content {
            case .program(let program, let page, let record):
                ProgramView(program: program, pageNumber: page)
                    .environment(\.widgetPageButton, pageButtons(record.id))
                    .widgetURL(DeepLink.open(vault: record.vaultID, path: record.path))
            case .noFile:
                StatusView(title: "No widget file yet", detail: "Add a .gitsidian.widget file to a vault in Gitsidian, then edit this widget to pick it.", symbol: "square.grid.2x2")
            case .needsConfig:
                StatusView(title: "Choose a widget file", detail: "Long-press › Edit Widget › File.", symbol: "hand.tap")
            case .error(let message, let record):
                StatusView(title: "Widget error", detail: String(message.prefix(200)), symbol: "exclamationmark.triangle")
                    .widgetURL(record.flatMap { DeepLink.open(vault: $0.vaultID, path: $0.path) })
            }
        }
        .padding(12)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func pageButtons(_ id: String) -> PageButtonBuilder {
        PageButtonBuilder { label, page in
            AnyView(
                Button(intent: PageIntent(page: page, widgetID: id)) {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.tint.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
            )
        }
    }
}

/// Finds the file a widget instance shows and keeps it fresh from GitHub. Shared by the Home
/// Screen widget (`*.gitsidian.widget`) and the Lock Screen widget (`*.gitsidian.lock`).
enum RecordLoader {
    enum Pick { case record(WidgetRecord), noFile, needsConfig, gone }

    /// Only ever the configured file. An unconfigured widget uses the sole file of its kind if there
    /// is exactly one, and otherwise asks to be configured, never "whichever changed last" (that made widgets swap).
    static func pick(id: String?, lock: Bool) -> Pick {
        let store = WidgetStore.shared
        if let id {
            guard let r = store.record(id: id), r.isLock == lock else { return .gone }
            return .record(r)
        }
        let all = store.load().filter { $0.isLock == lock }
        if all.count > 1 { return .needsConfig }
        return all.first.map(Pick.record) ?? .noFile
    }

    /// Offline or rate-limited: keeps the cached script.
    static func refreshed(_ record: WidgetRecord, now: Date, fetch: Bool) async -> WidgetRecord {
        var record = record
        if fetch, let token = Keychain.read(),
           case .found(let sha, let text)? = try? await RemoteFile.fetch(record, token: token), sha != record.baseSha {
            record.script = text
            record.baseSha = sha
            record.updatedAt = now
            WidgetStore.shared.update(record)
        }
        return record
    }
}
