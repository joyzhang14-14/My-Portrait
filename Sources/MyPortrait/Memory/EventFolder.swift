import Foundation

/// 项目维度的事件分组("My Portrait" / "Valis" / "UCI" 等)。
///
/// 物理位置:每个 folder 一个 JSON 文件,落在 `~/.portrait/events/_folders/<slug>.json`。
/// events/<day>/*.md 文件本身**不动** —— folder 只是个 metadata 索引。
/// 好处:relativePath 作为 stable id 的全局假设不破,所有 distill / archive /
/// weight / staging 逻辑零改动。
///
/// 设计约束(用户原话):
/// - **3+ 个相似 event 才开 folder**(EventClassifier 内部保证,Store 不强制)
/// - 一个 event 只能属一个 folder(简化模型;cross-cutting 主题继续靠 tags)
/// - **项目/大事件级别**的粒度:"My-Portrait" ✅ "audio" ❌
struct EventFolder: Codable, Sendable, Identifiable, Equatable {
    /// 文件名 slug。kebab-case ASCII,跟 portrait 的 slug 规则一致。
    /// 用作 _folders/<slug>.json 的文件名 + 在 LLM prompt 里作为 stable id。
    let slug: String
    /// 用户可见的名字。"My Portrait" / "Valis" / "UCI Application"。
    var name: String
    /// 一句话说明这个 folder 装什么。给 EventClassifier LLM 看着判断 "新 event
    /// 该不该归这里"。例:"All work on the My Portrait macOS app — bugs, releases, UI."
    var description: String
    /// folder 内的事件 relativePath(events/<day>/<slug>.md 形式)。**保序** ——
    /// 按加入顺序追加,UI 倒序展示等于"最新在前"。
    var events: [String]
    /// folder 创建时间戳(UTC ms)。UI 显示 + 调试用。
    let createdAtMs: Int64
    /// 上次有事件被分进来(或被移走)的时间。
    var updatedAtMs: Int64

    var id: String { slug }

    /// 当前 folder 内事件总数(给 UI / classifier 看)。
    var count: Int { events.count }
}
