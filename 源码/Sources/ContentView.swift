import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var logText = ""
    @State private var busy = false
    @State private var progress: Double = 0
    @State private var progressPhase = ""
    @State private var importPreview: [String] = []
    @State private var importZip: String?
    @State private var showConfirm = false
    @State private var sourcePaths: [String] = []
    @State private var categorySizes: [String: Int64] = [:]   // 各类别已勾选总大小缓存
    // 导出可单独勾选的三类范围
    @State private var optMemory = true
    @State private var optConversations = true
    @State private var optSkills = true
    // 第 4 类：项目空间
    @State private var optProjectSpaces = false
    @State private var projectOptions: [WorkspaceEntryOption] = []
    @State private var entryChecked: [String: Bool] = [:]   // 顶层条目路径 -> 是否勾选
    @State private var workspaceChecked: [String: Bool] = [:] // 工作区根路径 -> 是否勾选
    @State private var projectShowSubentries = true           // 面板显示模式：true=工作区+子目录，false=只显示工作区
    // 导入侧项目空间目标目录映射（旧工作区根 -> 新工作区根）
    @State private var importProjectRoots: [String] = []
    @State private var importTargets: [String: String] = [:]
    // 导入范围（读取包后显示，只恢复勾中的类别）
    @State private var importOptMemory = true
    @State private var importOptConversations = true
    @State private var importOptSkills = true
    @State private var importOptProjectSpaces = true
    @State private var importSummary: [BackupEngine.ImportCategorySummary] = []
    // 对话自选 + 账号过户
    @State private var packageConversations: [BackupEngine.PackageConversation] = []
    @State private var selectedConversationIds: Set<String> = []
    @State private var manualTargetUserId = ""
    @State private var showConversationPicker = false
    @State private var archiveMissing = false   // 目标工作区不存在时归档（默认自动创建）
    @State private var conflictPolicy: BackupEngine.ConflictPolicy = .alwaysOverwrite
    @State private var scanRoots: [String] = []
    @State private var showScanSettings = false
    @State private var syncRegistry = true   // 导出后同步修正已迁移/挪位工作区的注册路径
    @State private var detectedUserId: String?   // 本机当前账号 id（导入读取包时缓存，避免每帧跑 sqlite）
    private final class GenBox { var value = 0 }
    @State private var sourcesGen = GenBox()     // 后台统计的代数校验（防乱序回写）
    @State private var projectLoading = true     // 工作区枚举中
    @State private var projectSizesDone = false  // 大小懒加载是否完成

    var body: some View {
        ScrollView {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("WorkBuddy 记忆备份")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .padding(.top, 22)
                Text("长期记忆 · 对话记忆 · 全部 Skill · 项目空间")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            // 导出范围勾选（框内仅 4 个类别开关，大小保持不变）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) { Image(systemName: "checklist").foregroundStyle(.secondary); Text("导出范围（可单独勾选）") }.font(.subheadline.weight(.semibold))
                Toggle(isOn: $optMemory) {
                    HStack {
                        Text("长期记忆文件（MEMORY.md / memory / 工作区记忆）")
                        if optMemory, let sz = categorySizes["memory"] {
                            Text("已选 \(BackupEngine.shared.fmt(sz))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .onChange(of: optMemory) { _ in recomputeSources() }
                Toggle(isOn: $optConversations) {
                    HStack {
                        Text("对话记忆（对话库 / sessions / projects）")
                        if optConversations, let sz = categorySizes["conversations"] {
                            Text("已选 \(BackupEngine.shared.fmt(sz))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .onChange(of: optConversations) { _ in recomputeSources() }
                Toggle(isOn: $optSkills) {
                    HStack {
                        Text("全部 Skill（用户级 + 工作区）")
                        if optSkills, let sz = categorySizes["skills"] {
                            Text("已选 \(BackupEngine.shared.fmt(sz))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .onChange(of: optSkills) { _ in recomputeSources() }
                Toggle(isOn: $optProjectSpaces) {
                    HStack {
                        Text("项目空间（指定工作区的源码本体）")
                        if optProjectSpaces {
                            Text("已选 \(BackupEngine.shared.fmt(projectSelectedSize()))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .onChange(of: optProjectSpaces) { _ in recomputeSources() }
                Divider().padding(.vertical, 2)
                Toggle("同步修正 WorkBuddy 注册路径（已迁移/挪位的工作区按真实位置回写，反向软链保留）",
                       isOn: $syncRegistry)
                    .font(.caption)
            }
            .padding(10)
            .cardBackground()

            // 项目空间 + 数据来源位置：左右分屏
            HStack(alignment: .top, spacing: 12) {
                // 左：项目空间包含的工作区与子目录
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        HStack(spacing: 6) { Image(systemName: "folder").foregroundStyle(.secondary); Text("项目空间包含的工作区与子目录") }.font(.subheadline.weight(.semibold))
                        Spacer()
                        Picker("", selection: $projectShowSubentries) {
                            Text("只显示工作区").tag(false)
                            Text("工作区与子目录").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                        .controlSize(.small)
                        Button("全选") { selectAllProjects() }
                            .controlSize(.small)
                        Button("全不选") { deselectAllProjects() }
                            .controlSize(.small)
                    }
                    HStack(spacing: 6) {
                        Text(optProjectSpaces
                             ? "默认已排除 node_modules/.git/build 等膨胀项，可手动加回。"
                             : "⚠️ 需先在上方「导出范围」勾选「项目空间」，以下勾选才会生效并可操作。")
                            .font(.caption).foregroundColor(.secondary)
                        if projectLoading {
                            Spacer()
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("正在扫描工作区…").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            let grouped = Dictionary(grouping: projectOptions, by: { $0.workspace })
                            ForEach(Array(grouped.keys.sorted()), id: \.self) { ws in
                                VStack(alignment: .leading, spacing: 2) {
                                    // 行大小 = 该工作区可包含条目的固定总大小（默认排除项不计），与当前勾选状态无关
                                    let wsSize = grouped[ws]!.filter { !$0.excludedByDefault }.reduce(Int64(0)) { $0 + $1.size }
                                    Toggle(isOn: Binding(
                                            get: { workspaceChecked[ws] ?? true },
                                            set: { nv in
                                                workspaceChecked[ws] = nv
                                                for opt in grouped[ws]! {
                                                    entryChecked[opt.path] = nv
                                                }
                                                recomputeSources()
                                            })) {
                                        HStack(spacing: 5) {
                                            Text("📁 \((ws as NSString).lastPathComponent) (\(projectSizesDone ? BackupEngine.shared.fmt(wsSize) : "…"))")
                                            if let reg = grouped[ws]!.first?.registeredRoot {
                                                Text("已迁移 ↗")
                                                    .font(.caption2).fontWeight(.medium)
                                                    .foregroundColor(.orange)
                                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                                                    .help("SpaceMover 已迁移（反向软链）\n原位置: \(reg)\n现位置: \(ws)\n导入时将按原位置结构自动还原")
                                            }
                                        }
                                    }
                                    .font(.subheadline)
                                    .padding(.bottom, 2)
                                    if projectShowSubentries {
                                        ForEach(grouped[ws]!.sorted(by: { $0.name < $1.name })) { opt in
                                        Toggle("   \(opt.isDir ? "📂" : "📄") \(opt.name)\(opt.isSymlink ? " 🔗" : "")  (\(projectSizesDone || opt.size > 0 ? BackupEngine.shared.fmt(opt.size) : "…"))",
                                               isOn: Binding(
                                                get: { entryChecked[opt.path] ?? !opt.excludedByDefault },
                                                set: { nv in
                                                    entryChecked[opt.path] = nv
                                                    // 联动工作区总开关：全部子项都取消则关，全部选中则开，否则保持
                                                    let opts = grouped[ws]!
                                                    let allOff = opts.allSatisfy { entryChecked[$0.path] == false || (entryChecked[$0.path] == nil && $0.excludedByDefault) }
                                                    let allOn = opts.allSatisfy { entryChecked[$0.path] == true || (entryChecked[$0.path] == nil && !$0.excludedByDefault) }
                                                    if allOff { workspaceChecked[ws] = false }
                                                    else if allOn { workspaceChecked[ws] = true }
                                                    recomputeSources()
                                                }))
                                            .font(.caption)
                                            .foregroundColor(opt.excludedByDefault ? .secondary : .primary)
                                            .help(opt.isSymlink ? "🔗 该子项目为软链（SpaceMover 单项目迁移），数据在链接目标" : "")
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 480)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .cardBackground()
                // 「项目空间」类别未勾选时，面板内所有勾选/按钮禁用并置灰
                .disabled(!optProjectSpaces)
                .opacity(optProjectSpaces ? 1 : 0.55)

                // 右：数据来源位置（导出将收集以下路径）
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary); Text("数据来源位置（导出将收集以下路径）") }.font(.subheadline.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if sourcePaths.isEmpty {
                                Text("（未勾选任何范围或本地无对应数据）").foregroundColor(.secondary)
                            }
                            ForEach(sourcePaths, id: \.self) { p in
                                Text(abbr(p))
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 480)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .cardBackground()
            }

            // 扫描设置：挪位工作区的自定义搜索路径
            DisclosureGroup("扫描设置（工作区挪位后的搜索路径，当前 \(scanRoots.count) 条）", isExpanded: $showScanSettings) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("把项目挪入的「收容所」文件夹加进来，导出/导入时会到这里深度搜索（6 层）。内置已扫 WorkBuddy/Downloads/Desktop/Documents。")
                        .font(.caption).foregroundColor(.secondary)
                    ForEach(scanRoots, id: \.self) { r in
                        HStack {
                            Text(r).font(.caption).lineLimit(1)
                            Spacer()
                            Button("移除") {
                                scanRoots.removeAll { $0 == r }
                                BackupEngine.shared.setCustomScanRoots(scanRoots)
                                reloadProjectOptions()
                                recomputeSources()
                            }
                            .controlSize(.small)
                        }
                    }
                    HStack {
                        Button("添加扫描路径…") { addScanRoot() }
                            .controlSize(.small)
                        Text("改动后立即生效").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .font(.subheadline)

            HStack(spacing: 14) {
                Button(action: doExport) {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                        .frame(width: 168, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy)
                .help("把勾选的记忆与对话打包成 zip（保存位置由你选择）")

                Button(action: doImport) {
                    Label("导入备份", systemImage: "square.and.arrow.down")
                        .frame(width: 168, height: 44)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(busy)
                .help("从 zip 还原记忆与对话")
            }

            // 实时进度条（导出/导入进行中显示）
            if busy {
                VStack(spacing: 5) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 380)
                    HStack {
                        Text(progressPhase.isEmpty ? "处理中…" : progressPhase)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 380)
                }
                .padding(.vertical, 2)
            }

            if !importPreview.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("导入预览（共 \(importPreview.count) 项）— 将恢复到以下位置").bold()
                    Text("当前用户目录：\(abbr(NSHomeDirectory()))")
                        .font(.caption).foregroundColor(.secondary)

                    if !importSummary.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) { Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary); Text("导入范围（可单独勾选）") }.font(.subheadline.weight(.semibold))
                            let hasMemory = importSummary.contains(where: { $0.key == "memory" })
                            Toggle(isOn: $importOptMemory) {
                                HStack {
                                    Text("长期记忆文件")
                                    if let e = importSummary.first(where: { $0.key == "memory" }) {
                                        Text("（\(e.count) 项 · \(BackupEngine.shared.fmt(e.size))）")
                                            .font(.caption).foregroundColor(.secondary)
                                    } else {
                                        Text("（本包未含）").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .disabled(!hasMemory)
                            .onChange(of: importOptMemory) { _ in recomputeImportPreview() }
                            let hasConv = importSummary.contains(where: { $0.key == "conversations" })
                            Toggle(isOn: $importOptConversations) {
                                HStack {
                                    Text("对话记忆")
                                    if let e = importSummary.first(where: { $0.key == "conversations" }) {
                                        Text("（\(e.count) 项 · \(BackupEngine.shared.fmt(e.size))）")
                                            .font(.caption).foregroundColor(.secondary)
                                    } else {
                                        Text("（本包未含）").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .disabled(!hasConv)
                            .onChange(of: importOptConversations) { _ in recomputeImportPreview() }
                                if !packageConversations.isEmpty {
                                    HStack(spacing: 8) {
                                        Button(showConversationPicker ? "收起对话列表" : "选择要恢复的对话（\(selectedConversationIds.count)/\(packageConversations.count)）") {
                                            showConversationPicker.toggle()
                                        }
                                        .controlSize(.small)
                                        if showConversationPicker {
                                            Button("全选对话") { selectedConversationIds = Set(packageConversations.map { $0.id }) }
                                                .controlSize(.small)
                                            Button("全不选对话") { selectedConversationIds = [] }
                                                .controlSize(.small)
                                        }
                                    }
                                    if showConversationPicker {
                                        ScrollView {
                                            VStack(alignment: .leading, spacing: 2) {
                                                ForEach(packageConversations) { c in
                                                    Toggle(isOn: Binding(
                                                        get: { selectedConversationIds.contains(c.id) },
                                                        set: { nv in
                                                            if nv { selectedConversationIds.insert(c.id) }
                                                            else { selectedConversationIds.remove(c.id) }
                                                        })) {
                                                        HStack {
                                                            Text(c.title).lineLimit(1)
                                                            Text("· \(workspaceName(of: c.cwd))")
                                                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                                                            Spacer()
                                                            Text(dateStr(c.updatedAt))
                                                                .font(.caption2).foregroundColor(.secondary)
                                                        }
                                                    }
                                                    .font(.caption)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(maxHeight: 150)
                                        .padding(6)
                                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                                    }
                                }
                            let hasSkills = importSummary.contains(where: { $0.key == "skills" })
                            Toggle(isOn: $importOptSkills) {
                                HStack {
                                    Text("全部 Skill")
                                    if let e = importSummary.first(where: { $0.key == "skills" }) {
                                        Text("（\(e.count) 项 · \(BackupEngine.shared.fmt(e.size))）")
                                            .font(.caption).foregroundColor(.secondary)
                                    } else {
                                        Text("（本包未含）").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .disabled(!hasSkills)
                            .onChange(of: importOptSkills) { _ in recomputeImportPreview() }
                            let hasPS = importSummary.contains(where: { $0.key == "projectSpaces" })
                            Toggle(isOn: $importOptProjectSpaces) {
                                HStack {
                                    Text("项目空间")
                                    if let e = importSummary.first(where: { $0.key == "projectSpaces" }) {
                                        Text("（\(e.count) 项 · \(BackupEngine.shared.fmt(e.size))）")
                                            .font(.caption).foregroundColor(.secondary)
                                    } else {
                                        Text("（本包未含）").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .disabled(!hasPS)
                            .onChange(of: importOptProjectSpaces) { _ in recomputeImportPreview() }
                        }
                        .padding(8)
                        .cardBackground()
                    }

                    HStack(spacing: 8) {
                        Text("冲突策略：").font(.caption)
                        Picker("", selection: $conflictPolicy) {
                            ForEach(BackupEngine.ConflictPolicy.allCases, id: \.self) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                        .controlSize(.small)
                    }
                    .font(.caption)

                    Toggle("目标工作区不存在时归档到 workspace_memory_archive（默认关闭=按原目录结构自动创建并注册）",
                           isOn: $archiveMissing)
                        .font(.caption)

                    if importOptConversations && !packageConversations.isEmpty {
                        HStack(spacing: 6) {
                            if let local = detectedUserId {
                                Text("账号过户：恢复的会话将归属当前账号 \(String(local.prefix(8)))…")
                                    .font(.caption).foregroundColor(.secondary)
                            } else {
                                Text("未探测到本机账号，可手动填写目标账号 id（留空则不改）:")
                                    .font(.caption).foregroundColor(.orange)
                                TextField("user_id", text: $manualTargetUserId)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 260)
                                    .font(.caption)
                            }
                        }
                    }

                    if !importProjectRoots.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("项目空间：可选目标目录（不选则按原目录结构自动创建并注册）").bold()
                            ForEach(importProjectRoots, id: \.self) { root in
                                HStack {
                                    Text((root as NSString).lastPathComponent).font(.caption).bold()
                                    Spacer()
                                    if let tgt = importTargets[root] {
                                        Text("→ \((tgt as NSString).lastPathComponent)")
                                            .font(.caption).foregroundColor(.secondary)
                                    } else {
                                        Text("（未选→按原目录结构自动创建）").font(.caption).foregroundColor(.secondary)
                                    }
                                    Button("选择目录") { chooseTarget(for: root) }
                                        .controlSize(.small)
                                }
                            }
                        }
                        .padding(6)
                        .cardBackground()
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(importPreview, id: \.self) { line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true)  // 自动换行，完整显示长路径
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                    Button("确认导入") { confirmImport() }
                        .disabled(busy)
                        .controlSize(.large)
                }
                .padding(10)
.cardBackground()
            }

            Spacer(minLength: 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                    Text("日志").font(.caption).foregroundColor(.secondary)
                }
                ScrollView {
                    Text(logText.isEmpty ? "（暂无日志）" : logText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 80)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
        .padding([.horizontal, .bottom], 20)
        }
        .frame(minWidth: 880, minHeight: 780)
        .preferredColorScheme(.dark)
        .tint(Color.accentColor)
        .onAppear {
            scanRoots = BackupEngine.shared.customScanRoots()
            reloadProjectOptions()
            recomputeSources()
        }
    }

    // MARK: - 项目空间选择辅助

    private func reloadProjectOptions() {
        projectLoading = true
        projectSizesDone = false
        DispatchQueue.global().async {
            // 阶段 1：快速枚举（挪位探测 ~2s，但不算大小）→ 首屏秒出
            let opts = BackupEngine.shared.projectSpaceOptionsFast()
            DispatchQueue.main.async {
                projectOptions = opts
                for o in projectOptions where entryChecked[o.path] == nil {
                    entryChecked[o.path] = !o.excludedByDefault
                }
                let grouped = Dictionary(grouping: projectOptions, by: { $0.workspace })
                for (ws, _) in grouped {
                    if workspaceChecked[ws] == nil {
                        workspaceChecked[ws] = true
                    }
                }
                projectLoading = false
            }
            // 阶段 2：大小后台逐个回填（增量刷新，不阻塞界面）
            for o in opts {
                let sz = BackupEngine.shared.sizeOf(o.path)
                DispatchQueue.main.async {
                    if let i = projectOptions.firstIndex(where: { $0.path == o.path }) {
                        projectOptions[i].size = sz
                    }
                }
            }
            DispatchQueue.main.async { projectSizesDone = true }
        }
    }

    private func currentSelection() -> ProjectSpaceSelection {
        var map: [String: [String]] = [:]
        for o in projectOptions where entryChecked[o.path] == true {
            map[o.workspace, default: []].append(o.name)
        }
        return ProjectSpaceSelection(entries: map)
    }

    private func projectSelectedSize() -> Int64 {
        projectOptions.reduce(0) { total, opt in
            let checked = entryChecked[opt.path] ?? !opt.excludedByDefault
            return checked ? total + opt.size : total
        }
    }

    private func selectAllProjects() {
        let grouped = Dictionary(grouping: projectOptions, by: { $0.workspace })
        for (ws, opts) in grouped {
            workspaceChecked[ws] = true
            for opt in opts { entryChecked[opt.path] = true }
        }
        recomputeSources()
    }

    private func deselectAllProjects() {
        let grouped = Dictionary(grouping: projectOptions, by: { $0.workspace })
        for (ws, opts) in grouped {
            workspaceChecked[ws] = false
            for opt in opts { entryChecked[opt.path] = false }
        }
        recomputeSources()
    }

    private func recomputeSources() {
        // 后台统计（sizeOf 全量枚举可能较慢），带代数校验防止乱序回写旧结果
        sourcesGen.value += 1
        let gen = sourcesGen.value
        let sel = currentSelection()
        let opts = ExportOptions(longTermMemory: optMemory, conversations: optConversations,
                                 skills: optSkills, projectSpaces: optProjectSpaces,
                                 projectSelection: sel)
        DispatchQueue.global().async {
            let paths = BackupEngine.shared.sourcePaths(options: opts)
            var sizes: [String: Int64] = [:]
            func catSize(memory: Bool, conv: Bool, skill: Bool) -> Int64 {
                let o = ExportOptions(longTermMemory: memory, conversations: conv, skills: skill,
                                      projectSpaces: false, projectSelection: sel)
                return BackupEngine.shared.sourcePaths(options: o).reduce(0) { $0 + BackupEngine.shared.sizeOf($1) }
            }
            if optMemory { sizes["memory"] = catSize(memory: true, conv: false, skill: false) }
            if optConversations { sizes["conversations"] = catSize(memory: false, conv: true, skill: false) }
            if optSkills { sizes["skills"] = catSize(memory: false, conv: false, skill: true) }
            DispatchQueue.main.async {
                guard gen == sourcesGen.value else { return }   // 已有更新请求，丢弃本轮
                sourcePaths = paths
                categorySizes = sizes
            }
        }
    }

    private func abbr(_ p: String) -> String {
        let home = NSHomeDirectory()
        if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        return p
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmm"
        return f.string(from: Date())
    }

    private func doExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WorkBuddy记忆备份_\(stamp()).zip"
        panel.allowedContentTypes = [.zip]
        panel.title = "选择备份保存位置"
        panel.message = "建议保存到 U 盘或网盘，便于换机带走。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sel = currentSelection()
        let opts = ExportOptions(longTermMemory: optMemory, conversations: optConversations,
                                 skills: optSkills, projectSpaces: optProjectSpaces,
                                 projectSelection: sel, syncWorkspaceRegistry: syncRegistry)
        let hasProject = opts.projectSpaces && !opts.projectSelection.isEmpty
        guard opts.longTermMemory || opts.conversations || opts.skills || hasProject else {
            logText += "⚠️ 请至少勾选一类数据（项目空间需勾选至少一个子目录）再导出。\n"
            return
        }
        busy = true
        progress = 0
        progressPhase = "准备中…"
        let scope = [("长期记忆文件", opts.longTermMemory), ("对话记忆", opts.conversations),
                     ("全部 Skill", opts.skills), ("项目空间", hasProject)]
            .filter { $0.1 }.map { $0.0 }.joined(separator: " + ")
        DispatchQueue.main.async { logText += "开始导出（范围：\(scope)） → \(url.path)\n" }
        DispatchQueue.global().async {
            do {
                try BackupEngine.shared.export(to: url.path,
                    log: { line in DispatchQueue.main.async { logText += line + "\n" } },
                    progress: { p, phase in DispatchQueue.main.async { progress = p; progressPhase = phase } },
                    options: opts)
                DispatchQueue.main.async {
                    busy = false
                    logText += "✅ 导出完成：\(url.path)\n"
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    logText += "❌ 导出失败：\(error.localizedDescription)\n"
                }
            }
        }
    }

    private func doImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.title = "选择备份文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        progress = 0
        progressPhase = "正在读取清单…"
        importPreview = []
        DispatchQueue.main.async { logText += "读取备份清单：\(url.path)\n" }
        DispatchQueue.global().async {
            do {
                // 单次解压获取全部导入前信息（避免同一 zip 反复解压 4 次）
                let info = try BackupEngine.shared.inspectPackage(zip: url.path)
                let localId = BackupEngine.shared.localUserId()
                DispatchQueue.main.async {
                    busy = false
                    importPreview = info.previewLines
                    importZip = url.path
                    importSummary = info.summary
                    packageConversations = info.conversations
                    selectedConversationIds = Set(info.conversations.map { $0.id })
                    showConversationPicker = false
                    manualTargetUserId = ""
                    detectedUserId = localId
                    importOptMemory = true
                    importOptConversations = true
                    importOptSkills = true
                    importOptProjectSpaces = true
                    importProjectRoots = info.projectRoots
                    importTargets = [:]
                    showConfirm = true
                    logText += "已读取 \(info.previewLines.count) 项，请点「确认导入」。\n"
                    if !info.projectRoots.isEmpty {
                        logText += "检测到 \(info.projectRoots.count) 个项目空间工作区（可不选目录，自动按原结构落位）。\n"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    logText += "❌ 读取失败：\(error.localizedDescription)\n"
                }
            }
        }
    }

    private func addScanRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择要纳入扫描的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            if !scanRoots.contains(path) {
                scanRoots.append(path)
                BackupEngine.shared.setCustomScanRoots(scanRoots)
                reloadProjectOptions()
                recomputeSources()
                logText += "已添加扫描路径: \(path)\n"
            }
        }
    }

    private func workspaceName(of cwd: String) -> String {
        cwd.isEmpty ? "（无工作目录）" : (cwd as NSString).lastPathComponent
    }

    private func dateStr(_ ts: Int64) -> String {
        guard ts > 0 else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ts) / 1000.0))
    }

    private func recomputeImportPreview() {
        guard let zip = importZip else { return }
        let opts = BackupEngine.ImportOptions(
            memory: importOptMemory, conversations: importOptConversations,
            skills: importOptSkills, projectSpaces: importOptProjectSpaces)
        importPreview = (try? BackupEngine.shared.preview(zip: zip, options: opts,
                                                          projectTargets: importTargets)) ?? []
    }

    private func chooseTarget(for root: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择「\((root as NSString).lastPathComponent)」的导入父目录"
        panel.message = "将写入：<所选目录>/\((root as NSString).lastPathComponent)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let newRoot = (url.path as NSString).appendingPathComponent((root as NSString).lastPathComponent)
        importTargets[root] = newRoot
        recomputeImportPreview()   // 预览立即反映已选目标目录的冲突标注
    }

    private func confirmImport() {
        guard let zip = importZip else { return }
        // 未选目标目录的工作区将自动落位（原路径存在→原位；不存在→自动创建 ~/WorkBuddy/<名> 并注册）
        if !importProjectRoots.isEmpty {
            let missing = importProjectRoots.filter { importTargets[$0] == nil }
            if !missing.isEmpty {
                logText += "未选目标目录的工作区 \(missing.count) 个，将按原目录结构自动落位。\n"
            }
        }
        // 高危操作警示：导入对话将整库覆盖本机对话库
        if importOptConversations, let e = importSummary.first(where: { $0.key == "conversations" }) {
            let local = BackupEngine.shared.localSessionCount()
            let picked = importOptConversations ? selectedConversationIds.count : 0
            let alert = NSAlert()
            alert.messageText = "导入将覆盖本机对话库"
            alert.informativeText = picked == 0
                ? "⚠️ 未勾选任何对话，本机现有 \(local) 条会话导入后将全部消失（原对话库会自动备份到 migrate_backups）。确定继续吗？"
                : "本机现有 \(local) 条会话将被替换为包内已勾选的 \(picked) 条（原对话库自动备份到 migrate_backups）。确定继续吗？"
            alert.addButton(withTitle: "继续导入")
            alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn {
                logText += "已取消导入（对话库覆盖警示）。\n"
                return
            }
        }
        busy = true
        progress = 0
        progressPhase = "准备中…"
        DispatchQueue.main.async { logText += "开始导入...\n" }
        DispatchQueue.global().async {
            do {
                var opts = BackupEngine.ImportOptions(
                    memory: importOptMemory, conversations: importOptConversations,
                    skills: importOptSkills, projectSpaces: importOptProjectSpaces)
                if importOptConversations && !packageConversations.isEmpty {
                    opts.selectedSessions = selectedConversationIds
                }
                if importOptConversations && !manualTargetUserId.trimmingCharacters(in: .whitespaces).isEmpty {
                    opts.targetUserId = manualTargetUserId.trimmingCharacters(in: .whitespaces)
                }
                opts.archiveMissingWorkspaces = archiveMissing
                opts.conflictPolicy = conflictPolicy
                try BackupEngine.shared.importBackup(
                    from: zip,
                    log: { line in DispatchQueue.main.async { logText += line + "\n" } },
                    progress: { p, phase in DispatchQueue.main.async { progress = p; progressPhase = phase } },
                    projectTargets: importTargets,
                    importOptions: opts
                )
                DispatchQueue.main.async {
                    busy = false
                    importPreview = []
                    importZip = nil
                    importSummary = []
                    packageConversations = []
                    selectedConversationIds = []
                    manualTargetUserId = ""
                    showConversationPicker = false
                    importProjectRoots = []
                    importTargets = [:]
                    showConfirm = false
                    logText += "✅ 导入完成。\n"
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    logText += "❌ 导入失败：\(error.localizedDescription)\n"
                }
            }
        }
    }
}

// MARK: - 设计系统（Apple 风格 · 深色优先）

extension View {
    /// 卡片：14pt 连续曲率圆角 + 8% 细描边
    func cardBackground() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08)))
    }
}
