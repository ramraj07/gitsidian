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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
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
        default: return AccessoryFamily(f)?.rawValue ?? "medium"
        }
    }

    /// Picks the configured file (default: the most recently changed), refreshes it from GitHub, runs it.
    static func makeEntry(id: String?, family: WidgetFamily, fetch: Bool) async -> WidgetEntry {
        let store = WidgetStore.shared
        let now = Date()
        // Only ever the configured file. An unconfigured widget uses the sole file if there is exactly
        // one, and otherwise asks to be configured, never "whichever changed last" (that made widgets swap).
        let picked: WidgetRecord?
        if let id {
            picked = store.record(id: id)
        } else {
            let all = store.load()
            picked = all.count == 1 ? all[0] : nil
            if all.count > 1 { return WidgetEntry(date: now, content: .needsConfig) }
        }
        guard var record = picked else {
            return WidgetEntry(date: now, content: id == nil ? .noFile : .error("This widget file is no longer in any vault. Edit the widget to pick another.", record: nil))
        }

        if fetch, let token = Keychain.read() {
            // Offline or rate-limited: keep showing the cached script.
            if case .found(let sha, let text)? = try? await RemoteFile.fetch(record, token: token), sha != record.baseSha {
                record.script = text
                record.baseSha = sha
                record.updatedAt = now
                store.update(record)
            }
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

extension AccessoryFamily {
    init?(_ f: WidgetFamily) {
        switch f {
        case .accessoryRectangular: self = .rectangular
        case .accessoryCircular: self = .circular
        case .accessoryInline: self = .inline
        default: return nil
        }
    }
}

struct GitsidianWidgetView: View {
    let entry: WidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let accessory = AccessoryFamily(family) {
            AccessoryWidgetView(entry: entry, family: accessory)
        } else {
            homeScreen
        }
    }

    private var homeScreen: some View {
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

/// Lock Screen: compact layout, no pager or buttons; a tap opens the file.
struct AccessoryWidgetView: View {
    let entry: WidgetEntry
    let family: AccessoryFamily

    var body: some View {
        Group {
            switch entry.content {
            case .program(let program, _, let record):
                AccessoryProgramView(program: program, family: family)
                    .widgetURL(DeepLink.open(vault: record.vaultID, path: record.path))
            case .noFile:
                status("No widget file", detail: "Add a .gitsidian.widget file in Gitsidian.", symbol: "square.grid.2x2")
            case .needsConfig:
                status("Choose a file", detail: "Edit the widget to pick one.", symbol: "hand.tap")
            case .error(let message, let record):
                status("Widget error", detail: message, symbol: "exclamationmark.triangle")
                    .widgetURL(record.flatMap { DeepLink.open(vault: $0.vaultID, path: $0.path) })
            }
        }
        .containerBackground(for: .widget) {
            if family == .circular { AccessoryWidgetBackground() } else { Color.clear }
        }
    }

    @ViewBuilder
    private func status(_ title: String, detail: String, symbol: String) -> some View {
        switch family {
        case .inline:
            Label(title, systemImage: symbol)
        case .circular:
            Image(systemName: symbol).font(.title2)
        case .rectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(title, systemImage: symbol).font(.headline).lineLimit(1)
                Text(detail).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
