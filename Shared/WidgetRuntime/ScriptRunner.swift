import Foundation
import JavaScriptCore

/// Runs a widget script in a fresh JavaScriptCore context and returns the tree.
///
/// Sandbox: a bare `JSContext` has no timers, no network, no filesystem, no
/// `console`. The runtime adds `gitsidian` (aliased as `kondai`). `Math.random` is
/// replaced with a seeded PRNG so a given script always yields the same tree.
enum ScriptRunner {
    static let defaultTimeBudget: TimeInterval = 2.0

    /// - Parameters:
    ///   - script: the plaintext widget script.
    ///   - timeBudget: wall-clock budget. Native entry points throw once it is
    ///     exceeded; a script that spins in pure JS is abandoned by the watchdog.
    ///   - now: injected clock for deterministic tests.
    static func run(script: String, file: WidgetFileContext = .preview, timeBudget: TimeInterval = defaultTimeBudget, now: Date = Date()) throws -> WidgetProgram {
        final class Box: @unchecked Sendable { var result: Result<WidgetProgram, Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.result = Result { try runOnCurrentThread(script: script, file: file, timeBudget: timeBudget, now: now) }
            done.signal()
        }
        thread.name = "com.gitsidian.widget-script"
        thread.stackSize = 4 << 20
        thread.start()
        // Small grace period: native checks already fire at `timeBudget`.
        if done.wait(timeout: .now() + timeBudget + 0.5) == .timedOut {
            throw ScriptError.timeBudgetExceeded(seconds: timeBudget)
        }
        guard let result = box.result else { throw ScriptError.internalFailure("no result") }
        return try result.get()
    }

    static func runOnCurrentThread(script: String, file: WidgetFileContext, timeBudget: TimeInterval, now: Date) throws -> WidgetProgram {
        let vm = JSVirtualMachine()
        guard let context = JSContext(virtualMachine: vm) else {
            throw ScriptError.internalFailure("could not create JSContext")
        }
        context.name = "gitsidian.widget"
        let state = RuntimeState(deadline: Date().addingTimeInterval(timeBudget), now: now)

        var captured: (String, Int?)?
        context.exceptionHandler = { _, exception in
            guard captured == nil, let exception else { return }
            let message = exception.toString() ?? "unknown error"
            let line = exception.forProperty("line").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
            captured = (message, line)
        }

        let api = GitsidianJS(state: state, file: file)
        context.setObject(api, forKeyedSubscript: "gitsidian" as NSString)
        context.setObject(api, forKeyedSubscript: "kondai" as NSString)
        context.evaluateScript(prelude)
        if let (m, l) = captured { throw ScriptError.exception(message: m, line: l) }

        context.evaluateScript(script, withSourceURL: URL(string: "gitsidian-widget://" + file.path))
        if let (m, l) = captured { throw ScriptError.exception(message: m, line: l) }

        return state.build()
    }

    /// Deterministic `Math.random` (mulberry32) and a `console` that swallows output
    /// (so scripts written with console.log do not throw).
    static let prelude = """
    (function () {
      var seed = 0x6b6f6e64; // "kond"
      Math.random = function () {
        seed = (seed + 0x6D2B79F5) | 0;
        var t = seed;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
      };
      var noop = function () {};
      this.console = { log: noop, info: noop, warn: noop, error: noop, debug: noop };
      this.globalThis = this;
    })();
    """
}
