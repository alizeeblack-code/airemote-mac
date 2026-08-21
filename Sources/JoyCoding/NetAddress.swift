import Foundation

/// 手机遥控要给出一个手机能连上的地址。
///
/// 原来的实现写死只看 `en0` —— 用有线网、雷雳网桥、iPhone USB 共享,
/// 或者 Wi-Fi 不在 en0 的机型, 都会取不到值然后静默回落成 127.0.0.1,
/// 二维码照常生成, 手机扫了连不上, 界面上不给任何解释。
struct NetAddress: Identifiable, Hashable {
    let interface: String
    let ip: String
    let kind: Kind

    var id: String { ip }

    enum Kind: Int, Comparable {
        case lan = 0        // 物理网卡上的内网地址, 绝大多数人要的就是这个
        case tailscale = 1  // 100.64/10, 出门在外也能连
        case other = 2      // 其它可路由地址, 兜底列出来让人自己判断

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// 下拉里显示的文案。带上接口名, 多网卡的机器才分得清哪个是哪个。
    var label: String {
        switch kind {
        case .tailscale: return "\(ip) · Tailscale"
        default:         return "\(ip) · \(interface)"
        }
    }
}

enum NetAddresses {

    /// 按「最可能连得上」排序。空数组表示确实没有可用地址。
    static func all() -> [NetAddress] {
        var out: [NetAddress] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }

        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            // ifa_addr 可能是 NULL(没配地址的接口), 直接 .pointee 会崩
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let namePtr = p.pointee.ifa_name else { continue }

            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0 else { continue }

            let name = String(cString: namePtr)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)

            guard let kind = classify(interface: name, ip: ip) else { continue }
            out.append(NetAddress(interface: name, ip: ip, kind: kind))
        }

        return out.sorted { ($0.kind, $0.ip) < ($1.kind, $1.ip) }
    }

    /// 返回 nil 表示这个地址不该出现在候选里。
    /// internal 而非 private: 构建时会用合成用例直接测它
    static func classify(interface n: String, ip: String) -> NetAddress.Kind? {
        // 系统自建的虚拟接口: AirDrop / 热点 / iPhone 镜像, 手机都连不上
        if n.hasPrefix("awdl") || n.hasPrefix("llw")
            || n.hasPrefix("ap") || n.hasPrefix("anpi") { return nil }

        if ip.hasPrefix("127.") { return nil }        // 环回; all() 靠 flags 也拦, 这里独立成立
        if ip.hasPrefix("169.254.") { return nil }      // 没拿到 DHCP 时的自分配地址
        if ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.") { return nil }  // 代理软件 TUN 常占的保留段

        // Tailscale 走 utun, 地址在 100.64/10
        if isCGNAT(ip) { return .tailscale }

        // 其余隧道接口(VPN / 代理)给出的地址, 手机多半连不上
        if n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp") { return nil }

        return isPrivate(ip) ? .lan : .other
    }

    private static func isPrivate(_ ip: String) -> Bool {
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return true }
        let f = ip.split(separator: ".")
        guard f.count == 4, f[0] == "172", let b = Int(f[1]) else { return false }
        return (16...31).contains(b)
    }

    private static func isCGNAT(_ ip: String) -> Bool {
        let f = ip.split(separator: ".")
        guard f.count == 4, f[0] == "100", let b = Int(f[1]) else { return false }
        return (64...127).contains(b)
    }

    /// 用户选定的地址; 选的那个不在了(换了网络)就退回自动挑选。
    static func resolve(preferred: String) -> NetAddress? {
        let list = all()
        if !preferred.isEmpty, let hit = list.first(where: { $0.ip == preferred }) { return hit }
        return list.first
    }
}
