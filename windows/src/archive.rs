use crate::model::{
    generate_pseudo_uuid, iso8601_to_unix_secs, now_unix_secs, unix_secs_to_iso8601,
    ClipContentType, ClipItem, PinCategory,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

pub const ARCHIVE_FORMAT_ID: &str = "com.qingjian.iclip.archive";
pub const CURRENT_SCHEMA_VERSION: u32 = 1;
const MAX_EMBEDDED_IMAGE_BYTES: usize = 12 * 1024 * 1024;
pub const MAX_ARCHIVE_INPUT_BYTES: usize = 64 * 1024 * 1024;
const MAX_ARCHIVE_ENTRIES: usize = 5_000;

/// 与 macOS `ArchivedClipEntry` 100% 字节级兼容的跨平台收藏快照（Mac 导出的 .iclip 可直接在 Windows 导入，反之亦然）
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArchivedClipEntry {
    #[serde(rename = "type")]
    pub kind: ClipContentType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_height: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ocr_text: Option<String>,
    #[serde(rename = "embeddedPNGBase64", skip_serializing_if = "Option::is_none")]
    pub embedded_png_base64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_paths: Option<Vec<String>>,
    pub content_hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_app_name: Option<String>,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pin_category: Option<PinCategory>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_alias: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_todo_item: Option<bool>,
}

/// `.iclip` 收藏资产归档包根结构
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinnedArchiveBundle {
    pub format: String,
    pub schema_version: u32,
    pub app_version: String,
    pub exported_edition: String,
    pub exported_at: String,
    pub entries: Vec<ArchivedClipEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchiveImportSummary {
    pub imported_new_count: usize,
    pub updated_existing_count: usize,
    pub total_in_bundle: usize,
    pub source_format_label: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArchiveBackupError {
    NoPinnedItems,
    ArchiveTooLarge,
    PassphraseRequiredOrIncorrect,
    InvalidArchiveFormat,
    UnsupportedSchemaVersion(u32),
}

impl ArchiveBackupError {
    pub fn message(&self) -> String {
        match self {
            Self::NoPinnedItems => "当前暂无已固定的收藏记录，请先固定常用话术或模板".to_string(),
            Self::ArchiveTooLarge => {
                "归档文件体积超过 64 MB 安全上限，已拦截加载以保护内存稳定".to_string()
            }
            Self::PassphraseRequiredOrIncorrect => {
                "该归档受口令加密保护，口令缺失或不正确".to_string()
            }
            Self::InvalidArchiveFormat => {
                "无法解析该文件，请选择有效的 .iclip 归档或 Raycast / Maccy / CSV 常用语文件"
                    .to_string()
            }
            Self::UnsupportedSchemaVersion(v) => {
                format!("该归档包版本 (v{v}) 高于当前客户端，请先升级 iClip")
            }
        }
    }
}

/// 导出所有 `is_pinned == true` 的记录为 `.iclip` UTF-8 JSON 数据（绝不夹带未固定临时隐私记录）
pub fn export_pinned_archive_data(
    items: &[ClipItem],
    images_dir: &Path,
    app_version: &str,
    edition_key: &str,
) -> Result<Vec<u8>, ArchiveBackupError> {
    let pinned: Vec<&ClipItem> = items.iter().filter(|it| it.is_pinned).collect();
    if pinned.is_empty() {
        return Err(ArchiveBackupError::NoPinnedItems);
    }

    let entries = pinned
        .into_iter()
        .map(|item| {
            let mut embedded_png_base64 = None;
            if item.kind == ClipContentType::Image {
                if let Some(name) = &item.image_file_name {
                    if let Some(bytes) =
                        crate::security::read_decrypted_image_from_dir(images_dir, name)
                    {
                        if bytes.len() <= MAX_EMBEDDED_IMAGE_BYTES {
                            embedded_png_base64 = Some(BASE64.encode(&bytes));
                        }
                    }
                }
            }
            ArchivedClipEntry {
                kind: item.kind,
                text: item.text.clone(),
                image_width: item.image_width,
                image_height: item.image_height,
                ocr_text: item.ocr_text.clone(),
                embedded_png_base64,
                file_paths: item.file_paths.clone(),
                content_hash: item.content_hash.clone(),
                source_app_name: item.source_app_name.clone(),
                created_at: unix_secs_to_iso8601(item.created_unix_secs),
                pin_category: item.pin_category,
                custom_alias: item.custom_alias.clone(),
                is_todo_item: item.is_todo_item,
            }
        })
        .collect();

    let bundle = PinnedArchiveBundle {
        format: ARCHIVE_FORMAT_ID.to_string(),
        schema_version: CURRENT_SCHEMA_VERSION,
        app_version: app_version.to_string(),
        exported_edition: edition_key.to_string(),
        exported_at: unix_secs_to_iso8601(now_unix_secs()),
        entries,
    };

    serde_json::to_vec_pretty(&bundle).map_err(|_| ArchiveBackupError::InvalidArchiveFormat)
}

/// 非破坏性幂等去重合并导入（支持直接读取 macOS 版导出的 .iclip 文件）
pub fn merge_archive_data(
    data: &[u8],
    existing_items: &[ClipItem],
    images_dir: &Path,
) -> Result<(Vec<ClipItem>, ArchiveImportSummary), ArchiveBackupError> {
    merge_archive_data_with_hint(data, existing_items, images_dir, None)
}

pub fn merge_archive_data_with_hint(
    data: &[u8],
    existing_items: &[ClipItem],
    images_dir: &Path,
    ext_hint: Option<&str>,
) -> Result<(Vec<ClipItem>, ArchiveImportSummary), ArchiveBackupError> {
    merge_archive_data_full(data, existing_items, images_dir, None, ext_hint)
}

pub fn merge_archive_data_full(
    data: &[u8],
    existing_items: &[ClipItem],
    images_dir: &Path,
    passphrase: Option<&str>,
    ext_hint: Option<&str>,
) -> Result<(Vec<ClipItem>, ArchiveImportSummary), ArchiveBackupError> {
    if data.len() > MAX_ARCHIVE_INPUT_BYTES {
        return Err(ArchiveBackupError::ArchiveTooLarge);
    }
    let decrypted_buf: Option<Vec<u8>>;
    let effective_data: &[u8] = if crate::security::is_encrypted_archive_bytes(data) {
        let Some(pw) = passphrase.map(str::trim).filter(|s| !s.is_empty()) else {
            return Err(ArchiveBackupError::PassphraseRequiredOrIncorrect);
        };
        let Some(opened) = crate::security::open_encrypted_archive_bytes(data, pw) else {
            return Err(ArchiveBackupError::PassphraseRequiredOrIncorrect);
        };
        if opened.len() > MAX_ARCHIVE_INPUT_BYTES {
            return Err(ArchiveBackupError::ArchiveTooLarge);
        }
        decrypted_buf = Some(opened);
        decrypted_buf.as_deref().unwrap()
    } else {
        data
    };

    let bundle: PinnedArchiveBundle =
        match serde_json::from_slice::<PinnedArchiveBundle>(effective_data) {
            Ok(b) if b.format == ARCHIVE_FORMAT_ID => b,
            Ok(_) => return Err(ArchiveBackupError::InvalidArchiveFormat),
            Err(_) => {
                if let Some((cands, fmt_label)) =
                    crate::security::parse_external_competitor_data(effective_data, ext_hint)
                {
                    return Ok(merge_external_candidates(
                        &cands,
                        &fmt_label,
                        existing_items,
                    ));
                }
                return Err(ArchiveBackupError::InvalidArchiveFormat);
            }
        };

    if bundle.schema_version > CURRENT_SCHEMA_VERSION {
        return Err(ArchiveBackupError::UnsupportedSchemaVersion(
            bundle.schema_version,
        ));
    }

    let _ = fs::create_dir_all(images_dir);

    let mut working = existing_items.to_vec();
    let mut imported_new = 0usize;
    let mut updated_existing = 0usize;

    for entry in bundle.entries.iter().take(MAX_ARCHIVE_ENTRIES) {
        if let Some(existing) = working
            .iter_mut()
            .find(|it| it.content_hash == entry.content_hash)
        {
            let mut changed = false;
            if !existing.is_pinned {
                existing.is_pinned = true;
                changed = true;
            }
            if entry.is_todo_item == Some(true) && !existing.is_todo() {
                existing.set_todo(true);
                changed = true;
            }
            if existing.pin_category.is_none() && entry.pin_category.is_some() {
                existing.pin_category = entry.pin_category;
                changed = true;
            }
            let local_alias_empty = existing
                .custom_alias
                .as_deref()
                .map(|s| s.trim().is_empty())
                .unwrap_or(true);
            if local_alias_empty {
                if let Some(alias) = &entry.custom_alias {
                    if !alias.trim().is_empty() {
                        existing.custom_alias = Some(alias.clone());
                        changed = true;
                    }
                }
            }
            if existing.ocr_text.as_deref().unwrap_or("").is_empty() {
                if let Some(ocr) = &entry.ocr_text {
                    if !ocr.is_empty() {
                        existing.ocr_text = Some(ocr.clone());
                        existing.ocr_checked = Some(true);
                        changed = true;
                    }
                }
            }
            if existing.kind == ClipContentType::Image {
                if let Some(b64) = &entry.embedded_png_base64 {
                    if b64.len() <= (MAX_EMBEDDED_IMAGE_BYTES * 4 / 3 + 64) {
                        if let Ok(png_bytes) = BASE64.decode(b64) {
                            if png_bytes.len() <= MAX_EMBEDDED_IMAGE_BYTES
                                && is_valid_raster_image_header(&png_bytes)
                            {
                                let missing = existing
                                    .image_file_name
                                    .as_ref()
                                    .map(|n| !images_dir.join(n).exists())
                                    .unwrap_or(true);
                                if missing {
                                    let file_name = format!(
                                        "{}.png",
                                        generate_pseudo_uuid(&entry.content_hash)
                                    );
                                    if crate::security::write_encrypted_image_to_dir(
                                        images_dir, &file_name, &png_bytes,
                                    )
                                    .is_ok()
                                    {
                                        existing.image_file_name = Some(file_name);
                                        changed = true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if changed {
                updated_existing += 1;
            }
        } else {
            let mut saved_image_name = None;
            if entry.kind == ClipContentType::Image {
                let Some(b64) = &entry.embedded_png_base64 else {
                    continue;
                };
                if b64.len() > (MAX_EMBEDDED_IMAGE_BYTES * 4 / 3 + 64) {
                    continue;
                }
                let Ok(png_bytes) = BASE64.decode(b64) else {
                    continue;
                };
                if png_bytes.len() > MAX_EMBEDDED_IMAGE_BYTES
                    || !is_valid_raster_image_header(&png_bytes)
                {
                    continue;
                }
                let file_name = format!("{}.png", generate_pseudo_uuid(&entry.content_hash));
                if crate::security::write_encrypted_image_to_dir(images_dir, &file_name, &png_bytes)
                    .is_err()
                {
                    continue;
                }
                saved_image_name = Some(file_name);
            }

            if entry.kind == ClipContentType::File {
                if let Some(paths) = &entry.file_paths {
                    let has_traversal = paths.iter().any(|p| p.contains(".."));
                    if has_traversal
                        || crate::security::classify_sensitive_file_paths(paths).is_some()
                    {
                        continue;
                    }
                }
            }

            let sanitized_text = entry.text.as_ref().map(|raw_t| {
                if matches!(
                    crate::security::inspect_clipboard_poison(raw_t),
                    Some(crate::security::PoisonThreatKind::PastejackingOrBidi(_))
                ) {
                    let clean = crate::security::sanitize_clipboard_poison(raw_t);
                    if clean.is_empty() {
                        raw_t.clone()
                    } else {
                        clean
                    }
                } else {
                    raw_t.clone()
                }
            });
            let sanitized_alias = entry.custom_alias.as_ref().map(|raw_a| {
                if matches!(
                    crate::security::inspect_clipboard_poison(raw_a),
                    Some(crate::security::PoisonThreatKind::PastejackingOrBidi(_))
                ) {
                    crate::security::sanitize_clipboard_poison(raw_a)
                } else {
                    raw_a.clone()
                }
            });
            let sanitized_ocr = entry.ocr_text.as_ref().map(|raw_o| {
                if matches!(
                    crate::security::inspect_clipboard_poison(raw_o),
                    Some(crate::security::PoisonThreatKind::PastejackingOrBidi(_))
                ) {
                    let clean = crate::security::sanitize_clipboard_poison(raw_o);
                    if clean.is_empty() {
                        raw_o.clone()
                    } else {
                        clean
                    }
                } else {
                    raw_o.clone()
                }
            });
            let effective_hash = if sanitized_text.as_deref() != entry.text.as_deref() {
                if let Some(clean_t) = &sanitized_text {
                    ClipItem::new_text(clean_t.clone(), None).content_hash
                } else {
                    entry.content_hash.clone()
                }
            } else {
                entry.content_hash.clone()
            };

            let restored = ClipItem {
                id: generate_pseudo_uuid(&effective_hash),
                kind: entry.kind,
                text: sanitized_text,
                image_file_name: saved_image_name,
                image_width: entry.image_width,
                image_height: entry.image_height,
                ocr_text: sanitized_ocr.clone(),
                ocr_checked: sanitized_ocr.as_ref().map(|_| true),
                file_paths: entry.file_paths.clone(),
                content_hash: effective_hash,
                source_app_name: entry.source_app_name.clone(),
                created_unix_secs: iso8601_to_unix_secs(&entry.created_at),
                is_pinned: true,
                pin_category: entry.pin_category,
                custom_alias: sanitized_alias,
                is_todo_item: entry.is_todo_item,
                todo_completed_unix_secs: None,
                burn_after_paste: None,
            };
            working.push(restored);
            imported_new += 1;
        }
    }

    let summary = ArchiveImportSummary {
        imported_new_count: imported_new,
        updated_existing_count: updated_existing,
        total_in_bundle: bundle.entries.len(),
        source_format_label: "iClip 归档".to_string(),
    };
    Ok((working, summary))
}

fn merge_external_candidates(
    candidates: &[crate::security::ExternalImportCandidate],
    format_label: &str,
    existing_items: &[ClipItem],
) -> (Vec<ClipItem>, ArchiveImportSummary) {
    let mut working = existing_items.to_vec();
    let mut imported_new = 0usize;
    let mut updated_existing = 0usize;

    for cand in candidates {
        let safe_body = if matches!(
            crate::security::inspect_clipboard_poison(&cand.text),
            Some(crate::security::PoisonThreatKind::PastejackingOrBidi(_))
        ) {
            let clean = crate::security::sanitize_clipboard_poison(&cand.text);
            if clean.is_empty() {
                cand.text.clone()
            } else {
                clean
            }
        } else {
            cand.text.clone()
        };
        let safe_alias = cand.alias.as_ref().map(|raw_a| {
            if matches!(
                crate::security::inspect_clipboard_poison(raw_a),
                Some(crate::security::PoisonThreatKind::PastejackingOrBidi(_))
            ) {
                crate::security::sanitize_clipboard_poison(raw_a)
            } else {
                raw_a.clone()
            }
        });
        let trimmed = safe_body.trim();
        if trimmed.is_empty() {
            continue;
        }
        let mut temp_item = ClipItem::new_text(safe_body.clone(), Some(cand.source_label.clone()));
        let inferred_cat = PinCategory::infer(safe_alias.as_deref(), Some(&safe_body));

        if let Some(existing) = working
            .iter_mut()
            .find(|it| it.content_hash == temp_item.content_hash)
        {
            let mut changed = false;
            if !existing.is_pinned {
                existing.is_pinned = true;
                changed = true;
            }
            let alias_empty = existing
                .custom_alias
                .as_deref()
                .map(|s| s.trim().is_empty())
                .unwrap_or(true);
            if alias_empty {
                if let Some(al) = &safe_alias {
                    existing.custom_alias = Some(al.clone());
                    changed = true;
                }
            }
            if existing.pin_category.is_none() && inferred_cat.is_some() {
                existing.pin_category = inferred_cat;
                changed = true;
            }
            if changed {
                updated_existing += 1;
            }
        } else {
            temp_item.is_pinned = true;
            temp_item.custom_alias = safe_alias;
            temp_item.pin_category = inferred_cat;
            working.push(temp_item);
            imported_new += 1;
        }
    }

    (
        working,
        ArchiveImportSummary {
            imported_new_count: imported_new,
            updated_existing_count: updated_existing,
            total_in_bundle: candidates.len(),
            source_format_label: format_label.to_string(),
        },
    )
}

pub fn is_valid_raster_image_header(bytes: &[u8]) -> bool {
    if bytes.len() < 12 {
        return false;
    }
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return true;
    }
    if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
        return true;
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return true;
    }
    if &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return true;
    }
    false
}
