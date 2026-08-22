import Foundation
var bad = 0
func check(_ name: String, _ ok: Bool) {
    if !ok { bad += 1 }
    print("  \(ok ? "✅" : "❌")  \(name)")
}

// ---- CRC32 (种子 0xA2) 是否符合索尼规范 ----
let req = DualSenseRaw.fullReportRequest()
check("请求报告长度 78", req.count == 78)
check("report id = 0x31", req[0] == 0x31)
check("BT tag = 0x10", req[2] == 0x10)
// 独立实现一遍 CRC 做交叉验证
var c: UInt32 = 0xFFFF_FFFF
for b in [UInt8(0xA2)] + Array(req[0..<74]) {
    c ^= UInt32(b)
    for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
}
c = ~c
let stored = UInt32(req[74]) | UInt32(req[75]) << 8 | UInt32(req[76]) << 16 | UInt32(req[77]) << 24
check("CRC32 与独立实现一致 (\(String(format: "%08X", c)))", c == stored)

// ---- 构造一份蓝牙完整报告 ----
func frame(lx: UInt8, ly: UInt8, rx: UInt8, ry: UInt8,
           b0: UInt8, b1: UInt8, b2: UInt8, status: UInt8) -> [UInt8] {
    var d = [UInt8](repeating: 0, count: 78)
    d[0] = 0x31; d[1] = 0
    let base = 2
    d[base] = lx; d[base+1] = ly; d[base+2] = rx; d[base+3] = ry
    d[base+7] = b0; d[base+8] = b1; d[base+9] = b2
    d[base+52] = status
    return d
}
func parse(_ d: [UInt8]) -> DualSenseRaw.Frame? {
    d.withUnsafeBufferPointer { DualSenseRaw.parse(id: 0x31, bytes: $0.baseAddress!, length: d.count) }
}

// 全部回中, 面键 ✕(0x20), 电量 6 档未充电
if let f = parse(frame(lx:128, ly:128, rx:128, ry:128, b0:0x20|0x08, b1:0, b2:0, status:0x06)) {
    check("✕ 被识别为 2 号键", f.buttons == [2])
    check("十字键回中 (低四位=8)", f.hat == nil)
    check("摇杆回中 |x|<0.02", abs(f.left.x) < 0.02 && abs(f.right.y) < 0.02)
    check("电量 6 档 -> 65%", f.percent == 65)
    check("未充电", f.charging == false)
} else { check("基础帧能解析", false) }

// 四个面键同时按下 + 十字键正上 + 右摇杆推到底
if let f = parse(frame(lx:128, ly:128, rx:255, ry:0, b0:0xF0|0x00, b1:0, b2:0, status:0x25)) {
    check("□✕○△ 四键 = {1,2,3,4}", f.buttons == [1,2,3,4])
    check("十字键 0 = 正上", f.hat == 0)
    check("右摇杆 x≈+1", f.right.x > 0.99)
    check("右摇杆 y≈-1 (向上)", f.right.y < -0.99)
    check("充电中 -> 100%", f.percent == 100 && f.charging == false)
}
// 充电状态 0x1
if let f = parse(frame(lx:128,ly:128,rx:128,ry:128,b0:0x08,b1:0,b2:0,status:0x18)) {
    check("charge=1 标记为充电中", f.charging == true)
    check("charge=1 电量 8 档 -> 85%", f.percent == 85)
}
// 异常状态不显示错值
if let f = parse(frame(lx:128,ly:128,rx:128,ry:128,b0:0x08,b1:0,b2:0,status:0xF3)) {
    check("未知充电状态 -> 不给电量", f.percent == nil)
}
// 肩键 / L3R3
if let f = parse(frame(lx:128,ly:128,rx:128,ry:128,b0:0x08,b1:0x0F,b2:0,status:0x06)) {
    check("L1 R1 L2 R2 = {5,6,7,8}", f.buttons == [5,6,7,8])
}
// 精简报告要被拒绝
let tiny = [UInt8](repeating: 0, count: 10)
check("10 字节精简报告返回 nil",
      tiny.withUnsafeBufferPointer { DualSenseRaw.parse(id: 0x01, bytes: $0.baseAddress!, length: 10) } == nil)

// 方向离散: 右摇杆推正上应得 0
check("dir(正上) = 0", DualSenseRaw.dir((x: 0, y: -1)) == 0)
check("dir(正右) = 2", DualSenseRaw.dir((x: 1, y: 0)) == 2)
check("dir(正下) = 4", DualSenseRaw.dir((x: 0, y: 1)) == 4)
check("dir(正左) = 6", DualSenseRaw.dir((x: -1, y: 0)) == 6)
check("dir(回中) = nil", DualSenseRaw.dir((x: 0.1, y: 0.1)) == nil)

// 只认 DualSense, 不认 DS4
check("认 DualSense 0x0CE6", DualSenseRaw.isSupported(vendor: 0x054C, product: 0x0CE6))
check("认 Edge 0x0DF2", DualSenseRaw.isSupported(vendor: 0x054C, product: 0x0DF2))
check("不认 DualShock4 0x09CC", !DualSenseRaw.isSupported(vendor: 0x054C, product: 0x09CC))

print(bad == 0 ? "\n  全部 \(bad == 0 ? "通过" : "")" : "\n  \(bad) 条失败")
exit(bad == 0 ? 0 : 1)
