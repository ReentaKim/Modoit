import Foundation

// 제목 추출과 파일 이름 규칙. 이 파일에만 있다 (Brief 3.1-7, BUG-17, 18).
// 옮겨 온 곳: src-tauri/src/vault.rs

public let untitled = "새 메모"
let nameMaxChars = 60

func isThematicBreak(_ t: Scalars) -> Bool {
    let compact = t.filter { !$0.isWS }
    return compact.count >= 3 && ["-", "*", "_"].contains { m in compact.allSatisfy { $0 == m } }
}

func isFence(_ t: Scalars) -> Bool { t.hasPrefix("```") || t.hasPrefix("~~~") }

/// `[` 위치에서 시작하는 `[글](주소)`를 읽는다. (글, 끝 다음 위치)
private func parseInlineLink(_ c: [Unicode.Scalar], _ open: Int) -> (Scalars, Int)? {
    var depth = 0
    var i = open
    var close = -1
    while i < c.count {
        switch c[i] {
        case "\\": i += 1
        case "[": depth += 1
        case "]":
            depth -= 1
            if depth == 0 { close = i }
        default: break
        }
        if close >= 0 { break }
        i += 1
    }
    guard close >= 0, close + 1 < c.count, c[close + 1] == "(" else { return nil }
    depth = 0
    var j = close + 2
    while j < c.count {
        switch c[j] {
        case "\\": j += 1
        case "(": depth += 1
        case ")":
            if depth == 0 { return (c[(open + 1)..<close], j + 1) }
            depth -= 1
        default: break
        }
        j += 1
    }
    return nil
}

/// 인라인 강조 기호를 떼고 링크는 글만, 이미지는 지운다. 역슬래시 이스케이프는 글자로 둔다.
func stripInline(_ s: Scalars) -> [Unicode.Scalar] {
    let c = Array(s)
    var out: [Unicode.Scalar] = []
    var i = 0
    func word(_ k: Int) -> Bool { k >= 0 && k < c.count && c[k].isAlnum }
    while i < c.count {
        let ch = c[i]
        let next = i + 1 < c.count ? c[i + 1] : nil
        if ch == "\\", let n = next, n.isASCIIPunct {
            out.append(n)
            i += 2
            continue
        }
        if ch == "!", next == "[" {
            if let (_, end) = parseInlineLink(c, i + 1) { i = end; continue }
            out.append(ch)
        } else if ch == "[" {
            if let (text, end) = parseInlineLink(c, i) {
                out += stripInline(text)
                i = end
                continue
            }
            out.append(ch)
        } else if ch == "*" || ch == "`" {
            // 뗀다
        } else if ch == "~", next == "~" {
            i += 1
        } else if ch == "_" {
            // snake_case처럼 단어 안의 밑줄은 남긴다
            if word(i - 1) && word(i + 1) { out.append(ch) }
        } else {
            out.append(ch)
        }
        i += 1
    }
    return out
}

func decodeEntities(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
    var out: [Unicode.Scalar] = []
    var i = 0
    while i < s.count {
        guard s[i] == "&" else { out.append(s[i]); i += 1; continue }
        // 엔티티는 짧으므로 앞 12글자 안에서만 ';'를 찾는다
        let window = s[i..<min(i + 12, s.count)]
        var decoded: Unicode.Scalar?
        var length = 0
        if let semi = window.firstIndex(of: ";") {
            let name = String(s[(i + 1)..<semi])
            switch name {
            case "amp": decoded = "&"
            case "lt": decoded = "<"
            case "gt": decoded = ">"
            case "quot": decoded = "\""
            case "apos": decoded = "'"
            case "nbsp": decoded = "\u{a0}"
            default:
                var code: UInt32?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    let hex = name.dropFirst(2)
                    if !hex.isEmpty, hex.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit }) { code = UInt32(hex, radix: 16) }
                } else if name.hasPrefix("#") {
                    let dec = name.dropFirst()
                    if !dec.isEmpty, dec.unicodeScalars.allSatisfy(\.isASCIIDigit) { code = UInt32(dec) }
                }
                decoded = code.flatMap(Unicode.Scalar.init)
            }
            length = semi - i + 1
        }
        if let d = decoded {
            out.append(d)
            i += length
        } else {
            out.append("&")
            i += 1
        }
    }
    return out
}

/// 줄 앞의 목록·체크박스·제목·인용 기호를 뗀다(여러 겹도).
func stripBlockPrefix(_ input: Scalars) -> Scalars {
    var s = input
    while true {
        let before = s
        s = s.trimmedStart()
        if s.first == ">" {
            s = s.dropFirst()
        } else if s.first == "#" {
            let hashes = s.prefix { $0 == "#" }.count
            let r = s.dropFirst(hashes)
            if hashes <= 6, r.isEmpty || r.first!.isWS { s = r }
        } else if let r = ["- ", "* ", "+ "].lazy.compactMap({ s.stripPrefix($0) }).first {
            s = r
        } else if let r = ["[ ]", "[x]", "[X]"].lazy.compactMap({ s.stripPrefix($0) }).first {
            if r.isEmpty || r.first!.isWS { s = r }
        } else {
            let digits = s.prefix(while: \.isASCIIDigit).count
            if (1...9).contains(digits) {
                let r = s.dropFirst(digits)
                if let rest = r.stripPrefix(". ") ?? r.stripPrefix(") ") { s = rest }
            }
        }
        if s.count == before.count { return s }
    }
}

/// 한 줄을 표시용 글로 바꾼다. 의미 없는 줄이면 nil.
func cleanLine(_ line: Scalars) -> String? {
    let t = line.trimmed()
    if t.isEmpty || isThematicBreak(t) || isFence(t) { return nil }
    let text = decodeEntities(stripInline(stripBlockPrefix(t)))
        .map { $0 == "\u{a0}" || $0 == "\u{3000}" ? " " as Unicode.Scalar : $0 }
    let out = ArraySlice(text).trimmed()
    return out.isEmpty ? nil : String(out)
}

/// (제목, 미리보기): 의미 있는 첫째·둘째 줄
public func titleAndPreview(_ content: String) -> (title: String, preview: String) {
    var body = splitNote(content).body.scalars
    if body.first == "\u{feff}" { body = body.dropFirst() }
    var found: [String] = []
    for line in body.lines() {
        if let l = cleanLine(line) {
            found.append(l)
            if found.count == 2 { break }
        }
    }
    return (found.first ?? "", found.count > 1 ? found[1] : "")
}

public func extractTitle(_ content: String) -> String { titleAndPreview(content).title }

/// 파일·폴더 이름에 쓸 수 없는 문자를 걸러 내고 60자로 자른다. 비면 빈 문자열.
public func sanitizeComponent(_ s: String) -> String {
    let replaced = s.unicodeScalars.map { c -> Unicode.Scalar in
        switch c {
        case "/", "\\", ":", "*", "?", "\"", "<", ">", "|": return " "
        case "\u{0}"..."\u{1f}", "\u{7f}"..."\u{9f}", "\u{feff}": return " "
        default: return c
        }
    }
    let collapsed = replaced.split(whereSeparator: \.isWS).map { Array($0) }.joined(separator: [" "])
    func trim(_ x: Scalars) -> Scalars {
        var t = x
        while let f = t.first, f == "." || f == " " { t = t.dropFirst() }
        while let l = t.last, l == "." || l == " " { t = t.dropLast() }
        return t
    }
    return String(trim(trim(ArraySlice(collapsed)).prefix(nameMaxChars)))
}

/// 제목 → 파일 이름(확장자 제외). 비면 "새 메모".
public func fileBase(_ title: String) -> String {
    let s = sanitizeComponent(title)
    return s.isEmpty ? untitled : s
}

/// 폴더 이름 검증. 빈 이름과 점으로만 된 이름은 거부한다 (BUG-16).
public func folderName(_ name: String) throws -> String {
    let bad = VaultError("사용할 수 없는 폴더 이름입니다: \"\(name)\"")
    let t = name.scalars.trimmed()
    if t.isEmpty || t.allSatisfy({ $0 == "." }) { throw bad }
    let s = sanitizeComponent(String(t))
    if s.isEmpty { throw bad }
    return s
}
