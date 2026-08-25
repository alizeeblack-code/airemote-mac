import Foundation

/// 内置默认配置。
///
/// 配置本身存在 ~/.config/joycoding/config.json (每台机器各一份), 但【默认值
/// 随 app 一起发布】—— 新设备第一次接上时自动套用, 不用从零绑一遍。
/// 这对把 app 交给别人用很重要: 开箱就能用, 只需要授权辅助功能。
enum DefaultProfiles {

    static func make(vendor: Int, product: Int, name: String) -> DeviceProfile? {
        switch (vendor, product) {
        case (0x057E, 0x2009): return proController(name)
        case (0x054C, _):      return playstation(name)
        case (0x057E, 0x2007): return joyconRight(name)
        default:               return nil
        }
    }

    private static func b(_ pairs: [Int: String]) -> [String: ButtonBinding] {
        Dictionary(uniqueKeysWithValues: pairs.map { (String($0.key), ButtonBinding(tap: $0.value)) })
    }

    /// 十字键的帽子开关值是 HID 标准 (0=上 2=右 4=下 6=左), 不用学。
    /// Joy-Con 的摇杆才需要现场学 —— 横持竖持会整体旋转。
    private static let dpad: [String: StickDir] = [
        "up":    .init(hat: 0, action: "scrollUp"),
        "right": .init(hat: 2, action: "sessionNext"),
        "down":  .init(hat: 4, action: "scrollDown"),
        "left":  .init(hat: 6, action: "sessionPrev"),
    ]
    /// 右摇杆默认当方向键用: 选菜单、挪光标
    private static let rightStick: [String: StickDir] = [
        "up":    .init(hat: 0, action: "up"),
        "right": .init(hat: 2, action: "right"),
        "down":  .init(hat: 4, action: "down"),
        "left":  .init(hat: 6, action: "left"),
    ]

    // MARK: - Switch Pro

    private static func proController(_ name: String) -> DeviceProfile {
        var p = DeviceProfile(vendorID: 0x057E, productID: 0x2009, name: name)
        p.buttons = b([
            1: "confirm",       // A
            2: "clearLine",     // X
            3: "cancel",        // B
            4: "delete",        // Y
            5: "confirm",       // L   单手时左手也能发送
            6: Actions.focusID(for: BundleID.cursor),  // R
            7: "ptt",           // ZL  按住说话
            8: "switchApp",     // ZR
            9: "focusInput",    // −
            10: "modelMenu",    // +
            11: "cancel",       // 左摇杆按下
            12: "sideChat",     // 右摇杆按下
            14: "newSession",    // 截图键
            // 13 = Home 故意留空: macOS 原生接管 Pro 手柄, 这个键被系统
            // 截去开游戏覆盖层, 绑什么都不会生效
        ])
        p.sticks = ["hat": dpad, "right": rightStick]
        p.stickModes = ["right": "mouse"]   // 右摇杆默认推鼠标
        p.overrides = [BundleID.chrome: AppOverride(
            buttons: b([2: "reload", 4: "navBack"]))]
        return p
    }

    // MARK: - PlayStation

    private static func playstation(_ name: String) -> DeviceProfile {
        var p = DeviceProfile(vendorID: 0x054C, productID: 0, name: name)
        p.buttons = b([
            // 面键按【西方惯例】: ✕ 确认、○ 取消。位置上 ✕ 在下、○ 在右,
            // 和任天堂的 A/B 正好相反, 照搬位置反而不合 PS 用户的手感。
            2: "confirm",       // ✕
            3: "cancel",        // ○
            4: "clearLine",     // △
            1: "delete",        // □
            5: "confirm",       // L1
            6: Actions.focusID(for: BundleID.cursor),  // R1
            7: "ptt",           // L2
            8: "switchApp",     // R2
            9: "focusInput",    // Create / Share
            10: "modelMenu",    // Options
            11: "cancel",       // L3
            12: "sideChat",     // R3
            14: "newSession",    // 触摸板按下
            // 13 = PS 键留空, 多半和 Pro 的 Home 一样被系统截走
        ])
        p.sticks = ["hat": dpad, "right": rightStick]
        p.stickModes = ["right": "mouse"]   // 右摇杆默认推鼠标
        p.overrides = [BundleID.chrome: AppOverride(
            buttons: b([4: "reload", 1: "navBack"]))]
        return p
    }

    // MARK: - Joy-Con (R)

    private static func joyconRight(_ name: String) -> DeviceProfile {
        var p = DeviceProfile(vendorID: 0x057E, productID: 0x2007, name: name)
        p.buttons = b([
            1: "confirm", 2: "clearLine", 3: "cancel", 4: "delete",
            5: "focusClaude", 6: Actions.focusID(for: BundleID.cursor),
            10: "focusInput", 12: "modelMenu", 13: "newSession",
            15: "ptt", 16: "switchApp",
        ])
        // Chrome 里 X/Y/加号 本来的动作都是死键, 让给浏览器操作
        p.overrides = [BundleID.chrome: AppOverride(
            buttons: b([2: "reload", 4: "navBack", 10: "closeTab"]))]
        // 摇杆方向【不给默认值】: Joy-Con 横持和竖持会让帽子开关整体转 90°,
        // 猜错了比不给更糟。首次使用要跑一次"学习方向"。
        return p
    }
}
