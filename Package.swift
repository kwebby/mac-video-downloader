// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harbor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Harbor", targets: ["HarborApp"]),
        .executable(name: "HarborBroker", targets: ["HarborBroker"]),
        .executable(name: "HarborNativeHost", targets: ["HarborNativeHost"]),
        .executable(name: "harborctl", targets: ["HarborCLI"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "HarborCore"),
        .target(name: "HarborEngine", dependencies: ["HarborCore", "CSQLite"]),
        .executableTarget(name: "HarborApp", dependencies: ["HarborCore"]),
        .executableTarget(name: "HarborBroker", dependencies: ["HarborCore", "HarborEngine"]),
        .executableTarget(name: "HarborNativeHost", dependencies: ["HarborCore"]),
        .executableTarget(name: "HarborCLI", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborEngineTests", dependencies: ["HarborCore", "HarborEngine"]),
        .testTarget(name: "HarborCoreTests", dependencies: ["HarborCore"]),
    ],
    swiftLanguageModes: [.v5]
)
