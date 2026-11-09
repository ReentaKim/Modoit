import Foundation

public let attachmentsDir = "attachments"
public let attachmentMaxBytes = 20 * 1024 * 1024
public let attachmentExts = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"]

public struct NoteMeta: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let title: String
    public let preview: String
    public let modified: Date
    public let sticky: StickyMeta?
}

public struct Vault: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// 폴더 목록(저장 폴더 기준 상대 경로). 숨김 폴더와 attachments는 뺀다.
    public func folders() -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in e {
            let rel = toRel(vault: root, url)
            if rel == attachmentsDir { e.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { out.append(rel) }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// folder 안(하위 폴더 제외)의 메모. folder가 nil이면 전체.
    public func notes(in folder: String? = nil) -> [NoteMeta] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        var out: [NoteMeta] = []
        for case let url as URL in e where url.pathExtension.lowercased() == "md" {
            let rel = toRel(vault: root, url)
            if rel.hasPrefix(attachmentsDir + "/") { continue }
            if let folder, parentRel(rel) != folder { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let (title, preview) = titleAndPreview(text)
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            out.append(NoteMeta(path: rel, title: title.isEmpty ? untitled : title, preview: preview,
                                modified: mod, sticky: parseSticky(front: splitNote(text).front)))
        }
        return out.sorted { $0.modified > $1.modified }
    }

    public func read(_ rel: String) throws -> String {
        try String(contentsOf: resolve(vault: root, rel), encoding: .utf8)
    }

    /// 본문만 바꾼다. frontmatter는 디스크 최신본을 그대로 쓴다(아키텍처 3.1).
    public func writeBody(_ rel: String, body: String) throws {
        let url = try resolve(vault: root, rel)
        let disk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var parts = splitNote(disk)
        if parts.body == body { return }
        parts.body = body
        try atomicWrite(joinNote(parts), to: url)
    }

    public func updateSticky(_ rel: String, _ s: StickyMeta?) throws {
        let url = try resolve(vault: root, rel)
        var parts = splitNote(try String(contentsOf: url, encoding: .utf8))
        parts.front = setSticky(front: parts.front, s)
        try atomicWrite(joinNote(parts), to: url)
    }

    /// vault.rs `save_attachment`: attachments/에 저장하고 메모 기준 상대 링크를 돌려준다.
    public func saveAttachment(notePath: String, fileName: String, dataBase64: String) throws -> String {
        let note = try resolve(vault: root, notePath)
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard attachmentExts.contains(ext) else { throw VaultError("지원하지 않는 이미지 형식입니다: \(fileName)") }
        var b64 = Substring(dataBase64)
        if b64.hasPrefix("data:") { b64 = b64.split(separator: ",", maxSplits: 1).last ?? "" }
        guard let data = Data(base64Encoded: String(b64), options: .ignoreUnknownCharacters),
              !b64.contains("@") else { throw VaultError("이미지 데이터를 읽을 수 없습니다") }
        if data.count > attachmentMaxBytes { throw VaultError("이미지가 20MB를 넘습니다") }
        if data.isEmpty { throw VaultError("빈 이미지입니다") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let dir = root.appending(path: attachmentsDir)
        var target: URL?
        for _ in 0..<64 {
            let u = dir.appending(path: "\(stamp)-\(String(format: "%04x", UInt16.random(in: .min ... .max))).\(ext)")
            if !FileManager.default.fileExists(atPath: u.path) { target = u; break }
        }
        guard let target else { throw VaultError("이미지 이름을 만들 수 없습니다") }
        try atomicWrite(data, to: target)
        return relativePath(fromDir: parentRel(toRel(vault: root, note)), to: toRel(vault: root, target))
    }
}
