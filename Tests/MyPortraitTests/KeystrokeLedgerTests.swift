import XCTest
@testable import MyPortrait

/// KeystrokeLedger 单测 —— 不依赖真实 CGEventTap，全部通过 `record(timestampMs:)`
/// 注入时间戳。CGEventTap / ⌘V 过滤路径无法 unit test，走 manual test via
/// `--typing-observe-m1`（见 App.swift）。
final class KeystrokeLedgerTests: XCTestCase {

    func testHasKeystrokeWithinWindow_hit() {
        let ledger = KeystrokeLedger()
        let now = KeystrokeLedger.nowMs()
        ledger.record(timestampMs: now)
        XCTAssertTrue(ledger.hasKeystroke(within: 0.5))
    }

    func testHasKeystrokeWithinWindow_miss() {
        let ledger = KeystrokeLedger()
        let now = KeystrokeLedger.nowMs()
        ledger.record(timestampMs: now - 1000) // 1s ago
        XCTAssertFalse(ledger.hasKeystroke(within: 0.5))
    }

    func testHasKeystrokeWithinWindow_boundary() {
        // 精确边界：now - 500ms within 0.5 仍然 true（用 <=）；now - 501ms false。
        // 用一个固定的「now」参考点，避开 nowMs() 在断言之间漂移。
        let ledger1 = KeystrokeLedger()
        let now1 = KeystrokeLedger.nowMs()
        ledger1.record(timestampMs: now1 - 500)
        XCTAssertTrue(ledger1.hasKeystroke(within: 0.5),
                      "精确 500ms 前应命中（边界 inclusive）")

        let ledger2 = KeystrokeLedger()
        // 给「现在」往未来挪一点，模拟「这一笔是 600ms 前」。
        // 直接让时间戳 = now - 600ms，再查 within 0.5（500ms）—— 必 miss。
        let now2 = KeystrokeLedger.nowMs()
        ledger2.record(timestampMs: now2 - 600)
        XCTAssertFalse(ledger2.hasKeystroke(within: 0.5),
                       "600ms 前查 500ms 窗口应 miss")
    }

    func testRingBufferOverflow() {
        // 连写 100 次，最近 64 次保留，前 36 次覆盖。查询逻辑仍正确。
        let ledger = KeystrokeLedger()
        let now = KeystrokeLedger.nowMs()
        // 100 笔，时间戳跨度 100ms（每笔间隔 1ms），全部在 now 附近。
        for i in 0..<100 {
            ledger.record(timestampMs: now - Int64(99 - i)) // 最早 -99ms，最新 0
        }
        // recentTimestamps within 1s 应该恰好返回 64 笔（buffer 容量），
        // 其中最新的一笔是 now，最早的是 now - 63ms。
        let recent = ledger.recentTimestamps(within: 1.0)
        XCTAssertEqual(recent.count, 64, "环形缓冲容量 64，旧的被覆盖")
        XCTAssertEqual(recent.last, now)
        XCTAssertEqual(recent.first, now - 63)
        // 任意查询仍有效。
        XCTAssertTrue(ledger.hasKeystroke(within: 0.5))
    }

    // MARK: - hasSubmitKey

    func testHasSubmitKey_hit() {
        let ledger = KeystrokeLedger()
        ledger.recordSubmit(timestampMs: KeystrokeLedger.nowMs())
        XCTAssertTrue(ledger.hasSubmitKey(within: 0.5))
    }

    func testHasSubmitKey_miss_neverPressed() {
        // 从没按过提交键 → lastSubmitMs == 0 → 永远 false。
        let ledger = KeystrokeLedger()
        XCTAssertFalse(ledger.hasSubmitKey(within: 10.0))
    }

    func testHasSubmitKey_miss_tooOld() {
        let ledger = KeystrokeLedger()
        ledger.recordSubmit(timestampMs: KeystrokeLedger.nowMs() - 1000) // 1s ago
        XCTAssertFalse(ledger.hasSubmitKey(within: 0.3))
    }

    func testHasSubmitKey_boundary() {
        // 精确 300ms 前命中（边界 inclusive）；301ms 前 miss。
        let ledger1 = KeystrokeLedger()
        ledger1.recordSubmit(timestampMs: KeystrokeLedger.nowMs() - 300)
        XCTAssertTrue(ledger1.hasSubmitKey(within: 0.3),
                      "精确 300ms 前应命中（边界 inclusive）")

        let ledger2 = KeystrokeLedger()
        ledger2.recordSubmit(timestampMs: KeystrokeLedger.nowMs() - 400)
        XCTAssertFalse(ledger2.hasSubmitKey(within: 0.3),
                       "400ms 前查 300ms 窗口应 miss")
    }

    func testConcurrentWriteRead() {
        // 起 2 个 GCD task，一个高频 record，一个高频 hasKeystroke，
        // 跑 0.1s，无 crash 无数据竞争（ThreadSanitizer 友好）。
        let ledger = KeystrokeLedger()
        let deadline = Date().addingTimeInterval(0.1)
        let writerDone = expectation(description: "writer done")
        let readerDone = expectation(description: "reader done")

        DispatchQueue.global(qos: .userInitiated).async {
            while Date() < deadline {
                ledger.record()
            }
            writerDone.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            while Date() < deadline {
                // hasKeystroke 永远返回合法 Bool 不死锁。
                _ = ledger.hasKeystroke(within: 0.05)
            }
            readerDone.fulfill()
        }

        wait(for: [writerDone, readerDone], timeout: 2.0)
        // 收尾断言：写过那么多笔，最近 1s 内必有击键。
        XCTAssertTrue(ledger.hasKeystroke(within: 1.0))
    }
}
