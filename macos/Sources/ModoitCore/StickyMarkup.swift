import Foundation

// 네이티브 스티키 편집기의 "화면만 꾸미기" 규칙 (아키텍처 3.3, V2-10).
// 저장하는 글자는 Markdown 원문 그대로다. 여기서는 한 줄을 보고 어느 글자를 숨기고 어떻게 꾸밀지,
// 그리고 키 입력(Enter, 체크, 단축 입력)이 원문을 어떻게 바꾸는지만 계산한다. UI 코드는 없다.
// 위치는 모두 UTF-16 단위다(NSTextView의 NSRange와 같다).

public enum StickyLineKind: Equatable, Sendable {
    case paragraph
    case heading(level: Int)
    case bullet
    case ordered(number: Int)
    case checkbox(checked: Bool)
    case rule
    /// 빈 줄을 남기려고 쓰는 `&nbsp;` 한 줄
    case blank
}

public struct StickyLine: Equatable, Sendable {
    public var kind: StickyLineKind
    /// 인용(`>`) 겹 수
    public var quoteDepth: Int
    /// 목록 들여쓰기 단계(0부터)
    public var depth: Int
    /// 숨길 앞부분(들여쓰기·인용 기호·목록 기호·체크박스·`#`)의 끝. 본문은 여기서 시작한다
    public var contentStart: Int
    /// 체크박스의 `[ ]` 안 글자(공백 또는 x) 위치
    public var checkMark: Int?
}

public enum StickyInlineKind: Equatable, Sendable {
    case bold, italic, strike, code
    /// 링크의 보이는 글. `url`은 숨긴 주소다
    case link(url: String)
    /// 숨기는 기호(`**`, `` ` ``, `](주소)` 등)
    case marker
}

public struct StickyInline: Equatable, Sendable {
    public var kind: StickyInlineKind
    public var range: Range<Int>
}

private typealias U16 = [UInt16]

private func u(_ c: Character) -> UInt16 { c.utf16.first! }
private let space = u(" "), tab = u("\t")

private func digits(_ s: ArraySlice<UInt16>) -> Int { s.prefix { $0 >= 48 && $0 <= 57 }.count }

private func hasPrefix(_ s: ArraySlice<UInt16>, _ p: String) -> Bool { s.starts(with: p.utf16) }

/// 한 줄(줄바꿈 제외)의 모양
public func stickyLine(_ line: String) -> StickyLine {
    let s = Array(line.utf16)
    var i = 0
    var quote = 0
    // 인용 기호
    while true {
        var j = i
        while j < s.count, s[j] == space, j - i < 3 { j += 1 }
        guard j < s.count, s[j] == u(">") else { break }
        i = j + 1
        if i < s.count, s[i] == space { i += 1 }
        quote += 1
    }
    let afterQuote = i
    var indent = 0
    while i < s.count, s[i] == space || s[i] == tab {
        indent += s[i] == tab ? 4 : 1
        i += 1
    }
    let rest = s[i...]
    var out = StickyLine(kind: .paragraph, quoteDepth: quote, depth: 0, contentStart: afterQuote, checkMark: nil)

    if String(utf16CodeUnits: Array(rest), count: rest.count).trimmingCharacters(in: .whitespaces) == "&nbsp;" {
        out.kind = .blank
        out.contentStart = s.count
        return out
    }
    let compact = rest.filter { $0 != space && $0 != tab }
    if compact.count >= 3, [u("-"), u("*"), u("_")].contains(where: { m in compact.allSatisfy { $0 == m } }) {
        out.kind = .rule
        out.contentStart = s.count
        return out
    }
    if rest.first == u("#") {
        let level = rest.prefix { $0 == u("#") }.count
        let after = rest.dropFirst(level)
        if level <= 3, after.first == space {
            out.kind = .heading(level: level)
            out.contentStart = i + level + 1
            return out
        }
    }
    var marker = 0
    var number: Int?
    if hasPrefix(rest, "- ") || hasPrefix(rest, "* ") || hasPrefix(rest, "+ ") {
        marker = 2
    } else {
        let d = digits(rest)
        if (1...9).contains(d) {
            let r = rest.dropFirst(d)
            if hasPrefix(r, ". ") || hasPrefix(r, ") ") {
                marker = d + 2
                number = Int(String(utf16CodeUnits: Array(rest.prefix(d)), count: d))
            }
        }
    }
    guard marker > 0 else { return out }
    out.depth = indent / 2
    let content = i + marker
    if let n = number {
        out.kind = .ordered(number: n)
        out.contentStart = content
        return out
    }
    let c = s[content...]
    if hasPrefix(c, "[ ] ") || hasPrefix(c, "[x] ") || hasPrefix(c, "[X] ") {
        out.kind = .checkbox(checked: c[content + 1] != space)
        out.checkMark = content + 1
        out.contentStart = content + 4
    } else if c.count == 3, hasPrefix(c, "[ ]") || hasPrefix(c, "[x]") || hasPrefix(c, "[X]") {
        // 글을 아직 쓰지 않은 체크박스
        out.kind = .checkbox(checked: c[content + 1] != space)
        out.checkMark = content + 1
        out.contentStart = content + 3
    } else {
        out.kind = .bullet
        out.contentStart = content
    }
    return out
}

/// 줄 안의 굵게·기울임·취소선·코드·링크. `from`부터 본다(보통 `contentStart`).
/// 판정(`nativeBlockers`)을 통과한 줄만 온다고 가정한다: 역슬래시·이미지·HTML은 없다.
public func stickyInlines(_ line: String, from: Int = 0) -> [StickyInline] {
    let s = Array(line.utf16)
    var out: [StickyInline] = []
    func find(_ pat: String, from i: Int) -> Int? {
        let p = Array(pat.utf16)
        guard i + p.count <= s.count else { return nil }
        var k = i
        while k + p.count <= s.count {
            if s[k] == p[0], s[k..<(k + p.count)].elementsEqual(p) { return k }
            k += 1
        }
        return nil
    }
    func isWord(_ k: Int) -> Bool {
        guard k >= 0, k < s.count, let sc = Unicode.Scalar(s[k]) else { return k >= 0 && k < s.count }
        return sc.isAlnum
    }
    func pair(_ open: Int, _ mark: String, _ kind: StickyInlineKind) -> Int? {
        let n = mark.utf16.count
        guard let close = find(mark, from: open + n), close > open + n else { return nil }
        // 여는 기호 뒤와 닫는 기호 앞에는 공백이 올 수 없다
        if s[open + n] == space || s[close - 1] == space { return nil }
        out.append(StickyInline(kind: .marker, range: open..<(open + n)))
        out.append(StickyInline(kind: kind, range: (open + n)..<close))
        out.append(StickyInline(kind: .marker, range: close..<(close + n)))
        return close + n
    }
    var i = from
    while i < s.count {
        let c = s[i]
        var next: Int?
        if c == u("`") {
            next = pair(i, "`", .code)
        } else if c == u("*"), i + 1 < s.count, s[i + 1] == u("*") {
            next = pair(i, "**", .bold)
        } else if c == u("_"), i + 1 < s.count, s[i + 1] == u("_") {
            next = pair(i, "__", .bold)
        } else if c == u("~"), i + 1 < s.count, s[i + 1] == u("~") {
            next = pair(i, "~~", .strike)
        } else if c == u("*") {
            next = pair(i, "*", .italic)
        } else if c == u("_"), !isWord(i - 1) {
            // snake_case처럼 단어 안의 밑줄은 강조가 아니다
            if let close = find("_", from: i + 1), !isWord(close + 1) { next = pair(i, "_", .italic) }
        } else if c == u("["), let close = find("](", from: i + 1), let end = find(")", from: close + 2) {
            let url = String(utf16CodeUnits: Array(s[(close + 2)..<end]), count: end - close - 2)
            if close > i + 1, !url.isEmpty, !url.contains(" ") {
                out.append(StickyInline(kind: .marker, range: i..<(i + 1)))
                out.append(StickyInline(kind: .link(url: url), range: (i + 1)..<close))
                out.append(StickyInline(kind: .marker, range: close..<(end + 1)))
                next = end + 1
            }
        }
        i = next ?? i + 1
    }
    return out
}

// MARK: - 편집

/// 원문에 가하는 고침 하나: `range`를 `text`로 바꾸고 커서를 `cursor`에 둔다 (모두 줄 안 위치)
public struct StickyEdit: Equatable, Sendable {
    public var range: Range<Int>
    public var text: String
    public var cursor: Int
}

/// 체크박스를 누른다. `[ ]` ↔ `[x]` 한 글자만 바뀐다. 체크박스 줄이 아니면 nil
public func stickyToggleCheck(_ line: String) -> StickyEdit? {
    let l = stickyLine(line)
    guard case .checkbox(let checked) = l.kind, let at = l.checkMark else { return nil }
    return StickyEdit(range: at..<(at + 1), text: checked ? " " : "x", cursor: at + 1)
}

/// 줄에서 Enter를 눌렀다. 목록이면 다음 항목 기호를 이어 주고, 빈 항목이면 목록에서 나온다.
/// 기본 동작(줄바꿈만)이면 nil
public func stickyNewline(_ line: String, cursor: Int) -> StickyEdit? {
    let l = stickyLine(line)
    let s = Array(line.utf16)
    let prefix: String
    switch l.kind {
    case .bullet, .checkbox, .ordered:
        guard cursor >= l.contentStart else { return nil }
        let head = String(utf16CodeUnits: Array(s[..<l.contentStart]), count: l.contentStart)
        let isEmpty = s[l.contentStart...].allSatisfy { $0 == space }
        if isEmpty {
            // 빈 항목에서 Enter: 한 단계 내어쓰거나 목록을 끝낸다
            if l.depth > 0, let e = stickyIndent(line, cursor: cursor, deeper: false) { return e }
            let keep = String(repeating: "> ", count: l.quoteDepth)
            return StickyEdit(range: 0..<s.count, text: keep, cursor: keep.utf16.count)
        }
        switch l.kind {
        case .checkbox:
            // 새 항목은 늘 체크하지 않은 상태
            var h = Array(head.utf16)
            if let at = l.checkMark { h[at] = space }
            var str = String(utf16CodeUnits: h, count: h.count)
            if !str.hasSuffix(" ") { str += " " }
            prefix = str
        case .ordered(let n):
            let markerStart = l.contentStart - "\(n). ".utf16.count
            let lead = String(utf16CodeUnits: Array(s[..<markerStart]), count: markerStart)
            let sep = s[l.contentStart - 2] == u(")") ? ")" : "."
            prefix = "\(lead)\(n + 1)\(sep) "
        default:
            prefix = head
        }
    case .paragraph where l.quoteDepth > 0:
        if s[l.contentStart...].allSatisfy({ $0 == space }) { return StickyEdit(range: 0..<s.count, text: "", cursor: 0) }
        prefix = String(repeating: "> ", count: l.quoteDepth)
    default:
        return nil
    }
    let insert = "\n" + prefix
    return StickyEdit(range: cursor..<cursor, text: insert, cursor: cursor + insert.utf16.count)
}

/// Tab·Shift-Tab: 목록 항목을 한 단계(공백 2칸) 들이거나 내어쓴다. 목록이 아니면 nil
public func stickyIndent(_ line: String, cursor: Int, deeper: Bool) -> StickyEdit? {
    let l = stickyLine(line)
    switch l.kind {
    case .bullet, .checkbox, .ordered: break
    default: return nil
    }
    let s = Array(line.utf16)
    // 인용 기호 뒤가 들여쓰기 자리다
    var at = 0
    var q = 0
    while q < l.quoteDepth, at < s.count {
        if s[at] == u(">") { q += 1 }
        at += 1
    }
    if q > 0, at < s.count, s[at] == space { at += 1 }
    if deeper { return StickyEdit(range: at..<at, text: "  ", cursor: cursor + 2) }
    let spaces = s[at...].prefix { $0 == space }.count
    let remove = min(2, spaces)
    guard remove > 0 else { return nil }
    return StickyEdit(range: at..<(at + remove), text: "", cursor: max(at, cursor - remove))
}

/// 본문 맨 앞에서 Backspace: 목록·제목·인용 기호를 지워 보통 문단으로 만든다. 해당 없으면 nil
public func stickyBackspaceAtContentStart(_ line: String, cursor: Int) -> StickyEdit? {
    let l = stickyLine(line)
    guard cursor == l.contentStart, l.contentStart > 0 else { return nil }
    switch l.kind {
    case .rule, .blank: return nil
    case .paragraph where l.quoteDepth == 0: return nil
    default: break
    }
    if l.depth > 0, let e = stickyIndent(line, cursor: cursor, deeper: false) { return e }
    return StickyEdit(range: 0..<l.contentStart, text: "", cursor: 0)
}

/// 방금 `typed`(공백 등)를 쳐서 줄 앞부분이 단축 입력이 되었는지 (F-06 4.1).
/// `line`은 친 글자가 이미 들어간 상태, `cursor`는 그 뒤다. 메인 편집기와 같은 Markdown이 되어야 한다 (F-06 R-1).
public func stickyShortcut(_ line: String, cursor: Int) -> StickyEdit? {
    let s = Array(line.utf16)
    guard cursor <= s.count, cursor > 0 else { return nil }
    let l = stickyLine(line)
    let before = String(utf16CodeUnits: Array(s[..<cursor]), count: cursor)
    // 글자 안 변환: -> → →, <- → ← (코드 안은 제외)
    if before.hasSuffix("->") || before.hasSuffix("<-") {
        let inCode = stickyInlines(line).contains { $0.kind == .code && $0.range.contains(cursor - 1) }
            || before.filter({ $0 == "`" }).count % 2 == 1
        if !inCode {
            let arrow = before.hasSuffix("->") ? "→" : "←"
            return StickyEdit(range: (cursor - 2)..<cursor, text: arrow, cursor: cursor - 1)
        }
    }
    // 아래는 줄 맨 앞(들여쓰기·인용 뒤)에서 "기호 + 공백"을 쳤을 때만
    guard s[cursor - 1] == space else { return nil }
    var start = 0
    switch l.kind {
    case .bullet, .ordered, .checkbox:
        // 목록 안에서 `[] `를 치면 체크박스로
        start = l.contentStart
    default:
        start = l.contentStart
        while start < s.count, s[start] == space, start < cursor - 1 { start += 1 }
    }
    guard start < cursor else {
        // `- [ ]`처럼 이미 체크박스로 읽힌 직후
        return nil
    }
    let typed = String(utf16CodeUnits: Array(s[start..<cursor]), count: cursor - start)
    let inList: Bool = { if case .bullet = l.kind { return true } else { return false } }()
    func replace(_ text: String) -> StickyEdit {
        StickyEdit(range: start..<cursor, text: text, cursor: start + text.utf16.count)
    }
    switch typed {
    case "[] ", "[ ] ": return replace(inList ? "[ ] " : "- [ ] ")
    case "[x] ", "[X] ": return replace(inList ? "[x] " : "- [x] ")
    case "| ": return inList ? nil : replace("> ")
    default: return nil
    }
}
