import XCTest
@testable import MyPortrait

/// TranscriptDeduper 纯逻辑单测。
/// 案例来自 2026-06-10 真实外放通话(微信,远端 Stan 被 mic + loopback 双录)。
final class TranscriptDeduperTests: XCTestCase {

    private func seg(
        id: Int64? = nil, startMs: Int64, endMs: Int64,
        text: String, speaker: Int? = nil
    ) -> TranscriptDeduper.Segment {
        TranscriptDeduper.Segment(
            id: id, absStartMs: startMs, absEndMs: endMs,
            speakerId: speaker, text: text)
    }

    // MARK: - 归一化

    /// 繁简同句拼音归一后相等(两路 Whisper 输出常一繁一简)。
    func testNormalizeUnifiesSimplifiedAndTraditional() {
        XCTAssertEqual(
            TranscriptDeduper.normalize("現在他們還有這種東西搞什麼飢餓營銷"),
            TranscriptDeduper.normalize("现在他们还有这种东西搞什么饥饿营销"))
    }

    func testNormalizeStripsPunctuationAndCase() {
        XCTAssertEqual(TranscriptDeduper.normalize("Thank you."), "thankyou")
        XCTAssertEqual(TranscriptDeduper.normalize("Thank You"), "thankyou")
    }

    // MARK: - isDuplicate

    /// 真实案例:23:58:28 同句双份(文本全同,时间同)→ 重复。
    func testIdenticalCrossChannelIsDuplicate() {
        let mic  = seg(startMs: 0, endMs: 4_000, text: "現在他們還有這種東西搞什麼飢餓營銷")
        let loop = seg(startMs: 500, endMs: 4_500, text: "现在他们还有这种东西搞什么饥饿营销")
        XCTAssertTrue(TranscriptDeduper.isDuplicate(mic, loop))
    }

    /// 真实案例:23:58:21 mic「迪安福是嗎他這個是」vs 23:58:23 loopback
    /// 「是吗他这个是」—— 分段边界不同+繁简混杂,靠包含匹配。
    func testContainmentAcrossSegmentBoundaries() {
        let mic  = seg(startMs: 0, endMs: 5_000, text: "迪安福是嗎他這個是")
        let loop = seg(startMs: 2_000, endMs: 5_500, text: "是吗他这个是")
        XCTAssertTrue(TranscriptDeduper.isDuplicate(mic, loop))
    }

    /// 文本不同 → 不重复(即使时间重叠)。
    func testDifferentTextIsNotDuplicate() {
        let a = seg(startMs: 0, endMs: 3_000, text: "他六月二十二号就用不了了")
        let b = seg(startMs: 0, endMs: 3_000, text: "为什么用不了")
        XCTAssertFalse(TranscriptDeduper.isDuplicate(a, b))
    }

    /// 时间窗外(间隔 > slack,无重叠)→ 不重复(防把正常的复读去重掉)。
    func testNonOverlappingTimeIsNotDuplicate() {
        let a = seg(startMs: 0, endMs: 2_000, text: "为什么用不了")
        let b = seg(startMs: 60_000, endMs: 62_000, text: "为什么用不了")
        XCTAssertFalse(TranscriptDeduper.isDuplicate(a, b))
    }

    /// 说话人都识别出来且不同 → 不重复(我跟着对方说了同样的话不是回录)。
    func testDifferentIdentifiedSpeakersIsNotDuplicate() {
        let a = seg(startMs: 0, endMs: 2_000, text: "为什么用不了", speaker: 1)
        let b = seg(startMs: 500, endMs: 2_500, text: "为什么用不了", speaker: 2)
        XCTAssertFalse(TranscriptDeduper.isDuplicate(a, b))
        // 同说话人 → 正常判重复。
        let c = seg(startMs: 500, endMs: 2_500, text: "为什么用不了", speaker: 1)
        XCTAssertTrue(TranscriptDeduper.isDuplicate(a, c))
    }

    /// 短文本只认全等:「嗯」对「嗯」是重复,「嗯」对「好」不是,
    /// 且「嗯」不得通过包含规则误命中长句。
    func testShortTextRequiresExactMatch() {
        let en1 = seg(startMs: 0, endMs: 1_000, text: "嗯。")
        let en2 = seg(startMs: 200, endMs: 1_200, text: "嗯")
        let hao = seg(startMs: 200, endMs: 1_200, text: "好")
        let long = seg(startMs: 0, endMs: 3_000, text: "嗯现在他们还有这种东西")
        XCTAssertTrue(TranscriptDeduper.isDuplicate(en1, en2))
        XCTAssertFalse(TranscriptDeduper.isDuplicate(en1, hao))
        XCTAssertFalse(TranscriptDeduper.isDuplicate(en1, long))
    }

    /// 英文 Whisper 幻觉双份("Thank you." × 2)同样去重。
    func testEnglishDuplicate() {
        let a = seg(startMs: 0, endMs: 1_500, text: "Thank you.")
        let b = seg(startMs: 300, endMs: 1_800, text: "Thank you")
        XCTAssertTrue(TranscriptDeduper.isDuplicate(a, b))
    }

    // MARK: - duplicateMicIds(历史清理批量版)

    func testDuplicateMicIdsFindsOnlyEchoedSegments() {
        let mic = [
            // Joy 自己说话:loopback 没有 → 保留。
            seg(id: 1, startMs: 0, endMs: 3_000, text: "他六月二十二号就用不了了"),
            // Stan 外放回录:loopback 有同句 → 删。
            seg(id: 2, startMs: 10_000, endMs: 13_000, text: "為什麼用不了"),
            // Stan 外放回录(分段边界不同,包含)→ 删。
            seg(id: 3, startMs: 20_000, endMs: 25_000, text: "迪安福是嗎他這個是"),
            // 时间远处的同文本:窗外 → 保留。
            seg(id: 4, startMs: 300_000, endMs: 302_000, text: "为什么用不了"),
        ]
        let loopback = [
            seg(id: 101, startMs: 10_500, endMs: 13_200, text: "为什么用不了"),
            seg(id: 102, startMs: 22_000, endMs: 25_500, text: "是吗他这个是"),
        ]
        XCTAssertEqual(
            TranscriptDeduper.duplicateMicIds(mic: mic, loopback: loopback).sorted(),
            [2, 3])
    }

    func testDuplicateMicIdsEmptyInputs() {
        XCTAssertTrue(TranscriptDeduper.duplicateMicIds(mic: [], loopback: []).isEmpty)
        let mic = [seg(id: 1, startMs: 0, endMs: 1_000, text: "嗯")]
        XCTAssertTrue(TranscriptDeduper.duplicateMicIds(mic: mic, loopback: []).isEmpty)
    }
}
