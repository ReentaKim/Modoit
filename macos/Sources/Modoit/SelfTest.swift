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
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "Modoit" }), let v = w.contentView,
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
        check("메인 창이 떠 있다", NSApp.windows.contains { $0.isVisible && $0.title == "Modoit" }, NSApp.windows.map { "\($0.title)|\($0.isVisible)" }.joined(separator: ", "))
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

        // 7. 휴지통 대신: 종료 전 저장이 남은 입력을 쓴다 (F-12)
        let l5 = model.loadedCount
        model.selectNote("메모/장보기.md")
        _ = await wait("다시 열기") { self.model.loadedCount > l5 }
        _ = await js("(()=>{const e=document.querySelector('.modoit-editor');e.focus();const s=window.getSelection();s.selectAllChildren(e);s.collapseToEnd();document.execCommand('insertText',false,' 종료직전');return 1})()")
        _ = await wait("편집기 변경 전달", timeout: 2) { self.model.session?.dirty == true }
        check("종료 전 저장: 남은 것 없음", model.flushForQuit() == 0)
        check("종료 직전 입력이 파일에 있다", read("메모/장보기.md").contains("종료직전"))
    }
}
