import Foundation

/// Typing Observer v2 — Layer 2 多 element 路由层。
///
/// `IMEStateMachine` 单实例只对应一个 AX element。M3 串联真实 AX 事件流后，
/// 用户会在多个输入框间切换，每个 element 需要一份独立的折叠状态机。
/// Registry 按 `elementHash` 路由，没有就懒建一个。
///
/// element 失焦 / app 切走时主动 flush 并移除条目，防字典无限涨。
final class IMEStateMachineRegistry {

    /// key = elementHash（= CFHash(AXUIElement)）。
    private var machines: [Int: IMEStateMachine] = [:]

    init() {}

    /// 路由到对应 element 的状态机，没有则新建。
    func feed(_ raw: RawEdit) -> [IMEFoldEvent] {
        let machine: IMEStateMachine
        if let existing = machines[raw.elementHash] {
            machine = existing
        } else {
            machine = IMEStateMachine()
            machines[raw.elementHash] = machine
        }
        return machine.feed(raw)
    }

    /// 某 element 失焦：flush 它的 buffer，然后从字典移除（防字典无限涨）。
    func handleFocusChange(elementHash: Int) -> [IMEFoldEvent] {
        guard let machine = machines[elementHash] else { return [] }
        let events = machine.handleFocusChange()
        machines[elementHash] = nil
        return events
    }

    /// 全部 element flush（app 切走 / observer 停）：flush 所有再清空。
    func flushAll() -> [IMEFoldEvent] {
        var events: [IMEFoldEvent] = []
        for machine in machines.values {
            events += machine.handleFocusChange()
        }
        machines.removeAll()
        return events
    }

    /// 超时驱动：对所有在册状态机调 tick（规则 9 的 350ms compose timeout）。
    func tick(now: TimeInterval) -> [IMEFoldEvent] {
        var events: [IMEFoldEvent] = []
        for machine in machines.values {
            events += machine.tick(now: now)
        }
        return events
    }
}
