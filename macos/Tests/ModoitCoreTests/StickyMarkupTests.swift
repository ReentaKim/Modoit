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

@Test("F-08 R-9: n번째 체크박스만 한 글자 바뀐다") func sticky_toggle_nth_checkbox() {
    let body = "# 장보기\r\n- [ ] 우유\n```\n- [ ] 코드 안\n```\n  - [x] 빵\n- [ ] 달걀\n"
    #expect(toggleCheckbox(body, index: 0, checked: true) == body.replacingOccurrences(of: "- [ ] 우유", with: "- [x] 우유"))
    #expect(toggleCheckbox(body, index: 1, checked: false) == body.replacingOccurrences(of: "- [x] 빵", with: "- [ ] 빵"))
    #expect(toggleCheckbox(body, index: 2, checked: true) == body.replacingOccurrences(of: "- [ ] 달걀", with: "- [x] 달걀"))
    // 이미 그 상태이거나 없는 체크박스는 건드리지 않는다
    #expect(toggleCheckbox(body, index: 1, checked: true) == nil)
    #expect(toggleCheckbox(body, index: 3, checked: true) == nil)
}
