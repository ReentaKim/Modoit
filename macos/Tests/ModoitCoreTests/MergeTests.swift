// src/qa/v03Session.test.ts 의 mergeBodies 케이스를 옮겼다 (BUG-26, F-07).
import Foundation
import Testing
@testable import ModoitCore

private let cases: [(String, String, String, String, String)] = [
    ("다른 줄을 고침", "a\nb\nc", "A\nb\nc", "a\nb\nC", "A\nb\nC"),
    ("양쪽이 끝에 추가", "a", "a\n내 줄", "a\n남 줄", "a\n내 줄\n\n남 줄"),
    ("같은 줄 충돌 → 둘 다 남김", "a\nb", "a\n내 b", "a\n남 b", "a\n내 b\n\n남 b"),
    ("한쪽만 고침", "a\nb", "a\nb", "a\nb\n남", "a\nb\n남"),
    ("내가 다 지우고 상대는 추가", "a", "", "a\n추가", "\n\na\n추가"),
    // v2 추가
    ("양쪽이 같은 고침", "a\nb", "a\nB", "a\nB", "a\nB"),
    ("상대는 그대로", "a\nb", "a\nB\nc", "a\nb", "a\nB\nc"),
    ("서로 다른 곳에 줄 추가", "1\n2\n3\n4", "1\n내\n2\n3\n4", "1\n2\n3\n남\n4", "1\n내\n2\n3\n남\n4"),
    ("내가 지운 줄을 상대가 고침 → 상대 것이 남는다", "a\nb\nc", "a\nc", "a\nB\nc", "a\nB\nc"),
    ("체크박스를 서로 다른 줄에서 체크", "- [ ] 가\n- [ ] 나\n- [ ] 다", "- [x] 가\n- [ ] 나\n- [ ] 다", "- [ ] 가\n- [ ] 나\n- [x] 다", "- [x] 가\n- [ ] 나\n- [x] 다"),
    ("반복되는 줄 사이에 추가", "x\n\nx\n\nx", "x\n\nx\n내\n\nx", "x\n남\n\nx\n\nx", "x\n남\n\nx\n내\n\nx"),
]

@Test("mergeBodies: 어느 쪽 편집도 버리지 않는다 (BUG-26)", arguments: cases.indices)
func merge_bodies(_ i: Int) {
    let (name, base, mine, theirs, want) = cases[i]
    #expect(mergeBodies(base: base, mine: mine, theirs: theirs) == want, "\(name)")
}

@Test func merge_never_loses_a_line() {
    // 무작위: 양쪽이 넣은 줄은 결과에 모두 있어야 한다
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<500 {
        let base = (0..<Int.random(in: 0...8, using: &rng)).map { "기본\($0)" }
        func edit(_ tag: String) -> [String] {
            var l = base
            for k in 0..<Int.random(in: 0...3, using: &rng) {
                switch Int.random(in: 0...2, using: &rng) {
                case 0: l.insert("\(tag)추가\(k)", at: Int.random(in: 0...l.count, using: &rng))
                case 1 where !l.isEmpty: l[Int.random(in: 0..<l.count, using: &rng)] = "\(tag)고침\(k)"
                case 2 where !l.isEmpty: l.remove(at: Int.random(in: 0..<l.count, using: &rng))
                default: break
                }
            }
            return l
        }
        let mine = edit("내"), theirs = edit("남")
        let merged = mergeBodies(base: base.joined(separator: "\n"), mine: mine.joined(separator: "\n"),
                                 theirs: theirs.joined(separator: "\n")).components(separatedBy: "\n")
        for line in (mine + theirs) where line.hasPrefix("내") || line.hasPrefix("남") {
            #expect(merged.contains(line), "\(line) 이(가) 사라짐: base=\(base) mine=\(mine) theirs=\(theirs) → \(merged)")
        }
    }
}

/// v0.x의 실제 병합 코드(node-diff3 3.2.1)가 낸 결과와 한 글자까지 같다.
/// 반복되는 줄·빈 줄이 섞인 무작위 400건. 기대값은 Fixtures/gen-merge.mjs 로 만든다.
@Test func merge_matches_v0x_on_random_cases() throws {
    let url = try #require(Bundle.module.url(forResource: "merge-v0x", withExtension: "json", subdirectory: "Fixtures"))
    let cases = try JSONDecoder().decode([[String]].self, from: Data(contentsOf: url))
    #expect(cases.count == 400)
    var different = 0
    for c in cases where !mergeBodies(base: c[0], mine: c[1], theirs: c[2]).sameBytes(c[3]) {
        different += 1
        if different <= 3 {
            Issue.record("base=\(c[0].debugDescription) mine=\(c[1].debugDescription) theirs=\(c[2].debugDescription)\n want=\(c[3].debugDescription)\n  got=\(mergeBodies(base: c[0], mine: c[1], theirs: c[2]).debugDescription)")
        }
    }
    #expect(different == 0)
}
