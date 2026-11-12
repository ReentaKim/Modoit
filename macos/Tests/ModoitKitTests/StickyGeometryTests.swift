import Testing
@testable import ModoitKit

// 옮겨 온 곳: src-tauri/src/sticky.rs offscreen_positions_are_rejected (BUG-12)
@Test func offscreen_positions_are_rejected() {
    let mons = [ScreenRect(0, 0, 1440, 900), ScreenRect(1440, -200, 1920, 1080)]
    #expect(barVisible(x: 100, y: 100, w: 260, monitors: mons))
    #expect(barVisible(x: 1500, y: -150, w: 260, monitors: mons))
    // 떼어 낸 모니터 자리
    #expect(!barVisible(x: 3500, y: 100, w: 260, monitors: mons))
    #expect(!barVisible(x: -600, y: 100, w: 260, monitors: mons))
    // 막대가 화면 아래로 빠짐
    #expect(!barVisible(x: 100, y: 895, w: 260, monitors: [mons[0]]))
    // 왼쪽 끝에 조금만 걸침(40 미만)
    #expect(!barVisible(x: -230, y: 100, w: 260, monitors: [mons[0]]))
    #expect(barVisible(x: -200, y: 100, w: 260, monitors: [mons[0]]))
    #expect(barVisible(x: 5000, y: 5000, w: 260, monitors: []))
}
