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

    /// 反复试到成功或超时, **同步返回结果**。
    ///
    /// 为什么要轮询: deep link 切会话会让整个界面重渲染, 立刻去找输入框多半
    /// 还没挂上; 而 Chromium 收到 AXManualAccessibility 之后是**异步**重建
    /// 无障碍树的 —— 实测不等的话只能看到 235 个节点的空壳, 等一下才有 1015 个。
    ///
    /// 为什么同步而不是丢后台: 结果要能回给调用方。这条路上没有任何其它可
    /// 观测点, 静默失败的话用户只会说"跳过去了但还是不能打字", 而我们什么
    /// 都查不到。上限 2.5 秒, 走的是自己那条 HTTP 连接, 不挡别的请求。
    static func focusInput(bundleID: String, timeout: TimeInterval = 2.5) -> Bool {
        guard let a = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return false }
        let pid = a.processIdentifier
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if focusInput(pid: pid) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
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
}
