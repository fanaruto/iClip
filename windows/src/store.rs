use crate::archive::{export_pinned_archive_data, ArchiveBackupError, ArchiveImportSummary};
use crate::engines::is_otp_message;
use crate::hotkey::{WinHotKeyShortcut, WinSingleModifier};
use crate::intelligence::{
    extract_checklist_items, extract_suggestion_payload, parse_quick_capture, QuickCaptureIntent,
};
use crate::model::{
    contains_case_insensitive, now_unix_secs, sha256_hex, ClipContentType, ClipFilterTab, ClipItem,
    PinCategory, QuickAction,
};
use crate::security::{load_or_create_vault_key, open_vault_bytes, seal_vault_bytes};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};

/// 面板液态玻璃外观档位（对齐 macOS LiquidGlassAppearance）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GlassAppearance {
    Clear,
    Tinted,
    Solid,
}

impl Default for GlassAppearance {
    fn default() -> Self {
        Self::Tinted
    }
}

impl GlassAppearance {
    pub const ALL: [GlassAppearance; 3] = [Self::Clear, Self::Tinted, Self::Solid];

    pub fn title(self) -> &'static str {
        match self {
            Self::Clear => "清澈透光",
            Self::Tinted => "深邃柔焦",
            Self::Solid => "实色护眼",
        }
    }

    pub fn next(self) -> Self {
        match self {
            Self::Clear => Self::Tinted,
            Self::Tinted => Self::Solid,
            Self::Solid => Self::Clear,
        }
    }
}

fn default_true() -> bool {
    true
}
fn default_max_history() -> usize {
    200
}
fn default_blur_pct() -> u8 {
    38
}
fn default_toggle_hotkey() -> WinHotKeyShortcut {
    WinHotKeyShortcut::default_toggle()
}
fn default_queue_hotkey() -> WinHotKeyShortcut {
    WinHotKeyShortcut::default_queue_pop()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreConfig {
    #[serde(default)]
    pub minimal_mode_enabled: bool,
    #[serde(default)]
    pub always_on_top: bool,
    #[serde(default)]
    pub pinned_panel_pos: Option<(i32, i32)>,
    #[serde(default = "default_toggle_hotkey")]
    pub hotkey_toggle: WinHotKeyShortcut,
    #[serde(default = "default_queue_hotkey")]
    pub hotkey_queue_pop: WinHotKeyShortcut,
    #[serde(default = "default_true")]
    pub copy_append_enabled: bool,
    #[serde(default = "default_true")]
    pub double_copy_spark_enabled: bool,
    #[serde(default)]
    pub auto_strip_rich_formatting: bool,
    #[serde(default)]
    pub auto_clean_tracking_url: bool,
    #[serde(default = "default_true")]
    pub auto_paste_enabled: bool,
    #[serde(default = "default_true")]
    pub auto_expire_otp: bool,
    #[serde(default = "default_true")]
    pub screen_share_privacy: bool,
    #[serde(default = "default_true")]
    pub mask_sensitive_previews: bool,
    #[serde(default = "default_true")]
    pub auto_clear_concealed_clipboard: bool,
    #[serde(default = "default_true")]
    pub auto_expire_unpinned_secrets: bool,
    #[serde(default)]
    pub auto_strip_zero_width: bool,
    #[serde(default)]
    pub ignored_apps: Vec<String>,
    #[serde(default)]
    pub queue_auto_tab: bool,
    #[serde(default)]
    pub glass_appearance: GlassAppearance,
    #[serde(default = "default_blur_pct")]
    pub blur_concentration_pct: u8,
    #[serde(default = "default_max_history")]
    pub max_history_count: usize,
    #[serde(default)]
    pub has_seen_highlights_v27: bool,
}

pub const CORE_HIGHLIGHTS_V27: [(&str, &str); 4] = [
    (
        "唤醒零失焦直贴",
        "在搜索框或弹层内呼出不丢原焦点，按 Enter 瞬间顺手键入当前位置。",
    ),
    (
        "零信任隐私护盾",
        "全库硬件加密与投屏自动隐身，密钥默认圆点遮罩，Shift+Enter 一键 AI 替身脱敏。",
    ),
    (
        "剪贴即待办与净文",
        "Ctrl+T 一键转待办；AI 回复一键褪去 Markdown 符号，表格直粘 Excel 分列。",
    ),
    (
        "自由流转与极简开关",
        "Tab 秒切分类，方向键二维选图，按 Ctrl+E 随时切回极简纯净模式。",
    ),
];

impl Default for StoreConfig {
    fn default() -> Self {
        Self {
            minimal_mode_enabled: false,
            always_on_top: false,
            pinned_panel_pos: None,
            hotkey_toggle: default_toggle_hotkey(),
            hotkey_queue_pop: default_queue_hotkey(),
            copy_append_enabled: true,
            double_copy_spark_enabled: true,
            auto_strip_rich_formatting: false,
            auto_clean_tracking_url: false,
            auto_paste_enabled: true,
            auto_expire_otp: true,
            screen_share_privacy: true,
            mask_sensitive_previews: true,
            auto_clear_concealed_clipboard: true,
            auto_expire_unpinned_secrets: true,
            auto_strip_zero_width: false,
            ignored_apps: vec![
                "1Password".to_string(),
                "Bitwarden".to_string(),
                "KeePassXC".to_string(),
            ],
            queue_auto_tab: false,
            glass_appearance: GlassAppearance::Tinted,
            blur_concentration_pct: 38,
            max_history_count: 200,
            has_seen_highlights_v27: false,
        }
    }
}

/// 自适应行为习惯记忆（轻量本地 JSON，越用越顺手）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdaptiveMemory {
    #[serde(default)]
    pub reuse_counts: HashMap<String, u32>,
    #[serde(default)]
    pub app_affinity: HashMap<String, HashMap<String, u32>>,
    #[serde(default)]
    pub action_habits: HashMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserSuggestionRecord {
    pub created_unix_secs: u64,
    pub suggestion: String,
    pub applied_summary: String,
}

#[derive(Clone)]
struct UndoSnapshot {
    deleted_at_secs: u64,
    entries: Vec<(ClipItem, Option<Vec<u8>>)>,
}

/// 跨平台零冗余剪贴板核心仓库（支持双模备份自愈、FIFO 队列、自适应排序、8 秒撤销与 OTP 阅后即焚）
pub struct ClipboardStore {
    pub items: Vec<ClipItem>,
    pub config: StoreConfig,
    pub memory: AdaptiveMemory,
    pub is_paused: bool,
    pub pause_until_unix_secs: Option<u64>,
    pub queue_mode_active: bool,
    pub paste_queue_ids: VecDeque<String>,
    pub pending_otp_expirations: Vec<(String, u64)>,
    pub data_dir: PathBuf,
    pub images_dir: PathBuf,
    history_file: PathBuf,
    history_backup_file: PathBuf,
    config_file: PathBuf,
    memory_file: PathBuf,
    suggestions_file: PathBuf,
    vault_key: [u8; 32],
    undo_stack: Vec<UndoSnapshot>,
}

impl ClipboardStore {
    pub fn new(data_dir: PathBuf) -> Self {
        let images_dir = data_dir.join("images");
        let history_file = data_dir.join("history.json");
        let history_backup_file = data_dir.join("history.backup.json");
        let config_file = data_dir.join("config.json");
        let memory_file = data_dir.join("adaptive_intelligence.json");
        let suggestions_file = data_dir.join("user_suggestions.json");
        let _ = fs::create_dir_all(&images_dir);

        let vault_key = load_or_create_vault_key(&data_dir);
        let mut legacy_migrated = false;
        let mut legacy_memory_migrated = false;

        let config = fs::read(&config_file)
            .ok()
            .and_then(|b| serde_json::from_slice::<StoreConfig>(&b).ok())
            .unwrap_or_default();

        let memory = fs::read(&memory_file)
            .ok()
            .and_then(|raw| {
                let (plain, was_legacy) = open_vault_bytes(&raw, &vault_key)?;
                let parsed = serde_json::from_slice::<AdaptiveMemory>(&plain).ok()?;
                if was_legacy {
                    legacy_memory_migrated = true;
                }
                Some(parsed)
            })
            .unwrap_or_default();

        // 若存量建议单为旧明文，启动时无感升级为认证密文
        if let Ok(sug_raw) = fs::read(&suggestions_file) {
            if let Some((plain, true)) = open_vault_bytes(&sug_raw, &vault_key) {
                let sealed_sug = seal_vault_bytes(&plain, &vault_key, &data_dir);
                Self::atomic_write(&suggestions_file, &sealed_sug);
            }
        }

        // 零信任双模自愈读取：支持 DPAPI 认证密文与历史明文自动升级，主文件篡改/截断时自动从加密备份恢复
        let primary_items = fs::read(&history_file).ok().and_then(|raw| {
            let (plain, was_legacy) = open_vault_bytes(&raw, &vault_key)?;
            let parsed = serde_json::from_slice::<Vec<ClipItem>>(&plain).ok()?;
            if was_legacy {
                legacy_migrated = true;
            }
            Some(parsed)
        });

        let (mut items, healed_from_backup) = match primary_items {
            Some(list) if !list.is_empty() || !history_backup_file.exists() => (list, false),
            _ => {
                let backup = fs::read(&history_backup_file).ok().and_then(|raw| {
                    let (plain, _) = open_vault_bytes(&raw, &vault_key)?;
                    serde_json::from_slice::<Vec<ClipItem>>(&plain).ok()
                });
                match backup {
                    Some(b_list) if !b_list.is_empty() => (b_list, true),
                    _ => (primary_items.unwrap_or_default(), false),
                }
            }
        };
        Self::sort_items(&mut items);

        let mut store = Self {
            items,
            config,
            memory,
            is_paused: false,
            pause_until_unix_secs: None,
            queue_mode_active: false,
            paste_queue_ids: VecDeque::new(),
            pending_otp_expirations: Vec::new(),
            data_dir,
            images_dir,
            history_file,
            history_backup_file,
            config_file,
            memory_file,
            suggestions_file,
            vault_key,
            undo_stack: Vec::new(),
        };

        if legacy_memory_migrated {
            store.save_memory();
        }
        let _ = crate::security::upgrade_plain_images_in_dir(&store.images_dir, &store.vault_key);
        let now_init = now_unix_secs();
        let archived = store.archive_expired_completed_todos(now_init);
        let purged_sec = store.purge_expired_unpinned_secrets(now_init, 86_400);
        store.sweep_orphaned_image_files_with_min_age(60);
        if (healed_from_backup || legacy_migrated) && archived == 0 && purged_sec == 0 {
            store.save_history();
        }
        store
    }

    pub fn sweep_orphaned_image_files(&self) {
        self.sweep_orphaned_image_files_with_min_age(0);
    }

    pub fn sweep_orphaned_image_files_with_min_age(&self, min_age_secs: u64) {
        if min_age_secs > 0 && !self.history_file.exists() {
            return;
        }
        let referenced: std::collections::HashSet<&str> = self
            .items
            .iter()
            .filter_map(|i| i.image_file_name.as_deref())
            .collect();
        let now = std::time::SystemTime::now();
        if let Ok(entries) = fs::read_dir(&self.images_dir) {
            for entry in entries.flatten() {
                if let Some(name) = entry.file_name().to_str() {
                    if !name.starts_with('.') && !referenced.contains(name) {
                        if min_age_secs > 0 {
                            if let Ok(meta) = entry.metadata() {
                                if let Ok(mtime) = meta.modified() {
                                    if let Ok(age) = now.duration_since(mtime) {
                                        if age.as_secs() < min_age_secs {
                                            continue;
                                        }
                                    }
                                }
                            }
                        }
                        let _ = fs::remove_file(entry.path());
                    }
                }
            }
        }
    }

    pub fn write_image_bytes(&self, file_name: &str, plain_png: &[u8]) -> std::io::Result<()> {
        crate::security::write_encrypted_image_to_dir(&self.images_dir, file_name, plain_png)
    }

    pub fn read_image_bytes(&self, file_name: &str) -> Option<Vec<u8>> {
        crate::security::read_decrypted_image_from_dir(&self.images_dir, file_name)
    }

    pub fn default_app_data_dir() -> PathBuf {
        if let Ok(appdata) = std::env::var("APPDATA") {
            PathBuf::from(appdata).join("iClip")
        } else if let Ok(home) = std::env::var("HOME") {
            PathBuf::from(home).join(".iclip-win")
        } else {
            PathBuf::from(".iclip-win")
        }
    }

    pub fn edition_key() -> &'static str {
        if cfg!(feature = "flow") {
            "flow"
        } else {
            "dev"
        }
    }

    pub fn edition_title() -> &'static str {
        if cfg!(feature = "flow") {
            "商务与心流办公版"
        } else {
            "极客开发与 AI 版"
        }
    }

    pub fn save_config(&self) {
        if let Ok(bytes) = serde_json::to_vec_pretty(&self.config) {
            Self::atomic_write(&self.config_file, &bytes);
        }
    }

    pub fn save_memory(&self) {
        if let Ok(plain_bytes) = serde_json::to_vec(&self.memory) {
            let sealed = seal_vault_bytes(&plain_bytes, &self.vault_key, &self.data_dir);
            Self::atomic_write(&self.memory_file, &sealed);
        }
    }

    /// 定时无痕隐私护盾：开启指定分钟数的无痕暂停（`None` 表示持续暂停），到期自动恢复记录
    pub fn pause_for_minutes(&mut self, minutes: Option<u64>, now_secs: u64) {
        self.is_paused = true;
        self.pause_until_unix_secs = minutes.map(|m| now_secs.saturating_add(m.clamp(1, 480) * 60));
    }

    pub fn resume_capture(&mut self) {
        self.is_paused = false;
        self.pause_until_unix_secs = None;
    }

    pub fn toggle_timed_pause(&mut self, default_minutes: u64, now_secs: u64) -> bool {
        if self.is_paused {
            self.resume_capture();
            false
        } else {
            self.pause_for_minutes(Some(default_minutes), now_secs);
            true
        }
    }

    /// 检查定时无痕暂停是否已到期；若到期则自动恢复并返回 `true`
    pub fn check_auto_resume_pause(&mut self, now_secs: u64) -> bool {
        if self.is_paused {
            if let Some(deadline) = self.pause_until_unix_secs {
                if now_secs >= deadline {
                    self.resume_capture();
                    return true;
                }
            }
        }
        false
    }

    /// 物理级不可追溯遗忘：当记录被销毁时连根抹除 `AdaptiveMemory` 中的 SHA-256 哈希指纹
    pub fn forget_memory_hashes(&mut self, hashes: &[String]) {
        if hashes.is_empty() {
            return;
        }
        let mut changed = false;
        for h in hashes {
            if self.memory.reuse_counts.remove(h).is_some() {
                changed = true;
            }
            if self.memory.app_affinity.remove(h).is_some() {
                changed = true;
            }
        }
        self.memory.app_affinity.retain(|_, bucket| {
            for h in hashes {
                if bucket.remove(h).is_some() {
                    changed = true;
                }
            }
            !bucket.is_empty()
        });
        if changed {
            self.save_memory();
        }
    }

    pub fn save_history(&self) {
        if let Ok(plain_bytes) = serde_json::to_vec(&self.items) {
            let sealed = seal_vault_bytes(&plain_bytes, &self.vault_key, &self.data_dir);
            Self::atomic_write(&self.history_file, &sealed);
            Self::atomic_write(&self.history_backup_file, &sealed);
        }
    }

    fn atomic_write(dest: &Path, bytes: &[u8]) {
        let tmp = dest.with_extension("tmp");
        if fs::write(&tmp, bytes).is_ok() {
            if fs::rename(&tmp, dest).is_err() {
                let _ = fs::write(dest, bytes);
                let _ = fs::remove_file(&tmp);
            }
        }
    }

    pub fn insert_or_promote(&mut self, new_item: ClipItem) -> String {
        let final_id: String;
        if let Some(pos) = self
            .items
            .iter()
            .position(|it| it.content_hash == new_item.content_hash)
        {
            let mut existing = self.items.remove(pos);
            existing.created_unix_secs = now_unix_secs();
            if new_item.source_app_name.is_some() {
                existing.source_app_name = new_item.source_app_name;
            }
            final_id = existing.id.clone();
            self.items.insert(0, existing);
        } else {
            final_id = new_item.id.clone();
            self.items.insert(0, new_item);
        }

        if !self.config.minimal_mode_enabled
            && self.queue_mode_active
            && !self.paste_queue_ids.contains(&final_id)
        {
            self.paste_queue_ids.push_back(final_id.clone());
        }

        Self::sort_items(&mut self.items);
        self.trim_history_if_needed();
        self.save_history();
        final_id
    }

    /// 跨处选段续接复制（`Ctrl+Alt+C` / `Ctrl+Shift+C`）：将新选段无缝追加至最近一条未收藏、非待办文本记录末尾（绝不污染已锁定的收藏常用语）
    pub fn append_to_latest_text(&mut self, fragment: &str, separator: &str) -> Option<String> {
        let clean_frag = fragment.trim_matches(['\r', '\n']);
        if clean_frag.trim().is_empty() {
            return None;
        }
        if let Some(pos) = self.items.iter().position(|it| {
            !it.is_pinned
                && !it.is_pending_todo()
                && matches!(it.kind, ClipContentType::Text | ClipContentType::Link)
                && it.text.is_some()
        }) {
            let mut target = self.items.remove(pos);
            let old_hash = target.content_hash.clone();
            let prev = target.text.unwrap_or_default();
            let merged = if prev.is_empty() {
                clean_frag.to_string()
            } else {
                format!("{prev}{separator}{clean_frag}")
            };
            let is_link = crate::model::is_valid_web_url(merged.trim());
            target.kind = if is_link {
                ClipContentType::Link
            } else {
                ClipContentType::Text
            };
            let hash = sha256_hex(merged.as_bytes());
            let new_hash = format!("{}:{hash}", if is_link { "link" } else { "text" });
            target.content_hash = new_hash.clone();
            target.text = Some(merged.clone());
            target.created_unix_secs = now_unix_secs();
            self.items.insert(0, target);
            Self::sort_items(&mut self.items);
            if old_hash != new_hash && !self.items.iter().any(|it| it.content_hash == old_hash) {
                self.forget_memory_hashes(&[old_hash]);
            }
            self.save_history();
            Some(merged)
        } else {
            let item = ClipItem::new_text(clean_frag.to_string(), None);
            let out = item.text.clone();
            self.insert_or_promote(item);
            out
        }
    }

    /// 搜索框 `[] 事项` / `> 备注 :: 正文` 一行闪念入库
    pub fn capture_quick_note(&mut self, intent: &QuickCaptureIntent) -> Option<String> {
        let raw_body = intent.body.trim();
        if raw_body.is_empty() {
            return None;
        }
        if intent.default_todo {
            return self.capture_quick_todo(raw_body, intent.alias.as_deref());
        }
        let expanded = crate::security::expand_quick_capture_secret_body(raw_body);
        let final_body = expanded.as_deref().unwrap_or(raw_body);
        let mut item = ClipItem::new_text(final_body.to_string(), Some("闪念速记".to_string()));
        if let Some(alias) = &intent.alias {
            if !alias.trim().is_empty() {
                item.custom_alias = Some(alias.trim().to_string());
            }
        }
        if intent.default_pin {
            item.is_pinned = true;
            item.pin_category =
                PinCategory::infer(item.custom_alias.as_deref(), item.text.as_deref());
        }
        Some(self.insert_or_promote(item))
    }

    /// 闪念新建待办：直接落入待办清单且不冲掉当前系统剪贴板
    pub fn capture_quick_todo(&mut self, raw_body: &str, alias: Option<&str>) -> Option<String> {
        let body = raw_body.trim();
        if body.is_empty() {
            return None;
        }
        let probe = ClipItem::new_text(body.to_string(), Some("iClip 待办".to_string()));
        let hash = probe.content_hash.clone();
        let clean_alias = alias.map(|a| a.trim()).filter(|a| !a.is_empty());

        let final_id =
            if let Some(existing) = self.items.iter_mut().find(|it| it.content_hash == hash) {
                existing.created_unix_secs = now_unix_secs();
                existing.set_todo(true);
                existing.todo_completed_unix_secs = None;
                if let Some(al) = clean_alias {
                    existing.custom_alias = Some(al.to_string());
                }
                existing.id.clone()
            } else {
                let mut item = probe;
                item.set_todo(true);
                if let Some(al) = clean_alias {
                    item.custom_alias = Some(al.to_string());
                }
                let id = item.id.clone();
                self.items.insert(0, item);
                id
            };
        Self::sort_items(&mut self.items);
        self.trim_history_if_needed();
        self.save_history();
        Some(final_id)
    }

    pub fn pending_todo_count(&self) -> usize {
        self.items.iter().filter(|it| it.is_pending_todo()).count()
    }

    pub fn completed_todo_count(&self) -> usize {
        self.items
            .iter()
            .filter(|it| it.is_todo_completed())
            .count()
    }

    /// 导出当前所有待办为标准 Markdown 任务清单（未完成 `- [ ]` 在前，已完成 `- [x]` 在后）
    pub fn format_todos_as_markdown(&self) -> Option<(String, usize)> {
        let mut todos: Vec<&ClipItem> = self.items.iter().filter(|it| it.is_todo()).collect();
        if todos.is_empty() {
            return None;
        }
        todos.sort_by(
            |a, b| match (a.is_todo_completed(), b.is_todo_completed()) {
                (false, true) => std::cmp::Ordering::Less,
                (true, false) => std::cmp::Ordering::Greater,
                (false, false) => b.created_unix_secs.cmp(&a.created_unix_secs),
                (true, true) => b
                    .todo_completed_unix_secs
                    .unwrap_or(b.created_unix_secs)
                    .cmp(&a.todo_completed_unix_secs.unwrap_or(a.created_unix_secs)),
            },
        );
        let count = todos.len();
        let lines: Vec<String> = todos
            .into_iter()
            .map(|it| {
                let prefix = if it.is_todo_completed() {
                    "- [x] "
                } else {
                    "- [ ] "
                };
                let raw_flat = it.raw_content_preview().replace(" ↵ ", " ");
                let raw_clean = raw_flat.trim();
                if let Some(alias) = it.custom_alias.as_deref().map(|s| s.trim()) {
                    if !alias.is_empty() {
                        if it.kind == ClipContentType::Link
                            || (it.kind == ClipContentType::Text
                                && alias != raw_clean
                                && raw_clean.chars().count() <= 100)
                        {
                            return format!("{prefix}{alias} — {raw_clean}");
                        }
                        return format!("{prefix}{alias}");
                    }
                }
                format!("{prefix}{raw_clean}")
            })
            .collect();
        Some((lines.join("\r\n"), count))
    }

    /// Ctrl+T 切换：非待办 -> 待办未完成 -> 待办已完成 -> 恢复未完成
    pub fn toggle_todo(&mut self, item_id: &str) -> Option<&'static str> {
        let now = now_unix_secs();
        let item = self.items.iter_mut().find(|it| it.id == item_id)?;
        self.pending_otp_expirations.retain(|(id, _)| id != item_id);
        let msg = if !item.is_todo() {
            item.set_todo(true);
            item.todo_completed_unix_secs = None;
            "已加入待办 · 按 Alt+2 查看"
        } else if item.todo_completed_unix_secs.is_none() {
            item.todo_completed_unix_secs = Some(now);
            "✓ 已完成待办 · 24h 后自动归档"
        } else {
            item.todo_completed_unix_secs = None;
            "已恢复为未完成待办"
        };
        self.save_history();
        Some(msg)
    }

    pub fn mark_todo_completed_silently(&mut self, item_id: &str) -> bool {
        if let Some(item) = self.items.iter_mut().find(|it| it.id == item_id) {
            if item.is_pending_todo() {
                item.todo_completed_unix_secs = Some(now_unix_secs());
                self.save_history();
                return true;
            }
        }
        false
    }

    pub fn archive_completed_todos(&mut self) -> usize {
        let mut count = 0usize;
        for item in &mut self.items {
            if item.is_todo_completed() {
                item.set_todo(false);
                count += 1;
            }
        }
        if count > 0 {
            self.save_history();
        }
        count
    }

    pub fn archive_expired_completed_todos(&mut self, now_secs: u64) -> usize {
        let mut count = 0usize;
        for item in &mut self.items {
            if item.is_todo() {
                if let Some(done_at) = item.todo_completed_unix_secs {
                    if now_secs.saturating_sub(done_at) >= 86_400 {
                        item.set_todo(false);
                        count += 1;
                    }
                }
            }
        }
        if count > 0 {
            self.save_history();
        }
        count
    }

    pub fn split_checklist_into_todos(&mut self, item_id: &str) -> usize {
        let Some((raw, src_app)) = self
            .items
            .iter()
            .find(|it| it.id == item_id)
            .and_then(|it| it.text.clone().map(|t| (t, it.source_app_name.clone())))
        else {
            return 0;
        };
        let lines = extract_checklist_items(&raw);
        if lines.len() < 2 {
            return 0;
        }
        let base_ts = now_unix_secs();
        let mut count = 0usize;
        for (offset, line) in lines.into_iter().rev().enumerate() {
            let mut probe = ClipItem::new_text(
                line,
                src_app.clone().or_else(|| Some("清单拆解".to_string())),
            );
            probe.created_unix_secs = base_ts.saturating_add(offset as u64);
            probe.set_todo(true);
            if let Some(existing) = self
                .items
                .iter_mut()
                .find(|it| it.content_hash == probe.content_hash)
            {
                existing.created_unix_secs = probe.created_unix_secs;
                existing.set_todo(true);
                existing.todo_completed_unix_secs = None;
            } else {
                self.items.insert(0, probe);
            }
            count += 1;
        }
        Self::sort_items(&mut self.items);
        self.trim_history_if_needed();
        self.save_history();
        count
    }

    /// 修改卡片备注别名：输入非空备注时自动开启收藏保护并智能推断分组，防止被历史滚动挤掉
    pub fn set_custom_alias(&mut self, item_id: &str, raw_alias: &str) -> Option<bool> {
        let item = self.items.iter_mut().find(|it| it.id == item_id)?;
        let clean = raw_alias.trim();
        let mut auto_pinned = false;
        if clean.is_empty() {
            item.custom_alias = None;
        } else {
            item.custom_alias = Some(clean.to_string());
            if !item.is_pinned && !item.is_todo() {
                item.is_pinned = true;
                auto_pinned = true;
                self.pending_otp_expirations.retain(|(id, _)| id != item_id);
            }
            if item.is_pinned && item.pin_category.is_none() {
                item.pin_category = PinCategory::infer(Some(clean), item.text.as_deref());
            }
        }
        Self::sort_items(&mut self.items);
        self.save_history();
        Some(auto_pinned)
    }

    pub fn set_pin_category(&mut self, item_id: &str, category: Option<PinCategory>) {
        if let Some(item) = self.items.iter_mut().find(|it| it.id == item_id) {
            item.is_pinned = true;
            item.pin_category = category;
            self.pending_otp_expirations.retain(|(id, _)| id != item_id);
            Self::sort_items(&mut self.items);
            self.save_history();
        }
    }

    pub fn filtered_indices(&self, tab: ClipFilterTab, query: &str) -> Vec<usize> {
        self.filtered_indices_ext(tab, None, query, None)
    }

    pub fn filtered_indices_ext(
        &self,
        tab: ClipFilterTab,
        pin_category: Option<PinCategory>,
        query: &str,
        active_target_app: Option<&str>,
    ) -> Vec<usize> {
        let is_cmd = extract_suggestion_payload(query).is_some()
            || parse_quick_capture(query).is_some()
            || crate::security::evaluate_secure_password_query(query).is_some()
            || crate::security::evaluate_secret_capsule_command(
                query,
                self.latest_plain_for_capsule_lock(),
                self.latest_capsule_text(None),
            )
            .is_some();
        let effective_q = if is_cmd { "" } else { query.trim() };

        let mut matched: Vec<usize> = self
            .items
            .iter()
            .enumerate()
            .filter(|(_, item)| {
                let tab_ok = match tab {
                    ClipFilterTab::All => true,
                    ClipFilterTab::Todo => item.is_todo(),
                    ClipFilterTab::Pinned => {
                        if let Some(cat) = pin_category {
                            item.is_pinned && item.pin_category == Some(cat)
                        } else {
                            item.is_pinned
                        }
                    }
                    ClipFilterTab::Text => item.kind == ClipContentType::Text,
                    ClipFilterTab::Link => item.kind == ClipContentType::Link,
                    ClipFilterTab::Image => item.kind == ClipContentType::Image,
                    ClipFilterTab::File => item.kind == ClipContentType::File,
                };
                tab_ok && item.matches_query(effective_q)
            })
            .map(|(i, _)| i)
            .collect();

        if tab == ClipFilterTab::Todo {
            matched.sort_by(|&a, &b| {
                let ia = &self.items[a];
                let ib = &self.items[b];
                match (ia.is_todo_completed(), ib.is_todo_completed()) {
                    (false, true) => std::cmp::Ordering::Less,
                    (true, false) => std::cmp::Ordering::Greater,
                    (false, false) => ib.created_unix_secs.cmp(&ia.created_unix_secs),
                    (true, true) => ib
                        .todo_completed_unix_secs
                        .unwrap_or(ib.created_unix_secs)
                        .cmp(&ia.todo_completed_unix_secs.unwrap_or(ia.created_unix_secs)),
                }
            });
            return matched;
        }

        if self.config.minimal_mode_enabled || matched.len() <= 1 {
            return matched;
        }

        // 搜索词相关性 + 自适应复用频次与目标应用亲和排序
        if !effective_q.is_empty() {
            matched.sort_by(|&a, &b| {
                let score_a =
                    self.search_rank_score(&self.items[a], effective_q, active_target_app);
                let score_b =
                    self.search_rank_score(&self.items[b], effective_q, active_target_app);
                score_b.cmp(&score_a).then_with(|| {
                    self.items[b]
                        .created_unix_secs
                        .cmp(&self.items[a].created_unix_secs)
                })
            });
        } else if tab == ClipFilterTab::Pinned && active_target_app.is_some() {
            matched.sort_by(|&a, &b| {
                let aff_a =
                    self.target_affinity_count(&self.items[a].content_hash, active_target_app);
                let aff_b =
                    self.target_affinity_count(&self.items[b].content_hash, active_target_app);
                aff_b.cmp(&aff_a).then_with(|| {
                    self.items[b]
                        .created_unix_secs
                        .cmp(&self.items[a].created_unix_secs)
                })
            });
        }

        matched
    }

    fn search_rank_score(&self, item: &ClipItem, q: &str, target_app: Option<&str>) -> i32 {
        let mut score = 0i32;
        if item.is_pinned {
            score += 35;
        }
        if let Some(alias) = &item.custom_alias {
            if alias.eq_ignore_ascii_case(q) || alias == q {
                score += 120;
            } else if contains_case_insensitive(alias, q) {
                score += 75;
            }
        }
        if let Some(txt) = &item.text {
            let head = crate::model::safe_utf8_prefix(txt, 512);
            if head.trim().starts_with(q) {
                score += 50;
            }
        }
        score += (self.reuse_count(&item.content_hash).min(20) as i32) * 4;
        score += (self
            .target_affinity_count(&item.content_hash, target_app)
            .min(15) as i32)
            * 8;
        score
    }

    pub fn record_paste_usage(&mut self, content_hash: &str, target_app: Option<&str>) {
        if self.config.minimal_mode_enabled {
            return;
        }
        *self
            .memory
            .reuse_counts
            .entry(content_hash.to_string())
            .or_insert(0) += 1;
        if let Some(app) = target_app.map(str::trim).filter(|s| !s.is_empty()) {
            let entry = self
                .memory
                .app_affinity
                .entry(content_hash.to_string())
                .or_default();
            *entry.entry(app.to_string()).or_insert(0) += 1;
        }
        self.save_memory();
    }

    pub fn record_action_habit(&mut self, source_app: Option<&str>, action_id: &str) {
        if self.config.minimal_mode_enabled {
            return;
        }
        let key = source_app
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("_global_");
        self.memory
            .action_habits
            .insert(key.to_string(), action_id.to_string());
        self.save_memory();
    }

    pub fn reuse_count(&self, content_hash: &str) -> u32 {
        self.memory
            .reuse_counts
            .get(content_hash)
            .copied()
            .unwrap_or(0)
    }

    pub fn target_affinity_count(&self, content_hash: &str, target_app: Option<&str>) -> u32 {
        let Some(app) = target_app.map(str::trim).filter(|s| !s.is_empty()) else {
            return 0;
        };
        self.memory
            .app_affinity
            .get(content_hash)
            .and_then(|m| m.get(app))
            .copied()
            .unwrap_or(0)
    }

    pub fn preferred_target_badge(
        &self,
        content_hash: &str,
        active_target_app: Option<&str>,
    ) -> Option<String> {
        let app = active_target_app?.trim();
        if app.is_empty() {
            return None;
        }
        let cnt = self.target_affinity_count(content_hash, Some(app));
        if cnt >= 2 {
            Some(format!("常贴至 {app}"))
        } else {
            None
        }
    }

    pub fn rank_actions_for_item(
        &self,
        item: &ClipItem,
        actions: Vec<QuickAction>,
    ) -> Vec<QuickAction> {
        self.rank_actions_for_context(item, None, actions)
    }

    pub fn rank_actions_for_context(
        &self,
        item: &ClipItem,
        target_app: Option<&str>,
        mut actions: Vec<QuickAction>,
    ) -> Vec<QuickAction> {
        if actions.is_empty() || self.config.minimal_mode_enabled {
            return actions;
        }
        if actions.len() > 1 {
            let app_key = item
                .source_app_name
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or("_global_");
            let preferred = self
                .memory
                .action_habits
                .get(app_key)
                .or_else(|| self.memory.action_habits.get("_global_"));
            if let Some(pref_id) = preferred {
                if let Some(pos) = actions.iter().position(|a| a.id == pref_id.as_str()) {
                    if pos > 0 {
                        let act = actions.remove(pos);
                        actions.insert(0, act);
                    }
                }
            }
        }
        // 外发 AI 助手 / 公域聊天软件防泄密护航：自动将安全脱敏胶囊置顶为 #1 首选动作（Shift+Enter 直发）
        if crate::security::is_external_ai_or_chat_app(target_app) {
            if let Some(sec_pos) = actions
                .iter()
                .position(|a| a.is_security || a.id.starts_with("redact-"))
            {
                let mut sec = actions.remove(sec_pos);
                if sec.id == "redact-secrets" {
                    sec.title = "防泄密脱敏".to_string();
                }
                actions.insert(0, sec);
            }
        }
        actions
    }

    /// 采纳用户 `@建议 ...` 自然语言指令，即时生效并写入建议进化台账
    pub fn adopt_user_suggestion(&mut self, raw_payload: &str) -> String {
        let text = raw_payload.trim();
        if text.is_empty() {
            return "请输入建议内容，例如：@建议 开启始终在前 / 双击 Ctrl 呼出".to_string();
        }
        let lower = text.to_lowercase();
        let is_off = lower.contains("关闭")
            || lower.contains("取消")
            || lower.contains("不要")
            || lower.contains("禁用")
            || lower.contains("off");

        let mut effects: Vec<String> = Vec::new();

        if lower.contains("极简") || lower.contains("纯净") {
            self.config.minimal_mode_enabled = !is_off;
            effects.push(if !is_off {
                "已开启极简纯净模式".to_string()
            } else {
                "已恢复全量智能工具箱".to_string()
            });
        }
        if lower.contains("始终在前")
            || lower.contains("置顶")
            || lower.contains("钉住")
            || lower.contains("不消失")
        {
            self.config.always_on_top = !is_off;
            effects.push(if !is_off {
                "已开启窗口始终在前".to_string()
            } else {
                "已关闭窗口始终在前".to_string()
            });
        }
        if lower.contains("富文本")
            || lower.contains("纯文本")
            || lower.contains("去样式")
            || lower.contains("去格式")
        {
            self.config.auto_strip_rich_formatting = !is_off;
            effects.push(if !is_off {
                "已开启自动剥离富文本脏样式".to_string()
            } else {
                "已关闭自动剥离富文本样式".to_string()
            });
        }
        if lower.contains("净链") || lower.contains("追踪") || lower.contains("utm") {
            self.config.auto_clean_tracking_url = !is_off;
            effects.push(if !is_off {
                "已开启复制链接自动剥离追踪参数".to_string()
            } else {
                "已关闭自动净链".to_string()
            });
        }
        if lower.contains("验证码") || lower.contains("otp") || lower.contains("阅后即焚") {
            self.config.auto_expire_otp = !is_off;
            effects.push(if !is_off {
                "已开启验证码 30 秒自动销毁".to_string()
            } else {
                "已关闭验证码自动销毁".to_string()
            });
        }
        if lower.contains("投屏")
            || lower.contains("录屏")
            || lower.contains("共享屏幕")
            || lower.contains("会议隐身")
        {
            self.config.screen_share_privacy = !is_off;
            effects.push(if !is_off {
                "已开启投屏与录屏光学隐身护盾".to_string()
            } else {
                "已关闭投屏隐身保护".to_string()
            });
        }
        if lower.contains("防窥")
            || lower.contains("肩窥")
            || lower.contains("遮罩")
            || lower.contains("雾化")
        {
            self.config.mask_sensitive_previews = !is_off;
            effects.push(if !is_off {
                "已开启敏感凭据防肩窥圆点遮罩".to_string()
            } else {
                "已关闭敏感凭据遮罩".to_string()
            });
        }
        if lower.contains("自动粘贴") || lower.contains("直接粘贴") {
            self.config.auto_paste_enabled = !is_off;
            effects.push(if !is_off {
                "已开启选中自动键入粘贴".to_string()
            } else {
                "已改为仅复制不自动粘贴".to_string()
            });
        }
        if lower.contains("敏感清理")
            || lower.contains("敏感自毁")
            || lower.contains("24h自毁")
            || lower.contains("24小时清理")
        {
            self.config.auto_expire_unpinned_secrets = !is_off;
            effects.push(if !is_off {
                "已开启未收藏敏感凭据 24h 自动销毁".to_string()
            } else {
                "已关闭未收藏敏感凭据自动销毁".to_string()
            });
        }
        if lower.contains("双击") && (lower.contains("ctrl") || lower.contains("control")) {
            self.config.hotkey_toggle = WinHotKeyShortcut::double_tap(WinSingleModifier::Control);
            effects.push("呼出热键已切换为「双击 Ctrl」".to_string());
        } else if lower.contains("双击") && lower.contains("alt") {
            self.config.hotkey_toggle = WinHotKeyShortcut::double_tap(WinSingleModifier::Alt);
            effects.push("呼出热键已切换为「双击 Alt」".to_string());
        } else if lower.contains("双击") && lower.contains("shift") {
            self.config.hotkey_toggle = WinHotKeyShortcut::double_tap(WinSingleModifier::Shift);
            effects.push("呼出热键已切换为「双击 Shift」".to_string());
        }
        if lower.contains("通透") || lower.contains("透明") {
            self.config.glass_appearance = GlassAppearance::Clear;
            self.config.blur_concentration_pct = 15;
            effects.push("液态玻璃背景模糊浓度已调至 15%（清澈透光）".to_string());
        } else if lower.contains("实色") || lower.contains("不透明") || lower.contains("护眼")
        {
            self.config.glass_appearance = GlassAppearance::Solid;
            self.config.blur_concentration_pct = 96;
            effects.push("液态玻璃背景模糊浓度已调至 96%（实色护眼）".to_string());
        } else if lower.contains("柔焦") || lower.contains("深色玻璃") {
            self.config.glass_appearance = GlassAppearance::Tinted;
            self.config.blur_concentration_pct = 38;
            effects.push("液态玻璃背景模糊浓度已调至 38%（深邃柔焦）".to_string());
        }
        for cap in [100usize, 200, 500, 1000] {
            if lower.contains(&cap.to_string())
                && (lower.contains("条")
                    || lower.contains("容量")
                    || lower.contains("上限")
                    || lower.contains("保留"))
            {
                self.config.max_history_count = cap;
                self.trim_history_if_needed();
                self.save_history();
                effects.push(format!("历史保留上限已设为 {cap} 条"));
                break;
            }
        }

        if lower.contains("零宽")
            || lower.contains("隐藏字符")
            || lower.contains("幽灵字符")
            || lower.contains("控制符")
        {
            self.config.auto_strip_zero_width = !is_off;
            effects.push(if !is_off {
                "已开启复制自动清除零宽与隐藏控制符".to_string()
            } else {
                "已关闭自动清除隐藏字符".to_string()
            });
        }

        if lower.contains("恢复记录")
            || lower.contains("恢复监听")
            || lower.contains("开启记录")
            || lower.contains("取消暂停")
        {
            self.resume_capture();
            effects.push("已立即恢复剪贴板记录".to_string());
        } else if lower.contains("无痕暂停")
            || lower.contains("暂停记录")
            || lower.contains("暂停监听")
            || lower.starts_with("暂停")
            || lower.starts_with("无痕")
        {
            let mins = lower
                .split(|c: char| !c.is_ascii_digit())
                .find_map(|s| {
                    if s.is_empty() {
                        None
                    } else {
                        s.parse::<u64>().ok()
                    }
                })
                .unwrap_or(15)
                .clamp(1, 480);
            self.pause_for_minutes(Some(mins), now_unix_secs());
            effects.push(format!("已开启 {mins} 分钟无痕暂停（到点自动恢复）"));
        }

        self.save_config();

        let summary = if effects.is_empty() {
            "建议已归档至本地进化台账，将在后续习惯迭代中优先适配".to_string()
        } else {
            format!("已采纳并即时生效：{}", effects.join("；"))
        };

        let mut logs: Vec<UserSuggestionRecord> = fs::read(&self.suggestions_file)
            .ok()
            .and_then(|raw| {
                let (plain, _) = open_vault_bytes(&raw, &self.vault_key)?;
                serde_json::from_slice(&plain).ok()
            })
            .unwrap_or_default();
        logs.push(UserSuggestionRecord {
            created_unix_secs: now_unix_secs(),
            suggestion: text.to_string(),
            applied_summary: summary.clone(),
        });
        if let Ok(plain_bytes) = serde_json::to_vec_pretty(&logs) {
            let sealed = seal_vault_bytes(&plain_bytes, &self.vault_key, &self.data_dir);
            Self::atomic_write(&self.suggestions_file, &sealed);
        }

        summary
    }

    pub fn toggle_pin(&mut self, item_id: &str) -> Option<bool> {
        let item = self.items.iter_mut().find(|it| it.id == item_id)?;
        item.is_pinned = !item.is_pinned;
        let pinned = item.is_pinned;
        if pinned {
            self.pending_otp_expirations.retain(|(id, _)| id != item_id);
            if item.pin_category.is_none() {
                item.pin_category =
                    PinCategory::infer(item.custom_alias.as_deref(), item.text.as_deref());
            }
        } else {
            item.pin_category = None;
        }
        Self::sort_items(&mut self.items);
        self.save_history();
        Some(pinned)
    }

    pub fn delete_by_id(&mut self, item_id: &str) {
        let skip_undo = self
            .items
            .iter()
            .find(|it| it.id == item_id)
            .map(|it| {
                !it.is_pinned
                    && (it.is_burn_after_paste()
                        || it.detected_sensitive_kind().is_some()
                        || it.detected_poison_threat().is_some())
            })
            .unwrap_or(false);
        self.delete_by_id_with_undo(item_id, !skip_undo);
    }

    fn delete_by_id_with_undo(&mut self, item_id: &str, allow_undo: bool) {
        self.pending_otp_expirations.retain(|(id, _)| id != item_id);
        self.paste_queue_ids.retain(|id| id != item_id);
        if let Some(pos) = self.items.iter().position(|it| it.id == item_id) {
            let removed = self.items.remove(pos);
            let mut img_bytes = None;
            if let Some(img) = &removed.image_file_name {
                crate::security::purge_temp_preview_image(img);
                let p = self.images_dir.join(img);
                if allow_undo {
                    img_bytes = fs::read(&p).ok();
                }
                let _ = fs::remove_file(p);
            }
            if !self
                .items
                .iter()
                .any(|it| it.content_hash == removed.content_hash)
            {
                let h = removed.content_hash.clone();
                self.forget_memory_hashes(&[h]);
            }
            if allow_undo {
                self.push_undo_snapshot(vec![(removed, img_bytes)]);
            }
            self.save_history();
        }
    }

    pub fn clear_unpinned(&mut self) {
        crate::security::wipe_all_temp_previews();
        crate::security::wipe_privacy_twins();
        let mut kept = Vec::new();
        let mut removed_batch = Vec::new();
        let mut purged_hashes = Vec::new();
        for item in self.items.drain(..) {
            if item.is_pinned || item.is_pending_todo() {
                kept.push(item);
            } else {
                let is_sensitive_or_threat = item.is_burn_after_paste()
                    || item.detected_sensitive_kind().is_some()
                    || item.detected_poison_threat().is_some();
                let mut img_bytes = None;
                if let Some(img) = &item.image_file_name {
                    crate::security::purge_temp_preview_image(img);
                    let p = self.images_dir.join(img);
                    if !is_sensitive_or_threat && removed_batch.len() < 32 {
                        img_bytes = fs::read(&p).ok();
                    }
                    let _ = fs::remove_file(p);
                }
                self.paste_queue_ids.retain(|id| id != &item.id);
                self.pending_otp_expirations
                    .retain(|(id, _)| id != &item.id);
                purged_hashes.push(item.content_hash.clone());
                if !is_sensitive_or_threat {
                    removed_batch.push((item, img_bytes));
                }
            }
        }
        self.items = kept;
        purged_hashes.retain(|h| !self.items.iter().any(|k| &k.content_hash == h));
        self.forget_memory_hashes(&purged_hashes);
        if !removed_batch.is_empty() {
            self.push_undo_snapshot(removed_batch);
        } else {
            self.undo_stack.clear();
        }
        self.save_history();
    }

    /// 锁屏、休眠、安全清扫或退出应用时瞬时清零删除撤销栈与 AI 替身内存映射
    pub fn lock_down_ephemeral_buffers(&mut self) {
        self.undo_stack.clear();
        crate::security::wipe_privacy_twins();
    }

    fn push_undo_snapshot(&mut self, entries: Vec<(ClipItem, Option<Vec<u8>>)>) {
        let now = now_unix_secs();
        self.undo_stack
            .retain(|snap| now.saturating_sub(snap.deleted_at_secs) <= 10);
        if self.undo_stack.len() >= 5 {
            self.undo_stack.remove(0);
        }
        self.undo_stack.push(UndoSnapshot {
            deleted_at_secs: now,
            entries,
        });
    }

    /// 8 秒内按 `Ctrl+Z` 原位恢复误删记录（含 PNG 原图文件字节）
    pub fn undo_last_delete(&mut self, current_unix_secs: u64) -> Option<usize> {
        while let Some(snap) = self.undo_stack.pop() {
            if current_unix_secs.saturating_sub(snap.deleted_at_secs) <= 10
                && !snap.entries.is_empty()
            {
                let mut restored = 0usize;
                for (item, img_bytes) in snap.entries {
                    if let (Some(fname), Some(bytes)) = (&item.image_file_name, img_bytes) {
                        let _ = fs::write(self.images_dir.join(fname), bytes);
                    }
                    if !self.items.iter().any(|existing| existing.id == item.id) {
                        self.items.push(item);
                        restored += 1;
                    }
                }
                if restored > 0 {
                    Self::sort_items(&mut self.items);
                    self.save_history();
                    return Some(restored);
                }
            }
        }
        None
    }

    pub fn has_active_undo(&self, current_unix_secs: u64) -> bool {
        self.undo_stack
            .last()
            .map(|s| current_unix_secs.saturating_sub(s.deleted_at_secs) <= 8)
            .unwrap_or(false)
    }

    pub fn schedule_otp_expire_if_needed(&mut self, item_id: &str, delay_secs: u64) {
        if self.config.minimal_mode_enabled || !self.config.auto_expire_otp {
            return;
        }
        let Some(item) = self.items.iter().find(|it| it.id == item_id) else {
            return;
        };
        if item.is_pinned || item.kind != ClipContentType::Text {
            return;
        }
        if let Some(txt) = &item.text {
            if is_otp_message(txt) {
                let deadline = now_unix_secs() + delay_secs;
                self.pending_otp_expirations.retain(|(id, _)| id != item_id);
                self.pending_otp_expirations
                    .push((item_id.to_string(), deadline));
            }
        }
    }

    /// 清理已到期的一次性验证码记录与超期撤销快照，返回清理 OTP 条数
    pub fn sweep_expired_otps(&mut self, current_unix_secs: u64) -> usize {
        self.undo_stack
            .retain(|snap| current_unix_secs.saturating_sub(snap.deleted_at_secs) <= 10);

        let purged_secrets = self.purge_expired_unpinned_secrets(current_unix_secs, 86_400);

        if self.pending_otp_expirations.is_empty() {
            return purged_secrets;
        }
        let mut expired_ids = Vec::new();
        self.pending_otp_expirations.retain(|(id, deadline)| {
            if current_unix_secs >= *deadline {
                expired_ids.push(id.clone());
                false
            } else {
                true
            }
        });

        let mut count = purged_secrets;
        for id in expired_ids {
            if let Some(it) = self.items.iter().find(|i| i.id == id) {
                let is_burn = it.is_burn_after_paste();
                if is_burn
                    || (!it.is_pinned
                        && !self.config.minimal_mode_enabled
                        && self.config.auto_expire_otp)
                {
                    self.delete_by_id_with_undo(&id, false);
                    count += 1;
                }
            }
        }
        count
    }

    /// 清理超过指定存活窗口（默认 24h）的未收藏、非待办高敏凭据（含加密截图原文件）
    pub fn purge_expired_unpinned_secrets(
        &mut self,
        current_unix_secs: u64,
        max_age_secs: u64,
    ) -> usize {
        if self.config.minimal_mode_enabled || !self.config.auto_expire_unpinned_secrets {
            return 0;
        }
        let expired_ids: Vec<String> = self
            .items
            .iter()
            .filter(|it| {
                !it.is_pinned
                    && !it.is_pending_todo()
                    && it.detected_sensitive_kind().is_some()
                    && current_unix_secs.saturating_sub(it.created_unix_secs) >= max_age_secs
            })
            .map(|it| it.id.clone())
            .collect();
        let count = expired_ids.len();
        for id in expired_ids {
            self.delete_by_id_with_undo(&id, false);
        }
        count
    }

    fn is_unpinned_security_or_poison_risk(it: &ClipItem) -> bool {
        if it.is_pinned || it.is_pending_todo() {
            return false;
        }
        it.detected_sensitive_kind().is_some()
            || it.is_burn_after_paste()
            || it.detected_link_risk().is_some()
            || matches!(
                it.detected_poison_threat(),
                Some(crate::security::PoisonThreatKind::PastejackingOrBidi(_))
            )
    }

    /// 统计当前库中未收藏、非待办的高敏凭据、投毒风险与粘贴即焚项总数（支撑 `@敏感` 与 `@体检`）
    pub fn unpinned_sensitive_count(&self) -> usize {
        self.items
            .iter()
            .filter(|it| Self::is_unpinned_security_or_poison_risk(it))
            .count()
    }

    pub fn latest_plain_for_capsule_lock(&self) -> Option<&str> {
        self.items.iter().find_map(|it| {
            let t = it.text.as_deref()?.trim();
            if t.is_empty() || crate::security::contains_secret_capsule(Some(t)) {
                None
            } else {
                it.text.as_deref()
            }
        })
    }

    pub fn latest_capsule_text<'a>(&'a self, preferred_idx: Option<usize>) -> Option<&'a str> {
        if let Some(idx) = preferred_idx {
            if let Some(it) = self.items.get(idx) {
                if crate::security::contains_secret_capsule(it.text.as_deref()) {
                    return it.text.as_deref();
                }
            }
        }
        self.items.iter().find_map(|it| {
            if crate::security::contains_secret_capsule(it.text.as_deref()) {
                it.text.as_deref()
            } else {
                None
            }
        })
    }

    /// 一键无痕清扫所有未收藏、非待办的敏感凭据、隐藏控制符投毒、钓鱼风险与粘贴即焚残留（收藏项永久豁免）
    pub fn sweep_all_unpinned_sensitive(&mut self) -> usize {
        let target_ids: Vec<String> = self
            .items
            .iter()
            .filter(|it| Self::is_unpinned_security_or_poison_risk(it))
            .map(|it| it.id.clone())
            .collect();
        let count = target_ids.len();
        for id in target_ids {
            self.delete_by_id_with_undo(&id, false);
        }
        crate::security::wipe_privacy_twins();
        count
    }

    pub fn toggle_burn_after_paste(&mut self, item_id: &str) -> Option<bool> {
        let item = self.items.iter_mut().find(|it| it.id == item_id)?;
        let next = !item.is_burn_after_paste();
        item.set_burn_after_paste(next);
        if next && item.is_pinned {
            item.is_pinned = false;
        }
        self.save_history();
        Some(next)
    }

    pub fn schedule_burn_after_paste_if_needed(&mut self, item_id: &str, delay_secs: u64) -> bool {
        let Some(item) = self.items.iter().find(|it| it.id == item_id) else {
            return false;
        };
        if !item.is_burn_after_paste() {
            return false;
        }
        let expire_at = now_unix_secs() + delay_secs;
        self.pending_otp_expirations.retain(|(id, _)| id != item_id);
        self.pending_otp_expirations
            .push((item_id.to_string(), expire_at));
        true
    }

    pub fn is_app_ignored(&self, app_name: Option<&str>) -> bool {
        let Some(name) = app_name.map(|s| s.trim()).filter(|s| !s.is_empty()) else {
            return false;
        };
        self.config
            .ignored_apps
            .iter()
            .any(|ig| ig.eq_ignore_ascii_case(name))
    }

    pub fn toggle_queue_item(&mut self, item_id: &str) -> Option<usize> {
        if let Some(pos) = self.paste_queue_ids.iter().position(|id| id == item_id) {
            self.paste_queue_ids.remove(pos);
            None
        } else {
            self.paste_queue_ids.push_back(item_id.to_string());
            Some(self.paste_queue_ids.len())
        }
    }

    pub fn queue_rank(&self, item_id: &str) -> Option<usize> {
        self.paste_queue_ids
            .iter()
            .position(|id| id == item_id)
            .map(|idx| idx + 1)
    }

    pub fn dequeue_next_item(&mut self) -> Option<ClipItem> {
        while let Some(front_id) = self.paste_queue_ids.pop_front() {
            if let Some(found) = self.items.iter().find(|it| it.id == front_id) {
                return Some(found.clone());
            }
        }
        None
    }

    /// 将收件名片拆出的 `[姓名, 11位纯手机号, 详细地址]` 按序注入 FIFO 顺序连填队列
    pub fn enqueue_contact_fields_for_sequential_paste(&mut self, fields: &[String]) -> usize {
        let valid: Vec<String> = fields
            .iter()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if valid.is_empty() {
            return 0;
        }
        self.paste_queue_ids.clear();
        self.queue_mode_active = true;
        let mut ids = Vec::with_capacity(valid.len());
        for f in valid {
            let id = self.insert_or_promote(ClipItem::new_text(f, Some("收件连填".to_string())));
            ids.push(id);
        }
        self.paste_queue_ids.clear();
        for id in ids {
            self.paste_queue_ids.push_back(id);
        }
        self.save_history();
        self.paste_queue_ids.len()
    }

    pub fn pinned_count(&self) -> usize {
        self.items.iter().filter(|it| it.is_pinned).count()
    }

    pub fn pinned_sensitive_count(&self) -> usize {
        self.items
            .iter()
            .filter(|it| it.is_pinned && it.detected_sensitive_kind().is_some())
            .count()
    }

    pub fn export_archive_to_file(&self, dest: &Path) -> Result<usize, ArchiveBackupError> {
        self.export_archive_to_file_with_passphrase(dest, None)
            .map(|(n, _)| n)
    }

    pub fn export_archive_to_file_with_passphrase(
        &self,
        dest: &Path,
        passphrase: Option<&str>,
    ) -> Result<(usize, bool), ArchiveBackupError> {
        let plain_data = export_pinned_archive_data(
            &self.items,
            &self.images_dir,
            env!("CARGO_PKG_VERSION"),
            Self::edition_key(),
        )?;
        let (final_bytes, encrypted) =
            if let Some(pw) = passphrase.map(str::trim).filter(|s| !s.is_empty()) {
                (
                    crate::security::seal_archive_with_passphrase(&plain_data, pw, &self.data_dir),
                    true,
                )
            } else {
                (plain_data, false)
            };
        fs::write(dest, &final_bytes).map_err(|_| ArchiveBackupError::InvalidArchiveFormat)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(dest, fs::Permissions::from_mode(0o600));
        }
        Ok((self.pinned_count(), encrypted))
    }

    pub fn import_archive_from_file(
        &mut self,
        src: &Path,
    ) -> Result<ArchiveImportSummary, ArchiveBackupError> {
        self.import_archive_from_file_with_passphrase(src, None)
    }

    pub fn import_archive_from_file_with_passphrase(
        &mut self,
        src: &Path,
        passphrase: Option<&str>,
    ) -> Result<ArchiveImportSummary, ArchiveBackupError> {
        let data = fs::read(src).map_err(|_| ArchiveBackupError::InvalidArchiveFormat)?;
        let ext = src.extension().and_then(|e| e.to_str());
        let (mut merged, summary) = crate::archive::merge_archive_data_full(
            &data,
            &self.items,
            &self.images_dir,
            passphrase,
            ext,
        )?;
        Self::sort_items(&mut merged);
        self.items = merged;
        self.save_history();
        Ok(summary)
    }

    pub fn trim_history_if_needed(&mut self) {
        let max_unpinned = self.config.max_history_count.max(10);
        let mut unpinned_seen = 0usize;
        let mut retained = Vec::with_capacity(self.items.len());
        let mut evicted_hashes = Vec::new();
        let mut evicted_ids = std::collections::HashSet::new();
        for item in self.items.drain(..) {
            if item.is_pinned || item.is_pending_todo() {
                retained.push(item);
            } else if unpinned_seen < max_unpinned {
                unpinned_seen += 1;
                retained.push(item);
            } else {
                if let Some(img) = item.image_file_name {
                    let _ = fs::remove_file(self.images_dir.join(img));
                }
                evicted_hashes.push(item.content_hash);
                evicted_ids.insert(item.id);
            }
        }
        self.items = retained;
        if !evicted_ids.is_empty() {
            self.paste_queue_ids
                .retain(|qid| !evicted_ids.contains(qid));
            let active_hashes: std::collections::HashSet<&str> =
                self.items.iter().map(|i| i.content_hash.as_str()).collect();
            let dead_hashes: Vec<String> = evicted_hashes
                .into_iter()
                .filter(|h| !active_hashes.contains(h.as_str()))
                .collect();
            if !dead_hashes.is_empty() {
                self.forget_memory_hashes(&dead_hashes);
            }
        }
    }

    fn sort_items(list: &mut [ClipItem]) {
        list.sort_by(|a, b| b.created_unix_secs.cmp(&a.created_unix_secs));
    }
}
