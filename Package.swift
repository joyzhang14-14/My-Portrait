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
        // bge-m3 / XLM-RoBERTa 真推理（MLX-Swift 端口；用 mlx-community/bge-m3-mlx-fp16）
        .package(url: "https://github.com/mzbac/mlx.embeddings.git", from: "0.1.0"),
        // TOML 1.0 codec for the user-editable ~/.myportrait/config.toml
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
        // ONNX Runtime（说话人识别：pyannote 分离 + wespeaker CAM++ 嵌入）
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.0"),
        // Sparkle 自动更新（GitHub Pages 托管 appcast.xml）
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
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
                .product(name: "mlx_embeddings", package: "mlx.embeddings"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Sparkle", package: "Sparkle"),
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
