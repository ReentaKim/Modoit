import Foundation

// 스티키를 네이티브 편집기로 열 수 있는지 판정한다 (F-08 3.2, R-10, D-12).
// 허용 목록 방식이다: 아래에서 "네이티브가 다룰 수 있다"고 확인한 줄 모양만 통과시키고,
// 조금이라도 다른 것이 있으면 TipTap 편집기로 연다. 읽기 전용 판정(FR-43)은 여기서 하지 않는다.
// 그것은 TipTap 쪽(src/lib/markdownSafety.ts, src/editor/editability.ts)이 실제로 열어 보고 정한다.

public enum StickyEditorKind: Sendable, Equatable {
    case native
    case web
}

private func listMarkerLength(_ t: Scalars) -> Int? {
    if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return 2 }
    let digits = t.prefix(while: \.isASCIIDigit).count
    if (1...9).contains(digits) {
        let r = t.dropFirst(digits)
        if r.hasPrefix(". ") || r.hasPrefix(") ") { return digits + 2 }
    }
    return nil
}

private func isOnly(_ t: Scalars, _ c: Unicode.Scalar) -> Bool { !t.isEmpty && t.allSatisfy { $0 == c } }

/// 한 줄 안(인라인)에서 네이티브가 다루지 못하는 것
private func inlineBlockers(_ t: Scalars, into found: inout [String]) {
    let c = Array(t)
    func add(_ s: String) { if !found.contains(s) { found.append(s) } }
    var i = 0
    while i < c.count {
        let ch = c[i]
        let next = i + 1 < c.count ? c[i + 1] : nil
        switch ch {
        case "\\": add("역슬래시 이스케이프")
        case "!" where next == "[": add("이미지")
        case "<":
            if let n = next, n.isASCIIAlpha || n == "/" || n == "!" || n == "?" { add("HTML") }
        case "&":
            // &이름; &#숫자; 꼴
            var j = i + 1
            if j < c.count, c[j] == "#" { j += 1 }
            let startName = j
            while j < c.count, c[j].isASCIIAlpha || c[j].isASCIIDigit { j += 1 }
            if j > startName, j < c.count, c[j] == ";" { add("HTML 엔티티") }
        case "[":
            if next == "^" { add("각주") }
            // [글](주소) 만 허용. 제목이 붙거나 꺾쇠 주소면 TipTap
            if let close = c[i...].firstIndex(of: "]"), close + 1 < c.count {
                if c[close + 1] == "(" {
                    if let end = c[(close + 1)...].firstIndex(of: ")") {
                        let dest = c[(close + 2)..<end]
                        if dest.first == "<" { add("꺾쇠로 감싼 링크 주소") }
                        if dest.contains(where: \.isWS) { add("링크 제목") }
                    }
                } else if c[close + 1] == "[" || (close + 1 < c.count && c[close + 1] == ":" && i == 0) {
                    add("참조 링크")
                }
            }
        default: break
        }
        i += 1
    }
}

/// 네이티브 스티키 편집기가 다루지 못하는 서식 이름들. 비어 있으면 네이티브로 연다.
public func nativeBlockers(_ body: String) -> [String] {
    var found: [String] = []
    func add(_ s: String) { if !found.contains(s) { found.append(s) } }
    var prevBlank = true
    var prevWasList = false
    for raw in body.scalars.lines() {
        var line = raw
        if line.trimmed().isEmpty {
            prevBlank = true
            continue
        }
        defer { prevBlank = false }
        // 빈 줄을 남기려고 편집기가 쓰는 `&nbsp;` 한 줄
        if line.trimmed().elementsEqual("&nbsp;".unicodeScalars) { prevWasList = false; continue }
        if line.last == "\\" || (line.count >= 2 && line.suffix(2).allSatisfy { $0 == " " }) { add("줄 안 줄바꿈") }

        // 인용 기호를 벗긴다(여러 겹)
        var inQuote = false
        while true {
            let t = line.trimmedStart()
            guard t.first == ">", line.count - t.count <= 3 else { break }
            line = t.dropFirst()
            if line.first == " " { line = line.dropFirst() }
            inQuote = true
        }
        if inQuote, line.trimmed().isEmpty { continue }

        let t = line.trimmedStart()
        let indent = line.count - t.count
        let hasTab = line.prefix(indent).contains("\t")
        let marker = listMarkerLength(t)
        if marker == nil {
            // 목록이 아닌데 들여썼다: 들여쓴 코드 블록이거나 목록 항목의 이어지는 줄이다
            if indent >= 4 || hasTab { add(prevWasList ? "여러 줄 목록 항목" : "들여쓴 코드 블록") }
            else if indent > 0, prevWasList, !prevBlank { add("여러 줄 목록 항목") }
        }

        if isFence(t) { add("코드 블록") }
        if t.first == "|" { add("표") }
        if isOnly(t.trimmedEnd(), "=") { add("밑줄식 제목") }
        if isThematicBreak(t), marker == nil, !prevBlank, isOnly(t.filter { !$0.isWS }[...], "-") { add("밑줄식 제목") }
        if t.first == "#" {
            let hashes = t.prefix { $0 == "#" }.count
            let r = t.dropFirst(hashes)
            if hashes > 3, hashes <= 6, r.isEmpty || r.first!.isWS { add("제목 4~6") }
        }

        var content = t
        if let m = marker {
            content = t.dropFirst(m)
            // 체크박스
            if let r = content.stripPrefix("[ ] ") ?? content.stripPrefix("[x] ") ?? content.stripPrefix("[X] ") { content = r }
            if listMarkerLength(content.trimmedStart()) != nil { add("한 줄에 겹친 목록 기호") }
        }
        prevWasList = marker != nil
        inlineBlockers(content, into: &found)
    }
    return found
}

/// 스티키를 어떤 편집기로 열지 (F-08 4.2). 본문만 본다(frontmatter 제외).
public func stickyEditorKind(_ content: String) -> StickyEditorKind {
    nativeBlockers(splitNote(content).body).isEmpty ? .native : .web
}
