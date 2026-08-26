import Foundation

/// 从 transcript 里读出最后几轮对话, 给手机端的会话详情页用。
///
/// 遥控的核心场景是"人不在电脑前, 想知道跑完没" —— 光有状态还不够,
/// 还要能看见**它最后说了什么**, 才知道要不要走回去。
///
/// ⚠️ 这是本项目第一次解析 transcript 的**内部结构**。SessionScan 一直刻意
/// 只用 mtime, 理由是"各家私有格式, 版本一变就碎"。这个判断偏保守了 ——
/// 生态里已经有几个成熟工具(claude-code-log / claude-code-transcripts /
/// claude-session-viewer, 都是 MIT)长期在解析同一份文件。但**格式会漂这件事
/// 依然成立**, 所以这里的原则是: 解不出来就返回空, 让界面显示"看不了这个
/// 会话", 绝不崩、也绝不显示半截乱码。
enum SessionTranscript {

    struct Turn: Equatable {
        let role: String      // "user" / "assistant"
        let text: String
        let tools: [String]   // 这一轮用了哪些工具, 折叠成一行
    }

    /// 最多返回几轮。手机屏就那么大, 给多了也看不完。
    private static let maxTurns = 6
    /// 单条最多多少字 —— 有的回复几千字, 全塞进 JSON 会把 /state 之外的
    /// 这个接口撑得很慢, 而手机上也读不完。
    private static let maxChars = 1200

    // MARK: - 缓存

    /// 按 (路径, mtime) 缓存。解析要读几百 KB 并解 JSON, 不能每次点开都重来。
    private static var cache: [String: (mtime: Date, turns: [Turn])] = [:]
    private static let lock = NSLock()

    // MARK: - 入口

    /// 找到某个项目最新的 transcript 并读出最后几轮。
    static func recent(tool: SessionScan.Tool, project: String) -> [Turn] {
        guard let url = newestTranscript(tool: tool, project: project) else { return [] }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date.distantPast

        lock.lock()
        if let c = cache[url.path], c.mtime == mtime {
            lock.unlock()
            return c.turns
        }
        lock.unlock()

        let turns = tool == .claude ? parseClaude(url) : parseCodex(url)

        lock.lock()
        cache[url.path] = (mtime, turns)
        if cache.count > 50 { cache.removeAll() }   // 会话会不断新增, 别让缓存长疯
        lock.unlock()
        return turns
    }

    /// 该项目下最新的那个会话文件。项目名匹配用 SessionScan 同一套 cwd 判据。
    private static func newestTranscript(tool: SessionScan.Tool, project: String) -> URL? {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(tool == .claude ? ".claude/projects" : ".codex/sessions")
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: .skipsHiddenFiles) else { return nil }
        var best: (URL, Date)?
        for case let f as URL in walker where f.pathExtension == "jsonl" {
            guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            if let b = best, b.1 >= m { continue }
            // 项目名对得上才算。Claude 的目录名是编码过的路径, 取末段比;
            // Codex 的 cwd 在文件内容里, 交给 SessionScan 那套判据。
            guard matches(f, tool: tool, project: project) else { continue }
            best = (f, m)
        }
        return best?.0
    }

    private static func matches(_ url: URL, tool: SessionScan.Tool, project: String) -> Bool {
        let cwd = SessionScan.projectCwdPublic(url)
        if !cwd.isEmpty { return (cwd as NSString).lastPathComponent == project }
        // 读不到 cwd 时退回目录名末段, 和 SessionScan.shortFallback 同一逻辑
        let dir = url.deletingLastPathComponent().lastPathComponent
        return dir.split(separator: "-").last.map(String.init)?.hasPrefix(project) ?? false
    }

    // MARK: - 读文件尾

    /// 只读尾部。会话文件动辄几 MB, 而我们只要最后几轮。
    private static func tailLines(_ url: URL, bytes: Int = 512 * 1024) -> [String] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? fh.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("{") }   // 从中间截断的第一行多半是残的
    }

    private static func obj(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func clip(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > maxChars ? String(t.prefix(maxChars)) + "…" : t
    }

    // MARK: - Claude
    //
    // 每行一条记录, 对话在 type ∈ {user, assistant}, 正文在
    // message.content 的 text 块里。
    //
    // ⚠️ **不能直接取最后一行** —— 实测 30 个会话, 最后一行多数是元数据
    // (last-prompt / mode / custom-title / file-history-snapshot), 只有 3 个
    // 是对话记录。必须先过滤。
    private static func parseClaude(_ url: URL) -> [Turn] {
        var turns: [Turn] = []
        for line in tailLines(url) {
            guard let r = obj(line),
                  let type = r["type"] as? String,
                  type == "user" || type == "assistant",
                  let msg = r["message"] as? [String: Any] else { continue }

            var text = ""
            var tools: [String] = []
            if let s = msg["content"] as? String {
                text = s
            } else if let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks {
                    switch b["type"] as? String {
                    case "text":     text += (b["text"] as? String ?? "")
                    case "tool_use": tools.append(b["name"] as? String ?? "tool")
                    // thinking 故意跳过: 那是推理过程, 手机上看它没有意义,
                    // 而且很长, 会把真正的回复挤下去
                    default: break
                    }
                }
            }
            let clean = clip(text)
            guard !clean.isEmpty || !tools.isEmpty else { continue }
            turns.append(Turn(role: type, text: clean, tools: tools))
        }
        return Array(turns.suffix(maxTurns))
    }

    // MARK: - Codex
    //
    // 结构和 Claude 完全不同: 对话在 payload.type == "message" 里,
    // 正文在 content 的 input_text / output_text 块。
    //
    // ⚠️ role 有 developer —— 那是注入的系统指令(skills 说明之类), 不是对话,
    // 必须滤掉, 否则详情页第一屏全是给模型看的提示词。
    private static func parseCodex(_ url: URL) -> [Turn] {
        var turns: [Turn] = []
        for line in tailLines(url) {
            guard let r = obj(line),
                  let p = r["payload"] as? [String: Any],
                  p["type"] as? String == "message",
                  let role = p["role"] as? String,
                  role == "user" || role == "assistant" else { continue }

            var text = ""
            for b in (p["content"] as? [[String: Any]] ?? []) {
                if let t = b["text"] as? String { text += t }
            }
            let clean = clip(text)
            guard !clean.isEmpty else { continue }
            turns.append(Turn(role: role, text: clean, tools: []))
        }
        return Array(turns.suffix(maxTurns))
    }
}
