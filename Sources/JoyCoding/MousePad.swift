import AppKit
import CoreGraphics
import Foundation

/// 右摇杆当鼠标。
///
/// 不自己开定时器 —— 任天堂的完整报告 0x30 本来就是 ~60Hz 持续推送的,
/// 跟着报告走即可。附带的好处是自带停止条件: 手柄断连/休眠报告就没了,
/// 光标自然停下, 不会出现 PTT 卡键那种"事件丢了就永远停不下来"的情况。
enum MousePad {

    /// 死区只用来挡噪声。摇杆的【中位偏移】不靠死区硬扛 —— 实测这颗 Pro 手柄
    /// 静止时读数就有 0.12, 拿死区去盖会让左右不对称(往偏移方向推更早触发),
    /// 而且死区一大, 低速段就没了。所以偏移单独学出来减掉。
    private static let deadZone = 0.08

    // MARK: - 每根摇杆各自的状态
    //
    // 中位偏移是物理量, 每根摇杆各不相同(实测这颗 Pro 的右摇杆是 0.12)。
    // 状态存一份的话, 换一根摇杆当鼠标时旧中位会残留, 光标先漂一下才自我修正;
    // 两根同时当鼠标更糟 —— 会持续互相覆盖, 谁也学不准。所以按通道分开存。
    private struct Cal {
        var samples: [(Double, Double)] = []
        var center = (x: 0.0, y: 0.0)
        var carry = (x: 0.0, y: 0.0)
    }
    private static var cal: [String: Cal] = [:]

    /// 连续一批读数挤在很小的范围里, 就认为摇杆是松开的, 把这个位置当中位。
    /// 只在靠近原点时才认, 免得开机时正握着摇杆被学歪。
    private static func updateCenter(_ c: inout Cal, _ v: (x: Double, y: Double)) {
        guard abs(v.x) < 0.35, abs(v.y) < 0.35 else { c.samples.removeAll(); return }
        c.samples.append((v.x, v.y))
        if c.samples.count > 30 { c.samples.removeFirst() }
        guard c.samples.count == 30 else { return }
        let xs = c.samples.map { $0.0 }, ys = c.samples.map { $0.1 }
        guard (xs.max()! - xs.min()!) < 0.03, (ys.max()! - ys.min()!) < 0.03 else { return }
        c.center = (xs.reduce(0,+) / 30, ys.reduce(0,+) / 30)
    }

    /// 满推时每帧移动多少点。60Hz 下约 1400 点/秒。
    private static let maxStep = 23.0

    /// scroll() / click() 会把光标挪走再挪回来。那期间不能插手, 否则两边抢。
    static var suspended = false

    // MARK: - 左键
    private static var leftHeld = false

    /// 按下不放。松开前的移动要发 leftMouseDragged 而不是 mouseMoved ——
    /// 很多控件(拖选、拖窗口)只认拖拽事件, 发 mouseMoved 它们当没按住。
    static func leftDown() {
        guard !leftHeld, let p = CGEvent(source: nil)?.location else { return }
        leftHeld = true
        post(.leftMouseDown, at: p)
    }

    static func leftUp() {
        guard leftHeld, let p = CGEvent(source: nil)?.location else { return }
        leftHeld = false
        post(.leftMouseUp, at: p)
    }

    /// 手柄断连时兜底 —— 否则左键会一直按着, 和之前 PTT 卡修饰键一个道理
    static func releaseAll() { leftUp() }

    private static func post(_ type: CGEventType, at p: CGPoint) {
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// 传入某根摇杆的模拟量(-1...1)。回中或没绑鼠标时传 nil。
    /// key 用来区分是哪根摇杆 —— 校准和亚像素余数各算各的。
    static func apply(_ key: String, _ raw: (x: Double, y: Double)?) {
        var c = cal[key] ?? Cal()
        defer { cal[key] = c }
        guard !suspended, let r = raw else { c.carry = (0, 0); return }
        updateCenter(&c, r)

        let v = (x: r.x - c.center.x, y: r.y - c.center.y)
        let mag = (v.x * v.x + v.y * v.y).squareRoot()
        guard mag > deadZone else { c.carry = (0, 0); return }

        // 死区外重新铺满 0...1, 否则刚过死区就会突然跳一下
        let scaled = min((mag - deadZone) / (1 - deadZone), 1)
        // 平方曲线: 轻推能精调, 推到底够快
        let speed = scaled * scaled * maxStep

        // 摇杆 y 轴向上为正, 屏幕坐标向下为正
        // 慢速推时每帧的位移不足 1 点, 取整会被抹掉, 所以把余数攒着
        let dx = v.x / mag * speed + c.carry.x
        let dy = -v.y / mag * speed + c.carry.y
        let stepX = dx.rounded(.towardZero), stepY = dy.rounded(.towardZero)
        c.carry = (dx - stepX, dy - stepY)
        guard stepX != 0 || stepY != 0 else { return }

        guard let cur = CGEvent(source: nil)?.location else { return }
        let target = clampToScreens(CGPoint(x: cur.x + stepX, y: cur.y + stepY))

        // 用事件而不是 CGWarpMouseCursorPosition:
        // Warp 不产生事件(靠鼠标增量的应用收不到), 而且之后短时间内会抑制移动。
        post(leftHeld ? .leftMouseDragged : .mouseMoved, at: target)
    }

    /// 别让光标跑到所有显示器之外。多屏时按"落在哪块屏里"判断,
    /// 都不落就夹回距离最近的那块。
    private static func clampToScreens(_ p: CGPoint) -> CGPoint {
        let frames = NSScreen.screens.map { flipped($0.frame) }
        guard !frames.isEmpty else { return p }
        if frames.contains(where: { $0.contains(p) }) { return p }

        var best = p
        var bestD = Double.greatestFiniteMagnitude
        for f in frames {
            let c = CGPoint(x: min(max(p.x, f.minX), f.maxX - 1),
                            y: min(max(p.y, f.minY), f.maxY - 1))
            let d = (c.x - p.x) * (c.x - p.x) + (c.y - p.y) * (c.y - p.y)
            if d < bestD { bestD = d; best = c }
        }
        return best
    }

    /// NSScreen 原点在左下, CGEvent 坐标原点在左上 —— 要翻过来
    private static func flipped(_ r: NSRect) -> CGRect {
        guard let main = NSScreen.screens.first else { return r }
        return CGRect(x: r.minX, y: main.frame.maxY - r.maxY,
                      width: r.width, height: r.height)
    }
}
