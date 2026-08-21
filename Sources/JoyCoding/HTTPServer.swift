import Foundation
import Network
import AppKit

/// iPhone 遥控接口。手机「快捷指令」访问 http://<Mac>:27123/<token>/<动作名>。
/// 手柄和手机走同一张动作表, 加动作两边同时生效。
final class HTTPServer: ObservableObject {
    static let shared = HTTPServer()

    @Published private(set) var running = false
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private var watchdog: Timer?

    private init() {}

    func restart() {
        stop()
        let cfg = ConfigStore.shared.config
        guard cfg.httpEnabled else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params,
                                   on: NWEndpoint.Port(rawValue: UInt16(cfg.httpPort))!)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.running = true; self?.lastError = nil
                    case .failed(let e):
                        self?.running = false; self?.lastError = e.localizedDescription
                    case .cancelled:
                        self?.running = false
                    default: break
                    }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            lastError = error.localizedDescription
        }

        // 看门狗: 端口是手柄和手机唯一的出口, 它一死整套就哑, 而且症状
        // (按键没反应)看不出根因。定期确认, 掉了自动重建。
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, ConfigStore.shared.config.httpEnabled, !self.running else { return }
            NSLog("[JoyCoding] HTTP 端口掉了, 重建中")
            self.restart()
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        watchdog?.invalidate(); watchdog = nil
        running = false
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = HTTPServer.parsePath(request)
            let cookie = HTTPServer.parseCookie(request)
            let (body, ctype, status, setCookie) = self.handle(path, cookie: cookie)
            // 图标是二进制 PNG, 所以响应体统一走 Data
            let head = """
            HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r
            Content-Type: \(ctype)\r
            Content-Length: \(body.count)\r
            Cache-Control: \(ctype.hasPrefix("image") ? "max-age=86400" : "no-store")\r
            \(setCookie)Connection: close\r
            \r

            """
            var out = Data(head.utf8)
            out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// 取 Cookie 里的 joycoding=<token>
    private static func parseCookie(_ req: String) -> String? {
        for line in req.split(separator: "\r\n") where line.lowercased().hasPrefix("cookie:") {
            for kv in line.dropFirst(7).split(separator: ";") {
                let p = kv.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if p.count == 2, p[0] == "joycoding" { return String(p[1]) }
            }
        }
        return nil
    }

    private static func parsePath(_ req: String) -> String {
        guard let line = req.split(separator: "\r\n", maxSplits: 1).first else { return "" }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    private func txt(_ s: String, _ type: String = "text/plain; charset=utf-8",
                     _ code: Int = 200) -> (Data, String, Int) {
        (Data(s.utf8), type, code)
    }

    /// 配对失败计数, 防暴力猜码
    private var pairFails = 0
    private var pairLockUntil = Date.distantPast

    private func txt(_ s: String, _ type: String = "text/plain; charset=utf-8",
                     _ code: Int = 200) -> (Data, String, Int, String) {
        (Data(s.utf8), type, code, "")
    }

    /// 认证有两条路:
    ///   * 路径里带 token —— 老用法, iOS 快捷指令那种直打动作 URL 的场景
    ///   * Cookie 里带 token —— 手机配对后走这条, URL 只剩 IP:端口, 好手输
    private func handle(_ path: String, cookie: String?) -> (Data, String, Int, String) {
        let cfg = ConfigStore.shared.config
        var comps = path.split(separator: "/").map(String.init)
        let byCookie = (cookie == cfg.httpToken)

        if !byCookie {
            guard let t = comps.first, t == cfg.httpToken else {
                // 没凭据: 根路径给配对页, 其余一律拒绝
                if comps.isEmpty || comps.first == "pair" {
                    return handlePair(comps, cfg: cfg)
                }
                return txt("forbidden\n", "text/plain; charset=utf-8", 403)
            }
            comps.removeFirst()
        }

        let action = comps.first ?? ""
        if action.isEmpty { return txt(RemoteUI.page(), "text/html; charset=utf-8") }
        if action == "state" { return txt(stateJSON(), "application/json; charset=utf-8") }
        if action == "raw"   { return txt(indexPage()) }
        if action == "icon", comps.count > 1 {
            guard let png = HTTPServer.iconPNG(comps[1]) else {
                return txt("no icon\n", "text/plain; charset=utf-8", 404)
            }
            return (png, "image/png", 200, "")
        }
        if action == "pttStart" { Actions.pttStart(); return txt("ok: pttStart\n") }
        if action == "pttStop"  { Actions.pttStop();  return txt("ok: pttStop\n") }

        guard Actions.byID[action] != nil else {
            return txt("unknown action: \(action)\n", "text/plain; charset=utf-8", 404)
        }
        Actions.run(action)
        return txt("ok: \(action) (front=\(AppContext.shared.frontBundle))\n")
    }

    /// 配对: /pair/<6位码> 对上就下发 Cookie
    private func handlePair(_ comps: [String], cfg: Config) -> (Data, String, Int, String) {
        guard comps.count > 1, comps[0] == "pair" else {
            return txt(RemoteUI.pairPage(), "text/html; charset=utf-8")
        }
        if Date() < pairLockUntil {
            return txt("{\"ok\":false,\"msg\":\"尝试过多，请稍后再试\"}",
                       "application/json; charset=utf-8")
        }
        guard comps[1] == cfg.pairCode else {
            pairFails += 1
            if pairFails >= 5 { pairLockUntil = Date().addingTimeInterval(60); pairFails = 0 }
            return txt("{\"ok\":false,\"msg\":\"配对码不对\"}",
                       "application/json; charset=utf-8")
        }
        pairFails = 0
        // 一年有效; 重新生成配对码会换掉 token, 老 Cookie 自然失效
        let ck = "Set-Cookie: joycoding=\(cfg.httpToken); Max-Age=31536000; Path=/; SameSite=Lax\r\n"
        return (Data("{\"ok\":true}".utf8), "application/json; charset=utf-8", 200, ck)
    }

    /// 手机界面轮询这个: 当前前台 app + 该 app 下可用的专属动作。
    /// 前端据此更新标题栏和「⋯」面板, 不用把 36 个动作全塞给它。
    private func stateJSON() -> String {
        let front = AppContext.shared.frontBundle
        let extras = Actions.available(in: front)
            .filter { $0.onlyIn != nil || $0.group == "Claude Code" || $0.group == "会话" }
            .filter { $0.id != "ptt" }
            .map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\"}" }
            .joined(separator: ",")
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "") }
        let row = rowFor(front).map {
            "{\"id\":\"\(esc($0.0))\",\"icon\":\"\(esc($0.1))\",\"name\":\"\(esc($0.2))\"}"
        }.joined(separator: ",")
        let apps = cfgApps().map {
            "{\"id\":\"\(esc($0.0))\",\"name\":\"\(esc($0.1))\",\"act\":\"\(esc($0.2))\"}"
        }.joined(separator: ",")
        return """
        {"app":"\(esc(front))","appName":"\(esc(AppName.of(front)))",\
        "inTarget":\(AppContext.shared.inTarget()),"apps":[\(apps)],\
        "row":[\(row)],"extras":[\(extras)]}
        """
    }

    /// 手机功能行: 每个 app 给一组它自己最常用的四个。
    /// 之前是写死的四个通用键, 切到 Chrome 时"清空输入""聚焦输入框"都是死键。
    private func rowFor(_ app: String) -> [(String, String, String)] {
        switch app {
        case BundleID.chrome:
            return [("navBack", "←", "后退"), ("reload", "⟳", "刷新"),
                    ("closeTab", "✕", "关标签"), ("newTab", "＋", "新标签")]
        case BundleID.wechat:
            return [("delete", "⌫", "退格"), ("clearLine", "⌧", "清空"),
                    ("wechatNextUnread", "◉", "未读"), ("focusInput", "⌖", "聚焦")]
        case BundleID.ghostty:
            return [("delete", "⌫", "退格"), ("cancel", "⎋", "打断"),
                    ("clearLine", "⌧", "清空行"), ("mode", "⇅", "切模式")]
        case BundleID.claude:
            return [("delete", "⌫", "退格"), ("cancel", "⎋", "打断"),
                    ("clearLine", "⌧", "清空"), ("diffPane", "◧", "diff")]
        default:
            return [("delete", "⌫", "退格"), ("cancel", "⎋", "打断"),
                    ("clearLine", "⌧", "清空"), ("focusInput", "⌖", "聚焦")]
        }
    }

    /// app 图标 -> PNG。渲染一次就缓存, 手机侧还有 24 小时的 HTTP 缓存。
    private static var iconCache: [String: Data] = [:]

    static func iconPNG(_ bundleID: String, size: CGFloat = 120) -> Data? {
        if let c = iconCache[bundleID] { return c }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let target = NSSize(width: size, height: size)
        let img = NSImage(size: target)
        img.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: target),
                  from: .zero, operation: .copy, fraction: 1)
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        iconCache[bundleID] = png
        return png
    }

    /// 手机切换条用的 app 列表: (bundleID, 短名, 对应的切换动作)
    private func cfgApps() -> [(String, String, String)] {
        let short = [BundleID.claude: "Claude", BundleID.ghostty: "Ghostty",
                     BundleID.wechat: "微信",   BundleID.chrome: "Chrome"]
        let act = [BundleID.claude: "focusClaude", BundleID.ghostty: "focusGhostty",
                   BundleID.wechat: "focusWeChat", BundleID.chrome: "focusChrome"]
        let cfg = ConfigStore.shared.config
        // 用户在设置里指定了四角就按他的来, 没指定则自动取白名单前四个
        let list = cfg.remoteCorners.isEmpty
            ? Array(cfg.targetApps.prefix(4))
            : cfg.remoteCorners
        return list.compactMap { b in
            guard !b.isEmpty, let a = act[b] else { return nil }
            return (b, short[b] ?? AppName.of(b), a)
        }
    }

    private func indexPage() -> String {
        let cfg = ConfigStore.shared.config
        var out = """
        front app:     \(AppContext.shared.frontBundle)
        accessibility: \(KeySynth.hasAccessibility)
        in target:     \(AppContext.shared.inTarget())
        ptt style:     \(cfg.pttStyle)

        """
        let devs = HIDInput.shared.devices
        if devs.isEmpty {
            out += "device:        (没有手柄连接)\n"
        }
        for d in devs {
            let p = cfg.devices.first { $0.vendorID == d.vendorID && $0.productID == d.productID }
            out += "device:        \(d.name)  \(d.id)  "
            out += p.map { "已配 \($0.buttons.count) 键 / \($0.stickDirs.count) 方向" }
                    ?? "⚠️ 没有匹配的配置"
            if let pct = JoyConBattery.shared.levels[d.id] {
                out += "  电量 \(pct)%" + (JoyConBattery.shared.charging[d.id] == true ? " ⚡" : "")
                if let r = JoyConBattery.shared.raw[d.id] { out += "  [\(r)]" }
            } else {
                out += "  电量 — (" + JoyConBattery.shared.diag + ")"
            }
            out += "\n"
        }
        out += "\n"
        out += "last input:    " + HIDInput.shared.lastInput + "\n"
        out += "last dispatch: " + HIDInput.shared.lastDispatch + "\n"

        for g in Actions.groups {
            out += "\n[\(g)]\n"
            for a in Actions.all where a.group == g {
                out += "  /\(cfg.httpToken)/\(a.id)\n      \(a.name)"
                if !a.detail.isEmpty { out += " — \(a.detail)" }
                out += "\n"
            }
        }
        return out
    }
}
