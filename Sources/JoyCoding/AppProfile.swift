import Foundation

/// 一个键位规格: 修饰键 + 主键, 或者一段文本。
///
/// 存成字符串是为了配置文件好读好改, 也方便社区直接贴分享:
///   "cmd+shift+o"   组合键
///   "text:继续"      发送文本
struct KeySpec: Codable, Equatable {
    var raw: String

    init(_ raw: String) { self.raw = raw }
    init(from d: Decoder) throws { raw = try d.singleValueContainer().decode(String.self) }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer(); try c.encode(raw)
    }

    var isText: Bool { raw.hasPrefix("text:") }
    var text: String { String(raw.dropFirst(5)) }

    /// 拆成 (修饰键, 主键)。"cmd+shift+o" -> (["cmd","shift"], "o")
    var parsed: ([String], String)? {
        guard !isText, !raw.isEmpty else { return nil }
        var parts = raw.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.popLast() else { return nil }
        return (parts, key)
    }

    /// 给界面看的写法: ⌘⇧O
    var display: String {
        if isText { return "「\(text)」" }
        guard let (mods, key) = parsed else { return L("未设置") }
        let sym = ["cmd": "⌘", "shift": "⇧", "alt": "⌥", "ctrl": "⌃",
                   "rightctrl": "⌃", "rightalt": "⌥", "fn": "fn"]
        let named = ["return": "↩", "escape": "⎋", "tab": "⇥", "delete": "⌫",
                     "space": "␣", "up": "↑", "down": "↓", "left": "←", "right": "→",
                     "`": "`"]
        return mods.compactMap { sym[$0] }.joined()
             + (named[key] ?? key.uppercased())
    }
}

/// 某个 app 下, 各语义动作分别发什么键。
///
/// 这一层的存在是为了让「按键映射」保持纯语义 —— 用户配手柄时想的是
/// 「确认 / 发送」, 不需要知道那个 app 用什么快捷键。知道快捷键的人
/// 可以在这里改, 不知道的人靠内置预置。
typealias AppKeyMap = [String: KeySpec]     // actionID -> 键位

enum AppProfiles {
    /// 用户配置优先, 回落内置预置
    static func key(_ action: String, app: String) -> KeySpec? {
        if let k = ConfigStore.shared.config.appProfiles[app]?[action] { return k }
        return builtin[app]?[action]
    }

    static func hasAny(_ app: String) -> Bool {
        builtin[app] != nil || ConfigStore.shared.config.appProfiles[app] != nil
    }

    /// 内置预置。随 app 发布, 用户不用查快捷键。
    /// 来源: 各 app 的菜单栏(用无障碍接口读出来的) + 官方文档。
    private static let openAI: [String: KeySpec] = [
        "sessionPrev":  .init("cmd+shift+["),   // 菜单 Previous Chat
        "sessionNext":  .init("cmd+shift+]"),   // 菜单 Next Chat
        "newSession":   .init("cmd+n"),         // 菜单 New Chat
        "clearLine":    .init("cmd+a"),         // 菜单 Select All; Actions 会自动补退格
        "sideChat":     .init("cmd+b"),         // 菜单 Toggle Sidebar
        "terminalPane": .init("ctrl+`"),        // 菜单 Open Terminal
        "diffPane":     .init("cmd+alt+b"),     // 菜单 Toggle Review Panel
        "navBack":      .init("cmd+["),         // 菜单 Back
        "navForward":   .init("cmd+]"),         // 菜单 Forward
        // 下面两个不在菜单里, 这个 app 又不向辅助功能接口暴露内部元素, 没法实测。
        // 按错了也只是没反应, 不会有副作用。
        "interrupt":    .init("escape"),
        "focusInput":   .init("shift+escape"),
        "deleteWord":   .init("alt+delete"),
        // modelMenu 故意不配: text: 规格会在打完字后自动回车, 在 ChatGPT 里
        // 等于把 "/" 当成消息发出去。得先确认斜杠菜单的行为再说。
    ]

    static let builtin: [String: AppKeyMap] = [
        BundleID.claude: [
            "deleteWord":  .init("alt+delete"),
            "sessionPrev": .init("ctrl+shift+tab"),
            "sessionNext": .init("ctrl+tab"),
            "newSession":  .init("cmd+n"),
            "modelMenu":   .init("cmd+shift+i"),
            "effortMenu":  .init("cmd+shift+e"),
            "mode":        .init("cmd+shift+m"),
            "diffPane":    .init("cmd+shift+d"),
            "terminalPane":.init("ctrl+`"),
            "browserPane": .init("cmd+shift+b"),
            "sideChat":    .init("cmd+;"),
            "closePane":   .init("cmd+\\"),
            "viewMode":    .init("ctrl+o"),
            "clearLine":   .init("cmd+a"),      // 之后再补一次退格
        ],
        BundleID.ghostty: [
            "deleteWord":  .init("ctrl+w"),        // 终端走 readline, 不是 ⌥⌫
            "sessionPrev": .init("cmd+shift+`"),   // Ghostty 走窗口而不是标签
            "sessionNext": .init("cmd+`"),
            "mode":        .init("shift+tab"),     // Codex: 循环 Plan/Pair/Execute
            "modelMenu":   .init("text:/model"),
            "clearLine":   .init("ctrl+u"),
            "interrupt":   .init("ctrl+c"),
        ],
        BundleID.wechat: [
            "deleteWord":       .init("alt+delete"),
            "sessionPrev":      .init("alt+up"),     // 菜单 Show → Previous Chat
            "sessionNext":      .init("alt+down"),
            "wechatNextUnread": .init("cmd+alt+down"),
            "newSession":       .init("cmd+n"),
        ],
        // ⚠️ **未实测**。这个仓库里其它档案的键都是从 app 菜单栏读出来的,
        // 这份不是 —— 写它的时候本机没装 Slack, 下面是官方文档里的常用键。
        // 装上 Slack 之后请对着菜单栏核一遍再把这条注释删掉。
        BundleID.slack: [
            "deleteWord":       .init("alt+delete"),
            "sessionPrev":      .init("alt+up"),        // 上一个频道
            "sessionNext":      .init("alt+down"),      // 下一个频道
            "wechatNextUnread": .init("alt+shift+down"),// 下一个未读(ID 见 Actions)
            "newSession":       .init("cmd+n"),         // 新消息
            "closeTab":         .init("cmd+w"),
            "windowNext":       .init("cmd+`"),
            // focusInput 故意不配: Slack 没有公开的"聚焦输入框"快捷键,
            // 猜一个错的比不配更糟(按下去会触发别的功能)。
        ],
        BundleID.chrome: [
            "deleteWord":  .init("alt+delete"),
            "sessionPrev": .init("ctrl+shift+tab"),
            "sessionNext": .init("ctrl+tab"),
            "navBack":     .init("cmd+["),
            "navForward":  .init("cmd+]"),
            "reload":      .init("cmd+r"),
            "newTab":      .init("cmd+t"),
            "closeTab":    .init("cmd+w"),
            "windowNext":  .init("cmd+`"),
        ],
        // 以下为预置, 方便不用 Claude Code 的用户开箱即用
        // ChatGPT 和 Codex 现在是同一个 app: /Applications/ChatGPT.app 的
        // bundle id 就是 com.openai.codex(签名 OpenAI OpCo, 包里带 codex 二进制
        // 和 CodexDockTilePlugin)。旧的 com.openai.chat 在系统里已经解析不到,
        // 所以之前那份档案永远不会命中, 也永远不会出现在推荐里。
        //
        // 下面标「菜单」的都是从 app 自己的菜单栏读出来的实测值。
        BundleID.chatgpt: openAI,
        "com.openai.chat":  openAI,          // 留给旧版本
        BundleID.cursor: [                          // Cursor
            "deleteWord":  .init("alt+delete"),
            "sessionPrev": .init("cmd+shift+["),
            "sessionNext": .init("cmd+shift+]"),
            "newSession":  .init("cmd+n"),
            "terminalPane":.init("ctrl+`"),
        ],
        "com.microsoft.VSCode": [
            "deleteWord":  .init("alt+delete"),
            "sessionPrev": .init("cmd+shift+["),
            "sessionNext": .init("cmd+shift+]"),
            "newSession":  .init("cmd+n"),
            "terminalPane":.init("ctrl+`"),
            "closeTab":    .init("cmd+w"),
        ],
        "com.googlecode.iterm2": [
            "deleteWord":  .init("ctrl+w"),         // 终端
            "sessionPrev": .init("cmd+shift+["),
            "sessionNext": .init("cmd+shift+]"),
            "clearLine":   .init("ctrl+u"),
            "interrupt":   .init("ctrl+c"),
        ],
        "com.apple.Terminal": [
            "deleteWord":  .init("ctrl+w"),         // 终端
            "sessionPrev": .init("cmd+shift+["),
            "sessionNext": .init("cmd+shift+]"),
            "clearLine":   .init("ctrl+u"),
            "interrupt":   .init("ctrl+c"),
        ],
    ]

    /// 有内置预置、但还没加进白名单的 app（且本机装了的）。
    /// 「通用」页据此推荐 —— 否则用户不会知道 ChatGPT、Cursor 这些
    /// 已经有现成键位在等他。
    static func suggestions(installed: (String) -> Bool, whitelist: [String]) -> [String] {
        builtin.keys.filter { !whitelist.contains($0) && installed($0) }.sorted()
    }

    /// 哪些动作值得在档案里配。纯通用的(回车/退格/翻页)不需要 ——
    /// 它们在所有 app 里都一样。
    static let configurable = [
        "sessionPrev", "sessionNext", "newSession", "focusInput",
        "modelMenu", "effortMenu", "mode", "clearLine", "deleteWord", "interrupt",
        "diffPane", "terminalPane", "browserPane", "sideChat", "closePane",
        "viewMode", "navBack", "navForward", "reload", "newTab", "closeTab",
        "windowNext", "wechatNextUnread",
    ]
}
