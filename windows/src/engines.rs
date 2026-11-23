use crate::model::{safe_utf8_prefix, QuickAction};
#[cfg(feature = "dev")]
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use image::{
    codecs::jpeg::JpegEncoder, codecs::png::PngEncoder, ColorType, ImageEncoder, Rgba, RgbaImage,
};
use regex_lite::Regex;
use serde_json::Value;

// ============================================================================
// 统一快捷动作调度器（区分 Dev 极客开发版 与 Flow 心流办公版）
// ============================================================================

pub fn analyze_text_actions(raw: &str, minimal_mode: bool) -> Vec<QuickAction> {
    if minimal_mode || raw.is_empty() {
        return Vec::new();
    }
    let inspect = safe_utf8_prefix(raw, 16_384);
    let trimmed = inspect.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    let mut actions = Vec::new();

    // 0. 最高优：一次性短信/邮件验证码（OTP）抗干扰提取（双角色共享）
    if raw.len() <= 800 {
        if let Some(otp) = extract_verification_code(trimmed) {
            if otp != trimmed {
                actions.push(QuickAction {
                    id: "otp-extract-code",
                    title: format!("验证码 {otp}"),
                    is_security: false,
                    result_text: otp.clone(),
                    html_table_payload: None,
                    toast_text: format!("已提取纯验证码 {otp}"),
                });
            }
        }
    }

    // 0.5 双角色共享：多行待办清单拆解动作
    if inspect.contains('\n') {
        let checklist = crate::intelligence::extract_checklist_items(raw);
        if checklist.len() >= 2 {
            actions.push(QuickAction {
                id: "todo-split-checklist",
                title: format!("拆为 {} 条待办", checklist.len()),
                is_security: false,
                result_text: raw.to_string(),
                html_table_payload: None,
                toast_text: format!("已拆解为 {} 条待办（Alt+2 查看）", checklist.len()),
            });
        }
    }

    // 0.8 双角色共享：高敏密钥、连接凭据与身份证/银行卡一键防泄密脱敏
    if contains_sensitive_secret(inspect) {
        let redacted = redact_secrets(raw);
        if redacted != raw {
            actions.push(QuickAction {
                id: "redact-secrets",
                title: "脱敏粘贴".to_string(),
                is_security: true,
                result_text: redacted.clone(),
                html_table_payload: None,
                toast_text: "已掩码敏感凭据与隐私并写入剪贴板".to_string(),
            });
        }
        #[cfg(feature = "dev")]
        {
            let deep = redact_pii_and_private_ip(&redacted);
            if deep != redacted {
                actions.push(QuickAction {
                    id: "redact-deep",
                    title: "深度脱敏(含IP/隐私)".to_string(),
                    is_security: true,
                    result_text: deep,
                    html_table_payload: None,
                    toast_text: "已完成密钥 + 内网IP/邮箱/手机号全量脱敏".to_string(),
                });
            }
        }
    }

    #[cfg(feature = "dev")]
    {
        if trimmed.len() >= 11 && !actions.iter().any(|a| a.id.starts_with("redact-")) {
            let pii = redact_pii_and_private_ip(raw);
            if pii != raw && actions.is_empty() {
                actions.push(QuickAction {
                    id: "redact-pii",
                    title: "隐私掩码(IP/邮箱/号)".to_string(),
                    is_security: true,
                    result_text: pii,
                    html_table_payload: None,
                    toast_text: "已掩码内网 IP / 邮箱 / 手机号".to_string(),
                });
            }
        }

        // Dev 2: 营销追踪链接净链
        if !trimmed.contains('\n') && trimmed.len() <= 4096 {
            if let Some(clean_url) = clean_tracking_url(trimmed) {
                actions.push(QuickAction {
                    id: "clean-url",
                    title: "净链粘贴".to_string(),
                    is_security: false,
                    result_text: clean_url,
                    html_table_payload: None,
                    toast_text: "已剥离营销追踪参数".to_string(),
                });
            }
        }

        // Dev 3: JSON 格式化与压缩
        if raw.len() <= 65_536
            && ((trimmed.starts_with('{') && trimmed.ends_with('}'))
                || (trimmed.starts_with('[') && trimmed.ends_with(']')))
        {
            if let Ok(val) = serde_json::from_str::<Value>(trimmed) {
                if !trimmed.contains('\n') {
                    if let Ok(pretty) = serde_json::to_string_pretty(&val) {
                        actions.push(QuickAction {
                            id: "json-pretty",
                            title: "格式化 JSON".to_string(),
                            is_security: false,
                            result_text: pretty,
                            html_table_payload: None,
                            toast_text: "已美化 JSON 缩进".to_string(),
                        });
                    }
                } else if let Ok(compact) = serde_json::to_string(&val) {
                    actions.push(QuickAction {
                        id: "json-minify",
                        title: "压缩单行 JSON".to_string(),
                        is_security: false,
                        result_text: compact,
                        html_table_payload: None,
                        toast_text: "已压缩为单行 JSON".to_string(),
                    });
                }
            }
        }

        // Dev 4: Unix 时间戳转换
        if (trimmed.len() == 10 || trimmed.len() == 13)
            && trimmed.bytes().all(|b| b.is_ascii_digit())
        {
            if let Ok(v) = trimmed.parse::<u64>() {
                let secs = if trimmed.len() == 13 { v / 1000 } else { v };
                if (1_000_000_000..=4_102_444_800).contains(&secs) {
                    let iso = crate::model::unix_secs_to_iso8601(secs);
                    let readable = iso.replace('T', " ").trim_end_matches('Z').to_string() + " UTC";
                    actions.push(QuickAction {
                        id: "ts-utc",
                        title: readable.clone(),
                        is_security: false,
                        result_text: readable,
                        html_table_payload: None,
                        toast_text: "已转换 Unix 时间戳".to_string(),
                    });
                }
            }
        }
    }

    // 七大垂直行业引擎按优先级匹配
    if actions.len() < 3 && !trimmed.contains('\n') && (15..=32).contains(&trimmed.len()) {
        actions.extend(analyze_compliance_codes(trimmed));
    }
    if actions.is_empty() && raw.len() <= 65_536 && raw.contains('\n') {
        actions.extend(analyze_meeting_transcript(raw));
    }
    if actions.is_empty() && raw.len() <= 65_536 && raw.contains('\n') {
        actions.extend(analyze_table_bridge(raw));
    }
    if actions.is_empty() && raw.len() <= 16_384 {
        actions.extend(analyze_finance_numbers(raw));
    }
    if actions.is_empty() && raw.len() <= 32_768 {
        actions.extend(analyze_document_typography(raw));
    }

    #[cfg(feature = "dev")]
    if actions.is_empty() {
        // Dev 5: Base64 解码
        if (12..=4096).contains(&trimmed.len())
            && trimmed.len() % 4 == 0
            && !trimmed.contains(' ')
            && !trimmed.contains('\n')
            && trimmed
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=')
        {
            if let Ok(bytes) = BASE64.decode(trimmed) {
                if let Ok(decoded) = String::from_utf8(bytes) {
                    let clean = decoded.trim();
                    if clean.chars().count() >= 3
                        && !clean
                            .chars()
                            .any(|c| c.is_control() && c != '\n' && c != '\r' && c != '\t')
                    {
                        actions.push(QuickAction {
                            id: "base64-decode",
                            title: "Base64 解码".to_string(),
                            is_security: false,
                            result_text: decoded,
                            html_table_payload: None,
                            toast_text: "已解码 Base64 文本".to_string(),
                        });
                    }
                }
            }
        }

        // Dev 6: 多行 ID 列转 SQL IN (...)
        if actions.is_empty() && raw.len() <= 32_768 && trimmed.contains('\n') {
            let items: Vec<&str> = raw
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .collect();
            if (2..=500).contains(&items.len())
                && items.iter().all(|l| {
                    l.len() <= 64
                        && !l.contains('{')
                        && !l.contains('}')
                        && !l.ends_with(';')
                        && !l.contains('。')
                        && !l.contains('，')
                })
            {
                let all_numeric = items.iter().all(|s| s.bytes().all(|b| b.is_ascii_digit()));
                let sql_in = if all_numeric {
                    format!("IN ({})", items.join(", "))
                } else {
                    let quoted: Vec<String> = items
                        .iter()
                        .map(|s| format!("'{}'", s.replace('\'', "''")))
                        .collect();
                    format!("IN ({})", quoted.join(", "))
                };
                actions.push(QuickAction {
                    id: "list-sql-in",
                    title: "SQL IN (...)".to_string(),
                    is_security: false,
                    result_text: sql_in,
                    html_table_payload: None,
                    toast_text: format!("已将 {} 行转为 SQL IN 子句", items.len()),
                });
            }
        }
    }

    actions.truncate(3);
    actions
}

// ============================================================================
// 引擎 1：零浮点误差财务大写人民币、千分位与多行账单求和
// ============================================================================

const CN_DIGITS: [&str; 10] = ["零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖"];
const SECTION_UNITS: [&str; 4] = ["", "拾", "佰", "仟"];
const GROUP_UNITS: [&str; 4] = ["", "万", "亿", "兆"];

pub fn to_chinese_uppercase_rmb(int_digits: &str, frac_digits: Option<&str>) -> Option<String> {
    if int_digits.is_empty() || !int_digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let normalized_int = int_digits.trim_start_matches('0');
    let clean_int = if normalized_int.is_empty() {
        "0"
    } else {
        normalized_int
    };
    if clean_int.len() > 12 {
        return None;
    }

    let (jiao, fen) = match frac_digits {
        None | Some("") => (0usize, 0usize),
        Some(f) if f.len() == 1 && f.bytes().all(|b| b.is_ascii_digit()) => {
            ((f.as_bytes()[0] - b'0') as usize, 0usize)
        }
        Some(f) if f.len() == 2 && f.bytes().all(|b| b.is_ascii_digit()) => (
            (f.as_bytes()[0] - b'0') as usize,
            (f.as_bytes()[1] - b'0') as usize,
        ),
        _ => return None,
    };

    if clean_int == "0" && jiao == 0 && fen == 0 {
        return Some("零元整".to_string());
    }

    let mut result = String::new();
    if clean_int != "0" {
        let digits: Vec<usize> = clean_int.bytes().map(|b| (b - b'0') as usize).collect();
        let total = digits.len();
        let group_count = (total + 3) / 4;
        let mut need_zero_across = false;

        for g in 0..group_count {
            let group_idx_from_right = group_count - 1 - g;
            let first_len = if total % 4 == 0 { 4 } else { total % 4 };
            let start = if g == 0 { 0 } else { first_len + (g - 1) * 4 };
            let end = if g == 0 { first_len } else { start + 4 };
            let slice = &digits[start..end];

            if slice.iter().all(|&d| d == 0) {
                if !result.is_empty() {
                    need_zero_across = true;
                }
                continue;
            }

            if need_zero_across || (!result.is_empty() && slice[0] == 0) {
                result.push_str("零");
                need_zero_across = false;
            }

            let mut zero_pending = false;
            let s_len = slice.len();
            for (idx, &d) in slice.iter().enumerate() {
                let unit_pos = s_len - 1 - idx;
                if d == 0 {
                    zero_pending = true;
                } else {
                    if zero_pending && !result.is_empty() && !result.ends_with('零') {
                        result.push_str("零");
                    }
                    zero_pending = false;
                    result.push_str(CN_DIGITS[d]);
                    result.push_str(SECTION_UNITS[unit_pos]);
                }
            }
            result.push_str(GROUP_UNITS[group_idx_from_right]);
        }
        result.push_str("元");
    }

    if jiao == 0 && fen == 0 {
        result.push_str("整");
    } else if jiao > 0 && fen == 0 {
        result.push_str(CN_DIGITS[jiao]);
        result.push_str("角整");
    } else if jiao == 0 && fen > 0 {
        if clean_int != "0" {
            result.push_str("零");
        }
        result.push_str(CN_DIGITS[fen]);
        result.push_str("分");
    } else {
        result.push_str(CN_DIGITS[jiao]);
        result.push_str("角");
        result.push_str(CN_DIGITS[fen]);
        result.push_str("分");
    }

    Some(result)
}

pub fn format_thousands(int_digits: &str, frac_digits: Option<&str>) -> String {
    let norm = int_digits.trim_start_matches('0');
    let base = if norm.is_empty() { "0" } else { norm };
    let mut out = String::with_capacity(base.len() + 8);
    for (i, ch) in base.chars().enumerate() {
        if i > 0 && (base.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    if let Some(f) = frac_digits {
        if !f.is_empty() {
            out.push('.');
            out.push_str(f);
        }
    }
    out
}

pub fn analyze_finance_numbers(raw: &str) -> Vec<QuickAction> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || raw.len() > 16_384 {
        return Vec::new();
    }

    if !trimmed.contains('\n') {
        let re = Regex::new(
            r"^\s*([¥￥$€£]?)\s*([0-9][0-9,]*)(?:\.([0-9]{1,2}))?\s*(元|圆|RMB|CNY)?\s*$",
        )
        .unwrap();
        if let Some(caps) = re.captures(trimmed) {
            let prefix = caps.get(1).map(|m| m.as_str()).unwrap_or("");
            let raw_int = caps.get(2).map(|m| m.as_str()).unwrap_or("");
            let frac = caps.get(3).map(|m| m.as_str());
            let suffix = caps.get(4).map(|m| m.as_str()).unwrap_or("");

            if raw_int.contains(',') {
                let comma_ok = Regex::new(r"^\d{1,3}(?:,\d{3})+$")
                    .unwrap()
                    .is_match(raw_int);
                if !comma_ok {
                    return Vec::new();
                }
            }
            let clean_int = raw_int.replace(',', "");
            let has_explicit =
                !prefix.is_empty() || !suffix.is_empty() || raw_int.contains(',') || frac.is_some();

            // 防手机号、Unix 时间戳、年份、短序号误判
            if !has_explicit {
                if clean_int.len() == 11 && clean_int.starts_with('1') {
                    return Vec::new();
                }
                if clean_int.len() == 10 || clean_int.len() == 13 {
                    return Vec::new();
                }
                if clean_int.len() == 4 {
                    if let Ok(y) = clean_int.parse::<u32>() {
                        if (1970..=2099).contains(&y) {
                            return Vec::new();
                        }
                    }
                }
                if clean_int.len() > 9 {
                    return Vec::new();
                }
            }
            if clean_int.len() > 12 {
                return Vec::new();
            }

            let is_foreign = prefix == "$" || prefix == "€" || prefix == "£";
            let mut actions = Vec::new();
            if !is_foreign {
                if let Some(upper) = to_chinese_uppercase_rmb(&clean_int, frac) {
                    actions.push(QuickAction {
                        id: "fin-rmb-upper",
                        title: format!("大写：{upper}"),
                        is_security: false,
                        result_text: upper,
                        html_table_payload: None,
                        toast_text: "已转为会计人民币大写".to_string(),
                    });
                }
            }
            let thousands = format_thousands(&clean_int, frac);
            if thousands != trimmed && clean_int.len() >= 4 {
                actions.push(QuickAction {
                    id: "fin-thousands",
                    title: format!("千分位 {thousands}"),
                    is_security: false,
                    result_text: thousands,
                    html_table_payload: None,
                    toast_text: "已格式化为千分位数字".to_string(),
                });
            }
            let plain = match frac {
                Some(f) if !f.is_empty() => format!("{clean_int}.{f}"),
                _ => clean_int,
            };
            if plain != trimmed {
                actions.push(QuickAction {
                    id: "fin-plain-num",
                    title: format!("纯数字 {plain}"),
                    is_security: false,
                    result_text: plain,
                    html_table_payload: None,
                    toast_text: "已提取去符号纯数字".to_string(),
                });
            }
            return actions;
        }
        return Vec::new();
    }

    // 多行报销/对账单精确分位求和（整数毫分运算，0 浮点误差）
    let lines: Vec<&str> = raw
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    if !(2..=200).contains(&lines.len()) {
        return Vec::new();
    }
    if raw.contains('{')
        || raw.contains('}')
        || raw.contains("func ")
        || raw.contains("let ")
        || raw.contains("const ")
    {
        return Vec::new();
    }

    let tail_re = Regex::new(
        r"(?:[¥￥$]\s*)?(-?\d{1,3}(?:,\d{3})+|-?\d+)(?:\.(\d{1,2}))?\s*(?:元|圆|块)?\s*$",
    )
    .unwrap();
    let mut matched_count = 0usize;
    let mut sum_cents: i128 = 0;

    for line in &lines {
        let lower = line.to_lowercase();
        if lower.starts_with("合计")
            || lower.starts_with("总计")
            || lower.starts_with("小计")
            || lower.starts_with("total")
        {
            continue;
        }
        if let Some(caps) = tail_re.captures(line) {
            let int_raw = caps.get(1).unwrap().as_str().replace(',', "");
            let negative = int_raw.starts_with('-');
            let abs_int_str = int_raw.trim_start_matches('-');
            if abs_int_str.len() >= 10 {
                continue;
            }
            let Ok(int_val) = abs_int_str.parse::<i128>() else {
                continue;
            };
            let frac_str = caps.get(2).map(|m| m.as_str()).unwrap_or("");
            let cents_part: i128 = match frac_str.len() {
                0 => 0,
                1 => (frac_str.parse::<i128>().unwrap_or(0)) * 10,
                2 => frac_str.parse::<i128>().unwrap_or(0),
                _ => 0,
            };
            let line_cents = int_val * 100 + cents_part;
            sum_cents += if negative { -line_cents } else { line_cents };
            matched_count += 1;
        }
    }

    if matched_count < 2 || (matched_count as f64) < (lines.len() as f64 * 0.5) {
        return Vec::new();
    }

    let sign = if sum_cents < 0 { "-" } else { "" };
    let abs_cents = sum_cents.unsigned_abs();
    let sum_int = (abs_cents / 100).to_string();
    let rem_cents = abs_cents % 100;
    let frac_opt = if rem_cents == 0 {
        None
    } else {
        Some(format!("{rem_cents:02}"))
    };
    let plain_sum = match &frac_opt {
        Some(f) => format!("{sign}{sum_int}.{f}"),
        None => format!("{sign}{sum_int}"),
    };
    let thousands_sum = format!("{sign}{}", format_thousands(&sum_int, frac_opt.as_deref()));

    let mut actions = vec![QuickAction {
        id: "bill-sum-only",
        title: format!("求和 = ¥{thousands_sum}（{matched_count} 项）"),
        is_security: false,
        result_text: plain_sum,
        html_table_payload: None,
        toast_text: format!("已精确累加 {matched_count} 项金额"),
    }];

    if sum_cents >= 0 {
        if let Some(upper) = to_chinese_uppercase_rmb(&sum_int, frac_opt.as_deref()) {
            let appended = format!("{}\n合计：¥{thousands_sum}（{upper}）", raw.trim_end());
            actions.push(QuickAction {
                id: "bill-append-total",
                title: "追加合计与大写".to_string(),
                is_security: false,
                result_text: appended,
                html_table_payload: None,
                toast_text: "已在账单末尾追加合计与会计大写".to_string(),
            });
        }
    }

    actions
}

// ============================================================================
// 引擎 2：PDF 双栏硬折行智能缝合与盘古中英排版（保护 URL 与代码）
// ============================================================================

const HYPHEN_KEEP_PREFIXES: [&str; 24] = [
    "state-of-the",
    "end-to",
    "up-to",
    "out-of",
    "one-to",
    "peer-to",
    "self",
    "non",
    "multi",
    "cross",
    "inter",
    "intra",
    "co",
    "re",
    "pre",
    "post",
    "high",
    "low",
    "real",
    "open",
    "long",
    "short",
    "well",
    "zero",
];

pub fn heal_pdf_line_breaks(raw: &str) -> String {
    let normalized = raw.replace("\r\n", "\n").replace('\r', "\n");
    let lines: Vec<&str> = normalized.split('\n').collect();
    let mut paragraphs: Vec<String> = Vec::new();
    let mut current = String::new();
    let bullet_re = Regex::new(r"^\s*(?:[-*•·]|\d+[.)、]|[（(][一二三四五六七八九十\d]+[)）]|[一二三四五六七八九十]+、)\s*").unwrap();

    for raw_line in lines {
        let line = raw_line.trim();
        if line.is_empty() {
            if !current.is_empty() {
                paragraphs.push(std::mem::take(&mut current));
            }
            continue;
        }
        if bullet_re.is_match(line) {
            if !current.is_empty() {
                paragraphs.push(std::mem::take(&mut current));
            }
            current = line.to_string();
            continue;
        }
        if current.is_empty() {
            current = line.to_string();
            continue;
        }

        // 处理英文跨行连字符断词
        if current.ends_with('-') {
            let first_next = line.chars().next().unwrap_or(' ');
            if first_next.is_ascii_lowercase() {
                let last_word = current[..current.len() - 1]
                    .rsplit(|c: char| c.is_whitespace())
                    .next()
                    .unwrap_or("")
                    .to_lowercase();
                let keep_hyphen = HYPHEN_KEEP_PREFIXES.iter().any(|&p| last_word == p);
                if keep_hyphen {
                    current.push_str(line);
                } else {
                    current.pop();
                    current.push_str(line);
                }
                continue;
            }
        }

        let prev_last = current.chars().last().unwrap_or(' ');
        let next_first = line.chars().next().unwrap_or(' ');
        if is_cjk(prev_last) && is_cjk(next_first) {
            current.push_str(line);
        } else if is_cjk(prev_last) || is_cjk(next_first) {
            current.push_str(line);
        } else {
            current.push(' ');
            current.push_str(line);
        }
    }

    if !current.is_empty() {
        paragraphs.push(current);
    }
    paragraphs.join("\n\n")
}

pub fn apply_pangu_spacing(text: &str) -> String {
    // 保护 URL 不被插入空格
    let url_re = Regex::new(r"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+").unwrap();
    let mut placeholders: Vec<String> = Vec::new();
    let mut masked = String::with_capacity(text.len());
    let mut last_end = 0;
    for m in url_re.find_iter(text) {
        masked.push_str(&text[last_end..m.start()]);
        let token = format!("\u{E000}URL{}\u{E001}", placeholders.len());
        placeholders.push(m.as_str().to_string());
        masked.push_str(&token);
        last_end = m.end();
    }
    masked.push_str(&text[last_end..]);

    let chars: Vec<char> = masked.chars().collect();
    let mut spaced = String::with_capacity(masked.len() + 32);
    for i in 0..chars.len() {
        let c = chars[i];
        spaced.push(c);
        if i + 1 < chars.len() {
            let next = chars[i + 1];
            let left_cjk_right_latin = is_cjk(c)
                && (next.is_ascii_alphanumeric()
                    || next == '\u{E000}'
                    || next == '@'
                    || next == '#');
            let left_latin_right_cjk =
                (c.is_ascii_alphanumeric() || c == '%' || c == '\u{E001}') && is_cjk(next);
            if left_cjk_right_latin || left_latin_right_cjk {
                spaced.push(' ');
            }
        }
    }

    for (idx, url) in placeholders.iter().enumerate() {
        let token = format!("\u{E000}URL{idx}\u{E001}");
        spaced = spaced.replace(&token, url);
    }
    spaced
}

pub fn analyze_document_typography(raw: &str) -> Vec<QuickAction> {
    let trimmed = raw.trim();
    if trimmed.chars().count() < 6 || raw.len() > 32_768 {
        return Vec::new();
    }
    if trimmed.contains('{')
        || trimmed.contains('}')
        || trimmed.starts_with("http://")
        || trimmed.starts_with("https://")
        || trimmed.contains("func ")
        || trimmed.contains("import ")
    {
        return Vec::new();
    }

    let mut actions = Vec::new();
    let non_empty_lines: Vec<&str> = trimmed
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    if non_empty_lines.len() >= 2 {
        let mid_breaks = non_empty_lines[..non_empty_lines.len() - 1]
            .iter()
            .filter(|l| {
                let last = l.chars().last().unwrap_or('.');
                !matches!(
                    last,
                    '。' | '！' | '？' | '；' | '.' | '!' | '?' | ';' | ':' | '：'
                )
            })
            .count();
        if mid_breaks >= 1 {
            let healed = heal_pdf_line_breaks(raw);
            if healed != trimmed {
                actions.push(QuickAction {
                    id: "doc-pdf-heal",
                    title: "缝合 PDF 断行".to_string(),
                    is_security: false,
                    result_text: healed,
                    html_table_payload: None,
                    toast_text: "已智能缝合 PDF 跨行断句".to_string(),
                });
            }
        }
    }

    let base = actions
        .first()
        .map(|a| a.result_text.as_str())
        .unwrap_or(trimmed);
    let spaced = apply_pangu_spacing(base);
    if spaced != base {
        actions.push(QuickAction {
            id: "doc-pangu-space",
            title: if actions.is_empty() {
                "中英空格美化".to_string()
            } else {
                "缝合+中英美化".to_string()
            },
            is_security: false,
            result_text: spaced,
            html_table_payload: None,
            toast_text: "已规范化中英文数字间距".to_string(),
        });
    }

    actions
}

fn is_cjk(c: char) -> bool {
    ('\u{4E00}'..='\u{9FFF}').contains(&c)
}

// ============================================================================
// 引擎 3：二维表格破壁器 + Windows 标准 CF_HTML 精确偏移剪贴板协议
// ============================================================================

/// 生成符合微软 `HTML Format` (CF_HTML) 剪贴板规范的完整负载（精确 10 位十进制 UTF-8 字节偏移）
pub fn build_windows_cf_html_payload(html_fragment: &str) -> String {
    let prefix_html = "<html>\r\n<body>\r\n<!--StartFragment-->";
    let suffix_html = "<!--EndFragment-->\r\n</body>\r\n</html>";
    // 固定长度头部模板（偏移字段固定 10 位宽，总头部长度恒定为 105 字节）
    let header_template = "Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\n";
    let start_html = header_template.len();
    let start_fragment = start_html + prefix_html.len();
    let end_fragment = start_fragment + html_fragment.len();
    let end_html = end_fragment + suffix_html.len();

    format!(
        "Version:0.9\r\nStartHTML:{start_html:010}\r\nEndHTML:{end_html:010}\r\nStartFragment:{start_fragment:010}\r\nEndFragment:{end_fragment:010}\r\n{prefix_html}{html_fragment}{suffix_html}"
    )
}

pub fn to_html_table_fragment(tsv: &str) -> Option<String> {
    let rows: Vec<Vec<&str>> = tsv
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| l.split('\t').collect())
        .collect();
    if rows.is_empty() {
        return None;
    }
    let mut html = String::from("<table border=\"1\" style=\"border-collapse:collapse;\">");
    for (r_idx, row) in rows.iter().enumerate() {
        html.push_str("<tr>");
        let tag = if r_idx == 0 { "th" } else { "td" };
        for cell in row {
            let escaped = cell
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;");
            html.push_str(&format!("<{tag}>{escaped}</{tag}>"));
        }
        html.push_str("</tr>");
    }
    html.push_str("</table>");
    Some(html)
}

pub fn analyze_table_bridge(raw: &str) -> Vec<QuickAction> {
    if !raw.contains('\n') || raw.len() > 65_536 || (!raw.contains('|') && !raw.contains('\t')) {
        return Vec::new();
    }

    // 1. Markdown Table -> Excel (TSV + CF_HTML) / CSV
    if let Some(grid) = parse_markdown_table(raw) {
        let tsv: String = grid
            .iter()
            .map(|r| r.join("\t"))
            .collect::<Vec<_>>()
            .join("\n");
        let csv: String = grid
            .iter()
            .map(|r| {
                r.iter()
                    .map(|cell| {
                        if cell.contains(',') || cell.contains('"') || cell.contains('\n') {
                            format!("\"{}\"", cell.replace('"', "\"\""))
                        } else {
                            cell.clone()
                        }
                    })
                    .collect::<Vec<_>>()
                    .join(",")
            })
            .collect::<Vec<_>>()
            .join("\n");
        let cf_html = to_html_table_fragment(&tsv).map(|frag| build_windows_cf_html_payload(&frag));

        return vec![
            QuickAction {
                id: "tbl-md-to-excel",
                title: "转 Excel 分列直粘".to_string(),
                is_security: false,
                result_text: tsv,
                html_table_payload: cf_html,
                toast_text: format!("已转为 Excel 双协议分列格式（{} 行）", grid.len()),
            },
            QuickAction {
                id: "tbl-md-to-csv",
                title: "转 CSV".to_string(),
                is_security: false,
                result_text: csv,
                html_table_payload: None,
                toast_text: "已转为标准 CSV 表格".to_string(),
            },
        ];
    }

    // 2. Excel TSV -> Markdown Table / JSON 数组
    if let Some(grid) = parse_tsv_table(raw) {
        let col_count = grid[0].len();
        let header = format!("| {} |", grid[0].join(" | "));
        let sep = format!("| {} |", vec!["---"; col_count].join(" | "));
        let mut md_lines = vec![header, sep];
        for row in grid.iter().skip(1) {
            md_lines.push(format!("| {} |", row.join(" | ")));
        }
        let mut actions = vec![QuickAction {
            id: "tbl-tsv-to-md",
            title: "转 Markdown 表格".to_string(),
            is_security: false,
            result_text: md_lines.join("\n"),
            html_table_payload: None,
            toast_text: "已转为标准 Markdown 表格".to_string(),
        }];

        if grid.len() >= 2 {
            let headers = &grid[0];
            let mut objs = Vec::new();
            for row in grid.iter().skip(1) {
                let mut map = serde_json::Map::new();
                for (c, key) in headers.iter().enumerate() {
                    let val = row.get(c).cloned().unwrap_or_default();
                    map.insert(key.clone(), Value::String(val));
                }
                objs.push(Value::Object(map));
            }
            if let Ok(json_str) = serde_json::to_string_pretty(&objs) {
                actions.push(QuickAction {
                    id: "tbl-tsv-to-json",
                    title: "转 JSON 数组".to_string(),
                    is_security: false,
                    result_text: json_str,
                    html_table_payload: None,
                    toast_text: "已按表头转为 JSON 对象数组".to_string(),
                });
            }
        }
        return actions;
    }

    Vec::new()
}

fn parse_markdown_table(raw: &str) -> Option<Vec<Vec<String>>> {
    let lines: Vec<&str> = raw
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    if lines.len() < 2 || !lines[0].contains('|') {
        return None;
    }
    let sep_re = Regex::new(r"^\s*\|?(?:\s*:?-{2,}:?\s*\|)+\s*:?-{2,}:?\s*\|?\s*$").unwrap();
    if !sep_re.is_match(lines[1]) {
        return None;
    }

    let strip_md = |s: &str| -> String {
        s.trim()
            .trim_matches('*')
            .trim_matches('`')
            .trim_matches('_')
            .trim()
            .to_string()
    };

    let split_row = |line: &str| -> Vec<String> {
        let mut s = line.trim();
        if let Some(r) = s.strip_prefix('|') {
            s = r;
        }
        if let Some(r) = s.strip_suffix('|') {
            s = r;
        }
        s.split('|').map(strip_md).collect()
    };

    let mut grid = vec![split_row(lines[0])];
    if grid[0].len() < 2 {
        return None;
    }
    for line in lines.iter().skip(2) {
        if !line.contains('|') {
            return None;
        }
        if sep_re.is_match(line) {
            continue;
        }
        grid.push(split_row(line));
    }
    Some(grid)
}

fn parse_tsv_table(raw: &str) -> Option<Vec<Vec<String>>> {
    let lines: Vec<&str> = raw.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.len() < 2 {
        return None;
    }
    // 排除 Tab 缩进代码
    if lines.iter().any(|l| l.starts_with('\t')) {
        return None;
    }
    let expected_cols = lines[0].split('\t').count();
    if expected_cols < 2 {
        return None;
    }
    let mut grid = Vec::with_capacity(lines.len());
    for line in lines {
        let cols: Vec<String> = line.split('\t').map(|c| c.trim().to_string()).collect();
        if cols.len() != expected_cols {
            return None;
        }
        grid.push(cols);
    }
    Some(grid)
}

// ============================================================================
// 引擎 4：截图白底合成瞬时瘦身 JPEG & 柔光圆角阴影样机衬底渲染
// ============================================================================

pub fn compress_png_to_white_bg_jpeg(png_bytes: &[u8], quality: u8) -> Option<Vec<u8>> {
    let img = image::load_from_memory(png_bytes).ok()?.to_rgba8();
    let (w, h) = img.dimensions();
    let mut rgb_buf = Vec::with_capacity((w * h * 3) as usize);

    for px in img.pixels() {
        let a = px[3] as u32;
        let inv_a = 255 - a;
        let r = ((px[0] as u32 * a + 255 * inv_a) / 255) as u8;
        let g = ((px[1] as u32 * a + 255 * inv_a) / 255) as u8;
        let b = ((px[2] as u32 * a + 255 * inv_a) / 255) as u8;
        rgb_buf.push(r);
        rgb_buf.push(g);
        rgb_buf.push(b);
    }

    let mut out = Vec::new();
    let encoder = JpegEncoder::new_with_quality(&mut out, quality);
    encoder
        .write_image(&rgb_buf, w, h, ColorType::Rgb8.into())
        .ok()?;
    Some(out)
}

pub fn render_mockup_frame_png(png_bytes: &[u8], padding: u32) -> Option<(Vec<u8>, u32, u32)> {
    let src = image::load_from_memory(png_bytes).ok()?.to_rgba8();
    let (w, h) = src.dimensions();
    let out_w = w + padding * 2;
    let out_h = h + padding * 2;
    let radius = 14.0f32;

    let mut canvas = RgbaImage::new(out_w, out_h);
    // 1. 柔和冰雾蓝白渐变衬底 + 外围自然落影
    for y in 0..out_h {
        let ty = y as f32 / out_h.max(1) as f32;
        for x in 0..out_w {
            let tx = x as f32 / out_w.max(1) as f32;
            let mut r = 240.0 - tx * 12.0 - ty * 8.0;
            let mut g = 244.0 - tx * 8.0 - ty * 6.0;
            let mut b = 251.0 - ty * 4.0;

            // 计算到内容卡片圆角矩形的有向距离以叠加柔和阴影（带垂直偏移 y - 6）
            let dist = signed_distance_rounded_rect(
                x as f32,
                (y as f32) - 6.0,
                padding as f32,
                padding as f32,
                w as f32,
                h as f32,
                radius,
            );
            if dist > 0.0 && dist < 24.0 {
                let shadow_alpha = (1.0 - dist / 24.0).powi(2) * 0.20;
                r *= 1.0 - shadow_alpha;
                g *= 1.0 - shadow_alpha;
                b *= 1.0 - shadow_alpha;
            }
            canvas.put_pixel(x, y, Rgba([r as u8, g as u8, b as u8, 255]));
        }
    }

    // 2. 绘制抗锯齿圆角截图主体
    for sy in 0..h {
        for sx in 0..w {
            let cx = padding + sx;
            let cy = padding + sy;
            let dist = signed_distance_rounded_rect(
                cx as f32 + 0.5,
                cy as f32 + 0.5,
                padding as f32,
                padding as f32,
                w as f32,
                h as f32,
                radius,
            );
            if dist <= 0.5 {
                let edge_cov = (0.5 - dist).clamp(0.0, 1.0);
                let fg = src.get_pixel(sx, sy);
                let bg = canvas.get_pixel(cx, cy);
                let fg_a = (fg[3] as f32 / 255.0) * edge_cov;
                let blend = |f: u8, b_c: u8| -> u8 {
                    ((f as f32 * fg_a) + (b_c as f32 * (1.0 - fg_a))).round() as u8
                };
                canvas.put_pixel(
                    cx,
                    cy,
                    Rgba([
                        blend(fg[0], bg[0]),
                        blend(fg[1], bg[1]),
                        blend(fg[2], bg[2]),
                        255,
                    ]),
                );
            }
        }
    }

    let mut out = Vec::new();
    let enc = PngEncoder::new(&mut out);
    enc.write_image(canvas.as_raw(), out_w, out_h, ColorType::Rgba8.into())
        .ok()?;
    Some((out, out_w, out_h))
}

fn signed_distance_rounded_rect(
    px: f32,
    py: f32,
    rx: f32,
    ry: f32,
    rw: f32,
    rh: f32,
    radius: f32,
) -> f32 {
    let cx = rx + rw * 0.5;
    let cy = ry + rh * 0.5;
    let hx = rw * 0.5 - radius;
    let hy = rh * 0.5 - radius;
    let dx = (px - cx).abs() - hx;
    let dy = (py - cy).abs() - hy;
    let outside = (dx.max(0.0).powi(2) + dy.max(0.0).powi(2)).sqrt();
    let inside = dx.max(dy).min(0.0);
    outside + inside - radius
}

// ============================================================================
// 引擎 5：身份证 GB 11643 / 企业税号 GB 32100 / 银行卡 Luhn 离线国标校验
// ============================================================================

const ID_WEIGHTS: [u32; 17] = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
const ID_MAP: [char; 11] = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];

const USCC_ALPHABET: &[u8; 31] = b"0123456789ABCDEFGHJKLMNPQRTUWXY";
const USCC_WEIGHTS: [u32; 17] = [
    1, 3, 9, 27, 19, 26, 16, 17, 20, 29, 25, 13, 8, 24, 10, 30, 28,
];
const VALID_PROVINCE_CODES: [&str; 35] = [
    "11", "12", "13", "14", "15", "21", "22", "23", "31", "32", "33", "34", "35", "36", "37", "41",
    "42", "43", "44", "45", "46", "50", "51", "52", "53", "54", "61", "62", "63", "64", "65", "71",
    "81", "82", "91",
];

pub fn expected_id_card_checksum(first17: &str) -> Option<char> {
    if first17.len() != 17 || !first17.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if !VALID_PROVINCE_CODES.contains(&&first17[0..2]) {
        return None;
    }
    let year: u32 = first17[6..10].parse().ok()?;
    let month: u32 = first17[10..12].parse().ok()?;
    let day: u32 = first17[12..14].parse().ok()?;
    if !(1900..=2099).contains(&year) || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let sum: u32 = first17
        .bytes()
        .zip(ID_WEIGHTS.iter())
        .map(|(b, &w)| (b - b'0') as u32 * w)
        .sum();
    Some(ID_MAP[(sum % 11) as usize])
}

pub fn expected_uscc_checksum(first17: &str) -> Option<char> {
    if first17.len() != 17 {
        return None;
    }
    let upper = first17.to_ascii_uppercase();
    let first_byte = upper.as_bytes()[0];
    if !matches!(first_byte, b'1' | b'5' | b'9' | b'Y') {
        return None;
    }
    if !VALID_PROVINCE_CODES.contains(&&upper[2..4]) {
        return None;
    }
    let mut sum = 0u32;
    for (b, &w) in upper.bytes().zip(USCC_WEIGHTS.iter()) {
        let idx = USCC_ALPHABET.iter().position(|&c| c == b)? as u32;
        sum += idx * w;
    }
    let rem = (31 - (sum % 31)) % 31;
    Some(USCC_ALPHABET[rem as usize] as char)
}

pub fn passes_luhn_check(digits: &str) -> bool {
    if !(15..=19).contains(&digits.len()) || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }
    if digits.bytes().all(|b| b == digits.as_bytes()[0]) {
        return false;
    }
    let mut sum = 0u32;
    for (i, b) in digits.bytes().rev().enumerate() {
        let mut d = (b - b'0') as u32;
        if i % 2 == 1 {
            d *= 2;
            if d > 9 {
                d -= 9;
            }
        }
        sum += d;
    }
    sum % 10 == 0
}

pub fn analyze_compliance_codes(raw: &str) -> Vec<QuickAction> {
    let compact: String = raw
        .trim()
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .collect();

    // 1. 18 位身份证校验
    if compact.len() == 18 {
        let first17 = &compact[0..17];
        let actual = compact.chars().last().unwrap().to_ascii_uppercase();
        if (actual.is_ascii_digit() || actual == 'X') && first17.bytes().all(|b| b.is_ascii_digit())
        {
            if let Some(expected) = expected_id_card_checksum(first17) {
                if actual == expected {
                    let grouped = format!(
                        "{} {} {}",
                        &compact[0..6],
                        &compact[6..14],
                        &compact[14..18].to_ascii_uppercase()
                    );
                    let masked = format!(
                        "{}********{}",
                        &compact[0..6],
                        &compact[14..18].to_ascii_uppercase()
                    );
                    return vec![
                        QuickAction {
                            id: "comp-id-group",
                            title: format!("✓ 身份证无误 · {grouped}"),
                            is_security: false,
                            result_text: grouped,
                            html_table_payload: None,
                            toast_text: "国标校验通过，已按 6-8-4 分节".to_string(),
                        },
                        QuickAction {
                            id: "comp-id-mask",
                            title: format!("合规掩码 {masked}"),
                            is_security: true,
                            result_text: masked,
                            html_table_payload: None,
                            toast_text: "已掩码出生年月日隐私位".to_string(),
                        },
                    ];
                } else {
                    let fixed = format!("{first17}{expected}");
                    return vec![QuickAction {
                        id: "comp-id-invalid",
                        title: format!("⚠️ 身份证末位有误（应为 {expected}）"),
                        is_security: false,
                        result_text: fixed,
                        html_table_payload: None,
                        toast_text: "已修正身份证校验位".to_string(),
                    }];
                }
            }
        }
    }

    // 2. 18 位企业税号（含 O/0 与 I/1 手误纠错）
    if compact.len() == 18 && compact.bytes().all(|b| b.is_ascii_alphanumeric()) {
        let upper = compact.to_ascii_uppercase();
        let typo_fixed = upper.replace('O', "0").replace('I', "1");
        if typo_fixed != upper {
            if let Some(exp) = expected_uscc_checksum(&typo_fixed[0..17]) {
                if typo_fixed.chars().last() == Some(exp) {
                    return vec![QuickAction {
                        id: "comp-uscc-fix",
                        title: format!("⚠️ 修正手误字母 -> {typo_fixed}"),
                        is_security: false,
                        result_text: typo_fixed,
                        html_table_payload: None,
                        toast_text: "已将误输 O/I 修正为合法税号".to_string(),
                    }];
                }
            }
        }
        if let Some(exp) = expected_uscc_checksum(&upper[0..17]) {
            let actual = upper.chars().last().unwrap();
            if actual == exp {
                let grouped = format!(
                    "{} {} {} {}",
                    &upper[0..2],
                    &upper[2..8],
                    &upper[8..17],
                    &upper[17..18]
                );
                return vec![QuickAction {
                    id: "comp-uscc-group",
                    title: "✓ 企业税号无误 · 分节核对".to_string(),
                    is_security: false,
                    result_text: grouped,
                    html_table_payload: None,
                    toast_text: "GB 32100 税号校验通过".to_string(),
                }];
            }
        }
    }

    // 3. 15~19 位银行卡号 Luhn 校验
    if (15..=19).contains(&compact.len()) && compact.bytes().all(|b| b.is_ascii_digit()) {
        let p2 = &compact[0..2];
        let looks_like_card = compact.starts_with("62")
            || compact.starts_with('4')
            || matches!(p2, "51" | "52" | "53" | "54" | "55" | "34" | "37" | "35");
        if looks_like_card && passes_luhn_check(&compact) {
            let grouped = compact
                .as_bytes()
                .chunks(4)
                .map(|c| std::str::from_utf8(c).unwrap())
                .collect::<Vec<_>>()
                .join(" ");
            let masked = format!(
                "{} **** **** {}",
                &compact[0..4],
                &compact[compact.len() - 4..]
            );
            return vec![
                QuickAction {
                    id: "comp-card-group",
                    title: format!("✓ 卡号校验通过 · {grouped}"),
                    is_security: false,
                    result_text: grouped,
                    html_table_payload: None,
                    toast_text: "Luhn 校验通过，已按四位分节".to_string(),
                },
                QuickAction {
                    id: "comp-card-mask",
                    title: format!("尾号掩码 {masked}"),
                    is_security: true,
                    result_text: masked,
                    html_table_payload: None,
                    toast_text: "已生成首尾四位合规掩码卡号".to_string(),
                },
            ];
        }
    }

    Vec::new()
}

// ============================================================================
// 引擎 6：会议逐字稿去时间轴 & 一次性验证码（OTP）抗干扰提取
// ============================================================================

const OTP_KEYWORDS: [&str; 19] = [
    "验证码",
    "校验码",
    "动态码",
    "安全码",
    "确认码",
    "登录码",
    "授权码",
    "提取码",
    "认证码",
    "verification code",
    "security code",
    "auth code",
    "authentication code",
    "login code",
    "confirmation code",
    "one-time password",
    "one-time code",
    "passcode",
    "otp",
];

pub fn is_otp_message(raw: &str) -> bool {
    extract_verification_code(raw).is_some()
}

pub fn extract_verification_code(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.chars().count() < 6 || trimmed.len() > 800 || trimmed.lines().count() > 8 {
        return None;
    }

    let lower = trimmed.to_lowercase();
    let has_kw = OTP_KEYWORDS.iter().any(|&kw| {
        if kw == "otp" {
            Regex::new(r"\botp\b").unwrap().is_match(&lower)
        } else {
            lower.contains(kw)
        }
    });
    if !has_kw {
        return None;
    }

    let noise_patterns = [
        r"(?i)(?:尾号(?:为|是)?|ending\s+in)\s*[0-9A-Za-z]{3,6}",
        r"(?i)\b\d{1,4}\s*(?:分钟|分|秒钟|秒|小时|min|mins|minute|minutes|sec|secs|second|seconds|hr|hrs|hours)\b",
        r"(?i)(?:[¥￥$€£]\s*\d+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?\s*(?:元|圆|RMB|USD))",
        r"\b(?:\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?|\d{1,2}:\d{2}(?::\d{2})?)\b",
    ];

    let mut sanitized = trimmed.to_string();
    for pat in noise_patterns {
        let re = Regex::new(pat).unwrap();
        sanitized = re.replace_all(&sanitized, " ").into_owned();
    }

    // 紧跟关键词后的 4~8 位数字或含数字的混合码
    let after_re = Regex::new(
        r##"(?i)(?:验证码|校验码|动态码|安全码|确认码|登录码|授权码|提取码|认证码|(?:verification|security|auth|authentication|login|confirmation|one-time)\s+code|passcode|\botp\b)\s*(?:为|是|is)?\s*[:：]?\s*[\(\[【「『"']?([A-Za-z0-9]{4,8})[\)\]】」』"']?"##,
    )
    .unwrap();

    if let Some(caps) = after_re.captures(&sanitized) {
        let code = caps.get(1).unwrap().as_str();
        if code.bytes().any(|b| b.is_ascii_digit()) {
            return Some(code.to_string());
        }
    }

    // 验证码在前的英文/中文句式
    let before_re = Regex::new(
        r#"(?i)\b([A-Za-z0-9]{4,8})\b[^\n]{0,28}?(?:验证码|校验码|动态码|安全码|确认码|(?:verification|security|auth|login|confirmation|one-time)\s+code|passcode|\botp\b)"#,
    )
    .unwrap();
    if let Some(caps) = before_re.captures(&sanitized) {
        let code = caps.get(1).unwrap().as_str();
        if code.bytes().any(|b| b.is_ascii_digit()) {
            return Some(code.to_string());
        }
    }

    // 兜底：清洗干扰后的首个独立 4~8 位纯数字
    let digits_re = Regex::new(r"\b([0-9]{4,8})\b").unwrap();
    for caps in digits_re.captures_iter(&sanitized) {
        return Some(caps.get(1).unwrap().as_str().to_string());
    }

    None
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CleanedTranscript {
    pub plain_body: String,
    pub speaker_merged: Option<String>,
    pub removed_timestamps: usize,
}

pub fn clean_meeting_transcript(raw: &str) -> Option<CleanedTranscript> {
    if raw.len() > 65_536 || !raw.contains(':') {
        return None;
    }

    let log_excl = Regex::new(
        r"(?:\[(?:INFO|WARN|WARNING|ERROR|DEBUG|TRACE|FATAL)\]|Exception\b|Traceback\b|\bHTTP/\d\.\d\b|\b(?:GET|POST|PUT|DELETE)\s+/|\berrno\b|\bpid=\d+)",
    )
    .unwrap();
    if log_excl.is_match(raw) {
        return None;
    }

    let normalized = raw.replace("\r\n", "\n");
    let lines: Vec<&str> = normalized.split('\n').collect();
    if lines.len() < 2 {
        return None;
    }

    let srt_re = Regex::new(
        r"^\s*\d{1,2}:\d{2}(?::\d{2})?[.,]\d{1,3}\s*-->\s*\d{1,2}:\d{2}(?::\d{2})?[.,]\d{1,3}.*$",
    )
    .unwrap();
    let standalone_ts_re =
        Regex::new(r"^\s*[\(\[（【]?(\d{1,2}:\d{2}(?::\d{2})?)[\)\]）】]?\s*$").unwrap();
    let header_re = Regex::new(r"^\s*([^\d\[\]\n:：]{1,24}?(?:\s*\d{1,2})?)\s*[\(\[（【]?\b(\d{1,2}:\d{2}(?::\d{2})?)\b[\)\]）】]?\s*$").unwrap();
    let inline_re = Regex::new(r"^\s*[\(\[（【]?\b(\d{1,2}:\d{2}(?::\d{2})?)\b[\)\]）】]?\s*(?:([^\d\[\]\n:：]{1,20}?)\s*[:：]\s*)?(.+)$").unwrap();

    let mut hits = 0usize;
    let mut active_speaker: Option<String> = None;
    let mut plain_segments: Vec<String> = Vec::new();
    let mut turns: Vec<(Option<String>, String)> = Vec::new();

    let mut i = 0;
    while i < lines.len() {
        let line = lines[i].trim();
        if line.is_empty() || line.eq_ignore_ascii_case("WEBVTT") {
            i += 1;
            continue;
        }
        if line.bytes().all(|b| b.is_ascii_digit())
            && i + 1 < lines.len()
            && srt_re.is_match(lines[i + 1].trim())
        {
            hits += 1;
            i += 2;
            continue;
        }
        if srt_re.is_match(line) || standalone_ts_re.is_match(line) {
            hits += 1;
            i += 1;
            continue;
        }
        if let Some(caps) = header_re.captures(line) {
            let sp = caps.get(1).unwrap().as_str().trim();
            if !sp.is_empty() {
                active_speaker = Some(sp.to_string());
                hits += 1;
                i += 1;
                continue;
            }
        }
        if let Some(caps) = inline_re.captures(line) {
            let sp = caps
                .get(2)
                .map(|m| m.as_str().trim().to_string())
                .filter(|s| !s.is_empty());
            let content = caps.get(3).unwrap().as_str().trim().to_string();
            hits += 1;
            if let Some(ref s) = sp {
                active_speaker = Some(s.clone());
            }
            if !content.is_empty() {
                plain_segments.push(content.clone());
                push_dialogue_turn(&mut turns, sp.or_else(|| active_speaker.clone()), content);
            }
            i += 1;
            continue;
        }

        plain_segments.push(line.to_string());
        push_dialogue_turn(&mut turns, active_speaker.clone(), line.to_string());
        i += 1;
    }

    if hits < 2 || plain_segments.is_empty() {
        return None;
    }

    let mut plain_body = plain_segments[0].clone();
    for seg in plain_segments.iter().skip(1) {
        plain_body = join_fragments(&plain_body, seg);
    }

    let has_speaker = turns.iter().any(|(s, _)| s.is_some());
    let speaker_merged = if has_speaker {
        Some(
            turns
                .into_iter()
                .map(|(sp, txt)| match sp {
                    Some(s) => format!("{s}：{txt}"),
                    None => txt,
                })
                .collect::<Vec<_>>()
                .join("\n"),
        )
    } else {
        None
    };

    Some(CleanedTranscript {
        plain_body,
        speaker_merged,
        removed_timestamps: hits,
    })
}

pub fn analyze_meeting_transcript(raw: &str) -> Vec<QuickAction> {
    let Some(cleaned) = clean_meeting_transcript(raw) else {
        return Vec::new();
    };
    let mut actions = vec![QuickAction {
        id: "meet-plain-body",
        title: "纯享正文(去时间轴)".to_string(),
        is_security: false,
        result_text: cleaned.plain_body.clone(),
        html_table_payload: None,
        toast_text: format!("已剥离 {} 处会议时间轴", cleaned.removed_timestamps),
    }];
    if let Some(merged) = cleaned.speaker_merged {
        if merged != cleaned.plain_body {
            actions.push(QuickAction {
                id: "meet-speaker-notes",
                title: "按发言人合并纪要".to_string(),
                is_security: false,
                result_text: merged,
                html_table_payload: None,
                toast_text: "已合并同发言人段落并去除时间轴".to_string(),
            });
        }
    }
    actions
}

fn push_dialogue_turn(
    turns: &mut Vec<(Option<String>, String)>,
    speaker: Option<String>,
    text: String,
) {
    if let Some((last_sp, last_txt)) = turns.last_mut() {
        if *last_sp == speaker {
            *last_txt = join_fragments(last_txt, &text);
            return;
        }
    }
    turns.push((speaker, text));
}

fn join_fragments(lhs: &str, rhs: &str) -> String {
    let Some(last_c) = lhs.chars().last() else {
        return rhs.to_string();
    };
    let Some(first_c) = rhs.chars().next() else {
        return lhs.to_string();
    };
    let is_punct = matches!(
        last_c,
        '。' | '！' | '？' | '；' | '，' | '、' | '.' | '!' | '?' | ';' | ','
    );
    if is_punct {
        if last_c.is_ascii() && first_c.is_ascii_alphanumeric() {
            format!("{lhs} {rhs}")
        } else {
            format!("{lhs}{rhs}")
        }
    } else if last_c.is_ascii_alphanumeric() || first_c.is_ascii_alphanumeric() {
        format!("{lhs} {rhs}")
    } else {
        format!("{lhs}，{rhs}")
    }
}

// ============================================================================
// 引擎 7：极客开发版 AI 密钥脱敏、追踪净链与动态模板渲染
// ============================================================================

pub fn contains_sensitive_secret(text: &str) -> bool {
    if text.contains("-----BEGIN ") && text.contains("PRIVATE KEY-----") {
        return true;
    }
    redact_secrets(text) != text
}

pub fn redact_secrets(text: &str) -> String {
    let mut out = text.to_string();
    if out.contains("-----BEGIN ") && out.contains("PRIVATE KEY-----") {
        let pem_re = Regex::new(
            r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
        )
        .unwrap();
        out = pem_re
            .replace_all(
                &out,
                "-----BEGIN PRIVATE KEY-----\n[REDACTED_BY_iCLIP]\n-----END PRIVATE KEY-----",
            )
            .into_owned();
    }

    let rules: &[(&str, &str, &str)] = &[
        ("sk-", r"sk-[A-Za-z0-9_\-]{18,}", "sk-***REDACTED***"),
        (
            "gh",
            r"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{30,}",
            "gh_***REDACTED***",
        ),
        ("AKIA", r"AKIA[0-9A-Z]{16}", "AKIA***REDACTED***"),
        ("AIza", r"AIza[0-9A-Za-z\-_]{35}", "AIza***REDACTED***"),
        (
            "eyJ",
            r"eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}",
            "eyJ***JWT_REDACTED***",
        ),
        (
            "Bearer",
            r"(?i)(Bearer\s+)[A-Za-z0-9\-._~+/]{20,}=*",
            "${1}***REDACTED***",
        ),
        (
            "://",
            r"([a-zA-Z][a-zA-Z0-9+.\-]*://[^:\s/@]+:)([^@\s/]+)(@)",
            "${1}***REDACTED***${3}",
        ),
        (
            "=",
            r"(?i)([?&](?:api_key|apikey|access_token|auth_token|client_secret|secret|password|passwd)=)([^&\s#]{8,})",
            "${1}***REDACTED***",
        ),
    ];
    for (hint, pat, rep) in rules {
        if out.contains(hint) || (*hint == "Bearer" && out.to_lowercase().contains("bearer")) {
            let re = Regex::new(pat).unwrap();
            out = re.replace_all(&out, *rep).into_owned();
        }
    }

    if out.contains('=') || out.contains(':') {
        let env_re = Regex::new(
            r##"(?im)^(\s*(?:export\s+)?[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|API_KEY|ACCESS_KEY|PRIVATE_KEY|AUTH_TOKEN|CLIENT_SECRET)[A-Z0-9_]*\s*[:=]\s*['"]?)([^\s'"#]{6,})(['"]?)"##,
        )
        .unwrap();
        out = env_re
            .replace_all(&out, "${1}***REDACTED***${3}")
            .into_owned();
    }

    out = crate::security::mask_verified_identity_and_cards(&out);
    out
}

pub fn redact_pii_and_private_ip(text: &str) -> String {
    let ip_re = Regex::new(r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3})\b").unwrap();
    let email_re =
        Regex::new(r"\b([A-Za-z0-9._%+\-])([A-Za-z0-9._%+\-]*)(@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})\b")
            .unwrap();
    let phone_re = Regex::new(r"\b(1[3-9]\d)\d{4}(\d{4})\b").unwrap();

    let mut out = ip_re.replace_all(text, "*.*.*.*").into_owned();
    out = email_re.replace_all(&out, "${1}***${3}").into_owned();
    out = phone_re.replace_all(&out, "${1}****${2}").into_owned();
    out
}

pub fn clean_tracking_url(raw: &str) -> Option<String> {
    if !(raw.starts_with("http://") || raw.starts_with("https://")) {
        return None;
    }
    let (base_and_q, frag) = match raw.split_once('#') {
        Some((b, f)) => (b, Some(f)),
        None => (raw, None),
    };
    let (base, query) = base_and_q.split_once('?')?;
    let tracking_keys = [
        "utm_source",
        "utm_medium",
        "utm_campaign",
        "utm_term",
        "utm_content",
        "utm_id",
        "spm",
        "spm_id_from",
        "vd_source",
        "from_source",
        "share_source",
        "share_medium",
        "fbclid",
        "gclid",
        "dclid",
        "msclkid",
        "twclid",
        "igshid",
        "igsh",
        "si",
    ];

    let mut kept = Vec::new();
    let mut removed_any = false;
    for pair in query.split('&') {
        if pair.is_empty() {
            continue;
        }
        let key = pair.split('=').next().unwrap_or("").to_ascii_lowercase();
        if key.starts_with("utm_") || tracking_keys.contains(&key.as_str()) {
            removed_any = true;
        } else {
            kept.push(pair);
        }
    }
    if !removed_any {
        return None;
    }

    let mut out = base.to_string();
    if !kept.is_empty() {
        out.push('?');
        out.push_str(&kept.join("&"));
    }
    if let Some(f) = frag {
        out.push('#');
        out.push_str(f);
    }
    Some(out)
}

pub fn render_dynamic_template(template: &str, latest_context: Option<&str>) -> String {
    let ctx = latest_context.unwrap_or("");
    let redacted_ctx = redact_pii_and_private_ip(&redact_secrets(ctx));
    let iso = crate::model::unix_secs_to_iso8601(crate::model::now_unix_secs());
    let date_only = &iso[0..10];
    template
        .replace("{{clip_redacted}}", &redacted_ctx)
        .replace("{{clip}}", ctx)
        .replace("{{date}}", date_only)
        .replace("{{datetime}}", &iso)
}
