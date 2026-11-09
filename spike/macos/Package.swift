// swift-tools-version: 6.0
// Modoit v2 스파이크. 결정 근거는 docs/dev/architecture-v2.md
import PackageDescription

let package = Package(
    name: "ModoitSpike",
    defaultLocalization: "ko",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "ModoitCore", targets: ["ModoitCore"]),
        .executable(name: "ModoitSpike", targets: ["ModoitSpike"]),
    ],
    targets: [
        // macOS·iOS 공용 코어 (src-tauri/src/vault.rs의 일부를 옮김)
        .target(name: "ModoitCore"),
        .executableTarget(
            name: "ModoitSpike",
            dependencies: ["ModoitCore"],
            resources: [.copy("Resources/editor")]
        ),
        .testTarget(name: "ModoitCoreTests", dependencies: ["ModoitCore"]),
    ]
)
