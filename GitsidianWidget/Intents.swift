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
        WidgetStore.shared.load().filter { identifiers.contains($0.id) }.map(WidgetFileEntity.init)
    }

    func entities(matching string: String) async throws -> [WidgetFileEntity] {
        WidgetStore.shared.load().filter { $0.path.localizedCaseInsensitiveContains(string) }.map(WidgetFileEntity.init)
    }

    func suggestedEntities() async throws -> [WidgetFileEntity] {
        WidgetStore.shared.load().map(WidgetFileEntity.init)
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
        WidgetStore.shared.markSkipFetchOnce()
        WidgetCenter.shared.reloadTimelines(ofKind: GitsidianWidget.kind)
        return .result()
    }
}
