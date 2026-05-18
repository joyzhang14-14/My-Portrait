// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyPortrait",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyPortrait",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/MyPortrait",
            exclude: [
                "Capture/README.md",
                "Capture/Audio/README.md",
                "Capture/Compaction/README.md",
                "Capture/Events/README.md",
                "Capture/Power/README.md",
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
