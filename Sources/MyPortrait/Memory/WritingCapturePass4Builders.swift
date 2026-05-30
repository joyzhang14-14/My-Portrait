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

    /// 从 record 构造一条 Pass 4 输入 —— 纯内容审查,不带 keystroke。
    /// recordId 由 Worker 按 "g<groupIdx>_r<recIdx>" 编号传入。
    static func buildInput(
        recordId: String,
        record: WritingCaptureRecord
    ) -> WritingCapturePass4InputRecord {
        WritingCapturePass4InputRecord(
            recordId: recordId,
            text: record.text,
            kind: record.kind,
            source: record.source,
            app: record.app,
            url: record.url,
            contextSummary: record.contextSummary
        )
    }
}
