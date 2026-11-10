import Foundation

// 저장 폴더의 폴더 트리와 메모 목록. 옮겨 온 곳: src-tauri/src/vault.rs list_tree

public let defaultFolder = "메모"
public let attachmentsDir = "attachments"

public struct NoteMeta: Identifiable, Hashable, Sendable {
    public var id: String { path }
    /// 저장 폴더 기준 상대 경로
    public var path: String
    /// 들어 있는 폴더("" = 최상위)
    public var folder: String
    public var title: String
    public var preview: String
    /// 수정 시각(ms)
    public var modified: UInt64
    /// 파일 생성 시각(ms). 알 수 없으면 modified (FR-47)
    public var created: UInt64
    /// 즐겨찾기 (frontmatter `pinned`, FR-35)
    public var pinned: Bool
    public var sticky: StickyMeta?
    /// UTF-8이 아니면 false: 목록에는 보이되 열 수 없다 (BUG-19)
    public var readable: Bool

    public init(path: String, folder: String, title: String, preview: String, modified: UInt64, created: UInt64,
                pinned: Bool, sticky: StickyMeta?, readable: Bool) {
        self.path = path
        self.folder = folder
        self.title = title
        self.preview = preview
        self.modified = modified
        self.created = created
        self.pinned = pinned
        self.sticky = sticky
        self.readable = readable
    }
}

public struct FolderNode: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    /// 하위 메모의 가장 늦은 수정 시각(ms). 메모가 없으면 폴더 자체의 시각
    public var modified: UInt64
    public var children: [FolderNode]

    public init(path: String, name: String, modified: UInt64, children: [FolderNode]) {
        self.path = path
        self.name = name
        self.modified = modified
        self.children = children
    }
}

public struct Tree: Sendable {
    public var folders: [FolderNode]
    public var notes: [NoteMeta]
    public var layout: Layout

    public init(folders: [FolderNode] = [], notes: [NoteMeta] = [], layout: Layout = Layout()) {
        self.folders = folders
        self.notes = notes
        self.layout = layout
    }
}

func isAttachmentsName(_ name: String) -> Bool { name.lowercased() == attachmentsDir }

private func millis(_ d: Date?) -> UInt64? {
    guard let d, d.timeIntervalSince1970 >= 0 else { return nil }
    return UInt64(d.timeIntervalSince1970 * 1000)
}

private func modifiedMs(_ path: String) -> UInt64 {
    millis((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? 0
}

private func createdMs(_ path: String) -> UInt64? {
    millis((try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date)
}

/// 스칼라(코드 포인트) 순서. Rust의 `String` 비교와 같다
func scalarOrder(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
}

func noteMeta(vault: String, _ file: String) -> NoteMeta {
    let path = toRel(vault: vault, file)
    let modified = modifiedMs(file)
    var meta = NoteMeta(path: path, folder: parentRel(path), title: "", preview: "", modified: modified,
                        created: createdMs(file) ?? modified, pinned: false, sticky: nil, readable: false)
    guard let data = fm.contents(atPath: file) else { return meta }
    if let text = String(data: data, encoding: .utf8) {
        (meta.title, meta.preview) = titleAndPreview(text)
        let fields = readMeta(front: splitNote(text).front)
        meta.pinned = fields.pinned
        // v0.1 형식(최상위 color 등)은 아직 꺼낸 적 없는 일반 메모로 본다 (Brief 3.6-3)
        meta.sticky = fields.legacy ? nil : fields.sticky
        meta.readable = true
    } else {
        (meta.title, meta.preview) = titleAndPreview(String(decoding: data, as: UTF8.self))
    }
    return meta
}

private func walk(vault: String, dir: String, names: [String], notes: inout [NoteMeta]) -> [FolderNode] {
    var folders: [FolderNode] = []
    let top = dir.sameBytes(vault)
    for name in names where name.utf8.first != UInt8(ascii: ".") {
        let url = join(dir, name)
        switch entryKind(url) {
        case .directory:
            if top && isAttachmentsName(name) { continue }
            // 읽을 수 없는 폴더는 그 폴더만 건너뛴다 (BUG-07)
            guard let sub = entries(url) else { continue }
            let first = notes.count
            let children = walk(vault: vault, dir: url, names: sub, notes: &notes)
            // notes[first...]는 이 폴더 하위 트리의 메모 전부다
            let modified = notes[first...].map(\.modified).max() ?? modifiedMs(url)
            folders.append(FolderNode(path: toRel(vault: vault, url), name: name, modified: modified, children: children))
        case .file where isMarkdown(url):
            notes.append(noteMeta(vault: vault, url))
        default:
            break
        }
    }
    return folders.sorted { scalarOrder($0.name, $1.name) }
}

public func listTree(vault: String) throws -> Tree {
    guard let names = entries(vault) else { throw VaultError("저장 폴더를 읽을 수 없습니다: \(vault)") }
    var notes: [NoteMeta] = []
    let folders = walk(vault: vault, dir: vault, names: names, notes: &notes)
    notes.sort { $0.modified != $1.modified ? $0.modified > $1.modified : scalarOrder($0.path, $1.path) }
    return Tree(folders: folders, notes: notes, layout: loadLayout(vault: vault))
}
