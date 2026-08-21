import SwiftUI

enum AnchorShape { case circle, capsuleH, capsuleV }

/// 摇杆四向的虚拟锚点 id。用负数, 和真实按键编号错开。
enum StickAnchor {
    static let id = StickChannel.hat.anchorID
    static let keys = ["up", "down", "left", "right"]
    static let arrow = ["up": "arrow.up", "down": "arrow.down",
                        "left": "arrow.left", "right": "arrow.right"]
}
enum Side { case left, right }

/// 手柄上一颗按键的位置。坐标是归一化的 (0...1), 相对手柄本体的外框,
/// 这样换手柄型号只要换一张表, 布局代码不用动。
struct ButtonAnchor: Identifiable {
    let id: Int
    let label: String
    let pos: CGPoint
    let size: CGSize
    let shape: AnchorShape
    let side: Side
}

/// 手柄外观 + 按键锚点。目前有 Joy-Con (R) 和 PlayStation 两套。
enum BodyStyle { case joycon, proController, playstation }

struct DeviceArt {
    let anchors: [ButtonAnchor]
    let aspect: CGFloat          // 宽/高
    let railSide: Side?          // SL/SR 那条滑轨在哪边, nil = 没有
    var style: BodyStyle = .joycon
    /// 帽子开关在这只手柄上叫什么。Joy-Con 上是摇杆, Pro 手柄上是十字键 ——
    /// 模拟摇杆走 X/Y/Rx/Ry 轴, 我们不读那个。
    var hatLabel: String = L("摇杆")


    /// 锚点在父坐标系里的绝对位置, 给连线用
    static func point(_ a: ButtonAnchor, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + a.pos.x * rect.width,
                y: rect.minY + a.pos.y * rect.height)
    }

    /// 左右 Joy-Con 是两个不同的设备, 产品 ID 也不同, 各画各的。
    static func art(vendor: Int, product: Int) -> DeviceArt {
        switch (vendor, product) {
        case (0x057E, 0x2006): return joyconLeft
        case (0x057E, 0x2007): return joyconRight
        case (0x057E, 0x2009): return proController
        // DualSense / DualSense Edge 有静音键, DualShock 4 没有
        case (0x054C, 0x0CE6), (0x054C, 0x0DF2): return playstation(mute: true)
        case (0x054C, _):                        return playstation(mute: false)
        default:               return DeviceArt(anchors: [], aspect: 1, railSide: nil)
        }
    }

    // Joy-Con (R) 竖持。真机布局: ABXY 在上、摇杆在下、Home 最下
    // (摇杆在上那是左 Joy-Con)。加号在顶部靠外侧那一边。
    static let joyconRight = DeviceArt(
        anchors: [
            .init(id: 16, label: "ZR", pos: .init(x: 0.50, y: 0.012),
                  size: .init(width: 0.62, height: 0.022), shape: .capsuleH, side: .right),
            .init(id: 15, label: "R",  pos: .init(x: 0.50, y: 0.045),
                  size: .init(width: 0.72, height: 0.028), shape: .capsuleH, side: .right),
            // 加号在左上 (实机确认, 2026-08)
            .init(id: 10, label: "+",  pos: .init(x: 0.30, y: 0.115),
                  size: .init(width: 0.13, height: 0.038), shape: .circle, side: .left),
            // ABXY 菱形: X 上 / Y 左 / A 右 / B 下
            .init(id: 2,  label: "X",  pos: .init(x: 0.50, y: 0.235),
                  size: .init(width: 0.21, height: 0.062), shape: .circle, side: .right),
            .init(id: 4,  label: "Y",  pos: .init(x: 0.28, y: 0.310),
                  size: .init(width: 0.21, height: 0.062), shape: .circle, side: .left),
            .init(id: 1,  label: "A",  pos: .init(x: 0.72, y: 0.310),
                  size: .init(width: 0.21, height: 0.062), shape: .circle, side: .right),
            .init(id: 3,  label: "B",  pos: .init(x: 0.50, y: 0.385),
                  size: .init(width: 0.21, height: 0.062), shape: .circle, side: .left),
            // 摇杆在 ABXY 下方
            .init(id: 12, label: L("摇杆按下"), pos: .init(x: 0.50, y: 0.560),
                  size: .init(width: 0.48, height: 0.140), shape: .circle, side: .right),
            .init(id: StickAnchor.id, label: L("摇杆方向"), pos: .init(x: 0.50, y: 0.560),
                  size: .init(width: 0.48, height: 0.140), shape: .circle, side: .left),
            .init(id: 13, label: "⌂",  pos: .init(x: 0.50, y: 0.760),
                  size: .init(width: 0.14, height: 0.040), shape: .circle, side: .right),
            .init(id: 5,  label: "SL", pos: .init(x: 0.035, y: 0.300),
                  size: .init(width: 0.05, height: 0.080), shape: .capsuleV, side: .left),
            .init(id: 6,  label: "SR", pos: .init(x: 0.035, y: 0.600),
                  size: .init(width: 0.05, height: 0.080), shape: .capsuleV, side: .left),
        ],
        aspect: 0.355, railSide: .left)

    // Joy-Con (L) 竖持: 滑轨在【右】, 摇杆在上、四个方向键在下 —— 和右手柄相反。
    // 按键编号沿用实测出来的位序 (1=右 2=上 3=下 4=左)。
    static let joyconLeft = DeviceArt(
        anchors: [
            .init(id: 16, label: "ZL", pos: .init(x: 0.50, y: 0.012),
                  size: .init(width: 0.62, height: 0.022), shape: .capsuleH, side: .left),
            .init(id: 15, label: "L",  pos: .init(x: 0.50, y: 0.045),
                  size: .init(width: 0.72, height: 0.028), shape: .capsuleH, side: .left),
            .init(id: 9,  label: "−",  pos: .init(x: 0.70, y: 0.115),
                  size: .init(width: 0.13, height: 0.038), shape: .circle, side: .right),
            .init(id: 11, label: L("摇杆按下"), pos: .init(x: 0.50, y: 0.235),
                  size: .init(width: 0.48, height: 0.140), shape: .circle, side: .right),
            .init(id: StickAnchor.id, label: L("摇杆方向"), pos: .init(x: 0.50, y: 0.235),
                  size: .init(width: 0.48, height: 0.140), shape: .circle, side: .left),
            .init(id: 2,  label: "↑", pos: .init(x: 0.50, y: 0.430),
                  size: .init(width: 0.19, height: 0.056), shape: .circle, side: .right),
            .init(id: 4,  label: "←", pos: .init(x: 0.29, y: 0.500),
                  size: .init(width: 0.19, height: 0.056), shape: .circle, side: .left),
            .init(id: 1,  label: "→", pos: .init(x: 0.71, y: 0.500),
                  size: .init(width: 0.19, height: 0.056), shape: .circle, side: .right),
            .init(id: 3,  label: "↓", pos: .init(x: 0.50, y: 0.570),
                  size: .init(width: 0.19, height: 0.056), shape: .circle, side: .left),
            .init(id: 14, label: "◉", pos: .init(x: 0.50, y: 0.755),
                  size: .init(width: 0.14, height: 0.040), shape: .circle, side: .right),
            .init(id: 5,  label: "SL", pos: .init(x: 0.965, y: 0.300),
                  size: .init(width: 0.05, height: 0.080), shape: .capsuleV, side: .right),
            .init(id: 6,  label: "SR", pos: .init(x: 0.965, y: 0.600),
                  size: .init(width: 0.05, height: 0.080), shape: .capsuleV, side: .right),
        ],
        aspect: 0.355, railSide: .right)

    // Switch Pro 手柄。16 个按键 + 帽子开关(=十字键) + 四个模拟轴。
    // 按键编号是按 Joy-Con 实测位序(1=A 2=X 3=B 4=Y)外推的, 未实测 ——
    // 映射界面按一下会实时点亮, 对不上照着改这张表即可。
    static let proController = DeviceArt(
        anchors: [
            .init(id: 7,  label: "ZL", pos: .init(x: 0.185, y: 0.020),
                  size: .init(width: 0.17, height: 0.035), shape: .capsuleH, side: .left),
            .init(id: 5,  label: "L",  pos: .init(x: 0.205, y: 0.072),
                  size: .init(width: 0.19, height: 0.042), shape: .capsuleH, side: .left),
            .init(id: 8,  label: "ZR", pos: .init(x: 0.815, y: 0.020),
                  size: .init(width: 0.17, height: 0.035), shape: .capsuleH, side: .right),
            .init(id: 6,  label: "R",  pos: .init(x: 0.795, y: 0.072),
                  size: .init(width: 0.19, height: 0.042), shape: .capsuleH, side: .right),

            .init(id: 11, label: L("左摇杆按下"), pos: .init(x: 0.245, y: 0.300),
                  size: .init(width: 0.155, height: 0.225), shape: .circle, side: .left),
            .init(id: StickAnchor.id, label: L("十字键 / 左摇杆"), pos: .init(x: 0.335, y: 0.560),
                  size: .init(width: 0.13, height: 0.19), shape: .circle, side: .left),

            .init(id: 2,  label: "X", pos: .init(x: 0.775, y: 0.235),
                  size: .init(width: 0.072, height: 0.105), shape: .circle, side: .right),
            .init(id: 1,  label: "A", pos: .init(x: 0.858, y: 0.305),
                  size: .init(width: 0.072, height: 0.105), shape: .circle, side: .right),
            .init(id: 3,  label: "B", pos: .init(x: 0.775, y: 0.375),
                  size: .init(width: 0.072, height: 0.105), shape: .circle, side: .right),
            .init(id: 4,  label: "Y", pos: .init(x: 0.692, y: 0.305),
                  size: .init(width: 0.072, height: 0.105), shape: .circle, side: .left),

            .init(id: 12, label: L("右摇杆按下"), pos: .init(x: 0.648, y: 0.560),
                  size: .init(width: 0.155, height: 0.225), shape: .circle, side: .right),
            .init(id: StickChannel.right.anchorID, label: L("右摇杆方向"),
                  pos: .init(x: 0.648, y: 0.560),
                  size: .init(width: 0.155, height: 0.225), shape: .circle, side: .right),

            .init(id: 9,  label: "−", pos: .init(x: 0.398, y: 0.250),
                  size: .init(width: 0.050, height: 0.072), shape: .circle, side: .left),
            .init(id: 10, label: "+", pos: .init(x: 0.602, y: 0.250),
                  size: .init(width: 0.050, height: 0.072), shape: .circle, side: .right),
            .init(id: 14, label: "◉", pos: .init(x: 0.418, y: 0.420),
                  size: .init(width: 0.048, height: 0.070), shape: .circle, side: .left),
            .init(id: 13, label: "⌂", pos: .init(x: 0.582, y: 0.420),
                  size: .init(width: 0.048, height: 0.070), shape: .circle, side: .right),
        ],
        aspect: 1.45, railSide: nil, style: .proController, hatLabel: L("十字键"))

    /// PlayStation 手柄 (DualShock 4 / DualSense)。
    ///
    /// 和 Switch Pro 最大的区别是布局: PS 是【对称】的 —— 十字键在左上、
    /// 面键在右上、两只摇杆并排在下方中间; Pro 手柄是非对称的(左摇杆在上、
    /// 十字键在下)。所以这张表不能照抄 Pro 的坐标。
    ///
    /// 按键编号用的是 DualShock 4 的标准 HID 位序 —— 这个业界比较统一,
    /// 但仍然【未实测】。插上手柄后在映射页逐个按, 设备图会实时点亮。
    static func playstation(mute: Bool) -> DeviceArt {
        var a: [ButtonAnchor] = [
            .init(id: 7,  label: "L2", pos: .init(x: 0.180, y: 0.018),
                  size: .init(width: 0.16, height: 0.036), shape: .capsuleH, side: .left),
            .init(id: 5,  label: "L1", pos: .init(x: 0.200, y: 0.072),
                  size: .init(width: 0.18, height: 0.042), shape: .capsuleH, side: .left),
            .init(id: 8,  label: "R2", pos: .init(x: 0.820, y: 0.018),
                  size: .init(width: 0.16, height: 0.036), shape: .capsuleH, side: .right),
            .init(id: 6,  label: "R1", pos: .init(x: 0.800, y: 0.072),
                  size: .init(width: 0.18, height: 0.042), shape: .capsuleH, side: .right),

            // 十字键在左上 (Pro 手柄这里是左摇杆)
            .init(id: StickChannel.hat.anchorID, label: L("十字键"), pos: .init(x: 0.230, y: 0.290),
                  size: .init(width: 0.13, height: 0.19), shape: .circle, side: .left),

            .init(id: 4, label: "△", pos: .init(x: 0.778, y: 0.222),
                  size: .init(width: 0.068, height: 0.100), shape: .circle, side: .right),
            .init(id: 3, label: "○", pos: .init(x: 0.858, y: 0.292),
                  size: .init(width: 0.068, height: 0.100), shape: .circle, side: .right),
            .init(id: 2, label: "✕", pos: .init(x: 0.778, y: 0.362),
                  size: .init(width: 0.068, height: 0.100), shape: .circle, side: .right),
            .init(id: 1, label: "□", pos: .init(x: 0.698, y: 0.292),
                  size: .init(width: 0.068, height: 0.100), shape: .circle, side: .left),

            .init(id: 9,  label: "Create",  pos: .init(x: 0.352, y: 0.150),
                  size: .init(width: 0.038, height: 0.075), shape: .capsuleV, side: .left),
            .init(id: 10, label: "Options", pos: .init(x: 0.648, y: 0.150),
                  size: .init(width: 0.038, height: 0.075), shape: .capsuleV, side: .right),
            .init(id: 14, label: L("触摸板"), pos: .init(x: 0.500, y: 0.245),
                  size: .init(width: 0.235, height: 0.175), shape: .capsuleH, side: .right),

            // 两只摇杆并排在下方中间 —— PS 的对称布局
            .init(id: 11, label: L("左摇杆按下"), pos: .init(x: 0.352, y: 0.560),
                  size: .init(width: 0.145, height: 0.210), shape: .circle, side: .left),
            .init(id: 12, label: L("右摇杆按下"), pos: .init(x: 0.648, y: 0.560),
                  size: .init(width: 0.145, height: 0.210), shape: .circle, side: .right),
            .init(id: StickChannel.right.anchorID, label: L("右摇杆方向"),
                  pos: .init(x: 0.648, y: 0.560),
                  size: .init(width: 0.145, height: 0.210), shape: .circle, side: .right),

            .init(id: 13, label: "PS", pos: .init(x: 0.500, y: 0.660),
                  size: .init(width: 0.048, height: 0.070), shape: .circle, side: .left),
        ]
        if mute {
            a.append(.init(id: 15, label: L("静音"), pos: .init(x: 0.500, y: 0.775),
                           size: .init(width: 0.055, height: 0.048),
                           shape: .capsuleH, side: .right))
        }
        return DeviceArt(anchors: a, aspect: 1.52, railSide: nil,
                         style: .playstation, hatLabel: L("十字键"))
    }
}

// MARK: - 手柄本体绘制

/// 用矢量画而不是贴产品照: 照片有版权/商标问题不能分发, 而且是死的 ——
/// 矢量能让单颗按键跟着实时输入点亮。
struct DeviceBody: View {
    let art: DeviceArt
    let bound: Set<Int>
    let highlighted: Int?
    let liveDir: (StickChannel, String)?

    private let bodyColor = Color(red: 0.16, green: 0.17, blue: 0.19)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                shoulders(w: w, h: h)
                shell(w: w, h: h)
                rail(w: w, h: h)
                ForEach(art.anchors.filter {
                    $0.id != 15 && $0.id != 16 && StickChannel.from(anchorID: $0.id) == nil
                }) { a in
                    anchorView(a, w: w, h: h)
                }
                // 四向箭头画在摇杆外围, 推哪边哪边亮
                // 箭头围着"帽子开关"画。Joy-Con 上它是摇杆, Pro 手柄上是十字键,
                // 位置各不相同, 所以按虚拟锚点走而不是硬找摇杆 id。
                ForEach(art.anchors.filter { StickChannel.from(anchorID: $0.id) != nil }) { a in
                    stickArrows(a, w: w, h: h,
                                on: liveDir?.0 == StickChannel.from(anchorID: a.id)
                                    ? liveDir?.1 : nil)
                }
            }
        }
    }

    // 机身: 滑轨那侧是直边, 外侧是大圆角 —— Joy-Con 的辨识特征
    /// Pro 手柄轮廓: 顶部两肩、中间收窄、两个握把向下张开。
    /// 用归一化控制点描一遍, 换尺寸自动跟着缩放。
    private func proPath(_ w: CGFloat, _ h: CGFloat) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * w, y: y * h) }
        var p = Path()
        p.move(to: pt(0.30, 0.030))
        p.addQuadCurve(to: pt(0.70, 0.030), control: pt(0.50, 0.105))   // 顶部中间微凹
        p.addCurve(to: pt(0.965, 0.300),                                // 右肩
                   control1: pt(0.88, 0.020), control2: pt(0.975, 0.130))
        p.addCurve(to: pt(0.845, 0.945),                                // 右握把外侧
                   control1: pt(0.995, 0.640), control2: pt(0.955, 0.905))
        p.addCurve(to: pt(0.655, 0.720),                                // 右握把内侧
                   control1: pt(0.745, 0.995), control2: pt(0.700, 0.870))
        p.addQuadCurve(to: pt(0.345, 0.720), control: pt(0.500, 0.605)) // 底部中间
        p.addCurve(to: pt(0.155, 0.945),                                // 左握把内侧
                   control1: pt(0.300, 0.870), control2: pt(0.255, 0.995))
        p.addCurve(to: pt(0.035, 0.300),                                // 左握把外侧
                   control1: pt(0.045, 0.905), control2: pt(0.005, 0.640))
        p.addCurve(to: pt(0.30, 0.030),                                 // 左肩
                   control1: pt(0.025, 0.130), control2: pt(0.12, 0.020))
        p.closeSubpath()
        return p
    }

    /// PS 手柄轮廓: 顶部平直、两侧握把更长更外撇, 整体比 Pro 更宽扁
    private func psPath(_ w: CGFloat, _ h: CGFloat) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * w, y: y * h) }
        var p = Path()
        p.move(to: pt(0.335, 0.035))
        p.addQuadCurve(to: pt(0.665, 0.035), control: pt(0.500, 0.020))  // 顶部近乎平直
        p.addCurve(to: pt(0.975, 0.275),
                   control1: pt(0.875, 0.030), control2: pt(0.985, 0.120))
        p.addCurve(to: pt(0.800, 0.960),                                  // 右握把外侧
                   control1: pt(0.965, 0.640), control2: pt(0.915, 0.930))
        p.addCurve(to: pt(0.610, 0.700),                                  // 右握把内侧
                   control1: pt(0.700, 0.995), control2: pt(0.655, 0.845))
        p.addQuadCurve(to: pt(0.390, 0.700), control: pt(0.500, 0.640))
        p.addCurve(to: pt(0.200, 0.960),
                   control1: pt(0.345, 0.845), control2: pt(0.300, 0.995))
        p.addCurve(to: pt(0.025, 0.275),
                   control1: pt(0.085, 0.930), control2: pt(0.035, 0.640))
        p.addCurve(to: pt(0.335, 0.035),
                   control1: pt(0.015, 0.120), control2: pt(0.125, 0.030))
        p.closeSubpath()
        return p
    }

    private func bodyPath(_ w: CGFloat, _ h: CGFloat) -> Path {
        if art.style == .playstation { return psPath(w, h) }
        if art.style == .proController { return proPath(w, h) }
        let rS = w * 0.12, rB = w * 0.46
        var p = Path()
        // 滑轨在右边时整条机身左右翻一下 (左 Joy-Con)
        if art.railSide == .right {
            var q = Path()
            q.move(to: .init(x: w - rS, y: 0))
            q.addLine(to: .init(x: rB, y: 0))
            q.addQuadCurve(to: .init(x: 0, y: rB), control: .init(x: 0, y: 0))
            q.addLine(to: .init(x: 0, y: h - rB))
            q.addQuadCurve(to: .init(x: rB, y: h), control: .init(x: 0, y: h))
            q.addLine(to: .init(x: w - rS, y: h))
            q.addQuadCurve(to: .init(x: w, y: h - rS), control: .init(x: w, y: h))
            q.addLine(to: .init(x: w, y: rS))
            q.addQuadCurve(to: .init(x: w - rS, y: 0), control: .init(x: w, y: 0))
            q.closeSubpath()
            return q
        }
        p.move(to: .init(x: rS, y: 0))
        p.addLine(to: .init(x: w - rB, y: 0))
        p.addQuadCurve(to: .init(x: w, y: rB), control: .init(x: w, y: 0))
        p.addLine(to: .init(x: w, y: h - rB))
        p.addQuadCurve(to: .init(x: w - rB, y: h), control: .init(x: w, y: h))
        p.addLine(to: .init(x: rS, y: h))
        p.addQuadCurve(to: .init(x: 0, y: h - rS), control: .init(x: 0, y: h))
        p.addLine(to: .init(x: 0, y: rS))
        p.addQuadCurve(to: .init(x: rS, y: 0), control: .init(x: 0, y: 0))
        p.closeSubpath()
        return p
    }

    private func shell(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            bodyPath(w, h)
                .fill(LinearGradient(
                    colors: [bodyColor.opacity(0.95), bodyColor.opacity(0.72)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            bodyPath(w, h).stroke(Color.white.opacity(0.10), lineWidth: 1)
            // 外侧高光, 撑出圆柱感
            bodyPath(w, h)
                .stroke(LinearGradient(colors: [.white.opacity(0.18), .clear],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 2)
                .blur(radius: 2)
        }
        .frame(width: w, height: h)
    }

    // 顶部肩键: ZR 在后, R 在前
    private func shoulders(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            if let zr = art.anchors.first(where: { $0.id == 16 }) {
                Capsule()
                    .fill(fillColor(16).opacity(0.85))
                    .frame(width: w * 0.70, height: h * 0.022)
                    .position(x: w * 0.52, y: h * 0.008)
            }
            if let r = art.anchors.first(where: { $0.id == 15 }) {
                Capsule()
                    .fill(fillColor(15))
                    .frame(width: w * 0.86, height: h * 0.030)
                    .position(x: w * 0.50, y: h * 0.030)
            }
        }
        .frame(width: w, height: h)
    }

    // 滑轨: 贴合 Switch 主机那条平边, SL/SR 就长在上面
    private func rail(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            let rx = art.railSide == .right ? w * 0.957 : w * 0.043
            RoundedRectangle(cornerRadius: w * 0.03)
                .fill(Color.black.opacity(0.35))
                .frame(width: w * 0.085, height: h * 0.70)
                .position(x: rx, y: h * 0.47)
            RoundedRectangle(cornerRadius: w * 0.03)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                .frame(width: w * 0.085, height: h * 0.70)
                .position(x: rx, y: h * 0.47)
        }
        .frame(width: w, height: h)
    }

    /// 摇杆四向指示。半径按摇杆本体算, 换手柄自动跟着走。
    private func stickArrows(_ stick: ButtonAnchor, w: CGFloat, h: CGFloat,
                             on liveKey: String?) -> some View {
        let cx = stick.pos.x * w, cy = stick.pos.y * h
        let r = stick.size.width * w * 0.5 + w * 0.10
        let offsets: [(String, CGFloat, CGFloat)] = [
            ("up", 0, -r), ("down", 0, r), ("left", -r, 0), ("right", r, 0),
        ]
        return ZStack {
            ForEach(offsets, id: \.0) { key, dx, dy in
                let on = liveKey == key
                Image(systemName: StickAnchor.arrow[key]!)
                    .font(.system(size: max(6, w * 0.11), weight: .bold))
                    .foregroundStyle(on ? Color.accentColor : Color.white.opacity(0.22))
                    .shadow(color: on ? Color.accentColor.opacity(0.8) : .clear, radius: 4)
                    .position(x: cx + dx, y: cy + dy)
            }
        }
        .frame(width: w, height: h)
    }

    private func fillColor(_ id: Int) -> Color {
        if highlighted == id { return .accentColor }
        return bound.contains(id) ? Color.white.opacity(0.42) : Color.white.opacity(0.13)
    }

    @ViewBuilder
    private func anchorView(_ a: ButtonAnchor, w: CGFloat, h: CGFloat) -> some View {
        let cx = a.pos.x * w, cy = a.pos.y * h
        let bw = a.size.width * w, bh = a.size.height * h
        let hot = highlighted == a.id

        ZStack {
            switch a.id {
            case 11, 12:    // 摇杆: 底座 + 帽子, 做出立体感
                Circle().fill(Color.black.opacity(0.45))
                    .frame(width: bw, height: bw)
                Circle()
                    .fill(RadialGradient(
                        colors: [fillColor(a.id).opacity(0.9), fillColor(a.id).opacity(0.45)],
                        center: .init(x: 0.35, y: 0.3), startRadius: 1, endRadius: bw * 0.6))
                    .frame(width: bw * 0.74, height: bw * 0.74)
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 1)
                    .frame(width: bw * 0.74, height: bw * 0.74)

            case 13, 14:    // Home / 截图键: 外圈 + 图标
                Circle().stroke(Color.white.opacity(hot ? 0.9 : 0.20), lineWidth: 1.5)
                    .frame(width: bw * 1.55, height: bw * 1.55)
                Circle().fill(fillColor(a.id)).frame(width: bw, height: bw)
                Image(systemName: a.id == 13 ? "house.fill" : "square.fill")
                    .font(.system(size: max(5, bw * 0.5)))
                    .foregroundStyle(Color.black.opacity(0.5))

            case 14 where art.style == .playstation:   // 触摸板: 大方块
                RoundedRectangle(cornerRadius: bh * 0.22)
                    .fill(fillColor(14)).frame(width: bw, height: bh)
                RoundedRectangle(cornerRadius: bh * 0.22)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    .frame(width: bw, height: bh)

            case _ where a.shape != .circle:   // SL/SR、肩键、扳机: 胶囊形
                Capsule().fill(fillColor(a.id)).frame(width: bw, height: bh)
                if bw > 22 {
                    Text(a.label).font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.5))
                }

            default:    // 面键 + 加减号
                Circle().fill(fillColor(a.id)).frame(width: bw, height: bw)
                if a.id != 10 && a.id != 9 {
                    Text(a.label)
                        .font(.system(size: max(7, bw * 0.55), weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.55))
                } else {
                    // id 9 是减号, 10 才是加号 —— 之前两个都画了 plus
                    Image(systemName: a.id == 9 ? "minus" : "plus")
                        .font(.system(size: max(5, bw * 0.6), weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.5))
                }
            }

            if hot {
                Circle().stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: bw * 1.7, height: bw * 1.7)
                    .blur(radius: 3)
            }
        }
        .position(x: cx, y: cy)
        .frame(width: w, height: h)
    }
}
