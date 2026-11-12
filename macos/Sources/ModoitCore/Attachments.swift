import Foundation

// 붙여넣은 이미지를 `저장폴더/attachments/`에 저장한다 (F-06 R-5, NFR-10).
// 옮겨 온 곳: src-tauri/src/vault.rs save_attachment

public let attachmentMaxBytes = 20 * 1024 * 1024
public let attachmentExts = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"]

private func localTimestamp() -> String {
    let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
    func p(_ v: Int?, _ w: Int) -> String {
        let s = String(v ?? 0)
        return String(repeating: "0", count: max(0, w - s.count)) + s
    }
    return p(c.year, 4) + p(c.month, 2) + p(c.day, 2) + "-" + p(c.hour, 2) + p(c.minute, 2) + p(c.second, 2)
}

/// 이미지 바이트를 저장하고 메모 기준 상대 링크를 돌려준다.
public func saveAttachment(vault: String, notePath: String, fileName: String, data: Data) throws -> String {
    let note = try resolve(vault: vault, notePath)
    let ext = splitName(fileName).ext?.lowercased() ?? ""
    guard attachmentExts.contains(ext) else { throw VaultError("지원하지 않는 이미지 형식입니다: \(fileName)") }
    if data.count > attachmentMaxBytes { throw VaultError("이미지가 20MB를 넘습니다") }
    if data.isEmpty { throw VaultError("빈 이미지입니다") }
    let dir = join(vault, attachmentsDir)
    let stamp = localTimestamp()
    var target: String?
    for _ in 0..<64 {
        let u = join(dir, "\(stamp)-\(hex(UInt64(UInt16.random(in: .min ... .max)), width: 4)).\(ext)")
        if !exists(u) { target = u; break }
    }
    guard let target else { throw VaultError("이미지 이름을 만들 수 없습니다") }
    try atomicWrite(data, to: target)
    return relativePath(fromDir: parentRel(toRel(vault: vault, note)), to: toRel(vault: vault, target))
}

/// base64(또는 "data:image/png;base64,…") 문자열로 받은 이미지를 저장한다. 편집기 브리지가 쓴다.
public func saveAttachment(vault: String, notePath: String, fileName: String, dataBase64: String) throws -> String {
    // 확장자와 경로를 먼저 본다(큰 데이터를 풀기 전에)
    _ = try resolve(vault: vault, notePath)
    let ext = splitName(fileName).ext?.lowercased() ?? ""
    guard attachmentExts.contains(ext) else { throw VaultError("지원하지 않는 이미지 형식입니다: \(fileName)") }
    var b64 = Substring(dataBase64)
    if b64.hasPrefix("data:") {
        b64 = b64.dropFirst(5)
        if let comma = b64.firstIndex(of: ",") { b64 = b64[b64.index(after: comma)...] }
    }
    // 풀기 전에 터무니없이 큰 입력을 거른다(줄바꿈 등 5% 여유)
    if b64.utf8.count > attachmentMaxBytes / 3 * 4 * 21 / 20 + 64 { throw VaultError("이미지가 20MB를 넘습니다") }
    let compact = String(String.UnicodeScalarView(b64.unicodeScalars.filter { !($0.isASCII && $0.isWS) }))
    guard let data = Data(base64Encoded: compact) else { throw VaultError("이미지 데이터를 읽을 수 없습니다") }
    return try saveAttachment(vault: vault, notePath: notePath, fileName: fileName, data: data)
}
