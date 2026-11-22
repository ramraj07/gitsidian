import Foundation

struct FileNode: Identifiable, Hashable {
    var id: String { path.isEmpty ? "/" : path }
    let name: String
    let path: String          // relative to vault root; "" for root
    let isFolder: Bool
    var children: [FileNode]?

    var ext: String { (name as NSString).pathExtension.lowercased() }
    var isMarkdown: Bool { !isFolder && ext == "md" }
    /// Obsidian shows notes without their .md extension.
    var displayName: String { isMarkdown ? (name as NSString).deletingPathExtension : name }

    static func build(root: URL, showHidden: Bool) -> FileNode {
        FileNode(name: "", path: "", isFolder: true, children: children(of: root, rel: "", showHidden: showHidden))
    }

    private static func children(of dir: URL, rel: String, showHidden: Bool) -> [FileNode] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [FileNode] = []
        for name in names {
            if name == ".DS_Store" || name == ".git" || name.hasSuffix(".gitsidian-tmp") { continue }
            if !showHidden && name.hasPrefix(".") { continue }
            let path = rel.isEmpty ? name : rel + "/" + name
            var isDir: ObjCBool = false
            fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir)
            if isDir.boolValue {
                out.append(FileNode(name: name, path: path, isFolder: true,
                                    children: children(of: dir.appendingPathComponent(name), rel: path, showHidden: showHidden)))
            } else {
                out.append(FileNode(name: name, path: path, isFolder: false, children: nil))
            }
        }
        return out.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var allFiles: [FileNode] {
        isFolder ? (children ?? []).flatMap(\.allFiles) : [self]
    }

    var allFolders: [FileNode] {
        isFolder ? [self] + (children ?? []).flatMap(\.allFolders) : []
    }
}

enum FileKind {
    case markdown, text, image, pdf, other

    init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown": self = .markdown
        case "txt", "json", "canvas", "css", "js", "ts", "yml", "yaml", "csv", "tsv", "html", "xml", "base", "sh", "py", "swift", "toml", "ini", "log", "": self = .text
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "svg", "tiff": self = .image
        case "pdf": self = .pdf
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .markdown: return "doc.text"
        case .text: return "doc.plaintext"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .other: return "doc"
        }
    }
}
