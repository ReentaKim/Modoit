import Foundation
import Yams

// 메모 파일 맨 위 frontmatter. 사용자가 써 둔 키·주석·순서·서식은 그대로 두고
// Modoit이 쓰는 키(pinned, sticky)만 고친다 (NFR-09, BUG-34).
// 옮겨 온 곳: src-tauri/src/vault.rs split_frontmatter·note_flags, src/lib/frontmatter.ts

public let stickyColors = ["yellow", "pink", "blue", "green", "purple"]
public let stickyDefaultSize = 280.0

public struct StickyMeta: Hashable, Sendable {
    public var color: String
    public var x: Double?
    public var y: Double?
    public var w: Double
    public var h: Double
    public var onTop: Bool
    public var open: Bool

    public init(color: String = "yellow", x: Double? = nil, y: Double? = nil, w: Double = stickyDefaultSize,
                h: Double = stickyDefaultSize, onTop: Bool = false, open: Bool = false) {
        (self.color, self.x, self.y, self.w, self.h, self.onTop, self.open) = (color, x, y, w, h, onTop, open)
    }

    /// 처음 꺼낼 때의 값 (F-08 R-4)
    public static let firstOpen = StickyMeta(open: true)
}

public struct NoteParts: Equatable, Sendable {
    /// `---` 사이의 YAML 원문(끝 줄바꿈 포함). frontmatter가 없으면 nil
    public var front: String?
    public var body: String

    public init(front: String?, body: String) {
        self.front = front
        self.body = body
    }
}

public struct NoteMetaFields: Equatable, Sendable {
    public var pinned = false
    public var sticky: StickyMeta?
    /// v0.1 Stickies 형식(최상위 color·x·…)이었는지 (NFR-08)
    public var legacy = false
}

public struct MetaPatch: Sendable {
    public var pinned: Bool?
    /// `.some(nil)`이면 sticky 키를 지운다
    public var sticky: StickyMeta??

    public init(pinned: Bool? = nil, sticky: StickyMeta?? = nil) {
        self.pinned = pinned
        self.sticky = sticky
    }
}

// MARK: - 나누기·합치기

private enum YAMLKind {
    case mapping([AnyHashable: Any])
    case other
    case broken
}

private func parseYAML(_ yaml: String) -> YAMLKind {
    do {
        let v = try Yams.load(yaml: yaml)
        if v == nil || v is NSNull { return .mapping([:]) }
        if let m = v as? [AnyHashable: Any] { return .mapping(m) }
        return .other
    } catch {
        return .broken
    }
}

func looksLikeYAMLKey(_ line: Scalars) -> Bool {
    let t = line.trimmed()
    guard let i = t.firstIndex(of: ":"), i > t.startIndex else { return false }
    return t[..<i].allSatisfy { $0.isAlnum || $0 == "_" || $0 == "-" || $0 == " " }
}

/// 맨 앞 frontmatter를 떼어 낸다.
/// - 첫 줄(BOM 제외)이 끝 공백을 빼고 `---`
/// - 그 뒤 처음 나오는 `---` 또는 `...` 줄에서 닫힌다
/// - 안쪽이 YAML 매핑이거나 비어 있으면 frontmatter
/// - YAML이 깨져도 첫 줄이 `키:` 꼴이면 frontmatter
/// 그 밖에는 구분선으로 시작하는 본문으로 본다 (BUG-18, BUG-32).
/// frontmatter가 없으면 `body`는 원문 그대로다(BOM 포함).
public func splitNote(_ content: String) -> NoteParts {
    let none = NoteParts(front: nil, body: content)
    var s = content.scalars
    if s.first == "\u{feff}" { s = s.dropFirst() }
    let lines = s.linesInclusive()
    func text(_ l: Scalars) -> Scalars {
        var t = l
        while let c = t.last, c == "\n" || c == "\r" { t = t.dropLast() }
        return t.trimmedEnd()
    }
    guard let first = lines.first, text(first).elementsEqual("---".unicodeScalars) else { return none }
    for line in lines.dropFirst() {
        let t = text(line)
        guard t.elementsEqual("---".unicodeScalars) || t.elementsEqual("...".unicodeScalars) else { continue }
        let yaml = s[first.endIndex..<line.startIndex]
        let body = String(s[line.endIndex...])
        switch parseYAML(String(yaml)) {
        case .mapping: return NoteParts(front: String(yaml), body: body)
        case .other: return none
        case .broken:
            let firstKey = yaml.lines().first { !$0.trimmed().isEmpty }
            return firstKey.map(looksLikeYAMLKey) == true ? NoteParts(front: String(yaml), body: body) : none
        }
    }
    return none
}

public func joinNote(_ parts: NoteParts) -> String {
    guard let front = parts.front else { return parts.body }
    let f = front.isEmpty || front.utf8.last == UInt8(ascii: "\n") ? front : front + "\n"
    return "---\n\(f)---\n\(parts.body)"
}

// MARK: - 읽기

private func number(_ v: Any?) -> Double? {
    if v is Bool { return nil }
    if let i = v as? Int { return Double(i) }
    if let d = v as? Double, d.isFinite { return d }
    return nil
}

/// open 키가 없으면 '넣어 둠'으로 본다 (BUG-37). v0.1 형식은 파일이 곧 떠 있는 스티키였으므로 꺼냄
private func toSticky(_ raw: [AnyHashable: Any], legacy: Bool = false) -> StickyMeta {
    let color = (raw["color"] as? String).flatMap { stickyColors.contains($0) ? $0 : nil } ?? "yellow"
    let size = { (k: String) in number(raw[k]).flatMap { $0 > 0 ? $0 : nil } ?? stickyDefaultSize }
    let open = legacy ? (raw["open"] as? Bool) != false : (raw["open"] as? Bool) == true
    return StickyMeta(color: color, x: number(raw["x"]), y: number(raw["y"]), w: size("w"), h: size("h"),
                      onTop: (raw["onTop"] as? Bool) == true, open: open)
}

private let legacyKeys = ["color", "x", "y", "w", "h", "onTop", "open"]

public func readMeta(front: String?) -> NoteMetaFields {
    guard let front, case .mapping(let d) = parseYAML(front) else { return NoteMetaFields() }
    let pinned = (d["pinned"] as? Bool) == true
    if let s = d["sticky"] as? [AnyHashable: Any] {
        return NoteMetaFields(pinned: pinned, sticky: toSticky(s), legacy: false)
    }
    if d["color"] is String, d["w"] != nil || d["h"] != nil {
        return NoteMetaFields(pinned: pinned, sticky: toSticky(d, legacy: true), legacy: true)
    }
    return NoteMetaFields(pinned: pinned)
}

// MARK: - 쓰기

private func rounded(_ v: Double?) -> String {
    guard let v else { return "null" }
    return String(Int(v.rounded()))
}

func stickyLine(_ s: StickyMeta) -> String {
    "sticky: { color: \(s.color), x: \(rounded(s.x)), y: \(rounded(s.y)), w: \(rounded(s.w)), h: \(rounded(s.h)), "
        + "onTop: \(s.onTop), open: \(s.open) }"
}

private func roundedSticky(_ s: StickyMeta) -> StickyMeta {
    var r = s
    r.x = s.x?.rounded()
    r.y = s.y?.rounded()
    r.w = s.w.rounded()
    r.h = s.h.rounded()
    return r
}

/// 들여쓰지 않은 `키:` 줄이면 그 키 이름
private func topLevelKey(_ line: String) -> String? {
    let s = line.scalars
    guard let f = s.first, !f.isWS, f != "#", f != "-" else { return nil }
    var i = s.startIndex
    var quote: Unicode.Scalar?
    while i < s.endIndex {
        let c = s[i]
        if let q = quote {
            if c == q { quote = nil }
        } else if c == "\"" || c == "'" {
            quote = c
        } else if c == ":" {
            let next = i + 1 < s.endIndex ? s[i + 1] : nil
            if next == nil || next!.isWS {
                var key = s[..<i].trimmed()
                if key.count >= 2, let q = key.first, q == "\"" || q == "'", key.last == q {
                    key = key.dropFirst().dropLast()
                }
                return String(key)
            }
        }
        i += 1
    }
    return nil
}

/// 최상위 키의 줄 범위. 값이 여러 줄이면(들여쓴 줄) 거기까지 포함한다
private func keyBlock(_ lines: [String], _ key: String) -> Range<Int>? {
    guard let start = lines.firstIndex(where: { topLevelKey($0)?.sameBytes(key) == true }) else { return nil }
    var end = start + 1
    var i = end
    while i < lines.count {
        let s = lines[i].scalars
        if s.trimmed().isEmpty { i += 1; continue }
        guard let f = s.first, f.isWS else { break }
        i += 1
        end = i
    }
    return start..<end
}

private func patchLines(_ front: String, _ patch: MetaPatch, legacy: Bool) -> String? {
    let crlf = front.unicodeScalars.contains("\r")
    var lines = front.scalars.lines().map(String.init)
    func set(_ key: String, _ line: String?) {
        if let r = keyBlock(lines, key) {
            lines.replaceSubrange(r, with: line.map { [$0] } ?? [])
        } else if let line {
            var at = lines.count
            while at > 0, lines[at - 1].scalars.trimmed().isEmpty { at -= 1 }
            lines.insert(line, at: at)
        }
    }
    if let p = patch.pinned { set("pinned", p ? "pinned: true" : nil) }
    if let s = patch.sticky {
        if legacy { for k in legacyKeys { set(k, nil) } }
        set("sticky", s.map(stickyLine))
    }
    if lines.allSatisfy({ $0.scalars.trimmed().isEmpty }) { return nil }
    return lines.map { $0 + (crlf ? "\r\n" : "\n") }.joined()
}

/// 쓰기 결과가 뜻한 대로인지: 우리 키는 바뀐 값으로 읽히고, 다른 키는 값이 그대로다
private func verify(_ before: [AnyHashable: Any], _ after: String?, _ patch: MetaPatch, legacy: Bool) -> Bool {
    var ours: Set<String> = []
    if patch.pinned != nil { ours.insert("pinned") }
    if patch.sticky != nil {
        ours.insert("sticky")
        if legacy { ours.formUnion(legacyKeys) }
    }
    let rest = { (m: [AnyHashable: Any]) in m.filter { !ours.contains(($0.key as? String) ?? "") } as NSDictionary }
    guard let after else { return rest(before).count == 0 }
    guard case .mapping(let m) = parseYAML(after), rest(before).isEqual(rest(m)) else { return false }
    let meta = readMeta(front: after)
    if let p = patch.pinned, meta.pinned != p { return false }
    if let s = patch.sticky, meta.sticky != s.map(roundedSticky) || meta.legacy { return false }
    return true
}

/// 줄 단위로 고칠 수 없는 드문 모양일 때: YAML을 다시 써서라도 값은 맞게 저장한다(서식은 잃는다)
private func reserialize(_ front: String, _ patch: MetaPatch, legacy: Bool) -> String? {
    guard let node = try? Yams.compose(yaml: front), case .mapping(var map) = node else { return nil }
    func remove(_ key: String) { map = Node.Mapping(map.filter { $0.key.string != key }, map.tag, map.style) }
    if let p = patch.pinned {
        remove("pinned")
        if p { map["pinned"] = Node(true.description, Tag(.bool)) }
    }
    if let s = patch.sticky {
        if legacy { legacyKeys.forEach(remove) }
        remove("sticky")
        if let s, let n = try? Yams.compose(yaml: stickyLine(s)), let v = n.mapping?["sticky"] { map["sticky"] = v }
    }
    if map.isEmpty { return nil }
    return try? Yams.serialize(node: .mapping(map))
}

/// frontmatter의 pinned·sticky만 바꾼 새 원문. 남는 것이 없으면 nil(frontmatter 제거).
/// 사용자가 쓴 YAML이 깨져 있으면 건드리지 않는다.
public func writeMeta(front: String?, _ patch: MetaPatch) -> String? {
    let src = front ?? ""
    guard case .mapping(let before) = parseYAML(src) else { return front }
    let legacy = readMeta(front: src).legacy
    let patched = patchLines(src, patch, legacy: legacy)
    if verify(before, patched, patch, legacy: legacy) { return patched }
    let fallback = reserialize(src, patch, legacy: legacy)
    return verify(before, fallback, patch, legacy: legacy) ? fallback : front
}
