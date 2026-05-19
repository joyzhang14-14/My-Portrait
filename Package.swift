// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyPortrait",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.18.0"),
        // sentencepiece tokenizer，HuggingFace 出的 Swift 包
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "0.1.13"),
        // TOML 1.0 codec for the user-editable ~/.myportrait/config.toml
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyPortrait",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/MyPortrait",
            exclude: [
                "Capture/README.md",
                "Capture/Audio/README.md",
                "Capture/Compaction/README.md",
                "Capture/Events/README.md",
                "Capture/Power/README.md",
                "DB/README.md",
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "MyPortraitTests",
            dependencies: ["MyPortrait"],
            path: "Tests/MyPortraitTests"
        ),
    ]
)
