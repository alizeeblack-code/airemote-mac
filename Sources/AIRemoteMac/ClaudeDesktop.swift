import Foundation

/// 读 Claude 桌面版自己的会话索引。
///
/// 为什么要读别人的私有存储: `claude://resume` 不是"切到已有会话", 而是
/// **把 CLI transcript 导入成一条新的桌面会话** —— 会话本来就在桌面版里跑着
/// 的话, 就会多出一条同名同目录的重复项(而且是同一份 transcript 上的第二个
/// shell)。要避开它, 必须先知道"这个 CLI 会话在桌面版里已经有条目了吗"。
///
/// ⚠️ 这是**别人的私有格式**, 版本一变就可能碎。所以每一步都能返回 nil,
/// 读不出来就退回原来的 deep link —— 最坏结果是多一条重复项, 和改动前一样,
/// 绝不因为读不懂而让"切过去"整个失效。
enum ClaudeDesktop {

    struct Session {
        /// 对应的 CLI 会话 id, 也就是 transcript 的文件名
        let cliID: String
        let cwd: String
        /// 侧栏上显示的标题。**导入进来的条目没有这个字段**(所以侧栏显示成
        /// 通用名), 正好可以用它区分"原生的"和"我们导入的"。
        let title: String
        let focusedAt: Double
    }

    /// ~/Library/Application Support/Claude/claude-code-sessions/<设备>/<组织>/local_*.json
    private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// 按 (目录 mtime) 缓存。会话有几十条, 每次跳转都全量解 JSON 没必要;
    /// 但也不能一直缓存 —— 新开的会话要能被认出来。
    private static var cache: [Session] = []
    private static var stamp = Date.distantPast
    private static let lock = NSLock()

    /// 这个 CLI 会话在桌面版里**已经有原生条目**了吗。
    ///
    /// 只认有标题的 —— 没标题的那些正是之前 deep link 导入出来的产物,
    /// 拿它去侧栏找行会找不到(侧栏显示的是通用占位名)。
    static func existing(cliID: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        refresh()
        return cache
            .filter { $0.cliID == cliID && !$0.title.isEmpty }
            .max { $0.focusedAt < $1.focusedAt }
    }

    private static func refresh() {
        guard Date().timeIntervalSince(stamp) > 5 else { return }
        stamp = Date()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                         options: .skipsHiddenFiles) else { return }
        var out: [Session] = []
        for case let f as URL in walker
        where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let cli = o["cliSessionId"] as? String, !cli.isEmpty,
                  // 归档过的不在侧栏上, 点不着
                  (o["isArchived"] as? Bool) != true
            else { continue }
            out.append(Session(cliID: cli,
                               cwd: (o["cwd"] as? String) ?? "",
                               title: (o["title"] as? String) ?? "",
                               focusedAt: (o["lastFocusedAt"] as? Double) ?? 0))
        }
        cache = out
    }
}
