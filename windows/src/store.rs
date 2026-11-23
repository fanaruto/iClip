use crate::archive::{
    export_pinned_archive_data, merge_archive_data, ArchiveBackupError, ArchiveImportSummary,
};
use crate::engines::is_otp_message;
use crate::hotkey::{WinHotKeyShortcut, WinSingleModifier};
use crate::intelligence::{extract_suggestion_payload, parse_quick_capture, QuickCaptureIntent};
use crate::model::{
    contains_case_insensitive, now_unix_secs, sha256_hex, ClipContentType, ClipFilterTab, ClipItem,
    PinCategory, QuickAction,
};
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
    #[serde(default)]
    pub queue_auto_tab: bool,
    #[serde(default)]
    pub glass_appearance: GlassAppearance,
    #[serde(default = "default_blur_pct")]
    pub blur_concentration_pct: u8,
    #[serde(default = "default_max_history")]
    pub max_history_count: usize,
}

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
            queue_auto_tab: false,
            glass_appearance: GlassAppearance::Tinted,
            blur_concentration_pct: 38,
            max_history_count: 200,
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

        let config = fs::read(&config_file)
            .ok()
            .and_then(|b| serde_json::from_slice::<StoreConfig>(&b).ok())
            .unwrap_or_default();

        let memory = fs::read(&memory_file)
            .ok()
            .and_then(|b| serde_json::from_slice::<AdaptiveMemory>(&b).ok())
            .unwrap_or_default();

        // 双模自愈读取：主文件缺失或异常截断损坏时，自动从 backup 镜像无损恢复
        let primary_items = fs::read(&history_file)
            .ok()
            .and_then(|b| serde_json::from_slice::<Vec<ClipItem>>(&b).ok());

        let (mut items, healed_from_backup) = match primary_items {
            Some(list) if !list.is_empty() || !history_backup_file.exists() => (list, false),
            _ => {
                let backup = fs::read(&history_backup_file)
                    .ok()
                    .and_then(|b| serde_json::from_slice::<Vec<ClipItem>>(&b).ok());
                match backup {
                    Some(b_list) if !b_list.is_empty() => (b_list, true),
                    _ => (primary_items.unwrap_or_default(), false),
                }
            }
        };
        Self::sort_items(&mut items);

        let store = Self {
            items,
            config,
            memory,
            is_paused: false,
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
            undo_stack: Vec::new(),
        };

        if healed_from_backup {
            store.save_history();
        }
        store
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
        if let Ok(bytes) = serde_json::to_vec(&self.memory) {
            Self::atomic_write(&self.memory_file, &bytes);
        }
    }

    pub fn save_history(&self) {
        if let Ok(bytes) = serde_json::to_vec(&self.items) {
            Self::atomic_write(&self.history_file, &bytes);
            Self::atomic_write(&self.history_backup_file, &bytes);
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

    /// 跨处选段续接复制（`Ctrl+Alt+C` / `Ctrl+Shift+C`）：将新选段无缝追加至最近一条文本记录末尾
    pub fn append_to_latest_text(&mut self, fragment: &str, separator: &str) -> Option<String> {
        let clean_frag = fragment.trim_matches(['\r', '\n']);
        if clean_frag.trim().is_empty() {
            return None;
        }
        if let Some(pos) = self.items.iter().position(|it| {
            matches!(it.kind, ClipContentType::Text | ClipContentType::Link) && it.text.is_some()
        }) {
            let mut target = self.items.remove(pos);
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
            target.content_hash = format!("{}:{hash}", if is_link { "link" } else { "text" });
            target.text = Some(merged.clone());
            target.created_unix_secs = now_unix_secs();
            self.items.insert(0, target);
            Self::sort_items(&mut self.items);
            self.save_history();
            Some(merged)
        } else {
            let item = ClipItem::new_text(clean_frag.to_string(), None);
            let out = item.text.clone();
            self.insert_or_promote(item);
            out
        }
    }

    /// 搜索框 `> 备注 :: 正文` 一行闪念速记入库
    pub fn capture_quick_note(&mut self, intent: &QuickCaptureIntent) -> Option<String> {
        let body = intent.body.trim();
        if body.is_empty() {
            return None;
        }
        let mut item = ClipItem::new_text(body.to_string(), Some("闪念速记".to_string()));
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

    /// 修改卡片备注别名：输入非空备注时自动开启收藏保护并智能推断分组，防止被历史滚动挤掉
    pub fn set_custom_alias(&mut self, item_id: &str, raw_alias: &str) -> Option<bool> {
        let item = self.items.iter_mut().find(|it| it.id == item_id)?;
        let clean = raw_alias.trim();
        let mut auto_pinned = false;
        if clean.is_empty() {
            item.custom_alias = None;
        } else {
            item.custom_alias = Some(clean.to_string());
            if !item.is_pinned {
                item.is_pinned = true;
                auto_pinned = true;
                self.pending_otp_expirations.retain(|(id, _)| id != item_id);
            }
            if item.pin_category.is_none() {
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
        let is_cmd =
            extract_suggestion_payload(query).is_some() || parse_quick_capture(query).is_some();
        let effective_q = if is_cmd { "" } else { query.trim() };

        let mut matched: Vec<usize> = self
            .items
            .iter()
            .enumerate()
            .filter(|(_, item)| {
                let tab_ok = match tab {
                    ClipFilterTab::All => true,
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
        mut actions: Vec<QuickAction>,
    ) -> Vec<QuickAction> {
        if actions.len() <= 1 || self.config.minimal_mode_enabled {
            return actions;
        }
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
        if lower.contains("自动粘贴") || lower.contains("直接粘贴") {
            self.config.auto_paste_enabled = !is_off;
            effects.push(if !is_off {
                "已开启选中自动键入粘贴".to_string()
            } else {
                "已改为仅复制不自动粘贴".to_string()
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

        self.save_config();

        let summary = if effects.is_empty() {
            "建议已归档至本地进化台账，将在后续习惯迭代中优先适配".to_string()
        } else {
            format!("已采纳并即时生效：{}", effects.join("；"))
        };

        let mut logs: Vec<UserSuggestionRecord> = fs::read(&self.suggestions_file)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        logs.push(UserSuggestionRecord {
            created_unix_secs: now_unix_secs(),
            suggestion: text.to_string(),
            applied_summary: summary.clone(),
        });
        if let Ok(bytes) = serde_json::to_vec_pretty(&logs) {
            Self::atomic_write(&self.suggestions_file, &bytes);
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
        self.delete_by_id_with_undo(item_id, true);
    }

    fn delete_by_id_with_undo(&mut self, item_id: &str, allow_undo: bool) {
        self.pending_otp_expirations.retain(|(id, _)| id != item_id);
        self.paste_queue_ids.retain(|id| id != item_id);
        if let Some(pos) = self.items.iter().position(|it| it.id == item_id) {
            let removed = self.items.remove(pos);
            let mut img_bytes = None;
            if let Some(img) = &removed.image_file_name {
                let p = self.images_dir.join(img);
                if allow_undo {
                    img_bytes = fs::read(&p).ok();
                }
                let _ = fs::remove_file(p);
            }
            if allow_undo {
                self.push_undo_snapshot(vec![(removed, img_bytes)]);
            }
            self.save_history();
        }
    }

    pub fn clear_unpinned(&mut self) {
        let mut kept = Vec::new();
        let mut removed_batch = Vec::new();
        for item in self.items.drain(..) {
            if item.is_pinned {
                kept.push(item);
            } else {
                let mut img_bytes = None;
                if let Some(img) = &item.image_file_name {
                    let p = self.images_dir.join(img);
                    if removed_batch.len() < 32 {
                        img_bytes = fs::read(&p).ok();
                    }
                    let _ = fs::remove_file(p);
                }
                self.paste_queue_ids.retain(|id| id != &item.id);
                self.pending_otp_expirations
                    .retain(|(id, _)| id != &item.id);
                removed_batch.push((item, img_bytes));
            }
        }
        self.items = kept;
        if !removed_batch.is_empty() {
            self.push_undo_snapshot(removed_batch);
        }
        self.save_history();
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

        if self.pending_otp_expirations.is_empty() {
            return 0;
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

        let mut count = 0;
        for id in expired_ids {
            if let Some(it) = self.items.iter().find(|i| i.id == id) {
                if !it.is_pinned && !self.config.minimal_mode_enabled && self.config.auto_expire_otp
                {
                    self.delete_by_id_with_undo(&id, false);
                    count += 1;
                }
            }
        }
        count
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

    pub fn pinned_count(&self) -> usize {
        self.items.iter().filter(|it| it.is_pinned).count()
    }

    pub fn export_archive_to_file(&self, dest: &Path) -> Result<usize, ArchiveBackupError> {
        let data = export_pinned_archive_data(
            &self.items,
            &self.images_dir,
            env!("CARGO_PKG_VERSION"),
            Self::edition_key(),
        )?;
        fs::write(dest, &data).map_err(|_| ArchiveBackupError::InvalidArchiveFormat)?;
        Ok(self.pinned_count())
    }

    pub fn import_archive_from_file(
        &mut self,
        src: &Path,
    ) -> Result<ArchiveImportSummary, ArchiveBackupError> {
        let data = fs::read(src).map_err(|_| ArchiveBackupError::InvalidArchiveFormat)?;
        let (mut merged, summary) = merge_archive_data(&data, &self.items, &self.images_dir)?;
        Self::sort_items(&mut merged);
        self.items = merged;
        self.save_history();
        Ok(summary)
    }

    pub fn trim_history_if_needed(&mut self) {
        let max_unpinned = self.config.max_history_count.max(10);
        let mut unpinned_seen = 0usize;
        let mut retained = Vec::with_capacity(self.items.len());
        for item in self.items.drain(..) {
            if item.is_pinned {
                retained.push(item);
            } else if unpinned_seen < max_unpinned {
                unpinned_seen += 1;
                retained.push(item);
            } else if let Some(img) = item.image_file_name {
                let _ = fs::remove_file(self.images_dir.join(img));
            }
        }
        self.items = retained;
    }

    fn sort_items(list: &mut [ClipItem]) {
        list.sort_by(|a, b| b.created_unix_secs.cmp(&a.created_unix_secs));
    }
}
