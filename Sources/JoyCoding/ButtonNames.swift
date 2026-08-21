import Foundation

/// 按键编号 -> 物理键名。编号是 HID 位序, 各家排法不同, 所以按厂商查表。
/// 拿不准就在映射界面里按一下 —— 界面会直接显示编号。
enum ButtonNames {
    static let nintendo: [Int: String] = [
        1: "A", 2: "X", 3: "B", 4: "Y", 5: "SL", 6: "SR",
        9: "减号 −", 10: "加号 +", 11: "左摇杆按下", 12: "摇杆按下",
        13: "Home", 14: "截图键", 15: "R", 16: "ZR",
    ]
    /// PlayStation 标准位序。未实测, 以界面里按出来的编号为准。
    static let sony: [Int: String] = [
        1: "□", 2: "✕", 3: "○", 4: "△", 5: "L1", 6: "R1", 7: "L2", 8: "R2",
        9: "Create", 10: "Options", 11: "L3", 12: "R3", 13: "PS", 14: "触摸板",
    ]

    static func name(vendor: Int, button: Int) -> String {
        let table: [Int: String] = vendor == 0x057E ? nintendo
                                 : vendor == 0x054C ? sony : [:]
        return table[button].map { "\($0)  (\(button))" } ?? "按键 \(button)"
    }
}
