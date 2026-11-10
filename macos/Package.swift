// swift-tools-version: 6.0
// Modoit v2. 구조와 결정 근거는 docs/dev/architecture-v2.md
import PackageDescription

let package = Package(
    name: "Modoit",
    defaultLocalization: "ko",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ModoitCore", targets: ["ModoitCore"]),
    ],
    dependencies: [
        // frontmatter(YAML) 읽기 전용. 쓰기는 파서를 거치지 않는다 (V2-12)
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // UI 없는 코어. AppKit·SwiftUI를 넣지 않는다 (v0.x src-tauri/src 에서 옮김)
        .target(name: "ModoitCore", dependencies: [.product(name: "Yams", package: "Yams")]),
        .testTarget(
            name: "ModoitCoreTests",
            dependencies: ["ModoitCore"],
            // v0.x 코드로 만든 기대값. 만드는 스크립트가 같은 폴더에 있다
            resources: [.copy("Fixtures")]
        ),
    ]
)
