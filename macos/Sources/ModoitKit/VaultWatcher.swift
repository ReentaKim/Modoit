import CoreServices
import Foundation
import ModoitCore

/// 앱 내부 파일이라 목록을 다시 읽을 필요가 없는 경로인가: `.modoit/` 안, 원자적 쓰기의 임시 파일.
/// 옮겨 온 곳: src-tauri/src/watcher.rs is_internal
public func isInternalPath(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    if parts.last.map({ String($0).utf8.reversed().starts(with: tmpSuffix.utf8.reversed()) }) == true { return true }
    return parts.contains { String($0).sameBytes(metaDir) }
}

/// 저장 폴더를 지켜보다가 다른 앱이 바꾸면 알린다 (FR-22, F-07 4.2).
/// 몰려오는 변경은 0.25초 단위로 묶는다. 알림은 메인 스레드에서 온다.
@MainActor
public final class VaultWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void
    private let root: String

    /// `onChange`: 바뀐 파일의 저장 폴더 기준 상대 경로들. 비어 있으면 "어디가 바뀌었는지 모름"(전부 다시 확인)
    public init(vault: String, latency: Double = 0.25, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        // FSEvents는 실제 경로(/private/var/… 등)로 알려 준다
        root = realpath(vault, nil).map { p in defer { free(p) }; return String(cString: p) } ?? vault
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let rescan = (0..<count).contains { Int(flags[$0]) & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 }
            let me = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { me.received(list, rescan: rescan) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func received(_ paths: [String], rescan: Bool) {
        if rescan || paths.isEmpty { return onChange([]) }
        let rels = paths.compactMap { p -> String? in
            guard p.bytesHasPrefix(root + "/") else { return nil }
            let rel = p.droppingBytes(root.utf8.count + 1)
            return isInternalPath(rel) ? nil : rel
        }
        // 앱 내부 파일만 바뀐 것이면 알리지 않는다
        if !rels.isEmpty { onChange(rels) }
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
