import Foundation

// 앱 설정(저장 폴더 경로, 화면 설정). v0.x와 같은 위치·형식의 config.json (F-10 R-3).
// 읽을 때는 관대하게 읽는다. 설정 일부가 이상해도 저장 폴더 경로는 잃지 않는다 (F-01 R-4).
// 옮겨 온 곳: src-tauri/src/config.rs

public let fontSizeMin = 14.0
public let fontSizeMax = 22.0
public let fontSizeDefault = 17.0
public let fontFamilies = ["system", "pretendard", "serif", "mono", "custom"]
public let noteSorts = ["modified", "created", "name"]
public let themes = ["system", "light", "dark"]
public let accents = ["yellow", "orange", "red", "pink", "purple", "blue", "green", "graphite"]

public struct Prefs: Equatable, Codable, Sendable {
    public var fontFamily = "system"
    public var customFont = ""
    public var fontSize = fontSizeDefault
    public var sidebarCollapsed = false
    public var noteSort = "modified"
    /// 모양: system | light | dark (FR-45)
    public var theme = "system"
    /// 강조 색 이름 (FR-46)
    public var accent = "yellow"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Prefs()
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? d.fontFamily
        customFont = try c.decodeIfPresent(String.self, forKey: .customFont) ?? d.customFont
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        sidebarCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? d.sidebarCollapsed
        noteSort = try c.decodeIfPresent(String.self, forKey: .noteSort) ?? d.noteSort
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? d.accent
    }

    /// 허용 범위 밖의 값을 기본값이나 경계값으로 바꾼다 (Brief 3.7-3).
    public func normalized() -> Prefs {
        var p = self
        let d = Prefs()
        if !fontFamilies.contains(p.fontFamily) { p.fontFamily = d.fontFamily }
        if !noteSorts.contains(p.noteSort) { p.noteSort = d.noteSort }
        if !themes.contains(p.theme) { p.theme = d.theme }
        if !accents.contains(p.accent) { p.accent = d.accent }
        p.fontSize = p.fontSize.isFinite ? min(max(p.fontSize, fontSizeMin), fontSizeMax) : fontSizeDefault
        p.customFont = String(p.customFont.scalars.trimmed())
        return p
    }
}

public struct Config: Equatable, Sendable {
    public var vault: String?
    public var prefs = Prefs()

    public init(vault: String? = nil, prefs: Prefs = Prefs()) {
        self.vault = vault
        self.prefs = prefs
    }

    public init(json: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        vault = obj["vault"] as? String
        if let p = obj["prefs"], JSONSerialization.isValidJSONObject(p),
           let data = try? JSONSerialization.data(withJSONObject: p),
           let decoded = try? JSONDecoder().decode(Prefs.self, from: data) {
            prefs = decoded.normalized()
        }
    }

    public func json() throws -> Data {
        var obj: [String: Any] = [:]
        obj["vault"] = vault ?? NSNull()
        obj["prefs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs))
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func load(from path: String) -> Config {
        fm.contents(atPath: path).map { Config(json: String(decoding: $0, as: UTF8.self)) } ?? Config()
    }

    public func save(to path: String) throws {
        try atomicWrite(try json(), to: path)
    }
}
