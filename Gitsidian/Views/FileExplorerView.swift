import SwiftUI

struct FileExplorerView: View {
    @Environment(AppModel.self) private var app
    let session: VaultSession
    @Bindable var ui: VaultUI

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(session.config.displayName).font(.title3.bold()).lineLimit(1)
                Spacer()
                Button { ui.startNewNote(in: "") } label: { Image(systemName: "square.and.pencil") }
                Button { ui.startNewFolder(in: "") } label: { Image(systemName: "folder.badge.plus") }
                Button { ui.expanded.removeAll() } label: { Image(systemName: "arrow.up.and.down.text.horizontal") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            List {
                ForEach(session.tree.children ?? []) { node in
                    FileRow(node: node, session: session, ui: ui)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 34)
            .refreshable { await session.sync() }
            Divider()
            HStack {
                Button { app.closeVault() } label: { Label("Vaults", systemImage: "books.vertical") }
                Spacer()
                Button { ui.showSidebar = false; ui.showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onChange(of: ui.showSidebar) { _, open in
            guard open, let c = session.currentPath else { return }
            var dir = (c as NSString).deletingLastPathComponent
            while !dir.isEmpty { ui.expanded.insert(dir); dir = (dir as NSString).deletingLastPathComponent }
        }
    }
}

struct FileRow: View {
    let node: FileNode
    let session: VaultSession
    @Bindable var ui: VaultUI

    private var isExpanded: Binding<Bool> {
        Binding(get: { ui.expanded.contains(node.path) },
                set: { if $0 { ui.expanded.insert(node.path) } else { ui.expanded.remove(node.path) } })
    }

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.children ?? []) { child in
                    FileRow(node: child, session: session, ui: ui)
                }
            } label: {
                Button { isExpanded.wrappedValue.toggle() } label: {
                    Label(node.name, systemImage: isExpanded.wrappedValue ? "folder.fill" : "folder")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { ui.startNewNote(in: node.path) } label: { Label("New note", systemImage: "square.and.pencil") }
                    Button { ui.startNewFolder(in: node.path) } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    Button { ui.startNewWidget(in: node.path) } label: { Label("New widget", systemImage: "square.grid.2x2") }
                    Button { ui.startNewWidget(in: node.path, lock: true) } label: { Label("New Lock Screen widget", systemImage: "lock.square") }
                    Divider()
                    Button { ui.startRename(node.path) } label: { Label("Rename", systemImage: "pencil") }
                    Button { ui.moving = node.path } label: { Label("Move to…", systemImage: "folder") }
                    Button(role: .destructive) { ui.deleting = node.path } label: { Label("Delete", systemImage: "trash") }
                }
            }
        } else {
            Button {
                session.open(node.path)
                ui.showSidebar = false
            } label: {
                Label {
                    HStack {
                        Text(node.displayName).lineLimit(1)
                        if node.isWidget || node.isLockWidget {
                            Spacer()
                            Text(node.isLockWidget ? "LOCK" : "WIDGET").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                        } else if !node.isMarkdown {
                            Spacer()
                            Text(node.ext.uppercased()).font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                        }
                    }
                } icon: {
                    Image(systemName: FileKind(path: node.path).symbol).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .listRowBackground(session.currentPath == node.path ? Color.accentColor.opacity(0.15) : Color.clear)
            .contextMenu {
                Button { ui.startRename(node.path) } label: { Label("Rename", systemImage: "pencil") }
                Button { ui.moving = node.path } label: { Label("Move to…", systemImage: "folder") }
                ShareLink(item: session.url(node.path)) { Label("Share", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { ui.deleting = node.path } label: { Label("Delete", systemImage: "trash") }
            }
            .swipeActions {
                Button(role: .destructive) { ui.deleting = node.path } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

struct MoveSheet: View {
    let session: VaultSession
    let path: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(session.tree.allFolders.filter { $0.path != path && !$0.path.hasPrefix(path + "/") }) { folder in
                    Button {
                        let name = (path as NSString).lastPathComponent
                        _ = session.move(path, to: folder.path.isEmpty ? name : "\(folder.path)/\(name)")
                        dismiss()
                    } label: {
                        Label(folder.path.isEmpty ? "/ (vault root)" : folder.path, systemImage: "folder")
                    }
                    .disabled(folder.path == (path as NSString).deletingLastPathComponent)
                }
            }
            .navigationTitle("Move \((path as NSString).lastPathComponent)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
