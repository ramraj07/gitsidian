import Foundation

/// The tree a script builds. Pure data: Codable, Equatable, no SwiftUI, so tests can
/// compare it and the timeline entry can carry it.
indirect enum WidgetNode: Equatable, Codable, Sendable {
    case text(String, TextStyle)
    case image(ImageNode)
    case canvas(CanvasNode)
    case timer(Date)
    case relativeDate(Date)
    case progress(start: Date, end: Date)
    case gauge(GaugeNode)
    case list([ListItem])
    case row([WidgetNode])
    case column([WidgetNode])
    case spacer
    case link(label: String, url: URL)
    case pageButton(label: String, page: Int)   // 1-based page number
    case chart(ChartSpec)

    /// Short kind name, handy for test assertions.
    var kind: String {
        switch self {
        case .text: return "text"
        case .image: return "image"
        case .canvas: return "canvas"
        case .timer: return "timer"
        case .relativeDate: return "relativeDate"
        case .progress: return "progress"
        case .gauge: return "gauge"
        case .list: return "list"
        case .row: return "row"
        case .column: return "column"
        case .spacer: return "spacer"
        case .link: return "link"
        case .pageButton: return "pageButton"
        case .chart: return "chart"
        }
    }

    var children: [WidgetNode] {
        switch self {
        case .row(let c), .column(let c): return c
        default: return []
        }
    }
}

enum TextFont: String, Codable, Sendable {
    case largeTitle, title, headline, body, caption, mono
}

enum TextAlign: String, Codable, Sendable {
    case leading, center, trailing
}

struct TextStyle: Equatable, Codable, Sendable {
    var font: TextFont = .body
    var color: String? = nil   // "#rrggbb" / "#rrggbbaa"
    var align: TextAlign? = nil
    var lines: Int? = nil
    init(font: TextFont = .body, color: String? = nil, align: TextAlign? = nil, lines: Int? = nil) {
        self.font = font
        self.color = color
        self.align = align
        self.lines = lines
    }
}

struct ImageNode: Equatable, Codable, Sendable {
    var data: Data          // decoded image bytes (PNG/JPEG/...)
    var width: Double?
    var height: Double?
    var corner: Double?
    init(data: Data, width: Double? = nil, height: Double? = nil, corner: Double? = nil) {
        self.data = data
        self.width = width
        self.height = height
        self.corner = corner
    }
}

struct CanvasNode: Equatable, Codable, Sendable {
    var png: Data           // rendered at 3x
    var width: Double       // logical points
    var height: Double
    init(png: Data, width: Double, height: Double) {
        self.png = png
        self.width = width
        self.height = height
    }
}

struct GaugeNode: Equatable, Codable, Sendable {
    var value: Double
    var min: Double
    var max: Double
    var label: String?
    init(value: Double, min: Double = 0, max: Double = 1, label: String? = nil) {
        self.value = value
        self.min = min
        self.max = max
        self.label = label
    }
}

struct ListItem: Equatable, Codable, Sendable {
    var title: String
    var detail: String?
    var url: URL?
    init(title: String, detail: String? = nil, url: URL? = nil) {
        self.title = title
        self.detail = detail
        self.url = url
    }
}

enum ChartType: String, Codable, Sendable {
    case bar, line, area
}

struct ChartPoint: Equatable, Codable, Sendable {
    var x: String
    var y: Double
    init(x: String, y: Double) {
        self.x = x
        self.y = y
    }
}

struct ChartSpec: Equatable, Codable, Sendable {
    var type: ChartType
    var data: [ChartPoint]
    var color: String?
    init(type: ChartType, data: [ChartPoint], color: String? = nil) {
        self.type = type
        self.data = data
        self.color = color
    }
}

/// Everything one run of the script produced.
struct WidgetProgram: Equatable, Codable, Sendable {
    var pages: [[WidgetNode]]
    var fullView: String?
    var refreshAfterMinutes: Double?

    init(pages: [[WidgetNode]] = [], fullView: String? = nil, refreshAfterMinutes: Double? = nil) {
        self.pages = pages
        self.fullView = fullView
        self.refreshAfterMinutes = refreshAfterMinutes
    }

    var isEmpty: Bool { pages.allSatisfy { $0.isEmpty } }

    /// Pages are numbered 1..n. Out-of-range numbers clamp.
    func clampedPageNumber(_ number: Int) -> Int {
        guard !pages.isEmpty else { return 1 }
        return Swift.max(1, Swift.min(number, pages.count))
    }

    func page(number: Int) -> [WidgetNode] {
        guard !pages.isEmpty else { return [] }
        return pages[clampedPageNumber(number) - 1]
    }
}
