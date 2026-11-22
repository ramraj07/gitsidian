import Foundation

enum ArchiveError: LocalizedError {
    case badGzip, badTar
    var errorDescription: String? { self == .badGzip ? "Could not decompress repository archive" : "Could not read repository archive" }
}

enum TarGz {
    /// Decompresses a .tar.gz and calls `onFile` for each regular file with the first path component stripped
    /// (GitHub tarballs wrap everything in `owner-repo-sha/`).
    static func extract(_ gz: Data, onFile: (String, Data) throws -> Void) throws {
        let tar = try gunzip(gz)
        try untar(tar) { path, data in
            guard let slash = path.firstIndex(of: "/") else { return }
            let rel = String(path[path.index(after: slash)...])
            if !rel.isEmpty { try onFile(rel, data) }
        }
    }

    static func gunzip(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw ArchiveError.badGzip }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        if flags & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { throw ArchiveError.badGzip }
        let deflate = Data(b[i..<(b.count - 8)])
        // NSData's .zlib algorithm is raw DEFLATE (RFC 1951) — exactly gzip's payload.
        guard let out = try? (deflate as NSData).decompressed(using: .zlib) else { throw ArchiveError.badGzip }
        return out as Data
    }

    static func untar(_ data: Data, onFile: (String, Data) throws -> Void) throws {
        let b = [UInt8](data)
        var offset = 0
        var longName: String?
        var paxPath: String?

        func cstr(_ r: Range<Int>) -> String {
            let slice = b[r]
            let end = slice.firstIndex(of: 0) ?? r.upperBound
            return String(decoding: b[r.lowerBound..<end], as: UTF8.self)
        }
        func octal(_ r: Range<Int>) -> Int {
            Int(cstr(r).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\0"))), radix: 8) ?? 0
        }

        while offset + 512 <= b.count {
            if b[offset..<offset + 512].allSatisfy({ $0 == 0 }) { break }
            let name = cstr(offset..<offset + 100)
            let size = octal(offset + 124..<offset + 136)
            let type = b[offset + 156]
            let magic = cstr(offset + 257..<offset + 263)
            let prefix = magic.hasPrefix("ustar") ? cstr(offset + 345..<offset + 500) : ""
            let start = offset + 512
            guard start + size <= b.count else { throw ArchiveError.badTar }
            let content = Data(b[start..<start + size])

            switch type {
            case UInt8(ascii: "x"):
                paxPath = parsePax(content)["path"]
            case UInt8(ascii: "g"):
                break
            case UInt8(ascii: "L"):
                longName = String(decoding: content.prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "0"), 0:
                let path = paxPath ?? longName ?? (prefix.isEmpty ? name : prefix + "/" + name)
                try onFile(path, content)
                paxPath = nil; longName = nil
            default:
                paxPath = nil; longName = nil
            }
            offset = start + ((size + 511) / 512) * 512
        }
    }

    private static func parsePax(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        let b = [UInt8](data)
        var i = 0
        while i < b.count {
            guard let sp = b[i...].firstIndex(of: UInt8(ascii: " ")),
                  let len = Int(String(decoding: b[i..<sp], as: UTF8.self)), len > 0, i + len <= b.count else { break }
            let record = String(decoding: b[(sp + 1)..<(i + len - 1)], as: UTF8.self)
            if let eq = record.firstIndex(of: "=") {
                out[String(record[..<eq])] = String(record[record.index(after: eq)...])
            }
            i += len
        }
        return out
    }
}
