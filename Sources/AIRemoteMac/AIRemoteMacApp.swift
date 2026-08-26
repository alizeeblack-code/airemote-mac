import SwiftUI
import AppKit

@main
struct AIRemoteMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var hid = HIDInput.shared
    @ObservedObject private var http = HTTPServer.shared
    @ObservedObject private var batt = JoyConBattery.shared

    var body: some Scene {
        MenuBarExtra {
            if hid.devices.isEmpty {
                Button(L("没有手柄 — 按一下手柄任意键唤醒")) {
                    SettingsWindow.shared.show(tab: .controller)
                }
            } else {
                ForEach(hid.devices) { d in
                    Button(batt.levels[d.id].map {
                        "🎮 \(d.name)   \($0)%" + (batt.charging[d.id] == true ? " ⚡" : "")
                    } ?? "🎮 \(d.name)") {
                        SettingsWindow.shared.show(tab: .controller)
                    }
                }
            }
            Divider()
            if KeySynth.hasAccessibility {
                Button(L("辅助功能 ✓")) { SettingsWindow.shared.show(tab: .general) }
            } else {
                // 直接开系统设置那一页 —— 用户要的是去授权, 不是看我们的界面
                Button(L("⚠️ 辅助功能未授权 — 去授权")) {
                    NSWorkspace.shared.open(URL(string:
                      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            if ConfigStore.shared.config.httpEnabled {
                Button(http.running ? L("遥控端口 %@ ✓", String(ConfigStore.shared.config.httpPort))
                                    : L("⚠️ 遥控端口未监听")) {
                    SettingsWindow.shared.show(tab: .remote)
                }
            }
            Divider()
            // 远端改过配置就在菜单里留一条 —— 手机能改 Mac 的配置之后,
            // "谁动的"必须在 Mac 上看得见。10 分钟后自动消失, 免得长期占位。
            if let c = http.lastRemoteChange, Date().timeIntervalSince(c.at) < 600 {
                Divider()
                Text(c.text).font(.caption)
            }

            Divider()
            Button(L("设置…")) { SettingsWindow.shared.show() }.keyboardShortcut(",")
            Button(L("退出 AIRemote for Mac")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            MenuBarLabel()
        }
    }
}

/// 自己管设置窗口。SwiftUI 的 Settings scene 要靠 showSettingsWindow: 这个
/// 私有 selector 打开, 在 .accessory 策略的菜单栏 app 里经常发不出去,
/// 或者窗口开在别的 app 后面。直接持有 NSWindow 最稳。
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    /// 设置窗口是不是当前的 key 窗口。
    ///
    /// 用来在配键时**吞掉按键**: 窗口在前台时按手柄, 合成出来的键盘事件本来
    /// 就会落到设置窗口自己身上(KeySynth 发给 frontmostApplication), 什么用
    /// 都没有; 而"切到 Claude Code"这类不查白名单的动作还会真的把窗口切走,
    /// 人正配着键就被弹出去了。
    var isFront: Bool { window?.isKeyWindow == true }

    func show(tab: SettingsNav.Tab? = nil) {
        if let tab { SettingsNav.shared.tab = tab }
        NSApp.activate(ignoringOtherApps: true)

        if let w = window {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = L("AIRemote for Mac 设置")
        w.contentView = NSHostingView(rootView: SettingsView())
        w.contentMinSize = NSSize(width: 1060, height: 700)
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

// 菜单栏图标统一用 SF Symbols 的 gamecontroller。
// 试过按左右 Joy-Con 手绘区分, 但 16pt 下画不像, 反而不如一个标准图标清楚。
// (另: MenuBarExtra 的 label 只可靠支持 Text / Image, SwiftUI 形状画不出来,
//  真要手绘得先落到 template NSImage 上。)

/// 菜单栏上的图标 + 电量。图标右边直接显示百分比, 不用点开菜单。
struct MenuBarLabel: View {
    @ObservedObject private var hid = HIDInput.shared
    @ObservedObject private var batt = JoyConBattery.shared
    @ObservedObject private var store = ConfigStore.shared

    private var pct: Int? {
        guard let d = hid.devices.first else { return nil }
        return batt.levels[d.id]
    }
    private var isCharging: Bool {
        guard let d = hid.devices.first else { return false }
        return batt.charging[d.id] == true
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: hid.devices.isEmpty
                  ? "gamecontroller" : "gamecontroller.fill")
            if store.config.showBatteryInMenuBar, let pct {
                if isCharging { Image(systemName: "bolt.fill") }
                Text("\(pct)%").monospacedDigit()
            }
        }
    }
}

/// 外观。默认跟随系统 —— NSApp.appearance = nil 就是"不覆盖"。
/// 设成具体值会同时影响设置窗和菜单栏下拉菜单。
enum Appearance {
    static func apply(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        // 菜单栏 app, 不要 Dock 图标
        NSApp.setActivationPolicy(.accessory)

        // 只触发系统授权提示, 不弹自己的模态框 —— 模态框会阻塞后面的启动流程,
        // HTTP 服务就起不来了; 而且每次启动都弹很烦。状态在菜单栏和设置里显示。
        if !KeySynth.hasAccessibility { KeySynth.requestAccessibility() }

        Appearance.apply(ConfigStore.shared.config.appearance)

        _ = AppContext.shared
        HIDInput.shared.start()
        HTTPServer.shared.restart()

        // 一条映射都没有 = 还没配过, 直接把设置摆出来, 省得对方找不到入口。
        // 也支持 --settings 从命令行直接开 (调试和写脚本方便)
        let configured = ConfigStore.shared.config.devices.contains { !$0.buttons.isEmpty }
        if !configured || CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindow.shared.show()
            }
        }
    }
}
