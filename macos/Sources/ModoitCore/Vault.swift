import Foundation

// 메모·폴더 만들기, 이름 맞추기, 옮기기, 휴지통. 옮겨 온 곳: src-tauri/src/vault.rs

// MARK: - 이름

/// from을 to로 옮긴다. to가 from과 같은 파일(대소문자나 정규화만 다른 이름)이면
/// 임시 이름을 거쳐 바꾼다 (BUG-14). 다른 파일이 이미 있으면 오류.
func renameEntry(_ from: String, _ to: String) throws {
    if from.sameBytes(to) { return }
    if sameFile(from, to) {
        let tmp = join(dirName(from), ".modoit-rename-\(hex(UInt64.random(in: .min ... .max), width: 16))\(tmpSuffix)")
        try move(from, tmp)
        do {
            try move(tmp, to)
        } catch {
            try? move(tmp, from)
            throw error
        }
        return
    }
    if exists(to) { throw VaultError("이미 같은 이름이 있습니다: \(to)") }
    try move(from, to)
}

/// dir 안에서 겹치지 않는 "<base>.<ext>", "<base> 2.<ext>" … 경로.
/// own과 같은 파일이면 비어 있는 것으로 본다(자기 자신의 이름 바꾸기).
func uniqueFile(_ dir: String, _ base: String, _ ext: String, own: String? = nil) -> String {
    var n = 1
    while true {
        let candidate = join(dir, n == 1 ? "\(base).\(ext)" : "\(base) \(n).\(ext)")
        if !exists(candidate) || own.map({ sameFile($0, candidate) }) == true { return candidate }
        n += 1
    }
}

/// 폴더용. 저장 폴더 바로 아래에서는 `attachments`를 예약 이름으로 본다.
func uniqueDir(_ dir: String, _ base: String, own: String? = nil, topLevel: Bool) -> String {
    var n = 1
    while true {
        let name = n == 1 ? base : "\(base) \(n)"
        let candidate = join(dir, name)
        let reserved = topLevel && isAttachmentsName(name)
        if !reserved && (!exists(candidate) || own.map({ sameFile($0, candidate) }) == true) { return candidate }
        n += 1
    }
}

/// 시스템 휴지통으로 보낸다 (Brief 3.3-1)
public func trashPath(_ path: String) throws {
    do {
        try fm.trashItem(at: Foundation.URL(fileURLWithPath: path), resultingItemURL: nil)
    } catch {
        throw VaultError(error.localizedDescription)
    }
}

// MARK: - 메모

public func readNote(vault: String, _ rel: String) throws -> String {
    let url = try resolve(vault: vault, rel)
    guard let data = fm.contents(atPath: url) else { throw VaultError("메모를 읽을 수 없습니다: \(rel)") }
    guard let text = String(data: data, encoding: .utf8) else { throw VaultError.notUTF8 }
    return text
}

/// folder가 ""이면 `메모/`에 만들고, 그 폴더가 없으면 만든다 (BUG-08).
public func createNote(vault: String, folder: String) throws -> String {
    let dir: String
    if folder.isEmpty {
        dir = join(vault, defaultFolder)
        try mkdirs(dir)
    } else {
        dir = try resolveDir(vault: vault, folder)
    }
    let url = uniqueFile(dir, untitled, "md")
    try atomicWrite("", to: url)
    return toRel(vault: vault, url)
}

/// 디스크 내용의 제목으로 파일 이름을 맞춘다. 새 상대 경로를 돌려준다.
public func syncNoteName(vault: String, _ rel: String) throws -> String {
    let from = try resolve(vault: vault, rel)
    let rel = toRel(vault: vault, from)
    let base = fileBase(extractTitle(try readNote(vault: vault, rel)))
    let (stem, ext) = splitName(baseName(from))
    if stem.sameBytes(base) { return rel }
    let to = uniqueFile(dirName(from), base, ext ?? "md", own: from)
    if to.sameBytes(from) { return rel }
    try renameEntry(from, to)
    return toRel(vault: vault, to)
}

// MARK: - 폴더

public func createFolder(vault: String, parent: String, name: String) throws -> String {
    let name = try folderName(name)
    let pdir = try resolveDir(vault: vault, parent)
    let url = uniqueDir(pdir, name, topLevel: pdir.sameBytes(vault))
    guard mkdir(url, 0o755) == 0 else { throw VaultError.errno("폴더를 만들 수 없습니다") }
    return toRel(vault: vault, url)
}

public func renameFolder(vault: String, _ rel: String, to name: String) throws -> String {
    let from = try resolveDir(vault: vault, rel)
    if from.sameBytes(vault) { throw VaultError("저장 폴더 자체는 이름을 바꿀 수 없습니다") }
    let rel = toRel(vault: vault, from)
    let name = try folderName(name)
    if baseName(from).sameBytes(name) { return rel }
    let pdir = dirName(from)
    let to = uniqueDir(pdir, name, own: from, topLevel: pdir.sameBytes(vault))
    if to.sameBytes(from) { return rel }
    try renameEntry(from, to)
    let newRel = toRel(vault: vault, to)
    try updateLayout(vault: vault) { $0.moveDir(from: rel, to: newRel) }
    return newRel
}

public func trashFolder(vault: String, _ rel: String) throws {
    let dir = try resolveDir(vault: vault, rel)
    if dir.sameBytes(vault) { throw VaultError("저장 폴더 자체는 지울 수 없습니다") }
    let rel = toRel(vault: vault, dir)
    try trashPath(dir)
    try updateLayout(vault: vault) { $0.removeDir(rel) }
}

// MARK: - 옮기기

public struct Moved: Equatable, Sendable {
    public var from: String
    public var to: String
    public var isDir: Bool
}

private func markdownFiles(under dir: String) -> [String] {
    var out: [String] = []
    for name in entries(dir) ?? [] {
        let url = join(dir, name)
        switch entryKind(url) {
        case .directory: out += markdownFiles(under: url)
        case .file where isMarkdown(url): out.append(url)
        default: break
        }
    }
    return out
}

/// 파일이나 폴더를 다른 폴더로 옮긴다. 옮겨진 .md의 상대 링크를 다시 계산한다 (FR-36).
public func moveEntry(vault: String, from: String, toFolder: String) throws -> Moved {
    let src = try resolve(vault: vault, from)
    guard let kind = entryKind(src) else { throw VaultError("찾을 수 없습니다: \(from)") }
    let fromRel = toRel(vault: vault, src)
    let destDir = try resolveDir(vault: vault, toFolder)
    let destRel = toRel(vault: vault, destDir)
    let isDir = kind == .directory
    if isDir && (destRel.sameBytes(fromRel) || destRel.bytesHasPrefix(fromRel + "/")) {
        throw VaultError("폴더를 자기 자신이나 하위 폴더로 옮길 수 없습니다")
    }
    if parentRel(fromRel).sameBytes(destRel) { return Moved(from: fromRel, to: fromRel, isDir: isDir) }

    let name = baseName(src)
    let dst: String
    if isDir {
        dst = uniqueDir(destDir, name, topLevel: destDir.sameBytes(vault))
    } else {
        let (stem, ext) = splitName(name)
        dst = ext.map { uniqueFile(destDir, stem, $0) } ?? uniqueDir(destDir, stem, topLevel: false)
    }
    let toRelPath = toRel(vault: vault, dst)

    // 옮기기 전에 새 내용을 계산해 둔다(옮긴 뒤 새 위치에 쓴다)
    var rewrites: [(String, String)] = []
    func plan(_ oldFile: String) {
        let newFile = toRelPath + oldFile.droppingBytes(fromRel.utf8.count)
        guard let content = try? readNote(vault: vault, oldFile) else { return }
        let next = rewriteLinks(content, oldDir: parentRel(oldFile), newDir: parentRel(newFile), moved: (fromRel, toRelPath))
        if !next.sameBytes(content) { rewrites.append((newFile, next)) }
    }
    if isDir {
        for f in markdownFiles(under: src) { plan(toRel(vault: vault, f)) }
    } else if isMarkdown(src) {
        plan(fromRel)
    }

    try renameEntry(src, dst)
    for (rel, content) in rewrites {
        do {
            try atomicWrite(content, to: join(vault, rel))
        } catch {
            FileHandle.standardError.write(Data("링크 고치기 실패 \(rel): \(error)\n".utf8))
        }
    }
    if isDir { try updateLayout(vault: vault) { $0.moveDir(from: fromRel, to: toRelPath) } }
    return Moved(from: fromRel, to: toRelPath, isDir: isDir)
}
