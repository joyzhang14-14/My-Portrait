import Foundation
import Observation

/// 用户本地 Ollama 已安装的模型列表 —— **不写死**。Ollama 的模型由用户自己
/// `ollama pull` 装,我们只能运行时从 `http://localhost:11434/api/tags` 拉。
///
/// 两层缓存:
///   - `@Observable models` 给 SwiftUI picker 读(列表变了 picker 自动刷新)。
///   - nonisolated lock 镜像 `cachedModels` 给 `Provider.availableModels` 读
///     (PiInstaller.writeModelsJSON / resolvedModel 等非 MainActor 同步路径)。
///
/// 两份由 `refresh()` 一起更新,始终一致。
@MainActor
@Observable
final class OllamaModelStore {
    static let shared = OllamaModelStore()
    private init() {}

    /// SwiftUI 读这个(observable)。
    private(set) var models: [String] = []

    // MARK: - nonisolated 镜像(任意上下文同步读)

    nonisolated static var cachedModels: [String] { lock.withLock { mirror } }
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var mirror: [String] = []

    // MARK: - Fetch

    /// 拉 `/api/tags`,解析模型名,更新 `models` + 镜像。
    /// Ollama 没在跑 / 网络抖动失败时 **不清空**已有列表(避免一次失败把 picker
    /// 抹空)—— 保留上次结果。
    func refresh() async {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
            else { return }
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            // Ollama 返回顺序大致是安装时间;按名字稳定排序,picker 不抖。
            let names = decoded.models.map(\.name).sorted()
            models = names
            Self.lock.withLock { Self.mirror = names }
        } catch {
            // 静默:保留旧列表。
        }
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }
}
