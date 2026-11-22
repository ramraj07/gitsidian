import Foundation
import JavaScriptCore
import UIKit

// MARK: - JSExport protocols
//
// Swift methods with unlabeled parameters (`text(_:_:)`) export to JS under the
// selector's first segment ("text"), which is what gives the script the plain
// `page.text(str, opts)` shape from ARCHITECTURE.md "Runtime API (v1)".

@objc protocol GitsidianExports: JSExport {
    func widget() -> WidgetJS
    /// URL that opens a vault file in Gitsidian; relative paths resolve against the widget file's folder.
    func note(_ path: JSValue?) -> String
    var path: String { get }
    var repo: String { get }
    var branch: String { get }
    var family: String { get }
}

@objc protocol WidgetExports: JSExport {
    func page() -> ContainerJS
    func fullView(_ html: String)
    func refreshAfter(_ minutes: Double)
}

/// Page and row/column containers share one surface: every node method appends
/// to the container and returns the node handle.
@objc protocol ContainerExports: JSExport {
    func text(_ str: JSValue?, _ opts: JSValue?) -> NodeJS
    func image(_ src: JSValue?, _ opts: JSValue?) -> NodeJS
    func canvas(_ width: Double, _ height: Double, _ draw: JSValue?) -> NodeJS
    func timer(_ date: JSValue?) -> NodeJS
    func relativeDate(_ date: JSValue?) -> NodeJS
    func progress(_ start: JSValue?, _ end: JSValue?) -> NodeJS
    func gauge(_ value: Double, _ opts: JSValue?) -> NodeJS
    func list(_ items: JSValue?) -> NodeJS
    func row(_ builder: JSValue?) -> NodeJS
    func column(_ builder: JSValue?) -> NodeJS
    func spacer() -> NodeJS
    func button(_ label: JSValue?, _ target: JSValue?) -> NodeJS
    func chart(_ spec: JSValue?) -> NodeJS
}

@objc protocol NodeExports: JSExport {
    var kind: String { get }
}

// MARK: - Runtime state shared by the bridge objects

final class RuntimeState {
    static let minRefreshMinutes: Double = 5
    static let maxRefreshMinutes: Double = 1440

    let deadline: Date
    let now: Date
    var widget: WidgetJS?
    var pages: [ContainerJS] = []
    var fullView: String?
    var refreshAfter: Double?

    init(deadline: Date, now: Date) {
        self.deadline = deadline
        self.now = now
    }

    /// Called from every native entry point. A script that only loops in JS cannot be
    /// interrupted from here; the runner's watchdog covers that case.
    func checkBudget() -> Bool {
        if Date() > deadline {
            throwJS("Script exceeded its time budget")
            return false
        }
        return true
    }

    func throwJS(_ message: String) {
        guard let ctx = JSContext.current() else { return }
        ctx.exception = JSValue(newErrorFromMessage: message, in: ctx)
    }

    func build() -> WidgetProgram {
        WidgetProgram(
            pages: pages.map { $0.children },
            fullView: fullView,
            refreshAfterMinutes: refreshAfter
        )
    }
}

// MARK: - gitsidian (also bound as `kondai`, so Kondai scripts run unchanged)

@objc final class GitsidianJS: NSObject, GitsidianExports {
    let state: RuntimeState
    let file: WidgetFileContext
    init(state: RuntimeState, file: WidgetFileContext) {
        self.state = state
        self.file = file
    }

    var path: String { file.path }
    var repo: String { file.repo }
    var branch: String { file.branch }
    var family: String { file.family }

    func note(_ path: JSValue?) -> String {
        guard let raw = JSArgs.string(path), !raw.isEmpty else { return "" }
        return file.noteURL(raw)?.absoluteString ?? ""
    }

    func widget() -> WidgetJS {
        if let w = state.widget { return w }
        let w = WidgetJS(state: state)
        state.widget = w
        return w
    }
}

// MARK: - Widget

@objc final class WidgetJS: NSObject, WidgetExports {
    let state: RuntimeState
    init(state: RuntimeState) { self.state = state }

    /// Pages are numbered 1..n in creation order.
    func page() -> ContainerJS {
        let p = ContainerJS(state: state)
        state.pages.append(p)
        return p
    }

    func fullView(_ html: String) {
        state.fullView = html
    }

    /// Clamped to 5..1440 minutes.
    func refreshAfter(_ minutes: Double) {
        guard minutes.isFinite else { return }
        state.refreshAfter = Swift.min(Swift.max(minutes, RuntimeState.minRefreshMinutes), RuntimeState.maxRefreshMinutes)
    }
}

// MARK: - Node handle (opaque to the script apart from `kind`)

@objc final class NodeJS: NSObject, NodeExports {
    let node: WidgetNode
    init(_ node: WidgetNode) { self.node = node }
    var kind: String { node.kind }
}

// MARK: - Container (page, row, column)

@objc final class ContainerJS: NSObject, ContainerExports {
    let state: RuntimeState
    private(set) var children: [WidgetNode] = []

    init(state: RuntimeState) { self.state = state }

    private func add(_ node: WidgetNode) -> NodeJS {
        children.append(node)
        return NodeJS(node)
    }

    private func fail(_ message: String) -> NodeJS {
        state.throwJS(message)
        return NodeJS(.spacer)
    }

    // text(str, {font, color, align, lines})
    func text(_ str: JSValue?, _ opts: JSValue?) -> NodeJS {
        guard state.checkBudget() else { return NodeJS(.spacer) }
        let s = JSArgs.string(str) ?? ""
        var style = TextStyle()
        if let o = opts, o.isObject {
            if let f = JSArgs.string(o.forProperty("font")), let font = TextFont(rawValue: f) { style.font = font }
            if let c = JSArgs.string(o.forProperty("color")) { style.color = c }
            if let a = JSArgs.string(o.forProperty("align")), let align = TextAlign(rawValue: a) { style.align = align }
            // 0 = unlimited (the default).
            if let n = JSArgs.number(o.forProperty("lines")), n >= 1 { style.lines = Int(n) }
        }
        return add(.text(s, style))
    }

    // image(base64 | dataURL, {width, height, corner})
    func image(_ src: JSValue?, _ opts: JSValue?) -> NodeJS {
        guard state.checkBudget() else { return NodeJS(.spacer) }
        guard let s = JSArgs.string(src), let data = ImageDecoding.decode(s) else {
            return fail("image(): expected base64 or data URL")
        }
        var node = ImageNode(data: data)
        if let o = opts, o.isObject {
            node.width = JSArgs.number(o.forProperty("width"))
            node.height = JSArgs.number(o.forProperty("height"))
            node.corner = JSArgs.number(o.forProperty("corner"))
        }
        return add(.image(node))
    }

    // canvas(w, h, (ctx) => ...)
    func canvas(_ width: Double, _ height: Double, _ draw: JSValue?) -> NodeJS {
        guard state.checkBudget() else { return NodeJS(.spacer) }
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 2000, height <= 2000 else {
            return fail("canvas(): width/height must be positive numbers (max 2000)")
        }
        guard let fn = draw, !fn.isUndefined, !fn.isNull else {
            return fail("canvas(): missing draw function")
        }
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var error: JSValue?
        let png = renderer.pngData { rc in
            let ctx = CanvasContextJS(cg: rc.cgContext, state: state)
            let ctxValue = JSValue(object: ctx, in: fn.context)
            fn.call(withArguments: [ctxValue as Any])
            if let e = fn.context.exception { error = e }
        }
        if let error {
            // Re-raise so the script fails loudly rather than drawing nothing.
            fn.context.exception = error
            return NodeJS(.spacer)
        }
        return add(.canvas(CanvasNode(png: png, width: width, height: height)))
    }

    func timer(_ date: JSValue?) -> NodeJS {
        guard state.checkBudget() else { return NodeJS(.spacer) }
        guard let d = JSArgs.date(date) else { return fail("timer(): expected an ISO-8601 string or Date") }
        return add(.timer(d))
    }

    func relativeDate(_ date: JSValue?) -> NodeJS {
        guard state.checkBudget() else { return NodeJS(.spacer) }
        guard let d = JSArgs.date(date) else { return fail("relativeDate(): expected an ISO-8601 string or Date") }
        return add(.relativeDate(d))
    }

    func progress(_ start: JSValue?, _ end: JSValue?) -> NodeJS {
        guard state.checkBudget() else { return NodeJS(.spacer) }
        guard let s = JSArgs.date(start), let e = JSArgs.date(end) else {
            return fail("progress(): expected two dates (ISO-8601 string or Date)")
        }
        return add(.progress(start: Swift.min(s, e), end: Swift.max(s, e)))
    }

    // gauge(value, {min, max, label}); min/max default 0..1
    func gauge(_ value: Double, _ opts: JSValue?) -> NodeJS {
        guard state.checkBudget() else { return NodeJS(.spacer) }
        var g = GaugeNode(value: value.isFinite ? value : 0)
        if let o = opts, o.isObject {
            if let n = JSArgs.number(o.forProperty("min")) { g.min = n }
            if let n = JSArgs.number(o.forProperty("max")) { g.max = n }
            g.label = JSArgs.string(o.forProperty("label"))
        }
        if g.max <= g.min { g.max = g.min + 1 }
        g.value = Swift.min(Swift.max(g.value, g.min), g.max)
        return add(.gauge(g))
    }

    func list(_ items: JSValue?) -> NodeJS {
        guard state.checkBudget() else { return NodeJS(.spacer) }
        guard let arr = items, arr.isArray else { return fail("list(): expected an array") }
        var out: [ListItem] = []
        let n = Int(arr.forProperty("length").toInt32())
        for i in 0..<Swift.min(n, 50) {
            let item = arr.atIndex(i)!
            if item.isString {
                out.append(ListItem(title: item.toString()))
                continue
            }
            guard item.isObject else { continue }
            let title = JSArgs.string(item.forProperty("title")) ?? ""
            let detail = JSArgs.string(item.forProperty("detail"))
            let url = JSArgs.string(item.forProperty("url")).flatMap(URL.init(string:))
            out.append(ListItem(title: title, detail: detail, url: url))
        }
        return add(.list(out))
    }

    // row(fn) / column(fn): fn receives a container with the same methods.
    func row(_ builder: JSValue?) -> NodeJS {
        guard let children = buildChildren(builder, name: "row") else { return NodeJS(.spacer) }
        return add(.row(children))
    }

    func column(_ builder: JSValue?) -> NodeJS {
        guard let children = buildChildren(builder, name: "column") else { return NodeJS(.spacer) }
        return add(.column(children))
    }

    private func buildChildren(_ builder: JSValue?, name: String) -> [WidgetNode]? {
        guard state.checkBudget() else { return nil }
        guard let fn = builder, fn.isObject,
              JSObjectIsFunction(fn.context.jsGlobalContextRef, fn.jsValueRef) else {
            state.throwJS("\(name)(): expected a builder function")
            return nil
        }
        let inner = ContainerJS(state: state)
        let innerValue = JSValue(object: inner, in: fn.context)
        fn.call(withArguments: [innerValue as Any])
        if fn.context.exception != nil { return nil }
        return inner.children
    }

    func spacer() -> NodeJS {
        guard state.checkBudget() else { return NodeJS(.spacer) }
        return add(.spacer)
    }

    // button(label, url) | button(label, {page: n})   n is 1-based
    func button(_ label: JSValue?, _ target: JSValue?) -> NodeJS {
        guard state.checkBudget() else { return NodeJS(.spacer) }
        let text = JSArgs.string(label) ?? ""
        if let t = target, t.isObject, !t.isString {
            guard let p = JSArgs.number(t.forProperty("page")), p >= 1 else {
                return fail("button(): expected {page: n} with n >= 1")
            }
            return add(.pageButton(label: text, page: Int(p)))
        }
        guard let s = JSArgs.string(target), let url = URL(string: s) else {
            return fail("button(): expected a URL string or {page: n}")
        }
        return add(.link(label: text, url: url))
    }

    // chart({type, data: [{x, y}], color})
    func chart(_ spec: JSValue?) -> NodeJS {
        guard state.checkBudget() else { return NodeJS(.spacer) }
        guard let s = spec, s.isObject else { return fail("chart(): expected a spec object") }
        let type = ChartType(rawValue: JSArgs.string(s.forProperty("type")) ?? "bar") ?? .bar
        var points: [ChartPoint] = []
        if let data = s.forProperty("data"), data.isArray {
            let n = Int(data.forProperty("length").toInt32())
            for i in 0..<Swift.min(n, 500) {
                let p = data.atIndex(i)!
                if p.isObject {
                    let x = JSArgs.string(p.forProperty("x")) ?? String(i)
                    let y = JSArgs.number(p.forProperty("y")) ?? 0
                    points.append(ChartPoint(x: x, y: y))
                } else if let y = JSArgs.number(p) {
                    points.append(ChartPoint(x: String(i), y: y))
                }
            }
        }
        return add(.chart(ChartSpec(type: type, data: points, color: JSArgs.string(s.forProperty("color")))))
    }
}

// MARK: - Argument coercion

enum JSArgs {
    static func string(_ v: JSValue?) -> String? {
        guard let v, !v.isUndefined, !v.isNull else { return nil }
        if v.isString { return v.toString() }
        if v.isNumber || v.isBoolean { return v.toString() }
        return nil
    }

    static func number(_ v: JSValue?) -> Double? {
        guard let v, v.isNumber else { return nil }
        let d = v.toDouble()
        return d.isFinite ? d : nil
    }

    static func date(_ v: JSValue?) -> Date? {
        guard let v, !v.isUndefined, !v.isNull else { return nil }
        if v.isDate { return v.toDate() }
        if v.isNumber { return Date(timeIntervalSince1970: v.toDouble() / 1000) }
        if v.isString { return DateParsing.parse(v.toString()) }
        return nil
    }
}

enum ImageDecoding {
    static func decode(_ s: String) -> Data? {
        var payload = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("data:") {
            guard let comma = payload.firstIndex(of: ",") else { return nil }
            payload = String(payload[payload.index(after: comma)...])
        }
        payload = payload.filter { !$0.isWhitespace }
        return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
    }
}
