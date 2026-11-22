import Foundation

enum ScriptError: Error, LocalizedError, Equatable {
    case exception(message: String, line: Int?)
    case timeBudgetExceeded(seconds: Double)
    case internalFailure(String)

    var errorDescription: String? {
        switch self {
        case .exception(let m, let line):
            if let line { return "Script error (line \(line)): \(m)" }
            return "Script error: \(m)"
        case .timeBudgetExceeded(let s):
            return String(format: "Script exceeded its %.1f s time budget.", s)
        case .internalFailure(let s):
            return "Runtime failure: \(s)"
        }
    }
}
