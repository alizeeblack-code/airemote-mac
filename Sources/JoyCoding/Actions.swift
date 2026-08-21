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
    private static let base: [ActionDef] = [

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
    ]

    // MARK: - 「切到某个 app」按白名单动态生成
    //
    // 原来是四条写死的 focusClaude/focusGhostty/focusWeChat/focusChrome。
    // 用户往白名单里加了别的 app(比如 Codex), 手柄这边根本没有对应动作可绑,
    // 手机那边也会被 cfgApps 静默丢掉 —— 加一个 app 就要改一次代码。

    /// 这四个 app 沿用老 ID: 用户配置里已经绑着它们了, 换 ID 会让绑定静默失效。
    static let legacyFocusID: [String: String] = [
        BundleID.claude: "focusClaude", BundleID.ghostty: "focusGhostty",
        BundleID.wechat: "focusWeChat", BundleID.chrome: "focusChrome",
    ]

    /// 某个 app 对应的动作 ID。已知的给老 ID, 其余用 focus:<bundleID>。
    static func focusID(for bundle: String) -> String {
        legacyFocusID[bundle] ?? "focus:\(bundle)"
    }

    /// 出现在动作表里的 app: 白名单 ∪ 那四个老的。
    /// 并上老的是为了不改变现状 —— 有人可能把 Chrome 移出了白名单但按键还绑着。
    private static func focusApps() -> [String] {
        var seen = Set<String>()
        return (ConfigStore.shared.config.targetApps + Array(legacyFocusID.keys))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func focusActions() -> [ActionDef] {
        focusApps().map { b in
            ActionDef(focusID(for: b), L("切到 %@", AppName.of(b)), group: L("切换 app")) {
                ctx.focus(b)
            }
        }
    }

    // 每次读都重建的话, 按键路径和视图刷新都会付代价。按白名单签名缓存。
    private static var cacheKey = ""
    private static var cacheAll: [ActionDef] = []
    private static var cacheByID: [String: ActionDef] = [:]

    private static func rebuildIfNeeded() {
        let key = focusApps().joined(separator: "|")
        guard key != cacheKey || cacheAll.isEmpty else { return }
        cacheKey = key
        cacheAll = base + focusActions()
        cacheByID = Dictionary(cacheAll.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static var all: [ActionDef] { rebuildIfNeeded(); return cacheAll }
    static var byID: [String: ActionDef] { rebuildIfNeeded(); return cacheByID }

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
    /// onlyIn 是 app 档案系统之前的产物 —— 它把 diffPane / interrupt 这些锁死在
    /// 一个 app 上。可现在「这个 app 支不支持某动作」的判据应该是档案里配没配键:
    /// 给 Codex 配了 diffPane, 它就该能用。所以两者取并集(只增不减)。
    static func available(in app: String) -> [ActionDef] {
        all.filter {
            $0.onlyIn == nil || $0.onlyIn == app
                || AppProfiles.key($0.id, app: app) != nil
        }
    }

    // MARK: - 语音 (按下/松开语义, 不走普通动作)

    private static var pttWatchdog: Timer?

    static func pttStart() {
        // 保险丝用的是 Timer, 它挂在【当前线程】的 run loop 上。手机接口是在
        // Network.framework 的后台队列里直接调过来的, 那个线程没有 run loop,
        // Timer 于是永远不触发 —— 手机中途掉线就会让修饰键永久卡住。
        // 在源头收敛线程, 这样任何调用方都安全。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { pttStart() }; return
        }
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
        guard Thread.isMainThread else {
            DispatchQueue.main.async { pttStop() }; return
        }
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
