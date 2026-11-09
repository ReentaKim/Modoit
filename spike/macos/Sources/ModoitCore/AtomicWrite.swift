import Foundation

public let tmpSuffix = ".modoit-tmp"

/// vault.rs `atomic_write_bytes`: 임시 파일에 쓰고 fsync 뒤 rename.
/// 원래 파일의 생성 시각을 옮겨 준다(FR-47).
public func atomicWrite(_ data: Data, to url: URL) throws {
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let created = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    let tmp = dir.appending(path: ".\(url.lastPathComponent).\(String(format: "%08x", UInt32.random(in: .min ... .max)))\(tmpSuffix)")
    do {
        guard fm.createFile(atPath: tmp.path, contents: nil) else { throw VaultError("임시 파일을 만들 수 없습니다") }
        let h = try FileHandle(forWritingTo: tmp)
        try h.write(contentsOf: data)
        try h.synchronize()
        try h.close()
        if let created { try fm.setAttributes([.creationDate: created], ofItemAtPath: tmp.path) }
        guard rename(tmp.path, url.path) == 0 else { throw VaultError(String(cString: strerror(errno))) }
    } catch {
        try? fm.removeItem(at: tmp)
        throw error
    }
}

public func atomicWrite(_ text: String, to url: URL) throws {
    try atomicWrite(Data(text.utf8), to: url)
}
