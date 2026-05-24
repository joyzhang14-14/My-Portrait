import XCTest
@testable import MyPortrait

@MainActor
final class WritingCapturePass2AgentTests: XCTestCase {

    // MARK: - parse

    func testParseValidFullOutput() throws {
        let raw = """
        {
          "records": [
            {
              "text": "今天天气真好",
              "edit_log": [
                {"kind":"commit","text":"今天","ts":1716393600000},
                {"kind":"commit","text":"天气真好","ts":1716393601000}
              ],
              "kind": "long_form",
              "source": "ax_cleaned",
              "confidence": 0.85,
              "context_summary": "Journal entry",
              "app": "md.obsidian",
              "url": null,
              "start_ts": 1716393600000,
              "end_ts": 1716393700000,
              "reference_typing_event_ids": [123, 124],
              "reference_frame_ids": [456, 457],
              "reference_keystroke_range": {"start": 1716393600000, "end": 1716393700000}
            }
          ],
          "discarded": [
            {
              "reason": "search query the user typed but did not commit",
              "session_ids": ["sess_abc"],
              "preview": "量子力学"
            }
          ]
        }
        """
        let (recs, disc) = try WritingCapturePass2Agent.parse(from: raw)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].text, "今天天气真好")
        XCTAssertEqual(recs[0].kind, "long_form")
        XCTAssertEqual(recs[0].source, "ax_cleaned")
        XCTAssertEqual(recs[0].editLog.count, 2)
        XCTAssertEqual(recs[0].referenceKeystrokeRange.start, 1716393600000)
        XCTAssertEqual(disc.count, 1)
        XCTAssertEqual(disc[0].sessionIds, ["sess_abc"])
    }

    func testParseEmpty() throws {
        let raw = #"{"records": [], "discarded": []}"#
        let (recs, disc) = try WritingCapturePass2Agent.parse(from: raw)
        XCTAssertEqual(recs.count, 0)
        XCTAssertEqual(disc.count, 0)
    }

    func testParseInvalidKind() {
        let raw = """
        {
          "records": [{
            "text": "x", "edit_log": [], "kind": "WRONG", "source": "ax_cleaned", "confidence": 0.5,
            "context_summary": null, "app": "a", "url": null,
            "start_ts": 0, "end_ts": 1,
            "reference_typing_event_ids": [], "reference_frame_ids": [],
            "reference_keystroke_range": {"start": 0, "end": 1}
          }],
          "discarded": []
        }
        """
        XCTAssertThrowsError(try WritingCapturePass2Agent.parse(from: raw)) { err in
            guard case WritingCapturePass2Agent.AgentError.malformedJSON(let m) = err,
                  m.contains("kind") else {
                return XCTFail("expected malformedJSON(kind), got \(err)")
            }
        }
    }

    func testParseInvalidSource() {
        let raw = """
        {
          "records": [{
            "text": "x", "edit_log": [], "kind": "long_form", "source": "WRONG", "confidence": 0.5,
            "context_summary": null, "app": "a", "url": null,
            "start_ts": 0, "end_ts": 1,
            "reference_typing_event_ids": [], "reference_frame_ids": [],
            "reference_keystroke_range": {"start": 0, "end": 1}
          }],
          "discarded": []
        }
        """
        XCTAssertThrowsError(try WritingCapturePass2Agent.parse(from: raw)) { err in
            guard case WritingCapturePass2Agent.AgentError.malformedJSON(let m) = err,
                  m.contains("source") else {
                return XCTFail("expected malformedJSON(source), got \(err)")
            }
        }
    }

    func testParseConfidenceOutOfRange() {
        let raw = """
        {
          "records": [{
            "text": "x", "edit_log": [], "kind": "long_form", "source": "ax_cleaned", "confidence": 1.5,
            "context_summary": null, "app": "a", "url": null,
            "start_ts": 0, "end_ts": 1,
            "reference_typing_event_ids": [], "reference_frame_ids": [],
            "reference_keystroke_range": {"start": 0, "end": 1}
          }],
          "discarded": []
        }
        """
        XCTAssertThrowsError(try WritingCapturePass2Agent.parse(from: raw)) { err in
            guard case WritingCapturePass2Agent.AgentError.malformedJSON(let m) = err,
                  m.contains("confidence") else {
                return XCTFail("expected malformedJSON(confidence), got \(err)")
            }
        }
    }

    func testParseDiscardedFreeTextReason() throws {
        // discarded.reason 现在是自由文本(无 enum 前缀要求)
        let raw = """
        {
          "records": [],
          "discarded": [{"reason": "anything goes here, no prefix needed", "session_ids": ["a"], "preview": "x"}]
        }
        """
        let (_, disc) = try WritingCapturePass2Agent.parse(from: raw)
        XCTAssertEqual(disc.count, 1)
        XCTAssertEqual(disc[0].reason, "anything goes here, no prefix needed")
    }

    func testParseNoJSON() {
        let raw = "I cannot process this"
        XCTAssertThrowsError(try WritingCapturePass2Agent.parse(from: raw)) { err in
            guard case WritingCapturePass2Agent.AgentError.malformedJSON = err else {
                return XCTFail("expected malformedJSON, got \(err)")
            }
        }
    }

    // MARK: - buildPrompt

    func testBuildPromptEmpty() {
        let p = WritingCapturePass2Agent.buildPrompt(
            contextTimeline: [],
            groupApp: "obs",
            groupUrl: nil,
            rawSessions: []
        )
        XCTAssertTrue(p.contains("context_timeline:"))
        XCTAssertTrue(p.contains("group_meta:"))
        XCTAssertTrue(p.contains("raw_sessions:"))
    }

    func testBuildPromptWithData() {
        let timeline = [
            WritingCaptureContextSegment(
                startTs: 1000, endTs: 2000, app: "obs", url: nil,
                intentType: "writing", summary: "writing notes"
            )
        ]
        let evt = TypingEvent(
            id: 42, bundleId: "obs", elementHash: 0,
            startedAt: 1100, endedAt: 1200,
            text: "hello world test", editLog: "[]", totalChars: 16
        )
        let session = WritingCaptureRawSession(
            id: "sess_001", app: "obs", url: nil,
            startTs: 1100, endTs: 1200,
            typingEvents: [evt],
            keystrokes: [],
            ocrFrames: [],
            maxContentChars: 16
        )
        let p = WritingCapturePass2Agent.buildPrompt(
            contextTimeline: timeline,
            groupApp: "obs",
            groupUrl: nil,
            rawSessions: [session]
        )
        XCTAssertTrue(p.contains("\"intent_type\":\"writing\""))
        XCTAssertTrue(p.contains("\"session_id\":\"sess_001\""))
        XCTAssertTrue(p.contains("\"typing_events\""))
        XCTAssertTrue(p.contains("\"keystroke_log\""))
        XCTAssertTrue(p.contains("\"ocr_frames\""))
        XCTAssertTrue(p.contains("\"app\":\"obs\""))
        XCTAssertTrue(p.contains("\"id\":42"))
        XCTAssertTrue(p.contains("hello world test"))
    }
}
