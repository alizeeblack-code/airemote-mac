import Foundation
import CoreImage
import AppKit

/// 二维码。用系统自带的 CIQRCodeGenerator, 不引任何依赖。
enum QRCode {
    static func image(_ text: String, size: CGFloat = 220) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")   // 中等容错, 够用且码更疏
        guard let ci = filter.outputImage else { return nil }

        // 二维码原图很小(每个模块 1px), 必须整数倍放大, 否则边缘会糊
        let scale = size / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}
