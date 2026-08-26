import Foundation
import IOKit.hid
import Combine

struct ConnectedDevice: Identifiable, Equatable {
    let vendorID: Int
    let productID: Int
    let name: String
    var id: String { DeviceProfile.key(vendorID, productID) }
}

/// 原始输入, 给 GUI 的"按一下要绑的键"用
enum RawInput: Equatable {
    case button(Int, down: Bool)
    case hat(Int?, StickChannel)
}

/// 手柄输入层。按 HID 用途匹配而不是写死厂商 —— Joy-Con / PS / Xbox / 8BitDo
/// 上报的都是 usagePage=1(GenericDesktop) + usage=5(GamePad) 或 4(Joystick)。
final class HIDInput: ObservableObject {
    static let shared = HIDInput()

    @Published private(set) var devices: [ConnectedDevice] = []
    /// 旁观者: 界面用来实时点亮按下的键。【绝不拦截】动作派发 ——
    /// 早期版本把它做成拦截式的, 结果一打开设置页手柄就在所有地方失效了。
    var previewHandler: ((RawInput) -> Void)?
    /// previewHandler 当前归哪个视图。图形/表格两个视图切换时, SwiftUI 可能
    /// **先调新视图的 onAppear 再调旧视图的 onDisappear** —— 不带认领的话,
    /// 旧视图退场会把新视图刚装上的 handler 清掉, 实时高亮就静默失效。
    var previewOwner: UUID?
    /// 拦截式: 只在"学习摇杆方向"时设上, 期间摇杆不触发动作
    var captureHandler: ((RawInput) -> Void)?
    /// 排查用: 最后一次收到的输入, 不管来自哪只手柄
    @Published private(set) var lastInput = L("还没收到任何输入")
    /// 排查用: 按键走到哪一步了
    @Published private(set) var lastDispatch = "—"
    @Published private(set) var inputCount = 0

    private var manager: IOHIDManager?
    // 两只手柄都有 1 号键。只按按键号记状态的话, 一只会吞掉另一只的事件。
    private var lastButton: [String: Int] = [:]   // "设备#键号"
    private var lastHat: [String: Int?] = [:]   // 通道 -> 上次方向
    /// 走原始报告解析的设备。这些设备的标准 HID 元素不再上报,
    /// 也不能让元素路径和原始路径同时派发, 否则会触发两次。
    private var rawDevices: Set<String> = []
    private var rawButtons: [String: Set<Int>] = [:]

    // 手势状态
    private var pressTime: [String: Date] = [:]
    private var longTimers: [String: Timer] = [:]
    private var longFired: Set<String> = []
    private var pendingTap: [String: Timer] = [:]
    private var repeatTimer: Timer?
    private var repeatButton: String?

    private let doubleWindow: TimeInterval = 0.28
    private let longDelay: TimeInterval = 0.45

    private init() {}

    // MARK: - 启动

    func start() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        IOHIDManagerSetDeviceMatchingMultiple(mgr, [
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x05],   // GamePad
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x04],   // Joystick
        ] as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterInputValueCallback(mgr, { ctx, _, _, value in
            guard let ctx else { return }
            Unmanaged<HIDInput>.fromOpaque(ctx).takeUnretainedValue().handle(value)
        }, ctx)

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            let s = Unmanaged<HIDInput>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { s.refreshDevices() }
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            let s = Unmanaged<HIDInput>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                // 手柄拔了/断连了, 按住型的东西要放开, 否则左键一直按着
                MousePad.releaseAll()
                s.refreshDevices()
            }
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // 非独占打开: 别的程序(比如系统的手柄框架)也能同时读, 不互相踢
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        refreshDevices()
    }

    /// 新设备第一次接上时套用内置默认配置。已有配置的绝不覆盖 ——
    /// 用户改过的东西不能被"默认值"冲掉。
    static func seedDefaults(_ d: ConnectedDevice) {
        let store = ConfigStore.shared
        guard !store.config.devices.contains(where: { $0.id == d.id }),
              var p = DefaultProfiles.make(vendor: d.vendorID, product: d.productID, name: d.name)
        else { return }
        p.productID = d.productID       // PS 系列产品号不止一个, 用实际连上的
        store.config.devices.append(p)
        store.save()
        NSLog("[AIRemote] 为 \(d.name) 套用了内置默认配置")
    }

    private func refreshDevices() {
        guard let mgr = manager,
              let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
            devices = []; return
        }
        let found: [ConnectedDevice] = set.compactMap { d in
            guard let v = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int,
                  let p = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int
            else { return nil }
            let n = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? L("手柄")
            let dev = ConnectedDevice(vendorID: v, productID: p, name: n)
            JoyConBattery.shared.attach(d, id: dev.id)
            HIDInput.seedDefaults(dev)
            return dev
        }.sorted { $0.name < $1.name }

        for gone in devices where !found.contains(gone) { JoyConBattery.shared.detach(id: gone.id) }
        devices = found
    }

    // MARK: - 事件分发

    private func handle(_ value: IOHIDValue) {
        let elem = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(elem)
        let usage = Int(IOHIDElementGetUsage(elem))
        let v = Int(IOHIDValueGetIntegerValue(value))

        // 来自哪只手柄。只记真实输入 —— 厂商页上那些 0x21 子命令回复是
        // 电量轮询的产物, 混在里面会盖掉真正的按键记录。
        let dev = IOHIDElementGetDevice(elem)
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        if page == UInt32(kHIDPage_Button) || page == UInt32(kHIDPage_GenericDesktop) {
            DispatchQueue.main.async {
                self.inputCount += 1
                self.lastInput = "#\(self.inputCount) \(name) page=0x\(String(page, radix: 16)) "
                    + "usage=\(usage) v=\(v)"
            }
        }
        if let v = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int,
           let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int,
           rawDevices.contains(DeviceProfile.key(v, pid)) {
            return      // 这只手柄走原始报告, 元素事件丢弃
        }

        // 摇杆走帽子开关, 逻辑范围 0...7, 越界即回中
        if page == UInt32(kHIDPage_GenericDesktop) && usage == 0x39 {
            let dir = (v >= 0 && v <= 7) ? v : nil
            let devID = HIDInput.deviceKey(dev)
            let hk = "\(devID)/\(StickChannel.hat.rawValue)"   // 和 injectRaw 同一格式
            if lastHat[hk] ?? -1 == dir { return }
            lastHat[hk] = dir
            DispatchQueue.main.async { self.onHat(dir, device: devID, ch: .hat) }
            return
        }

        guard page == UInt32(kHIDPage_Button) else { return }
        let devID = HIDInput.deviceKey(dev)
        let bk = "\(devID)#\(usage)"
        if lastButton[bk] == v { return }           // 去抖(按设备分开)
        lastButton[bk] = v
        DispatchQueue.main.async { self.onButton(usage, down: v == 1, device: devID) }
    }

    private var profile: DeviceProfile? {
        guard let d = devices.first else { return nil }
        return ConfigStore.shared.config.devices
            .first { $0.vendorID == d.vendorID && $0.productID == d.productID }
    }

    /// 按设备 id 取配置 —— 两只手柄同时连着时各用各的
    static func deviceKey(_ dev: IOHIDDevice) -> String {
        guard let v = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int,
              let p = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int
        else { return "" }
        return DeviceProfile.key(v, p)
    }

    private func profile(_ id: String) -> DeviceProfile? {
        ConfigStore.shared.config.devices.first { $0.id == id }
    }

    /// 原始报告解析出的状态。和元素路径复用同一套手势/动作逻辑,
    /// 只是入口不同 —— 这样 Pro 手柄和 Joy-Con 的行为完全一致。
    func injectRaw(deviceID: String, buttons: Set<Int>, dirs: [StickChannel: Int?],
                   vecs: [StickChannel: (Double, Double)?] = [:]) {
        rawDevices.insert(deviceID)

        // 哪几根摇杆被整体绑成了鼠标。它们的幅度直接喂给 MousePad,
        // 不再走"方向 -> 动作"。报告是 ~60Hz 持续来的, 天然就是刷新循环。
        let prof = profile(deviceID)
        var mouseChs: Set<StickChannel> = []
        for (ch, v) in vecs where prof?.stickMode(ch) == "mouse" {
            mouseChs.insert(ch)
            // 设置窗口在前台时不推光标 —— 否则人正在配键, 鼠标自己在屏幕上
            // 乱跑。仍然占住 mouseChs, 免得这根摇杆掉回"方向 -> 动作"那条路。
            guard !SettingsWindow.shared.isFront else { continue }
            MousePad.apply("\(deviceID)/\(ch.rawValue)", v.map { (x: $0.0, y: $0.1) })
        }

        let prev = rawButtons[deviceID] ?? []
        rawButtons[deviceID] = buttons
        for n in buttons.subtracting(prev) { onButton(n, down: true, device: deviceID) }
        for n in prev.subtracting(buttons) { onButton(n, down: false, device: deviceID) }

        for (ch, dir) in dirs {
            if mouseChs.contains(ch) { continue }     // 这根已经当鼠标用了
            let key = "\(deviceID)/\(ch.rawValue)"
            if lastHat[key] ?? -1 == dir { continue }
            lastHat[key] = dir
            onHat(dir, device: deviceID, ch: ch)
        }
    }

    // MARK: - 按键手势

    private func onButton(_ n: Int, down: Bool, device: String) {
        previewHandler?(.button(n, down: down))
        // 设置窗口在前台: 只点亮界面, 不发给系统。顺序要紧 —— 必须在
        // previewHandler 之后, 否则映射页的实时高亮也一起没了。
        if SettingsWindow.shared.isFront { return }
        // 覆盖优先, 回落基础层
        let app = AppContext.shared.frontBundle
        guard let prof = profile(device) else {
            if down { lastDispatch = L("按键%@ [%@] 找不到配置", String(n), device) }
            return
        }
        guard let b = prof.binding(button: n, app: app), !b.isEmpty else {
            if down { lastDispatch = L("按键%@ [%@] 没绑动作", String(n), device) }
            return
        }
        if down { lastDispatch = L("按键 %@ [%@] -> %@", String(n), device, b.tap ?? "?") }

        // 语音是按下/松开语义, 不参与单击双击长按
        // 按住型动作: 按下和松开各有含义, 不参与单击/双击/长按那套
        switch b.tap {
        case "ptt":
            down ? Actions.pttStart() : Actions.pttStop(); return
        case "mouseLeft":
            down ? MousePad.leftDown() : MousePad.leftUp(); return
        default: break
        }

        let k = "\(device)#\(n)"
        if down {
            pressTime[k] = Date()
            longFired.remove(k)

            if let long = b.long {
                longTimers[k] = Timer.scheduledTimer(withTimeInterval: longDelay, repeats: false) { _ in
                    self.longFired.insert(k)
                    Actions.run(long)
                }
            } else if let tap = b.tap, b.double == nil, Actions.isRepeatable(tap) {
                // 没绑长按才连发, 否则两者会打架
                startRepeat(k, tap)
            }
        } else {
            longTimers[k]?.invalidate(); longTimers[k] = nil
            stopRepeat(k)
            if longFired.contains(k) { longFired.remove(k); return }

            guard let tap = b.tap else { return }

            guard b.double != nil else { Actions.run(tap); return }

            // 绑了双击才需要等 —— 否则每次单击都白白多等 0.28 秒
            if let pending = pendingTap[k] {
                pending.invalidate(); pendingTap[k] = nil
                Actions.run(b.double!)
            } else {
                pendingTap[k] = Timer.scheduledTimer(withTimeInterval: doubleWindow, repeats: false) { _ in
                    self.pendingTap[k] = nil
                    Actions.run(tap)
                }
            }
        }
    }

    /// 长按连发, 和键盘重复一个手感
    private func startRepeat(_ key: String, _ action: String) {
        repeatButton = key
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                Actions.run(action)
            }
        }
    }

    private func stopRepeat(_ key: String) {
        guard repeatButton == key else { return }
        repeatTimer?.invalidate(); repeatTimer = nil; repeatButton = nil
    }

    // MARK: - 摇杆

    private func onHat(_ dir: Int?, device: String, ch: StickChannel) {
        previewHandler?(.hat(dir, ch))
        // 学习方向时才拦截, 免得学的过程中摇杆还在翻页
        if let cap = captureHandler { cap(.hat(dir, ch)); return }
        // 设置窗口在前台: 只点亮界面, 不发给系统。
        // ⚠️ 必须排在 captureHandler **之后** —— 学习方向向导本来就是在设置
        // 窗口前台跑的, 拦在它前面等于把向导整个废掉。
        if SettingsWindow.shared.isFront { return }
        repeatTimer?.invalidate(); repeatTimer = nil; repeatButton = nil

        guard let dir, let p = profile(device),
              let key = HIDInput.nearestKey(dir, p.sticks[ch.rawValue] ?? [:]),
              let action = p.stickAction(ch, dir: key, app: AppContext.shared.frontBundle)
        else { return }
        Actions.run(action)
        repeatButton = "\(device)#hat"
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                Actions.run(action)
            }
        }
    }

    /// 帽子开关是 8 方向环形。取最近的已学方向, 斜推也能落到正确的一边。
    /// 当前推的方向对应哪个 "up"/"down"/"left"/"right", 给界面高亮用
    static func nearestKey(_ value: Int, _ dirs: [String: StickDir]) -> String? {
        var best: (String, Int)?
        for (key, d) in dirs {
            let diff = abs(value - d.hat) % 8
            let dist = min(diff, 8 - diff)
            if best == nil || dist < best!.1 { best = (key, dist) }
        }
        guard let b = best, b.1 <= 1 else { return nil }
        return b.0
    }
}
