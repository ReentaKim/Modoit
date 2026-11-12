import Foundation
import ModoitCore

// 사이드바 폴더 트리의 화면 순서 (FR-26~29). 순수 함수다. 옮겨 온 곳: src/lib/sidebar.ts

public enum SidebarItem: Equatable, Sendable {
    case folder(FolderNode)
    case separator(String)

    /// layout.json에 적는 이름: 폴더 이름 또는 구분선 id
    public var key: String {
        switch self {
        case .folder(let n): n.name
        case .separator(let id): id
        }
    }
}

public struct SidebarRow: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case folder(path: String, name: String, hasChildren: Bool, expanded: Bool)
        case separator(id: String)
    }
    public var kind: Kind
    public var parent: String
    public var depth: Int
    public var id: String {
        switch kind {
        case .folder(let path, _, _, _): "f:" + path
        case .separator(let sid): "s:" + parent + "/" + sid
        }
    }
}

public func isSeparatorKey(_ s: String) -> Bool { s.hasPrefix("sep:") }

/// 한국어 이름순(숫자는 크기대로). JS `localeCompare(…, "ko", { numeric: true })`
public func nameOrder(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.numeric], range: nil, locale: Locale(identifier: "ko")) == .orderedAscending
}

/// 직접 정렬 순서: layout.order에 있는 것 먼저, 나머지는 이름순으로 뒤에
public func customSequence(parent: String, _ nodes: [FolderNode], _ layout: Layout) -> [SidebarItem] {
    var used = Set<String>()
    var seq: [SidebarItem] = []
    for key in layout.order[parent] ?? [] {
        if isSeparatorKey(key) {
            seq.append(.separator(key))
        } else if !used.contains(key), let n = nodes.first(where: { $0.name == key }) {
            seq.append(.folder(n))
            used.insert(key)
        }
    }
    for n in nodes.sorted(by: { nameOrder($0.name, $1.name) }) where !used.contains(n.name) { seq.append(.folder(n)) }
    return seq
}

/// 화면 순서: 구분선으로 나뉜 구역 안에서만 정렬한다 (FR-29)
public func displaySequence(parent: String, _ nodes: [FolderNode], _ layout: Layout) -> [SidebarItem] {
    let seq = customSequence(parent: parent, nodes, layout)
    if layout.sort == .custom { return seq }
    var out: [SidebarItem] = []
    var section: [FolderNode] = []
    func flush() {
        let sorted = section.sorted { a, b in
            if layout.sort == .recent, a.modified != b.modified { return a.modified > b.modified }
            return nameOrder(a.name, b.name)
        }
        out += sorted.map(SidebarItem.folder)
        section = []
    }
    for it in seq {
        switch it {
        case .separator: flush(); out.append(it)
        case .folder(let n): section.append(n)
        }
    }
    flush()
    return out
}

/// 펼친 상태를 반영해 한 줄씩 펼쳐 놓은 목록
public func flattenTree(_ folders: [FolderNode], _ layout: Layout, collapsed: Set<String>) -> [SidebarRow] {
    var rows: [SidebarRow] = []
    func walk(_ parent: String, _ nodes: [FolderNode], _ depth: Int) {
        for it in displaySequence(parent: parent, nodes, layout) {
            switch it {
            case .separator(let id):
                rows.append(SidebarRow(kind: .separator(id: id), parent: parent, depth: depth))
            case .folder(let n):
                let expanded = !collapsed.contains(n.path)
                rows.append(SidebarRow(kind: .folder(path: n.path, name: n.name, hasChildren: !n.children.isEmpty, expanded: expanded),
                                       parent: parent, depth: depth))
                if expanded { walk(n.path, n.children, depth + 1) }
            }
        }
    }
    walk("", folders, 0)
    return rows
}

public func findNode(_ folders: [FolderNode], _ path: String) -> FolderNode? {
    for n in folders {
        if n.path == path { return n }
        if path.hasPrefix(n.path + "/") { return findNode(n.children, path) }
    }
    return nil
}

public func childrenOf(_ folders: [FolderNode], parent: String) -> [FolderNode] {
    parent.isEmpty ? folders : findNode(folders, parent)?.children ?? []
}

/// parent 안의 순서에서 key를 빼고 beforeKey 앞(nil이면 맨 뒤)에 넣은 새 layout.
/// 정렬 방식이 이름순·최신순이었다면, 보던 화면 순서를 모든 부모에 고정한 뒤 직접 정렬로 바꾼다.
/// - into: 다른 폴더 위에 놓아 '안으로' 옮긴 경우. 순서를 정한 것이 아니므로 정렬 방식을 유지한다 (BUG-33, 45)
public func reorder(_ folders: [FolderNode], _ layout: Layout, parent: String, key: String, before: String?, into: Bool = false) -> Layout {
    if into && layout.sort != .custom { return layout }
    var order = layout.order
    if layout.sort != .custom {
        func fix(_ p: String, _ nodes: [FolderNode]) {
            order[p] = displaySequence(parent: p, nodes, layout).map(\.key)
            for n in nodes { fix(n.path, n.children) }
        }
        fix("", folders)
    }
    let base = layout.sort == .custom
        ? customSequence(parent: parent, childrenOf(folders, parent: parent), Layout(sort: layout.sort, order: order)).map(\.key)
        : order[parent] ?? []
    var list = base.filter { $0 != key }
    let at = before.flatMap { list.firstIndex(of: $0) } ?? list.count
    list.insert(key, at: at)
    order[parent] = list
    return Layout(sort: .custom, order: order)
}

/// parent 안 afterKey 바로 뒤에 새 구분선
public func addSeparator(_ folders: [FolderNode], _ layout: Layout, parent: String, after: String,
                         id: String = "sep:" + String(UUID().uuidString.prefix(6)).lowercased()) -> Layout {
    var seq = customSequence(parent: parent, childrenOf(folders, parent: parent), layout).map(\.key)
    let at = seq.firstIndex(of: after).map { $0 + 1 } ?? seq.count
    seq.insert(id, at: at)
    var l = layout
    l.order[parent] = seq
    return l
}

public func removeKey(_ layout: Layout, parent: String, key: String) -> Layout {
    var l = layout
    l.order[parent] = (layout.order[parent] ?? []).filter { $0 != key }
    return l
}
