import SwiftUI
import AppKit

private struct IDBox: Identifiable { let id: String }

/// 表格分节。锚点声明里不加字段 —— 全部 label 一共 29 个, 查表比给
/// 五套外观图 30 多个锚点逐个标注省得多, 也只有一处要维护。
private enum AnchorGroup: Int, CaseIterable {
    case shoulders, face, dpad, system

    var title: String {
        switch self {
        case .shoulders: return L("肩键与扳机")
        case .face:      return L("面键")
        case .dpad:      return L("十字键")
        case .system:    return L("系统键")
        }
    }

    static func of(_ label: String) -> AnchorGroup {
        switch label {
        case "L", "R", "ZL", "ZR", "L1", "L2", "R1", "R2", "SL", "SR":
            return .shoulders
        case "A", "B", "X", "Y", "□", "△", "○", "✕":
            return .face
        case "←", "↑", "→", "↓":
            return .dpad
        default:                         // + − ⌂ Create Options PS ◉ …
            return .system
        }
    }
}

/// 表格视图: 左侧选层(基础层或某个 app 的覆盖层), 右侧一张
/// 按键 × (单击/双击/长按) 的表。
///
/// 之前是 按键 × app 的矩阵, 三种触发挤在一个格子里堆叠, 导出还只导单击 ——
/// 而 ButtonBinding 本来就是 tap/double/long 三个槽位, 这张表只是把模型
/// 本来的形状画出来。跨 app 对比弱化为左侧角标(哪层覆盖了几颗键),
/// ↳ 表示沿用基础层。
struct OverviewView: View {
    /// 图形/表格切换 —— 壳(ControllerView)持有
    @Binding var mode: ControllerMode
    /// 选中的手柄。和图形视图共用一份 —— 在一边切了手柄, 切到另一边还是它
    @Binding var selectedID: String?
    @ObservedObject var store = ConfigStore.shared
    @ObservedObject var hid = HIDInput.shared
    @ObservedObject var batt = JoyConBattery.shared

    /// 当前查看的层。"" = 基础层, 否则是 app 的 bundleID
    @State private var layer = ""
    /// 打开某个 app 的键位档案 sheet
    @State private var editingProfile: String?
    /// 手柄上真按下的键 / 推的方向, 实时点亮所在行
    @State private var pressed: Int?
    @State private var liveDir: (StickChannel, String)?
    /// previewHandler 的认领凭据(见 HIDInput.previewOwner)
    @State private var watchToken = UUID()

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

    /// 表里列出的按键: 有外观图就列**全部**锚点(没绑的显示 "—", 让人看见
    /// 这颗键存在且空着); 没外观图退回"只列绑过的", 用编号当名字。
    private var anchors: [ButtonAnchor] {
        // 摇杆方向是虚拟锚点(id 用负数和真实按键错开), 它不是一颗按键 ——
        // 漏进来就会多出一行 "摇杆方向 -1 —", 而真正的方向在下面的分节里。
        // 画布那边同样把它们排除在按键之外。
        if let a = art { return a.anchors.filter { StickChannel.from(anchorID: $0.id) == nil } }
        guard let p = profile else { return [] }
        var ids = Set(p.buttons.keys.compactMap(Int.init))
        for (_, o) in p.overrides { ids.formUnion(o.buttons.keys.compactMap(Int.init)) }
        return ids.sorted().map {
            ButtonAnchor(id: $0, label: L("按键 %@", String($0)), pos: .zero,
                         size: .zero, shape: .circle, side: .left)
        }
    }

    private func anchors(in g: AnchorGroup) -> [ButtonAnchor] {
        anchors.filter { AnchorGroup.of($0.label) == g }
    }

    /// 通道在这只手柄上叫什么。
    ///
    /// ⚠️ 不能写成 `ch == .hat ? 主方向 : 右摇杆` —— 通道有 hat/left/right
    /// **三个**, 那么写会把 Pro 手柄的左摇杆也标成"右摇杆"(于是表里出现两个
    /// 右摇杆)。优先用外观图锚点上的名字, 比枚举的通用名更准: 同样是 hat,
    /// Pro 上是十字键、Joy-Con 上是摇杆。
    private func chLabel(_ ch: StickChannel) -> String {
        art?.anchors.first { $0.id == ch.anchorID }?.label ?? ch.label
    }

    /// 这只手柄**实际拥有**且学过方向的通道。
    ///
    /// 只按 profile 里有没有数据来判断是不够的: 配置换过手柄、或早期版本
    /// 把十字键和左摇杆合流时留下的数据都会残留, 于是单只 Joy-Con(只有一颗
    /// 摇杆)也会列出"右摇杆"四行。以外观图声明的通道为准 —— 画布那边
    /// 一直是这么判断的。
    private var channels: [StickChannel] {
        let owned: [StickChannel] = art.map { a in
            a.anchors.compactMap { StickChannel.from(anchorID: $0.id) }
        } ?? [.hat]
        return owned.filter { !(profile?.sticks[$0.rawValue]?.isEmpty ?? true) }
    }

    /// 某层的角标: 覆盖了多少颗键(按键 + 摇杆方向)
    private func overrideCount(_ app: String) -> Int {
        guard let o = profile?.overrides[app] else { return 0 }
        return o.buttons.count + o.sticks.values.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if profile == nil {
                Spacer()
                Text(L("连上手柄后这里会列出全部映射")).foregroundStyle(.secondary)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    table
                }
            }
        }
        .onAppear { watchPresses() }
        .onDisappear {
            // 只清自己装的 —— 见 HIDInput.previewOwner 的注释
            if HIDInput.shared.previewOwner == watchToken {
                HIDInput.shared.previewHandler = nil
                HIDInput.shared.previewOwner = nil
            }
        }
        // 白名单变了要防呆: 选中的层被删掉就回基础层
        .onChange(of: store.config.targetApps) { apps in
            if !layer.isEmpty && !apps.contains(layer) { layer = "" }
        }
        .sheet(item: Binding(
            get: { editingProfile.map { IDBox(id: $0) } },
            set: { editingProfile = $0?.id })) { box in
            ProfilesView(app: box.id) { editingProfile = nil }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 10) {
            ControllerModePicker(mode: $mode)
            Divider().frame(height: 16)
            // 多只手柄时这里要能切 —— 图形页一直有这个下拉, 表格页漏了,
            // 于是接两只手柄时表格永远只显示第一只
            if hid.devices.count > 1 {
                Picker("", selection: Binding(
                    get: { selectedID ?? hid.devices.first?.id ?? "" },
                    set: { selectedID = $0 })) {
                    ForEach(hid.devices) { d in Text(d.name).tag(d.id) }
                }
                .labelsHidden().frame(maxWidth: 240)
            } else {
                Text(device?.name ?? L("没有手柄"))
                    .font(.title3.weight(.semibold))
            }
            if device != nil {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
            // 电量。图形页顶栏一直有, 表格页漏了 —— 两边都是"看这只手柄"的
            // 地方, 没道理切过来就不见了。
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
            Spacer()
            if !layer.isEmpty {
                Button(L("键位档案…")) { editingProfile = layer }
                    .help(L("查看 / 修改这个 app 的快捷键"))
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown(), forType: .string)
            } label: { Label(L("复制为表格"), systemImage: "doc.on.doc") }
                .disabled(profile == nil)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - 左侧: 层列表

    private var sidebar: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                deviceCard
                Text(L("层")).font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                layerRow("", title: L("基础"), icon: nil)
                ForEach(store.config.targetApps, id: \.self) { app in
                    layerRow(app, title: AppName.of(app), icon: appIcon(app))
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
        .frame(width: 260)
    }

    /// 手柄缩略图 + 当前按下那颗键是什么。
    ///
    /// 复用画布那套 DeviceBody(它本来就是独立 View), 传同一个 highlighted ——
    /// 于是按一下手柄, 图上的键和表格里的行**同时亮**, 不用在两个视图之间
    /// 来回对照才能认出这颗键叫什么。
    /// 缩略图卡片尺寸。Joy-Con 细高(aspect 0.355)会得到 90×254,
    /// Pro/PS 扁宽会撞宽度上限得到 244×168 —— 卡片外框都是 254 高。
    private let cardH: CGFloat = 254
    private let cardMaxW: CGFloat = 244

    @ViewBuilder
    private var deviceCard: some View {
        if let art {
            VStack(alignment: .leading, spacing: 8) {
                // 卡片高度固定, 设备等比装进去(aspect-fit)。
                //
                // **不能只定宽度**: Joy-Con 的 aspect 是 0.355, 228 宽算出来
                // 642pt 高, 直接把层列表挤出屏幕。也不能只定高度: Pro 手柄
                // 会超出侧栏宽度。所以两边都设上限, 取能装下的那个。
                // 卡片本身高度写死 —— 换手柄时层列表位置不动。
                let w = min(cardMaxW, cardH * art.aspect)
                DeviceBody(art: art,
                           bound: Set((profile?.buttons ?? [:]).compactMap { Int($0.key) }),
                           highlighted: pressed,
                           liveDir: liveDir)
                    .frame(width: w, height: w / art.aspect)
                    .frame(maxWidth: .infinity)
                    .frame(height: cardH)
                    .background(Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                // 按下时说明这颗键是什么。没按时留一行占位, 否则整个侧栏会
                // 随按键上下跳。
                HStack(spacing: 6) {
                    if let id = pressed,
                       let a = art.anchors.first(where: { $0.id == id }) {
                        Text(a.label)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        Text(currentAction(id).map(name) ?? L("未绑定"))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(L("按一下手柄，这里会显示是哪颗键"))
                            .font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(height: 18)
                .padding(.horizontal, 2)
            }
            .padding(.top, 10)
        }
    }

    /// 某颗键在当前层的单击动作(含继承)
    private func currentAction(_ id: Int) -> String? {
        layer.isEmpty ? profile?.buttons[String(id)]?.tap
                      : profile?.binding(button: id, app: layer)?.tap
    }

    private func layerRow(_ id: String, title: String, icon: NSImage?) -> some View {
        let on = layer == id
        let count = id.isEmpty ? 0 : overrideCount(id)
        return Button { layer = id } label: {
            HStack(spacing: 7) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 17, height: 17)
                } else {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(on ? .white : Color.accentColor)
                        .frame(width: 17)
                }
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? .white : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(on ? Color.white
                                                      : Color.primary.opacity(0.08)))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(on ? Color.accentColor : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func appIcon(_ b: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: b)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    // MARK: - 右侧: 表格

    private var table: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                columnHeader
                Divider()
                ForEach(AnchorGroup.allCases, id: \.rawValue) { g in
                    let list = anchors(in: g)
                    if !list.isEmpty {
                        sectionHeader(g.title)
                        ForEach(list) { a in buttonRow(a) }
                    }
                }
                if !channels.isEmpty {
                    sectionHeader(L("摇杆方向"))
                    ForEach(channels, id: \.self) { ch in
                        ForEach(DeviceProfile.dirKeys, id: \.self) { dir in
                            stickRow(ch, dir)
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text(L("按键")).frame(width: 150, alignment: .leading)
            Text(L("单击")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("双击")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("长按")).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
    }

    private func buttonRow(_ a: ButtonAnchor) -> some View {
        let base = profile?.buttons[String(a.id)]
        let eff  = layer.isEmpty ? base : profile?.binding(button: a.id, app: layer)
        let ov   = layer.isEmpty ? true
                 : (profile?.isOverridden(button: a.id, app: layer) ?? false)
        return row(highlight: pressed == a.id) {
            HStack(spacing: 5) {
                Text(a.label)
                    .font(.system(.body, design: .rounded).weight(.medium))
                Text("\(a.id)").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(width: 150, alignment: .leading)
            // 覆盖以整颗按键为单位, 所以"恢复继承"三列给同一个动作
            let clear: (() -> Void)? = (!layer.isEmpty && ov) ? {
                guard let d = device else { return }
                BindingEditor(device: d, layer: layer).clearOverride(a.id)
            } : nil
            slot(eff?.tap,    inherited: !ov, clearOverride: clear) { write(a.id, \.tap,    $0) }
            slot(eff?.double, inherited: !ov, clearOverride: clear) { write(a.id, \.double, $0) }
            slot(eff?.long,   inherited: !ov, clearOverride: clear) { write(a.id, \.long,   $0) }
        }
    }

    private func write(_ n: Int, _ path: WritableKeyPath<ButtonBinding, String?>,
                       _ v: String?) {
        guard let d = device else { return }
        BindingEditor(device: d, layer: layer).set(n, path, v)
    }

    private func stickRow(_ ch: StickChannel, _ dir: String) -> some View {
        let base = profile?.stickDir(ch, dir)?.action
        let eff  = layer.isEmpty ? base : profile?.stickAction(ch, dir: dir, app: layer)
        let ov   = layer.isEmpty ? true
                 : (profile?.isOverridden(ch, dir: dir, app: layer) ?? false)
        let hot  = liveDir?.0 == ch && liveDir?.1 == dir
        return row(highlight: hot) {
            HStack(spacing: 4) {
                Image(systemName: StickAnchor.arrow[dir]!)
                    .font(.system(size: 11, weight: .bold))
                Text(chLabel(ch)).font(.body)
            }
            .frame(width: 150, alignment: .leading)
            slot(eff, inherited: !ov) { v in
                guard let d = device else { return }
                BindingEditor(device: d, layer: layer).setDir(ch, dir, v)
            }
            // 摇杆方向只有单击语义, 另外两列留空
            Text("").frame(maxWidth: .infinity)
            Text("").frame(maxWidth: .infinity)
        }
    }

    private func row(highlight: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        // alignment 必须显式 .leading —— VStack 默认居中, 一旦某行内容没撑满
        // 整行宽度, 整排就会被推到中间去
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 7)
            Divider().opacity(0.4)
        }
        .background(highlight ? Color.accentColor.opacity(0.14) : .clear)
    }

    /// 一格 —— **可点可改**。继承基础层的显示 ↳ 浅色; 该 app 没有对应快捷键
    /// 的动作显示 "—"(显示成"↳ 继承"会让人以为它能用)。
    ///
    /// 菜单项和写入都走 BindingEditor / ActionMenuItems, 和图形页同一份实现:
    /// 覆盖层"首次改动要把基础层整颗键拷过来"的语义只有一处, 不会两边跑偏。
    @ViewBuilder
    private func slot(_ action: String?, inherited: Bool,
                      clearOverride: (() -> Void)? = nil,
                      apply: @escaping (String?) -> Void) -> some View {
        let unsupported = unsupported(action)
        let s = action.map(name) ?? "—"
        Menu {
            ActionMenuItems(layer: layer, pick: apply)
            // "未设置"是**显式解绑**(这颗键在这个 app 里什么都不干),
            // 和"回到继承基础层"是两回事。只有已经覆盖过才给这项。
            if let clearOverride {
                Divider()
                Button(L("恢复继承基础层"), action: clearOverride)
            }
        } label: {
            Text(unsupported ? "—" : (inherited && action != nil ? "↳ " + s : s))
                .font(.body)
                .foregroundStyle(action == nil || unsupported
                                 ? Color.secondary.opacity(0.35)
                                 : (inherited ? Color.secondary.opacity(0.7) : Color.primary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())      // 整格可点, 不只是文字那几个像素
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // ⚠️ 这行不能少。.borderlessButton 的 Menu **按内容取固有宽度**,
        // 上面那个 maxWidth 加在 label 的 Text 上, 管不到 Menu 自己 ——
        // 少了它三列会缩成内容宽, 挤在一起且对不上表头。
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(device == nil)
        .help(unsupported ? L("这个 app 没有对应的快捷键，按下去不会有反应")
                          : L("点一下改这个动作"))
    }

    private func unsupported(_ action: String?) -> Bool {
        guard let action, !layer.isEmpty,
              AppProfiles.configurable.contains(action) else { return false }
        guard let spec = AppProfiles.key(action, app: layer) else { return true }
        return spec.raw.isEmpty
    }

    private func name(_ id: String) -> String { Actions.byID[id]?.name ?? id }

    // MARK: - 实时高亮

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

    // MARK: - 导出

    /// 当前层导出成 Markdown。全空的行不导 —— 表是给人看的, 不是快照。
    private func markdown() -> String {
        guard let p = profile else { return "" }
        let title = layer.isEmpty ? L("基础层") : AppName.of(layer)
        var out = "**\(title)**\n\n"
        out += "| " + [L("按键"), L("单击"), L("双击"), L("长按")].joined(separator: " | ") + " |\n"
        out += "|---|---|---|---|\n"
        for a in anchors {
            let b = layer.isEmpty ? p.buttons[String(a.id)]
                                  : p.binding(button: a.id, app: layer)
            guard let b, !b.isEmpty else { continue }
            let cells = [b.tap, b.double, b.long].map { $0.map(name) ?? "—" }
            out += "| \(a.label) | " + cells.joined(separator: " | ") + " |\n"
        }
        for ch in channels {
            let prefix = chLabel(ch)
            for dir in DeviceProfile.dirKeys {
                let act = layer.isEmpty ? p.stickDir(ch, dir)?.action
                                        : p.stickAction(ch, dir: dir, app: layer)
                guard let act else { continue }
                let arrow = ["up": "↑", "down": "↓", "left": "←", "right": "→"][dir]!
                out += "| \(prefix)\(arrow) | \(name(act)) | — | — |\n"
            }
        }
        return out
    }
}
