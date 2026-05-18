import XCTest
@testable import MyPortrait

/// 守门测试：跑一遍 capture 流水线的主路径，断言**没有任何 stub 被命中**。
///
/// 设计原理（见 memory: feedback-notimplemented-visibility）：notImplemented 不允
/// 许漏到 release。这个测试就是那一道门 —— release 上线前 CI 必须 pass。
///
/// **现状**：很多采集子系统在 :memory: + 无屏幕权限 + 无音频权限的 CI 环境里
/// 启动会失败（无屏幕录制权限就直接 throw）。完整 smoke 测试需要 mock 出整个
/// 子系统层，或者在真机上跑。
///
/// 这个 case 目前 `XCTSkip` —— 占位作用，提醒未来补全。
final class NoUnimplementedInProductionTests: XCTestCase {

    @MainActor
    func testMainCaptureFlowHasNoUnimplementedStubs() async throws {
        throw XCTSkip("Needs mocked subsystems (screen / audio / power) or real-device CI runner")

        // Phase 5 验证：
        // let services = Services.testMode()   // 全 mock 子系统
        // services.startManagedLifecycle()
        // try await services.coordinator.captureOnce()
        // try await services.audio.captureSegmentOnce()
        // ... 跑完后
        // XCTAssertEqual(services.reporter.callCount, 0)
    }

    /// 退而求其次的版本：直接验证 stub 路径会增加 reporter.callCount。
    /// 这个测试是 **negative**（验证 stub 工作正常），跟上面的 production 守门正好对照。
    @MainActor
    func testStubCorrectlyReportsThroughReporter() async throws {
        let reporter = UnimplementedReporter()
        let stub = StubPortraitDB(reporter: reporter)

        // 调一个会 throw notImplemented 的方法
        do {
            _ = try await stub.insertFrame(FrameRecord(
                timestampMs: 0, appName: "x", windowName: nil,
                browserUrl: nil, focused: true, deviceName: "main",
                snapshotPath: "/tmp/x", captureTrigger: "test"
            ))
            XCTFail("expected notImplemented to throw")
        } catch is CaptureError {
            // good
        }

        // notImplemented helper 是 fire-and-forget Task，等一下让 reporter 收到。
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(reporter.callCount, 0,
                             "reporter should have incremented after stub hit")
    }
}
