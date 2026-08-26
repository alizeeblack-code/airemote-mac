import AppKit
import Foundation

/// 认得出装了哪个听写工具, 但**不猜它的热键**。
///
/// 试过读 Typeless 的偏好(`now.typeless.desktop.plist`) —— 里面只有系统通用键,
/// 热键存在别处。其它几个工具各存各的、还随版本变。猜错比不猜更糟:
/// 用户会以为已经配好了, 然后按了没反应也不知道为什么。
///
/// 所以这里只做一件有把握的事: 报出装了什么, 提醒去核对。
enum DictationApps {

    struct Known {
        let bundleID: String
        let name: String
    }

    static let known: [Known] = [
        Known(bundleID: "now.typeless.desktop",     name: "Typeless"),
        Known(bundleID: "com.prakashjoshipax.VoiceInk", name: "VoiceInk"),
        Known(bundleID: "com.superduper.superwhisper", name: "superwhisper"),
        Known(bundleID: "com.flow.app",             name: "Wispr Flow"),
        Known(bundleID: "com.goodsnooze.MacWhisper", name: "MacWhisper"),
    ]

    /// 装在这台机器上的听写工具。只查 bundle ID 能不能定位到 app, 不读它们的配置。
    static func installed() -> [String] {
        known.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) == nil
                ? nil : $0.name
        }
    }
}
