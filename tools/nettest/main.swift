import Foundation

let cases: [(String, String, String)] = [
    // 接口,    地址,              期望  —— en1 那条是真实故障复现
    ("en0",    "192.168.2.193",  "lan"),        // 本机 Wi-Fi
    ("en1",    "192.168.3.99",   "lan"),        // ← 出问题那台机器
    ("en5",    "10.0.1.42",      "lan"),        // 有线网
    ("en7",    "172.20.10.3",    "lan"),        // iPhone USB 共享
    ("bridge0","192.168.9.1",    "lan"),        // 雷雳网桥
    ("utun10", "100.69.140.73",  "tailscale"),
    ("utun11", "198.18.0.1",     "nil"),        // Clash TUN 保留段
    ("utun4",  "10.8.0.6",       "nil"),        // 普通 VPN 隧道
    ("lo0",    "127.0.0.1",      "nil"),        // 环回(实际靠 flags 排除, 这里走地址)
    ("awdl0",  "169.254.1.2",    "nil"),        // AirDrop
    ("en0",    "169.254.55.7",   "nil"),        // 没拿到 DHCP
    ("en0",    "203.0.113.9",    "other"),      // 公网直连
]
var bad = 0
for (n, ip, want) in cases {
    let got = NetAddresses.classify(interface: n, ip: ip)
    let s = got.map { "\($0)" } ?? "nil"
    let ok = s == want
    if !ok { bad += 1 }
    print("  \(ok ? "✅" : "❌")  \(n.padding(toLength: 9, withPad: " ", startingAt: 0))\(ip.padding(toLength: 18, withPad: " ", startingAt: 0))→ \(s)\(ok ? "" : "  (期望 \(want))")")
}
print(bad == 0 ? "\n  全部通过" : "\n  \(bad) 条不符")
exit(bad == 0 ? 0 : 1)
