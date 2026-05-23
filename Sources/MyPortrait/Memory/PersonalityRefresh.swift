import Foundation
import os.log

private let prLog = Logger(subsystem: "com.myportrait.memory", category: "personality-refresh")

/// 三源 personality 流水线的总装:
///   - events  → PersonalityAgent.generateDailySnapshot
///   - portraits(其他板块) → PortraitToTagsAgent
///   - OCR(当天) → OCRToTagsAgent
/// 把候选合一后,丢给 PersonalityMerger.merge → applyActions 落盘。
@MainActor
final class PersonalityRefresh {

    struct Report: Sendable {
        let day: Date
        let eventCount: Int
        let eventCandidates: Int
        let portraitInputs: Int
        let portraitCandidates: Int
        let ocrCandidates: Int
        let clusterCount: Int
        let existingConceptCount: Int
        let actions: [PersonalityMergeAction]
        let apply: PersonalityMerger.ApplyResult
    }

    private let model: String
    /// cluster 这步用更轻的模型(默认 gpt-5.4-mini)。轻语义聚类任务不值得
    /// 烧主模型,而且 mini 在这种"列一堆 tag 分组"的任务里反而决断更利索。
    private let clusterModel: String
    init(model: String = "gpt-5.4",
         clusterModel: String = "gpt-5.4-mini") {
        self.model = model
        self.clusterModel = clusterModel
    }

    func refresh(day: Date, writeDailySnapshot: Bool = true) async throws -> Report {

        // ── 1) events 源 ──────────────────────────────────────────────
        let events = await PersonalityAgent.readEvents(for: day)
        let snapshot = try await PersonalityAgent(model: model)
            .generateDailySnapshot(date: day, events: events)
        if writeDailySnapshot {
            _ = try? PersonalityDailyStore.write(snapshot)
        }
        let eventsCandidates: [PersonalityTagCandidate] = snapshot.tags.map {
            PersonalityTagCandidate(tag: $0.name, source: .events, evidence: $0.evidence)
        }

        // ── 2) portraits 源 ───────────────────────────────────────────
        let portraitInputs = PortraitToTagsAgent.collectPortraits()
        var portraitCandidates: [PersonalityTagCandidate] = []
        if !portraitInputs.isEmpty {
            let pttResult = try await PortraitToTagsAgent(model: model)
                .extract(portraits: portraitInputs)
            for entry in pttResult {
                for tag in entry.tags {
                    portraitCandidates.append(
                        PersonalityTagCandidate(tag: tag, source: .portraits,
                                                evidence: [entry.path]))
                }
            }
        }

        // ── 3) OCR 源 ─────────────────────────────────────────────────
        let timeline = TimelineDB()
        let ocrTags = try await OCRToTagsAgent(model: model)
            .extract(forDay: day, timeline: timeline)
        let dayStr = Self.formatDay(PortraitFile.truncateToDay(day))
        let ocrCandidates: [PersonalityTagCandidate] = ocrTags.map {
            PersonalityTagCandidate(tag: $0, source: .ocr, evidence: [dayStr])
        }

        // ── 4) 语义聚类(去重 + 收敛同义) ───────────────────────────
        let all = eventsCandidates + portraitCandidates + ocrCandidates
        let clusterAgent = PersonalityClusterAgent(model: clusterModel)
        let clusters = try await clusterAgent.cluster(candidates: all)

        // ── 5) merge 决策(per-cluster) + 落盘 ──────────────────────
        let existing = await PersonalityMerger.readConcepts()
        let merger = PersonalityMerger(model: model)
        let actions = try await merger.merge(clusters: clusters, existingConcepts: existing)
        let apply = try merger.applyActions(actions, on: day)

        return Report(
            day: day,
            eventCount: events.count,
            eventCandidates: eventsCandidates.count,
            portraitInputs: portraitInputs.count,
            portraitCandidates: portraitCandidates.count,
            ocrCandidates: ocrCandidates.count,
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
