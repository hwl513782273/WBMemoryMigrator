#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod engine;

use serde::{Deserialize, Serialize};
use tauri::Emitter;

#[derive(Serialize, Clone)]
struct ProgressEv { phase: String, progress: f64 }

#[derive(Serialize, Clone)]
struct LogEv { line: String }

fn emit_log(app: &tauri::AppHandle) -> impl FnMut(&str) + '_ {
    move |line: &str| { let _ = app.emit("job-log", LogEv { line: line.to_string() }); }
}

#[tauri::command]
fn list_project_options() -> Vec<engine::WsOption> {
    let mut noop = |_: &str| {};
    engine::project_options_fast(&mut noop)
}

#[tauri::command]
fn entry_size(path: String) -> u64 {
    engine::dir_size(std::path::Path::new(&path))
}

#[tauri::command]
fn collect_source_paths(options: engine::ExportOptionsDto) -> Vec<String> {
    let mut noop = |_: &str| {};
    engine::collect_source_paths(&options, &mut noop)
}

#[tauri::command]
fn local_user_id() -> Option<String> { engine::local_user_id() }

#[tauri::command]
fn local_session_count() -> i64 { engine::local_session_count() }

#[tauri::command]
fn custom_scan_roots() -> Vec<String> { engine::custom_scan_roots() }

#[tauri::command]
fn add_scan_root(path: String) { engine::add_scan_root(&path); }

#[tauri::command]
fn remove_scan_root(path: String) { engine::remove_scan_root(&path); }

#[tauri::command]
fn pick_folder(title: String) -> Option<String> {
    rfd::FileDialog::new().set_title(&title).pick_folder()
        .map(|p| p.to_string_lossy().to_string())
}

#[tauri::command]
fn pick_save_zip(title: String, file_name: String) -> Option<String> {
    rfd::FileDialog::new().set_title(&title).set_file_name(&file_name)
        .add_filter("备份包 (zip)", &["zip"]).save_file()
        .map(|p| p.to_string_lossy().to_string())
}

#[tauri::command]
fn pick_open_zip(title: String) -> Option<String> {
    rfd::FileDialog::new().set_title(&title)
        .add_filter("备份包 (zip)", &["zip"]).pick_file()
        .map(|p| p.to_string_lossy().to_string())
}

#[tauri::command]
fn export_backup(app: tauri::AppHandle, save_path: String, options: engine::ExportOptionsDto) -> Result<(), String> {
    engine::export(&save_path, &options, &mut emit_log(&app), &mut |p, phase| {
        let _ = app.emit("job-progress", ProgressEv { phase: phase.to_string(), progress: p });
    })
}

#[tauri::command]
fn inspect_package(zip_path: String, project_targets: Option<std::collections::HashMap<String, String>>) -> Result<engine::PackageInfo, String> {
    let empty = std::collections::HashMap::new();
    let targets = project_targets.unwrap_or(empty);
    let mut noop = |_: &str| {};
    engine::inspect_package(&zip_path, &targets, &mut noop)
}

#[tauri::command]
fn import_backup(app: tauri::AppHandle, zip_path: String, options: engine::ImportOptionsDto) -> Result<(), String> {
    engine::import(&zip_path, &options, &mut emit_log(&app), &mut |p, phase| {
        let _ = app.emit("job-progress", ProgressEv { phase: phase.to_string(), progress: p });
    })
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            list_project_options, entry_size, collect_source_paths, local_user_id, local_session_count,
            custom_scan_roots, add_scan_root, remove_scan_root,
            pick_folder, pick_save_zip, pick_open_zip,
            export_backup, inspect_package, import_backup
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
