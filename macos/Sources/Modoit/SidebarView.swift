import ModoitCore
import ModoitKit
import SwiftUI
import UniformTypeIdentifiers

/// 끌어 옮기는 것. 글자 한 줄로 실어 보낸다
enum DragPayload: Equatable {
    case folder(String)
    case separator(parent: String, id: String)
    case note(String)

    var text: String {
        switch self {
        case .folder(let p): "modoit-folder\n" + p
        case .separator(let parent, let id): "modoit-sep\n" + parent + "\n" + id
        case .note(let p): "modoit-note\n" + p
        }
    }

    init?(text: String) {
        let parts = text.components(separatedBy: "\n")
        switch parts.first {
        case "modoit-folder" where parts.count == 2: self = .folder(parts[1])
        case "modoit-sep" where parts.count == 3: self = .separator(parent: parts[1], id: parts[2])
        case "modoit-note" where parts.count == 2: self = .note(parts[1])
        default: return nil
        }
    }

    var provider: NSItemProvider { NSItemProvider(object: text as NSString) }
}

/// 놓을 자리: 행의 위쪽 = 그 앞, 가운데 = 폴더 안으로, 아래쪽 = 그 뒤 (F-03 4장)
enum DropZone: Equatable {
    case before, into, after
}

struct DropTarget: Equatable {
    var rowID: String
    var zone: DropZone
}

private let rowHeight: CGFloat = 26

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var drop: DropTarget?
    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var deleting: String?

    /// 이름을 묻는 중인 일
    enum Naming: Equatable {
        case create(parent: String)
        case rename(path: String)
    }

    var body: some View {
        List(selection: $model.selection) {
            Label("모든 메모", systemImage: "tray.full")
                .badge(model.tree.notes.count)
                .tag(SidebarSelection.all)
            // 모든 폴더의 즐겨찾기 메모만 (FR-54)
            Label("즐겨찾기", systemImage: "star")
                .badge(model.favoriteCount)
                .tag(SidebarSelection.favorites)

            Section {
                let rows = model.sidebarRows
                ForEach(rows) { row in
                    rowView(row, rows: rows)
                }
                // 맨 아래에 놓을 자리
                Color.clear
                    .frame(height: 10)
                    .overlay(alignment: .top) { if drop?.rowID == "__end" { insertionLine } }
                    .onDrop(of: [.plainText], delegate: RowDrop(rowID: "__end", allowInto: false, target: $drop) { payload, _ in
                        dropped(payload, parent: "", before: nil, into: false)
                    })
            } header: {
                HStack {
                    Text("폴더")
                    Spacer()
                    sortMenu
                }
            }

            if !model.openStickies.isEmpty {
                // 떠 있는 스티키만 (FR-31). v0.x의 "꺼내 둔 메모"
                Section("스티키 메모") {
                    ForEach(model.openStickies) { n in
                        Button {
                            model.selection = .all
                            model.selectNote(n.path)
                        } label: {
                            HStack {
                                Circle().fill(stickyColor(n.sticky?.color)).frame(width: 8, height: 8)
                                Text(displayTitle(n)).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .contextMenu {
            Button("새 폴더") { ask(.create(parent: "")) }
        }
        .safeAreaInset(edge: .bottom) {
            // 저장 폴더 이름. 누르면 폴더 변경 (FR-02)
            Button {
                model.chooseVault()
            } label: {
                Label(((model.vault ?? "") as NSString).lastPathComponent, systemImage: "externaldrive")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .help(model.vault ?? "")
        }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("폴더 이름", text: $nameText)
            Button("취소", role: .cancel) { naming = nil }
            Button(namingConfirm) { commitName() }
        }
        .alert("폴더 삭제", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { path in
            Button("취소", role: .cancel) {}
            Button("휴지통으로 이동", role: .destructive) { model.trashFolder(path) }
        } message: { path in
            Text("\"\((path as NSString).lastPathComponent)\" 폴더와 안의 메모 \(model.noteCount(under: path))개를 휴지통으로 옮길까요?")
        }
    }

    // MARK: 행

    @ViewBuilder
    private func rowView(_ row: SidebarRow, rows: [SidebarRow]) -> some View {
        switch row.kind {
        case .separator(let id):
            Divider()
                .padding(.leading, CGFloat(row.depth) * 14)
                .frame(height: 12)
                .contentShape(Rectangle())
                .overlay(alignment: drop?.zone == .after ? .bottom : .top) { if drop?.rowID == row.id { insertionLine } }
                .onDrag { DragPayload.separator(parent: row.parent, id: id).provider }
                .onDrop(of: [.plainText], delegate: RowDrop(rowID: row.id, allowInto: false, target: $drop) { payload, zone in
                    dropped(payload, parent: row.parent, before: zone == .after ? keyAfter(row, rows) : id, into: false)
                })
                .contextMenu {
                    Button("구분선 삭제") { model.setLayout(removeKey(model.tree.layout, parent: row.parent, key: id)) }
                }
        case .folder(let path, let name, let hasChildren, let expanded):
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .opacity(hasChildren ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if expanded { model.collapsed.insert(path) } else { model.collapsed.remove(path) }
                    }
                Label(name, systemImage: "folder")
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(row.depth) * 14)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            // 끌기(onDrag)를 붙인 행은 목록의 기본 클릭 선택이 먹지 않는다. 직접 고른다
            .onTapGesture { model.selection = .folder(path) }
            .badge(model.count(in: path))
            .tag(SidebarSelection.folder(path))
            .listRowBackground(drop == DropTarget(rowID: row.id, zone: .into) ? Color.accentColor.opacity(0.25) : nil)
            .overlay(alignment: drop?.zone == .after ? .bottom : .top) {
                if drop?.rowID == row.id, drop?.zone != .into { insertionLine }
            }
            .onDrag { DragPayload.folder(path).provider }
            .onDrop(of: [.plainText], delegate: RowDrop(rowID: row.id, allowInto: true, target: $drop) { payload, zone in
                switch zone {
                case .into: dropped(payload, parent: path, before: nil, into: true)
                case .before: dropped(payload, parent: row.parent, before: name, into: false)
                case .after: dropped(payload, parent: row.parent, before: keyAfter(row, rows), into: false)
                }
            })
            .contextMenu {
                Button("새 하위 폴더") { ask(.create(parent: path)) }
                Button("이름 변경") { ask(.rename(path: path), initial: name) }
                Button("아래에 구분선 추가") {
                    model.setLayout(addSeparator(model.tree.folders, model.tree.layout, parent: row.parent, after: name))
                }
                Divider()
                Button("휴지통으로 이동", role: .destructive) {
                    // 메모가 있으면 확인한다 (FR-26)
                    if model.noteCount(under: path) > 0 { deleting = path } else { model.trashFolder(path) }
                }
            }
        }
    }

    private var insertionLine: some View {
        Rectangle().fill(Color.accentColor).frame(height: 2)
    }

    /// 같은 부모 안에서 이 행 바로 다음 항목의 키. 없으면 nil(맨 뒤)
    private func keyAfter(_ row: SidebarRow, _ rows: [SidebarRow]) -> String? {
        let siblings = rows.filter { $0.parent == row.parent && $0.depth == row.depth }
        guard let i = siblings.firstIndex(of: row), i + 1 < siblings.count else { return nil }
        switch siblings[i + 1].kind {
        case .folder(_, let name, _, _): return name
        case .separator(let id): return id
        }
    }

    private func dropped(_ payload: DragPayload, parent: String, before: String?, into: Bool) {
        switch payload {
        case .folder(let path):
            // 제자리 앞에 놓은 것은 아무 일도 아니다
            if !into, parentRel(path) == parent, before == (path as NSString).lastPathComponent { return }
            model.moveFolder(path, toParent: parent, before: before, into: into)
        case .separator(let from, let id):
            // 구분선은 폴더 안으로 넣지 않는다. 폴더 위에 놓으면 그 폴더의 형제로 둔다
            if before == id { return }
            model.moveSeparator(id, from: from, toParent: into ? parentRel(parent) : parent, before: into ? nil : before)
        case .note(let path):
            // 메모는 폴더 위에 놓을 때만 옮긴다 (FR-36)
            if into { model.moveNote(path, toFolder: parent) }
        }
    }

    // MARK: 정렬·이름

    private var sortMenu: some View {
        Menu {
            Picker("정렬", selection: Binding(get: { model.tree.layout.sort }, set: { s in
                var l = model.tree.layout
                l.sort = s
                model.setLayout(l)
            })) {
                Text("직접 정렬").tag(SortMode.custom)
                Text("이름순").tag(SortMode.name)
                Text("최신순").tag(SortMode.recent)
            }
            .pickerStyle(.inline)
            Divider()
            Button("새 폴더") { ask(.create(parent: "")) }
            Button("맨 아래에 구분선 추가") {
                let last = displaySequence(parent: "", model.tree.folders, model.tree.layout).last?.key ?? ""
                model.setLayout(addSeparator(model.tree.folders, model.tree.layout, parent: "", after: last))
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("정렬, 새 폴더")
    }

    private func ask(_ what: Naming, initial: String = "") {
        nameText = initial
        naming = what
    }

    private var namingTitle: String {
        if case .rename = naming { return "폴더 이름 변경" }
        return "새 폴더"
    }

    private var namingConfirm: String {
        if case .rename = naming { return "변경" }
        return "만들기"
    }

    private func commitName() {
        let name = nameText
        switch naming {
        case .create(let parent): model.createFolder(parent: parent, name: name)
        case .rename(let path): model.renameFolder(path, to: name)
        case nil: break
        }
        naming = nil
    }
}

/// 행 하나에 끌어 놓기. 세로 위치로 앞·안·뒤를 가른다
private struct RowDrop: DropDelegate {
    let rowID: String
    let allowInto: Bool
    @Binding var target: DropTarget?
    let perform: (DragPayload, DropZone) -> Void

    private func zone(_ info: DropInfo) -> DropZone {
        guard allowInto else { return info.location.y > 6 && rowID != "__end" ? .after : .before }
        let y = info.location.y
        if y < rowHeight * 0.25 { return .before }
        if y > rowHeight * 0.75 { return .after }
        return .into
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

    func dropEntered(info: DropInfo) { target = DropTarget(rowID: rowID, zone: zone(info)) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let t = DropTarget(rowID: rowID, zone: zone(info))
        if target != t { target = t }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if target?.rowID == rowID { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let z = zone(info)
        target = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let text = obj as? String, let payload = DragPayload(text: text) else { return }
            DispatchQueue.main.async { perform(payload, z) }
        }
        return true
    }
}
