// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lintel",
    platforms: [.macOS(.v14)],
    targets: [
        // AppKit-free logic, unit-tested.
        .target(name: "LintelCore"),
        // No SwiftPM resources: Bundle.module breaks once the binary is copied into a
        // hand-assembled .app. scripts/bundle.sh copies Resources/ into the bundle instead.
        .executableTarget(name: "Lintel", dependencies: ["LintelCore"]),
        .testTarget(name: "LintelCoreTests", dependencies: ["LintelCore"]),
    ]
)
