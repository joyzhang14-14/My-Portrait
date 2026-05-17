// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyPortrait",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MyPortrait",
            path: "Sources/MyPortrait",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
