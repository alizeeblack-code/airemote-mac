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
        /// "user" / "assistant" / **"tools"**。
        /// tools 是合成的一条 —— 把连续的纯工具调用压成一行摘要, 见 condense。
        let role: String
        let text: String
        let tools: [String]   // 用了哪些工具(**带重复**, 手机端自己聚成 "Bash ×7")
        /// 正文被 maxChars 砍过。
        ///
        /// 手机端要**明说**"这里还有更多", 而不是只留一个省略号 —— 省略号
        /// 跟在半截代码块后面, 看起来就是渲染坏了(这条是用户实际反馈的)。
        let truncated: Bool
    }

    /// 最多返回几段**有正文的**回复。
    ///
    /// ⚠️ 关键是"有正文的" —— 原来按总轮数取 6, 实测四个真实会话里
    /// 6 轮有 3~5 轮正文是空的(只有一个工具名), 手机上就是一串空行,
    /// 真正想看的那段话反而被挤出屏幕。
    private static let maxTextTurns = 4
    /// 一条工具摘要里最多列几个 —— 一轮跑几十个工具是常事, 全给会撑爆 JSON。
    private static let maxToolsPerRun = 40
    /// 单条最多多少字。
    ///
    /// ⚠️ 原来是 1200, **太小了**。扫本机 792 条真实回复: 中位数只有 68 字,
    /// 但 p95 就到 1345、最长 4028 —— 也就是说恰恰是那些"写得最详细、最值得
    /// 你看"的回复会被腰斩, 而且截断点经常落在代码块中间, 看起来像 app 坏了。
    /// 6000 覆盖全部样本。
    ///
    /// 别担心体积: 4 段 × 6000 字撑死 24KB, 走的还是局域网, 而按中位数算
    /// 实际负载只有几百字节。
    private static let maxChars = 6000

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

    /// 尾部窗口逐级放大。
    ///
    /// ⚠️ 固定读 512K 是**不够的**, Codex 上会直接读空。实测某个
    /// rollout 文件 285MB, 里面 item_completed 7737 条、token_count 4252 条、
    /// reasoning 3866 条, 而真正的对话(message)只有 586 条 —— 最后 512K 里
    /// 一条 message 都没有, 详情页就显示"读不了这个会话"。
    ///
    /// 所以攒不够就往前多读一截。上限 32MB: 再大就该认命了, 总不能为了看
    /// 最后几句话把 285MB 全解一遍。
    private static let tailSteps = [512 * 1024, 4 * 1024 * 1024, 32 * 1024 * 1024]

    /// 只读尾部。
    ///
    /// ⚠️ `keep` 是**解 JSON 之前**的字符串预筛。32MB 尾部有几十万行,
    /// 每行都 JSONSerialization 一遍要好几秒; 而 99% 的行是工具输出,
    /// 一个 contains 就能筛掉, 代价可以忽略。
    private static func tailLines(_ url: URL, bytes: Int, keep: String) -> [String] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? fh.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").lazy
            // 从中间截断的第一行多半是残的
            .filter { $0.hasPrefix("{") && $0.contains(keep) }
            .map(String.init)
    }

    /// 逐级放大尾部窗口跑 parse, 攒够 maxTextTurns 段正文就停。
    private static func grow(_ url: URL, keep: String,
                             _ parse: ([String]) -> [Turn]) -> [Turn] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var best: [Turn] = []
        for bytes in tailSteps {
            best = parse(tailLines(url, bytes: bytes, keep: keep))
            if best.filter({ !$0.text.isEmpty }).count >= maxTextTurns { break }
            if bytes >= size { break }      // 整个文件都读完了, 再放大没意义
        }
        return condense(best)
    }

    private static func obj(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func clip(_ s: String) -> (text: String, cut: Bool) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxChars else { return (t, false) }
        return (String(t.prefix(maxChars)), true)
    }

    /// 把原始轮次压成"值得看的那几段"。
    ///
    /// 规则: 只有带正文的轮次才计入 maxTextTurns; 夹在中间的连续纯工具调用
    /// 合并成一条 role == "tools" 的摘要(而不是每个占一行空白)。
    ///
    /// 顺序: 输入是时间正序, 这里倒着走(先拿最新的, 因为要保的是尾巴),
    /// 最后再翻回正序。
    private static func condense(_ turns: [Turn]) -> [Turn] {
        var out: [Turn] = []          // 倒序累积
        var pending: [String] = []    // 比当前轮更新的那些工具, 等碰到正文再吐
        var textCount = 0

        for t in turns.reversed() {
            if t.text.isEmpty {
                // 纯工具轮。倒着走, 所以更老的要插到前面, 才能保住时间正序。
                pending.insert(contentsOf: t.tools, at: 0)
                continue
            }
            if !pending.isEmpty {
                out.append(Turn(role: "tools", text: "",
                                tools: Array(pending.prefix(maxToolsPerRun)),
                                truncated: false))
                pending = []
            }
            out.append(t)
            textCount += 1
            if textCount >= maxTextTurns { break }
        }
        // 整段都是工具调用(会话正跑在半路上)时, 这一条就是全部内容, 不能丢
        if !pending.isEmpty, textCount < maxTextTurns {
            out.append(Turn(role: "tools", text: "",
                            tools: Array(pending.prefix(maxToolsPerRun)),
                            truncated: false))
        }
        return out.reversed()
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
        // 预筛 "message": Claude 的对话记录一定有这个键, 工具输出行没有
        grow(url, keep: "\"message\"") { lines in
        var turns: [Turn] = []
        for line in lines {
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
            guard !clean.text.isEmpty || !tools.isEmpty else { continue }
            turns.append(Turn(role: type, text: clean.text, tools: tools,
                              truncated: clean.cut))
        }
        return turns
        }
    }

    // MARK: - Codex
    //
    // 结构和 Claude 完全不同: 对话在 payload.type == "message" 里,
    // 正文在 content 的 input_text / output_text 块。
    //
    // ⚠️ role 有 developer —— 那是注入的系统指令(skills 说明之类), 不是对话,
    // 必须滤掉, 否则详情页第一屏全是给模型看的提示词。
    private static func parseCodex(_ url: URL) -> [Turn] {
        // 预筛 "message": 把 item_completed / token_count / reasoning 全挡在
        // JSON 解析之外 —— 那是这个文件里 95% 的内容
        grow(url, keep: "\"message\"") { lines in
        var turns: [Turn] = []
        for line in lines {
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
            guard !clean.text.isEmpty else { continue }
            turns.append(Turn(role: role, text: clean.text, tools: [],
                              truncated: clean.cut))
        }
        return turns
        }
    }
}
