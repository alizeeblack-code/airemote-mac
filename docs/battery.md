# Joy-Con 电量是怎么读出来的

macOS **完全不暴露** Joy-Con 电量 —— `IOHIDDeviceGetProperty`、IORegistry
全库搜 `BatteryPercent`/`BatteryLevel`/`PercentRemaining`、
`system_profiler SPBluetoothDataType` 全都查过，一条都没有。

所以只能发任天堂的私有子命令。实现在 `Sources/AIRemoteMac/Battery.swift`。

## 做法

发输出报告 `0x01`（震动 + 子命令），子命令 `0x50`（读稳压电压），
从输入报告 `0x21` 的回复里取电量。

**不需要切换报告模式** —— 按键和摇杆继续走 macOS 的 HID 元素解析，
输入层保持厂商无关。

## 三个坑（每一个都会让它静默失败）

**1. 输出报告必须补齐到 49 字节。**
短包手柄直接忽略整个命令，`SetReport` 却照样返回成功，完全没有报错。

**2. report id 要既单独传、又留在缓冲区第 0 字节。**
```swift
data[0] = 0x01                       // ← 容易漏掉这个
data[1] = packet & 0x0F
data[2..<10] = 中性震动
data[10] = 0x50                      // 子命令
IOHIDDeviceSetReport(dev, .output, 0x01, &data, 49)
```
漏掉 `data[0]` 的话后面全部错位，手柄会当成子命令 `0x00` 来回复 ——
症状是收到了 `0x21` 但 ACK=`0x80`、子命令号=`0x00`。

**3. 原始报告回调要求设备自己被 open + schedule。**
只在 `IOHIDManager` 层面 open/schedule 是收不到 `InputReport` 回调的：
```swift
IOHIDDeviceOpen(device, ...)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), ...)
IOHIDDeviceRegisterInputReportCallback(device, buf, size, cb, ctx)
```

## 报告格式

输入报告 `0x21`（含 report id，49 字节）：

```
[0]     0x21
[1]     timer
[2]     电量 + 连接信息  ← 高半字节: 最低位=充电中,
                          偶数部分 8/6/4/2/0 = 满/高/中/低/空
[3:12]  按键 / 摇杆
[12]    震动回执
[13]    ACK           (0x90 = 带数据的应答)
[14]    回复的子命令号
[15:16] 稳压电压，小端 16 位，单位 2.5mV
```

**byte 2 任何 `0x21` 回复都带**，所以粗粒度电量总是能拿到；
精确电压只在 `0x50` 应答里有。代码里两者都用：有精确值用精确值，
否则退回粗粒度（0…4 映射成 5/25/50/75/100%）。

电压换算参考点：满电约 1673，空电约 1264。

## 参考

协议细节对照 Linux 内核 `hid-nintendo.c` 和
[JoyType](https://github.com/0xDarcyJ/JoyType)（Python 实现，
`joytype/hid_reader.py` + `joytype/macos_controllers.py`）。
49 字节和 report id 这两个坑就是从它的注释里看出来的。

注：JoyType 还会发子命令 `0x03`/arg `0x30` 切到完整报告模式并自己解析
按键，我们不需要 —— 只读电量的话保持简易模式即可。
