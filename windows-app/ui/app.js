// WBMemoryMigrator Windows 版前端逻辑
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (id) => document.getElementById(id);
const fmt = (b) => {
  const kb = b / 1024;
  if (kb < 1024) return kb.toFixed(0) + " KB";
  const mb = kb / 1024;
  if (mb < 1024) return mb.toFixed(1) + " MB";
  return (mb / 1024).toFixed(2) + " GB";
};
const baseName = (p) => p.split(/[\\/]/).filter(Boolean).pop() || p;

function addLog(line) {
  const el = $("log");
  el.textContent += line + "\n";
  el.scrollTop = el.scrollHeight;
}

function setProgress(p, phase) {
  $("progressWrap").classList.add("show");
  $("progressBar").style.width = Math.round(p * 100) + "%";
  $("phaseText").textContent = phase + " " + Math.round(p * 100) + "%";
}
function hideProgress() { $("progressWrap").classList.remove("show"); }

let wsOptions = [];          // 工作区条目
let wsChecked = {};          // path -> bool
let busy = false;
let importZip = null;
let packageInfo = null;      // inspect 结果
let selectedConvs = new Set();
let importTargets = {};      // workspaceRoot -> 本机目标目录
let detectedUid = null;
let localCount = 0;

// MARK: 导出侧

async function loadWsOptions() {
  $("projectHint").textContent = "正在扫描工作区…";
  wsOptions = await invoke("list_project_options");
  for (const o of wsOptions) if (wsChecked[o.path] === undefined) wsChecked[o.path] = !o.excludedByDefault;
  $("projectHint").textContent = wsOptions.length
    ? `共 ${new Set(wsOptions.map(o => o.workspace)).size} 个工作区、${wsOptions.length} 个条目（大小后台计算中）`
    : "未找到任何工作区（检查 %USERPROFILE%\\.workbuddy\\workbuddy.db 的 workspaces 表）";
  renderWsList();
  // 大小懒加载回填
  for (const o of wsOptions) {
    invoke("entry_size", { path: o.path }).then(sz => {
      o.size = sz;
      const span = document.querySelector(`[data-size="${CSS.escape(o.path)}"]`);
      if (span) span.textContent = "(" + fmt(sz) + ")";
      const wspan = document.querySelector(`[data-wsize="${CSS.escape(o.workspace)}"]`);
      if (wspan) {
        let total = 0, done = true;
        for (const x of wsOptions.filter(v => v.workspace === o.workspace)) {
          if (x.size === 0) done = false; else if (!x.excludedByDefault) total += x.size;
        }
        wspan.textContent = done ? "(" + fmt(total) + ")" : "(…)";
      }
    }).catch(() => {});
  }
}

function renderWsList() {
  const list = $("wsList");
  list.innerHTML = "";
  const showFull = $("modeFull").checked;
  const groups = {};
  for (const o of wsOptions) (groups[o.workspace] = groups[o.workspace] || []).push(o);
  for (const [ws, entries] of Object.entries(groups)) {
    const group = document.createElement("div");
    group.className = "ws-group";
    const total = entries.filter(e => !e.excludedByDefault).reduce((a, e) => a + e.size, 0);
    const wsDone = entries.every(e => e.size > 0) || entries.length === 0;
    const head = document.createElement("div");
    head.className = "ws-head";
    const badge = entries.some(e => e.registeredRoot) ? ' <span class="badge">已迁移</span>' : "";
    head.innerHTML = `<input type="checkbox" class="checkbox" ${wsChecked[ws] ? "checked" : ""}>
      📁 ${baseName(ws)}${badge} <span class="size" data-wsize="${ws.replace(/"/g, "&quot;")}">${wsDone ? "(" + fmt(total) + ")" : "(…)"}</span>
      <span class="hint">${ws}</span>`;
    head.querySelector("input").addEventListener("change", (ev) => {
      wsChecked[ws] = ev.target.checked;
      if (showFull) for (const e of entries) if (!e.excludedByDefault) wsChecked[e.path] = ev.target.checked;
      renderWsList();
    });
    group.appendChild(head);
    if (showFull) {
      for (const e of entries) {
        const row = document.createElement("div");
        row.className = "entry";
        const dim = e.excludedByDefault ? ' style="opacity:.55"' : "";
        row.innerHTML = `<span${dim}>${e.isDir ? "📂" : "📄"} ${e.name}</span>
          <span class="size" data-size="${e.path.replace(/"/g, "&quot;")}">(${e.size > 0 ? fmt(e.size) : "…"})</span>
          ${e.excludedByDefault ? '<span class="hint">默认排除</span>' : ""}`;
        const cb = document.createElement("input");
        cb.type = "checkbox"; cb.className = "checkbox"; cb.checked = !!wsChecked[e.path];
        cb.addEventListener("change", (ev) => { wsChecked[e.path] = ev.target.checked; });
        row.prepend(cb);
        group.appendChild(row);
      }
    }
    list.appendChild(group);
  }
}

$("modeWsOnly").addEventListener("change", renderWsList);
$("modeFull").addEventListener("change", renderWsList);
$("btnSelAllWs").addEventListener("click", () => {
  for (const o of wsOptions) { wsChecked[o.path] = true; wsChecked[o.workspace] = true; }
  renderWsList();
});
$("btnDeselAllWs").addEventListener("click", () => {
  for (const o of wsOptions) { wsChecked[o.path] = false; wsChecked[o.workspace] = false; }
  renderWsList();
});

// 扫描设置
$("btnScanSettings").addEventListener("click", async () => {
  const el = $("scanSettings");
  el.classList.toggle("hidden");
  if (!el.classList.contains("hidden")) await renderScanRoots();
});
async function renderScanRoots() {
  const roots = await invoke("custom_scan_roots");
  const list = $("scanRootList");
  list.innerHTML = "";
  for (const r of roots) {
    const row = document.createElement("div");
    row.className = "row";
    row.innerHTML = `<span class="hint">${r}</span><span class="spacer"></span>`;
    const btn = document.createElement("button");
    btn.className = "btn small"; btn.textContent = "移除";
    btn.addEventListener("click", async () => { await invoke("remove_scan_root", { path: r }); renderScanRoots(); loadWsOptions(); });
    row.appendChild(btn);
    list.appendChild(row);
  }
}
$("btnAddScanRoot").addEventListener("click", async () => {
  const p = await invoke("pick_folder", { title: "选择要纳入扫描的文件夹" });
  if (p) { await invoke("add_scan_root", { path: p }); addLog("已添加扫描路径: " + p); renderScanRoots(); loadWsOptions(); }
});

// 导出类别大小（懒统计）
async function refreshCategorySizes() {
  const tasks = [
    ["optMemory", "sizeMemory", { longTermMemory: true, conversations: false, skills: false, projectSpaces: false, projectSelection: {}, syncWorkspaceRegistry: false }],
    ["optConversations", "sizeConversations", { longTermMemory: false, conversations: true, skills: false, projectSpaces: false, projectSelection: {}, syncWorkspaceRegistry: false }],
    ["optSkills", "sizeSkills", { longTermMemory: false, conversations: false, skills: true, projectSpaces: false, projectSelection: {}, syncWorkspaceRegistry: false }],
  ];
  for (const [cbId, sizeId, opts] of tasks) {
    if (!$(cbId).checked) { $(sizeId).textContent = ""; continue; }
    $(sizeId).textContent = "(统计中…)";
    const paths = await invoke("collect_source_paths", { options: opts }).catch(() => []);
    let total = 0;
    for (const p of paths) total += await invoke("entry_size", { path: p }).catch(() => 0);
    $(sizeId).textContent = "(" + fmt(total) + ")";
  }
  const ps = $("optProjectSpaces").checked;
  $("sizeProjects").textContent = ps ? "" : "";
}
["optMemory", "optConversations", "optSkills"].forEach(id =>
  $(id).addEventListener("change", refreshCategorySizes));
$("optProjectSpaces").addEventListener("change", () => {
  $("projectPanel").style.opacity = $("optProjectSpaces").checked ? "1" : ".6";
});

$("btnExport").addEventListener("click", async () => {
  if (busy) return;
  const selection = {};
  for (const o of wsOptions) {
    if (wsChecked[o.path] && !o.excludedByDefault) {
      (selection[o.workspace] = selection[o.workspace] || []).push(o.name);
    }
  }
  const save = await invoke("pick_save_zip", { title: "保存备份包", fileName: "WorkBuddy记忆备份.zip" });
  if (!save) return;
  busy = true; setProgress(0, "准备中…");
  addLog("开始导出…");
  try {
    await invoke("export_backup", { savePath: save, options: {
      longTermMemory: $("optMemory").checked,
      conversations: $("optConversations").checked,
      skills: $("optSkills").checked,
      projectSpaces: $("optProjectSpaces").checked,
      projectSelection: selection,
      syncWorkspaceRegistry: true,
    }});
    addLog("✅ 导出完成: " + save);
  } catch (e) { addLog("❌ 导出失败: " + e); }
  busy = false; hideProgress();
});

// MARK: 导入侧

$("btnChooseZip").addEventListener("click", async () => {
  if (busy) return;
  const zip = await invoke("pick_open_zip", { title: "选择备份包" });
  if (!zip) return;
  busy = true; setProgress(0.02, "正在读取备份包…");
  addLog("读取备份包: " + zip);
  try {
    packageInfo = await invoke("inspect_package", { zipPath: zip, projectTargets: {} });
    importZip = zip;
    selectedConvs = new Set(packageInfo.conversations.map(c => c.id));
    importTargets = {};
    detectedUid = await invoke("local_user_id");
    localCount = await invoke("local_session_count");
    renderImportUI();
    $("importArea").classList.remove("hidden");
    $("importArea").scrollIntoView({ behavior: "smooth" });
  } catch (e) { addLog("❌ 读取失败: " + e); }
  busy = false; hideProgress();
});

function renderImportUI() {
  const info = packageInfo;
  const sum = Object.fromEntries(info.summary.map(s => [s.key, s]));
  const setup = (key, rowId, cbId, sizeId, label) => {
    const has = !!sum[key];
    $(rowId).classList.toggle("locked", !has);
    $(sizeId).textContent = has ? `（${sum[key].count} 项 · ${fmt(sum[key].size)}）` : "（本包未含）";
    $(cbId).checked = has;
  };
  setup("memory", "rowIMemory", "iOptMemory", "iSizeMemory");
  setup("conversations", "rowIConversations", "iOptConversations", "iSizeConversations");
  setup("skills", "rowISkills", "iOptSkills", "iSizeSkills");
  setup("projectSpaces", "rowIProjects", "iOptProjects", "iSizeProjects");

  // 对话列表
  const convList = $("convList");
  convList.innerHTML = "";
  $("convCard").classList.toggle("hidden", info.conversations.length === 0);
  $("convHint").textContent = `包内共 ${info.conversations.length} 条会话，已默认全选（${selectedConvs.size} 条）`;
  for (const c of info.conversations) {
    const row = document.createElement("div");
    row.className = "conv";
    const d = c.updatedAt > 0 ? new Date(c.updatedAt * 1000).toLocaleString("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }) : "";
    row.innerHTML = `<span>${c.title}</span>
      <span class="meta">· ${c.cwd ? baseName(c.cwd) : "（无工作目录）"}</span>
      <span class="spacer"></span><span class="meta">${d}</span>`;
    const cb = document.createElement("input");
    cb.type = "checkbox"; cb.className = "checkbox"; cb.checked = selectedConvs.has(c.id);
    cb.addEventListener("change", (ev) => {
      ev.target.checked ? selectedConvs.add(c.id) : selectedConvs.delete(c.id);
      $("convHint").textContent = `包内共 ${info.conversations.length} 条会话，已勾选 ${selectedConvs.size} 条`;
      refreshPreview();
    });
    row.prepend(cb);
    convList.appendChild(row);
  }
  $("takeoverLine").textContent = detectedUid
    ? `账号过户：恢复的会话将归属当前账号 ${detectedUid.slice(0, 8)}…`
    : "未探测到本机账号 id";
  $("manualUidRow").classList.toggle("hidden", !!detectedUid);

  // 项目空间目标目录
  const tl = $("targetList");
  tl.innerHTML = "";
  $("targetCard").classList.toggle("hidden", info.projectRoots.length === 0);
  for (const root of info.projectRoots) {
    const row = document.createElement("div");
    row.className = "row";
    row.style.margin = "4px 0";
    row.innerHTML = `<span style="font-size:12px">${baseName(root)}</span><span class="hint">${root}</span><span class="spacer"></span>`;
    const status = document.createElement("span");
    status.className = "hint";
    status.textContent = importTargets[root] ? "→ " + importTargets[root] : "（未选→按原目录结构自动创建）";
    const btn = document.createElement("button");
    btn.className = "btn small"; btn.textContent = "选择目录…";
    btn.addEventListener("click", async () => {
      const p = await invoke("pick_folder", { title: "选择导入目标目录（其下将创建 " + baseName(root) + "）" });
      if (p) {
        importTargets[root] = p + (p.endsWith("\\") || p.endsWith("/") ? "" : "\\") + baseName(root);
        status.textContent = "→ " + importTargets[root];
        await refreshPreview();
      }
    });
    row.append(status, btn);
    tl.appendChild(row);
  }
  refreshPreview();
}

async function refreshPreview() {
  if (!importZip) return;
  const targets = Object.fromEntries(Object.entries(importTargets).filter(([k]) => packageInfo.projectRoots.includes(k)));
  try {
    packageInfo = await invoke("inspect_package", { zipPath: importZip, projectTargets: targets });
  } catch (e) { addLog("预览刷新失败: " + e); return; }
  $("previewList").textContent = packageInfo.previewLines.join("\n");
  $("previewCount").textContent = packageInfo.previewLines.length;
}

["iOptMemory", "iOptConversations", "iOptSkills", "iOptProjects"].forEach(id =>
  $(id).addEventListener("change", refreshPreview));
$("btnSelAllConv").addEventListener("click", () => {
  selectedConvs = new Set(packageInfo.conversations.map(c => c.id));
  renderImportUI();
});
$("btnDeselAllConv").addEventListener("click", () => {
  selectedConvs = new Set();
  renderImportUI();
});

$("btnConfirmImport").addEventListener("click", async () => {
  if (busy || !importZip) return;
  // 高危操作警示：导入对话将整库覆盖本机对话库
  if ($("iOptConversations").checked) {
    const convSum = packageInfo.summary.find(s => s.key === "conversations");
    if (convSum) {
      const picked = selectedConvs.size;
      const msg = picked === 0
        ? `⚠️ 未勾选任何对话，本机现有 ${localCount} 条会话导入后将全部消失（原对话库会自动备份到 migrate_backups）。确定继续吗？`
        : `本机现有 ${localCount} 条会话将被替换为包内已勾选的 ${picked} 条（原对话库自动备份到 migrate_backups）。确定继续吗？`;
      if (!confirm(msg)) { addLog("已取消导入（对话库覆盖警示）。"); return; }
    }
  }
  busy = true; setProgress(0, "准备中…");
  addLog("开始导入…");
  try {
    await invoke("import_backup", { zipPath: importZip, options: {
      memory: $("iOptMemory").checked,
      conversations: $("iOptConversations").checked,
      skills: $("iOptSkills").checked,
      projectSpaces: $("iOptProjects").checked,
      projectTargets: Object.fromEntries(Object.entries(importTargets).filter(([k]) => packageInfo.projectRoots.includes(k))),
      selectedSessions: [...selectedConvs],
      targetUserId: ($("manualUid").value || "").trim() || null,
      conflictPolicy: document.querySelector('input[name="cpolicy"]:checked').value,
      archiveMissing: $("iArchiveMissing").checked,
    }});
    addLog("✅ 导入完成");
    alert("导入完成！重启 WorkBuddy 后生效。");
  } catch (e) { addLog("❌ 导入失败: " + e); }
  busy = false; hideProgress();
});

// 进度与日志事件
listen("job-progress", (ev) => setProgress(ev.payload.progress, ev.payload.phase));
listen("job-log", (ev) => addLog(ev.payload.line));

// 启动
loadWsOptions();
refreshCategorySizes();
