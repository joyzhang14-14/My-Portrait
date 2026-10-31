import Foundation
import GRDB

/// 窗口没显示(后台采集)时,把能还的内存还给系统:SQLite 页缓存和读连接、
/// malloc 里整页空着的内存。窗口显示时什么都不做,前台照旧。
///
/// 调用时机:关窗卸视图树之后,以及每个后台任务(压 MP4 / 补 OCR / 转录 /
/// 事件画像等 job)跑完之后。缓存下次用到时自己长回来。
enum MemoryTrim {

    /// Services 启动时填上。
    nonisolated(unsafe) static var dbPools: [DatabasePool] = []

    static func ifHidden() {
        Task { @MainActor in
            guard !HealthMonitor.shared.windowVisible else { return }
            let pools = dbPools
            Task.detached(priority: .utility) {
                // releaseMemory 会等手上的读写做完再关读连接,放在后台线程。
                for pool in pools { pool.releaseMemory() }
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }
}
