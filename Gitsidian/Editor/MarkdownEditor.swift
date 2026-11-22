import SwiftUI
import UIKit

/// The source-mode editor: a UITextView with markdown styling, a formatting bar above the keyboard,
/// [[wikilink]] autocomplete and list continuation.
struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 17
    var highlight = true
    var autoFocus = false
    var suggestions: (String) -> [String] = { _ in [] }
    var openLink: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView(usingTextLayoutManager: false)
        let c = context.coordinator
        c.textView = tv
        c.highlighter.fontSize = fontSize
        c.highlighter.enabled = highlight
        tv.textStorage.delegate = c.highlighter
        tv.delegate = c
        tv.backgroundColor = .systemBackground
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 120, right: 14)
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.autocapitalizationType = .sentences
        tv.dataDetectorTypes = []
        tv.font = c.highlighter.baseFont
        tv.typingAttributes = c.highlighter.baseAttributes
        tv.inputAccessoryView = c.accessory
        c.accessory.coordinator = c
        c.accessory.showFormatting()
        tv.text = text
        if autoFocus {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        var restyle = false
        if c.highlighter.fontSize != fontSize { c.highlighter.fontSize = fontSize; restyle = true }
        if c.highlighter.enabled != highlight { c.highlighter.enabled = highlight; restyle = true }
        if tv.text != text {
            let sel = tv.selectedRange
            tv.text = text
            let len = (text as NSString).length
            tv.selectedRange = NSRange(location: min(sel.location, len), length: 0)
        } else if restyle {
            c.highlighter.highlight(tv.textStorage, in: NSRange(location: 0, length: tv.textStorage.length))
        }
    }

    static func dismantleUIView(_ tv: UITextView, coordinator: Coordinator) {
        tv.textStorage.delegate = nil
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: UITextView?
        let highlighter = MarkdownHighlighter()
        let accessory = EditorAccessoryView(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        private var linkQueryStart: Int?

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            if parent.text != tv.text { parent.text = tv.text }
            updateSuggestions(tv)
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            tv.typingAttributes = highlighter.baseAttributes
            updateSuggestions(tv)
        }

        // List continuation on return.
        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText rep: String) -> Bool {
            guard rep == "\n", range.length == 0 else { return true }
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
            guard let m = Self.listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return true }
            let lns = line as NSString
            let indent = lns.substring(with: m.range(at: 1))
            let marker = lns.substring(with: m.range(at: 2))
            let isTask = m.range(at: 3).location != NSNotFound
            let rest = lns.substring(from: m.range.location + m.range.length)
            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty item: end the list (remove the marker).
                replace(tv, NSRange(location: lineRange.location, length: range.location - lineRange.location), with: indent.isEmpty ? "" : String(indent.dropLast(indent.hasSuffix("\t") ? 1 : min(indent.count, 4))))
                return false
            }
            var next = marker
            if let n = Int(marker.dropLast()) { next = "\(n + 1)\(marker.last!)" }
            replace(tv, range, with: "\n" + indent + next + " " + (isTask ? "[ ] " : ""))
            return false
        }
        static let listPrefix = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+[.)])[ \t](\[[ xX/\-]\][ \t])?"#)

        // MARK: Editing helpers

        func replace(_ tv: UITextView, _ range: NSRange, with str: String, select: NSRange? = nil) {
            guard let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
                  let end = tv.position(from: start, offset: range.length),
                  let tr = tv.textRange(from: start, to: end) else { return }
            tv.replace(tr, withText: str)
            if let select { tv.selectedRange = select }
            textViewDidChange(tv)
        }

        func wrap(_ prefix: String, _ suffix: String) {
            guard let tv = textView else { return }
            let ns = tv.text as NSString
            let sel = tv.selectedRange
            let p = (prefix as NSString).length, s = (suffix as NSString).length
            if sel.location >= p, NSMaxRange(sel) + s <= ns.length,
               ns.substring(with: NSRange(location: sel.location - p, length: p)) == prefix,
               ns.substring(with: NSRange(location: NSMaxRange(sel), length: s)) == suffix {
                let inner = ns.substring(with: sel)
                replace(tv, NSRange(location: sel.location - p, length: sel.length + p + s), with: inner,
                        select: NSRange(location: sel.location - p, length: sel.length))
                return
            }
            let inner = ns.substring(with: sel)
            replace(tv, sel, with: prefix + inner + suffix, select: NSRange(location: sel.location + p, length: sel.length))
        }

        func transformLines(_ f: (String) -> String) {
            guard let tv = textView else { return }
            let ns = tv.text as NSString
            let sel = tv.selectedRange
            var lr = ns.lineRange(for: sel)
            var chunk = ns.substring(with: lr)
            let trailingNewline = chunk.hasSuffix("\n")
            if trailingNewline { chunk.removeLast(); lr.length -= 1 }
            let lines = chunk.components(separatedBy: "\n")
            let out = lines.map(f).joined(separator: "\n")
            let delta = (out as NSString).length - lr.length
            if lines.count == 1 {
                replace(tv, lr, with: out, select: NSRange(location: max(lr.location, sel.location + delta), length: sel.length))
            } else {
                replace(tv, lr, with: out, select: NSRange(location: lr.location, length: (out as NSString).length))
            }
        }

        private static let taskRe = try! NSRegularExpression(pattern: #"^(\s*)([-*+]) \[([ xX/\-])\] ?"#)
        private static let bulletRe = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+[.)]) "#)
        private static let headingRe = try! NSRegularExpression(pattern: #"^(#{1,6}) "#)

        private func match(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
            re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
        }

        func toggleTask() {
            transformLines { line in
                let ns = line as NSString
                if let m = match(Self.taskRe, line) {
                    let state = ns.substring(with: m.range(at: 3))
                    return ns.replacingCharacters(in: m.range(at: 3), with: state == " " ? "x" : " ")
                }
                if let m = match(Self.bulletRe, line) {
                    let indent = ns.substring(with: m.range(at: 1))
                    return indent + "- [ ] " + ns.substring(from: m.range.length)
                }
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                return indent + "- [ ] " + line.dropFirst(indent.count)
            }
        }

        func toggleBullet() {
            transformLines { line in
                let ns = line as NSString
                if let m = match(Self.taskRe, line) {
                    return ns.substring(with: m.range(at: 1)) + "- " + ns.substring(from: m.range.length)
                }
                if let m = match(Self.bulletRe, line) {
                    return ns.substring(with: m.range(at: 1)) + ns.substring(from: m.range.length)
                }
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                return indent + "- " + line.dropFirst(indent.count)
            }
        }

        func cycleHeading() {
            transformLines { line in
                let ns = line as NSString
                if let m = match(Self.headingRe, line) {
                    let n = m.range(at: 1).length
                    let body = ns.substring(from: m.range.length)
                    return n >= 4 ? body : String(repeating: "#", count: n + 1) + " " + body
                }
                return "# " + line
            }
        }

        func indent(_ inward: Bool) {
            transformLines { line in
                if inward { return "\t" + line }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                let spaces = line.prefix(4).prefix { $0 == " " }.count
                return String(line.dropFirst(spaces))
            }
        }

        func insertLink() { wrap("[[", "]]"); if let tv = textView { updateSuggestions(tv) } }

        func linkUnderCursor() -> String? {
            guard let tv = textView else { return nil }
            let ns = tv.text as NSString
            let cursor = tv.selectedRange.location
            let lr = ns.lineRange(for: NSRange(location: cursor, length: 0))
            for m in Links.wikiRegex.matches(in: tv.text, range: lr) where NSLocationInRange(cursor, m.range) || NSMaxRange(m.range) == cursor {
                return Links.split(ns.substring(with: m.range(at: 2))).target
            }
            return nil
        }

        // MARK: Autocomplete

        func updateSuggestions(_ tv: UITextView) {
            let sel = tv.selectedRange
            guard sel.length == 0 else { linkQueryStart = nil; accessory.showFormatting(); return }
            let ns = tv.text as NSString
            let lr = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let before = ns.substring(with: NSRange(location: lr.location, length: sel.location - lr.location)) as NSString
            let open = before.range(of: "[[", options: .backwards)
            if open.location != NSNotFound {
                let query = before.substring(from: open.location + 2)
                if !query.contains("]") && !query.contains("|") && !query.contains("#") {
                    linkQueryStart = lr.location + open.location + 2
                    let names = parent.suggestions(query)
                    if !names.isEmpty { accessory.showSuggestions(names); return }
                }
            }
            linkQueryStart = nil
            accessory.showFormatting()
        }

        func pickSuggestion(_ name: String) {
            guard let tv = textView, let start = linkQueryStart else { return }
            let ns = tv.text as NSString
            let cursor = tv.selectedRange.location
            guard cursor >= start else { return }
            let hasClose = cursor + 2 <= ns.length && ns.substring(with: NSRange(location: cursor, length: 2)) == "]]"
            let insert = hasClose ? name : name + "]]"
            let endOfLink = start + (name as NSString).length + 2
            replace(tv, NSRange(location: start, length: cursor - start), with: insert, select: NSRange(location: endOfLink, length: 0))
            linkQueryStart = nil
            accessory.showFormatting()
        }
    }
}

/// The bar above the keyboard: formatting buttons, or note suggestions while typing a [[link.
final class EditorAccessoryView: UIInputView {
    weak var coordinator: MarkdownEditor.Coordinator?
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let dismissButton = UIButton(type: .system)
    private var mode = -1

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        allowsSelfSizing = true
        scroll.showsHorizontalScrollIndicator = false
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        dismissButton.addAction(UIAction { [weak self] _ in self?.coordinator?.textView?.resignFirstResponder() }, for: .touchUpInside)
        addSubview(scroll)
        addSubview(dismissButton)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -4),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    private func clear() { stack.arrangedSubviews.forEach { $0.removeFromSuperview() } }

    private func iconButton(_ symbol: String, _ action: @escaping (MarkdownEditor.Coordinator) -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        b.tintColor = .label
        b.widthAnchor.constraint(equalToConstant: 42).isActive = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        b.addAction(UIAction { [weak self] _ in if let c = self?.coordinator { action(c) } }, for: .touchUpInside)
        return b
    }

    func showFormatting() {
        guard mode != 0 else { return }
        mode = 0
        clear()
        let items: [(String, (MarkdownEditor.Coordinator) -> Void)] = [
            ("arrow.uturn.backward", { $0.textView?.undoManager?.undo() }),
            ("arrow.uturn.forward", { $0.textView?.undoManager?.redo() }),
            ("link", { $0.insertLink() }),
            ("checklist", { $0.toggleTask() }),
            ("list.bullet", { $0.toggleBullet() }),
            ("number", { $0.cycleHeading() }),
            ("bold", { $0.wrap("**", "**") }),
            ("italic", { $0.wrap("*", "*") }),
            ("highlighter", { $0.wrap("==", "==") }),
            ("strikethrough", { $0.wrap("~~", "~~") }),
            ("chevron.left.forwardslash.chevron.right", { $0.wrap("`", "`") }),
            ("decrease.indent", { $0.indent(false) }),
            ("increase.indent", { $0.indent(true) }),
            ("number.square", { c in c.wrap("#", "") }),
            ("arrow.up.forward.square", { c in if let l = c.linkUnderCursor() { c.parent.openLink(l) } }),
        ]
        for (symbol, action) in items { stack.addArrangedSubview(iconButton(symbol, action)) }
        scroll.setContentOffset(.zero, animated: false)
    }

    func showSuggestions(_ names: [String]) {
        mode = 1
        clear()
        for name in names {
            var cfg = UIButton.Configuration.tinted()
            cfg.title = name
            cfg.cornerStyle = .capsule
            cfg.buttonSize = .small
            cfg.titleLineBreakMode = .byTruncatingMiddle
            let b = UIButton(configuration: cfg)
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            b.addAction(UIAction { [weak self] _ in self?.coordinator?.pickSuggestion(name) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        scroll.setContentOffset(.zero, animated: false)
    }
}
