// src-tauri/src/vault.rs 테스트를 명세로 옮겼다 (ADR-11). 테스트 이름은 Rust와 같다.
import Foundation
import Testing
@testable import ModoitCore

private func tempVault() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appending(path: "modoit-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func write(_ v: URL, _ rel: String, _ text: String) throws {
    try atomicWrite(text, to: v.appending(path: rel))
}

@Test func rejects_escaping_paths() throws {
    let v = try tempVault()
    #expect(throws: VaultError.self) { try resolve(vault: v, "../x.md") }
    #expect(throws: VaultError.self) { try resolve(vault: v, "a/../../x.md") }
    #expect(throws: VaultError.self) { try resolve(vault: v, "/etc/passwd") }
    #expect(throws: VaultError.self) { try resolve(vault: v, "") }
    #expect((try? resolve(vault: v, "메모/새 메모.md")) != nil)
}

@Test func rejects_symlink_escape() throws {
    let v = try tempVault()
    let outside = try tempVault()
    try FileManager.default.createSymbolicLink(at: v.appending(path: "link"), withDestinationURL: outside)
    #expect(throws: VaultError.self) { try resolve(vault: v, "link/x.md") }
}

@Test func atomic_write_replaces_and_leaves_no_tmp() throws {
    let v = try tempVault()
    let p = v.appending(path: "a/b.md")
    try atomicWrite("one", to: p)
    try atomicWrite("two", to: p)
    #expect(try String(contentsOf: p, encoding: .utf8) == "two")
    #expect(try FileManager.default.contentsOfDirectory(atPath: v.appending(path: "a").path).count == 1)
}

@Test func atomic_write_keeps_creation_time() throws {
    let v = try tempVault()
    let p = v.appending(path: "c.md")
    try atomicWrite("one", to: p)
    let born = try FileManager.default.attributesOfItem(atPath: p.path)[.creationDate] as! Date
    Thread.sleep(forTimeInterval: 1.1)
    try atomicWrite("two", to: p)
    let a = try FileManager.default.attributesOfItem(atPath: p.path)
    #expect(a[.creationDate] as! Date == born)
    #expect(a[.modificationDate] as! Date > born)
}

@Test func title_basic_markdown() {
    let (t, p) = titleAndPreview("# 장보기\n\n- [ ] 우유\n- 빵")
    #expect(t == "장보기")
    #expect(p == "우유")
    #expect(extractTitle("> 인용 *기울임* 제목") == "인용 기울임 제목")
    #expect(extractTitle("1. 첫째") == "첫째")
    #expect(extractTitle("+ 더하기") == "더하기")
    #expect(extractTitle("#해시태그") == "#해시태그")
}

@Test func title_emphasis_and_links() {
    #expect(extractTitle("**굵게** __밑줄__ ~~취소~~ `코드` 끝") == "굵게 밑줄 취소 코드 끝")
    #expect(extractTitle("_기울임_ snake_case") == "기울임 snake_case")
    #expect(extractTitle("[링크 글](https://a.com/x_(y)) 뒤") == "링크 글 뒤")
    #expect(extractTitle("앞 ![그림](a.png) 뒤") == "앞  뒤")
    #expect(extractTitle("\\*별\\* \\[ \\]") == "*별* [ ]")
    #expect(extractTitle("10~20") == "10~20")
}

@Test func title_bom_and_frontmatter() {
    #expect(extractTitle("\u{feff}BOM 제목") == "BOM 제목")
    #expect(extractTitle("\u{feff}---\npinned: true\n---\n본문 제목") == "본문 제목")
    #expect(extractTitle("---\ncolor: yellow\n---\n오늘 할 일") == "오늘 할 일")
    #expect(extractTitle("---\r\ntags: [a, b]\r\n---\r\n# 윈도 줄바꿈\r\n") == "윈도 줄바꿈")
    #expect(extractTitle("---\ntags: [a, b\n---\n본문") == "본문")
    #expect(extractTitle("---\n---\n빈 머리") == "빈 머리")
}

@Test func title_starting_with_thematic_break() {
    #expect(extractTitle("---\n첫 글\n---\n둘째 글") == "첫 글")
    #expect(extractTitle("---\n\n본문") == "본문")
    #expect(extractTitle("***\n* * *\n별 구분선 뒤") == "별 구분선 뒤")
}

@Test func title_skips_fences_and_images() {
    #expect(extractTitle("```\n코드\n```\n뒤") == "코드")
    #expect(extractTitle("![](a.png)\n![x](b.png) ![y](c.png)\n사진 설명") == "사진 설명")
    #expect(extractTitle("") == "")
    #expect(extractTitle("   \n\n") == "")
}

@Test func file_name_rules() {
    #expect(fileBase("회의: 1/2분기") == "회의 1 2분기")
    #expect(fileBase("a\u{0}b\u{1f}c\u{7f}d\u{85}e\u{9f}f\u{feff}g") == "a b c d e f g")
    #expect(fileBase("탭\t과\n줄") == "탭 과 줄")
    #expect(fileBase("  ..숨김 이름..  ") == "숨김 이름")
    #expect(fileBase("...") == untitled)
    #expect(fileBase("") == untitled)
    #expect(fileBase("R&D <회의> | \"끝\"?") == "R&D 회의 끝")
}

@Test func file_name_truncates_then_trims() {
    let b = fileBase(String(repeating: "가", count: 58) + "가 나")
    #expect(b.count == 59)
    #expect(!b.hasSuffix(" "))
    #expect(fileBase(String(repeating: "a", count: 58) + "...끝") == String(repeating: "a", count: 58))
    #expect(fileBase(String(repeating: "한", count: 80)).count == 60)
}

@Test func tree_parses_pinned_and_sticky() throws {
    let v = try tempVault()
    try write(v, "a.md", "---\npinned: true\nsticky: {color: pink, x: 1250, y: 140, w: 300, h: 200, onTop: true, open: true}\ntags: [x]\n---\n장보기")
    try write(v, "b.md", "---\nsticky:\n  color: green\n  x: 10.5\n---\n블록 형식")
    try write(v, "old.md", "---\ncolor: yellow\nx: 1\ny: 2\n---\nv0.1 형식")
    try write(v, "bad.md", "---\nsticky: {color: [\n---\n깨진 yaml")
    try write(v, "weird.md", "---\npinned: 'yes'\nsticky: {color: orange, w: -1}\n---\n이상한 값")
    let notes = Vault(root: v).notes()
    func get(_ p: String) -> NoteMeta { notes.first { $0.path == p }! }
    #expect(get("a.md").title == "장보기")
    #expect(get("a.md").sticky == StickyMeta(color: "pink", x: 1250, y: 140, w: 300, h: 200, onTop: true, open: true))
    let s = get("b.md").sticky!
    #expect(s.color == "green" && s.x == 10.5 && s.y == nil && s.w == 280 && !s.onTop && !s.open)
    #expect(get("old.md").sticky == nil)
    #expect(get("old.md").title == "v0.1 형식")
    #expect(get("bad.md").sticky == nil)
    #expect(get("weird.md").sticky?.color == "yellow")
    #expect(get("weird.md").sticky?.w == 280)
}

@Test func save_attachment_checks_and_link() throws {
    let v = try tempVault()
    try write(v, "업무/회의/a.md", "a")
    try write(v, "top.md", "t")
    let vault = Vault(root: v)
    let data = Data([137, 80, 78, 71, 1, 2, 3]).base64EncodedString()
    let link = try vault.saveAttachment(notePath: "업무/회의/a.md", fileName: "스크린샷.PNG", dataBase64: data)
    #expect(link.hasPrefix("../../attachments/"))
    #expect(link.hasSuffix(".png"))
    let name = String(link.split(separator: "/").last!)
    let parts = name.replacingOccurrences(of: ".png", with: "").split(separator: "-")
    #expect(parts.map(\.count) == [8, 6, 4])
    #expect(try Data(contentsOf: v.appending(path: "attachments/\(name)")) == Data([137, 80, 78, 71, 1, 2, 3]))
    let top = try vault.saveAttachment(notePath: "top.md", fileName: "a.jpeg", dataBase64: "data:image/jpeg;base64,\(data)")
    #expect(top.hasPrefix("attachments/") && top.hasSuffix(".jpeg"))
    for bad in ["a.svg", "a.exe", "noext"] {
        #expect(throws: VaultError.self) { try vault.saveAttachment(notePath: "top.md", fileName: bad, dataBase64: data) }
    }
    for ext in attachmentExts {
        #expect((try? vault.saveAttachment(notePath: "top.md", fileName: "x.\(ext)", dataBase64: data)) != nil)
    }
    let big = Data(count: attachmentMaxBytes + 1).base64EncodedString()
    #expect(throws: VaultError("이미지가 20MB를 넘습니다")) { try vault.saveAttachment(notePath: "top.md", fileName: "big.png", dataBase64: big) }
    let ok = Data(count: attachmentMaxBytes).base64EncodedString()
    #expect((try? vault.saveAttachment(notePath: "top.md", fileName: "max.png", dataBase64: ok)) != nil)
    #expect(throws: VaultError.self) { try vault.saveAttachment(notePath: "top.md", fileName: "a.png", dataBase64: "@@@") }
    #expect(throws: VaultError.self) { try vault.saveAttachment(notePath: "../x.md", fileName: "a.png", dataBase64: data) }
    #expect(!vault.folders().contains(attachmentsDir))
}

// ── 스파이크 추가: frontmatter 보존 ──

@Test func write_body_keeps_frontmatter() throws {
    let v = try tempVault()
    try write(v, "n.md", "---\n# 사용자 주석\ntags: [a]\nsticky: {color: blue, x: 1, y: 2, w: 300, h: 300, onTop: false, open: true}\n---\n옛 본문\n")
    let vault = Vault(root: v)
    try vault.writeBody("n.md", body: "새 본문\n")
    #expect(try vault.read("n.md") == "---\n# 사용자 주석\ntags: [a]\nsticky: {color: blue, x: 1, y: 2, w: 300, h: 300, onTop: false, open: true}\n---\n새 본문\n")
    try vault.updateSticky("n.md", StickyMeta(color: "pink", x: 10, y: 20, w: 280, h: 280, onTop: true, open: false))
    #expect(try vault.read("n.md") == "---\n# 사용자 주석\ntags: [a]\nsticky: {color: pink, x: 10, y: 20, w: 280, h: 280, onTop: true, open: false}\n---\n새 본문\n")
    try vault.updateSticky("n.md", nil)
    #expect(try vault.read("n.md") == "---\n# 사용자 주석\ntags: [a]\n---\n새 본문\n")
}

@Test func write_body_adds_nothing_without_frontmatter() throws {
    let v = try tempVault()
    try write(v, "p.md", "---\n첫 글\n---\n둘째")
    let vault = Vault(root: v)
    try vault.writeBody("p.md", body: "바뀜")
    #expect(try vault.read("p.md") == "바뀜")
    try vault.updateSticky("p.md", StickyMeta(open: true))
    #expect(try vault.read("p.md") == "---\nsticky: {color: yellow, x: null, y: null, w: 280, h: 280, onTop: false, open: true}\n---\n바뀜")
}
