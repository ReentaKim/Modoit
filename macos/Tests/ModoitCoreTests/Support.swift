import Foundation
@testable import ModoitCore

/// 임시 저장 폴더의 절대 경로
func tempVault() throws -> String {
    // /var → /private/var 같은 심볼릭 링크를 미리 풀어 둔다
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let p = join(base, "modoit-test-\(UUID().uuidString)")
    try mkdirs(p)
    return p
}

func write(_ v: String, _ rel: String, _ text: String) throws {
    try atomicWrite(text, to: join(v, rel))
}

func read(_ v: String, _ rel: String) throws -> String {
    try String(contentsOfFile: join(v, rel), encoding: .utf8)
}

func mkdir(_ v: String, _ rel: String) throws {
    try mkdirs(join(v, rel))
}

/// 숨김 파일을 뺀 이름들(정렬). 디스크에 있는 바이트 그대로다
func namesIn(_ dir: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir).filter { !$0.hasPrefix(".") }.sorted(by: scalarOrder)
}

func isDir(_ path: String) -> Bool { isDirectory(path) }

func occurrences(of needle: String, in s: String) -> Int {
    s.components(separatedBy: needle).count - 1
}
