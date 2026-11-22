import UIKit

/// Live syntax styling for the source editor — headings get bigger, markup is dimmed, links are accented.
final class MarkdownHighlighter: NSObject, NSTextStorageDelegate {
    var fontSize: CGFloat = 17
    var enabled = true

    static var accent: UIColor { UIColor(named: "AccentColor") ?? .systemPurple }

    private static func re(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    private static let heading = re(#"^(#{1,6})[ \t]+.*$"#)
    private static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = re(#"(?<![\*\w])([\*_])(?=[^\s\*_])(.+?)(?<=[^\s\*_])\1(?![\*\w])"#)
    private static let strike = re(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let mark = re(#"==(?=\S)(.+?)(?<=\S)=="#)
    private static let code = re(#"(`+)([^`\n]+?)\1"#)
    private static let wiki = re(#"(!?\[\[)([^\[\]\n]+?)(\]\])"#)
    private static let mdLink = re(#"(!?\[)([^\]\n]*)(\]\()([^)\n]*)(\))"#)
    private static let url = re(#"(?<![\(<])https?://[^\s<>\)\]]+"#)
    private static let tag = re(#"(?<![\w#&/\]])#[\p{L}\p{N}_\-/]*[\p{L}_\-/][\p{L}\p{N}_\-/]*"#)
    private static let listMarker = re(#"^[ \t]*([-*+]|\d+[.)])[ \t]"#)
    private static let task = re(#"^[ \t]*[-*+][ \t](\[[ xX/\-]\])"#)
    private static let doneTask = re(#"^[ \t]*[-*+][ \t]\[[xX]\][ \t](.*)$"#)
    private static let quote = re(#"^(>+)(.*)$"#)
    private static let callout = re(#"^>[ \t]*\[![\w-]+\][+-]?.*$"#)
    private static let rule = re(#"^([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let comment = re(#"%%[\s\S]*?%%"#, [])
    private static let fence = re(#"^[ \t]*(```|~~~)[^\n]*\n[\s\S]*?(^[ \t]*\1[ \t]*$|\z)"#)
    private static let frontmatter = re(#"\A---[ \t]*\n[\s\S]*?\n---[ \t]*$"#)

    var baseFont: UIFont { .systemFont(ofSize: fontSize) }
    var monoFont: UIFont { .monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular) }

    var baseAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacing = 2
        return [.font: baseFont, .foregroundColor: UIColor.label, .paragraphStyle: p]
    }

    func textStorage(_ ts: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let full = NSRange(location: 0, length: ts.length)
        let target = ts.length < 60_000 ? full : (ts.string as NSString).paragraphRange(for: editedRange)
        highlight(ts, in: target)
    }

    func highlight(_ ts: NSTextStorage, in range: NSRange) {
        ts.setAttributes(baseAttributes, range: range)
        guard enabled, range.length > 0 else { return }
        let text = ts.string
        let dim = UIColor.tertiaryLabel
        let accent = Self.accent

        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            re.enumerateMatches(in: text, range: range) { m, _, _ in if let m { body(m) } }
        }
        func color(_ r: NSRange, _ c: UIColor) { if r.location != NSNotFound { ts.addAttribute(.foregroundColor, value: c, range: r) } }
        func traits(_ r: NSRange, _ t: UIFontDescriptor.SymbolicTraits) {
            ts.enumerateAttribute(.font, in: r) { v, sub, _ in
                let f = (v as? UIFont) ?? baseFont
                if let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(t)) {
                    ts.addAttribute(.font, value: UIFont(descriptor: d, size: f.pointSize), range: sub)
                }
            }
        }

        each(Self.heading) { m in
            let level = m.range(at: 1).length
            let scale: [CGFloat] = [1.6, 1.4, 1.25, 1.12, 1.05, 1.0]
            ts.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize * scale[level - 1], weight: .bold), range: m.range)
            color(m.range(at: 1), dim)
        }
        each(Self.listMarker) { m in
            color(m.range(at: 1), accent)
            traits(m.range(at: 1), .traitBold)
        }
        each(Self.task) { m in color(m.range(at: 1), accent) }
        each(Self.doneTask) { m in
            color(m.range(at: 1), .secondaryLabel)
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
        }
        each(Self.quote) { m in
            color(m.range(at: 1), accent)
            color(m.range(at: 2), .secondaryLabel)
        }
        each(Self.callout) { m in
            color(m.range, accent)
            traits(m.range, .traitBold)
        }
        each(Self.rule) { m in color(m.range, dim) }
        each(Self.bold) { m in
            traits(m.range, .traitBold)
            color(NSRange(location: m.range.location, length: 2), dim)
            color(NSRange(location: NSMaxRange(m.range) - 2, length: 2), dim)
        }
        each(Self.italic) { m in
            traits(m.range, .traitItalic)
            color(NSRange(location: m.range.location, length: 1), dim)
            color(NSRange(location: NSMaxRange(m.range) - 1, length: 1), dim)
        }
        each(Self.strike) { m in
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            color(NSRange(location: m.range.location, length: 2), dim)
            color(NSRange(location: NSMaxRange(m.range) - 2, length: 2), dim)
        }
        each(Self.mark) { m in
            ts.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35), range: m.range(at: 1))
            color(NSRange(location: m.range.location, length: 2), dim)
            color(NSRange(location: NSMaxRange(m.range) - 2, length: 2), dim)
        }
        each(Self.url) { m in color(m.range, accent) }
        each(Self.mdLink) { m in
            color(m.range(at: 1), dim); color(m.range(at: 3), dim); color(m.range(at: 5), dim)
            color(m.range(at: 2), accent)
            color(m.range(at: 4), .secondaryLabel)
        }
        each(Self.wiki) { m in
            color(m.range(at: 1), dim); color(m.range(at: 3), dim)
            color(m.range(at: 2), accent)
        }
        each(Self.tag) { m in
            color(m.range, accent)
            ts.addAttribute(.backgroundColor, value: accent.withAlphaComponent(0.12), range: m.range)
        }
        each(Self.code) { m in
            ts.addAttribute(.font, value: monoFont, range: m.range)
            ts.addAttribute(.backgroundColor, value: UIColor.tertiarySystemFill, range: m.range)
            ts.addAttribute(.foregroundColor, value: UIColor.systemPink, range: m.range(at: 2))
            color(m.range(at: 1), dim)
        }
        each(Self.comment) { m in color(m.range, dim) }
        // Block-level overrides last.
        let codeAttrs: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: UIColor.label, .backgroundColor: UIColor.secondarySystemFill]
        Self.fence.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { m, _, _ in
            guard let m, let r = m.range.intersection(range) else { return }
            ts.addAttributes(codeAttrs, range: r)
            ts.removeAttribute(.strikethroughStyle, range: r)
        }
        if let m = Self.frontmatter.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
           let r = m.range.intersection(range) {
            ts.addAttributes([.font: UIFont.monospacedSystemFont(ofSize: fontSize * 0.8, weight: .regular),
                              .foregroundColor: UIColor.secondaryLabel], range: r)
            ts.removeAttribute(.backgroundColor, range: r)
        }
    }
}
