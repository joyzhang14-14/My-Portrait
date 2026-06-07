import Foundation

/// Pass 4 输入构造 + fanout 协调,从 Worker 抽出来保持文件可读。
enum WritingCapturePass4Builders {

    /// Pass 4 一组的执行结果。
    enum GroupResult {
        case success(WritingCapturePass4Agent.Output)
        case failure(Error)
    }

    /// 并发跑多 group 的 Pass 4。inputs 数组按 group index 对齐(空数组表示该
    /// group Pass 3 失败 / 无输出 → 跳过 LLM 调用)。
    static func runConcurrently(
        inputsByGroupIdx: [[WritingCapturePass4InputRecord]],
        concurrency: Int,
        userRejections: [UserRejectionRow] = [],
        makePass4: @escaping @MainActor @Sendable () -> WritingCapturePass4Agent
    ) async -> [GroupResult] {
        await withTaskGroup(of: (Int, GroupResult).self) { taskGroup in
            var inFlight = 0
            var nextIdx = 0
            var results: [Int: GroupResult] = [:]
            @Sendable func launch(_ idx: Int) -> @Sendable () async -> (Int, GroupResult) {
                let inputs = inputsByGroupIdx[idx]
                return {
                    do {
                        let agent = await makePass4()
                        let out = try await agent.run(records: inputs, userRejections: userRejections)
                        return (idx, .success(out))
                    } catch {
                        return (idx, .failure(error))
                    }
                }
            }
            while inFlight < concurrency && nextIdx < inputsByGroupIdx.count {
                let idx = nextIdx; nextIdx += 1
                taskGroup.addTask(operation: launch(idx)); inFlight += 1
            }
            while let (idx, res) = await taskGroup.next() {
                results[idx] = res
                inFlight -= 1
                if nextIdx < inputsByGroupIdx.count {
                    let nidx = nextIdx; nextIdx += 1
                    taskGroup.addTask(operation: launch(nidx)); inFlight += 1
                }
            }
            return (0..<inputsByGroupIdx.count).map { results[$0] ?? .failure(NSError()) }
        }
    }

    /// 从 record 构造一条 Pass 4 输入。带上该 record 时间窗内的物理击键数 ——
    /// 让 Pass 4 能分辨"用户亲手敲的"(有击键)vs"屏上显示的页面/标题文字"(零击)。
    /// recordId 由 Worker 按 "g<groupIdx>_r<recIdx>" 编号传入。
    static func buildInput(
        recordId: String,
        record: WritingCaptureRecord,
        keys: [KeystrokeEntry]
    ) -> WritingCapturePass4InputRecord {
        let pad: Int64 = 10_000
        let kc = keys.lazy.filter {
            $0.bundleId == record.app
                && $0.tsMs >= record.startTs - pad && $0.tsMs <= record.endTs + pad
                && ($0.modifiers & 0x07) == 0
        }.count
        // canvas_fusion(屏幕 OCR 重建)单独带「击键文字」:它的时间窗常塌成单帧瞬刻,
        // 改用该组(=该文档 session)全部击键,让 Pass 4 判「击键能否产出这段文本」。
        // 非 canvas 不带(text 本就来自击键、已被上游覆盖闸门把过关,省 token)。
        let keystrokeText: String? = record.source == "canvas_fusion"
            ? Self.assembleKeys(keys.filter { $0.bundleId == record.app })
            : nil
        return WritingCapturePass4InputRecord(
            recordId: recordId,
            text: record.text,
            kind: record.kind,
            source: record.source,
            app: record.app,
            url: record.url,
            keystrokeCount: kc,
            contextSummary: record.contextSummary,
            keystrokeText: keystrokeText
        )
    }

    /// 把击键拼成原始字符串(同 Pass2/3 的 assembleKeystrokeText:跳修饰组合键,
    /// 退格→<BS>,回车→<CR>)。在此内联因 Pass2Agent 那份是 @MainActor、本函数同步。
    private static func assembleKeys(_ keys: [KeystrokeEntry]) -> String {
        var out = ""
        for k in keys.sorted(by: { $0.tsMs < $1.tsMs }) {
            if (k.modifiers & 0x07) != 0 { continue }
            if k.isBackspace != 0 { out += "<BS>"; continue }
            if let c = k.char, !c.isEmpty { out += (c == "\n" || c == "\r") ? "<CR>" : c }
        }
        return String(out.prefix(800))
    }
}
