import Foundation
import CryptoKit

enum GitHash {
    /// The SHA-1 git uses for a blob with these bytes — lets us detect changes without talking to GitHub.
    static func blob(_ data: Data) -> String {
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\u{0}".utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
