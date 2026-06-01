import Foundation
import CoreAudio
import AudioToolbox
import Observation
import os.log

/// 系统输入设备列表 + 当前 active device 的可观测快照。
///
/// 给 UI:Audio Capture 页 Input device picker + 实时状态栏
/// 给 AudioCaptureService:配 picker 选中的 UID 去解析 AudioDeviceID
///
/// 监听:
///   - `kAudioHardwarePropertyDevices`            设备列表变化(插拔)
///   - `kAudioHardwarePropertyDefaultInputDevice` 系统默认输入变化
///
/// **不会自己启停采集** —— 它只是 metadata 观察者。AudioCaptureService
/// 自己订阅这里的 active 变化决定要不要重启。
@MainActor
@Observable
final class AudioDevicesMonitor {

    static let shared = AudioDevicesMonitor()

    /// 输入设备的精简描述。UI 渲染 + AudioCaptureService 解析都用。
    struct Device: Identifiable, Sendable, Equatable, Hashable {
        let id: String                  // UID(跨重启稳定)
        let coreAudioId: AudioDeviceID  // 当前进程内的临时 id,拔插重连可能变
        let name: String                // 用户友好名("MacBook Pro 麦克风" / "AirPods Pro")
        let transport: Transport
        let inputChannels: Int

        enum Transport: String, Sendable {
            case builtIn = "built_in"
            case usb     = "usb"
            case bluetooth = "bluetooth"
            case airplay = "airplay"
            case aggregate = "aggregate"
            case virtual = "virtual"
            case other   = "other"

            var icon: String {
                switch self {
                case .builtIn:    return "laptopcomputer"
                case .usb:        return "cable.connector"
                case .bluetooth:  return "wave.3.right"
                case .airplay:    return "airplayaudio"
                case .aggregate:  return "rectangle.connected.to.line.below"
                case .virtual:    return "waveform.path"
                case .other:      return "mic"
                }
            }
        }
    }

    /// 全部 input devices(含通道数 > 0 的)。UI picker 用这个。
    private(set) var devices: [Device] = []
    /// 当前系统默认 input device 的 UID。UI 显示用 + AudioCaptureService
    /// 在 preferredInputDeviceUID 为空时 fallback 到这个。
    private(set) var systemDefaultUID: String = ""
    /// app 当前**实际**在用的 device UID(AudioCaptureService 启 engine 后
    /// 写进来)。空 = 没在录。UI "Currently recording from" 用这个。
    private(set) var activeUID: String = ""

    /// AudioCaptureService 启停时调,更新 UI live indicator。
    func setActiveUID(_ uid: String) { activeUID = uid }

    private let log = Logger(subsystem: "com.myportrait.capture", category: "devices-monitor")

    private init() {
        refresh()
        registerListeners()
    }

    // 单例不显式 deinit cleanup — listener block 由系统 audio daemon 持有
    // 引用,进程退出时整个 unregister。MainActor 隔离让 deinit 写不进 listener
    // remove(跨 actor),且没有实用价值。

    // MARK: - 强制重扫

    func refresh() {
        devices = Self.enumerateInputDevices()
        systemDefaultUID = Self.currentSystemDefaultInputUID()
    }

    // MARK: - Listeners

    nonisolated(unsafe) private static let devicesListAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    nonisolated(unsafe) private static let defaultInputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func registerListeners() {
        let listBlock: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        var listAddr = Self.devicesListAddr
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, DispatchQueue.main, listBlock
        ) != noErr {
            log.warning("failed to register device-list listener")
        }

        let defBlock: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        var defAddr = Self.defaultInputAddr
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defAddr, DispatchQueue.main, defBlock
        ) != noErr {
            log.warning("failed to register default-input listener")
        }
    }

    // MARK: - CoreAudio 查询

    /// 列出所有 input devices(channels > 0)。CoreAudio 同步 API,nonisolated
    /// 让 AudioCaptureService(actor)能直接调,不用跨 actor hop。
    nonisolated static func enumerateInputDevices() -> [Device] {
        var addr = devicesListAddr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return [] }

        var out: [Device] = []
        for id in ids {
            let inputCh = inputChannels(of: id)
            guard inputCh > 0 else { continue }
            let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? ""
            guard !uid.isEmpty else { continue }
            let name = stringProperty(id, selector: kAudioObjectPropertyName) ?? "(unknown)"
            let transport = transportType(of: id)
            out.append(Device(id: uid, coreAudioId: id, name: name,
                              transport: transport, inputChannels: inputCh))
        }
        // built-in 排第一(选起来方便),其它按名字。
        return out.sorted { a, b in
            if a.transport == .builtIn && b.transport != .builtIn { return true }
            if b.transport == .builtIn && a.transport != .builtIn { return false }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    nonisolated static func currentSystemDefaultInputUID() -> String {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultInputAddr
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return "" }
        return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? ""
    }

    /// uid → 当前 AudioDeviceID(进程内,设备拔插可能失效)。
    nonisolated static func deviceID(forUID uid: String) -> AudioDeviceID? {
        enumerateInputDevices().first { $0.id == uid }?.coreAudioId
    }

    // MARK: - 底层 CoreAudio 属性读取

    nonisolated private static func inputChannels(of id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(size))
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        let abl = UnsafeMutableRawPointer(buf).assumingMemoryBound(to: AudioBufferList.self)
        let bufList = UnsafeMutableAudioBufferListPointer(abl)
        var channels = 0
        for b in bufList { channels += Int(b.mNumberChannels) }
        return channels
    }

    nonisolated private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr else { return nil }
        return cf as String
    }

    nonisolated private static func transportType(of id: AudioDeviceID) -> Device.Transport {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr else { return .other }
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB:     return .usb
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airplay
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }
}
