// F-08 3.2 / R-10 / D-12: 네이티브 스티키 편집기로 열 수 있는 메모인지.
import Foundation
import Testing
@testable import ModoitCore

private let native: [String] = [
    "",
    "그냥 문단\n\n둘째 문단",
    "# 제목 1\n## 제목 2\n### 제목 3",
    "- [ ] 할 일\n- [x] 끝낸 일\n  - [ ] 안쪽 할 일\n    - 더 안쪽",
    "1. 첫째\n2. 둘째\n   - 섞인 목록",
    "**굵게** *기울임* ~~취소~~ `코드` [링크](https://example.com/a_b)",
    "> 인용\n> 둘째 줄\n>\n> - 인용 안 목록",
    "문단\n\n---\n\n다음",
    "***\n처음부터 구분선",
    "빈 줄 표시\n\n&nbsp;\n\n다음",
    "R&D, AT&T, a < b, 3 > 2, 10~20, snake_case",
    "---\npinned: true\nsticky: { color: yellow, x: 1, y: 2, w: 280, h: 280, onTop: false, open: true }\n---\n- [ ] 머리말이 있어도 본문만 본다",
]

@Test("FR-51: 네이티브로 여는 메모", arguments: native)
func classify_native(_ md: String) {
    #expect(nativeBlockers(splitNote(md).body) == [], "\(md.debugDescription)")
    #expect(stickyEditorKind(md) == .native)
}

private let web: [(String, String)] = [
    ("| 가 | 나 |\n|---|---|\n| 1 | 2 |", "표"),
    ("<details>\n<summary>토글</summary>\n\n안\n\n</details>", "HTML"),
    ("```\n코드\n```", "코드 블록"),
    ("~~~js\nx\n~~~", "코드 블록"),
    ("![그림](../attachments/a.png)", "이미지"),
    ("글 <b>굵게</b>", "HTML"),
    ("<https://example.com>", "HTML"),
    ("#### 제목 4", "제목 4~6"),
    ("제목\n===", "밑줄식 제목"),
    ("제목\n---", "밑줄식 제목"),
    ("    들여쓴 코드", "들여쓴 코드 블록"),
    ("2 \\* 3", "역슬래시 이스케이프"),
    ("&copy; 2026", "HTML 엔티티"),
    ("가&nbsp;나", "HTML 엔티티"),
    ("[글](a.md \"제목\")", "링크 제목"),
    ("[글](<a b.md>)", "꺾쇠로 감싼 링크 주소"),
    ("각주[^1]\n\n[^1]: 내용", "각주"),
    ("[글][ref]\n\n[ref]: https://a.com", "참조 링크"),
    ("줄 끝 두 칸  \n다음", "줄 안 줄바꿈"),
    ("- 항목\n  이어지는 줄", "여러 줄 목록 항목"),
    ("> ```\n> 인용 안 코드\n> ```", "코드 블록"),
]

@Test("FR-52: 하나라도 있으면 TipTap으로 연다 (R-10)", arguments: web.indices)
func classify_web(_ i: Int) {
    let (md, reason) = web[i]
    #expect(nativeBlockers(md).contains(reason), "\(md.debugDescription) → \(nativeBlockers(md))")
    #expect(stickyEditorKind(md) == .web)
}

@Test func classify_mixed_note_is_web() {
    // 네이티브 서식 사이에 표 하나만 있어도 TipTap
    #expect(stickyEditorKind("# 할 일\n- [ ] 가\n\n| a | b |\n|---|---|\n\n끝") == .web)
}
