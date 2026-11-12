import Foundation

/// 감시기가 무시하는 임시 파일 꼬리표
public let tmpSuffix = ".modoit-tmp"

/// 임시 파일에 쓴 뒤 바꿔 끼운다. 쓰는 도중 앱이 죽어도 원본이 깨지지 않는다 (Brief 3.1-5).
/// 바꿔 끼우면 새 파일이 되므로 원래 생성 시각을 옮겨 준다 (FR-47).
public func atomicWrite(_ data: Data, to path: String) throws {
    let dir = dirName(path)
    try mkdirs(dir)
    let created = (try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date
    // 여러 곳에서 같은 파일을 동시에 써도 임시 파일이 섞이지 않게 이름에 임의값을 붙인다
    let tmp = join(dir, ".\(baseName(path)).\(hex(UInt64(UInt32.random(in: .min ... .max)), width: 8))\(tmpSuffix)")
    let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY, 0o644)
    guard fd >= 0 else { throw VaultError.errno("임시 파일을 만들 수 없습니다") }
    do {
        defer { close(fd) }
        try data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if Darwin.errno == EINTR { continue }
                    throw VaultError.errno("쓸 수 없습니다")
                }
                off += n
            }
        }
        if let created { try? fm.setAttributes([.creationDate: created], ofItemAtPath: tmp) }
        guard fsync(fd) == 0 else { throw VaultError.errno("쓸 수 없습니다") }
        try move(tmp, path)
    } catch {
        unlink(tmp)
        throw error
    }
}

public func atomicWrite(_ text: String, to path: String) throws {
    try atomicWrite(Data(text.utf8), to: path)
}
