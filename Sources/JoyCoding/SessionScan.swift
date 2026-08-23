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
    }

    /// 项目名缓存: 文件路径 -> 名字。名字要读文件内容, 不能每 1.5s 轮询都读。
    private static var nameCache: [String: String] = [:]

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
        return newest.values.map { url, m in
            (entry(name: projectName(url, key: "cwd"), at: m, tool: .claude), m)
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
            let name = projectName(f, key: "cwd")     // 在 payload 里, 下面递归找
            if let cur = newest[name], cur.1 >= m { continue }
            newest[name] = (f, m)
        }
        return newest.map { name, v in
            (entry(name: name, at: v.1, tool: .codex), v.1)
        }
    }

    // MARK: - 公共

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func fresh(_ m: Date, _ within: TimeInterval) -> Bool {
        Date().timeIntervalSince(m) < within
    }

    private static func entry(name: String, at m: Date, tool: Tool) -> Entry {
        let age = Date().timeIntervalSince(m)
        return Entry(name: name, ageSec: Int(age), busy: age < 10, tool: tool)
    }

    /// 目录名是把路径里的 / 换成 - 的编码, 路径本身含 - 就解不回去。
    /// 两家的 transcript 每行都带 cwd(Codex 包在 payload 里), 从内容读才可靠。
    private static func projectName(_ url: URL, key: String) -> String {
        if let cached = nameCache[url.path] { return cached }
        var name = url.deletingLastPathComponent().lastPathComponent
        if let fh = try? FileHandle(forReadingFrom: url) {
            let head = fh.readData(ofLength: 64 * 1024)
            try? fh.close()
            outer: for line in String(decoding: head, as: UTF8.self)
                .split(separator: "\n").prefix(20) {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) else { continue }
                if let cwd = findString(obj, key: key), !cwd.isEmpty {
                    name = (cwd as NSString).lastPathComponent
                    break outer
                }
            }
        }
        nameCache[url.path] = name
        return name
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
