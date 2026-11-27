import Foundation
import UIKit

/// Renders a subset of SVG to PNG with Core Graphics, when the script runs. WidgetKit can't
/// host a web view and iOS has no runtime SVG renderer, so this is the whole implementation.
///
/// Supported: `svg g path rect circle ellipse line polyline polygon text tspan`, all path
/// commands (incl. arcs), `transform`, `viewBox` (meet, centred), presentation attributes and
/// `style="…"`: fill, stroke, stroke-width, opacity, fill-opacity, stroke-opacity, fill-rule,
/// stroke-linecap, stroke-linejoin, stroke-dasharray, stroke-dashoffset, font-size,
/// font-weight, font-family (monospace/serif/rounded), text-anchor, color, display, visibility.
/// Not supported (skipped): gradients, patterns, masks, clip paths, filters, `use`, images, CSS.
///
/// Lock Screen difference: the default fill and `currentColor` are white, because the Lock
/// Screen draws widgets in one tint by brightness, so black would be invisible.
enum SVGRenderer {
    struct Rendered {
        var png: Data
        var size: CGSize
    }

    enum Failure: LocalizedError {
        case parse(String)
        var errorDescription: String? {
            switch self { case .parse(let m): return "svg(): \(m)" }
        }
    }

    static let maxBytes = 256 * 1024
    static let maxElements = 5000

    /// - Parameters: width/height: output size in points; missing ones come from the SVG's own
    ///   width/height or viewBox (keeping its aspect ratio).
    ///   `fitting`: with no width/height, scale the drawing to fit this box (keeps it sharp when the
    ///   viewBox is small, e.g. a 24×24 icon shown on a 76 pt circle).
    static func render(_ markup: String, width: Double?, height: Double?, fitting box: CGSize? = nil,
                       defaultColor: UIColor = .white) throws -> Rendered {
        guard markup.utf8.count <= maxBytes else { throw Failure.parse("markup is over 256 KB") }
        let root = try SVGParser.parse(markup)
        guard root.name == "svg" else { throw Failure.parse("the root element must be <svg>") }

        let vb = root.attrs["viewBox"].map(SVGNumbers.list) ?? []
        let ownW = root.attrs["width"].flatMap { SVGNumbers.length($0, relativeTo: 0) }
        let ownH = root.attrs["height"].flatMap { SVGNumbers.length($0, relativeTo: 0) }
        let viewBox: CGRect = vb.count == 4 && vb[2] > 0 && vb[3] > 0
            ? CGRect(x: vb[0], y: vb[1], width: vb[2], height: vb[3])
            : CGRect(x: 0, y: 0, width: ownW ?? 100, height: ownH ?? 100)
        let aspect = viewBox.width / viewBox.height

        var out: CGSize
        switch (width, height) {
        case let (w?, h?): out = CGSize(width: w, height: h)
        case let (w?, nil): out = CGSize(width: w, height: w / aspect)
        case let (nil, h?): out = CGSize(width: h * aspect, height: h)
        case (nil, nil):
            if let box {
                let k = min(box.width / viewBox.width, box.height / viewBox.height)
                out = CGSize(width: viewBox.width * k, height: viewBox.height * k)
            } else {
                out = CGSize(width: ownW ?? viewBox.width, height: ownH ?? viewBox.height)
            }
        }
        out.width = min(max(out.width, 1), 1000)
        out.height = min(max(out.height, 1), 1000)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let png = UIGraphicsImageRenderer(size: out, format: format).pngData { rc in
            let cg = rc.cgContext
            // viewBox -> output, preserveAspectRatio="xMidYMid meet"
            let s = min(out.width / viewBox.width, out.height / viewBox.height)
            cg.translateBy(x: (out.width - viewBox.width * s) / 2, y: (out.height - viewBox.height * s) / 2)
            cg.scaleBy(x: s, y: s)
            cg.translateBy(x: -viewBox.minX, y: -viewBox.minY)
            var style = SVGStyle(color: defaultColor)
            style.apply(root.attrs, viewport: viewBox.size)
            let painter = SVGPainter(cg: cg, viewport: viewBox.size, budget: maxElements)
            painter.drawChildren(of: root, style: style)
        }
        return Rendered(png: png, size: out)
    }
}

// MARK: - Tree

final class SVGElement {
    let name: String
    var attrs: [String: String]
    var children: [SVGElement] = []
    var text = ""
    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }
}

final class SVGParser: NSObject, XMLParserDelegate {
    private var stack: [SVGElement] = []
    private var root: SVGElement?
    private var count = 0

    static func parse(_ markup: String) throws -> SVGElement {
        let p = SVGParser()
        let xml = XMLParser(data: Data(markup.utf8))
        xml.delegate = p
        xml.shouldProcessNamespaces = false
        guard xml.parse(), let root = p.root else {
            let line = xml.lineNumber
            throw SVGRenderer.Failure.parse("invalid XML near line \(line): \(xml.parserError?.localizedDescription ?? "unknown error")")
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        count += 1
        if count > SVGRenderer.maxElements { parser.abortParsing(); return }
        // Drop a namespace prefix ("svg:path" -> "path").
        let local = name.split(separator: ":").last.map(String.init) ?? name
        let el = SVGElement(name: local, attrs: attributes)
        if let parent = stack.last { parent.children.append(el) } else { root = el }
        stack.append(el)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}

// MARK: - Style

enum SVGPaint: Equatable {
    case none
    case color(UIColor)
    case current
}

struct SVGStyle {
    var color: UIColor
    var fill: SVGPaint = .current
    var stroke: SVGPaint = .none
    var strokeWidth: CGFloat = 1
    var fillOpacity: CGFloat = 1
    var strokeOpacity: CGFloat = 1
    var opacity: CGFloat = 1          // cumulative (group opacity is applied per element)
    var evenOdd = false
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var dash: [CGFloat] = []
    var dashOffset: CGFloat = 0
    var fontSize: CGFloat = 16
    var fontWeight: UIFont.Weight = .regular
    var fontFamily = ""
    var anchor = "start"
    var hidden = false

    init(color: UIColor) { self.color = color }

    /// Attributes, then `style="…"` (which wins), as SVG does.
    mutating func apply(_ attrs: [String: String], viewport: CGSize) {
        var props = attrs
        if let inline = attrs["style"] {
            for decl in inline.split(separator: ";") {
                let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { props[kv[0].lowercased()] = kv[1] }
            }
        }
        let diag = (viewport.width * viewport.width + viewport.height * viewport.height).squareRoot() / CGFloat(2).squareRoot()
        if let v = props["color"], let c = CSSColor.parse(v) { color = c }
        if let v = props["fill"] { fill = Self.paint(v) ?? fill }
        if let v = props["stroke"] { stroke = Self.paint(v) ?? stroke }
        if let v = props["stroke-width"], let n = SVGNumbers.length(v, relativeTo: diag) { strokeWidth = max(0, n) }
        if let v = props["fill-opacity"], let n = SVGNumbers.opacity(v) { fillOpacity = n }
        if let v = props["stroke-opacity"], let n = SVGNumbers.opacity(v) { strokeOpacity = n }
        if let v = props["opacity"], let n = SVGNumbers.opacity(v) { opacity *= n }
        if let v = props["fill-rule"] { evenOdd = v.trimmingCharacters(in: .whitespaces) == "evenodd" }
        if let v = props["stroke-linecap"] {
            switch v.trimmingCharacters(in: .whitespaces) {
            case "round": lineCap = .round
            case "square": lineCap = .square
            default: lineCap = .butt
            }
        }
        if let v = props["stroke-linejoin"] {
            switch v.trimmingCharacters(in: .whitespaces) {
            case "round": lineJoin = .round
            case "bevel": lineJoin = .bevel
            default: lineJoin = .miter
            }
        }
        if let v = props["stroke-dasharray"] {
            let t = v.trimmingCharacters(in: .whitespaces)
            dash = t == "none" ? [] : SVGNumbers.list(t).map { CGFloat($0) }.filter { $0 >= 0 }
            if dash.count % 2 == 1 { dash += dash }
            if dash.allSatisfy({ $0 == 0 }) { dash = [] }
        }
        if let v = props["stroke-dashoffset"], let n = SVGNumbers.length(v, relativeTo: diag) { dashOffset = n }
        if let v = props["font-size"], let n = SVGNumbers.length(v, relativeTo: fontSize) { fontSize = max(1, n) }
        if let v = props["font-weight"] {
            switch v.trimmingCharacters(in: .whitespaces) {
            case "bold", "bolder", "700": fontWeight = .bold
            case "800": fontWeight = .heavy
            case "900": fontWeight = .black
            case "600": fontWeight = .semibold
            case "500": fontWeight = .medium
            case "300", "lighter": fontWeight = .light
            case "200": fontWeight = .thin
            case "100": fontWeight = .ultraLight
            default: fontWeight = .regular
            }
        }
        if let v = props["font-family"] { fontFamily = v.lowercased() }
        if let v = props["text-anchor"] { anchor = v.trimmingCharacters(in: .whitespaces) }
        if props["display"]?.trimmingCharacters(in: .whitespaces) == "none" { hidden = true }
        if let v = props["visibility"]?.trimmingCharacters(in: .whitespaces) { hidden = hidden || v == "hidden" || v == "collapse" }
    }

    static func paint(_ raw: String) -> SVGPaint? {
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if v == "none" || v == "transparent" { return SVGPaint.none }
        if v == "currentcolor" { return .current }
        if v.hasPrefix("url(") { return SVGPaint.none }   // gradients/patterns aren't supported
        return CSSColor.parse(v).map(SVGPaint.color)
    }

    func resolve(_ p: SVGPaint, alpha: CGFloat) -> CGColor? {
        let base: UIColor
        switch p {
        case .none: return nil
        case .current: base = color
        case .color(let c): base = c
        }
        return base.withAlphaComponent(base.cgColor.alpha * alpha * opacity).cgColor
    }

    var font: UIFont {
        let system = UIFont.systemFont(ofSize: fontSize, weight: fontWeight)
        if fontFamily.contains("mono") || fontFamily.contains("courier") || fontFamily.contains("menlo") {
            return UIFont.monospacedSystemFont(ofSize: fontSize, weight: fontWeight)
        }
        let design: UIFontDescriptor.SystemDesign? = fontFamily.contains("rounded") ? .rounded
            : (fontFamily.contains("serif") && !fontFamily.contains("sans")) ? .serif : nil
        if let design, let d = system.fontDescriptor.withDesign(design) { return UIFont(descriptor: d, size: fontSize) }
        return system
    }
}

// MARK: - Painting

final class SVGPainter {
    let cg: CGContext
    let viewport: CGSize
    let budget: Int
    private(set) var drawn = 0

    init(cg: CGContext, viewport: CGSize, budget: Int) {
        self.cg = cg
        self.viewport = viewport
        self.budget = budget
    }

    func drawChildren(of el: SVGElement, style: SVGStyle) {
        for child in el.children { draw(child, inherited: style) }
    }

    private func num(_ el: SVGElement, _ key: String, _ relative: CGFloat) -> CGFloat {
        el.attrs[key].flatMap { SVGNumbers.length($0, relativeTo: relative) } ?? 0
    }

    func draw(_ el: SVGElement, inherited: SVGStyle) {
        drawn += 1
        guard drawn <= budget else { return }
        switch el.name {
        case "defs", "title", "desc", "metadata", "style", "script", "linearGradient", "radialGradient",
             "pattern", "mask", "clipPath", "filter", "symbol", "marker":
            return
        default: break
        }
        var style = inherited
        style.apply(el.attrs, viewport: viewport)
        if style.hidden { return }

        cg.saveGState()
        defer { cg.restoreGState() }
        if let t = el.attrs["transform"] { cg.concatenate(SVGTransform.parse(t)) }

        let w = viewport.width, h = viewport.height
        switch el.name {
        case "svg", "g", "a", "switch":
            if el.name == "svg" {
                cg.translateBy(x: num(el, "x", w), y: num(el, "y", h))
            }
            drawChildren(of: el, style: style)
        case "path":
            if let d = el.attrs["d"] { paint(SVGPath.parse(d), style) }
        case "rect":
            let r = CGRect(x: num(el, "x", w), y: num(el, "y", h), width: num(el, "width", w), height: num(el, "height", h))
            guard r.width > 0, r.height > 0 else { return }
            var rx = el.attrs["rx"].flatMap { SVGNumbers.length($0, relativeTo: w) }
            var ry = el.attrs["ry"].flatMap { SVGNumbers.length($0, relativeTo: h) }
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let cw = min(max(rx ?? 0, 0), r.width / 2), ch = min(max(ry ?? 0, 0), r.height / 2)
            paint(CGPath(roundedRect: r, cornerWidth: cw, cornerHeight: ch, transform: nil), style)
        case "circle":
            let r = num(el, "r", min(w, h))
            guard r > 0 else { return }
            paint(CGPath(ellipseIn: CGRect(x: num(el, "cx", w) - r, y: num(el, "cy", h) - r, width: 2 * r, height: 2 * r), transform: nil), style)
        case "ellipse":
            let rx = num(el, "rx", w), ry = num(el, "ry", h)
            guard rx > 0, ry > 0 else { return }
            paint(CGPath(ellipseIn: CGRect(x: num(el, "cx", w) - rx, y: num(el, "cy", h) - ry, width: 2 * rx, height: 2 * ry), transform: nil), style)
        case "line":
            let p = CGMutablePath()
            p.move(to: CGPoint(x: num(el, "x1", w), y: num(el, "y1", h)))
            p.addLine(to: CGPoint(x: num(el, "x2", w), y: num(el, "y2", h)))
            var s = style
            s.fill = .none
            paint(p, s)
        case "polyline", "polygon":
            let v = SVGNumbers.list(el.attrs["points"] ?? "")
            guard v.count >= 4 else { return }
            let p = CGMutablePath()
            p.move(to: CGPoint(x: v[0], y: v[1]))
            var i = 2
            while i + 1 < v.count { p.addLine(to: CGPoint(x: v[i], y: v[i + 1])); i += 2 }
            if el.name == "polygon" { p.closeSubpath() }
            paint(p, style)
        case "text":
            drawText(el, style)
        default:
            return
        }
    }

    private func paint(_ path: CGPath, _ s: SVGStyle) {
        if let fill = s.resolve(s.fill, alpha: s.fillOpacity) {
            cg.addPath(path)
            cg.setFillColor(fill)
            cg.fillPath(using: s.evenOdd ? .evenOdd : .winding)
        }
        if s.strokeWidth > 0, let stroke = s.resolve(s.stroke, alpha: s.strokeOpacity) {
            cg.addPath(path)
            cg.setStrokeColor(stroke)
            cg.setLineWidth(s.strokeWidth)
            cg.setLineCap(s.lineCap)
            cg.setLineJoin(s.lineJoin)
            cg.setLineDash(phase: s.dashOffset, lengths: s.dash)
            cg.strokePath()
        }
    }

    private func drawText(_ el: SVGElement, _ style: SVGStyle) {
        var x = num(el, "x", viewport.width), y = num(el, "y", viewport.height)
        // <text>abc<tspan>def</tspan></text>: one run, styled by <text>; a tspan's own x/y moves it.
        func runs(_ e: SVGElement, _ s: SVGStyle) -> [(String, SVGStyle, CGPoint?)] {
            var out: [(String, SVGStyle, CGPoint?)] = []
            let own = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !own.isEmpty { out.append((own, s, nil)) }
            for c in e.children where c.name == "tspan" {
                var cs = s
                cs.apply(c.attrs, viewport: viewport)
                let pos: CGPoint? = (c.attrs["x"] != nil || c.attrs["y"] != nil)
                    ? CGPoint(x: c.attrs["x"].flatMap { SVGNumbers.length($0, relativeTo: viewport.width) } ?? .nan,
                              y: c.attrs["y"].flatMap { SVGNumbers.length($0, relativeTo: viewport.height) } ?? .nan)
                    : nil
                for (i, r) in runs(c, cs).enumerated() { out.append((r.0, r.1, i == 0 ? pos : r.2)) }
            }
            return out
        }
        for (text, s, pos) in runs(el, style) {
            if let pos {
                if !pos.x.isNaN { x = pos.x }
                if !pos.y.isNaN { y = pos.y }
            }
            guard let color = s.resolve(s.fill, alpha: s.fillOpacity) else { continue }
            let font = s.font
            let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor(cgColor: color)])
            let width = str.size().width
            let dx: CGFloat = s.anchor == "middle" ? -width / 2 : s.anchor == "end" ? -width : 0
            // SVG y is the baseline; UIKit draws from the top of the line box.
            UIGraphicsPushContext(cg)
            str.draw(at: CGPoint(x: x + dx, y: y - font.ascender))
            UIGraphicsPopContext()
            x += width
        }
    }
}

// MARK: - Numbers, transforms, paths

enum SVGNumbers {
    /// "12", "12px", "1.5e2", "50%" (of `relativeTo`). Other units are taken as px.
    static func length(_ raw: String, relativeTo: CGFloat) -> CGFloat? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("%") {
            s.removeLast()
            return Double(s).map { CGFloat($0) / 100 * relativeTo }
        }
        while let last = s.last, last.isLetter { s.removeLast() }
        return Double(s).map { CGFloat($0) }
    }

    static func opacity(_ raw: String) -> CGFloat? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("%") { return Double(s.dropLast()).map { CGFloat(min(max($0 / 100, 0), 1)) } }
        return Double(s).map { CGFloat(min(max($0, 0), 1)) }
    }

    static func list(_ raw: String) -> [Double] {
        var scanner = SVGScanner(raw)
        var out: [Double] = []
        while let n = scanner.number() { out.append(n) }
        return out
    }
}

/// Reads SVG number lists: "1-2", "1.5.5", "1e-3", separators of commas and/or spaces.
struct SVGScanner {
    private let bytes: [UInt8]
    private(set) var i = 0

    init(_ s: String) { bytes = Array(s.utf8) }

    var atEnd: Bool { mutating get { skipSeparators(); return i >= bytes.count } }

    mutating func skipSeparators() {
        while i < bytes.count, bytes[i] == 32 || bytes[i] == 44 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13 { i += 1 }
    }

    mutating func peekCommand() -> UInt8? {
        skipSeparators()
        guard i < bytes.count else { return nil }
        let c = bytes[i]
        let isLetter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
        return isLetter && c != 101 && c != 69 ? c : nil   // not 'e'/'E'
    }

    mutating func advance() { i += 1 }

    /// An arc flag: a single 0 or 1, which may be written with no separator after it.
    mutating func flag() -> Bool? {
        skipSeparators()
        guard i < bytes.count, bytes[i] == 48 || bytes[i] == 49 else { return nil }
        defer { i += 1 }
        return bytes[i] == 49
    }

    mutating func number() -> Double? {
        skipSeparators()
        let start = i
        if i < bytes.count, bytes[i] == 43 || bytes[i] == 45 { i += 1 }
        var digits = false, dot = false
        while i < bytes.count {
            let c = bytes[i]
            if c >= 48 && c <= 57 { digits = true; i += 1 }
            else if c == 46 && !dot { dot = true; i += 1 }
            else { break }
        }
        guard digits else { i = start; return nil }
        if i < bytes.count, bytes[i] == 101 || bytes[i] == 69 {
            let save = i
            i += 1
            if i < bytes.count, bytes[i] == 43 || bytes[i] == 45 { i += 1 }
            var exp = false
            while i < bytes.count, bytes[i] >= 48 && bytes[i] <= 57 { exp = true; i += 1 }
            if !exp { i = save }
        }
        return Double(String(decoding: bytes[start..<i], as: UTF8.self))
    }
}

enum SVGTransform {
    static func parse(_ raw: String) -> CGAffineTransform {
        var t = CGAffineTransform.identity
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n")).lowercased()
            let v = SVGNumbers.list(String(rest[rest.index(after: open)..<close])).map { CGFloat($0) }
            var m = CGAffineTransform.identity
            switch name {
            case "translate" where !v.isEmpty:
                m = CGAffineTransform(translationX: v[0], y: v.count > 1 ? v[1] : 0)
            case "scale" where !v.isEmpty:
                m = CGAffineTransform(scaleX: v[0], y: v.count > 1 ? v[1] : v[0])
            case "rotate" where !v.isEmpty:
                let a = v[0] * .pi / 180
                if v.count >= 3 {
                    m = CGAffineTransform(translationX: v[1], y: v[2]).rotated(by: a).translatedBy(x: -v[1], y: -v[2])
                } else {
                    m = CGAffineTransform(rotationAngle: a)
                }
            case "skewx" where !v.isEmpty:
                m = CGAffineTransform(a: 1, b: 0, c: tan(v[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewy" where !v.isEmpty:
                m = CGAffineTransform(a: 1, b: tan(v[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            case "matrix" where v.count == 6:
                m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            default:
                break
            }
            // "A B" applies B first, then A.
            t = m.concatenating(t)
            rest = rest[rest.index(after: close)...]
        }
        return t
    }
}

enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var s = SVGScanner(d)
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var cmd: UInt8 = 0

        func pt(_ rel: Bool) -> CGPoint? {
            guard let x = s.number(), let y = s.number() else { return nil }
            return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }

        while true {
            if let c = s.peekCommand() { cmd = c; s.advance() } else if s.atEnd || cmd == 0 { break }
            let rel = cmd >= 97
            var cubic: CGPoint?, quad: CGPoint?
            switch cmd | 0x20 {   // lowercase
            case 109: // m
                guard let p = pt(rel) else { return path }
                path.move(to: p); cur = p; start = p
                cmd = rel ? 108 : 76   // further pairs are lineto
            case 108: // l
                guard let p = pt(rel) else { return path }
                if path.isEmpty { path.move(to: cur) }
                path.addLine(to: p); cur = p
            case 104: // h
                guard let x = s.number() else { return path }
                if path.isEmpty { path.move(to: cur) }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur)
            case 118: // v
                guard let y = s.number() else { return path }
                if path.isEmpty { path.move(to: cur) }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur)
            case 99: // c
                guard let c1 = pt(rel), let c2 = pt(rel), let p = pt(rel) else { return path }
                if path.isEmpty { path.move(to: cur) }
                path.addCurve(to: p, control1: c1, control2: c2); cubic = c2; cur = p
            case 115: // s
                guard let c2 = pt(rel), let p = pt(rel) else { return path }
                if path.isEmpty { path.move(to: cur) }
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addCurve(to: p, control1: c1, control2: c2); cubic = c2; cur = p
            case 113: // q
                guard let c1 = pt(rel), let p = pt(rel) else { return path }
                if path.isEmpty { path.move(to: cur) }
                path.addQuadCurve(to: p, control: c1); quad = c1; cur = p
            case 116: // t
                guard let p = pt(rel) else { return path }
                if path.isEmpty { path.move(to: cur) }
                let c1 = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addQuadCurve(to: p, control: c1); quad = c1; cur = p
            case 97: // a
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(),
                      let large = s.flag(), let sweep = s.flag(), let p = pt(rel) else { return path }
                if path.isEmpty { path.move(to: cur) }
                addArc(path, from: cur, to: p, rx: abs(rx), ry: abs(ry), rotation: rot, large: large, sweep: sweep)
                cur = p
            case 122: // z
                path.closeSubpath(); cur = start
                cmd = 0
                lastCubic = nil; lastQuad = nil
                continue
            default:
                return path
            }
            lastCubic = cubic
            lastQuad = quad
        }
        return path
    }

    /// SVG endpoint arc -> center parameterization -> cubic Béziers (SVG spec, appendix B.2.4).
    static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: Double, ry: Double,
                       rotation: Double, large: Bool, sweep: Bool) {
        guard p0 != p1 else { return }
        var rx = rx, ry = ry
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (Double(p0.x) - Double(p1.x)) / 2, dy = (Double(p0.y) - Double(p1.y)) / 2
        let x1 = cosP * dx + sinP * dy
        let y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : (max(0, num / den)).squareRoot()
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry
        let cy1 = -coef * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (Double(p0.x) + Double(p1.x)) / 2
        let cy = sinP * cx1 + cosP * cy1 + (Double(p0.y) + Double(p1.y)) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func point(_ t: Double) -> (Double, Double) {
            (cx + rx * cos(t) * cosP - ry * sin(t) * sinP, cy + rx * cos(t) * sinP + ry * sin(t) * cosP)
        }
        func deriv(_ t: Double) -> (Double, Double) {
            (-rx * sin(t) * cosP - ry * cos(t) * sinP, -rx * sin(t) * sinP + ry * cos(t) * cosP)
        }
        var t = theta1
        for i in 0..<segments {
            let t2 = t + step
            let (ax, ay) = point(t), (bx, by) = point(t2)
            let (dax, day) = deriv(t), (dbx, dby) = deriv(t2)
            let end = i == segments - 1 ? p1 : CGPoint(x: bx, y: by)
            path.addCurve(to: end,
                          control1: CGPoint(x: ax + k * dax, y: ay + k * day),
                          control2: CGPoint(x: bx - k * dbx, y: by - k * dby))
            t = t2
        }
    }
}
