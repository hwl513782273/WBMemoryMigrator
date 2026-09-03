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
    static let all = ExportOptions(longTermMemory: true, conversations: true, skills: true,
                                   projectSpaces: false,
                                   projectSelection: ProjectSpaceSelection(entries: [:]))
}

/// UI 用的项目空间条目选项
struct WorkspaceEntryOption: Identifiable {
    let workspace: String
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64
    let excludedByDefault: Bool
    var id: String { path }
}

// 项目空间默认排除的膨胀项（默认不勾，可在 UI 手动加回）
let defaultProjectExcludes = Set<String>([
    "node_modules", ".git", "build", "DerivedData", ".build",
    "Pods", "vendor", "dist", "out", ".DS_Store"
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
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "BackupEngine",
                          code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "命令失败: \(args.joined(separator: " "))\n\(msg)"])
        }
    }

    // MARK: 工作区枚举（读 workspaces 表真实路径）

    func workspacePaths() -> [String] {
        let db = (wbDir() as NSString).appendingPathComponent("workbuddy.db")
        guard fm.fileExists(atPath: db) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db, "SELECT path FROM workspaces;"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        guard let s = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) else { return [] }
        return s.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 列出所有工作区的顶层条目（供 UI 勾选），含大小与默认排除态
    func projectSpaceOptions() -> [WorkspaceEntryOption] {
        var out: [WorkspaceEntryOption] = []
        for wp in workspacePaths() {
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
        for wp in workspacePaths() {
            let key = safeName(wp)
            if options.longTermMemory {
                tasks.append(ColTask(src: (wp as NSString).appendingPathComponent(".workbuddy/memory"),
                                     cat: "workspaceMemory", rel: "workspaces/\(key)/memory"))
            }
            if options.skills {
                tasks.append(ColTask(src: (wp as NSString).appendingPathComponent(".workbuddy/skills"),
                                     cat: "workspaceSkills", rel: "workspaces/\(key)/skills"))
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
                                items: items)
        let mdata = try JSONEncoder().encode(manifest)
        try mdata.write(to: URL(fileURLWithPath:
            (staging as NSString).appendingPathComponent("manifest.json")))

        // 打包
        progress(0.78, "正在打包压缩…")
        try fm.removeItemIfExists(atPath: zipPath)
        try run("/usr/bin/zip", ["-r", "-q", zipPath, "."], currentDir: staging)
        progress(1.0, "完成")
        log("打包完成：\(zipPath)  共 \(items.count) 项")
        try? fm.removeItem(atPath: staging)
    }

    // MARK: 预览

    /// 导入预览：返回「将恢复到本机的目标路径」清单（工作区不存在时标注跳过）
    func preview(zip: String) throws -> [String] {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wbmem_prev_\(Int(Date().timeIntervalSince1970))")
        try fm.removeItemIfExists(atPath: tmp)
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", zip, "-d", tmp])
        let man = (tmp as NSString).appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: man))
        let m = try JSONDecoder().decode(Manifest.self, from: data)
        try? fm.removeItem(atPath: tmp)
        var lines: [String] = []
        for item in m.items {
            if item.category == "projectSpace" {
                lines.append("→ \(item.realPath)  （项目空间 · \(fmt(item.size)) · 导入时选择目标目录）")
                continue
            }
            let dst = resolveDst(item)
            var note = ""
            if item.category == "workspaceMemory" || item.category == "workspaceSkills" {
                let wsRoot = (dst as NSString).deletingLastPathComponent
                let wsGrand = (wsRoot as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: wsGrand) {
                    note = "  ⚠️ 目标工作区不存在，将归档到 ~/.workbuddy/workspace_memory_archive/\(safeName(wsGrand))"
                }
            }
            lines.append("→ \(dst)  （\(item.category) · \(fmt(item.size))）\(note)")
        }
        return lines
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
        try? fm.removeItem(atPath: tmp)
        let roots = Set(m.items.filter { $0.category == "projectSpace" }
                            .compactMap { $0.workspaceRoot })
        return Array(roots).sorted()
    }

    // MARK: 导入

    func importBackup(from zip: String, log: @escaping (String) -> Void,
                      progress: @escaping (Double, String) -> Void,
                      projectTargets: [String: String] = [:]) throws {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wbmem_imp_\(Int(Date().timeIntervalSince1970))")
        try fm.removeItemIfExists(atPath: tmp)
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", zip, "-d", tmp])
        progress(0.1, "正在解压备份…")

        let man = (tmp as NSString).appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: man))
        let m = try JSONDecoder().decode(Manifest.self, from: data)

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupRoot = (wbDir() as NSString).appendingPathComponent("migrate_backups/\(ts)")
        try fm.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)

        let total = Double(max(m.items.count, 1))
        for (i, item) in m.items.enumerated() {
            restore(item: item, fromStaging: tmp, backupRoot: backupRoot, log: log,
                    projectTargets: projectTargets)
            progress(0.1 + 0.9 * Double(i + 1) / total, "正在还原文件…")
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

        progress(1.0, "完成")
        try? fm.removeItem(atPath: tmp)
        log("导入完成。被覆盖的原文件已备份到：\(backupRoot)")
    }

    private func restore(item: ExportItem, fromStaging tmp: String,
                         backupRoot: String, log: @escaping (String) -> Void,
                         projectTargets: [String: String] = [:]) {
        let src = (tmp as NSString).appendingPathComponent(item.bundleRel)
        guard fm.fileExists(atPath: src) else {
            log("跳过(包内缺失): \(item.bundleRel)")
            return
        }

        // 解析目标路径：项目空间按导入映射重定位，其余按原逻辑
        let dst: String
        if item.category == "projectSpace" {
            if let root = item.workspaceRoot, let nr = projectTargets[root] {
                let entryName = (item.realPath as NSString).lastPathComponent
                dst = (nr as NSString).appendingPathComponent(entryName)
            } else {
                dst = item.realPath
            }
        } else {
            dst = resolveDst(item)
        }

        // 工作区类（记忆/Skill）：目标工作区不存在 → 兜底归档到用户级 workspace_memory_archive，不丢弃
        if item.category == "workspaceMemory" || item.category == "workspaceSkills" {
            let wsRoot = (dst as NSString).deletingLastPathComponent   // .../.workbuddy
            let wsGrand = (wsRoot as NSString).deletingLastPathComponent // 工作区路径
            if !fm.fileExists(atPath: wsGrand) {
                let arcName = safeName(wsGrand)
                let sub = item.category == "workspaceMemory" ? "memory" : "skills"
                let arcDst = (self.wbDir() as NSString)
                    .appendingPathComponent("workspace_memory_archive/\(arcName)/\(sub)")
                // 已有归档先备份，避免覆盖丢失
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
            }
        }

        // 已存在则先备份（移入 migrate_backups，非删除）
        if fm.fileExists(atPath: dst) {
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
}
