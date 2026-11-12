import AppKit
import ModoitCore

// 사용법
//   StickyEditorSpike <메모.md> [<메모.md> …]        스티키로 띄운다
//   StickyEditorSpike --selftest                      입력을 재현해 결과를 검사하고 끝낸다(종료 코드 0 = 통과)
//   StickyEditorSpike --snapshot out.png <메모.md>    화면을 그림으로 저장하고 끝낸다
//   --ready-file <경로>                               모든 스티키가 뜨면 이 파일을 만든다(측정용)

final class StickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class Sticky: NSObject {
    let path: String
    let panel: StickyPanel
    let editor: MarkupTextView
    private var saveTimer: Timer?
    private(set) var lastSaved = ""

    init(path: String, index: Int) {
        self.path = path
        panel = StickyPanel(contentRect: NSRect(x: 80 + index * 36, y: 620 - index * 30, width: 300, height: 300),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = NSColor(red: 1.0, green: 0.93, blue: 0.62, alpha: 1)
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 272))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        editor = MarkupTextView.make(frame: scroll.bounds)
        scroll.documentView = editor
        panel.contentView?.addSubview(scroll)
        super.init()
        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let body = splitNote(content).body
        lastSaved = body
        if stickyEditorKind(content) == .web {
            editor.load("이 메모는 TipTap 편집기로 엽니다:\n" + nativeBlockers(body).joined(separator: ", "))
            editor.isEditable = false
        } else {
            editor.load(body)
            editor.onChange = { [weak self] in self?.scheduleSave() }
        }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.save() }
        }
    }

    /// 본문만 바꿔 쓴다. frontmatter는 디스크에 있는 그대로 둔다
    func save() {
        saveTimer?.invalidate()
        let body = editor.string
        guard body != lastSaved || !FileManager.default.fileExists(atPath: path) else { return }
        var parts = splitNote((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
        parts.body = body
        do {
            try atomicWrite(joinNote(parts), to: path)
            lastSaved = body
            editor.markSynced()
        } catch {
            FileHandle.standardError.write(Data("저장 실패: \(error)\n".utf8))
        }
    }
}

@MainActor
func snapshot(_ view: NSView, to out: String) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
}

/// 키 입력을 재현해 원문이 기대대로 바뀌는지 본다
@MainActor
func selfTest() -> Int32 {
    let dir = NSTemporaryDirectory() + "sticky-selftest-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/t.md"
    let front = "---\ntags: [a, b]   # 사용자 주석\nsticky: { color: yellow, x: 1, y: 2, w: 280, h: 280, onTop: false, open: true }\n---\n"
    let body0 = "# 장보기\n- [ ] 우유\n- [x] 빵\n\n메모 **굵게** 와 [링크](https://example.com)\n"
    try? (front + body0).write(toFile: path, atomically: true, encoding: .utf8)
    let s = Sticky(path: path, index: 0)
    let tv = s.editor
    var failures = 0
    func check(_ name: String, _ got: String, _ want: String) {
        if got == want { print("  통과  \(name)") } else {
            failures += 1
            print("  실패  \(name)\n    기대 \(want.debugDescription)\n    결과 \(got.debugDescription)")
        }
    }
    func caret(after needle: String) {
        let r = (tv.string as NSString).range(of: needle)
        tv.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
    }
    func type(_ text: String) {
        for ch in text {
            tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
            if CommandLine.arguments.contains("--trace") { print("    입력 \(ch) → 커서 \(tv.selectedRange().location) / 길이 \((tv.string as NSString).length)") }
        }
    }

    check("열면 본문 그대로", tv.string, body0)

    // 1. 체크박스 줄 끝에서 Enter → 새 체크박스, 글 입력
    caret(after: "우유")
    tv.insertNewline(nil)
    type("계란")
    check("Enter가 체크박스를 잇는다", tv.string, body0.replacingOccurrences(of: "우유\n", with: "우유\n- [ ] 계란\n"))

    // 2. 체크박스 누르기: 한 글자만 바뀐다
    let milk = (tv.string as NSString).range(of: "우유").location
    tv.toggleCheck(atCharacter: milk)
    check("체크는 한 글자만", tv.string, "# 장보기\n- [x] 우유\n- [ ] 계란\n- [x] 빵\n\n메모 **굵게** 와 [링크](https://example.com)\n")

    // 3. 빈 줄에서 단축 입력 `[] ` → `- [ ] `
    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    type("[] 치즈")
    check("단축 입력 [] ", String(tv.string.suffix("- [ ] 치즈".count)), "- [ ] 치즈")

    // 4. Tab으로 들이고, 빈 항목에서 Enter 두 번으로 목록 끝내기
    tv.insertTab(nil)
    check("Tab 들여쓰기", String(tv.string.suffix("  - [ ] 치즈".count)), "  - [ ] 치즈")
    tv.insertNewline(nil)
    tv.insertNewline(nil)
    tv.insertNewline(nil)
    check("빈 항목 Enter로 목록 끝", String(tv.string.suffix("  - [ ] 치즈\n".count)), "  - [ ] 치즈\n")

    // 5. 한글 조합 재현: 조합 중에는 꾸밈·저장을 건드리지 않고, 끝나면 글자가 그대로 남는다
    caret(after: "계란")
    let none = NSRange(location: NSNotFound, length: 0)
    for step in ["ㅎ", "하", "한", "한ㄱ", "한그", "한글"] {
        tv.setMarkedText(step, selectedRange: NSRange(location: (step as NSString).length, length: 0), replacementRange: none)
        if !tv.hasMarkedText() { failures += 1; print("  실패  조합 상태가 끊김: \(step)") }
    }
    tv.insertText("한글", replacementRange: none)
    check("한글 조합 뒤 글자", (tv.string as NSString).substring(with: (tv.string as NSString).paragraphRange(for: NSRange(location: (tv.string as NSString).range(of: "계란").location, length: 0))), "- [ ] 계란한글\n")
    // 조합 중에 다른 쪽(메인 창)에서 다른 줄이 바뀌었다: 조합이 끝날 때까지 미뤘다가 합친다
    tv.markSynced()
    let theirs = tv.string.replacingOccurrences(of: "# 장보기", with: "# 장보기 목록")
    tv.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
    let marked = tv.markedRange()
    let during = tv.string
    tv.applyExternal(theirs)
    check("조합 중에는 본문을 바꾸지 않는다", tv.string, during)
    check("조합 범위 유지", NSStringFromRange(tv.markedRange()), NSStringFromRange(marked))
    tv.insertText("가", replacementRange: none)
    check("조합이 끝나면 양쪽 입력이 모두 남는다", tv.string, theirs.replacingOccurrences(of: "계란한글", with: "계란한글가"))
    let caretLine = (tv.string as NSString).substring(with: (tv.string as NSString).paragraphRange(for: tv.selectedRange()))
    check("커서는 치던 줄에 그대로", caretLine, "- [ ] 계란한글가\n")

    // 6. 저장: frontmatter는 한 글자도 바뀌지 않고, 고치지 않은 줄도 그대로
    s.save()
    let disk = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    check("frontmatter 그대로", String(disk.prefix(front.count)), front)
    let lines = disk.dropFirst(front.count).components(separatedBy: "\n")
    check("다른 쪽이 고친 줄", lines.first ?? "", "# 장보기 목록")
    check("고치지 않은 줄: 서식 있는 문단", lines.contains("메모 **굵게** 와 [링크](https://example.com)") ? "있음" : "없음", "있음")
    check("고친 줄", lines.contains("- [ ] 계란한글가") ? "있음" : "없음", "있음")

    // 7. 숨긴 기호는 폭이 없다: `- [ ] `의 첫 글자와 본문 첫 글자의 x가 같다
    if let lm = tv.layoutManager, let tc = tv.textContainer {
        lm.ensureLayout(for: tc)
        let line = (tv.string as NSString).range(of: "- [x] 우유")
        let g0 = lm.glyphRange(forCharacterRange: NSRange(location: line.location, length: 1), actualCharacterRange: nil)
        let g1 = lm.glyphRange(forCharacterRange: NSRange(location: line.location + 6, length: 1), actualCharacterRange: nil)
        let dx = lm.boundingRect(forGlyphRange: g1, in: tc).minX - lm.boundingRect(forGlyphRange: g0, in: tc).minX
        check("숨긴 기호의 폭 < 1pt", dx < 1 ? "예" : "아니오(\(dx))", "예")
    }
    print(failures == 0 ? "자체 검사 통과" : "자체 검사 실패 \(failures)건")
    return failures == 0 ? 0 : 1
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var args = Array(CommandLine.arguments.dropFirst())
var stickies: [Sticky] = []

MainActor.assumeIsolated {
    if args.first == "--selftest" { exit(selfTest()) }
    var snapshotPath: String?
    var readyFile: String?
    var files: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        if a == "--snapshot" { snapshotPath = args.removeFirst() }
        else if a == "--ready-file" { readyFile = args.removeFirst() }
        else { files.append(a) }
    }
    stickies = files.enumerated().map { Sticky(path: $1, index: $0) }
    if let out = snapshotPath, let s = stickies.first {
        s.editor.layoutManager?.ensureLayout(for: s.editor.textContainer!)
        if let v = s.panel.contentView { snapshot(v, to: out) }
        exit(0)
    }
    for s in stickies { s.panel.orderFrontRegardless() }
    DispatchQueue.main.async {
        if let f = readyFile { FileManager.default.createFile(atPath: f, contents: nil) }
    }
}
app.run()
