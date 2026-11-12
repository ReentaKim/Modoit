// 사이드바 순서(src/qa/logic.test.ts, v03Logic.test.ts)와 메모 목록 묶음.
import Foundation
import Testing
import ModoitCore
@testable import ModoitKit

private func node(_ path: String, _ modified: UInt64 = 0, _ children: [FolderNode] = []) -> FolderNode {
    FolderNode(path: path, name: String(path.split(separator: "/").last!), modified: modified, children: children)
}

private let folders = [node("가", 3), node("나", 1, [node("나/하위")]), node("다", 2)]

private func names(_ l: Layout) -> String {
    flattenTree(folders, l, collapsed: []).map { r in
        if case .folder(let path, _, _, _) = r.kind { return path }
        return "|"
    }.joined(separator: " ")
}

@Test("FR-29: 구분선 구역 안에서만 이름순·최신순") func sidebar_sorts_within_sections() {
    let order = ["": ["다", "sep:1", "나", "가"]]
    #expect(names(Layout(sort: .custom, order: order)) == "다 | 나 나/하위 가")
    #expect(names(Layout(sort: .name, order: order)) == "다 | 가 나 나/하위")
    #expect(names(Layout(sort: .recent, order: order)) == "다 | 가 나 나/하위")
    // 순서 정보가 없으면 이름순, 접으면 하위가 빠진다
    #expect(names(Layout()) == "가 나 나/하위 다")
    #expect(flattenTree(folders, Layout(), collapsed: ["나"]).count == 3)
}

@Test("FR-27: 직접 정렬에서 폴더 사이로 놓으면 그 자리로") func sidebar_reorder() {
    let l = reorder(folders, Layout(), parent: "", key: "다", before: "가")
    #expect(l.order[""] == ["다", "가", "나"])
    // 맨 뒤로
    #expect(reorder(folders, Layout(), parent: "", key: "가", before: nil).order[""] == ["나", "다", "가"])
}

@Test("BUG-33: 이름순에서 폴더를 다른 폴더 안으로 옮겨도 정렬 방식은 이름순으로 남는다") func sidebar_into_keeps_sort() {
    let after = [node("가", 3), node("나", 2, [node("나/하위"), node("나/다", 2)])]
    #expect(reorder(after, Layout(sort: .name), parent: "나", key: "다", before: nil, into: true).sort == .name)
}

@Test("BUG-45: 이름순에서 맨 뒤에 놓으면 보던 순서를 고정하고 직접 정렬로 바뀐다") func sidebar_reorder_from_name_sort() {
    let l = reorder(folders, Layout(sort: .recent, order: ["": ["가", "sep:1", "나", "다"]]), parent: "", key: "sep:1", before: nil)
    #expect(l.sort == .custom)
    #expect(l.order[""]?.last == "sep:1")
    #expect(Set(l.order[""] ?? []) == ["가", "나", "다", "sep:1"])
}

@Test("FR-29: 구분선 추가·삭제") func sidebar_separators() {
    var l = addSeparator(folders, Layout(), parent: "", after: "가", id: "sep:x")
    #expect(l.order[""] == ["가", "sep:x", "나", "다"])
    l = removeKey(l, parent: "", key: "sep:x")
    #expect(l.order[""] == ["가", "나", "다"])
}

private func note(_ path: String, modified: UInt64, created: UInt64 = 0, title: String? = nil, pinned: Bool = false, preview: String = "") -> NoteMeta {
    NoteMeta(path: path, folder: parentRel(path), title: title ?? String(path.split(separator: "/").last!.dropLast(3)),
             preview: preview, modified: modified, created: created, pinned: pinned, sticky: nil, readable: true)
}

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}
private let now = Date(timeIntervalSince1970: 1_794_000_000) // 2026-11-06 20:00 UTC
private let d: UInt64 = 86_400_000
private var today: UInt64 { UInt64(utc.startOfDay(for: now).timeIntervalSince1970 * 1000) }

@Test("FR-05: 즐겨찾기 → 오늘 / 어제 / 지난 7일 / 지난 30일 / 연도") func notes_grouped_by_date() {
    let notes = [
        note("a.md", modified: today + 1000),
        note("b.md", modified: today - 1000),
        note("c.md", modified: today - 3 * d),
        note("d.md", modified: today - 20 * d),
        note("e.md", modified: today - 400 * d),
        note("f.md", modified: today - 500 * d, pinned: true),
    ]
    let g = groupNotes(notes, sort: .modified, now: now, calendar: utc)
    #expect(g.map(\.title) == ["즐겨찾기", "오늘", "어제", "지난 7일", "지난 30일", "2025년"])
    #expect(g[0].notes.map(\.path) == ["f.md"])
    #expect(g.dropFirst().flatMap(\.notes).map(\.path) == ["a.md", "b.md", "c.md", "d.md", "e.md"])
}

@Test("FR-39·R-2·R-3: 정렬 기준에 따라 묶음과 순서가 바뀐다") func notes_sort_modes() {
    let notes = [
        note("나.md", modified: today + 10, created: today - 40 * d),
        note("가.md", modified: today - 2 * d, created: today + 5),
        note("10.md", modified: today - 3 * d, created: today - 3 * d),
        note("9.md", modified: today - 4 * d, created: today - 4 * d, pinned: true),
    ]
    // 만든 날짜순: 묶음도 만든 날 기준
    let c = groupNotes(notes, sort: .created, now: now, calendar: utc)
    #expect(c.map(\.title) == ["즐겨찾기", "오늘", "지난 7일", "2026년"])
    // 이름순: 날짜 묶음 없이 즐겨찾기 + 메모, 숫자는 크기대로
    let n = groupNotes(notes, sort: .name, now: now, calendar: utc)
    #expect(n.map(\.title) == ["즐겨찾기", "메모"])
    #expect(n[1].notes.map(\.path) == ["10.md", "가.md", "나.md"])
    // 즐겨찾기가 없으면 묶음 제목이 없다
    #expect(groupNotes(Array(notes.prefix(3)), sort: .name, now: now, calendar: utc).map(\.title) == [""])
    #expect(displayTitle(note("x.md", modified: 0, title: "")) == "새로운 메모")
}

@Test("F-04 R-1·R-7, F-09: 범위와 검색") func notes_filter() {
    let notes = [
        note("top.md", modified: 3),
        note("업무/a.md", modified: 2, pinned: true, preview: "주간 Report"),
        note("업무/회의/b.md", modified: 1, title: "회의록"),
    ]
    #expect(filterNotes(notes, scope: .all).count == 3)
    // 폴더를 고르면 바로 안의 메모만
    #expect(filterNotes(notes, scope: .folder("업무")).map(\.path) == ["업무/a.md"])
    #expect(filterNotes(notes, scope: .folder("")).map(\.path) == ["top.md"])
    // 즐겨찾기는 모든 폴더에서
    #expect(filterNotes(notes, scope: .favorites).map(\.path) == ["업무/a.md"])
    // 제목·미리보기·경로, 대소문자 무시, 지금 범위 안에서만
    #expect(filterNotes(notes, scope: .all, query: "report").map(\.path) == ["업무/a.md"])
    #expect(filterNotes(notes, scope: .all, query: "회의").map(\.path) == ["업무/회의/b.md"])
    #expect(filterNotes(notes, scope: .folder("업무"), query: "회의록").isEmpty)
}

@Test func notes_short_date() {
    #expect(shortDate(today - 1000, now: now, calendar: utc) == "어제")
    #expect(shortDate(today - 3 * d, now: now, calendar: utc) == "2026. 11. 3.")
    #expect(shortDate(today + 14 * 3_600_000 + 5 * 60_000, now: now, calendar: utc) == "오후 2:05")
}

@Test("FR-53: 다시 켜면 마지막 폴더와 메모. 메모가 없으면 폴더만, 폴더도 없으면 모든 메모") func FR53_restore_last_selection() {
    let folders: Set<String> = ["업무", "업무/회의"]
    let notes: Set<String> = ["업무/회의/주간.md"]
    func r(_ sel: String?, _ note: String?) -> (NoteScope, String?) {
        let x = resolveLastSelection(selection: sel, note: note, hasFolder: folders.contains, hasNote: notes.contains)
        return (x.scope, x.note)
    }
    #expect(r("folder:업무/회의", "업무/회의/주간.md") == (.folder("업무/회의"), "업무/회의/주간.md"))
    // 메모가 지워졌거나 옮겨졌다: 폴더만
    #expect(r("folder:업무/회의", "업무/회의/없음.md") == (.folder("업무/회의"), nil))
    // 폴더도 없어졌다: 모든 메모
    #expect(r("folder:지운 폴더", "지운 폴더/메모.md") == (.all, nil))
    #expect(r("favorites", "") == (.favorites, nil))
    // 처음 켰거나 저장 폴더를 바꿔 기억이 없다
    #expect(r(nil, nil) == (.all, nil))
}

