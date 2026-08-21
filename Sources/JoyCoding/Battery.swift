import Foundation
import IOKit.hid

/// Joy-Con 电量。
///
/// macOS 完全不暴露这个信息(HID 属性 / IORegistry / 蓝牙层都查过), 只能发
/// 任天堂私有子命令。协议细节参考 hid-nintendo 内核驱动和 JoyType 项目。
///
/// 两个关键点(第一次实现时都踩了):
///   1. 输出报告必须补齐到 49 字节, 短包手柄直接忽略整个命令
///   2. 原始报告回调要求设备【自己】被 open + schedule, 只在 manager
///      层面 open 是收不到的
final class JoyConBattery: ObservableObject {
    static let shared = JoyConBattery()

    @Published private(set) var levels: [String: Int] = [:]      // 0...4 粗粒度
    @Published private(set) var charging: [String: Bool] = [:]
    @Published private(set) var diag = L("未开始")
    /// 排查用: 每只手柄各自的原始读数
    @Published private(set) var raw: [String: String] = [:]

    private var buffers: [String: UnsafeMutablePointer<UInt8>] = [:]
    private var devices: [String: IOHIDDevice] = [:]
    /// 回调只给一个 sender 指针, 靠它反查是哪只手柄 —— 不然两只同时连着
    /// 时电量会串到一起
    private var idByPointer: [UnsafeMutableRawPointer: String] = [:]
    private var packet: UInt8 = 0
    private var timer: Timer?
    private var reportKinds: Set<Int> = []

    private let bufSize = 64
    private let outLen  = 49          // ← 必须是 49
    private let nintendo = 0x057E

    private init() {}

    func attach(_ device: IOHIDDevice, id: String) {
        guard (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) == nintendo,
              buffers[id] == nil else { return }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        buf.initialize(repeating: 0, count: bufSize)
        buffers[id] = buf
        devices[id] = device
        idByPointer[Unmanaged.passUnretained(device).toOpaque()] = id

        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(),
                                       CFRunLoopMode.defaultMode.rawValue)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, bufSize, { ctx, _, sender, _, rid, rep, len in
            guard let ctx else { return }
            Unmanaged<JoyConBattery>.fromOpaque(ctx).takeUnretainedValue()
                .handleReport(sender: sender, id: Int(rid), bytes: rep, length: len)
        }, ctx)

        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 0.5) {
                self.query(id)
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.buffers.keys.forEach { self?.query($0) }
        }
    }

    func detach(id: String) {
        buffers[id]?.deallocate()
        buffers.removeValue(forKey: id)
        if let d = devices[id] {
            idByPointer.removeValue(forKey: Unmanaged.passUnretained(d).toOpaque())
        }
        devices.removeValue(forKey: id)
        levels.removeValue(forKey: id)
        charging.removeValue(forKey: id)
    }

    /// 输出报告 0x01 = 震动 + 子命令, 整包 49 字节:
    ///   [0] 0x01 报告 id   [1] 包序号   [2:10] 中性震动
    ///   [10] 子命令 id     [11] 参数
    ///
    /// 两个坑都在这一个函数里:
    ///   * 长度必须是 49, 短包手柄直接忽略
    ///   * report id 要【既单独传给 SetReport, 又留在缓冲区第 0 字节】。
    ///     少这一个字节, 后面全部错位, 手柄会当成子命令 0x00。
    private func query(_ id: String) {
        guard let device = devices[id] else { return }
        var data = [UInt8](repeating: 0, count: outLen)
        data[0] = 0x01
        data[1] = packet & 0x0F
        let rumble: [UInt8] = [0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40]
        for (i, b) in rumble.enumerated() { data[2 + i] = b }
        data[10] = 0x50                      // 读稳压电压
        packet = packet &+ 1

        let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x01, &data, data.count)
        if r != kIOReturnSuccess {
            DispatchQueue.main.async {
                self.diag = String(format: L("SetReport 失败 0x%%08X"), r)
            }
        }
    }

    private func handleReport(sender: UnsafeMutableRawPointer?, id: Int,
                              bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        // 完整报告 0x30: 按键走这里解析, 顺带取电量。
        // Pro 手柄被系统切进这个模式后, 标准 HID 元素就不再上报了。
        if id == 0x30, length >= 12 {
            let b = UnsafeBufferPointer(start: bytes, count: Int(length))
            let btns = NintendoRaw.buttons(b)
            // 三个方向来源各走各的通道, 可以分别绑不同动作
            let dirs: [StickChannel: Int?] = [
                // 十字键和左摇杆合流: 推哪个都一样
                .hat:   NintendoRaw.hat(b) ?? NintendoRaw.leftStick(b),
                .right: NintendoRaw.rightStick(b),
            ]
            let nib = Int(b[2]) >> 4
            DispatchQueue.main.async {
                guard let sender, let k = self.idByPointer[sender] else { return }
                self.levels[k] = JoyConBattery.coarseToPercent((nib & 0x0E) / 2)
                self.charging[k] = (nib & 0x01) != 0
                self.raw[k] = L("完整报告")
                HIDInput.shared.injectRaw(deviceID: k, buttons: btns, dirs: dirs)
            }
            return
        }
        // 缓冲区【含】report id, byte 0 就是 0x21
        guard id == 0x21, length >= 17 else { return }
        let b = UnsafeBufferPointer(start: bytes, count: Int(length))

        // byte 2 = 电量 + 连接信息。高半字节: 最低位是充电标志, 偶数部分
        // 8/6/4/2/0 = 满/高/中/低/空。任何 0x21 回复都带这个。
        let nib = Int(b[2]) >> 4
        let coarse = (nib & 0x0E) / 2                  // 0...4
        let isCharging = (nib & 0x01) != 0

        // 子命令 0x50 的回复里还有精确电压 (小端 16 位, 单位 2.5mV)
        var precise = -1
        if b[13] == 0x90, b[14] == 0x50 {
            precise = JoyConBattery.percent(fromRaw: Int(b[15]) | (Int(b[16]) << 8))
        }

        DispatchQueue.main.async {
            guard let sender, let key = self.idByPointer[sender] else { return }
            self.levels[key] = precise >= 0 ? precise
                                            : JoyConBattery.coarseToPercent(coarse)
            self.charging[key] = isCharging
            self.raw[key] = precise >= 0 ? L("精确 %@%%", String(precise)) : L("粗 %@/4", String(coarse))
            self.diag = L("%@ 只手柄各自上报", String(self.levels.count))
        }
    }

    /// 粗粒度 0...4 转百分比。手柄只给五档, 取每档代表值。
    static func coarseToPercent(_ level: Int) -> Int {
        [5, 25, 50, 75, 100][max(0, min(4, level))]
    }

    /// 社区实测参考点: 满电约 1673, 空电约 1264 (单位 2.5mV)
    static func percent(fromRaw raw: Int) -> Int {
        guard raw > 800, raw < 2200 else { return -1 }
        let p = (Double(raw) - 1264) / (1673 - 1264) * 100
        return max(0, min(100, Int(p.rounded())))
    }

    static func symbol(_ pct: Int) -> String {
        switch pct {
        case 88...:   return "battery.100"
        case 60..<88: return "battery.75"
        case 35..<60: return "battery.50"
        case 12..<35: return "battery.25"
        default:      return "battery.0"
        }
    }
}
