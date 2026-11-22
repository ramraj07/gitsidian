import SwiftUI
import UIKit

/// Reading view: renders a note like Obsidian's reading mode.
struct MarkdownReader: View {
    let text: String
    let path: String
    let session: VaultSession
    var onToggleTask: (Int) -> Void
    @AppStorage(Pref.editorFontSize) private var fontSize = 17.0
    @AppStorage(Pref.readableLineLength) private var readable = true
    @State private var backlinks: [Backlink] = []
    @State private var showBacklinks = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
                    .font(.system(size: fontSize * 1.75, weight: .bold))
                    .padding(.bottom, 14)
                BlocksView(blocks: MarkdownParser.parse(text), session: session, path: path, onToggleTask: onToggleTask)
                backlinksSection.padding(.top, 40)
            }
            .font(.system(size: fontSize))
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: readable ? 720 : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .environment(\.openURL, OpenURLAction { url in handle(url) })
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(150))
            backlinks = session.backlinks(for: path)
        }
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == "gitsidian" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let t = comps?.queryItems?.first(where: { $0.name == "t" })?.value ?? ""
            if url.host == "open" { session.openLink(t, from: path) }
            return .handled
        }
        if url.scheme == nil || url.scheme == "file" {
            let target = (url.path.removingPercentEncoding ?? url.path)
            if !target.isEmpty { session.openLink(target, from: path) }
            return .handled
        }
        return .systemAction
    }

    @ViewBuilder private var backlinksSection: some View {
        if !backlinks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Button { withAnimation { showBacklinks.toggle() } } label: {
                    HStack {
                        Image(systemName: showBacklinks ? "chevron.down" : "chevron.right").font(.caption)
                        Text("Linked mentions").font(.headline)
                        Text("\(backlinks.count)").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                if showBacklinks {
                    ForEach(backlinks, id: \.path) { link in
                        Button { session.open(link.path) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(((link.path as NSString).lastPathComponent as NSString).deletingPathExtension).font(.subheadline.bold())
                                Text(link.line).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct BlocksView: View {
    let blocks: [MDBlock]
    let session: VaultSession
    let path: String
    var onToggleTask: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                BlockView(block: block, session: session, path: path, onToggleTask: onToggleTask)
            }
        }
    }
}

struct BlockView: View {
    let block: MDBlock
    let session: VaultSession
    let path: String
    var onToggleTask: (Int) -> Void
    @State private var expanded = true

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(Inline.attributed(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 12 : 6)
        case .paragraph(let text):
            Text(Inline.attributed(text)).fixedSize(horizontal: false, vertical: true)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(marker == "•" ? Color.accentColor : .secondary).monospacedDigit()
                Text(Inline.attributed(text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 7)
        case .task(let indent, let done, let text, let line):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { if let line { onToggleTask(line) } } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(line == nil)
                Text(Inline.attributed(text))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 7)
        case .quote(let text):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 3)
                BlocksView(blocks: MarkdownParser.parse(text, lineOffset: nil), session: session, path: path, onToggleTask: onToggleTask)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .callout(let type, let title, let body, let folded):
            CalloutView(type: type, title: title, content: body, startFolded: folded, session: session, path: path, onToggleTask: onToggleTask)
        case .code(let lang, let code):
            VStack(alignment: .leading, spacing: 4) {
                if !lang.isEmpty { Text(lang).font(.caption2).foregroundStyle(.secondary) }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code).font(.system(.callout, design: .monospaced))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        case .rule:
            Divider().padding(.vertical, 6)
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow { ForEach(header.indices, id: \.self) { Text(Inline.attributed(header[$0])).bold() } }
                    Divider()
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(rows[r].indices, id: \.self) { c in Text(Inline.attributed(rows[r][c])) }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            }
        case .embed(let target):
            EmbedView(target: target, session: session, from: path)
        case .properties(let props):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(props.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline) {
                        Text(props[i].0).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).lineLimit(1)
                        Text(Inline.attributed(props[i].1))
                    }
                    .font(.footnote)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        case 4: return .headline
        default: return .subheadline.bold()
        }
    }
}

struct CalloutView: View {
    let type: String, title: String, content: String
    let startFolded: Bool
    let session: VaultSession
    let path: String
    var onToggleTask: (Int) -> Void
    @State private var folded: Bool?

    private var style: (Color, String) {
        switch type {
        case "tip", "hint", "important": return (.teal, "flame")
        case "success", "check", "done": return (.green, "checkmark.circle")
        case "question", "help", "faq": return (.orange, "questionmark.circle")
        case "warning", "caution", "attention": return (.orange, "exclamationmark.triangle")
        case "failure", "fail", "missing", "danger", "error": return (.red, "xmark.octagon")
        case "bug": return (.red, "ant")
        case "example": return (.purple, "list.bullet")
        case "quote", "cite": return (.gray, "quote.opening")
        case "todo": return (.blue, "checklist")
        case "abstract", "summary", "tldr": return (.cyan, "doc.text")
        default: return (.blue, "info.circle")
        }
    }

    var body: some View {
        let (color, icon) = style
        let isFolded = folded ?? startFolded
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { folded = !isFolded } } label: {
                HStack {
                    Image(systemName: icon)
                    Text(Inline.attributed(title)).bold()
                    Spacer()
                    if !content.isEmpty { Image(systemName: isFolded ? "chevron.right" : "chevron.down").font(.caption) }
                }
                .foregroundStyle(color)
            }
            .buttonStyle(.plain)
            if !isFolded && !content.isEmpty {
                BlocksView(blocks: MarkdownParser.parse(content, lineOffset: nil), session: session, path: path, onToggleTask: onToggleTask)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
    }
}

struct EmbedView: View {
    let target: String
    let session: VaultSession
    let from: String

    var body: some View {
        let clean = Links.split(target).target
        let decoded = clean.removingPercentEncoding ?? clean
        if let path = session.resolve(decoded, from: from) {
            switch FileKind(path: path) {
            case .image:
                if let img = UIImage(contentsOfFile: session.url(path).path) {
                    Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else { missing(decoded) }
            case .markdown:
                Button { session.open(path) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(((path as NSString).lastPathComponent as NSString).deletingPathExtension, systemImage: "doc.text")
                            .font(.subheadline.bold()).foregroundStyle(Color.accentColor)
                        Text(Inline.attributed(String(session.readText(path).prefix(600))))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(8)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 2) }
                }
                .buttonStyle(.plain)
            default:
                Button { session.open(path) } label: { Label((path as NSString).lastPathComponent, systemImage: FileKind(path: path).symbol) }
            }
        } else if decoded.hasPrefix("http") {
            AsyncImage(url: URL(string: decoded)) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
        } else {
            missing(decoded)
        }
    }

    private func missing(_ t: String) -> some View {
        Label("Not found: \(t)", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
    }
}
