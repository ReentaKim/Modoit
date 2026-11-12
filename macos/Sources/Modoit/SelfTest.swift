import AppKit
import ModoitCore
import ModoitKit
import WebKit

/// `--selftest`: 실제 앱에서 메모를 고르고, 편집기에 글자를 넣고, 파일에 저장되는지 본다.
/// 개발 중 확인용이다. `--vault`로 준 임시 폴더에서만 돌린다.
@MainActor
final class SelfTest {
    let model: AppModel
    private var failures = 0

    init(model: AppModel) { self.model = model }

    private var lines: [String] = []

    /// 결과를 표준 출력과 `--log` 파일에 남긴다(`open`으로 띄우면 표준 출력이 보이지 않는다)
    private func log(_ line: String) {
        print(line)
        lines.append(line)
        if let path = LaunchOptions.current.log { try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
    }

    private func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { log("  통과  \(name)") } else {
            failures += 1
            log("  실패  \(name) \(detail())")
        }
    }

    private func wait(_ what: String, timeout: Double = 8, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        log("  시간 초과: \(what)")
        return false
    }

    private func js(_ code: String) async -> String {
        (try? await model.editor.webView.evaluateJavaScript(code)).map { "\($0)" } ?? ""
    }

    private func read(_ rel: String) -> String {
        (try? String(contentsOfFile: model.vault! + "/" + rel, encoding: .utf8)) ?? "(없음)"
    }

    func run() {
        Task { @MainActor in
            await body()
            if let out = LaunchOptions.current.snapshot { await snapshot(to: out) }
            log(failures == 0 ? "자체 검사 통과" : "자체 검사 실패 \(failures)건")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private func snapshot(to out: String) async {
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue == "main" }), let v = w.contentView,
           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        if let img = try? await model.editor.webView.takeSnapshot(configuration: nil),
           let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "-editor.png")))
        }
    }

    private func body() async {
        guard let vault = model.vault else { return check("저장 폴더", false) }
        check("메인 창이 떠 있다", NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == "main" }, NSApp.windows.map { "\($0.title)|\($0.isVisible)" }.joined(separator: ", "))
        check("목록을 읽었다", model.tree.notes.count >= 2, "\(model.tree.notes.count)개")
        check("기본 폴더가 있다", FileManager.default.fileExists(atPath: vault + "/메모"))

        // 1. 메모를 고르면 편집기에 뜬다. 열기만 해서는 파일을 쓰지 않는다 (Brief 3.4-1)
        let before = read("메모/장보기.md")
        // 지난 실행의 선택이 복원돼 이미 열려 있을 수 있다 (FR-53)
        if model.selectedNote != "메모/장보기.md" {
            let loads = model.loadedCount
            model.selectNote("메모/장보기.md")
            _ = await wait("편집기가 문서를 그림") { self.model.loadedCount > loads }
        } else {
            _ = await wait("편집기가 문서를 그림") { self.model.loadedCount > 0 }
        }
        let text = await js("document.querySelector('.modoit-editor').innerText")
        check("편집기에 본문이 보인다", text.contains("우유"), text.debugDescription)
        try? await Task.sleep(for: .milliseconds(900))
        check("열기만 해서는 파일을 쓰지 않는다", read("메모/장보기.md") == before)

        // 2. 글자를 넣으면 0.5초 뒤 저장된다. frontmatter는 그대로다
        _ = await js("(()=>{const e=document.querySelector('.modoit-editor');e.focus();const s=window.getSelection();s.selectAllChildren(e);s.collapseToEnd();document.execCommand('insertText',false,' 두부');return 1})()")
        _ = await wait("저장") { self.read("메모/장보기.md").contains("두부") }
        let after = read("메모/장보기.md")
        check("입력이 저장된다", after.contains("두부"), after.debugDescription)
        check("frontmatter는 그대로", after.hasPrefix("---\ntags: [a, b]  # 주석\n---\n"), after.debugDescription)
        check("고치지 않은 줄은 그대로", after.contains("# 장보기\n") && after.contains("- [ ] 우유"), after.debugDescription)

        // 3. 새 메모: 제목을 쓰면 파일 이름이 따라간다 (F-05)
        let l2 = model.loadedCount
        model.newNote()
        _ = await wait("새 메모 편집기") { self.model.loadedCount > l2 }
        check("새 메모가 선택됐다", model.selectedNote == "메모/새 메모.md", model.selectedNote ?? "nil")
        _ = await js("(()=>{const e=document.querySelector('.modoit-editor');e.focus();document.execCommand('insertText',false,'회의록 가나다');return 1})()")
        _ = await wait("이름 맞추기") { self.model.selectedNote == "메모/회의록 가나다.md" }
        check("파일 이름이 제목을 따른다", model.selectedNote == "메모/회의록 가나다.md" && read("메모/회의록 가나다.md").contains("회의록 가나다"), model.selectedNote ?? "nil")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: vault + "/메모")) ?? []
        check("이름은 NFC 그대로", names.contains { Array($0.utf8) == Array("회의록 가나다.md".utf8) }, "\(names)")

        // 4. 빈 새 메모는 떠날 때 정리된다 (Brief 3.3-2)
        let l3 = model.loadedCount
        model.newNote()
        _ = await wait("빈 새 메모") { self.model.loadedCount > l3 }
        let empty = model.selectedNote ?? ""
        model.selectNote("메모/장보기.md")
        try? await Task.sleep(for: .milliseconds(300))
        check("빈 새 메모는 정리된다", !FileManager.default.fileExists(atPath: vault + "/" + empty), empty)

        // 5. 즐겨찾기: 다른 줄은 바뀌지 않는다 (NFR-09)
        model.setFavorite("메모/장보기.md", true)
        check("즐겨찾기 저장", read("메모/장보기.md").hasPrefix("---\ntags: [a, b]  # 주석\npinned: true\n---\n"), read("메모/장보기.md").debugDescription)
        check("즐겨찾기 묶음이 맨 위", model.groups.first?.title == "즐겨찾기")
        model.selection = .favorites
        check("사이드바 즐겨찾기는 즐겨찾기만", model.groups.flatMap(\.notes).map(\.path) == ["메모/장보기.md"])
        model.selection = .all

        // 6. 지원하지 않는 서식은 읽기 전용 (FR-43)
        let l4 = model.loadedCount
        model.selectNote("메모/각주.md")
        _ = await wait("각주 메모") { self.model.loadedCount > l4 }
        check("읽기 전용 안내", !model.unsupported.isEmpty, "\(model.unsupported)")

        // 6-1. 폴더 (F-03): 만들기, 이름 변경, 옮기기, 구분선
        model.createFolder(parent: "", name: "프로젝트")
        check("폴더 만들기 → 선택", model.selection == .folder("프로젝트") && FileManager.default.fileExists(atPath: vault + "/프로젝트"))
        model.createFolder(parent: "프로젝트", name: "..")
        check("잘못된 폴더 이름은 거부", !FileManager.default.fileExists(atPath: vault + "/프로젝트/.."+"x") && model.notice != nil)
        // 메모를 폴더로 옮긴다: 선택이 따라가고 이미지 링크가 새 위치 기준이 된다 (FR-36)
        try? atomicWrite("# 그림 메모\n![](../attachments/a.png)\n", to: vault + "/메모/그림 메모.md")
        try? atomicWrite(Data([1]), to: vault + "/attachments/a.png")
        model.refresh()
        model.selection = .all
        let l6 = model.loadedCount
        model.selectNote("메모/그림 메모.md")
        _ = await wait("그림 메모") { self.model.loadedCount > l6 }
        try? FileManager.default.createDirectory(atPath: vault + "/프로젝트/세부", withIntermediateDirectories: true)
        model.refresh()
        model.moveNote("메모/그림 메모.md", toFolder: "프로젝트/세부")
        check("메모 옮기기: 선택이 따라간다", model.selectedNote == "프로젝트/세부/그림 메모.md", model.selectedNote ?? "nil")
        check("메모 옮기기: 링크를 고친다", read("프로젝트/세부/그림 메모.md").contains("![](../../attachments/a.png)"), read("프로젝트/세부/그림 메모.md").debugDescription)
        // 열린 메모가 든 폴더의 이름을 바꾼다: 세션 경로가 따라가 새 자리에 저장된다 (F-03 R-4)
        model.renameFolder("프로젝트", to: "일")
        check("폴더 이름 변경: 선택이 따라간다", model.selectedNote == "일/세부/그림 메모.md", model.selectedNote ?? "nil")
        _ = await js("(()=>{const e=document.querySelector('.modoit-editor');e.focus();const s=window.getSelection();s.selectAllChildren(e);s.collapseToEnd();document.execCommand('insertText',false,' 이름바꾼뒤');return 1})()")
        _ = await wait("바뀐 경로에 저장") { self.read("일/세부/그림 메모.md").contains("이름바꾼뒤") }
        check("이름 바꾼 뒤 입력은 새 경로에 저장", read("일/세부/그림 메모.md").contains("이름바꾼뒤") && !FileManager.default.fileExists(atPath: vault + "/프로젝트"))
        // 폴더를 다른 폴더 안으로 (FR-27)
        model.moveFolder("일", toParent: "업무", before: nil, into: true)
        check("폴더를 안으로: 선택이 따라간다", model.selectedNote == "업무/일/세부/그림 메모.md", model.selectedNote ?? "nil")
        check("자기 하위로는 못 옮긴다", { model.moveFolder("업무", toParent: "업무/일", before: nil, into: true); return FileManager.default.fileExists(atPath: vault + "/업무/일") }())
        // 순서와 구분선 (FR-28, 29)
        model.moveFolder("업무", toParent: "", before: "메모", into: false)
        check("순서 바꾸기", model.sidebarRows.filter { $0.depth == 0 }.map(\.id).prefix(2) == ["f:업무", "f:메모"], "\(model.sidebarRows.map(\.id))")
        model.setLayout(addSeparator(model.tree.folders, model.tree.layout, parent: "", after: "업무"))
        check("구분선 추가", model.sidebarRows.filter { $0.depth == 0 }.count == 3 && read(".modoit/layout.json").contains("sep:"), read(".modoit/layout.json"))

        // 6-2. 설정 (F-10): 저장, 앱 전체 모양, 편집기 강조 색
        model.updatePrefs { $0.theme = "dark"; $0.accent = "blue"; $0.fontSize = 99 }
        let conf = (try? String(contentsOfFile: model.configPath, encoding: .utf8)) ?? ""
        check("설정 저장 (범위 밖 크기는 22로)", conf.contains("\"theme\" : \"dark\"") && conf.contains("\"accent\" : \"blue\"") && conf.contains("\"fontSize\" : 22"), conf)
        check("모양: 앱 전체가 다크", NSApp.appearance?.name == .darkAqua)
        _ = await wait("편집기 다크", timeout: 3) { self.model.editor.webView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        try? await Task.sleep(for: .milliseconds(700))
        let look = await js("document.documentElement.dataset.accent + '|' + matchMedia('(prefers-color-scheme: dark)').matches + '|' + getComputedStyle(document.documentElement).getPropertyValue('--font-size')")
        check("편집기에 강조 색·다크·글자 크기 적용", look == "blue|true|22px", look)
        if let out = LaunchOptions.current.snapshot { await snapshot(to: out.replacingOccurrences(of: ".png", with: "-dark.png")) }
        model.updatePrefs { $0.theme = "system"; $0.accent = "yellow"; $0.fontSize = 17 }
        check("모양: 시스템 설정으로 되돌림", NSApp.appearance == nil)

        // 6-3. 파일 감시 (FR-22): 다른 앱이 고친 내용이 열린 편집기와 목록에 반영된다
        let open = model.selectedNote ?? ""
        try? atomicWrite(read(open) + "\n밖에서 덧붙임\n", to: vault + "/" + open)
        let shown = await wait("밖에서 고친 내용") { self.model.session?.body.contains("밖에서 덧붙임") == true }
        try? await Task.sleep(for: .milliseconds(300))
        let seen = await js("document.querySelector('.modoit-editor').innerText")
        check("밖에서 고친 내용이 편집기에 보인다", shown && seen.contains("밖에서 덧붙임"), seen.debugDescription)
        try? atomicWrite("# 밖에서 만든 메모\n", to: vault + "/메모/밖에서 만든 메모.md")
        let listed = await wait("밖에서 만든 메모") { self.model.tree.notes.contains { $0.path == "메모/밖에서 만든 메모.md" } }
        check("밖에서 만든 메모가 목록에 뜬다", listed)
        unlink(vault + "/메모/밖에서 만든 메모.md")
        let gone = await wait("밖에서 지운 메모") { !self.model.tree.notes.contains { $0.path == "메모/밖에서 만든 메모.md" } }
        check("밖에서 지운 메모가 목록에서 빠진다", gone)

        // 6-4. 메뉴 (F-11)
        let menus = (NSApp.mainMenu?.items ?? []).map { m in m.title + "[" + (m.submenu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title + ($0.keyEquivalent.isEmpty ? "" : "(\($0.keyEquivalent))") }.joined(separator: ", ") + "]" }
        log("  메뉴: " + menus.joined(separator: "\n        "))
        let all = menus.joined()
        check("메뉴 항목이 있다", ["새 메모", "새 폴더", "저장 폴더 변경…", "찾기", "사이드바 보기·가리기", "모양", "메인 창", "설정…"].allSatisfy { all.contains($0) })
        model.menuToggleSidebar()
        check("사이드바 가리기는 설정에 남는다", model.prefs.sidebarCollapsed)
        model.menuToggleSidebar()

        // 창 제목은 고른 항목이다 (F-02 R-4)
        model.selection = .folder("업무")
        try? await Task.sleep(for: .milliseconds(300))
        let title = NSApp.windows.first { $0.identifier?.rawValue == "main" }?.title ?? ""
        check("창 제목 = 고른 폴더", title == "업무", title)
        model.selection = .all

        // 6-5. 메인 창을 닫아도 앱은 살아 있고 다시 열린다 (FR-42)
        let main = { NSApp.windows.first { $0.identifier?.rawValue == "main" } }
        check("메인 창을 찾는다", main() != nil, NSApp.windows.map { "\($0.identifier?.rawValue ?? "-")" }.joined(separator: ","))
        main()?.performClose(nil)
        _ = await wait("닫힘", timeout: 2) { main()?.isVisible != true }
        check("메인 창이 닫혔다", main()?.isVisible != true)
        model.showMainWindow()
        let back = await wait("다시 열림", timeout: 3) { main()?.isVisible == true }
        try? await Task.sleep(for: .milliseconds(400))
        let again = await js("document.querySelector('.modoit-editor').innerText")
        check("메인 창이 다시 열리고 편집기가 그대로다", back && again.contains("밖에서 덧붙임"), again.debugDescription)
        model.menuFind()
        try? await Task.sleep(for: .milliseconds(500))
        check("찾기: 검색 칸에 커서", main()?.firstResponder is NSTextView, "\(String(describing: main()?.firstResponder))")
        // 검색어가 있으면 목록이 걸러지고, 새 메모를 만들면 검색어를 지운다 (F-09 R-3)
        model.selection = .all
        model.query = "주간"
        let found = model.groups.flatMap(\.notes).map(\.path)
        check("검색: 입력하는 대로 걸러진다", found == ["업무/회의/주간.md"], "\(found)")
        model.menuNewNote()
        let made = model.selectedNote ?? ""
        check("새 메모를 만들면 검색어를 지운다", model.query.isEmpty && model.groups.flatMap(\.notes).contains { $0.path == made }, made)

        // 7. 휴지통 대신: 종료 전 저장이 남은 입력을 쓴다 (F-12)
        let l5 = model.loadedCount
        model.selectNote("메모/장보기.md")
        _ = await wait("다시 열기") { self.model.loadedCount > l5 }
        _ = await js("(()=>{const e=document.querySelector('.modoit-editor');e.focus();const s=window.getSelection();s.selectAllChildren(e);s.collapseToEnd();document.execCommand('insertText',false,' 종료직전');return 1})()")
        _ = await wait("편집기 변경 전달", timeout: 2) { self.model.session?.dirty == true }
        check("종료 전 저장: 남은 것 없음", model.flushForQuit() == 0)
        check("종료 직전 입력이 파일에 있다", read("메모/장보기.md").contains("종료직전"))

        await stickyChecks(vault)
    }

    /// 8. 스티키 (F-08)
    private func stickyChecks(_ vault: String) async {
        let st = model.stickies
        let note = "메모/장보기.md"
        func web(_ w: WebEditor?, _ code: String) async -> String {
            guard let w else { return "" }
            return (try? await w.webView.evaluateJavaScript(code)).map { "\($0)" } ?? ""
        }

        // 꺼내기: 네이티브 편집기로 뜨고, frontmatter에는 sticky만 더해진다 (FR-30, FR-51, NFR-09)
        st.popOut(note)
        guard let c = st.controller(note) else { return check("꺼내기: 패널이 뜬다", false) }
        check("꺼내기: 패널이 뜬다", c.panel.isVisible)
        check("꺼내기: sticky만 더해진다", read(note).hasPrefix("---\ntags: [a, b]  # 주석\npinned: true\nsticky: { color: yellow, x: null, y: null, w: 280, h: 280, onTop: false, open: true }\n---\n"), read(note).debugDescription)
        check("네이티브 편집기로 열린다", c.kind == .native && c.textView?.string == model.session?.body)
        check("사이드바 스티키 메모에 뜬다", model.openStickies.map(\.path) == [note])
        check("다른 앱의 포커스를 뺏지 않는 패널", c.panel.styleMask.contains(.nonactivatingPanel) && c.panel.collectionBehavior.contains(.canJoinAllSpaces))

        // 스티키는 보기 전용이다 (D-25)
        check("스티키는 보기 전용", c.textView?.isEditable == false && c.textView?.isSelectable == true)

        // 기호만 있는 줄도 한 줄 높이를 지킨다 (체크박스가 겹쳐 그려지던 문제)
        try? atomicWrite(read(note) + "\n- [ ] 달걀\n- [ ] ", to: vault + "/" + note)
        _ = await wait("밖에서 고친 내용", timeout: 3) { c.textView?.string.contains("달걀") == true }
        if let tv = c.textView, let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            let last = lm.lineFragmentRect(forGlyphAt: max(0, lm.numberOfGlyphs - 1), effectiveRange: nil)
            check("빈 체크박스 줄도 한 줄 높이", last.height >= 20, "높이 \(last.height)")
        }

        // 메인 창에 쓰면 스티키에 보인다 (FR-30)
        _ = await wait("메인 창 반영") { self.model.session?.body.contains("달걀") == true }
        try? await Task.sleep(for: .milliseconds(400))
        _ = await js("(()=>{const e=document.querySelector('.modoit-editor');e.focus();const s=window.getSelection();s.selectAllChildren(e);s.collapseToEnd();document.execCommand('insertText',false,'간장');return 1})()")
        let seenInSticky = await wait("스티키에 반영", timeout: 1.5) { c.textView?.string.contains("간장") == true }
        check("메인 창 입력이 1초 안에 스티키에 보인다", seenInSticky, c.textView?.string.debugDescription ?? "")
        _ = await wait("입력 저장") { self.model.session?.dirty == false && self.read(note).contains("간장") }

        // 체크박스를 누르면 그 줄의 한 글자만 바뀌고 메인 창에도 보인다 (R-9)
        let beforeCheck = read(note)
        if let tv = c.textView, let r = tv.string.range(of: "- [ ] 우유") {
            tv.toggleCheck(atCharacter: NSRange(r, in: tv.string).location)
        }
        _ = await wait("체크 저장") { self.read(note).contains("- [x] 우유") }
        check("스티키에서 체크: 한 글자만 바뀐다", read(note) == beforeCheck.replacingOccurrences(of: "- [ ] 우유", with: "- [x] 우유"), read(note).debugDescription)
        let checkedInMain = await wait("메인 창에 체크 반영", timeout: 1.5) { self.model.session?.body.contains("- [x] 우유") == true }
        check("스티키의 체크가 메인 창에 보인다", checkedInMain)

        // 항상 위, 색 (FR-40, FR-55)
        st.setOnTop(note, true)
        check("항상 위: 창 단계와 파일, 사이드바가 같다", c.panel.level == .floating && read(note).contains("onTop: true") && model.openStickies.first?.sticky?.onTop == true)
        st.setColor(note, "blue")
        check("색 바꾸기", read(note).contains("color: blue"))

        // 눈으로 볼 수 있게 스티키 화면을 그림으로 남긴다
        if let out = LaunchOptions.current.snapshot, let v = c.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "-sticky.png")))
        }

        // 네이티브로 그릴 수 없는 서식이 생기면 TipTap으로 바꿔 그린다 (R-10)
        _ = await wait("입력 저장") { self.model.session?.dirty == false }
        try? atomicWrite(read(note) + "\n```\ncode\n```\n", to: vault + "/" + note)
        let switched = await wait("TipTap으로 전환") { c.kind == .web && c.web != nil }
        check("코드 블록이 생기면 TipTap으로", switched)
        _ = await wait("스티키 화면 준비", timeout: 5) { self.model.session?.body.contains("code") == true }
        try? await Task.sleep(for: .milliseconds(1200))
        let webText = await web(c.web, "document.querySelector('.modoit-editor')?.innerText ?? ''")
        check("TipTap 스티키에 본문이 보인다", webText.contains("달걀") && webText.contains("code"), webText.debugDescription)
        let compact = await web(c.web, "document.body.classList.contains('compact') + '|' + matchMedia('(prefers-color-scheme: dark)').matches + '|' + document.querySelector('.modoit-editor').isContentEditable")
        check("TipTap 스티키는 좁은 화면·밝은 종이·보기 전용", compact == "true|false|false", compact)
        // TipTap 스티키의 체크: 편집기가 문서를 다시 쓰지 않고 그 줄의 한 글자만 바뀐다
        let beforeWeb = read(note)
        _ = await web(c.web, "(()=>{const b=[...document.querySelectorAll('li[data-type=\"taskItem\"] input[type=checkbox]')];const t=b.find(x=>x.closest('li').innerText.includes('달걀'));t.click();return b.length})()")
        _ = await wait("TipTap 스티키 체크 저장", timeout: 3) { self.read(note).contains("- [x] 달걀") }
        check("TipTap 스티키에서 체크: 한 글자만 바뀐다", read(note) == beforeWeb.replacingOccurrences(of: "- [ ] 달걀", with: "- [x] 달걀"), read(note).debugDescription)
        try? await Task.sleep(for: .milliseconds(600))
        let webChecked = await web(c.web, "[...document.querySelectorAll('li[data-checked=\"true\"]')].some(x=>x.innerText.includes('달걀'))")
        check("TipTap 스티키에 체크가 보인다", webChecked == "true" || webChecked == "1", webChecked)
        // 코드 블록이 없어지면 다시 네이티브로 그린다
        try? atomicWrite(read(note).replacingOccurrences(of: "\n```\ncode\n```\n", with: "\n"), to: vault + "/" + note)
        let back = await wait("네이티브로 되돌림", timeout: 3) { c.kind == .native && c.textView?.string.contains("- [x] 달걀") == true }
        check("TipTap 서식이 없어지면 다시 네이티브로", back)
        // 두 번 누르면 메인 창에서 그 메모가 열린다
        model.selectNote("업무/회의/주간.md")
        c.textView?.onOpen?()
        check("스티키를 두 번 누르면 메인 창에서 열린다", model.selectedNote == note, model.selectedNote ?? "")

        // 다시 넣기: 색·위치는 기억한다 (FR-31, R-3)
        check("다시 넣기", st.putBack(note) && st.controller(note) == nil && !c.panel.isVisible)
        check("넣어도 색은 기억", read(note).contains("color: blue") && read(note).contains("open: false") && model.openStickies.isEmpty, read(note).debugDescription)
        // 다시 꺼내면 같은 색 (FR-31)
        st.popOut(note)
        check("다시 꺼내면 같은 색·항상 위", st.controller(note)?.meta.color == "blue" && st.controller(note)?.meta.onTop == true)
        // 다시 켠 것처럼: 닫았다가 복원해도 파일을 쓰지 않는다 (R-8)
        let disk = read(note)
        st.closeAll()
        model.refresh()
        st.restore()
        check("복원: 열려 있던 스티키가 다시 뜨고 파일은 그대로", st.controller(note)?.panel.isVisible == true && read(note) == disk)
        // 기억 지우기: sticky 키만 지운다 (FR-44)
        st.forget(note)
        check("기억 지우기", st.controller(note) == nil && !read(note).contains("sticky:") && read(note).hasPrefix("---\ntags: [a, b]  # 주석\npinned: true\n---\n"), read(note).debugDescription)

        // ⌘⇧N: 빈 채로 넣으면 그 메모만 정리한다 (FR-38, R-7)
        model.selection = .all
        let countBefore = model.tree.notes.count
        model.newStickyNote()
        let freshPath = st.controllers.last?.session.path ?? ""
        check("새 스티키 메모: 스티키로 뜨고 메인 창에서 쓴다", st.controllers.count == 1 && st.controllers.last?.fresh == true && model.tree.notes.count == countBefore + 1 && model.selectedNote == freshPath, freshPath)
        st.putBack(freshPath)
        model.selectNote("업무/회의/주간.md")
        _ = await wait("빈 메모 정리", timeout: 2) { !FileManager.default.fileExists(atPath: vault + "/" + freshPath) }
        model.refresh()
        check("빈 새 스티키 메모는 정리된다", !FileManager.default.fileExists(atPath: vault + "/" + freshPath) && model.tree.notes.count == countBefore)
        // 내용이 있는 메모는 넣어도 남는다 (BUG-23)
        st.popOut("업무/회의/주간.md")
        st.putBack("업무/회의/주간.md")
        check("원래 있던 메모는 넣어도 남는다", read("업무/회의/주간.md").contains("주간 회의"))

        // 휴지통으로 보내면 스티키도 닫힌다 (Brief 3.3-4)
        try? atomicWrite("# 버릴 메모\n", to: vault + "/메모/버릴 메모.md")
        model.refresh()
        st.popOut("메모/버릴 메모.md")
        model.trash(note: "메모/버릴 메모.md")
        check("휴지통: 스티키가 닫히고 파일이 되살아나지 않는다", st.controllers.isEmpty && !FileManager.default.fileExists(atPath: vault + "/메모/버릴 메모.md"))
    }
}
