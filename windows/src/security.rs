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

    // 平滑兼容历史遗留未加密 UTF-8 JSON 数组或对象
    let first_non_ws = raw
        .iter()
        .copied()
        .find(|b| !matches!(b, b' ' | b'\n' | b'\r' | b'\t'));
    if matches!(first_non_ws, Some(b'[' | b'{')) {
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
    let preview_dir = if cfg!(test) {
        images_dir.join(".iClipPreviewExports")
    } else {
        std::env::temp_dir().join("iClipPreviewExports")
    };
    let _ = fs::create_dir_all(&preview_dir);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&preview_dir, fs::Permissions::from_mode(0o700));
    }
    if let Ok(entries) = fs::read_dir(&preview_dir) {
        let now = std::time::SystemTime::now();
        for ent in entries.flatten() {
            if let Ok(meta) = ent.metadata() {
                if let Ok(modified) = meta.modified() {
                    if now
                        .duration_since(modified)
                        .map(|d| d.as_secs() > 60)
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
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&out_path, fs::Permissions::from_mode(0o600));
    }
    Some(out_path)
}

/// 删除单条记录或即焚销毁时，立即擦除临时预览目录中对应的明文副本
pub fn purge_temp_preview_image(file_name: &str) {
    if let Some(clean_name) = Path::new(file_name).file_name() {
        let p = std::env::temp_dir()
            .join("iClipPreviewExports")
            .join(clean_name);
        let _ = fs::remove_file(p);
    }
}

/// 启动、锁屏、休眠、清空历史或进程退出时，锁紧目录权限并全量擦除临时预览导出目录中的明文文件
pub fn wipe_all_temp_previews() {
    if cfg!(test) {
        return;
    }
    let preview_dir = std::env::temp_dir().join("iClipPreviewExports");
    #[cfg(unix)]
    if preview_dir.exists() {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&preview_dir, fs::Permissions::from_mode(0o700));
    }
    if let Ok(entries) = fs::read_dir(&preview_dir) {
        for ent in entries.flatten() {
            let _ = fs::remove_file(ent.path());
        }
    }
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
// 1.9 剪贴板投毒、终端粘贴劫持（Pastejacking / Trojan Source CVE-2021-42574）与零宽幽灵字符净化护盾
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PoisonThreatKind {
    PastejackingOrBidi(usize),
    ZeroWidthGhost(usize),
}

fn is_bidi_override_char(c: char) -> bool {
    let v = c as u32;
    (0x202A..=0x202E).contains(&v) || (0x2066..=0x2069).contains(&v) || v == 0x061C
}

fn is_zero_width_char(c: char) -> bool {
    matches!(c as u32, 0x200B | 0x200C | 0x2060 | 0xFEFF)
}

pub fn inspect_clipboard_poison(raw: &str) -> Option<PoisonThreatKind> {
    if raw.is_empty() {
        return None;
    }
    let sample = if raw.len() > 16_384 {
        let mut end = 16_384;
        while end > 0 && !raw.is_char_boundary(end) {
            end -= 1;
        }
        &raw[..end]
    } else {
        raw
    };

    let chars: Vec<char> = sample.chars().collect();
    let mut high_risk = 0usize;
    let mut zero_width = 0usize;
    let mut prev_u32 = 0u32;

    for (idx, &ch) in chars.iter().enumerate() {
        let v = ch as u32;
        if is_bidi_override_char(ch) || v == 0x001B || v == 0x009B || v == 0x0008 || v == 0x0007 {
            high_risk += 1;
        } else if v == 0x000D {
            if let Some(&next_ch) = chars.get(idx + 1) {
                if next_ch != '\n' && next_ch != '\r' {
                    high_risk += 1;
                }
            }
        } else if is_zero_width_char(ch) {
            zero_width += 1;
        } else if v == 0x200D && prev_u32 < 0x2600 {
            zero_width += 1;
        }
        prev_u32 = v;
    }

    if high_risk > 0 {
        Some(PoisonThreatKind::PastejackingOrBidi(high_risk + zero_width))
    } else if zero_width > 0 {
        Some(PoisonThreatKind::ZeroWidthGhost(zero_width))
    } else {
        None
    }
}

pub fn sanitize_clipboard_poison(raw: &str) -> String {
    if raw.is_empty() {
        return String::new();
    }
    let had_high_risk = matches!(
        inspect_clipboard_poison(raw),
        Some(PoisonThreatKind::PastejackingOrBidi(_))
    );

    static ANSI_RE: OnceLock<Regex> = OnceLock::new();
    let mut stage = if raw.contains('\x1b') || raw.contains('\u{009b}') {
        let re = ANSI_RE.get_or_init(|| {
            Regex::new("\x1b\\[[0-9;?]*[ -/]*[@-~]|\u{009b}[0-9;?]*[ -/]*[@-~]|\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)")
                .unwrap()
        });
        re.replace_all(raw, "").into_owned()
    } else {
        raw.to_string()
    };

    stage = stage.replace("\r\n", "\n");
    if stage.contains('\r') {
        stage = stage.replace('\r', " ");
    }

    let mut out = String::with_capacity(stage.len());
    let mut prev_u32 = 0u32;
    for ch in stage.chars() {
        let v = ch as u32;
        if is_bidi_override_char(ch) || is_zero_width_char(ch) {
            continue;
        }
        if v == 0x200D && prev_u32 < 0x2600 {
            continue;
        }
        if v < 0x0020 && ch != '\n' && ch != '\t' {
            continue;
        }
        if v == 0x007F || (0x0080..=0x009F).contains(&v) {
            continue;
        }
        out.push(ch);
        prev_u32 = v;
    }

    if had_high_risk {
        while out.ends_with('\n') {
            out.pop();
        }
    }
    out
}

pub fn is_terminal_app(app_name: Option<&str>) -> bool {
    let Some(raw) = app_name.map(str::trim).filter(|s| !s.is_empty()) else {
        return false;
    };
    let lower = raw.to_lowercase();
    const TERMS: &[&str] = &[
        "windowsterminal",
        "wt",
        "powershell",
        "pwsh",
        "cmd",
        "ghostty",
        "iterm",
        "terminal",
        "终端",
        "warp",
        "wezterm",
        "kitty",
        "alacritty",
        "tabby",
        "windterm",
        "xshell",
        "mobaxterm",
    ];
    TERMS.iter().any(|t| lower == *t || lower.contains(t))
}

// ============================================================================
// 2. 离线微秒级敏感凭据嗅探与防肩窥圆点雾化遮罩（零高度抖动）
// ============================================================================

pub fn is_webhook_url(raw: &str) -> bool {
    if raw.is_empty() {
        return false;
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
    static WEBHOOK_RE: OnceLock<Regex> = OnceLock::new();
    let re = WEBHOOK_RE.get_or_init(|| {
        Regex::new(r"(?i)https?://(?:open\.(?:feishu\.cn|larksuite\.com)/open-apis/bot/v2/hook/|qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?(?:[^&#\s]+&)*key=|hooks\.slack\.com/services/[A-Z0-9]{8,}/[A-Z0-9]{8,}/|(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d{10,}/)[A-Za-z0-9_\-]{12,}").unwrap()
    });
    if re.is_match(sample) {
        return true;
    }
    sample
        .to_ascii_lowercase()
        .contains("oapi.dingtalk.com/robot/send")
}

pub fn is_otpauth_uri(raw: &str) -> bool {
    if raw.is_empty() {
        return false;
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
    static OTPAUTH_RE: OnceLock<Regex> = OnceLock::new();
    let re = OTPAUTH_RE.get_or_init(|| {
        Regex::new(r##"(?i)\botpauth(?:-migration)?://(?:totp|hotp|offline)[^\s'"]+"##).unwrap()
    });
    re.is_match(sample)
}

fn is_placeholder_secret_value(val: &str) -> bool {
    let lower = val.trim().to_ascii_lowercase();
    if lower.len() < 6 {
        return true;
    }
    const PLACEHOLDERS: &[&str] = &[
        "changeme",
        "change_me",
        "example",
        "placeholder",
        "replace_me",
        "redacted",
        "todo",
        "123456",
        "password",
        "secret",
        "xxxxxx",
    ];
    if PLACEHOLDERS.contains(&lower.as_str())
        || lower.starts_with("your_")
        || lower.ends_with("_here")
        || lower.contains("redacted")
        || lower.contains("***")
        || (lower.starts_with('<') && lower.ends_with('>'))
    {
        return true;
    }
    let bytes = lower.as_bytes();
    if bytes.iter().all(|&b| b == bytes[0]) {
        return true;
    }
    false
}

fn has_real_env_secret_assignment(sample: &str) -> bool {
    if !sample.contains('=') && !sample.contains(':') {
        return false;
    }
    static ENV_SEC_DETECT_RE: OnceLock<Regex> = OnceLock::new();
    let re = ENV_SEC_DETECT_RE.get_or_init(|| {
        Regex::new(
            r##"(?im)^(?:\s*(?:export\s+)?[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|API_KEY|ACCESS_KEY|PRIVATE_KEY|AUTH_TOKEN|CLIENT_SECRET)[A-Z0-9_]*\s*[:=]\s*['"]?)([^\s'"#]{6,})"##,
        )
        .unwrap()
    });
    for caps in re.captures_iter(sample) {
        if let Some(m) = caps.get(1) {
            if !is_placeholder_secret_value(m.as_str()) {
                return true;
            }
        }
    }
    false
}

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

    if sample.contains("-----BEGIN ")
        && (sample.contains("PRIVATE KEY-----") || sample.contains("PRIVATE KEY BLOCK-----"))
    {
        return Some(SensitiveSecretKind::PrivateKey);
    }
    if sample.contains("PuTTY-User-Key-File-") {
        return Some(SensitiveSecretKind::PrivateKey);
    }

    static AGE_KEY_RE: OnceLock<Regex> = OnceLock::new();
    let age_re =
        AGE_KEY_RE.get_or_init(|| Regex::new(r"\bAGE-SECRET-KEY-1[A-Z0-9]{50,}\b").unwrap());
    static WG_PRIV_RE: OnceLock<Regex> = OnceLock::new();
    let wg_re = WG_PRIV_RE.get_or_init(|| {
        Regex::new(r"(?im)^\s*(?:PrivateKey|PresharedKey)\s*=\s*[A-Za-z0-9+/]{42,44}=\s*$").unwrap()
    });
    static KUBE_KEY_RE: OnceLock<Regex> = OnceLock::new();
    let kube_re = KUBE_KEY_RE.get_or_init(|| {
        Regex::new(r"(?im)^\s*client-key-data\s*:\s*[A-Za-z0-9+/=]{32,}\s*$").unwrap()
    });
    if (sample.contains("AGE-SECRET-KEY-1") && age_re.is_match(sample))
        || is_otpauth_uri(sample)
        || (sample.contains("Key") && wg_re.is_match(sample))
        || (sample.contains("client-key-data") && kube_re.is_match(sample))
    {
        return Some(SensitiveSecretKind::PrivateKey);
    }

    static API_RE: OnceLock<Regex> = OnceLock::new();
    static JWT_RE: OnceLock<Regex> = OnceLock::new();
    static CONN_RE: OnceLock<Regex> = OnceLock::new();
    static BEARER_RE: OnceLock<Regex> = OnceLock::new();

    let api_re = API_RE.get_or_init(|| {
        Regex::new(r"\b(?:sk-(?:proj-|ant-|or-v1-)?[A-Za-z0-9_-]{18,}|(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{28,}|glpat-[A-Za-z0-9_-]{18,}|glsa_[A-Za-z0-9_-]{24,}|glc_[A-Za-z0-9_=+-]{24,}|dapi[a-fA-F0-9]{32}|re_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{18,}|AIzaSy[A-Za-z0-9_-]{31,}|hf_[A-Za-z0-9]{24,}|gsk_[A-Za-z0-9]{24,}|pplx-[A-Za-z0-9]{24,}|r8_[A-Za-z0-9]{24,}|ntn_[A-Za-z0-9]{24,}|secret_[A-Za-z0-9]{32,}|sbp_[a-fA-F0-9]{32,}|figd_[A-Za-z0-9_-]{24,}|lin_api_[A-Za-z0-9]{24,}|PMAK-[a-fA-F0-9]{24}-[a-fA-F0-9]{34}|dop_v1_[a-fA-F0-9]{64}|dckr_pat_[A-Za-z0-9_-]{20,}|hvs\.[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|LTAI[A-Za-z0-9]{12,24}|AKID[A-Za-z0-9]{13,32}|\d{8,10}:AA[A-Za-z0-9_-]{33}|npm_[A-Za-z0-9]{36}|pypi-[A-Za-z0-9_-]{40,}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,})\b").unwrap()
    });
    const API_FAST_HINTS: &[&str] = &[
        "sk-",
        "_live_",
        "_test_",
        "whsec_",
        "ghp_",
        "gho_",
        "ghu_",
        "ghs_",
        "ghr_",
        "github_pat_",
        "glpat-",
        "glsa_",
        "glc_",
        "dapi",
        "re_",
        "xox",
        "AIzaSy",
        "hf_",
        "gsk_",
        "pplx-",
        "r8_",
        "ntn_",
        "secret_",
        "sbp_",
        "figd_",
        "lin_api_",
        "PMAK-",
        "dop_v1_",
        "dckr_pat_",
        "hvs.",
        "AKIA",
        "LTAI",
        "AKID",
        ":AA",
        "npm_",
        "pypi-",
        "SG.",
    ];
    if API_FAST_HINTS.iter().any(|h| sample.contains(h)) && api_re.is_match(sample) {
        return Some(SensitiveSecretKind::ApiKey);
    }

    let jwt_re = JWT_RE.get_or_init(|| {
        Regex::new(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b").unwrap()
    });
    if sample.contains("eyJ") && jwt_re.is_match(sample) {
        return Some(SensitiveSecretKind::JwtToken);
    }

    let conn_re = CONN_RE.get_or_init(|| {
        Regex::new(r"(?i)\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|rediss?|amqps?|clickhouse)://[^:\s/@]*:[^@\s]{4,}@[^\s]+").unwrap()
    });
    let bearer_re = BEARER_RE.get_or_init(|| {
        Regex::new(r"(?i)\b(?:bearer|authorization\s*:\s*bearer)\s+[A-Za-z0-9._~+/=-]{20,}")
            .unwrap()
    });
    static URL_QUERY_SEC_RE: OnceLock<Regex> = OnceLock::new();
    let url_q_re = URL_QUERY_SEC_RE.get_or_init(|| {
        Regex::new(
            r"(?i)[?&](?:api_key|apikey|access_token|auth_token|id_token|refresh_token|session_token|jwt|client_secret|secret|password|passwd|x-amz-signature|x-amz-security-token|x-goog-signature|q-signature|ossaccesskeyid|signature)=[^&\s#]{8,}",
        )
        .unwrap()
    });
    static BASIC_AUTH_RE: OnceLock<Regex> = OnceLock::new();
    let basic_re =
        BASIC_AUTH_RE.get_or_init(|| Regex::new(r"(?i)\bhttps?://[^:\s/@]+:[^@\s/]{4,}@").unwrap());
    static HTTP_HDR_SEC_RE: OnceLock<Regex> = OnceLock::new();
    let http_hdr_re = HTTP_HDR_SEC_RE.get_or_init(|| {
        Regex::new(
            r##"(?i)\b(?:cookie|set-cookie|x-api-key|x-auth-token|x-csrf-token)\s*:\s*[^\r\n'"]{8,}"##,
        )
        .unwrap()
    });
    static HTTP_BASIC_HDR_RE: OnceLock<Regex> = OnceLock::new();
    let http_basic_hdr_re = HTTP_BASIC_HDR_RE.get_or_init(|| {
        Regex::new(r"(?i)\b(?:authorization|proxy-authorization)\s*:\s*basic\s+[A-Za-z0-9+/=]{8,}")
            .unwrap()
    });
    static JSON_SEC_RE: OnceLock<Regex> = OnceLock::new();
    let json_sec_re = JSON_SEC_RE.get_or_init(|| {
        Regex::new(
            r##"(?i)"(?:password|passwd|secret|client_secret|api_key|apikey|access_token|refresh_token|id_token|session_token|private_key)"\s*:\s*"[^"\r\n]{6,}""##,
        )
        .unwrap()
    });
    static WIFI_PW_RE: OnceLock<Regex> = OnceLock::new();
    let wifi_re =
        WIFI_PW_RE.get_or_init(|| Regex::new(r"(?i)WIFI:(?:[^;\r\n]*;)*?P:[^;\r\n]{4,};").unwrap());
    static JDBC_PW_RE: OnceLock<Regex> = OnceLock::new();
    let jdbc_re = JDBC_PW_RE.get_or_init(|| {
        Regex::new(r##"(?i)jdbc:[a-z0-9+:-]+://[^\s'"]*?(?:[?&;]|user=[^&\s;]+[?&;])password=[^&\s;'"]{4,}"##).unwrap()
    });
    static CURL_CRED_RE: OnceLock<Regex> = OnceLock::new();
    let curl_cred_re = CURL_CRED_RE.get_or_init(|| {
        Regex::new(r##"(?i)\bcurl\b[\s\S]{0,600}?\s(?:-u|--user|-b|--cookie)\s+['"]?[^'"\s]{6,}"##)
            .unwrap()
    });
    if conn_re.is_match(sample)
        || bearer_re.is_match(sample)
        || (sample.to_ascii_lowercase().contains("curl") && curl_cred_re.is_match(sample))
        || url_q_re.is_match(sample)
        || basic_re.is_match(sample)
        || (sample.to_ascii_lowercase().contains("jdbc:") && jdbc_re.is_match(sample))
        || is_webhook_url(sample)
        || http_hdr_re.is_match(sample)
        || http_basic_hdr_re.is_match(sample)
        || json_sec_re.is_match(sample)
        || wifi_re.is_match(sample)
        || has_real_env_secret_assignment(sample)
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkRiskKind {
    /// 同形异义伪装域名（IDN Punycode `xn--`、西里尔/希腊混排拉丁主机、或 `trusted@evil` 用户信息段欺骗）
    HomographPhishing,
    /// 直接指向非官方源可执行脚本/安装器的高危下载链接
    ExecutableDownload,
}

impl LinkRiskKind {
    pub fn badge_title(self) -> &'static str {
        match self {
            Self::HomographPhishing => "疑似伪装域名",
            Self::ExecutableDownload => "可执行下载链接",
        }
    }
}

/// 离线微秒级识别高危私钥与凭据配置文件（排除 `.pub` 公钥与 `.env.example` 模板，零误伤）
pub fn classify_sensitive_file_paths(paths: &[String]) -> Option<SensitiveSecretKind> {
    const PRIVATE_KEY_EXACT: &[&str] = &["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "id_xmss"];
    const PRIVATE_KEY_EXTS: &[&str] = &[
        "pem",
        "key",
        "p12",
        "pfx",
        "jks",
        "keystore",
        "mobileprovision",
    ];
    const SECRET_CONFIG_EXACT: &[&str] = &[
        ".env",
        ".npmrc",
        ".pypirc",
        ".netrc",
        ".pgpass",
        "kubeconfig",
        "credentials.json",
        "secrets.json",
        "secrets.yaml",
        "secrets.yml",
    ];
    const SECRET_CONFIG_EXTS: &[&str] = &["kdbx", "ovpn", "rdp", "tfvars"];
    const SAFE_TEMPLATE_SUFFIXES: &[&str] =
        &[".example", ".sample", ".template", ".dist", ".schema"];

    for raw_path in paths {
        let file_name = raw_path
            .rsplit(['/', '\\'])
            .next()
            .unwrap_or("")
            .trim()
            .to_ascii_lowercase();
        if file_name.is_empty() || file_name.ends_with(".pub") {
            continue;
        }
        if SAFE_TEMPLATE_SUFFIXES
            .iter()
            .any(|suf| file_name.ends_with(suf))
        {
            continue;
        }
        if PRIVATE_KEY_EXACT.contains(&file_name.as_str()) {
            return Some(SensitiveSecretKind::PrivateKey);
        }
        let ext = file_name.rsplit_once('.').map(|(_, e)| e).unwrap_or("");
        if !ext.is_empty() && PRIVATE_KEY_EXTS.contains(&ext) {
            return Some(SensitiveSecretKind::PrivateKey);
        }
        if SECRET_CONFIG_EXACT.contains(&file_name.as_str())
            || file_name.starts_with(".env.")
            || (file_name.starts_with("service-account") && file_name.ends_with(".json"))
            || (!ext.is_empty() && SECRET_CONFIG_EXTS.contains(&ext))
        {
            return Some(SensitiveSecretKind::ConnectionSecret);
        }
    }
    None
}

/// 离线检测同形异义字钓鱼域名（IDN Homograph Attack）与非信任源可执行文件直链
pub fn inspect_link_risk(raw_input: &str) -> Option<LinkRiskKind> {
    const DANGEROUS_EXEC_EXTS: &[&str] = &[
        "exe", "msi", "bat", "cmd", "scr", "vbs", "vbe", "js", "jse", "wsf", "hta", "ps1", "apk",
    ];
    const TRUSTED_DOWNLOAD_HOSTS: &[&str] = &[
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "app.webfooo.com",
        "apple.com",
        "microsoft.com",
    ];

    let trimmed = raw_input.trim();
    if trimmed.is_empty() || trimmed.len() > 4_096 {
        return None;
    }

    // 检测 `https://apple.com@evil.example` URL userinfo 欺骗
    if let Some((_scheme, after_scheme)) = trimmed.split_once("://") {
        let authority = after_scheme.split(['/', '?', '#']).next().unwrap_or("");
        if authority.contains('@') && classify_sensitive_text(trimmed).is_none() {
            return Some(LinkRiskKind::HomographPhishing);
        }
    }

    let lower_head: String = trimmed
        .chars()
        .take(12)
        .collect::<String>()
        .to_ascii_lowercase();
    let after_scheme_owned;
    let after_scheme: &str = if lower_head.starts_with("https://") {
        &trimmed[8..]
    } else if lower_head.starts_with("http://") {
        &trimmed[7..]
    } else {
        after_scheme_owned = trimmed.to_string();
        after_scheme_owned.as_str()
    };

    let (authority_raw, path_and_rest) = match after_scheme.find(['/', '?', '#']) {
        Some(pos) => (&after_scheme[..pos], &after_scheme[pos..]),
        None => (after_scheme, ""),
    };
    let host_port = authority_raw.rsplit('@').next().unwrap_or("").trim();
    let host = host_port
        .split(':')
        .next()
        .unwrap_or("")
        .trim()
        .to_lowercase();
    if host.is_empty() || !host.contains('.') {
        return None;
    }

    // 1. Punycode `xn--` 同形异义字编码预警
    if host.contains("xn--") {
        return Some(LinkRiskKind::HomographPhishing);
    }

    // 2. 同一域名标签内混排 ASCII 拉丁字母与西里尔/希腊视觉同形字母（如 `аррӏе.com`）
    for label in host.split('.') {
        let mut has_ascii_alpha = false;
        let mut has_confusable_script = false;
        for ch in label.chars() {
            let v = ch as u32;
            if ch.is_ascii_alphabetic() {
                has_ascii_alpha = true;
            } else if (0x0370..=0x052F).contains(&v) {
                has_confusable_script = true;
            }
        }
        if has_ascii_alpha && has_confusable_script {
            return Some(LinkRiskKind::HomographPhishing);
        }
    }

    // 3. 非可信主机的高危可执行脚本/安装器直链预警
    let is_trusted = TRUSTED_DOWNLOAD_HOSTS
        .iter()
        .any(|t| host == *t || host.ends_with(&format!(".{t}")));
    if !is_trusted && path_and_rest.starts_with('/') {
        let path_only = path_and_rest.split(['?', '#']).next().unwrap_or("");
        let last_seg = path_only.rsplit('/').next().unwrap_or("");
        if let Some((_, ext)) = last_seg.rsplit_once('.') {
            let ext_lower = ext.to_ascii_lowercase();
            if DANGEROUS_EXEC_EXTS.contains(&ext_lower.as_str()) {
                return Some(LinkRiskKind::ExecutableDownload);
            }
        }
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

    if ext != "csv" && ext != "tsv" && ext != "md" && ext != "markdown" {
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
            if ext == "md" || ext == "markdown" || looks_like_markdown_snippet_note(trimmed) {
                if let Some(md_res) = parse_markdown_snippets(trimmed) {
                    if !md_res.0.is_empty() {
                        return Some(md_res);
                    }
                }
            }
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

fn looks_like_markdown_snippet_note(trimmed: &str) -> bool {
    trimmed.lines().any(|line| {
        let l = line.trim_start();
        l.starts_with("## ") || l.starts_with("### ")
    })
}

fn unwrap_single_code_fence(block: &str) -> String {
    let lines: Vec<&str> = block.lines().collect();
    if lines.len() < 3 {
        return block.to_string();
    }
    let first = lines.first().copied().unwrap_or("").trim();
    let last = lines.last().copied().unwrap_or("").trim();
    let marker = if first.starts_with("```") && last == "```" {
        Some("```")
    } else if first.starts_with("~~~") && last == "~~~" {
        Some("~~~")
    } else {
        None
    };
    let Some(mk) = marker else {
        return block.to_string();
    };
    let inner = &lines[1..lines.len() - 1];
    if inner.iter().any(|l| l.trim_start().starts_with(mk)) {
        return block.to_string();
    }
    inner.join("\n")
}

fn parse_markdown_snippets(input: &str) -> Option<(Vec<ExternalImportCandidate>, String)> {
    let normalized = input.replace("\r\n", "\n");
    let all_lines: Vec<&str> = normalized.split('\n').collect();
    let mut lines: &[&str] = &all_lines;

    if lines.first().map(|s| s.trim()) == Some("---") {
        if let Some(close_rel) = lines
            .iter()
            .skip(1)
            .position(|s| matches!(s.trim(), "---" | "..."))
        {
            lines = &all_lines[close_rel + 2..];
        }
    }

    let mut sections: Vec<(String, Vec<&str>)> = Vec::new();
    let mut cur_title: Option<String> = None;
    let mut cur_body: Vec<&str> = Vec::new();
    let mut inside_fence = false;

    for &line in lines {
        let ws = line.trim();
        if ws.starts_with("```") || ws.starts_with("~~~") {
            inside_fence = !inside_fence;
            if cur_title.is_some() {
                cur_body.push(line);
            }
            continue;
        }
        if !inside_fence {
            if ws.starts_with("# ") {
                if let Some(prev) = cur_title.take() {
                    sections.push((prev, std::mem::take(&mut cur_body)));
                }
                continue;
            }
            if ws.starts_with("## ") || ws.starts_with("### ") {
                if let Some(prev) = cur_title.take() {
                    sections.push((prev, std::mem::take(&mut cur_body)));
                }
                let prefix_len = if ws.starts_with("### ") { 4 } else { 3 };
                let mut heading = ws[prefix_len..].trim_matches(['#', ' ']).trim().to_string();
                if heading.starts_with('`') && heading.ends_with('`') && heading.len() >= 3 {
                    heading = heading[1..heading.len() - 1].to_string();
                }
                cur_title = Some(heading);
                continue;
            }
            if ws == "---" || ws == "***" {
                continue;
            }
        }
        if cur_title.is_some() {
            cur_body.push(line);
        }
    }
    if let Some(prev) = cur_title.take() {
        sections.push((prev, cur_body));
    }

    let mut out = Vec::new();
    for (title, body_lines) in sections {
        let raw_sec = body_lines.join("\n");
        let raw_trimmed = raw_sec.trim();
        if raw_trimmed.is_empty() {
            continue;
        }
        let unwrapped = unwrap_single_code_fence(raw_trimmed);
        let final_body = unwrapped.trim();
        if final_body.is_empty() {
            continue;
        }
        let alias = if !title.is_empty() && title != final_body {
            Some(title.chars().take(80).collect::<String>())
        } else {
            None
        };
        out.push(ExternalImportCandidate {
            text: final_body.to_string(),
            alias,
            source_label: "Markdown 常用语笔记".to_string(),
        });
    }
    if out.is_empty() {
        None
    } else {
        Some((out, "Markdown 常用语笔记".to_string()))
    }
}

fn parse_json_competitor_payload(root: &Value) -> Option<(Vec<ExternalImportCandidate>, String)> {
    let mut format_name = "外部 JSON 收藏".to_string();
    let single_buf: Vec<Value>;
    let arr: &[Value] = match root {
        Value::Array(list) => {
            if list
                .first()
                .and_then(|v| v.as_object())
                .and_then(|o| o.get("alfredsnippet"))
                .is_some()
            {
                format_name = "Alfred 常用语".to_string();
                single_buf = list
                    .iter()
                    .filter_map(|v| v.get("alfredsnippet").cloned())
                    .collect();
                single_buf.as_slice()
            } else {
                if let Some(first) = list.first().and_then(|v| v.as_object()) {
                    if first.contains_key("keyword") && first.contains_key("text") {
                        format_name = "Raycast 常用语".to_string();
                    } else if first.contains_key("abbreviation")
                        && (first.contains_key("plainText") || first.contains_key("string"))
                    {
                        format_name = "TextExpander 常用语".to_string();
                    } else if first.contains_key("pin") || first.contains_key("application") {
                        format_name = "Maccy 剪贴记录".to_string();
                    }
                }
                list.as_slice()
            }
        }
        Value::Object(map) => {
            if map.get("format").and_then(|v| v.as_str()) == Some(crate::archive::ARCHIVE_FORMAT_ID)
            {
                return None;
            }
            if let Some(single_alfred) = map.get("alfredsnippet") {
                format_name = "Alfred 常用语".to_string();
                single_buf = vec![single_alfred.clone()];
                single_buf.as_slice()
            } else {
                let mut found = None;
                for key in [
                    "snippets",
                    "snippetPlists",
                    "items",
                    "pins",
                    "history",
                    "clips",
                    "data",
                    "records",
                ] {
                    if let Some(sub) = map.get(key).and_then(|v| v.as_array()) {
                        if !sub.is_empty() {
                            if sub
                                .first()
                                .and_then(|v| v.as_object())
                                .and_then(|o| o.get("alfredsnippet"))
                                .is_some()
                            {
                                format_name = "Alfred 常用语".to_string();
                                single_buf = sub
                                    .iter()
                                    .filter_map(|v| v.get("alfredsnippet").cloned())
                                    .collect();
                                found = Some(single_buf.as_slice());
                            } else {
                                if key == "snippetPlists"
                                    || sub
                                        .first()
                                        .and_then(|v| v.as_object())
                                        .map(|o| o.contains_key("abbreviation"))
                                        .unwrap_or(false)
                                {
                                    format_name = "TextExpander 常用语".to_string();
                                } else if key == "snippets" {
                                    format_name = "常用语片段包".to_string();
                                } else if key == "pins" {
                                    format_name = "Maccy / Paste 收藏".to_string();
                                }
                                found = Some(sub.as_slice());
                            }
                            break;
                        }
                    }
                }
                found?
            }
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

        let raw_alias = [
            "title",
            "name",
            "alias",
            "customAlias",
            "label",
            "keyword",
            "abbreviation",
        ]
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

// ============================================================================
// 4. 硬件级 CSPRNG 零离手强密码与随机密钥生成器（阻断 Win+V / 云同步 + 45s 自动擦除）
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SecurePasswordCandidate {
    pub secret_value: String,
    pub subtitle: String,
    pub ephemeral_toast: String,
    pub default_vault_alias: String,
}

#[derive(Clone, Copy)]
enum PasswordSpecKind {
    StrongPassword { len: usize, include_symbols: bool },
    NumericPin { len: usize },
    HexSecretKey { byte_count: usize },
}

static PW_GEN_EPOCH: AtomicU64 = AtomicU64::new(0);
static PW_SESSION_SEED: OnceLock<[u8; 32]> = OnceLock::new();

fn pw_session_seed() -> &'static [u8; 32] {
    PW_SESSION_SEED.get_or_init(|| {
        let mut s = [0u8; 32];
        fill_os_csprng(&mut s);
        s
    })
}

/// 每次键入或保存生成密码后推进轮次，使界面悬停重绘零跳变，而下次输入 `@pw` 必定生成全新密码
pub fn bump_password_generation_salt() {
    PW_GEN_EPOCH.fetch_add(1, Ordering::Relaxed);
}

pub fn evaluate_secure_password_query(raw_query: &str) -> Option<SecurePasswordCandidate> {
    let (spec, norm_key) = parse_password_spec(raw_query)?;
    let epoch = PW_GEN_EPOCH.load(Ordering::Relaxed);
    let tag = format!("{epoch}|{norm_key}");
    Some(build_password_candidate(spec, Some(&tag)))
}

pub fn expand_quick_capture_secret_body(raw_body: &str) -> Option<String> {
    let (spec, _) = parse_password_spec(raw_body)?;
    bump_password_generation_salt();
    Some(build_password_candidate(spec, None).secret_value)
}

fn parse_password_spec(raw_input: &str) -> Option<(PasswordSpecKind, String)> {
    let trimmed = raw_input.trim();
    let rest_after_at = trimmed
        .strip_prefix('@')
        .or_else(|| trimmed.strip_prefix('＠'))?;
    let normalized = format!("@{rest_after_at}");
    let lower = normalized.to_lowercase();
    let tokens: Vec<&str> = lower.split_whitespace().collect();
    let head = *tokens.first()?;

    if matches!(head, "@genkey" | "@hexkey" | "@随机密钥" | "@生成密钥") {
        let req = tokens
            .iter()
            .skip(1)
            .find_map(|t| t.parse::<usize>().ok())
            .unwrap_or(32)
            .clamp(16, 64);
        return Some((
            PasswordSpecKind::HexSecretKey { byte_count: req },
            format!("hex:{req}"),
        ));
    }

    // 严密避开 `@pin` 收藏筛选词
    if matches!(head, "@pin码" | "@随机码" | "@数字码" | "@genpin")
        || (head == "@pw" && tokens.contains(&"pin"))
    {
        let req = tokens
            .iter()
            .skip(1)
            .find_map(|t| t.parse::<usize>().ok())
            .unwrap_or(6)
            .clamp(4, 12);
        return Some((
            PasswordSpecKind::NumericPin { len: req },
            format!("pin:{req}"),
        ));
    }

    if !matches!(head, "@pw" | "@密码" | "@强密码" | "@生成密码" | "@genpw") {
        return None;
    }

    let no_symbols = lower.contains("无符号")
        || lower.contains("纯字母")
        || lower.contains("nosym")
        || lower.contains("alnum");
    let len = tokens
        .iter()
        .skip(1)
        .find_map(|t| t.parse::<usize>().ok())
        .unwrap_or(20)
        .clamp(8, 64);
    Some((
        PasswordSpecKind::StrongPassword {
            len,
            include_symbols: !no_symbols,
        },
        format!("pw:{len}:{}", if no_symbols { 0 } else { 1 }),
    ))
}

struct ByteStreamGen<'a> {
    tag: Option<&'a str>,
    counter: u64,
    buf: [u8; 32],
    offset: usize,
}

impl<'a> ByteStreamGen<'a> {
    fn new(tag: Option<&'a str>) -> Self {
        Self {
            tag,
            counter: 0,
            buf: [0u8; 32],
            offset: 32,
        }
    }

    fn next_byte(&mut self) -> u8 {
        if self.offset >= 32 {
            self.offset = 0;
            if let Some(t) = self.tag {
                let msg = format!("{t}|{}", self.counter);
                self.counter = self.counter.wrapping_add(1);
                self.buf = hmac_sha256(pw_session_seed(), msg.as_bytes());
            } else {
                fill_os_csprng(&mut self.buf);
            }
        }
        let b = self.buf[self.offset];
        self.offset += 1;
        b
    }

    fn next_index(&mut self, upper: usize) -> usize {
        if upper <= 1 {
            return 0;
        }
        let limit = 256 - (256 % upper);
        loop {
            let b = self.next_byte() as usize;
            if b < limit {
                return b % upper;
            }
        }
    }
}

fn build_password_candidate(spec: PasswordSpecKind, tag: Option<&str>) -> SecurePasswordCandidate {
    let mut rng = ByteStreamGen::new(tag);
    match spec {
        PasswordSpecKind::HexSecretKey { byte_count } => {
            let mut hex = String::with_capacity(byte_count * 2);
            for _ in 0..byte_count {
                let b = rng.next_byte();
                hex.push_str(&format!("{b:02x}"));
            }
            let bits = byte_count * 8;
            SecurePasswordCandidate {
                secret_value: hex,
                subtitle: format!("CSPRNG {bits}-bit 随机密钥 · 禁Win+V/云同步 · 45s擦除"),
                ephemeral_toast: format!("已无痕键入 {bits}-bit 随机密钥（45s后自动擦除）"),
                default_vault_alias: format!("随机密钥 ({bits}-bit)"),
            }
        }
        PasswordSpecKind::NumericPin { len } => {
            let digits = b"0123456789";
            let mut out = String::with_capacity(len);
            for _ in 0..len {
                out.push(digits[rng.next_index(digits.len())] as char);
            }
            SecurePasswordCandidate {
                secret_value: out,
                subtitle: format!("CSPRNG {len} 位随机数字码 · 禁Win+V/云同步 · 45s擦除"),
                ephemeral_toast: format!("已无痕键入 {len} 位随机数字码（45s后自动擦除）"),
                default_vault_alias: "随机数字码".to_string(),
            }
        }
        PasswordSpecKind::StrongPassword {
            len,
            include_symbols,
        } => {
            let upper = b"ABCDEFGHJKLMNPQRSTUVWXYZ";
            let lower = b"abcdefghijkmnopqrstuvwxyz";
            let digits = b"23456789";
            let symbols = b"!@#$%^&*-_=+?";

            let mut pool = Vec::with_capacity(80);
            pool.extend_from_slice(upper);
            pool.extend_from_slice(lower);
            pool.extend_from_slice(digits);
            if include_symbols {
                pool.extend_from_slice(symbols);
            }

            let mut chars = Vec::with_capacity(len);
            chars.push(upper[rng.next_index(upper.len())]);
            chars.push(lower[rng.next_index(lower.len())]);
            chars.push(digits[rng.next_index(digits.len())]);
            if include_symbols {
                chars.push(symbols[rng.next_index(symbols.len())]);
            }
            while chars.len() < len {
                chars.push(pool[rng.next_index(pool.len())]);
            }
            for i in (1..chars.len()).rev() {
                let j = rng.next_index(i + 1);
                chars.swap(i, j);
            }
            let pw = String::from_utf8(chars).unwrap_or_default();
            let mode = if include_symbols {
                "含符号"
            } else {
                "纯字母数字"
            };
            SecurePasswordCandidate {
                secret_value: pw,
                subtitle: format!("CSPRNG {len}位强密码({mode}) · 禁Win+V/云同步 · 45s擦除"),
                ephemeral_toast: format!("已无痕键入 {len} 位强密码（本地隔离 · 45s后擦除）"),
                default_vault_alias: format!("随机强密码 ({len}位)"),
            }
        }
    }
}

// ============================================================================
// 8. 离线零联网 RFC 6238 TOTP 两步验证动态码直算引擎（纯 Rust 标准 SHA-1 / SHA-256 + Base32）
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TotpEvaluation {
    pub code: String,
    pub formatted_code: String,
    pub remaining_seconds: u32,
    pub period: u32,
}

pub fn decode_base32_rfc4648(encoded: &str) -> Option<Vec<u8>> {
    let mut buffer: u32 = 0;
    let mut bits_left: u32 = 0;
    let mut out = Vec::with_capacity(encoded.len() * 5 / 8 + 1);
    for b in encoded.bytes() {
        if b == b' ' || b == b'-' {
            continue;
        }
        if b == b'=' {
            break;
        }
        let five = match b {
            b'A'..=b'Z' => (b - b'A') as u32,
            b'a'..=b'z' => (b - b'a') as u32,
            b'2'..=b'7' => (b - b'2' + 26) as u32,
            _ => return None,
        };
        buffer = (buffer << 5) | five;
        bits_left += 5;
        if bits_left >= 8 {
            bits_left -= 8;
            out.push(((buffer >> bits_left) & 0xff) as u8);
        }
    }
    if out.len() >= 5 {
        Some(out)
    } else {
        None
    }
}

fn sha1_digest(message: &[u8]) -> [u8; 20] {
    let mut h0: u32 = 0x6745_2301;
    let mut h1: u32 = 0xEFCD_AB89;
    let mut h2: u32 = 0x98BA_DCFE;
    let mut h3: u32 = 0x1032_5476;
    let mut h4: u32 = 0xC3D2_E1F0;

    let bit_len = (message.len() as u64).wrapping_mul(8);
    let mut padded = Vec::with_capacity(((message.len() + 9 + 63) / 64) * 64);
    padded.extend_from_slice(message);
    padded.push(0x80);
    while (padded.len() % 64) != 56 {
        padded.push(0x00);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in padded.chunks_exact(64) {
        let mut w = [0u32; 80];
        for i in 0..16 {
            let s = i * 4;
            w[i] = u32::from_be_bytes([chunk[s], chunk[s + 1], chunk[s + 2], chunk[s + 3]]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }

        let mut a = h0;
        let mut b = h1;
        let mut c = h2;
        let mut d = h3;
        let mut e = h4;

        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | ((!b) & d), 0x5A82_7999u32),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1u32),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDCu32),
                _ => (b ^ c ^ d, 0xCA62_C1D6u32),
            };
            let temp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
        }

        h0 = h0.wrapping_add(a);
        h1 = h1.wrapping_add(b);
        h2 = h2.wrapping_add(c);
        h3 = h3.wrapping_add(d);
        h4 = h4.wrapping_add(e);
    }

    let mut out = [0u8; 20];
    out[0..4].copy_from_slice(&h0.to_be_bytes());
    out[4..8].copy_from_slice(&h1.to_be_bytes());
    out[8..12].copy_from_slice(&h2.to_be_bytes());
    out[12..16].copy_from_slice(&h3.to_be_bytes());
    out[16..20].copy_from_slice(&h4.to_be_bytes());
    out
}

fn hmac_sha1_var(key: &[u8], message: &[u8]) -> [u8; 20] {
    let mut k_block = [0u8; 64];
    if key.len() > 64 {
        let kh = sha1_digest(key);
        k_block[..20].copy_from_slice(&kh);
    } else {
        k_block[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= k_block[i];
        opad[i] ^= k_block[i];
    }
    let mut inner_in = Vec::with_capacity(64 + message.len());
    inner_in.extend_from_slice(&ipad);
    inner_in.extend_from_slice(message);
    let inner_hash = sha1_digest(&inner_in);

    let mut outer_in = [0u8; 64 + 20];
    outer_in[..64].copy_from_slice(&opad);
    outer_in[64..].copy_from_slice(&inner_hash);
    sha1_digest(&outer_in)
}

fn hmac_sha256_var(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut k_block = [0u8; 64];
    if key.len() > 64 {
        let mut h = Sha256::new();
        h.update(key);
        k_block[..32].copy_from_slice(&h.finalize());
    } else {
        k_block[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= k_block[i];
        opad[i] ^= k_block[i];
    }
    let mut inner = Sha256::new();
    inner.update(ipad);
    inner.update(message);
    let inner_digest = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(opad);
    outer.update(inner_digest);
    let mut out = [0u8; 32];
    out.copy_from_slice(&outer.finalize());
    out
}

pub fn evaluate_totp_uri(raw: &str, unix_secs: u64) -> Option<TotpEvaluation> {
    let trimmed = raw.trim();
    if trimmed.len() < 20 || trimmed.len() > 2048 {
        return None;
    }
    if !trimmed.as_bytes()[..15].eq_ignore_ascii_case(b"otpauth://totp/") {
        return None;
    }
    let q_pos = trimmed.find('?')?;
    let query = &trimmed[q_pos + 1..];
    let query_clean = query.split('#').next().unwrap_or(query);

    let mut secret_b32: Option<&str> = None;
    let mut digits: u32 = 6;
    let mut period: u32 = 30;
    let mut use_sha256 = false;

    for pair in query_clean.split('&') {
        let Some((k, v)) = pair.split_once('=') else {
            continue;
        };
        if k.eq_ignore_ascii_case("secret") {
            secret_b32 = Some(v.trim());
        } else if k.eq_ignore_ascii_case("digits") {
            if let Ok(d) = v.trim().parse::<u32>() {
                if matches!(d, 6..=8) {
                    digits = d;
                }
            }
        } else if k.eq_ignore_ascii_case("period") {
            if let Ok(p) = v.trim().parse::<u32>() {
                if (10..=120).contains(&p) {
                    period = p;
                }
            }
        } else if k.eq_ignore_ascii_case("algorithm") {
            let alg = v.trim();
            if alg.eq_ignore_ascii_case("sha256") || alg.eq_ignore_ascii_case("hmacsha256") {
                use_sha256 = true;
            }
        }
    }

    let key_bytes = decode_base32_rfc4648(secret_b32?)?;
    let counter = unix_secs / (period as u64);
    let counter_be = counter.to_be_bytes();

    let (bin_code, rem) = if use_sha256 {
        let mac = hmac_sha256_var(&key_bytes, &counter_be);
        let offset = (mac[31] & 0x0f) as usize;
        let code_u32 = (((mac[offset] & 0x7f) as u32) << 24)
            | ((mac[offset + 1] as u32) << 16)
            | ((mac[offset + 2] as u32) << 8)
            | (mac[offset + 3] as u32);
        (code_u32, period - ((unix_secs % (period as u64)) as u32))
    } else {
        let mac = hmac_sha1_var(&key_bytes, &counter_be);
        let offset = (mac[19] & 0x0f) as usize;
        let code_u32 = (((mac[offset] & 0x7f) as u32) << 24)
            | ((mac[offset + 1] as u32) << 16)
            | ((mac[offset + 2] as u32) << 8)
            | (mac[offset + 3] as u32);
        (code_u32, period - ((unix_secs % (period as u64)) as u32))
    };

    let modulo = match digits {
        8 => 100_000_000,
        7 => 10_000_000,
        _ => 1_000_000,
    };
    let val = bin_code % modulo;
    let code = format!("{val:0width$}", width = digits as usize);
    let formatted_code = match code.len() {
        6 => format!("{} {}", &code[..3], &code[3..]),
        8 => format!("{} {}", &code[..4], &code[4..]),
        _ => code.clone(),
    };

    Some(TotpEvaluation {
        code,
        formatted_code,
        remaining_seconds: rem,
        period,
    })
}

// ============================================================================
// 9. `.env` 环境变量配置一键生成安全 `.env.example` 净模板引擎
// ============================================================================

pub fn generate_env_example_template(raw: &str) -> Option<String> {
    if raw.len() > 65_536 || !raw.contains('=') || !raw.contains('\n') {
        return None;
    }
    let lines: Vec<&str> = raw.split('\n').collect();
    if lines.len() < 2 {
        return None;
    }

    static ENV_LINE_RE: OnceLock<Regex> = OnceLock::new();
    let re = ENV_LINE_RE.get_or_init(|| {
        Regex::new(r"^(\s*(?:export\s+)?)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)(.*)$").unwrap()
    });
    const SENSITIVE_MARKERS: &[&str] = &[
        "KEY",
        "SECRET",
        "TOKEN",
        "PASS",
        "PWD",
        "AUTH",
        "PRIVATE",
        "CERT",
        "CREDENTIAL",
        "WEBHOOK",
        "COOKIE",
        "DSN",
        "MNEMONIC",
        "SEED",
    ];

    let mut valid_assignments = 0usize;
    let mut mutated_count = 0usize;
    let mut out_lines = Vec::with_capacity(lines.len());

    for raw_line in lines {
        let has_cr = raw_line.ends_with('\r');
        let line = if has_cr {
            &raw_line[..raw_line.len() - 1]
        } else {
            raw_line
        };
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            out_lines.push(raw_line.to_string());
            continue;
        }
        let Some(caps) = re.captures(line) else {
            if trimmed.starts_with('{')
                || trimmed.starts_with('}')
                || trimmed.starts_with('<')
                || trimmed.ends_with(';')
            {
                return None;
            }
            out_lines.push(raw_line.to_string());
            continue;
        };

        valid_assignments += 1;
        let prefix = caps.get(1).map(|m| m.as_str()).unwrap_or("");
        let key = caps.get(2).map(|m| m.as_str()).unwrap_or("");
        let eq = caps.get(3).map(|m| m.as_str()).unwrap_or("=");
        let val_part = caps.get(4).map(|m| m.as_str()).unwrap_or("").trim();

        if val_part.is_empty() {
            out_lines.push(raw_line.to_string());
            continue;
        }

        let quote = if val_part.len() >= 2 && val_part.starts_with('"') && val_part.ends_with('"') {
            "\""
        } else if val_part.len() >= 2 && val_part.starts_with('\'') && val_part.ends_with('\'') {
            "'"
        } else {
            ""
        };
        let inner = if quote.is_empty() {
            val_part
        } else {
            &val_part[1..val_part.len() - 1]
        };

        let upper_key = key.to_ascii_uppercase();
        let key_sens = SENSITIVE_MARKERS.iter().any(|m| upper_key.contains(m));
        let val_sens = classify_sensitive_text(&format!("{key}={inner}")).is_some()
            || classify_sensitive_text(inner).is_some();

        if key_sens || val_sens {
            let lower_inner = inner.to_ascii_lowercase();
            let placeholder = if lower_inner.starts_with("postgres://")
                || lower_inner.starts_with("postgresql://")
            {
                "postgresql://user:password@localhost:5432/dbname".to_string()
            } else if lower_inner.starts_with("mysql://") {
                "mysql://user:password@localhost:3306/dbname".to_string()
            } else if lower_inner.starts_with("mongodb://")
                || lower_inner.starts_with("mongodb+srv://")
            {
                "mongodb://user:password@localhost:27017/dbname".to_string()
            } else if lower_inner.starts_with("redis://") || lower_inner.starts_with("rediss://") {
                "redis://:password@localhost:6379/0".to_string()
            } else {
                format!("your_{}_here", key.to_ascii_lowercase())
            };
            if placeholder != inner {
                mutated_count += 1;
            }
            let suffix = if has_cr { "\r" } else { "" };
            out_lines.push(format!(
                "{prefix}{key}{eq}{quote}{placeholder}{quote}{suffix}"
            ));
        } else {
            out_lines.push(raw_line.to_string());
        }
    }

    if valid_assignments >= 2 && mutated_count >= 1 {
        Some(out_lines.join("\n"))
    } else {
        None
    }
}

pub fn is_security_audit_query(raw: &str) -> bool {
    let q = raw.trim().to_lowercase();
    matches!(
        q.as_str(),
        "@安全" | "@体检" | "@隐私体检" | "@shield" | "@audit"
    )
}

// ============================================================================
// 10. 零知识端到端认证加密密文信封（`@锁 口令` 加锁外发 / `@解锁 口令` 无痕阅后即焚，与 macOS `ICLPMSG1:` 100% 字节级互解）
// ============================================================================

pub const SECRET_CAPSULE_PREFIX: &str = "ICLPMSG1:";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecretCapsuleCommand {
    LockReady {
        passphrase: String,
        plain_source: String,
        is_inline_body: bool,
    },
    LockAwaitingInput {
        hint: String,
    },
    UnlockDecrypted {
        decrypted_plain: String,
    },
    UnlockPending {
        has_target_capsule: bool,
        attempted_passphrase: bool,
    },
}

pub fn contains_secret_capsule(raw: Option<&str>) -> bool {
    let Some(s) = raw else { return false };
    if !s.contains(SECRET_CAPSULE_PREFIX) {
        return false;
    }
    static CAP_RE: OnceLock<Regex> = OnceLock::new();
    let re = CAP_RE.get_or_init(|| Regex::new(r"ICLPMSG1:([A-Za-z0-9_-]{80,})").unwrap());
    re.is_match(s)
}

pub fn seal_secret_capsule(plain_text: &str, passphrase: &str, seed_dir: &Path) -> Option<String> {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};

    let pw = passphrase.trim();
    if plain_text.is_empty() || pw.is_empty() || plain_text.len() > 65_536 {
        return None;
    }
    let sealed = seal_archive_with_passphrase(plain_text.as_bytes(), pw, seed_dir);
    let b64 = URL_SAFE_NO_PAD.encode(&sealed);
    Some(format!(
        "🔒[iClip密文·口令解锁] {SECRET_CAPSULE_PREFIX}{b64}"
    ))
}

pub fn open_secret_capsule(raw_envelope: &str, passphrase: &str) -> Option<String> {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};

    let pw = passphrase.trim();
    if pw.is_empty() || !raw_envelope.contains(SECRET_CAPSULE_PREFIX) {
        return None;
    }
    static CAP_RE: OnceLock<Regex> = OnceLock::new();
    let re = CAP_RE.get_or_init(|| Regex::new(r"ICLPMSG1:([A-Za-z0-9_-]{80,})").unwrap());
    let caps = re.captures(raw_envelope)?;
    let b64_part = caps.get(1)?.as_str();
    let cipher_bytes = URL_SAFE_NO_PAD.decode(b64_part).ok()?;
    let plain_bytes = open_encrypted_archive_bytes(&cipher_bytes, pw)?;
    String::from_utf8(plain_bytes).ok()
}

pub fn evaluate_secret_capsule_command(
    query: &str,
    latest_plain_candidate: Option<&str>,
    latest_capsule_candidate: Option<&str>,
) -> Option<SecretCapsuleCommand> {
    let trimmed = query.trim();
    if !trimmed.starts_with('@') {
        return None;
    }
    let lower = trimmed.to_lowercase();

    for p in ["@锁", "@加密", "@lock"] {
        if lower == p || lower.starts_with(&format!("{p} ")) || lower.starts_with(&format!("{p}\t"))
        {
            let rest = trimmed[p.len()..].trim();
            if rest.is_empty() {
                return Some(SecretCapsuleCommand::LockAwaitingInput {
                    hint: "输入口令加密首条剪贴（如 @锁 8866）或 @锁 8866 :: 正文".to_string(),
                });
            }
            for sep in ["::", "：："] {
                if let Some((left, right)) = rest.split_once(sep) {
                    let pw = left.trim();
                    let body = right.trim();
                    if pw.is_empty() {
                        return Some(SecretCapsuleCommand::LockAwaitingInput {
                            hint: format!("请在 {sep} 左侧填写加密口令"),
                        });
                    }
                    if body.is_empty() {
                        return Some(SecretCapsuleCommand::LockAwaitingInput {
                            hint: format!("请在 {sep} 右侧输入要端到端加锁的机密正文"),
                        });
                    }
                    return Some(SecretCapsuleCommand::LockReady {
                        passphrase: pw.to_string(),
                        plain_source: body.to_string(),
                        is_inline_body: true,
                    });
                }
            }
            if let Some(fb) = latest_plain_candidate
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                return Some(SecretCapsuleCommand::LockReady {
                    passphrase: rest.to_string(),
                    plain_source: fb.to_string(),
                    is_inline_body: false,
                });
            }
            return Some(SecretCapsuleCommand::LockAwaitingInput {
                hint: format!("当前无可用纯文本剪贴，可使用 @锁 {rest} :: 机密正文"),
            });
        }
    }

    for p in ["@解锁", "@解密", "@unlock"] {
        if lower == p || lower.starts_with(&format!("{p} ")) || lower.starts_with(&format!("{p}\t"))
        {
            let pw = trimmed[p.len()..].trim();
            let Some(cap) = latest_capsule_candidate.filter(|c| contains_secret_capsule(Some(c)))
            else {
                return Some(SecretCapsuleCommand::UnlockPending {
                    has_target_capsule: false,
                    attempted_passphrase: !pw.is_empty(),
                });
            };
            if pw.is_empty() {
                return Some(SecretCapsuleCommand::UnlockPending {
                    has_target_capsule: true,
                    attempted_passphrase: false,
                });
            }
            if let Some(plain) = open_secret_capsule(cap, pw) {
                return Some(SecretCapsuleCommand::UnlockDecrypted {
                    decrypted_plain: plain,
                });
            }
            return Some(SecretCapsuleCommand::UnlockPending {
                has_target_capsule: true,
                attempted_passphrase: true,
            });
        }
    }

    None
}

// ============================================================================
// 11. OWASP CWE-1236 电子表格公式注入护盾 & 纯内存双向 AI 替身沙盒（ReversiblePrivacyTwin）
// ============================================================================

/// 防御 Excel / WPS / Numbers / Google Sheets 公式与 DDE 命令注入（`=CMD|...`、`+HYPERLINK(...)`、`@SUM(...)`），
/// 同时精准豁免合法负数、百分比与国际电话号码（如 `-128.50`、`-3.14%`、`+86-13800138000`），保持数值求和无损
pub fn sanitize_spreadsheet_cell(raw: &str) -> String {
    if raw.is_empty() || raw.starts_with('\'') {
        return raw.to_string();
    }
    let trimmed_lead = raw.trim_start_matches(' ');
    let Some(first) = trimmed_lead.chars().next() else {
        return raw.to_string();
    };
    if matches!(first, '=' | '@' | '\t' | '\r') {
        return format!("'{raw}");
    }
    if first == '+' || first == '-' {
        let rest = &trimmed_lead[first.len_utf8()..];
        let has_digit = rest.bytes().any(|b| b.is_ascii_digit());
        let is_safe_numeric = has_digit
            && rest
                .chars()
                .all(|ch| ch.is_ascii_digit() || matches!(ch, '.' | ',' | '%' | ' ' | '-'));
        if !is_safe_numeric {
            return format!("'{raw}");
        }
    }
    raw.to_string()
}

struct TwinVaultState {
    entries_by_token: std::collections::HashMap<String, (String, u64)>,
    token_by_real: std::collections::HashMap<String, String>,
    category_counters: std::collections::HashMap<&'static str, usize>,
}

impl TwinVaultState {
    fn new() -> Self {
        Self {
            entries_by_token: std::collections::HashMap::new(),
            token_by_real: std::collections::HashMap::new(),
            category_counters: std::collections::HashMap::new(),
        }
    }

    fn prune_expired(&mut self, now_secs: u64) {
        let expired: Vec<String> = self
            .entries_by_token
            .iter()
            .filter_map(|(k, (_, exp))| {
                if *exp <= now_secs {
                    Some(k.clone())
                } else {
                    None
                }
            })
            .collect();
        for tok in expired {
            if let Some((real_val, _)) = self.entries_by_token.remove(&tok) {
                if self.token_by_real.get(&real_val) == Some(&tok) {
                    self.token_by_real.remove(&real_val);
                }
            }
        }
    }

    fn assign_token(&mut self, category: &'static str, real_val: &str, now_secs: u64) -> String {
        const TTL_SECS: u64 = 1_800;
        const MAX_ENTRIES: usize = 256;
        if let Some(existing) = self.token_by_real.get(real_val).cloned() {
            if let Some(entry) = self.entries_by_token.get_mut(&existing) {
                entry.1 = now_secs + TTL_SECS;
                return existing;
            }
        }
        if self.entries_by_token.len() >= MAX_ENTRIES {
            if let Some(oldest_tok) = self
                .entries_by_token
                .iter()
                .min_by_key(|(_, (_, exp))| *exp)
                .map(|(k, _)| k.clone())
            {
                if let Some((old_real, _)) = self.entries_by_token.remove(&oldest_tok) {
                    self.token_by_real.remove(&old_real);
                }
            }
        }
        let next_idx = self.category_counters.entry(category).or_insert(0);
        *next_idx += 1;
        let token = format!("[ICLIP_{category}_{next_idx}]");
        self.entries_by_token
            .insert(token.clone(), (real_val.to_string(), now_secs + TTL_SECS));
        self.token_by_real
            .insert(real_val.to_string(), token.clone());
        token
    }
}

thread_local! {
    static TWIN_VAULT: std::cell::RefCell<TwinVaultState> =
        std::cell::RefCell::new(TwinVaultState::new());
}

/// 锁屏、休眠、安全清扫、清空未收藏或进程退出时瞬时清零全部纯内存 AI 替身映射
pub fn wipe_privacy_twins() {
    TWIN_VAULT.with(|cell| {
        let mut guard = cell.borrow_mut();
        guard.entries_by_token.clear();
        guard.token_by_real.clear();
        guard.category_counters.clear();
    });
}

fn replace_full_matches_with_twins(
    input: &str,
    re: &Regex,
    category: &'static str,
    state: &mut TwinVaultState,
    now_secs: u64,
    count: &mut usize,
) -> String {
    let mut out = String::with_capacity(input.len());
    let mut last = 0usize;
    for m in re.find_iter(input) {
        let val = m.as_str();
        if val.starts_with("[ICLIP_") {
            continue;
        }
        out.push_str(&input[last..m.start()]);
        let tok = state.assign_token(category, val, now_secs);
        out.push_str(&tok);
        last = m.end();
        *count += 1;
    }
    out.push_str(&input[last..]);
    out
}

fn replace_group2_matches_with_twins(
    input: &str,
    re: &Regex,
    category: &'static str,
    state: &mut TwinVaultState,
    now_secs: u64,
    count: &mut usize,
) -> String {
    let mut out = String::with_capacity(input.len());
    let mut last = 0usize;
    for caps in re.captures_iter(input) {
        let Some(g2) = caps.get(2) else { continue };
        let val = g2.as_str();
        if val.starts_with("[ICLIP_")
            || val.contains("***")
            || val.to_ascii_lowercase().contains("redacted")
        {
            continue;
        }
        out.push_str(&input[last..g2.start()]);
        let tok = state.assign_token(category, val, now_secs);
        out.push_str(&tok);
        last = g2.end();
        *count += 1;
    }
    out.push_str(&input[last..]);
    out
}

/// 将文本中的敏感凭据、口令、身份证、银行卡、内网 IP、邮箱与手机号替换为一致性编号替身（如 `[ICLIP_KEY_1]`、`[ICLIP_IP_1]`）
pub fn mask_with_privacy_twins(raw: &str) -> Option<(String, usize)> {
    if raw.is_empty() || raw.len() > 65_536 {
        return None;
    }
    let now_secs = crate::model::now_unix_secs();
    TWIN_VAULT.with(|cell| {
        let mut state = cell.borrow_mut();
        state.prune_expired(now_secs);

        static PEM_RE: OnceLock<Regex> = OnceLock::new();
        static KEY_RE: OnceLock<Regex> = OnceLock::new();
        static URI_PW_RE: OnceLock<Regex> = OnceLock::new();
        static ENV_BEARER_RE: OnceLock<Regex> = OnceLock::new();
        static PRIV_IP_RE: OnceLock<Regex> = OnceLock::new();
        static EMAIL_RE: OnceLock<Regex> = OnceLock::new();
        static PHONE_RE: OnceLock<Regex> = OnceLock::new();

        let pem_re = PEM_RE.get_or_init(|| {
            Regex::new(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----").unwrap()
        });
        let key_re = KEY_RE.get_or_init(|| {
            Regex::new(r"\b(?:AGE-SECRET-KEY-1[A-Z0-9]{50,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|sk-(?:proj-|ant-|or-v1-)?[A-Za-z0-9_-]{18,}|(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{28,}|glpat-[A-Za-z0-9_-]{18,}|glsa_[A-Za-z0-9_-]{24,}|glc_[A-Za-z0-9_=+-]{24,}|dapi[a-fA-F0-9]{32}|re_[A-Za-z0-9_]{24,}|xox[baprs]-[A-Za-z0-9-]{18,}|AIzaSy[A-Za-z0-9_-]{31,}|hf_[A-Za-z0-9]{24,}|gsk_[A-Za-z0-9]{24,}|pplx-[A-Za-z0-9]{24,}|r8_[A-Za-z0-9]{24,}|ntn_[A-Za-z0-9]{24,}|secret_[A-Za-z0-9]{32,}|sbp_[a-fA-F0-9]{32,}|figd_[A-Za-z0-9_-]{24,}|lin_api_[A-Za-z0-9]{24,}|PMAK-[a-fA-F0-9]{24}-[a-fA-F0-9]{34}|dop_v1_[a-fA-F0-9]{64}|dckr_pat_[A-Za-z0-9_-]{20,}|hvs\.[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|LTAI[A-Za-z0-9]{12,24}|AKID[A-Za-z0-9]{13,32}|\d{8,10}:AA[A-Za-z0-9_-]{33}|npm_[A-Za-z0-9]{36}|pypi-[A-Za-z0-9_-]{40,}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,})\b").unwrap()
        });
        let uri_pw_re = URI_PW_RE.get_or_init(|| {
            Regex::new(r"(?i)\b((?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|rediss?|amqps?|clickhouse|https?)://[^:\s/@]*:)([^@\s/]{4,})(@)").unwrap()
        });
        let env_bearer_re = ENV_BEARER_RE.get_or_init(|| {
            Regex::new(r##"(?im)((?:^\s*(?:export\s+)?[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|API_KEY|ACCESS_KEY|PRIVATE_KEY|AUTH_TOKEN|CLIENT_SECRET)[A-Z0-9_]*\s*[:=]\s*['"]?)|(?:\bBearer\s+))([^\s'"#\[\]]{6,})"##).unwrap()
        });
        let priv_ip_re = PRIV_IP_RE.get_or_init(|| {
            Regex::new(r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3})\b").unwrap()
        });
        let email_re = EMAIL_RE.get_or_init(|| {
            Regex::new(r"\b[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]+\.[A-Za-z]{2,18}\b").unwrap()
        });
        let phone_re = PHONE_RE.get_or_init(|| Regex::new(r"\b1[3-9]\d{9}\b").unwrap());

        let mut out = raw.to_string();
        let mut count = 0usize;

        if out.contains("PRIVATE KEY") {
            out = replace_full_matches_with_twins(
                &out, pem_re, "KEY", &mut state, now_secs, &mut count,
            );
        }
        out = replace_full_matches_with_twins(&out, key_re, "KEY", &mut state, now_secs, &mut count);
        if out.contains("://") {
            out = replace_group2_matches_with_twins(
                &out, uri_pw_re, "SEC", &mut state, now_secs, &mut count,
            );
        }
        if out.contains('=') || out.contains(':') || out.to_ascii_lowercase().contains("bearer ") {
            out = replace_group2_matches_with_twins(
                &out,
                env_bearer_re,
                "SEC",
                &mut state,
                now_secs,
                &mut count,
            );
        }

        if contains_verified_identity_or_card(&out) {
            let bytes = out.as_bytes();
            let mut rebuilt = String::with_capacity(out.len());
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
                        let tok_val = &out[i..end];
                        if tok_val.len() == 18 && is_valid_chinese_id_card_18(tok_val) {
                            rebuilt.push_str(&out[last_copied..i]);
                            rebuilt.push_str(&state.assign_token("ID", tok_val, now_secs));
                            last_copied = end;
                            count += 1;
                        } else if (15..=19).contains(&tok_val.len())
                            && is_valid_bank_card_luhn(tok_val)
                        {
                            rebuilt.push_str(&out[last_copied..i]);
                            rebuilt.push_str(&state.assign_token("CARD", tok_val, now_secs));
                            last_copied = end;
                            count += 1;
                        }
                    }
                    i = end;
                } else {
                    i += 1;
                }
            }
            rebuilt.push_str(&out[last_copied..]);
            out = rebuilt;
        }

        if out.contains("10.") || out.contains("192.168.") || out.contains("172.") {
            out = replace_full_matches_with_twins(
                &out, priv_ip_re, "IP", &mut state, now_secs, &mut count,
            );
        }
        if out.contains('@') {
            out = replace_full_matches_with_twins(
                &out, email_re, "EMAIL", &mut state, now_secs, &mut count,
            );
        }
        if out.contains('1') {
            let mut rebuilt = String::with_capacity(out.len());
            let mut last = 0usize;
            for m in phone_re.find_iter(&out) {
                let prev_digit =
                    m.start() > 0 && out.as_bytes()[m.start() - 1].is_ascii_alphanumeric();
                let next_digit =
                    m.end() < out.len() && out.as_bytes()[m.end()].is_ascii_alphanumeric();
                if prev_digit || next_digit {
                    continue;
                }
                rebuilt.push_str(&out[last..m.start()]);
                rebuilt.push_str(&state.assign_token("PHONE", m.as_str(), now_secs));
                last = m.end();
                count += 1;
            }
            rebuilt.push_str(&out[last..]);
            out = rebuilt;
        }

        if count == 0 || out == raw {
            return None;
        }
        Some((out, count))
    })
}

/// 检测剪贴文本或 AI 回复中是否含本会话有效 `[ICLIP_*_N]` 替身占位符，若有则一键无损回填真值
pub fn inspect_restorable_privacy_twins(raw: &str) -> Option<(String, usize)> {
    if !raw.contains("[ICLIP_") || raw.len() > 131_072 {
        return None;
    }
    let now_secs = crate::model::now_unix_secs();
    TWIN_VAULT.with(|cell| {
        let mut state = cell.borrow_mut();
        state.prune_expired(now_secs);
        if state.entries_by_token.is_empty() {
            return None;
        }

        static TWIN_TOK_RE: OnceLock<Regex> = OnceLock::new();
        let re = TWIN_TOK_RE.get_or_init(|| {
            Regex::new(r"\[ICLIP_(?:KEY|SEC|IP|EMAIL|PHONE|ID|CARD)_\d+\]").unwrap()
        });

        let mut out = String::with_capacity(raw.len());
        let mut last = 0usize;
        let mut restored = 0usize;
        for m in re.find_iter(raw) {
            let tok = m.as_str();
            if let Some(entry) = state.entries_by_token.get_mut(tok) {
                entry.1 = now_secs + 1_800;
                out.push_str(&raw[last..m.start()]);
                out.push_str(&entry.0);
                last = m.end();
                restored += 1;
            }
        }
        out.push_str(&raw[last..]);
        if restored == 0 || out == raw {
            return None;
        }
        Some((out, restored))
    })
}

// ============================================================================
// 13. cURL 安全复现瘦身与容错 JSONC（注释 + 尾随逗号）一键净化引擎
// ============================================================================

pub fn sanitize_curl_for_repro(raw: &str) -> Option<(String, usize, usize)> {
    let trimmed = raw.trim();
    if !(12..=32_768).contains(&trimmed.len()) {
        return None;
    }
    if !trimmed
        .as_bytes()
        .get(..5)
        .map(|s| s.eq_ignore_ascii_case(b"curl ") || s.eq_ignore_ascii_case(b"curl\t"))
        .unwrap_or(false)
    {
        return None;
    }

    static CONT_RE: OnceLock<Regex> = OnceLock::new();
    let cont_re = CONT_RE.get_or_init(|| Regex::new(r"\\\r?\n\s*").unwrap());
    let joined = cont_re.replace_all(trimmed, " ");
    let tokens = tokenize_shell_words(&joined);
    if tokens.len() < 2 {
        return None;
    }

    const BROWSER_NOISE_HEADERS: &[&str] = &[
        "sec-ch-ua",
        "sec-ch-ua-mobile",
        "sec-ch-ua-platform",
        "sec-ch-ua-arch",
        "sec-ch-ua-bitness",
        "sec-ch-ua-full-version",
        "sec-ch-ua-full-version-list",
        "sec-ch-ua-model",
        "sec-fetch-dest",
        "sec-fetch-mode",
        "sec-fetch-site",
        "sec-fetch-user",
        "upgrade-insecure-requests",
        "priority",
        "dnt",
        "pragma",
        "cache-control",
        "accept-language",
        "accept-encoding",
        "user-agent",
        "connection",
        "keep-alive",
        "if-none-match",
        "if-modified-since",
    ];

    let mut method: Option<String> = None;
    let mut target_url: Option<String> = None;
    let mut kept_headers: Vec<String> = Vec::new();
    let mut extra_flags: Vec<String> = Vec::new();
    let mut body_args: Vec<(String, String)> = Vec::new();
    let mut redacted_count = 0usize;
    let mut removed_noise_count = 0usize;

    let mut idx = 1usize;
    while idx < tokens.len() {
        let tok = tokens[idx].as_str();
        match tok {
            "-X" | "--request" if idx + 1 < tokens.len() => {
                method = Some(tokens[idx + 1].to_ascii_uppercase());
                idx += 2;
                continue;
            }
            "-H" | "--header" if idx + 1 < tokens.len() => {
                let hdr = &tokens[idx + 1];
                if let Some((name_raw, val_raw)) = hdr.split_once(':') {
                    let name_orig = name_raw.trim();
                    let name_lower = name_orig.to_ascii_lowercase();
                    let val_orig = val_raw.trim();

                    if BROWSER_NOISE_HEADERS.contains(&name_lower.as_str())
                        || name_lower.starts_with("sec-ch-")
                        || name_lower.starts_with("sec-fetch-")
                    {
                        removed_noise_count += 1;
                    } else if val_orig.contains("[ICLIP_") {
                        kept_headers.push(format!("{name_orig}: {val_orig}"));
                    } else if name_lower == "authorization" || name_lower == "proxy-authorization" {
                        let v_lower = val_orig.to_ascii_lowercase();
                        if v_lower.starts_with("bearer ") {
                            kept_headers.push(format!("{name_orig}: Bearer $AUTH_TOKEN"));
                        } else if v_lower.starts_with("basic ") {
                            kept_headers.push(format!("{name_orig}: Basic $BASIC_AUTH"));
                        } else {
                            kept_headers.push(format!("{name_orig}: $AUTH_TOKEN"));
                        }
                        if !val_orig.contains('$') && !val_orig.contains("REDACTED") {
                            redacted_count += 1;
                        }
                    } else if name_lower == "cookie" || name_lower == "set-cookie" {
                        kept_headers.push(format!("{name_orig}: $REDACTED_COOKIE"));
                        if !val_orig.contains('$') && !val_orig.contains("REDACTED") {
                            redacted_count += 1;
                        }
                    } else if matches!(
                        name_lower.as_str(),
                        "x-api-key"
                            | "api-key"
                            | "apikey"
                            | "x-auth-token"
                            | "x-csrf-token"
                            | "x-xsrf-token"
                            | "x-access-token"
                    ) {
                        kept_headers.push(format!("{name_orig}: $API_KEY"));
                        if !val_orig.contains('$') && !val_orig.contains("REDACTED") {
                            redacted_count += 1;
                        }
                    } else {
                        let safe_val = crate::engines::redact_secrets(val_orig);
                        if safe_val != val_orig {
                            redacted_count += 1;
                        }
                        kept_headers.push(format!("{name_orig}: {safe_val}"));
                    }
                } else {
                    kept_headers.push(hdr.clone());
                }
                idx += 2;
                continue;
            }
            "-b" | "--cookie" if idx + 1 < tokens.len() => {
                let v = &tokens[idx + 1];
                extra_flags.push(format!("-b {}", shell_single_quote("$REDACTED_COOKIE")));
                if !v.contains('$') && !v.contains("REDACTED") {
                    redacted_count += 1;
                }
                idx += 2;
                continue;
            }
            "-u" | "--user" if idx + 1 < tokens.len() => {
                let v = &tokens[idx + 1];
                extra_flags.push(format!("-u {}", shell_single_quote("$API_USER:$API_PASS")));
                if !v.contains('$') && !v.contains("REDACTED") {
                    redacted_count += 1;
                }
                idx += 2;
                continue;
            }
            "-d" | "--data" | "--data-raw" | "--data-binary" | "--data-urlencode" | "--json"
                if idx + 1 < tokens.len() =>
            {
                let raw_body = &tokens[idx + 1];
                let safe_body = crate::engines::redact_secrets(raw_body);
                if &safe_body != raw_body {
                    redacted_count += 1;
                }
                body_args.push((tok.to_string(), safe_body));
                idx += 2;
                continue;
            }
            "--compressed" => {
                removed_noise_count += 1;
                idx += 1;
                continue;
            }
            "-L" | "--location" | "-k" | "--insecure" => {
                extra_flags.push(tok.to_string());
                idx += 1;
                continue;
            }
            _ => {
                let lower_tok = tok.to_ascii_lowercase();
                if (lower_tok.starts_with("http://") || lower_tok.starts_with("https://"))
                    && target_url.is_none()
                {
                    target_url = Some(tok.to_string());
                }
                idx += 1;
            }
        }
    }

    let raw_url = target_url?;
    let safe_url = if let Some(pub_clean) = crate::engines::sanitize_url_for_public_share(&raw_url)
    {
        redacted_count += 1;
        pub_clean
    } else {
        let red = crate::engines::redact_secrets(&raw_url);
        if red != raw_url {
            redacted_count += 1;
        }
        crate::engines::clean_tracking_url(&red).unwrap_or(red)
    };

    if redacted_count == 0 && removed_noise_count < 2 {
        return None;
    }

    let mut lines: Vec<String> = Vec::new();
    let mut first = "curl".to_string();
    if let Some(m) = &method {
        if m != "GET" || !body_args.is_empty() {
            first.push_str(&format!(" -X {m}"));
        }
    }
    for fl in &extra_flags {
        if matches!(fl.as_str(), "-L" | "--location" | "-k" | "--insecure") {
            first.push(' ');
            first.push_str(fl);
        }
    }
    first.push(' ');
    first.push_str(&shell_single_quote(&safe_url));
    lines.push(first);

    for fl in &extra_flags {
        if !matches!(fl.as_str(), "-L" | "--location" | "-k" | "--insecure") {
            lines.push(format!("  {fl}"));
        }
    }
    for hdr in &kept_headers {
        lines.push(format!("  -H {}", shell_single_quote(hdr)));
    }
    for (flag, payload) in &body_args {
        lines.push(format!("  {flag} {}", shell_single_quote(payload)));
    }

    let rebuilt = lines.join(" \\\n");
    if rebuilt == trimmed {
        None
    } else {
        Some((rebuilt, redacted_count, removed_noise_count))
    }
}

/// 字符串字面量感知的容错 JSONC（支持 `//` 单行注释、`/* */` 块注释与对象/数组尾随逗号）转标准合法缩进 JSON
pub fn clean_jsonc_to_strict_json(raw: &str) -> Option<String> {
    if !(4..=65_536).contains(&raw.len()) {
        return None;
    }
    let trimmed = raw.trim();
    if !trimmed.contains('{') && !trimmed.contains('[') {
        return None;
    }
    if serde_json::from_str::<Value>(trimmed).is_ok() {
        return None;
    }

    let no_comments = strip_comments_outside_strings(trimmed);
    let nc_trimmed = no_comments.trim();
    if !((nc_trimmed.starts_with('{') && nc_trimmed.ends_with('}'))
        || (nc_trimmed.starts_with('[') && nc_trimmed.ends_with(']')))
    {
        return None;
    }

    let strict_candidate = strip_trailing_commas_outside_strings(nc_trimmed);
    let val = serde_json::from_str::<Value>(&strict_candidate).ok()?;
    if !val.is_object() && !val.is_array() {
        return None;
    }
    serde_json::to_string_pretty(&val).ok()
}

fn strip_comments_outside_strings(input: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let n = chars.len();
    let mut out = String::with_capacity(input.len());
    let mut i = 0usize;
    let mut in_str = false;
    let mut escaped = false;

    while i < n {
        let ch = chars[i];
        if in_str {
            out.push(ch);
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_str = false;
            }
            i += 1;
            continue;
        }
        if ch == '"' {
            in_str = true;
            out.push(ch);
            i += 1;
            continue;
        }
        if ch == '/' && i + 1 < n {
            if chars[i + 1] == '/' {
                i += 2;
                while i < n && chars[i] != '\n' {
                    i += 1;
                }
                continue;
            } else if chars[i + 1] == '*' {
                i += 2;
                while i + 1 < n && !(chars[i] == '*' && chars[i + 1] == '/') {
                    i += 1;
                }
                i += 2;
                continue;
            }
        }
        out.push(ch);
        i += 1;
    }
    out
}

fn strip_trailing_commas_outside_strings(input: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let n = chars.len();
    let mut out = String::with_capacity(input.len());
    let mut i = 0usize;
    let mut in_str = false;
    let mut escaped = false;

    while i < n {
        let ch = chars[i];
        if in_str {
            out.push(ch);
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_str = false;
            }
            i += 1;
            continue;
        }
        if ch == '"' {
            in_str = true;
            out.push(ch);
            i += 1;
            continue;
        }
        if ch == ',' {
            let mut look = i + 1;
            while look < n && chars[look].is_whitespace() {
                look += 1;
            }
            if look < n && (chars[look] == '}' || chars[look] == ']') {
                i += 1;
                continue;
            }
        }
        out.push(ch);
        i += 1;
    }
    out
}

fn tokenize_shell_words(cmd: &str) -> Vec<String> {
    let mut tokens: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut in_single = false;
    let mut in_double = false;
    let mut escaped = false;

    for ch in cmd.chars() {
        if escaped {
            cur.push(ch);
            escaped = false;
            continue;
        }
        if in_single {
            if ch == '\'' {
                in_single = false;
            } else {
                cur.push(ch);
            }
            continue;
        }
        if in_double {
            if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_double = false;
            } else {
                cur.push(ch);
            }
            continue;
        }
        if ch == '\\' {
            escaped = true;
        } else if ch == '\'' {
            in_single = true;
        } else if ch == '"' {
            in_double = true;
        } else if ch.is_whitespace() {
            if !cur.is_empty() {
                tokens.push(std::mem::take(&mut cur));
            }
        } else {
            cur.push(ch);
        }
    }
    if !cur.is_empty() {
        tokens.push(cur);
    }
    tokens
}

fn shell_single_quote(val: &str) -> String {
    format!("'{}'", val.replace('\'', "'\\''"))
}

// ============================================================================
// 14. 乱码转义一键安全解码（Unicode \uXXXX / URL %XX / HTML 实体 + 内联防隐藏毒字符）与多行列表稳定去重
// ============================================================================

pub fn decode_escaped_text(raw: &str) -> Option<(String, String, String)> {
    if !(6..=32_768).contains(&raw.len()) {
        return None;
    }
    let trimmed = raw.trim();

    // 1. Unicode `\uXXXX` 转义（支持 UTF-16 代理对，至少含 2 处 `\uXXXX` 避免误伤单次转义）
    if trimmed.contains("\\u") {
        static UNI_ESC_RE: OnceLock<Regex> = OnceLock::new();
        let re = UNI_ESC_RE.get_or_init(|| Regex::new(r"\\u[0-9a-fA-F]{4}").unwrap());
        if re.find_iter(raw).take(2).count() >= 2 {
            if let Some(decoded) = decode_unicode_escapes(raw) {
                if decoded != raw {
                    let safe = sanitize_decoded_output(&decoded);
                    return Some((
                        safe,
                        "解码 Unicode 中文".to_string(),
                        "已将 \\uXXXX 转义解码为可读文本".to_string(),
                    ));
                }
            }
        }
    }

    // 2. UTF-8 `%XX` 百分号编码还原
    if trimmed.contains('%') {
        static PCT_RE: OnceLock<Regex> = OnceLock::new();
        let re = PCT_RE.get_or_init(|| Regex::new(r"(?:%[0-9a-fA-F]{2}){2,}").unwrap());
        if re.is_match(trimmed) {
            if let Some(unescaped) = decode_percent_utf8(raw) {
                if unescaped != raw && has_newly_decoded_non_ascii_or_uri_delim(raw, &unescaped) {
                    let safe = sanitize_decoded_output(&unescaped);
                    return Some((
                        safe,
                        "URL 解码还原".to_string(),
                        "已将 %XX 编码还原为可读中文/符号".to_string(),
                    ));
                }
            }
        }
    }

    // 3. HTML 实体转义
    if trimmed.contains('&') && trimmed.contains(';') {
        static HTML_ENT_RE: OnceLock<Regex> = OnceLock::new();
        let re = HTML_ENT_RE.get_or_init(|| {
            Regex::new(
                r"(?i)&(?:lt|gt|quot|apos|amp|nbsp|copy|reg|mdash|ndash|hellip|#\d{2,7}|#x[0-9a-fA-F]{2,6});",
            )
            .unwrap()
        });
        if re.is_match(trimmed) {
            let decoded = decode_html_entities(raw);
            if decoded != raw {
                let safe = sanitize_decoded_output(&decoded);
                return Some((
                    safe,
                    "解码 HTML 实体".to_string(),
                    "已解码 HTML 转义实体字符".to_string(),
                ));
            }
        }
    }

    None
}

pub fn deduplicate_list_lines(raw: &str) -> Option<(String, usize, usize)> {
    if !raw.contains('\n') || raw.len() > 65_536 {
        return None;
    }
    let normalized = raw.replace("\r\n", "\n").replace('\r', "\n");
    if looks_like_source_code_or_md_fence(&normalized) {
        return None;
    }

    let lines: Vec<&str> = normalized
        .split('\n')
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    if !(3..=2_000).contains(&lines.len()) {
        return None;
    }
    if lines.iter().any(|l| l.chars().count() > 140) {
        return None;
    }

    let mut seen = std::collections::HashSet::with_capacity(lines.len());
    let mut unique: Vec<&str> = Vec::with_capacity(lines.len());
    for line in &lines {
        if seen.insert(*line) {
            unique.push(*line);
        }
    }
    let removed = lines.len().saturating_sub(unique.len());
    if removed == 0 || unique.is_empty() {
        return None;
    }
    Some((unique.join("\n"), removed, unique.len()))
}

fn looks_like_source_code_or_md_fence(text: &str) -> bool {
    if text.contains("```") || text.contains("{\n") || text.contains("\n}") || text.contains(";\n")
    {
        return true;
    }
    const CODE_KEYWORDS: &[&str] = &[
        "func ", "def ", "class ", "struct ", "import ", "#include", "public ", "private ",
        "const ", "let ", "var ", "return ", "SELECT ", "FROM ",
    ];
    CODE_KEYWORDS.iter().any(|kw| text.contains(kw))
}

fn sanitize_decoded_output(decoded: &str) -> String {
    if matches!(
        inspect_clipboard_poison(decoded),
        Some(PoisonThreatKind::PastejackingOrBidi(_))
    ) {
        let clean = sanitize_clipboard_poison(decoded);
        if clean.is_empty() {
            decoded.to_string()
        } else {
            clean
        }
    } else {
        decoded.to_string()
    }
}

fn has_newly_decoded_non_ascii_or_uri_delim(orig: &str, decoded: &str) -> bool {
    let orig_non_ascii = orig.chars().filter(|c| !c.is_ascii()).count();
    let dec_non_ascii = decoded.chars().filter(|c| !c.is_ascii()).count();
    if dec_non_ascii > orig_non_ascii {
        return true;
    }
    let lower = orig.to_ascii_lowercase();
    lower.contains("%2f") || lower.contains("%3a")
}

fn decode_unicode_escapes(input: &str) -> Option<String> {
    let chars: Vec<char> = input.chars().collect();
    let n = chars.len();
    let mut out = String::with_capacity(input.len());
    let mut i = 0usize;
    let mut converted_any = false;

    let parse_hex4 = |pos: usize| -> Option<u16> {
        if pos + 4 > n {
            return None;
        }
        let s: String = chars[pos..pos + 4].iter().collect();
        u16::from_str_radix(&s, 16).ok()
    };

    while i < n {
        if chars[i] == '\\' && i + 5 < n && chars[i + 1] == 'u' {
            if let Some(u1) = parse_hex4(i + 2) {
                if (0xD800..=0xDBFF).contains(&u1)
                    && i + 11 < n
                    && chars[i + 6] == '\\'
                    && chars[i + 7] == 'u'
                {
                    if let Some(u2) = parse_hex4(i + 8) {
                        if (0xDC00..=0xDFFF).contains(&u2) {
                            let cp =
                                0x10000 + (((u1 - 0xD800) as u32) << 10 | ((u2 - 0xDC00) as u32));
                            if let Some(ch) = char::from_u32(cp) {
                                out.push(ch);
                                converted_any = true;
                                i += 12;
                                continue;
                            }
                        }
                    }
                } else if let Some(ch) = char::from_u32(u1 as u32) {
                    out.push(ch);
                    converted_any = true;
                    i += 6;
                    continue;
                }
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    if converted_any {
        Some(out)
    } else {
        None
    }
}

fn decode_percent_utf8(input: &str) -> Option<String> {
    let bytes = input.as_bytes();
    let mut out_bytes = Vec::with_capacity(bytes.len());
    let mut i = 0usize;
    let hex_val = |b: u8| -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            b'A'..=b'F' => Some(b - b'A' + 10),
            _ => None,
        }
    };

    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                out_bytes.push((h << 4) | l);
                i += 3;
                continue;
            }
        }
        out_bytes.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out_bytes).ok()
}

fn decode_html_entities(input: &str) -> String {
    let mut working = input.to_string();
    const NAMED: &[(&str, &str)] = &[
        ("&quot;", "\""),
        ("&QUOT;", "\""),
        ("&apos;", "'"),
        ("&#39;", "'"),
        ("&lt;", "<"),
        ("&LT;", "<"),
        ("&gt;", ">"),
        ("&GT;", ">"),
        ("&nbsp;", " "),
        ("&NBSP;", " "),
        ("&copy;", "©"),
        ("&reg;", "®"),
        ("&mdash;", "—"),
        ("&ndash;", "–"),
        ("&hellip;", "…"),
    ];
    for &(ent, rep) in NAMED {
        if working.contains(ent) {
            working = working.replace(ent, rep);
        }
    }
    static NUM_ENT_RE: OnceLock<Regex> = OnceLock::new();
    let re =
        NUM_ENT_RE.get_or_init(|| Regex::new(r"(?i)&#(?:x([0-9a-fA-F]{1,6})|(\d{1,7}));").unwrap());
    working = re
        .replace_all(&working, |caps: &regex_lite::Captures| {
            let code = if let Some(hx) = caps.get(1) {
                u32::from_str_radix(hx.as_str(), 16).ok()
            } else if let Some(dc) = caps.get(2) {
                dc.as_str().parse::<u32>().ok()
            } else {
                None
            };
            if let Some(ch) = code.filter(|&c| c > 0).and_then(char::from_u32) {
                ch.to_string()
            } else {
                caps.get(0).map(|m| m.as_str()).unwrap_or("").to_string()
            }
        })
        .into_owned();
    working.replace("&amp;", "&").replace("&AMP;", "&")
}

// ============================================================================
// 15. 速览文本实时 Token 标尺、离线 Cron 5段中文直译与跨平台路径斜杠/终端安全转义
// ============================================================================

pub fn text_metrics_summary(text: &str) -> String {
    let mut char_count = 0usize;
    let mut lines = 1usize;
    let mut ascii_count = 0usize;
    let mut non_ascii_count = 0usize;
    for ch in text.chars() {
        char_count += 1;
        if ch == '\n' {
            lines += 1;
        }
        if ch.is_ascii() {
            ascii_count += 1;
        } else {
            non_ascii_count += 1;
        }
    }
    if char_count == 0 {
        return "0 字".to_string();
    }
    let est_tokens =
        ((ascii_count as f64 * 0.26 + non_ascii_count as f64 * 1.15).round() as usize).max(1);
    if lines > 1 {
        format!("{char_count}字 · {lines}行 · ≈{est_tokens} tok")
    } else {
        format!("{char_count}字 · ≈{est_tokens} tok")
    }
}

pub fn explain_cron_expression(raw: &str) -> Option<(String, String)> {
    let original_clean = raw.trim();
    if original_clean.len() < 9 || original_clean.len() > 160 || original_clean.contains('\n') {
        return None;
    }

    let mut working = original_clean;
    let mut tz_label: Option<&str> = None;
    if working
        .as_bytes()
        .get(..8)
        .is_some_and(|b| b.eq_ignore_ascii_case(b"CRON_TZ="))
        && working.len() > 8
    {
        let mut split = working.splitn(2, char::is_whitespace);
        let first = split.next()?;
        let rest = split.next()?.trim_start();
        let tz = first[8..].trim_matches(|c| c == '"' || c == '\'');
        if !tz.is_empty() {
            tz_label = Some(tz);
        }
        working = rest;
    }

    let fields: Vec<&str> = working.split_whitespace().collect();
    if fields.len() != 5 {
        return None;
    }
    if !fields
        .iter()
        .any(|f| f.contains('*') || f.contains('/') || f.contains('-') || f.contains(','))
    {
        return None;
    }

    if !validate_cron_field(fields[0], 0, 59)
        || !validate_cron_field(fields[1], 0, 23)
        || !validate_cron_field(fields[2], 1, 31)
        || !validate_cron_field(fields[3], 1, 12)
        || !validate_cron_field(fields[4], 0, 7)
    {
        return None;
    }

    let (min_f, hour_f, dom_f, mon_f, dow_f) =
        (fields[0], fields[1], fields[2], fields[3], fields[4]);
    let mut segments: Vec<String> = Vec::new();
    if let Some(tz) = tz_label {
        segments.push(format!("[{tz}]"));
    }
    if mon_f != "*" {
        segments.push(describe_cron_month(mon_f));
    }
    if dom_f != "*" {
        segments.push(describe_cron_dom(dom_f));
    }
    if dow_f != "*" {
        segments.push(describe_cron_dow(dow_f));
    }
    segments.push(describe_cron_time(
        min_f,
        hour_f,
        dom_f != "*" || mon_f != "*" || dow_f != "*",
    ));

    let summary = segments.join(" ");
    let annotated = format!("# {summary}\n{original_clean}");
    Some((summary, annotated))
}

pub fn analyze_path_action(raw: &str) -> Option<(&'static str, String, String, String)> {
    let trimmed = raw.trim();
    if trimmed.len() < 4 || trimmed.len() > 512 || trimmed.contains('\n') || trimmed.contains('\r')
    {
        return None;
    }

    let bytes = trimmed.as_bytes();
    let is_win_drive =
        bytes.len() >= 4 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'\\';
    let is_unc = trimmed.starts_with("\\\\") && trimmed[2..].contains('\\');

    if is_win_drive || is_unc {
        let mut normalized = trimmed.replace("\\\\", "/").replace('\\', "/");
        if is_unc && !normalized.starts_with("//") {
            normalized.insert(0, '/');
        }
        if normalized != trimmed {
            return Some((
                "path-win-to-slash",
                "转为正斜杠 /".to_string(),
                normalized,
                "已将 Windows 反斜杠路径转为跨平台正斜杠".to_string(),
            ));
        }
    }

    if (trimmed.starts_with('/') || trimmed.starts_with("~/"))
        && trimmed.contains(' ')
        && !trimmed.starts_with('\'')
        && !trimmed.starts_with('"')
        && trimmed.chars().filter(|&c| c == '/').count() >= 2
    {
        let quoted = format!("'{}'", trimmed.replace('\'', "'\\''"));
        return Some((
            "path-shell-quote",
            "终端安全转义".to_string(),
            quoted,
            "已为含空格路径包裹 Shell 安全引号".to_string(),
        ));
    }

    None
}

fn validate_cron_field(field: &str, min: u32, max: u32) -> bool {
    if field.is_empty() {
        return false;
    }
    for part in field.split(',') {
        if part.is_empty() {
            return false;
        }
        let step_parts: Vec<&str> = part.split('/').collect();
        if step_parts.len() > 2 {
            return false;
        }
        if step_parts.len() == 2 {
            let Ok(step) = step_parts[1].parse::<u32>() else {
                return false;
            };
            if step < 1 || step > max {
                return false;
            }
        }
        let base = step_parts[0];
        if base == "*" {
            continue;
        }
        let range_parts: Vec<&str> = base.split('-').collect();
        match range_parts.len() {
            1 => {
                let Ok(v) = range_parts[0].parse::<u32>() else {
                    return false;
                };
                if v < min || v > max {
                    return false;
                }
            }
            2 => {
                let (Ok(a), Ok(b)) = (range_parts[0].parse::<u32>(), range_parts[1].parse::<u32>())
                else {
                    return false;
                };
                if a < min || b > max || a > b {
                    return false;
                }
            }
            _ => return false,
        }
    }
    true
}

fn describe_cron_month(f: &str) -> String {
    if let Ok(m) = f.parse::<u32>() {
        return format!("{m}月");
    }
    if let Some(step) = f.strip_prefix("*/") {
        return format!("每{step}个月");
    }
    format!("{f}月")
}

fn describe_cron_dom(f: &str) -> String {
    if let Ok(d) = f.parse::<u32>() {
        return format!("每月{d}日");
    }
    if let Some(step) = f.strip_prefix("*/") {
        return format!("每{step}天");
    }
    format!("每月{f}日")
}

fn describe_cron_dow(f: &str) -> String {
    if f == "1-5" {
        return "工作日".to_string();
    }
    if f == "0,6" || f == "6,0" || f == "6-7" {
        return "周末".to_string();
    }
    const NAMES: [&str; 8] = [
        "周日", "周一", "周二", "周三", "周四", "周五", "周六", "周日",
    ];
    if let Ok(w) = f.parse::<usize>() {
        if w <= 7 {
            return format!("每{}", NAMES[w]);
        }
    }
    let mapped: Vec<String> = f
        .split(',')
        .map(|sub| {
            if let Ok(v) = sub.parse::<usize>() {
                if v <= 7 {
                    return NAMES[v].to_string();
                }
            }
            sub.to_string()
        })
        .collect();
    mapped.join("/")
}

fn describe_cron_time(min_f: &str, hour_f: &str, has_date_scope: bool) -> String {
    let day_prefix = if has_date_scope { "" } else { "每天 " };
    if min_f == "*" && hour_f == "*" {
        return "每分钟".to_string();
    }
    if let Some(step) = min_f.strip_prefix("*/") {
        if hour_f == "*" {
            return format!("每 {step} 分钟");
        }
    }
    if let Ok(m) = min_f.parse::<u32>() {
        if hour_f == "*" {
            return if m == 0 {
                "每小时整点".to_string()
            } else {
                format!("每小时第 {m} 分")
            };
        }
        if let Some(h_step) = hour_f.strip_prefix("*/") {
            return format!("每 {h_step} 小时 (:{m:02})");
        }
        if let Ok(h) = hour_f.parse::<u32>() {
            return format!("{day_prefix}{h:02}:{m:02}");
        }
        if hour_f.contains('-') && !hour_f.contains('/') {
            let parts: Vec<&str> = hour_f.split('-').collect();
            if parts.len() == 2 {
                if let (Ok(h1), Ok(h2)) = (parts[0].parse::<u32>(), parts[1].parse::<u32>()) {
                    return format!("{day_prefix}{h1:02}:00–{h2:02}:59 第{m:02}分");
                }
            }
        }
    }
    format!("{day_prefix}{hour_f}时 {min_f}分")
}
