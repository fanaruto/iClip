use regex_lite::Regex;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::Path;
use std::sync::OnceLock;

pub const VAULT_MAGIC: &[u8; 8] = b"ICLPWIN1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SensitiveSecretKind {
    ApiKey,
    PrivateKey,
    JwtToken,
    ConnectionSecret,
}

impl SensitiveSecretKind {
    pub fn badge_title(self) -> &'static str {
        match self {
            Self::ApiKey => "密钥保护",
            Self::PrivateKey => "私钥保护",
            Self::JwtToken => "令牌保护",
            Self::ConnectionSecret => "凭据保护",
        }
    }
}

// ============================================================================
// 1. 本机零信任透明静态认证加密（Windows DPAPI 保护主密钥 + Encrypt-then-HMAC-SHA256）
// ============================================================================

#[cfg(target_os = "windows")]
mod win_dpapi {
    use std::ptr::{null, null_mut};

    #[repr(C)]
    struct CryptoApiBlob {
        cb_data: u32,
        pb_data: *mut u8,
    }

    const CRYPTPROTECT_UI_FORBIDDEN: u32 = 0x1;

    #[link(name = "crypt32")]
    extern "system" {
        fn CryptProtectData(
            p_data_in: *const CryptoApiBlob,
            sz_data_descr: *const u16,
            p_optional_entropy: *const CryptoApiBlob,
            pv_reserved: *const core::ffi::c_void,
            p_prompt_struct: *const core::ffi::c_void,
            dw_flags: u32,
            p_data_out: *mut CryptoApiBlob,
        ) -> i32;

        fn CryptUnprotectData(
            p_data_in: *const CryptoApiBlob,
            ppsz_data_descr: *mut *mut u16,
            p_optional_entropy: *const CryptoApiBlob,
            pv_reserved: *const core::ffi::c_void,
            p_prompt_struct: *const core::ffi::c_void,
            dw_flags: u32,
            p_data_out: *mut CryptoApiBlob,
        ) -> i32;
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn LocalFree(h_mem: *mut core::ffi::c_void) -> *mut core::ffi::c_void;
    }

    pub fn protect_bytes(plain: &[u8]) -> Option<Vec<u8>> {
        if plain.is_empty() {
            return None;
        }
        unsafe {
            let in_blob = CryptoApiBlob {
                cb_data: plain.len() as u32,
                pb_data: plain.as_ptr() as *mut u8,
            };
            let mut out_blob = CryptoApiBlob {
                cb_data: 0,
                pb_data: null_mut(),
            };
            let ok = CryptProtectData(
                &in_blob,
                null(),
                null(),
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out_blob,
            );
            if ok == 0 || out_blob.pb_data.is_null() {
                return None;
            }
            let out =
                std::slice::from_raw_parts(out_blob.pb_data, out_blob.cb_data as usize).to_vec();
            let _ = LocalFree(out_blob.pb_data as *mut core::ffi::c_void);
            Some(out)
        }
    }

    pub fn unprotect_bytes(cipher: &[u8]) -> Option<Vec<u8>> {
        if cipher.is_empty() {
            return None;
        }
        unsafe {
            let in_blob = CryptoApiBlob {
                cb_data: cipher.len() as u32,
                pb_data: cipher.as_ptr() as *mut u8,
            };
            let mut out_blob = CryptoApiBlob {
                cb_data: 0,
                pb_data: null_mut(),
            };
            let ok = CryptUnprotectData(
                &in_blob,
                null_mut(),
                null(),
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out_blob,
            );
            if ok == 0 || out_blob.pb_data.is_null() {
                return None;
            }
            let out =
                std::slice::from_raw_parts(out_blob.pb_data, out_blob.cb_data as usize).to_vec();
            let _ = LocalFree(out_blob.pb_data as *mut core::ffi::c_void);
            Some(out)
        }
    }
}

fn generate_entropy_32(seed_hint: &Path) -> [u8; 32] {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = std::process::id();
    let addr = seed_hint as *const Path as *const u8 as usize;
    let mut h = Sha256::new();
    h.update(b"iclip-vault-entropy-v1|");
    h.update(nanos.to_le_bytes());
    h.update(pid.to_le_bytes());
    h.update(addr.to_le_bytes());
    h.update(seed_hint.to_string_lossy().as_bytes());
    let digest = h.finalize();
    let mut out = [0u8; 32];
    out.copy_from_slice(&digest);
    out
}

/// 加载或静默初始化与数据目录绑定的 256-bit 主密钥（Windows 下经系统内核 DPAPI 封装）
pub fn load_or_create_vault_key(data_dir: &Path) -> [u8; 32] {
    let key_path = data_dir.join("vault.dpapi");
    if let Ok(raw) = fs::read(&key_path) {
        #[cfg(target_os = "windows")]
        if let Some(unprotected) = win_dpapi::unprotect_bytes(&raw) {
            if unprotected.len() == 32 {
                let mut k = [0u8; 32];
                k.copy_from_slice(&unprotected);
                return k;
            }
        }
        #[cfg(not(target_os = "windows"))]
        if raw.len() == 32 {
            let mut k = [0u8; 32];
            k.copy_from_slice(&raw);
            return k;
        }
    }

    let fresh = generate_entropy_32(data_dir);
    let _ = fs::create_dir_all(data_dir);
    #[cfg(target_os = "windows")]
    if let Some(protected) = win_dpapi::protect_bytes(&fresh) {
        let _ = fs::write(&key_path, protected);
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = fs::write(&key_path, fresh);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&key_path, fs::Permissions::from_mode(0o600));
        }
    }
    fresh
}

fn hmac_sha256(key: &[u8; 32], message: &[u8]) -> [u8; 32] {
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5Cu8; 64];
    for i in 0..32 {
        ipad[i] ^= key[i];
        opad[i] ^= key[i];
    }
    let mut inner = Sha256::new();
    inner.update(ipad);
    inner.update(message);
    let inner_digest = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(opad);
    outer.update(inner_digest);
    let final_digest = outer.finalize();
    let mut out = [0u8; 32];
    out.copy_from_slice(&final_digest);
    out
}

fn derive_subkeys(master_key: &[u8; 32], nonce: &[u8; 16]) -> ([u8; 32], [u8; 32]) {
    let enc_key = hmac_sha256(master_key, &[b"enc|".as_slice(), nonce.as_slice()].concat());
    let mac_key = hmac_sha256(master_key, &[b"mac|".as_slice(), nonce.as_slice()].concat());
    (enc_key, mac_key)
}

fn apply_sha256_ctr_stream(enc_key: &[u8; 32], nonce: &[u8; 16], buf: &mut [u8]) {
    let mut counter: u64 = 0;
    for chunk in buf.chunks_mut(32) {
        let mut h = Sha256::new();
        h.update(enc_key);
        h.update(nonce);
        h.update(counter.to_le_bytes());
        let stream = h.finalize();
        for (b, s) in chunk.iter_mut().zip(stream.iter()) {
            *b ^= *s;
        }
        counter = counter.wrapping_add(1);
    }
}

/// 封装明文 JSON 为 `ICLPWIN1` + 16B Nonce + Ciphertext + 32B HMAC-SHA256 Tag
pub fn seal_vault_bytes(plain: &[u8], master_key: &[u8; 32], seed_dir: &Path) -> Vec<u8> {
    let entropy = generate_entropy_32(seed_dir);
    let mut nonce = [0u8; 16];
    nonce.copy_from_slice(&entropy[..16]);

    let (enc_key, mac_key) = derive_subkeys(master_key, &nonce);
    let mut ciphertext = plain.to_vec();
    apply_sha256_ctr_stream(&enc_key, &nonce, &mut ciphertext);

    let mut out = Vec::with_capacity(8 + 16 + ciphertext.len() + 32);
    out.extend_from_slice(VAULT_MAGIC);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ciphertext);

    let tag = hmac_sha256(&mac_key, &out);
    out.extend_from_slice(&tag);
    out
}

/// 解密本地快照（返回 `(明文字节, 是否为历史遗留未加密明文)`；篡改密文将严格返回 `None` 触发备份自愈）
pub fn open_vault_bytes(raw: &[u8], master_key: &[u8; 32]) -> Option<(Vec<u8>, bool)> {
    if raw.is_empty() {
        return None;
    }
    if raw.starts_with(VAULT_MAGIC) {
        if raw.len() < 8 + 16 + 32 {
            return None;
        }
        let body_end = raw.len() - 32;
        let expected_tag = &raw[body_end..];
        let mut nonce = [0u8; 16];
        nonce.copy_from_slice(&raw[8..24]);

        let (enc_key, mac_key) = derive_subkeys(master_key, &nonce);
        let computed_tag = hmac_sha256(&mac_key, &raw[..body_end]);

        // 恒定时间比较防止侧信道泄露
        let mut diff = 0u8;
        for (a, b) in expected_tag.iter().zip(computed_tag.iter()) {
            diff |= a ^ b;
        }
        if diff != 0 {
            return None;
        }

        let mut plain = raw[24..body_end].to_vec();
        apply_sha256_ctr_stream(&enc_key, &nonce, &mut plain);
        return Some((plain, false));
    }

    // 平滑兼容历史遗留未加密 UTF-8 JSON 数组
    let first_non_ws = raw
        .iter()
        .copied()
        .find(|b| !matches!(b, b' ' | b'\n' | b'\r' | b'\t'));
    if first_non_ws == Some(b'[') {
        return Some((raw.to_vec(), true));
    }
    None
}

// ============================================================================
// 2. 离线微秒级敏感凭据嗅探与防肩窥圆点雾化遮罩（零高度抖动）
// ============================================================================

pub fn classify_sensitive_text(raw: &str) -> Option<SensitiveSecretKind> {
    if raw.is_empty() {
        return None;
    }
    let sample = if raw.len() > 2048 {
        let mut end = 2048;
        while end > 0 && !raw.is_char_boundary(end) {
            end -= 1;
        }
        &raw[..end]
    } else {
        raw
    };

    if sample.contains("-----BEGIN ") && sample.contains("PRIVATE KEY-----") {
        return Some(SensitiveSecretKind::PrivateKey);
    }

    static API_RE: OnceLock<Regex> = OnceLock::new();
    static JWT_RE: OnceLock<Regex> = OnceLock::new();
    static CONN_RE: OnceLock<Regex> = OnceLock::new();
    static BEARER_RE: OnceLock<Regex> = OnceLock::new();

    let api_re = API_RE.get_or_init(|| {
        Regex::new(r"\b(?:sk-(?:proj-|ant-|live_|test_)?[A-Za-z0-9_-]{18,}|gh[pousr]_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{28,}|glpat-[A-Za-z0-9_-]{18,}|xox[baprs]-[A-Za-z0-9-]{18,}|AIzaSy[A-Za-z0-9_-]{31,}|hf_[A-Za-z0-9]{24,}|AKIA[0-9A-Z]{16})\b").unwrap()
    });
    if api_re.is_match(sample) {
        return Some(SensitiveSecretKind::ApiKey);
    }

    let jwt_re = JWT_RE.get_or_init(|| {
        Regex::new(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b").unwrap()
    });
    if jwt_re.is_match(sample) {
        return Some(SensitiveSecretKind::JwtToken);
    }

    let conn_re = CONN_RE.get_or_init(|| {
        Regex::new(r"(?i)\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^:\s/]+:[^@\s]{4,}@[^\s]+").unwrap()
    });
    let bearer_re = BEARER_RE.get_or_init(|| {
        Regex::new(r"(?i)\b(?:bearer|authorization\s*:\s*bearer)\s+[A-Za-z0-9._~+/=-]{20,}")
            .unwrap()
    });
    if conn_re.is_match(sample) || bearer_re.is_match(sample) {
        return Some(SensitiveSecretKind::ConnectionSecret);
    }

    None
}

pub fn veiled_sensitive_preview(raw: &str) -> String {
    let prefix: String = raw.chars().take(360).collect();
    let trimmed = prefix.trim();
    if trimmed.is_empty() {
        return "••••••••••••".to_string();
    }
    if trimmed.contains("PRIVATE KEY-----") {
        let first_line = trimmed
            .lines()
            .next()
            .unwrap_or("-----BEGIN PRIVATE KEY-----");
        return format!("{first_line} ••••••••••••••••");
    }
    let single = trimmed.replace('\n', " ").replace('\r', "");
    let chars: Vec<char> = single.chars().collect();
    if chars.len() <= 12 {
        let h: String = chars.iter().take(3).collect();
        return format!("{h}••••••••");
    }
    let head_len = (chars.len() / 5).clamp(4, 8);
    let head: String = chars.iter().take(head_len).collect();
    let tail: String = chars.iter().skip(chars.len() - 4).collect();
    format!("{head}••••••••••••{tail}")
}

// ============================================================================
// 3. 跨软件零成本搬家解析器（支持 Raycast / Maccy / Paste / CopyQ JSON & CSV / TSV）
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalImportCandidate {
    pub text: String,
    pub alias: Option<String>,
    pub source_label: String,
}

pub fn parse_external_competitor_data(
    data: &[u8],
    ext_hint: Option<&str>,
) -> Option<(Vec<ExternalImportCandidate>, String)> {
    let ext = ext_hint.unwrap_or("").to_ascii_lowercase();

    if ext != "csv" && ext != "tsv" {
        if let Ok(json_val) = serde_json::from_slice::<Value>(data) {
            if let Some(res) = parse_json_competitor_payload(&json_val) {
                if !res.0.is_empty() {
                    return Some(res);
                }
            }
        }
    }

    if let Ok(raw_str) = std::str::from_utf8(data) {
        let trimmed = raw_str.trim();
        if !trimmed.is_empty() && !trimmed.starts_with('{') && !trimmed.starts_with('[') {
            let delim = if ext == "tsv" || (trimmed.contains('\t') && !trimmed.contains(',')) {
                '\t'
            } else {
                ','
            };
            let rows = parse_delimited_rows(trimmed, delim);
            let list = candidates_from_table_rows(&rows);
            if !list.is_empty() {
                let name = if delim == '\t' {
                    "TSV 常用语表"
                } else {
                    "CSV 常用语表"
                };
                return Some((list, name.to_string()));
            }
        }
    }

    None
}

fn parse_json_competitor_payload(root: &Value) -> Option<(Vec<ExternalImportCandidate>, String)> {
    let mut format_name = "外部 JSON 收藏".to_string();
    let arr: &[Value] = match root {
        Value::Array(list) => {
            if let Some(first) = list.first().and_then(|v| v.as_object()) {
                if first.contains_key("keyword") && first.contains_key("text") {
                    format_name = "Raycast 常用语".to_string();
                } else if first.contains_key("pin") || first.contains_key("application") {
                    format_name = "Maccy 剪贴记录".to_string();
                }
            }
            list.as_slice()
        }
        Value::Object(map) => {
            if map.get("format").and_then(|v| v.as_str()) == Some(crate::archive::ARCHIVE_FORMAT_ID)
            {
                return None;
            }
            let mut found = None;
            for key in [
                "snippets", "items", "pins", "history", "clips", "data", "records",
            ] {
                if let Some(sub) = map.get(key).and_then(|v| v.as_array()) {
                    if !sub.is_empty() {
                        if key == "snippets" {
                            format_name = "常用语片段包".to_string();
                        } else if key == "pins" {
                            format_name = "Maccy / Paste 收藏".to_string();
                        }
                        found = Some(sub.as_slice());
                        break;
                    }
                }
            }
            found?
        }
        _ => return None,
    };

    let mut out = Vec::new();
    for entry in arr {
        if let Some(s) = entry.as_str() {
            let t = s.trim();
            if !t.is_empty() {
                out.push(ExternalImportCandidate {
                    text: t.to_string(),
                    alias: None,
                    source_label: "JSON 列表导入".to_string(),
                });
            }
            continue;
        }
        let Some(obj) = entry.as_object() else {
            continue;
        };
        let text = [
            "text",
            "content",
            "value",
            "plainText",
            "body",
            "snippet",
            "string",
        ]
        .iter()
        .find_map(|k| obj.get(*k).and_then(|v| v.as_str()))
        .filter(|s| !s.trim().is_empty());
        let Some(clean_text) = text else {
            continue;
        };

        let raw_alias = ["title", "name", "alias", "customAlias", "label", "keyword"]
            .iter()
            .find_map(|k| obj.get(*k).and_then(|v| v.as_str()))
            .map(|s| s.trim())
            .filter(|s| !s.is_empty() && *s != clean_text.trim())
            .map(|s| s.chars().take(80).collect::<String>());

        let source_label = ["application", "sourceAppName", "app", "source"]
            .iter()
            .find_map(|k| obj.get(*k).and_then(|v| v.as_str()))
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(&format_name)
            .to_string();

        out.push(ExternalImportCandidate {
            text: clean_text.to_string(),
            alias: raw_alias,
            source_label,
        });
    }

    if out.is_empty() {
        None
    } else {
        Some((out, format_name))
    }
}

fn parse_delimited_rows(input: &str, delimiter: char) -> Vec<Vec<String>> {
    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut cur_row: Vec<String> = Vec::new();
    let mut cur_field = String::new();
    let mut in_quotes = false;
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        let ch = chars[i];
        if in_quotes {
            if ch == '"' {
                if i + 1 < chars.len() && chars[i + 1] == '"' {
                    cur_field.push('"');
                    i += 2;
                    continue;
                } else {
                    in_quotes = false;
                }
            } else {
                cur_field.push(ch);
            }
        } else if ch == '"' && cur_field.is_empty() {
            in_quotes = true;
        } else if ch == delimiter {
            cur_row.push(std::mem::take(&mut cur_field));
        } else if ch == '\r' || ch == '\n' {
            if ch == '\r' && i + 1 < chars.len() && chars[i + 1] == '\n' {
                i += 1;
            }
            cur_row.push(std::mem::take(&mut cur_field));
            if cur_row.iter().any(|c| !c.trim().is_empty()) {
                rows.push(std::mem::take(&mut cur_row));
            } else {
                cur_row.clear();
            }
        } else {
            cur_field.push(ch);
        }
        i += 1;
    }

    if !cur_field.is_empty() || !cur_row.is_empty() {
        cur_row.push(cur_field);
        if cur_row.iter().any(|c| !c.trim().is_empty()) {
            rows.push(cur_row);
        }
    }
    rows
}

fn candidates_from_table_rows(rows: &[Vec<String>]) -> Vec<ExternalImportCandidate> {
    if rows.is_empty() {
        return Vec::new();
    }
    let headers = [
        "title",
        "name",
        "alias",
        "keyword",
        "label",
        "text",
        "content",
        "value",
        "body",
        "snippet",
        "标题",
        "名称",
        "备注",
        "快捷键",
        "内容",
        "正文",
        "话术",
    ];
    let mut start = 0usize;
    if let Some(first) = rows.first() {
        let c0 = first
            .first()
            .map(|s| s.trim().to_lowercase())
            .unwrap_or_default();
        let c1 = first
            .get(1)
            .map(|s| s.trim().to_lowercase())
            .unwrap_or_default();
        if headers.contains(&c0.as_str()) || headers.contains(&c1.as_str()) {
            start = 1;
        }
    }

    let mut out = Vec::new();
    for row in rows.iter().skip(start) {
        if row.len() >= 2 {
            let c0 = row[0].trim();
            let c1 = row[1].trim();
            if !c1.is_empty() {
                let alias = if !c0.is_empty() && c0 != c1 {
                    Some(c0.chars().take(80).collect())
                } else {
                    None
                };
                out.push(ExternalImportCandidate {
                    text: c1.to_string(),
                    alias,
                    source_label: "表格迁入".to_string(),
                });
            } else if !c0.is_empty() {
                out.push(ExternalImportCandidate {
                    text: c0.to_string(),
                    alias: None,
                    source_label: "表格迁入".to_string(),
                });
            }
        } else if let Some(only) = row.first().map(|s| s.trim()).filter(|s| !s.is_empty()) {
            out.push(ExternalImportCandidate {
                text: only.to_string(),
                alias: None,
                source_label: "列表迁入".to_string(),
            });
        }
    }
    out
}
