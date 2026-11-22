import SwiftUI

@main
struct GitsidianApp: App {
    @State private var app: AppModel

    init() {
        Pref.register()
        _app = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(.accentColor)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.token == nil {
            LoginView()
        } else if let session = app.session {
            VaultView(session: session)
                .id(session.config.id)
        } else {
            VaultListView()
        }
    }
}
