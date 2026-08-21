import Foundation

struct ActionDef: Identifiable {
    let id: String
    let name: String
    let detail: String
    let group: String
    /// 按住是否连发 (退格、方向、翻页这类)
    let repeatable: Bool
    /// 只在这个 app 里有效。界面在别的层里会把它置灰并标注,
    /// 而不是直接隐藏 —— 隐藏会让人以为功能没了。
    let onlyIn: String?
    let run: () -> Void

    init(_ id: String, _ name: String, _ detail: String = "",
         group: String? = nil, repeatable: Bool = false,
         onlyIn: String? = nil, run: @escaping () -> Void) {
        self.id = id; self.name = name; self.detail = detail
        self.group = group ?? L("通用"); self.repeatable = repeatable
        self.onlyIn = onlyIn; self.run = run
    }
}

/// 菜单模式。
///
/// 打开模型/权限/effort 菜单后, 摇杆上下应该是"选项上下移动"而不是"翻页"。
/// 本想用无障碍接口检测菜单是否打开, 但 Claude Code 是 Web 界面, 菜单是
/// 网页渲染的, AXFocusedUIElement 根本看不到。所以改成显式模式:
/// 触发菜单的动作顺手进入模式, 确认/取消或超时自动退出。
enum MenuMode {
    static private(set) var active = false
    private static var timer: Timer?

    static func enter(_ seconds: Double = 6) {
        active = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            active = false
        }
    }

    static func exit() {
        active = false
        timer?.invalidate(); timer = nil
    }
}

enum Actions {
    static let ctx = AppContext.shared
    private static func key(_ m: [String], _ k: String) { KeySynth.keyStroke(m, k) }

    /// 按当前前台 app 查档案表并发出去。
    /// 这是「语义动作 → 具体快捷键」的唯一出口 —— 以前这层散落在 21 处
    /// if inClaude / inGhostty 里, 加个 app 就得改代码。
    private static func send(_ action: String) {
        let app = ctx.frontBundle
        guard let spec = AppProfiles.key(action, app: app) else { return }
        if spec.isText {
            KeySynth.type(spec.text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { key([], "return") }
        } else if let (mods, k) = spec.parsed {
            key(mods, k)
        }
    }

    // 同一颗键在不同 app 里做语义相同、快捷键不同的事。按键不够用时
    // 这是最划算的扩展方式 —— 肌肉记忆通用, 行为跟着场景走。
    static let all: [ActionDef] = [

        // ── 通用 ──────────────────────────────────────────────
        ActionDef("confirm", L("确认 / 发送"), L("回车；菜单打开时是「选中」")) {
            if ctx.inTarget() { key([], "return") }
            MenuMode.exit()
        },
        ActionDef("cancel", L("打断 / 取消"), L("Esc；菜单打开时是「关掉菜单」")) {
            if ctx.inTarget() { key([], "escape") }
            MenuMode.exit()
        },
        ActionDef("delete", L("退格删除"), repeatable: true) {
            if ctx.inTarget() { key([], "delete") }
        },
        ActionDef("clearLine", L("清空当前输入"), L("终端是 Ctrl+U，输入框是全选再删")) {
            guard ctx.inTarget() else { return }
            if let spec = AppProfiles.key("clearLine", app: ctx.frontBundle),
               let (m, k) = spec.parsed {
                key(m, k)
                // 全选之后还得删一下
                if k == "a" && m.contains("cmd") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { key([], "delete") }
                }
            }
        },
        ActionDef("scrollUp", L("向上翻页"), L("菜单打开时变成「上一项」"), repeatable: true) {
            guard ctx.inTarget() else { return }
            if MenuMode.active { key([], "up") } else { KeySynth.scroll(lines: 8) }
        },
        ActionDef("scrollDown", L("向下翻页"), L("菜单打开时变成「下一项」"), repeatable: true) {
            guard ctx.inTarget() else { return }
            if MenuMode.active { key([], "down") } else { KeySynth.scroll(lines: -8) }
        },
        ActionDef("up", L("上"), repeatable: true) { if ctx.inTarget() { key([], "up") } },
        ActionDef("down", L("下"), repeatable: true) { if ctx.inTarget() { key([], "down") } },
        ActionDef("left", L("左"), repeatable: true) { if ctx.inTarget() { key([], "left") } },
        ActionDef("right", L("右"), repeatable: true) { if ctx.inTarget() { key([], "right") } },
        ActionDef("ptt", L("语音输入"), L("按住录, 松开出字")) { /* 按下/松开另行处理 */ },
        ActionDef("focusInput", L("聚焦输入框"), L("点一下底部输入区")) {
            // Claude Code / 微信都没有聚焦输入框的快捷键(文档和菜单都查过),
            // Web 界面也不暴露无障碍元素。只能按窗口比例点 —— 聊天界面的
            // 输入框总在底部, 这个位置很稳。
            let offset: CGFloat
            switch ctx.frontBundle {
            case BundleID.claude: offset = 72
            case BundleID.wechat: offset = 52
            default:              offset = 60
            }
            guard ctx.inTarget(), !ctx.inGhostty,     // 终端本来就一直有焦点
                  let p = KeySynth.composerPoint(bottomOffset: offset) else { return }
            KeySynth.click(at: p)
        },

        // ── 会话 / 标签 ────────────────────────────────────────
        ActionDef("sessionPrev", L("上一个会话"), L("Session / 聊天 / 标签 / 窗口，看 app"),
                  group: L("会话"), repeatable: true) { send("sessionPrev") },
        ActionDef("sessionNext", L("下一个会话"), L("Session / 聊天 / 标签 / 窗口，看 app"),
                  group: L("会话"), repeatable: true) { send("sessionNext") },
        ActionDef("wechatNextUnread", L("下一个未读会话"), L("微信 · Cmd+Opt+↓"),
                  group: L("会话"), onlyIn: BundleID.wechat) {
            send("wechatNextUnread")
        },
        ActionDef("windowNext", L("下一个窗口"), L("同一个 app 的窗口间切换"), group: L("会话")) {
            send("windowNext")
        },

        // ── Claude Code ───────────────────────────────────────
        ActionDef("newSession", L("新建 Session"), "Cmd+N", group: "Claude Code", onlyIn: BundleID.claude) {
            send("newSession")
        },
        ActionDef("modelMenu", L("切换模型"), L("Claude 开菜单 / Codex 打 /model"), group: "Claude Code") {
            send("modelMenu")
        },
        ActionDef("effortMenu", L("切换 effort"), "Cmd+Shift+E", group: "Claude Code", onlyIn: BundleID.claude) {
            send("effortMenu")
        },
        ActionDef("mode", L("切权限模式"), "Codex:Shift+Tab / Claude:Cmd+Shift+M", group: "Claude Code") {
            send("mode")
        },
        ActionDef("diffPane", L("切换 diff 面板"), L("看改了什么"), group: "Claude Code", onlyIn: BundleID.claude) {
            send("diffPane")
        },
        ActionDef("terminalPane", L("切换终端面板"), L("内置 shell"), group: "Claude Code", onlyIn: BundleID.claude) {
            send("terminalPane")
        },
        ActionDef("browserPane", L("切换 Browser 面板"), group: "Claude Code", onlyIn: BundleID.claude) {
            send("browserPane")
        },
        ActionDef("sideChat", L("打开 side chat"), group: "Claude Code", onlyIn: BundleID.claude) {
            send("sideChat")
        },
        ActionDef("closePane", L("关闭当前分栏"), group: "Claude Code", onlyIn: BundleID.claude) {
            send("closePane")
        },
        ActionDef("viewMode", L("循环视图模式"), L("控制正文详细程度"), group: "Claude Code", onlyIn: BundleID.claude) {
            send("viewMode")
        },

        // ── 终端 ──────────────────────────────────────────────
        ActionDef("interrupt", "Ctrl+C", L("⚠️ Codex 里这是退出 CLI, 打断请用 Esc"), group: L("终端"), onlyIn: BundleID.ghostty) {
            send("interrupt")
        },

        // ── Chrome ────────────────────────────────────────────
        ActionDef("navBack", L("后退"), "Cmd+[", group: "Chrome", repeatable: true, onlyIn: BundleID.chrome) {
            send("navBack")
        },
        ActionDef("navForward", L("前进"), "Cmd+]", group: "Chrome", repeatable: true, onlyIn: BundleID.chrome) {
            send("navForward")
        },
        ActionDef("reload", L("刷新页面"), "Cmd+R", group: "Chrome", onlyIn: BundleID.chrome) {
            send("reload")
        },
        ActionDef("newTab", L("新建标签"), "Cmd+T", group: "Chrome", onlyIn: BundleID.chrome) {
            send("newTab")
        },
        ActionDef("closeTab", L("关闭当前标签"), L("Cmd+W；最后一个标签会连窗口一起关"),
                  group: "Chrome", onlyIn: BundleID.chrome) {
            send("closeTab")
        },

        // ── 切换 app (不受白名单限制, 任何地方都能用) ──────────
        ActionDef("switchApp", L("切换到上一个 app"), L("连按继续往前翻"), group: L("切换 app")) {
            ctx.switchToPrevious()
        },
        ActionDef("focusClaude", L("切到 Claude Code"), group: L("切换 app")) { ctx.focus(BundleID.claude) },
        ActionDef("focusGhostty", L("切到 Ghostty"), group: L("切换 app")) { ctx.focus(BundleID.ghostty) },
        ActionDef("focusWeChat", L("切到微信"), group: L("切换 app")) { ctx.focus(BundleID.wechat) },
        ActionDef("focusChrome", L("切到 Chrome"), group: L("切换 app")) { ctx.focus(BundleID.chrome) },
    ]

    static let byID: [String: ActionDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static var groups: [String] {
        var seen: [String] = []
        for a in all where !seen.contains(a.group) { seen.append(a.group) }
        return seen
    }

    static func run(_ id: String) {
        guard let a = byID[id] else { return }
        DispatchQueue.main.async { a.run() }
    }

    static func isRepeatable(_ id: String) -> Bool { byID[id]?.repeatable ?? false }

    /// 在指定 app 下有效的动作。手机界面靠它动态过滤 ——
    /// 换个 app 就变死键的动作不该占着屏幕。
    static func available(in app: String) -> [ActionDef] {
        all.filter { $0.onlyIn == nil || $0.onlyIn == app }
    }

    // MARK: - 语音 (按下/松开语义, 不走普通动作)

    private static var pttWatchdog: Timer?

    static func pttStart() {
        let cfg = ConfigStore.shared.config
        guard cfg.pttStyle == "hold" else {
            KeySynth.keyStroke(cfg.pttMods, cfg.pttKey); return
        }
        pttPost(down: true)
        // 保险丝: 手柄掉线 / 松开事件丢了, 也不能让修饰键永远卡住
        pttWatchdog?.invalidate()
        pttWatchdog = Timer.scheduledTimer(withTimeInterval: cfg.pttMaxHold, repeats: false) { _ in
            pttPost(down: false)
            NSLog("[JoyCoding] PTT 超过 \(cfg.pttMaxHold)s, 已强制松开")
        }
    }

    static func pttStop() {
        let cfg = ConfigStore.shared.config
        switch cfg.pttStyle {
        case "hold":
            pttWatchdog?.invalidate(); pttWatchdog = nil
            pttPost(down: false)
        case "toggle":
            KeySynth.keyStroke(cfg.pttMods, cfg.pttKey)
        default:
            break   // "tap": 松开不做事, 靠下次按下停止听写
        }
    }

    private static func pttPost(down: Bool) {
        let cfg = ConfigStore.shared.config
        if KeySynth.isModifier(cfg.pttKey) {
            KeySynth.modifierHold(cfg.pttKey, down: down)
        } else if down {
            KeySynth.keyDown(cfg.pttMods, cfg.pttKey)
        } else {
            KeySynth.keyUp(cfg.pttMods, cfg.pttKey)
        }
    }
}
