import Foundation
import JavaScriptCore
import UIKit

@objc protocol CanvasGradientExports: JSExport {
    func addColorStop(_ offset: Double, _ color: String)
}

@objc final class CanvasGradientJS: NSObject, CanvasGradientExports {
    let start: CGPoint
    let end: CGPoint
    var stops: [(CGFloat, UIColor)] = []

    init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }

    func addColorStop(_ offset: Double, _ color: String) {
        guard offset.isFinite else { return }
        stops.append((CGFloat(min(max(offset, 0), 1)), CSSColor.parse(color) ?? .black))
        stops.sort { $0.0 < $1.0 }
    }

    func cgGradient() -> CGGradient? {
        guard !stops.isEmpty else { return nil }
        let colors = stops.map { $0.1.cgColor } as CFArray
        let locations = stops.map { $0.0 }
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations)
    }
}

@objc protocol CanvasContextExports: JSExport {
    var fillStyle: JSValue? { get set }
    var strokeStyle: JSValue? { get set }
    var lineWidth: Double { get set }
    var font: String { get set }
    var globalAlpha: Double { get set }
    var textAlign: String { get set }

    func fillRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double)
    func strokeRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double)
    func clearRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double)
    func beginPath()
    func moveTo(_ x: Double, _ y: Double)
    func lineTo(_ x: Double, _ y: Double)
    func arc(_ x: Double, _ y: Double, _ r: Double, _ start: Double, _ end: Double, _ anticlockwise: Bool)
    func closePath()
    func fill()
    func stroke()
    func fillText(_ text: String, _ x: Double, _ y: Double)
    func save()
    func restore()
    func translate(_ x: Double, _ y: Double)
    func scale(_ x: Double, _ y: Double)
    func rotate(_ angle: Double)
    func roundRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ radii: JSValue?)
    func createLinearGradient(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> CanvasGradientJS
}

/// Canvas 2D subset over a CGContext supplied by `UIGraphicsImageRenderer`
/// (top-left origin, 3x scale). The path is mirrored in a `CGMutablePath` in
/// "base" user space so that, like the HTML canvas, `fill()` does not consume it
/// and points are fixed at the transform in effect when they were added.
@objc final class CanvasContextJS: NSObject, CanvasContextExports {
    private let cg: CGContext
    private let state: RuntimeState
    private var path = CGMutablePath()
    private var transform = CGAffineTransform.identity
    private var transformStack: [CGAffineTransform] = []
    private var opCount = 0

    private enum Paint {
        case color(UIColor)
        case gradient(CanvasGradientJS)
    }
    private var fillPaint: Paint = .color(.black)
    private var strokePaint: Paint = .color(.black)
    private var paintStack: [(Paint, Paint, Double, String, Double, String)] = []
    private var currentFont: UIFont = .systemFont(ofSize: 10)

    init(cg: CGContext, state: RuntimeState) {
        self.cg = cg
        self.state = state
        super.init()
        cg.setLineCap(.butt)
        cg.setLineJoin(.miter)
        cg.setLineWidth(1)
    }

    /// Periodically check the time budget; drawing loops are the hot path.
    private func tick() -> Bool {
        opCount += 1
        if opCount % 64 == 0 { return state.checkBudget() }
        return true
    }

    // MARK: Properties

    private var _fillStyle: JSValue?
    var fillStyle: JSValue? {
        get { _fillStyle }
        set {
            _fillStyle = newValue
            if let p = Self.paint(from: newValue) { fillPaint = p }
        }
    }

    private var _strokeStyle: JSValue?
    var strokeStyle: JSValue? {
        get { _strokeStyle }
        set {
            _strokeStyle = newValue
            if let p = Self.paint(from: newValue) { strokePaint = p }
        }
    }

    private static func paint(from v: JSValue?) -> Paint? {
        guard let v else { return nil }
        if let g = v.toObject() as? CanvasGradientJS { return .gradient(g) }
        if v.isString, let c = CSSColor.parse(v.toString()) { return .color(c) }
        return nil
    }

    var lineWidth: Double = 1 {
        didSet {
            if lineWidth.isFinite && lineWidth > 0 { cg.setLineWidth(CGFloat(lineWidth)) } else { lineWidth = oldValue }
        }
    }

    var font: String = "10px sans-serif" {
        didSet { currentFont = CanvasFont.parse(font) }
    }

    var globalAlpha: Double = 1 {
        didSet {
            if globalAlpha.isFinite { cg.setAlpha(CGFloat(min(max(globalAlpha, 0), 1))) } else { globalAlpha = oldValue }
        }
    }

    var textAlign: String = "left"

    // MARK: Rects

    func fillRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        guard tick(), [x, y, w, h].allSatisfy(\.isFinite) else { return }
        let p = CGMutablePath()
        p.addRect(CGRect(x: x, y: y, width: w, height: h))
        paint(path: p, fill: true)
    }

    func strokeRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        guard tick(), [x, y, w, h].allSatisfy(\.isFinite) else { return }
        let p = CGMutablePath()
        p.addRect(CGRect(x: x, y: y, width: w, height: h))
        paint(path: p, fill: false)
    }

    func clearRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        guard tick(), [x, y, w, h].allSatisfy(\.isFinite) else { return }
        cg.saveGState()
        cg.setBlendMode(.clear)
        cg.fill(CGRect(x: x, y: y, width: w, height: h))
        cg.restoreGState()
    }

    // MARK: Path

    func beginPath() {
        _ = tick()
        path = CGMutablePath()
    }

    func moveTo(_ x: Double, _ y: Double) {
        guard tick(), x.isFinite, y.isFinite else { return }
        path.move(to: CGPoint(x: x, y: y), transform: transform)
    }

    func lineTo(_ x: Double, _ y: Double) {
        guard tick(), x.isFinite, y.isFinite else { return }
        if path.isEmpty {
            path.move(to: CGPoint(x: x, y: y), transform: transform)
        } else {
            path.addLine(to: CGPoint(x: x, y: y), transform: transform)
        }
    }

    func arc(_ x: Double, _ y: Double, _ r: Double, _ start: Double, _ end: Double, _ anticlockwise: Bool) {
        guard tick(), [x, y, r, start, end].allSatisfy(\.isFinite), r >= 0 else { return }
        // Canvas angles are clockwise-positive in a y-down space; CG's `clockwise`
        // flag refers to a y-up space, so the flag inverts.
        path.addArc(center: CGPoint(x: x, y: y), radius: CGFloat(r), startAngle: CGFloat(start), endAngle: CGFloat(end),
                    clockwise: anticlockwise, transform: transform)
    }

    func closePath() {
        _ = tick()
        if !path.isEmpty { path.closeSubpath() }
    }

    func roundRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ radii: JSValue?) {
        guard tick(), [x, y, w, h].allSatisfy(\.isFinite) else { return }
        var r: CGFloat = 0
        if let radii {
            if radii.isNumber {
                r = CGFloat(radii.toDouble())
            } else if radii.isArray, let first = radii.atIndex(0), first.isNumber {
                r = CGFloat(first.toDouble())
            }
        }
        r = max(0, min(r, CGFloat(min(abs(w), abs(h)) / 2)))
        let rect = CGRect(x: x, y: y, width: w, height: h).standardized
        if r > 0 {
            path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r, transform: transform)
        } else {
            path.addRect(rect, transform: transform)
        }
    }

    func fill() {
        guard tick() else { return }
        paintCurrentPath(fill: true)
    }

    func stroke() {
        guard tick() else { return }
        paintCurrentPath(fill: false)
    }

    /// The mirror path lives in base space; bring it back into the current user space
    /// so stroke widths scale with the CTM the way canvas does.
    private func paintCurrentPath(fill: Bool) {
        guard !path.isEmpty else { return }
        var inverse = transform.inverted()
        guard let local = path.copy(using: &inverse) else { return }
        paint(path: local, fill: fill)
    }

    private func paint(path p: CGPath, fill: Bool) {
        let paintStyle = fill ? fillPaint : strokePaint
        switch paintStyle {
        case .color(let c):
            cg.saveGState()
            cg.addPath(p)
            if fill {
                cg.setFillColor(c.cgColor)
                cg.fillPath()
            } else {
                cg.setStrokeColor(c.cgColor)
                cg.strokePath()
            }
            cg.restoreGState()
        case .gradient(let g):
            guard let gradient = g.cgGradient() else { return }
            cg.saveGState()
            if fill {
                cg.addPath(p)
                cg.clip()
            } else {
                cg.addPath(p)
                cg.replacePathWithStrokedPath()
                cg.clip()
            }
            cg.drawLinearGradient(gradient, start: g.start, end: g.end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            cg.restoreGState()
        }
    }

    // MARK: Text

    func fillText(_ text: String, _ x: Double, _ y: Double) {
        guard tick(), x.isFinite, y.isFinite else { return }
        let color: UIColor
        if case .color(let c) = fillPaint { color = c } else { color = .black }
        let attrs: [NSAttributedString.Key: Any] = [.font: currentFont, .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        var px = CGFloat(x)
        switch textAlign {
        case "center": px -= size.width / 2
        case "right", "end": px -= size.width
        default: break
        }
        // Canvas draws at the alphabetic baseline; UIKit draws from the top-left.
        let origin = CGPoint(x: px, y: CGFloat(y) - currentFont.ascender)
        UIGraphicsPushContext(cg)
        str.draw(at: origin)
        UIGraphicsPopContext()
    }

    // MARK: State and transforms

    func save() {
        _ = tick()
        cg.saveGState()
        transformStack.append(transform)
        paintStack.append((fillPaint, strokePaint, lineWidth, font, globalAlpha, textAlign))
    }

    func restore() {
        _ = tick()
        guard let t = transformStack.popLast(), let p = paintStack.popLast() else { return }
        cg.restoreGState()
        transform = t
        (fillPaint, strokePaint) = (p.0, p.1)
        lineWidth = p.2
        font = p.3
        globalAlpha = p.4
        textAlign = p.5
    }

    func translate(_ x: Double, _ y: Double) {
        guard tick(), x.isFinite, y.isFinite else { return }
        cg.translateBy(x: CGFloat(x), y: CGFloat(y))
        transform = CGAffineTransform(translationX: CGFloat(x), y: CGFloat(y)).concatenating(transform)
    }

    func scale(_ x: Double, _ y: Double) {
        guard tick(), x.isFinite, y.isFinite, x != 0, y != 0 else { return }
        cg.scaleBy(x: CGFloat(x), y: CGFloat(y))
        transform = CGAffineTransform(scaleX: CGFloat(x), y: CGFloat(y)).concatenating(transform)
    }

    func rotate(_ angle: Double) {
        guard tick(), angle.isFinite else { return }
        cg.rotate(by: CGFloat(angle))
        transform = CGAffineTransform(rotationAngle: CGFloat(angle)).concatenating(transform)
    }

    func createLinearGradient(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> CanvasGradientJS {
        _ = tick()
        return CanvasGradientJS(start: CGPoint(x: x0, y: y0), end: CGPoint(x: x1, y: y1))
    }
}

// MARK: - CSS color / font parsing

enum CSSColor {
    static let named: [String: UIColor] = [
        "black": .black, "white": .white, "red": .red, "green": UIColor(red: 0, green: 0.5, blue: 0, alpha: 1),
        "blue": .blue, "yellow": .yellow, "orange": .orange, "purple": .purple, "gray": .gray, "grey": .gray,
        "cyan": .cyan, "magenta": .magenta, "transparent": .clear, "lime": .green, "pink": .systemPink,
        "navy": UIColor(red: 0, green: 0, blue: 0.5, alpha: 1), "teal": UIColor(red: 0, green: 0.5, blue: 0.5, alpha: 1),
    ]

    /// `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb(r,g,b)`, `rgba(r,g,b,a)`, a few names.
    static func parse(_ raw: String) -> UIColor? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let c = named[s] { return c }
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            let hasAlpha = hex.count == 8
            let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
            let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
            let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
            let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
            return UIColor(red: r, green: g, blue: b, alpha: a)
        }
        if s.hasPrefix("rgb") {
            guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
            let parts = s[s.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else { return nil }
            let a = parts.count > 3 ? (Double(parts[3]) ?? 1) : 1
            return UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
        }
        return nil
    }
}

enum CanvasFont {
    /// "bold 14px Helvetica", "italic 600 12px sans-serif", "12px monospace".
    static func parse(_ spec: String) -> UIFont {
        var size: CGFloat = 10
        var weight: UIFont.Weight = .regular
        var italic = false
        var mono = false
        for tok in spec.lowercased().split(separator: " ") {
            let t = String(tok)
            if t.hasSuffix("px"), let v = Double(t.dropLast(2)) { size = CGFloat(v); continue }
            if t.hasSuffix("pt"), let v = Double(t.dropLast(2)) { size = CGFloat(v); continue }
            switch t {
            case "bold", "700", "800", "900": weight = .bold
            case "600": weight = .semibold
            case "500": weight = .medium
            case "300", "200", "100": weight = .light
            case "italic", "oblique": italic = true
            default:
                if t.contains("mono") || t.contains("menlo") || t.contains("courier") { mono = true }
            }
        }
        var font = mono
            ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        if italic, let desc = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: desc, size: size)
        }
        return font
    }
}
