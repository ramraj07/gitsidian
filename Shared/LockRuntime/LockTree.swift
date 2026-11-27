import Foundation

/// The Lock Screen sizes. The raw value is `gitsidian.family` in a `*.gitsidian.lock` script.
enum LockFamily: String, CaseIterable, Codable, Sendable {
    case rectangular, circular, inline
}

/// What a `*.gitsidian.lock` script built: one layout per Lock Screen size. A size the script
/// left out shows "No <size> layout". Pure data (Codable), like `WidgetProgram`.
struct LockProgram: Equatable, Codable, Sendable {
    var circular: LockFace?
    var rectangular: [LockRow]?
    var inline: LockInline?
    var refreshAfterMinutes: Double?

    init(circular: LockFace? = nil, rectangular: [LockRow]? = nil, inline: LockInline? = nil, refreshAfterMinutes: Double? = nil) {
        self.circular = circular
        self.rectangular = rectangular
        self.inline = inline
        self.refreshAfterMinutes = refreshAfterMinutes
    }

    func has(_ family: LockFamily) -> Bool {
        switch family {
        case .circular: return circular != nil
        case .rectangular: return !(rectangular ?? []).isEmpty
        case .inline: return inline != nil
        }
    }
}

/// Text or an SF Symbol shown in the middle of a ring or gauge.
struct LockLabel: Equatable, Codable, Sendable {
    var text: String?
    var symbol: String?
    init(text: String? = nil, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }
    var isEmpty: Bool { text == nil && symbol == nil }
}

struct LockGauge: Equatable, Codable, Sendable {
    var value: Double
    var min: Double = 0
    var max: Double = 1
    var center: LockLabel?
    var label: String?
    var minLabel: String?
    var maxLabel: String?
    init(value: Double, min: Double = 0, max: Double = 1, center: LockLabel? = nil,
         label: String? = nil, minLabel: String? = nil, maxLabel: String? = nil) {
        self.value = value
        self.min = min
        self.max = max
        self.center = center
        self.label = label
        self.minLabel = minLabel
        self.maxLabel = maxLabel
    }
}

/// An SVG or canvas drawing, already rendered to PNG (at 3x) when the script ran.
struct LockPicture: Equatable, Codable, Sendable {
    var png: Data
    var width: Double     // points
    var height: Double
    init(png: Data, width: Double, height: Double) {
        self.png = png
        self.width = width
        self.height = height
    }
}

/// The single thing a circular widget shows.
enum LockFace: Equatable, Codable, Sendable {
    case ring(LockGauge)                                    // closed ring, fills with value
    case gauge(LockGauge)                                   // open arc with min/max labels
    case timeRing(start: Date, end: Date, center: LockLabel?)  // ring that fills live between two dates
    case number(String, caption: String?, symbol: String?)
    case symbol(String, caption: String?)
    case countdown(Date, caption: String?)
    case picture(LockPicture)                               // svg() / canvas(): fills the circle

    /// Ring and gauge styles draw their own track; the others sit on the standard round backdrop.
    var wantsBackground: Bool {
        switch self {
        case .ring, .gauge, .timeRing: return false
        default: return true
        }
    }
}

/// One row of a rectangular widget (at most 3, or 1 picture).
enum LockRow: Equatable, Codable, Sendable {
    case title(String, symbol: String?)
    case line(String, symbol: String?, trailing: String?, mono: Bool)
    case bar(LockGauge)
    case timeBar(start: Date, end: Date, label: String?)
    case countdown(Date, label: String?)
    case relative(Date, label: String?)
    case sparkline([Double], type: ChartType)
    case picture(LockPicture)
}

/// The one line of an inline widget (above the clock). The system shows one symbol and one text.
struct LockInline: Equatable, Codable, Sendable {
    enum DateStyle: String, Codable, Sendable { case timer, relative }
    var text: String
    var symbol: String?
    var date: Date?
    var dateStyle: DateStyle?
    init(text: String, symbol: String? = nil, date: Date? = nil, dateStyle: DateStyle? = nil) {
        self.text = text
        self.symbol = symbol
        self.date = date
        self.dateStyle = dateStyle
    }
}
