import XCTest
@testable import MyPortrait

final class PortraitFileIOTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
    }

    /// Phase 3 字段（mergeCount / primaryLabel / aliases / lastModified）写读往返。
    func testPhase3FieldsRoundTrip() throws {
        var f = PortraitFile(impact: 3, body: "# T\n\nbody")
        f.mergeCount = 7
        f.primaryLabel = "asks why before how"
        f.aliases = ["questions assumptions", "probes rationale"]
        let lm = PortraitFile.truncateToDay(Date())
        f.lastModified = lm

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try PortraitFileIO.write(f, to: url)
        let back = try PortraitFileIO.read(from: url)

        XCTAssertEqual(back.mergeCount, 7)
        XCTAssertEqual(back.primaryLabel, "asks why before how")
        XCTAssertEqual(back.aliases, ["questions assumptions", "probes rationale"])
        XCTAssertEqual(back.lastModified, lm)
    }

    /// 多段 event_summary（含换行 / 冒号 / 逗号）往返 —— 回归
    /// "扁平 YAML 解析器被多行值打断" 的 bug。
    func testMultilineEventSummaryRoundTrip() throws {
        var f = PortraitFile(impact: 3, body: "# T\n\nbody")
        f.eventSummary = "Para one with a colon: yes, and a comma.\n\nPara two after a blank line."

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try PortraitFileIO.write(f, to: url)
        let back = try PortraitFileIO.read(from: url)

        XCTAssertEqual(back.eventSummary, f.eventSummary)
    }

    /// portrait 文件 impact = nil 往返：序列化时整行 skip，反序列化为 nil。
    func testPortraitImpactNilRoundTrip() throws {
        let f = PortraitFile(impact: nil, body: "# portrait\n\nbody")
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try PortraitFileIO.write(f, to: url)

        // 落盘 frontmatter 不应包含 `impact:` 行。
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("\nimpact:"),
                       "portrait 文件不应序列化 impact 行")

        let back = try PortraitFileIO.read(from: url)
        XCTAssertNil(back.impact)
        // 同源的 3 个 event-only 字段也不该写。
        XCTAssertFalse(raw.contains("\nraw_impact:"))
        XCTAssertFalse(raw.contains("\nrebalance_count:"))
        XCTAssertFalse(raw.contains("\nimpact_source:"))
        XCTAssertNil(back.rawImpact)
        XCTAssertNil(back.rebalanceCount)
        XCTAssertNil(back.impactSource)
    }

    /// event 文件 impact 仍正常往返（非 nil）。
    func testEventImpactRoundTrip() throws {
        let f = PortraitFile(impact: 3.7, body: "# event\n\nbody")
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try PortraitFileIO.write(f, to: url)
        let back = try PortraitFileIO.read(from: url)
        XCTAssertEqual(back.impact, 3.7)
    }

    /// 缺 Phase 3 portrait-layer 字段（event 文件本就不带）→ 读出全 nil。
    func testOldFileDefaultsForMissingPhase3Fields() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let yaml = """
        ---
        created: 2026-05-01
        impact: 3
        raw_impact: 3
        rebalance_count: 0
        impact_source: unscored
        weight: 5
        occurrences: [2026-05-01]
        event_title: "X"
        event_summary: "Y"
        type: experience
        portrait_facets: []
        member_frame_ids: []
        source: null
        tags: []
        superseded_by: null
        pinned: false
        archived_at: null
        ---
        # X

        body
        """
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        let f = try PortraitFileIO.read(from: url)

        XCTAssertNil(f.mergeCount)
        XCTAssertNil(f.primaryLabel)
        XCTAssertNil(f.aliases)
        XCTAssertNil(f.lastModified)
        XCTAssertNil(f.evidenceEventIds)
    }

    /// portrait 专属字段：event 文件不带（序列化时整行 skip）。
    func testEventFileOmitsPortraitFields() throws {
        let f = PortraitFile(impact: 3, body: "# E\n\nbody")   // 便利 init = event
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try PortraitFileIO.write(f, to: url)
        let raw = try String(contentsOf: url, encoding: .utf8)
        for key in ["merge_count:", "primary_label:", "aliases:",
                    "last_modified:", "evidence_event_ids:"] {
            XCTAssertFalse(raw.contains("\n\(key)"), "event 文件不该写 \(key)")
        }
        let back = try PortraitFileIO.read(from: url)
        XCTAssertNil(back.mergeCount)
        XCTAssertNil(back.lastModified)
    }
}
