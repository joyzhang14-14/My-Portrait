import XCTest
@testable import MyPortrait

/// 写作采集 Step 0 算法预压缩单测。
/// 不碰 DB,只测纯算法。
final class WritingCaptureStep0Tests: XCTestCase {

    // MARK: - Jaccard / tokenize

    func testTokenizeEnglish() {
        let s = "Hello world, this is a test"
        let t = WritingCaptureStep0.tokenize(s)
        XCTAssertTrue(t.contains("Hello"))
        XCTAssertTrue(t.contains("world"))
        XCTAssertTrue(t.contains("test"))
    }

    func testTokenizeChinese() {
        // 中文每个字一个 token
        let s = "今天天气真好"
        let t = WritingCaptureStep0.tokenize(s)
        XCTAssertEqual(t, ["今", "天", "气", "真", "好"])
        // 注: "天" 是同字符,Set 去重 → 5 个 unique tokens
    }

    func testJaccardIdentical() {
        let s = WritingCaptureStep0.tokenize("hello world")
        XCTAssertEqual(WritingCaptureStep0.jaccard(s, s), 1.0)
    }

    func testJaccardEmpty() {
        let empty: Set<String> = []
        XCTAssertEqual(WritingCaptureStep0.jaccard(empty, empty), 1.0)
        let a = WritingCaptureStep0.tokenize("a")
        XCTAssertEqual(WritingCaptureStep0.jaccard(a, empty), 0.0)
    }

    func testJaccardPartial() {
        let a = WritingCaptureStep0.tokenize("hello world foo")
        let b = WritingCaptureStep0.tokenize("hello world bar")
        // 交集 = {hello, world} = 2,并集 = {hello, world, foo, bar} = 4
        XCTAssertEqual(WritingCaptureStep0.jaccard(a, b), 0.5)
    }

    // MARK: - OCR dedupe

    func testOcrDedupePreservesTwoEndpoints() {
        // 子段只有两帧时强制保留首尾，即使文本相同。
        let frames = [
            WritingCaptureRawOcr(id: 1, tsMs: 1000, app: "obs", url: nil, text: "Hello world this is text"),
            WritingCaptureRawOcr(id: 2, tsMs: 2000, app: "obs", url: nil, text: "Hello world this is text")
        ]
        let deduped = WritingCaptureStep0.jaccardDedupe(frames)
        XCTAssertEqual(deduped.count, 2)
        XCTAssertEqual(deduped[0].frameId, 1)
        XCTAssertEqual(deduped[0].startTs, 1000)
        XCTAssertEqual(deduped[1].frameId, 2)
        XCTAssertEqual(deduped[1].startTs, 2000)
    }

    func testOcrDedupeDifferent() {
        // 内容差距大 → 不合并
        let frames = [
            WritingCaptureRawOcr(id: 1, tsMs: 1000, app: "obs", url: nil, text: "First content here"),
            WritingCaptureRawOcr(id: 2, tsMs: 2000, app: "obs", url: nil, text: "Completely different stuff")
        ]
        let deduped = WritingCaptureStep0.jaccardDedupe(frames)
        XCTAssertEqual(deduped.count, 2)
    }

    func testOcrDedupeMergesSimilarMiddleFrames() {
        // 首尾强制保留，两个相同的中间帧合并。
        let frames = [
            WritingCaptureRawOcr(id: 1, tsMs: 1000, app: "a", url: nil,
                text: "first endpoint"),
            WritingCaptureRawOcr(id: 2, tsMs: 2000, app: "a", url: nil,
                text: "alpha beta gamma delta epsilon zeta eta theta iota kappa"),
            WritingCaptureRawOcr(id: 3, tsMs: 3000, app: "a", url: nil,
                text: "alpha beta gamma delta epsilon zeta eta theta iota kappa"),
            WritingCaptureRawOcr(id: 4, tsMs: 4000, app: "a", url: nil,
                text: "last endpoint")
        ]
        let deduped = WritingCaptureStep0.jaccardDedupe(frames)
        XCTAssertEqual(deduped.count, 3)
        XCTAssertEqual(deduped[0].startTs, 1000)
        XCTAssertEqual(deduped[1].startTs, 2000)
        XCTAssertEqual(deduped[1].endTs, 3000)
        XCTAssertEqual(deduped[2].startTs, 4000)
    }

    // MARK: - throwaway / max content chars

    func testMaxContentCharsTypingOnly() {
        let evts = [
            TypingEvent(id: nil, bundleId: "a", elementHash: 0, startedAt: 0, endedAt: 1,
                        text: "hello", editLog: "[]", totalChars: 5),
            TypingEvent(id: nil, bundleId: "a", elementHash: 0, startedAt: 2, endedAt: 3,
                        text: "world", editLog: "[]", totalChars: 5)
        ]
        let max = WritingCaptureStep0.computeMaxContentChars(typingEvents: evts, ocrFrames: [])
        XCTAssertEqual(max, 10)  // hello + world 拼起来
    }

    func testMaxContentCharsOcrOnly() {
        let frames = [
            WritingCaptureOcrFrame(frameId: 1, startTs: 0, endTs: 1, app: "a", url: nil,
                                   text: "long ocr text here for sure"),
            WritingCaptureOcrFrame(frameId: 2, startTs: 2, endTs: 3, app: "a", url: nil,
                                   text: "short")
        ]
        let max = WritingCaptureStep0.computeMaxContentChars(typingEvents: [], ocrFrames: frames)
        XCTAssertEqual(max, 27)  // max 帧的 text 长度
    }

    func testMaxContentCharsTypingVsOcr() {
        let evts = [
            TypingEvent(id: nil, bundleId: "a", elementHash: 0, startedAt: 0, endedAt: 1,
                        text: "abc", editLog: "[]", totalChars: 3)
        ]
        let frames = [
            WritingCaptureOcrFrame(frameId: 1, startTs: 0, endTs: 1, app: "a", url: nil,
                                   text: "a much longer ocr frame")
        ]
        let max = WritingCaptureStep0.computeMaxContentChars(typingEvents: evts, ocrFrames: frames)
        XCTAssertEqual(max, 23)  // 取大
    }

    // MARK: - segment + merge candidates

    func testSegmentIdleGap() {
        // 第一个 typing event 在 0,第二个 在 6 分钟后(超过 5 分钟 threshold)
        // → 切成 2 个 session
        let evts = [
            TypingEvent(id: nil, bundleId: "a", elementHash: 0, startedAt: 0, endedAt: 1000,
                        text: "first session content here long enough", editLog: "[]", totalChars: 35),
            TypingEvent(id: nil, bundleId: "a", elementHash: 0, startedAt: 6 * 60 * 1000, endedAt: 6 * 60 * 1000 + 1000,
                        text: "second session content here long enough too", editLog: "[]", totalChars: 40)
        ]
        let sessions = WritingCaptureStep0.segmentSessions(
            typingEvents: evts, keystrokes: [], ocrFrames: []
        )
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].typingEvents.count, 1)
        XCTAssertEqual(sessions[1].typingEvents.count, 1)
    }

    func testSegmentAppChange() {
        // 两个 typing 紧挨着但 app 不同 → 切 2 个 session
        let evts = [
            TypingEvent(id: nil, bundleId: "a", elementHash: 0, startedAt: 0, endedAt: 1000,
                        text: "in app a long enough content here yes", editLog: "[]", totalChars: 35),
            TypingEvent(id: nil, bundleId: "b", elementHash: 0, startedAt: 2000, endedAt: 3000,
                        text: "in app b also long enough content here yes", editLog: "[]", totalChars: 40)
        ]
        let sessions = WritingCaptureStep0.segmentSessions(
            typingEvents: evts, keystrokes: [], ocrFrames: []
        )
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].app, "a")
        XCTAssertEqual(sessions[1].app, "b")
    }

    func testMergeCandidatesSameAppNearby() {
        // 两个同 app 同 url 的 session 间隔 < 30min → 一组
        let s1 = WritingCaptureRawSession(
            id: "sess_a", app: "obs", url: nil,
            startTs: 0, endTs: 60_000,
            typingEvents: [], keystrokes: [], ocrFrames: [], maxContentChars: 100
        )
        let s2 = WritingCaptureRawSession(
            id: "sess_b", app: "obs", url: nil,
            startTs: 10 * 60 * 1000, endTs: 11 * 60 * 1000,
            typingEvents: [], keystrokes: [], ocrFrames: [], maxContentChars: 100
        )
        let groups = WritingCaptureStep0.computeMergeCandidates([s1, s2])
        XCTAssertEqual(groups, [["sess_a", "sess_b"]])
    }

    func testMergeCandidatesAppChangeBreaksGroup() {
        let s1 = WritingCaptureRawSession(
            id: "sess_a", app: "obs", url: nil,
            startTs: 0, endTs: 60_000,
            typingEvents: [], keystrokes: [], ocrFrames: [], maxContentChars: 100
        )
        let s2 = WritingCaptureRawSession(
            id: "sess_b", app: "slack", url: nil,
            startTs: 5 * 60 * 1000, endTs: 6 * 60 * 1000,
            typingEvents: [], keystrokes: [], ocrFrames: [], maxContentChars: 100
        )
        let groups = WritingCaptureStep0.computeMergeCandidates([s1, s2])
        XCTAssertEqual(groups, [["sess_a"], ["sess_b"]])
    }

    func testMergeCandidatesGap30MinBreaks() {
        let s1 = WritingCaptureRawSession(
            id: "sess_a", app: "obs", url: nil,
            startTs: 0, endTs: 60_000,
            typingEvents: [], keystrokes: [], ocrFrames: [], maxContentChars: 100
        )
        // 间隔 35 分钟(从 60_000 ms 到 35*60*1000 ms = gap > 30min)
        let s2 = WritingCaptureRawSession(
            id: "sess_b", app: "obs", url: nil,
            startTs: 35 * 60 * 1000, endTs: 36 * 60 * 1000,
            typingEvents: [], keystrokes: [], ocrFrames: [], maxContentChars: 100
        )
        let groups = WritingCaptureStep0.computeMergeCandidates([s1, s2])
        XCTAssertEqual(groups, [["sess_a"], ["sess_b"]])
    }

    // MARK: - throwaway filter

    func testThrowawayFilterKeepsAnyTyping() {
        // 新规则:任何 typing_events 一律直通(短输出是 speech-style 信号);
        // 只过滤"纯 OCR 0-typing 且 OCR 太短"的会话。
        let shortEvt = TypingEvent(id: nil, bundleId: "a", elementHash: 0, startedAt: 0, endedAt: 1000,
                                    text: "ok", editLog: "[]", totalChars: 2)
        let longEvt = TypingEvent(id: nil, bundleId: "b", elementHash: 0, startedAt: 10 * 60 * 1000, endedAt: 10 * 60 * 1000 + 1000,
                                   text: "this is a long enough writing session here yes", editLog: "[]", totalChars: 45)
        let output = WritingCaptureStep0.preprocess(
            typingEvents: [shortEvt, longEvt],
            keystrokes: [],
            rawOcrFrames: []
        )
        // 两个 session 都该保留(typing 一律不丢)
        XCTAssertEqual(output.rawSessions.count, 2)
        XCTAssertEqual(output.throwawaySessions.count, 0)
    }

    func testPureOcrNoTypingNorKeystrokeProducesNoSession() {
        // 新语义:纯 OCR 没 typing/keystroke 锚点 → 不形成 session
        // (OCR 是反向 join 进来的上下文,自己不切 session)
        let frame = WritingCaptureRawOcr(
            id: 1, tsMs: 0, app: "snipaste", url: nil, text: "Some text"
        )
        let output = WritingCaptureStep0.preprocess(
            typingEvents: [], keystrokes: [], rawOcrFrames: [frame]
        )
        XCTAssertEqual(output.rawSessions.count, 0)
        XCTAssertEqual(output.throwawaySessions.count, 0)
    }
}
