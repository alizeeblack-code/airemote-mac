import SwiftUI
import AppKit

/// 设置窗口当前在哪一页。菜单栏的状态项要能直接跳到对应页面,
/// 所以选中项得放在外面, 不能藏在 TabView 内部。
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    enum Tab: Hashable { case mapping, overview, general, voice, remote }
    @Published var tab: Tab = .mapping
}

struct SettingsView: View {
    @ObservedObject private var nav = SettingsNav.shared

    var body: some View {
        TabView(selection: $nav.tab) {
            MappingView().tabItem { Label("按键映射", systemImage: "gamecontroller") }
                .tag(SettingsNav.Tab.mapping)
            OverviewView().tabItem { Label("总览", systemImage: "tablecells") }
                .tag(SettingsNav.Tab.overview)
            GeneralView().tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsNav.Tab.general)
            VoiceView().tabItem { Label("语音", systemImage: "mic") }
                .tag(SettingsNav.Tab.voice)
            RemoteView().tabItem { Label("手机遥控", systemImage: "iphone") }
                .tag(SettingsNav.Tab.remote)
        }
        .frame(minWidth: 1040, minHeight: 680)
    }
}

// MARK: - 通用

struct GeneralView: View {
    @ObservedObject var store = ConfigStore.shared
    @State private var newApp = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var hasAX = KeySynth.hasAccessibility

    var body: some View {
        Form {
            Section {
                Toggle("只在下列 app 里响应通用按键", isOn: $store.config.restrictToTargets)
                Text("关掉的话所有 app 都生效。不建议——Finder 里回车是重命名，"
                     + "对话框里回车是确定，手柄放桌上碰一下就可能出事。\n"
                     + "语音和切换 app 不受此限制，任何地方都能用。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Section("权限") {
                HStack {
                    Label(hasAX ? "辅助功能已授权" : "辅助功能未授权",
                          systemImage: hasAX ? "checkmark.shield.fill"
                                             : "exclamationmark.shield.fill")
                        .foregroundStyle(hasAX ? Color.green : Color.orange)
                    Spacer()
                    if !hasAX {
                        Button("去授权") { KeySynth.openAccessibilityPane() }
                    }
                    Button("重启 JoyCoding") { KeySynth.relaunch() }
                }
                Text(hasAX
                     ? "手柄按键要靠它翻译成键盘事件，这一项是整个 app 的前提。"
                     : "在「系统设置 → 隐私与安全性 → 辅助功能」里勾选 JoyCoding，"
                       + "然后点上面的「重启 JoyCoding」—— 授权对已运行的进程不会即时生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("启动") {
                Toggle("开机自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        LaunchAtLogin.set(on)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }))
                Text(LaunchAtLogin.statusText)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("外观") {
                Picker("界面主题", selection: $store.config.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: store.config.appearance) { Appearance.apply($0) }
            }

            Section("菜单栏") {
                Toggle("在菜单栏图标右边显示手柄电量", isOn: $store.config.showBatteryInMenuBar)
                Text("关掉就只留一个手柄图标，电量仍可在菜单里和设置页看到。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Section("生效的 app") {
                List {
                    ForEach(store.config.targetApps, id: \.self) { b in
                        HStack {
                            Text(b).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                store.config.targetApps.removeAll { $0 == b }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(height: 150)

                HStack {
                    TextField("bundle ID，例如 md.obsidian", text: $newApp)
                    Button("添加") {
                        let t = newApp.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty && !store.config.targetApps.contains(t) {
                            store.config.targetApps.append(t)
                        }
                        newApp = ""
                    }
                    Button("选 app…") { pickApp() }
                }
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

    private func pickApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let url = p.url,
              let b = Bundle(url: url)?.bundleIdentifier else { return }
        if !store.config.targetApps.contains(b) { store.config.targetApps.append(b) }
    }
}

// MARK: - 语音

struct VoiceView: View {
    @ObservedObject var store = ConfigStore.shared

    var body: some View {
        Form {
            Section("触发方式") {
                Picker("模式", selection: $store.config.pttStyle) {
                    Text("按住录，松开出字").tag("hold")
                    Text("按一下开始，再按一下停止").tag("tap")
                    Text("按住说话（底层 toggle）").tag("toggle")
                }
                .pickerStyle(.radioGroup)

                Text("Typeless、VoiceInk 这类「按住热键」的工具选第一个；"
                     + "macOS 自带听写是 toggle 语义，选第二个。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Section("发给听写工具的热键") {
                Picker("按键", selection: $store.config.pttKey) {
                    Text("左 Control").tag("ctrl")
                    Text("右 Control").tag("rightctrl")
                    Text("左 Option").tag("alt")
                    Text("右 Option").tag("rightalt")
                    Text("Fn").tag("fn")
                    Text("D（配合下面的修饰键）").tag("d")
                }
                Text("填修饰键时会合成 flagsChanged 事件，效果等同于物理按住那颗键。"
                     + "按下时必须带上自己的 flag，否则监听方看到的是「已松开」——"
                     + "这是本项目实测踩过的坑。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Section("保险丝") {
                HStack {
                    Text("按住超过")
                    TextField("", value: $store.config.pttMaxHold, format: .number)
                        .frame(width: 60)
                    Text("秒强制松开")
                }
                Text("手柄在你按住时掉线的话，「松开」事件永远不会来，"
                     + "修饰键会一直卡住，整台机器基本没法用。这是兜底。")
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

    private var lanURL: String {
        "http://\(localIP()):\(store.config.httpPort)/\(store.config.httpToken)/"
    }

    private var baseURL: String { "http://\(localIP()):\(store.config.httpPort)/" }

    private var cornerApps: [String] {
        let c = store.config.remoteCorners
        if !c.isEmpty { return c + Array(repeating: "", count: max(0, 4 - c.count)) }
        let auto = Array(store.config.targetApps.prefix(4))
        return auto + Array(repeating: "", count: max(0, 4 - auto.count))
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用手机遥控", isOn: $store.config.httpEnabled)
                    .onChange(of: store.config.httpEnabled) { _ in http.restart() }
                HStack {
                    Text("状态")
                    Spacer()
                    if !store.config.httpEnabled {
                        Text("已关闭").foregroundStyle(.secondary)
                    } else if http.running {
                        Label("监听中 :\(store.config.httpPort)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label(http.lastError ?? "未监听", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("配对") {
                HStack(alignment: .top, spacing: 20) {
                    if let qr = QRCode.image(baseURL, size: 150) {
                        Image(nsImage: qr)
                            .interpolation(.none)          // 二维码不能插值, 会糊
                            .resizable().frame(width: 150, height: 150)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("用手机相机扫码，或在浏览器打开：")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(baseURL)
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Divider()
                        Text("配对码").font(.subheadline).foregroundStyle(.secondary)
                        Text(store.config.pairCode)
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .kerning(6).textSelection(.enabled)
                        Text("只需输一次，之后这台手机会被记住")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack {
                    Button("复制地址") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(baseURL, forType: .string)
                    }
                    Button("重新生成配对码") {
                        store.config.pairCode = ConfigStore.randomPairCode()
                        store.config.httpToken = ConfigStore.randomToken()   // 让已配对的手机失效
                        http.restart()
                    }
                    .help("已配对的手机需要重新配对")
                }
            }

            Section("四角直达键") {
                Text("对应手机遥控界面圆盘四周的四个 app 图标")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow { cornerPicker(0); cornerPicker(1) }
                    GridRow { cornerPicker(2); cornerPicker(3) }
                }
                .padding(.vertical, 4)
            }

            Section {
                Text("⚠️ 这个接口等于把键盘权限开到网络上。只在内网或 Tailscale 里用，"
                     + "绝对不要做端口转发暴露到公网。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// 一个角的选择器。只列白名单里的 app —— 切过去之后按键才是有效的。
    private func cornerPicker(_ i: Int) -> some View {
        let cur = cornerApps.indices.contains(i) ? cornerApps[i] : ""
        return Picker(["左上", "右上", "左下", "右下"][i], selection: Binding(
            get: { cur },
            set: { newValue in
                var c = cornerApps
                while c.count < 4 { c.append("") }
                c[i] = newValue
                store.config.remoteCorners = c
            })) {
            Text("不设置").tag("")
            ForEach(store.config.targetApps, id: \.self) { b in
                Text(AppName.of(b)).tag(b)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func localIP() -> String {
        var addr = "127.0.0.1"
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return addr }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard p.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  let n = p.pointee.ifa_name, String(cString: n) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(p.pointee.ifa_addr, socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            addr = String(cString: host)
        }
        return addr
    }
}
