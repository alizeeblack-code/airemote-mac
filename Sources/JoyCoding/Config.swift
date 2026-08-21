import Foundation

// MARK: - 按键手势

/// 一颗按键的三层绑定。空 = 不绑。
struct ButtonBinding: Codable, Equatable {
    init(tap: String? = nil, double: String? = nil, long: String? = nil) {
        self.tap = tap; self.double = double; self.long = long
    }
    var tap: String?
    var double: String?
    var long: String?

    var isEmpty: Bool { tap == nil && double == nil && long == nil }
}

/// 摇杆的一个方向。hat 是实测学到的帽子开关原始值 (0...7),
/// action 是绑的动作。分开存才能在界面上按"上下左右"展示 ——
/// 只存 动作→hat 的话, 界面就只能显示"方向 6"这种对人没意义的数字。
/// 方向通道。一只手柄可能有好几个方向来源, 各绑各的。
enum StickChannel: String, CaseIterable {
    /// hat = 主方向通道。Joy-Con 上是摇杆; Pro 手柄上十字键和左摇杆【合流】
    /// 到这里 —— 推哪个都一样, 省一套配置。右摇杆才单独成一个通道。
    case hat, right

    var label: String {
        switch self {
        case .hat:   return L("主方向")
        case .right: return L("右摇杆")
        }
    }
    /// 虚拟锚点 id, 用负数和真实按键编号错开
    var anchorID: Int { self == .hat ? -1 : -3 }
    static func from(anchorID: Int) -> StickChannel? {
        allCases.first { $0.anchorID == anchorID }
    }
}

struct StickDir: Codable, Equatable {
    var hat: Int
    var action: String?
}

/// 某个 app 下的覆盖层。只存和基础层【不一样】的那些键。
///
/// 覆盖以【整颗按键】为单位: 一旦覆盖, 这颗键在该 app 下的单击/双击/长按
/// 全部由这一层定义。做成按手势继承会引入"继承/无/具体动作"三态,
/// 对用户是额外的心智负担, 不值得。
struct AppOverride: Codable, Equatable {
    var buttons: [String: ButtonBinding] = [:]
    /// 旧格式, 仅用于迁移
    var stick: [String: String] = [:]
    /// 通道 -> 方向 -> 动作。hat 值是物理属性只学一次, 存基础层, 覆盖只改动作。
    var sticks: [String: [String: String]] = [:]

    var isEmpty: Bool { buttons.isEmpty && sticks.allSatisfy { $0.value.isEmpty } }

    init(buttons: [String: ButtonBinding] = [:], sticks: [String: [String: String]] = [:]) {
        self.buttons = buttons; self.sticks = sticks
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        buttons = try c.decodeIfPresent([String: ButtonBinding].self, forKey: .buttons) ?? [:]
        stick   = try c.decodeIfPresent([String: String].self, forKey: .stick) ?? [:]
        sticks  = try c.decodeIfPresent([String: [String: String]].self, forKey: .sticks) ?? [:]
        if sticks.isEmpty && !stick.isEmpty { sticks[StickChannel.hat.rawValue] = stick }
    }
}

/// 一个手柄的完整配置。按 厂商:产品 区分, 换手柄不会互相覆盖。
struct DeviceProfile: Codable, Identifiable, Equatable {
    var vendorID: Int
    var productID: Int
    var name: String
    /// "按键编号" -> 三层绑定
    var buttons: [String: ButtonBinding] = [:]
    /// 旧格式: 动作名 -> hat 值。仅用于迁移, 新代码一律读 stickDirs。
    var stick: [String: Int] = [:]
    /// 旧格式: 只有一组方向。仅用于迁移, 新代码一律读 sticks。
    var stickDirs: [String: StickDir] = [:]
    /// 通道 -> 方向 -> 绑定。Joy-Con 只有 "hat", Pro 手柄还有左右摇杆。
    var sticks: [String: [String: StickDir]] = [:]
    /// bundleID -> 该 app 的覆盖层。上面的 buttons/stickDirs 就是基础层。
    var overrides: [String: AppOverride] = [:]

    var id: String { DeviceProfile.key(vendorID, productID) }

    init(vendorID: Int, productID: Int, name: String,
         buttons: [String: ButtonBinding] = [:],
         stickDirs: [String: StickDir] = [:]) {
        self.vendorID = vendorID; self.productID = productID; self.name = name
        self.buttons = buttons; self.stickDirs = stickDirs
    }

    /// 某个 app 下这颗按键实际生效的绑定
    func binding(button: Int, app: String) -> ButtonBinding? {
        overrides[app]?.buttons[String(button)] ?? buttons[String(button)]
    }

    /// 某个 app 下这个方向实际生效的动作
    func stickAction(_ ch: StickChannel, dir: String, app: String) -> String? {
        overrides[app]?.sticks[ch.rawValue]?[dir] ?? sticks[ch.rawValue]?[dir]?.action
    }

    func stickDir(_ ch: StickChannel, _ dir: String) -> StickDir? {
        sticks[ch.rawValue]?[dir]
    }

    /// 这只手柄学过方向的通道
    var learnedChannels: [StickChannel] {
        StickChannel.allCases.filter { !(sticks[$0.rawValue]?.isEmpty ?? true) }
    }

    func isOverridden(button: Int, app: String) -> Bool {
        overrides[app]?.buttons[String(button)] != nil
    }

    func isOverridden(_ ch: StickChannel, dir: String, app: String) -> Bool {
        overrides[app]?.sticks[ch.rawValue]?[dir] != nil
    }

    static let dirKeys = ["up", "down", "left", "right"]
    static let dirLabel = ["up": L("上"), "down": L("下"), "left": L("左"), "right": L("右")]

    // 手写解码, 缺字段就用默认值。合成的 Codable 遇到缺 key 会直接抛错,
    // 结果是"加个新字段就把用户配置清空"——这个坑踩过一次。
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        vendorID  = try c.decodeIfPresent(Int.self, forKey: .vendorID) ?? 0
        productID = try c.decodeIfPresent(Int.self, forKey: .productID) ?? 0
        name      = try c.decodeIfPresent(String.self, forKey: .name) ?? L("手柄")
        buttons   = try c.decodeIfPresent([String: ButtonBinding].self, forKey: .buttons) ?? [:]
        stick     = try c.decodeIfPresent([String: Int].self, forKey: .stick) ?? [:]
        stickDirs = try c.decodeIfPresent([String: StickDir].self, forKey: .stickDirs) ?? [:]
        sticks    = try c.decodeIfPresent([String: [String: StickDir]].self, forKey: .sticks) ?? [:]
        // 旧配置只有一组方向, 归到 hat 通道
        if sticks.isEmpty && !stickDirs.isEmpty { sticks[StickChannel.hat.rawValue] = stickDirs }
        overrides = try c.decodeIfPresent([String: AppOverride].self, forKey: .overrides) ?? [:]

        // 从旧格式迁移。老的向导按 上/下/左/右 顺序绑的就是这四个动作。
        if stickDirs.isEmpty && !stick.isEmpty {
            let legacy = ["scrollUp": "up", "scrollDown": "down",
                          "sessionPrev": "left", "sessionNext": "right"]
            for (action, hat) in stick {
                guard let dir = legacy[action] else { continue }
                stickDirs[dir] = StickDir(hat: hat, action: action)
            }
        }
    }

    static func key(_ v: Int, _ p: Int) -> String {
        String(format: "%04X:%04X", v, p)
    }
}

// MARK: - 全局配置

struct Config: Codable {
    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ dflt: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)) .flatMap { $0 } ?? dflt
        }
        httpEnabled       = v(.httpEnabled, true)
        httpPort          = v(.httpPort, 27123)
        remoteAddress     = v(.remoteAddress, "")
        httpToken         = v(.httpToken, "")
        httpInterface     = v(.httpInterface, "all")
        restrictToTargets = v(.restrictToTargets, true)
        targetApps        = v(.targetApps, [BundleID.ghostty, BundleID.claude,
                                            BundleID.wechat, BundleID.chrome])
        pttStyle          = v(.pttStyle, "hold")
        pttKey            = v(.pttKey, "ctrl")
        pttMods           = v(.pttMods, [String]())
        pttMaxHold        = v(.pttMaxHold, 60)
        showBatteryInMenuBar = v(.showBatteryInMenuBar, true)
        appearance        = v(.appearance, "system")
        language          = v(.language, "auto")
        pairCode          = v(.pairCode, "")
        remoteCorners     = v(.remoteCorners, [String]())
        appProfiles       = v(.appProfiles, [String: AppKeyMap]())
        devices           = v(.devices, [DeviceProfile]())
    }

    var httpEnabled = true
    var httpPort = 27123
    /// 手机遥控用哪个本机地址; 空表示自动挑。
    var remoteAddress = ""
    var httpToken = ""
    /// 监听网卡: "all" / "localhost" / 具体 IP
    var httpInterface = "all"

    /// 通用按键(回车/Esc/退格/翻页)只在这些 app 里生效, 防止在 Finder、
    /// 确认对话框里误触。语音和切 app 不受此限制。
    var restrictToTargets = true
    var targetApps: [String] = [
        BundleID.ghostty, BundleID.claude, BundleID.wechat, BundleID.chrome,
    ]

    /// "hold"   = 按住录, 松开出字 (Typeless / VoiceInk)
    /// "tap"    = 按一下开始, 再按一下停止 (macOS 自带听写)
    /// "toggle" = 按住说话, 但底层是 toggle 式听写
    var pttStyle = "hold"
    /// 可以直接填修饰键名("ctrl"/"alt"/"shift"/"cmd"), 会合成 flagsChanged 事件
    var pttKey = "ctrl"
    var pttMods: [String] = []
    /// 保险丝: 按住超过这么久强制松开, 防手柄掉线导致修饰键卡死
    var pttMaxHold: Double = 60

    /// 菜单栏图标右边是否显示电量百分比
    var showBatteryInMenuBar = true
    /// 界面外观: "system" 跟随系统 / "light" 浅色 / "dark" 深色
    var appearance = "system"
    /// 界面语言: "auto" 跟随系统 / "zh" 中文 / "en" English。
    /// auto 时只有【简体中文】用中文, 其余一律英文。
    var language = "auto"
    /// 手机配对码。6 位数字, 只在首次配对时输一次, 之后靠 Cookie 记住。
    /// 重新生成会让所有已配对的手机失效。
    var pairCode = ""
    /// 手机四角直达键绑哪几个 app (bundle ID, 最多 4 个)。
    /// 留空则自动取白名单前四个。
    var remoteCorners: [String] = []

    /// bundleID -> (动作 -> 键位)。用户在「app 档案」页改的东西, 覆盖内置预置。
    var appProfiles: [String: AppKeyMap] = [:]

    var devices: [DeviceProfile] = []

    mutating func profile(vendor: Int, product: Int, name: String) -> DeviceProfile {
        if let p = devices.first(where: { $0.vendorID == vendor && $0.productID == product }) {
            return p
        }
        let p = DeviceProfile(vendorID: vendor, productID: product, name: name)
        devices.append(p)
        return p
    }

    mutating func update(_ p: DeviceProfile) {
        if let i = devices.firstIndex(where: { $0.id == p.id }) { devices[i] = p }
        else { devices.append(p) }
    }
}

enum AppName {
    static func of(_ bid: String) -> String {
        switch bid {
        case BundleID.ghostty: return "Ghostty"
        case BundleID.claude:  return "Claude Code"
        case BundleID.wechat:  return L("微信")
        case BundleID.chrome:  return "Chrome"
        default: return bid.split(separator: ".").last.map(String.init) ?? bid
        }
    }
}

enum BundleID {
    static let ghostty = "com.mitchellh.ghostty"
    static let claude  = "com.anthropic.claudefordesktop"
    static let wechat  = "com.tencent.xinWeChat"
    static let chrome  = "com.google.Chrome"
}

// MARK: - 存取

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config {
        didSet { save() }
    }

    private let url: URL

    private init() {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/joycoding", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")

        if let d = try? Data(contentsOf: url),
           let c = try? JSONDecoder().decode(Config.self, from: d) {
            config = c
        } else {
            var c = Config()
            c.httpToken = ConfigStore.randomToken()
            config = c
        }
        if config.httpToken.isEmpty { config.httpToken = ConfigStore.randomToken() }
        if config.pairCode.isEmpty { config.pairCode = ConfigStore.randomPairCode() }
        // Swift 的属性观察器在 init 里赋值不触发, 首次生成的配置不会自动落盘。
        save()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(config) { try? d.write(to: url) }
    }

    var configPath: String { url.path }

    /// 6 位数字配对码。只用于首次配对, 真正的凭据是 Cookie 里的长 token。
    static func randomPairCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    static func randomToken() -> String {
        (0..<16).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }
}
