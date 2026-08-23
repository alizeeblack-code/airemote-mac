import AppKit
import Foundation

/// 一个会话跑在哪个 app 里 —— Ghostty? iTerm? Claude 桌面版? ChatGPT.app?
///
/// transcript 文件里查不到: Codex 的 session_meta 只有 originator
/// (codex-tui / codex_vscode / codex_exec), 分得出 CLI 和 VS Code, 分不出
/// 是哪个终端; TERM_PROGRAM、tty、pid 一个都没记。Claude 那边同理。
///
/// 所以从活进程反查: 每个 codex/claude 进程的 cwd 就是项目目录(和会话对得上),
/// 沿父进程链往上走, 第一个能被 NSRunningApplication 认出来的就是宿主 app。
/// 不维护"进程名 → bundle id"的映射表 —— 那样每出一个新终端就要加一行,
/// 而 NSRunningApplication 直接给出真实 bundle id, Warp / Kitty 白捡。
enum SessionHost {

    /// cwd → 宿主 bundle id。5 秒一刷: /state 是 1.5s 轮询, 每次都开进程扛不住,
    /// 而"会话换了个窗口"本来也不是需要实时的事。
    private static var cache: [String: String] = [:]
    private static var stamp = Date.distantPast

    /// 同 SessionScan: HTTP 连接跑在并发队列上, 这里的静态字典必须自己上锁。
    /// 只被 SessionScan 调用, 且从不回调过去, 所以两把锁不会互等。
    private static let lock = NSLock()

    /// 查不到活进程时的退路。已退出的会话(卡片上写着 "3h")没有宿主可查,
    /// ChatGPT.app 里的 codex 是个 cwd=/ 的常驻 app-server 也对不上 ——
    /// 这时退化成工具自己的图标, 读作"这是哪个工具"而不是"在哪个窗口"。
    static func fallback(_ tool: SessionScan.Tool) -> String {
        switch tool {
        case .claude: return BundleID.claude
        case .codex:  return "com.openai.codex"
        }
    }

    static func appID(cwd: String, tool: SessionScan.Tool) -> String {
        lock.lock()
        defer { lock.unlock() }
        refresh()
        if !cwd.isEmpty, let hit = cache[cwd] { return hit }
        return fallback(tool)
    }

    // MARK: - 进程表

    private static func refresh() {
        guard Date().timeIntervalSince(stamp) > 5 else { return }
        stamp = Date()

        let parents = parentMap()
        var next: [String: String] = [:]
        for (pid, cwd) in cwds() where cwd != "/" {
            guard let bid = guiAncestor(pid, parents: parents) else { continue }
            next[cwd] = bid
        }
        cache = next
    }

    /// `ps` 一次拉全表, 父进程链在内存里走 —— 每层都开一次 ps 的话,
    /// 一个 5 层的链子就是 5 次 fork。
    private static func parentMap() -> [Int32: Int32] {
        var map: [Int32: Int32] = [:]
        for line in run("/bin/ps", ["-axo", "pid=,ppid="]).split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, let a = Int32(f[0]), let b = Int32(f[1]) else { continue }
            map[a] = b
        }
        return map
    }

    /// -Fpn 的输出是每行一个字段: `p<pid>` / `fcwd` / `n<路径>`。
    private static func cwds() -> [(Int32, String)] {
        var out: [(Int32, String)] = []
        var pid: Int32 = 0
        for line in run("/usr/sbin/lsof",
                        ["-a", "-d", "cwd", "-c", "codex", "-c", "claude", "-Fpn"])
            .split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst()) ?? 0
            case "n": if pid != 0 { out.append((pid, String(line.dropFirst()))) }
            default: break
            }
        }
        return out
    }

    /// 往上找第一个"是个 app"的祖先。CLI 进程本身 NSRunningApplication 认不出来
    /// (不是 GUI app), 正好天然跳过。
    private static func guiAncestor(_ pid: Int32, parents: [Int32: Int32]) -> String? {
        var p = pid
        for _ in 0..<12 {
            if let bid = NSRunningApplication(processIdentifier: p)?.bundleIdentifier {
                return bid
            }
            guard let pp = parents[p], pp > 1 else { return nil }
            p = pp
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
