import ModoitCore
import ModoitKit
import SwiftUI
import WebKit

struct WelcomeView: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "note.text")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Modoit에 오신 것을 환영합니다").font(.title2.bold())
            Text("메모를 저장할 폴더를 먼저 정해 주세요.\n모든 메모는 이 폴더 안에 .md 파일로 저장됩니다.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("저장 폴더 선택…") { model.chooseVault() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("나중에 사이드바 아래에서 언제든 바꿀 수 있어요.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MainView: View {
    @Bindable var model: AppModel
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        Group {
            if model.vault == nil {
                WelcomeView(model: model)
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView(model: model)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                } content: {
                    NoteListView(model: model)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
                } detail: {
                    EditorPane(model: model)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Text(notice)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.notice)
    }
}

func stickyColor(_ name: String?) -> Color {
    switch name {
    case "pink": .pink
    case "blue": .blue
    case "green": .green
    case "purple": .purple
    default: .yellow
    }
}

struct NoteListView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.selectedNote }, set: { model.selectNote($0) })) {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.notes) { n in
                        NoteRow(note: n, sort: model.sort)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            // 끌기(onDrag)를 붙인 행은 목록의 기본 클릭 선택이 먹지 않는다. 직접 고른다
                            .onTapGesture { model.selectNote(n.path) }
                            .tag(n.path)
                            // 사이드바 폴더로 끌어 옮긴다 (FR-36)
                            .onDrag { DragPayload.note(n.path).provider }
                            .contextMenu {
                                Button(n.pinned ? "즐겨찾기에서 해제" : "즐겨찾기에 추가") { model.setFavorite(n.path, !n.pinned) }
                                Divider()
                                Button("휴지통으로", role: .destructive) { model.trash(note: n.path) }
                            }
                    }
                } header: {
                    if !group.title.isEmpty { Text(group.title) }
                }
            }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "검색")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("정렬", selection: Binding(get: { model.sort }, set: { model.setSort($0) })) {
                        Text("수정일순").tag(NoteSort.modified)
                        Text("만든 날짜순").tag(NoteSort.created)
                        Text("이름순").tag(NoteSort.name)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("정렬", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    model.newNote()
                } label: {
                    Label("새 메모", systemImage: "square.and.pencil")
                }
                .help("새 메모 (⌘N)")
            }
        }
        .overlay {
            if model.groups.isEmpty {
                Text(model.query.isEmpty ? "메모가 없습니다" : "찾는 메모가 없습니다").foregroundStyle(.secondary)
            }
        }
    }
}

struct NoteRow: View {
    let note: NoteMeta
    let sort: NoteSort

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if note.sticky?.open == true {
                    Circle().fill(stickyColor(note.sticky?.color)).frame(width: 8, height: 8)
                }
                Text(displayTitle(note)).font(.headline).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(shortDate(sortDate(note, sort)))
                Text(note.preview).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

struct EditorPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.saveFailing {
                Banner(text: "저장하지 못했습니다 — 다시 시도 중…", color: .red)
            }
            if !model.unsupported.isEmpty {
                Banner(text: "이 메모에는 Modoit이 지원하지 않는 서식(\(model.unsupported.joined(separator: ", ")))이 있어 읽기 전용으로 열었습니다.",
                       color: .orange, action: ("그래도 편집", { model.editAnyway() }))
            }
            if model.notUTF8 {
                Text("이 파일은 UTF-8이 아닌 인코딩이라 열 수 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let n = model.selectedMeta ?? model.session.map({ _ in nil }) ?? nil {
                Text(dateLine(n))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
            }
            WebEditorView(editor: model.editor)
                .opacity(model.selectedNote == nil || model.notUTF8 ? 0 : 1)
                .overlay {
                    if model.selectedNote == nil {
                        Text("메모를 고르거나 새로 만드세요").foregroundStyle(.secondary)
                    }
                }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.toggleFavoriteOfSelected()
                } label: {
                    Label("즐겨찾기", systemImage: model.selectedMeta?.pinned == true ? "star.fill" : "star")
                }
                .help("즐겨찾기 (⇧⌘P)")
                .disabled(model.selectedNote == nil)
                Button {
                    if let p = model.selectedNote { model.trash(note: p) }
                } label: {
                    Label("휴지통으로", systemImage: "trash")
                }
                .disabled(model.selectedNote == nil)
            }
        }
    }

    /// "만든 날 2026년 11월 7일 오후 5:22  ·  고친 날 오후 6:34" — 같은 날이면 고친 날은 시각만 (FR-47)
    private func dateLine(_ n: NoteMeta) -> String {
        let c = Date(timeIntervalSince1970: Double(n.created) / 1000)
        let m = Date(timeIntervalSince1970: Double(n.modified) / 1000)
        let full = DateFormatter()
        full.locale = Locale(identifier: "ko_KR")
        full.dateFormat = "yyyy년 M월 d일 a h:mm"
        let time = DateFormatter()
        time.locale = Locale(identifier: "ko_KR")
        time.dateFormat = "a h:mm"
        let sameDay = Calendar.current.isDate(c, inSameDayAs: m)
        return "만든 날 \(full.string(from: c))  ·  고친 날 \((sameDay ? time : full).string(from: m))"
    }
}

struct Banner: View {
    let text: String
    let color: Color
    var action: (String, () -> Void)?

    var body: some View {
        HStack {
            Text(text).font(.callout)
            Spacer()
            if let (title, run) = action { Button(title, action: run).buttonStyle(.link) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(color.opacity(0.14))
    }
}

struct WebEditorView: NSViewRepresentable {
    let editor: WebEditor
    func makeNSView(context: Context) -> WKWebView { editor.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
