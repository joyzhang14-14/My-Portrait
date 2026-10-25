import Darwin
import Foundation

/// 本机内存余量 —— 后台重活(延后 OCR,以后的本地模型)开跑前的闸。
///
/// macOS 有内存压缩和 swap,「空闲页」几乎总是很小,不能直接拿来判断。这里看两样:
///   - 系统内存压力(内核综合了压缩器和 swap 的情况)必须是「正常」;
///   - 能立刻让出来的内存 = 空闲(含预读)+ 不活跃 + 可清除。压缩器和 swap 里的不算。
enum SystemMemory {

    /// 能立刻让出来的字节数;读不到返回 nil。
    static func availableBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        // free_count 已含 speculative(vm_stat 的 Pages free 是减掉它之后的数)。
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
        return pages * UInt64(getpagesize())
    }

    /// `kern.memorystatus_vm_pressure_level`:1 正常 / 2 警告 / 4 严重。读不到返回 nil。
    static func pressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return level
    }
}
