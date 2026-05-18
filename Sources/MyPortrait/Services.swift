import Foundation
import SwiftUI

/// 进程级服务集合。AppDelegate 在 `applicationDidFinishLaunching` 创建一次，
/// 进程退出时释放。通过 EnvironmentKey 注入 SwiftUI 树。
///
/// 持有：
///   - `reporter`:     notImplemented 上报中枢
///   - `db`:           PortraitDB 实现（P0 是 stub，后续由 DB 层换成真实实现）
///   - `coordinator`:  CaptureCoordinator（屏幕采集主流水线）
///   - `compactor`:    CompactionWorker（JPG → MP4 后台压缩）
///   - `audio`:        AudioCaptureService（麦克风 30s 段）
///   - `transcriber`:  TranscriptionScheduler（VAD + WhisperKit 调度）
///
/// 不持有窗口 —— AppDelegate 自己管。
@MainActor
final class Services {
    let reporter: UnimplementedReporter
    let db: PortraitDB
    let coordinator: CaptureCoordinator
    let compactor: CompactionWorker
    let audio: AudioCaptureService
    let transcriber: TranscriptionScheduler

    init() {
        let reporter = UnimplementedReporter()
        self.reporter = reporter
        let stubDB = StubPortraitDB(reporter: reporter)
        self.db = stubDB
        self.coordinator = CaptureCoordinator(db: stubDB, reporter: reporter)
        self.compactor = CompactionWorker(db: stubDB, reporter: reporter)
        let audioSvc = AudioCaptureService(reporter: reporter)
        self.audio = audioSvc
        self.transcriber = TranscriptionScheduler(
            db: stubDB, audio: audioSvc, reporter: reporter
        )
    }
}

// MARK: - SwiftUI 环境注入

private struct ServicesKey: EnvironmentKey {
    static let defaultValue: Services? = nil
}

extension EnvironmentValues {
    var services: Services? {
        get { self[ServicesKey.self] }
        set { self[ServicesKey.self] = newValue }
    }
}
