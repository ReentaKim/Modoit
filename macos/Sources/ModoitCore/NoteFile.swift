import Foundation

// 메모 파일 하나를 읽고 고치는 도구. 본문과 frontmatter를 따로 다룬다 (Brief 3.4).

/// 메모를 (frontmatter, 본문)으로 읽는다
public func readParts(vault: String, _ rel: String) throws -> NoteParts {
    splitNote(try readNote(vault: vault, rel))
}

/// 읽고 고친 뒤 바뀐 것이 있을 때만 쓴다. 쓴(또는 그대로인) 내용을 돌려준다
@discardableResult
public func updateNote(vault: String, _ rel: String, _ change: (inout NoteParts) -> Void) throws -> NoteParts {
    let src = try readNote(vault: vault, rel)
    var parts = splitNote(src)
    change(&parts)
    let next = joinNote(parts)
    if !next.sameBytes(src) { try atomicWrite(next, to: try resolve(vault: vault, rel)) }
    return parts
}

/// 즐겨찾기·스티키 정보만 고친다. 본문과 다른 키는 그대로다 (NFR-09)
public func patchMeta(vault: String, _ rel: String, _ patch: MetaPatch) throws {
    try updateNote(vault: vault, rel) { $0.front = writeMeta(front: $0.front, patch) }
}

/// 메모 파일이 있는가
public func noteExists(vault: String, _ rel: String) -> Bool {
    (try? resolve(vault: vault, rel)).map { entryKind($0) == .file } ?? false
}
