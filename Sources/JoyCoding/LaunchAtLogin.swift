import Foundation
import ServiceManagement

/// 开机自启。用 macOS 13+ 的 SMAppService —— 它把注册项挂在 app 自身上,
/// app 移动或删除时系统会自动清理, 不像老的 LaunchAgent plist 那样
/// 留一堆指向已删除路径的孤儿。
///
/// 前提: app 必须在稳定位置(/Applications)且签名有效。从构建目录直接跑
/// 是注册不上的。
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 返回是否成功。失败通常是 app 不在 /Applications, 或签名有问题。
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on {
                if SMAppService.mainApp.status == .enabled { return true }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("[JoyCoding] 开机自启设置失败: \(error.localizedDescription)")
            return false
        }
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled:        return L("已开启")
        case .notRegistered:  return L("未开启")
        case .requiresApproval: return L("需要在「系统设置 → 通用 → 登录项」里批准")
        case .notFound:       return L("找不到 app —— 需要先装到「应用程序」文件夹")
        @unknown default:     return L("未知")
        }
    }
}
