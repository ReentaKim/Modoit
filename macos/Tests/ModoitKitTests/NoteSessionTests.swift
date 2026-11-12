// src/qa/v03Session.test.ts 의 세션 케이스를 옮기고, v2의 "메모 하나에 세션 하나"(V2-09)를 더했다.
import Foundation
import Testing
import ModoitCore
@testable import ModoitKit

@MainActor
private struct Fixture {
    let vault: String
    let store: SessionStore

    init() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        vault = base + "/modoit-kit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: vault + "/메모", withIntermediateDirectories: true)
        // 테스트에서는 타이머를 기다리지 않고 flush()를 직접 부른다
        store = SessionStore(vault: vault, delays: .init(save: 60, retry: 60))
    }

    func write(_ rel: String, _ text: String) throws { try atomicWrite(text, to: vault + "/" + rel) }
    func read(_ rel: String) throws -> String { try String(contentsOfFile: vault + "/" + rel, encoding: .utf8) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: vault + "/" + rel) }
}

@MainActor @Test("FR-30: 메인 창과 스티키가 같은 세션을 쓰고, 한쪽 입력이 바로 다른 쪽에 보인다")
func session_shared_between_editors() throws {
    let f = try Fixture()
    try f.write("메모/a.md", "첫 줄\n")
    let s = try f.store.open("메모/a.md")
    #expect(try f.store.open("메모/a.md") === s)
    let main = EditorID(), sticky = EditorID()
    var mainSaw: [String] = [], stickySaw: [String] = []
    s.attach(main) { mainSaw.append($0) }
    s.attach(sticky) { stickySaw.append($0) }
    s.edit("첫 줄\n스티키에서\n", from: sticky)
    // 파일을 거치지 않고 바로 알린다. 친 쪽에는 되돌려 보내지 않는다
    #expect(mainSaw == ["첫 줄\n스티키에서\n"])
    #expect(stickySaw == [])
    #expect(try f.read("메모/a.md") == "첫 줄\n")
    #expect(s.flush())
    #expect(try f.read("메모/첫 줄.md") == "첫 줄\n스티키에서\n")
}

@MainActor @Test("BUG-26: 다른 앱이 먼저 저장한 줄과 내 편집을 병합해 쓰고 화면에 알린다")
func session_merges_with_disk() throws {
    let f = try Fixture()
    try f.write("메모/a.md", "a\nb\nc")
    let s = try f.store.open("메모/a.md")
    s.syncName = false
    var seen: [String] = []
    let me = EditorID()
    s.attach(me) { seen.append($0) }
    try f.write("메모/a.md", "a\nb\nC 남")
    s.edit("A 나\nb\nc", from: me)
    #expect(s.flush())
    #expect(try f.read("메모/a.md") == "A 나\nb\nC 남")
    // 병합 결과는 친 쪽 화면에도 다시 보여 준다
    #expect(seen == ["A 나\nb\nC 남"])
    #expect(s.body == "A 나\nb\nC 남")
    #expect(!s.dirty)
}

@MainActor @Test("NFR-09: frontmatter는 디스크 최신본을 그대로 둔다")
func session_keeps_frontmatter() throws {
    let f = try Fixture()
    try f.write("메모/a.md", "---\ntags: [a, b]  # 주석\n---\n본문")
    let s = try f.store.open("메모/a.md")
    s.syncName = false
    #expect(s.body == "본문")
    // 그 사이 다른 쪽이 즐겨찾기를 켰다
    try patchMeta(vault: f.vault, "메모/a.md", MetaPatch(pinned: true))
    s.edit("본문 고침", from: nil)
    #expect(s.flush())
    #expect(try f.read("메모/a.md") == "---\ntags: [a, b]  # 주석\npinned: true\n---\n본문 고침")
}

@MainActor @Test("BUG-39: TipTap이 옛 본문을 보고 보낸 변경에도 그 사이 다른 편집기의 줄이 남는다")
func session_edit_based_on_stale_body() throws {
    let f = try Fixture()
    try f.write("메모/a.md", "a\nb")
    let s = try f.store.open("메모/a.md")
    s.syncName = false
    let web = EditorID(), native = EditorID()
    var webSaw: [String] = [], nativeSaw: [String] = []
    s.attach(web) { webSaw.append($0) }
    s.attach(native) { nativeSaw.append($0) }
    // 네이티브 스티키가 먼저 한 줄을 넣었다
    s.edit("a\nb\n스티키", from: native)
    // 웹 편집기는 그 전 본문("a\nb")을 보고 첫 줄을 고쳐 보냈다
    s.edit("A 웹\nb", basedOn: "a\nb", from: web)
    #expect(s.body == "A 웹\nb\n스티키")
    #expect(nativeSaw.last == "A 웹\nb\n스티키")
    // 보낸 쪽도 합친 결과로 다시 그린다
    #expect(webSaw.last == "A 웹\nb\n스티키")
    #expect(s.flush())
    #expect(try f.read("메모/a.md") == "A 웹\nb\n스티키")
}

@MainActor @Test("BUG-24: 저장할 것이 없으면 떠날 때 바로 닫힌다")
func session_closes_when_clean() throws {
    let f = try Fixture()
    try f.write("메모/a.md", "글")
    let s = try f.store.open("메모/a.md")
    let id = EditorID()
    s.attach(id) { _ in }
    #expect(f.store.count == 1)
    f.store.detach(id, from: s)
    #expect(f.store.count == 0)
}

@MainActor @Test("NFR-13·BUG-24: 실패 중에 떠나면 남아서 다시 시도하고, 성공하면 저절로 닫힌다")
func session_retries_after_leaving() throws {
    let f = try Fixture()
    try f.write("메모/a.md", "글")
    let s = try f.store.open("메모/a.md")
    s.syncName = false
    let id = EditorID()
    s.attach(id) { _ in }
    var stateChanges = 0
    f.store.onState = { stateChanges += 1 }
    s.edit("글 고침", from: id)
    // 폴더를 잠가 쓰지 못하게 한다
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.vault + "/메모")
    #expect(!s.flush())
    #expect(s.failure != nil)
    #expect(stateChanges == 1)
    f.store.detach(id, from: s)
    // 화면에서 떠났지만 저장하지 못했으므로 남아 있다
    #expect(f.store.count == 1)
    #expect(f.store.backgroundFailing == 1)
    #expect(f.store.unsavedCount == 1)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.vault + "/메모")
    #expect(f.store.flushAll() == 0)
    #expect(try f.read("메모/a.md") == "글 고침")
    #expect(f.store.count == 0)
    #expect(stateChanges == 2)
}

@MainActor @Test("BUG-40: 저장할 때 파일이 사라졌으면 그 자리에 다시 만들어 입력을 살린다")
func session_recreates_missing_file() throws {
    let f = try Fixture()
    try f.write("메모/a.md", "글")
    let s = try f.store.open("메모/a.md")
    s.syncName = false
    s.edit("글 더 씀", from: nil)
    try FileManager.default.removeItem(atPath: f.vault + "/메모/a.md")
    #expect(s.flush())
    #expect(try f.read("메모/a.md") == "글 더 씀")
}

@MainActor @Test("Brief 3.3-4: 휴지통으로 보낸 메모는 저장하지 않는다(다시 만들지 않는다)")
func session_discard_does_not_recreate() throws {
    let f = try Fixture()
    try f.write("메모/a.md", "글")
    try f.write("메모/b.md", "남는 글")
    let a = try f.store.open("메모/a.md")
    let b = try f.store.open("메모/b.md")
    b.syncName = false
    a.edit("글 더 씀", from: nil)
    b.edit("남는 글 고침", from: nil)
    try FileManager.default.removeItem(atPath: f.vault + "/메모/a.md")
    f.store.discardUnder("메모/a.md")
    #expect(f.store.flushAll() == 0)
    #expect(!f.exists("메모/a.md"))
    #expect(try f.read("메모/b.md") == "남는 글 고침")
    // 폴더를 지울 때는 그 아래 전부
    _ = try f.store.open("메모/b.md").edit("또 고침", from: nil)
    f.store.discardUnder("메모")
    #expect(f.store.flushAll() == 0)
    #expect(try f.read("메모/b.md") == "남는 글 고침")
}

@MainActor @Test("BUG-25·BUG-28: 저장하면 제목에 맞춰 파일 이름이 바뀌고, 세션 경로가 따라간다")
func session_renames_to_title() throws {
    let f = try Fixture()
    let path = try createNote(vault: f.vault, folder: "")
    let s = try f.store.open(path, createdNew: true)
    s.attach(EditorID()) { _ in }
    var renamed: [(String, String)] = []
    f.store.onRenamed = { renamed.append(($0, $1)) }
    s.edit("# 장보기\n- [ ] 우유", from: nil)
    #expect(s.flush())
    #expect(s.path == "메모/장보기.md")
    #expect(renamed.map(\.1) == ["메모/장보기.md"])
    #expect(f.store.existing("메모/장보기.md") === s)
    #expect(try f.read("메모/장보기.md") == "# 장보기\n- [ ] 우유")
    // 제목이 그대로면 이름도 그대로
    s.edit("# 장보기\n- [x] 우유", from: nil)
    #expect(s.flush())
    #expect(renamed.count == 1)
}

@MainActor @Test("F-07 4.2: 다른 앱이 파일을 바꾸면, 입력 중이 아닐 때는 새 내용을 보여 준다")
func session_disk_changed() throws {
    let f = try Fixture()
    try f.write("메모/a.md", "a\nb")
    let s = try f.store.open("메모/a.md")
    s.syncName = false
    var seen: [String] = []
    let id = EditorID()
    s.attach(id) { seen.append($0) }
    try f.write("메모/a.md", "a\nb\n다른 앱")
    f.store.diskChanged(["메모/a.md"])
    #expect(seen == ["a\nb\n다른 앱"])
    #expect(!s.dirty)
    // 내가 방금 쓴 변경은 무시한다(본문이 같다)
    f.store.diskChanged()
    #expect(seen.count == 1)
    // 입력 중이면 병합해 저장한다
    s.edit("A 나\nb\n다른 앱", from: id)
    try f.write("메모/a.md", "a\nb\n다른 앱\n또")
    f.store.diskChanged(["메모/a.md"])
    #expect(try f.read("메모/a.md") == "A 나\nb\n다른 앱\n또")
    #expect(seen.last == "A 나\nb\n다른 앱\n또")
}

@MainActor @Test("F-03 R-4: 폴더 이름 변경·이동 때 열린 세션의 경로가 따라간다")
func session_follows_moves() throws {
    let f = try Fixture()
    try f.write("메모/a.md", "글")
    try f.write("메모-2/b.md", "글")
    let a = try f.store.open("메모/a.md")
    let b = try f.store.open("메모-2/b.md")
    a.syncName = false
    let m = try moveEntry(vault: f.vault, from: "메모", toFolder: "메모-2")
    f.store.applyMove(from: m.from, to: m.to)
    #expect(a.path == "메모-2/메모/a.md")
    #expect(b.path == "메모-2/b.md") // 접두사만 같은 폴더는 그대로
    a.edit("글 고침", from: nil)
    #expect(a.flush())
    #expect(try f.read("메모-2/메모/a.md") == "글 고침")
}

@MainActor @Test("Brief 3.2-1: 입력을 멈추면 잠시 뒤 스스로 저장한다")
func session_autosaves_after_delay() async throws {
    let f = try Fixture()
    try f.write("메모/a.md", "글")
    let store = SessionStore(vault: f.vault, delays: .init(save: 0.05, retry: 0.05))
    let s = try store.open("메모/a.md")
    s.syncName = false
    s.edit("글 1", from: nil)
    s.edit("글 12", from: nil)
    #expect(try f.read("메모/a.md") == "글")
    try await Task.sleep(for: .milliseconds(300))
    #expect(try f.read("메모/a.md") == "글 12")
    #expect(!s.dirty)
}
