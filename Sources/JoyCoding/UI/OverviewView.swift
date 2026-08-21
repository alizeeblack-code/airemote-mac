import SwiftUI
import AppKit

/// 总览: 行=按键, 列=app。一眼看出某颗键在某个 app 里是什么。
/// 继承基础层的显示为浅色 ↳, 被覆盖的正常显示。
struct OverviewView: View {
    @ObservedObject var store = ConfigStore.shared
    @ObservedObject var hid = HIDInput.shared

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
                ?? ButtonAnchor(id: id, label: "按键 \(id)", pos: .zero,
                                size: .zero, shape: .circle, side: .left)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(device.map { "\($0.name) · 全部映射" } ?? "没有手柄")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown(), forType: .string)
                } label: { Label("复制为表格", systemImage: "doc.on.doc") }
                    .disabled(profile == nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            if profile == nil {
                Spacer(); Text("连上手柄后这里会列出全部映射")
                    .foregroundStyle(.secondary); Spacer()
            } else {
                ScrollView([.vertical, .horizontal]) {
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
                }
            }
        }
    }

    private var header: some View {
        GridRow {
            Text("按键").font(.subheadline.weight(.semibold))
                .frame(width: 130, alignment: .leading).padding(.vertical, 8)
            Text("基础层").font(.subheadline.weight(.semibold))
                .frame(width: 172, alignment: .leading)
            ForEach(apps, id: \.self) { app in
                Text(AppName.of(app)).font(.subheadline.weight(.semibold))
                    .frame(width: 172, alignment: .leading)
            }
        }
    }

    private func buttonRow(_ a: ButtonAnchor) -> some View {
        GridRow {
            HStack(spacing: 4) {
                Text(a.label).font(.system(.subheadline, design: .rounded).weight(.medium))
                Text("\(a.id)").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(width: 130, alignment: .leading).padding(.vertical, 6)

            cell(profile?.buttons[String(a.id)], overridden: true)
            ForEach(apps, id: \.self) { app in
                let ov = profile?.isOverridden(button: a.id, app: app) ?? false
                cell(profile?.binding(button: a.id, app: app), overridden: ov)
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
                Text(ch == .hat ? "主方向" : "右摇杆").font(.subheadline)
            }
            .frame(width: 130, alignment: .leading).padding(.vertical, 6)

            text(profile?.stickDir(ch, dir)?.action, overridden: true)
            ForEach(apps, id: \.self) { app in
                let ov = profile?.isOverridden(ch, dir: dir, app: app) ?? false
                text(profile?.stickAction(ch, dir: dir, app: app), overridden: ov)
            }
        }
    }

    private func cell(_ b: ButtonBinding?, overridden: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            text(b?.tap, overridden: overridden)
            if let dbl = b?.double { label("双击 " + name(dbl), overridden) }
            if let lng = b?.long   { label("长按 " + name(lng), overridden) }
        }
        .frame(width: 172, alignment: .leading)
    }

    private func text(_ action: String?, overridden: Bool) -> some View {
        label(action.map(name) ?? "—", overridden)
    }

    private func label(_ s: String, _ overridden: Bool) -> some View {
        Text(overridden ? s : "↳ " + s)
            .font(.subheadline)
            .foregroundStyle(overridden ? Color.primary : Color.secondary.opacity(0.7))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func name(_ id: String) -> String { Actions.byID[id]?.name ?? id }

    /// 导出成 Markdown 表格, 贴到笔记或者发给别人
    private func markdown() -> String {
        guard let p = profile else { return "" }
        var out = "| 按键 | 基础层 | " + apps.map(AppName.of).joined(separator: " | ") + " |\n"
        out += "|---|---|" + apps.map { _ in "---|" }.joined() + "\n"
        for a in rows {
            var cells = [name(p.buttons[String(a.id)]?.tap ?? "—")]
            cells += apps.map { name(p.binding(button: a.id, app: $0)?.tap ?? "—") }
            out += "| \(a.label) | " + cells.joined(separator: " | ") + " |\n"
        }
        for ch in channels {
            let prefix = ch == .hat ? "主方向" : "右摇杆"
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
