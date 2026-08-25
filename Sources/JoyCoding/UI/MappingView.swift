import SwiftUI
import AppKit

struct MappingView: View {
    /// 图形/表格切换 —— 壳(ControllerView)持有, 两个视图的顶栏各放一个切换器
    @Binding var mode: ControllerMode
    @ObservedObject var store = ConfigStore.shared
    @ObservedObject var hid = HIDInput.shared
    @ObservedObject var batt = JoyConBattery.shared

    /// 选中的手柄。壳(ControllerView)持有, 和表格视图共用一份
    @Binding var selectedID: String?
    @State private var hot: Int?              // 鼠标悬停高亮的按键
    @State private var pressed: Int?          // 手柄上真按下的键, 实时点亮
    @State private var learningStick = false
    @State private var liveDir: (StickChannel, String)?
    @State private var learningCh: StickChannel = .hat
    /// 当前编辑的层。"" = 基础层, 否则是 app 的 bundleID。
    @State private var layer = ""
    @State private var stickStep = 0
    /// previewHandler 的认领凭据(见 HIDInput.previewOwner)
    @State private var watchToken = UUID()

    /// (方向键, 默认动作)。提示文案按设备现生成 —— Joy-Con 上是摇杆要"推",
    /// Pro 手柄上这个通道其实是十字键, 得说"按"。
    private let stickWizard: [(String, String)] = [
        ("up",    "scrollUp"),
        ("down",  "scrollDown"),
        ("left",  "sessionPrev"),
        ("right", "sessionNext"),
    ]

    /// 通道在这只手柄上叫什么 —— 用设备图锚点上的名字, 比枚举里的通用名准确
    /// (Joy-Con 是"摇杆方向", Pro 手柄主通道是"十字键 / 左摇杆")
    private func chLabel(_ ch: StickChannel) -> String {
        art?.anchors.first { $0.id == ch.anchorID }?.label ?? ch.label
    }

    /// 这只手柄有哪些方向通道
    private var channels: [StickChannel] {
        guard let a = art else { return [.hat] }
        return a.anchors.compactMap { StickChannel.from(anchorID: $0.id) }
    }

    /// 这只手柄的方向通道叫什么: Joy-Con = 摇杆, Pro = 十字键
    private var hatLabel: String {
        guard let d = device else { return L("摇杆") }
        return DeviceArt.art(vendor: d.vendorID, product: d.productID).hatLabel
    }

    private func stickPrompt(_ ch: StickChannel, _ i: Int) -> String {
        let dir = [L("上"), L("下"), L("左"), L("右")][min(i, 3)]
        if ch == .right { return L("把右摇杆推向【%@】", dir) }
        return hatLabel == L("十字键")
            ? L("按十字键或推左摇杆【%@】", dir) : L("把摇杆推向【%@】", dir)
    }

    private var device: ConnectedDevice? {
        hid.devices.first { $0.id == selectedID } ?? hid.devices.first
    }
    private var profile: DeviceProfile? {
        guard let d = device else { return nil }
        return store.config.devices.first { $0.id == d.id }
    }
    private var art: DeviceArt? {
        guard let d = device else { return nil }
        let a = DeviceArt.art(vendor: d.vendorID, product: d.productID)
        return a.anchors.isEmpty ? nil : a
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            // 层胶囊只在画布可用时出现 —— 没手柄(或没外观图)时既没有可编辑的
            // 层, 胶囊点了也什么都不发生, 还把空状态引导挤到更低的位置
            if let d = device, let art {
                layerBar
                Divider()
                canvas(d, art)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            // 只在还没选过时兜底。selectedID 现在是壳持有的共享状态, 无条件
            // 重置会把用户在表格页选的手柄冲掉(切回图形就跳回第一只)。
            if selectedID == nil { selectedID = hid.devices.first?.id }
            watchPresses()
        }
        .onDisappear { stopWatching() }
        .onChange(of: hid.devices.map(\.id)) { _ in
            if selectedID == nil { selectedID = hid.devices.first?.id }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            ControllerModePicker(mode: $mode)
            Divider().frame(height: 16)
            Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
            if hid.devices.isEmpty {
                Text(L("未连接手柄")).foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { selectedID ?? hid.devices.first?.id ?? "" },
                    set: { selectedID = $0 })) {
                    ForEach(hid.devices) { d in Text("\(d.name)   \(d.id)").tag(d.id) }
                }
                .labelsHidden().frame(maxWidth: 300)
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(L("已连接")).font(.subheadline).foregroundStyle(.secondary)
                if let d = device, let pct = batt.levels[d.id] {
                    Label {
                        Text("\(pct)%").font(.subheadline).monospacedDigit()
                    } icon: {
                        Image(systemName: batt.charging[d.id] == true
                              ? "battery.100.bolt" : JoyConBattery.symbol(pct))
                    }
                    .foregroundStyle(pct <= 20 ? Color.orange : Color.secondary)
                    .help(L("Joy-Con 电量"))
                }
            }
            Spacer()
            if let d = device {
                if learningStick {
                    Text(stickStep < stickWizard.count
                         ? stickPrompt(learningCh, stickStep) : "")
                        .font(.subheadline).foregroundStyle(Color.accentColor)
                    Button(L("取消")) { endStick() }.font(.subheadline)
                } else {
                    let chs = channels
                    if chs.count <= 1 {
                        Button { beginStick(d, chs.first ?? .hat) } label: {
                            Label(L("学习「%@」", chLabel(chs.first ?? .hat)),
                                  systemImage: "wand.and.stars").font(.subheadline)
                        }
                    } else {
                        Menu {
                            ForEach(chs, id: \.self) { ch in
                                Button(L("学习「%@」", chLabel(ch))) { beginStick(d, ch) }
                            }
                        } label: {
                            Label(L("学习方向"), systemImage: "wand.and.stars").font(.subheadline)
                        }
                        .fixedSize()
                    }
                }
            }
            if !KeySynth.hasAccessibility {
                Button {
                    NSWorkspace.shared.open(URL(string:
                      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                } label: {
                    Label(L("辅助功能未授权"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.subheadline)
                }
                .help(L("勾选后必须重启 JoyCoding 才生效"))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var layerBar: some View {
        HStack(spacing: 6) {
            layerChip("", L("基础"))
            ForEach(store.config.targetApps, id: \.self) { app in
                layerChip(app, AppName.of(app))
            }
            Spacer()
            if !layer.isEmpty {
                let n = profile?.overrides[layer]?.buttons.count ?? 0
                Text(n == 0 ? L("这一层还没有覆盖，按键都继承基础层")
                            : L("%@ 个按键在这一层被覆盖", String(n)))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func layerChip(_ id: String, _ title: String) -> some View {
        let on = layer == id
        let count = id.isEmpty ? 0 : (profile?.overrides[id]?.buttons.count ?? 0)
        return Button { layer = id } label: {
            HStack(spacing: 4) {
                Text(title).font(.subheadline)
                if count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(on ? Color.white.opacity(0.3)
                                                      : Color.accentColor.opacity(0.22)))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
            .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "gamecontroller")
                .font(.system(size: 44)).foregroundStyle(.tertiary)
            if hid.devices.isEmpty {
                noDeviceGuide
            } else {
                // 手柄在, 只是没画过它的外观图 —— 映射照常能用, 说清楚就行
                Text(L("这个手柄还没有外观图")).foregroundStyle(.secondary)
                Text(L("按键仍可正常映射，只是画不出图形"))
                    .font(.subheadline).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 一个手柄都没有时的引导。
    ///
    /// 这一页是设置窗口的**默认标签页**, 所以没手柄的人一打开设置第一眼就是
    /// 这里 —— 原来只有"没检测到手柄 / 蓝牙配对后按一下"两行小字, 既没说
    /// 怎么配对, 也把 USB 这条路藏了(HID 是按 usage page 认的, 线连一样识别)。
    private var noDeviceGuide: some View {
        VStack(spacing: 14) {
            Text(L("没检测到手柄")).font(.title3).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.secondary).frame(width: 18)
                    Text(L("在系统设置里和手柄蓝牙配对")).foregroundStyle(.secondary)
                    Button(L("打开蓝牙设置")) {
                        // macOS 13 起系统设置是 ExtensionKit 面板, 用这个 URL 直达。
                        // 打不开也不至于卡住 —— 上面那句话已经说清该去哪。
                        if let u = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                    .font(.subheadline)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "cable.connector")
                        .foregroundStyle(.secondary).frame(width: 18)
                    Text(L("或者直接用 USB 线连上，不配对也能用"))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "hand.tap")
                        .foregroundStyle(.secondary).frame(width: 18)
                    Text(L("连上后按一下手柄任意键唤醒它"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .padding(.vertical, 14).padding(.horizontal, 18)
            .background(.quaternary.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(L("Switch Pro、Joy-Con、DualSense 有外观图；其他手柄也能映射，只是画不出图形"))
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Divider().frame(width: 260).padding(.top, 4)

            HStack(spacing: 6) {
                Text(L("没有手柄？")).font(.subheadline).foregroundStyle(.tertiary)
                Button(L("用手机遥控")) { SettingsNav.shared.tab = .remote }
                    .font(.subheadline)
            }
        }
    }

    // MARK: - 画布: 手柄居中, 卡片分列两侧, 细线相连

    private func canvas(_ d: ConnectedDevice, _ art: DeviceArt) -> some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let cardW: CGFloat = 262
            // Pro 手柄有 15 张卡, 一屏放不下 —— 算出需要多高, 不够就整块滚动。
            // 连线和卡片在同一坐标系里, 一起滚不会错位。
            let lefts0  = art.anchors.filter { $0.side == .left  }
            let rights0 = art.anchors.filter { $0.side == .right }
            let need = max(stackHeight(lefts0), stackHeight(rights0)) + 24
            let CH = max(H, need)
            let deviceH = min(CH * 0.86, (W - cardW * 2 - 90) / art.aspect)
            let deviceW = deviceH * art.aspect
            let deviceRect = CGRect(x: (W - deviceW) / 2, y: (CH - deviceH) / 2,
                                    width: deviceW, height: deviceH)

            let lefts  = art.anchors.filter { $0.side == .left  }.sorted { $0.pos.y < $1.pos.y }
            let rights = art.anchors.filter { $0.side == .right }.sorted { $0.pos.y < $1.pos.y }
            let ly = layout(lefts, H: CH), ry = layout(rights, H: CH)
            let lx = cardX(.left, W: W, cardW: cardW), rx = cardX(.right, W: W, cardW: cardW)

            ScrollView(.vertical, showsIndicators: CH > H) {
              ZStack(alignment: .topLeading) {
                Path { p in
                    for (i, a) in lefts.enumerated() {
                        connect(&p, from: CGPoint(x: lx + cardW / 2, y: ly[i]),
                                to: DeviceArt.point(a, in: deviceRect))
                    }
                    for (i, a) in rights.enumerated() {
                        connect(&p, from: CGPoint(x: rx - cardW / 2, y: ry[i]),
                                to: DeviceArt.point(a, in: deviceRect))
                    }
                }
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)

                DeviceBody(art: art,
                           bound: Set((profile?.buttons ?? [:]).compactMap { Int($0.key) }),
                           highlighted: pressed ?? hot,
                           liveDir: liveDir)
                    .frame(width: deviceW, height: deviceH)
                    .position(x: deviceRect.midX, y: deviceRect.midY)

                ForEach(Array(lefts.enumerated()), id: \.element.id) { i, a in
                    card(d, a, width: cardW).position(x: lx, y: ly[i])
                }
                ForEach(Array(rights.enumerated()), id: \.element.id) { i, a in
                    card(d, a, width: cardW).position(x: rx, y: ry[i])
                }
              }
              .frame(width: W, height: CH)
            }
        }
    }

    /// 一列卡片堆起来需要多高 (含最小间距)
    private func stackHeight(_ list: [ButtonAnchor]) -> CGFloat {
        guard !list.isEmpty else { return 0 }
        return list.map(height).reduce(0, +) + CGFloat(list.count - 1) * 6
    }

    private let stickCardH: CGFloat = 158

    /// 卡片高度按【实际设了几层】算。三行固定占位的话, 双击长按大多是空的,
    /// 2/3 的高度都在显示"未设置" —— 既浪费空间又让字没法放大。
    private func height(_ a: ButtonAnchor) -> CGFloat {
        // 认所有方向通道, 不是只认主方向 —— 右摇杆的 id 是 -3
        if StickChannel.from(anchorID: a.id) != nil { return stickCardH }
        let b = profile?.binding(button: a.id, app: layer) ?? ButtonBinding()
        var h: CGFloat = 66                                   // 标题 + 单击 + 内边距
        if b.double != nil { h += 26 }
        if b.long   != nil { h += 26 }
        if b.double == nil || b.long == nil { h += 22 }       // L("＋双击") + " " + L("＋长按") 那一行
        return h
    }

    /// position() 定的是卡片【中心】, 所以上下必须各留半张卡, 否则首尾会被切在窗外。
    /// 而且摇杆卡比按键卡高, 不能简单均分 —— 按实际高度依次堆叠再整体居中。
    private func layout(_ list: [ButtonAnchor], H: CGFloat) -> [CGFloat] {
        guard !list.isEmpty else { return [] }
        let heights = list.map(height)
        let total = heights.reduce(0, +)
        let gap = list.count > 1 ? max(6, (H - 12 - total) / CGFloat(list.count - 1)) : 0
        let stack = total + gap * CGFloat(list.count - 1)
        var y = max(heights[0] / 2 + 6, (H - stack) / 2 + heights[0] / 2)
        var out: [CGFloat] = []
        for (i, h) in heights.enumerated() {
            if i > 0 { y += heights[i - 1] / 2 + gap + h / 2 }
            out.append(y)
        }
        return out
    }

    private func slotColor(learned: Bool, hasAction: Bool) -> Color {
        if !learned { return Color.primary.opacity(0.35) }
        return hasAction ? Color.primary : Color.secondary
    }

    private func cardX(_ side: Side, W: CGFloat, cardW: CGFloat) -> CGFloat {
        side == .left ? cardW / 2 + 20 : W - cardW / 2 - 20
    }

    /// 贝塞尔连线: 先横向出卡片, 再拐向按键, 比直线好看且不遮挡
    private func connect(_ p: inout Path, from: CGPoint, to: CGPoint) {
        let dx = (to.x - from.x) * 0.55
        p.move(to: from)
        p.addCurve(to: to,
                   control1: CGPoint(x: from.x + dx, y: from.y),
                   control2: CGPoint(x: to.x - dx, y: to.y))
    }

    // MARK: - 单颗按键的卡片

    @ViewBuilder
    private func card(_ d: ConnectedDevice, _ a: ButtonAnchor, width: CGFloat) -> some View {
        if StickChannel.from(anchorID: a.id) != nil {
            stickCard(d, a, width: width)
        } else {
            buttonCard(d, a, width: width)
        }
    }

    /// 方向卡: 每个通道一张, 和按键卡一样挂在设备图上
    private func stickCard(_ d: ConnectedDevice, _ a: ButtonAnchor, width: CGFloat) -> some View {
        let ch = StickChannel.from(anchorID: a.id) ?? .hat
        let hot = liveDir?.0 == ch
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "dial.min").font(.subheadline)
                Text(a.label).font(.system(.title3, design: .rounded).weight(.bold))
                Spacer()
            }
            // 右摇杆可以整体当鼠标。那种模式下"四个方向各绑什么"是被绕过的,
            // 所以不能再把它们列出来 —— 否则界面显示的和实际行为对不上。
            if ch.isAnalog {
                Picker("", selection: Binding(
                    get: { profile?.stickMode(ch) ?? "keys" },
                    set: { setStickMode(d, ch, $0) })) {
                    Text(L("按方向绑动作")).tag("keys")
                    Text(L("推鼠标")).tag("mouse")
                }
                .pickerStyle(.segmented).labelsHidden().font(.caption)
            }
            if !(ch.isAnalog && profile?.stickMode(ch) == "mouse") {
                ForEach(DeviceProfile.dirKeys, id: \.self) { dir in dirRow(d, ch, dir) }
            } else {
                Text(L("mouseModeHint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(hot ? Color.accentColor : Color.primary.opacity(0.16),
                        lineWidth: hot ? 2 : 1))
    }

    private func setStickMode(_ d: ConnectedDevice, _ ch: StickChannel, _ mode: String) {
        guard let i = ConfigStore.shared.config.devices
            .firstIndex(where: { $0.id == DeviceProfile.key(d.vendorID, d.productID) }) else { return }
        ConfigStore.shared.config.devices[i].stickModes[ch.rawValue] = mode
    }

    private func dirRow(_ d: ConnectedDevice, _ ch: StickChannel, _ dir: String) -> some View {
        let sd = profile?.stickDir(ch, dir)
        let act = profile?.stickAction(ch, dir: dir, app: layer)
        let live = liveDir?.0 == ch && liveDir?.1 == dir
        return HStack(spacing: 6) {
            Image(systemName: StickAnchor.arrow[dir]!)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(live ? Color.accentColor : Color.secondary)
                .frame(width: 32, alignment: .leading)
            Menu {
                if sd != nil {
                    actionMenuItems { setDir(d, ch, dir, $0) }
                } else {
                    Text(L("先点右上角学习「%@」", chLabel(ch)))
                }
            } label: {
                Text(act.flatMap { Actions.byID[$0]?.name } ?? (sd == nil ? L("未学习") : L("未设置")))
                    .font(.subheadline).lineLimit(1)
                    .foregroundStyle(slotColor(learned: sd != nil, hasAction: act != nil))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(act == nil ? .hidden : .visible)
        }
    }

    private func buttonCard(_ d: ConnectedDevice, _ a: ButtonAnchor, width: CGFloat) -> some View {
        let overridden = !layer.isEmpty && (profile?.isOverridden(button: a.id, app: layer) ?? false)
        let b = profile?.binding(button: a.id, app: layer) ?? ButtonBinding()
        let live = pressed == a.id

        return VStack(alignment: .leading, spacing: 4) {
            // 键名是找卡片的锚, 放大到最显眼
            HStack(spacing: 6) {
                Text(a.label)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text("\(a.id)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if !layer.isEmpty {
                    if overridden {
                        Button { clearOverride(d, a.id) } label: {
                            Text(L("覆盖")).font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.accentColor))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain).help(L("点一下恢复继承基础层"))
                    } else {
                        Text(L("↳ 继承")).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }

            // 单击是主动作, 单独一行且字号大
            gestureRow(d, a.id, nil, \.tap, primary: true)

            if b.double != nil { gestureRow(d, a.id, L("双击"), \.double, primary: false) }
            if b.long   != nil { gestureRow(d, a.id, L("长按"), \.long,   primary: false) }

            if b.double == nil || b.long == nil {
                HStack(spacing: 8) {
                    if b.double == nil { addChip(d, a.id, L("双击"), \.double) }
                    if b.long   == nil { addChip(d, a.id, L("长按"), \.long) }
                    Spacer()
                }
            }
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(live ? Color.accentColor
                             : (b.isEmpty ? Color.primary.opacity(0.08)
                                          : Color.primary.opacity(0.16)),
                        lineWidth: live ? 2 : 1))
        .onHover { hot = $0 ? a.id : (hot == a.id ? nil : hot) }
    }

    private func gestureRow(_ d: ConnectedDevice, _ n: Int, _ title: String?,
                            _ path: WritableKeyPath<ButtonBinding, String?>,
                            primary: Bool) -> some View {
        let current = profile?.binding(button: n, app: layer)?[keyPath: path]
        return HStack(spacing: 6) {
            if let title {
                Text(title).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
            }
            Menu {
                actionMenuItems { set(d, n, path, $0) }
            } label: {
                Text(current.flatMap { Actions.byID[$0]?.name } ?? L("未设置"))
                    .font(primary ? .body : .subheadline)
                    .fontWeight(primary ? .medium : .regular)
                    .foregroundStyle(current == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
        }
    }

    /// 未设置的手势收成一个小胶囊, 点开直接选动作 —— 比空着一整行省地方
    private func addChip(_ d: ConnectedDevice, _ n: Int, _ title: String,
                         _ path: WritableKeyPath<ButtonBinding, String?>) -> some View {
        Menu {
            actionMenuItems { set(d, n, path, $0) }
        } label: {
            Text("＋\(title)").font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func row(_ d: ConnectedDevice, _ n: Int, _ title: String,
                     _ path: WritableKeyPath<ButtonBinding, String?>) -> some View {
        let current = profile?.binding(button: n, app: layer)?[keyPath: path]
        return HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            Menu {
                actionMenuItems { set(d, n, path, $0) }
            } label: {
                Text(current.flatMap { Actions.byID[$0]?.name } ?? L("未设置"))
                    .font(.subheadline)
                    .foregroundStyle(current == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(current == nil ? .hidden : .visible)
        }
    }

    // MARK: - 摇杆

    private func setDir(_ d: ConnectedDevice, _ ch: StickChannel,
                        _ dir: String, _ action: String?) {
        mutate(d) { p in
            if layer.isEmpty {
                guard var sd = p.sticks[ch.rawValue]?[dir] else { return }
                sd.action = action
                p.sticks[ch.rawValue]?[dir] = sd
            } else {
                var ov = p.overrides[layer] ?? AppOverride()
                if let action { ov.sticks[ch.rawValue, default: [:]][dir] = action }
                else { ov.sticks[ch.rawValue]?.removeValue(forKey: dir) }
                if ov.isEmpty { p.overrides.removeValue(forKey: layer) } else { p.overrides[layer] = ov }
            }
        }
    }

    // MARK: - 实时输入

    /// 只旁观, 不拦截 —— 按 A 该发的回车照发, 界面只是跟着亮一下
    private func watchPresses() {
        HIDInput.shared.previewOwner = watchToken
        HIDInput.shared.previewHandler = { input in
            DispatchQueue.main.async {
                switch input {
                case .button(let n, let down):
                    pressed = down ? n : nil
                case .hat(let dir, let ch):
                    if let dir, let key = HIDInput.nearestKey(
                        dir, profile?.sticks[ch.rawValue] ?? [:]) {
                        liveDir = (ch, key)
                    } else if liveDir?.0 == ch {
                        liveDir = nil
                    }
                }
            }
        }
    }

    private func stopWatching() {
        // 只清自己装的 —— 见 HIDInput.previewOwner 的注释
        if HIDInput.shared.previewOwner == watchToken {
            HIDInput.shared.previewHandler = nil
            HIDInput.shared.previewOwner = nil
        }
        HIDInput.shared.captureHandler = nil
    }

    /// 学习摇杆期间才拦截, 结束立刻还回去
    private func beginStick(_ d: ConnectedDevice, _ ch: StickChannel) {
        stickStep = 0
        learningCh = ch
        mutate(d) { $0.sticks[ch.rawValue] = [:] }
        learningStick = true
        HIDInput.shared.captureHandler = { input in
            DispatchQueue.main.async {
                guard case .hat(let dir, let ch) = input, let dir, ch == learningCh,
                      stickStep < stickWizard.count else { return }
                let w = stickWizard[stickStep]
                let cur = profile?.sticks[ch.rawValue] ?? [:]
                // 同一个方向值不能学两次, 否则两个方向会打架
                guard !cur.values.contains(where: { $0.hat == dir }) else { return }
                mutate(d) { $0.sticks[ch.rawValue, default: [:]][w.0] = StickDir(hat: dir, action: w.1) }
                stickStep += 1
                if stickStep >= stickWizard.count { endStick() }
            }
        }
    }

    private func endStick() {
        learningStick = false
        HIDInput.shared.captureHandler = nil
    }

    // MARK: - 配置读写

    /// 当前层的菜单该怎么分组。
    /// 整组都用不了的收进「其它 app 专属」, 不占顶层位置 ——
    /// 在 Claude Code 层顶着一个「Chrome」组是纯噪音。
    /// 基础层不做收拢: 基础层对所有 app 生效, 绑个 app 专属动作是合理的。
    private var groupSplit: (primary: [String], other: [String]) {
        let all = Actions.groups
        guard !layer.isEmpty else { return (all, []) }
        var primary: [String] = [], other: [String] = []
        for g in all {
            if Actions.all.filter({ $0.group == g }).contains(where: available) {
                primary.append(g)
            } else {
                other.append(g)
            }
        }
        // 当前 app 自己的组排最前, 最常用的放最近
        let own = primary.filter { g in
            Actions.all.first { $0.group == g }?.onlyIn == layer
        }
        return (own + primary.filter { !own.contains($0) }, other)
    }

    @ViewBuilder
    private func actionMenuItems(_ pick: @escaping (String?) -> Void) -> some View {
        let split = groupSplit
        Button(L("未设置")) { pick(nil) }
        ForEach(split.primary, id: \.self) { g in
            Menu(g) {
                ForEach(Actions.all.filter { $0.group == g }) { act in
                    Button(actionLabel(act)) { pick(act.id) }
                        .disabled(!available(act))
                }
            }
        }
        if !split.other.isEmpty {
            Menu(L("其它 app 专属（本层无效）")) {
                ForEach(split.other, id: \.self) { g in
                    Menu(g) {
                        ForEach(Actions.all.filter { $0.group == g }) { act in
                            Button(act.name) { }.disabled(true)
                        }
                    }
                }
            }
        }
    }

    /// 动作在当前层是否有效。无效的不隐藏, 只置灰并标注 ——
    /// 隐藏会让人以为功能没了。
    private func available(_ a: ActionDef) -> Bool {
        guard let only = a.onlyIn else { return true }
        return layer.isEmpty || layer == only
    }

    private func actionLabel(_ a: ActionDef) -> String {
        guard let only = a.onlyIn, !available(a) else { return a.name }
        return L("%@（仅 %@）", a.name, AppName.of(only))
    }

    private func clearOverride(_ d: ConnectedDevice, _ n: Int) {
        mutate(d) { p in
            p.overrides[layer]?.buttons.removeValue(forKey: String(n))
            if p.overrides[layer]?.isEmpty == true { p.overrides.removeValue(forKey: layer) }
        }
    }

    private func set(_ d: ConnectedDevice, _ n: Int,
                     _ path: WritableKeyPath<ButtonBinding, String?>, _ v: String?) {
        mutate(d) { p in
            if layer.isEmpty {
                p.buttons[String(n), default: .init()][keyPath: path] = v
            } else {
                // 首次覆盖: 先把基础层这颗键整个拷过来, 再改 ——
                // 覆盖以整颗按键为单位, 不做按手势继承
                var ov = p.overrides[layer] ?? AppOverride()
                var b = ov.buttons[String(n)] ?? p.buttons[String(n)] ?? ButtonBinding()
                b[keyPath: path] = v
                ov.buttons[String(n)] = b
                p.overrides[layer] = ov
            }
        }
    }

    private func mutate(_ d: ConnectedDevice, _ body: (inout DeviceProfile) -> Void) {
        if !store.config.devices.contains(where: { $0.id == d.id }) {
            store.config.devices.append(
                DeviceProfile(vendorID: d.vendorID, productID: d.productID, name: d.name))
        }
        guard let i = store.config.devices.firstIndex(where: { $0.id == d.id }) else { return }
        body(&store.config.devices[i])
        store.save()
    }
}
