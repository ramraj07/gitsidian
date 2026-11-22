import WidgetKit

enum WidgetReload {
    static let kind = "GitsidianWidget"   // must match the extension's widget kind

    static func all() { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
}
