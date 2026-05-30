import Foundation
import os.log

/// bge-m3 模型本地缓存管理。
///
/// 从 HuggingFace `BAAI/bge-m3` 下载模型权重 + tokenizer 到 `~/.portrait/models/bge-m3/`。
/// 一次性下载（~2.5 GB），后续直接读本地。
///
/// 触发：Services.startManagedLifecycle 后台启 Task 调 `ensureDownloaded()`。
/// 推理（Phase 4）会先 `await ensureDownloaded()` 再加载模型。
///
/// **不做的事**：
///   - 模型版本管理（HuggingFace 仓库的最新 commit 我们直接拿 main 分支）
///   - 校验 checksum（HuggingFace 没在文件名里给 hash）
///   - 断点续传（URLSession.download 本身有 temp 文件，但移动到目的地后再启动相当于重新跑）
///
/// 失败处理：单个文件失败 → 抛错，已下载的部分留在原地（下次再来重头跑该文件）。
actor BGEM3ModelManager {

    private let logger = Logger(subsystem: "com.myportrait.db", category: "model")
    private let modelDir: URL
    private let session: URLSession

    /// HuggingFace 仓库根。`resolve/main/` 后接文件名。
    private static let repoBase = "https://huggingface.co/BAAI/bge-m3/resolve/main"

    /// 启动期必下的文件（**只下 tokenizer + 配置**，约 ~17 MB 总共）。
    /// 重 ~2.27 GB 的权重文件 `pytorch_model.bin` **不在这里**——
    /// 由 BGEM3VectorEmbedder.embed 首次 MLX 推理时按需调 `ensureWeightsDownloaded()` 拉取。
    ///
    /// 之前列了 `model.safetensors` 是错的：BAAI/bge-m3 实际只发布
    /// `pytorch_model.bin`，没有 safetensors 版本（用户日志: 404）。
    private static let requiredFiles: [String] = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "sentencepiece.bpe.model",
        "special_tokens_map.json",
        "1_Pooling/config.json",
    ]

    /// 真权重文件（~2.27 GB），仅当 MLX 推理实际要跑时才下。
    private static let weightsFile = "pytorch_model.bin"

    init(modelDir: URL = Storage.modelsDir.appendingPathComponent("bge-m3", isDirectory: true)) {
        self.modelDir = modelDir
        // 大文件超长下载，关掉默认超时（None ≈ 7 天）。
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60         // 单个请求建立连接 60s 超时
        config.timeoutIntervalForResource = 60 * 60 * 4  // 单个资源 4h 超时
        self.session = URLSession(configuration: config)
    }

    /// 完整路径（推理用）。
    func filePath(for relative: String) -> URL {
        modelDir.appendingPathComponent(relative)
    }

    /// **轻量下载**：只拉 tokenizer + config 文件（~17 MB 共）。
    /// 启动时跑这个就够——没有权重，无法推理，但 NLEmbedding 后端不需要。
    /// 抛错：某个文件下载失败 / 写盘失败。
    func ensureDownloaded() async throws {
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        for rel in Self.requiredFiles {
            let dest = modelDir.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: dest.path) {
                continue
            }
            try await downloadFile(relative: rel, to: dest)
        }
        logger.info("bge-m3 config + tokenizer ready at \(self.modelDir.path, privacy: .public) (~17 MB; weights not downloaded yet)")
    }

    /// **重量下载**：~2.27 GB 的 pytorch_model.bin。MLX 推理实现时第一次调用前
    /// 主动 `await ensureWeightsDownloaded()`，UI 可显示进度条。
    func ensureWeightsDownloaded() async throws {
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let dest = modelDir.appendingPathComponent(Self.weightsFile)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        logger.info("downloading bge-m3 weights (~2.27 GB) — this may take a while...")
        try await downloadFile(relative: Self.weightsFile, to: dest)
    }

    // MARK: - 私有

    private func downloadFile(relative: String, to dest: URL) async throws {
        guard let url = URL(string: "\(Self.repoBase)/\(relative)") else {
            throw ModelDownloadError.invalidURL(relative)
        }

        // 父目录就绪（如 1_Pooling/）。
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        logger.info("downloading \(relative, privacy: .public) ...")
        let started = Date()
        let (tempURL, response) = try await session.download(from: url)

        // HTTP 错误 → 抛
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw ModelDownloadError.httpStatus(statusCode: http.statusCode, file: relative)
        }

        // 原子 move 到最终路径。
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)

        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        let elapsed = Date().timeIntervalSince(started)
        logger.info("downloaded \(relative, privacy: .public) — \(size) bytes in \(elapsed, format: .fixed(precision: 1))s")
    }
}

enum ModelDownloadError: Error, CustomStringConvertible {
    case invalidURL(String)
    case httpStatus(statusCode: Int, file: String)

    var description: String {
        switch self {
        case .invalidURL(let f): return "ModelDownloadError.invalidURL(\(f))"
        case .httpStatus(let code, let f): return "ModelDownloadError.httpStatus(\(code), \(f))"
        }
    }
}
