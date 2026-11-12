import Foundation

// 메모를 옮길 때 상대 링크·이미지 경로를 새 위치 기준으로 다시 쓴다 (FR-36).
// 옮겨 온 곳: src-tauri/src/vault.rs rewrite_links

private func hasScheme(_ s: Scalars) -> Bool {
    guard let f = s.first, f.isASCIIAlpha else { return false }
    for c in s.dropFirst() {
        if c == ":" { return true }
        if !(c.isASCIIAlpha || c.isASCIIDigit || c == "+" || c == "-" || c == ".") { return false }
    }
    return false
}

private func percentDecode(_ s: String) -> String? {
    let b = Array(s.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(b.count)
    func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
    var i = 0
    while i < b.count {
        if b[i] == UInt8(ascii: "%"), i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
            out.append(h * 16 + l)
            i += 3
            continue
        }
        out.append(b[i])
        i += 1
    }
    return String(validatingUTF8: out.map { CChar(bitPattern: $0) } + [0]).flatMap { $0.utf8.count == out.count ? $0 : nil }
}

private func percentEncodePath(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for c in s.unicodeScalars {
        switch c {
        case " ": out.append(contentsOf: "%20".unicodeScalars)
        case "%": out.append(contentsOf: "%25".unicodeScalars)
        case "(": out.append(contentsOf: "%28".unicodeScalars)
        case ")": out.append(contentsOf: "%29".unicodeScalars)
        case "<": out.append(contentsOf: "%3C".unicodeScalars)
        case ">": out.append(contentsOf: "%3E".unicodeScalars)
        case "#": out.append(contentsOf: "%23".unicodeScalars)
        case "?": out.append(contentsOf: "%3F".unicodeScalars)
        default: out.append(c)
        }
    }
    return String(out)
}

/// base 폴더 기준 상대 경로를 풀어 저장 폴더 기준 경로로. 밖으로 벗어나면 nil.
private func joinNormalize(_ baseDir: String, _ rel: String) -> String? {
    var parts = baseDir.pathSegments
    let segs = rel.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
    for seg in segs {
        if seg.isEmpty || seg.sameBytes(".") { continue }
        if seg.sameBytes("..") {
            if parts.isEmpty { return nil }
            parts.removeLast()
        } else {
            parts.append(seg)
        }
    }
    return parts.joined(separator: "/")
}

/// 링크 대상 하나를 고친다. 고칠 필요가 없으면 nil.
private func rewriteTarget(_ raw: Scalars, _ oldDir: String, _ newDir: String, _ moved: (from: String, to: String)?) -> String? {
    guard let f = raw.first, f != "#", f != "/", f != "~", !hasScheme(raw) else { return nil }
    let cut = raw.firstIndex { $0 == "#" || $0 == "?" } ?? raw.endIndex
    let pathPart = raw[..<cut], suffix = raw[cut...]
    if pathPart.isEmpty { return nil }
    guard let decoded = percentDecode(String(pathPart)), var abs = joinNormalize(oldDir, decoded) else { return nil }
    if let (from, to) = moved {
        if abs.sameBytes(from) {
            abs = to
        } else if abs.bytesHasPrefix(from + "/") {
            abs = to + abs.droppingBytes(from.utf8.count)
        }
    }
    let rel = relativePath(fromDir: newDir, to: abs)
    if rel.isEmpty || rel.sameBytes(decoded) { return nil }
    return percentEncodePath(rel) + String(suffix)
}

/// `](` 바로 뒤의 링크 대상을 읽는다. (앞 공백 길이, 대상 글, 대상이 차지한 길이)
private func parseDestination(_ s: Scalars) -> (lead: Int, target: Scalars, length: Int)? {
    let rest = s.drop { $0 == " " || $0 == "\t" }
    let lead = s.count - rest.count
    if rest.first == "<" {
        let inner = rest.dropFirst()
        guard let end = inner.firstIndex(where: { $0 == ">" || $0 == "\n" }), inner[end] == ">" else { return nil }
        return (lead, inner[..<end], end - inner.startIndex + 2)
    }
    var depth = 0
    var end = rest.endIndex
    var escaped = false
    loop: for i in rest.indices {
        if escaped { escaped = false; continue }
        let c = rest[i]
        switch c {
        case "\\": escaped = true
        case "(": depth += 1
        case ")":
            if depth == 0 { end = i; break loop }
            depth -= 1
        default:
            if c.isWS { end = i; break loop }
        }
    }
    let length = end - rest.startIndex
    return length > 0 ? (lead, rest[..<end], length) : nil
}

/// 메모 내용의 Markdown 링크·이미지 대상을 옛 위치(oldDir) 기준에서 새 위치(newDir) 기준으로 다시 쓴다.
/// moved = (옛 경로, 새 경로): 함께 옮겨진 파일·폴더를 가리키는 링크는 새 자리로 맞춘다.
/// 코드 블록 안, 웹 주소, 절대 경로, 저장 폴더 밖으로 풀리는 링크는 건드리지 않는다.
public func rewriteLinks(_ content: String, oldDir: String, newDir: String, moved: (from: String, to: String)? = nil) -> String {
    var out = String.UnicodeScalarView()
    var inFence = false
    for line in content.scalars.linesInclusive() {
        if isFence(line.trimmedStart()) {
            inFence.toggle()
            out.append(contentsOf: line)
            continue
        }
        if inFence {
            out.append(contentsOf: line)
            continue
        }
        var rest = line
        while let r = rest.firstRange(of: "](") {
            out.append(contentsOf: rest[..<r.upperBound])
            rest = rest[r.upperBound...]
            guard let (lead, target, length) = parseDestination(rest) else { continue }
            out.append(contentsOf: rest.prefix(lead))
            if let new = rewriteTarget(target, oldDir, newDir, moved) {
                out.append(contentsOf: new.unicodeScalars)
            } else {
                out.append(contentsOf: rest.dropFirst(lead).prefix(length))
            }
            rest = rest.dropFirst(lead + length)
        }
        out.append(contentsOf: rest)
    }
    return String(out)
}
