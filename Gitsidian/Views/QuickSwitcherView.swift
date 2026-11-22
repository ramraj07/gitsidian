import SwiftUI

/// Obsidian's "Quick switcher": fuzzy-find a file by name, or create a note with the typed name.
struct QuickSwitcherView: View {
    let session: VaultSession
    var onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private func name(_ p: String) -> String {
        let n = (p as NSString).lastPathComponent
        return FileKind(path: p) == .markdown ? (n as NSString).deletingPathExtension : n
    }

    private var results: [String] {
        let files = session.visibleFiles
        if query.isEmpty {
            let recent = session.recent.filter { files.contains($0) }
            return recent + files.filter { !recent.contains($0) }.prefix(max(0, 50 - recent.count))
        }
        return files.compactMap { f -> (String, Int)? in
            let s = max(Fuzzy.score(query, name(f)).map { $0 + 15 } ?? Int.min, Fuzzy.score(query, f) ?? Int.min)
            return s == Int.min ? nil : (f, s)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(60)
        .map(\.0)
    }

    var body: some View {
        NavigationStack {
            List {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !results.contains(where: { name($0).lowercased() == trimmed.lowercased() }) {
                    Button {
                        onCreate(trimmed); dismiss()
                    } label: {
                        Label("Create \"\(trimmed)\"", systemImage: "plus.circle").foregroundStyle(Color.accentColor)
                    }
                }
                ForEach(results, id: \.self) { p in
                    Button {
                        session.open(p); dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name(p)).foregroundStyle(.primary)
                            let dir = (p as NSString).deletingLastPathComponent
                            if !dir.isEmpty { Text(dir).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find or create a note…")
            .autocorrectionDisabled()
            .onSubmit(of: .search) {
                if let first = results.first { session.open(first); dismiss() }
                else if !query.isEmpty { onCreate(query); dismiss() }
            }
            .navigationTitle("Go to file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

struct SearchView: View {
    let session: VaultSession
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SearchHit] = []

    var body: some View {
        NavigationStack {
            List(hits, id: \.path) { hit in
                Button {
                    session.open(hit.path); dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(((hit.path as NSString).lastPathComponent as NSString).deletingPathExtension).font(.headline).foregroundStyle(.primary)
                        Text(hit.path).font(.caption2).foregroundStyle(.secondary)
                        ForEach(hit.snippets, id: \.self) { s in
                            Text(highlighted(s)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if query.count >= 2 && hits.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search all files")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                hits = session.search(query)
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func highlighted(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        if let r = a.range(of: query, options: .caseInsensitive) {
            a[r].foregroundColor = Color.primary
            a[r].backgroundColor = Color.yellow.opacity(0.35)
        }
        return a
    }
}
