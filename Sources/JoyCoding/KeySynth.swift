import Foundation
import CoreGraphics
import AppKit

/// 键盘 / 滚轮事件合成。等价于 Hammerspoon 的 hs.eventtap, 但是原生 CGEvent。
enum KeySynth {

    // MARK: - 键名 -> 虚拟键码

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "escape": 53,
        // 修饰键本身 (合成裸修饰键时用)
        "cmd": 55, "shift": 56, "capslock": 57, "alt": 58, "ctrl": 59,
        "rightshift": 60, "rightalt": 61, "rightctrl": 62, "fn": 63,
        "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119, "pagedown": 121,
        "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    /// 修饰键名 -> 它对应的 flag。合成裸修饰键时按下必须带上自己, 否则
    /// 监听方看到的是"已松开"——按住说话就会失效。本项目实测踩过这个坑。
    static let modifierFlag: [String: CGEventFlags] = [
        "cmd": .maskCommand, "shift": .maskShift, "alt": .maskAlternate, "ctrl": .maskControl,
        "rightshift": .maskShift, "rightalt": .maskAlternate, "rightctrl": .maskControl,
        "fn": .maskSecondaryFn,
    ]

    static func flags(_ mods: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in mods { if let x = modifierFlag[m.lowercased()] { f.insert(x) } }
        return f
    }

    // MARK: - 键盘

    static func keyStroke(_ mods: [String], _ key: String) {
        guard let code = keyCodes[key.lowercased()] else { return }
        let f = flags(mods)
        post(code, down: true, flags: f)
        post(code, down: false, flags: f)
    }

    static func keyDown(_ mods: [String], _ key: String) {
        guard let code = keyCodes[key.lowercased()] else { return }
        post(code, down: true, flags: flags(mods))
    }

    static func keyUp(_ mods: [String], _ key: String) {
        guard let code = keyCodes[key.lowercased()] else { return }
        post(code, down: false, flags: flags(mods))
    }

    private static func post(_ code: CGKeyCode, down: Bool, flags f: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
        e.flags = f
        e.post(tap: .cghidEventTap)
    }

    /// 合成"按住/松开某个裸修饰键"。走 flagsChanged 事件, 不是 keyDown/keyUp。
    /// 按下时 flags 必须包含自己, 松开时清空 —— 这样才和物理按键一模一样。
    static func modifierHold(_ key: String, down: Bool) {
        guard let code = keyCodes[key.lowercased()],
              let flag = modifierFlag[key.lowercased()] else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = down ? flag : []
        e.post(tap: .cghidEventTap)
    }

    static func isModifier(_ key: String) -> Bool {
        modifierFlag[key.lowercased()] != nil
    }

    /// 打字。用 Unicode 直接输入, 不依赖键盘布局, 中文也没问题。
    static func type(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text {
            var utf16 = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 滚轮

    /// 翻页用合成滚轮而不是 Page Up/Down 键: Web 界面要看焦点在不在正文区,
    /// 全屏 TUI 的终端滚动缓冲区又根本不生效。滚轮对两者都有效。
    /// 滚轮按鼠标位置投递, 所以指针不在目标窗口上时先临时挪过去再挪回来。
    static func scroll(lines: Int32) {
        // 下面要把光标挪走再挪回, 这期间右摇杆不能同时推
        MousePad.suspended = true
        defer { MousePad.suspended = false }
        let origin = CGEvent(source: nil)?.location
        var moved = false

        if let o = origin, let frame = frontWindowFrame(), !frame.contains(o) {
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
            moved = true
        }

        let src = CGEventSource(stateID: .hidSystemState)
        if let e = CGEvent(scrollWheelEvent2Source: src, units: .line,
                           wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) {
            e.post(tap: .cghidEventTap)
        }

        if moved, let o = origin { CGWarpMouseCursorPosition(o) }
    }

    // MARK: - 点击

    /// 在指定位置点一下, 然后把指针放回原处。
    ///
    /// 用来兜底"聚焦输入框" —— Claude Code / 微信都没有这个快捷键(官方文档
    /// 和菜单都查过), Web 界面的元素又不暴露给无障碍接口, 点不到。
    /// 好在聊天类界面的输入框永远在窗口底部, 按比例点得到。
    static func click(at p: CGPoint) {
        MousePad.suspended = true
        defer { MousePad.suspended = false }
        let origin = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        if let o = origin { CGWarpMouseCursorPosition(o) }
    }

    /// 前台窗口底部中央往上 offset 点的位置 —— 聊天输入框大致在这
    static func composerPoint(bottomOffset: CGFloat) -> CGPoint? {
        guard let f = frontWindowFrame() else { return nil }
        return CGPoint(x: f.midX, y: f.maxY - bottomOffset)
    }

    /// 前台 app 最前面那个窗口的位置。用于把指针挪进去。
    static func frontWindowFrame() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                  as? [[String: Any]]
        else { return nil }

        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 100, height > 100     // 跳过工具条之类的小窗
            else { continue }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }

    // MARK: - 权限

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// 重启自己。授权辅助功能后必须重启才生效, 让用户去终端 killall 太不友好。
    /// 做法: 先派一个 shell 等我们退出, 再把 app 拉起来。
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.8; open -n \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    static func openAccessibilityPane() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// 弹系统授权对话框。授权后必须重启 app 才生效 —— macOS 对已运行进程
    /// 不会即时放行, 这一步很容易被忽略。
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }
}
