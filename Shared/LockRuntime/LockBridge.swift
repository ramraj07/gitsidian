import Foundation
import JavaScriptCore

// The `*.gitsidian.lock` API. Each Lock Screen size has its own small builder, made for
// how little fits there; nothing is shrunk from a Home Screen layout.
//
//   const lock = gitsidian.lockScreen();
//   lock.circular(c => c.ring(0.7, { center: "7k", symbol: "figure.walk" }));
//   lock.rectangular(r => { r.title("Inbox", { symbol: "tray" }); r.line("Reply to Sam", { trailing: "2 pm" }); });
//   lock.inline(i => i.text("3 due", { symbol: "checklist" }));

@objc protocol LockScreenExports: JSExport {
    func circular(_ build: JSValue?)
    func rectangular(_ build: JSValue?)
    func inline(_ build: JSValue?)
    func refreshAfter(_ minutes: Double)
}

@objc protocol CircularExports: JSExport {
    func ring(_ value: Double, _ opts: JSValue?)
    func gauge(_ value: Double, _ opts: JSValue?)
    func timeRing(_ start: JSValue?, _ end: JSValue?, _ opts: JSValue?)
    func number(_ text: JSValue?, _ opts: JSValue?)
    func symbol(_ name: JSValue?, _ opts: JSValue?)
    func countdown(_ date: JSValue?, _ opts: JSValue?)
    func svg(_ markup: JSValue?)
    func canvas(_ draw: JSValue?)
}

@objc protocol RectangularExports: JSExport {
    func title(_ text: JSValue?, _ opts: JSValue?)
    func line(_ text: JSValue?, _ opts: JSValue?)
    func bar(_ value: Double, _ opts: JSValue?)
    func timeBar(_ start: JSValue?, _ end: JSValue?, _ opts: JSValue?)
    func countdown(_ date: JSValue?, _ opts: JSValue?)
    func relative(_ date: JSValue?, _ opts: JSValue?)
    func sparkline(_ values: JSValue?, _ opts: JSValue?)
    func svg(_ markup: JSValue?, _ opts: JSValue?)
    func canvas(_ draw: JSValue?, _ opts: JSValue?)
}

@objc protocol InlineExports: JSExport {
    func text(_ text: JSValue?, _ opts: JSValue?)
    func countdown(_ date: JSValue?, _ opts: JSValue?)
    func relative(_ date: JSValue?, _ opts: JSValue?)
}

/// Design sizes in points. Real sizes vary a little by phone; drawings scale to fit.
enum LockSize {
    static let circular = CGSize(width: 76, height: 76)
    static let rectangular = CGSize(width: 172, height: 76)
    static let rowHeight: CGFloat = 24
    static let maxRows = 3
}

@objc final class LockScreenJS: NSObject, LockScreenExports {
    let state: RuntimeState
    let file: WidgetFileContext
    var circularFace: LockFace?
    var rectangularRows: [LockRow]?
    var inlineLine: LockInline?

    init(state: RuntimeState, file: WidgetFileContext) {
        self.state = state
        self.file = file
    }

    private func run(_ build: JSValue?, _ name: String, _ builder: NSObject) -> Bool {
        guard state.checkBudget() else { return false }
        guard let fn = build, fn.isObject, JSObjectIsFunction(fn.context.jsGlobalContextRef, fn.jsValueRef) else {
            state.throwJS("\(name)(): expected a builder function, e.g. lock.\(name)(c => …)")
            return false
        }
        fn.call(withArguments: [JSValue(object: builder, in: fn.context) as Any])
        return fn.context.exception == nil
    }

    func circular(_ build: JSValue?) {
        let b = CircularJS(state: state)
        if run(build, "circular", b) { circularFace = b.face }
    }

    func rectangular(_ build: JSValue?) {
        let b = RectangularJS(state: state)
        if run(build, "rectangular", b) { rectangularRows = b.rows }
    }

    func inline(_ build: JSValue?) {
        let b = InlineJS(state: state)
        if run(build, "inline", b) { inlineLine = b.line }
    }

    func refreshAfter(_ minutes: Double) {
        guard minutes.isFinite else { return }
        state.refreshAfter = Swift.min(Swift.max(minutes, RuntimeState.minRefreshMinutes), RuntimeState.maxRefreshMinutes)
    }
}

// MARK: - Shared option parsing

enum LockArgs {
    static func string(_ o: JSValue?, _ key: String) -> String? {
        guard let o, o.isObject else { return nil }
        return JSArgs.string(o.forProperty(key)).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func number(_ o: JSValue?, _ key: String) -> Double? {
        guard let o, o.isObject else { return nil }
        return JSArgs.number(o.forProperty(key))
    }

    static func center(_ o: JSValue?) -> LockLabel? {
        let l = LockLabel(text: string(o, "center"), symbol: string(o, "symbol"))
        return l.isEmpty ? nil : l
    }

    static func gauge(_ value: Double, _ o: JSValue?) -> LockGauge {
        var g = LockGauge(value: value.isFinite ? value : 0)
        if let n = number(o, "min") { g.min = n }
        if let n = number(o, "max") { g.max = n }
        if g.max <= g.min { g.max = g.min + 1 }
        g.value = Swift.min(Swift.max(g.value, g.min), g.max)
        g.center = center(o)
        g.label = string(o, "label")
        g.minLabel = string(o, "minLabel")
        g.maxLabel = string(o, "maxLabel")
        return g
    }

    static func svg(_ markup: JSValue?, width: Double? = nil, height: Double? = nil, fitting: CGSize, state: RuntimeState, name: String) -> LockPicture? {
        guard let s = JSArgs.string(markup), !s.isEmpty else {
            state.throwJS("\(name).svg(): expected an SVG string")
            return nil
        }
        do {
            let r = try SVGRenderer.render(s, width: width, height: height, fitting: fitting)
            return LockPicture(png: r.png, width: r.size.width, height: r.size.height)
        } catch {
            state.throwJS(error.localizedDescription)
            return nil
        }
    }

    static func canvas(_ draw: JSValue?, size: CGSize, state: RuntimeState, name: String) -> LockPicture? {
        guard let fn = draw, fn.isObject, JSObjectIsFunction(fn.context.jsGlobalContextRef, fn.jsValueRef) else {
            state.throwJS("\(name).canvas(): expected a draw function (ctx => …)")
            return nil
        }
        guard let png = CanvasRendering.png(width: size.width, height: size.height, draw: fn, state: state) else { return nil }
        return LockPicture(png: png, width: size.width, height: size.height)
    }
}

// MARK: - circular: exactly one thing

@objc final class CircularJS: NSObject, CircularExports {
    let state: RuntimeState
    var face: LockFace?
    init(state: RuntimeState) { self.state = state }

    private func set(_ f: LockFace?, _ name: String) {
        guard state.checkBudget(), let f else { return }
        if face != nil {
            state.throwJS("circular.\(name)(): a circular widget shows one thing, and one is already set")
            return
        }
        face = f
    }

    func ring(_ value: Double, _ opts: JSValue?) { set(.ring(LockArgs.gauge(value, opts)), "ring") }
    func gauge(_ value: Double, _ opts: JSValue?) { set(.gauge(LockArgs.gauge(value, opts)), "gauge") }

    func timeRing(_ start: JSValue?, _ end: JSValue?, _ opts: JSValue?) {
        guard let s = JSArgs.date(start), let e = JSArgs.date(end) else {
            state.throwJS("circular.timeRing(): expected two dates (ISO-8601 string or Date)")
            return
        }
        set(.timeRing(start: Swift.min(s, e), end: Swift.max(s, e), center: LockArgs.center(opts)), "timeRing")
    }

    func number(_ text: JSValue?, _ opts: JSValue?) {
        guard let t = JSArgs.string(text) else { state.throwJS("circular.number(): expected text or a number"); return }
        set(.number(t, caption: LockArgs.string(opts, "caption"), symbol: LockArgs.string(opts, "symbol")), "number")
    }

    func symbol(_ name: JSValue?, _ opts: JSValue?) {
        guard let n = JSArgs.string(name), !n.isEmpty else { state.throwJS("circular.symbol(): expected an SF Symbol name"); return }
        set(.symbol(n, caption: LockArgs.string(opts, "caption")), "symbol")
    }

    func countdown(_ date: JSValue?, _ opts: JSValue?) {
        guard let d = JSArgs.date(date) else { state.throwJS("circular.countdown(): expected a date"); return }
        set(.countdown(d, caption: LockArgs.string(opts, "caption")), "countdown")
    }

    func svg(_ markup: JSValue?) {
        set(LockArgs.svg(markup, fitting: LockSize.circular, state: state, name: "circular").map(LockFace.picture), "svg")
    }

    func canvas(_ draw: JSValue?) {
        set(LockArgs.canvas(draw, size: LockSize.circular, state: state, name: "circular").map(LockFace.picture), "canvas")
    }
}

// MARK: - rectangular: up to 3 rows

@objc final class RectangularJS: NSObject, RectangularExports {
    let state: RuntimeState
    var rows: [LockRow] = []
    init(state: RuntimeState) { self.state = state }

    private func add(_ row: LockRow?, _ name: String) {
        guard state.checkBudget(), let row else { return }
        if rows.count >= LockSize.maxRows {
            state.throwJS("rectangular.\(name)(): a rectangular widget fits \(LockSize.maxRows) rows; pick what matters most")
            return
        }
        rows.append(row)
    }

    func title(_ text: JSValue?, _ opts: JSValue?) {
        add(.title(JSArgs.string(text) ?? "", symbol: LockArgs.string(opts, "symbol")), "title")
    }

    func line(_ text: JSValue?, _ opts: JSValue?) {
        let mono = (opts?.isObject ?? false) && (opts?.forProperty("mono")?.toBool() ?? false)
        add(.line(JSArgs.string(text) ?? "", symbol: LockArgs.string(opts, "symbol"),
                  trailing: LockArgs.string(opts, "trailing"), mono: mono), "line")
    }

    func bar(_ value: Double, _ opts: JSValue?) { add(.bar(LockArgs.gauge(value, opts)), "bar") }

    func timeBar(_ start: JSValue?, _ end: JSValue?, _ opts: JSValue?) {
        guard let s = JSArgs.date(start), let e = JSArgs.date(end) else {
            state.throwJS("rectangular.timeBar(): expected two dates (ISO-8601 string or Date)")
            return
        }
        add(.timeBar(start: Swift.min(s, e), end: Swift.max(s, e), label: LockArgs.string(opts, "label")), "timeBar")
    }

    func countdown(_ date: JSValue?, _ opts: JSValue?) {
        guard let d = JSArgs.date(date) else { state.throwJS("rectangular.countdown(): expected a date"); return }
        add(.countdown(d, label: LockArgs.string(opts, "label")), "countdown")
    }

    func relative(_ date: JSValue?, _ opts: JSValue?) {
        guard let d = JSArgs.date(date) else { state.throwJS("rectangular.relative(): expected a date"); return }
        add(.relative(d, label: LockArgs.string(opts, "label")), "relative")
    }

    func sparkline(_ values: JSValue?, _ opts: JSValue?) {
        guard let arr = values, arr.isArray else { state.throwJS("rectangular.sparkline(): expected an array of numbers"); return }
        let n = Swift.min(Int(arr.forProperty("length").toInt32()), 200)
        let ys = (0..<n).compactMap { JSArgs.number(arr.atIndex($0)) }
        let type = LockArgs.string(opts, "type").flatMap(ChartType.init(rawValue:)) ?? .line
        add(.sparkline(ys, type: type), "sparkline")
    }

    /// The first picture defaults to the whole widget (172×76); later ones to a 24 pt row.
    private func pictureBox(_ opts: JSValue?) -> CGSize {
        let h = LockArgs.number(opts, "height").map { Swift.min(Swift.max(CGFloat($0), 8), LockSize.rectangular.height) }
        return CGSize(width: LockSize.rectangular.width, height: h ?? (rows.isEmpty ? LockSize.rectangular.height : LockSize.rowHeight))
    }

    func svg(_ markup: JSValue?, _ opts: JSValue?) {
        add(LockArgs.svg(markup, fitting: pictureBox(opts), state: state, name: "rectangular").map(LockRow.picture), "svg")
    }

    func canvas(_ draw: JSValue?, _ opts: JSValue?) {
        add(LockArgs.canvas(draw, size: pictureBox(opts), state: state, name: "rectangular").map(LockRow.picture), "canvas")
    }
}

// MARK: - inline: one line of text with an optional symbol

@objc final class InlineJS: NSObject, InlineExports {
    let state: RuntimeState
    var line: LockInline?
    init(state: RuntimeState) { self.state = state }

    private func set(_ l: LockInline, _ name: String) {
        guard state.checkBudget() else { return }
        if line != nil {
            state.throwJS("inline.\(name)(): an inline widget is one line, and it is already set")
            return
        }
        line = l
    }

    func text(_ text: JSValue?, _ opts: JSValue?) {
        set(LockInline(text: JSArgs.string(text) ?? "", symbol: LockArgs.string(opts, "symbol")), "text")
    }

    func countdown(_ date: JSValue?, _ opts: JSValue?) {
        guard let d = JSArgs.date(date) else { state.throwJS("inline.countdown(): expected a date"); return }
        set(LockInline(text: LockArgs.string(opts, "text") ?? "", symbol: LockArgs.string(opts, "symbol"), date: d, dateStyle: .timer), "countdown")
    }

    func relative(_ date: JSValue?, _ opts: JSValue?) {
        guard let d = JSArgs.date(date) else { state.throwJS("inline.relative(): expected a date"); return }
        set(LockInline(text: LockArgs.string(opts, "text") ?? "", symbol: LockArgs.string(opts, "symbol"), date: d, dateStyle: .relative), "relative")
    }
}
