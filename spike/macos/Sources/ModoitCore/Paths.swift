import Foundation

public struct VaultError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// vault.rs `resolve`: 상대 경로를 검증해 저장 폴더 안의 절대 경로로 바꾼다.
/// 절대 경로, `.`/`..`, 빈 경로, 심볼릭 링크로 밖을 가리키는 경로를 막는다.
public func resolve(vault: URL, _ rel: String) throws -> URL {
    if rel.isEmpty || rel.hasPrefix("/") { throw VaultError("잘못된 경로: \(rel)") }
    let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
    for p in parts where p.isEmpty || p == "." || p == ".." {
        throw VaultError("허용되지 않는 경로: \(rel)")
    }
    let full = vault.appending(path: rel)
    let base = vault.resolvingSymlinksInPath().standardizedFileURL.path
    var probe = full
    while !FileManager.default.fileExists(atPath: probe.path) {
        let parent = probe.deletingLastPathComponent()
        if parent.path == probe.path { break }
        probe = parent
    }
    let real = probe.resolvingSymlinksInPath().standardizedFileURL.path
    if real != base && !real.hasPrefix(base + "/") {
        throw VaultError("저장 폴더 밖의 경로: \(rel)")
    }
    return full
}

/// "a/b/c.md" → "a/b", "c.md" → ""
public func parentRel(_ rel: String) -> String {
    guard let i = rel.lastIndex(of: "/") else { return "" }
    return String(rel[..<i])
}

/// vault.rs `relative_path`: fromDir에서 target으로 가는 상대 경로 (둘 다 저장 폴더 기준)
public func relativePath(fromDir: String, to target: String) -> String {
    let from = fromDir.split(separator: "/")
    let to = target.split(separator: "/")
    var common = 0
    while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
    let ups = Array(repeating: "..", count: from.count - common)
    return (ups + to[common...].map(String.init)).joined(separator: "/")
}

/// 저장 폴더 기준 상대 경로
public func toRel(vault: URL, _ url: URL) -> String {
    let base = vault.standardizedFileURL.path
    let p = url.standardizedFileURL.path
    guard p.hasPrefix(base + "/") else { return p }
    return String(p.dropFirst(base.count + 1))
}
