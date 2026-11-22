import SwiftUI
import Charts

/// How a `pageButton` node becomes a view. The widget supplies `Button(intent:)`;
/// previews and the app supply a plain button.
struct PageButtonBuilder {
    let make: (_ label: String, _ page: Int) -> AnyView
    init(_ make: @escaping (_ label: String, _ page: Int) -> AnyView) { self.make = make }

    static let inert = PageButtonBuilder { label, _ in
        AnyView(Text(label).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: Capsule()))
    }
}

private struct PageButtonBuilderKey: EnvironmentKey {
    static let defaultValue = PageButtonBuilder.inert
}

extension EnvironmentValues {
    var widgetPageButton: PageButtonBuilder {
        get { self[PageButtonBuilderKey.self] }
        set { self[PageButtonBuilderKey.self] = newValue }
    }
}

/// Renders one page (a list of top-level nodes) as a column.
struct PageView: View {
    let nodes: [WidgetNode]

    init(nodes: [WidgetNode]) { self.nodes = nodes }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                NodeView(node: node)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct NodeView: View {
    let node: WidgetNode
    @Environment(\.widgetPageButton) private var pageButton

    init(node: WidgetNode) { self.node = node }

    var body: some View {
        switch node {
        case .text(let s, let style):
            textView(s, style)
        case .image(let img):
            imageView(img)
        case .canvas(let c):
            if let ui = UIImage(data: c.png, scale: 3) {
                Image(uiImage: ui).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: c.width, height: c.height)
            }
        case .timer(let date):
            Text(date, style: .timer).font(.body.monospacedDigit())
        case .relativeDate(let date):
            RelativeDateText(date: date)
        case .progress(let start, let end):
            ProgressView(timerInterval: start...end, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                .tint(.accentColor)
        case .gauge(let g):
            Gauge(value: g.value, in: g.min...g.max) {
                if let l = g.label { Text(l) }
            } currentValueLabel: {
                Text(g.value, format: .number.precision(.fractionLength(0...1)))
            }
            .gaugeStyle(.accessoryCircular)
        case .list(let items):
            listView(items)
        case .row(let children):
            HStack(alignment: .center, spacing: 6) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in NodeView(node: c) }
            }
        case .column(let children):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in NodeView(node: c) }
            }
        case .spacer:
            Spacer(minLength: 0)
        case .link(let label, let url):
            Link(destination: url) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.tint.opacity(0.18), in: Capsule())
            }
        case .pageButton(let label, let page):
            pageButton.make(label, page)
        case .chart(let spec):
            chartView(spec)
        }
    }

    @ViewBuilder
    private func textView(_ s: String, _ style: TextStyle) -> some View {
        let color: Color = style.color.flatMap(Color.init(css:)) ?? .primary
        Text(s)
            .font(style.font.swiftUIFont)
            .foregroundStyle(color)
            .lineLimit(style.lines)
            .multilineTextAlignment(style.align?.textAlignment ?? .leading)
            .frame(maxWidth: style.align == nil ? nil : .infinity, alignment: style.align?.alignment ?? .leading)
    }

    @ViewBuilder
    private func imageView(_ img: ImageNode) -> some View {
        if let ui = UIImage(data: img.data) {
            Image(uiImage: ui)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: img.width.map { CGFloat($0) }, height: img.height.map { CGFloat($0) })
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(img.corner ?? 0), style: .continuous))
        }
    }

    @ViewBuilder
    private func listView(_ items: [ListItem]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let row = HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let d = item.detail {
                        Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let url = item.url {
                    Link(destination: url) { row }.buttonStyle(.plain)
                } else {
                    row
                }
            }
        }
    }

    @ViewBuilder
    private func chartView(_ spec: ChartSpec) -> some View {
        let color = spec.color.flatMap(Color.init(css:)) ?? .accentColor
        Chart(Array(spec.data.enumerated()), id: \.offset) { _, p in
            switch spec.type {
            case .bar:
                BarMark(x: .value("x", p.x), y: .value("y", p.y)).foregroundStyle(color)
            case .line:
                LineMark(x: .value("x", p.x), y: .value("y", p.y)).foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
            case .area:
                AreaMark(x: .value("x", p.x), y: .value("y", p.y)).foregroundStyle(color.opacity(0.35))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("x", p.x), y: .value("y", p.y)).foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel().font(.caption2)
            }
        }
        .frame(minHeight: 40)
    }
}

extension TextFont {
    var swiftUIFont: Font {
        switch self {
        case .largeTitle: return .largeTitle.weight(.bold)
        case .title: return .title2.weight(.semibold)
        case .headline: return .headline
        case .body: return .body
        case .caption: return .caption
        case .mono: return .system(.body, design: .monospaced)
        }
    }
}

extension TextAlign {
    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
    var alignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

extension Color {
    init?(css: String) {
        guard let ui = CSSColor.parse(css) else { return nil }
        self = Color(uiColor: ui)
    }
}

/// "5 min ago" / "in 2 hr". Minute granularity, never a seconds counter:
/// live on iOS 18 (system-updated), fixed at render time on iOS 17.
struct RelativeDateText: View {
    let date: Date

    var body: some View {
        if #available(iOS 18.0, *) {
            Text(.currentDate, format: .reference(to: date,
                                                   allowedFields: [.year, .month, .week, .day, .hour, .minute],
                                                   maxFieldCount: 1))
                .font(.body)
        } else {
            Text(Self.fallback(date)).font(.body)
        }
    }

    static func fallback(_ date: Date, now: Date = Date()) -> String {
        if abs(date.timeIntervalSince(now)) < 60 { return "now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }
}
