import Foundation
import AppKit
import CoreGraphics

/// 前台 app 追踪 + 使用历史。等价于 hs.application.watcher / hs.window.orderedWindows。
final class AppContext {
    static let shared = AppContext()

    /// 最近使用顺序, 下标 0 是当前 app
    private(set) var history: [String] = []

    private var cycleSnapshot: [String]?
    private var cycleIndex = 1
    private var cycleTimer: Timer?

    private init() {
        seedHistory()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            if let bid = app?.bundleIdentifier { self?.push(bid) }
        }
    }

    var frontBundle: String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    }

    /// 通知只能记录 app 启动之后的切换。不播种的话每次重启历史都只剩当前 app,
    /// "切到上一个 app" 会一直没反应。窗口层级顺序正好是"最近使用"的近似。
    private func seedHistory() {
        if let f = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { history.append(f) }

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }

        let running = NSWorkspace.shared.runningApplications
        for w in list where history.count < 12 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let bid = running.first(where: { $0.processIdentifier == pid })?.bundleIdentifier,
                  !history.contains(bid)
            else { continue }
            history.append(bid)
        }
    }

    private func push(_ bid: String) {
        history.removeAll { $0 == bid }
        history.insert(bid, at: 0)
        if history.count > 12 { history.removeLast(history.count - 12) }
    }

    /// 把某个 app 切到前台。
    ///
    /// ⚠️ **必须走 LaunchServices(openApplication), 不能用 activate()。**
    ///
    /// 原来的写法是"在跑就 activate、没跑才 openApplication"。从 macOS 14
    /// 起, 后台进程调 NSRunningApplication.activate() 会被系统**静默忽略**
    /// —— 而我们是 LSUIElement, 永远不在前台, 所以永远命中这条限制。
    /// 症状极具迷惑性: 动作返回 ok、日志干净、什么错都不报, 就是不切。
    /// (实测 macOS 26: activate 无效, `open -b` 立刻生效。)
    ///
    /// openApplication 走的是 LaunchServices, 由系统代为激活, 不受这条限制;
    /// 对已经在跑的 app 它就是"激活", 不会开新实例。
    ///
    /// 这条路径同时喂着手机端的「切过去」和手柄的「切到某个 app」, 两边都靠它。
    func focus(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            // 拿不到路径(没装/被删了)。退回 activate() 聊胜于无 ——
            // 我们自己恰好在前台时它还是有效的。
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == bundleID }?
                .activate(options: [.activateAllWindows])
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = false
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
            // 补一刀, 把这个 app 的其余窗口也带上来 —— openApplication 只保证
            // 主窗口到前面。此时目标 app 已经是前台了, activate 不再受限制。
            // 失败也无所谓, 切换本身上一步已经完成。
            DispatchQueue.main.async { app?.activate(options: [.activateAllWindows]) }
        }
    }

    /// 不发 Cmd+Tab: 那是按住修饰键连点的交互, 而且 Dock/WindowServer 对它有
    /// 特殊处理, 合成事件经常打不进去。自己维护顺序更可靠。
    ///
    /// 第一次按时给历史拍快照 —— 切 app 本身会改动历史, 不快照的话连按就在
    /// 两个 app 之间横跳, 翻不深。
    func switchToPrevious() {
        if cycleSnapshot == nil {
            cycleSnapshot = history
            cycleIndex = 1
        }
        guard let snap = cycleSnapshot, snap.count >= 2 else { return }

        cycleIndex += 1
        if cycleIndex > snap.count { cycleIndex = 2 }
        focus(snap[cycleIndex - 1])

        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.cycleSnapshot = nil
        }
    }

    /// 通用按键是否该在当前 app 生效。白名单查表, 免得在 Finder、
    /// 确认对话框之类的地方误触回车。
    func inTarget() -> Bool {
        let cfg = ConfigStore.shared.config
        if !cfg.restrictToTargets { return true }
        return cfg.targetApps.contains(frontBundle)
    }

    var inGhostty: Bool { frontBundle == BundleID.ghostty }
    var inClaude:  Bool { frontBundle == BundleID.claude }
    var inWeChat:  Bool { frontBundle == BundleID.wechat }
    var inChrome:  Bool { frontBundle == BundleID.chrome }
}
