import XCTest
@testable import MyPortrait

final class PersonalityAgentTests: XCTestCase {

    /// LLM 返回的 JSON 形状能 decode 进 PersonalityDailySnapshot（契约测试）。
    func testSnapshotDecodesFromLLMJSON() throws {
        let json = """
        {
          "date": "2026-05-11",
          "summary": "While releasing My Orphies the user tightened many small parts.",
          "observedTraits": ["cross-checks details across tools", "interleaves planning with execution"],
          "evidenceEventIds": ["2026-05-11_set_up_and_release_my_orphies_app"]
        }
        """
        let s = try JSONDecoder().decode(PersonalityDailySnapshot.self,
                                         from: Data(json.utf8))
        XCTAssertEqual(s.date, "2026-05-11")
        XCTAssertEqual(s.observedTraits.count, 2)
        XCTAssertEqual(s.evidenceEventIds, ["2026-05-11_set_up_and_release_my_orphies_app"])
        XCTAssertTrue(s.summary.contains("My Orphies"))
    }

    /// 空事件日：短路返回空 snapshot，不调 LLM。
    @MainActor
    func testEmptyEventsShortCircuits() async throws {
        let agent = PersonalityAgent()
        let day = PortraitFile.truncateToDay(Date())
        let snap = try await agent.generateDailySnapshot(date: day, events: [])
        XCTAssertTrue(snap.observedTraits.isEmpty)
        XCTAssertTrue(snap.evidenceEventIds.isEmpty)
        XCTAssertFalse(snap.date.isEmpty)
    }
}
