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

    func focus(_ bundleID: String) {
        if let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
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
