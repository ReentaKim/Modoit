import Foundation
import ModoitCore
import Testing
@testable import ModoitKit

// 옮겨 온 곳: src-tauri/src/watcher.rs internal_paths
@Test func internal_paths() {
    #expect(isInternalPath(".modoit/layout.json"))
    #expect(isInternalPath(".modoit"))
    #expect(isInternalPath("메모/.a.md.modoit-tmp"))
    #expect(!isInternalPath("메모/a.md"))
    #expect(!isInternalPath(".modoitx/a.md"))
}

/// FR-22: 다른 앱이 파일을 바꾸면 그 경로를 알린다. `.modoit/` 안의 변경은 알리지 않는다
@MainActor @Test func FR22_watcher_reports_external_change() async throws {
    let dir = NSTemporaryDirectory() + "modoit-watch-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir + "/.modoit", withIntermediateDirectories: true)
    // Foundation으로 만들면 한글 이름이 NFD가 된다 (V2-13). 코어로 만든다
    _ = try createFolder(vault: dir, parent: "", name: "메모")
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var seen: [String] = []
    let w = VaultWatcher(vault: dir, latency: 0.05) { seen += $0 }
    defer { w.stop() }
    try await Task.sleep(for: .milliseconds(300))
    try atomicWrite("{}", to: dir + "/.modoit/layout.json")
    try atomicWrite("안녕", to: dir + "/메모/가.md")
    for _ in 0..<60 where !seen.contains(where: { $0.sameBytes("메모/가.md") }) { try await Task.sleep(for: .milliseconds(50)) }
    #expect(seen.contains { $0.sameBytes("메모/가.md") }, "\(seen.map { Array($0.utf8) })")
    #expect(!seen.contains { $0.hasPrefix(".modoit") || $0.hasSuffix(tmpSuffix) })
}

/// FR-22: 감시가 알려 준 경로의 한글 정규화가 달라도 열린 메모에 반영한다
@MainActor @Test func FR22_disk_change_matches_path_across_normalization() throws {
    let dir = NSTemporaryDirectory() + "modoit-watch-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    _ = try createFolder(vault: dir, parent: "", name: "메모")
    try atomicWrite("처음", to: dir + "/메모/가.md")
    let store = SessionStore(vault: dir)
    let s = try store.open("메모/가.md")
    try atomicWrite("바뀜", to: dir + "/메모/가.md")
    store.diskChanged(["메모/가.md".decomposedStringWithCanonicalMapping])
    #expect(s.body == "바뀜")
}
