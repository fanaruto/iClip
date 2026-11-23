use regex_lite::Regex;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

pub const VAULT_MAGIC: &[u8; 8] = b"ICLPWIN1";
pub const IMAGE_VAULT_MAGIC: &[u8; 8] = b"ICLPIMG1";
pub const ARCHIVE_ENC_MAC_MAGIC: &[u8; 9] = b"ICLPARCH1";
pub const ARCHIVE_ENC_WIN_MAGIC: &[u8; 9] = b"ICLPAWIN1";
static NONCE_SEQ: AtomicU64 = AtomicU64::new(1);
static KEY_CACHE: OnceLock<Mutex<Vec<(PathBuf, [u8; 32])>>> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SensitiveSecretKind {
    ApiKey,
    PrivateKey,
    JwtToken,
    ConnectionSecret,
    PersonalIdentity,
}

impl SensitiveSecretKind {
    pub fn badge_title(self) -> &'static str {
        match self {
            Self::ApiKey => "密钥保护",
            Self::PrivateKey => "私钥保护",
            Self::JwtToken => "令牌保护",
            Self::ConnectionSecret => "凭据保护",
            Self::PersonalIdentity => "隐私保护",
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

fn fill_os_csprng(buf: &mut [u8; 32]) {
    #[cfg(target_os = "windows")]
    {
        #[link(name = "advapi32")]
        extern "system" {
            fn SystemFunction036(random_buffer: *mut u8, random_buffer_length: u32) -> u8;
        }
        unsafe {
            let _ = SystemFunction036(buf.as_mut_ptr(), buf.len() as u32);
        }
    }
    #[cfg(unix)]
    {
        use std::io::Read;
        if let Ok(mut f) = fs::File::open("/dev/urandom") {
            let _ = f.read_exact(buf);
        }
    }
}

fn generate_entropy_32(seed_hint: &Path) -> [u8; 32] {
    let mut os_rand = [0u8; 32];
    fill_os_csprng(&mut os_rand);
    let seq = NONCE_SEQ.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = std::process::id();
    let addr = seed_hint as *const Path as *const u8 as usize;
    let mut h = Sha256::new();
    h.update(b"iclip-vault-entropy-v2|");
    h.update(os_rand);
    h.update(seq.to_le_bytes());
    h.update(nanos.to_le_bytes());
    h.update(pid.to_le_bytes());
    h.update(addr.to_le_bytes());
    h.update(seed_hint.to_string_lossy().as_bytes());
    let digest = h.finalize();
    let mut out = [0u8; 32];
    out.copy_from_slice(&digest);
    out
}

/// 加载或静默初始化与数据目录绑定的 256-bit 主密钥（Windows 下经系统内核 DPAPI 封装，进程内内存缓存零重复 I/O）
pub fn load_or_create_vault_key(data_dir: &Path) -> [u8; 32] {
    let cache = KEY_CACHE.get_or_init(|| Mutex::new(Vec::new()));
    if let Ok(guard) = cache.lock() {
        if let Some((_, k)) = guard.iter().find(|(p, _)| p == data_dir) {
            return *k;
        }
    }

    let key_path = data_dir.join("vault.dpapi");
    let resolved: [u8; 32] = 'load: {
        if let Ok(raw) = fs::read(&key_path) {
            #[cfg(target_os = "windows")]
            if let Some(unprotected) = win_dpapi::unprotect_bytes(&raw) {
                if unprotected.len() == 32 {
                    let mut k = [0u8; 32];
                    k.copy_from_slice(&unprotected);
                    break 'load k;
                }
            }
            #[cfg(not(target_os = "windows"))]
            if raw.len() == 32 {
                let mut k = [0u8; 32];
                k.copy_from_slice(&raw);
                break 'load k;
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
    };

    if let Ok(mut guard) = cache.lock() {
        if guard.len() < 16 && !guard.iter().any(|(p, _)| p == data_dir) {
            guard.push((data_dir.to_path_buf(), resolved));
        }
    }
    resolved
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
// 1.5 本地剪贴板截图全模态透明静态认证加密（`ICLPIMG1` + 旧明文 PNG 自动升级）
// ============================================================================

pub fn seal_image_bytes(plain: &[u8], master_key: &[u8; 32], seed_dir: &Path) -> Vec<u8> {
    let entropy = generate_entropy_32(seed_dir);
    let mut nonce = [0u8; 16];
    nonce.copy_from_slice(&entropy[..16]);

    let (enc_key, mac_key) = derive_subkeys(master_key, &nonce);
    let mut ciphertext = plain.to_vec();
    apply_sha256_ctr_stream(&enc_key, &nonce, &mut ciphertext);

    let mut out = Vec::with_capacity(8 + 16 + ciphertext.len() + 32);
    out.extend_from_slice(IMAGE_VAULT_MAGIC);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ciphertext);

    let tag = hmac_sha256(&mac_key, &out);
    out.extend_from_slice(&tag);
    out
}

pub fn open_image_bytes(raw: &[u8], master_key: &[u8; 32]) -> Option<(Vec<u8>, bool)> {
    if raw.is_empty() {
        return None;
    }
    if raw.starts_with(IMAGE_VAULT_MAGIC) {
        if raw.len() < 8 + 16 + 32 {
            return None;
        }
        let body_end = raw.len() - 32;
        let expected_tag = &raw[body_end..];
        let mut nonce = [0u8; 16];
        nonce.copy_from_slice(&raw[8..24]);

        let (enc_key, mac_key) = derive_subkeys(master_key, &nonce);
        let computed_tag = hmac_sha256(&mac_key, &raw[..body_end]);

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
    // 平滑兼容历史遗留明文 PNG / JPEG 图像
    Some((raw.to_vec(), true))
}

fn data_dir_from_images_dir(images_dir: &Path) -> &Path {
    images_dir.parent().unwrap_or(images_dir)
}

pub fn write_encrypted_image_to_dir(
    images_dir: &Path,
    file_name: &str,
    plain_png: &[u8],
) -> std::io::Result<()> {
    let _ = fs::create_dir_all(images_dir);
    let data_dir = data_dir_from_images_dir(images_dir);
    let key = load_or_create_vault_key(data_dir);
    let sealed = seal_image_bytes(plain_png, &key, data_dir);
    let dest = images_dir.join(file_name);
    fs::write(&dest, sealed)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&dest, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

pub fn read_decrypted_image_from_dir(images_dir: &Path, file_name: &str) -> Option<Vec<u8>> {
    let clean_name = Path::new(file_name).file_name()?;
    let raw = fs::read(images_dir.join(clean_name)).ok()?;
    let data_dir = data_dir_from_images_dir(images_dir);
    let key = load_or_create_vault_key(data_dir);
    open_image_bytes(&raw, &key).map(|(plain, _)| plain)
}

pub fn upgrade_plain_images_in_dir(images_dir: &Path, master_key: &[u8; 32]) -> usize {
    let Ok(entries) = fs::read_dir(images_dir) else {
        return 0;
    };
    let data_dir = data_dir_from_images_dir(images_dir);
    let mut upgraded = 0usize;
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Ok(raw) = fs::read(&path) else {
            continue;
        };
        if raw.is_empty() || raw.starts_with(IMAGE_VAULT_MAGIC) {
            continue;
        }
        let sealed = seal_image_bytes(&raw, master_key, data_dir);
        if fs::write(&path, sealed).is_ok() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
            }
            upgraded += 1;
        }
    }
    upgraded
}

/// 按需将加密截图物化至受控临时预览目录（自动清扫超 10 分钟旧临时件，供资源管理器预览）
pub fn materialize_temp_preview_image(images_dir: &Path, file_name: &str) -> Option<PathBuf> {
    let clean_name = Path::new(file_name)
        .file_name()?
        .to_string_lossy()
        .to_string();
    let plain = read_decrypted_image_from_dir(images_dir, &clean_name)?;
    let preview_dir = std::env::temp_dir().join("iClipPreviewExports");
    let _ = fs::create_dir_all(&preview_dir);
    if let Ok(entries) = fs::read_dir(&preview_dir) {
        let now = std::time::SystemTime::now();
        for ent in entries.flatten() {
            if let Ok(meta) = ent.metadata() {
                if let Ok(modified) = meta.modified() {
                    if now
                        .duration_since(modified)
                        .map(|d| d.as_secs() > 600)
                        .unwrap_or(false)
                    {
                        let _ = fs::remove_file(ent.path());
                    }
                }
            }
        }
    }
    let out_path = preview_dir.join(clean_name);
    fs::write(&out_path, plain).ok()?;
    Some(out_path)
}

// ============================================================================
// 1.8 口令级归档认证加密（支持 `.iclip` 密码保护与跨平台加密归档识别）
// ============================================================================

fn derive_passphrase_key_32(passphrase: &str, salt: &[u8; 16]) -> [u8; 32] {
    let mut h0 = Sha256::new();
    h0.update(salt);
    h0.update(passphrase.trim().as_bytes());
    let mut hash = [0u8; 32];
    hash.copy_from_slice(&h0.finalize());

    for round in 0u32..4096 {
        let mut hm = Sha256::new();
        hm.update(hash);
        hm.update(salt);
        hm.update(round.to_le_bytes());
        hash.copy_from_slice(&hm.finalize());
    }
    hash
}

pub fn is_encrypted_archive_bytes(data: &[u8]) -> bool {
    data.starts_with(ARCHIVE_ENC_WIN_MAGIC) || data.starts_with(ARCHIVE_ENC_MAC_MAGIC)
}

pub fn seal_archive_with_passphrase(plain: &[u8], passphrase: &str, seed_dir: &Path) -> Vec<u8> {
    let trimmed = passphrase.trim();
    if trimmed.is_empty() {
        return plain.to_vec();
    }
    let ent = generate_entropy_32(seed_dir);
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 16];
    salt.copy_from_slice(&ent[..16]);
    nonce.copy_from_slice(&ent[16..32]);

    let master = derive_passphrase_key_32(trimmed, &salt);
    let (enc_key, mac_key) = derive_subkeys(&master, &nonce);
    let mut ciphertext = plain.to_vec();
    apply_sha256_ctr_stream(&enc_key, &nonce, &mut ciphertext);

    let mut out = Vec::with_capacity(9 + 16 + 16 + ciphertext.len() + 32);
    out.extend_from_slice(ARCHIVE_ENC_WIN_MAGIC);
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ciphertext);

    let tag = hmac_sha256(&mac_key, &out);
    out.extend_from_slice(&tag);
    out
}

pub fn open_encrypted_archive_bytes(data: &[u8], passphrase: &str) -> Option<Vec<u8>> {
    if !data.starts_with(ARCHIVE_ENC_WIN_MAGIC) {
        return None;
    }
    if data.len() < 9 + 16 + 16 + 32 {
        return None;
    }
    let trimmed = passphrase.trim();
    if trimmed.is_empty() {
        return None;
    }
    let body_end = data.len() - 32;
    let expected_tag = &data[body_end..];
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 16];
    salt.copy_from_slice(&data[9..25]);
    nonce.copy_from_slice(&data[25..41]);

    let master = derive_passphrase_key_32(trimmed, &salt);
    let (enc_key, mac_key) = derive_subkeys(&master, &nonce);
    let computed_tag = hmac_sha256(&mac_key, &data[..body_end]);

    let mut diff = 0u8;
    for (a, b) in expected_tag.iter().zip(computed_tag.iter()) {
        diff |= a ^ b;
    }
    if diff != 0 {
        return None;
    }

    let mut plain = data[41..body_end].to_vec();
    apply_sha256_ctr_stream(&enc_key, &nonce, &mut plain);
    Some(plain)
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
    static URL_QUERY_SEC_RE: OnceLock<Regex> = OnceLock::new();
    let url_q_re = URL_QUERY_SEC_RE.get_or_init(|| {
        Regex::new(
            r"(?i)[?&](?:api_key|apikey|access_token|auth_token|client_secret|secret|password|passwd)=[^&\s#]{8,}",
        )
        .unwrap()
    });
    static BASIC_AUTH_RE: OnceLock<Regex> = OnceLock::new();
    let basic_re =
        BASIC_AUTH_RE.get_or_init(|| Regex::new(r"(?i)\bhttps?://[^:\s/@]+:[^@\s/]{4,}@").unwrap());
    if conn_re.is_match(sample)
        || bearer_re.is_match(sample)
        || url_q_re.is_match(sample)
        || basic_re.is_match(sample)
    {
        return Some(SensitiveSecretKind::ConnectionSecret);
    }

    if contains_verified_identity_or_card(sample) {
        return Some(SensitiveSecretKind::PersonalIdentity);
    }

    None
}

/// GB 11643-1999 18 位二代身份证加权模 11 校验核验（零误伤普通 18 位订单号）
pub fn is_valid_chinese_id_card_18(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 18 || !(b'1'..=b'8').contains(&b[0]) {
        return false;
    }
    for &c in &b[0..17] {
        if !c.is_ascii_digit() {
            return false;
        }
    }
    let year = (b[6] - b'0') as u32 * 1000
        + (b[7] - b'0') as u32 * 100
        + (b[8] - b'0') as u32 * 10
        + (b[9] - b'0') as u32;
    let month = (b[10] - b'0') * 10 + (b[11] - b'0');
    let day = (b[12] - b'0') * 10 + (b[13] - b'0');
    if !(1900..=2099).contains(&year) || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return false;
    }
    const WEIGHTS: [u32; 17] = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
    const MAP: [u8; 11] = *b"10X98765432";
    let mut sum = 0u32;
    for i in 0..17 {
        sum += (b[i] - b'0') as u32 * WEIGHTS[i];
    }
    let expected = MAP[(sum % 11) as usize];
    let last = b[17].to_ascii_uppercase();
    last == expected
}

/// 银联 / Visa / MasterCard / Amex 银行卡号 BIN 前缀 + Luhn 模 10 校验核验
pub fn is_valid_bank_card_luhn(s: &str) -> bool {
    let b = s.as_bytes();
    if !(15..=19).contains(&b.len()) || !b.iter().all(|c| c.is_ascii_digit()) {
        return false;
    }
    let bin_ok = match b.len() {
        15 => b.starts_with(b"34") || b.starts_with(b"37"),
        16 => b.starts_with(b"62") || b[0] == b'4' || (b'1'..=b'5').contains(&b[1]) && b[0] == b'5',
        17..=19 => b.starts_with(b"62"),
        _ => false,
    };
    if !bin_ok {
        return false;
    }
    let first = b[0];
    if b.iter().all(|&c| c == first) {
        return false;
    }
    let mut sum = 0u32;
    let mut double = false;
    for &c in b.iter().rev() {
        let mut d = (c - b'0') as u32;
        if double {
            d *= 2;
            if d > 9 {
                d -= 9;
            }
        }
        sum += d;
        double = !double;
    }
    sum % 10 == 0
}

pub fn contains_verified_identity_or_card(sample: &str) -> bool {
    let bytes = sample.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let prev_alnum = i > 0 && bytes[i - 1].is_ascii_alphanumeric();
            let mut end = i + 1;
            while end < bytes.len()
                && (bytes[end].is_ascii_digit()
                    || ((end - i) == 17 && (bytes[end] == b'X' || bytes[end] == b'x')))
            {
                end += 1;
            }
            let next_alnum = end < bytes.len() && bytes[end].is_ascii_alphanumeric();
            if !prev_alnum && !next_alnum {
                let tok = &sample[i..end];
                if (tok.len() == 18 && is_valid_chinese_id_card_18(tok))
                    || ((15..=19).contains(&tok.len()) && is_valid_bank_card_luhn(tok))
                {
                    return true;
                }
            }
            i = end;
        } else {
            i += 1;
        }
    }
    false
}

/// 精准掩码文本中通过校验位的 18 位身份证与银行卡号（保留首尾辨识位，零误伤普通数字串）
pub fn mask_verified_identity_and_cards(text: &str) -> String {
    if !contains_verified_identity_or_card(text) {
        return text.to_string();
    }
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut last_copied = 0usize;
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let prev_alnum = i > 0 && bytes[i - 1].is_ascii_alphanumeric();
            let mut end = i + 1;
            while end < bytes.len()
                && (bytes[end].is_ascii_digit()
                    || ((end - i) == 17 && (bytes[end] == b'X' || bytes[end] == b'x')))
            {
                end += 1;
            }
            let next_alnum = end < bytes.len() && bytes[end].is_ascii_alphanumeric();
            if !prev_alnum && !next_alnum {
                let tok = &text[i..end];
                if tok.len() == 18 && is_valid_chinese_id_card_18(tok) {
                    out.push_str(&text[last_copied..i]);
                    out.push_str(&tok[..3]);
                    out.push_str("***********");
                    out.push_str(&tok[14..]);
                    last_copied = end;
                } else if (15..=19).contains(&tok.len()) && is_valid_bank_card_luhn(tok) {
                    out.push_str(&text[last_copied..i]);
                    out.push_str(&tok[..4]);
                    out.push_str("********");
                    out.push_str(&tok[tok.len() - 4..]);
                    last_copied = end;
                }
            }
            i = end;
        } else {
            i += 1;
        }
    }
    out.push_str(&text[last_copied..]);
    out
}

/// 判断目标窗口是否为外部公域 AI 助手或聊天工具（外发粘贴时自动置顶防泄密脱敏胶囊）
pub fn is_external_ai_or_chat_app(app_name: Option<&str>) -> bool {
    let Some(raw) = app_name.map(str::trim).filter(|s| !s.is_empty()) else {
        return false;
    };
    let lower = raw.to_lowercase();
    const MARKERS: &[&str] = &[
        "chatgpt",
        "claude",
        "deepseek",
        "grok",
        "kimi",
        "豆包",
        "doubao",
        "元宝",
        "yuanbao",
        "通义",
        "tongyi",
        "perplexity",
        "gemini",
        "poe",
        "ego",
        "微信",
        "wechat",
        "weixin",
        "飞书",
        "feishu",
        "lark",
        "钉钉",
        "dingtalk",
        "企业微信",
        "wecom",
        "qq",
        "slack",
        "discord",
        "telegram",
        "whatsapp",
    ];
    MARKERS.iter().any(|m| lower.contains(m))
}

/// 严格网页浏览器跳转 URL 协议白名单校验（仅放行合法的 http:// 与 https:// 主机，拦截 javascript:/file:/ms-msdt:/UNC/本地路径）
pub fn sanitize_safe_browser_url(raw_input: &str) -> Option<String> {
    let raw = raw_input.trim();
    if raw.is_empty() {
        return None;
    }

    // 控制符、空白或命令行引号一律拒绝，防止 ShellExecute 参数欺骗
    if raw
        .chars()
        .any(|c| c.is_control() || c == ' ' || c == '"' || c == '<' || c == '>')
    {
        return None;
    }

    // 拒绝本地文件路径与 UNC 共享路径
    if raw.starts_with('/') || raw.starts_with('~') || raw.starts_with('\\') {
        return None;
    }
    let bytes = raw.as_bytes();
    if bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes[2] == b'\\' || bytes[2] == b'/')
    {
        return None;
    }

    let normalized = if let Some((scheme, _rest)) = raw.split_once("://") {
        let sc = scheme.to_ascii_lowercase();
        if sc != "http" && sc != "https" {
            return None;
        }
        if let Some(clean) = crate::engines::clean_tracking_url(raw) {
            clean
        } else {
            raw.to_string()
        }
    } else {
        // 检查无双斜杠伪协议（如 javascript:alert(1), ms-msdt:id=..., search-ms:query=..., data:..., mailto:...）
        if let Some((prefix, after_colon)) = raw.split_once(':') {
            let is_scheme_chars = !prefix.is_empty()
                && prefix
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'-' || b == b'.');
            let port_digits_len = after_colon
                .bytes()
                .take_while(|b| b.is_ascii_digit())
                .count();
            let after_port = &after_colon[port_digits_len..];
            let looks_like_host_port = (1..=5).contains(&port_digits_len)
                && (after_port.is_empty()
                    || after_port.starts_with('/')
                    || after_port.starts_with('?')
                    || after_port.starts_with('#'));
            if is_scheme_chars && !looks_like_host_port {
                return None;
            }
        }
        let lower = raw.to_ascii_lowercase();
        let is_local = lower == "localhost"
            || lower.starts_with("localhost:")
            || lower.starts_with("localhost/")
            || lower.starts_with("127.0.0.1")
            || lower.starts_with("0.0.0.0");
        let prefixed = format!("{}{raw}", if is_local { "http://" } else { "https://" });
        crate::engines::clean_tracking_url(&prefixed).unwrap_or(prefixed)
    };

    let after_scheme = normalized
        .strip_prefix("https://")
        .or_else(|| normalized.strip_prefix("http://"))
        .or_else(|| {
            let lower = normalized.to_ascii_lowercase();
            if lower.starts_with("https://") {
                Some(&normalized[8..])
            } else if lower.starts_with("http://") {
                Some(&normalized[7..])
            } else {
                None
            }
        })?;
    let authority = after_scheme
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("")
        .trim();
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    let host = authority
        .split(':')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    if host.is_empty() || (host != "localhost" && !host.contains('.')) {
        return None;
    }
    Some(normalized)
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
