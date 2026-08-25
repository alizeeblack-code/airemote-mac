import SwiftUI
import AppKit

/// 设置窗口当前在哪一页。菜单栏的状态项要能直接跳到对应页面,
/// 所以选中项得放在外面, 不能藏在 TabView 内部。
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    enum Tab: Hashable { case controller, apps, general, voice, remote }
    @Published var tab: Tab = .controller
}

struct SettingsView: View {
    @ObservedObject private var nav = SettingsNav.shared

    var body: some View {
        TabView(selection: $nav.tab) {
            ControllerView().tabItem { Label(L("手柄"), systemImage: "gamecontroller") }
                .tag(SettingsNav.Tab.controller)
            AppsView().tabItem { Label(L("App"), systemImage: "square.grid.2x2") }
                .tag(SettingsNav.Tab.apps)
            VoiceView().tabItem { Label(L("语音听写"), systemImage: "mic") }
                .tag(SettingsNav.Tab.voice)
            RemoteView().tabItem { Label(L("手机遥控"), systemImage: "iphone") }
                .tag(SettingsNav.Tab.remote)
            GeneralView().tabItem { Label(L("通用"), systemImage: "gearshape") }
                .tag(SettingsNav.Tab.general)
        }
        .frame(minWidth: 1040, minHeight: 680)
    }
}

// MARK: - 手柄 (图形/表格 两视图)

/// 映射编辑(画布)和映射总表是**同一份数据的两个视图**, 以前分居两个标签页,
/// 名字("按键映射"/"总览")还都在说映射, 点哪个全凭猜。合成一页, 顶栏分段
/// 控件切换; 两个视图本体不动, 只换这层壳。
enum ControllerMode: String { case canvas, table }

struct ControllerView: View {
    /// 窗口存续期间记住停在哪个视图; 不跨启动持久, 没这个必要
    @State private var mode: ControllerMode = .canvas
    /// 选中的手柄放在壳里 —— 两个视图共用, 在一边切了手柄切到另一边还是它。
    /// 以前它是 MappingView 的私有 @State, 表格视图压根没有这个概念, 永远
    /// 只显示第一只手柄。
    @State private var selectedID: String?

    var body: some View {
        if mode == .canvas {
            MappingView(mode: $mode, selectedID: $selectedID)
        } else {
            OverviewView(mode: $mode, selectedID: $selectedID)
        }
    }
}

/// 两个视图的顶栏里都放同一个切换器, 位置一致才不用来回找
struct ControllerModePicker: View {
    @Binding var mode: ControllerMode
    var body: some View {
        Picker("", selection: $mode) {
            Text(L("图形")).tag(ControllerMode.canvas)
            Text(L("表格")).tag(ControllerMode.table)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - App

/// 生效的 app + 每个 app 的键位档案。
///
/// 白名单原来埋在「通用」第三节, 但它是三处功能的数据源(总览的列、遥控
/// 四角、档案), 新用户第一天就得配, 不是"不常动的系统偏好"。档案入口
/// 原来只有总览的**列头可点**, 隐蔽到基本发现不了 —— 在这里每行都是
/// 一等入口。
private struct AppBox: Identifiable { let id: String }

struct AppsView: View {
    @ObservedObject var store = ConfigStore.shared
    @State private var newApp = ""
    @State private var editing: String?

    var body: some View {
        Form {
            Section(L("生效的 app")) {
                Toggle(L("只在下列 app 里响应通用按键"), isOn: $store.config.restrictToTargets)
                Text(L("whitelistHint"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(L("点某一行，编辑这个 app 里各动作发什么快捷键"))
                    .font(.caption).foregroundStyle(.secondary)

                List {
                    ForEach(store.config.targetApps, id: \.self) { b in
                        HStack(spacing: 8) {
                            Button { editing = b } label: {
                                HStack(spacing: 8) {
                                    if let icon = NSWorkspace.shared
                                        .urlForApplication(withBundleIdentifier: b)
                                        .map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
                                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                                    }
                                    Text(AppName.of(b))
                                    if AppProfiles.builtin[b] != nil {
                                        Label(L("预置"), systemImage: "checkmark.seal.fill")
                                            .font(.caption).foregroundStyle(.green)
                                            .labelStyle(.iconOnly)
                                            .help(L("有内置的快捷键预置"))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                store.config.targetApps.removeAll { $0 == b }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(height: 220)

                let sug = AppProfiles.suggestions(
                    installed: { NSWorkspace.shared
                        .urlForApplication(withBundleIdentifier: $0) != nil },
                    whitelist: store.config.targetApps)
                if !sug.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("这些已装的 app 有现成的快捷键预置，点一下加进来："))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(sug, id: \.self) { b in
                                Button {
                                    store.config.targetApps.append(b)
                                } label: {
                                    HStack(spacing: 5) {
                                        if let icon = NSWorkspace.shared
                                            .urlForApplication(withBundleIdentifier: b)
                                            .map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
                                            Image(nsImage: icon).resizable()
                                                .frame(width: 16, height: 16)
                                        }
                                        Text(AppName.of(b)).font(.callout)
                                    }
                                }
                            }
                            Spacer()
                        }
                    }
                    .padding(.vertical, 2)
                }

                HStack {
                    TextField(L("bundle ID，例如 md.obsidian"), text: $newApp)
                    Button(L("添加")) {
                        let t = newApp.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty && !store.config.targetApps.contains(t) {
                            store.config.targetApps.append(t)
                        }
                        newApp = ""
                    }
                    Button(L("选 app…")) { pickApp() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(item: Binding(
            get: { editing.map { AppBox(id: $0) } },
            set: { editing = $0?.id })) { box in
            ProfilesView(app: box.id) { editing = nil }
        }
    }

    private func pickApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let url = p.url,
              let b = Bundle(url: url)?.bundleIdentifier else { return }
        if !store.config.targetApps.contains(b) { store.config.targetApps.append(b) }
    }
}

// MARK: - 通用

struct GeneralView: View {
    @ObservedObject var store = ConfigStore.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var hasAX = KeySynth.hasAccessibility

    var body: some View {
        Form {
            Section(L("权限")) {
                HStack {
                    Label(hasAX ? L("辅助功能已授权") : L("辅助功能未授权"),
                          systemImage: hasAX ? "checkmark.shield.fill"
                                             : "exclamationmark.shield.fill")
                        .foregroundStyle(hasAX ? Color.green : Color.orange)
                    Spacer()
                    if !hasAX {
                        Button(L("去授权")) { KeySynth.openAccessibilityPane() }
                    }
                    Button(L("重启 JoyCoding")) { KeySynth.relaunch() }
                        .help(L("axGranted"))
                }
                // 已授权就不再占一行说明, 只在没授权时讲怎么做
                if !hasAX {
                    Text(L("axHowto"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L("偏好")) {
                Toggle(L("开机自动启动"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        LaunchAtLogin.set(on)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }))
                    .help(LaunchAtLogin.statusText)

                Picker(L("界面语言"), selection: $store.config.language) {
                    Text(L("跟随系统")).tag("auto")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                .pickerStyle(.segmented)
                .help(L("langHint"))

                Picker(L("界面主题"), selection: $store.config.appearance) {
                    Text(L("跟随系统")).tag("system")
                    Text(L("浅色")).tag("light")
                    Text(L("深色")).tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: store.config.appearance) { Appearance.apply($0) }

                Toggle(L("菜单栏显示手柄电量"), isOn: $store.config.showBatteryInMenuBar)
                    .help(L("关掉就只留一个手柄图标，电量仍可在菜单里和设置页看到。"))
            }

        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            hasAX = KeySynth.hasAccessibility
        }
        // 用户可能开着这个页面去系统设置勾选, 回来时要能看到变化
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            hasAX = KeySynth.hasAccessibility
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

}

// MARK: - 语音

struct VoiceView: View {
    @ObservedObject var store = ConfigStore.shared
    @State private var testing = false
    @State private var testLeft = 0

    /// 走 Actions 的真实 PTT 路径, 不另写一份 —— 否则测的就不是实际会发生的事
    private func runTest() {
        guard !testing else { return }
        testing = true
        testLeft = 2
        Actions.pttStart()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            testLeft -= 1
            if testLeft <= 0 {
                t.invalidate()
                // "按一下开始, 再按一下停止"模式里 pttStop 是故意不做事的
                // (靠下一次按下来停)。测试必须自己收尾, 不能把听写一直开着。
                if ConfigStore.shared.config.pttStyle == "tap" {
                    Actions.pttStart()
                } else {
                    Actions.pttStop()
                }
                testing = false
            }
        }
    }

    var body: some View {
        Form {
            Section(L("触发方式")) {
                Picker(L("模式"), selection: $store.config.pttStyle) {
                    Text(L("按住录，松开出字")).tag("hold")
                    Text(L("按一下开始，再按一下停止")).tag("tap")
                    Text(L("按住说话（底层 toggle）")).tag("toggle")
                }
                .pickerStyle(.radioGroup)

                Text(L("pttStyleHint"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Section(L("发给听写工具的热键")) {
                HStack {
                    Picker(L("按键"), selection: $store.config.pttKey) {
                    Text(L("左 Control")).tag("ctrl")
                    Text(L("右 Control")).tag("rightctrl")
                    Text(L("左 Option")).tag("alt")
                    Text(L("右 Option")).tag("rightalt")
                    Text("Fn").tag("fn")
                        Text(L("D（配合下面的修饰键）")).tag("d")
                    }
                    Spacer()
                    // 键对不对是看不出来的, 只能试。按一下就知道听写有没有起来。
                    Button(testing ? L("测试中… %@", String(testLeft)) : L("测试")) { runTest() }
                        .disabled(testing)
                }
                Text(L("pttKeyHint"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(L("pttTestHint"))
                    .font(.caption).foregroundStyle(.secondary)

                let apps = DictationApps.installed()
                if !apps.isEmpty {
                    Label(L("pttInstalledHint", apps.joined(separator: "、")),
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L("保险丝")) {
                HStack {
                    Text(L("按住超过"))
                    TextField("", value: $store.config.pttMaxHold, format: .number)
                        .frame(width: 60)
                    Text(L("秒强制松开"))
                }
                Text(L("pttFuseHint"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 手机遥控

struct RemoteView: View {
    @ObservedObject var store = ConfigStore.shared
    @ObservedObject var http = HTTPServer.shared

    /// 每次渲染重新枚举 —— 用户可能刚插网线或切了 Wi-Fi
    private var addresses: [NetAddress] { NetAddresses.all() }

    private var current: NetAddress? {
        NetAddresses.resolve(preferred: store.config.remoteAddress)
    }

    private var lanURL: String {
        "http://\(current?.ip ?? "127.0.0.1"):\(store.config.httpPort)/\(store.config.httpToken)/"
    }

    private var baseURL: String {
        "http://\(current?.ip ?? "127.0.0.1"):\(store.config.httpPort)/"
    }

    private var cornerApps: [String] {
        let c = store.config.remoteCorners
        if !c.isEmpty { return c + Array(repeating: "", count: max(0, 4 - c.count)) }
        let auto = Array(store.config.targetApps.prefix(4))
        return auto + Array(repeating: "", count: max(0, 4 - auto.count))
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("启用手机遥控"), isOn: $store.config.httpEnabled)
                    .onChange(of: store.config.httpEnabled) { _ in http.restart() }
                HStack {
                    Text(L("状态"))
                    Spacer()
                    if !store.config.httpEnabled {
                        Text(L("已关闭")).foregroundStyle(.secondary)
                    } else if http.running {
                        Label(L("监听中 :%@", String(store.config.httpPort)), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label(http.lastError ?? L("未监听"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section(L("配对")) {
                if current == nil {
                    // 静默回落成 127.0.0.1 的话, 二维码照样生成但手机连不上,
                    // 而且看不出是为什么 —— 所以这里必须说清楚
                    Label(L("noLanAddr"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                HStack(alignment: .top, spacing: 20) {
                    if current != nil, let qr = QRCode.image(baseURL, size: 150) {
                        Image(nsImage: qr)
                            .interpolation(.none)          // 二维码不能插值, 会糊
                            .resizable().frame(width: 150, height: 150)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("用手机相机扫码，或在浏览器打开："))
                            .font(.subheadline).foregroundStyle(.secondary)
                        // 一个地址时没什么可选的, 不拿下拉去占地方
                        if addresses.count > 1 {
                            Picker(L("地址"), selection: $store.config.remoteAddress) {
                                ForEach(addresses) { a in Text(a.label).tag(a.ip) }
                            }
                            .labelsHidden().frame(maxWidth: 260)
                        }
                        Text(baseURL)
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        if addresses.count > 1 {
                            Toggle(L("只监听选中的这个地址"), isOn: Binding(
                                get: { store.config.httpInterface == "selected" },
                                set: { store.config.httpInterface = $0 ? "selected" : "all" }))
                                .onChange(of: store.config.httpInterface) { _ in http.restart() }
                                .help(L("ifaceHint"))
                        }
                        Divider()
                        Text(L("配对码")).font(.subheadline).foregroundStyle(.secondary)
                        Text(store.config.pairCode)
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .kerning(6).textSelection(.enabled)
                        Text(L("只需输一次，之后这台手机会被记住"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack {
                    Button(L("复制地址")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(baseURL, forType: .string)
                    }
                    Button(L("重新生成配对码")) {
                        store.config.pairCode = ConfigStore.randomPairCode()
                        store.config.httpToken = ConfigStore.randomToken()   // 让已配对的手机失效
                        http.restart()
                    }
                    .help(L("已配对的手机需要重新配对"))
                }
            }

            Section(L("四角直达键")) {
                Text(L("对应手机遥控界面圆盘四周的四个 app 图标"))
                    .font(.caption).foregroundStyle(.secondary)
                // 四角只能从白名单里选 —— 名单空着的话四个下拉全是空的,
                // 而且从这页完全看不出该去哪加, 必须给出口
                if store.config.targetApps.isEmpty {
                    HStack {
                        Text(L("这里从「App」页的列表里选——列表还是空的"))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button(L("去 App 页")) { SettingsNav.shared.tab = .apps }
                    }
                } else {
                    Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow { cornerPicker(0); cornerPicker(1) }
                        GridRow { cornerPicker(2); cornerPicker(3) }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Text(L("remoteWarn"))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// 一个角的选择器。只列白名单里的 app —— 切过去之后按键才是有效的。
    private func cornerPicker(_ i: Int) -> some View {
        let cur = cornerApps.indices.contains(i) ? cornerApps[i] : ""
        return Picker([L("左上"), L("右上"), L("左下"), L("右下")][i], selection: Binding(
            get: { cur },
            set: { newValue in
                var c = cornerApps
                while c.count < 4 { c.append("") }
                c[i] = newValue
                store.config.remoteCorners = c
            })) {
            Text(L("不设置")).tag("")
            ForEach(store.config.targetApps, id: \.self) { b in
                Text(AppName.of(b)).tag(b)
            }
        }
        .frame(maxWidth: .infinity)
    }

}
