use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};

/// 收藏置顶的商务与办公场景分组标签（与 macOS 版枚举值 100% 互通）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PinCategory {
    Reply,
    Invoice,
    Contact,
    Template,
}

impl PinCategory {
    pub const ALL_CATEGORIES: [PinCategory; 4] =
        [Self::Reply, Self::Invoice, Self::Contact, Self::Template];

    pub fn title(self) -> &'static str {
        match self {
            Self::Reply => "常用话术",
            Self::Invoice => "开票财务",
            Self::Contact => "地址名片",
            Self::Template => "合同模板",
        }
    }

    /// 根据备注名、原分类目录名与正文特征自动推断收藏分组（普通文本保持 None 不乱分）
    pub fn infer(alias: Option<&str>, text: Option<&str>) -> Option<Self> {
        Self::infer_with_hint(alias, text, None)
    }

    pub fn infer_with_hint(
        alias: Option<&str>,
        text: Option<&str>,
        category_hint: Option<&str>,
    ) -> Option<Self> {
        if let Some(raw) = text {
            if raw.contains("{{") && raw.contains("}}") {
                return Some(Self::Template);
            }
        }
        let head: String = text.unwrap_or("").chars().take(200).collect();
        let combined = format!(
            "{} {} {}",
            category_hint.unwrap_or(""),
            alias.unwrap_or(""),
            head
        )
        .to_lowercase();
        if combined.trim().is_empty() {
            return None;
        }
        for kw in ["模板", "合同", "协议", "条款", "甲方", "乙方", "template"] {
            if combined.contains(kw) {
                return Some(Self::Template);
            }
        }
        if let Some(hint) = category_hint {
            let lower_hint = hint.to_lowercase();
            for kw in [
                "代码", "脚本", "命令", "终端", "sql", "prompt", "code", "shell", "cmd",
                "snippet", "dev",
            ] {
                if lower_hint.contains(kw) {
                    return Some(Self::Template);
                }
            }
        }
        for kw in [
            "税号",
            "开票",
            "发票",
            "抬头",
            "开户行",
            "对公",
            "联行号",
            "纳税人",
            "收款",
            "财务",
            "报价",
        ] {
            if combined.contains(kw) {
                return Some(Self::Invoice);
            }
        }
        for kw in [
            "地址", "收货", "寄件", "快递", "电话", "手机", "名片", "联系", "邮箱", "邮编",
        ] {
            if combined.contains(kw) {
                return Some(Self::Contact);
            }
        }
        for kw in [
            "话术",
            "回复",
            "客服",
            "问候",
            "售后",
            "催款",
            "通知",
            "欢迎语",
        ] {
            if combined.contains(kw) {
                return Some(Self::Reply);
            }
        }
        None
    }
}

/// 剪贴内容类型
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ClipContentType {
    Text,
    Link,
    Image,
    File,
}

impl ClipContentType {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Text => "文本",
            Self::Link => "链接",
            Self::Image => "图片",
            Self::File => "文件",
        }
    }
}

/// 顶部分类筛选标签
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClipFilterTab {
    All,
    Todo,
    Pinned,
    Text,
    Link,
    Image,
    File,
}

impl ClipFilterTab {
    pub const ALL_TABS: [ClipFilterTab; 7] = [
        Self::All,
        Self::Todo,
        Self::Pinned,
        Self::Text,
        Self::Link,
        Self::Image,
        Self::File,
    ];

    pub const MINIMAL_TABS: [ClipFilterTab; 6] = [
        Self::All,
        Self::Pinned,
        Self::Text,
        Self::Link,
        Self::Image,
        Self::File,
    ];

    pub fn visible_tabs(minimal_mode: bool) -> &'static [ClipFilterTab] {
        if minimal_mode {
            &Self::MINIMAL_TABS
        } else {
            &Self::ALL_TABS
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::All => "全部",
            Self::Todo => "待办",
            Self::Pinned => "收藏",
            Self::Text => "文本",
            Self::Link => "链接",
            Self::Image => "图片",
            Self::File => "文件",
        }
    }
}

/// 单项可执行快捷变换动作
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickAction {
    pub id: &'static str,
    pub title: String,
    pub is_security: bool,
    pub result_text: String,
    pub html_table_payload: Option<String>,
    pub toast_text: String,
}

/// 单条剪贴板记录（与 macOS 超集 Schema 字段对齐）
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipItem {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: ClipContentType,
    pub text: Option<String>,
    pub image_file_name: Option<String>,
    pub image_width: Option<u32>,
    pub image_height: Option<u32>,
    pub ocr_text: Option<String>,
    pub ocr_checked: Option<bool>,
    pub file_paths: Option<Vec<String>>,
    pub content_hash: String,
    pub source_app_name: Option<String>,
    /// Unix 秒级时间戳（持久化轻量高效）
    pub created_unix_secs: u64,
    pub is_pinned: bool,
    pub pin_category: Option<PinCategory>,
    pub custom_alias: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_todo_item: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub todo_completed_unix_secs: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub burn_after_paste: Option<bool>,
}

impl ClipItem {
    pub fn is_burn_after_paste(&self) -> bool {
        self.burn_after_paste == Some(true)
    }

    pub fn set_burn_after_paste(&mut self, enabled: bool) {
        self.burn_after_paste = if enabled { Some(true) } else { None };
    }

    pub fn detected_sensitive_kind(&self) -> Option<crate::security::SensitiveSecretKind> {
        match self.kind {
            ClipContentType::Text | ClipContentType::Link => self
                .text
                .as_deref()
                .and_then(crate::security::classify_sensitive_text),
            ClipContentType::Image => self
                .ocr_text
                .as_deref()
                .and_then(crate::security::classify_sensitive_text),
            ClipContentType::File => self
                .file_paths
                .as_deref()
                .and_then(crate::security::classify_sensitive_file_paths),
        }
    }

    pub fn detected_poison_threat(&self) -> Option<crate::security::PoisonThreatKind> {
        match self.kind {
            ClipContentType::Text | ClipContentType::Link => self
                .text
                .as_deref()
                .and_then(crate::security::inspect_clipboard_poison),
            ClipContentType::Image | ClipContentType::File => None,
        }
    }

    pub fn detected_link_risk(&self) -> Option<crate::security::LinkRiskKind> {
        match self.kind {
            ClipContentType::Link => self
                .text
                .as_deref()
                .and_then(crate::security::inspect_link_risk),
            ClipContentType::Text => self.text.as_deref().and_then(|t| {
                let head = safe_utf8_prefix(t, 2048);
                if head.contains("http://") || head.contains("https://") {
                    crate::intelligence::extract_clean_share_url(head)
                        .and_then(|u| crate::security::inspect_link_risk(&u))
                } else {
                    None
                }
            }),
            ClipContentType::Image | ClipContentType::File => None,
        }
    }

    pub fn display_title(&self, minimal_mode: bool, veil_active: bool) -> String {
        if !minimal_mode {
            if let Some(alias) = &self.custom_alias {
                let t = alias.trim();
                if !t.is_empty() {
                    return t.to_string();
                }
            }
        }
        if veil_active
            && matches!(self.kind, ClipContentType::Text | ClipContentType::Link)
            && self.detected_sensitive_kind().is_some()
        {
            if let Some(raw) = &self.text {
                return crate::security::veiled_sensitive_preview(raw);
            }
        }
        self.primary_title(minimal_mode)
    }

    pub fn is_todo(&self) -> bool {
        self.is_todo_item == Some(true)
    }

    pub fn is_pending_todo(&self) -> bool {
        self.is_todo() && self.todo_completed_unix_secs.is_none()
    }

    pub fn is_todo_completed(&self) -> bool {
        self.is_todo() && self.todo_completed_unix_secs.is_some()
    }

    pub fn set_todo(&mut self, enabled: bool) {
        if enabled {
            self.is_todo_item = Some(true);
        } else {
            self.is_todo_item = None;
            self.todo_completed_unix_secs = None;
        }
    }

    /// 单条文本历史入库最大 UTF-8 字节上限（4 MB，O(1) 放行常规与 2MB 文本，超限时按合法字符边界截断防止 AES 写放大）
    pub const MAX_PERSISTED_TEXT_UTF8_BYTES: usize = 4 * 1024 * 1024;

    pub fn clamp_oversized_text(raw: String, max_bytes: usize) -> String {
        if raw.len() <= max_bytes || max_bytes == 0 {
            return raw;
        }
        let mut end = max_bytes;
        while end > 0 && !raw.is_char_boundary(end) {
            end -= 1;
        }
        raw[..end].to_string()
    }

    pub fn new_text(raw: String, source_app: Option<String>) -> Self {
        let clamped = Self::clamp_oversized_text(raw, Self::MAX_PERSISTED_TEXT_UTF8_BYTES);
        let trimmed = clamped.trim();
        let is_link = is_valid_web_url(trimmed);
        let hash = sha256_hex(clamped.as_bytes());
        Self {
            id: generate_pseudo_uuid(&hash),
            kind: if is_link {
                ClipContentType::Link
            } else {
                ClipContentType::Text
            },
            text: Some(clamped),
            image_file_name: None,
            image_width: None,
            image_height: None,
            ocr_text: None,
            ocr_checked: None,
            file_paths: None,
            content_hash: format!("{}:{hash}", if is_link { "link" } else { "text" }),
            source_app_name: source_app,
            created_unix_secs: now_unix_secs(),
            is_pinned: false,
            pin_category: None,
            custom_alias: None,
            is_todo_item: None,
            todo_completed_unix_secs: None,
            burn_after_paste: None,
        }
    }

    pub fn new_image(
        file_name: String,
        width: u32,
        height: u32,
        png_bytes: &[u8],
        source_app: Option<String>,
    ) -> Self {
        let hash = sha256_hex(png_bytes);
        Self {
            id: generate_pseudo_uuid(&hash),
            kind: ClipContentType::Image,
            text: None,
            image_file_name: Some(file_name),
            image_width: Some(width),
            image_height: Some(height),
            ocr_text: None,
            ocr_checked: None,
            file_paths: None,
            content_hash: format!("img:{hash}"),
            source_app_name: source_app,
            created_unix_secs: now_unix_secs(),
            is_pinned: false,
            pin_category: None,
            custom_alias: None,
            is_todo_item: None,
            todo_completed_unix_secs: None,
            burn_after_paste: None,
        }
    }

    pub fn new_files(paths: Vec<String>, source_app: Option<String>) -> Self {
        let joined = paths.join("\n");
        let hash = sha256_hex(joined.as_bytes());
        Self {
            id: generate_pseudo_uuid(&hash),
            kind: ClipContentType::File,
            text: None,
            image_file_name: None,
            image_width: None,
            image_height: None,
            ocr_text: None,
            ocr_checked: None,
            file_paths: Some(paths),
            content_hash: format!("file:{hash}"),
            source_app_name: source_app,
            created_unix_secs: now_unix_secs(),
            is_pinned: false,
            pin_category: None,
            custom_alias: None,
            is_todo_item: None,
            todo_completed_unix_secs: None,
            burn_after_paste: None,
        }
    }

    /// 卡片主标题（O(1) 截断头部前 180 个字符，杜绝百万字符大文本卡死 UI 排版）
    pub fn primary_title(&self, minimal_mode: bool) -> String {
        if !minimal_mode {
            if let Some(alias) = &self.custom_alias {
                let t = alias.trim();
                if !t.is_empty() {
                    return t.to_string();
                }
            }
        }
        self.raw_content_preview()
    }

    /// O(1) 严格前缀截断预览
    pub fn raw_content_preview(&self) -> String {
        match self.kind {
            ClipContentType::Text | ClipContentType::Link => {
                let Some(raw) = &self.text else {
                    return "空白文本".to_string();
                };
                if raw.is_empty() {
                    return "空白文本".to_string();
                }
                let prefix = safe_utf8_prefix(raw, 1_024);
                let head: String = if self.kind == ClipContentType::Link && prefix.contains('%') {
                    crate::intelligence::decode_percent_readable_url(prefix)
                        .chars()
                        .take(180)
                        .collect()
                } else {
                    prefix.chars().take(180).collect()
                };
                let trimmed = head.trim();
                if trimmed.is_empty() {
                    "空白文本".to_string()
                } else {
                    let joined = trimmed.replace('\r', "").replace('\n', " · ");
                    joined
                        .replace("） · ", "）· ")
                        .replace("」 · ", "」· ")
                        .replace("】 · ", "】· ")
                        .replace("” · ", "”· ")
                }
            }
            ClipContentType::Image => {
                if let (Some(w), Some(h)) = (self.image_width, self.image_height) {
                    format!("图片 · {w} × {h}")
                } else {
                    "剪贴板图片".to_string()
                }
            }
            ClipContentType::File => {
                let Some(paths) = &self.file_paths else {
                    return "未知文件".to_string();
                };
                let Some(first) = paths.first() else {
                    return "未知文件".to_string();
                };
                let name = first.rsplit(['\\', '/']).next().unwrap_or(first);
                if paths.len() == 1 {
                    name.to_string()
                } else {
                    format!("{name} 等 {} 个项目", paths.len())
                }
            }
        }
    }

    /// O(1) 字节门控辅助信息（支持防肩窥遮罩：备注名卡片未选中/未悬停时绝不在副标题泄露明文密钥）
    pub fn subtitle_info(&self) -> String {
        self.subtitle_info_veiled(false)
    }

    pub fn subtitle_info_veiled(&self, veil_active: bool) -> String {
        if let Some(alias) = &self.custom_alias {
            if !alias.trim().is_empty() {
                if veil_active && self.detected_sensitive_kind().is_some() {
                    if let Some(raw) = &self.text {
                        return crate::security::veiled_sensitive_preview(raw);
                    }
                    if let Some(ocr) = &self.ocr_text {
                        return format!(
                            "实况文本：{}",
                            crate::security::veiled_sensitive_preview(ocr)
                        );
                    }
                }
                let p: String = self.raw_content_preview().chars().take(28).collect();
                return p;
            }
        }
        match self.kind {
            ClipContentType::Text => {
                let Some(t) = &self.text else {
                    return "0 字".to_string();
                };
                let bytes = t.len();
                if bytes <= 8_192 {
                    format!("{} 字", t.chars().count())
                } else if bytes < 1_048_576 {
                    format!("{:.1} KB 文本", bytes as f64 / 1024.0)
                } else {
                    format!("{:.2} MB 大文本", bytes as f64 / 1_048_576.0)
                }
            }
            ClipContentType::Link => {
                if let Some(raw) = &self.text {
                    if raw.len() <= 4_096 {
                        if let Some(host) = extract_url_host(raw.trim()) {
                            return host.to_string();
                        }
                    }
                }
                "网页链接".to_string()
            }
            ClipContentType::Image => {
                if let Some(ocr) = &self.ocr_text {
                    let clean = ocr.trim();
                    if !clean.is_empty() {
                        if veil_active && crate::security::classify_sensitive_text(clean).is_some()
                        {
                            return format!(
                                "实况文本：{}",
                                crate::security::veiled_sensitive_preview(clean)
                            );
                        }
                        let preview: String = clean.replace('\n', " ").chars().take(24).collect();
                        return format!("实况文本：{preview}");
                    }
                }
                "PNG 图像".to_string()
            }
            ClipContentType::File => self
                .file_paths
                .as_ref()
                .and_then(|p| p.first())
                .cloned()
                .unwrap_or_else(|| "本地文件".to_string()),
        }
    }

    /// 全维度直觉盲搜：支持多词 AND、`!` 排除词、自然情景时间窗（今天/昨天/本周）、跨语言应用/模态同义词、百分号中文 URL 与拼音首字母检索
    pub fn matches_query(&self, query: &str) -> bool {
        let q = query.trim();
        if q.is_empty() {
            return true;
        }
        let now_secs = now_unix_secs();
        for raw_token in q.split_whitespace() {
            if raw_token.is_empty() {
                continue;
            }
            if let Some(neg) = raw_token
                .strip_prefix('!')
                .or_else(|| raw_token.strip_prefix('！'))
            {
                let neg = neg.trim();
                if !neg.is_empty() && self.matches_single_token(neg) {
                    return false;
                }
                continue;
            }
            if let Some(scope) = crate::intelligence::TimeScopeFilter::from_token(raw_token) {
                if !scope.matches_timestamp(self.created_unix_secs, now_secs) {
                    return false;
                }
                continue;
            }
            if !self.matches_single_token(raw_token) {
                return false;
            }
        }
        true
    }

    fn matches_single_token(&self, token: &str) -> bool {
        let token_lower = token.to_lowercase();
        match token_lower.as_str() {
            "收藏" | "@pin" | "@star" | "pinned" | "starred" => return self.is_pinned,
            "待办" | "todo" | "@todo" | "@待办" => return self.is_todo(),
            "未完成" | "@pending" => return self.is_pending_todo(),
            "已完成" | "@done" => return self.is_todo_completed(),
            "敏感" | "@敏感" | "@密钥" | "@隐私" | "@secret" | "secret" => {
                if matches!(
                    self.detected_poison_threat(),
                    Some(crate::security::PoisonThreatKind::PastejackingOrBidi(_))
                ) || self.detected_link_risk()
                    == Some(crate::security::LinkRiskKind::HomographPhishing)
                {
                    return true;
                }
                return self.detected_sensitive_kind().is_some() || self.is_burn_after_paste();
            }
            "私钥" | "@私钥" | "@privatekey" => {
                return self.detected_sensitive_kind()
                    == Some(crate::security::SensitiveSecretKind::PrivateKey)
            }
            "@jwt" | "jwt" => {
                return self.detected_sensitive_kind()
                    == Some(crate::security::SensitiveSecretKind::JwtToken)
            }
            "@apikey" | "apikey" | "@token" => {
                return matches!(
                    self.detected_sensitive_kind(),
                    Some(
                        crate::security::SensitiveSecretKind::ApiKey
                            | crate::security::SensitiveSecretKind::ConnectionSecret
                    )
                )
            }
            "身份证" | "@身份证" | "银行卡" | "@银行卡" | "@idcard" => {
                return self.detected_sensitive_kind()
                    == Some(crate::security::SensitiveSecretKind::PersonalIdentity)
            }
            "webhook" | "@webhook" => {
                return self
                    .text
                    .as_deref()
                    .map(crate::security::is_webhook_url)
                    .unwrap_or(false)
            }
            "2fa" | "@2fa" | "totp" | "@totp" | "@动态码" => {
                return self
                    .text
                    .as_deref()
                    .map(crate::security::is_otpauth_uri)
                    .unwrap_or(false)
            }
            "@安全" | "@体检" | "@隐私体检" | "@shield" | "@audit" => {
                if matches!(
                    self.detected_poison_threat(),
                    Some(crate::security::PoisonThreatKind::PastejackingOrBidi(_))
                ) || self.detected_link_risk().is_some()
                {
                    return true;
                }
                return self.detected_sensitive_kind().is_some() || self.is_burn_after_paste();
            }
            "密文" | "@密文" | "@locked" | "iclpmsg1" => {
                return crate::security::contains_secret_capsule(self.text.as_deref());
            }
            "@地址" | "@收件" | "@收货" => {
                return self
                    .text
                    .as_deref()
                    .map(crate::intelligence::has_chinese_address)
                    .unwrap_or(false);
            }
            "@手机" | "@电话" | "@phone" => {
                return self
                    .text
                    .as_deref()
                    .map(crate::intelligence::has_mainland_phone)
                    .unwrap_or(false)
                    || self
                        .ocr_text
                        .as_deref()
                        .map(crate::intelligence::has_mainland_phone)
                        .unwrap_or(false);
            }
            "@邮箱" | "@email" => {
                return self
                    .text
                    .as_deref()
                    .map(crate::intelligence::has_email_address)
                    .unwrap_or(false)
                    || self
                        .ocr_text
                        .as_deref()
                        .map(crate::intelligence::has_email_address)
                        .unwrap_or(false);
            }
            "@ip" => {
                return self
                    .text
                    .as_deref()
                    .map(crate::intelligence::has_ipv4_address)
                    .unwrap_or(false)
                    || self
                        .ocr_text
                        .as_deref()
                        .map(crate::intelligence::has_ipv4_address)
                        .unwrap_or(false);
            }
            "风险" | "@风险" | "@毒" | "@poison" | "poison" => {
                return self.detected_poison_threat().is_some()
                    || self.detected_link_risk().is_some()
            }
            "即焚" | "@即焚" | "@burn" | "burn" => return self.is_burn_after_paste(),
            _ => {}
        }
        if let Some(text) = &self.text {
            let window = safe_utf8_prefix(text, 65_536);
            if contains_case_insensitive(window, token) {
                return true;
            }
            if self.kind == ClipContentType::Link && window.contains('%') {
                let decoded = crate::intelligence::decode_percent_readable_url(window);
                if contains_case_insensitive(&decoded, token) {
                    return true;
                }
                if crate::intelligence::is_pure_ascii_letters(token) {
                    let initials = crate::intelligence::extract_pinyin_initials(&decoded, 200);
                    if initials.contains(&token.to_ascii_lowercase()) {
                        return true;
                    }
                }
            }
        }
        if let Some(alias) = &self.custom_alias {
            if contains_case_insensitive(alias, token) {
                return true;
            }
        }
        if let Some(cat) = self.pin_category {
            if contains_case_insensitive(cat.title(), token) {
                return true;
            }
        }
        if let Some(ocr) = &self.ocr_text {
            if contains_case_insensitive(safe_utf8_prefix(ocr, 32_768), token) {
                return true;
            }
        }
        if let Some(paths) = &self.file_paths {
            if paths.iter().any(|p| contains_case_insensitive(p, token)) {
                return true;
            }
        }
        if let Some(app) = &self.source_app_name {
            if contains_case_insensitive(app, token) {
                return true;
            }
        }
        if contains_case_insensitive(self.kind.display_name(), token) {
            return true;
        }

        let token_lower = token.to_lowercase();
        if crate::intelligence::matches_app_or_modality_synonym(
            &token_lower,
            self.source_app_name.as_deref(),
            self.kind,
        ) {
            return true;
        }

        // 英文输入法下免切输入法拼音首字母盲搜（如 `fptt` 命中「发票抬头」）
        if crate::intelligence::is_pure_ascii_letters(&token_lower) {
            if let Some(alias) = &self.custom_alias {
                if crate::intelligence::extract_pinyin_initials(alias, 96).contains(&token_lower) {
                    return true;
                }
            }
            if let Some(text) = &self.text {
                let head = safe_utf8_prefix(text, 2_048);
                if crate::intelligence::extract_pinyin_initials(head, 320).contains(&token_lower) {
                    return true;
                }
            }
            if let Some(ocr) = &self.ocr_text {
                let head = safe_utf8_prefix(ocr, 1_024);
                if crate::intelligence::extract_pinyin_initials(head, 200).contains(&token_lower) {
                    return true;
                }
            }
        }

        false
    }
}

pub fn safe_utf8_prefix(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// 零堆分配 ASCII 大小写不敏感子串搜索（非 ASCII 关键字安全降级至小写比较）
pub fn contains_case_insensitive(haystack: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return true;
    }
    if needle.len() > haystack.len() {
        return false;
    }
    if needle.is_ascii() {
        let n_bytes = needle.as_bytes();
        let h_bytes = haystack.as_bytes();
        let first_lower = n_bytes[0].to_ascii_lowercase();
        let first_upper = n_bytes[0].to_ascii_uppercase();
        let max_start = h_bytes.len() - n_bytes.len();
        let mut i = 0;
        while i <= max_start {
            let b = h_bytes[i];
            if b == first_lower || b == first_upper {
                if h_bytes[i..i + n_bytes.len()].eq_ignore_ascii_case(n_bytes) {
                    return true;
                }
            }
            i += 1;
        }
        false
    } else {
        // 中文无大小写之分，若 needle 不含 ASCII 字母直接走 O(N) 原串极速匹配，零堆分配！
        if !needle.bytes().any(|b| b.is_ascii_alphabetic()) {
            haystack.contains(needle)
        } else {
            haystack.to_lowercase().contains(&needle.to_lowercase())
        }
    }
}

pub fn is_valid_web_url(s: &str) -> bool {
    if s.contains('\n') || s.contains('\r') || s.contains(' ') {
        return false;
    }
    let rest = if let Some(r) = s.strip_prefix("https://") {
        r
    } else if let Some(r) = s.strip_prefix("http://") {
        r
    } else {
        return false;
    };
    let host_port = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = host_port.split(':').next().unwrap_or("");
    (host.contains('.') && host.len() >= 4)
        || host.eq_ignore_ascii_case("localhost")
        || host == "127.0.0.1"
        || host == "0.0.0.0"
}

pub fn extract_url_host(s: &str) -> Option<&str> {
    let rest = s
        .strip_prefix("https://")
        .or_else(|| s.strip_prefix("http://"))?;
    let host = rest.split(['/', '?', '#']).next()?;
    if host.is_empty() {
        None
    } else {
        Some(host)
    }
}

pub fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    let out = hasher.finalize();
    let mut hex = String::with_capacity(64);
    for b in out {
        use std::fmt::Write;
        let _ = write!(&mut hex, "{b:02x}");
    }
    hex
}

pub fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// 纯算法 Howard Hinnant 日历转换：Unix 秒转标准 ISO-8601 UTC 字符串（与 macOS JSONEncoder.iso8601 完全兼容）
pub fn unix_secs_to_iso8601(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let hour = rem / 3600;
    let min = (rem % 3600) / 60;
    let sec = rem % 60;

    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };

    format!("{year:04}-{m:02}-{d:02}T{hour:02}:{min:02}:{sec:02}Z")
}

/// 解析 ISO-8601 字符串回 Unix 秒（失败时安全退回当前时间）
pub fn iso8601_to_unix_secs(iso: &str) -> u64 {
    if iso.len() >= 19 {
        let y: i64 = iso[0..4].parse().unwrap_or(2026);
        let m: i64 = iso[5..7].parse().unwrap_or(1);
        let d: i64 = iso[8..10].parse().unwrap_or(1);
        let hh: u64 = iso[11..13].parse().unwrap_or(0);
        let mm: u64 = iso[14..16].parse().unwrap_or(0);
        let ss: u64 = iso[17..19].parse().unwrap_or(0);

        let y_adj = y - if m <= 2 { 1 } else { 0 };
        let era = if y_adj >= 0 { y_adj } else { y_adj - 399 } / 400;
        let yoe = (y_adj - era * 400) as u64;
        let mp = (m + if m > 2 { -3 } else { 9 }) as u64;
        let doy = (153 * mp + 2) / 5 + d as u64 - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        let days = era * 146_097 + doe as i64 - 719_468;
        if days >= 0 {
            return (days as u64) * 86_400 + hh * 3600 + mm * 60 + ss;
        }
    }
    now_unix_secs()
}

pub fn generate_pseudo_uuid(seed_hex: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mix = sha256_hex(format!("{seed_hex}:{nanos}").as_bytes());
    format!(
        "{}-{}-4{}-a{}-{}",
        &mix[0..8],
        &mix[8..12],
        &mix[13..16],
        &mix[17..20],
        &mix[20..32]
    )
    .to_uppercase()
}
