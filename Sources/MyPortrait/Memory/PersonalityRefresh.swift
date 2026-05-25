import Foundation
import os.log

private let prLog = Logger(subsystem: "com.myportrait.memory", category: "personality-refresh")

/// Personality 流水线 v2 总装 —— 不再三源齐发,改成 events 主导 + OCR 验证:
///   1. events 源: 只看 weight > minEventWeight 的高权重事件
///   2. PersonalityAgent → 每个 tag 自带 ocr_keywords(LLM 给的搜索词)
///   3. OCR 验证: 当天命中 ocr_keywords 的帧数必须 ≥ minOCRFrames,
///      不够就丢弃这个 tag
///   4. 幸存 tag 同时以 .events / .ocr 两种来源进 cluster + merge → 落盘
///
/// 其他 portrait 板块(skills / interests / 等)不再做 personality 来源——
/// 信噪比太低,会把 personality 灌成几十个近义 concept。PortraitToTagsAgent
/// 文件保留备查,但 refresh 不再调用。
@MainActor
final class PersonalityRefresh {

    /// 事件权重门槛: weight > 这个值才喂 PersonalityAgent。当前 portrait/
    /// EMA 配置下,事件 weight 分布是 0–7,3 大致圈到全体的 1/3,够拉开
    /// "随手刷一下"和"做了件正经事"的差距。
    nonisolated static let minEventWeight: Double = 3.0
    /// OCR 验证门槛: tag.ocr_keywords 命中的当天帧数 ≥ 这个值才落盘。
    /// 20 帧 ~= 1 分钟的屏幕时间(15s/帧抽样),够说明"不是偶然飘过一眼"。
    nonisolated static let minOCRFrames: Int = 20

    struct Report: Sendable {
        let day: Date
        let eventsTotal: Int          // 当天 events/<day>/ 全量
        let eventsAboveWeight: Int    // 过 minEventWeight 的
        let snapshotTags: Int         // PersonalityAgent 提的 tag 数
        let ocrKept: Int              // OCR 验证通过的 tag 数
        let ocrDropped: Int           // OCR 验证不够 minOCRFrames 被丢的
        let clusterCount: Int
        let existingConceptCount: Int
        let actions: [PersonalityMergeAction]
        let apply: PersonalityMerger.ApplyResult
    }

    private let provider: Provider
    private let model: String
    /// cluster 这步用更轻的模型(默认 gpt-5.4-mini)。轻语义聚类任务不值得
    /// 烧主模型,而且 mini 在这种"列一堆 tag 分组"的任务里反而决断更利索。
    private let clusterModel: String
    init(provider: Provider = .chatgpt,
         model: String = "gpt-5.4",
         clusterModel: String = "gpt-5.4-mini") {
        self.provider = provider
        self.model = model
        self.clusterModel = clusterModel
    }

    func refresh(day: Date, writeDailySnapshot: Bool = true) async throws -> Report {
        let napGuard = AppNapGuard.acquire(reason: "Personality refresh")
        defer { napGuard.release() }
        return try await refreshImpl(day: day, writeDailySnapshot: writeDailySnapshot)
    }

    private func refreshImpl(day: Date, writeDailySnapshot: Bool) async throws -> Report {

        // ── 1) events 源(weight > threshold) ──────────────────────────
        let allEvents = await PersonalityAgent.readEvents(for: day)
        let highWeightEvents = allEvents.filter { $0.file.weight > Self.minEventWeight }
        prLog.notice("events: \(allEvents.count) total → \(highWeightEvents.count) with weight > \(Self.minEventWeight)")

        let snapshot = try await PersonalityAgent(provider: provider, model: model)
            .generateDailySnapshot(date: day, events: highWeightEvents)
        if writeDailySnapshot {
            _ = try? PersonalityDailyStore.write(snapshot)
        }

        // ── 2) OCR 验证: 每个 tag 自带 ocr_keywords,数命中帧数 ────────
        let timeline = TimelineDB()
        var keptCandidates: [PersonalityTagCandidate] = []
        var kept = 0, dropped = 0
        for tag in snapshot.tags {
            guard !tag.ocrKeywords.isEmpty else {
                prLog.notice("tag '\(tag.name, privacy: .public)': no ocr_keywords → drop")
                dropped += 1
                continue
            }
            let frames = timeline.frameCount(on: day, keywords: tag.ocrKeywords)
            if frames < Self.minOCRFrames {
                prLog.notice("tag '\(tag.name, privacy: .public)': \(frames) frame(s) < \(Self.minOCRFrames) → drop (kw=\(tag.ocrKeywords, privacy: .public))")
                dropped += 1
                continue
            }
            prLog.notice("tag '\(tag.name, privacy: .public)': \(frames) frame(s) ≥ \(Self.minOCRFrames) → keep")
            kept += 1
            // events 侧 evidence: event slug 列表
            keptCandidates.append(
                PersonalityTagCandidate(tag: tag.name, source: .events,
                                        evidence: tag.evidence))
            // ocr 侧 evidence: 一行验证记录,落进 concept body 的 ## ocr
            let kwPreview = tag.ocrKeywords.joined(separator: ", ")
            let dayStr = Self.formatDay(PortraitFile.truncateToDay(day))
            keptCandidates.append(
                PersonalityTagCandidate(
                    tag: tag.name, source: .ocr,
                    evidence: ["\(dayStr): \(frames) frames matched [\(kwPreview)]"]))
        }

        // ── 3) 语义聚类(去重 + 收敛同义) ───────────────────────────
        let clusterAgent = PersonalityClusterAgent(provider: provider, model: clusterModel)
        let clusters = try await clusterAgent.cluster(candidates: keptCandidates)

        // ── 4) merge 决策(per-cluster) + 落盘 ──────────────────────
        let existing = await PersonalityMerger.readConcepts()
        let merger = PersonalityMerger(provider: provider, model: model)
        let actions = try await merger.merge(clusters: clusters, existingConcepts: existing)
        let apply = try merger.applyActions(actions, on: day)

        return Report(
            day: day,
            eventsTotal: allEvents.count,
            eventsAboveWeight: highWeightEvents.count,
            snapshotTags: snapshot.tags.count,
            ocrKept: kept,
            ocrDropped: dropped,
            clusterCount: clusters.count,
            existingConceptCount: existing.count,
            actions: actions,
            apply: apply
        )
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func formatDay(_ d: Date) -> String { dayFmt.string(from: d) }
}
