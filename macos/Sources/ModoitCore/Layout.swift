import Foundation

// 사이드바 직접 정렬 순서와 구분선 (`.modoit/layout.json`).
// 폴더는 실제 디렉터리라서 순서를 담을 곳이 따로 필요하다. 파일이 없거나 깨졌으면 기본값으로 동작한다.
// 옮겨 온 곳: src-tauri/src/layout.rs

public let metaDir = ".modoit"
private let layoutFile = "layout.json"

public enum SortMode: String, Codable, Sendable {
    case custom, name, recent
}

public struct Layout: Equatable, Codable, Sendable {
    public var sort: SortMode = .custom
    /// 부모 폴더 경로("" = 최상위) → 하위 폴더 이름 또는 구분선 id("sep:…")의 순서
    public var order: [String: [String]] = [:]

    public init(sort: SortMode = .custom, order: [String: [String]] = [:]) {
        self.sort = sort
        self.order = order
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sort = try c.decodeIfPresent(SortMode.self, forKey: .sort) ?? .custom
        order = try c.decodeIfPresent([String: [String]].self, forKey: .order) ?? [:]
    }

    /// 폴더 이름 변경·이동(from → to)을 반영한다.
    /// 그 폴더와 하위 폴더의 키를 옮기고, 부모 순서 목록의 이름을 고친다.
    public mutating func moveDir(from: String, to: String) {
        for k in order.keys.filter({ isSelfOrUnder($0, from) }) {
            if let v = order.removeValue(forKey: k) {
                order[to + k.droppingBytes(from.utf8.count)] = v
            }
        }
        let (fromParent, fromName) = splitParent(from)
        let (toParent, toName) = splitParent(to)
        if fromParent.sameBytes(toParent) {
            if let list = order[fromParent] {
                order[fromParent] = list.map { $0.sameBytes(fromName) ? toName : $0 }
            }
        } else {
            order[fromParent]?.removeAll { $0.sameBytes(fromName) }
            // 새 부모에 직접 정렬 목록이 있으면 맨 뒤에 붙여 둔다
            if let list = order[toParent], !list.contains(where: { $0.sameBytes(toName) }) {
                order[toParent] = list + [toName]
            }
        }
    }

    /// 폴더 삭제를 반영한다. 그 폴더와 하위 키, 부모 목록의 이름을 지운다.
    public mutating func removeDir(_ rel: String) {
        for k in order.keys where isSelfOrUnder(k, rel) { order.removeValue(forKey: k) }
        let (parent, name) = splitParent(rel)
        order[parent]?.removeAll { $0.sameBytes(name) }
    }
}

/// "a/b/c" → ("a/b", "c"), "c" → ("", "c")
private func splitParent(_ rel: String) -> (String, String) {
    let parent = parentRel(rel)
    return (parent, parent.isEmpty ? rel : rel.droppingBytes(parent.utf8.count + 1))
}

private func isSelfOrUnder(_ key: String, _ dir: String) -> Bool {
    key.sameBytes(dir) || key.bytesHasPrefix(dir + "/")
}

func layoutPath(vault: String) -> String { join(join(vault, metaDir), layoutFile) }

public func loadLayout(vault: String) -> Layout {
    guard let data = fm.contents(atPath: layoutPath(vault: vault)),
          let l = try? JSONDecoder().decode(Layout.self, from: data) else { return Layout() }
    return l
}

public func saveLayout(vault: String, _ layout: Layout) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try atomicWrite(try enc.encode(layout), to: layoutPath(vault: vault))
}

/// 읽고 고친 뒤 바뀐 것이 있을 때만 쓴다(없던 파일을 괜히 만들지 않는다).
public func updateLayout(vault: String, _ change: (inout Layout) -> Void) throws {
    var layout = loadLayout(vault: vault)
    let before = layout
    change(&layout)
    if layout != before { try saveLayout(vault: vault, layout) }
}
