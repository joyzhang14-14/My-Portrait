import Foundation

/// canvas 编辑过程重建 —— 只对 AX 拿不到内容的 canvas session(Google Docs /
/// Figma 等自绘编辑器)用。
///
/// 思路:AX 路径靠 AXValue diff 出 edit_log;canvas 上 AXValue 是空的,改用
/// **相邻 OCR 帧的中段 diff** 当编辑过程,**keystroke 当闸门**滤掉滚动/加载。
///
/// 必须跑在 **dedup 之前的 raw 帧**上 —— Jaccard 去重会把逐步变长的编辑过程
/// 合并成最长那帧,中间状态全丢。
///
/// 精度定位(用户明确):不需要精准 commit/delete,截屏间隙有变化即可。
///   - delete:中段净缩 > 10 字才算(打错一两个字的微删忽略)
///   - commit:新中段 ≥ 3 字才算(挡 OCR 抖动)
enum CanvasEditReconstructor {

    /// 一条 canvas 编辑事件。结构对齐 AX 的 EditEntry 语义,但带 before/after
    /// 让 Pass 2 自己理解(净变长=偏 commit,净缩=偏 delete)。
    struct Event: Sendable, Codable, Equatable {
        let ts: Int64
        let kind: String      // "commit" | "delete"
        let before: String    // 变化前的中段(去掉公共头尾)
        let after: String     // 变化后的中段
    }

    /// delete 阈值:中段净缩超过这个字数才算一次删除。
    static let deleteMinChars = 10
    /// commit 抖动地板:新中段至少这么长才算(挡 OCR 噪音)。
    static let commitMinChars = 3

    /// 重建一个 session 的 canvas 编辑事件。
    /// - frames: dedup 之前的 raw OCR 帧(同 session,已按 ts 升序)
    /// - keystrokes: 同 session 的击键(已按 ts 升序)
    static func reconstruct(
        frames: [WritingCaptureRawOcr],
        keystrokes: [KeystrokeEntry]
    ) -> [Event] {
        guard frames.count >= 2 else { return [] }
        var events: [Event] = []
        let sortedKeys = keystrokes.sorted { $0.tsMs < $1.tsMs }

        var prev = normalize(frames[0].text)
        var prevTs = frames[0].tsMs
        for f in frames.dropFirst() {
            let cur = normalize(f.text)
            defer { prev = cur; prevTs = f.tsMs }
            if cur == prev || cur.isEmpty || prev.isEmpty { continue }

            // 去公共头尾 → 中段
            let (beforeMid, afterMid) = middleDiff(prev, cur)
            if beforeMid.isEmpty && afterMid.isEmpty { continue }

            // keystroke 闸门:窗口 (prevTs, f.tsMs] 里有没有"算编辑"的键
            let hasEditKey = sortedKeys.contains { k in
                k.tsMs > prevTs && k.tsMs <= f.tsMs && isEditKey(k)
            }
            if !hasEditKey { continue }   // 滚动 / 加载 / 抖动

            let removed = max(0, beforeMid.count - afterMid.count)
            if removed > deleteMinChars {
                events.append(Event(ts: f.tsMs, kind: "delete",
                                    before: beforeMid, after: afterMid))
            } else if afterMid.count >= commitMinChars {
                events.append(Event(ts: f.tsMs, kind: "commit",
                                    before: beforeMid, after: afterMid))
            }
            // 介于两者之间(微小净变化)→ 忽略
        }
        return events
    }

    // MARK: - 私有

    /// 删换行 + 折叠连续空白为单空格 + trim。段落比较,不在意排版。
    static func normalize(_ s: String) -> String {
        let noNewline = s.replacingOccurrences(of: "\n", with: " ")
        let collapsed = noNewline.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// 去掉公共前缀 + 公共后缀,返回两边各自的中段。
    /// 按 Character(grapheme)切,中英文都安全。
    static func middleDiff(_ a: String, _ b: String) -> (String, String) {
        let ac = Array(a), bc = Array(b)
        var p = 0
        let maxP = min(ac.count, bc.count)
        while p < maxP && ac[p] == bc[p] { p += 1 }
        // 公共后缀(不跟前缀重叠)
        var s = 0
        let maxS = min(ac.count, bc.count) - p
        while s < maxS && ac[ac.count - 1 - s] == bc[bc.count - 1 - s] { s += 1 }
        let beforeMid = String(ac[p ..< ac.count - s])
        let afterMid = String(bc[p ..< bc.count - s])
        return (beforeMid, afterMid)
    }

    /// 这次击键算不算"编辑动作"(用于闸门):
    ///   - backspace / forward-delete → 算(删除)
    ///   - ⌘X 剪切                    → 算(删除)
    ///   - 普通字符键(非导航键、非纯修饰)→ 算(输入)
    /// 排除:方向键 / PageUp/Down / Home/End 等导航键(滚动不算编辑)。
    static func isEditKey(_ k: KeystrokeEntry) -> Bool {
        if k.isBackspace != 0 { return true }
        let hasCmd = (k.modifiers & 0x01) != 0
        if hasCmd, k.char?.lowercased() == "x" { return true }   // ⌘X
        // 其余带 cmd/opt/ctrl 的当快捷键,不算输入
        if hasCmd || (k.modifiers & 0x02) != 0 || (k.modifiers & 0x04) != 0 {
            return false
        }
        guard let c = k.char, let scalar = c.unicodeScalars.first else { return false }
        // 导航 / 功能键落在 private-use 区 0xF700–0xF8FF(NSUpArrowFunctionKey 等)
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        // 控制字符(含纯回车/Tab 也不当正文输入闸门)
        if scalar.value < 0x20 { return false }
        return true
    }
}
