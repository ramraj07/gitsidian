import SwiftUI

/// Transient UI state for the vault screen, shared with the file explorer drawer.
@Observable @MainActor
final class VaultUI {
    var showSidebar = false
    var showSwitcher = false
    var showSearch = false
    var showSettings = false
    var expanded: Set<String> = []

    var renaming: String?
    var renameText = ""
    var newNoteFolder: String?
    var newNoteName = ""
    var newFolderParent: String?
    var newFolderName = ""
    var moving: String?
    var deleting: String?

    func startRename(_ path: String) {
        let name = (path as NSString).lastPathComponent
        renameText = FileKind(path: path) == .markdown ? (name as NSString).deletingPathExtension : name
        renaming = path
    }
    func startNewNote(in folder: String) { newNoteName = ""; newNoteFolder = folder }
    func startNewFolder(in parent: String) { newFolderName = ""; newFolderParent = parent }
}

extension Binding where Value == Bool {
    init<T>(present source: Binding<T?>) {
        self.init(get: { source.wrappedValue != nil }, set: { if !$0 { source.wrappedValue = nil } })
    }
}

struct VaultView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var session: VaultSession
    @State private var ui = VaultUI()
    @State private var reading = Pref.d.bool(forKey: Pref.defaultReading)

    var body: some View {
        Group {
            if session.isCloned { shell } else { CloneView(session: session) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: session.syncInBackground()
            case .active: if Pref.d.bool(forKey: Pref.syncOnOpen) { Task { await session.sync() } }
            default: break
            }
        }
    }

    private var currentFolder: String {
        guard let c = session.currentPath else { return "" }
        return (c as NSString).deletingLastPathComponent
    }

    private var shell: some View {
        GeometryReader { geo in
            let w = min(geo.size.width * 0.86, 360)
            ZStack(alignment: .leading) {
                NavigationStack {
                    main
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { toolbar }
                        .toolbarBackground(.visible, for: .bottomBar)
                }
                if ui.showSidebar {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .onTapGesture { ui.showSidebar = false }
                        .transition(.opacity)
                }
                FileExplorerView(session: session, ui: ui)
                    .frame(width: w)
                    .background(Color(.systemBackground).shadow(radius: ui.showSidebar ? 12 : 0).ignoresSafeArea())
                    .offset(x: ui.showSidebar ? 0 : -w - 16)
                    .gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.width < -60 { ui.showSidebar = false } })
                if !ui.showSidebar {
                    Color.clear
                        .frame(width: 18)
                        .contentShape(Rectangle())
                        .padding(.top, 110)
                        .gesture(DragGesture(minimumDistance: 15).onEnded { if $0.translation.width > 50 { ui.showSidebar = true } })
                }
            }
            .animation(.snappy(duration: 0.25), value: ui.showSidebar)
        }
        .sheet(isPresented: $ui.showSwitcher) {
            QuickSwitcherView(session: session) { name in
                if let p = session.createNote(in: currentFolder, name: name) { session.open(p); reading = false }
            }
        }
        .sheet(isPresented: $ui.showSearch) { SearchView(session: session) }
        .sheet(isPresented: $ui.showSettings) { SettingsView(session: session) }
        .sheet(isPresented: Binding(present: $ui.moving)) {
            if let p = ui.moving { MoveSheet(session: session, path: p) }
        }
        .alert("Rename", isPresented: Binding(present: $ui.renaming)) {
            TextField("Name", text: $ui.renameText)
            Button("Rename") { if let p = ui.renaming { _ = session.rename(p, to: ui.renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New note", isPresented: Binding(present: $ui.newNoteFolder)) {
            TextField("Untitled", text: $ui.newNoteName)
            Button("Create") {
                let folder = ui.newNoteFolder ?? ""
                let name = ui.newNoteName.trimmingCharacters(in: .whitespaces)
                if let p = session.createNote(in: folder, name: name.isEmpty ? nil : name) {
                    session.open(p); reading = false; ui.showSidebar = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ui.newNoteFolder.map { $0.isEmpty ? "In vault root" : "In \($0)" } ?? "")
        }
        .alert("New folder", isPresented: Binding(present: $ui.newFolderParent)) {
            TextField("Untitled", text: $ui.newFolderName)
            Button("Create") {
                let name = ui.newFolderName.trimmingCharacters(in: .whitespaces)
                if let p = session.createFolder(in: ui.newFolderParent ?? "", name: name.isEmpty ? "Untitled" : name) {
                    ui.expanded.insert(p)
                    var parent = (p as NSString).deletingLastPathComponent
                    while !parent.isEmpty { ui.expanded.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Empty folders aren't stored in git until they contain a file.")
        }
        .confirmationDialog("Delete?", isPresented: Binding(present: $ui.deleting), titleVisibility: .visible, presenting: ui.deleting) { p in
            Button("Delete \((p as NSString).lastPathComponent)", role: .destructive) { session.delete(p) }
        } message: { _ in
            Text("It will be removed from the repository on the next sync (still recoverable from git history).")
        }
        .alert("Gitsidian", isPresented: Binding(present: $session.notice)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.notice ?? "")
        }
    }

    @ViewBuilder private var main: some View {
        if let path = session.currentPath {
            NoteView(session: session, path: path, reading: reading)
                .id(path)
        } else {
            ContentUnavailableView {
                Label("No file is open", systemImage: "doc.text")
            } actions: {
                Button("Open file browser") { ui.showSidebar = true }
                Button("Go to file") { ui.showSwitcher = true }
                Button("Create new note") { ui.startNewNote(in: "") }
            }
        }
    }

    private var title: String {
        guard let p = session.currentPath else { return session.config.displayName }
        let name = (p as NSString).lastPathComponent
        return FileKind(path: p) == .markdown ? (name as NSString).deletingPathExtension : name
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { ui.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
        }
        ToolbarItem(placement: .principal) {
            Button { if let p = session.currentPath { ui.startRename(p) } } label: {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
            }
            .buttonStyle(.plain)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let p = session.currentPath, FileKind(path: p) == .markdown {
                Button { reading.toggle() } label: { Image(systemName: reading ? "pencil" : "book") }
            }
            SyncButton(session: session)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { session.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!session.canGoBack)
            Button { session.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!session.canGoForward)
            Spacer()
            Button { ui.showSwitcher = true } label: { Image(systemName: "magnifyingglass") }
            Spacer()
            Button { ui.startNewNote(in: currentFolder) } label: { Image(systemName: "square.and.pencil") }
            Spacer()
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { Task { await session.sync() } } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
            Button { ui.showSearch = true } label: { Label("Search in all files", systemImage: "text.magnifyingglass") }
            if let p = session.currentPath {
                Section {
                    Button { ui.startRename(p) } label: { Label("Rename", systemImage: "pencil") }
                    Button { ui.moving = p } label: { Label("Move to…", systemImage: "folder") }
                    ShareLink(item: session.url(p)) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { ui.deleting = p } label: { Label("Delete", systemImage: "trash") }
                }
            }
            Section {
                Button { ui.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                Button { app.closeVault() } label: { Label("Switch vault", systemImage: "books.vertical") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

struct SyncButton: View {
    let session: VaultSession

    var body: some View {
        Menu {
            Section {
                switch session.status {
                case .syncing(let msg): Text(msg)
                case .error(let msg): Text("Sync failed: \(msg)")
                case .idle: Text(session.hasLocalEdits ? "\(max(session.pendingCount, 1)) change(s) waiting to sync" : "Everything is synced")
                }
                if let last = session.lastSync { Text("Last synced \(last.formatted(.relative(presentation: .named)))") }
                Text("\(session.config.fullName) · \(session.config.branch)")
            }
            Button { Task { await session.sync() } } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(session.isSyncing)
        } label: {
            switch session.status {
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath").symbolEffect(.pulse)
            case .error:
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.red)
            case .idle:
                Image(systemName: session.hasLocalEdits ? "icloud.and.arrow.up" : "checkmark.icloud")
            }
        }
    }
}

struct CloneView: View {
    @Environment(AppModel.self) private var app
    let session: VaultSession

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical.fill").font(.system(size: 48)).foregroundStyle(Color.accentColor)
            Text(session.config.fullName).font(.title3.bold())
            if let err = session.cloneError {
                Text(err).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try again") { Task { await session.clone() } }.buttonStyle(.borderedProminent)
            } else {
                ProgressView()
                Text(session.cloneProgress ?? "Preparing…").foregroundStyle(.secondary)
            }
            Button("Back to vaults") { app.closeVault() }.padding(.top, 20)
        }
        .padding()
    }
}
