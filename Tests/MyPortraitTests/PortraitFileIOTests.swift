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

    /// 老文件缺 Phase 3 字段 → 读出默认值（mergeCount 1 / nil / [] / =created）。
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

        XCTAssertEqual(f.mergeCount, 1)
        XCTAssertNil(f.primaryLabel)
        XCTAssertEqual(f.aliases, [])
        XCTAssertEqual(f.lastModified, f.created)
    }
}
