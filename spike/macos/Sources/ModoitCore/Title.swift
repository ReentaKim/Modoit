import Foundation

public let untitled = "새 메모"
let nameMaxChars = 60

func isThematicBreak(_ t: Substring) -> Bool {
    let compact = t.filter { !$0.isWhitespace }
    return compact.count >= 3 && ["-", "*", "_"].contains { m in compact.allSatisfy { $0 == m } }
}

func isFence(_ t: Substring) -> Bool { t.hasPrefix("```") || t.hasPrefix("~~~") }

/// vault.rs `strip_block_prefix`
func stripBlockPrefix(_ input: Substring) -> Substring {
    var s = input
    while true {
        let before = s
        s = s.drop { $0.isWhitespace }
        if s.hasPrefix(">") {
            s = s.dropFirst()
        } else if s.hasPrefix("#") {
            let hashes = s.prefix { $0 == "#" }.count
            let r = s.dropFirst(hashes)
            if hashes <= 6, r.isEmpty || r.first!.isWhitespace { s = r }
        } else if let p = ["- ", "* ", "+ "].first(where: { s.hasPrefix($0) }) {
            s = s.dropFirst(p.count)
        } else if let p = ["[ ]", "[x]", "[X]"].first(where: { s.hasPrefix($0) }) {
            let r = s.dropFirst(p.count)
            if r.isEmpty || r.first!.isWhitespace { s = r }
        } else {
            let digits = s.prefix { $0.isASCII && $0.isNumber }.count
            if (1...9).contains(digits) {
                let r = s.dropFirst(digits)
                if r.hasPrefix(". ") || r.hasPrefix(") ") { s = r.dropFirst(2) }
            }
        }
        if s == before { return s }
    }
}

/// `[` 위치의 `[글](주소)` → (글, 끝 다음 위치)
private func parseInlineLink(_ c: [Character], _ open: Int) -> (String, Int)? {
    var i = open + 1, depth = 1
    while i < c.count {
        if c[i] == "\\" { i += 2; continue }
        if c[i] == "[" { depth += 1 }
        if c[i] == "]" { depth -= 1; if depth == 0 { break } }
        i += 1
    }
    guard i < c.count, i + 1 < c.count, c[i + 1] == "(" else { return nil }
    let text = String(c[(open + 1)..<i])
    var j = i + 2, paren = 1
    while j < c.count {
        if c[j] == "(" { paren += 1 }
        if c[j] == ")" { paren -= 1; if paren == 0 { return (text, j + 1) } }
        j += 1
    }
    return nil
}

/// vault.rs `strip_inline`
func stripInline(_ s: String) -> String {
    let c = Array(s)
    var out = "", i = 0
    func word(_ k: Int) -> Bool { k >= 0 && k < c.count && (c[k].isLetter || c[k].isNumber) }
    while i < c.count {
        let ch = c[i]
        switch ch {
        // Rust is_ascii_punctuation = ASCII 문장 부호 + 기호
        case "\\" where i + 1 < c.count && c[i + 1].isASCII && (c[i + 1].isPunctuation || c[i + 1].isSymbol):
            out.append(c[i + 1]); i += 2; continue
        case "!" where i + 1 < c.count && c[i + 1] == "[":
            if let (_, end) = parseInlineLink(c, i + 1) { i = end; continue }
            out.append(ch)
        case "[":
            if let (text, end) = parseInlineLink(c, i) { out += stripInline(text); i = end; continue }
            out.append(ch)
        case "*", "`": break
        case "~" where i + 1 < c.count && c[i + 1] == "~": i += 1
        case "_" where word(i - 1) && word(i + 1): out.append(ch)
        case "_": break
        default: out.append(ch)
        }
        i += 1
    }
    return out
}

func cleanLine(_ line: Substring) -> String? {
    let t = line.trimmingCharacters(in: .whitespaces)[...]
    if t.isEmpty || isThematicBreak(t) || isFence(t) { return nil }
    let text = stripInline(String(stripBlockPrefix(t)))
        .map { $0 == "\u{a0}" || $0 == "\u{3000}" ? " " : $0 }
    let out = String(text).trimmingCharacters(in: .whitespaces)
    return out.isEmpty ? nil : out
}

/// (제목, 미리보기). 스파이크는 HTML 엔티티 해석을 뺐다.
public func titleAndPreview(_ content: String) -> (String, String) {
    let body = splitNote(content).body
    var found: [String] = []
    for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
        if let l = cleanLine(line) { found.append(l); if found.count == 2 { break } }
    }
    return (found.first ?? "", found.count > 1 ? found[1] : "")
}

public func extractTitle(_ content: String) -> String { titleAndPreview(content).0 }

/// vault.rs `sanitize_component`
public func sanitizeComponent(_ s: String) -> String {
    let replaced = s.unicodeScalars.map { u -> Character in
        switch u {
        case "/", "\\", ":", "*", "?", "\"", "<", ">", "|": return " "
        case "\u{0}"..."\u{1f}", "\u{7f}"..."\u{9f}", "\u{feff}": return " "
        default: return Character(u)
        }
    }
    let collapsed = String(replaced).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let trim = { (x: String) in x.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
    return trim(String(trim(collapsed).prefix(nameMaxChars)))
}

public func fileBase(_ title: String) -> String {
    let s = sanitizeComponent(title)
    return s.isEmpty ? untitled : s
}
