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

            // httpInterface 一直是个死配置 —— 定义了但没人读, 服务器始终监听
            // 全部网卡。"selected" 时只绑用户在上面选中的那个地址, 其余网段
            // 连端口都看不到(比如只对 Tailscale 开放, 不暴露给整个局域网)。
            let port = NWEndpoint.Port(rawValue: UInt16(cfg.httpPort))!
            let l: NWListener
            if cfg.httpInterface == "selected",
               let ip = NetAddresses.resolve(preferred: cfg.remoteAddress)?.ip {
                // 绑定特定地址时只能走 requiredLocalEndpoint。再传 on: port
                // 会和它冲突, 监听器直接起不来(实测端口上什么都没有)。
                params.requiredLocalEndpoint = .hostPort(host: .init(ip), port: port)
                l = try NWListener(using: params)
            } else {
                l = try NWListener(using: params, on: port)
            }
            // Bonjour 广播 —— 让 iPhone 端不用手输 IP 就能找到这台 Mac。
            //
            // 顺带解决 iOS 那边一个更烦的问题: iOS 14+ 访问局域网要用户授权,
            // 而**触发授权弹窗的那次请求必然失败**。手机端没有"提前申请"的 API,
            // 只能靠真发一次本地网络操作把弹窗勾出来 —— 有了这个广播, 它就能在
            // 「装 Mac 端」那一屏用一次 Bonjour 浏览把权限问完, 而不是等到用户
            // 输完 6 位码、砸在配对那一下上。
            //
            // 只在监听全部网卡时广播。httpInterface == "selected" 是用户特意
            // 把端口收窄到某个网段(典型是只对 Tailscale 开、不暴露给局域网),
            // 这时候还往局域网上喊一嗓子"这里有台 JoyCoding"就违背他的本意了 ——
            // 虽然喊了也连不上(端口没绑在那个网段), 但那是噪音。
            //
            // 广播本身不放权: 手机看到的只有机器名和端口, 要动这台 Mac 仍然得
            // 输那 6 位配对码。端口本来就在那儿, 扫一下就能发现, Bonjour 只是
            // 省掉手输地址。
            if cfg.httpInterface != "selected" {
                l.service = NWListener.Service(name: Host.current().localizedName
                                                    ?? ProcessInfo.processInfo.hostName,
                                              type: "_joycoding._tcp")
            }
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
        readRequest(conn, buffer: Data())
    }

    /// 一次 receive 只保证"有字节就返回", 不保证请求头收全了。
    /// Wi-Fi 上请求头被拆成两个 TCP 段是常事 —— 第一段只有请求行、没有 Cookie,
    /// 于是被当成没配对, 手机偶发掉回配对页。所以要读到头结束为止。
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, done, err in
            var buf = buffer
            if let d = data { buf.append(d) }

            let headerEnd = Data("\r\n\r\n".utf8)
            let gotHeaders = buf.range(of: headerEnd) != nil
            // 64K 上限: 不让对端拿一个永不结束的请求把内存撑爆
            if !gotHeaders && !done && err == nil && buf.count < 64 * 1024 {
                self.readRequest(conn, buffer: buf)
                return
            }
            guard !buf.isEmpty else { conn.cancel(); return }
            self.respond(conn, request: String(decoding: buf, as: UTF8.self))
        }
    }

    private func respond(_ conn: NWConnection, request: String) {
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

        // 配对请求不看凭据 —— 手机端解除配对后 Cookie 往往还在浏览器/URLSession
        // 里, 带着旧的【有效】Cookie 重新配对是正当场景。不提前拦的话它会落进
        // 动作分发, 变成 "unknown action: pair" 的纯文本 404, 手机端一脸懵。
        if comps.first == "pair" { return handlePair(comps, cfg: cfg) }

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
        // 某个 app 的完整可用动作表。手机端的功能行编辑器用 ——
        // /state 里的 extras 是给「⋯」面板过滤过的子集, 不够当选择器的数据源。
        //
        // /actions/<bundleID> 指定 app, /actions 不带参数则是当前前台 ——
        // 功能行是 per-app 的配置, 手机上要能改「不在前台的那个 app」,
        // 否则想调 Chrome 的按键就得先把 Mac 切到 Chrome。
        if action == "actions" {
            let target = comps.count > 1 && !comps[1].isEmpty
                ? comps[1] : AppContext.shared.frontBundle
            let list = Actions.available(in: target)
                .filter { $0.id != "ptt" }
                .map { "{\"id\":\"\($0.id)\",\"name\":\(jsonStr($0.name))}" }
                .joined(separator: ",")
            // 连默认功能行一起给: 编辑非前台 app 时 /state 里没有它的 row,
            // 手机端就没法显示"恢复默认后会变成什么"。
            let defRow = rowFor(target).map {
                "{\"id\":\(jsonStr($0.0)),\"icon\":\(jsonStr($0.1)),\"name\":\(jsonStr($0.2))}"
            }.joined(separator: ",")
            return txt("{\"app\":\(jsonStr(target)),\"appName\":\(jsonStr(AppName.of(target))),"
                       + "\"actions\":[\(list)],\"row\":[\(defRow)]}",
                       "application/json; charset=utf-8")
        }
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
    /// 拼 JSON 字面量。直接插值的话中文里的引号会把 JSON 打断,
    /// 而且不加引号本身就已经不是合法 JSON 了 —— 手机端 r.json() 抛异常,
    /// 落进 catch 显示"连不上 Mac", 把"配对码不对"这个真实原因盖掉。
    private func jsonStr(_ v: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [v]),
              let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }

    private func handlePair(_ comps: [String], cfg: Config) -> (Data, String, Int, String) {
        guard comps.count > 1, comps[0] == "pair" else {
            return txt(RemoteUI.pairPage(), "text/html; charset=utf-8")
        }
        if Date() < pairLockUntil {
            return txt("{\"ok\":false,\"msg\":\(jsonStr(L("尝试过多，请稍后再试")))}",
                       "application/json; charset=utf-8")
        }
        guard comps[1] == cfg.pairCode else {
            pairFails += 1
            if pairFails >= 5 { pairLockUntil = Date().addingTimeInterval(60); pairFails = 0 }
            return txt("{\"ok\":false,\"msg\":\(jsonStr(L("配对码不对")))}",
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
            .filter { $0.onlyIn != nil || $0.group == "Claude Code" || $0.group == L("会话") }
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
        let dirs = dirsFor(front).map {
            "{\"id\":\(jsonStr($0.0)),\"name\":\(jsonStr($0.1))}"
        }.joined(separator: ",")
        // 前台 app 决定显示哪一边(终端和无关 app 给两边)
        let tools = SessionScan.tools(forFront: front)
        let found = SessionScan.recent(tools: tools)
        // tool 恒定输出: 手机端不再拿它当文字标签(改用 appID 的图标了), 只用来
        // 算配色和无障碍朗读 —— 跟着前台 app 时有时无的话, 同一个会话的颜色
        // 会在切 app 时跳变。
        let sessions = found.map {
            "{\"name\":\(jsonStr($0.name)),\"ageSec\":\($0.ageSec),"
            + "\"busy\":\($0.busy),\"tool\":\(jsonStr($0.tool.label)),"
            + "\"appID\":\(jsonStr($0.appID))}"
        }.joined(separator: ",")
        return """
        {"app":"\(esc(front))","appName":"\(esc(AppName.of(front)))",\
        "inTarget":\(AppContext.shared.inTarget()),"apps":[\(apps)],\
        "row":[\(row)],"extras":[\(extras)],"sessions":[\(sessions)],"dirs":[\(dirs)]}
        """
    }

    /// 方向键在每个 app 里的说法。◀▶ 在 Claude 里是切会话, 在 Chrome 里是切
    /// 标签页, 微信里是切聊天, Ghostty 里是切窗口(它的档案走窗口不走标签)。
    ///
    /// 手机上的按键说明卡照抄这份。之前那句说明是写死的英文常量, 不管切到哪个
    /// app 都说 "previous / next session" —— 在 Chrome 上就是错的。
    ///
    /// 写成四组完整词条而不是「上一个」+ 单位拼接: 拼接在英文下会撞单复数
    /// (已有的「会话」译作 Sessions, 拼出来是 "Previous Sessions"), 而且
    /// 各语言的语序也不一定是「序数词 + 名词」。
    private func dirsFor(_ app: String) -> [(String, String)] {
        let prev: String, next: String
        switch app {
        case BundleID.chrome:  prev = L("上一个标签页"); next = L("下一个标签页")
        case BundleID.wechat:  prev = L("上一个聊天");   next = L("下一个聊天")
        case BundleID.ghostty: prev = L("上一个窗口");   next = L("下一个窗口")
        default:               prev = L("上一个会话");   next = L("下一个会话")
        }
        return [("scrollUp",    L("向上翻页")),
                ("scrollDown",  L("向下翻页")),
                ("sessionPrev", prev),
                ("sessionNext", next)]
    }

    /// 手机功能行: 每个 app 给一组它自己最常用的四个。
    /// 之前是写死的四个通用键, 切到 Chrome 时"清空输入""聚焦输入框"都是死键。
    private func rowFor(_ app: String) -> [(String, String, String)] {
        switch app {
        case BundleID.chrome:
            return [("navBack", "←", L("后退")), ("reload", "⟳", L("刷新")),
                    ("closeTab", "✕", L("关标签")), ("newTab", "＋", L("新标签"))]
        case BundleID.wechat:
            return [("delete", "⌫", L("退格")), ("clearLine", "⌧", L("清空")),
                    ("wechatNextUnread", "◉", L("未读")), ("focusInput", "⌖", L("聚焦"))]
        case BundleID.ghostty:
            return [("delete", "⌫", L("退格")), ("cancel", "⎋", L("打断")),
                    ("clearLine", "⌧", L("清空行")), ("mode", "⇅", L("切模式"))]
        case BundleID.claude:
            return [("delete", "⌫", L("退格")), ("cancel", "⎋", L("打断")),
                    ("clearLine", "⌧", L("清空")), ("diffPane", "◧", "diff")]
        default:
            return [("delete", "⌫", L("退格")), ("cancel", "⎋", L("打断")),
                    ("clearLine", "⌧", L("清空")), ("focusInput", "⌖", L("聚焦"))]
        }
    }

    /// app 图标 -> PNG。渲染一次就缓存, 手机侧还有 24 小时的 HTTP 缓存。
    /// 同样要上锁: 手机一屏能同时发出七八个 /icon 请求(四角 + 每张会话卡),
    /// 它们落在并发队列上会同时写这个字典。
    private static var iconCache: [String: Data] = [:]
    private static let iconLock = NSLock()

    static func iconPNG(_ bundleID: String, size: CGFloat = 120) -> Data? {
        iconLock.lock()
        defer { iconLock.unlock() }
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
    /// 手机端要的完整 app 列表。**不要在这里截断** —— 手机侧拿它同时做两件事:
    /// 前四个放圆盘四角, 全部放进「⋯ → 切换到」。之前这里 prefix(4) 一刀切,
    /// 结果切换列表也只剩四个, 而且 JS 里 `apps.length>4` 才显示的「更多」入口
    /// 成了永远走不到的死代码。
    ///
    /// 动作 ID 也不再查写死的四条映射 —— 那会把用户新加的 app 静默丢掉。
    private func cfgApps() -> [(String, String, String)] {
        // 手机屏窄, 给常见的几个配短名; 没列到的走 AppName.of
        let short = [BundleID.claude: "Claude", BundleID.ghostty: "Ghostty",
                     BundleID.wechat: L("微信"),   BundleID.chrome: "Chrome",
                     BundleID.chatgpt: "ChatGPT", BundleID.cursor: "Cursor",
                     BundleID.slack: "Slack"]
        let cfg = ConfigStore.shared.config
        // 四角指定过就按用户的来, 没指定就用白名单本身的顺序
        let list = cfg.remoteCorners.isEmpty ? cfg.targetApps : cfg.remoteCorners
        var seen = Set<String>()
        return list.compactMap { b in
            guard !b.isEmpty, seen.insert(b).inserted else { return nil }
            return (b, short[b] ?? AppName.of(b), Actions.focusID(for: b))
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
            out += L("device:        (没有手柄连接)") + "\n"
        }
        for d in devs {
            let p = cfg.devices.first { $0.vendorID == d.vendorID && $0.productID == d.productID }
            out += "device:        \(d.name)  \(d.id)  "
            out += p.map { L("已配 %@ 键 / %@ 方向", String($0.buttons.count), String($0.stickDirs.count)) }
                    ?? L("⚠️ 没有匹配的配置")
            if let pct = JoyConBattery.shared.levels[d.id] {
                out += L("  电量 %@%%", String(pct)) + (JoyConBattery.shared.charging[d.id] == true ? " ⚡" : "")
                if let r = JoyConBattery.shared.raw[d.id] { out += "  [\(r)]" }
            } else {
                out += L("  电量 — (") + JoyConBattery.shared.diag + ")"
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
