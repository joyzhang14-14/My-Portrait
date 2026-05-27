import Foundation

/// Pass 3 输入构造 + fanout 协调,从 Worker 抽出来保持文件可读。
enum WritingCapturePass3Builders {

    /// Pass 3 一组的执行结果。
    enum GroupResult {
        case success(WritingCapturePass3Agent.Output)
        case failure(Error)
    }

    /// 并发跑多 group 的 Pass 3。inputs 数组按 group index 对齐(空数组表示该
    /// group Pass 2 失败 / 无输出 → 跳过 LLM 调用)。
    static func runConcurrently(
        inputsByGroupIdx: [[WritingCapturePass3InputRecord]],
        concurrency: Int,
        makePass3: @escaping @MainActor @Sendable () -> WritingCapturePass3Agent
    ) async -> [GroupResult] {
        await withTaskGroup(of: (Int, GroupResult).self) { taskGroup in
            var inFlight = 0
            var nextIdx = 0
            var results: [Int: GroupResult] = [:]
            while inFlight < concurrency && nextIdx < inputsByGroupIdx.count {
                let idx = nextIdx; nextIdx += 1
                let inputs = inputsByGroupIdx[idx]
                taskGroup.addTask {
                    do {
                        let agent = await makePass3()
                        let out = try await agent.run(records: inputs)
                        return (idx, .success(out))
                    } catch {
                        return (idx, .failure(error))
                    }
                }
                inFlight += 1
            }
            while let (idx, res) = await taskGroup.next() {
                results[idx] = res
                inFlight -= 1
                if nextIdx < inputsByGroupIdx.count {
                    let nidx = nextIdx; nextIdx += 1
                    let inputs = inputsByGroupIdx[nidx]
                    taskGroup.addTask {
                        do {
                            let agent = await makePass3()
                            let out = try await agent.run(records: inputs)
                            return (nidx, .success(out))
                        } catch {
                            return (nidx, .failure(error))
                        }
                    }
                    inFlight += 1
                }
            }
            return (0..<inputsByGroupIdx.count).map { results[$0] ?? .failure(NSError()) }
        }
    }

    /// 从 (record, typing, keys) 构造一条 Pass 3 输入。
    /// recordId 由 Worker 按 "g<groupIdx>_r<recIdx>" 编号传入。
    static func buildInput(
        recordId: String,
        record: WritingCaptureRecord,
        typing: [TypingEvent],
        keys: [KeystrokeEntry]
    ) -> WritingCapturePass3InputRecord {
        let start = record.startTs
        let end = record.endTs

        // 窗口内 keystrokes(同 app)
        let windowKeys = keys.filter {
            $0.tsMs >= start && $0.tsMs <= end && $0.bundleId == record.app
        }
        let keystrokeText = assembleKeystrokeText(windowKeys)
        let keystrokeCount = windowKeys.count

        // 窗口内 typing_events(同 app)
        let windowTyping = typing.filter {
            $0.startedAt >= start && $0.endedAt <= end && $0.bundleId == record.app
        }
        let typingText = windowTyping.map { $0.text }.joined(separator: "\n")

        // paste / cut 检测
        var hasPaste = false
        var hasCut = false
        for k in windowKeys {
            let m = k.modifiers
            guard (m & 0x01) != 0 else { continue }   // cmd
            let lower = k.char?.lowercased()
            if lower == "v" { hasPaste = true }
            if lower == "x" { hasCut = true }
        }

        let imeLikely = detectImeLikely(text: record.text, keystrokeText: keystrokeText)

        return WritingCapturePass3InputRecord(
            recordId: recordId,
            text: record.text,
            kind: record.kind,
            source: record.source,
            app: record.app,
            url: record.url,
            startTs: start, endTs: end,
            keystrokeText: keystrokeText,
            keystrokeCount: keystrokeCount,
            typingEventsText: typingText,
            hasPasteEvent: hasPaste,
            hasCutEvent: hasCut,
            imeLikely: imeLikely
        )
    }

    /// 跟 Pass2 的 `assembleKeystrokeText` 一致:
    /// 跳过 modifier-only / shortcut,backspace → "<BS>",其他 char 按 ts 拼接。
    static func assembleKeystrokeText(_ keys: [KeystrokeEntry]) -> String {
        var out = ""
        for k in keys.sorted(by: { $0.tsMs < $1.tsMs }) {
            let m = k.modifiers
            if (m & 0x01) != 0 || (m & 0x02) != 0 || (m & 0x04) != 0 { continue }
            if k.isBackspace != 0 { out += "<BS>"; continue }
            if let c = k.char, !c.isEmpty { out += c }
        }
        return out
    }

    /// 启发式 IME 判定:record.text 含 CJK + keystroke 里小写 ASCII 字母 > 5 个。
    static func detectImeLikely(text: String, keystrokeText: String) -> Bool {
        let hasCJK = text.unicodeScalars.contains { s in
            let v = s.value
            return (0x3040...0x30FF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0xAC00...0xD7AF).contains(v)
        }
        if !hasCJK { return false }
        let asciiLowerCount = keystrokeText.lowercased().filter { $0.isASCII && $0.isLetter }.count
        return asciiLowerCount > 5
    }
}
