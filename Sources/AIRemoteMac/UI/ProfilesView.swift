import SwiftUI
import AppKit

/// app 档案: 每个 app 下，各语义动作分别发什么快捷键。
///
/// 存在的意义是让「按键映射」保持纯语义 —— 配手柄时想的是「下一个会话」，
/// 不用知道 ChatGPT 是 ⌘⇧O 还是别的。不知道快捷键的人靠内置预置，
/// 知道的人在这里改或录制。
/// 单个 app 的键位档案。从总览页点某个 app 的列头进来。
/// 不做成独立标签页 —— 那和总览是同一张表的两个层级, 分开反而要来回切。
struct ProfilesView: View {
    @ObservedObject var store = ConfigStore.shared
    let app: String
    var onClose: () -> Void = {}
    @State private var recording: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon = NSWorkspace.shared
                    .urlForApplication(withBundleIdentifier: app)
                    .map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
                    Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                }
                Text(AppName.of(app)).font(.title3.weight(.semibold))
                if AppProfiles.builtin[app] != nil {
                    Label(L("有内置预置"), systemImage: "checkmark.seal")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if store.config.appProfiles[app] != nil {
                    Button(L("恢复预置")) { store.config.appProfiles.removeValue(forKey: app) }
                }
                Button(L("完成")) { KeyRecorder.stop(); onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(AppProfiles.configurable, id: \.self) { id in
                        row(id)
                        Divider()
                    }
                }
                .padding(.horizontal, 16)
            }

            Divider()
            Text(recording != nil
                 ? L("按下想绑定的快捷键…  Esc 取消")
                 : L("留空表示这个 app 不支持该动作，按键按下去不会有反应。"))
                .font(.callout)
                .foregroundStyle(recording != nil ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 720, height: 560)
        .onDisappear { KeyRecorder.stop(); recording = nil }
    }

    private func installed(_ b: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) != nil
    }

    private func row(_ id: String) -> some View {
        let name = Actions.byID[id]?.name ?? id
        let user = store.config.appProfiles[app]?[id]
        let spec = user ?? AppProfiles.builtin[app]?[id]
        let isRec = recording == id
        return HStack(spacing: 10) {
            Text(name).font(.body).frame(width: 190, alignment: .leading)
            if let d = Actions.byID[id]?.detail, !d.isEmpty {
                Text(d).font(.callout).foregroundStyle(.tertiary)
                    .lineLimit(1).frame(maxWidth: 200, alignment: .leading)
            }
            Spacer()
            Text((spec?.raw.isEmpty ?? true) ? "—" : spec!.display)
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(spec == nil ? Color.secondary : Color.primary)
                .frame(width: 130, alignment: .trailing)
            if user != nil {
                Text(L("已改")).font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor)).foregroundStyle(.white)
            }
            Button(isRec ? L("按键…") : L("录制")) {
                if isRec { KeyRecorder.stop(); recording = nil; return }
                recording = id
                KeyRecorder.start { spec in
                    if let spec { store.config.appProfiles[app, default: [:]][id] = spec }
                    recording = nil
                }
            }
                .buttonStyle(.bordered)
            // 本来就没有键位的不给清空按钮 —— 清一个空的没有意义
            if spec != nil && !(spec!.raw.isEmpty) {
                Button {
                    store.config.appProfiles[app, default: [:]][id] = KeySpec("")
                    clean()
                } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(L("标记为「这个 app 不支持该动作」"))
            } else {
                Spacer().frame(width: 22)
            }
        }
        .padding(.vertical, 9)
        .background(isRec ? Color.accentColor.opacity(0.10) : .clear)
    }

    /// 全空的条目不留在配置里, 免得文件越攒越脏
    private func clean() {
        if store.config.appProfiles[app]?.isEmpty == true {
            store.config.appProfiles.removeValue(forKey: app)
        }
    }
}


/// 快捷键录制。
///
/// 不用 SwiftUI 的 onKeyPress —— 那是 macOS 14+ 才有的, 而我们支持 13。
/// NSEvent 本地监听在 13 上就能用, 而且拿修饰键更直接。
enum KeyRecorder {
    private static var monitor: Any?

    static func start(_ done: @escaping (KeySpec?) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            defer { stop() }
            if e.keyCode == 53 { done(nil); return nil }        // Esc 取消

            var mods: [String] = []
            if e.modifierFlags.contains(.command)  { mods.append("cmd") }
            if e.modifierFlags.contains(.shift)    { mods.append("shift") }
            if e.modifierFlags.contains(.option)   { mods.append("alt") }
            if e.modifierFlags.contains(.control)  { mods.append("ctrl") }

            let named: [UInt16: String] = [
                36: "return", 48: "tab", 49: "space", 51: "delete", 50: "`",
                123: "left", 124: "right", 125: "down", 126: "up",
                33: "[", 30: "]", 42: "\\", 41: ";", 44: "/", 27: "-", 24: "=",
            ]
            let key = named[e.keyCode]
                ?? e.charactersIgnoringModifiers?.lowercased()
                ?? ""
            guard !key.isEmpty else { done(nil); return nil }
            done(KeySpec((mods + [key]).joined(separator: "+")))
            return nil      // 吞掉, 不让它真的发出去
        }
    }

    static func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
