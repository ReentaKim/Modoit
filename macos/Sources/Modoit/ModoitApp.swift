import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 앱 상태. 창보다 먼저 만든다
    let model = AppModel()
    /// 닫힌 메인 창을 다시 여는 SwiftUI 동작. 메인 창이 처음 뜰 때 받아 둔다
    var reopenMain: (() -> Void)?

    override init() {
        super.init()
        model.showMainWindow = { [weak self] in self?.showMain() }
    }

    private var mainWindow: NSWindow? { NSApp.windows.first { $0.identifier?.rawValue == "main" } }

    /// 메인 창을 앞으로. 빨간 버튼으로 닫았어도 앱은 살아 있고 다시 열 수 있다 (FR-42)
    func showMain() {
        NSApp.activate()
        if let w = mainWindow {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            reopenMain?()
        }
    }

    /// 어떤 종료 경로에서도 저장을 마친 뒤 끝낸다 (F-12, Brief 3.2-7).
    /// ⌘Q, Dock 종료, 로그아웃·재시동, `brew upgrade` 모두 여기로 온다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = model.flushForQuit()
        if unsaved == 0 || model.quitForced { return .terminateNow }
        // 저장 못 한 메모가 있으면 한 번 멈추고 알린다. 다음 종료 요청은 그대로 끝낸다 (F-12 R-2)
        model.quitForced = true
        showMain()
        model.show(notice: "저장하지 못한 메모 \(unsaved)개가 있어 종료를 멈췄습니다. 한 번 더 종료하면 저장하지 않고 끝냅니다.", seconds: 10)
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock 아이콘을 누르면 메인 창을 보인다. 스티키만 떠 있을 때도 같다 (FR-42)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if mainWindow?.isVisible != true { showMain() }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // swift run 으로 띄워도 보통 앱처럼 창과 메뉴가 나오게
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if LaunchOptions.current.selfTest {
            // 창이 뜬 뒤에 시작한다
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [model] in SelfTest(model: model).run() }
        }
    }
}

/// 메인 창 안에서 "창 다시 열기" 동작을 받아 AppDelegate에 넘긴다
private struct ReopenCapture: ViewModifier {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { delegate.reopenMain = { openWindow(id: "main") } }
    }
}

@main
struct ModoitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        Window("Modoit", id: "main") {
            MainView(model: model)
                .frame(minWidth: 760, minHeight: 420)
                .modifier(ReopenCapture(delegate: delegate))
        }
        .defaultSize(width: 1080, height: 680)
        // 창 메뉴에 자동으로 생기는 "Modoit" 항목 대신 "메인 창"(⌘0)을 직접 둔다
        .commandsRemoved()

        Settings {
            SettingsView(model: model)
        }
        .commands { menus }
    }

    /// 메뉴 막대 (F-11 4장). 앱 메뉴·편집·창의 기본 항목은 macOS가 채운다
    @CommandsBuilder private var menus: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 메모") { model.menuNewNote() }
                .keyboardShortcut("n")
                .disabled(model.vault == nil)
            // 스티키는 M7에서 붙인다
            Button("새 스티키 메모") {}
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(true)
            Button("새 폴더") { model.menuNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model.vault == nil)
            Divider()
            Button("스티키로 꺼내기") {}
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(true)
            // 메인 창에서 고른 메모에 적용된다 (F-11 R-2)
            Button(model.selectedMeta?.pinned == true ? "즐겨찾기에서 해제" : "즐겨찾기에 추가") { model.toggleFavoriteOfSelected() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.selectedNote == nil)
            Divider()
            Button("저장 폴더 변경…") { model.menuChooseVault() }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("찾기") { model.menuFind() }
                .keyboardShortcut("f")
                .disabled(model.vault == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button("사이드바 보기·가리기") { model.menuToggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.vault == nil)
            // 설정 창 밖에서도 바로 바꾼다. 같은 설정에 저장한다 (F-10 R-2)
            Picker("모양", selection: Binding(get: { model.prefs.theme }, set: { v in model.updatePrefs { $0.theme = v } })) {
                Text("시스템 설정 따르기").tag("system")
                Text("라이트").tag("light")
                Text("다크").tag("dark")
            }
            Divider()
        }
        // 도움말에는 macOS의 메뉴 검색 칸만 둔다
        CommandGroup(replacing: .help) {}
        CommandGroup(before: .windowList) {
            Button("메인 창") { model.showMainWindow() }
                .keyboardShortcut("0")
            Divider()
        }
    }
}
