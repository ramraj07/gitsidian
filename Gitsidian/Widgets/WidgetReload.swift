import WidgetKit

enum WidgetReload {
    static let kind = "GitsidianWidget"          // must match the extension's widget kinds
    static let lockKind = "GitsidianLockWidget"

    static func all() {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        WidgetCenter.shared.reloadTimelines(ofKind: lockKind)
    }
}
