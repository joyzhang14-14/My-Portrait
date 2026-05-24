import XCTest
@testable import MyPortrait

/// Pass 1 Agent 的纯函数单测(prompt 拼接 + JSON 解析)。
/// 不调真 LLM。
@MainActor
final class WritingCapturePass1AgentTests: XCTestCase {

    // MARK: - parse

    func testParseValidTimeline() throws {
        let raw = """
        {
          "timeline": [
            {
              "start_ts": 1716393600000,
              "end_ts": 1716393900000,
              "app": "md.obsidian",
              "url": null,
              "intent_type": "writing",
              "summary": "Drafting design doc"
            },
            {
              "start_ts": 1716394000000,
              "end_ts": 1716394500000,
              "app": "com.apple.Safari",
              "url": "https://google.com/search",
              "intent_type": "search",
              "summary": "Looking up React hooks"
            }
          ]
        }
        """
        let parsed = try WritingCapturePass1Agent.parse(from: raw)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].app, "md.obsidian")
        XCTAssertNil(parsed[0].url)
        XCTAssertEqual(parsed[0].intentType, "writing")
        XCTAssertEqual(parsed[1].url, "https://google.com/search")
        XCTAssertEqual(parsed[1].intentType, "search")
    }

    func testParseEmptyTimeline() throws {
        let raw = #"{"timeline": []}"#
        let parsed = try WritingCapturePass1Agent.parse(from: raw)
        XCTAssertEqual(parsed.count, 0)
    }

    func testParseInvalidIntentType() {
        let raw = """
        {
          "timeline": [
            {"start_ts": 0, "end_ts": 1, "app": "a", "url": null,
             "intent_type": "GARBAGE", "summary": "x"}
          ]
        }
        """
        XCTAssertThrowsError(try WritingCapturePass1Agent.parse(from: raw)) { err in
            guard case WritingCapturePass1Agent.AgentError.malformedJSON = err else {
                return XCTFail("expected malformedJSON, got \(err)")
            }
        }
    }

    func testParseNoJSON() {
        let raw = "Sorry, I couldn't process that."
        XCTAssertThrowsError(try WritingCapturePass1Agent.parse(from: raw)) { err in
            guard case WritingCapturePass1Agent.AgentError.malformedJSON(let m) = err,
                  m.contains("noJSONInResponse") else {
                return XCTFail("expected malformedJSON(noJSONInResponse), got \(err)")
            }
        }
    }

    func testParseWithSurroundingProse() throws {
        // LLM 有时候在 JSON 前后加一点废话,parse 应该能撑住
        let raw = """
        Here is the timeline:
        {"timeline": [{"start_ts":0,"end_ts":1,"app":"a","url":null,
                       "intent_type":"writing","summary":"x"}]}
        Hope that helps!
        """
        let parsed = try WritingCapturePass1Agent.parse(from: raw)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].app, "a")
    }

    // MARK: - buildPrompt

    func testBuildPromptEmpty() {
        let p = WritingCapturePass1Agent.buildPrompt(ocrFrames: [])
        // 包含 system 指令 + 空数组
        XCTAssertTrue(p.contains("You analyze a day's worth of OCR data"))
        XCTAssertTrue(p.contains("ocr_frames:"))
        XCTAssertTrue(p.contains("[]"))
    }

    func testBuildPromptWithFrames() {
        let frames = [
            WritingCaptureOcrFrame(
                frameId: 1, startTs: 1000, endTs: 2000,
                app: "md.obsidian", url: nil,
                text: "Hello"
            )
        ]
        let p = WritingCapturePass1Agent.buildPrompt(ocrFrames: frames)
        // JSON 应该 snake_case 字段名
        XCTAssertTrue(p.contains("\"frame_id\""))
        XCTAssertTrue(p.contains("\"start_ts\""))
        XCTAssertTrue(p.contains("\"end_ts\""))
        XCTAssertTrue(p.contains("\"app\":\"md.obsidian\""))
        XCTAssertTrue(p.contains("Hello"))
    }
}
