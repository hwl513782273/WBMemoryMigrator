import Foundation
import AppKit

// MARK: - 数据模型

struct ExportItem: Codable, Identifiable {
    var id: String { bundleRel }
    let category: String
    let realPath: String
    let bundleRel: String
    let homeRel: String?   // 相对家目录的路径（用户级条目用，导入时按当前家目录解析）
    let size: Int64
    let workspaceRoot: String?   // 原始工作区绝对路径（projectSpace 导入重映射用）
}

struct Manifest: Codable {
    let appVersion: String
    let createdAt: String
    let items: [ExportItem]
    let homeDir: String?   // 导出机器的家目录（用于导入时按原目录结构重建）

    init(appVersion: String, createdAt: String, items: [ExportItem], homeDir: String?) {
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.items = items
        self.homeDir = homeDir
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        items = try c.decode([ExportItem].self, forKey: .items)
        homeDir = try c.decodeIfPresent(String.self, forKey: .homeDir)
    }

    enum CodingKeys: String, CodingKey {
        case appVersion, createdAt, items, homeDir
    }
}

/// 项目空间迁移选择：工作区根绝对路径 -> 勾中的顶层条目名列表
struct ProjectSpaceSelection: Codable {
    var entries: [String: [String]]
    var isEmpty: Bool { entries.isEmpty }
}

/// 导出时可单独勾选的范围
struct ExportOptions {
    var longTermMemory: Bool   // 长期记忆文件（MEMORY.md / memory / 工作区记忆 / 兜底归档）
    var conversations: Bool    // 对话记忆（对话库快照 / sessions / projects）
    var skills: Bool           // 全部 Skill（用户级 + 工作区）
    var projectSpaces: Bool    // 项目空间（指定工作区的源码本体）
    var projectSelection: ProjectSpaceSelection
    var syncWorkspaceRegistry: Bool = true  // 导出后把已迁移/挪位工作区的注册路径同步修正到真实位置
    static let all = ExportOptions(longTermMemory: true, conversations: true, skills: true,
                                   projectSpaces: false,
                                   projectSelection: ProjectSpaceSelection(entries: [:]),
                                   syncWorkspaceRegistry: true)
}

/// UI 用的项目空间条目选项
struct WorkspaceEntryOption: Identifiable {
    let workspace: String
    let name: String
    let path: String
    let isDir: Bool
    var size: Int64          // 懒加载：先 0，后台逐个回填
    let excludedByDefault: Bool
    var id: String { path }
}

// 项目空间默认排除的膨胀项（默认不勾，可在 UI 手动加回）
let defaultProjectExcludes = Set<String>([
    "node_modules", ".git", "build", "DerivedData", ".build",
    "Pods", "vendor", "dist", "out", ".DS_Store", "staging"
])

// MARK: - 扩展

extension FileManager {
    func removeItemIfExists(atPath p: String) throws {
        if fileExists(atPath: p) { try removeItem(atPath: p) }
    }
}

// MARK: - 引擎

final class BackupEngine {
    static let shared = BackupEngine()
    private let fm = FileManager.default
    private let version = "1.0"

    // MARK: 路径

    private func homeDir() -> String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }

    private func wbDir() -> String {
        // 尊重 $HOME 环境变量（生产下等同于 NSHomeDirectory()，同时也便于测试重定向）
        (homeDir() as NSString).appendingPathComponent(".workbuddy")
    }

    private func safeName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    func fmt(_ b: Int64) -> String {
        let kb = Double(b) / 1024.0
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024.0)
    }

    func sizeOf(_ path: String) -> Int64 {
        var total: Int64 = 0
        guard let e = fm.enumerator(at: URL(fileURLWithPath: path),
                                   includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        for case let u as URL in e {
            if let s = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(s)
            }
        }
        return total
    }

    private func sqlEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: 命令执行

    private func run(_ launchPath: String, _ args: [String], currentDir: String? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cd = currentDir { p.currentDirectoryURL = URL(fileURLWithPath: cd) }
        let err = Pipe()
        var errData = Data()
        // 实时读取 stderr，防止输出超过 64KB 管道缓冲导致死锁
        err.fileHandleForReading.readabilityHandler = { h in errData.append(h.availableData) }
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        if p.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "BackupEngine",
                          code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "命令失败: \(args.joined(separator: " "))\n\(msg)"])
        }
    }

    // MARK: 工作区枚举（读 workspaces 表真实路径）

    func workspacePaths() -> [String] {
        let db = (wbDir() as NSString).appendingPathComponent("workbuddy.db")
        guard fm.fileExists(atPath: db) else { return [] }
        return sqliteOut(db, "SELECT path FROM workspaces;")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 快速枚举：只列名字与排除态，不算大小（首屏秒出，大小由 UI 后台逐个回填）
    func projectSpaceOptionsFast(log: ((String) -> Void)? = nil) -> [WorkspaceEntryOption] {
        var out: [WorkspaceEntryOption] = []
        for wp in resolveWorkspacesDetailed(log: log).map({ $0.effective }) {
            guard let urls = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: wp),
                           includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for u in urls {
                let name = u.lastPathComponent
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                out.append(WorkspaceEntryOption(workspace: wp, name: name, path: u.path,
                                                isDir: isDir, size: 0,
                                                excludedByDefault: defaultProjectExcludes.contains(name)))
            }
        }
        return out
    }

    /// 完整枚举（含递归算大小，较慢；保留给需要一次性全量的调用方）
    func projectSpaceOptions(log: ((String) -> Void)? = nil) -> [WorkspaceEntryOption] {
        var out: [WorkspaceEntryOption] = []
        for wp in resolveWorkspacesDetailed(log: log).map({ $0.effective }) {
            guard let urls = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: wp),
                           includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { continue }
            for u in urls {
                let name = u.lastPathComponent
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let sz = self.sizeOf(u.path)
                out.append(WorkspaceEntryOption(workspace: wp, name: name, path: u.path,
                                                isDir: isDir, size: sz,
                                                excludedByDefault: defaultProjectExcludes.contains(name)))
            }
        }
        return out
    }

    // MARK: 导出

    /// 导出前展示给用户的「数据来源位置」清单（仅返回实际存在、且被勾选的路径）
    func sourcePaths(options: ExportOptions = .all) -> [String] {
        let wb = wbDir()
        var paths: [String] = []
        if options.longTermMemory {
            paths.append((wb as NSString).appendingPathComponent("MEMORY.md"))
            paths.append((wb as NSString).appendingPathComponent("memory"))
            paths.append((wb as NSString).appendingPathComponent("workspace_memory_archive"))
        }
        if options.conversations {
            paths.append((wb as NSString).appendingPathComponent("workbuddy.db"))
            paths.append((wb as NSString).appendingPathComponent("sessions"))
            paths.append((wb as NSString).appendingPathComponent("projects"))
        }
        if options.skills {
            paths.append((wb as NSString).appendingPathComponent("skills"))
        }
        if options.projectSpaces {
            // 项目空间只列工作区根（避免逐条目刷屏）
            for (ws, _) in options.projectSelection.entries {
                paths.append(ws)
            }
        }
        for wp in workspacePaths() {
            if options.longTermMemory {
                paths.append((wp as NSString).appendingPathComponent(".workbuddy/memory"))
            }
            if options.skills {
                paths.append((wp as NSString).appendingPathComponent(".workbuddy/skills"))
            }
        }
        return paths.filter { fm.fileExists(atPath: $0) }
    }

    /// 导入时按当前家目录解析目标路径（用户级条目用 homeRel，工作区用原绝对路径）
    private func resolveDst(_ item: ExportItem) -> String {
        let curHome = self.homeDir()
        if let hr = item.homeRel, !hr.isEmpty {
            return (curHome as NSString).appendingPathComponent(hr)
        }
        return item.realPath
    }

    func export(to zipPath: String, log: @escaping (String) -> Void,
                progress: @escaping (Double, String) -> Void,
                options: ExportOptions = .all) throws {
        let staging = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wbmem_export_\(Int(Date().timeIntervalSince1970))")
        try fm.removeItemIfExists(atPath: staging)
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)

        var items: [ExportItem] = []
        let h = self.homeDir()
        let prefix = (h as NSString).appendingPathComponent("")   // home + "/"
        let wb = wbDir()

        // 构造待收集任务清单（按勾选范围过滤，可计数，便于进度条）
        struct ColTask { let src: String; let cat: String; let rel: String; var workspaceRoot: String? = nil }
        var tasks: [ColTask] = []
        if options.longTermMemory {
            tasks.append(ColTask(src: (wb as NSString).appendingPathComponent("MEMORY.md"),
                                 cat: "userMemory", rel: "MEMORY.md"))
            tasks.append(ColTask(src: (wb as NSString).appendingPathComponent("memory"),
                                 cat: "memoryCache", rel: "memory_cache"))
            tasks.append(ColTask(src: (wb as NSString).appendingPathComponent("workspace_memory_archive"),
                                 cat: "workspaceArchive", rel: "workspace_archive"))
        }
        if options.conversations {
            tasks.append(ColTask(src: (wb as NSString).appendingPathComponent("sessions"),
                                 cat: "sessions", rel: "conversations/sessions"))
            tasks.append(ColTask(src: (wb as NSString).appendingPathComponent("projects"),
                                 cat: "projects", rel: "conversations/projects"))
        }
        if options.skills {
            tasks.append(ColTask(src: (wb as NSString).appendingPathComponent("skills"),
                                 cat: "userSkills", rel: "skills"))
        }
        let resolvedWS = resolveWorkspacesDetailed(log: log)
        for rw in resolvedWS {
            let wp = rw.effective
            let key = safeName(wp)
            if options.longTermMemory {
                tasks.append(ColTask(src: (wp as NSString).appendingPathComponent(".workbuddy/memory"),
                                     cat: "workspaceMemory", rel: "workspaces/\(key)/memory", workspaceRoot: wp))
            }
            if options.skills {
                tasks.append(ColTask(src: (wp as NSString).appendingPathComponent(".workbuddy/skills"),
                                     cat: "workspaceSkills", rel: "workspaces/\(key)/skills", workspaceRoot: wp))
            }
        }
        // 项目空间：仅收集用户勾选的工作区顶层条目
        if options.projectSpaces {
            for (ws, entryNames) in options.projectSelection.entries {
                let key = safeName(ws)
                for name in entryNames {
                    let src = (ws as NSString).appendingPathComponent(name)
                    let rel = "workspaces/\(key)/\(name)"
                    tasks.append(ColTask(src: src, cat: "projectSpace", rel: rel, workspaceRoot: ws))
                }
            }
        }

        let n = Double(max(tasks.count, 1))
        progress(0.02, "正在收集文件…")

        for (i, t) in tasks.enumerated() {
            guard fm.fileExists(atPath: t.src) else {
                log("跳过(不存在): \(t.src)")
                progress(0.6 * Double(i + 1) / n, "正在收集文件…")
                continue
            }
            let dest = (staging as NSString).appendingPathComponent(t.rel)
            try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try fm.copyItem(atPath: t.src, toPath: dest)
            let sz = self.sizeOf(t.src)
            // 项目空间条目不写 homeRel（导入时按映射重定位），其余按是否在家目录决定
            let computedHomeRel: String? = (t.workspaceRoot == nil)
                ? (t.src.hasPrefix(prefix) ? String(t.src.dropFirst(prefix.count)) : nil)
                : nil
            items.append(ExportItem(category: t.cat, realPath: t.src, bundleRel: t.rel,
                                    homeRel: computedHomeRel, size: sz, workspaceRoot: t.workspaceRoot))
            log("已收集 \(t.cat)：\(t.src) (\(self.fmt(sz)))")
            progress(0.6 * Double(i + 1) / n, "正在收集文件…")
        }

        // 对话库一致性快照（属于「对话记忆」类）
        if options.conversations {
            progress(0.62, "正在快照对话库…")
            let dbSrc = (wb as NSString).appendingPathComponent("workbuddy.db")
            if fm.fileExists(atPath: dbSrc) {
                let dbDest = (staging as NSString).appendingPathComponent("conversations/workbuddy.db")
                try fm.createDirectory(atPath: (dbDest as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                try run("/usr/bin/sqlite3", [dbSrc, ".backup '\(dbDest)'"])
                let sz = sizeOf(dbDest)
                let dbHomeRel: String? = dbSrc.hasPrefix(prefix) ? String(dbSrc.dropFirst(prefix.count)) : nil
                items.append(ExportItem(category: "conversationsDB",
                                        realPath: dbSrc,
                                        bundleRel: "conversations/workbuddy.db",
                                        homeRel: dbHomeRel,
                                        size: sz, workspaceRoot: nil))
                log("已快照对话库 conversations/workbuddy.db (\(fmt(sz)))")
            }
        }
        progress(0.7, "正在写入清单…")

        // 清单
        let manifest = Manifest(appVersion: version,
                                createdAt: ISO8601DateFormatter().string(from: Date()),
                                items: items, homeDir: homeDir())
        let mdata = try JSONEncoder().encode(manifest)
        try mdata.write(to: URL(fileURLWithPath:
            (staging as NSString).appendingPathComponent("manifest.json")))

        // 打包（异步执行，按 zip 体积增长实时反馈进度，避免长时间停在 78%）
        progress(0.78, "正在打包压缩…（大包耗时较久，进度按压缩体积估算）")
        try fm.removeItemIfExists(atPath: zipPath)
        let stagingBytes = max(sizeOf(staging), 1)
        let zipProc = Process()
        zipProc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -y：符号链接按链接本身存储，不跟随（防止链接指向 /Applications 等巨目录甚至链接环路）
        zipProc.arguments = ["-r", "-q", "-y", zipPath, "."]
        zipProc.currentDirectoryURL = URL(fileURLWithPath: staging)
        let zipErr = Pipe()
        var zipErrData = Data()
        zipErr.fileHandleForReading.readabilityHandler = { h in zipErrData.append(h.availableData) }
        zipProc.standardError = zipErr
        try zipProc.run()
        while zipProc.isRunning {
            Thread.sleep(forTimeInterval: 0.5)
            var frac = 0.0
            if let attr = try? fm.attributesOfItem(atPath: zipPath),
               let bytes = attr[.size] as? Int64 {
                frac = min(Double(bytes) / Double(stagingBytes), 1.0)
            }
            progress(0.78 + 0.2 * frac, "正在打包压缩…（大包耗时较久，进度按压缩体积估算）")
        }
        zipProc.waitUntilExit()
        zipErr.fileHandleForReading.readabilityHandler = nil
        if zipProc.terminationStatus != 0 {
            let msg = String(data: zipErrData, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "BackupEngine",
                          code: Int(zipProc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "打包失败: \(msg)"])
        }
        progress(1.0, "完成")
        log("打包完成：\(zipPath)  共 \(items.count) 项")
        try? fm.removeItem(atPath: staging)

        // 导出后：把已迁移/挪位工作区的注册路径同步修正到真实位置（反向软链保留，兜底不破坏）
        if options.syncWorkspaceRegistry {
            let db = (wbDir() as NSString).appendingPathComponent("workbuddy.db")
            if fm.fileExists(atPath: db) {
                var fixed = 0
                for rw in resolvedWS where rw.effective != rw.registered {
                    let eo = sqlEsc(rw.registered), en = sqlEsc(rw.effective)
                    try? run("/usr/bin/sqlite3", [db, "DELETE FROM workspaces WHERE path='\(en)' AND path <> '\(eo)';"])
                    try? run("/usr/bin/sqlite3", [db, "UPDATE workspaces SET path='\(en)' WHERE path='\(eo)';"])
                    try? run("/usr/bin/sqlite3", [db, "INSERT OR IGNORE INTO workspaces(path, last_opened_at) VALUES('\(en)', strftime('%s','now')*1000);"])
                    fixed += 1
                    log("已同步修正 WorkBuddy 注册路径: \(rw.registered) → \(rw.effective)\(rw.isSymlinkMigration ? "（反向软链保留，兜底不破坏）" : "")")
                }
                if fixed > 0 {
                    log("共修正 \(fixed) 个工作区的注册路径（WorkBuddy 重新打开即认新位置）")
                }
            }
        }
    }

    // MARK: 导入范围过滤

    enum ConflictPolicy: String, CaseIterable {
        case alwaysOverwrite = "始终覆盖"
        case keepNewer = "保留较新"
        case skipConflicts = "跳过冲突"
    }

    struct ImportOptions {
        var memory = true
        var conversations = true
        var skills = true
        var projectSpaces = true
        // 对话自选：nil=恢复包内全部；非 nil=只保留集合内会话（其余 db 行与对话文件删除）
        var selectedSessions: Set<String>? = nil
        // 账号过户：nil=自动探测本机现有账号 id
        var targetUserId: String? = nil
        // 目标工作区不存在时：false=自动创建并注册（默认），true=归档到 workspace_memory_archive
        var archiveMissingWorkspaces = false
        // 与本机现有文件冲突时的策略
        var conflictPolicy: ConflictPolicy = .alwaysOverwrite

        func allows(_ category: String) -> Bool {
            switch category {
            case "userMemory", "memoryCache", "workspaceArchive", "workspaceMemory":
                return memory
            case "sessions", "projects", "conversationsDB":
                return conversations
            case "userSkills", "workspaceSkills":
                return skills
            case "projectSpace":
                return projectSpaces
            default:
                return true
            }
        }
    }

    struct ImportCategorySummary {
        let key: String      // memory / conversations / skills / projectSpaces
        let count: Int
        let size: Int64
    }

    private func groupKey(_ cat: String) -> String {
        switch cat {
        case "userMemory", "memoryCache", "workspaceArchive", "workspaceMemory":
            return "memory"
        case "sessions", "projects", "conversationsDB":
            return "conversations"
        case "userSkills", "workspaceSkills":
            return "skills"
        case "projectSpace":
            return "projectSpaces"
        default:
            return "other"
        }
    }

    /// 包内各类别统计（供导入范围勾选显示）
    func importSummary(zip: String) throws -> [ImportCategorySummary] {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wbmem_sum_\(Int(Date().timeIntervalSince1970))")
        try fm.removeItemIfExists(atPath: tmp)
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", zip, "-d", tmp])
        let man = (tmp as NSString).appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: man))
        let m = try JSONDecoder().decode(Manifest.self, from: data)
        defer { try? fm.removeItem(atPath: tmp) }
        var agg: [String: (Int, Int64)] = [:]
        for item in m.items {
            let k = groupKey(item.category)
            let e = agg[k] ?? (0, 0)
            agg[k] = (e.0 + 1, e.1 + item.size)
        }
        var out: [ImportCategorySummary] = []
        for k in ["memory", "conversations", "skills", "projectSpaces"] {
            if let e = agg[k] { out.append(ImportCategorySummary(key: k, count: e.0, size: e.1)) }
        }
        return out
    }

    // MARK: 预览

    /// 冲突标注：对比包内文件与本机现有目标文件的修改时间
    private func conflictNote(dst: String, src: String) -> String {
        guard fm.fileExists(atPath: dst) else { return "  （新增）" }
        let ld = (try? fm.attributesOfItem(atPath: dst)[.modificationDate] as? Date) ?? nil
        let pd = (try? fm.attributesOfItem(atPath: src)[.modificationDate] as? Date) ?? nil
        guard let l = ld, let p = pd else { return "  ⚠️ 与本机现有文件冲突" }
        if p > l.addingTimeInterval(1) { return "  ⚠️ 包内较新（将覆盖本机）" }
        if p < l.addingTimeInterval(-1) { return "  ⚠️ 本机较新（导入将被包内版本替换）" }
        return "  （与本机一致）"
    }

    /// 导入预览：返回「将恢复到本机的目标路径」清单（工作区不存在时标注跳过）
    func preview(zip: String, options: ImportOptions? = nil,
                 projectTargets: [String: String] = [:]) throws -> [String] {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wbmem_prev_\(Int(Date().timeIntervalSince1970))")
        try fm.removeItemIfExists(atPath: tmp)
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", zip, "-d", tmp])
        let man = (tmp as NSString).appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: man))
        let m = try JSONDecoder().decode(Manifest.self, from: data)
        defer { try? fm.removeItem(atPath: tmp) }
        var lines: [String] = []
        for item in m.items {
            if let o = options, !o.allows(item.category) { continue }
            let src = (tmp as NSString).appendingPathComponent(item.bundleRel)
            if item.category == "projectSpace" {
                var note = "未选目录→自动落位"
                var dst = item.realPath
                if let root = item.workspaceRoot {
                    if let nr = projectTargets[root] {
                        let entryName = (item.realPath as NSString).lastPathComponent
                        dst = (nr as NSString).appendingPathComponent(entryName)
                        note = "已选目标目录"
                    } else if !fm.fileExists(atPath: root) {
                        let ar = autoRoot(for: root, manifestHome: m.homeDir)
                        // realPath 已含条目名，只替换工作区根部分
                        let entryName = (item.realPath as NSString).lastPathComponent
                        dst = (ar as NSString).appendingPathComponent(entryName)
                        note = "原路径不存在→自动创建并注册: \(ar)"
                    }
                }
                lines.append("→ \(dst)  （项目空间 · \(fmt(item.size)) · \(note)）\(conflictNote(dst: dst, src: src))")
                continue
            }
            var dst = resolveDst(item)
            var note = ""
            if item.category == "workspaceMemory" || item.category == "workspaceSkills" {
                let oldWsRoot = item.workspaceRoot
                    ?? (((dst as NSString).deletingLastPathComponent) as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: oldWsRoot) {
                    let sub = item.category == "workspaceMemory" ? "memory" : "skills"
                    let newRoot = autoRoot(for: oldWsRoot, manifestHome: m.homeDir)
                    dst = (newRoot as NSString).appendingPathComponent(".workbuddy/\(sub)")
                    note = "  ⚠️ 目标工作区不存在→自动创建并注册: \(newRoot)"
                }
            }
            lines.append("→ \(dst)  （\(item.category) · \(fmt(item.size))）\(note)\(conflictNote(dst: dst, src: src))")
        }
        return lines
    }

    struct PackageConversation: Identifiable {
        let id: String
        let title: String
        let cwd: String
        let userId: String
        let updatedAt: Int64
    }

    private func sqliteOut(_ db: String, _ sql: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db, sql]
        let out = Pipe()
        var outData = Data()
        // 实时读取 stdout，防 >64KB 管道死锁
        out.fileHandleForReading.readabilityHandler = { h in outData.append(h.availableData) }
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        return String(data: outData, encoding: .utf8) ?? ""
    }

    private func parseSessionsDB(at db: String) -> [PackageConversation] {
        guard fm.fileExists(atPath: db) else { return [] }
        let sql = "SELECT id || char(31) || COALESCE(NULLIF(custom_title,''), IFNULL(title,'(无标题)')) || char(31) || IFNULL(cwd,'') || char(31) || user_id || char(31) || IFNULL(updated_at,0) FROM sessions ORDER BY updated_at DESC;"
        let out = sqliteOut(db, sql)
        return out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\u{1F}")
            guard f.count >= 5 else { return nil }
            return PackageConversation(id: f[0], title: f[1], cwd: f[2],
                                       userId: f[3], updatedAt: Int64(f[4]) ?? 0)
        }
    }

    /// 包内会话清单（供导入侧勾选）
    func conversationsInPackage(zip: String) throws -> [PackageConversation] {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wbmem_conv_\(Int(Date().timeIntervalSince1970))")
        try fm.removeItemIfExists(atPath: tmp)
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        try run("/usr/bin/unzip", ["-q", zip, "-d", tmp])
        return parseSessionsDB(at: (tmp as NSString).appendingPathComponent("conversations/workbuddy.db"))
    }

    /// 本机现有会话最多的 user_id（账号过户默认目标）
    func localUserId() -> String? {
        let db = (wbDir() as NSString).appendingPathComponent("workbuddy.db")
        guard fm.fileExists(atPath: db) else { return nil }
        let out = sqliteOut(db, "SELECT user_id FROM sessions GROUP BY user_id ORDER BY count(*) DESC LIMIT 1;")
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 本机现有会话条数（导入覆盖警示用）
    func localSessionCount() -> Int {
        let db = (wbDir() as NSString).appendingPathComponent("workbuddy.db")
        guard fm.fileExists(atPath: db) else { return 0 }
        return Int(sqliteOut(db, "SELECT count(*) FROM sessions;").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    struct ResolvedWorkspace {
        let registered: String        // workspaces 表登记路径
        let effective: String         // 实际收集使用的路径
        let isSymlinkMigration: Bool  // 原位置为反向软链（SpaceMover 式迁移）
    }

    func isSymlinkPath(_ p: String) -> Bool {
        guard let rv = try? fm.attributesOfItem(atPath: p)[.type] as? FileAttributeType else { return false }
        return rv == .typeSymbolicLink
    }

    /// 导出侧工作区解析：原位 / 反向软链迁移（SpaceMover 式）/ 挪位自动探测，三类判定
    func resolveWorkspacesDetailed(log: ((String) -> Void)? = nil) -> [ResolvedWorkspace] {
        var out: [ResolvedWorkspace] = []
        for wp in workspacePaths() {
            if fm.fileExists(atPath: wp) {
                if isSymlinkPath(wp) {
                    // SpaceMover 式迁移：原位置是反向软链，真实数据在链接目标
                    let real = (try? fm.destinationOfSymbolicLink(atPath: wp)) ?? wp
                    let effective = fm.fileExists(atPath: real) ? real : wp
                    out.append(ResolvedWorkspace(registered: wp, effective: effective, isSymlinkMigration: true))
                    log?("检测到已迁移工作区（反向软链）: 「\((wp as NSString).lastPathComponent)」→ 真实位置 \(effective)（本次按真实位置收集）")
                } else {
                    out.append(ResolvedWorkspace(registered: wp, effective: wp, isSymlinkMigration: false))
                }
                continue
            }
            let name = (wp as NSString).lastPathComponent
            let hits = findFolder(named: name)
            if hits.count == 1 {
                out.append(ResolvedWorkspace(registered: wp, effective: hits[0], isSymlinkMigration: false))
                log?("已探测到工作区挪位: 「\(name)」\(wp) → \(hits[0])（本次按新位置收集）")
            } else if hits.count > 1 {
                let cand = hits.prefix(3).joined(separator: "  |  ")
                log?("⚠️ 工作区「\(name)」命中 \(hits.count) 处，无法自动确定：\(cand)\(hits.count > 3 ? " 等" : "")。本次导出跳过，请在「扫描设置」清理或手动处理")
            } else {
                log?("⚠️ 工作区「\(name)」登记路径已失效且未找到新位置（含自定义扫描路径），本次导出跳过其数据")
            }
        }
        return out
    }

    func resolveWorkspaces(log: ((String) -> Void)? = nil) -> [String] {
        resolveWorkspacesDetailed(log: log).map { $0.effective }
    }

    /// 工作区缺失时的落位：优先按原 home 相对结构重建（/Users/old/Downloads/X → ~/Downloads/X），
    /// 原路径不在家目录内（如外置盘）或旧清单未记录 home 时回退 ~/WorkBuddy/<名>
    func autoRoot(for oldRoot: String, manifestHome: String?) -> String {
        // 老包无 homeDir 字段时的兜底推断：/Users/<名>/... 且 <名> 与当前用户一致 → 原 home 即当前 home
        var inferredHome: String? = manifestHome
        if (inferredHome == nil || inferredHome!.isEmpty), oldRoot.hasPrefix("/Users/") {
            let comps = oldRoot.split(separator: "/")
            if comps.count >= 2 {
                let name = String(comps[1])
                if name == (homeDir() as NSString).lastPathComponent {
                    inferredHome = "/Users/\(name)"
                }
            }
        }
        if let oh = inferredHome, !oh.isEmpty, oldRoot.hasPrefix(oh), oldRoot != oh {
            let rel = String(oldRoot.dropFirst(oh.count))
            if rel.hasPrefix("/") {
                let preferred = (homeDir() as NSString).appendingPathComponent(rel)
                if !fm.fileExists(atPath: preferred) { return preferred }
                // 被占用：加 -imported 后缀，绝不覆盖
                var n = 1
                while true {
                    let cand = n == 1 ? preferred + "-imported" : preferred + "-imported-\(n)"
                    if !fm.fileExists(atPath: cand) { return cand }
                    n += 1
                }
            }
        }
        return wsAutoCreateRoot(oldRoot)
    }

    /// 工作区缺失时的自动创建目标：~/WorkBuddy/<名>（被占用则 -imported 后缀）
    func wsAutoCreateRoot(_ oldRoot: String) -> String {
        let name = (oldRoot as NSString).lastPathComponent
        let base = (homeDir() as NSString).appendingPathComponent("WorkBuddy")
        var root = (base as NSString).appendingPathComponent(name)
        if root == oldRoot { return root }
        var n = 1
        while fm.fileExists(atPath: root) {
            n += 1
            root = (base as NSString).appendingPathComponent(n == 2 ? "\(name)-imported" : "\(name)-imported-\(n - 1)")
        }
        return root
    }

    /// 按文件夹名搜索（内置常见位置深度 4；用户自定义扫描根深度 6），返回全部命中
    func findFolder(named name: String, maxDepth: Int = 4) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        let home = homeDir()
        var roots: [(String, Int)] = [(home + "/WorkBuddy", maxDepth),
                                      (home + "/Downloads", maxDepth),
                                      (home + "/Desktop", maxDepth),
                                      (home + "/Documents", maxDepth),
                                      (home, maxDepth)]
        for c in customScanRoots() { roots.append((c, 6)) }
        // 扫描禁区：媒体/系统目录（相册图库是 TCC 受保护项，误碰会弹照片权限）
        let skipDirs: Set<String> = ["Library", "Pictures", "Movies", "Music", "Public",
                                     "Applications", "Photos Library.photoslibrary"]
        func walk(_ dir: String, _ depth: Int, _ limit: Int) {
            guard depth <= limit,
                  let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for it in items {
                if it.hasPrefix(".") || skipDirs.contains(it) { continue }
                let p = (dir as NSString).appendingPathComponent(it)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
                if it == name { out.append(p) }
                walk(p, depth + 1, limit)
            }
        }
        for (r, md) in roots {
            if seen.contains(r) || !fm.fileExists(atPath: r) { continue }
            seen.insert(r)
            walk(r, 1, md)
        }
        return Array(Set(out)).sorted()
    }

    // MARK: 自定义扫描根目录（用户指定的「挪入收容所」路径，持久化到 ~/.workbuddy/scan_roots.txt）

    func customScanRoots() -> [String] {
        let f = (wbDir() as NSString).appendingPathComponent("scan_roots.txt")
        guard let t = try? String(contentsOfFile: f, encoding: .utf8) else { return [] }
        return t.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && fm.fileExists(atPath: $0) }
    }

    func setCustomScanRoots(_ roots: [String]) {
        let f = (wbDir() as NSString).appendingPathComponent("scan_roots.txt")
        try? roots.joined(separator: "\n")
            .write(to: URL(fileURLWithPath: f), atomically: true, encoding: .utf8)
    }

    /// 读取备份内包含的项目空间工作区根（供导入侧映射目标目录）
    func projectSpaceWorkspaces(from zip: String) throws -> [String] {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wbmem_ps_\(Int(Date().timeIntervalSince1970))")
        try fm.removeItemIfExists(atPath: tmp)
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", zip, "-d", tmp])
        let man = (tmp as NSString).appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: man))
        let m = try JSONDecoder().decode(Manifest.self, from: data)
        defer { try? fm.removeItem(atPath: tmp) }
        let roots = Set(m.items.filter { $0.category == "projectSpace" }
                            .compactMap { $0.workspaceRoot })
        return Array(roots).sorted()
    }

    struct PackageInfo {
        let previewLines: [String]
        let summary: [ImportCategorySummary]
        let conversations: [PackageConversation]
        let projectRoots: [String]
    }

    /// 单次解压获取全部导入前信息（预览/分类统计/会话清单/项目空间根）
    func inspectPackage(zip: String, options: ImportOptions? = nil) throws -> PackageInfo {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wbmem_inspect_\(Int(Date().timeIntervalSince1970))_\(Int.random(in: 100...999))")
        try fm.removeItemIfExists(atPath: tmp)
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        try run("/usr/bin/unzip", ["-q", zip, "-d", tmp])
        let man = (tmp as NSString).appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: man))
        let m = try JSONDecoder().decode(Manifest.self, from: data)

        var lines: [String] = []
        for item in m.items {
            if let o = options, !o.allows(item.category) { continue }
            let src = (tmp as NSString).appendingPathComponent(item.bundleRel)
            if item.category == "projectSpace" {
                var note = "未选目录→自动落位"
                var dst = item.realPath
                if let root = item.workspaceRoot, !fm.fileExists(atPath: root) {
                    let ar = autoRoot(for: root, manifestHome: m.homeDir)
                    let entryName = (item.realPath as NSString).lastPathComponent
                    dst = (ar as NSString).appendingPathComponent(entryName)
                    note = "原路径不存在→自动创建并注册: \(ar)"
                }
                lines.append("→ \(dst)  （项目空间 · \(fmt(item.size)) · \(note)）\(conflictNote(dst: dst, src: src))")
                continue
            }
            var dst = resolveDst(item)
            var note = ""
            if item.category == "workspaceMemory" || item.category == "workspaceSkills" {
                let oldWsRoot = item.workspaceRoot
                    ?? (((dst as NSString).deletingLastPathComponent) as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: oldWsRoot) {
                    let sub = item.category == "workspaceMemory" ? "memory" : "skills"
                    let newRoot = autoRoot(for: oldWsRoot, manifestHome: m.homeDir)
                    dst = (newRoot as NSString).appendingPathComponent(".workbuddy/\(sub)")
                    note = "  ⚠️ 目标工作区不存在→自动创建并注册: \(newRoot)"
                }
            }
            lines.append("→ \(dst)  （\(item.category) · \(fmt(item.size))）\(note)\(conflictNote(dst: dst, src: src))")
        }

        var agg: [String: (Int, Int64)] = [:]
        for item in m.items {
            let k = groupKey(item.category)
            let e = agg[k] ?? (0, 0)
            agg[k] = (e.0 + 1, e.1 + item.size)
        }
        var summary: [ImportCategorySummary] = []
        for k in ["memory", "conversations", "skills", "projectSpaces"] {
            if let e = agg[k] { summary.append(ImportCategorySummary(key: k, count: e.0, size: e.1)) }
        }

        let convs = parseSessionsDB(at: (tmp as NSString).appendingPathComponent("conversations/workbuddy.db"))
        let roots = Set(m.items.filter { $0.category == "projectSpace" }
                            .compactMap { $0.workspaceRoot })
        return PackageInfo(previewLines: lines, summary: summary,
                           conversations: convs, projectRoots: Array(roots).sorted())
    }

    // MARK: 导入

    func importBackup(from zip: String, log: @escaping (String) -> Void,
                      progress: @escaping (Double, String) -> Void,
                      projectTargets: [String: String] = [:],
                      importOptions: ImportOptions = ImportOptions()) throws {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wbmem_imp_\(Int(Date().timeIntervalSince1970))")
        try fm.removeItemIfExists(atPath: tmp)
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", zip, "-d", tmp])
        progress(0.1, "正在解压备份…")

        let man = (tmp as NSString).appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: man))
        let m = try JSONDecoder().decode(Manifest.self, from: data)

        // 账号过户：覆盖前先探测本机现有账号 id（覆盖后原 user_id 信息仍在会话行里，但本机旧库已无）
        let detectedLocalUserId = localUserId()

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupRoot = (wbDir() as NSString).appendingPathComponent("migrate_backups/\(ts)")
        try fm.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)

        let total = Double(max(m.items.count, 1))
        var skipped = 0
        for (i, item) in m.items.enumerated() {
            if !importOptions.allows(item.category) {
                skipped += 1
                log("按导入范围跳过: \(item.category) \(item.bundleRel)")
                continue
            }
            restore(item: item, fromStaging: tmp, backupRoot: backupRoot, log: log,
                    projectTargets: projectTargets, importOptions: importOptions,
                    manifestHome: m.homeDir)
            progress(0.1 + 0.9 * Double(i + 1) / total, "正在还原文件…")
        }
        if skipped > 0 {
            log("已按导入范围跳过 \(skipped) 项（未勾选的类别不会被改动）")
        }

        // 项目空间路径重映射：刷新 workspaces 表，让 WorkBuddy 在新机器认出工作区
        if !projectTargets.isEmpty {
            let db = (wbDir() as NSString).appendingPathComponent("workbuddy.db")
            if fm.fileExists(atPath: db) {
                for (oldRoot, newRoot) in projectTargets {
                    let eo = sqlEsc(oldRoot), en = sqlEsc(newRoot)
                    try? run("/usr/bin/sqlite3", [db, "UPDATE workspaces SET path='\(en)' WHERE path='\(eo)';"])
                    try? run("/usr/bin/sqlite3", [db, "INSERT OR IGNORE INTO workspaces(path, last_opened_at) VALUES('\(en)', strftime('%s','now')*1000);"])
                }
                log("已刷新 workspaces 路径映射（\(projectTargets.count) 个工作区）")
            }
        }

        // 对话记忆后处理：自选保留 + 账号过户 + cwd 重映射 + 自动探测挪位文件夹
        if importOptions.conversations {
            let db = (wbDir() as NSString).appendingPathComponent("workbuddy.db")
            if fm.fileExists(atPath: db) {
                // 1) 对话自选：只保留勾选会话（db 行 + 对话文件）
                if let sel = importOptions.selectedSessions {
                    if sel.isEmpty {
                        try? run("/usr/bin/sqlite3", [db, "DELETE FROM sessions;"])
                        try? run("/usr/bin/sqlite3", [db, "DELETE FROM session_usage;"])
                    } else {
                        let idList = sel.map { "'\(sqlEsc($0))'" }.joined(separator: ",")
                        try? run("/usr/bin/sqlite3", [db, "DELETE FROM sessions WHERE id NOT IN (\(idList));"])
                        try? run("/usr/bin/sqlite3", [db, "DELETE FROM session_usage WHERE session_id NOT IN (\(idList));"])
                    }
                    log("按勾选保留会话 \(sel.count) 条，其余 db 行已删除")
                    let keepOut = sqliteOut(db, "SELECT id FROM sessions;")
                    let keep = Set(keepOut.split(separator: "\n").map(String.init))
                    // 清理范围仅限「本次包内解压出的对话文件」，绝不触碰本机原有会话的文件
                    let stagedProj = (tmp as NSString).appendingPathComponent("conversations/projects")
                    let localProj = (wbDir() as NSString).appendingPathComponent("projects")
                    if let subdirs = try? fm.contentsOfDirectory(atPath: stagedProj) {
                        for sub in subdirs {
                            let sd = (stagedProj as NSString).appendingPathComponent(sub)
                            guard let items = try? fm.contentsOfDirectory(atPath: sd) else { continue }
                            let localSub = (localProj as NSString).appendingPathComponent(sub)
                            for it in items {
                                let stem = it.hasSuffix(".jsonl") ? String(it.dropLast(6)) : it
                                if !keep.contains(stem) {
                                    try? fm.removeItem(atPath: (localSub as NSString).appendingPathComponent(it))
                                }
                            }
                        }
                    }
                    log("包内未勾选会话的对话文件已清理（本机原有会话文件不受影响）")
                }
                // 2) 账号过户
                if let target = importOptions.targetUserId ?? detectedLocalUserId, !target.isEmpty {
                    try? run("/usr/bin/sqlite3", [db, "UPDATE sessions SET user_id='\(sqlEsc(target))' WHERE user_id <> '\(sqlEsc(target))';"])
                    log("已过户会话到账号: \(target)\(importOptions.targetUserId == nil ? "（自动探测）" : "")")
                } else {
                    log("⚠️ 未探测到本机账号 id，会话 user_id 未改写（请在 UI 手动填写目标账号）")
                }
                // 3) cwd 按项目空间映射重写
                for (oldRoot, newRoot) in projectTargets {
                    let eo = sqlEsc(oldRoot), en = sqlEsc(newRoot)
                    try? run("/usr/bin/sqlite3", [db, "UPDATE sessions SET cwd='\(en)' || substr(cwd, length('\(eo)')+1) WHERE cwd='\(eo)' OR cwd LIKE '\(eo)/%';"])
                }
                // 4) cwd 自动探测挪位文件夹（按文件夹名在常见位置唯一匹配才改）
                let deadOut = sqliteOut(db, "SELECT DISTINCT cwd FROM sessions WHERE cwd IS NOT NULL AND cwd <> '';")
                for cwd in deadOut.split(separator: "\n").map(String.init) where !fm.fileExists(atPath: cwd) {
                    let name = (cwd as NSString).lastPathComponent
                    let hits = findFolder(named: name)
                    if hits.count == 1 {
                        try? run("/usr/bin/sqlite3", [db, "UPDATE sessions SET cwd='\(sqlEsc(hits[0]))' WHERE cwd='\(sqlEsc(cwd))';"])
                        log("cwd 自动探测: 「\(name)」→ \(hits[0])")
                    } else if hits.count > 1 {
                        let cand = hits.prefix(3).joined(separator: "  |  ")
                        log("⚠️ cwd 自动探测: 「\(name)」命中 \(hits.count) 处未改动：\(cand)\(hits.count > 3 ? " 等" : "")")
                    } else {
                        log("⚠️ cwd 自动探测: 「\(name)」未找到新位置（含自定义扫描路径），相关会话仍会提示目录不存在")
                    }
                }
            }
        }

        progress(1.0, "完成")
        try? fm.removeItem(atPath: tmp)
        log("导入完成。被覆盖的原文件已备份到：\(backupRoot)")
    }

    private func restore(item: ExportItem, fromStaging tmp: String,
                         backupRoot: String, log: @escaping (String) -> Void,
                         projectTargets: [String: String] = [:],
                         importOptions: ImportOptions = ImportOptions(),
                         manifestHome: String? = nil) {
        let src = (tmp as NSString).appendingPathComponent(item.bundleRel)
        guard fm.fileExists(atPath: src) else {
            log("跳过(包内缺失): \(item.bundleRel)")
            return
        }

        // 解析目标路径：项目空间按导入映射重定位，其余按原逻辑
        var dst: String
        if item.category == "projectSpace" {
            if let root = item.workspaceRoot, let nr = projectTargets[root] {
                let entryName = (item.realPath as NSString).lastPathComponent
                dst = (nr as NSString).appendingPathComponent(entryName)
            } else if let root = item.workspaceRoot, !fm.fileExists(atPath: root) {
                // 未选目标目录且原路径本机不存在 → 按原目录结构自动创建并注册
                let newRoot = autoRoot(for: root, manifestHome: manifestHome)
                try? fm.createDirectory(atPath: newRoot, withIntermediateDirectories: true)
                let db = (wbDir() as NSString).appendingPathComponent("workbuddy.db")
                if fm.fileExists(atPath: db) {
                    let eo = sqlEsc(newRoot)
                    try? run("/usr/bin/sqlite3", [db, "INSERT OR IGNORE INTO workspaces(path, last_opened_at) VALUES('\(eo)', strftime('%s','now')*1000);"])
                }
                log("项目空间未选目标目录，已自动创建并注册: \(newRoot)")
                let entryName = (item.realPath as NSString).lastPathComponent
                dst = (newRoot as NSString).appendingPathComponent(entryName)
            } else {
                dst = item.realPath
            }
        } else {
            dst = resolveDst(item)
        }

        // 工作区类（记忆/Skill）：目标工作区不存在
        if item.category == "workspaceMemory" || item.category == "workspaceSkills" {
            let oldWsRoot = item.workspaceRoot
                ?? (((dst as NSString).deletingLastPathComponent) as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: oldWsRoot) {
                if importOptions.archiveMissingWorkspaces {
                    // 归档模式：兜底到用户级 workspace_memory_archive，不丢弃
                    let arcName = safeName(oldWsRoot)
                    let sub = item.category == "workspaceMemory" ? "memory" : "skills"
                    let arcDst = (self.wbDir() as NSString)
                        .appendingPathComponent("workspace_memory_archive/\(arcName)/\(sub)")
                    if self.fm.fileExists(atPath: arcDst) {
                        let bk = (backupRoot as NSString)
                            .appendingPathComponent("archive_\(safeName(arcDst))")
                        try? self.fm.createDirectory(atPath: (bk as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
                        try? self.fm.removeItemIfExists(atPath: bk)
                        try? self.fm.moveItem(atPath: arcDst, toPath: bk)
                    }
                    try? self.fm.createDirectory(atPath: (arcDst as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
                    do {
                        try self.fm.copyItem(atPath: src, toPath: arcDst)
                        log("目标工作区不存在，已归档工作区\(item.category)到: \(arcDst)")
                    } catch {
                        log("归档失败: \(arcDst) - \(error.localizedDescription)")
                    }
                    return
                } else {
                    // 默认：按原目录结构自动创建并注册 workspaces 表，让 WorkBuddy 直接认出
                    let newRoot = autoRoot(for: oldWsRoot, manifestHome: manifestHome)
                    let wbDir = (newRoot as NSString).appendingPathComponent(".workbuddy")
                    try? self.fm.createDirectory(atPath: wbDir, withIntermediateDirectories: true)
                    let sub = item.category == "workspaceMemory" ? "memory" : "skills"
                    dst = (wbDir as NSString).appendingPathComponent(sub)
                    let db = (self.wbDir() as NSString).appendingPathComponent("workbuddy.db")
                    if self.fm.fileExists(atPath: db) {
                        let eo = sqlEsc(newRoot)
                        try? self.run("/usr/bin/sqlite3", [db, "INSERT OR IGNORE INTO workspaces(path, last_opened_at) VALUES('\(eo)', strftime('%s','now')*1000);"])
                    }
                    log("目标工作区不存在，已自动创建并注册: \(newRoot)（\(item.category) 将还原到该工作区）")
                }
            }
        }

        // 目录对目录：递归合并（逐文件应用冲突策略），本机多出的文件不动——防止整目录替换吞掉本机文件
        var srcIsDir: ObjCBool = false
        let srcExists = fm.fileExists(atPath: src, isDirectory: &srcIsDir)
        var dstIsDir: ObjCBool = false
        let dstExists = fm.fileExists(atPath: dst, isDirectory: &dstIsDir)
        if srcExists && srcIsDir.boolValue && dstExists && dstIsDir.boolValue {
            mergeDirectory(src: src, dst: dst, backupRoot: backupRoot, log: log,
                           importOptions: importOptions)
            return
        }

        // 已存在：先按冲突策略决定动作，再备份（移入 migrate_backups，非删除）
        if fm.fileExists(atPath: dst) {
            if importOptions.conflictPolicy == .skipConflicts {
                log("冲突跳过（策略=跳过冲突）: \(dst)")
                return
            }
            if importOptions.conflictPolicy == .keepNewer {
                let ld = (try? fm.attributesOfItem(atPath: dst)[.modificationDate] as? Date) ?? nil
                let pd = (try? fm.attributesOfItem(atPath: src)[.modificationDate] as? Date) ?? nil
                if let l = ld, let p = pd, l > p.addingTimeInterval(1) {
                    log("本机较新，跳过覆盖（策略=保留较新）: \(dst)")
                    return
                }
            }
            let bk = (backupRoot as NSString).appendingPathComponent(safeName(dst))
            try? fm.createDirectory(atPath: (bk as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            try? fm.removeItemIfExists(atPath: bk)
            do {
                try fm.moveItem(atPath: dst, toPath: bk)
                log("已备份原文件: \(dst)")
            } catch {
                log("备份失败(继续): \(dst) - \(error.localizedDescription)")
            }
        }

        try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        do {
            try fm.copyItem(atPath: src, toPath: dst)
            log("已还原 \(item.category): \(dst)")
        } catch {
            log("还原失败: \(dst) - \(error.localizedDescription)")
        }
    }

    /// 目录递归合并：src 的每个文件按冲突策略并入 dst；dst 独有内容一律不动
    private func mergeDirectory(src: String, dst: String, backupRoot: String,
                                log: @escaping (String) -> Void, importOptions: ImportOptions) {
        let items = (try? fm.contentsOfDirectory(atPath: src)) ?? []
        for it in items {
            let s = (src as NSString).appendingPathComponent(it)
            let d = (dst as NSString).appendingPathComponent(it)
            var sIsDir: ObjCBool = false
            guard fm.fileExists(atPath: s, isDirectory: &sIsDir) else { continue }
            var dIsDir: ObjCBool = false
            let dExists = fm.fileExists(atPath: d, isDirectory: &dIsDir)
            if sIsDir.boolValue {
                if !dExists {
                    try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
                    dIsDir = ObjCBool(true)
                }
                if dIsDir.boolValue {
                    mergeDirectory(src: s, dst: d, backupRoot: backupRoot,
                                   log: log, importOptions: importOptions)
                    continue
                }
            }
            if dExists {
                if importOptions.conflictPolicy == .skipConflicts {
                    log("冲突跳过（策略=跳过冲突）: \(d)")
                    continue
                }
                if importOptions.conflictPolicy == .keepNewer {
                    let ld = (try? fm.attributesOfItem(atPath: d)[.modificationDate] as? Date) ?? nil
                    let pd = (try? fm.attributesOfItem(atPath: s)[.modificationDate] as? Date) ?? nil
                    if let l = ld, let p = pd, l > p.addingTimeInterval(1) {
                        log("本机较新，跳过覆盖（策略=保留较新）: \(d)")
                        continue
                    }
                }
                let bk = (backupRoot as NSString).appendingPathComponent(safeName(d))
                try? fm.createDirectory(atPath: (bk as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
                try? fm.removeItemIfExists(atPath: bk)
                try? fm.moveItem(atPath: d, toPath: bk)
            }
            try? fm.createDirectory(atPath: (d as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            do {
                try fm.copyItem(atPath: s, toPath: d)
                log("已还原(合并): \(d)")
            } catch {
                log("合并失败: \(d) - \(error.localizedDescription)")
            }
        }
    }
}
