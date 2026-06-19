// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyPortrait",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.18.0"),
        // TOML 1.0 codec for the user-editable ~/.myportrait/config.toml
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
        // ONNX Runtime（说话人识别：pyannote 分离 + wespeaker CAM++ 嵌入）
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.0"),
        // Sparkle 自动更新（GitHub Pages 托管 appcast.xml）
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Qwen3-ASR 原生转录引擎（MLX）。0.0.x 快速 churn —— pin exact 保证可复现。
        // 只用 Qwen3ASR 库产品（不碰它附带的 TTS / hummingbird server 那一坨）。
        .package(url: "https://github.com/ivan-digital/qwen3-asr-swift.git", exact: "0.0.19"),
    ],
    targets: [
        // ObjC helper —— Swift 不接 NSException,AVAudioEngine.installTap /
        // engine.start 在 aggregate device 格式不匹配时会抛 NSException
        // 直接杀进程。这个 target 提供一个 ObjC try/catch wrapper 转成 NSError。
        .target(
            name: "MyPortraitObjC",
            path: "Sources/MyPortraitObjC",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "MyPortrait",
            dependencies: [
                "MyPortraitObjC",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Qwen3ASR", package: "qwen3-asr-swift"),
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
        // 特权 root LaunchDaemon helper —— 跟 app 双轨并存(`swift build` 编译校验,
        // Xcode 经 project.yml 出签名产物嵌进 .app)。只依赖 Foundation。
        .executableTarget(
            name: "PortraitSleepHelper",
            path: "Sources/PortraitSleepHelper"
        ),
        .testTarget(
            name: "MyPortraitTests",
            dependencies: ["MyPortrait"],
            path: "Tests/MyPortraitTests"
        ),
    ]
)
