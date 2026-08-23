import AppKit
import Foundation

/// Claude Code / Codex 的活跃会话。给手机遥控的状态区用 ——
/// 遥控的核心场景就是"人不在电脑前, 想知道跑完没"。
///
/// 两家的存储格式意外地一致, 所以同一套逻辑就能覆盖:
///   Claude Code  ~/.claude/projects/<项目>/<会话>.jsonl        行内 cwd
///   Codex        ~/.codex/sessions/年/月/日/rollout-*.jsonl    行内 payload.cwd
///
/// 活跃判定都用文件修改时间(10 秒内有写入 = 工作中), 不解析 transcript
/// 内部格式 —— 那是各家的私有结构, 版本一变就碎; mtime 谁也动不了。
enum SessionScan {

    enum Tool: String {
        case claude, codex

        var label: String {
            switch self {
            case .claude: return "Claude"
            case .codex:  return "Codex"
            }
        }
    }

    struct Entry {
        let name: String        // 项目目录名
        let ageSec: Int         // 距最后一次写入多久
        let busy: Bool
        let tool: Tool
        let appID: String       // 宿主 app 的 bundle id, 给手机取图标
    }

    /// 项目路径缓存: transcript 路径 -> cwd。cwd 要读文件内容, 不能每 1.5s 轮询都读。
    private static var cwdCache: [String: String] = [:]

    /// ⚠️ Network.framework 在并发 root queue 上派发连接 —— 两台手机(或一台
    /// 手机的两次轮询叠在一起)会同时进 recent(), 同时写上面那个字典, 字典
    /// 直接写坏, 崩在 swift_isUniquelyReferenced。整个扫描串行化, 别只锁字典:
    /// 反正有缓存, 真正干活的次数很少。
    private static let lock = NSLock()

    /// 前台 app 决定显示哪一边的会话。
    ///
    /// 终端是特例: 里面跑的可能是 claude 也可能是 codex, 光看前台分不出来,
    /// 所以两边都给 —— 按活跃时间排序后, 正在用的那个自然排在最前且亮着。
    /// 无关 app(浏览器、聊天)也给两边: "切去干别的事了想知道跑完没" 正是
    /// 这个功能最大的价值, 这时候藏起来等于把它砍了。
    static func tools(forFront bundleID: String) -> Set<Tool> {
        switch bundleID {
        case BundleID.claude: return [.claude]
        case "com.openai.codex", "com.openai.chat": return [.codex]
        default: return [.claude, .codex]
        }
    }

    /// 最近活跃的会话, 每个 (工具, 项目) 只留最新的一条 ——
    /// 同项目开两个会话时显示两行一模一样的名字只是噪音。
    static func recent(tools: Set<Tool> = [.claude, .codex],
                       limit: Int = 5, within: TimeInterval = 8 * 3600) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        var all: [(Entry, Date)] = []
        if tools.contains(.claude) { all += scanClaude(within: within) }
        if tools.contains(.codex)  { all += scanCodex(within: within) }
        return all.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    // MARK: - Claude Code

    private static func scanClaude(within: TimeInterval) -> [(Entry, Date)] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return [] }

        var newest: [String: (URL, Date)] = [:]
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for f in files where f.pathExtension == "jsonl" {
                guard let m = modified(f), fresh(m, within) else { continue }
                let key = dir.lastPathComponent
                if let cur = newest[key], cur.1 >= m { continue }
                newest[key] = (f, m)
            }
        }
        return newest.map { key, v in
            (entry(cwd: projectCwd(v.0), fallbackName: key, at: v.1, tool: .claude), v.1)
        }
    }

    // MARK: - Codex

    /// 会话按 年/月/日 分目录, 直接递归枚举比自己拼日期稳。
    private static func scanCodex(within: TimeInterval) -> [(Entry, Date)] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles) else { return [] }

        var newest: [String: (URL, Date)] = [:]
        for case let f as URL in walker where f.pathExtension == "jsonl" {
            guard let m = modified(f), fresh(m, within) else { continue }
            let cwd = projectCwd(f)                   // 在 payload 里, 下面递归找
            if let cur = newest[cwd], cur.1 >= m { continue }
            newest[cwd] = (f, m)
        }
        return newest.map { cwd, v in
            (entry(cwd: cwd, fallbackName: v.0.deletingLastPathComponent().lastPathComponent,
                   at: v.1, tool: .codex), v.1)
        }
    }

    // MARK: - 公共

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func fresh(_ m: Date, _ within: TimeInterval) -> Bool {
        Date().timeIntervalSince(m) < within
    }

    private static func entry(cwd: String, fallbackName: String,
                              at m: Date, tool: Tool) -> Entry {
        let age = Date().timeIntervalSince(m)
        let name = cwd.isEmpty ? fallbackName : (cwd as NSString).lastPathComponent
        return Entry(name: name, ageSec: Int(age), busy: age < 10, tool: tool,
                     appID: SessionHost.appID(cwd: cwd, tool: tool))
    }

    /// 会话的工作目录。目录名是把路径里的 / 换成 - 的编码, 路径本身含 - 就解不回去,
    /// 所以从内容读 —— 两家的 transcript 都带 cwd(Codex 包在 payload 里)。
    /// 除了项目名, 这个完整路径还是和活进程 cwd 对账的钥匙(见 SessionHost)。
    private static func projectCwd(_ url: URL) -> String {
        if let cached = cwdCache[url.path] { return cached }
        var cwd = ""
        if let fh = try? FileHandle(forReadingFrom: url) {
            let head = fh.readData(ofLength: 64 * 1024)
            try? fh.close()
            for line in String(decoding: head, as: UTF8.self)
                .split(separator: "\n").prefix(20) {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) else { continue }
                if let hit = findString(obj, key: "cwd"), !hit.isEmpty {
                    cwd = hit
                    break
                }
            }
        }
        cwdCache[url.path] = cwd
        return cwd
    }

    /// 往下找一层 key。Claude 的 cwd 在顶层, Codex 的在 payload 里。
    private static func findString(_ obj: Any, key: String, depth: Int = 0) -> String? {
        guard depth < 3, let dict = obj as? [String: Any] else { return nil }
        if let v = dict[key] as? String { return v }
        for v in dict.values {
            if let hit = findString(v, key: key, depth: depth + 1) { return hit }
        }
        return nil
    }
}
