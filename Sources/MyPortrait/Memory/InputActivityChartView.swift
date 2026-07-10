import SwiftUI
import AppKit

/// 盖在图后的透明 AppKit 层:让「在图上按下拖动」不被当成拖动窗口
/// (窗口 isMovableByWindowBackground 时,SwiftUI 内容默认可拖窗 → 整窗漂移)。
private struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BlockerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

/// 一次选中的结果:[lo, hi] = 选中的分钟窗口(高亮带 + records 过滤共用)。
/// click = 点击点(画蓝线);拖拽框选无点击点 → nil,只画带不画线。
private struct InputSelection: Equatable {
    let lo: Int
    let hi: Int
    let click: Int?
    /// 点击自动选丛时是否撞到 keystrokeCap 被截断(拖拽框选恒 false)。
    var capped: Bool = false
}

/// Memory 区 "Input" scope 的**图谱形态**(canvas 模式)。
///
/// 一天一张面积图:x 轴 = 当天**第一次打字到最后一次打字**的时段(动态,不固定
/// 24h),y 轴 = 每分钟总击键数(含退格,不减)。曲线下方阴影按 app 堆叠分色
/// (和 timeline 一致的 `AppColor`);数据做移动平均平滑,曲线更顺。
/// 顶部日期切换栏复用 timeline 的 `TimelineControlsBar`(日历弹窗切天)。
///
/// 图例下方接当天 writing_records 卡片流:收起态只显 app 名 / start 时间 /
/// 内容预览,点开下拉显示全文 + 元数据 + 编辑记录。
///
/// 数据源:`keystroke_log`(raw 每次击键),按本地某天 [00:00, +24h) 查
/// `WritingCaptureStore.keystrokesInRange`,后台聚合成 1440 个分钟桶后取活动段;
/// records 走 `writingRecordsInRange` 同窗口。
@MainActor
struct InputActivityChartView: View {
    /// writing-style wr chip 跳转目标(ContentView 传入)。非 nil 时:切到该
    /// record 所在天 → 滚动到并高亮/展开那张卡片。消费后置回 nil。
    var jumpToRecordId: Binding<Int64?>? = nil
    /// 待定位的 record id —— 换天要等 reload 完成才能滚,先挂在这。
    @State private var pendingJumpId: Int64? = nil
    /// 当前高亮的 record(定位后 ~2s 淡出)。
    @State private var highlightedId: Int64? = nil
    /// 滚动目标 + nonce(同 id 重复定位也要触发 ScrollViewReader.onChange)。
    @State private var scrollTargetId: Int64? = nil
    @State private var scrollNonce = 0
    @State private var selectedDay: Date = Date()
    @State private var buckets: MinuteBuckets = .empty
    @State private var records: [WritingRecordViewRow] = []
    /// 展开的 record id 集合(可多开)。切天清空。
    @State private var expandedIds: Set<Int64> = []
    /// 已提交的选中(点击自动丛 or 拖拽框选)。nil = 未选、显示全天。
    /// 点图表空白处取消。
    @State private var selection: InputSelection? = nil
    /// 拖拽框选进行中的实时预览窗口(只驱动高亮带,不动 records,松手才提交)。
    @State private var dragPreview: (lo: Int, hi: Int)? = nil
    @State private var loading = false
    /// 代际 token —— 快速切天时慢查询晚归不能盖掉新一天的结果。
    @State private var reloadGen = 0
    @Environment(\.colorScheme) private var colorScheme

    private var store: WritingCaptureStore? { WritingCaptureWorker.shared?.store }

    var body: some View {
        VStack(spacing: 0) {
            TimelineControlsBar(currentDate: $selectedDay, onRefresh: { Task { await reload() } })
                .padding(.top, 40)
                .padding(.bottom, 8)

            Divider().overlay(Theme.stroke)

            chartArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SidebarBackdrop().ignoresSafeArea())
        .task(id: selectedDay) {
            expandedIds = []
            selection = nil
            await reload()
        }
        .task { await handleJump() }                       // 首次进入即带跳转
        .onChange(of: jumpToRecordId?.wrappedValue) { _, v in
            if v != nil { Task { await handleJump() } }    // 已在此界面再点别的 chip
        }
    }

    // MARK: - wr chip 跳转定位

    /// 查该 record 所在天 → 切天(或同天直接定位)。消费 binding 防重触发。
    @MainActor
    private func handleJump() async {
        guard let target = jumpToRecordId?.wrappedValue, let store else { return }
        jumpToRecordId?.wrappedValue = nil
        let ts = await Task.detached(priority: .userInitiated) {
            store.writingRecordStartTs(id: target)
        }.value
        guard let ts else { return }   // record 不存在(可能已删)→ 放弃
        let day = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        pendingJumpId = target
        if Calendar.current.isDate(day, inSameDayAs: selectedDay) {
            performPendingJump()       // 同一天:records 已加载,直接定位
        } else {
            selectedDay = day          // 换天:触发 .task(id:selectedDay) → reload 末尾定位
        }
    }

    /// records 就绪后:**把目标 record 的时间段设为图表选中窗口**(等同手动
    /// 框选那段;07-10 用户定稿"目标段设为画布中心")—— records 列表随选中
    /// 过滤到该窗口,目标卡片直接在台前,不再依赖全天长列表的 LazyVStack
    /// 滚动(懒加载下 scrollTo 不可靠,实测滚不到)。再展开 + 高亮。
    /// 目标不在当前 records(天没对上/reload 未完)则不动,留待下一次 reload
    /// 末尾重试(pendingJumpId 不清)。
    @MainActor
    private func performPendingJump() {
        guard let pid = pendingJumpId,
              let rec = records.first(where: { $0.id == pid }) else { return }
        pendingJumpId = nil
        dragPreview = nil
        // 目标段 → 分钟窗口(与图表 [lo,hi] 含端点语义一致),夹回当天。
        let lo = min(max(Int((rec.startTs - dayStartMs) / 60_000), 0), 1439)
        let hi = min(max(Int((rec.endTs - dayStartMs) / 60_000), lo), 1439)
        withAnimation(.easeOut(duration: 0.15)) {
            selection = InputSelection(lo: lo, hi: hi, click: nil)
        }
        expandedIds.insert(pid)
        highlightedId = pid
        scrollTargetId = pid
        scrollNonce += 1
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if highlightedId == pid {
                withAnimation(.easeOut(duration: 0.4)) { highlightedId = nil }
            }
        }
    }

    // MARK: - 选中窗口派生

    /// 本地当天 00:00 的 ms —— 分钟↔时间戳换算基准(与 reload 同源)。
    private var dayStartMs: Int64 {
        Int64(Calendar.current.startOfDay(for: selectedDay).timeIntervalSince1970 * 1000)
    }

    /// records 过滤用的**已提交**窗口(拖拽中不动 records,只看提交值)。
    private var windowMinutes: (lo: Int, hi: Int)? {
        guard let s = selection else { return nil }
        return (s.lo, s.hi)
    }

    /// 表头显示用窗口:拖拽中优先显示实时预览,否则已提交选中。
    private var displayWindow: (lo: Int, hi: Int)? {
        dragPreview ?? windowMinutes
    }

    /// 上面窗口换算成 [start, end) 毫秒。hi 是**含端点**的分钟(keystrokes 用
    /// rawTotals[lo...hi] 闭区间),所以排他终点要 +1 分钟,否则漏掉整个 hi 分钟。
    private var windowMs: (start: Int64, end: Int64)? {
        guard let w = windowMinutes else { return nil }
        return (dayStartMs + Int64(w.lo) * 60_000,
                dayStartMs + Int64(w.hi + 1) * 60_000)
    }

    /// records 联动:选中时只留与窗口时间重叠的,否则全天。
    private var visibleRecords: [WritingRecordViewRow] {
        guard let w = windowMs else { return records }
        return records.filter { $0.startTs < w.end && $0.endTs > w.start }
    }

    /// 表头文字。拖拽中(dragPreview 非空)**不显 records 数**——列表还是旧提交
    /// 选区,数目和实时时间/keys 不同源会误导;松手提交后才出现。点击选丛撞 cap
    /// 截断时标 "capped",解释为何比拖拽/整段小。
    private func headerLabel(_ w: (lo: Int, hi: Int)) -> String {
        var s = "\(Self.hm(w.lo))–\(Self.hm(w.hi)) · \(buckets.keystrokes(in: w.lo, w.hi)) keys"
        if dragPreview == nil {
            if selection?.capped == true { s += " · capped" }
            s += " · \(visibleRecords.count)"
        }
        return s
    }

    /// 分钟(当天分钟数)→ "HH:mm",越界夹到 00:00 / 23:59。
    private static func hm(_ minute: Int) -> String {
        let m = min(max(minute, 0), 1439)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    @ViewBuilder
    private var chartArea: some View {
        if buckets.maxTotal == 0 && records.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(loading ? "Loading…" : "No typing on this day")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 图 + 图例**固定在顶部**(不进 ScrollView):在图上拖动就不会带动内容/
            // 窗口漂移;records 卡片流在下方独立滚动。图占面板高度的 1/3。
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 14) {
                    if buckets.maxTotal > 0 {
                        InputActivityCanvas(buckets: buckets,
                                            colorScheme: colorScheme,
                                            selection: selection,
                                            dragPreview: dragPreview,
                                            onTapSelect: { m in
                                                dragPreview = nil
                                                withAnimation(.easeOut(duration: 0.15)) {
                                                    if let w = buckets.burstWindow(around: m) {
                                                        // ±snapRange 内有 session → 吸附整段。
                                                        selection = InputSelection(lo: w.lo, hi: w.hi,
                                                                                   click: w.anchor, capped: w.capped)
                                                    } else {
                                                        // 附近确实空 → ±3h 兜底盒,盒边碰到的 session 补全不拦腰切。
                                                        let w = buckets.fallbackWindow(around: m)
                                                        selection = InputSelection(lo: w.lo, hi: w.hi, click: m)
                                                    }
                                                }
                                            },
                                            onDragChange: { lo, hi in
                                                dragPreview = (lo, hi)   // 实时预览,不动 records
                                            },
                                            onDragEnd: { lo, hi in
                                                dragPreview = nil
                                                withAnimation(.easeOut(duration: 0.15)) {
                                                    // 拖拽框选:精确用拖出的范围,不夹 cap(你手动定的)。
                                                    selection = InputSelection(lo: lo, hi: hi, click: nil)
                                                }
                                            },
                                            onDragCancel: {
                                                // 竖向为主的拖拽(想滚页)→ 不改选中,只清途中预览。
                                                dragPreview = nil
                                            })
                            .frame(height: geo.size.height / 3)
                            .background(WindowDragBlocker())   // 禁止图上拖动带动窗口
                        legend
                    } else {
                        // 有 records 但无击键图(纯粘贴/OCR 来源那天):说明为何没图,
                        // 也点不了选窗口(没有时间轴可点)。
                        Text("No keystroke activity to chart on this day")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }

                    // records 独立滚动区(图不动、只这里滚)。
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                recordsSection
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.bottom, 24)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // wr chip 定位滚动。锚点用 **.top 不是 .center**:卡片顶部
                        // (标题+正文)对齐视口顶,正文在最前;展开态正文下面接的
                        // edit_log(逐条 commit/delete 编辑历史)沉到下面/视口外,
                        // 否则按卡片中心滚会正好停在一堆 commit/delete 上看不到正文。
                        // 多次重试:选中过滤后列表已短、目标基本都已 realize,重试只是
                        // 兜底(懒加载偶发未 realize 时 scrollTo 静默失败)。
                        .onChange(of: scrollNonce) { _, _ in
                            guard let target = scrollTargetId else { return }
                            Task { @MainActor in
                                for ms in [120, 220, 360] {
                                    try? await Task.sleep(for: .milliseconds(ms))
                                    proxy.scrollTo(target, anchor: .top)
                                }
                                try? await Task.sleep(for: .milliseconds(80))
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo(target, anchor: .top)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // 点图表/卡片以外的空白处 → 取消选中(canvas 与卡片的手势是子视图,优先)。
                .contentShape(Rectangle())
                .onTapGesture {
                    if selection != nil || dragPreview != nil {
                        withAnimation(.easeOut(duration: 0.15)) { selection = nil; dragPreview = nil }
                    }
                }
            }
        }
    }

    // MARK: - Records 卡片流

    @ViewBuilder
    private var recordsSection: some View {
        // 选中/拖拽中:表头显 "09:30–13:04 · 8421 keys · N";否则 "RECORDS · N"。
        Group {
            if let w = displayWindow {
                Text(headerLabel(w)).foregroundStyle(.blue)
            } else {
                Text("RECORDS · \(records.count)")
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .tracking(0.8)
        .padding(.top, 10)

        if visibleRecords.isEmpty {
            Text(selection == nil
                 ? "No writing records this day"
                 : "No writing records in this selection")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(visibleRecords) { rec in
                    InputRecordCard(record: rec,
                                    expanded: expandedIds.contains(rec.id)) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            if expandedIds.contains(rec.id) {
                                expandedIds.remove(rec.id)
                            } else {
                                expandedIds.insert(rec.id)
                            }
                        }
                    }
                    .id(rec.id)   // ScrollViewReader 定位锚点
                    .overlay(     // wr chip 跳转命中的卡片高亮描边(~2s 淡出)
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.accent,
                                          lineWidth: highlightedId == rec.id ? 2 : 0)
                            .animation(.easeInOut(duration: 0.3), value: highlightedId)
                    )
                }
            }
        }
    }

    /// 图例:每个 app 一个色块 + 名称,和堆叠层同一套 AppColor;按活跃度从高到低
    /// (buckets.apps 是升序,reversed 即降序),自适应换行。
    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12, alignment: .leading)],
                  alignment: .leading, spacing: 8) {
            ForEach(buckets.apps.reversed(), id: \.self) { bundle in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppColor.color(for: InputCaptureView.appLabel(bundle)))
                        .frame(width: 10, height: 10)
                    Text(InputCaptureView.appLabel(bundle))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @MainActor
    private func reload() async {
        guard let store else { buckets = .empty; return }
        reloadGen += 1
        let gen = reloadGen
        loading = true
        // 刷新/切天一律清选中:旧 lo/hi 是按旧数据算的,套新 buckets 会显示陈旧丛。
        // (同日点刷新时 .task(id:) 不触发,靠这里兜底。)
        selection = nil
        dragPreview = nil
        // 本地当天 [00:00, +24h) —— x 轴天然是本地时间,不用管 DB 的 UTC 切日。
        let dayStart = Calendar.current.startOfDay(for: selectedDay)
        let startMs = Int64(dayStart.timeIntervalSince1970 * 1000)
        let endMs = startMs + 86_400_000

        let result = await Task.detached(priority: .userInitiated) {
            () -> (MinuteBuckets, [WritingRecordViewRow]) in
            let ks = (try? store.keystrokesInRange(
                startMs: startMs, endMs: endMs, excludeBundleIds: [])) ?? []
            let recs = (try? store.writingRecordsInRange(
                startMs: startMs, endMs: endMs)) ?? []
            return (MinuteBuckets.aggregate(ks, dayStartMs: startMs), recs)
        }.value

        guard gen == reloadGen else { return }   // 期间切到别的天 → 丢弃
        buckets = result.0
        records = result.1
        loading = false
        if pendingJumpId != nil { performPendingJump() }   // 换天 reload 完成 → 定位
    }
}

// MARK: - 聚合结果

/// 一天 1440 分钟的击键分桶。堆叠面积图 + 总量曲线都从这里读。
/// counts/totals 已做移动平均平滑(Double);x 轴只画 [firstMinute, lastMinute]
/// 这段有活动的时段(当天第一次打字到最后一次打字)。
struct MinuteBuckets: Sendable {
    /// 堆叠顺序的 app bundle_id(总量小的在底,大的在上 —— 大块在顶更好读)。
    let apps: [String]
    /// counts[minute(0..1439)][appIndex] = 平滑后的该分钟该 app 击键数。
    let counts: [[Double]]
    /// totals[minute] = 平滑后该分钟所有 app 击键总数(= 堆叠顶 = 单色曲线)。
    let totals: [Double]
    /// rawTotals[minute] = **平滑前**的原始每分钟击键数(长度 1440)。
    /// 峰值丛检测 / keystroke 计数只能用 raw,不能用平滑值。
    let rawTotals: [Int]
    let maxTotal: Double
    /// 有打字的分钟(raw 击键 >0)的每分钟击键数中位数 —— y 轴中间那格。
    let median: Double
    /// 有活动的分钟范围(x 轴左右端)。无数据时 0/0。
    let firstMinute: Int
    let lastMinute: Int

    static let empty = MinuteBuckets(apps: [], counts: [], totals: [], rawTotals: [],
                                     maxTotal: 0, median: 0, firstMinute: 0, lastMinute: 0)

    // MARK: 峰值丛选择旋钮(代码里可调)

    /// 每分钟击键 ≥ 此值才算"活跃"。取 1:连微弱边缘(每分钟 1 键)也算进 session,
    /// 不再被当噪声剔掉,选中不漏边边角。只有完全 0 击键的分钟才是"安静"。
    static let activeFloor = 1
    /// 连续安静 ≥ 此分钟数 → session 收边。取 90min:实测(2026-07-10 扫库)相邻
    /// bump 间距 45~90min 的很多,视觉上是同一坨,gap=45 会把它们划开 → 点一边
    /// 漏另一边的"边角"。只有真正的长时间安静(>1.5h)才断开。调大 = 选更大片。
    static let gapMinutes = 90
    /// 点击自动选中的击键上限(安全值)—— 从点击点按密度扩到此量就停,
    /// 防极端大 session 一口气全选。绝大多数 session 都在此值内会整段选中。
    static let keystrokeCap = 10000
    /// 吸附范围(分钟):点击点 ±此值内有活跃分钟 → 吸附到那个 session;
    /// 超出(附近确实空)→ 调用方走 ±fallbackRadius 兜底。
    static let snapRange = 60
    /// 死区兜底半宽(分钟):附近无 session 时,圈点击点 ±此值(±3h)。
    static let fallbackRadius = 180

    /// 点选峰值丛:① snap 到 **±snapRange 内最近的活跃分钟**(点空白吸到附近 session;
    /// 超范围返回 nil,调用方走 ±3h 兜底)② 用 gap 定住整丛 [L,R] ③ 从 anchor 按密度
    /// 向两边扩、到 keystroke 上限停(不越出 [L,R])。返回 [lo,hi] + anchor(蓝线落点)。
    func burstWindow(around click: Int) -> (lo: Int, hi: Int, capped: Bool, anchor: Int)? {
        guard !rawTotals.isEmpty, lastMinute >= firstMinute else { return nil }
        let firstM = firstMinute, lastM = lastMinute

        // ① snap:点击点不活跃 → ±snapRange 内向两侧找**最近**的活跃分钟。
        var c = min(max(click, firstM), lastM)
        if rawTotals[c] < Self.activeFloor {
            snap: for d in 1...Self.snapRange {
                for cand in [c - d, c + d] where cand >= firstM && cand <= lastM {
                    if rawTotals[cand] >= Self.activeFloor { c = cand; break snap }
                }
            }
        }
        // 范围内没有活跃分钟(附近确实空)→ 返回 nil,调用方兜底 ±3h。
        guard rawTotals[c] >= Self.activeFloor else { return nil }

        // ② 自然丛 [L,R]:向两边跨小停顿,连续安静 ≥ gapMinutes 收边。
        let (L, R) = sessionBounds(from: c)

        // ③ 从 c 按密度扩到 cap:每步取两侧邻居中"更密且加得下"的那个;
        //    0 值(桥接内部小空隙)不吃预算,一律并入;两侧都放不下就停。
        var lo = c, hi = c
        var total = rawTotals[c]
        var capped = false   // 因预算(而非到达丛边界)停下 = 截断
        while lo > L || hi < R {
            let leftVal = lo > L ? rawTotals[lo - 1] : -1
            let rightVal = hi < R ? rawTotals[hi + 1] : -1
            // 更密的先试;放不下再试另一侧;都放不下就停。
            let denserIsLeft = leftVal >= rightVal
            let firstV = denserIsLeft ? leftVal : rightVal
            let secondV = denserIsLeft ? rightVal : leftVal
            if firstV >= 0 && total + firstV <= Self.keystrokeCap {
                if denserIsLeft { lo -= 1 } else { hi += 1 }
                total += firstV
            } else if secondV >= 0 && total + secondV <= Self.keystrokeCap {
                if denserIsLeft { hi += 1 } else { lo -= 1 }
                total += secondV
            } else {
                // 循环条件保证至少一侧可扩,却都放不下 → 是被 cap 卡住的。
                capped = true
                break
            }
        }

        // 修边:去掉两端桥接进来的安静分钟(0 击键),带子不含空隙尾巴。
        while lo < hi && rawTotals[lo] < Self.activeFloor { lo += 1 }
        while hi > lo && rawTotals[hi] < Self.activeFloor { hi -= 1 }
        // 视觉外扩:盖住平滑曲线的裙边(见 visualPad),否则曲线尾巴总探出带外。
        lo = max(firstM, lo - Self.visualPad)
        hi = min(lastM, hi + Self.visualPad)
        // anchor(蓝线落点)夹进最终窗口,免得吸附后 c 落在被修掉的边缘外。
        let anchor = min(max(c, lo), hi)
        return (lo, hi, capped, anchor)
    }

    /// 从 seed(须为活跃分钟)向两侧按 gap 容忍扫出所属 session 的完整边界 [L,R]。
    /// burstWindow 定丛 / fallbackWindow 补全被切 session 共用。
    func sessionBounds(from seed: Int) -> (L: Int, R: Int) {
        var L = seed, R = seed
        var gap = 0
        var i = seed - 1
        while i >= firstMinute {
            if rawTotals[i] >= Self.activeFloor { L = i; gap = 0 }
            else { gap += 1; if gap >= Self.gapMinutes { break } }
            i -= 1
        }
        gap = 0; i = seed + 1
        while i <= lastMinute {
            if rawTotals[i] >= Self.activeFloor { R = i; gap = 0 }
            else { gap += 1; if gap >= Self.gapMinutes { break } }
            i += 1
        }
        return (L, R)
    }

    /// 死区兜底窗口:点击点 ±fallbackRadius 盒子,再把被盒边**切到一半**的 session
    /// 补全(盒内有活跃分钟时,左右各自延伸到其 session 完整边界)——绝不拦腰切
    /// session(实测:兜底盒切在上午 session 中间是"漏边角"的主要来源之一)。
    func fallbackWindow(around click: Int) -> (lo: Int, hi: Int) {
        let c = min(max(click, firstMinute), lastMinute)
        var lo = max(firstMinute, c - Self.fallbackRadius)
        var hi = min(lastMinute, c + Self.fallbackRadius)
        // 盒内最左活跃分钟所属 session 的左边界 ≤ 盒左边 → 延伸补全;右侧同理。
        if let a = (lo...hi).first(where: { rawTotals[$0] >= Self.activeFloor }) {
            lo = min(lo, sessionBounds(from: a).L)
        }
        if let b = (lo...hi).last(where: { rawTotals[$0] >= Self.activeFloor }) {
            hi = max(hi, sessionBounds(from: b).R)
        }
        // 视觉外扩,同 burstWindow(见 visualPad)。
        return (max(firstMinute, lo - Self.visualPad),
                min(lastMinute, hi + Self.visualPad))
    }

    /// [lo, hi] 区间的原始击键总数(表头显示 / 触顶判断)。
    func keystrokes(in lo: Int, _ hi: Int) -> Int {
        guard !rawTotals.isEmpty, lo <= hi,
              lo >= 0, hi < rawTotals.count else { return 0 }
        return rawTotals[lo...hi].reduce(0, +)
    }

    /// 平滑窗口半径(分钟)。窗口 = 2r+1,边界处自动收缩。轻度即可 —— 视觉
    /// 圆滑交给渲染层的 Catmull-Rom,这里只压噪声、不削峰。
    private static let smoothRadius = 2

    /// 选中窗口视觉外扩(分钟)。曲线画的是**平滑值**(±smoothRadius)+ 样条圆角,
    /// 比 raw 活动边缘多探出 ~3min;带子贴 raw 边收,曲线尾巴就总露在带外
    /// ("总是差一捏捏",2026-06-04 实测:raw 末键 02:11,平滑曲线到 02:13 才归零)。
    /// 提交窗口两端各外扩此值盖住裙边;外扩分钟 raw=0,keys 计数不变。
    static let visualPad = smoothRadius + 1

    /// 纯函数,后台线程跑。keystroke 已按 ts 升序,但不依赖顺序。
    static func aggregate(_ ks: [KeystrokeEntry], dayStartMs: Int64) -> MinuteBuckets {
        guard !ks.isEmpty else { return .empty }

        // 1) 先统计每 app 全天总量,定堆叠顺序(升序:小的在底)。
        var appTotals: [String: Int] = [:]
        for k in ks { appTotals[k.bundleId, default: 0] += 1 }
        let apps = appTotals.sorted { $0.value < $1.value }.map { $0.key }
        let appIndex = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($1, $0) })

        // 2) 逐击键落分钟桶(原始整数)。
        var raw = Array(repeating: Array(repeating: 0, count: apps.count), count: 1440)
        var rawTot = Array(repeating: 0, count: 1440)
        for k in ks {
            let m = Int((k.tsMs - dayStartMs) / 60_000)
            guard m >= 0, m < 1440, let ai = appIndex[k.bundleId] else { continue }
            raw[m][ai] += 1
            rawTot[m] += 1
        }

        // 3) 活动范围 = 第一次/最后一次打字的分钟。
        guard let first = rawTot.firstIndex(where: { $0 > 0 }),
              let last = rawTot.lastIndex(where: { $0 > 0 }) else { return .empty }

        // 4) 移动平均平滑(每 app 列 + 总量;线性运算,各层平滑后仍精确堆叠成总量)。
        var counts = Array(repeating: Array(repeating: 0.0, count: apps.count), count: 1440)
        for ai in apps.indices {
            let col = (0..<1440).map { raw[$0][ai] }
            let sm = movingAverage(col, radius: smoothRadius)
            for m in 0..<1440 { counts[m][ai] = sm[m] }
        }
        let totals = movingAverage(rawTot, radius: smoothRadius)
        let maxTotal = (first...last).map { totals[$0] }.max() ?? 0

        // 中位数:只取有打字的分钟(raw>0)的原始每分钟击键数 —— 空白分钟不计入。
        let active = (first...last).map { rawTot[$0] }.filter { $0 > 0 }.sorted()
        let median: Double = {
            guard !active.isEmpty else { return 0 }
            let n = active.count
            return n.isMultiple(of: 2)
                ? Double(active[n / 2 - 1] + active[n / 2]) / 2
                : Double(active[n / 2])
        }()

        return MinuteBuckets(apps: apps, counts: counts, totals: totals, rawTotals: rawTot,
                             maxTotal: maxTotal, median: median,
                             firstMinute: first, lastMinute: last)
    }

    /// 前缀和 O(n) 滑动平均。边界窗口收缩(不补零,免得两端被压低)。
    private static func movingAverage(_ a: [Int], radius r: Int) -> [Double] {
        let n = a.count
        var prefix = Array(repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + a[i] }
        var out = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            let lo = max(0, i - r), hi = min(n - 1, i + r)
            out[i] = Double(prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
        return out
    }
}

// MARK: - Canvas 渲染

/// 面积图画布。堆叠阴影(按 app AppColor)→ 单色总量曲线 → 时间轴刻度。
/// Canvas 闭包保持精简(只调 draw* helper),避免 Swift 类型检查超时。
private struct InputActivityCanvas: View {
    let buckets: MinuteBuckets
    let colorScheme: ColorScheme
    /// 已提交选中(蓝线 = click,高亮带 = [lo,hi]);nil = 无。
    let selection: InputSelection?
    /// 拖拽中的实时预览窗口(优先画,只画带不画线);nil = 不在拖拽。
    let dragPreview: (lo: Int, hi: Int)?
    /// 轻点(总位移 < 阈值)→ 命中分钟,走点击自动选丛。
    let onTapSelect: (Int) -> Void
    /// 横向拖拽中 → 实时回传框选范围 [lo,hi]。
    let onDragChange: (Int, Int) -> Void
    /// 横向拖拽松手 → 提交框选范围。
    let onDragEnd: (Int, Int) -> Void
    /// 竖向为主的拖拽(想滚页)→ 不选、只清预览。
    let onDragCancel: () -> Void

    /// 判定"点击 vs 拖拽"的位移阈值(pt)。
    private let dragSlop: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let plot = plotRect(size)
                drawGrid(ctx, plot: plot)
                drawStackedArea(ctx, plot: plot)
                drawTotalCurve(ctx, plot: plot)
                drawSelection(ctx, plot: plot)   // 高亮带 + 蓝线,压在面积上
                drawAxis(ctx, plot: plot, size: size)
            }
            .contentShape(Rectangle())
            // 一个手势兼顾轻点与拖拽:minimumDistance:0 立即起手;松手时按位移判定。
            // highPriority 让"图上拖拽"胜过 ScrollView 竖滚(图只占 1/3,竖滚从下方 records 起)。
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let dx = abs(v.translation.width), dy = abs(v.translation.height)
                        // 只在**横向占优**的拖拽时预览框选;竖向为主(想滚页)不预览。
                        guard dx >= dragSlop, dx > dy else { return }
                        let a = minuteAt(v.startLocation.x, size: geo.size)
                        let b = minuteAt(v.location.x, size: geo.size)
                        onDragChange(min(a, b), max(a, b))
                    }
                    .onEnded { v in
                        let dx = abs(v.translation.width), dy = abs(v.translation.height)
                        if hypot(dx, dy) < dragSlop {
                            onTapSelect(minuteAt(v.startLocation.x, size: geo.size))   // 轻点 → 选丛
                        } else if dx > dy {
                            let a = minuteAt(v.startLocation.x, size: geo.size)
                            let b = minuteAt(v.location.x, size: geo.size)
                            onDragEnd(min(a, b), max(a, b))                            // 横拖 → 框选
                        } else {
                            onDragCancel()   // 竖向为主 → 不改选中(避免误改),清预览
                        }
                    }
            )
        }
    }

    /// 屏幕 x → 当天分钟数(反查 plot 映射),夹到活动范围内。
    private func minuteAt(_ px: CGFloat, size: CGSize) -> Int {
        let plot = plotRect(size)
        let frac = (px - plot.minX) / max(1, plot.width)
        let m = buckets.firstMinute + Int((Double(frac) * span).rounded())
        return min(max(m, buckets.firstMinute), buckets.lastMinute)
    }

    /// 高亮带(贯穿全图高度)+ 蓝线:点击选中在 anchor 画一条;
    /// 拖拽框选(click=nil)在左右两边界各画一条。拖拽预览优先。
    private func drawSelection(_ ctx: GraphicsContext, plot: CGRect) {
        // 拖拽预览优先;否则画已提交选中。
        let lo: Int, hi: Int, click: Int?
        if let d = dragPreview { lo = d.lo; hi = d.hi; click = nil }
        else if let s = selection { lo = s.lo; hi = s.hi; click = s.click }
        else { return }

        // hi 含端点:带子画到 x(hi+1) 才覆盖 hi 整分钟宽度,单分钟也可见;右端夹到 plot。
        let xl = x(lo, plot), xr = min(x(hi + 1, plot), plot.maxX)
        let band = Path(CGRect(x: xl, y: plot.minY, width: max(0, xr - xl), height: plot.height))
        ctx.fill(band, with: .color(.blue.opacity(0.13)))

        if let c = click {
            drawVLine(ctx, x(c, plot), plot)          // 点击选中:标点击点
        } else {
            drawVLine(ctx, xl, plot)                  // 框选:左右两边界各一条
            drawVLine(ctx, xr, plot)
        }
    }

    /// 一条贯穿全图高度的蓝竖线。
    private func drawVLine(_ ctx: GraphicsContext, _ px: CGFloat, _ plot: CGRect) {
        var line = Path()
        line.move(to: CGPoint(x: px, y: plot.minY))
        line.addLine(to: CGPoint(x: px, y: plot.maxY))
        ctx.stroke(line, with: .color(.blue.opacity(0.9)), lineWidth: 1.5)
    }

    // 左留 y 轴数字,底留时间标签。
    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: 40, y: 6, width: max(1, size.width - 48), height: max(1, size.height - 26))
    }

    // x 轴范围 = 活动时段 [firstMinute, lastMinute],至少 1 分钟宽避免除零。
    private var span: Double { max(1.0, Double(buckets.lastMinute - buckets.firstMinute)) }

    private func x(_ minute: Int, _ plot: CGRect) -> CGFloat {
        plot.minX + CGFloat((Double(minute - buckets.firstMinute)) / span) * plot.width
    }
    private func y(_ value: Double, _ plot: CGRect) -> CGFloat {
        let maxV = max(1.0, buckets.maxTotal)
        return plot.maxY - CGFloat(value / maxV) * plot.height
    }

    private var gridColor: Color {
        colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.08)
    }
    private var curveColor: Color {
        colorScheme == .light ? Color.black.opacity(0.65) : Color.white.opacity(0.80)
    }

    /// 中位数离 0 或离最高值差不到 2 时就不显示(挤在一起没意义)。
    private var showMedian: Bool {
        buckets.median >= 2 && (buckets.maxTotal - buckets.median) >= 2
    }

    /// 落在活动范围内的整点小时刻度(跨度小用 1h,大用 2/3h,避免拥挤)。
    private var hourTicks: [Int] {
        let firstH = (buckets.firstMinute + 59) / 60   // ceil
        let lastH = buckets.lastMinute / 60            // floor
        guard lastH >= firstH else { return [] }
        let spanH = lastH - firstH
        let step = spanH <= 6 ? 1 : (spanH <= 14 ? 2 : 3)
        return stride(from: firstH, through: lastH, by: step).map { $0 }
    }

    /// 每整点刻度一条竖线 + y 轴顶横线。
    private func drawGrid(_ ctx: GraphicsContext, plot: CGRect) {
        var p = Path()
        for h in hourTicks {
            let px = x(h * 60, plot)
            p.move(to: CGPoint(x: px, y: plot.minY))
            p.addLine(to: CGPoint(x: px, y: plot.maxY))
        }
        // 顶(最高)+(可选)中位数高度横向网格线,对齐 y 轴刻度。
        var gridYs = [plot.minY]
        if showMedian { gridYs.append(y(buckets.median, plot)) }
        for gy in gridYs {
            p.move(to: CGPoint(x: plot.minX, y: gy))
            p.addLine(to: CGPoint(x: plot.maxX, y: gy))
        }
        ctx.stroke(p, with: .color(gridColor), lineWidth: 0.6)
    }

    /// 逐 app 从底往上堆叠:每层 = 上界(累计+本层)Catmull-Rom 平滑上去,再沿
    /// 下界(累计)平滑回来,闭合填 AppColor。上下界共享点集+同一插值公式,层间无缝。
    private func drawStackedArea(_ ctx: GraphicsContext, plot: CGRect) {
        let lo = buckets.firstMinute, hi = buckets.lastMinute
        var cumulative = Array(repeating: 0.0, count: 1440)
        for (ai, bundle) in buckets.apps.enumerated() {
            var upper = Array(repeating: 0.0, count: 1440)
            for m in lo...hi { upper[m] = cumulative[m] + buckets.counts[m][ai] }

            let upperPts = (lo...hi).map { CGPoint(x: x($0, plot), y: y(upper[$0], plot)) }
            let lowerPts = (lo...hi).map { CGPoint(x: x($0, plot), y: y(cumulative[$0], plot)) }

            var path = Path()
            path.move(to: upperPts[0])
            addCatmullRom(&path, upperPts, plot: plot)
            path.addLine(to: lowerPts[lowerPts.count - 1])
            addCatmullRom(&path, Array(lowerPts.reversed()), plot: plot)
            path.closeSubpath()

            let color = AppColor.color(for: InputCaptureView.appLabel(bundle))
            ctx.fill(path, with: .color(color.opacity(0.55)))

            cumulative = upper
        }
    }

    /// 单色曲线 = 每分钟总量顶部轮廓(Catmull-Rom 平滑)。
    private func drawTotalCurve(_ ctx: GraphicsContext, plot: CGRect) {
        let lo = buckets.firstMinute, hi = buckets.lastMinute
        let pts = (lo...hi).map { CGPoint(x: x($0, plot), y: y(buckets.totals[$0], plot)) }
        var path = Path()
        path.move(to: pts[0])
        addCatmullRom(&path, pts, plot: plot)
        ctx.stroke(path, with: .color(curveColor), lineWidth: 1.4)
    }

    /// 沿点序列追加 Catmull-Rom 平滑曲线段(path 须已 move 到 pts[0])。
    /// 标准 1/6 张力,把折线转成穿过每个点的圆滑贝塞尔 —— 峰变钟形。
    /// 控制点 y 夹在 [plot.minY, plot.maxY]:贝塞尔落在控制点凸包内,端点又是
    /// 真实数据点,故曲线**绝不跌破基线**(谷底 overshoot)也不冲出顶部。
    private func addCatmullRom(_ path: inout Path, _ pts: [CGPoint], plot: CGRect) {
        guard pts.count > 1 else { return }
        func clampY(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: min(max(p.y, plot.minY), plot.maxY))
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = clampY(CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6))
            let c2 = clampY(CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    /// 底部时间标签(整点刻度)+ 左侧峰值数字。
    private func drawAxis(_ ctx: GraphicsContext, plot: CGRect, size: CGSize) {
        let labelColor = colorScheme == .light ? Color.black.opacity(0.45) : Color.white.opacity(0.45)
        for h in hourTicks {
            let text = Text(String(format: "%02d:00", h))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(labelColor)
            ctx.draw(text, at: CGPoint(x: x(h * 60, plot), y: plot.maxY + 12))
        }
        // y 轴刻度:最高(顶)/(可选)中位数(其真实高度)/ 0(底),右对齐贴绘图区左侧。
        var yTicks: [(CGFloat, Int)] = [(plot.minY, Int(buckets.maxTotal.rounded()))]
        if showMedian {
            yTicks.append((y(buckets.median, plot), Int(buckets.median.rounded())))
        }
        yTicks.append((plot.maxY, 0))
        for (py, value) in yTicks {
            let text = Text("\(value)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(labelColor)
            ctx.draw(text, at: CGPoint(x: plot.minX - 6, y: py), anchor: .trailing)
        }
    }
}

// MARK: - Record 卡片

/// 一条 writing_record 的可展开卡片。
/// 收起:app 色条 + app 名 + start 时间 + 内容预览(2 行)。
/// 点开:内容展全(可选中)+ 元数据(显示全)+ 编辑记录,spring 下拉展开。
private struct InputRecordCard: View {
    let record: WritingRecordViewRow
    let expanded: Bool
    let onToggle: () -> Void
    @State private var hovering = false
    /// 收起态内容测量:全文高 / 3 行显示高。全文更高 = 被截断,标 article 徽标。
    @State private var fullTextHeight: CGFloat = 0
    @State private var shownTextHeight: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    private var appLabel: String { InputCaptureView.appLabel(record.app) }
    private var accent: Color { AppColor.color(for: appLabel) }
    /// 3 行装不下(有隐藏内容)→ true。留 1pt 容差避免亚像素误判。
    private var isTruncated: Bool { fullTextHeight > shownTextHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            contentText
            if expanded {
                details
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(expanded ? 0.14 : 0.08),
                                lineWidth: 0.8)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        // 收起态整卡可点;展开态只有 header 可点(正文要留给文本选中)。
        .onTapGesture { if !expanded { onToggle() } }
    }

    private var cardFill: Color {
        let base: Double = expanded ? 0.055 : (hovering ? 0.048 : 0.032)
        return colorScheme == .light
            ? Color.black.opacity(base)
            : Color.white.opacity(base + 0.015)
    }

    // MARK: 收起态

    /// app 色条 + app 名 + (截断徽标) + start 时间 + 旋转 chevron。展开态点这行收起。
    private var headerRow: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3, height: 14)
            Text(appLabel)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(Self.hmFmt.string(from: Date(
                timeIntervalSince1970: TimeInterval(record.startTs) / 1000)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            // app、时间、标签依次靠左排。徽标超 3 行没显示全才有:
            // 特别长=article / 短一点=paragraph。
            if !expanded, isTruncated { lengthBadge }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    /// 内容:收起 3 行预览(截断标 article 徽标),展开显全 + 可选中。
    @ViewBuilder
    private var contentText: some View {
        let empty = record.text.isEmpty
        let display = empty ? "(empty content)" : record.text
        let base = Text(display)
            .font(.system(size: 12))
            .foregroundStyle(empty ? Color.secondary : Color.primary.opacity(0.88))

        if expanded {
            base
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                base
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 隐藏全文副本量高(fixedSize 忽略 3 行约束,给出真实全高)。
                    .background(fullTextProbe(display))
                    // 可见 3 行的实际高。
                    .overlay(GeometryReader { g in
                        Color.clear.preference(key: ShownTextHeightKey.self,
                                               value: g.size.height)
                    })
            }
            .onPreferenceChange(FullTextHeightKey.self) { fullTextHeight = $0 }
            .onPreferenceChange(ShownTextHeightKey.self) { shownTextHeight = $0 }
        }
    }

    /// 不限行数的隐藏副本 —— 只为量出全文完整高度,不参与卡片布局、不渲染。
    private func fullTextProbe(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background(GeometryReader { g in
                Color.clear.preference(key: FullTextHeightKey.self, value: g.size.height)
            })
    }

    /// 按长度分档:全文高 > 3 行高的 3 倍(≈9 行以上)= 特别长 = article;
    /// 只是超过 3 行没显示全(短一点)= paragraph。
    private var isArticle: Bool { fullTextHeight > shownTextHeight * 3 }

    /// 截断徽标,比暗淡的「…」显眼。用 app 色系;article / paragraph 分档。
    private var lengthBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: isArticle ? "text.justify" : "paragraph")
                .font(.system(size: 8, weight: .semibold))
            Text(isArticle ? "article" : "paragraph")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(accent.opacity(0.14)))
    }

    // MARK: 展开态

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().background(Color.primary.opacity(0.08))
                .padding(.top, 8)

            // 元数据:显示全。有值才列,不占空行。
            VStack(alignment: .leading, spacing: 3) {
                ForEach(metadataRows, id: \.0) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.0)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 80, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }

            let entries = Self.decodeEditLog(record.editLog)
            if !entries.isEmpty {
                Text("EDIT LOG · \(entries.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                        editEntryRow(e)
                    }
                }
            }
        }
    }

    private var metadataRows: [(String, String)] {
        var rows: [(String, String)] = []
        rows.append(("start", InputCaptureView.timeString(record.startTs)))
        rows.append(("end", InputCaptureView.timeString(record.endTs)))
        rows.append(("source", record.source))
        rows.append(("kind", record.kind))
        rows.append(("confidence", String(format: "%.2f", record.confidence)))
        rows.append(("chars", "\(record.text.count)"))
        if let u = record.url, !u.isEmpty { rows.append(("url", u)) }
        if let loc = record.location, !loc.isEmpty { rows.append(("location", loc)) }
        if let cs = record.contextSummary, !cs.isEmpty { rows.append(("context", cs)) }
        return rows
    }

    /// 单条编辑记录:[kind tag] text … 时刻。tag 按操作类型分色。
    private func editEntryRow(_ e: EditEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(e.kind)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Self.tagColor(e.kind))
                .cornerRadius(3)
            Text(e.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text(Self.hmsFmt.string(from: Date(
                timeIntervalSince1970: TimeInterval(e.ts) / 1000)))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private static func tagColor(_ kind: String) -> Color {
        switch kind {
        case "delete":        return Color.red.opacity(0.20)
        case "paste", "cut":  return Color.orange.opacity(0.20)
        case "undo", "redo":  return Color.secondary.opacity(0.15)
        default:              return Color.green.opacity(0.20)
        }
    }

    private static func decodeEditLog(_ json: String) -> [EditEntry] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([EditEntry].self, from: data)) ?? []
    }

    nonisolated(unsafe) private static let hmFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    nonisolated(unsafe) private static let hmsFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 内容截断测量 PreferenceKey

/// 全文(不限行)完整高度。
private struct FullTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 收起态实际显示(3 行)高度。
private struct ShownTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
