import Foundation

/// 开发者模式 —— 让 app 的**界面**指向一套编造的演示数据(`~/.portrait-dev`),
/// 而后台采集与 pipeline 继续读写真实的 `~/.portrait`。用来调"新用户第一次
/// 打开"的观感、以及录演示视频而不暴露真实数据。
///
/// 三条铁律(08-09 用户定,改这个文件前先读):
///
/// 1. **capture 永远写 `~/.portrait`** —— dev mode 期间一帧都不能少。
/// 2. **pipeline 定时任务永远读写 `~/.portrait`** —— 它产出的是真实记忆。
/// 3. **config 按 section 切**:界面类(display / general / aiModels /
///    notifications / usage / chat / personalInfo)跟 dev 走;后台类
///    (capture / privacy / storage / scheduler / memory)永远读真实值,
///    且在 dev mode 下**只读**(ConfigStore.mutate 会把改动丢弃)。
///    这条线画在配置项上而不是调用方上,是因为后者要人工判断 ~85 处读取点,
///    漏一处(比如 storage.retentionDays)就是真删数据。
enum DevMode {
    /// `~/.portrait-dev` —— 演示数据根。**不进 git**(用户 08-09 定):
    /// 生成脚本在 `Scripts/` 里进版本控制,数据本身随时可重新生成。
    static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".portrait-dev", isDirectory: true)
    }

    /// 开关是否**可见**。判据 = `~/.portrait-dev` 目录存在。
    ///
    /// 别人 clone 这个仓库、或装发布版 app,都没有这个目录 → 整张设置卡不渲染。
    /// **故意不做密钥**:本地 app 里"藏一个功能"从来不是安全边界(用户对自己
    /// 的机器有完全控制权),目录判据够用、零维护,而且不存在"私钥读取逻辑
    /// 要不要上 GitHub"这个自相矛盾的问题 —— 代码本来就是公开的。
    static var isAvailable: Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    private static let defaultsKey = "MyPortrait.devMode.enabled"

    /// 本进程当前是否处于 dev mode。**启动时读一次就冻结**。
    ///
    /// 路径在进程生命周期内必须恒定 —— 半路改变会让已经打开的 sqlite 连接、
    /// config 文件监听器、各视图的列表缓存分别指向两个根,状态必然对不上,
    /// 且很难查(表现是"某个面板还显示旧数据")。所以切换只写 UserDefaults,
    /// 重启后生效。
    ///
    /// 存 UserDefaults 而不是 config.toml —— config 自己就是被切换的对象之一,
    /// 把开关放进去会变成鸡生蛋。
    /// `let` 不只是风格 —— 它就是"冻结"本身:静态 let 由 swift_once 保证只求值
    /// 一次且线程安全,从类型上就写死了"运行中不可能变"。
    static let isOn: Bool = {
        UserDefaults.standard.bool(forKey: defaultsKey) && isAvailable
    }()

    /// 写下新状态,**下次启动生效**。
    static func setEnabledPendingRestart(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: defaultsKey)
    }

    /// 磁盘上记录的意愿(可能与本进程正在用的 `isOn` 不一致 = 待重启)。
    static var desiredOn: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// 需要重启才能生效。UI 据此显示提示。
    static var needsRestart: Bool { desiredOn != isOn }
}
