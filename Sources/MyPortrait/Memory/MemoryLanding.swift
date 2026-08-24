import Foundation

/// Memories 打开时落在哪个 scope / 视图形态 —— 记在 config 里,切换即写回。
///
/// **读回来要校验**,不能直接信盘上的值:
///   - scope 可能已经不存在(portrait 分类被删)
///   - scope + mode 可能是无效组合(Personal Info 没有图谱形态)
/// 任何一条不成立就回落到默认,不让 Memories 开在一个渲染不出来的状态上。
@MainActor
enum MemoryLanding {

    static func restoredScope() -> MemoryScope {
        let raw = ConfigStore.shared.current.display.memoryLastScope
        return MemoryScope(id: raw) ?? .events
    }

    static func restoredViewMode() -> MemoryViewMode {
        let scope = restoredScope()
        let raw = ConfigStore.shared.current.display.memoryLastViewMode
        let mode = MemoryViewMode(rawValue: raw) ?? .text
        // 图谱设置页只在图谱模式下路由得到,单独放行(它不是"图谱形态")。
        if scope == .neuralGraphSettings { return .neuralGraph }
        if scope == .textSettings { return .text }
        guard mode == .neuralGraph else { return .text }
        return MemoryViewMode.supportsNeuralGraph(scope) ? .neuralGraph : .text
    }

    static func persist(scope: MemoryScope, mode: MemoryViewMode) {
        ConfigStore.shared.mutate {
            $0.display.memoryLastScope = scope.id
            $0.display.memoryLastViewMode = mode.rawValue
        }
    }
}
