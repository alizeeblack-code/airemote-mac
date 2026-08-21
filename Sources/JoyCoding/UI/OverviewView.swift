import SwiftUI
import AppKit

private struct IDBox: Identifiable { let id: String }

/// 总览: 行=按键, 列=app。一眼看出某颗键在某个 app 里是什么。
/// 继承基础层的显示为浅色 ↳, 被覆盖的正常显示。
struct OverviewView: View {
    @ObservedObject var store = ConfigStore.shared
    @ObservedObject var hid = HIDInput.shared
    @State private var editing: String?

    private var device: ConnectedDevice? { hid.devices.first }
    private var profile: DeviceProfile? {
        guard let d = device else { return nil }
        return store.config.devices.first { $0.id == d.id }
    }
    private var apps: [String] { store.config.targetApps }
    private var art: DeviceArt? {
        guard let d = device else { return nil }
        let a = DeviceArt.art(vendor: d.vendorID, product: d.productID)
        return a.anchors.isEmpty ? nil : a
    }

    /// 有绑定的按键, 按编号排序
    private var rows: [ButtonAnchor] {
        guard let p = profile else { return [] }
        var ids = Set(p.buttons.keys.compactMap(Int.init))
        for (_, o) in p.overrides { ids.formUnion(o.buttons.keys.compactMap(Int.init)) }
        let anchors = art?.anchors ?? []
        return ids.sorted().map { id in
            anchors.first { $0.id == id }
                ?? ButtonAnchor(id: id, label: L("按键 %@", String(id)), pos: .zero,
                                size: .zero, shape: .circle, side: .left)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(device.map { L("%@ · 全部映射", $0.name) } ?? L("没有手柄"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown(), forType: .string)
                } label: { Label(L("复制为表格"), systemImage: "doc.on.doc") }
                    .disabled(profile == nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            if profile == nil {
                Spacer(); Text(L("连上手柄后这里会列出全部映射"))
                    .foregroundStyle(.secondary); Spacer()
            } else {
                ScrollView([.vertical, .horizontal]) {
                    // 顶对齐 —— 之前 Grid 在 ScrollView 里被垂直居中,
                    // 表格不满一屏时上方会空掉一大片
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        header
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(rows) { a in
                            buttonRow(a)
                            Divider().gridCellUnsizedAxes(.horizontal)
                        }
                        ForEach(channels, id: \.self) { ch in
                            ForEach(DeviceProfile.dirKeys, id: \.self) { dir in
                                stickRow(ch, dir)
                                Divider().gridCellUnsizedAxes(.horizontal)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .sheet(item: Binding(
            get: { editing.map { IDBox(id: $0) } },
            set: { editing = $0?.id })) { box in
            ProfilesView(app: box.id) { editing = nil }
        }
    }

    private var header: some View {
        GridRow {
            Text(L("按键")).font(.headline)
                .frame(width: 130, alignment: .leading).padding(.vertical, 9)
            Text(L("基础层")).font(.headline)
                .frame(width: 172, alignment: .leading)
            ForEach(apps, id: \.self) { app in
                // 点列头进这个 app 的键位档案 —— 总览是"按键×app",
                // 档案是"动作×键位", 本来就是同一张表的两层
                Button { editing = app } label: {
                    HStack(spacing: 5) {
                        if let icon = NSWorkspace.shared
                            .urlForApplication(withBundleIdentifier: app)
                            .map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
                            Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                        }
                        Text(AppName.of(app)).font(.headline)
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(width: 172, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(L("查看 / 修改这个 app 的快捷键"))
            }
        }
    }

    private func buttonRow(_ a: ButtonAnchor) -> some View {
        GridRow {
            HStack(spacing: 4) {
                Text(a.label).font(.system(.body, design: .rounded).weight(.medium))
                Text("\(a.id)").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(width: 130, alignment: .leading).padding(.vertical, 6)

            cell(profile?.buttons[String(a.id)], overridden: true)
            ForEach(apps, id: \.self) { app in
                let ov = profile?.isOverridden(button: a.id, app: app) ?? false
                cell(profile?.binding(button: a.id, app: app), overridden: ov, app: app)
            }
        }
    }

    /// 这只手柄学过方向的通道
    private var channels: [StickChannel] {
        StickChannel.allCases.filter { !(profile?.sticks[$0.rawValue]?.isEmpty ?? true) }
    }

    private func stickRow(_ ch: StickChannel, _ dir: String) -> some View {
        GridRow {
            HStack(spacing: 4) {
                Image(systemName: StickAnchor.arrow[dir]!).font(.system(size: 11, weight: .bold))
                Text(ch == .hat ? L("主方向") : L("右摇杆")).font(.body)
            }
            .frame(width: 130, alignment: .leading).padding(.vertical, 6)

            text(profile?.stickDir(ch, dir)?.action, overridden: true)
            ForEach(apps, id: \.self) { app in
                let ov = profile?.isOverridden(ch, dir: dir, app: app) ?? false
                text(profile?.stickAction(ch, dir: dir, app: app), overridden: ov, app: app)
            }
        }
    }

    private func cell(_ b: ButtonBinding?, overridden: Bool, app: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            text(b?.tap, overridden: overridden, app: app)
            if let dbl = b?.double { label(L("双击") + " " + name(dbl), overridden) }
            if let lng = b?.long   { label(L("长按") + " " + name(lng), overridden) }
        }
        .frame(width: 172, alignment: .leading)
    }

    private func text(_ action: String?, overridden: Bool, app: String? = nil) -> some View {
        label(action.map(name) ?? "—", overridden,
              unsupported: unsupported(action, app: app))
    }

    /// 动作在这个 app 下有没有对应键位。没有的话显示成"—"而不是"↳ 继承",
    /// 后者会让人以为它能用。
    private func unsupported(_ action: String?, app: String?) -> Bool {
        guard let action, let app,
              AppProfiles.configurable.contains(action) else { return false }
        guard let spec = AppProfiles.key(action, app: app) else { return true }
        return spec.raw.isEmpty
    }

    private func label(_ s: String, _ overridden: Bool, unsupported: Bool = false) -> some View {
        Text(unsupported ? "—" : (overridden ? s : "↳ " + s))
            .font(.body)
            .foregroundStyle(unsupported ? Color.secondary.opacity(0.35)
                             : (overridden ? Color.primary : Color.secondary.opacity(0.7)))
            .help(unsupported ? L("这个 app 没有对应的快捷键，按下去不会有反应") : "")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func name(_ id: String) -> String { Actions.byID[id]?.name ?? id }

    /// 导出成 Markdown 表格, 贴到笔记或者发给别人
    private func markdown() -> String {
        guard let p = profile else { return "" }
        var out = "| " + L("按键") + " | " + L("基础层") + " | " + apps.map(AppName.of).joined(separator: " | ") + " |\n"
        out += "|---|---|" + apps.map { _ in "---|" }.joined() + "\n"
        for a in rows {
            var cells = [name(p.buttons[String(a.id)]?.tap ?? "—")]
            cells += apps.map { name(p.binding(button: a.id, app: $0)?.tap ?? "—") }
            out += "| \(a.label) | " + cells.joined(separator: " | ") + " |\n"
        }
        for ch in channels {
            let prefix = ch == .hat ? L("主方向") : L("右摇杆")
            for dir in DeviceProfile.dirKeys {
                let arrow = ["up": "↑", "down": "↓", "left": "←", "right": "→"][dir]!
                var cells = [name(p.stickDir(ch, dir)?.action ?? "—")]
                cells += apps.map { name(p.stickAction(ch, dir: dir, app: $0) ?? "—") }
                out += "| \(prefix)\(arrow) | " + cells.joined(separator: " | ") + " |\n"
            }
        }
        return out
    }
}
