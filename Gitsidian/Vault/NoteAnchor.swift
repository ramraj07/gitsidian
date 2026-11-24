import Foundation

/// Obsidian-style subpaths: `Note#Heading`, `Note#Parent#Child` (last heading wins) and
/// `Note#^block-id` (a line ending in ` ^block-id`). Matching is forgiving: case, spacing and
/// inline markup are ignored, then a prefix match is tried. Unknown anchors just open the note.
enum NoteAnchor {
    private static let headingLine = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+(.*?)[ \t#]*$"#)

    static func isBlock(_ subpath: String) -> Bool { subpath.hasPrefix("^") }

    /// The heading text to look for: "Parent#Child" -> "Child".
    static func headingTarget(_ subpath: String) -> String {
        subpath.split(separator: "#").last.map(String.init) ?? subpath
    }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        for token in ["[[", "]]", "**", "__", "==", "~~", "`", "*", "_"] { t = t.replacingOccurrences(of: token, with: "") }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Does `text` end with the block id `^id`?
    static func endsWithBlockID(_ text: String, _ id: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "^" + id || t.hasSuffix(" ^" + id) || t.hasSuffix("\t^" + id) || t.hasSuffix("\n^" + id)
    }

    /// 0-based line the anchor points at in raw markdown (for the editor).
    static func line(in text: String, subpath: String) -> Int? {
        let lines = text.components(separatedBy: "\n")
        var inFence = false
        if isBlock(subpath) {
            let id = String(subpath.dropFirst())
            for (i, l) in lines.enumerated() where endsWithBlockID(l, id) {
                // An id on its own line labels the block above it.
                if l.trimmingCharacters(in: .whitespaces) == "^" + id,
                   let prev = lines[..<i].lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { return prev }
                return i
            }
            return nil
        }
        let want = normalize(headingTarget(subpath))
        var prefixHit: Int?
        for (i, l) in lines.enumerated() {
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            let ns = l as NSString
            guard let m = headingLine.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) else { continue }
            let h = normalize(ns.substring(with: m.range(at: 1)))
            if h == want { return i }
            if prefixHit == nil, !want.isEmpty, h.hasPrefix(want) { prefixHit = i }
        }
        return prefixHit
    }

    /// Top-level reading-view block the anchor points at.
    static func blockID(in blocks: [MDBlock], subpath: String) -> Int? {
        if isBlock(subpath) {
            let id = String(subpath.dropFirst())
            for (i, b) in blocks.enumerated() {
                guard let t = text(of: b), endsWithBlockID(t, id) else { continue }
                // A paragraph that is only "^id" labels the previous block.
                if t.trimmingCharacters(in: .whitespacesAndNewlines) == "^" + id, i > 0 { return blocks[i - 1].id }
                return b.id
            }
            return nil
        }
        let want = normalize(headingTarget(subpath))
        var prefixHit: Int?
        for b in blocks {
            guard case .heading(_, let t) = b.kind else { continue }
            let h = normalize(t)
            if h == want { return b.id }
            if prefixHit == nil, !want.isEmpty, h.hasPrefix(want) { prefixHit = b.id }
        }
        return prefixHit
    }

    private static func text(of b: MDBlock) -> String? {
        switch b.kind {
        case .heading(_, let t), .paragraph(let t), .listItem(_, _, let t), .task(_, _, let t, _), .quote(let t): return t
        case .callout(_, let title, let body, _): return title + "\n" + body
        default: return nil
        }
    }
}

/// A request to scroll the open note to a subpath. The token makes repeated taps on the same link work.
struct AnchorRequest: Equatable {
    let path: String
    let subpath: String
    var token = UUID()
}
