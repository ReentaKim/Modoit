// src-tauri/src/config.rs 테스트를 명세로 옮겼다. 테스트 이름은 Rust와 같다.
import Foundation
import Testing
@testable import ModoitCore

private func prefs(_ json: String) throws -> Prefs {
    try JSONDecoder().decode(Prefs.self, from: Data(json.utf8)).normalized()
}

@Test func defaults() throws {
    let p = Prefs()
    #expect(p.fontFamily == "system")
    #expect(p.customFont == "")
    #expect(p.fontSize == 17.0)
    #expect(!p.sidebarCollapsed)
    #expect(p.noteSort == "modified")
    // v0.x와 같은 키 이름(camelCase)으로 저장한다
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
    #expect(json["fontFamily"] as? String == "system")
    #expect(json["fontSize"] as? Double == 17.0)
    #expect(json["sidebarCollapsed"] as? Bool == false)
    #expect(json["noteSort"] as? String == "modified")
}

@Test func v01_config_keeps_vault() {
    let c = Config(json: #"{"vault":"/tmp/v"}"#)
    #expect(c.vault == "/tmp/v")
    #expect(c.prefs == Prefs())
}

@Test func broken_prefs_do_not_lose_vault() {
    var c = Config(json: #"{"vault":"/tmp/v","prefs":{"fontSize":"큼"}}"#)
    #expect(c.vault == "/tmp/v")
    #expect(c.prefs == Prefs())
    c = Config(json: #"{"vault":"/tmp/v","prefs":{"fontSize":40,"fontFamily":"comic","noteSort":"x","sidebarCollapsed":true}}"#)
    #expect(c.prefs.fontSize == 22.0)
    #expect(c.prefs.fontFamily == "system")
    #expect(c.prefs.noteSort == "modified")
    #expect(c.prefs.sidebarCollapsed)
    #expect(Config(json: "깨짐").vault == nil)
}

@Test func partial_prefs_from_frontend() throws {
    var p = try prefs(#"{"fontFamily":"custom","customFont":" D2Coding "}"#)
    #expect(p.fontFamily == "custom")
    #expect(p.customFont == "D2Coding")
    #expect(p.fontSize == 17.0)
    #expect([p.theme, p.accent] == ["system", "yellow"])
    p = try prefs(#"{"theme":"dark","accent":"blue","noteSort":"created"}"#)
    #expect([p.theme, p.accent, p.noteSort] == ["dark", "blue", "created"])
    p = try prefs(#"{"theme":"sepia","accent":"rainbow"}"#)
    #expect([p.theme, p.accent] == ["system", "yellow"])
}

/// v2 추가: 저장한 config.json을 다시 읽으면 같고, v0.x가 쓰던 모양(vault + prefs)이다 (F-10 R-3)
@Test func config_roundtrip_keeps_v0x_shape() throws {
    let v = try tempVault()
    let url = join(v, "config.json")
    var c = Config(vault: "/Users/x/메모")
    c.prefs.theme = "dark"
    c.prefs.accent = "green"
    try c.save(to: url)
    #expect(Config.load(from: url) == c)
    let obj = try JSONSerialization.jsonObject(with: #require(FileManager.default.contents(atPath: url))) as! [String: Any]
    #expect(Set(obj.keys) == ["vault", "prefs"])
    #expect(Config.load(from: join(v, "없음.json")) == Config())
}
