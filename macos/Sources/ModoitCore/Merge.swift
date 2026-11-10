import Foundation

// 줄 단위 3-way 병합 (F-07, Brief 3.2-3). 어느 쪽 입력도 버리지 않는다.
// 옮겨 온 곳: src/lib/merge.ts 와 그것이 쓰던 node-diff3(MIT)의 diff3Merge. 같은 입력에 같은 결과가 나오도록
// 알고리즘을 그대로 옮겼다(공통 줄을 고르는 방식이 다르면 반복되는 줄에서 결과가 달라진다).

private typealias Line = [UInt8]

private final class Candidate {
    let i: Int
    let j: Int
    let chain: Candidate?
    init(_ i: Int, _ j: Int, _ chain: Candidate?) {
        (self.i, self.j, self.chain) = (i, j, chain)
    }
}

/// 가장 긴 공통 부분열. 끝에서부터 `chain`으로 이어진다 (node-diff3 `LCS`)
private func lcs(_ a: [Line], _ b: [Line]) -> Candidate {
    var classes: [Line: [Int]] = [:]
    for (j, item) in b.enumerated() { classes[item, default: []].append(j) }
    var candidates = [Candidate(-1, -1, nil)]
    for (i, item) in a.enumerated() {
        var r = 0
        var c = candidates[0]
        for j in classes[item] ?? [] {
            var s = r
            while s < candidates.count {
                if candidates[s].j < j && (s == candidates.count - 1 || candidates[s + 1].j > j) { break }
                s += 1
            }
            if s < candidates.count {
                let new = Candidate(i, j, candidates[s])
                if r == candidates.count { candidates.append(c) } else { candidates[r] = c }
                r = s + 1
                c = new
                if r == candidates.count { break }
            }
        }
        if r == candidates.count { candidates.append(c) } else { candidates[r] = c }
    }
    return candidates[candidates.count - 1]
}

private struct Hunk {
    var mine: Bool
    var oStart: Int
    var oLength: Int
    var abStart: Int
    var abLength: Int
}

/// base에서 other로 바뀐 구간들 (node-diff3 `diffIndices`)
private func hunks(_ o: [Line], _ other: [Line], mine: Bool) -> [Hunk] {
    var out: [Hunk] = []
    var tail1 = o.count
    var tail2 = other.count
    var c: Candidate? = lcs(o, other)
    while let cand = c {
        let len1 = tail1 - cand.i - 1
        let len2 = tail2 - cand.j - 1
        tail1 = cand.i
        tail2 = cand.j
        if len1 != 0 || len2 != 0 {
            out.append(Hunk(mine: mine, oStart: tail1 + 1, oLength: len1, abStart: tail2 + 1, abLength: len2))
        }
        c = cand.chain
    }
    return out.reversed()
}

private enum Region {
    case ok([Line])
    case conflict(a: [Line], b: [Line])
}

/// node-diff3 `diff3MergeRegions` + `diff3Merge`(excludeFalseConflicts)
private func diff3(_ a: [Line], _ o: [Line], _ b: [Line]) -> [Region] {
    // 같은 자리면 내 것이 먼저 오도록 안정 정렬
    var queue = (hunks(o, a, mine: true) + hunks(o, b, mine: false)).enumerated()
        .sorted { ($0.element.oStart, $0.offset) < ($1.element.oStart, $1.offset) }.map(\.element)[...]
    var out: [Region] = []
    var ok: [Line] = []
    var offset = 0
    func flush() {
        if !ok.isEmpty { out.append(.ok(ok)) }
        ok = []
    }
    while let hunk = queue.popFirst() {
        let start = hunk.oStart
        var end = hunk.oStart + hunk.oLength
        var region = [hunk]
        if start > offset { ok += o[offset..<start] }
        while let next = queue.first, next.oStart <= end {
            end = max(end, next.oStart + next.oLength)
            region.append(queue.removeFirst())
        }
        if region.count == 1 {
            // 한쪽만 고친 구간
            let src = hunk.mine ? a : b
            ok += src[hunk.abStart..<(hunk.abStart + hunk.abLength)]
        } else {
            var bounds = [true: [a.count, -1, o.count, -1], false: [b.count, -1, o.count, -1]]
            for h in region {
                var x = bounds[h.mine]!
                x[0] = min(h.abStart, x[0])
                x[1] = max(h.abStart + h.abLength, x[1])
                x[2] = min(h.oStart, x[2])
                x[3] = max(h.oStart + h.oLength, x[3])
                bounds[h.mine] = x
            }
            func slice(_ buf: [Line], _ x: [Int]) -> [Line] {
                let s = x[0] + (start - x[2])
                let e = x[1] + (end - x[3])
                return Array(buf[max(0, s)..<max(max(0, s), min(buf.count, e))])
            }
            let mine = slice(a, bounds[true]!), theirs = slice(b, bounds[false]!)
            if mine == theirs {
                ok += mine
            } else {
                flush()
                out.append(.conflict(a: mine, b: theirs))
            }
        }
        offset = end
    }
    if o.count > offset { ok += o[offset...] }
    flush()
    return out
}

/// 같은 메모를 두 곳에서 고쳤을 때 줄 단위로 합친다 (BUG-26).
/// - base: 마지막으로 서로 같다고 알던 본문
/// - mine: 내 편집
/// - theirs: 상대 편집(지금 디스크 본문, 또는 다른 편집기의 본문)
///
/// 같은 줄을 양쪽이 다르게 고쳤으면 어느 쪽도 버리지 않고 내 것 → 빈 줄 → 상대 것 순서로 둘 다 남긴다.
public func mergeBodies(base: String, mine: String, theirs: String) -> String {
    if theirs.sameBytes(base) || mine.sameBytes(theirs) { return mine }
    if mine.sameBytes(base) { return theirs }
    func lines(_ s: String) -> [Line] {
        s.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map(Array.init)
    }
    var out: [Line] = []
    for r in diff3(lines(mine), lines(base), lines(theirs)) {
        switch r {
        case .ok(let l): out += l
        case .conflict(let a, let b):
            out += a
            if !a.isEmpty && !b.isEmpty { out.append([]) }
            out += b
        }
    }
    return String(decoding: Array(out.joined(separator: [UInt8(ascii: "\n")])), as: UTF8.self)
}
