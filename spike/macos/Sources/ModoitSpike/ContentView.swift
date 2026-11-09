import ModoitCore
import SwiftUI
import WebKit

/// v0.3과 같은 3단 화면: 폴더 · 메모 목록 · 편집기
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.folder) {
                Label("모든 메모", systemImage: "tray.full").tag(allNotes as String?)
                Section("폴더") {
                    ForEach(model.folders, id: \.self) { f in
                        Label(f.split(separator: "/").last.map(String.init) ?? f, systemImage: "folder")
                            .padding(.leading, CGFloat(f.split(separator: "/").count - 1) * 12)
                            .tag(f as String?)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            List(model.notes, selection: $model.selected) { n in
                NoteRow(note: n)
                    .tag(n.path)
                    .contextMenu {
                        Button("스티키로 꺼내기") { model.popOut(n.path) }
                    }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .navigationTitle(model.folder == allNotes ? "모든 메모" : model.folder ?? "")
        } detail: {
            ZStack {
                if let editor = model.editor {
                    WebEditorView(editor: editor)
                        .opacity(model.selected == nil ? 0 : 1)
                }
                if model.selected == nil {
                    ContentUnavailableView("메모를 고르세요", systemImage: "note.text")
                }
            }
            .background(.background)
            .toolbar {
                Button("스티키로 꺼내기", systemImage: "rectangle.portrait.on.rectangle.portrait") { model.popOut() }
                    .disabled(model.selected == nil)
            }
        }
        .onChange(of: model.folder) { model.reload() }
        .onChange(of: model.selected) { model.openSelected() }
    }
}

private struct NoteRow: View {
    let note: NoteMeta
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(note.title).fontWeight(.semibold).lineLimit(1)
                if note.sticky?.open == true {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.yellow)
                }
            }
            HStack(spacing: 6) {
                Text(note.modified, format: .dateTime.month().day()).foregroundStyle(.secondary)
                Text(note.preview).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }
}

/// 메인 창의 편집기: 하나의 WKWebView를 메모마다 다시 쓴다
struct WebEditorView: NSViewRepresentable {
    let editor: WebEditor
    func makeNSView(context: Context) -> WKWebView { editor.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
