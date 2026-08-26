import Foundation

/// DualSense 的原始输入报告。
///
/// 蓝牙连接时 macOS 默认让手柄停在 10 字节精简模式 —— 那里面【没有电量】。
/// 发一个合法的 0x31 输出报告(不改灯光也不震动)之后, 手柄会切到 78 字节的
/// 完整报告, 电量、两根摇杆的模拟量都在里面。
///
/// 代价是: 切过去之后 macOS 就不再给 IOHIDManager 派发标准 HID 元素了,
/// 所以按键、十字键、摇杆全都得从这里解析 —— 和任天堂手柄的处境一样。
/// 只启用完整报告而不接管解析的话, 手柄会彻底没有输入。
enum DualSenseRaw {

    static let vendor = 0x054C

    /// 只认 DualSense / DualSense Edge。DualShock 4 也是索尼但报告格式不同,
    /// 拿这套偏移去解会得到一堆乱码。
    static func isSupported(vendor v: Int, product p: Int) -> Bool {
        v == vendor && (p == 0x0CE6 || p == 0x0DF2)
    }

    // MARK: - 让手柄切到完整报告

    /// 蓝牙输出报告必须带以 0xA2 为种子的 CRC32, 否则手柄直接丢弃。
    static func fullReportRequest() -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 78)
        d[0] = 0x31        // report id
        d[1] = 0x00        // sequence tag
        d[2] = 0x10        // 索尼要求的 BT tag

        var crc: UInt32 = 0xFFFF_FFFF
        func feed(_ b: UInt8) {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        feed(0xA2)                      // PS_OUTPUT_CRC32_SEED
        for b in d[0..<74] { feed(b) }
        crc = ~crc
        for i in 0..<4 { d[74 + i] = UInt8((crc >> UInt32(i * 8)) & 0xFF) }
        return d
    }

    // MARK: - 解析

    struct Frame {
        var buttons: Set<Int>
        var hat: Int?                       // 0...7, 回中为 nil
        var left: (x: Double, y: Double)
        var right: (x: Double, y: Double)
        var percent: Int?
        var charging: Bool
        var statusRaw: Int
    }

    /// 缓冲区【含】report id, 所以 byte 0 就是 0x31 / 0x01。
    /// 通用数据在蓝牙报告的 byte 2 开始, USB 的 byte 1 开始。
    static func parse(id: Int, bytes: UnsafePointer<UInt8>, length: Int) -> Frame? {
        let base: Int
        switch id {
        case 0x31 where length >= 55: base = 2      // 蓝牙完整报告
        case 0x01 where length >= 54: base = 1      // USB
        default: return nil                          // 10 字节精简报告等, 没东西可取
        }
        let b = UnsafeBufferPointer(start: bytes, count: length)

        // 面键和十字键挤在同一个字节: 低四位是十字键(8 表示回中), 高四位是面键
        let b0 = Int(b[base + 7]), b1 = Int(b[base + 8]), b2 = Int(b[base + 9])
        var buttons: Set<Int> = []
        let map: [(Int, Int, Int)] = [        // (按键编号, 字节, 位掩码)
            (1, b0, 0x10), (2, b0, 0x20), (3, b0, 0x40), (4, b0, 0x80),   // □ ✕ ○ △
            (5, b1, 0x01), (6, b1, 0x02), (7, b1, 0x04), (8, b1, 0x08),   // L1 R1 L2 R2
            (9, b1, 0x10), (10, b1, 0x20), (11, b1, 0x40), (12, b1, 0x80),// Create Options L3 R3
            (13, b2, 0x01), (14, b2, 0x02), (15, b2, 0x04),               // PS 触摸板 静音
        ]
        for (n, byte, mask) in map where byte & mask != 0 { buttons.insert(n) }

        let hatVal = b0 & 0x0F
        // 8 位轴, 中位 127.5
        func axis(_ v: UInt8) -> Double { max(-1, min(1, (Double(v) - 127.5) / 127.5)) }

        // status[0] 在通用数据偏移 52。低四位是 10% 档位, 高四位是充电状态。
        let status = Int(b[base + 52])
        let level = status & 0x0F
        let charge = (status >> 4) & 0x0F
        var percent: Int?
        switch charge {
        case 0x0, 0x1: percent = min(level * 10 + 5, 100)
        case 0x2:      percent = 100
        default:       percent = nil        // 温度异常/未知, 宁可不显示也别显示错的
        }

        return Frame(buttons: buttons,
                     hat: hatVal <= 7 ? hatVal : nil,
                     left:  (axis(b[base]),     axis(b[base + 1])),
                     right: (axis(b[base + 2]), axis(b[base + 3])),
                     percent: percent, charging: charge == 0x1, statusRaw: status)
    }

    /// 模拟量 -> 八方向。和任天堂那边一个取舍: 死区取满量程 40%,
    /// 只用来给"按方向绑动作"那条路, 鼠标模式走的是原始模拟量。
    static func dir(_ v: (x: Double, y: Double)) -> Int? {
        guard v.x * v.x + v.y * v.y > 0.16 else { return nil }
        // 摇杆 y 轴向下为正, 帽子开关 0 是正上
        var a = atan2(v.x, -v.y) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45) % 8
    }
}
