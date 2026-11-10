// 네이티브 스티키 편집기의 줄 해석과 편집 규칙 (FR-51, F-08 R-9, F-06 R-1).
import Foundation
import Testing
@testable import ModoitCore

/// 고침을 줄에 적용한 결과와 커서
private func apply(_ line: String, _ e: StickyEdit?) -> (String, Int)? {
    guard let e else { return nil }
    var s = Array(line.utf16)
    s.replaceSubrange(e.range, with: Array(e.text.utf16))
    return (String(utf16CodeUnits: s, count: s.count), e.cursor)
}

private func content(_ line: String) -> String {
    let s = Array(line.utf16)
    let from = stickyLine(line).contentStart
    return String(utf16CodeUnits: Array(s[from...]), count: s.count - from)
}

@Test func sticky_line_kinds() {
    #expect(stickyLine("그냥 글").kind == .paragraph)
    #expect(stickyLine("# 제목").kind == .heading(level: 1))
    #expect(stickyLine("### 제목").kind == .heading(level: 3))
    #expect(stickyLine("#### 넷").kind == .paragraph) // 판정에서 TipTap으로 가는 줄. 여기선 꾸미지 않는다
    #expect(stickyLine("#해시태그").kind == .paragraph)
    #expect(stickyLine("- 점").kind == .bullet)
    #expect(stickyLine("* 별").kind == .bullet)
    #expect(stickyLine("12. 열둘").kind == .ordered(number: 12))
    #expect(stickyLine("3) 셋").kind == .ordered(number: 3))
    #expect(stickyLine("- [ ] 할 일").kind == .checkbox(checked: false))
    #expect(stickyLine("- [x] 끝").kind == .checkbox(checked: true))
    #expect(stickyLine("- [X] 끝").kind == .checkbox(checked: true))
    #expect(stickyLine("- [ ]").kind == .checkbox(checked: false))
    #expect(stickyLine("- [ ]글").kind == .bullet) // 공백이 없으면 체크박스가 아니다
    #expect(stickyLine("---").kind == .rule)
    #expect(stickyLine("* * *").kind == .rule)
    #expect(stickyLine("&nbsp;").kind == .blank)
    #expect(stickyLine("").kind == .paragraph)
}

@Test func sticky_line_content_and_depth() {
    #expect(content("# 제목") == "제목")
    #expect(content("- [ ] 할 일") == "할 일")
    #expect(content("  - 안쪽") == "안쪽")
    #expect(stickyLine("  - 안쪽").depth == 1)
    #expect(stickyLine("    - [x] 더 안쪽").depth == 2)
    #expect(stickyLine("    - [x] 더 안쪽").checkMark == 7)
    #expect(content("> 인용") == "인용")
    #expect(stickyLine("> 인용").quoteDepth == 1)
    #expect(stickyLine("> > 겹").quoteDepth == 2)
    #expect(stickyLine("> - [ ] 인용 안 할 일").kind == .checkbox(checked: false))
    #expect(content("> - [ ] 인용 안 할 일") == "인용 안 할 일")
    // 한글·이모지가 앞에 있어도 위치는 UTF-16 단위
    #expect(stickyLine("- [ ] 😀").contentStart == 6)
}

@Test func sticky_inlines() {
    func kinds(_ s: String) -> [String] {
        let u16 = Array(s.utf16)
        return stickyInlines(s).filter { $0.kind != .marker }.map {
            "\($0.kind):" + String(utf16CodeUnits: Array(u16[$0.range]), count: $0.range.count)
        }
    }
    #expect(kinds("**굵게** 와 *기울임*") == ["bold:굵게", "italic:기울임"])
    #expect(kinds("~~취소~~ `코드 *안*`") == ["strike:취소", "code:코드 *안*"])
    #expect(kinds("[링크](https://a.com/x_y) 뒤") == ["link(url: \"https://a.com/x_y\"):링크"])
    #expect(kinds("snake_case 와 _기울임_") == ["italic:기울임"])
    #expect(kinds("2 * 3 * 4") == []) // 공백 옆 별표는 강조가 아니다
    #expect(kinds("**닫지 않음") == [])
    // 숨기는 기호의 범위
    let m = stickyInlines("**a**").filter { $0.kind == .marker }.map(\.range)
    #expect(m == [0..<2, 3..<5])
    let l = stickyInlines("[글](u)").filter { $0.kind == .marker }.map(\.range)
    #expect(l == [0..<1, 2..<6])
}

@Test("F-08 R-9: 체크는 한 글자만 바꾼다") func sticky_toggle_check() {
    #expect(apply("- [ ] 할 일", stickyToggleCheck("- [ ] 할 일"))?.0 == "- [x] 할 일")
    #expect(apply("- [x] 할 일", stickyToggleCheck("- [x] 할 일"))?.0 == "- [ ] 할 일")
    #expect(apply("  * [X] 안쪽", stickyToggleCheck("  * [X] 안쪽"))?.0 == "  * [ ] 안쪽")
    let e = stickyToggleCheck("> - [ ] 인용 안")
    #expect(e?.range.count == 1)
    #expect(stickyToggleCheck("- 점") == nil)
}

@Test func sticky_newline_continues_lists() {
    func enter(_ line: String, at: Int? = nil) -> String? {
        let c = at ?? line.utf16.count
        return apply(line, stickyNewline(line, cursor: c))?.0
    }
    #expect(enter("- 가") == "- 가\n- ")
    #expect(enter("- [x] 끝낸 일") == "- [x] 끝낸 일\n- [ ] ")
    #expect(enter("  - [ ] 안쪽") == "  - [ ] 안쪽\n  - [ ] ")
    #expect(enter("1. 첫째") == "1. 첫째\n2. ")
    #expect(enter("9) 아홉") == "9) 아홉\n10) ")
    #expect(enter("> 인용") == "> 인용\n> ")
    #expect(enter("> - 인용 목록") == "> - 인용 목록\n> - ")
    // 줄 가운데서 나누기
    #expect(enter("- 가나", at: 3) == "- 가\n- 나")
    // 빈 항목에서 Enter: 목록을 끝낸다. 안쪽이면 한 단계 내어쓴다
    #expect(enter("- ") == "")
    #expect(enter("- [ ] ") == "")
    #expect(enter("  - ") == "- ")
    #expect(enter("> ") == "")
    // 보통 문단·제목은 기본 동작
    #expect(stickyNewline("문단", cursor: 2) == nil)
    #expect(stickyNewline("# 제목", cursor: 4) == nil)
    // 기호 안에 커서가 있으면 기본 동작
    #expect(stickyNewline("- 가", cursor: 1) == nil)
}

@Test func sticky_indent_and_backspace() {
    #expect(apply("- 가", stickyIndent("- 가", cursor: 3, deeper: true))! == ("  - 가", 5))
    #expect(apply("  - 가", stickyIndent("  - 가", cursor: 5, deeper: false))! == ("- 가", 3))
    #expect(stickyIndent("- 가", cursor: 3, deeper: false) == nil)
    #expect(stickyIndent("문단", cursor: 1, deeper: true) == nil)
    #expect(apply("> - 가", stickyIndent("> - 가", cursor: 5, deeper: true))?.0 == ">   - 가")
    // 본문 맨 앞에서 Backspace: 기호를 지운다
    #expect(apply("- [ ] 가", stickyBackspaceAtContentStart("- [ ] 가", cursor: 6))! == ("가", 0))
    #expect(apply("# 제목", stickyBackspaceAtContentStart("# 제목", cursor: 2))! == ("제목", 0))
    #expect(apply("  - 가", stickyBackspaceAtContentStart("  - 가", cursor: 4))?.0 == "- 가")
    #expect(stickyBackspaceAtContentStart("- 가", cursor: 3) == nil)
    #expect(stickyBackspaceAtContentStart("문단", cursor: 0) == nil)
}

@Test("F-06 R-1: 단축 입력 결과는 메인 편집기와 같은 Markdown") func sticky_shortcuts() {
    func typed(_ line: String) -> String? { apply(line, stickyShortcut(line, cursor: line.utf16.count))?.0 }
    #expect(typed("[] ") == "- [ ] ")
    #expect(typed("[ ] ") == "- [ ] ")
    #expect(typed("[x] ") == "- [x] ")
    #expect(typed("- [] ") == "- [ ] ")
    #expect(typed("  - [] ") == "  - [ ] ")
    #expect(typed("| ") == "> ")
    #expect(typed("가 ->") == "가 →")
    #expect(typed("<-") == "←")
    #expect(typed("`a ->") == nil) // 코드 안에서는 바꾸지 않는다
    // 이미 Markdown인 것은 그대로 둔다: `- `, `1. `, `# `
    #expect(typed("- ") == nil)
    #expect(typed("1. ") == nil)
    #expect(typed("# ") == nil)
    #expect(typed("글 [] ") == nil) // 줄 가운데는 아니다
}
