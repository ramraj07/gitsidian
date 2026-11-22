import Foundation

/// UserDefaults keys shared by @AppStorage in views and by the session.
enum Pref {
    static let autoSyncDelay = "autoSyncDelay"       // seconds; 0 = manual only
    static let syncOnOpen = "syncOnOpen"
    static let defaultReading = "defaultReading"
    static let showHidden = "showHidden"
    static let editorFontSize = "editorFontSize"
    static let commitTitle = "commitTitle"
    static let updateLinksOnRename = "updateLinksOnRename"
    static let readableLineLength = "readableLineLength"

    static func register() {
        UserDefaults.standard.register(defaults: [
            autoSyncDelay: 30,
            syncOnOpen: true,
            defaultReading: false,
            showHidden: false,
            editorFontSize: 17.0,
            commitTitle: "vault backup",
            updateLinksOnRename: true,
            readableLineLength: true,
        ])
    }

    static var d: UserDefaults { .standard }
}
