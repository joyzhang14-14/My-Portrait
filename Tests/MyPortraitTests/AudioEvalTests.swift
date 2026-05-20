import XCTest
@testable import MyPortrait

/// 转录 / 说话人分离评估指标的回归测试。复刻 screenpipe-audio-eval 的测试。
/// 跑法：`xcodebuild test` 或 Xcode 内。
final class AudioEvalTests: XCTestCase {

    // MARK: - WER / CER

    func testWERIdenticalIsZero() {
        XCTAssertEqual(AudioEval.wer(reference: "hello world", hypothesis: "hello world"),
                       0, accuracy: 1e-6)
    }

    func testWEROneSubstitution() {
        // 2 个参考词，错 1 个 → 0.5
        XCTAssertEqual(AudioEval.wer(reference: "hello world", hypothesis: "hello there"),
                       0.5, accuracy: 1e-6)
    }

    func testWERNormalizationIgnoresPunctuationAndCase() {
        XCTAssertEqual(AudioEval.wer(reference: "Hello, World!", hypothesis: "hello world"),
                       0, accuracy: 1e-6)
    }

    func testWEREmptyReference() {
        XCTAssertEqual(AudioEval.wer(reference: "", hypothesis: ""), 0, accuracy: 1e-6)
        XCTAssertEqual(AudioEval.wer(reference: "", hypothesis: "extra"), 1, accuracy: 1e-6)
    }

    func testCERIdenticalIsZero() {
        XCTAssertEqual(AudioEval.cer(reference: "abc", hypothesis: "abc"), 0, accuracy: 1e-6)
    }

    func testCEROneCharWrong() {
        // 3 个参考字符，错 1 个 → 1/3
        XCTAssertEqual(AudioEval.cer(reference: "abc", hypothesis: "abd"),
                       1.0 / 3.0, accuracy: 1e-6)
    }

    // MARK: - DER

    func testDERPerfectMatchIsZero() {
        let r = [
            AudioEval.EvalSegment(start: 0, duration: 1, speaker: "alice"),
            AudioEval.EvalSegment(start: 1, duration: 1, speaker: "bob"),
        ]
        let s = AudioEval.der(reference: r, hypothesis: r)
        XCTAssertLessThan(s.der, 1e-9)
        XCTAssertEqual(s.totalSpeechSeconds, 2, accuracy: 0.05)
    }

    func testDERLabelSwapRemappedToZero() {
        // hypothesis 用了不同的标签名，但贪心映射应还原 → DER 仍 0。
        let r = [
            AudioEval.EvalSegment(start: 0, duration: 1, speaker: "alice"),
            AudioEval.EvalSegment(start: 1, duration: 1, speaker: "bob"),
        ]
        let h = [
            AudioEval.EvalSegment(start: 0, duration: 1, speaker: "spk1"),
            AudioEval.EvalSegment(start: 1, duration: 1, speaker: "spk2"),
        ]
        XCTAssertLessThan(AudioEval.der(reference: r, hypothesis: h).der, 1e-9)
    }

    func testDERMissedHalf() {
        // 参考 2s 语音，hypothesis 只覆盖 1s → 漏检一半。
        let r = [AudioEval.EvalSegment(start: 0, duration: 2, speaker: "alice")]
        let h = [AudioEval.EvalSegment(start: 0, duration: 1, speaker: "alice")]
        let s = AudioEval.der(reference: r, hypothesis: h)
        XCTAssertEqual(s.der, 0.5, accuracy: 0.05)
        XCTAssertEqual(s.missedDetectionRate, 0.5, accuracy: 0.05)
    }

    func testDERSpeakerError() {
        // hypothesis 把 bob 那段全标成 alice → 后半段说话人错配。
        let r = [
            AudioEval.EvalSegment(start: 0, duration: 1, speaker: "alice"),
            AudioEval.EvalSegment(start: 1, duration: 1, speaker: "bob"),
        ]
        let h = [AudioEval.EvalSegment(start: 0, duration: 2, speaker: "alice")]
        let s = AudioEval.der(reference: r, hypothesis: h)
        XCTAssertGreaterThan(s.speakerErrorRate, 0.4)
    }
}
