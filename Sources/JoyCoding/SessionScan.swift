import Foundation

/// Claude Code 的活跃会话。给手机遥控的状态区用 ——
/// 遥控的核心场景就是"人不在电脑前, 想知道跑完没"。
///
/// 数据来源是 ~/.claude/projects/<项目>/<会话>.jsonl 的文件修改时间:
/// 正在写入(10 秒内有更新) = 工作中。不解析 transcript 内部格式 ——
/// 那是 Claude Code 的私有结构, 版本一变就碎; mtime 谁也动不了。
enum SessionScan {

    struct Entry {
        let name: String        // 项目目录名, 从 transcript 的 cwd 字段取
        let ageSec: Int         // 距最后一次写入多久
        let busy: Bool
    }

    /// 项目名缓存: 文件路径 -> 名字。名字要读文件内容, 不能每 1.5s 轮询都读。
    private static var nameCache: [String: String] = [:]

    /// 最近活跃的会话, 每个项目只留最新的一条 ——
    /// 同项目开两个会话时显示两行一模一样的名字只是噪音。
    static func recent(limit: Int = 5, within: TimeInterval = 8 * 3600) -> [Entry] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return [] }

        let now = Date()
        var newestPerProject: [String: (URL, Date)] = [:]
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for f in files where f.pathExtension == "jsonl" {
                guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                      now.timeIntervalSince(m) < within else { continue }
                let key = dir.lastPathComponent
                if let cur = newestPerProject[key], cur.1 >= m { continue }
                newestPerProject[key] = (f, m)
            }
        }

        return newestPerProject.values
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { url, m in
                let age = now.timeIntervalSince(m)
                return Entry(name: projectName(url), ageSec: Int(age), busy: age < 10)
            }
    }

    /// 目录名是把路径里的 / 换成 - 的编码, 路径本身含 - 就解不回去。
    /// transcript 每行都带 cwd 字段, 从内容里读才可靠。
    private static func projectName(_ url: URL) -> String {
        if let cached = nameCache[url.path] { return cached }
        var name = url.deletingLastPathComponent().lastPathComponent
        if let fh = try? FileHandle(forReadingFrom: url) {
            let head = fh.readData(ofLength: 64 * 1024)
            try? fh.close()
            for line in String(decoding: head, as: UTF8.self)
                .split(separator: "\n").prefix(20) {
                if let d = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                    name = (cwd as NSString).lastPathComponent
                    break
                }
            }
        }
        nameCache[url.path] = name
        return name
    }
}
