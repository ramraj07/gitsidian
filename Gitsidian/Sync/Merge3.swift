import Foundation

/// Line-based three-way merge. Returns nil when both sides changed the same region differently.
enum Merge3 {
    struct Hunk { let start: Int; let end: Int; let lines: [String]; let side: Int }

    static func merge(base: String, local: String, remote: String) -> String? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        let b = base.components(separatedBy: "\n")
        let l = local.components(separatedBy: "\n")
        let r = remote.components(separatedBy: "\n")
        guard let hl = diff(b, l, side: 0), let hr = diff(b, r, side: 1) else { return nil }

        let all = (hl + hr).sorted { ($0.start, $0.end, $0.side) < ($1.start, $1.end, $1.side) }
        var out: [String] = []
        var pos = 0
        var i = 0
        while i < all.count {
            var group = [all[i]]
            let gs = all[i].start
            var ge = all[i].end
            i += 1
            while i < all.count, all[i].start <= ge {
                group.append(all[i]); ge = max(ge, all[i].end); i += 1
            }
            out += b[pos..<gs]
            let ls = group.filter { $0.side == 0 }, rs = group.filter { $0.side == 1 }
            func apply(_ hs: [Hunk]) -> [String] {
                var res: [String] = []; var p = gs
                for h in hs { res += b[p..<h.start]; res += h.lines; p = h.end }
                res += b[p..<ge]
                return res
            }
            if rs.isEmpty { out += apply(ls) }
            else if ls.isEmpty { out += apply(rs) }
            else {
                let a = apply(ls), c = apply(rs)
                guard a == c else { return nil }
                out += a
            }
            pos = ge
        }
        out += b[pos...]
        return out.joined(separator: "\n")
    }

    /// LCS diff producing replacement hunks against `a`. Returns nil if too large to diff cheaply.
    static func diff(_ a: [String], _ b: [String], side: Int) -> [Hunk]? {
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let A = Array(a[pre..<(a.count - suf)]), B = Array(b[pre..<(b.count - suf)])
        let n = A.count, m = B.count
        if n == 0 && m == 0 { return [] }
        if n == 0 || m == 0 { return [Hunk(start: pre, end: pre + n, lines: B, side: side)] }
        guard n * m <= 6_000_000 else { return nil }

        // dp[i][j] = LCS length of A[i...], B[j...]
        let w = m + 1
        var dp = [Int32](repeating: 0, count: (n + 1) * w)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i * w + j] = A[i] == B[j] ? dp[(i + 1) * w + j + 1] + 1 : max(dp[(i + 1) * w + j], dp[i * w + j + 1])
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        var hs = -1, hLines: [String] = []
        func flush() {
            if hs >= 0 { hunks.append(Hunk(start: pre + hs, end: pre + i, lines: hLines, side: side)); hs = -1; hLines = [] }
        }
        while i < n || j < m {
            if i < n, j < m, A[i] == B[j] { flush(); i += 1; j += 1 }
            else if j < m, i == n || dp[i * w + j + 1] >= dp[(i + 1) * w + j] {
                if hs < 0 { hs = i }; hLines.append(B[j]); j += 1
            } else {
                if hs < 0 { hs = i }; i += 1
            }
        }
        flush()
        return hunks
    }
}
