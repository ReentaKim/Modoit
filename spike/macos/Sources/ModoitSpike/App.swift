import AppKit
import ModoitCore
import SwiftUI

/// 실행 옵션 (측정 스크립트용)
///   --vault <경로>          저장 폴더 (없으면 지난번 폴더 또는 선택 창)
///   --sticky-kind web|native 스티키 편집기 종류 (기본 web)
struct LaunchOptions {
    var vault: URL?
    var stickyKind = StickyKind.web

    static func parse(_ args: [String] = CommandLine.arguments) -> LaunchOptions {
        var o = LaunchOptions()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--vault": o.vault = it.next().map { URL(filePath: $0) }
            case "--sticky-kind": o.stickyKind = it.next().flatMap(StickyKind.init) ?? .web
            default: break
            }
        }
        return o
    }
}

/// 프로세스 시작 시각 (실행 시간 측정)
func processStart() -> Date {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &info, &size, nil, 0)
    let tv = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
}

let allNotes = "*"

@MainActor @Observable
final class AppModel {
    let options = LaunchOptions.parse()
    private(set) var vault: Vault?
    var folders: [String] = []
    /// 사이드바 선택. "*" = 모든 메모
    var folder: String? = allNotes
    var notes: [NoteMeta] = []
    var selected: String?
    var readOnlyReason: String?
    @ObservationIgnored private(set) var editor: WebEditor?
    @ObservationIgnored private var session: NoteSession?
    @ObservationIgnored let stickies = StickyManager()
    @ObservationIgnored private var launchPending = 0

    func start() {
        let saved = UserDefaults.standard.string(forKey: "vault").map { URL(filePath: $0) }
        if let url = options.vault ?? saved {
            open(vault: url)
        } else {
            chooseVault()
        }
    }

    func chooseVault() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "이 폴더에 저장"
        if p.runModal() == .OK, let url = p.url { open(vault: url) }
    }

    func open(vault url: URL) {
        UserDefaults.standard.set(url.path, forKey: "vault")
        let v = Vault(root: url)
        vault = v
        let ed = WebEditor(vault: v)
        ed.onChange = { [weak self] md in self?.session?.edit(md) }
        ed.onLoaded = { [weak self] in self?.launchStep() }
        editor = ed
        reload()
        // v0.3처럼: open:true인 스티키를 다시 띄운다
        let reopen = v.notes().filter { $0.sticky?.open == true }
        launchPending = reopen.count + (notes.isEmpty ? 0 : 1)
        selected = notes.first?.path
        openSelected()
        for n in reopen {
            stickies.show(vault: v, path: n.path, meta: n.sticky, kind: options.stickyKind) { [weak self] in
                self?.launchStep()
            }
        }
        if launchPending == 0 { launchStep() }
    }

    /// 메인 편집기와 다시 띄운 스티키가 모두 그려지면 한 번 출력한다
    private func launchStep() {
        guard launchPending >= 0 else { return }
        launchPending -= 1
        if launchPending <= 0 {
            launchPending = -1
            let ms = Int(Date().timeIntervalSince(processStart()) * 1000)
            print("SPIKE_READY ms=\(ms) stickies=\(stickies.open.count) kind=\(options.stickyKind.rawValue)")
            fflush(stdout)
        }
    }

    func reload() {
        guard let vault else { return }
        folders = vault.folders()
        notes = vault.notes(in: folder == allNotes ? nil : folder)
    }

    func openSelected() {
        session?.flush()
        session = nil
        guard let vault, let editor, let path = selected,
              let text = try? vault.read(path) else { return }
        let s = NoteSession(vault: vault, path: path)
        s.onSaved = { [weak self] in self?.reload() }
        session = s
        editor.load(markdown: splitNote(text).body, notePath: path, compact: false)
    }

    func popOut(_ path: String? = nil) {
        guard let vault, let path = path ?? selected else { return }
        session?.flush()
        let meta = vault.notes().first { $0.path == path }?.sticky
        stickies.show(vault: vault, path: path, meta: meta, kind: options.stickyKind)
    }

    func flushAll() {
        session?.flush()
        stickies.flushAll()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { model.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.flushAll() }
    }
}

@main
struct ModoitSpikeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Modoit", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("스티키로 꺼내기") { delegate.model.popOut() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("저장 폴더 바꾸기…") { delegate.model.chooseVault() }
            }
        }
    }
}
