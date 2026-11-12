// src-tauri/src/layout.rs 테스트를 명세로 옮겼다. 테스트 이름은 Rust와 같다.
import Foundation
import Testing
@testable import ModoitCore

private func sample() -> Layout {
    Layout(order: ["": ["업무", "sep:1", "개인"], "업무": ["회의", "보고"], "업무/회의": ["2026"], "업무-2024": ["x"]])
}

@Test func missing_or_broken_file_gives_default() throws {
    let v = try tempVault()
    #expect(loadLayout(vault: v) == Layout())
    try atomicWrite("{깨진 json", to: layoutPath(vault: v))
    #expect(loadLayout(vault: v) == Layout())
    // 일부 필드만 있어도 나머지는 기본값
    try atomicWrite(#"{"sort":"name"}"#, to: layoutPath(vault: v))
    let l = loadLayout(vault: v)
    #expect(l.sort == .name)
    #expect(l.order.isEmpty)
}

@Test func save_and_load_roundtrip() throws {
    let v = try tempVault()
    var l = sample()
    l.sort = .recent
    try saveLayout(vault: v, l)
    #expect(loadLayout(vault: v) == l)
    #expect(try String(contentsOfFile: layoutPath(vault: v), encoding: .utf8).contains("\"recent\""))
}

@Test func rename_updates_keys_and_parent_order() {
    var l = sample()
    l.moveDir(from: "업무", to: "일")
    #expect(l.order[""] == ["일", "sep:1", "개인"])
    #expect(l.order["일"] == ["회의", "보고"])
    #expect(l.order["일/회의"] == ["2026"])
    // 접두사만 같은 다른 폴더는 그대로
    #expect(l.order["업무-2024"] != nil)
    #expect(l.order["업무"] == nil)
}

@Test func move_to_other_parent_updates_both_lists() {
    var l = sample()
    l.moveDir(from: "업무/회의", to: "개인/회의")
    #expect(l.order["업무"] == ["보고"])
    #expect(l.order["개인/회의"] == ["2026"])
    // 최상위로 옮기면 최상위 목록 끝에 붙는다
    l.moveDir(from: "개인/회의", to: "회의")
    #expect(l.order[""] == ["업무", "sep:1", "개인", "회의"])
    #expect(l.order["회의"] != nil)
}

@Test func remove_drops_keys_and_name() {
    var l = sample()
    l.removeDir("업무")
    #expect(l.order[""] == ["sep:1", "개인"])
    #expect(l.order["업무"] == nil)
    #expect(l.order["업무/회의"] == nil)
    #expect(l.order["업무-2024"] != nil)
}

@Test func update_does_not_create_file_without_change() throws {
    let v = try tempVault()
    try updateLayout(vault: v) { $0.removeDir("없는폴더") }
    #expect(!FileManager.default.fileExists(atPath: layoutPath(vault: v)))
}
