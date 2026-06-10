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
        XCTAssertTrue(TranscriptDeduper.isDuplicate(mic: mic, loopback: loop))
    }

    /// 真实案例:23:58:21 mic「迪安福是嗎他這個是」vs 23:58:23 loopback
    /// 「是吗他这个是」—— 分段边界不同+繁简混杂,靠包含匹配(loopback 占
    /// mic 的 71%,过 60% 比例门槛)。
    func testContainmentAcrossSegmentBoundaries() {
        let mic  = seg(startMs: 0, endMs: 5_000, text: "迪安福是嗎他這個是")
        let loop = seg(startMs: 2_000, endMs: 5_500, text: "是吗他这个是")
        XCTAssertTrue(TranscriptDeduper.isDuplicate(mic: mic, loopback: loop))
    }

    /// 文本不同 → 不重复(即使时间重叠)。
    func testDifferentTextIsNotDuplicate() {
        let mic  = seg(startMs: 0, endMs: 3_000, text: "他六月二十二号就用不了了")
        let loop = seg(startMs: 0, endMs: 3_000, text: "为什么用不了")
        XCTAssertFalse(TranscriptDeduper.isDuplicate(mic: mic, loopback: loop))
    }

    /// 时间窗外(间隔 > slack,无重叠)→ 不重复(防把正常的复读去重掉)。
    func testNonOverlappingTimeIsNotDuplicate() {
        let mic  = seg(startMs: 0, endMs: 2_000, text: "为什么用不了")
        let loop = seg(startMs: 60_000, endMs: 62_000, text: "为什么用不了")
        XCTAssertFalse(TranscriptDeduper.isDuplicate(mic: mic, loopback: loop))
    }

    /// 说话人都识别出来且不同 → 不重复(我跟着对方说了同样的话不是回录)。
    func testDifferentIdentifiedSpeakersIsNotDuplicate() {
        let mic  = seg(startMs: 0, endMs: 2_000, text: "为什么用不了", speaker: 1)
        let loop = seg(startMs: 500, endMs: 2_500, text: "为什么用不了", speaker: 2)
        XCTAssertFalse(TranscriptDeduper.isDuplicate(mic: mic, loopback: loop))
        // 同说话人 → 正常判重复。
        let same = seg(startMs: 500, endMs: 2_500, text: "为什么用不了", speaker: 1)
        XCTAssertTrue(TranscriptDeduper.isDuplicate(mic: mic, loopback: same))
    }

    /// 说话人不确定(任一侧 nil)时短文本一律不判重:戴耳机(物理无回录)
    /// 通话里双方 5s 内都说「嗯」「好的」是常态,<2s 短段又从不进声纹 ——
    /// 误删真实语音的代价大于留一条重复。同说话人时短文本照常去重。
    func testShortTextNotDedupedWhenSpeakerUncertain() {
        let en1 = seg(startMs: 0, endMs: 1_000, text: "嗯。")
        let en2 = seg(startMs: 200, endMs: 1_200, text: "嗯")
        XCTAssertFalse(TranscriptDeduper.isDuplicate(mic: en1, loopback: en2))
        XCTAssertFalse(TranscriptDeduper.isDuplicate(
            mic: seg(startMs: 0, endMs: 1_500, text: "Thank you."),
            loopback: seg(startMs: 300, endMs: 1_800, text: "Thank you")))
        // 双方声纹一致(真回录,如外放时两路都识别为对方)→ 短文本可去重。
        let s1 = seg(startMs: 0, endMs: 1_000, text: "嗯。", speaker: 7)
        let s2 = seg(startMs: 200, endMs: 1_200, text: "嗯", speaker: 7)
        XCTAssertTrue(TranscriptDeduper.isDuplicate(mic: s1, loopback: s2))
        // 「嗯」不得通过包含规则误命中长句。
        let long = seg(startMs: 0, endMs: 3_000, text: "嗯现在他们还有这种东西", speaker: 7)
        XCTAssertFalse(TranscriptDeduper.isDuplicate(mic: s1, loopback: long))
    }

    /// 短子串不能干掉长 mic 行:loopback「好的」("haode")是长文本的子串,
    /// 但比例门槛(60%)+ 时长上限(15s)都挡住 —— 防止 diarize 退化时
    /// 整 chunk 大段(回录+我自己的话混录)被一个子串整行带走。
    func testShortSubstringDoesNotKillLongMicRow() {
        let micBlob = seg(startMs: 0, endMs: 60_000,
                          text: "好的现在他们还有这种东西搞什么饥饿营销他六月二十二号就用不了了我必须得疯狂用",
                          speaker: 7)
        let shortLoop = seg(startMs: 1_000, endMs: 2_000, text: "好的", speaker: 7)
        XCTAssertFalse(TranscriptDeduper.isDuplicate(mic: micBlob, loopback: shortLoop))
        // 即使 mic 行只有 8s(过时长上限),比例门槛也挡住。
        let micShort = seg(startMs: 0, endMs: 8_000,
                           text: "好的现在他们还有这种东西搞什么饥饿营销", speaker: 7)
        XCTAssertFalse(TranscriptDeduper.isDuplicate(mic: micShort, loopback: shortLoop))
    }

    /// mic ⊂ loopback 豁免时长上限:mic 行(哪怕 60s)的文本完整包含于
    /// loopback → mic 行没有独有内容,删了不丢任何东西。
    func testMicFullyContainedInLoopbackExemptFromDurationCap() {
        let mic  = seg(startMs: 0, endMs: 60_000, text: "现在他们还有这种东西搞什么饥饿营销")
        let loop = seg(startMs: 0, endMs: 58_000, text: "我跟你说现在他们还有这种东西搞什么饥饿营销对吧")
        XCTAssertTrue(TranscriptDeduper.isDuplicate(mic: mic, loopback: loop))
        // 反向(loopback ⊂ mic)的 60s 大段不豁免:mic 多出的可能是我的话。
        XCTAssertFalse(TranscriptDeduper.isDuplicate(
            mic: seg(startMs: 0, endMs: 60_000, text: "我跟你说现在他们还有这种东西搞什么饥饿营销对吧"),
            loopback: seg(startMs: 0, endMs: 58_000, text: "现在他们还有这种东西搞什么饥饿营销")))
    }

    /// 超长串(归一化 > 400 字符)拒绝编辑距离比较而不是截断比较 ——
    /// 按前缀算相似度会把 400 字符之后的独有内容连带删掉。
    func testOverlongTextsRefuseLevenshteinInsteadOfTruncating() {
        let echo = String(repeating: "现在他们还有这种东西搞什么饥饿营销", count: 10)
        let mic  = seg(startMs: 0, endMs: 10_000,
                       text: echo + "我自己说的话完全不同的内容在最后面藏着呢", speaker: 7)
        let loop = seg(startMs: 0, endMs: 10_000, text: "对吧那个" + echo, speaker: 7)
        XCTAssertFalse(TranscriptDeduper.isDuplicate(mic: mic, loopback: loop))
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
