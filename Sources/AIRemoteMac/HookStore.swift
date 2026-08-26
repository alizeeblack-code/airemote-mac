import Foundation

/// Claude Code 的 hook 推过来的实时会话状态。
///
/// 为什么需要它: 扫 transcript 有个死穴 —— "答完在等你追问" 和 "任务干完了"
/// 在文件里**写下来一模一样**(本机 30 个会话里 25 个都以 assistant/end_turn
/// 收尾), 而"卡在授权框"和"被限流了"根本不落文件。这几类状态只有 hook 给得出,
/// 恰恰又是"人不在电脑前"时最想知道的。
///
/// 定位是**增强不是替换**: 没装 hook、hook 被卸了、或者跑的是 Codex 时,
/// SessionScan 的 mtime 扫描照常工作 —— 这里只在有数据时把状态盖得更准。
final class HookStore {
    static let shared = HookStore()

    struct Live {
        var status: SessionScan.Status
        var cwd: String
        var lastMsg: String
        var turn: Int
        var at: Date
        var event: String       // 最后一个事件名, 只给 /hook/dump 调试看
    }

    /// transcript 路径 -> 状态。
    ///
    /// ⚠️ 用 transcript 路径当键, **不能用 cwd** —— cwd 是会变的: 会话里
    /// 跑一次 `cd` 就触发 CwdChanged, 实测同一个会话在日志里出现过三个不同
    /// cwd(项目根 → apps/ios → apps/ios/<模块>)。transcript 路径整个
    /// 会话生命周期不变, 而且 hook 每条 payload 都带。
    private var live: [String: Live] = [:]
    /// session_id -> transcript 路径。SessionEnd 只给 session_id, 得能反查。
    private var bySession: [String: String] = [:]
    private let lock = NSLock()

    /// hook 停了多久就不再信它。用户可能把 hook 卸了、Claude Code 崩了,
    /// 那样状态会永远冻在最后一帧 —— 显示"正在跑"而其实早没了比没状态更糟。
    /// 超时就当没有, 退回扫描结果。
    private let trustFor: TimeInterval = 4 * 3600

    // MARK: - 写入

    func ingest(_ body: String) {
        guard let d = body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ev = o["hook_event_name"] as? String
        else { return }

        // ⚠️ subagent 的事件要丢掉。它带的是**父会话的 session_id**, 照单全收的话
        // 一个 Explore 子任务跑完(SubagentStop)会把主会话标成"在等你输入",
        // 而主会话其实正忙着。agent_id 非空 = 这条来自子任务。
        if let aid = o["agent_id"] as? String, !aid.isEmpty { return }

        let sid = (o["session_id"] as? String) ?? ""
        let path = (o["transcript_path"] as? String) ?? bySession[sid] ?? ""
        guard !path.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if ev == "SessionEnd" {
            live.removeValue(forKey: path)
            bySession.removeValue(forKey: sid)
            return
        }

        var st: SessionScan.Status
        switch ev {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse",
             "PostToolBatch", "PostToolUseFailure", "PermissionDenied":
            st = .working
        case "Stop":
            // 本轮答完 = 球在用户这边。这是 transcript 里分不出来的那一档。
            st = .waiting
        case "StopFailure":
            st = .failed
        case "PermissionRequest":
            st = .blocked
        case "Notification":
            let t = (o["notification_type"] as? String) ?? ""
            if t.contains("permission") { st = .blocked }
            else if t.contains("idle")  { st = .waiting }
            else { return }             // 其它通知(auth_success 之类)不代表状态
        case "SessionStart":
            st = .waiting               // 刚开, 还没人说话
        default:
            return                      // 不认识的事件一律不动状态
        }

        var e = live[path] ?? Live(status: st, cwd: "", lastMsg: "",
                                   turn: 0, at: Date(), event: ev)
        e.status = st
        e.at = Date()
        e.event = ev
        if let c = o["cwd"] as? String, !c.isEmpty { e.cwd = c }
        if let m = o["last_assistant_message"] as? String { e.lastMsg = String(m.prefix(400)) }
        if let t = o["turn_number"] as? Int { e.turn = t }
        live[path] = e
        bySession[sid] = path

        prune()
    }

    /// 过期和超量清理。会话只增不减的话字典会一直长 —— SessionEnd 并不保证
    /// 每次都收得到(强杀终端就没有)。
    private func prune() {
        let cutoff = Date().addingTimeInterval(-trustFor)
        live = live.filter { $0.value.at > cutoff }
        if live.count > 200 { live.removeAll() }
        bySession = bySession.filter { live[$0.value] != nil }
    }

    // MARK: - 读取

    /// 某个 transcript 对应的实时状态。没有 hook 数据或已过期就返回 nil,
    /// 调用方退回自己的判断。
    func status(transcript path: String) -> Live? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = live[path], Date().timeIntervalSince(e.at) < trustFor else { return nil }
        return e
    }

    /// 调试用: 看 hook 到底推没推、推的是什么。
    func dump() -> String {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let items = live.map { path, e in
            """
            {"transcript":\(jsonEsc(path)),"status":\(jsonEsc(e.status.rawValue)),\
            "cwd":\(jsonEsc(e.cwd)),"event":\(jsonEsc(e.event)),"turn":\(e.turn),\
            "ageSec":\(Int(now.timeIntervalSince(e.at))),"lastMsg":\(jsonEsc(e.lastMsg))}
            """
        }.joined(separator: ",")
        return "{\"count\":\(live.count),\"sessions\":[\(items)]}"
    }

    private func jsonEsc(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let t = d.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(t.dropFirst().dropLast())
    }
}
