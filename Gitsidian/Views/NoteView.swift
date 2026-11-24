import SwiftUI
import PDFKit

struct NoteView: View {
    let session: VaultSession
    let path: String
    let reading: Bool

    var body: some View {
        switch FileKind(path: path) {
        case .markdown: TextFileView(session: session, path: path, markdown: true, reading: reading)
        case .text: TextFileView(session: session, path: path, markdown: false, reading: false)
        case .widget: WidgetFileView(session: session, path: path)
        case .image: ImageFileView(url: session.url(path))
        case .pdf: PDFFileView(url: session.url(path))
        case .other:
            ContentUnavailableView {
                Label((path as NSString).lastPathComponent, systemImage: "doc")
            } description: {
                Text("This file type can't be previewed.")
            } actions: {
                ShareLink(item: session.url(path)) { Label("Open in…", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

/// Holds the editor's text and saves it to disk shortly after typing stops.
@Observable @MainActor
final class NoteBuffer {
    let session: VaultSession
    let path: String
    var text: String
    private var saved: String
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(session: VaultSession, path: String) {
        self.session = session
        self.path = path
        let t = session.readText(path)
        text = t
        saved = t
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        guard text != saved, session.exists(path) else { return }
        session.writeText(path, text)
        saved = text
    }

    /// Sync rewrote the file: take the new contents unless the user has unsaved typing.
    func reloadIfClean() {
        guard text == saved else { return }
        let t = session.readText(path)
        guard t != text else { return }
        saved = t
        text = t
    }
}

struct TextFileView: View {
    let session: VaultSession
    let path: String
    let markdown: Bool
    let reading: Bool
    @State private var buffer: NoteBuffer
    @State private var flushId = UUID()
    @State private var anchor: AnchorRequest?
    @AppStorage(Pref.editorFontSize) private var fontSize = 17.0

    init(session: VaultSession, path: String, markdown: Bool, reading: Bool) {
        self.session = session
        self.path = path
        self.markdown = markdown
        self.reading = reading
        _buffer = State(initialValue: NoteBuffer(session: session, path: path))
    }

    var body: some View {
        Group {
            if markdown && reading {
                MarkdownReader(text: buffer.text, path: path, session: session, onToggleTask: toggleTask, anchor: anchor)
            } else {
                MarkdownEditor(
                    text: $buffer.text,
                    fontSize: CGFloat(fontSize),
                    highlight: markdown,
                    autoFocus: buffer.text.isEmpty,
                    suggestions: { [session] q in session.linkSuggestions(q) },
                    openLink: { [session, path] t in session.openLink(t, from: path) },
                    scrollTo: anchor.flatMap { a in NoteAnchor.line(in: buffer.text, subpath: a.subpath).map { (line: $0, token: a.token) } }
                )
            }
        }
        .onChange(of: buffer.text) { buffer.scheduleSave() }
        .onAppear {
            let b = buffer
            session.registerFlusher(flushId) { b.save() }
            consumeAnchor()
        }
        .onChange(of: session.anchorRequest) { consumeAnchor() }
        .onDisappear {
            buffer.save()
            session.unregisterFlusher(flushId)
        }
        .onChange(of: session.diskVersion) {
            if session.changedOnDisk.contains(path) { buffer.reloadIfClean() }
        }
    }

    private func consumeAnchor() {
        guard let r = session.anchorRequest, r.path == path else { return }
        session.anchorRequest = nil
        anchor = r
    }

    private func toggleTask(_ line: Int) {
        var lines = buffer.text.components(separatedBy: "\n")
        guard line < lines.count else { return }
        let l = lines[line]
        if let r = l.range(of: "[ ]") {
            lines[line] = l.replacingCharacters(in: r, with: "[x]")
        } else if let r = l.range(of: "[x]") ?? l.range(of: "[X]") ?? l.range(of: "[/]") ?? l.range(of: "[-]") {
            lines[line] = l.replacingCharacters(in: r, with: "[ ]")
        }
        buffer.text = lines.joined(separator: "\n")
        buffer.save()
    }
}

struct ImageFileView: View {
    let url: URL
    @State private var scale: CGFloat = 1

    var body: some View {
        if let img = UIImage(contentsOfFile: url.path) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: UIScreen.main.bounds.width * scale)
                    .gesture(MagnifyGesture().onChanged { scale = max(1, min(6, $0.magnification)) })
                    .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
            }
        } else {
            ContentUnavailableView("Can't display image", systemImage: "photo")
        }
    }
}

struct PDFFileView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(url: url)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
}
