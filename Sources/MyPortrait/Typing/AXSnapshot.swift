/// AXSnapshot —— 某一时刻 focused text element 的纯数据快照。
///
/// Step 2 只定义 struct + 字段 + memberwise init，不写任何 AX 抓取逻辑
/// （那是 Step 4 的事）。这里刻意不持有 AXUIElement 引用，保证本类型纯数据、
/// 可在测试里随手构造、不依赖 ApplicationServices。
struct AXSnapshot: Equatable {
    /// 元素当前全文。
    let value: String
    /// 选区（字符偏移，可空）。
    let selection: Range<Int>?
    /// UTC 毫秒时间戳。
    let timestampMs: Int64
    /// AX role（AXTextField / AXTextArea / ...），可空。
    let role: String?
    /// 来源 app 的 bundle id。
    let bundleId: String
    /// 来源 app 名，可空。
    let appName: String?
    /// 元素提示（placeholder / title 等），可空。
    let elementHint: String?

    init(
        value: String,
        selection: Range<Int>? = nil,
        timestampMs: Int64,
        role: String? = nil,
        bundleId: String,
        appName: String? = nil,
        elementHint: String? = nil
    ) {
        self.value = value
        self.selection = selection
        self.timestampMs = timestampMs
        self.role = role
        self.bundleId = bundleId
        self.appName = appName
        self.elementHint = elementHint
    }
}
