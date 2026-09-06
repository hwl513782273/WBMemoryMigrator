# WBMemoryMigrator / WorkBuddy 记忆备份

> 一款 macOS 原生的 WorkBuddy 数据一键导出 / 导入工具：长期记忆文件 · 对话记忆 · 全部 Skill · 项目空间，换机迁移一个 App 搞定。/ A native macOS one-click export & import tool for WorkBuddy data — long-term memory, conversation history, all Skills, and project workspaces. Migrate to a new Mac with a single app.

> **作者 Author：banqiu**
> **许可证 License：MIT**（详见 LICENSE）。可自由使用、修改与再分发，须保留版权与许可声明。

<p align="center"><img src="Resources/AppIcon.png" width="96" height="96" alt="WBMemoryMigrator"></p>

[下载最新版 / Download](https://github.com/hwl513782273/WBMemoryMigrator/releases/latest) · [问题反馈 / Issues](https://github.com/hwl513782273/WBMemoryMigrator/issues)

---

## 中文

### 主要功能
- **四大类数据，单独勾选**：长期记忆文件（MEMORY.md / memory / 工作区记忆）、对话记忆（workbuddy.db / sessions / projects）、全部 Skill（用户级 + 工作区）、项目空间（工作区源码本体），每类可独立开关。
- **每类实时显示「已选」总大小**：勾选即算，导出前心里有数。
- **项目空间精细勾选**：自动枚举所有工作区（来自 `workbuddy.db` 的 `workspaces` 表），支持「只显示工作区 / 工作区与子目录」两种视图，子目录可按需勾选；`node_modules` / `.git` / `build` / `DerivedData` / `Pods` / `vendor` / `dist` / `out` 等膨胀项默认排除，可手动加回。
- **导入路径重映射**：新机器路径不一致？导入时自选目标目录，App 自动写入并刷新 `workbuddy.db` 的 `workspaces` 路径，WorkBuddy 直接认得老工作区。
- **覆盖前自动备份**：导入与现有文件冲突时，旧文件先备份到 `~/.workbuddy/migrate_backups/<时间戳>/`，不丢任何数据。
- **工作区缺失兜底归档**：导入包内的工作区在新机器上不存在对应目录时，自动归档到 `~/.workbuddy/workspace_memory_archive/`，绝不为迁而丢。
- **实时进度条**：导出 / 导入全程显示百分比与阶段提示。
- **对话自选 + 账号过户**：导入时可逐条勾选要恢复的对话；恢复的会话自动过户到当前账号（跨账号导入不再「隐身」），并按导入映射自动改写会话工作目录（cwd），失效目录还会按名称自动探测挪位后的新位置。
- **工作区缺失自动落位**：目标工作区不存在时按**原目录结构**自动创建（如 `~/Downloads/workbuddy 项目/X` 原样重建）并注册进 workspaces 表，WorkBuddy 直接认出；可选改为归档模式。
- **自定义扫描路径**：把项目挪入的「收容所」文件夹加入扫描设置（深度 6 层），导出/导入自动跟上挪过位置的工作区。
- **冲突差异预览 + 三档策略**：导入预览逐条标注「新增 / 包内较新 / 本机较新 / 与本机一致」；冲突策略可选「始终覆盖 / 保留较新 / 跳过冲突」，两个备份包含同一项目不再抓瞎。
- **覆盖警示**：导入对话记忆前弹窗明示「本机 X 条会话将被替换为已勾选的 M 条」，未勾选任何对话时明确警告将清空。
- **目录合并语义**：目录对目录的还原改为递归合并（逐文件应用冲突策略），本机独有文件绝不会被整目录替换吞掉。
- **Apple 风格 UI 重设计**：卡片化布局、图标化区块标题、主次分明按钮、终端风日志，功能零改动。
- **安全加固**：导入清理范围限定为包内解压文件（本机原有会话文件不再被误删）；高危操作弹窗确认。
- **性能**：文件统计与全盘扫描挪后台线程（代数校验防乱序），同一个 zip 只解压一次，项目空间首屏秒出、大小懒加载回填。
- 原生 SwiftUI App，Universal（Apple Silicon + Intel），最低 macOS 12，拖入「应用程序」即用，无依赖脚本。

### 快速开始
1. 在 Releases 下载 `12-WBMemoryMigrator-1.2-universal.dmg`。
2. 打开 DMG，把 `WBMemoryMigrator.app` 拖入「应用程序」。
3. 首次打开：右键 → 打开（或终端执行 `xattr -dr com.apple.quarantine /Applications/WBMemoryMigrator.app`）。
4. 勾选要迁移的数据类别 → 点击「导出」，得到一个 zip 备份包。
5. 在新机器上打开 App → 选择该 zip → 确认导入（项目空间可逐个选择目标目录）。

从源码构建（需 macOS 12+ 与 Swift 工具链）：
```bash
bash build.sh      # swiftc 双架构编译 + lipo 合并 Universal + ad-hoc 签名
bash make_dmg.sh   # hdiutil 打包 DMG
```

### 导出包内容

| 类别 | 包内收集 | 说明 |
|---|---|---|
| 长期记忆 | `MEMORY.md`、`~/.workbuddy/memory/`、`workspace_memory_archive/`、各工作区 `.workbuddy/memory/` | 用户级 + 工作区级记忆 |
| 对话记忆 | `workbuddy.db`（一致性快照）、`sessions/`、`projects/` | 对话库用 SQLite `.backup` 取快照，保证一致性 |
| 全部 Skill | `~/.workbuddy/skills/`、各工作区 `.workbuddy/skills/` | 用户级 + 工作区级 Skill |
| 项目空间 | 各选中工作区勾选的顶层条目 | manifest 记录原始工作区根路径，导入时用于重映射 |

### 差异化亮点
- 🧳 **换机迁移一条龙**：记忆、对话、Skill、项目源码四类数据一个包带走，不用再手工翻目录拼凑。
- 🔀 **路径重映射自动刷新 db**：`workspaces` 表以绝对路径为主键，导入时自动 `UPDATE` 为新路径——新机器目录结构不同也不怕。
- 🧱 **膨胀项默认排除**：`node_modules` 一个目录就能撑到 GB 级；默认排除、按需加回，备份包保持轻量。
- 🛟 **冲突即备份、缺失即归档**：覆盖前自动备份旧文件到 `migrate_backups/`；目标工作区不存在时归档到 `workspace_memory_archive/`，两条兜底路径确保「只迁不丢」。
- 📊 **所见即所导**：每类实时显示已选大小，来源路径面板实时列出将收集的文件，导出前一目了然。
- 🔒 **纯本地运行**：导出 / 导入全部在你自己的机器上完成，不联网、不上传任何数据。
- 💻 **Universal 双架构**：同一份 DMG 覆盖 Apple Silicon 与 Intel，最低 macOS 12。

### 已知限制
- App 未公证（notarized），首次打开需右键「打开」放行 Gatekeeper。
- 导入会覆盖同路径的现有记忆文件（覆盖前自动备份）；若你在两台机器上同时改过同一份记忆，请自行取舍合并。
- 对话记忆快照基于本地 `workbuddy.db`；WorkBuddy 云端按账号同步的部分以云端为准，本工具不涉及云端数据。

---

## English

### Highlights
- **Four data categories, independently toggleable**: long-term memory (MEMORY.md / memory / workspace memory), conversation history (workbuddy.db / sessions / projects), all Skills (user-level + workspace), and project workspaces (source code itself).
- **Live "selected size" per category**: totals update in real time as you check/uncheck.
- **Fine-grained workspace selection**: enumerates all workspaces from the `workspaces` table in `workbuddy.db`; two view modes (workspace-only / workspace + sub-entries); bloat dirs (`node_modules`, `.git`, `build`, `DerivedData`, `Pods`, `vendor`, `dist`, `out`) are excluded by default and can be re-included manually.
- **Path remapping on import**: target machine has a different path? Pick a destination per workspace — the app writes files there and refreshes the `workspaces` paths in `workbuddy.db`, so WorkBuddy recognizes them immediately.
- **Automatic pre-overwrite backup**: on conflicts, existing files are backed up to `~/.workbuddy/migrate_backups/<timestamp>/` first — nothing gets lost.
- **Fallback archiving**: if a workspace from the backup doesn't exist on the new machine, its data is archived to `~/.workbuddy/workspace_memory_archive/` instead of being dropped.
- **Real-time progress**: percentage + phase text throughout export / import.
- **Conversation picking + account takeover**: tick individual conversations to restore; restored sessions are automatically re-owned to the current account (no more "invisible" imports across accounts), with session working directories (cwd) remapped per import mapping — and moved folders are auto-detected by name.
- **Auto-create missing workspaces**: recreates the **original directory structure** (e.g. `~/Downloads/workbuddy 项目/X`) and registers it in the workspaces table so WorkBuddy recognizes it immediately; archive mode available as an alternative.
- **Custom scan roots**: register "relocation vault" folders (scanned 6 levels deep) so export/import automatically follow moved workspaces.
- **Conflict diff preview + three policies**: import preview marks every entry as "new / newer in package / newer locally / identical"; choose per-import policy: always overwrite / keep newer / skip conflicts.
- **Overwrite warning**: importing conversations pops a dialog stating "X local sessions will be replaced by the M selected", with an explicit warning when nothing is selected.
- **Directory merge semantics**: directory-to-directory restore now merges recursively (per-file conflict policy) — local-only files are never swallowed by a whole-directory replacement.
- **Apple-style UI redesign**: card layout, iconified section headers, primary/secondary buttons, terminal-style log — zero functional changes.
- **Safety hardening**: import cleanup is limited to files extracted from the package (local-only session files are never deleted); high-risk operations require confirmation.
- **Performance**: file stats and full-disk scans moved to background threads (generation-guarded), each zip is extracted only once, project space first paint is instant with lazy size backfill.
- Native SwiftUI app, Universal (Apple Silicon + Intel), minimum macOS 12 — drag into Applications and it just works, no helper scripts.

### Quick start
1. Download `12-WBMemoryMigrator-1.2-universal.dmg` from Releases.
2. Open the DMG and drag `WBMemoryMigrator.app` into Applications.
3. First launch: right-click → Open (or run `xattr -dr com.apple.quarantine /Applications/WBMemoryMigrator.app` in Terminal).
4. Check the categories you want → click Export → get a single zip backup.
5. On the new machine, open the app → pick the zip → confirm import (choose destination folders per workspace as prompted).

Build from source (requires macOS 12+ and the Swift toolchain):
```bash
bash build.sh      # dual-arch swiftc + lipo universal merge + ad-hoc codesign
bash make_dmg.sh   # hdiutil DMG packaging
```

### Backup archive contents

| Category | Collected | Notes |
|---|---|---|
| Long-term memory | `MEMORY.md`, `~/.workbuddy/memory/`, `workspace_memory_archive/`, per-workspace `.workbuddy/memory/` | user-level + workspace-level memory |
| Conversations | `workbuddy.db` (consistent snapshot), `sessions/`, `projects/` | DB snapshot taken via SQLite `.backup` for consistency |
| Skills | `~/.workbuddy/skills/`, per-workspace `.workbuddy/skills/` | user-level + workspace-level skills |
| Project spaces | selected top-level entries of chosen workspaces | manifest records the original workspace root for import-time remapping |

### Why this tool
- 🧳 **End-to-end machine migration**: memory, conversations, skills, and project source in one archive — no more manually hunting directories.
- 🔀 **Automatic path remapping**: `workspaces` are keyed by absolute path; import rewrites them to the new location so the new machine just works.
- 🧱 **Bloat excluded by default**: a single `node_modules` can balloon to GBs; excluded by default, re-include on demand, backups stay light.
- 🛟 **Two safety nets**: auto-backup before overwrite (`migrate_backups/`) and fallback archiving for missing workspaces (`workspace_memory_archive/`) — migrate without losing anything.
- 📊 **What you see is what you export**: live size totals per category and a live source-path panel — no surprises before export.
- 🔒 **Fully local**: export and import run entirely on your machine — no network, no uploads, ever.
- 💻 **Universal binary**: one DMG covers Apple Silicon and Intel, macOS 12+.

### Known limitations
- The app is ad-hoc signed and **not notarized**; right-click "Open" on first launch to bypass Gatekeeper.
- Import overwrites existing memory files at the same paths (with automatic backup first); if you edited the same memory on both machines, merge manually.
- Conversation snapshots come from the local `workbuddy.db`; anything synced by WorkBuddy's cloud follows the cloud — this tool does not touch cloud data.

---

## 隐私与安全 / Privacy and security
- 纯本地运行，不上传任何数据；导出包保存在你指定的位置。/ Runs fully offline; the backup zip stays wherever you saved it.
- 导入覆盖前自动备份旧文件，删除/覆盖行为全部透明可查（`migrate_backups/`）。/ Old files are auto-backed up before any overwrite.
- 应用未公证，请仅从你信任的来源获取。/ The app is not notarized — only obtain it from sources you trust.

---

## 许可证 / License
**MIT License** — 版权归 **banqiu** 所有（2026）。
- 允许个人与商业免费使用、修改、再分发，须保留版权与许可声明。
- 完整条款见 [LICENSE](LICENSE)。

---

## 支持 / Support
WBMemoryMigrator 是一款免费开源工具，基于 MIT 许可发布，离线、无广告。如果你觉得好用，欢迎在 GitHub 上点个 Star，或反馈问题 / 提交 PR 帮它变得更好 —— 纯自愿。 This tool is free, open-source, and ad-free. If it helps you, a GitHub Star or an issue/PR is warmly welcome — entirely optional.
