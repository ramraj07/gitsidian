import AppIntents
import WidgetKit

/// A `*.gitsidian.widget` file as offered in "Edit Widget". The list is what the app last
/// saw in each vault (WidgetStore, in the App Group).
struct WidgetFileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Widget file"
    static var defaultQuery = WidgetFileQuery()

    let id: String
    let name: String
    let location: String

    init(_ r: WidgetRecord) {
        id = r.id
        name = r.name
        location = r.folder.isEmpty ? r.fullName : "\(r.fullName) · \(r.folder)"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(location)")
    }
}

struct WidgetFileQuery: EntityStringQuery {
    func entities(for identifiers: [WidgetFileEntity.ID]) async throws -> [WidgetFileEntity] {
        WidgetStore.shared.load().filter { !$0.isLock && identifiers.contains($0.id) }.map(WidgetFileEntity.init)
    }

    func entities(matching string: String) async throws -> [WidgetFileEntity] {
        WidgetStore.shared.load().filter { !$0.isLock && $0.path.localizedCaseInsensitiveContains(string) }.map(WidgetFileEntity.init)
    }

    func suggestedEntities() async throws -> [WidgetFileEntity] {
        WidgetStore.shared.load().filter { !$0.isLock }.map(WidgetFileEntity.init)
    }
}

/// Widget configuration: which vault file this widget runs.
struct SelectWidgetFileIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose widget file"
    static var description = IntentDescription("Pick a .gitsidian.widget file from one of your vaults.")

    @Parameter(title: "File")
    var file: WidgetFileEntity?

    init() {}
}

/// A `*.gitsidian.lock` file, offered in the Lock Screen widget's "Edit Widget".
struct LockFileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Lock Screen file"
    static var defaultQuery = LockFileQuery()

    let id: String
    let name: String
    let location: String

    init(_ r: WidgetRecord) {
        id = r.id
        name = r.name
        location = r.folder.isEmpty ? r.fullName : "\(r.fullName) · \(r.folder)"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(location)")
    }
}

struct LockFileQuery: EntityStringQuery {
    private var locks: [WidgetRecord] { WidgetStore.shared.load().filter(\.isLock) }

    func entities(for identifiers: [LockFileEntity.ID]) async throws -> [LockFileEntity] {
        locks.filter { identifiers.contains($0.id) }.map(LockFileEntity.init)
    }

    func entities(matching string: String) async throws -> [LockFileEntity] {
        locks.filter { $0.path.localizedCaseInsensitiveContains(string) }.map(LockFileEntity.init)
    }

    func suggestedEntities() async throws -> [LockFileEntity] {
        locks.map(LockFileEntity.init)
    }
}

struct SelectLockFileIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Lock Screen file"
    static var description = IntentDescription("Pick a .gitsidian.lock file from one of your vaults.")

    @Parameter(title: "File")
    var file: LockFileEntity?

    init() {}
}

/// `button(label, {page: n})` and the pager: remember the page and reload in place, no app launch.
struct PageIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch widget page"
    static var isDiscoverable = false

    @Parameter(title: "Page") var page: Int
    @Parameter(title: "Widget") var widgetID: String

    init() {}
    init(page: Int, widgetID: String) {
        self.page = page
        self.widgetID = widgetID
    }

    func perform() async throws -> some IntentResult {
        WidgetStore.shared.setPageNumber(page, widgetID)
        WidgetStore.shared.markSkipFetchOnce(widgetID)
        WidgetCenter.shared.reloadTimelines(ofKind: GitsidianWidget.kind)
        return .result()
    }
}
