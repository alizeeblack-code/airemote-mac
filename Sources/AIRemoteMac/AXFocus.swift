import AppKit
import ApplicationServices

/// 切过去之后**把光标放进输入框**。
///
/// 为什么需要: `claude://resume` 能把会话切出来、窗口也拿到前台了, 但键盘
/// 焦点不在输入框上 —— 人还得伸手点一下才能打字。遥控的整个卖点是"不用
/// 走到电脑前", 差这一下就等于没做完。
///
/// 为什么走 AX 而不是别的:
///   * 桌面版**没有**聚焦输入框的快捷键(菜单和渲染层都翻过了, 没有)
///   * Apple Events 要单独的自动化授权(Ghostty 那条就卡在 -1743)
///   * 而辅助功能权限我们本来就有 —— 遥控敲键盘靠的就是它, 不新增授权面
///
/// ⚠️ Electron/Chromium 默认只暴露一个空壳 AX 树(几个元素), 必须先把
/// `AXManualAccessibility` 置真, 它才会把真正的控件铺出来(实测 5 → 1439 个)。
enum AXFocus {

    /// 把某个 app 的输入框聚焦。找不到或没生效就返回 false ——
    /// 不用兜底, 最坏情况是用户自己点一下, 和改动前一样。
    @discardableResult
    static func focusInput(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let target = findComposer(app) else { return false }
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // ⚠️ **必须回读确认**, 不能信 set 的返回值。Chromium 对这个属性是
        // "收下了就返回 success", 焦点有没有真落进去是另一回事 —— 只看返回值
        // 的话下面那个重试循环第一轮就会退出, 而光标其实还没进去。
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(target, kAXFocusedAttribute as CFString, &v)
        return (v as? Bool) ?? false
    }

    /// 反复试到**焦点站稳**或超时, 同步返回结果。
    ///
    /// ⚠️ 光"设上了"是不够的, 必须**等一下再回读确认它还在**。
    ///
    /// 实测: 切到另一条会话时, 点完侧栏界面要重渲染, 我们设的焦点会在几百
    /// 毫秒后**被重渲染抢回去** —— 表现是接口报 focused:true, 但人走过去
    /// 一看光标不在输入框里, 而且只在"真的换了会话"时才出现("再点一次同一条"
    /// 不重渲染, 反而是好的)。用户报的就是这个。
    ///
    /// 所以每轮: 设焦点 → 睡一下让重渲染有机会发生 → 回读。连着两次都还在
    /// 才认。多花约 0.8 秒, 换的是这个功能真的可用。
    ///
    /// 为什么同步而不是丢后台: 结果要能回给调用方。这条路上没有任何其它可
    /// 观测点, 静默失败的话用户只会说"跳过去了但还是不能打字", 而我们什么
    /// 都查不到。走的是自己那条 HTTP 连接, 不挡别的请求。
    static func focusInput(bundleID: String, timeout: TimeInterval = 4) -> Bool {
        guard let a = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return false }
        let pid = a.processIdentifier
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let deadline = Date().addingTimeInterval(timeout)
        var clicked = false
        repeat {
            // 先试设属性 —— 不动鼠标, 能成就最干净。
            _ = focusInput(pid: pid)
            Thread.sleep(forTimeInterval: 0.5)
            if composerFocused(pid) {
                Thread.sleep(forTimeInterval: 0.5)
                if composerFocused(pid) { return true }
            }
            // 设属性被重渲染抢回去了。**改成真点一下** —— 用户手动就是这么
            // 做的, 比设 AXFocused 硬得多; 属性可以被下一次渲染覆盖, 一次
            // 真实点击产生的焦点不会。只点一次, 免得反复挪用户的鼠标。
            if !clicked {
                clicked = true
                clickComposer(pid)
                Thread.sleep(forTimeInterval: 0.6)
                if composerFocused(pid) { return true }
            }
        } while Date() < deadline
        return composerFocused(pid)
    }

    /// 在输入框中心点一下。
    ///
    /// ⚠️ 点完要把鼠标挪回去。CGEvent 的点击会**真的移动光标** —— 用户正
    /// 盯着屏幕的话会看到指针莫名其妙跳走, 而他根本没碰鼠标。
    private static func clickComposer(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        guard let el = findComposer(app),
              let p = position(el), let sz = size(el), sz.width > 0 else { return }
        // 靠左一点: 输入框右侧常有发送/附件按钮, 点正中心可能戳到它们
        let pt = CGPoint(x: p.x + min(60, sz.width / 2), y: p.y + sz.height / 2)
        let restore = CGEvent(source: nil)?.location
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        if let r = restore { CGWarpMouseCursorPosition(r) }
    }

    private static func size(_ el: AXUIElement) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success,
              let val = v else { return nil }
        var s = CGSize.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(val as! AXValue, .cgSize, &s) else { return nil }
        return s
    }

    /// 输入框此刻是不是焦点。
    ///
    /// ⚠️ 这里**也要**置 AXManualAccessibility。切会话会换渲染进程, 新进程的
    /// 无障碍树是塌着的 —— 不重新打开就 findComposer == nil, 于是"读不到
    /// 输入框"被当成"焦点丢了", 白白重试甚至误报失败。查了半天才想明白。
    private static func composerFocused(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let el = findComposer(app) else { return false }
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXFocusedAttribute as CFString, &v)
        return (v as? Bool) ?? false
    }

    /// 找"最像输入框"的那个元素。
    ///
    /// 判据是**可设焦点的文本控件里位置最靠下的那个** —— 聊天类界面的输入框
    /// 永远在底部, 而上面可能还有搜索框、标题编辑框这些同类控件。只按类型取
    /// 第一个的话很容易focus到搜索框上去。
    private static func findComposer(_ app: AXUIElement) -> AXUIElement? {
        var best: (el: AXUIElement, y: CGFloat)?
        for el in descendants(app) {
            guard isEditable(el), let p = position(el) else { continue }
            if best == nil || p.y > best!.y { best = (el, p.y) }
        }
        return best?.el
    }

    private static func isEditable(_ el: AXUIElement) -> Bool {
        guard let role = string(el, kAXRoleAttribute) else { return false }
        // AXTextArea / AXTextField 是常规控件; Electron 里富文本输入框常常是
        // 一个 contenteditable, 会以 AXGroup + AXTextArea 的组合出现。
        guard role == kAXTextAreaRole || role == kAXTextFieldRole else { return false }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(el, kAXFocusedAttribute as CFString, &settable)
        return settable.boolValue
    }

    private static func position(_ el: AXUIElement) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success,
              let val = v else { return nil }
        var p = CGPoint.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(val as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// 广度优先铺开整棵树。
    ///
    /// ⚠️ 必须封顶。Electron 打开 AXManualAccessibility 之后树有上千个节点,
    /// 而且**可能有环**(某些容器会把自己列进 children); 不封顶会在 HTTP
    /// 线程上转到天荒地老, 手机那边表现为整个遥控卡死。
    private static func descendants(_ root: AXUIElement, limit: Int = 4000) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var queue = [root]
        while !queue.isEmpty, out.count < limit {
            let el = queue.removeFirst()
            out.append(el)
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
                  let kids = v as? [AXUIElement] else { continue }
            queue.append(contentsOf: kids)
        }
        return out
    }

    // MARK: - 侧栏

    /// 点侧栏上标题为 `title` 的那一行。
    ///
    /// 侧栏每行是个 AXButton, 标签形如 `<状态> <标题>` ——
    /// `Running <标题>` / `Idle <标题>` / `Awaiting input <标题>` /
    /// `Unread response <标题>`。判据用**以标题结尾**, 不去枚举状态词:
    /// 状态是会变的(而且还会新增), 枚举必然漏。
    ///
    /// ⚠️ 侧栏是个虚拟滚动列表, **只有渲染出来的行才在 AX 树里**。目标会话
    /// 滚出可视区就点不着 —— 返回 false, 调用方退回只切 app。好在按活跃度
    /// 排序, 你会去跳的那些本来就在最上面。
    static func clickSidebarRow(pid: pid_t, title: String) -> Bool {
        guard !title.isEmpty else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let deadline = Date().addingTimeInterval(2.5)
        repeat {
            // 同上: 每轮都置一遍, 树可能刚塌过
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            for el in descendants(app) {
                guard string(el, kAXRoleAttribute) == kAXButtonRole,
                      let p = position(el), p.x < 420 else { continue }   // 只看左侧栏
                let label = string(el, kAXTitleAttribute)
                    ?? string(el, kAXDescriptionAttribute) ?? ""
                guard label == title || label.hasSuffix(" " + title) else { continue }
                return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }
}
