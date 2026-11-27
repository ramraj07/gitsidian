import Foundation

/// Markdown task lines (`- [ ] text`, `* [x] text`, `1. [ ] text`) as checkboxes.
///
/// A widget checkbox is bound to one such line, by its text, in some vault file: the widget
/// file itself (tasks written inside a template string) or a note. Ticking it rewrites only
/// the `[ ]` / `[x]` of that line, so the rest of the file is left byte-for-byte alone.
enum TaskLines {
    struct Task: Equatable, Sendable {
        var text: String
        var checked: Bool
    }

    /// One line split around its box: `prefix` ends in "[", `mark` is " " / "x" / "X", `rest` starts with "]".
    private struct Parsed {
        var prefix: Substring
        var mark: Character
        var rest: Substring
        /// What follows "] ", trimmed.
        var text: String { String(rest.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
        var checked: Bool { mark != " " }
    }

    private static func parse(line: Substring) -> Parsed? {
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
        guard i < line.endIndex else { return nil }
        // Bullet: -, *, + or "12." / "12)".
        if "-*+".contains(line[i]) {
            i = line.index(after: i)
        } else {
            let digits = i
            while i < line.endIndex, line[i].isASCII, line[i].isNumber { i = line.index(after: i) }
            guard i > digits, i < line.endIndex, line[i] == "." || line[i] == ")" else { return nil }
            i = line.index(after: i)
        }
        // At least one space, then "[", one mark character, "]", then a space or the end.
        guard i < line.endIndex, line[i] == " " || line[i] == "\t" else { return nil }
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
        guard i < line.endIndex, line[i] == "[" else { return nil }
        let markIndex = line.index(after: i)
        guard markIndex < line.endIndex, " xX".contains(line[markIndex]) else { return nil }
        let close = line.index(after: markIndex)
        guard close < line.endIndex, line[close] == "]" else { return nil }
        let after = line.index(after: close)
        guard after == line.endIndex || line[after] == " " || line[after] == "\t" || line[after] == "\r" else { return nil }
        return Parsed(prefix: line[..<markIndex], mark: line[markIndex], rest: line[close...])
    }

    /// Every task line in `markdown`, in order. `\r` is dropped from the text.
    static func parse(_ markdown: String) -> [Task] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            return parse(line: line).map { Task(text: $0.text, checked: $0.checked) }
        }
    }

    /// Does this line's text match `text`? Tasks written in a widget file can end with the
    /// closing quote of the JS string they sit in ("- [ ] Call mom`);"), so a quote right after
    /// the text still counts.
    private static func matches(_ p: Parsed, _ text: String) -> Bool {
        let t = p.text
        if t == text { return true }
        guard t.hasPrefix(text) else { return false }
        return t.dropFirst(text.count).first.map { "`\"'".contains($0) } ?? false
    }

    enum SetResult: Equatable {
        case changed(String)
        /// Every matching line already had that state (ticked somewhere else first).
        case unchanged
        case notFound
    }

    /// Ticks or unticks the first line whose text is `text` and whose box isn't already in that state.
    static func set(_ text: String, checked: Bool, in source: String) -> SetResult {
        let want = text.trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty else { return .notFound }
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found = false
        for (n, line) in lines.enumerated() {
            guard let p = parse(line: Substring(line)), matches(p, want) else { continue }
            found = true
            if p.checked == checked { continue }
            lines[n] = String(p.prefix) + (checked ? "x" : " ") + String(p.rest)
            return .changed(lines.joined(separator: "\n"))
        }
        return found ? .unchanged : .notFound
    }
}
