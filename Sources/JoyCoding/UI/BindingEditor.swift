import SwiftUI

/// 改绑定的写入口。图形页和表格页共用。
///
/// 单独抽出来是因为**覆盖层的语义容易写歪**: 在某个 app 层上改一颗键时,
/// 要先把基础层这颗键整个拷过来再改(覆盖以整颗按键为单位, 不做按手势继承)。
/// 两处各写一份的话, 迟早只有一边是对的。
struct BindingEditor {
    let device: ConnectedDevice
    /// "" = 基础层, 否则是 app 的 bundleID
    let layer: String

    func set(_ n: Int, _ path: WritableKeyPath<ButtonBinding, String?>, _ v: String?) {
        mutate { p in
            if layer.isEmpty {
                p.buttons[String(n), default: .init()][keyPath: path] = v
            } else {
                var ov = p.overrides[layer] ?? AppOverride()
                var b = ov.buttons[String(n)] ?? p.buttons[String(n)] ?? ButtonBinding()
                b[keyPath: path] = v
                ov.buttons[String(n)] = b
                p.overrides[layer] = ov
            }
        }
    }

    func setDir(_ ch: StickChannel, _ dir: String, _ action: String?) {
        mutate { p in
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

    /// 把这颗键在当前层的覆盖整个撤掉, 回到继承基础层
    func clearOverride(_ n: Int) {
        guard !layer.isEmpty else { return }
        mutate { p in
            p.overrides[layer]?.buttons.removeValue(forKey: String(n))
            if p.overrides[layer]?.isEmpty == true { p.overrides.removeValue(forKey: layer) }
        }
    }

    private func mutate(_ body: (inout DeviceProfile) -> Void) {
        let store = ConfigStore.shared
        if !store.config.devices.contains(where: { $0.id == device.id }) {
            store.config.devices.append(
                DeviceProfile(vendorID: device.vendorID, productID: device.productID,
                              name: device.name))
        }
        guard let i = store.config.devices.firstIndex(where: { $0.id == device.id }) else { return }
        body(&store.config.devices[i])
        store.save()
    }
}

/// 选动作的菜单项。分组、置灰"本层无效"的动作都在这儿, 两个视图共用。
struct ActionMenuItems: View {
    let layer: String
    let pick: (String?) -> Void

    var body: some View {
        let split = groupSplit
        Button(L("未设置")) { pick(nil) }
        ForEach(split.primary, id: \.self) { g in
            Menu(g) {
                ForEach(Actions.all.filter { $0.group == g }) { act in
                    Button(label(act)) { pick(act.id) }
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

    private func label(_ a: ActionDef) -> String {
        guard let only = a.onlyIn, !available(a) else { return a.name }
        return L("%@（仅 %@）", a.name, AppName.of(only))
    }

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
        let own = primary.filter { g in
            Actions.all.first { $0.group == g }?.onlyIn == layer
        }
        return (own + primary.filter { !own.contains($0) }, other)
    }
}
