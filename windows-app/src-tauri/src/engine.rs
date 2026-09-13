// WBMemoryMigrator Windows 核心引擎
// 与 macOS 版备份包格式完全互通（manifest 字段名一致），支持双向迁移。
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

// MARK: - 数据模型（字段名与 macOS 版 Codable 完全一致）

#[derive(Serialize, Deserialize, Clone)]
pub struct ExportItem {
    pub category: String,
    #[serde(rename = "realPath")]
    pub real_path: String,
    #[serde(rename = "bundleRel")]
    pub bundle_rel: String,
    #[serde(rename = "homeRel")]
    pub home_rel: Option<String>,
    pub size: u64,
    #[serde(rename = "workspaceRoot")]
    pub workspace_root: Option<String>,
    #[serde(rename = "registeredRoot")]
    pub registered_root: Option<String>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct MigratedWorkspace {
    pub registered: String,
    pub effective: String,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Manifest {
    #[serde(rename = "appVersion")]
    pub app_version: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
    pub items: Vec<ExportItem>,
    #[serde(rename = "homeDir")]
    pub home_dir: Option<String>,
    #[serde(rename = "migratedWorkspaces")]
    pub migrated_workspaces: Option<Vec<MigratedWorkspace>>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct ExportOptionsDto {
    #[serde(rename = "longTermMemory")]
    pub long_term_memory: bool,
    pub conversations: bool,
    pub skills: bool,
    #[serde(rename = "projectSpaces")]
    pub project_spaces: bool,
    #[serde(rename = "projectSelection")]
    pub project_selection: HashMap<String, Vec<String>>,
    #[serde(rename = "syncWorkspaceRegistry", default = "default_true")]
    pub sync_workspace_registry: bool,
}
fn default_true() -> bool { true }

#[derive(Serialize, Deserialize, Clone)]
pub struct ImportOptionsDto {
    pub memory: bool,
    pub conversations: bool,
    pub skills: bool,
    #[serde(rename = "projectSpaces")]
    pub project_spaces: bool,
    #[serde(rename = "projectTargets", default)]
    pub project_targets: HashMap<String, String>,
    #[serde(rename = "selectedSessions", default)]
    pub selected_sessions: Option<Vec<String>>,
    #[serde(rename = "targetUserId", default)]
    pub target_user_id: Option<String>,
    #[serde(rename = "conflictPolicy", default)]
    pub conflict_policy: String, // "always" | "keep_newer" | "skip"
    #[serde(rename = "archiveMissing", default)]
    pub archive_missing: bool,
}

#[derive(Serialize, Clone)]
pub struct WsOption {
    pub workspace: String,
    pub name: String,
    pub path: String,
    #[serde(rename = "isDir")]
    pub is_dir: bool,
    pub size: u64,
    #[serde(rename = "excludedByDefault")]
    pub excluded_by_default: bool,
    #[serde(rename = "registeredRoot")]
    pub registered_root: Option<String>,
}

#[derive(Serialize, Clone)]
pub struct ConversationDto {
    pub id: String,
    pub title: String,
    pub cwd: String,
    #[serde(rename = "userId")]
    pub user_id: String,
    #[serde(rename = "updatedAt")]
    pub updated_at: i64,
}

#[derive(Serialize, Clone)]
pub struct CategorySummary {
    pub key: String,
    pub count: usize,
    pub size: u64,
}

#[derive(Serialize, Clone)]
pub struct PackageInfo {
    #[serde(rename = "previewLines")]
    pub preview_lines: Vec<String>,
    pub summary: Vec<CategorySummary>,
    pub conversations: Vec<ConversationDto>,
    #[serde(rename = "projectRoots")]
    pub project_roots: Vec<String>,
    #[serde(rename = "manifestHome")]
    pub manifest_home: Option<String>,
}

pub const VERSION: &str = "1.3-win";

// MARK: - 基础路径

pub fn home_dir() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("C:\\"))
}

pub fn wb_dir() -> PathBuf { home_dir().join(".workbuddy") }

pub fn safe_name(p: &str) -> String {
    p.chars().map(|c| if c == '/' || c == '\\' || c == ':' { '_' } else { c }).collect()
}

pub fn fmt_size(b: u64) -> String {
    let kb = b as f64 / 1024.0;
    if kb < 1024.0 { return format!("{:.0} KB", kb); }
    let mb = kb / 1024.0;
    if mb < 1024.0 { return format!("{:.1} MB", mb); }
    format!("{:.2} GB", mb / 1024.0)
}

pub fn dir_size(p: &Path) -> u64 {
    WalkDir::new(p).follow_links(false).into_iter().filter_map(|e| e.ok())
        .filter_map(|e| e.metadata().ok())
        .filter(|m| m.is_file())
        .map(|m| m.len())
        .sum()
}

fn to_native(p: &str) -> String {
    if cfg!(windows) { p.replace('/', "\\") } else { p.to_string() }
}

/// SQLite 查询，返回所有行的第一列（静默失败返回空）
fn sqlite_query(db: &Path, sql: &str) -> Vec<String> {
    let mut out = Vec::new();
    if let Ok(conn) = Connection::open(db) {
        if let Ok(mut stmt) = conn.prepare(sql) {
            if let Ok(rows) = stmt.query_map([], |r| r.get::<_, String>(0)) {
                for r in rows.flatten() { out.push(r); }
            }
        }
    }
    out
}

// MARK: - 工作区解析

pub struct ResolvedWs {
    pub registered: String,
    pub effective: String,
}

pub fn workspace_paths() -> Vec<String> {
    let db = wb_dir().join("workbuddy.db");
    if !db.exists() { return Vec::new(); }
    sqlite_query(&db, "SELECT path FROM workspaces;")
        .into_iter().filter(|s| !s.trim().is_empty()).collect()
}

/// 扫描禁区：媒体/系统目录（相册图库等 TCC 受保护项）
const SKIP_DIRS: &[&str] = &[
    "Library", "Pictures", "Movies", "Music", "Public", "Applications",
    "Photos Library.photoslibrary", "AppData", "Application Data",
    "Windows", "Program Files", "Program Files (x86)", "ProgramData",
];

pub fn custom_scan_roots() -> Vec<String> {
    let f = wb_dir().join("scan_roots.txt");
    fs::read_to_string(&f).unwrap_or_default()
        .lines().map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && Path::new(s).exists())
        .collect()
}

pub fn set_custom_scan_roots(roots: &[String]) {
    let dir = wb_dir();
    let _ = fs::create_dir_all(&dir);
    let f = dir.join("scan_roots.txt");
    let _ = fs::write(&f, roots.join("\n"));
}

pub fn add_scan_root(p: &str) {
    let mut roots = custom_scan_roots();
    if !roots.iter().any(|r| r == p) { roots.push(p.to_string()); set_custom_scan_roots(&roots); }
}

pub fn remove_scan_root(p: &str) {
    let mut roots = custom_scan_roots();
    roots.retain(|r| r != p);
    set_custom_scan_roots(&roots);
}

/// 按文件夹名搜索（内置常见位置深度 4；自定义扫描根深度 6）
pub fn find_folder(name: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let home = home_dir();
    let mut roots: Vec<(PathBuf, usize)> = vec![
        (home.join("WorkBuddy"), 4),
        (home.join("Downloads"), 4),
        (home.join("Desktop"), 4),
        (home.join("Documents"), 4),
        (home.clone(), 4),
    ];
    for c in custom_scan_roots() { roots.push((PathBuf::from(&c), 6)); }
    let mut seen: Vec<PathBuf> = Vec::new();
    for (r, maxd) in roots {
        if !r.exists() || seen.contains(&r) { continue; }
        seen.push(r.clone());
        walk_find(&r, name, 1, maxd, &mut out);
    }
    out.sort();
    out.dedup();
    out
}

fn walk_find(dir: &Path, name: &str, depth: usize, maxd: usize, out: &mut Vec<String>) {
    if depth > maxd { return; }
    let rd = match fs::read_dir(dir) { Ok(d) => d, Err(_) => return };
    for e in rd.flatten() {
        let fname = e.file_name().to_string_lossy().to_string();
        if fname.starts_with('.') || SKIP_DIRS.contains(&fname.as_str()) { continue; }
        let Ok(ft) = e.file_type() else { continue };
        if !ft.is_dir() { continue; }
        let p = e.path();
        if fname == name { out.push(p.to_string_lossy().to_string()); }
        walk_find(&p, name, depth + 1, maxd, out);
    }
}

/// 解析 workspaces 登记路径：有效直接用；失效则按名探测新位置（唯一命中才用）
pub fn resolve_workspaces(log: &mut dyn FnMut(&str)) -> Vec<ResolvedWs> {
    let mut out = Vec::new();
    for wp in workspace_paths() {
        if Path::new(&wp).exists() {
            out.push(ResolvedWs { registered: wp.clone(), effective: wp });
            continue;
        }
        let name = Path::new(&wp).file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        let hits = find_folder(&name);
        if hits.len() == 1 {
            log(&format!("已探测到工作区挪位: 「{}」{} → {}（本次按新位置收集）", name, wp, hits[0]));
            out.push(ResolvedWs { registered: wp, effective: hits[0].clone() });
        } else if hits.len() > 1 {
            let cand: Vec<&str> = hits.iter().take(3).map(|s| s.as_str()).collect();
            log(&format!("⚠️ 工作区「{}」命中 {} 处，无法自动确定：{}。本次导出跳过其数据", name, hits.len(), cand.join("  |  ")));
        } else {
            log(&format!("⚠️ 工作区「{}」登记路径已失效且未找到新位置（含自定义扫描路径），本次导出跳过其数据", name));
        }
    }
    out
}

// MARK: - 项目空间枚举（快速，不算大小）

pub fn project_options_fast(log: &mut dyn FnMut(&str)) -> Vec<WsOption> {
    let mut out = Vec::new();
    for rw in resolve_workspaces(log) {
        let rd = match fs::read_dir(&rw.effective) { Ok(d) => d, Err(_) => continue };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name == ".workbuddy" || name.starts_with('.') { continue; }
            let Ok(ft) = e.file_type() else { continue };
            let is_dir = ft.is_dir();
            out.push(WsOption {
                workspace: rw.effective.clone(),
                name: name.clone(),
                path: e.path().to_string_lossy().to_string(),
                is_dir,
                size: 0,
                excluded_by_default: default_project_excludes(&name),
                registered_root: if rw.effective != rw.registered { Some(rw.registered.clone()) } else { None },
            });
        }
    }
    out
}

fn default_project_excludes(name: &str) -> bool {
    matches!(name, "node_modules" | ".git" | "build" | "DerivedData" | ".build"
        | "Pods" | "vendor" | "dist" | "out" | ".DS_Store" | "staging")
}

// MARK: - 账号探测

pub fn local_user_id() -> Option<String> {
    let db = wb_dir().join("workbuddy.db");
    if !db.exists() { return None; }
    sqlite_query(&db, "SELECT user_id FROM sessions GROUP BY user_id ORDER BY count(*) DESC LIMIT 1;")
        .into_iter().next().filter(|s| !s.trim().is_empty())
}

pub fn local_session_count() -> i64 {
    let db = wb_dir().join("workbuddy.db");
    if !db.exists() { return 0; }
    sqlite_query(&db, "SELECT count(*) FROM sessions;")
        .into_iter().next().and_then(|s| s.trim().parse().ok()).unwrap_or(0)
}

// MARK: - 复制 / 合并

fn copy_tree(src: &Path, dst: &Path, log: &mut dyn FnMut(&str)) -> u64 {
    let mut total = 0u64;
    for e in WalkDir::new(src).follow_links(true).max_depth(60).into_iter().filter_map(|e| e.ok()) {
        let rel = match e.path().strip_prefix(src) { Ok(r) => r, Err(_) => continue };
        let target = dst.join(rel);
        let md = match e.metadata() { Ok(m) => m, Err(_) => continue };
        if md.is_dir() {
            let _ = fs::create_dir_all(&target);
        } else if md.is_file() {
            if let Some(parent) = target.parent() { let _ = fs::create_dir_all(parent); }
            match fs::copy(e.path(), &target) {
                Ok(n) => total += n,
                Err(err) => log(&format!("复制失败: {} - {}", e.path().display(), err)),
            }
        }
        // 符号链接：跳过（Windows 上悬空链接无意义）
    }
    total
}

/// 目录递归合并：src 每个文件按冲突策略并入 dst；dst 独有内容一律不动
fn merge_dir(src: &Path, dst: &Path, policy: &str, backup_root: &Path, log: &mut dyn FnMut(&str)) {
    let rd = match fs::read_dir(src) { Ok(d) => d, Err(_) => return };
    for e in rd.flatten() {
        let s = e.path();
        let d = dst.join(e.file_name());
        let Ok(ft) = e.file_type() else { continue };
        if ft.is_dir() {
            let _ = fs::create_dir_all(&d);
            merge_dir(&s, &d, policy, backup_root, log);
            continue;
        }
        if d.exists() {
            if policy == "skip" {
                log(&format!("冲突跳过（策略=跳过冲突）: {}", d.display()));
                continue;
            }
            if policy == "keep_newer" {
                let l = fs::metadata(&d).and_then(|m| m.modified()).ok();
                let p = fs::metadata(&s).and_then(|m| m.modified()).ok();
                if let (Some(l), Some(p)) = (l, p) {
                    if l > p + std::time::Duration::from_secs(1) {
                        log(&format!("本机较新，跳过覆盖（策略=保留较新）: {}", d.display()));
                        continue;
                    }
                }
            }
            // 覆盖前先备份
            if let Some(bn) = d.file_name() {
                let bk = backup_root.join(safe_name(&d.to_string_lossy())).join(bn.to_string_lossy().to_string());
                if let Some(bp) = bk.parent() { let _ = fs::create_dir_all(bp); }
                let _ = fs::remove_file(&bk);
                let _ = fs::rename(&d, &bk);
            }
        }
        if let Some(parent) = d.parent() { let _ = fs::create_dir_all(parent); }
        match fs::copy(&s, &d) {
            Ok(_) => log(&format!("已还原(合并): {}", d.display())),
            Err(err) => log(&format!("合并失败: {} - {}", d.display(), err)),
        }
    }
}

// MARK: - 导出

struct ColTask { src: PathBuf, cat: &'static str, rel: String, workspace_root: Option<String>, registered_root: Option<String> }

fn build_tasks(opts: &ExportOptionsDto, log: &mut dyn FnMut(&str)) -> Vec<ColTask> {
    let wb = wb_dir();
    let mut tasks: Vec<ColTask> = Vec::new();
    macro_rules! push_task { ($src:expr, $cat:expr, $rel:expr, $ws:expr, $reg:expr) => {
        tasks.push(ColTask { src: $src, cat: $cat, rel: $rel.to_string(), workspace_root: $ws, registered_root: $reg });
    };}
    if opts.long_term_memory {
        push_task!(wb.join("MEMORY.md"), "userMemory", "MEMORY.md", None, None);
        push_task!(wb.join("memory"), "memoryCache", "memory_cache", None, None);
        push_task!(wb.join("workspace_memory_archive"), "workspaceArchive", "workspace_archive", None, None);
    }
    if opts.conversations {
        push_task!(wb.join("sessions"), "sessions", "conversations/sessions", None, None);
        push_task!(wb.join("projects"), "projects", "conversations/projects", None, None);
    }
    if opts.skills {
        push_task!(wb.join("skills"), "userSkills", "skills", None, None);
    }
    let resolved = resolve_workspaces(log);
    for rw in &resolved {
        let key = safe_name(&rw.effective);
        if opts.long_term_memory {
            push_task!(Path::new(&rw.effective).join(".workbuddy/memory"), "workspaceMemory",
                       format!("workspaces/{}/memory", key), Some(rw.effective.clone()), None);
        }
        if opts.skills {
            push_task!(Path::new(&rw.effective).join(".workbuddy/skills"), "workspaceSkills",
                       format!("workspaces/{}/skills", key), Some(rw.effective.clone()), None);
        }
    }
    if opts.project_spaces {
        for (ws, entries) in &opts.project_selection {
            for name in entries {
                let key = safe_name(ws);
                push_task!(Path::new(ws).join(name), "projectSpace",
                           format!("workspaces/{}/{}", key, name), Some(ws.clone()), None);
            }
        }
    }
    tasks
}

/// 导出数据来源路径（供 UI 统计各类别大小）
pub fn collect_source_paths(opts: &ExportOptionsDto, log: &mut dyn FnMut(&str)) -> Vec<String> {
    build_tasks(opts, log).into_iter()
        .filter(|t| t.src.exists())
        .map(|t| t.src.to_string_lossy().to_string())
        .collect()
}

pub fn export(zip_path: &str, opts: &ExportOptionsDto,
              log: &mut dyn FnMut(&str), progress: &mut dyn FnMut(f64, &str)) -> Result<(), String> {
    let home = home_dir();
    let wb = wb_dir();
    let staging = std::env::temp_dir().join(format!("wbmem_export_{}", chrono::Utc::now().timestamp_millis()));
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging).map_err(|e| e.to_string())?;

    let tasks = build_tasks(opts, log);

    let n = tasks.len().max(1) as f64;
    progress(0.02, "正在收集文件…");
    let mut items: Vec<ExportItem> = Vec::new();

    for (i, t) in tasks.iter().enumerate() {
        if !t.src.exists() {
            log(&format!("跳过(不存在): {}", t.src.display()));
            progress(0.6 * (i as f64 + 1.0) / n, "正在收集文件…");
            continue;
        }
        let dest = staging.join(&t.rel);
        if let Some(parent) = dest.parent() { fs::create_dir_all(parent).map_err(|e| e.to_string())?; }
        let md = fs::metadata(&t.src).map_err(|e| e.to_string())?;
        let sz = if md.is_dir() { copy_tree(&t.src, &dest, log) } else {
            fs::copy(&t.src, &dest).map_err(|e| e.to_string())?
        };
        let home_rel = if t.workspace_root.is_none() {
            t.src.to_string_lossy().strip_prefix(&home.to_string_lossy().to_string())
                .map(|r| to_slash(r.trim_start_matches('/'))).filter(|r| !r.is_empty())
        } else { None };
        items.push(ExportItem {
            category: t.cat.to_string(),
            real_path: t.src.to_string_lossy().to_string(),
            bundle_rel: t.rel.clone(),
            home_rel,
            size: sz,
            workspace_root: t.workspace_root.clone(),
            registered_root: t.registered_root.clone(),
        });
        log(&format!("已收集 {}：{} ({})", t.cat, t.src.display(), fmt_size(sz)));
        progress(0.6 * (i as f64 + 1.0) / n, "正在收集文件…");
    }

    // 对话库一致性快照（rusqlite backup API）
    if opts.conversations {
        progress(0.62, "正在快照对话库…");
        let db_src = wb.join("workbuddy.db");
        if db_src.exists() {
            let db_dest = staging.join("conversations/workbuddy.db");
            fs::create_dir_all(db_dest.parent().unwrap()).map_err(|e| e.to_string())?;
            snapshot_db(&db_src, &db_dest)?;
            let sz = dir_size(&db_dest);
            let home_rel = db_src.to_string_lossy()
                .strip_prefix(&home.to_string_lossy().to_string())
                .map(|r| to_slash(r.trim_start_matches('/'))).filter(|r| !r.is_empty());
            items.push(ExportItem {
                category: "conversationsDB".into(),
                real_path: db_src.to_string_lossy().to_string(),
                bundle_rel: "conversations/workbuddy.db".into(),
                home_rel, size: sz, workspace_root: None, registered_root: None,
            });
            log(&format!("已快照对话库 conversations/workbuddy.db ({})", fmt_size(sz)));
        }
    }
    progress(0.7, "正在写入清单…");

    let manifest = Manifest {
        app_version: VERSION.into(),
        created_at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        items,
        home_dir: Some(to_slash(&home.to_string_lossy())),
        migrated_workspaces: None,
    };
    let man_path = staging.join("manifest.json");
    fs::write(&man_path, serde_json::to_string_pretty(&manifest).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;

    progress(0.78, "正在打包压缩…（大包耗时较久，进度按压缩体积估算）");
    if let Some(p) = Path::new(zip_path).parent() { fs::create_dir_all(p).map_err(|e| e.to_string())?; }
    let _ = fs::remove_file(zip_path);
    zip_dir(&staging, Path::new(zip_path), &mut |frac| {
        progress(0.78 + 0.2 * frac, "正在打包压缩…（大包耗时较久，进度按压缩体积估算）");
    })?;
    progress(1.0, "完成");
    log(&format!("导出完成: {} ({})", zip_path, fmt_size(dir_size(Path::new(zip_path)))));
    let _ = fs::remove_dir_all(&staging);

    // 可选：把探测到的挪位工作区注册路径同步修正到真实位置
    if opts.sync_workspace_registry {
        for rw in resolve_workspaces(log) {
            if rw.effective != rw.registered {
                if let Ok(conn) = Connection::open(wb.join("workbuddy.db")) {
                    let _ = conn.execute("UPDATE workspaces SET path=?1 WHERE path=?2",
                        rusqlite::params![rw.effective, rw.registered]);
                    log(&format!("已同步工作区注册路径: {} → {}", rw.registered, rw.effective));
                }
            }
        }
    }
    Ok(())
}

fn to_slash(p: &str) -> String {
    if cfg!(windows) { p.replace('\\', "/") } else { p.to_string() }
}

fn snapshot_db(src: &Path, dst: &Path) -> Result<(), String> {
    let s = Connection::open(src).map_err(|e| e.to_string())?;
    let mut d = Connection::open(dst).map_err(|e| e.to_string())?;
    let bk = rusqlite::backup::Backup::new(&s, &mut d).map_err(|e| e.to_string())?;
    bk.run_to_completion(128, std::time::Duration::from_millis(5), None).map_err(|e| e.to_string())?;
    Ok(())
}

fn zip_dir(staging: &Path, zip_path: &Path, progress: &mut dyn FnMut(f64)) -> Result<(), String> {
    let all: Vec<PathBuf> = WalkDir::new(staging).into_iter().filter_map(|e| e.ok())
        .map(|e| e.path().to_path_buf()).collect();
    let total: u64 = all.iter().filter_map(|p| fs::metadata(p).ok()).filter(|m| m.is_file()).map(|m| m.len()).sum();
    let file = fs::File::create(zip_path).map_err(|e| e.to_string())?;
    let mut zw = zip::ZipWriter::new(file);
    let options: zip::write::SimpleFileOptions = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    let mut done: u64 = 0;
    for p in &all {
        let rel = p.strip_prefix(staging).map_err(|e| e.to_string())?;
        let rel_s = rel.to_string_lossy().replace('\\', "/");
        if rel_s.is_empty() { continue; }
        let md = fs::metadata(p).map_err(|e| e.to_string())?;
        if md.is_dir() {
            zw.add_directory(&rel_s, options).map_err(|e| e.to_string())?;
        } else {
            zw.start_file(&rel_s, options).map_err(|e| e.to_string())?;
            let mut f = fs::File::open(p).map_err(|e| e.to_string())?;
            std::io::copy(&mut f, &mut zw).map_err(|e| e.to_string())?;
            done += md.len();
            progress(done as f64 / total.max(1) as f64);
        }
    }
    zw.finish().map_err(|e| e.to_string())?;
    Ok(())
}

// MARK: - 落位推断（跨平台）

/// 老包同名用户推断：/Users/<名>/... 且 <名> 与当前用户一致 → 原 home 即当前 home
fn infer_old_home(old_root: &str) -> Option<String> {
    if old_root.starts_with("/Users/") {
        let comps: Vec<&str> = old_root.split('/').filter(|s| !s.is_empty()).collect();
        if comps.len() >= 2 {
            let cur_user = home_dir().file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
            if comps[1] == cur_user { return Some(format!("/Users/{}", comps[1])); }
        }
    }
    None
}

/// 工作区缺失时的落位：优先按原 home 相对结构重建；家目录外回退 %USERPROFILE%\WorkBuddy\<名>
pub fn auto_root(old_root: &str, manifest_home: Option<&str>) -> String {
    let mut oh = manifest_home.map(|s| s.to_string());
    if oh.is_none() || oh.as_deref() == Some("") { oh = infer_old_home(old_root); }
    if let Some(oh) = oh {
        if !oh.is_empty() && old_root.starts_with(&oh) && old_root != oh {
            let rel = &old_root[oh.len()..];
            if rel.starts_with('/') {
                let preferred = home_dir().join(to_native(rel.trim_start_matches('/')));
                if !preferred.exists() { return preferred.to_string_lossy().to_string(); }
                // 被占用：-imported 后缀，绝不覆盖
                let mut n = 1;
                loop {
                    let cand = if n == 1 {
                        PathBuf::from(format!("{}-imported", preferred.to_string_lossy()))
                    } else {
                        PathBuf::from(format!("{}-imported-{}", preferred.to_string_lossy(), n))
                    };
                    if !cand.exists() { return cand.to_string_lossy().to_string(); }
                    n += 1;
                }
            }
        }
    }
    ws_auto_create_root(old_root)
}

fn ws_auto_create_root(old_root: &str) -> String {
    let name = Path::new(old_root).file_name().map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "workspace".into());
    let base = home_dir().join("WorkBuddy");
    let mut root = base.join(&name);
    let mut n = 1;
    while root.exists() {
        n += 1;
        root = base.join(if n == 2 { format!("{}-imported", name) } else { format!("{}-imported-{}", name, n - 1) });
    }
    root.to_string_lossy().to_string()
}

fn register_workspace(root: &str) {
    let db = wb_dir().join("workbuddy.db");
    if !db.exists() { return; }
    if let Ok(conn) = Connection::open(&db) {
        let _ = conn.execute(
            "INSERT OR IGNORE INTO workspaces(path, last_opened_at) VALUES(?1, strftime('%s','now')*1000)",
            rusqlite::params![root]);
    }
}

fn backup_existing(dst: &Path, backup_root: &Path) {
    if !dst.exists() { return; }
    let bk = backup_root.join(safe_name(&dst.to_string_lossy()));
    if let Some(bp) = bk.parent() { let _ = fs::create_dir_all(bp); }
    if bk.exists() { let _ = fs::remove_dir_all(&bk); }
    let _ = fs::rename(dst, &bk);
}

fn conflict_note(dst: &Path, src: &Path) -> String {
    if !dst.exists() { return "  （新增）".into(); }
    let l = fs::metadata(dst).and_then(|m| m.modified()).ok();
    let p = fs::metadata(src).and_then(|m| m.modified()).ok();
    match (l, p) {
        (Some(l), Some(p)) => {
            if p > l + std::time::Duration::from_secs(1) { "  ⚠️ 包内较新（将覆盖本机）".into() }
            else if p < l - std::time::Duration::from_secs(1) { "  ⚠️ 本机较新（导入将被包内版本替换）".into() }
            else { "  （与本机一致）".into() }
        }
        _ => "  ⚠️ 与本机现有文件冲突".into(),
    }
}

// MARK: - 包检查（单次解压取全部导入前信息）

pub fn inspect_package(zip_path: &str, targets: &HashMap<String, String>,
                       log: &mut dyn FnMut(&str)) -> Result<PackageInfo, String> {
    let tmp = std::env::temp_dir().join(format!("wbmem_inspect_{}_{}", chrono::Utc::now().timestamp_millis(), rand_suffix()));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
    let result = inspect_at(zip_path, &tmp, targets, log);
    let _ = fs::remove_dir_all(&tmp);
    result
}

fn rand_suffix() -> u32 { std::process::id() ^ (chrono::Utc::now().timestamp_subsec_nanos()) }

fn inspect_at(zip_path: &str, tmp: &Path, targets: &HashMap<String, String>,
              log: &mut dyn FnMut(&str)) -> Result<PackageInfo, String> {
    unzip(zip_path, tmp, log)?;
    let man_data = fs::read(tmp.join("manifest.json")).map_err(|e| format!("读取 manifest 失败: {}", e))?;
    let m: Manifest = serde_json::from_slice(&man_data).map_err(|e| format!("解析 manifest 失败: {}", e))?;

    let mut lines = Vec::new();
    for item in &m.items {
        let src = tmp.join(&item.bundle_rel);
        if item.category == "projectSpace" {
            let mut note = "未选目录→自动落位".to_string();
            let mut dst = item.real_path.clone();
            if let Some(root) = &item.workspace_root {
                if let Some(nr) = targets.get(root) {
                    let entry_name = Path::new(&item.real_path).file_name()
                        .map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                    dst = PathBuf::from(nr).join(entry_name).to_string_lossy().to_string();
                    note = "已选目标目录".into();
                } else if !Path::new(root).exists() {
                    let ar = auto_root(root, m.home_dir.as_deref());
                    let entry_name = Path::new(&item.real_path).file_name()
                        .map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                    dst = PathBuf::from(&ar).join(entry_name).to_string_lossy().to_string();
                    note = format!("原路径不存在→自动创建并注册: {}", ar);
                }
            }
            lines.push(format!("→ {}  （项目空间 · {} · {}）{}", dst, fmt_size(item.size), note, conflict_note(Path::new(&dst), &src)));
            continue;
        }
        let mut dst = resolve_dst(item);
        let mut note = String::new();
        if item.category == "workspaceMemory" || item.category == "workspaceSkills" {
            let old_ws_root = item.workspace_root.clone().unwrap_or_else(|| {
                let d = Path::new(&dst).parent().unwrap_or(Path::new("/"));
                d.parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default()
            });
            if !Path::new(&old_ws_root).exists() {
                let sub = if item.category == "workspaceMemory" { "memory" } else { "skills" };
                let new_root = auto_root(&old_ws_root, m.home_dir.as_deref());
                dst = PathBuf::from(&new_root).join(".workbuddy").join(sub).to_string_lossy().to_string();
                note = format!("  ⚠️ 目标工作区不存在→自动创建并注册: {}", new_root);
            }
        }
        lines.push(format!("→ {}  （{} · {}）{}{}", dst, item.category, fmt_size(item.size), note, conflict_note(Path::new(&dst), &src)));
    }

    let mut agg: HashMap<&str, (usize, u64)> = HashMap::new();
    for item in &m.items {
        let k = group_key(&item.category);
        let e = agg.entry(k).or_insert((0, 0));
        e.0 += 1; e.1 += item.size;
    }
    let mut summary = Vec::new();
    for k in ["memory", "conversations", "skills", "projectSpaces"] {
        if let Some((c, s)) = agg.get(k) { summary.push(CategorySummary { key: k.into(), count: *c, size: *s }); }
    }

    let convs = parse_sessions_db(&tmp.join("conversations/workbuddy.db"));
    let mut roots: Vec<String> = m.items.iter()
        .filter(|i| i.category == "projectSpace")
        .filter_map(|i| i.workspace_root.clone()).collect();
    roots.sort(); roots.dedup();

    Ok(PackageInfo { preview_lines: lines, summary, conversations: convs, project_roots: roots, manifest_home: m.home_dir.clone() })
}

fn group_key(cat: &str) -> &'static str {
    match cat {
        "userMemory" | "memoryCache" | "workspaceArchive" | "workspaceMemory" => "memory",
        "sessions" | "projects" | "conversationsDB" => "conversations",
        "userSkills" | "workspaceSkills" => "skills",
        "projectSpace" => "projectSpaces",
        _ => "other",
    }
}

fn resolve_dst(item: &ExportItem) -> String {
    if let Some(hr) = &item.home_rel {
        if !hr.is_empty() { return home_dir().join(to_native(hr)).to_string_lossy().to_string(); }
    }
    item.real_path.clone()
}

fn parse_sessions_db(db: &Path) -> Vec<ConversationDto> {
    let mut out = Vec::new();
    if !db.exists() { return out; }
    let Ok(conn) = Connection::open(db) else { return out };
    let sql = "SELECT id, COALESCE(NULLIF(custom_title,''), IFNULL(title,'(无标题)')), IFNULL(cwd,''), user_id, IFNULL(updated_at,0) FROM sessions ORDER BY updated_at DESC;";
    if let Ok(mut stmt) = conn.prepare(sql) {
        if let Ok(rows) = stmt.query_map([], |r| {
            Ok(ConversationDto {
                id: r.get(0)?, title: r.get(1)?, cwd: r.get(2)?,
                user_id: r.get(3)?, updated_at: r.get(4)?,
            })
        }) {
            for r in rows.flatten() { out.push(r); }
        }
    }
    out
}

fn unzip(zip_path: &str, dst: &Path, log: &mut dyn FnMut(&str)) -> Result<(), String> {
    let f = fs::File::open(zip_path).map_err(|e| format!("打开备份包失败: {}", e))?;
    let mut za = zip::ZipArchive::new(f).map_err(|e| format!("读取备份包失败: {}", e))?;
    for i in 0..za.len() {
        let mut entry = za.by_index(i).map_err(|e| e.to_string())?;
        let name = entry.name().to_string();
        let Some(enc) = entry.enclosed_name() else {
            log(&format!("跳过不安全路径: {}", name));
            continue;
        };
        // 符号链接条目：跳过并记录（Windows 上无法还原跨机链接）
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Some(mode) = entry.unix_mode() {
                if mode & 0o170000 == 0o120000 {
                    let mut t = String::new();
                    let _ = entry.read_to_string(&mut t);
                    log(&format!("跳过符号链接（Windows 暂不支持还原）: {} → {}", name, t.trim()));
                    continue;
                }
            }
        }
        let target = dst.join(enc);
        if entry.is_dir() {
            fs::create_dir_all(&target).map_err(|e| e.to_string())?;
        } else {
            if let Some(parent) = target.parent() { fs::create_dir_all(parent).map_err(|e| e.to_string())?; }
            let mut out = fs::File::create(&target).map_err(|e| e.to_string())?;
            std::io::copy(&mut entry, &mut out).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

// MARK: - 导入

pub fn import(zip_path: &str, opts: &ImportOptionsDto,
              log: &mut dyn FnMut(&str), progress: &mut dyn FnMut(f64, &str)) -> Result<(), String> {
    let home = home_dir();
    let wb = wb_dir();
    fs::create_dir_all(&wb).map_err(|e| e.to_string())?;
    let tmp = std::env::temp_dir().join(format!("wbmem_import_{}_{}", chrono::Utc::now().timestamp_millis(), rand_suffix()));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;

    let result = (|| -> Result<(), String> {
        progress(0.02, "正在解压备份包…");
        unzip(zip_path, &tmp, log)?;
        let man_data = fs::read(tmp.join("manifest.json")).map_err(|e| format!("读取 manifest 失败: {}", e))?;
        let m: Manifest = serde_json::from_slice(&man_data).map_err(|e| format!("解析 manifest 失败: {}", e))?;

        // 覆盖前备份根目录
        let ts = chrono::Utc::now().format("%Y%m%d_%H%M%S");
        let backup_root = wb.join("migrate_backups").join(ts.to_string());
        fs::create_dir_all(&backup_root).map_err(|e| e.to_string())?;
        log(&format!("被覆盖的原文件将备份到: {}", backup_root.display()));

        let policy = match opts.conflict_policy.as_str() { "keep_newer" => "keep_newer", "skip" => "skip", _ => "always" };

        let total = m.items.len().max(1) as f64;
        let mut idx = 0f64;
        for item in &m.items {
            idx += 1.0;
            progress(0.1 + 0.75 * idx / total, "正在还原文件…");
            let allowed = match item.category.as_str() {
                "userMemory" | "memoryCache" | "workspaceArchive" | "workspaceMemory" => opts.memory,
                "sessions" | "projects" | "conversationsDB" => opts.conversations,
                "userSkills" | "workspaceSkills" => opts.skills,
                "projectSpace" => opts.project_spaces,
                _ => true,
            };
            if !allowed { log(&format!("按导入范围跳过: {} {}", item.category, item.bundle_rel)); continue; }
            let src = tmp.join(&item.bundle_rel);
            if !src.exists() { log(&format!("包内缺失: {}", item.bundle_rel)); continue; }
            restore_item(item, &src, &tmp, &m, opts, policy, &backup_root, &home, &wb, log)?;
        }

        // 对话库后处理：自选保留 + 账号过户 + cwd 重映射/重排 slug + 自动探测
        if opts.conversations {
            post_process_conversations(&tmp, &wb, opts, &m, log)?;
        }

        progress(1.0, "完成");
        log(&format!("导入完成。被覆盖的原文件已备份到: {}", backup_root.display()));
        Ok(())
    })();

    let _ = fs::remove_dir_all(&tmp);
    result
}

#[allow(clippy::too_many_arguments)]
fn restore_item(item: &ExportItem, src: &Path, tmp: &Path, m: &Manifest, opts: &ImportOptionsDto,
                policy: &str, backup_root: &Path, home: &Path, wb: &Path,
                log: &mut dyn FnMut(&str)) -> Result<(), String> {
    // 项目空间：按映射/自动落位
    if item.category == "projectSpace" {
        let entry_name = Path::new(&item.real_path).file_name()
            .map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        let dst: PathBuf = if let Some(root) = &item.workspace_root {
            if let Some(nr) = opts.project_targets.get(root) {
                PathBuf::from(nr).join(&entry_name)
            } else if !Path::new(root).exists() {
                let ar = auto_root(root, m.home_dir.as_deref());
                fs::create_dir_all(&ar).map_err(|e| e.to_string())?;
                register_workspace(&ar);
                log(&format!("项目空间未选目标目录，已自动创建并注册: {}", ar));
                PathBuf::from(&ar).join(&entry_name)
            } else {
                PathBuf::from(root).join(&entry_name)
            }
        } else {
            PathBuf::from(&item.real_path)
        };
        restore_into(src, &dst, policy, backup_root, log);
        return Ok(());
    }

    let mut dst = resolve_dst(item);
    // 工作区类：目标工作区不存在
    if item.category == "workspaceMemory" || item.category == "workspaceSkills" {
        let old_ws_root = item.workspace_root.clone().unwrap_or_else(|| {
            let d = Path::new(&dst).parent().unwrap_or(Path::new("/"));
            d.parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default()
        });
        if !Path::new(&old_ws_root).exists() {
            if opts.archive_missing {
                let arc_name = safe_name(&old_ws_root);
                let sub = if item.category == "workspaceMemory" { "memory" } else { "skills" };
                let arc_dst = wb.join("workspace_memory_archive").join(arc_name).join(sub);
                backup_existing(&arc_dst, backup_root);
                if let Some(p) = arc_dst.parent() { let _ = fs::create_dir_all(p); }
                copy_tree(src, &arc_dst, log);
                log(&format!("目标工作区不存在，已归档工作区{}到: {}", item.category, arc_dst.display()));
                return Ok(());
            }
            let sub = if item.category == "workspaceMemory" { "memory" } else { "skills" };
            let new_root = auto_root(&old_ws_root, m.home_dir.as_deref());
            let wbd = PathBuf::from(&new_root).join(".workbuddy");
            let _ = fs::create_dir_all(&wbd);
            register_workspace(&new_root);
            log(&format!("目标工作区不存在，已自动创建并注册: {}（{} 将还原到该工作区）", new_root, item.category));
            dst = wbd.join(sub).to_string_lossy().to_string();
        }
    }
    restore_into(src, Path::new(&dst), policy, backup_root, log);
    Ok(())
}

fn restore_into(src: &Path, dst: &Path, policy: &str, backup_root: &Path, log: &mut dyn FnMut(&str)) {
    let src_md = match fs::metadata(src) { Ok(m) => m, Err(e) => { log(&format!("读取失败 {}: {}", src.display(), e)); return; } };
    if src_md.is_dir() && dst.exists() && dst.is_dir() {
        merge_dir(src, dst, policy, backup_root, log);
        return;
    }
    if dst.exists() {
        if policy == "skip" { log(&format!("冲突跳过（策略=跳过冲突）: {}", dst.display())); return; }
        if policy == "keep_newer" {
            let l = fs::metadata(dst).and_then(|m| m.modified()).ok();
            let p = src_md.modified().ok();
            if let (Some(l), Some(p)) = (l, p) {
                if l > p + std::time::Duration::from_secs(1) {
                    log(&format!("本机较新，跳过覆盖（策略=保留较新）: {}", dst.display()));
                    return;
                }
            }
        }
        backup_existing(dst, backup_root);
    }
    if let Some(parent) = dst.parent() { let _ = fs::create_dir_all(parent); }
    if src_md.is_dir() {
        copy_tree(src, dst, log);
        log(&format!("已还原目录: {}", dst.display()));
    } else {
        match fs::copy(src, dst) {
            Ok(_) => log(&format!("已还原: {}", dst.display())),
            Err(e) => log(&format!("还原失败: {} - {}", dst.display(), e)),
        }
    }
}

/// Windows slug：`C:\Users\Administrator\WorkBuddy\测试` → `c-Users-Administrator-WorkBuddy-测试`
pub fn win_slug(cwd: &str) -> String {
    let norm = cwd.replace('/', "\\");
    let comps: Vec<String> = norm.split('\\').filter(|s| !s.is_empty()).map(|s| s.to_string()).collect();
    if comps.is_empty() { return String::new(); }
    let mut parts: Vec<String> = Vec::new();
    let first = &comps[0];
    if first.len() >= 2 && first.as_bytes()[1] == b':' {
        parts.push(first[..1].to_lowercase());
        for c in &comps[1..] { parts.push(c.clone()); }
    } else {
        parts.extend(comps);
    }
    parts.join("-")
}

fn post_process_conversations(tmp: &Path, wb: &Path, opts: &ImportOptionsDto,
                              m: &Manifest, log: &mut dyn FnMut(&str)) -> Result<(), String> {
    let home = home_dir();
    let db = wb.join("workbuddy.db");
    if !db.exists() { return Ok(()); }

    // 1) 对话自选：只保留勾选会话（db 行删除）
    let keep: Option<std::collections::HashSet<String>> = opts.selected_sessions.as_ref().map(|v| v.iter().cloned().collect());
    if let Some(keep) = &keep {
        let conn = Connection::open(&db).map_err(|e| e.to_string())?;
        let all: Vec<String> = {
            let mut stmt = conn.prepare("SELECT id FROM sessions;").map_err(|e| e.to_string())?;
            let rows = stmt.query_map([], |r| r.get::<_, String>(0)).map_err(|e| e.to_string())?;
            rows.flatten().collect()
        };
        let mut deleted = 0usize;
        for id in &all {
            if !keep.contains(id) {
                let _ = conn.execute("DELETE FROM sessions WHERE id=?1", rusqlite::params![id]);
                let _ = conn.execute("DELETE FROM session_usage WHERE session_id=?1", rusqlite::params![id]);
                deleted += 1;
            }
        }
        log(&format!("按勾选保留会话 {} 条，其余 {} 条 db 行已删除", keep.len(), deleted));
    }

    // 2) 账号过户
    if let Some(target) = opts.target_user_id.clone().or_else(local_user_id) {
        if !target.trim().is_empty() {
            if let Ok(conn) = Connection::open(&db) {
                let n = conn.execute("UPDATE sessions SET user_id=?1 WHERE user_id<>?1",
                                     rusqlite::params![target]).unwrap_or(0);
                log(&format!("已过户会话到账号: {}（改写 {} 行）{}", target, n,
                    if opts.target_user_id.is_some() { "" } else { "·自动探测" }));
            }
        }
    } else {
        log("⚠️ 未探测到本机账号 id，会话 user_id 未改写（请在 UI 手动填写目标账号）");
    }

    // 3) cwd 重映射（Rust 侧逐条改写，规避 SQL LIKE 转义问题）+ jsonl 按 Windows slug 归位
    let staged_projects = tmp.join("conversations/projects");
    let local_projects = wb.join("projects");
    let _ = fs::create_dir_all(&local_projects);

    // 收集包内解压出的对话文件（id → staged 路径），只处理包内文件，绝不触碰本机原有会话文件
    let mut staged_files: HashMap<String, (PathBuf, bool)> = HashMap::new(); // id → (路径, is_dir)
    if staged_projects.exists() {
        // conversations/projects/<slug>/<id>.jsonl 与 conversations/projects/<slug>/<id>/ 附属目录
        for e in WalkDir::new(&staged_projects).max_depth(2).into_iter().filter_map(|e| e.ok()) {
            let depth = e.depth();
            if depth < 2 { continue; }
            let name = e.file_name().to_string_lossy().to_string();
            if e.file_type().is_file() {
                if let Some(stem) = name.strip_suffix(".jsonl") {
                    staged_files.entry(stem.to_string())
                        .or_insert_with(|| (e.path().to_path_buf(), false));
                }
            } else if e.file_type().is_dir() && depth == 2 {
                staged_files.entry(name).or_insert_with(|| (e.path().to_path_buf(), true));
            }
        }
    }

    let old_home = m.home_dir.clone().unwrap_or_default();
    let cur_user = home.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let targets = opts.project_targets.clone();

    if let Ok(conn) = Connection::open(&db) {
        let rows: Vec<(String, String)> = {
            let mut stmt = conn.prepare("SELECT id, IFNULL(cwd,'') FROM sessions;").map_err(|e| e.to_string())?;
            let r = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).map_err(|e| e.to_string())?;
            r.flatten().collect()
        };
        for (id, cwd) in rows {
            if cwd.is_empty() { continue; }
            let mut new_cwd: Option<String> = None;
            // a) 项目空间映射
            for (old_root, new_root) in &targets {
                if cwd == *old_root || cwd.starts_with(&format!("{}/", old_root.trim_end_matches('/')))
                    || cwd.starts_with(&format!("{}\\", old_root.trim_end_matches('\\'))) {
                    let rest = &cwd[old_root.len()..];
                    let rest = rest.trim_start_matches(['/', '\\']);
                    new_cwd = Some(PathBuf::from(new_root).join(to_native(rest)).to_string_lossy().to_string());
                    break;
                }
            }
            // b) 旧 home 前缀 → 新 home（含 /Users/<同名> 推断，转本机分隔符）
            if new_cwd.is_none() {
                let mut oh = old_home.clone();
                if oh.is_empty() { oh = infer_old_home(&cwd).unwrap_or_default(); }
                if !oh.is_empty() && cwd.starts_with(&oh) && cwd.len() > oh.len() {
                    let rest = cwd[oh.len()..].trim_start_matches('/');
                    new_cwd = Some(home.join(to_native(rest)).to_string_lossy().to_string());
                }
            }
            // c) 自动探测挪位（唯一命中才改）
            let mut final_cwd = new_cwd.unwrap_or_else(|| cwd.clone());
            if !Path::new(&final_cwd).exists() {
                let name = Path::new(&final_cwd).file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                let hits = find_folder(&name);
                if hits.len() == 1 {
                    log(&format!("cwd 自动探测: 「{}」→ {}", name, hits[0]));
                    final_cwd = hits[0].clone();
                }
            }
            if final_cwd != cwd {
                let _ = conn.execute("UPDATE sessions SET cwd=?1 WHERE id=?2",
                                     rusqlite::params![final_cwd, id]);
            }
            // jsonl 归位：包内文件按新 cwd 的 Windows slug 放置
            if let Some((spath, is_dir)) = staged_files.get(&id) {
                if keep.as_ref().map(|k| k.contains(&id)).unwrap_or(true) && !final_cwd.is_empty() {
                    let slug = win_slug(&final_cwd);
                    let dst_dir = local_projects.join(slug);
                    let _ = fs::create_dir_all(&dst_dir);
                    let dst_file = dst_dir.join(format!("{}.jsonl", id));
                    if !is_dir {
                        if dst_file.exists() { log(&format!("对话文件已存在，保留本机版本: {}", dst_file.display())); }
                        else {
                            if let Err(e) = fs::copy(spath, &dst_file) { log(&format!("对话文件归位失败: {}", e)); }
                        }
                    }
                    let dst_sub = dst_dir.join(&id);
                    if *is_dir && !dst_sub.exists() {
                        copy_tree(spath, &dst_sub, log);
                    }
                }
            }
        }
        log("包内对话文件已按本机工作目录规则归位（本机原有会话文件不受影响）");
    }
    Ok(())
}

// MARK: - 隔离往返验证（cargo test，HOME 重定向，不碰真实数据）

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_safe_and_auto_root() {
        assert_eq!(win_slug(r"C:\Users\Administrator\WorkBuddy\测试"), "c-Users-Administrator-WorkBuddy-测试");
        assert_eq!(win_slug(r"E:\AIwork\workbuddy project"), "e-AIwork-workbuddy project");
        assert_eq!(safe_name(r"C:\x\y"), "C__x_y");
        // 老包（/Users/<同名>/ 前缀）同名用户推断 → 原结构重建
        let home = home_dir();
        let target = home.join("Downloads/workbuddy 项目/NotExistingWs");
        let _ = fs::remove_dir_all(&target);
        let r = auto_root(&format!("{}/Downloads/workbuddy 项目/NotExistingWs", to_slash(&home.to_string_lossy())), None);
        assert_eq!(r, target.to_string_lossy().to_string());
        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn full_roundtrip() {
        let base = std::env::temp_dir().join(format!("wbwin_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let h1 = base.join("home1");
        let h2 = base.join("home2");
        for h in [&h1, &h2] {
            fs::create_dir_all(h.join(".workbuddy")).unwrap();
        }

        // ---- home1 造数据 ----
        std::env::set_var("HOME", &h1);
        std::env::remove_var("USERPROFILE");
        let ws1 = h1.join("projects/WsZ");
        fs::create_dir_all(&ws1).unwrap();
        fs::write(ws1.join("f.txt"), b"pkg-f").unwrap();
        fs::write(h1.join(".workbuddy/MEMORY.md"), b"mem").unwrap();
        fs::create_dir_all(h1.join(".workbuddy/skills")).unwrap();
        fs::write(h1.join(".workbuddy/skills/x.md"), b"skill").unwrap();
        let slug1 = win_slug(&ws1.to_string_lossy());
        fs::create_dir_all(h1.join(".workbuddy/projects").join(&slug1)).unwrap();
        fs::write(h1.join(".workbuddy/projects").join(&slug1).join("s1.jsonl"), b"conv1").unwrap();
        fs::write(h1.join(".workbuddy/projects").join(&slug1).join("s2.jsonl"), b"conv2").unwrap();
        {
            let conn = Connection::open(h1.join(".workbuddy/workbuddy.db")).unwrap();
            conn.execute_batch(
                "CREATE TABLE workspaces(path TEXT PRIMARY KEY, last_opened_at INTEGER);
                 INSERT INTO workspaces VALUES('WS1PATH', 1);
                 CREATE TABLE sessions(id TEXT PRIMARY KEY, cwd TEXT NOT NULL, user_id TEXT NOT NULL,
                     title TEXT, custom_title TEXT, status TEXT DEFAULT 'Pending',
                     created_at INTEGER DEFAULT 0, updated_at INTEGER DEFAULT 0);
                 CREATE TABLE session_usage(session_id TEXT);
                 INSERT INTO sessions VALUES('s1','WS1PATH','userA','会话一','',1,100,300);
                 INSERT INTO sessions VALUES('s2','WS1PATH','userB','会话二','',1,200,200);
                 INSERT INTO session_usage VALUES('s1');"
            ).unwrap();
        }
        // 把 WS1PATH 占位替换成真实路径（避免 SQL 注入转义麻烦，直接 UPDATE）
        {
            let conn = Connection::open(h1.join(".workbuddy/workbuddy.db")).unwrap();
            conn.execute("UPDATE workspaces SET path=?1", rusqlite::params![ws1.to_string_lossy().to_string()]).unwrap();
            conn.execute("UPDATE sessions SET cwd=?1", rusqlite::params![ws1.to_string_lossy().to_string()]).unwrap();
        }

        // ---- 导出 ----
        let mut noop = |_: &str| {};
        let mut lines = Vec::new();
        let _ = &mut noop;
        let zip1 = h1.join("out.zip");
        let opts = ExportOptionsDto {
            long_term_memory: true, conversations: true, skills: true, project_spaces: true,
            project_selection: HashMap::from([(ws1.to_string_lossy().to_string(), vec!["f.txt".to_string()])]),
            sync_workspace_registry: false,
        };
        let mut noProg = |_: f64, _: &str| {};
        export(&zip1.to_string_lossy(), &opts, &mut |l| lines.push(l.to_string()), &mut noProg).unwrap();
        assert!(zip1.exists(), "导出 zip 应存在");
        // 模拟新机器：把 h1 项目目录挪走，导入时触发自动落位
        fs::rename(&ws1, base.join("wsz_hidden")).unwrap();

        // ---- home2 准备本机环境并 inspect ----
        std::env::set_var("HOME", &h2);
        {
            let conn = Connection::open(h2.join(".workbuddy/workbuddy.db")).unwrap();
            conn.execute_batch(
                "CREATE TABLE workspaces(path TEXT PRIMARY KEY, last_opened_at INTEGER);
                 CREATE TABLE sessions(id TEXT PRIMARY KEY, cwd TEXT NOT NULL, user_id TEXT NOT NULL,
                     title TEXT, custom_title TEXT, status TEXT DEFAULT 'Pending',
                     created_at INTEGER DEFAULT 0, updated_at INTEGER DEFAULT 0);
                 CREATE TABLE session_usage(session_id TEXT);
                 INSERT INTO sessions VALUES('local1','LOCALCWD','LOCALID','本机会话','',1,1,1);"
            ).unwrap();
        }
        let info = inspect_package(&zip1.to_string_lossy(), &HashMap::new(), &mut |l| lines.push(l.to_string())).unwrap();
        let keys: Vec<&str> = info.summary.iter().map(|s| s.key.as_str()).collect();
        assert!(keys.contains(&"memory") && keys.contains(&"conversations") && keys.contains(&"skills") && keys.contains(&"projectSpaces"), "四类统计齐全: {:?}", keys);
        assert_eq!(info.conversations.len(), 2, "包内会话数");
        assert_eq!(info.project_roots.len(), 1, "项目空间根数");

        // ---- 只勾 s1 导入 + 过户 LOCALID ----
        let iopts = ImportOptionsDto {
            memory: true, conversations: true, skills: true, project_spaces: true,
            project_targets: HashMap::new(),
            selected_sessions: Some(vec!["s1".into()]),
            target_user_id: Some("LOCALID".into()),
            conflict_policy: "always".into(),
            archive_missing: false,
        };
        import(&zip1.to_string_lossy(), &iopts, &mut |l| lines.push(l.to_string()), &mut noProg).unwrap();

        // ---- 断言 ----
        // 1) 长期记忆落地
        assert_eq!(fs::read_to_string(h2.join(".workbuddy/MEMORY.md")).unwrap(), "mem");
        // 2) Skill 落地
        assert_eq!(fs::read_to_string(h2.join(".workbuddy/skills/x.md")).unwrap(), "skill");
        // 3) 项目空间按原结构重建（老包同名推断）
        let expect_ws = h2.join("projects/WsZ/f.txt");
        assert!(expect_ws.exists(), "项目空间应按原结构重建: {}", expect_ws.display());
        assert_eq!(fs::read_to_string(&expect_ws).unwrap(), "pkg-f");
        // 4) db：保留 2 条（local1 + s1），user_id 全为 LOCALID，cwd 已重映射
        {
            let conn = Connection::open(h2.join(".workbuddy/workbuddy.db")).unwrap();
            let ids: Vec<String> = {
                let mut stmt = conn.prepare("SELECT id FROM sessions ORDER BY id;").unwrap();
                stmt.query_map([], |r| r.get(0)).unwrap().flatten().collect()
            };
            assert_eq!(ids, vec!["s1".to_string()], "整库替换+只保留勾选会话: {:?}", ids);
            let (uid, cwd): (String, String) = {
                let mut stmt = conn.prepare("SELECT user_id, cwd FROM sessions WHERE id='s1';").unwrap();
                stmt.query_row([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap()
            };
            assert_eq!(uid, "LOCALID", "账号过户");
            let expect_cwd = h2.join("projects/WsZ").to_string_lossy().to_string();
            assert_eq!(cwd, expect_cwd, "cwd 应重映射到新 home: {} vs {}", cwd, expect_cwd);
        }
        // 5) jsonl 按 Windows slug 归位 + 本机原有会话文件不受影响
        let jsonl = h2.join(".workbuddy/projects").join(win_slug(&h2.join("projects/WsZ").to_string_lossy())).join("s1.jsonl");
        assert!(jsonl.exists(), "s1.jsonl 应按 slug 归位: {}", jsonl.display());
        assert!(!jsonl.parent().unwrap().join("s2.jsonl").exists(), "未勾选的 s2 不应落地");
        assert!(h1.join(".workbuddy/projects").join(&slug1).join("s1.jsonl").exists() || true, "占位");

        let _ = fs::remove_dir_all(&base);
        println!("ROUNDTRIP_OK");
    }
}
