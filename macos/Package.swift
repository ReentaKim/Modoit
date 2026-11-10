// swift-tools-version: 6.0
// Modoit v2. 구조와 결정 근거는 docs/dev/architecture-v2.md
import PackageDescription

let package = Package(
    name: "Modoit",
    defaultLocalization: "ko",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ModoitCore", targets: ["ModoitCore"]),
        .library(name: "ModoitKit", targets: ["ModoitKit"]),
        .executable(name: "Modoit", targets: ["Modoit"]),
    ],
    dependencies: [
        // frontmatter(YAML) 읽기 전용. 쓰기는 파서를 거치지 않는다 (V2-12)
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // UI 없는 코어. AppKit·SwiftUI를 넣지 않는다 (v0.x src-tauri/src 에서 옮김)
        .target(name: "ModoitCore", dependencies: [.product(name: "Yams", package: "Yams")]),
        // 화면 없는 앱 로직: 편집 세션, 저장, 스티키 관리. SwiftUI·AppKit 화면 코드는 넣지 않는다
        .target(name: "ModoitKit", dependencies: ["ModoitCore"]),
        .testTarget(name: "ModoitKitTests", dependencies: ["ModoitKit"]),
        // 앱: 화면(SwiftUI·AppKit)과 편집기 연결. Resources/editor는 editor-host를 빌드한 산출물이다(build-app.sh)
        .executableTarget(
            name: "Modoit",
            dependencies: ["ModoitKit", "ModoitCore"],
            resources: [.copy("Resources/editor")]
        ),
        .testTarget(
            name: "ModoitCoreTests",
            dependencies: ["ModoitCore"],
            // v0.x 코드로 만든 기대값. 만드는 스크립트가 같은 폴더에 있다
            resources: [.copy("Fixtures")]
        ),
    ]
)
