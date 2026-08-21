import Foundation

/// 任天堂完整输入报告 0x30 的按键解析。
///
/// 为什么需要它: Pro 手柄连上 macOS 后会被系统的手柄框架切进完整报告模式,
/// 输入走【厂商自定义用途页 0xFF01】而不是标准 HID 按键页 —— 我们基于
/// HID 元素的解析在它身上完全落空(实测 page=0xff01 usage=0x30)。
/// 单只 Joy-Con 没有这个问题, 系统不接管它, 它一直在简易模式 0x3F。
///
/// 位序来自 Linux 内核 hid-nintendo.c 的 JC_BUTTON_* 宏。
enum NintendoRaw {

    /// 报告字节位 -> 我们的按键编号。编号和 DeviceArt 里 Pro 手柄那张表一致。
    /// (字节下标, 位, 我们的编号)
    private static let map: [(Int, UInt8, Int)] = [
        (3, 3, 1),   // A
        (3, 1, 2),   // X
        (3, 2, 3),   // B
        (3, 0, 4),   // Y
        (5, 6, 5),   // L
        (3, 6, 6),   // R
        (5, 7, 7),   // ZL
        (3, 7, 8),   // ZR
        (4, 0, 9),   // −
        (4, 1, 10),  // +
        (4, 3, 11),  // 左摇杆按下
        (4, 2, 12),  // 右摇杆按下
        (4, 4, 13),  // Home
        (4, 5, 14),  // 截图
    ]

    /// 解出按下的按键编号集合
    static func buttons(_ b: UnsafeBufferPointer<UInt8>) -> Set<Int> {
        var out: Set<Int> = []
        for (byte, bit, id) in map where b[byte] & (1 << bit) != 0 { out.insert(id) }
        return out
    }

    /// 12 位打包, 中位约 0x800。归一化到 -1...1。
    /// 八方向那条路会把幅度扔掉, 但鼠标要靠幅度决定速度, 所以单独留一个出口。
    private static func stickVec(_ x: Int, _ y: Int) -> (Double, Double) {
        (Double(x - 0x800) / Double(0x800), Double(y - 0x800) / Double(0x800))
    }

    /// 右摇杆的模拟量。给鼠标用 —— 它需要"推了多远", 不是"推向哪个方向"。
    static func rightStickVec(_ b: UnsafeBufferPointer<UInt8>) -> (Double, Double)? {
        guard b.count >= 12 else { return nil }
        return stickVec(Int(b[9]) | ((Int(b[10]) & 0x0F) << 8),
                        (Int(b[10]) >> 4) | (Int(b[11]) << 4))
    }

    /// 模拟摇杆 -> 八方向。
    /// 死区取满量程的 40%, 太小会漂、太大要推到底才认。
    /// 注意这个 40% 是【离散成八方向】用的, 和鼠标的死区不是一回事。
    private static func stickDir(_ x: Int, _ y: Int) -> Int? {
        let (dx, dy) = stickVec(x, y)
        guard dx * dx + dy * dy > 0.16 else { return nil }        // 0.4²
        // 摇杆 y 轴向上为正, 帽子开关 0 是正上
        var a = atan2(dx, dy) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45) % 8
    }

    static func leftStick(_ b: UnsafeBufferPointer<UInt8>) -> Int? {
        guard b.count >= 12 else { return nil }
        return stickDir(Int(b[6]) | ((Int(b[7]) & 0x0F) << 8),
                        (Int(b[7]) >> 4) | (Int(b[8]) << 4))
    }

    static func rightStick(_ b: UnsafeBufferPointer<UInt8>) -> Int? {
        guard b.count >= 12 else { return nil }
        return stickDir(Int(b[9]) | ((Int(b[10]) & 0x0F) << 8),
                        (Int(b[10]) >> 4) | (Int(b[11]) << 4))
    }

    /// 十字键 -> 帽子开关值(0…7), 回中返回 nil。
    /// byte 5 的低四位: bit0=下 bit1=上 bit2=右 bit3=左
    static func hat(_ b: UnsafeBufferPointer<UInt8>) -> Int? {
        let d = b[5]
        let down  = d & 0x01 != 0, up   = d & 0x02 != 0
        let right = d & 0x04 != 0, left = d & 0x08 != 0
        switch (up, right, down, left) {
        case (true,  false, false, false): return 0
        case (true,  true,  false, false): return 1
        case (false, true,  false, false): return 2
        case (false, true,  true,  false): return 3
        case (false, false, true,  false): return 4
        case (false, false, true,  true):  return 5
        case (false, false, false, true):  return 6
        case (true,  false, false, true):  return 7
        default: return nil
        }
    }
}
