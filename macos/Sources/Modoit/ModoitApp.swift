import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 앱 상태. 창보다 먼저 만든다
    let model = AppModel()

    /// 어떤 종료 경로에서도 저장을 마친 뒤 끝낸다 (F-12, Brief 3.2-7).
    /// ⌘Q, Dock 종료, 로그아웃·재시동, `brew upgrade` 모두 여기로 온다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = model.flushForQuit()
        if unsaved == 0 || model.quitForced { return .terminateNow }
        // 저장 못 한 메모가 있으면 한 번 멈추고 알린다. 다음 종료 요청은 그대로 끝낸다 (F-12 R-2)
        model.quitForced = true
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        model.show(notice: "저장하지 못한 메모 \(unsaved)개가 있어 종료를 멈췄습니다. 한 번 더 종료하면 저장하지 않고 끝냅니다.", seconds: 10)
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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

@main
struct ModoitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        Window("Modoit", id: "main") {
            MainView(model: model)
                .frame(minWidth: 760, minHeight: 420)
        }
        .defaultSize(width: 1080, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("새 메모") { model.newNote() }
                    .keyboardShortcut("n")
                    .disabled(model.vault == nil)
                Divider()
                Button("즐겨찾기에 추가·해제") { model.toggleFavoriteOfSelected() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.selectedNote == nil)
                Divider()
                Button("저장 폴더 변경…") { model.chooseVault() }
            }
        }
    }
}
