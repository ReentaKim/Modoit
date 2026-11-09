import Foundation

public let stickyColors = ["yellow", "pink", "blue", "green", "purple"]
public let stickyDefaultSize = 280.0

public struct StickyMeta: Hashable, Sendable, Codable {
    public var color = "yellow"
    public var x: Double?
    public var y: Double?
    public var w = stickyDefaultSize
    public var h = stickyDefaultSize
    public var onTop = false
    public var open = false
    public init(color: String = "yellow", x: Double? = nil, y: Double? = nil, w: Double = stickyDefaultSize,
                h: Double = stickyDefaultSize, onTop: Bool = false, open: Bool = false) {
        (self.color, self.x, self.y, self.w, self.h, self.onTop, self.open) = (color, x, y, w, h, onTop, open)
    }
}

public struct NoteParts: Equatable, Sendable {
    /// `---` 사이 YAML 원문(끝 줄바꿈 포함). frontmatter가 없으면 nil
    public var front: String?
    public var body: String
}

private func lineText(_ s: Substring) -> Substring {
    var t = s
    while let c = t.last, c == "\n" || c == "\r" || c == "\r\n" { t = t.dropLast() }
    return t
}

private func trimEnd(_ s: Substring) -> Substring {
    var t = s
    while let c = t.last, c.isWhitespace { t = t.dropLast() }
    return t
}

/// vault.rs `looks_like_yaml_key`
func looksLikeYAMLKey(_ line: Substring) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard let i = t.firstIndex(of: ":"), i > t.startIndex else { return false }
    return t[..<i].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == " " }
}

/// YAML 매핑인지(스파이크용 근사): 비었거나, 들여쓰지 않은 모든 내용 줄이 `키:` 꼴.
/// v2 본 구현에서는 YAML 파서(Yams 등)로 바꾼다.
func looksLikeMapping(_ yaml: Substring) -> Bool {
    let lines = yaml.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        .map { trimEnd($0) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    if lines.isEmpty { return true }
    return lines.allSatisfy { $0.first == " " || $0.first == "\t" || looksLikeYAMLKey($0) }
}

/// vault.rs `split_frontmatter`와 같은 판정(BUG-18, BUG-32):
/// 첫 줄이 `---`, 다음 `---`/`...` 줄에서 닫히고, 안쪽이 매핑일 때만 frontmatter.
public func splitNote(_ content: String) -> NoteParts {
    let s = content.hasPrefix("\u{feff}") ? String(content.dropFirst()) : content
    var lines: [Substring] = []
    var start = s.startIndex
    // split_inclusive('\n')
    while start < s.endIndex {
        // Swift에서 "\r\n"은 글자 하나다
        let end = s[start...].firstIndex { $0 == "\n" || $0 == "\r\n" }.map { s.index(after: $0) } ?? s.endIndex
        lines.append(s[start..<end])
        start = end
    }
    guard let first = lines.first, trimEnd(lineText(first)) == "---" else { return NoteParts(front: nil, body: s) }
    for line in lines.dropFirst() {
        let t = trimEnd(lineText(line))
        if t == "---" || t == "..." {
            let yaml = s[first.endIndex..<line.startIndex]
            let body = String(s[line.endIndex...])
            if looksLikeMapping(yaml) { return NoteParts(front: String(yaml), body: body) }
            return NoteParts(front: nil, body: s)
        }
    }
    return NoteParts(front: nil, body: s)
}

public func joinNote(_ parts: NoteParts) -> String {
    guard let front = parts.front else { return parts.body }
    let f = front.isEmpty || front.hasSuffix("\n") ? front : front + "\n"
    return "---\n\(f)---\n\(parts.body)"
}

// MARK: - sticky

private func parseScalar(_ v: Substring) -> String {
    var t = v.trimmingCharacters(in: .whitespaces)
    if t.count >= 2, (t.first == "'" && t.last == "'") || (t.first == "\"" && t.last == "\"") {
        t = String(t.dropFirst().dropLast())
    }
    return t
}

private func makeSticky(_ kv: [String: String]) -> StickyMeta {
    func num(_ k: String) -> Double? { kv[k].flatMap(Double.init) }
    func flag(_ k: String) -> Bool { kv[k] == "true" }
    let color = kv["color"].flatMap { stickyColors.contains($0) ? $0 : nil } ?? "yellow"
    return StickyMeta(
        color: color, x: num("x"), y: num("y"),
        w: num("w").flatMap { $0 > 0 ? $0 : nil } ?? stickyDefaultSize,
        h: num("h").flatMap { $0 > 0 ? $0 : nil } ?? stickyDefaultSize,
        onTop: flag("onTop"), open: flag("open"))
}

/// frontmatter의 `sticky:` (흐름 `{…}`, 블록 둘 다). 깨진 값이면 nil.
public func parseSticky(front: String?) -> StickyMeta? {
    guard let front else { return nil }
    let lines = front.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    guard let i = lines.firstIndex(where: { $0.hasPrefix("sticky:") }) else { return nil }
    let rest = lines[i].dropFirst("sticky:".count).trimmingCharacters(in: .whitespaces)
    var kv: [String: String] = [:]
    if rest.hasPrefix("{") {
        guard rest.hasSuffix("}"), !rest.contains("[") else { return nil }
        for pair in rest.dropFirst().dropLast().split(separator: ",") {
            let p = pair.split(separator: ":", maxSplits: 1)
            guard p.count == 2 else { return nil }
            kv[parseScalar(p[0])] = parseScalar(p[1])
        }
        return makeSticky(kv)
    }
    guard rest.isEmpty else { return nil }
    for line in lines[(i + 1)...] {
        guard line.first == " " || line.first == "\t" else { break }
        let p = line.split(separator: ":", maxSplits: 1)
        if p.count == 2 { kv[parseScalar(p[0])] = parseScalar(p[1]) }
    }
    return makeSticky(kv)
}

private func fmt(_ v: Double?) -> String {
    guard let v else { return "null" }
    return String(Int(v.rounded()))
}

/// frontmatter의 sticky 한 줄만 바꾼다. 다른 키·순서는 그대로 둔다(NFR-09).
public func setSticky(front: String?, _ s: StickyMeta?) -> String? {
    var lines = (front ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    if let i = lines.firstIndex(where: { $0.hasPrefix("sticky:") }) {
        var end = i + 1
        while end < lines.count, lines[end].first == " " || lines[end].first == "\t" { end += 1 }
        lines.removeSubrange(i..<end)
        if let s { lines.insert(stickyLine(s), at: i) }
    } else if let s {
        lines.append(stickyLine(s))
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n") + "\n"
}

func stickyLine(_ s: StickyMeta) -> String {
    "sticky: {color: \(s.color), x: \(fmt(s.x)), y: \(fmt(s.y)), w: \(fmt(s.w)), h: \(fmt(s.h)), onTop: \(s.onTop), open: \(s.open)}"
}
