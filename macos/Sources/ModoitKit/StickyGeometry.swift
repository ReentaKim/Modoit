import Foundation

// 스티키 창의 크기·위치 규칙. 좌표는 v0.x와 같이 주 모니터 왼쪽 위가 원점이고 아래로 커진다(frontmatter `sticky`의 x, y).
// 옮겨 온 곳: src-tauri/src/sticky.rs

public let stickyMinWidth = 160.0
public let stickyMinHeight = 120.0
/// 끌 수 있는 상단 막대 높이
public let stickyBarHeight = 28.0

public struct ScreenRect: Equatable, Sendable {
    public var x, y, w, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        (self.x, self.y, self.w, self.h) = (x, y, w, h)
    }
}

/// 상단 막대가 어느 모니터 안에 충분히(가로 40, 세로 14 이상) 보이는가 (BUG-12, F-08 R-8).
/// 모니터 목록을 못 얻으면 위치를 믿는다.
public func barVisible(x: Double, y: Double, w: Double, monitors: [ScreenRect]) -> Bool {
    if monitors.isEmpty { return true }
    func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double { max(min(a1, b1) - max(a0, b0), 0) }
    return monitors.contains { m in
        overlap(x, x + w, m.x, m.x + m.w) >= min(w, 40) && overlap(y, y + stickyBarHeight, m.y, m.y + m.h) >= 14
    }
}

/// n번째로 띄우는 스티키의 기본 위치(왼쪽 위). 조금씩 비껴 놓는다 (F-08 R-4)
public func defaultStickyOrigin(index: Int, screen: ScreenRect) -> (x: Double, y: Double) {
    let step = Double(index % 8) * 26
    return (screen.x + 120 + step, screen.y + 120 + step)
}
