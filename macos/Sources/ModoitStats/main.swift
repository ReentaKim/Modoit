import Foundation
import ModoitCore

// H-2 측정 (Brief 2장): 저장 폴더의 메모 가운데 스티키로 꺼냈을 때 TipTap으로 그려야 하는 메모의 비율.
//   swift run --package-path macos modoit-stats <저장 폴더>
// 읽기만 한다. 파일을 쓰지 않고, 메모 내용이나 제목을 출력하지 않는다(개수와 이유만).

guard CommandLine.arguments.count == 2 else {
    print("사용법: modoit-stats <저장 폴더>")
    exit(2)
}
let vault = CommandLine.arguments[1]
let tree: Tree
do { tree = try listTree(vault: vault) } catch {
    print("저장 폴더를 읽지 못했습니다: \(error)")
    exit(1)
}

var total = 0, web = 0, open = 0, openWeb = 0
var reasons: [String: Int] = [:]
for n in tree.notes {
    guard let text = try? String(contentsOfFile: vault + "/" + n.path, encoding: .utf8) else { continue }
    total += 1
    let blockers = nativeBlockers(splitNote(text).body)
    let isOpen = n.sticky?.open == true
    if isOpen { open += 1 }
    guard !blockers.isEmpty else { continue }
    web += 1
    if isOpen { openWeb += 1 }
    for r in Set(blockers) { reasons[r, default: 0] += 1 }
}

func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%.0f%%", Double(a) / Double(b) * 100) }
print("메모 \(total)개 중 TipTap으로 그릴 메모: \(web)개 (\(pct(web, total)))")
print("지금 꺼내 둔 스티키 \(open)개 중 TipTap: \(openWeb)개 (\(pct(openWeb, open)))")
for (r, c) in reasons.sorted(by: { $0.value > $1.value }) { print("  \(r): \(c)개") }
