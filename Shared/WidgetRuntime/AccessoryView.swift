import SwiftUI

/// The Lock Screen widget sizes. The raw value is what a script sees as `gitsidian.family`.
enum AccessoryFamily: String, CaseIterable, Sendable {
    case rectangular, circular, inline
}

private struct WidgetCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True on the Lock Screen: smaller type, no buttons (only a tap on the whole widget works there).
    var widgetCompact: Bool {
        get { self[WidgetCompactKey.self] }
        set { self[WidgetCompactKey.self] = newValue }
    }
}

/// A program on the Lock Screen. Only the first page is shown (there is no pager), buttons
/// and links are left out, and `inline` flattens the page into one line of text.
/// The surrounding background (e.g. `AccessoryWidgetBackground`) is up to the caller.
struct AccessoryProgramView: View {
    let program: WidgetProgram
    let family: AccessoryFamily

    init(program: WidgetProgram, family: AccessoryFamily) {
        self.program = program
        self.family = family
    }

    private var nodes: [WidgetNode] { program.isEmpty ? [] : program.page(number: 1) }

    var body: some View {
        switch family {
        case .inline:
            AccessoryInline.text(for: nodes, empty: "Empty widget")
        case .circular:
            VStack(alignment: .center, spacing: 0) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in NodeView(node: node) }
            }
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.widgetCompact, true)
        case .rectangular:
            if nodes.isEmpty {
                Text("Empty widget").font(.headline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in NodeView(node: node) }
                }
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(\.widgetCompact, true)
            }
        }
    }
}

/// `accessoryInline` shows a single line of text, so the page's texts, list titles, gauges and
/// dates are joined with " · " in page order. Images, canvases, charts and buttons are skipped.
enum AccessoryInline {
    static func text(for nodes: [WidgetNode], empty: String) -> Text {
        let parts = segments(nodes)
        guard var line = parts.first else { return Text(empty) }
        for part in parts.dropFirst() { line = line + Text(" · ") + part }
        return line
    }

    static func segments(_ nodes: [WidgetNode]) -> [Text] {
        nodes.flatMap { node -> [Text] in
            switch node {
            case .text(let s, _):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? [] : [Text(t)]
            case .timer(let date):
                return [Text(date, style: .timer)]
            case .relativeDate(let date):
                return [RelativeDateText.text(date)]
            case .progress(let start, let end):
                return [Text(timerInterval: start...end, countsDown: true)]
            case .gauge(let g):
                let value = Text(g.value, format: .number.precision(.fractionLength(0...1)))
                return [g.label.map { Text($0 + " ") + value } ?? value]
            case .list(let items):
                guard let first = items.first else { return [] }
                return [first.detail.map { Text(first.title + " " + $0) } ?? Text(first.title)]
            case .row(let children), .column(let children):
                return segments(children)
            case .image, .canvas, .spacer, .link, .pageButton, .chart:
                return []
            }
        }
    }
}
