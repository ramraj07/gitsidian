import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let session: VaultSession?

    @AppStorage(Pref.autoSyncDelay) private var autoSyncDelay = 30
    @AppStorage(Pref.syncOnOpen) private var syncOnOpen = true
    @AppStorage(Pref.commitTitle) private var commitTitle = "vault backup"
    @AppStorage(Pref.defaultReading) private var defaultReading = false
    @AppStorage(Pref.editorFontSize) private var fontSize = 17.0
    @AppStorage(Pref.readableLineLength) private var readable = true
    @AppStorage(Pref.showHidden) private var showHidden = false
    @AppStorage(Pref.updateLinksOnRename) private var updateLinks = true

    var body: some View {
        NavigationStack {
            Form {
                if let session {
                    Section("Vault") {
                        LabeledContent("Repository", value: session.config.fullName)
                        LabeledContent("Branch", value: session.config.branch)
                        if let last = session.lastSync {
                            LabeledContent("Last sync", value: last.formatted(.relative(presentation: .named)))
                        }
                        LabeledContent("Unsynced changes", value: "\(session.pendingCount)")
                        if case .error(let msg) = session.status {
                            Text(msg).font(.footnote).foregroundStyle(.red)
                        }
                        Button("Sync now") { Task { await session.sync() } }.disabled(session.isSyncing)
                        Button("Switch vault") { dismiss(); app.closeVault() }
                    }
                }
                Section {
                    Picker("Auto-sync after editing", selection: $autoSyncDelay) {
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("Manual only").tag(0)
                    }
                    Toggle("Sync when app opens", isOn: $syncOnOpen)
                    TextField("Commit message", text: $commitTitle)
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Edits are saved locally right away and batched into one commit after you stop editing for this long, and whenever the app goes to the background. Remote changes are merged in; if both sides changed the same lines, your version is kept as a conflict copy.")
                }
                Section("Editor") {
                    Toggle("Open notes in reading view", isOn: $defaultReading)
                    Stepper("Font size: \(Int(fontSize))", value: $fontSize, in: 12...28)
                    Toggle("Readable line length", isOn: $readable)
                }
                Section("Files & links") {
                    Toggle("Show hidden files (.obsidian, …)", isOn: $showHidden)
                        .onChange(of: showHidden) { session?.refreshTree() }
                    Toggle("Update internal links on rename", isOn: $updateLinks)
                }
                Section("Account") {
                    if let login = app.login { LabeledContent("GitHub", value: login) }
                    Button("Sign out", role: .destructive) { dismiss(); app.signOut() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                if app.login == nil, let client = app.client { app.login = try? await client.currentUser().login }
            }
        }
    }
}
