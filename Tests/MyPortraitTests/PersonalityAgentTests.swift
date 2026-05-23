import XCTest
@testable import MyPortrait

final class PersonalityAgentTests: XCTestCase {

    /// LLM 返回的 v3 JSON（tags + 各自 evidence）能 decode（契约测试）。
    func testSnapshotDecodesFromLLMJSON() throws {
        let json = """
        {
          "date": "2026-05-11",
          "tags": [
            { "name": "verification", "evidence": ["set_up_my_orphies_app", "inspected_update_settings"] },
            { "name": "background-audio", "evidence": ["listened_to_music"] }
          ]
        }
        """
        let s = try JSONDecoder().decode(PersonalityDailySnapshot.self,
                                         from: Data(json.utf8))
        XCTAssertEqual(s.date, "2026-05-11")
        XCTAssertEqual(s.tags.count, 2)
        XCTAssertEqual(s.tags[0].name, "verification")
        XCTAssertEqual(s.tags[0].evidence, ["set_up_my_orphies_app", "inspected_update_settings"])
        XCTAssertEqual(s.tags[1].name, "background-audio")
    }

    /// 空事件日：短路返回空 tags，不调 LLM。
    @MainActor
    func testEmptyEventsShortCircuits() async throws {
        let agent = PersonalityAgent()
        let day = PortraitFile.truncateToDay(Date())
        let snap = try await agent.generateDailySnapshot(date: day, events: [])
        XCTAssertTrue(snap.tags.isEmpty)
        XCTAssertFalse(snap.date.isEmpty)
    }
}

final class PersonalityMergerTests: XCTestCase {

    /// cluster 为空 → merge 短路返回 []，不调 LLM。
    @MainActor
    func testMergeShortCircuitsOnEmptyClusters() async throws {
        let actions = try await PersonalityMerger().merge(
            clusters: [], existingConcepts: [])
        XCTAssertTrue(actions.isEmpty)
    }
}
