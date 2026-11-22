import SwiftUI

struct VaultListView: View {
    @Environment(AppModel.self) private var app
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var removing: VaultConfig?

    var body: some View {
        NavigationStack {
            List {
                if app.vaults.isEmpty {
                    ContentUnavailableView {
                        Label("No vaults yet", systemImage: "books.vertical")
                    } description: {
                        Text("Open a GitHub repository to start.")
                    } actions: {
                        Button("Open repository") { showPicker = true }.buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(app.vaults) { v in
                    Button { app.open(v) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "books.vertical").foregroundStyle(Color.accentColor).font(.title3)
                            VStack(alignment: .leading) {
                                Text(v.displayName).font(.headline).foregroundStyle(.primary)
                                Text("\(v.fullName) · \(v.branch)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { removing = v }
                    }
                }
            }
            .navigationTitle("Vaults")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showPicker) { RepoPickerView() }
            .sheet(isPresented: $showSettings) { SettingsView(session: nil) }
            .confirmationDialog("Remove vault?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { v in
                Button("Remove local copy", role: .destructive) { app.remove(v) }
            } message: { _ in
                Text("Deletes the copy on this iPhone. Anything not yet synced is lost. The GitHub repository is not touched.")
            }
        }
    }
}

struct RepoPickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var repos: [GitHubRepo] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?

    private var filtered: [GitHubRepo] {
        query.isEmpty ? repos : repos.filter { $0.full_name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                if query.contains("/"), !repos.contains(where: { $0.full_name.lowercased() == query.lowercased() }) {
                    let parts = query.split(separator: "/", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        NavigationLink("Open \(query)") { BranchPickerView(owner: parts[0], repo: parts[1], defaultBranch: nil, onDone: { dismiss() }) }
                    }
                }
                ForEach(filtered) { r in
                    NavigationLink {
                        BranchPickerView(owner: r.owner.login, repo: r.name, defaultBranch: r.default_branch, onDone: { dismiss() })
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(r.full_name).font(.body)
                                if r.private { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                            }
                            if let d = r.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                }
            }
            .overlay { if loading { ProgressView() } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or type owner/repo")
            .textInputAutocapitalization(.never)
            .navigationTitle("Open repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                guard let client = app.client else { return }
                do { repos = try await client.allRepos() } catch { self.error = error.localizedDescription }
                loading = false
            }
        }
    }
}

struct BranchPickerView: View {
    @Environment(AppModel.self) private var app
    let owner: String
    let repo: String
    let defaultBranch: String?
    var onDone: () -> Void
    @State private var branches: [String] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            Section("Branch") {
                ForEach(branches, id: \.self) { b in
                    Button {
                        app.addVault(owner: owner, repo: repo, branch: b)
                        onDone()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.branch")
                            Text(b)
                            Spacer()
                            if b == defaultBranch { Text("default").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle(repo)
        .overlay { if branches.isEmpty && error == nil { ProgressView() } }
        .task {
            guard let client = app.client else { return }
            do {
                let names = try await client.branches("\(owner)/\(repo)").map(\.name)
                if names.isEmpty {
                    branches = [defaultBranch ?? "main"] // empty repo: we'll initialize it
                } else {
                    branches = names.sorted { a, b in a == defaultBranch ? true : b == defaultBranch ? false : a < b }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
