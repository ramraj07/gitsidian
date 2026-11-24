import Foundation

enum Links {
    static let wikiRegex = try! NSRegularExpression(pattern: #"(!?)\[\[([^\[\]\n]+?)\]\]"#)

    /// "Note#Heading|alias" -> ("Note#Heading", "alias")
    static func split(_ inner: String) -> (target: String, alias: String?) {
        if let bar = inner.firstIndex(of: "|") {
            return (String(inner[..<bar]), String(inner[inner.index(after: bar)...]))
        }
        return (inner, nil)
    }

    /// "Note#Heading" -> "Heading", "Note#^id" -> "^id", "Note" -> nil
    static func subpath(_ target: String) -> String? {
        guard let i = target.firstIndex(of: "#") else { return nil }
        let s = target[target.index(after: i)...].trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func stripSubpath(_ target: String) -> String {
        var t = target
        if let i = t.firstIndex(of: "#") { t = String(t[..<i]) }
        if let i = t.firstIndex(of: "^") { t = String(t[..<i]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func wikiTargets(in text: String) -> [String] {
        let ns = text as NSString
        return wikiRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            split(ns.substring(with: $0.range(at: 2))).target
        }
    }

    static func sanitize(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rewrites [[old]], [[old|x]], [[old#h]] and ![[old]] to point at `new`.
    static func renameTarget(in text: String, from old: String, to new: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: old)
        guard let re = try? NSRegularExpression(pattern: #"(!?\[\[)(?:[^\[\]\n|#]*/)?"# + escaped + #"(\.md)?(?=[\]|#])"#, options: [.caseInsensitive]) else { return text }
        let tmpl = NSRegularExpression.escapedTemplate(for: new)
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1" + tmpl)
    }
}

enum Fuzzy {
    /// Subsequence match score (higher is better), nil if not a match.
    static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased()), c = Array(candidate.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0, score = 0, streak = 0, last = -2
        for (i, ch) in c.enumerated() where qi < q.count {
            if ch == q[qi] {
                streak = (i == last + 1) ? streak + 1 : 1
                score += 1 + streak * 2 + (i == 0 || c[i - 1] == " " || c[i - 1] == "/" || c[i - 1] == "-" ? 5 : 0)
                last = i
                qi += 1
            }
        }
        guard qi == q.count else { return nil }
        if candidate.lowercased().hasPrefix(query.lowercased()) { score += 20 }
        return score - c.count / 10
    }
}
