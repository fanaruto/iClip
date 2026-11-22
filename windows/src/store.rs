use crate::archive::{
    export_pinned_archive_data, merge_archive_data, ArchiveBackupError, ArchiveImportSummary,
};
use crate::engines::is_otp_message;
use crate::model::{now_unix_secs, ClipContentType, ClipFilterTab, ClipItem};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreConfig {
    pub minimal_mode_enabled: bool,
    pub auto_paste_enabled: bool,
    pub auto_expire_otp: bool,
    pub auto_clean_tracking_url: bool,
    pub queue_auto_tab: bool,
    pub max_history_count: usize,
}

impl Default for StoreConfig {
    fn default() -> Self {
        Self {
            minimal_mode_enabled: false,
            auto_paste_enabled: true,
            auto_expire_otp: true,
            auto_clean_tracking_url: false,
            queue_auto_tab: false,
            max_history_count: 200,
        }
    }
}

/// 跨平台零冗余剪贴板核心仓库（支持原子持久化、FIFO 队列、极简模式与 OTP 30 秒阅后即焚）
pub struct ClipboardStore {
    pub items: Vec<ClipItem>,
    pub config: StoreConfig,
    pub is_paused: bool,
    pub queue_mode_active: bool,
    pub paste_queue_ids: VecDeque<String>,
    pub pending_otp_expirations: Vec<(String, u64)>,
    pub data_dir: PathBuf,
    pub images_dir: PathBuf,
    history_file: PathBuf,
    config_file: PathBuf,
}

impl ClipboardStore {
    pub fn new(data_dir: PathBuf) -> Self {
        let images_dir = data_dir.join("images");
        let history_file = data_dir.join("history.json");
        let config_file = data_dir.join("config.json");
        let _ = fs::create_dir_all(&images_dir);

        let config = fs::read(&config_file)
            .ok()
            .and_then(|b| serde_json::from_slice::<StoreConfig>(&b).ok())
            .unwrap_or_default();

        let mut items = fs::read(&history_file)
            .ok()
            .and_then(|b| serde_json::from_slice::<Vec<ClipItem>>(&b).ok())
            .unwrap_or_default();
        Self::sort_items(&mut items);

        Self {
            items,
            config,
            is_paused: false,
            queue_mode_active: false,
            paste_queue_ids: VecDeque::new(),
            pending_otp_expirations: Vec::new(),
            data_dir,
            images_dir,
            history_file,
            config_file,
        }
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
            let tmp = self.config_file.with_extension("json.tmp");
            if fs::write(&tmp, &bytes).is_ok() {
                let _ = fs::rename(&tmp, &self.config_file);
            }
        }
    }

    pub fn save_history(&self) {
        if let Ok(bytes) = serde_json::to_vec(&self.items) {
            let tmp = self.history_file.with_extension("json.tmp");
            if fs::write(&tmp, &bytes).is_ok() {
                let _ = fs::rename(&tmp, &self.history_file);
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

    pub fn filtered_indices(&self, tab: ClipFilterTab, query: &str) -> Vec<usize> {
        self.items
            .iter()
            .enumerate()
            .filter(|(_, item)| {
                let tab_ok = match tab {
                    ClipFilterTab::All => true,
                    ClipFilterTab::Pinned => item.is_pinned,
                    ClipFilterTab::Text => item.kind == ClipContentType::Text,
                    ClipFilterTab::Link => item.kind == ClipContentType::Link,
                    ClipFilterTab::Image => item.kind == ClipContentType::Image,
                    ClipFilterTab::File => item.kind == ClipContentType::File,
                };
                tab_ok && item.matches_query(query)
            })
            .map(|(i, _)| i)
            .collect()
    }

    pub fn toggle_pin(&mut self, item_id: &str) -> Option<bool> {
        let item = self.items.iter_mut().find(|it| it.id == item_id)?;
        item.is_pinned = !item.is_pinned;
        let pinned = item.is_pinned;
        if pinned {
            self.pending_otp_expirations.retain(|(id, _)| id != item_id);
        } else {
            item.pin_category = None;
        }
        Self::sort_items(&mut self.items);
        self.save_history();
        Some(pinned)
    }

    pub fn delete_by_id(&mut self, item_id: &str) {
        self.pending_otp_expirations.retain(|(id, _)| id != item_id);
        self.paste_queue_ids.retain(|id| id != item_id);
        if let Some(pos) = self.items.iter().position(|it| it.id == item_id) {
            let removed = self.items.remove(pos);
            if let Some(img) = removed.image_file_name {
                let _ = fs::remove_file(self.images_dir.join(img));
            }
            self.save_history();
        }
    }

    pub fn clear_unpinned(&mut self) {
        let mut kept = Vec::new();
        for item in self.items.drain(..) {
            if item.is_pinned {
                kept.push(item);
            } else {
                if let Some(img) = item.image_file_name {
                    let _ = fs::remove_file(self.images_dir.join(img));
                }
                self.paste_queue_ids.retain(|id| id != &item.id);
                self.pending_otp_expirations.retain(|(id, _)| id != &item.id);
            }
        }
        self.items = kept;
        self.save_history();
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

    /// 清理已到期的一次性验证码记录，返回清理条数
    pub fn sweep_expired_otps(&mut self, current_unix_secs: u64) -> usize {
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
                if !it.is_pinned && !self.config.minimal_mode_enabled && self.config.auto_expire_otp {
                    self.delete_by_id(&id);
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

    fn trim_history_if_needed(&mut self) {
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
