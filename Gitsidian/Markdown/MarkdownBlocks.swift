import Foundation
import SwiftUI

struct MDBlock: Identifiable {
    let id: Int
    let kind: Kind

    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(indent: Int, marker: String, text: String)
        case task(indent: Int, done: Bool, text: String, line: Int?)
        case quote(String)
        case callout(type: String, title: String, body: String, folded: Bool)
        case code(lang: String, code: String)
        case rule
        case table(header: [String], rows: [[String]])
        case embed(String)
        case properties([(String, String)])
    }
}

/// A small block-level markdown parser covering what Obsidian notes typically use.
enum MarkdownParser {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let heading = re(#"^(#{1,6})[ \t]+(.*?)[ \t#]*$"#)
    private static let task = re(#"^([ \t]*)[-*+][ \t]+\[([ xX/\-])\][ \t]?(.*)$"#)
    private static let list = re(#"^([ \t]*)([-*+]|\d+[.)])[ \t]+(.*)$"#)
    private static let rule = re(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let tableSep = re(#"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
    private static let wikiEmbed = re(#"^!\[\[([^\]]+)\]\]$"#)
    private static let mdEmbed = re(#"^!\[[^\]]*\]\(([^)]+)\)$"#)
    private static let calloutHead = re(#"^\[!([\w-]+)\]([+-]?)[ \t]*(.*)$"#)

    private static func m(_ r: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let x = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<x.numberOfRanges).map { x.range(at: $0).location == NSNotFound ? "" : ns.substring(with: x.range(at: $0)) }
    }

    private static func indentLevel(_ ws: String) -> Int {
        ws.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    static func parse(_ text: String, lineOffset: Int? = 0) -> [MDBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var para: [String] = []
        var i = 0
        func add(_ k: MDBlock.Kind) { blocks.append(MDBlock(id: blocks.count, kind: k)) }
        func flush() {
            if !para.isEmpty { add(.paragraph(para.joined(separator: "\n"))); para = [] }
        }

        // Frontmatter → properties
        if lineOffset == 0, lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            var props: [(String, String)] = []
            for l in lines[1..<end] {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- "), !props.isEmpty {
                    let v = String(t.dropFirst(2))
                    props[props.count - 1].1 += props[props.count - 1].1.isEmpty ? v : ", " + v
                } else if let colon = l.firstIndex(of: ":"), !l.hasPrefix(" ") {
                    let k = String(l[..<colon]).trimmingCharacters(in: .whitespaces)
                    var v = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if v.hasPrefix("[") && v.hasSuffix("]") { v = String(v.dropFirst().dropLast()) }
                    props.append((k, v))
                }
            }
            if !props.isEmpty { add(.properties(props)) }
            i = end + 1
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                add(.code(lang: lang, code: code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            if trimmed.hasPrefix("%%") {
                flush()
                // Obsidian comments are hidden in reading view.
                if trimmed.count >= 4, trimmed.hasSuffix("%%"), trimmed != "%%" { i += 1; continue }
                i += 1
                while i < lines.count, !lines[i].contains("%%") { i += 1 }
                i += 1
                continue
            }
            if let g = m(heading, line) { flush(); add(.heading(level: g[1].count, text: g[2])); i += 1; continue }
            if m(rule, line) != nil, para.isEmpty || trimmed.hasPrefix("*") || trimmed.hasPrefix("_") {
                flush(); add(.rule); i += 1; continue
            }
            if let g = m(wikiEmbed, trimmed) ?? m(mdEmbed, trimmed) { flush(); add(.embed(g[1])); i += 1; continue }
            if let g = m(task, line) {
                flush()
                add(.task(indent: indentLevel(g[1]), done: g[2] != " ", text: g[3], line: lineOffset.map { $0 + i }))
                i += 1; continue
            }
            if let g = m(list, line) {
                flush()
                let marker = g[2].first!.isNumber ? g[2] : "•"
                add(.listItem(indent: indentLevel(g[1]), marker: marker, text: g[3]))
                i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var l = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if l.hasPrefix(" ") { l = l.dropFirst() }
                    q.append(String(l)); i += 1
                }
                if let first = q.first, let g = m(calloutHead, first) {
                    let title = g[3].isEmpty ? g[1].prefix(1).uppercased() + g[1].dropFirst().lowercased() : g[3]
                    add(.callout(type: g[1].lowercased(), title: title, body: q.dropFirst().joined(separator: "\n"), folded: g[2] == "-"))
                } else {
                    add(.quote(q.joined(separator: "\n")))
                }
                continue
            }
            if line.contains("|"), i + 1 < lines.count, m(tableSep, lines[i + 1]) != nil {
                flush()
                func cells(_ s: String) -> [String] {
                    var t = s.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("|") { t.removeFirst() }
                    if t.hasSuffix("|") { t.removeLast() }
                    return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i])); i += 1
                }
                add(.table(header: header, rows: rows))
                continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return blocks
    }
}

enum Inline {
    private static let highlight = try! NSRegularExpression(pattern: #"==(?=\S)(.+?)(?<=\S)=="#)
    private static let tag = try! NSRegularExpression(pattern: #"(?<![\w#&/\]\(])#([\p{L}\p{N}_\-/]*[\p{L}_\-/][\p{L}\p{N}_\-/]*)"#)
    private static let comment = try! NSRegularExpression(pattern: #"%%.*?%%"#)

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    /// Inline markdown → AttributedString. Wikilinks become gitsidian://open links, tags gitsidian://tag links.
    static func attributed(_ source: String) -> AttributedString {
        var s = source
        let full = { NSRange(location: 0, length: (s as NSString).length) }
        s = comment.stringByReplacingMatches(in: s, range: full(), withTemplate: "")

        // Wikilinks (embeds inside a paragraph render as links).
        let ns = s as NSString
        var out = ""
        var last = 0
        for match in Links.wikiRegex.matches(in: s, range: full()) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let (target, alias) = Links.split(ns.substring(with: match.range(at: 2)))
            var label = alias ?? target
            if alias == nil, let hash = target.firstIndex(of: "#") {
                let page = target[..<hash], sub = target[target.index(after: hash)...]
                label = page.isEmpty ? String(sub) : "\(page) › \(sub)"
            }
            let escaped = label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            out += "[\(escaped)](gitsidian://open?t=\(encode(target)))"
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        s = out
        s = tag.stringByReplacingMatches(in: s, range: full(), withTemplate: "[#$1](gitsidian://tag?t=$1)")

        var marks: [String] = []
        for m in highlight.matches(in: s, range: full()) { marks.append((s as NSString).substring(with: m.range(at: 1))) }
        s = highlight.stringByReplacingMatches(in: s, range: full(), withTemplate: "$1")

        let opts = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var a = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(source)
        for mark in marks {
            if let r = a.range(of: mark) { a[r].backgroundColor = Color.yellow.opacity(0.35) }
        }
        return a
    }
}
