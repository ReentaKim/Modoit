import Foundation

// 네이티브 스티키 편집기의 "화면만 꾸미기" 규칙 (아키텍처 3.3, V2-10).
// 저장하는 글자는 Markdown 원문 그대로다. 여기서는 한 줄을 보고 어느 글자를 숨기고 어떻게 꾸밀지,
// 그리고 체크박스를 눌렀을 때 원문을 어떻게 바꾸는지만 계산한다. UI 코드는 없다. 스티키는 보기 전용이다 (D-25).
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

/// 문서에서 `index`번째(0부터) 체크박스를 `checked` 상태로 바꾼 본문. 그 줄의 한 글자만 바뀐다 (F-08 R-9).
/// 코드 블록 안의 줄은 세지 않는다. 그 체크박스가 없거나 이미 그 상태면 nil(아무것도 바꾸지 않는다)
public func toggleCheckbox(_ body: String, index: Int, checked: Bool) -> String? {
    var units = Array(body.utf16)
    var lineStart = 0
    var n = 0
    var fence: UInt16?
    while lineStart <= units.count {
        var end = lineStart
        while end < units.count, units[end] != 10 { end += 1 }
        var textEnd = end
        if textEnd > lineStart, units[textEnd - 1] == 13 { textEnd -= 1 }
        let line = String(utf16CodeUnits: Array(units[lineStart..<textEnd]), count: textEnd - lineStart)
        let trimmed = line.drop { $0 == " " }
        let lead = line.count - trimmed.count
        if lead <= 3, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            let mark = trimmed.utf16.first!
            if fence == nil { fence = mark } else if fence == mark { fence = nil }
        } else if fence == nil {
            let l = stickyLine(line)
            if case .checkbox(let now) = l.kind, let at = l.checkMark {
                if n == index {
                    guard now != checked else { return nil }
                    units[lineStart + at] = checked ? u("x") : space
                    return String(utf16CodeUnits: units, count: units.count)
                }
                n += 1
            }
        }
        lineStart = end + 1
    }
    return nil
}
