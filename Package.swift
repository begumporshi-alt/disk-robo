// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskRobo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DiskRobo", targets: ["DiskRobo"]),
        .library(name: "RoboCore", targets: ["RoboCore"]),
    ],
    targets: [
        .target(
            name: "RoboCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "DiskRobo",
            dependencies: ["RoboCore"]
        ),
        .executableTarget(
            name: "DiskRoboScanner",
            dependencies: ["RoboCore"]
        ),
        .testTarget(
            name: "RoboCoreTests",
            dependencies: ["RoboCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
