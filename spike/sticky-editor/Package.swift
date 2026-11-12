// swift-tools-version: 6.0
// 2차 스파이크: 꾸밈이 있는 네이티브 스티키 편집기 (아키텍처 V2-10, V2-11). 제품 코드가 아니다.
import PackageDescription

let package = Package(
    name: "StickyEditorSpike",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../macos")],
    targets: [
        .executableTarget(
            name: "StickyEditorSpike",
            dependencies: [.product(name: "ModoitCore", package: "macos")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
