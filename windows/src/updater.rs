//! Windows 端纯原生零外部 HTTP/ZIP 依赖 OTA 更新引擎
//!
//! - 检查通道：GitHub `releases/latest` API（自动按当前编译角色匹配 `iClip-Dev-Windows-x64.zip` / `iClip-Flow-Windows-x64.zip`）
//! - 双源下载：优先走国内高速同源镜像 `https://app.webfooo.com/iClip/downloads/<asset>`，失败自动回退 GitHub Release 资产直链
//! - 安全门控：全链路 HTTPS 可信域名白名单（含重定向后 URL 复检）+ ZIP 魔数与体积边界 + Release Notes SHA-256 校验 + PE 头签名 (`MZ` / `PE\0\0`) + 自动清除 `Zone.Identifier` 隔离流
//! - 原地热替换：利用 Windows 允许重命名运行中 `.exe` 的机制（`MoveFileExW` -> `iClip.exe.old` -> 落位新版 -> 无缝拉起 -> 下次启动自动删 `.old`），零黑框闪现、失败自动回滚

use regex_lite::Regex;
use serde::Deserialize;
use sha2::{Digest, Sha256};

pub const GITHUB_LATEST_RELEASE_API: &str =
    "https://api.github.com/repos/fanaruto/iClip/releases/latest";
pub const WEBFOOO_MIRROR_BASE: &str = "https://app.webfooo.com/iClip/downloads";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OtaReleaseInfo {
    pub version: String,
    pub asset_name: String,
    pub primary_url: String,
    pub fallback_url: String,
    pub expected_sha256: Option<String>,
    pub release_notes: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OtaState {
    Idle,
    Checking,
    UpToDate {
        latest: String,
    },
    Available(OtaReleaseInfo),
    Downloading {
        info: OtaReleaseInfo,
        progress_pct: u8,
        downloaded_kb: u64,
        total_kb: u64,
    },
    Installing(OtaReleaseInfo),
    Failed(String),
}

impl OtaState {
    pub fn is_busy(&self) -> bool {
        matches!(
            self,
            OtaState::Checking | OtaState::Downloading { .. } | OtaState::Installing(_)
        )
    }

    pub fn available_version(&self) -> Option<&str> {
        match self {
            OtaState::Available(info)
            | OtaState::Downloading { info, .. }
            | OtaState::Installing(info) => Some(info.version.as_str()),
            _ => None,
        }
    }
}

/// 去掉版本号前导 `v` / `V` 与空白
pub fn normalize_version(raw: &str) -> String {
    raw.trim().trim_start_matches(['v', 'V']).trim().to_string()
}

/// 语义化版本比对：若 `lhs > rhs` 返回 `true`
pub fn is_version_newer(lhs: &str, rhs: &str) -> bool {
    let parse = |s: &str| -> Vec<u32> {
        normalize_version(s)
            .split(|c: char| !c.is_ascii_digit())
            .filter(|p| !p.is_empty())
            .filter_map(|p| p.parse::<u32>().ok())
            .collect()
    };
    let a = parse(lhs);
    let b = parse(rhs);
    if a.is_empty() {
        return false;
    }
    let n = a.len().max(b.len());
    for i in 0..n {
        let va = a.get(i).copied().unwrap_or(0);
        let vb = b.get(i).copied().unwrap_or(0);
        if va != vb {
            return va > vb;
        }
    }
    false
}

/// 当前版本期望匹配的 Windows 发行包名称（One iClip 默认优先统一包名，兼容历史包名）
pub fn expected_windows_asset_name(edition_key: &str) -> &'static str {
    if edition_key.eq_ignore_ascii_case("flow") {
        "iClip-Flow-Windows-x64.zip"
    } else if edition_key.eq_ignore_ascii_case("dev") {
        "iClip-Dev-Windows-x64.zip"
    } else {
        "iClip-Windows-x64.zip"
    }
}

/// 解析 HTTPS URL 为 `(host, port, path_and_query)`，拒绝非 HTTPS、含认证信息或非法控制符
pub fn parse_https_url(raw: &str) -> Option<(String, u16, String)> {
    let trimmed = raw.trim();
    let rest = trimmed.strip_prefix("https://")?;
    if rest.is_empty()
        || rest
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || c == '\\')
    {
        return None;
    }
    let (authority, path_part) = match rest.find('/') {
        Some(idx) => (&rest[..idx], &rest[idx..]),
        None => (rest, "/"),
    };
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) if !h.is_empty() => {
            let parsed = p.parse::<u16>().ok()?;
            (h.to_ascii_lowercase(), parsed)
        }
        _ => (authority.to_ascii_lowercase(), 443u16),
    };
    if host.is_empty()
        || !host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
    {
        return None;
    }
    Some((host, port, path_part.to_string()))
}

/// 与 macOS `UpdateManager.isTrustedRemoteDownloadURL` 对等的可信 HTTPS 域名白名单
pub fn is_trusted_download_url(url: &str) -> bool {
    let Some((host, port, _)) = parse_https_url(url) else {
        return false;
    };
    if port != 443 {
        return false;
    }
    matches!(
        host.as_str(),
        "app.webfooo.com"
            | "api.github.com"
            | "github.com"
            | "objects.githubusercontent.com"
            | "release-assets.githubusercontent.com"
            | "github-releases.githubusercontent.com"
            | "codeload.github.com"
    )
}

#[derive(Debug, Deserialize)]
struct GitHubReleaseDto {
    tag_name: String,
    #[serde(default)]
    body: String,
    #[serde(default)]
    assets: Vec<GitHubAssetDto>,
}

#[derive(Debug, Deserialize)]
struct GitHubAssetDto {
    name: String,
    #[serde(default)]
    digest: Option<String>,
    browser_download_url: String,
}

/// 严格校验远端 Asset 文件名（仅允许 ASCII 字母数字与 `._-`，严禁路径穿越符或控制字符）
pub fn is_safe_asset_filename(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && !name.contains("..")
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
}

/// 优先提取 GitHub REST API 原生 `asset.digest`（`sha256:<64-hex>`），无则从 Release Notes 校验表提取
pub fn resolve_expected_sha256(
    asset_digest: Option<&str>,
    body: &str,
    asset_name: &str,
) -> Option<String> {
    if let Some(raw) = asset_digest.map(str::trim) {
        if raw.len() == 71 && raw[..7].eq_ignore_ascii_case("sha256:") {
            let hex = &raw[7..];
            if hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Some(hex.to_ascii_lowercase());
            }
        }
    }
    extract_expected_sha256(body, asset_name)
}

/// 从 Release Notes 校验表中提取目标包名对应的 64 位十六进制 SHA-256（若发布说明包含）
pub fn extract_expected_sha256(body: &str, asset_name: &str) -> Option<String> {
    let hex_re = Regex::new(r"\b([0-9a-fA-F]{64})\b").ok()?;
    for line in body.lines() {
        if line.contains(asset_name) {
            if let Some(cap) = hex_re.captures(line) {
                if let Some(m) = cap.get(1) {
                    return Some(m.as_str().to_ascii_lowercase());
                }
            }
        }
    }
    None
}

/// 解析 GitHub `releases/latest` JSON，返回匹配的 Windows OTA 发行包信息
pub fn parse_github_release_json(
    json_bytes: &[u8],
    edition_key: &str,
) -> Result<OtaReleaseInfo, String> {
    let dto: GitHubReleaseDto =
        serde_json::from_slice(json_bytes).map_err(|e| format!("版本元数据解析失败：{e}"))?;
    let version = normalize_version(&dto.tag_name);
    if version.is_empty() {
        return Err("远端版本号为空".to_string());
    }

    let preferred = expected_windows_asset_name(edition_key);
    let matched = dto
        .assets
        .iter()
        .find(|a| a.name.eq_ignore_ascii_case(preferred))
        .or_else(|| {
            dto.assets
                .iter()
                .find(|a| a.name.eq_ignore_ascii_case("iClip-Windows-x64.zip"))
        })
        .or_else(|| {
            dto.assets
                .iter()
                .find(|a| a.name.eq_ignore_ascii_case("iClip-Dev-Windows-x64.zip"))
        })
        .ok_or_else(|| format!("最新发行版 v{version} 尚未包含 Windows 安装包（{preferred}）"))?;

    if !is_safe_asset_filename(&matched.name) {
        return Err("远端安装包文件名包含非法字符，已拦截".to_string());
    }
    if !is_trusted_download_url(&matched.browser_download_url) {
        return Err("远端下载地址未通过可信域名白名单校验".to_string());
    }

    let primary_url = format!("{WEBFOOO_MIRROR_BASE}/{}", matched.name);
    let expected_sha256 =
        resolve_expected_sha256(matched.digest.as_deref(), &dto.body, &matched.name);
    let summary = dto
        .body
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty() && !l.starts_with('#') && !l.starts_with("```"))
        .unwrap_or("包含性能、界面与安全体验优化")
        .chars()
        .take(72)
        .collect::<String>();

    Ok(OtaReleaseInfo {
        version,
        asset_name: matched.name.clone(),
        primary_url,
        fallback_url: matched.browser_download_url.clone(),
        expected_sha256,
        release_notes: summary,
    })
}

/// 校验下载完成的 ZIP 魔数、体积边界与可选 SHA-256 哈希
pub fn verify_zip_payload(data: &[u8], expected_sha256: Option<&str>) -> Result<String, String> {
    if data.len() < 64 * 1024 || data.len() > 25 * 1024 * 1024 {
        return Err(format!(
            "安装包体积异常（{} KB），已中止更新",
            data.len() / 1024
        ));
    }
    if !data.starts_with(&[0x50, 0x4B, 0x03, 0x04]) {
        return Err("安装包文件头非法（非有效 ZIP 归档）".to_string());
    }
    let mut hasher = Sha256::new();
    hasher.update(data);
    let digest = format!("{:x}", hasher.finalize());
    if let Some(exp) = expected_sha256 {
        if !digest.eq_ignore_ascii_case(exp.trim()) {
            return Err("安装包 SHA-256 完整性校验未通过，已拒绝安装".to_string());
        }
    }
    Ok(digest)
}

/// 校验解压出的 Windows 可执行文件 PE 结构（`MZ` DOS 头 + `PE\0\0` NT 头 + 合理体积）
pub fn verify_pe_executable(data: &[u8]) -> Result<(), String> {
    if data.len() < 128 * 1024 || data.len() > 30 * 1024 * 1024 {
        return Err(format!("可执行文件体积异常（{} KB）", data.len() / 1024));
    }
    if data.len() < 0x40 || &data[0..2] != b"MZ" {
        return Err("可执行文件缺少有效 MZ 头".to_string());
    }
    let pe_off = u32::from_le_bytes([data[0x3C], data[0x3D], data[0x3E], data[0x3F]]) as usize;
    if pe_off + 4 > data.len() || &data[pe_off..pe_off + 4] != b"PE\0\0" {
        return Err("可执行文件缺少有效 PE 签名".to_string());
    }
    Ok(())
}

// ============================================================================
// Windows 原生 WinHTTP 网络层与无感原子热替换执行层
// ============================================================================

#[cfg(target_os = "windows")]
pub mod win_runtime {
    use super::*;
    use std::ffi::c_void;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::ptr::{null, null_mut};
    use std::sync::atomic::{AtomicBool, Ordering};
    use windows_sys::Win32::Networking::WinHttp::{
        WinHttpCloseHandle, WinHttpConnect, WinHttpOpen, WinHttpOpenRequest,
        WinHttpQueryDataAvailable, WinHttpQueryHeaders, WinHttpQueryOption, WinHttpReadData,
        WinHttpReceiveResponse, WinHttpSendRequest, WinHttpSetTimeouts,
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_FLAG_SECURE, WINHTTP_OPTION_URL,
        WINHTTP_QUERY_CONTENT_LENGTH, WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_QUERY_STATUS_CODE,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    fn to_wide_z(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    struct WinHttpHandle(*mut c_void);
    impl Drop for WinHttpHandle {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe {
                    let _ = WinHttpCloseHandle(self.0);
                }
            }
        }
    }

    /// 每次启动时静默清扫上一次原地热更新遗留的 `iClip.exe.old` 与临时目录
    pub fn cleanup_stale_old_binary() {
        if let Ok(cur) = std::env::current_exe() {
            let old = cur.with_extension("exe.old");
            if old.exists() {
                let _ = fs::remove_file(&old);
            }
            let new_tmp = cur.with_extension("exe.new");
            if new_tmp.exists() {
                let _ = fs::remove_file(&new_tmp);
            }
        }
    }

    /// 通过 Windows 原生 WinHTTP 拉取 HTTPS 资源（支持自动系统代理、进度回调、实时取消与重定向白名单复检）
    pub fn winhttp_fetch_bytes<F>(
        url: &str,
        timeout_ms: i32,
        cancel_flag: Option<&AtomicBool>,
        mut on_progress: F,
    ) -> Result<Vec<u8>, String>
    where
        F: FnMut(u64, u64),
    {
        if !is_trusted_download_url(url) {
            return Err("请求地址不在可信 HTTPS 白名单内".to_string());
        }
        let (host, port, path_and_query) =
            parse_https_url(url).ok_or_else(|| "无效的 HTTPS 地址".to_string())?;

        unsafe {
            let ua = to_wide_z(concat!(
                "iClip-Windows-OTA/",
                env!("CARGO_PKG_VERSION"),
                " (+https://github.com/fanaruto/iClip)"
            ));
            let h_session = WinHttpHandle(WinHttpOpen(
                ua.as_ptr(),
                WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                null(),
                null(),
                0,
            ));
            if h_session.0.is_null() {
                return Err("初始化 WinHTTP 网络会话失败".to_string());
            }
            let _ = WinHttpSetTimeouts(
                h_session.0,
                timeout_ms.min(12_000),
                timeout_ms.min(15_000),
                timeout_ms,
                timeout_ms,
            );

            let host_w = to_wide_z(&host);
            let h_conn = WinHttpHandle(WinHttpConnect(h_session.0, host_w.as_ptr(), port, 0));
            if h_conn.0.is_null() {
                return Err(format!("无法连接更新服务器（{host}）"));
            }

            let verb_w = to_wide_z("GET");
            let path_w = to_wide_z(&path_and_query);
            let h_req = WinHttpHandle(WinHttpOpenRequest(
                h_conn.0,
                verb_w.as_ptr(),
                path_w.as_ptr(),
                null(),
                null(),
                null(),
                WINHTTP_FLAG_SECURE,
            ));
            if h_req.0.is_null() {
                return Err("创建 HTTPS 更新请求失败".to_string());
            }

            let headers = to_wide_z("Accept: application/vnd.github+json, application/octet-stream, */*\r\nCache-Control: no-cache\r\n");
            let sent = WinHttpSendRequest(
                h_req.0,
                headers.as_ptr(),
                (headers.len().saturating_sub(1)) as u32,
                null(),
                0,
                0,
                0,
            );
            if sent == 0 {
                return Err("发送更新请求失败，请检查网络连接".to_string());
            }

            if WinHttpReceiveResponse(h_req.0, null_mut()) == 0 {
                return Err("等待更新服务器响应超时".to_string());
            }

            // 对 302 重定向后的最终落点 URL 做强制 Fail-Closed 可信白名单校验（8192 UTF-16 兼容超长预签名 URL）
            let mut final_url_buf = vec![0u16; 8192];
            let mut final_url_bytes = (final_url_buf.len() * 2) as u32;
            if WinHttpQueryOption(
                h_req.0,
                WINHTTP_OPTION_URL,
                final_url_buf.as_mut_ptr() as *mut c_void,
                &mut final_url_bytes,
            ) == 0
            {
                return Err("无法核验最终下载源域名，已安全中止".to_string());
            }
            let u16_len = (final_url_bytes as usize / 2).min(final_url_buf.len());
            let final_url = String::from_utf16_lossy(&final_url_buf[..u16_len])
                .trim_end_matches('\0')
                .to_string();
            if final_url.is_empty() || !is_trusted_download_url(&final_url) {
                return Err("重定向目标域名不在安全白名单内，已拦截".to_string());
            }

            let mut status_code: u32 = 0;
            let mut status_len = std::mem::size_of::<u32>() as u32;
            if WinHttpQueryHeaders(
                h_req.0,
                WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                null(),
                (&mut status_code as *mut u32) as *mut c_void,
                &mut status_len,
                null_mut(),
            ) == 0
            {
                return Err("读取更新响应状态码失败".to_string());
            }
            if status_code != 200 {
                return Err(format!("更新服务器返回 HTTP {status_code}"));
            }

            let mut content_len: u32 = 0;
            let mut cl_size = std::mem::size_of::<u32>() as u32;
            let total_bytes: u64 = if WinHttpQueryHeaders(
                h_req.0,
                WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER,
                null(),
                (&mut content_len as *mut u32) as *mut c_void,
                &mut cl_size,
                null_mut(),
            ) != 0
            {
                content_len as u64
            } else {
                0
            };

            if total_bytes > 26 * 1024 * 1024 {
                return Err("远端安装包响应体积超出安全上限，已拦截".to_string());
            }
            let mut out: Vec<u8> = Vec::with_capacity((total_bytes as usize).min(4 * 1024 * 1024));
            let mut chunk = vec![0u8; 32 * 1024];
            loop {
                if cancel_flag.is_some_and(|f| f.load(Ordering::Relaxed)) {
                    return Err("已取消更新下载".to_string());
                }
                let mut avail: u32 = 0;
                if WinHttpQueryDataAvailable(h_req.0, &mut avail) == 0 {
                    return Err("读取更新数据流中断".to_string());
                }
                if avail == 0 {
                    break;
                }
                let to_read = (avail as usize).min(chunk.len()) as u32;
                let mut read_n: u32 = 0;
                if WinHttpReadData(
                    h_req.0,
                    chunk.as_mut_ptr() as *mut c_void,
                    to_read,
                    &mut read_n,
                ) == 0
                {
                    return Err("下载更新数据包失败".to_string());
                }
                if read_n == 0 {
                    break;
                }
                out.extend_from_slice(&chunk[..read_n as usize]);
                if out.len() > 26 * 1024 * 1024 {
                    return Err("远端下载内容超出安全体积上限".to_string());
                }
                on_progress(out.len() as u64, total_bytes);
            }

            Ok(out)
        }
    }

    /// 检查最新 GitHub Release（返回 `Ok(Some(info))` 代表存在更新版本，`Ok(None)` 代表已是最新）
    pub fn check_latest_release(
        current_version: &str,
        edition_key: &str,
    ) -> Result<Option<OtaReleaseInfo>, String> {
        let json_bytes = winhttp_fetch_bytes(GITHUB_LATEST_RELEASE_API, 15_000, None, |_, _| {})?;
        let info = parse_github_release_json(&json_bytes, edition_key)?;
        if is_version_newer(&info.version, current_version) {
            Ok(Some(info))
        } else {
            Ok(None)
        }
    }

    /// 双源下载安装包（优先国内同源高速节点，失败无缝切换 GitHub Release 备用源）并执行完整性校验
    pub fn download_and_verify_release<F>(
        info: &OtaReleaseInfo,
        cancel_flag: &AtomicBool,
        mut on_progress: F,
    ) -> Result<Vec<u8>, String>
    where
        F: FnMut(u64, u64),
    {
        let primary_res =
            winhttp_fetch_bytes(&info.primary_url, 15_000, Some(cancel_flag), |d, t| {
                on_progress(d, t)
            });
        let raw_zip = match primary_res {
            Ok(bytes) => match verify_zip_payload(&bytes, info.expected_sha256.as_deref()) {
                Ok(_) => bytes,
                Err(_) => {
                    // 若镜像仍在同步或哈希与最新 Release 不一致，无缝回退 GitHub Release 直链
                    if cancel_flag.load(Ordering::Relaxed) {
                        return Err("已取消更新下载".to_string());
                    }
                    let fb = winhttp_fetch_bytes(
                        &info.fallback_url,
                        45_000,
                        Some(cancel_flag),
                        |d, t| on_progress(d, t),
                    )?;
                    verify_zip_payload(&fb, info.expected_sha256.as_deref())?;
                    fb
                }
            },
            Err(_) => {
                if cancel_flag.load(Ordering::Relaxed) {
                    return Err("已取消更新下载".to_string());
                }
                let fb =
                    winhttp_fetch_bytes(&info.fallback_url, 45_000, Some(cancel_flag), |d, t| {
                        on_progress(d, t)
                    })?;
                verify_zip_payload(&fb, info.expected_sha256.as_deref())?;
                fb
            }
        };
        Ok(raw_zip)
    }

    fn strip_zone_identifier(path: &Path) {
        let ads = format!("{}:Zone.Identifier", path.display());
        let _ = fs::remove_file(ads);
    }

    /// 解压 ZIP 中的 `iClip.exe`、校验 PE 头并执行原地原子热替换与无感重启
    pub fn apply_zip_and_restart(zip_bytes: &[u8]) -> Result<PathBuf, String> {
        let cur_exe = std::env::current_exe().map_err(|e| format!("无法定位当前程序路径：{e}"))?;
        let install_dir = cur_exe
            .parent()
            .ok_or_else(|| "无法解析安装目录".to_string())?;

        let stage_dir = std::env::temp_dir().join(format!(
            "iclip-ota-{}-{}",
            std::process::id(),
            crate::security::random_hex_16()
        ));
        let _ = fs::create_dir_all(&stage_dir);
        let zip_path = stage_dir.join("update.zip");
        let unpack_dir = stage_dir.join("unpacked");
        fs::write(&zip_path, zip_bytes).map_err(|e| format!("写入临时更新包失败：{e}"))?;

        let z_esc = zip_path.display().to_string().replace('\'', "''");
        let u_esc = unpack_dir.display().to_string().replace('\'', "''");
        let ps_cmd = format!(
            "$ErrorActionPreference='Stop'; Expand-Archive -LiteralPath '{z_esc}' -DestinationPath '{u_esc}' -Force"
        );
        let sys_root = std::env::var_os("SystemRoot")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
        let ps_bin = sys_root
            .join("System32")
            .join("WindowsPowerShell")
            .join("v1.0")
            .join("powershell.exe");
        let status = std::process::Command::new(&ps_bin)
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-WindowStyle",
                "Hidden",
                "-Command",
                &ps_cmd,
            ])
            .status()
            .map_err(|e| format!("解压更新包失败：{e}"))?;
        if !status.success() {
            let _ = fs::remove_dir_all(&stage_dir);
            return Err("系统解压更新包返回非零状态".to_string());
        }

        let unpacked_exe = unpack_dir.join("iClip.exe");
        if let Ok(meta) = fs::symlink_metadata(&unpacked_exe) {
            if meta.file_type().is_symlink() {
                let _ = fs::remove_dir_all(&stage_dir);
                return Err("拒绝解压包含符号链接的异常更新包".to_string());
            }
        }
        let exe_bytes = fs::read(&unpacked_exe).map_err(|_| {
            let _ = fs::remove_dir_all(&stage_dir);
            "更新包内未找到 iClip.exe".to_string()
        })?;
        if let Err(e) = verify_pe_executable(&exe_bytes) {
            let _ = fs::remove_dir_all(&stage_dir);
            return Err(e);
        }

        let new_exe_path = install_dir.join("iClip.exe.new");
        let old_exe_path = install_dir.join("iClip.exe.old");
        crate::security::write_protected_atomic(&new_exe_path, &exe_bytes).map_err(|e| {
            let _ = fs::remove_dir_all(&stage_dir);
            format!("当前安装目录无写入权限或存在异常链接（{e}），请移至用户目录后重试")
        })?;
        strip_zone_identifier(&new_exe_path);
        let _ = fs::remove_dir_all(&stage_dir);

        // 原子热替换：先将运行中的当前 exe 重命名为 .old，再将 .new 原地落位为当前 exe
        unsafe {
            let cur_w = to_wide_z(&cur_exe.display().to_string());
            let old_w = to_wide_z(&old_exe_path.display().to_string());
            let new_w = to_wide_z(&new_exe_path.display().to_string());
            let flags = MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH;
            if MoveFileExW(cur_w.as_ptr(), old_w.as_ptr(), flags) == 0 {
                let _ = fs::remove_file(&new_exe_path);
                return Err("原地切换程序文件失败（文件被外部占用或无权限）".to_string());
            }
            if MoveFileExW(new_w.as_ptr(), cur_w.as_ptr(), flags) == 0 {
                // 异常回滚：把旧版恢复回原位，绝不留残局
                let _ = MoveFileExW(old_w.as_ptr(), cur_w.as_ptr(), flags);
                let _ = fs::remove_file(&new_exe_path);
                return Err("落位新版可执行文件失败，已自动回滚原版本".to_string());
            }
        }
        strip_zone_identifier(&cur_exe);

        // 无感拉起新版本进程
        std::process::Command::new(&cur_exe)
            .spawn()
            .map_err(|e| format!("已替换新版但自动重启失败：{e}"))?;

        Ok(cur_exe)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_windows_ota_version_whitelist_release_parse_and_integrity() {
        assert!(is_version_newer("v2.8.0", "2.7.0"));
        assert!(is_version_newer("2.7.1", "v2.7.0"));
        assert!(!is_version_newer("v2.7.0", "2.7.0"));
        assert!(!is_version_newer("2.6.9", "2.7.0"));

        assert!(is_trusted_download_url(
            "https://app.webfooo.com/iClip/downloads/iClip-Dev-Windows-x64.zip"
        ));
        assert!(is_trusted_download_url(
            "https://github.com/fanaruto/iClip/releases/download/v2.8.0/iClip-Dev-Windows-x64.zip"
        ));
        assert!(is_trusted_download_url(
            "https://release-assets.githubusercontent.com/github-production-release-asset/foo"
        ));
        assert!(!is_trusted_download_url(
            "http://app.webfooo.com/iClip/downloads/iClip-Dev-Windows-x64.zip"
        ));
        assert!(!is_trusted_download_url(
            "https://evil.example.com/iClip-Dev-Windows-x64.zip"
        ));
        assert!(!is_trusted_download_url(
            "https://app.webfooo.com@evil.example.com/iClip.zip"
        ));

        let fake_sha = "af1c4fe04e28341be56315ba7a9a671c4f4d6afed4c2abed2f383f171687aedb";
        let release_json = format!(
            r###"{{
                "tag_name": "v2.8.0",
                "body": "## 亮点\n全新字体排版与 Windows 原生 OTA\n| `iClip-Dev-Windows-x64.zip` | 910 KB | `{fake_sha}` |",
                "assets": [
                    {{"name": "iClip-Dev-Windows-x64.zip", "browser_download_url": "https://github.com/fanaruto/iClip/releases/download/v2.8.0/iClip-Dev-Windows-x64.zip"}},
                    {{"name": "iClip-Flow-Windows-x64.zip", "browser_download_url": "https://github.com/fanaruto/iClip/releases/download/v2.8.0/iClip-Flow-Windows-x64.zip"}}
                ]
            }}"###
        );
        let parsed = parse_github_release_json(release_json.as_bytes(), "dev").unwrap();
        assert_eq!(parsed.version, "2.8.0");
        assert_eq!(parsed.asset_name, "iClip-Dev-Windows-x64.zip");
        assert_eq!(
            parsed.primary_url,
            "https://app.webfooo.com/iClip/downloads/iClip-Dev-Windows-x64.zip"
        );
        assert_eq!(parsed.expected_sha256.as_deref(), Some(fake_sha));

        let parsed_flow = parse_github_release_json(release_json.as_bytes(), "flow").unwrap();
        assert_eq!(parsed_flow.asset_name, "iClip-Flow-Windows-x64.zip");

        let native_digest_sha = "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff";
        let digest_json = format!(
            r###"{{
                "tag_name": "v2.9.0",
                "body": "无手写校验表",
                "assets": [
                    {{"name": "iClip-Dev-Windows-x64.zip", "digest": "sha256:{native_digest_sha}", "browser_download_url": "https://github.com/fanaruto/iClip/releases/download/v2.9.0/iClip-Dev-Windows-x64.zip"}}
                ]
            }}"###
        );
        let parsed_digest = parse_github_release_json(digest_json.as_bytes(), "dev").unwrap();
        assert_eq!(
            parsed_digest.expected_sha256.as_deref(),
            Some(native_digest_sha)
        );
        assert!(is_safe_asset_filename("iClip-Dev-Windows-x64.zip"));
        assert!(!is_safe_asset_filename("../evil.zip"));
        assert!(!is_safe_asset_filename("bad/name.zip"));

        let mut fake_zip = vec![0u8; 80 * 1024];
        fake_zip[0..4].copy_from_slice(&[0x50, 0x4B, 0x03, 0x04]);
        let digest = verify_zip_payload(&fake_zip, None).unwrap();
        assert!(verify_zip_payload(&fake_zip, Some(&digest)).is_ok());
        assert!(verify_zip_payload(&fake_zip, Some(fake_sha)).is_err());

        let mut fake_pe = vec![0u8; 160 * 1024];
        fake_pe[0..2].copy_from_slice(b"MZ");
        fake_pe[0x3C..0x40].copy_from_slice(&0x80u32.to_le_bytes());
        fake_pe[0x80..0x84].copy_from_slice(b"PE\0\0");
        assert!(verify_pe_executable(&fake_pe).is_ok());
        fake_pe[0x80] = b'X';
        assert!(verify_pe_executable(&fake_pe).is_err());
    }
}
