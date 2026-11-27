import SwiftUI
import WebKit

/// A `*.gitsidian.widget` or `*.gitsidian.lock` file: live preview at each widget size, or the source.
struct WidgetFileView: View {
    let session: VaultSession
    let path: String
    var lock = false
    @State private var showCode = false

    var body: some View {
        VStack(spacing: 0) {
            // Flush the editor first so the preview runs what was just typed.
            Picker("Mode", selection: Binding(get: { showCode }, set: { session.flushEditors(); showCode = $0 })) {
                Text("Preview").tag(false)
                Text("Code").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            if showCode {
                TextFileView(session: session, path: path, markdown: false, reading: false)
            } else if lock {
                LockPreview(session: session, path: path)
            } else {
                WidgetPreview(session: session, path: path)
            }
        }
    }
}

struct WidgetPreview: View {
    let session: VaultSession
    let path: String

    enum Family: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        /// Typical iPhone widget sizes in points.
        var size: CGSize {
            switch self {
            case .small: return CGSize(width: 170, height: 170)
            case .medium: return CGSize(width: 364, height: 170)
            case .large: return CGSize(width: 364, height: 382)
            }
        }
    }

    @State private var results: [Family: Result<WidgetProgram, Error>] = [:]
    @State private var pages: [Family: Int] = [:]
    @State private var fullView: String?
    @State private var showFullView = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Family.allCases) { family in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(family.rawValue.capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        frame(family)
                    }
                }
                if fullView != nil {
                    Button { showFullView = true } label: { Label("Full view (shown when the widget is tapped)", systemImage: "doc.richtext") }
                }
                Label("Add it from the Home Screen: long-press › Edit › Add Widget › Gitsidian, then pick this file.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .task(id: session.diskVersion) { await run() }
        .sheet(isPresented: $showFullView) {
            NavigationStack {
                HTMLView(html: fullView ?? "")
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(WidgetFile.displayName(path))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFullView = false } } }
            }
        }
    }

    @ViewBuilder
    private func frame(_ family: Family) -> some View {
        let content: AnyView = {
            switch results[family] {
            case .none:
                return AnyView(ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity))
            case .failure(let e):
                return AnyView(StatusView(title: "Widget error", detail: e.localizedDescription, symbol: "exclamationmark.triangle"))
            case .success(let program):
                return AnyView(
                    ProgramView(program: program, pageNumber: pages[family] ?? 1)
                        .environment(\.widgetPageButton, PageButtonBuilder { label, page in
                            AnyView(Button { pages[family] = page } label: {
                                Text(label)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.tint.opacity(0.18), in: Capsule())
                            }.buttonStyle(.plain))
                        })
                )
            }
        }()
        content
            .padding(12)
            .frame(width: family.size.width, height: family.size.height, alignment: .topLeading)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func run() async {
        let script = session.readText(path)
        let config = session.config
        let path = path
        var out: [Family: Result<WidgetProgram, Error>] = [:]
        for family in Family.allCases {
            let ctx = WidgetFileContext(vaultID: config.id, repo: config.fullName, branch: config.branch, path: path, family: family.rawValue)
            out[family] = await Task.detached(priority: .userInitiated) {
                Result { try ScriptRunner.run(script: script, file: ctx) }
            }.value
        }
        results = out
        fullView = out.values.lazy.compactMap { try? $0.get().fullView }.first
    }
}

struct HTMLView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        return WKWebView(frame: .zero, configuration: config)
    }
    func updateUIView(_ v: WKWebView, context: Context) { v.loadHTMLString(html, baseURL: nil) }
}

/// A `*.gitsidian.lock` file at the three Lock Screen sizes, on a dark wallpaper and in one tint,
/// roughly as the Lock Screen draws it.
struct LockPreview: View {
    let session: VaultSession
    let path: String

    @State private var results: [LockFamily: Result<LockProgram, Error>] = [:]

    private static let sizes: [LockFamily: CGSize] = [
        .rectangular: LockSize.rectangular, .circular: LockSize.circular, .inline: CGSize(width: 234, height: 22),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                wallpaper
                ForEach(errors, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
                Label("Add it from the Lock Screen: long-press › Customize › Lock Screen › tap the widget area › Gitsidian › Lock Screen widget, then pick this file.",
                      systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .task(id: session.diskVersion) { await run() }
    }

    private var errors: [String] {
        var seen = Set<String>()
        return LockFamily.allCases.compactMap { family -> String? in
            guard case .failure(let e)? = results[family] else { return nil }
            let m = e.localizedDescription
            return seen.insert(m).inserted ? m : nil
        }
    }

    private var wallpaper: some View {
        VStack(spacing: 14) {
            frame(.inline)
            Text(Date(), format: .dateTime.hour().minute())
                .font(.system(size: 64, weight: .bold, design: .rounded))
            HStack(spacing: 12) {
                frame(.circular)
                frame(.rectangular)
            }
        }
        .padding(.vertical, 24)
        .frame(width: 364)
        .background(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.06)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func frame(_ family: LockFamily) -> some View {
        let size = Self.sizes[family] ?? .zero
        Group {
            switch results[family] {
            case .none: ProgressView()
            case .failure: Image(systemName: "exclamationmark.triangle")
            case .success(let program):
                LockProgramView(program: program, family: family)
                    .background {
                        if family == .circular, program.circular?.wantsBackground ?? true {
                            Circle().fill(.white.opacity(0.16))
                        }
                    }
            }
        }
        .frame(width: size.width, height: size.height, alignment: family == .rectangular ? .topLeading : .center)
        .saturation(0)
        .overlay {
            // Dashed outline of the widget's area, so empty space is visible while designing.
            if family == .circular { Circle().strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, dash: [3])) }
            else { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, dash: [3])) }
        }
    }

    private func run() async {
        let script = session.readText(path)
        let config = session.config
        let path = path
        var out: [LockFamily: Result<LockProgram, Error>] = [:]
        for family in LockFamily.allCases {
            let ctx = WidgetFileContext(vaultID: config.id, repo: config.fullName, branch: config.branch, path: path, family: family.rawValue)
            out[family] = await Task.detached(priority: .userInitiated) {
                Result { try ScriptRunner.runLock(script: script, file: ctx) }
            }.value
        }
        results = out
    }
}
