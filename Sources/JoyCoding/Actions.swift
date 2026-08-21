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
         group: String = "通用", repeatable: Bool = false,
         onlyIn: String? = nil, run: @escaping () -> Void) {
        self.id = id; self.name = name; self.detail = detail
        self.group = group; self.repeatable = repeatable
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

    // 同一颗键在不同 app 里做语义相同、快捷键不同的事。按键不够用时
    // 这是最划算的扩展方式 —— 肌肉记忆通用, 行为跟着场景走。
    private static let sessionKeys: [String: (prev: ([String], String), next: ([String], String))] = [
        // Claude Code 桌面版 (官方文档: 是 Ctrl 不是 Cmd)
        BundleID.claude: (([ "ctrl", "shift" ], "tab"), ([ "ctrl" ], "tab")),
        // Chrome 切标签, 和 Claude 巧合地是同一组键
        BundleID.chrome: (([ "ctrl", "shift" ], "tab"), ([ "ctrl" ], "tab")),
        // Ghostty 走【窗口】而不是标签页 —— 实际用法就是开多个窗口。
        // Cmd+` 是系统级的"移到应用程序中的下一个窗口", Ghostty 自己没占用。
        BundleID.ghostty: (([ "cmd", "shift" ], "`"), ([ "cmd" ], "`")),
        // 微信 (菜单 Show → Show Previous/Next Chat)
        BundleID.wechat: (([ "alt" ], "up"), ([ "alt" ], "down")),
    ]

    static let all: [ActionDef] = [

        // ── 通用 ──────────────────────────────────────────────
        ActionDef("confirm", "确认 / 发送", "回车；菜单打开时是「选中」") {
            if ctx.inTarget() { key([], "return") }
            MenuMode.exit()
        },
        ActionDef("cancel", "打断 / 取消", "Esc；菜单打开时是「关掉菜单」") {
            if ctx.inTarget() { key([], "escape") }
            MenuMode.exit()
        },
        ActionDef("delete", "退格删除", repeatable: true) {
            if ctx.inTarget() { key([], "delete") }
        },
        ActionDef("clearLine", "清空当前输入", "终端发 Ctrl+U, 其它发 Cmd+A 再退格") {
            if ctx.inGhostty { key(["ctrl"], "u") }
            else if ctx.inTarget() {
                key(["cmd"], "a")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { key([], "delete") }
            }
        },
        ActionDef("scrollUp", "向上翻页", "菜单打开时变成「上一项」", repeatable: true) {
            guard ctx.inTarget() else { return }
            if MenuMode.active { key([], "up") } else { KeySynth.scroll(lines: 8) }
        },
        ActionDef("scrollDown", "向下翻页", "菜单打开时变成「下一项」", repeatable: true) {
            guard ctx.inTarget() else { return }
            if MenuMode.active { key([], "down") } else { KeySynth.scroll(lines: -8) }
        },
        ActionDef("up", "上", repeatable: true) { if ctx.inTarget() { key([], "up") } },
        ActionDef("down", "下", repeatable: true) { if ctx.inTarget() { key([], "down") } },
        ActionDef("left", "左", repeatable: true) { if ctx.inTarget() { key([], "left") } },
        ActionDef("right", "右", repeatable: true) { if ctx.inTarget() { key([], "right") } },
        ActionDef("ptt", "语音输入", "按住录, 松开出字") { /* 按下/松开另行处理 */ },
        ActionDef("focusInput", "聚焦输入框", "点一下底部输入区") {
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
        ActionDef("sessionPrev", "上一个会话", "Claude Session / 微信聊天 / Chrome 标签 / Ghostty 窗口",
                  group: "会话", repeatable: true) {
            if let k = sessionKeys[ctx.frontBundle] { key(k.prev.0, k.prev.1) }
        },
        ActionDef("sessionNext", "下一个会话", "Claude Session / 微信聊天 / Chrome 标签 / Ghostty 窗口",
                  group: "会话", repeatable: true) {
            if let k = sessionKeys[ctx.frontBundle] { key(k.next.0, k.next.1) }
        },
        ActionDef("wechatNextUnread", "下一个未读会话", "微信 · Cmd+Opt+↓",
                  group: "会话", onlyIn: BundleID.wechat) {
            if ctx.inWeChat { key(["cmd", "alt"], "down") }
        },
        ActionDef("windowNext", "下一个窗口", "同一个 app 的窗口间切换", group: "会话") {
            key(["cmd"], "`")
        },

        // ── Claude Code ───────────────────────────────────────
        ActionDef("newSession", "新建 Session", "Cmd+N", group: "Claude Code", onlyIn: BundleID.claude) {
            if ctx.inClaude { key(["cmd"], "n") }
        },
        ActionDef("modelMenu", "切换模型", "Claude 开菜单 / Codex 打 /model", group: "Claude Code") {
            if ctx.inClaude {
                key(["cmd", "shift"], "i")
                MenuMode.enter()      // 摇杆上下随即变成选项上下
            } else if ctx.inGhostty {
                KeySynth.type("/model")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { key([], "return") }
                MenuMode.enter()
            }
        },
        ActionDef("effortMenu", "切换 effort", "Cmd+Shift+E", group: "Claude Code", onlyIn: BundleID.claude) {
            if ctx.inClaude { key(["cmd", "shift"], "e"); MenuMode.enter() }
        },
        ActionDef("mode", "切权限模式", "Codex:Shift+Tab / Claude:Cmd+Shift+M", group: "Claude Code") {
            // 桌面版不吃 Shift+Tab —— 那是终端专有的, 官方文档明确写了
            if ctx.inGhostty { key(["shift"], "tab") }
            else if ctx.inClaude { key(["cmd", "shift"], "m"); MenuMode.enter() }
        },
        ActionDef("diffPane", "切换 diff 面板", "看改了什么", group: "Claude Code", onlyIn: BundleID.claude) {
            if ctx.inClaude { key(["cmd", "shift"], "d") }
        },
        ActionDef("terminalPane", "切换终端面板", "内置 shell", group: "Claude Code", onlyIn: BundleID.claude) {
            if ctx.inClaude { key(["ctrl"], "`") }
        },
        ActionDef("browserPane", "切换 Browser 面板", group: "Claude Code", onlyIn: BundleID.claude) {
            if ctx.inClaude { key(["cmd", "shift"], "b") }
        },
        ActionDef("sideChat", "打开 side chat", group: "Claude Code", onlyIn: BundleID.claude) {
            if ctx.inClaude { key(["cmd"], ";") }
        },
        ActionDef("closePane", "关闭当前分栏", group: "Claude Code", onlyIn: BundleID.claude) {
            if ctx.inClaude { key(["cmd"], "\\") }
        },
        ActionDef("viewMode", "循环视图模式", "控制正文详细程度", group: "Claude Code", onlyIn: BundleID.claude) {
            if ctx.inClaude { key(["ctrl"], "o") }
        },

        // ── 终端 ──────────────────────────────────────────────
        ActionDef("interrupt", "Ctrl+C", "⚠️ Codex 里这是退出 CLI, 打断请用 Esc", group: "终端", onlyIn: BundleID.ghostty) {
            if ctx.inGhostty { key(["ctrl"], "c") }
        },

        // ── Chrome ────────────────────────────────────────────
        ActionDef("navBack", "后退", "Cmd+[", group: "Chrome", repeatable: true, onlyIn: BundleID.chrome) {
            if ctx.inChrome { key(["cmd"], "[") }
        },
        ActionDef("navForward", "前进", "Cmd+]", group: "Chrome", repeatable: true, onlyIn: BundleID.chrome) {
            if ctx.inChrome { key(["cmd"], "]") }
        },
        ActionDef("reload", "刷新页面", "Cmd+R", group: "Chrome", onlyIn: BundleID.chrome) {
            if ctx.inChrome { key(["cmd"], "r") }
        },
        ActionDef("newTab", "新建标签", "Cmd+T", group: "Chrome", onlyIn: BundleID.chrome) {
            if ctx.inChrome { key(["cmd"], "t") }
        },
        ActionDef("closeTab", "关闭当前标签", "Cmd+W；最后一个标签会连窗口一起关",
                  group: "Chrome", onlyIn: BundleID.chrome) {
            if ctx.inChrome { key(["cmd"], "w") }
        },

        // ── 切换 app (不受白名单限制, 任何地方都能用) ──────────
        ActionDef("switchApp", "切换到上一个 app", "连按继续往前翻", group: "切换 app") {
            ctx.switchToPrevious()
        },
        ActionDef("focusClaude", "切到 Claude Code", group: "切换 app") { ctx.focus(BundleID.claude) },
        ActionDef("focusGhostty", "切到 Ghostty", group: "切换 app") { ctx.focus(BundleID.ghostty) },
        ActionDef("focusWeChat", "切到微信", group: "切换 app") { ctx.focus(BundleID.wechat) },
        ActionDef("focusChrome", "切到 Chrome", group: "切换 app") { ctx.focus(BundleID.chrome) },
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
