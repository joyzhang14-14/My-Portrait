import Foundation
import SwiftUI

/// 进程级服务集合。AppDelegate 在 `applicationDidFinishLaunching` 创建一次，
/// 进程退出时释放。通过 EnvironmentKey 注入 SwiftUI 树。
///
/// 持有：
///   - `reporter`: notImplemented 上报中枢
///   - `db`: PortraitDB 实现（P0 是 stub，后续由 DB 层换成真实实现）
///   - `coordinator`: CaptureCoordinator
///
/// 不持有窗口 —— AppDelegate 自己管。
@MainActor
final class Services {
    let reporter: UnimplementedReporter
    let db: PortraitDB
    let coordinator: CaptureCoordinator

    init() {
        let reporter = UnimplementedReporter()
        self.reporter = reporter
        let stubDB = StubPortraitDB(reporter: reporter)
        self.db = stubDB
        self.coordinator = CaptureCoordinator(db: stubDB, reporter: reporter)
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
