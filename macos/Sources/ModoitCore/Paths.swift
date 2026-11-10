import Foundation

// 경로는 `String`으로 다룬다. `URL`과 `FileManager`의 만들기·쓰기 API는 한글 이름을 자모로 풀어(NFD)
// 디스크에 만든다. v0.x(Rust)는 받은 바이트 그대로(NFC) 만들고 바이트로 비교하므로,
// v2도 만들기·이름 바꾸기는 POSIX 호출로 하고 이름은 디스크에 있는 그대로 둔다 (NFR-16).

public struct VaultError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }

    /// UTF-8이 아닌 파일을 읽으려 했다 (BUG-19)
    public static let notUTF8 = VaultError("NOT_UTF8")

    static func errno(_ what: String) -> VaultError {
        VaultError("\(what): \(String(cString: strerror(Darwin.errno)))")
    }
}

var fm: FileManager { .default }

func join(_ dir: String, _ name: String) -> String {
    name.isEmpty ? dir : (dir.utf8.last == UInt8(ascii: "/") ? dir + name : dir + "/" + name)
}

/// 마지막 "/" 앞. 없으면 ""
func dirName(_ path: String) -> String { parentRel(path) }

/// 마지막 "/" 뒤
func baseName(_ path: String) -> String {
    let b = Array(path.utf8)
    guard let i = b.lastIndex(of: UInt8(ascii: "/")) else { return path }
    return String(decoding: b[(i + 1)...], as: UTF8.self)
}

func exists(_ path: String) -> Bool {
    var s = stat()
    return stat(path, &s) == 0
}

func isDirectory(_ path: String) -> Bool {
    var s = stat()
    return stat(path, &s) == 0 && s.st_mode & S_IFMT == S_IFDIR
}

enum EntryKind { case directory, file, other }

/// 심볼릭 링크를 따라가지 않고 종류를 본다 (Rust `DirEntry::file_type`)
func entryKind(_ path: String) -> EntryKind? {
    var s = stat()
    guard lstat(path, &s) == 0 else { return nil }
    switch s.st_mode & S_IFMT {
    case S_IFDIR: return .directory
    case S_IFREG: return .file
    default: return .other
    }
}

/// 두 경로가 같은 파일인가 (대소문자·유니코드 정규화만 다른 이름 포함)
func sameFile(_ a: String, _ b: String) -> Bool {
    var x = stat(), y = stat()
    guard stat(a, &x) == 0, stat(b, &y) == 0 else { return false }
    return x.st_dev == y.st_dev && x.st_ino == y.st_ino
}

/// 폴더 안의 이름들(디스크에 있는 그대로). 읽을 수 없으면 nil
func entries(_ dir: String) -> [String]? {
    try? fm.contentsOfDirectory(atPath: dir)
}

func canonical(_ path: String) -> String? {
    guard let p = realpath(path, nil) else { return nil }
    defer { free(p) }
    return String(cString: p)
}

func mkdirs(_ path: String) throws {
    if isDirectory(path) { return }
    let parent = dirName(path)
    if !parent.isEmpty, !parent.sameBytes(path) { try mkdirs(parent) }
    if mkdir(path, 0o755) != 0, Darwin.errno != EEXIST { throw VaultError.errno("폴더를 만들 수 없습니다") }
}

func move(_ from: String, _ to: String) throws {
    guard rename(from, to) == 0 else { throw VaultError.errno("옮길 수 없습니다") }
}

// MARK: - 저장 폴더 기준 경로

/// 상대 경로를 검증해 저장 폴더 안의 절대 경로로 바꾼다 (Brief 3.1-4).
/// 절대 경로, 빈 조각, `.`·`..`, 심볼릭 링크로 밖을 가리키는 경로를 막는다.
public func resolve(vault: String, _ rel: String) throws -> String {
    if rel.isEmpty || rel.utf8.first == UInt8(ascii: "/") { throw VaultError("잘못된 경로: \(rel)") }
    let parts = rel.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
    for p in parts where p.isEmpty || p.sameBytes(".") || p.sameBytes("..") {
        throw VaultError("허용되지 않는 경로: \(rel)")
    }
    let full = join(vault, rel)
    guard let base = canonical(vault) else { throw VaultError("저장 폴더를 찾을 수 없습니다: \(vault)") }
    var probe = full
    while entryKind(probe) == nil {
        let parent = dirName(probe)
        if parent.isEmpty || parent.sameBytes(probe) { break }
        probe = parent
    }
    guard let real = canonical(probe), real.sameBytes(base) || real.bytesHasPrefix(base + "/") else {
        throw VaultError("저장 폴더 밖의 경로: \(rel)")
    }
    return full
}

/// 폴더 경로("" = 저장 폴더 자체)를 검증한다. 있는 폴더여야 한다.
public func resolveDir(vault: String, _ rel: String) throws -> String {
    var r = rel
    while r.utf8.last == UInt8(ascii: "/") { r = String(decoding: r.utf8.dropLast(), as: UTF8.self) }
    let dir = rel.isEmpty ? vault : try resolve(vault: vault, r)
    guard isDirectory(dir) else { throw VaultError("폴더를 찾을 수 없습니다: \(rel)") }
    return dir
}

/// 저장 폴더 기준 상대 경로
public func toRel(vault: String, _ path: String) -> String {
    if path.sameBytes(vault) { return "" }
    let base = vault.utf8.last == UInt8(ascii: "/") ? vault : vault + "/"
    guard path.bytesHasPrefix(base) else { return path }
    return path.droppingBytes(base.utf8.count)
}

/// "a/b/c.md" → "a/b", "c.md" → ""
public func parentRel(_ rel: String) -> String {
    let b = Array(rel.utf8)
    guard let i = b.lastIndex(of: UInt8(ascii: "/")) else { return "" }
    return String(decoding: b[..<i], as: UTF8.self)
}

/// fromDir에서 target으로 가는 상대 경로 (둘 다 저장 폴더 기준)
public func relativePath(fromDir: String, to target: String) -> String {
    let from = fromDir.pathSegments
    let to = target.pathSegments
    var common = 0
    while common < from.count, common < to.count, from[common].sameBytes(to[common]) { common += 1 }
    let ups = Array(repeating: "..", count: from.count - common)
    return (ups + to[common...]).joined(separator: "/")
}

/// 파일 이름을 (이름, 확장자)로 나눈다. Rust `file_stem`·`extension`과 같다: ".숨김"은 확장자가 없다
func splitName(_ name: String) -> (stem: String, ext: String?) {
    let b = Array(name.utf8)
    guard let i = b.lastIndex(of: UInt8(ascii: ".")), i > 0 else { return (name, nil) }
    return (String(decoding: b[..<i], as: UTF8.self), String(decoding: b[(i + 1)...], as: UTF8.self))
}

func isMarkdown(_ path: String) -> Bool {
    splitName(baseName(path)).ext?.lowercased() == "md"
}

func hex(_ v: UInt64, width: Int) -> String {
    let s = String(v, radix: 16)
    return String(repeating: "0", count: max(0, width - s.count)) + s
}
