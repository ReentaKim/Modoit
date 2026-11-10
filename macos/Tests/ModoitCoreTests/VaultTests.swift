// src-tauri/src/vault.rs 테스트를 명세로 옮겼다 (V2-02). 테스트 이름은 Rust와 같다.
import Foundation
import Testing
@testable import ModoitCore

// MARK: - 경로

@Test func rejects_escaping_paths() throws {
    let v = try tempVault()
    #expect(throws: VaultError.self) { try resolve(vault: v, "../x.md") }
    #expect(throws: VaultError.self) { try resolve(vault: v, "a/../../x.md") }
    #expect(throws: VaultError.self) { try resolve(vault: v, "/etc/passwd") }
    #expect(throws: VaultError.self) { try resolve(vault: v, "") }
    #expect(throws: Never.self) { try resolve(vault: v, "메모/새 메모.md") }
}

@Test func rejects_symlink_escape() throws {
    let v = try tempVault()
    let outside = try tempVault()
    try FileManager.default.createSymbolicLink(atPath: join(v, "link"), withDestinationPath: outside)
    #expect(throws: VaultError.self) { try resolve(vault: v, "link/x.md") }
}

@Test func atomic_write_replaces_and_leaves_no_tmp() throws {
    let v = try tempVault()
    let p = join(v, "a/b.md")
    try atomicWrite("one", to: p)
    try atomicWrite("two", to: p)
    #expect(try String(contentsOfFile: p, encoding: .utf8) == "two")
    #expect(try FileManager.default.contentsOfDirectory(atPath: join(v, "a")).count == 1)
}

@Test func atomic_write_keeps_creation_time() throws {
    let v = try tempVault()
    let p = join(v, "c.md")
    try atomicWrite("one", to: p)
    let born = try FileManager.default.attributesOfItem(atPath: p)[.creationDate] as! Date
    Thread.sleep(forTimeInterval: 1.1)
    try atomicWrite("two", to: p)
    let a = try FileManager.default.attributesOfItem(atPath: p)
    #expect(a[.creationDate] as! Date == born)
    #expect(a[.modificationDate] as! Date > born)
}

// MARK: - 제목 추출

@Test func title_basic_markdown() {
    let (t, p) = titleAndPreview("# 장보기\n\n- [ ] 우유\n- 빵")
    #expect(t == "장보기")
    #expect(p == "우유")
    #expect(extractTitle("> 인용 *기울임* 제목") == "인용 기울임 제목")
    #expect(extractTitle("1. 첫째") == "첫째")
    #expect(extractTitle("+ 더하기") == "더하기")
    #expect(extractTitle("#해시태그") == "#해시태그")
}

@Test func title_entities() {
    #expect(extractTitle("R&amp;D 회의") == "R&D 회의")
    #expect(extractTitle("a &lt; b &gt; c &quot;x&quot; &#39;y&#39;") == "a < b > c \"x\" 'y'")
    #expect(extractTitle("&#44032;&#x B; &#xAC00;") == "가&#x B; 가")
    #expect(extractTitle("앞&nbsp;뒤\u{3000}끝&nbsp;") == "앞 뒤 끝")
    #expect(extractTitle("&nbsp;\n두 번째") == "두 번째")
    #expect(extractTitle("AT&T") == "AT&T")
}

@Test func title_emphasis_and_links() {
    #expect(extractTitle("**굵게** __밑줄__ ~~취소~~ `코드` 끝") == "굵게 밑줄 취소 코드 끝")
    #expect(extractTitle("*기울임* 제목") == "기울임 제목")
    #expect(extractTitle("_기울임_ snake_case") == "기울임 snake_case")
    #expect(extractTitle("[링크 글](https://a.com/x_(y)) 뒤") == "링크 글 뒤")
    #expect(extractTitle("앞 ![그림](a.png) 뒤") == "앞  뒤")
    #expect(extractTitle("\\*별\\* \\[ \\]") == "*별* [ ]")
    #expect(extractTitle("10~20") == "10~20")
}

@Test func title_checkboxes() {
    #expect(extractTitle("* [X] 완료") == "완료")
    #expect(extractTitle("- [x] 끝냄") == "끝냄")
    #expect(extractTitle("- [ ] 할 일") == "할 일")
    #expect(extractTitle("[X] 맨 체크") == "맨 체크")
    #expect(extractTitle("- [ ]\n둘째") == "둘째")
}

@Test func title_bom_and_frontmatter() {
    #expect(extractTitle("\u{feff}BOM 제목") == "BOM 제목")
    #expect(extractTitle("\u{feff}---\npinned: true\n---\n본문 제목") == "본문 제목")
    #expect(extractTitle("---\ncolor: yellow\n---\n오늘 할 일") == "오늘 할 일")
    #expect(extractTitle("---\r\ntags: [a, b]\r\n---\r\n# 윈도 줄바꿈\r\n") == "윈도 줄바꿈")
    // 깨진 YAML이어도 키 꼴이면 frontmatter
    #expect(extractTitle("---\ntags: [a, b\n---\n본문") == "본문")
    // 빈 frontmatter
    #expect(extractTitle("---\n---\n빈 머리") == "빈 머리")
}

@Test func title_starting_with_thematic_break() {
    // 구분선으로 시작하는 메모는 frontmatter가 아니다 (BUG-18)
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

// MARK: - 파일 이름 규칙

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
    let long = String(repeating: "가", count: 58) + "가 나"
    // 60자에서 자르면 "가…가 "로 끝나므로 끝 공백을 지운다
    let b = fileBase(long)
    #expect(b.unicodeScalars.count == 59)
    #expect(!b.hasSuffix(" "))
    let dots = String(repeating: "a", count: 58) + "...끝"
    #expect(fileBase(dots) == String(repeating: "a", count: 58))
    #expect(fileBase(String(repeating: "한", count: 80)).unicodeScalars.count == 60)
}

@Test func folder_name_rejects_dots_and_empty() throws {
    for bad in ["", "   ", ".", "..", " ... ", "///"] {
        #expect(throws: VaultError.self) { try folderName(bad) }
    }
    #expect(try folderName(".숨김") == "숨김")
    #expect(try folderName("Stickies") == "Stickies")
}

// MARK: - 목록

@Test func tree_nested_and_excludes_attachments_and_hidden() throws {
    let v = try tempVault()
    try write(v, "업무/회의/주간.md", "# 주간 회의\n안건")
    try write(v, "업무/a.md", "가")
    try write(v, "업무-2024/b.md", "나")
    try write(v, "Stickies/s.md", "스티키")
    try write(v, "top.md", "최상위")
    try write(v, "attachments/x.md", "첨부 안 md")
    try write(v, ".modoit/layout.json", #"{"sort":"name","order":{"":["업무"]}}"#)
    try write(v, ".hidden/x.md", "숨김")
    try write(v, "업무/attachments/ok.md", "하위의 attachments는 보통 폴더")
    let t = try listTree(vault: v)
    #expect(t.folders.map(\.name) == ["Stickies", "업무", "업무-2024"])
    let work = t.folders[1]
    #expect(work.path == "업무")
    #expect(work.children.map(\.path) == ["업무/attachments", "업무/회의"])
    #expect(t.notes.map(\.path).sorted(by: scalarOrder)
        == ["Stickies/s.md", "top.md", "업무-2024/b.md", "업무/a.md", "업무/attachments/ok.md", "업무/회의/주간.md"])
    let n = try #require(t.notes.first { $0.path == "업무/회의/주간.md" })
    #expect(n.folder == "업무/회의")
    #expect(n.title == "주간 회의")
    #expect(n.preview == "안건")
    #expect(n.readable)
    #expect(t.notes.first { $0.path == "top.md" }?.folder == "")
    #expect(t.layout.sort == .name)
    // 폴더 modified = 하위 메모의 최대 modified
    let maxNote = t.notes.filter { $0.path.hasPrefix("업무/") }.map(\.modified).max()
    #expect(work.modified == maxNote)
    // 메모는 최신순
    #expect(zip(t.notes, t.notes.dropFirst()).allSatisfy { $0.modified >= $1.modified })
}

@Test func tree_skips_unreadable_folder() throws {
    let v = try tempVault()
    try write(v, "열림/a.md", "가")
    try write(v, "잠김/b.md", "나")
    let locked = join(v, "잠김")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    // root로 돌리면 권한이 무시된다
    let readableAnyway = (try? FileManager.default.contentsOfDirectory(atPath: locked)) != nil
    let result = Result { try listTree(vault: v) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
    let t = try result.get()
    #expect(t.notes.contains { $0.path == "열림/a.md" })
    if !readableAnyway {
        #expect(t.folders.allSatisfy { $0.name != "잠김" })
        #expect(t.notes.count == 1)
    }
}

@Test func tree_non_utf8_is_listed_unreadable() throws {
    let v = try tempVault()
    // CP949 "가나" + 줄바꿈
    try mkdir(v, "메모")
    try atomicWrite(Data([0xb0, 0xa1, 0xb3, 0xaa, 0x0a, 0x78]), to: join(v, "메모/옛메모.md"))
    let t = try listTree(vault: v)
    let n = t.notes[0]
    #expect(!n.readable)
    #expect(n.title.unicodeScalars.contains("\u{fffd}"))
    #expect(throws: VaultError.notUTF8) { try readNote(vault: v, "메모/옛메모.md") }
    #expect(throws: VaultError.notUTF8) { try syncNoteName(vault: v, "메모/옛메모.md") }
}

@Test func tree_parses_pinned_and_sticky() throws {
    let v = try tempVault()
    try write(v, "a.md", "---\npinned: true\nsticky: {color: pink, x: 1250, y: 140, w: 300, h: 200, onTop: true, open: true}\ntags: [x]\n---\n장보기")
    try write(v, "b.md", "---\nsticky:\n  color: green\n  x: 10.5\n---\n블록 형식")
    try write(v, "old.md", "---\ncolor: yellow\nx: 1\ny: 2\n---\nv0.1 형식")
    try write(v, "bad.md", "---\nsticky: {color: [\n---\n깨진 yaml")
    try write(v, "weird.md", "---\npinned: 'yes'\nsticky: {color: orange, w: -1}\n---\n이상한 값")
    let t = try listTree(vault: v)
    func get(_ p: String) throws -> NoteMeta { try #require(t.notes.first { $0.path == p }) }
    let a = try get("a.md")
    #expect(a.pinned)
    #expect(a.title == "장보기")
    #expect(a.sticky == StickyMeta(color: "pink", x: 1250, y: 140, w: 300, h: 200, onTop: true, open: true))
    let b = try get("b.md")
    #expect(!b.pinned)
    #expect(b.sticky == StickyMeta(color: "green", x: 10.5, y: nil, w: 280, h: 280, onTop: false, open: false))
    let old = try get("old.md")
    #expect(old.sticky == nil)
    #expect(old.title == "v0.1 형식")
    let bad = try get("bad.md")
    #expect(!bad.pinned && bad.sticky == nil)
    let weird = try get("weird.md")
    #expect(!weird.pinned)
    #expect(weird.sticky?.color == "yellow")
}

// MARK: - 메모

@Test func create_note_makes_default_folder() throws {
    let v = try tempVault()
    #expect(try createNote(vault: v, folder: "") == "메모/새 메모.md")
    #expect(try createNote(vault: v, folder: "") == "메모/새 메모 2.md")
    try mkdir(v, "업무")
    #expect(try createNote(vault: v, folder: "업무") == "업무/새 메모.md")
    #expect(throws: VaultError.self) { try createNote(vault: v, folder: "없는폴더") }
}

@Test func sync_note_name_follows_title() throws {
    let v = try tempVault()
    let a = try createNote(vault: v, folder: "")
    let b = try createNote(vault: v, folder: "")
    try write(v, a, "회의: 1/2분기\n본문")
    try write(v, b, "# 회의: 1/2분기")
    let a2 = try syncNoteName(vault: v, a)
    #expect(a2 == "메모/회의 1 2분기.md")
    let b2 = try syncNoteName(vault: v, b)
    #expect(b2 == "메모/회의 1 2분기 2.md")
    // 같은 제목이면 그대로
    #expect(try syncNoteName(vault: v, a2) == a2)
    #expect(try syncNoteName(vault: v, b2) == b2)
    // 엔티티는 풀어서 쓴다 (BUG-03)
    try write(v, a2, "R&amp;D 회의")
    #expect(try syncNoteName(vault: v, a2) == "메모/R&D 회의.md")
}

@Test func sync_note_name_case_only_change() throws {
    let v = try tempVault()
    try write(v, "메모/Abc.md", "abc")
    #expect(try syncNoteName(vault: v, "메모/Abc.md") == "메모/abc.md")
    #expect(try namesIn(join(v, "메모")) == ["abc.md"])
    #expect(try read(v, "메모/abc.md") == "abc")
    // 다시 대문자로
    try write(v, "메모/abc.md", "ABC")
    #expect(try syncNoteName(vault: v, "메모/abc.md") == "메모/ABC.md")
    #expect(try namesIn(join(v, "메모")) == ["ABC.md"])
}

@Test func sync_note_name_nfd_hangul() throws {
    // Finder가 만든 NFD 이름도 " 2"를 거치지 않는다
    let v = try tempVault()
    let nfd = "\u{1112}\u{1161}\u{11AB}" // "한" 자모 분해
    try write(v, "\(nfd).md", "한")
    let to = try syncNoteName(vault: v, "\(nfd).md")
    #expect(to.sameBytes("한.md") || to.sameBytes("\(nfd).md"))
    #expect(try namesIn(v).count == 1)
}

// MARK: - 폴더

@Test func create_folder_rules() throws {
    let v = try tempVault()
    #expect(try createFolder(vault: v, parent: "", name: "업무") == "업무")
    #expect(try createFolder(vault: v, parent: "", name: "업무") == "업무 2")
    #expect(try createFolder(vault: v, parent: "업무", name: "회의") == "업무/회의")
    #expect(try createFolder(vault: v, parent: "", name: "Stickies") == "Stickies")
    #expect(throws: VaultError.self) { try createFolder(vault: v, parent: "", name: "..") }
    #expect(throws: VaultError.self) { try createFolder(vault: v, parent: "", name: ".") }
    #expect(throws: VaultError.self) { try createFolder(vault: v, parent: "", name: "") }
    #expect(throws: VaultError.self) { try createFolder(vault: v, parent: "../밖", name: "x") }
    // 최상위 attachments는 예약 이름
    #expect(try createFolder(vault: v, parent: "", name: "attachments") == "attachments 2")
    #expect(try createFolder(vault: v, parent: "업무", name: "attachments") == "업무/attachments")
}

@Test func rename_folder_updates_layout_and_case() throws {
    let v = try tempVault()
    _ = try createFolder(vault: v, parent: "", name: "업무")
    _ = try createFolder(vault: v, parent: "업무", name: "회의")
    _ = try createFolder(vault: v, parent: "", name: "개인")
    try saveLayout(vault: v, Layout(order: ["": ["개인", "sep:a", "업무"], "업무": ["회의"]]))

    #expect(try renameFolder(vault: v, "업무", to: "일") == "일")
    #expect(isDir(join(v, "일/회의")))
    let l = loadLayout(vault: v)
    #expect(l.order[""] == ["개인", "sep:a", "일"])
    #expect(l.order["일"] == ["회의"])
    // 이미 있는 이름이면 번호
    #expect(try renameFolder(vault: v, "개인", to: "일") == "일 2")
    // 대소문자만 다른 이름
    _ = try createFolder(vault: v, parent: "", name: "Work")
    #expect(try renameFolder(vault: v, "Work", to: "work") == "work")
    #expect(try namesIn(v).contains("work"))
    #expect(throws: VaultError.self) { try renameFolder(vault: v, "work", to: "..") }
}

@Test func trash_folder_cleans_layout() throws {
    let v = try tempVault()
    _ = try createFolder(vault: v, parent: "", name: "업무")
    _ = try createFolder(vault: v, parent: "업무", name: "회의")
    try saveLayout(vault: v, Layout(order: ["": ["업무"], "업무": ["회의"], "업무/회의": []]))
    // 실제 휴지통 대신 layout 갱신만 확인한다
    try updateLayout(vault: v) { $0.removeDir("업무") }
    let l = loadLayout(vault: v)
    #expect(l.order[""] == [])
    #expect(l.order.count == 1)
}

// MARK: - 옮기기

@Test func move_rejects_into_self_or_descendant() throws {
    let v = try tempVault()
    _ = try createFolder(vault: v, parent: "", name: "a")
    _ = try createFolder(vault: v, parent: "a", name: "b")
    #expect(throws: VaultError.self) { try moveEntry(vault: v, from: "a", toFolder: "a") }
    #expect(throws: VaultError.self) { try moveEntry(vault: v, from: "a", toFolder: "a/b") }
    #expect(throws: VaultError.self) { try moveEntry(vault: v, from: "없음.md", toFolder: "a") }
    #expect(throws: VaultError.self) { try moveEntry(vault: v, from: "a/b", toFolder: "../x") }
    // 이름 접두사만 같은 폴더로는 옮길 수 있다
    _ = try createFolder(vault: v, parent: "", name: "ab")
    #expect(try moveEntry(vault: v, from: "a", toFolder: "ab").to == "ab/a")
}

@Test func move_note_rewrites_links_across_depth() throws {
    let v = try tempVault()
    try write(v, "attachments/p 1.png", "img")
    try write(v, "attachments/q.png", "img")
    try write(v, "메모/a.md",
              "제목\n![](../attachments/p%201.png) 글 ![q](../attachments/q.png \"제목\")\n"
                  + "[웹](https://example.com/a.png) [메일](mailto:x@y.z) [앵커](#h) [절대](/etc/x.png) "
                  + "![데이터](data:image/png;base64,AAA=)\n[밖](../../outside.png) [옆](b.md#sec)\n"
                  + "```\n![](../attachments/q.png)\n```\n")
    try write(v, "메모/b.md", "옆 메모")
    try mkdir(v, "업무/회의")
    let m = try moveEntry(vault: v, from: "메모/a.md", toFolder: "업무/회의")
    #expect(m == Moved(from: "메모/a.md", to: "업무/회의/a.md", isDir: false))
    var c = try read(v, "업무/회의/a.md")
    #expect(c.contains("![](../../attachments/p%201.png) 글"))
    #expect(c.contains("![q](../../attachments/q.png \"제목\")"))
    #expect(c.contains("[웹](https://example.com/a.png)"))
    #expect(c.contains("[메일](mailto:x@y.z)"))
    #expect(c.contains("[앵커](#h)"))
    #expect(c.contains("[절대](/etc/x.png)"))
    #expect(c.contains("(data:image/png;base64,AAA=)"))
    // 저장 폴더 밖으로 풀리는 링크는 그대로
    #expect(c.contains("[밖](../../outside.png)"))
    // 같이 옮겨지지 않은 메모로의 링크는 새 위치 기준
    #expect(c.contains("[옆](../../메모/b.md#sec)"))
    // 코드 블록 안은 건드리지 않는다
    #expect(c.contains("```\n![](../attachments/q.png)\n```"))
    // 최상위로 옮기기
    #expect(try moveEntry(vault: v, from: "업무/회의/a.md", toFolder: "").to == "a.md")
    c = try read(v, "a.md")
    #expect(c.contains("![](attachments/p%201.png)"))
    #expect(c.contains("[옆](메모/b.md#sec)"))
}

@Test func move_note_name_collision_and_angle_links() throws {
    let v = try tempVault()
    try write(v, "x/a.md", "<옛>\n![](<../attachments/공백 있는 그림.png>)")
    try write(v, "y/z/a.md", "이미 있음")
    #expect(try moveEntry(vault: v, from: "x/a.md", toFolder: "y/z").to == "y/z/a 2.md")
    #expect(try read(v, "y/z/a 2.md").contains("![](../../attachments/공백%20있는%20그림.png)"))
    #expect(try read(v, "y/z/a.md") == "이미 있음")
}

@Test func move_folder_keeps_internal_links() throws {
    let v = try tempVault()
    try write(v, "attachments/i.png", "img")
    try write(v, "프로젝트/개요.md", "개요\n[상세](세부/상세.md) ![](../attachments/i.png) [밖](../메모/c.md) [자기](개요.md)")
    try write(v, "프로젝트/세부/상세.md", "상세\n[위로](../개요.md) ![](../../attachments/i.png) ![a](../../attachments/i.png)")
    try write(v, "메모/c.md", "c")
    _ = try createFolder(vault: v, parent: "", name: "보관")
    _ = try createFolder(vault: v, parent: "보관", name: "2026")
    try saveLayout(vault: v, Layout(order: ["": ["프로젝트", "보관"], "프로젝트": ["세부"]]))

    let m = try moveEntry(vault: v, from: "프로젝트", toFolder: "보관/2026")
    #expect(m == Moved(from: "프로젝트", to: "보관/2026/프로젝트", isDir: true))
    let a = try read(v, "보관/2026/프로젝트/개요.md")
    #expect(a.contains("[상세](세부/상세.md)"))
    #expect(a.contains("![](../../../attachments/i.png)"))
    #expect(a.contains("[밖](../../../메모/c.md)"))
    #expect(a.contains("[자기](개요.md)"))
    let b = try read(v, "보관/2026/프로젝트/세부/상세.md")
    #expect(b.contains("[위로](../개요.md)"))
    #expect(occurrences(of: "../../../../attachments/i.png", in: b) == 2)
    let l = loadLayout(vault: v)
    #expect(l.order[""] == ["보관"])
    #expect(l.order["보관/2026/프로젝트"] == ["세부"])
    #expect(l.order["프로젝트"] == nil)
}

@Test func move_to_same_folder_is_noop() throws {
    let v = try tempVault()
    try write(v, "메모/a.md", "a")
    #expect(try moveEntry(vault: v, from: "메모/a.md", toFolder: "메모").to == "메모/a.md")
}

@Test func rewrite_links_unit() {
    // 깊이가 같으면 바뀌지 않는다
    let s = "![](../attachments/a.png)"
    #expect(rewriteLinks(s, oldDir: "x", newDir: "y") == s)
    // 이미지 여러 개, 퍼센트 인코딩
    #expect(rewriteLinks("![](../attachments/a%20b.png)![](../attachments/c.png)", oldDir: "x", newDir: "x/y")
        == "![](../../attachments/a%20b.png)![](../../attachments/c.png)")
    // 괄호가 든 대상
    #expect(rewriteLinks("[a](p(1).png)", oldDir: "x", newDir: "") == "[a](x/p%281%29.png)")
    // 앞 공백과 제목 유지
    #expect(rewriteLinks("[a]( b.png 'c')", oldDir: "x", newDir: "") == "[a]( x/b.png 'c')")
    // 빈 대상, 짝이 안 맞는 것
    #expect(rewriteLinks("[a]() [b](", oldDir: "x", newDir: "") == "[a]() [b](")
    #expect(relativePath(fromDir: "a/b", to: "a/c/d.png") == "../c/d.png")
    #expect(relativePath(fromDir: "", to: "attachments/x.png") == "attachments/x.png")
}

// MARK: - 첨부

@Test func save_attachment_checks_and_link() throws {
    let v = try tempVault()
    try write(v, "업무/회의/a.md", "a")
    try write(v, "top.md", "t")
    let bytes = Data([137, 80, 78, 71, 1, 2, 3])
    let data = bytes.base64EncodedString()
    var link = try saveAttachment(vault: v, notePath: "업무/회의/a.md", fileName: "스크린샷.PNG", dataBase64: data)
    #expect(link.hasPrefix("../../attachments/"))
    #expect(link.hasSuffix(".png"))
    let name = String(link.split(separator: "/").last!)
    // YYYYMMDD-HHMMSS-xxxx.png
    let parts = name.dropLast(4).split(separator: "-")
    #expect(parts.map(\.count) == [8, 6, 4])
    #expect(parts[2].allSatisfy { $0.isHexDigit })
    #expect(FileManager.default.contents(atPath: join(v, "attachments/\(name)")) == bytes)
    // 최상위 메모, data URL
    link = try saveAttachment(vault: v, notePath: "top.md", fileName: "a.jpeg", dataBase64: "data:image/jpeg;base64,\(data)")
    #expect(link.hasPrefix("attachments/") && link.hasSuffix(".jpeg"))
    // 확장자 검사
    for bad in ["a.svg", "a.exe", "noext"] {
        #expect(throws: VaultError.self) { try saveAttachment(vault: v, notePath: "top.md", fileName: bad, dataBase64: data) }
    }
    for ext in attachmentExts {
        #expect(throws: Never.self) { try saveAttachment(vault: v, notePath: "top.md", fileName: "x.\(ext)", dataBase64: data) }
    }
    // 크기 검사
    let big = Data(count: attachmentMaxBytes + 1).base64EncodedString()
    let tooBig = #expect(throws: VaultError.self) { try saveAttachment(vault: v, notePath: "top.md", fileName: "big.png", dataBase64: big) }
    #expect(tooBig?.message.contains("20MB") == true)
    let ok = Data(count: attachmentMaxBytes).base64EncodedString()
    #expect(throws: Never.self) { try saveAttachment(vault: v, notePath: "top.md", fileName: "max.png", dataBase64: ok) }
    // 깨진 base64, 저장 폴더 밖 메모
    #expect(throws: VaultError.self) { try saveAttachment(vault: v, notePath: "top.md", fileName: "a.png", dataBase64: "@@@") }
    #expect(throws: VaultError.self) { try saveAttachment(vault: v, notePath: "../x.md", fileName: "a.png", dataBase64: data) }
    // 첨부 폴더는 목록에서 빠진다
    #expect(try listTree(vault: v).folders.allSatisfy { $0.name != attachmentsDir })
}

// MARK: - v2 추가: 이름의 바이트 보존 (NFR-16)

/// 앱이 만드는 폴더·파일 이름은 받은 글자 그대로(NFC) 디스크에 남아야 한다.
/// Foundation의 만들기 API는 한글을 자모로 풀어(NFD) 만들어서, v0.x가 만든 이름과 바이트가 달라진다.
@Test func created_names_keep_nfc_bytes() throws {
    let v = try tempVault()
    let nfc = "한글 폴더" // 13바이트. NFD면 31바이트
    #expect(nfc.utf8.count == 13)
    #expect(try createFolder(vault: v, parent: "", name: nfc).sameBytes(nfc))
    let note = try createNote(vault: v, folder: nfc)
    try write(v, note, "# 회의록 가나다")
    let renamed = try syncNoteName(vault: v, note)
    #expect(renamed.sameBytes("\(nfc)/회의록 가나다.md"))
    _ = try saveAttachment(vault: v, notePath: renamed, fileName: "a.png", data: Data([1, 2, 3]))
    try updateLayout(vault: v) { $0.order[""] = [nfc] }
    let moved = try moveEntry(vault: v, from: renamed, toFolder: "")
    #expect(moved.to.sameBytes("회의록 가나다.md"))
    // 디스크에 실제로 남은 이름
    #expect(try namesIn(v).map { Array($0.utf8) } == ["attachments", nfc, "회의록 가나다.md"].sorted(by: scalarOrder).map { Array($0.utf8) })
    // 목록이 돌려주는 경로도 같은 바이트
    let t = try listTree(vault: v)
    #expect(t.folders.map(\.name).contains { $0.sameBytes(nfc) })
    #expect(t.notes.map(\.path).contains { $0.sameBytes("회의록 가나다.md") })
}
