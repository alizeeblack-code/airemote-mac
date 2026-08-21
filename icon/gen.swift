import Foundation
import AppKit

// JoyCoding 图标: 单只手柄剪影 + 中心的终端光标。
//
// 形状取自"单手柄"最本质的几何特征——竖长条、一边直边(滑轨)、一边大圆角。
// 刻意避开侵权点: 不用霓虹红/蓝配色、不写 ABXY 字母、不放任何标识,
// 只保留通用的手柄几何。摇杆中心放一个终端光标块, 点出"用手柄打字"。

let S: CGFloat = 1024
let inset: CGFloat = 100
let box = CGRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2)

/// 手柄机身: 左边直边(滑轨侧), 右边大圆角
func bodyPath(_ r: CGRect) -> NSBezierPath {
    let rS = r.width * 0.16, rB = r.width * 0.46
    let p = NSBezierPath()
    p.move(to: CGPoint(x: r.minX + rS, y: r.maxY))
    p.line(to: CGPoint(x: r.maxX - rB, y: r.maxY))
    p.curve(to: CGPoint(x: r.maxX, y: r.maxY - rB),
            controlPoint1: CGPoint(x: r.maxX - rB*0.45, y: r.maxY),
            controlPoint2: CGPoint(x: r.maxX, y: r.maxY - rB*0.45))
    p.line(to: CGPoint(x: r.maxX, y: r.minY + rB))
    p.curve(to: CGPoint(x: r.maxX - rB, y: r.minY),
            controlPoint1: CGPoint(x: r.maxX, y: r.minY + rB*0.45),
            controlPoint2: CGPoint(x: r.maxX - rB*0.45, y: r.minY))
    p.line(to: CGPoint(x: r.minX + rS, y: r.minY))
    p.curve(to: CGPoint(x: r.minX, y: r.minY + rS),
            controlPoint1: CGPoint(x: r.minX + rS*0.45, y: r.minY),
            controlPoint2: CGPoint(x: r.minX, y: r.minY + rS*0.45))
    p.line(to: CGPoint(x: r.minX, y: r.maxY - rS))
    p.curve(to: CGPoint(x: r.minX + rS, y: r.maxY),
            controlPoint1: CGPoint(x: r.minX, y: r.maxY - rS*0.45),
            controlPoint2: CGPoint(x: r.minX + rS*0.45, y: r.maxY))
    p.close()
    return p
}

func draw() -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    // 圆角底 + 渐变
    ctx.saveGState()
    NSBezierPath(roundedRect: box, xRadius: box.width*0.225, yRadius: box.width*0.225).addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.38, green: 0.46, blue: 0.99, alpha: 1),
                        NSColor(srgbRed: 0.19, green: 0.22, blue: 0.70, alpha: 1)])!
        .draw(in: box, angle: -90)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.20), NSColor(white: 1, alpha: 0)])!
        .draw(in: CGRect(x: box.minX, y: box.midY, width: box.width, height: box.height/2), angle: -90)
    ctx.restoreGState()

    // 机身: 稍微倾斜, 填满方形也更有动势
    let bw = box.width * 0.375, bh = box.height * 0.70
    let body = CGRect(x: box.midX - bw/2, y: box.midY - bh/2, width: bw, height: bh)

    ctx.saveGState()
    ctx.translateBy(x: box.midX, y: box.midY)
    ctx.rotate(by: -14 * .pi / 180)
    ctx.translateBy(x: -box.midX, y: -box.midY)

    NSColor.white.setFill()
    bodyPath(body).fill()

    // 滑轨: 直边那一侧的凹槽
    NSColor(srgbRed: 0.24, green: 0.28, blue: 0.78, alpha: 0.30).setFill()
    let railW = bw * 0.115
    NSBezierPath(roundedRect: CGRect(x: body.minX + bw*0.075, y: body.minY + bh*0.16,
                                     width: railW, height: bh*0.68),
                 xRadius: railW*0.45, yRadius: railW*0.45).fill()

    // 摇杆 + 中心光标块 —— "用手柄打字"
    let deep = NSColor(srgbRed: 0.19, green: 0.22, blue: 0.70, alpha: 1)
    let sr = bw * 0.30
    let sc = CGPoint(x: body.midX + bw*0.055, y: body.midY + bh*0.235)
    deep.setFill()
    NSBezierPath(ovalIn: CGRect(x: sc.x - sr, y: sc.y - sr, width: sr*2, height: sr*2)).fill()
    NSColor.white.setFill()
    let cw = sr * 0.34, chh = sr * 0.96
    NSBezierPath(roundedRect: CGRect(x: sc.x - cw/2, y: sc.y - chh/2, width: cw, height: chh),
                 xRadius: cw*0.34, yRadius: cw*0.34).fill()

    // 四个面键: 只留几何形状, 不写字母
    deep.setFill()
    let dr = bw * 0.098
    let dc = CGPoint(x: body.midX + bw*0.055, y: body.midY - bh*0.185)
    let off = bw * 0.225
    for (dx, dy) in [(0.0, off), (0.0, -off), (-off, 0.0), (off, 0.0)] {
        NSBezierPath(ovalIn: CGRect(x: dc.x + dx - dr, y: dc.y + dy - dr,
                                    width: dr*2, height: dr*2)).fill()
    }
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

let img = draw()
let dir = "icon/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),
                   (128,"128x128"),(256,"128x128@2x"),(256,"256x256"),
                   (512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let t = NSSize(width: CGFloat(px), height: CGFloat(px))
    let out = NSImage(size: t)
    out.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(origin: .zero, size: t))
    out.unlockFocus()
    if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
    }
}
print("iconset 已生成")
