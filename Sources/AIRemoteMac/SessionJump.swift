import AppKit
import Foundation

/// 跳到**某个具体会话**, 而不只是把宿主 app 切到前面。
///
/// 之前试过 AppleScript 按 cwd 在 Ghostty 里找终端、试过读 Claude 桌面版的
/// 无障碍树按侧栏标题匹配 —— 前者卡在自动化授权(-1743), 后者覆盖率只有 2/5
/// 而且有误配(我们的名字来自 transcript 的 cwd, 它侧栏显示的是自己生成的
/// 对话标题, 两者根本不是一回事)。两条路都放弃了。
///
/// 真正的路子是官方的 deep link: `claude://resume?session=<CLI session UUID>`。
/// 桌面版收到后走 importCliSession, 直接把那个会话开出来。
/// (从 app 包里挖出来的; 参数名是 `session`, **不是** sessionId —— 写错的话
/// 日志里只留一句 "Resume deep link: missing or invalid session", app 照样
/// 被拉到前台, 看起来像"切过去了但没换会话"。)
///
/// ⚠️ Claude Code 的 **CLI session UUID 就是 transcript 的文件名**, 所以不用
/// 额外维护映射。桌面版内部那个 `local_<uuid>` 是它自己加的前缀。
enum SessionJump {

    /// 这个会话能不能精确跳。
    ///
    /// 只有 Claude 有 deep link; Codex 没有对外的会话入口, 只能退回切 app。
    static func canJump(tool: SessionScan.Tool, transcript: String) -> Bool {
        tool == .claude && sessionID(from: transcript) != nil
    }

    /// 跳过去。成功返回 true; 返回 false 时调用方应该退回"切宿主 app"。
    @discardableResult
    static func jump(tool: SessionScan.Tool, transcript: String) -> Bool {
        guard tool == .claude, let sid = sessionID(from: transcript),
              let url = URL(string: "claude://resume?session=\(sid)")
        else { return false }
        // ⚠️ **必须显式 activates = true**。
        //
        // 光调 NSWorkspace.open(url) 的话, URL 事件投递到了(桌面版日志里
        // 确实有 "importing CLI session ..."), 但 app **不会被拉到前台** ——
        // 表现成"会话在后台悄悄切了, 你看到的还是原来那个窗口", 比完全不
        // 工作还费解。(shell 里 `open claude://...` 会激活, 是因为 open(1)
        // 默认就带激活; NSWorkspace 的默认值不一样。)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(url, configuration: cfg) { app, _ in
            // 和 AppContext.focus 一样补一刀, 把其余窗口带上来
            DispatchQueue.main.async { app?.activate(options: [.activateAllWindows]) }
        }
        return true
    }

    /// transcript 路径 → CLI session UUID。
    ///
    /// 格式必须校验: 桌面版那边对非 UUID 的值是**静默拒绝**的(只写一条 warn),
    /// 我们这边却会以为跳成功了。不如自己先拦住, 退回切 app 至少有反应。
    private static func sessionID(from transcript: String) -> String? {
        let name = ((transcript as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        guard isUUID(name) else { return nil }
        return name
    }

    /// 8-4-4-4-12 十六进制。不引正则, 这点判断手写更快也更好读。
    private static func isUUID(_ s: String) -> Bool {
        let groups = s.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5,
              [8, 4, 4, 4, 12] == groups.map(\.count) else { return false }
        return s.allSatisfy { $0 == "-" || $0.isHexDigit }
    }
}
