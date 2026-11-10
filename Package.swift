// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Scruffy",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Scruffy", targets: ["Scruffy"]),
               .executable(name: "ScruffyStorageHelper", targets: ["ScruffyStorageHelper"])],
    targets: [
        .target(name: "CleanupCore", path: "src/CleanupCore"),
        .executableTarget(name: "Scruffy", dependencies: ["CleanupCore"], path: "src/Scruffy", resources: [.process("Resources")]),
        .executableTarget(name: "ScruffyStorageHelper", dependencies: ["CleanupCore"], path: "src/ScruffyStorageHelper"),
        .testTarget(name: "CleanupCoreTests", dependencies: ["CleanupCore"], path: "tests/CleanupCoreTests"),
        .testTarget(name: "ScruffyTests", dependencies: ["Scruffy", "CleanupCore"], path: "tests/ScruffyTests")
    ]
)
