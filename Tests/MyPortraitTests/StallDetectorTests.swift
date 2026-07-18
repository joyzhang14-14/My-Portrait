import XCTest
@testable import MyPortrait

@MainActor
final class StallDetectorTests: XCTestCase {

    private let pause = IntentionalPauseState.shared

    private func resetPause() {
        pause.drmActive = false
        pause.captureDisabled = false
        pause.markScreenAwake(at: Date(timeIntervalSince1970: 0))
    }

    func testWakeGraceSuppressesStaleDbWriteAndResetsBaseline() {
        resetPause()
        let detector = StallDetector()
        let wake = Date(timeIntervalSince1970: 10_000)
        let before = vision(now: wake, attempts: 10, persisted: 8, dedup: 2)
        _ = evaluate(detector, vision: before, now: wake.addingTimeInterval(-30))

        pause.markScreenAwake(at: wake)
        let interrupted = vision(now: wake, attempts: 11, persisted: 8, dedup: 2)
        XCTAssertTrue(evaluate(
            detector, vision: interrupted, now: wake.addingTimeInterval(2)
        ).isEmpty)

        // 宽限期内已经吸收了睡眠边界产生的 +1；过期后不能迟到补报。
        let recovered = vision(
            now: wake.addingTimeInterval(61), attempts: 12, persisted: 9, dedup: 2
        )
        XCTAssertTrue(evaluate(
            detector, vision: recovered, now: wake.addingTimeInterval(61)
        ).isEmpty)
    }

    func testRealDbWriteStallStillReportsAfterWakeGrace() {
        resetPause()
        let detector = StallDetector()
        let wake = Date(timeIntervalSince1970: 20_000)
        pause.markScreenAwake(at: wake)

        let baseline = vision(now: wake, attempts: 20, persisted: 18, dedup: 2)
        XCTAssertTrue(evaluate(
            detector, vision: baseline, now: wake.addingTimeInterval(30)
        ).isEmpty)

        let failed = vision(
            now: wake.addingTimeInterval(61), attempts: 21, persisted: 18, dedup: 2
        )
        let verdicts = evaluate(
            detector, vision: failed, now: wake.addingTimeInterval(61)
        )
        XCTAssertEqual(verdicts.map(\.kind), [.visionDbWrite])
    }

    private func vision(
        now: Date, attempts: UInt64, persisted: UInt64, dedup: UInt64
    ) -> VisionSnapshot {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return VisionSnapshot(
            captureAttempts: attempts,
            framesPersisted: persisted,
            dedupSkips: dedup,
            intentionalSkips: 0,
            lastAttemptMs: nowMs - 1_000,
            lastDbWriteMs: nowMs - 120_000,
            startedAtMs: nowMs - 300_000
        )
    }

    private func evaluate(
        _ detector: StallDetector,
        vision: VisionSnapshot,
        now: Date
    ) -> [StallVerdict] {
        detector.evaluate(
            vision: vision,
            audio: AudioMetricsSnapshot(
                chunksProduced: 0, chunksTranscribed: 0, startedAtMs: 0
            ),
            pause: pause,
            permissionGranted: true,
            captureEnabled: true,
            audioEngineEnabled: false,
            pendingAudio: (0, 0),
            now: now
        )
    }
}
