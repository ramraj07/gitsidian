import SwiftUI
import WebKit

/// A `*.gitsidian.widget` file: live preview at each widget size, or the source.
struct WidgetFileView: View {
    let session: VaultSession
    let path: String
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
        case rectangular, circular, inline
        var id: String { rawValue }
        static let homeScreen: [Family] = [.small, .medium, .large]
        var accessory: AccessoryFamily? { AccessoryFamily(rawValue: rawValue) }
        /// Typical iPhone widget sizes in points.
        var size: CGSize {
            switch self {
            case .small: return CGSize(width: 170, height: 170)
            case .medium: return CGSize(width: 364, height: 170)
            case .large: return CGSize(width: 364, height: 382)
            case .rectangular: return CGSize(width: 172, height: 76)
            case .circular: return CGSize(width: 76, height: 76)
            case .inline: return CGSize(width: 234, height: 22)
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
                ForEach(Family.homeScreen) { family in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(family.rawValue.capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        frame(family)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Lock Screen (rectangular, circular, inline)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    lockScreen
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

    /// Lock Screen widgets render monochrome on a wallpaper; this approximates it.
    private var lockScreen: some View {
        VStack(spacing: 12) {
            accessoryFrame(.inline)
            HStack(spacing: 12) {
                accessoryFrame(.circular)
                accessoryFrame(.rectangular)
            }
        }
        .padding(16)
        .frame(width: Family.medium.size.width)
        .background(LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func accessoryFrame(_ family: Family) -> some View {
        let content: AnyView = {
            switch results[family] {
            case .none:
                return AnyView(ProgressView())
            case .failure:
                return AnyView(Label("Widget error", systemImage: "exclamationmark.triangle").font(.caption))
            case .success(let program):
                return AnyView(AccessoryProgramView(program: program, family: family.accessory ?? .rectangular))
            }
        }()
        content
            .foregroundStyle(.white)
            .saturation(0)
            .frame(width: family.size.width, height: family.size.height,
                   alignment: family == .rectangular ? .topLeading : .center)
            .background {
                if family == .circular { Circle().fill(.white.opacity(0.18)) }
            }
            .clipShape(family == .circular ? AnyShape(Circle()) : AnyShape(Rectangle()))
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
