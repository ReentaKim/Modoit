// src/qa/logic.test.ts, src/lib/lib.test.ts, src/qa/v03Logic.test.ts 의 frontmatter 케이스를 옮겼다.
import Foundation
import Testing
@testable import ModoitCore

/// [원문, frontmatter로 볼 때의 본문(아니면 nil)] — v0.x Rust `split_frontmatter`의 실제 결과다
private let agree: [(String, String?)] = [
    ("---\na: 1\n---\nbody", "body"),
    ("---\na: 1\n--- \nbody", "body"),
    ("\u{feff}---\na: 1\n---\nbody", "body"),
    ("---\r\na: 1\r\n---\r\nbody", "body"),
    ("---\n---\nbody", "body"),
    ("---\n제목\n---\n본문", nil),
    ("---\n- a\n- b\n---\n", nil),
    ("---\nkey: [unclosed\n---\nbody", "body"),
    ("---\n# 주석만\n---\nbody", "body"),
    ("---\nfoo:bar\n---\n", nil),
    ("---\n@at: 1\n---\n", nil),
    ("---\nfoo: bar", nil),
    ("---", nil),
    ("\n---\na: 1\n---\n", nil),
    ("---\na: |\n  multi\n  ---\n---\nbody", "body"),
    // v0.3에서 TS와 Rust가 달랐던 것 (BUG-32). Rust 쪽이 기준이다
    ("--- \na: 1\n---\nbody", "body"),
    ("---  \t\na: 1\n---\n", ""),
    ("---\na: 1\n...\nbody", "body"),
    ("---\n\t탭: 1\n---\n", ""),
    ("---\nnull\n---\n본문", "본문"),
    ("---\n~\n---\n본문", "본문"),
]

@Test("frontmatter 판정이 v0.x와 같다 (NFR-09, BUG-18, BUG-32)", arguments: agree.indices)
func frontmatter_split_matches_v0x(_ i: Int) {
    let (src, body) = agree[i]
    let t = splitNote(src)
    #expect((t.front != nil) == (body != nil), "\(src.debugDescription)")
    if let body { #expect(t.body == body, "\(src.debugDescription)") }
}

@Test func frontmatter_split_and_join() {
    let src = "---\ntags: [a, b] # 내 주석\ntitle: 원래\n---\n본문\n"
    let hr = "---\n그냥 글\n---\n본문"
    #expect(splitNote(hr) == NoteParts(front: nil, body: hr))
    #expect(splitNote("---\n---\n본문").front == "")
    #expect(splitNote("---\nkey: [깨진\n---\n본문").body == "본문")
    // 나누고 합치면 원본 그대로
    #expect(joinNote(splitNote(src)) == src)
    #expect(splitNote("본문만") == NoteParts(front: nil, body: "본문만"))
    // frontmatter가 없으면 BOM도 그대로 둔다
    #expect(joinNote(splitNote("\u{feff}본문")).unicodeScalars.first == "\u{feff}")
}

@Test("NFR-09: sticky를 쓰면 사용자 키·주석은 보존") func frontmatter_sticky_keeps_user_keys() throws {
    let src = "tags: [a, b] # 내 주석\ntitle: 원래\n"
    var s = StickyMeta.firstOpen
    s.x = 10.4
    s.y = 20
    let front = try #require(writeMeta(front: src, MetaPatch(sticky: s)))
    // BUG-34: 사용자가 쓴 줄은 한 글자도 바뀌지 않는다
    #expect(front == src + "sticky: { color: yellow, x: 10, y: 20, w: 280, h: 280, onTop: false, open: true }\n")
    #expect(readMeta(front: front).sticky == StickyMeta(x: 10, y: 20, open: true))
}

@Test func frontmatter_pinned_on_off() throws {
    let on = try #require(writeMeta(front: nil, MetaPatch(pinned: true)))
    #expect(on == "pinned: true\n")
    #expect(readMeta(front: on).pinned)
    // 비면 frontmatter 제거
    #expect(writeMeta(front: on, MetaPatch(pinned: false)) == nil)
}

@Test("NFR-08: v0.1 스티키 형식을 읽고, 새 형식으로 바꾼다") func frontmatter_legacy_sticky() throws {
    let legacy = "color: pink\nx: 100\ny: 50\nw: 240\nh: 220\nonTop: false\nopen: false\n"
    let m = readMeta(front: legacy)
    #expect(m.legacy)
    #expect(m.sticky?.color == "pink")
    #expect(m.sticky?.open == false)
    var s = try #require(m.sticky)
    s.open = true
    let next = try #require(writeMeta(front: legacy, MetaPatch(sticky: s)))
    #expect(next == "sticky: { color: pink, x: 100, y: 50, w: 240, h: 220, onTop: false, open: true }\n")
    #expect(readMeta(front: next) == NoteMetaFields(pinned: false, sticky: s, legacy: false))
    // open 키가 없는 v0.1 파일은 떠 있던 스티키다
    #expect(readMeta(front: "color: blue\nw: 200\n").sticky?.open == true)
}

@Test func frontmatter_broken_yaml_untouched() {
    #expect(writeMeta(front: "a: [1, 2\n", MetaPatch(pinned: true)) == "a: [1, 2\n")
}

private let userFronts = [
    "title: \"회의록\"\ntags:\n  - a\n  - b\n",
    "# 주석\ndate: 2026-11-07\naliases:\n  - 별칭\n",
    "desc: |\n  여러 줄\n  설명\n",
    "'quoted key': 'v'\nempty:\n",
    // BUG-34: v0.3은 YAML 전체를 다시 써서 아래 서식이 바뀌었다. v2는 그대로 둔다 (D-13)
    "tags: [a, b]\n",
    "num: 0x1F\n",
    "a:   1   # 정렬한 주석\nb: 'x'\n\n# 끝 주석\n",
    "title: 윈도\r\ntags: [a]\r\n",
]

@Test("NFR-09·BUG-34: pinned를 켰다 끄면 원래 YAML 그대로", arguments: userFronts)
func frontmatter_toggle_pinned_roundtrip(_ front: String) throws {
    let on = try #require(writeMeta(front: front, MetaPatch(pinned: true)))
    #expect(readMeta(front: on).pinned)
    #expect(on.hasPrefix(front) || on.contains("pinned: true"))
    #expect(writeMeta(front: on, MetaPatch(pinned: false)) == front)
}

@Test("NFR-09·BUG-34: 스티키를 꺼냈다 지워도 원래 YAML 그대로", arguments: userFronts)
func frontmatter_toggle_sticky_roundtrip(_ front: String) throws {
    let on = try #require(writeMeta(front: front, MetaPatch(sticky: StickyMeta(color: "blue", x: 1, y: 2, open: true))))
    #expect(readMeta(front: on).sticky?.color == "blue")
    // 위치를 바꿔도 다른 줄은 그대로
    let moved = try #require(writeMeta(front: on, MetaPatch(sticky: StickyMeta(color: "blue", x: 300, y: 2, open: true))))
    #expect(readMeta(front: moved).sticky?.x == 300)
    #expect(writeMeta(front: moved, MetaPatch(sticky: .some(nil))) == front)
}

@Test func frontmatter_replaces_existing_sticky_in_place() throws {
    // 블록으로 쓴 sticky도 그 자리에서 한 줄로 바꾸고, 앞뒤 키는 그대로
    let front = "title: a\nsticky:\n  color: green\n  x: 10.5\npinned: true\ntags: [x]\n"
    let next = try #require(writeMeta(front: front, MetaPatch(sticky: StickyMeta(color: "pink", open: true))))
    #expect(next == "title: a\nsticky: { color: pink, x: null, y: null, w: 280, h: 280, onTop: false, open: true }\npinned: true\ntags: [x]\n")
    // pinned만 끄기
    #expect(writeMeta(front: next, MetaPatch(pinned: false))
        == "title: a\nsticky: { color: pink, x: null, y: null, w: 280, h: 280, onTop: false, open: true }\ntags: [x]\n")
}

@Test("BUG-37: sticky 기본값") func frontmatter_sticky_defaults() {
    #expect(stickyDefaultSize == 280)
    let m = readMeta(front: "sticky: {color: blue}\n").sticky
    #expect(m == StickyMeta(color: "blue", w: 280, h: 280, open: false))
}

@Test func frontmatter_odd_shapes_still_save_correct_values() throws {
    // 줄 단위로 고치기 어려운 모양(따옴표 키, 여러 줄 흐름 값)이어도 값은 맞게 저장된다
    for front in ["\"sticky\": {color: pink}\nkeep: 1\n", "sticky: {color: pink,\n  x: 1}\nkeep: 1\n"] {
        let next = try #require(writeMeta(front: front, MetaPatch(sticky: StickyMeta(color: "green", x: 5, y: 6, open: true))))
        let m = readMeta(front: next)
        #expect(m.sticky == StickyMeta(color: "green", x: 5, y: 6, open: true), "\(front.debugDescription) → \(next.debugDescription)")
        #expect(next.contains("keep: 1"))
    }
}
