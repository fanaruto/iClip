use crate::model::{safe_utf8_prefix, QuickAction};
#[cfg(feature = "dev")]
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
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

    // 0.00 最高优双向 AI 替身回填：检测到 AI 回复中包含本会话有效 `[ICLIP_*_N]` 占位符时一键无损还原真值
    if let Some((restored_text, restored_count)) =
        crate::security::inspect_restorable_privacy_twins(raw)
    {
        actions.push(QuickAction {
            id: "restore-privacy-twin",
            title: format!("还原 {restored_count} 处真值"),
            is_security: true,
            result_text: restored_text,
            html_table_payload: None,
            toast_text: format!("已无损还原 {restored_count} 处脱敏真值（本机隔离 · 45s自动擦除）"),
        });
    }

    // 0.0 最高优安全护盾：剪贴板投毒（Bidi / ANSI 控制符劫持）与零宽幽灵字符净化
    if let Some(threat) = crate::security::inspect_clipboard_poison(inspect) {
        let cleaned = crate::security::sanitize_clipboard_poison(raw);
        if cleaned != raw && !cleaned.is_empty() {
            let (title, is_sec, toast) = match threat {
                crate::security::PoisonThreatKind::PastejackingOrBidi(_) => (
                    "净化隐藏控制符".to_string(),
                    true,
                    "已剥离隐藏终端控制符与双向伪装符".to_string(),
                ),
                crate::security::PoisonThreatKind::ZeroWidthGhost(n) => (
                    format!("清除 {n} 个零宽字符"),
                    false,
                    "已清除隐藏零宽幽灵字符".to_string(),
                ),
            };
            actions.push(QuickAction {
                id: "sanitize-invisible-poison",
                title,
                is_security: is_sec,
                result_text: cleaned,
                html_table_payload: None,
                toast_text: toast,
            });
        }
    }

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

    // 0.2 双角色共享：离线 2FA TOTP 动态验证码实时直出（`otpauth://totp/...`）与 Wi-Fi 分享串免扫直提纯密码
    if trimmed.len() <= 2048 {
        if let Some(totp) =
            crate::security::evaluate_totp_uri(trimmed, crate::model::now_unix_secs())
        {
            actions.push(QuickAction {
                id: "totp-live-code",
                title: format!(
                    "动态码 {} · {}s",
                    totp.formatted_code, totp.remaining_seconds
                ),
                is_security: false,
                result_text: totp.code,
                html_table_payload: None,
                toast_text: format!(
                    "已算出 2FA 动态码 {}（30s后自动擦除剪贴板）",
                    totp.formatted_code
                ),
            });
        } else if !trimmed.contains('\n') {
            if let Some((ssid, pw)) = crate::security::parse_wifi_qr_payload(trimmed) {
                let title = if ssid.is_empty() {
                    "提取 Wi-Fi 密码".to_string()
                } else {
                    format!("Wi-Fi 密码 · {ssid}")
                };
                actions.push(QuickAction {
                    id: "wifi-extract-password",
                    title,
                    is_security: true,
                    result_text: pw,
                    html_table_payload: None,
                    toast_text: "已提取纯 Wi-Fi 密码并启用本机云隔离保护".to_string(),
                });
            }
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
        if let Some((twin_masked, twin_cnt)) = crate::security::mask_with_privacy_twins(raw) {
            actions.push(QuickAction {
                id: "redact-reversible-twin",
                title: "AI 替身脱敏".to_string(),
                is_security: true,
                result_text: twin_masked,
                html_table_payload: None,
                toast_text: format!("已生成 {twin_cnt} 处可逆替身（复制 AI 回复可一键还原真值）"),
            });
        }
        if let Some(env_example) = crate::security::generate_env_example_template(raw) {
            actions.push(QuickAction {
                id: "env-to-example",
                title: "生成 .env.example".to_string(),
                is_security: true,
                result_text: env_example,
                html_table_payload: None,
                toast_text: "已生成安全的 .env.example 净模板".to_string(),
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
            if let Some((jwt_decoded, unexpired)) =
                decode_jwt_inspection(trimmed, crate::model::now_unix_secs())
            {
                let chip_title = match unexpired {
                    Some(true) => "解码 JWT · 有效".to_string(),
                    Some(false) => "解码 JWT · 已过期".to_string(),
                    None => "解码 JWT".to_string(),
                };
                actions.push(QuickAction {
                    id: "jwt-decode",
                    title: chip_title,
                    is_security: false,
                    result_text: jwt_decoded,
                    html_table_payload: None,
                    toast_text: "已离线解码 JWT 载荷".to_string(),
                });
            }
        }
    }

    // 0.85 双角色共享：cURL 安全复现瘦身、容错 JSONC 净化、公域去鉴权净链 & 营销追踪净链
    if trimmed
        .as_bytes()
        .get(..5)
        .map(|s| s.eq_ignore_ascii_case(b"curl ") || s.eq_ignore_ascii_case(b"curl\t"))
        .unwrap_or(false)
    {
        if let Some((clean_curl, red_cnt, noise_cnt)) =
            crate::security::sanitize_curl_for_repro(raw)
        {
            let is_sec = red_cnt > 0;
            let insert_idx = if actions.first().map(|a| a.id) == Some("restore-privacy-twin") {
                1.min(actions.len())
            } else {
                actions
                    .iter()
                    .take_while(|a| a.id == "redact-secrets" || a.id == "redact-reversible-twin")
                    .count()
                    .min(actions.len())
            };
            actions.insert(
                insert_idx,
                QuickAction {
                    id: if is_sec {
                        "curl-safe-repro"
                    } else {
                        "curl-slim-clean"
                    },
                    title: if is_sec {
                        "安全复现 cURL".to_string()
                    } else {
                        "精简纯净 cURL".to_string()
                    },
                    is_security: is_sec,
                    result_text: clean_curl,
                    html_table_payload: None,
                    toast_text: if is_sec {
                        format!("已脱敏 {red_cnt} 处凭据并剥除 {noise_cnt} 个浏览器噪音头")
                    } else {
                        format!("已剥除 {noise_cnt} 个浏览器指纹噪音头")
                    },
                },
            );
        }
    } else if raw.len() <= 65_536 {
        if let Some(strict_json) = crate::security::clean_jsonc_to_strict_json(raw) {
            actions.push(QuickAction {
                id: "jsonc-clean-strict",
                title: "净化为标准 JSON".to_string(),
                is_security: false,
                result_text: strict_json,
                html_table_payload: None,
                toast_text: "已剥除注释与尾随逗号，转为标准合法 JSON".to_string(),
            });
        }
    }
    if !trimmed.contains('\n') && trimmed.len() <= 4096 {
        if let Some(public_url) = sanitize_url_for_public_share(trimmed) {
            let pos = usize::from(actions.first().map(|a| a.id) == Some("restore-privacy-twin"))
                .min(actions.len());
            actions.insert(
                pos,
                QuickAction {
                    id: "sanitize-auth-url",
                    title: "去鉴权净链".to_string(),
                    is_security: true,
                    result_text: public_url,
                    html_table_payload: None,
                    toast_text: "已剥离 URL 鉴权令牌与追踪尾巴，可安全外发".to_string(),
                },
            );
        } else if let Some(clean_url) = clean_tracking_url(trimmed) {
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
    if actions.len() < 3
        && raw.len() <= 32_768
        && !actions.iter().any(|a| a.id == "jsonc-clean-strict")
        && serde_json::from_str::<Value>(trimmed).is_err()
    {
        if let Some((decoded_txt, chip_title, toast_txt)) =
            crate::security::decode_escaped_text(raw)
        {
            actions.push(QuickAction {
                id: "decode-escaped-text",
                title: chip_title,
                is_security: false,
                result_text: decoded_txt,
                html_table_payload: None,
                toast_text: toast_txt,
            });
        }
    }
    if actions.len() < 3 && !trimmed.contains('\n') && trimmed.len() <= 512 {
        if let Some((cron_short, cron_comment)) = crate::security::explain_cron_expression(trimmed)
        {
            actions.push(QuickAction {
                id: "cron-explain",
                title: format!("Cron：{cron_short}"),
                is_security: false,
                result_text: cron_comment,
                html_table_payload: None,
                toast_text: format!("已复制 Cron 注释：{cron_short}"),
            });
        } else if let Some((act_id, act_title, act_res, act_toast)) =
            crate::security::analyze_path_action(trimmed)
        {
            actions.push(QuickAction {
                id: act_id,
                title: act_title,
                is_security: false,
                result_text: act_res,
                html_table_payload: None,
                toast_text: act_toast,
            });
        }
    }
    if actions.len() < 3 && raw.len() <= 65_536 && raw.contains('\n') {
        if let Some((dedup_txt, removed_cnt, remain_cnt)) =
            crate::security::deduplicate_list_lines(raw)
        {
            actions.push(QuickAction {
                id: "dedup-list-lines",
                title: format!("去重净列(剩{remain_cnt}行)"),
                is_security: false,
                result_text: dedup_txt,
                html_table_payload: None,
                toast_text: format!("已按原序剔除 {removed_cnt} 行重复项，保留 {remain_cnt} 行"),
            });
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
                if let Some((twin_masked, twin_cnt)) = crate::security::mask_with_privacy_twins(raw)
                {
                    actions.push(QuickAction {
                        id: "redact-reversible-twin",
                        title: "AI 替身脱敏".to_string(),
                        is_security: true,
                        result_text: twin_masked,
                        html_table_payload: None,
                        toast_text: format!(
                            "已生成 {twin_cnt} 处可逆替身（复制 AI 回复可一键还原真值）"
                        ),
                    });
                }
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

        // Dev 4.5: 编程标识符命名风格互转（camelCase / snake_case / UPPER_CASE）
        if actions.len() < 3
            && (4..=80).contains(&trimmed.len())
            && !trimmed.contains([' ', '\n', '/', '.'])
        {
            for (act_id, act_title, act_res, act_toast) in
                crate::intelligence::analyze_card_identifier_case_actions(trimmed)
            {
                if actions.len() >= 3 {
                    break;
                }
                actions.push(QuickAction {
                    id: act_id,
                    title: act_title,
                    is_security: false,
                    result_text: act_res,
                    html_table_payload: None,
                    toast_text: act_toast,
                });
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

    // 最小够用结构化净提与收件名片一键拆入连填队列（双角色共享）
    if actions.len() < 3 && raw.len() <= 16_384 && !is_otp_message(raw) {
        if let Some(shipping) = crate::intelligence::parse_shipping_contact(raw) {
            actions.insert(
                0,
                QuickAction {
                    id: "contact-clean-card",
                    title: "净提收件卡".to_string(),
                    is_security: false,
                    result_text: shipping.clean_card_text(),
                    html_table_payload: None,
                    toast_text: "已剥离闲聊噪音提纯标准收件信息".to_string(),
                },
            );
            actions.insert(
                0,
                QuickAction {
                    id: "contact-split-queue",
                    title: "拆入连填(名→号→址)".to_string(),
                    is_security: false,
                    result_text: shipping.clean_card_text(),
                    html_table_payload: None,
                    toast_text: "已拆入顺序队列（连按 Ctrl+Alt+V 依次填入姓名/手机/地址）"
                        .to_string(),
                },
            );
        } else {
            if let Some(clean_phone) = crate::intelligence::extract_normalized_single_phone(raw) {
                actions.push(QuickAction {
                    id: "extract-clean-phone",
                    title: format!("纯手机号 {clean_phone}"),
                    is_security: false,
                    result_text: clean_phone.clone(),
                    html_table_payload: None,
                    toast_text: format!("已提取 11 位纯数字手机号 {clean_phone}"),
                });
            }
            let emails = crate::intelligence::extract_unique_emails(raw);
            if emails.len() >= 2 {
                actions.push(QuickAction {
                    id: "extract-unique-emails",
                    title: format!("提取 {} 个邮箱", emails.len()),
                    is_security: false,
                    result_text: emails.join("\n"),
                    html_table_payload: None,
                    toast_text: format!("已去重净提 {} 个邮箱地址", emails.len()),
                });
            }
            let ips = crate::intelligence::extract_unique_ipv4s(raw);
            if ips.len() >= 2 {
                actions.push(QuickAction {
                    id: "extract-unique-ips",
                    title: format!("提取 {} 个 IP", ips.len()),
                    is_security: false,
                    result_text: ips.join("\n"),
                    html_table_payload: None,
                    toast_text: format!("已去重净提 {} 个 IPv4 地址", ips.len()),
                });
            }
            let urls = crate::intelligence::extract_unique_clean_urls(raw);
            if urls.len() >= 2 {
                let joined_urls = urls.join("\n");
                let has_signed = crate::security::classify_sensitive_text(&joined_urls).is_some();
                actions.push(QuickAction {
                    id: "extract-clean-urls",
                    title: format!("提取 {} 条净链", urls.len()),
                    is_security: has_signed,
                    result_text: joined_urls,
                    html_table_payload: None,
                    toast_text: format!("已去重提取并净化 {} 条链接", urls.len()),
                });
            }
        }
    }

    if !trimmed.contains('\n') && trimmed.len() <= 64 {
        for (act_id, act_title, act_res, act_toast) in
            crate::intelligence::analyze_card_color_actions(trimmed)
        {
            if actions.len() >= 3 {
                break;
            }
            actions.push(QuickAction {
                id: act_id,
                title: act_title,
                is_security: false,
                result_text: act_res,
                html_table_payload: None,
                toast_text: act_toast,
            });
        }
    }

    if actions.len() < 3 && raw.len() <= 32_768 {
        let has_sec = crate::security::classify_sensitive_text(raw).is_some();
        for (act_id, act_title, act_res, act_toast) in crate::security::analyze_query_json_bridge(raw)
            .into_iter()
            .chain(crate::security::analyze_kv_block_to_json(raw))
        {
            if actions.len() >= 3 {
                break;
            }
            actions.push(QuickAction {
                id: act_id,
                title: act_title,
                is_security: has_sec,
                result_text: act_res,
                html_table_payload: None,
                toast_text: act_toast,
            });
        }
    }

    if actions.len() < 3 && raw.len() <= 65_536 {
        let include_sql = cfg!(feature = "dev");
        let list_acts = crate::security::analyze_list_batch_conversion(raw, include_sql);
        if !list_acts.is_empty() {
            let has_sec = crate::security::classify_sensitive_text(raw).is_some()
                || redact_pii_and_private_ip(raw) != raw;
            for (act_id, act_title, act_res, act_toast) in list_acts {
                if actions.len() >= 3 {
                    break;
                }
                actions.push(QuickAction {
                    id: act_id,
                    title: act_title,
                    is_security: has_sec,
                    result_text: act_res,
                    html_table_payload: None,
                    toast_text: act_toast,
                });
            }
        }
    }

    #[cfg(feature = "dev")]
    if actions.is_empty() {
        // Dev 5: Base64 解码（含 URL-Safe 兼容与内联防 Bidi/终端投毒护盾）
        if (12..=4096).contains(&trimmed.len())
            && !trimmed.contains(' ')
            && !trimmed.contains('\n')
            && trimmed.bytes().all(|b| {
                b.is_ascii_alphanumeric()
                    || b == b'+'
                    || b == b'/'
                    || b == b'-'
                    || b == b'_'
                    || b == b'='
            })
        {
            let mut b64_norm = trimmed.replace('-', "+").replace('_', "/");
            let rem = b64_norm.len() % 4;
            if rem > 0 {
                b64_norm.push_str(&"=".repeat(4 - rem));
            }
            if let Ok(bytes) = BASE64.decode(&b64_norm) {
                if let Ok(raw_decoded) = String::from_utf8(bytes) {
                    let had_poison =
                        crate::security::inspect_clipboard_poison(&raw_decoded).is_some();
                    let safe_decoded = if had_poison {
                        crate::security::sanitize_clipboard_poison(&raw_decoded)
                    } else {
                        raw_decoded
                    };
                    let clean = safe_decoded.trim();
                    if clean.chars().count() >= 3
                        && !clean
                            .chars()
                            .any(|c| c.is_control() && c != '\n' && c != '\r' && c != '\t')
                    {
                        actions.push(QuickAction {
                            id: "base64-decode",
                            title: if had_poison {
                                "Base64 安全解码".to_string()
                            } else {
                                "Base64 解码".to_string()
                            },
                            is_security: had_poison,
                            result_text: safe_decoded,
                            html_table_payload: None,
                            toast_text: if had_poison {
                                "已解码 Base64 并剥除暗藏毒字符".to_string()
                            } else {
                                "已解码 Base64 文本".to_string()
                            },
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
        use std::sync::OnceLock;
        static FIN_SINGLE_RE: OnceLock<Regex> = OnceLock::new();
        static FIN_COMMA_RE: OnceLock<Regex> = OnceLock::new();
        let re = FIN_SINGLE_RE.get_or_init(|| {
            Regex::new(
                r"^\s*([¥￥$€£]?)\s*([0-9][0-9,]*)(?:\.([0-9]{1,2}))?\s*(元|圆|RMB|CNY)?\s*$",
            )
            .unwrap()
        });
        if let Some(caps) = re.captures(trimmed) {
            let prefix = caps.get(1).map(|m| m.as_str()).unwrap_or("");
            let raw_int = caps.get(2).map(|m| m.as_str()).unwrap_or("");
            let frac = caps.get(3).map(|m| m.as_str());
            let suffix = caps.get(4).map(|m| m.as_str()).unwrap_or("");

            if raw_int.contains(',') {
                let comma_ok = FIN_COMMA_RE
                    .get_or_init(|| Regex::new(r"^\d{1,3}(?:,\d{3})+$").unwrap())
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

    static FIN_TAIL_RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let tail_re = FIN_TAIL_RE.get_or_init(|| {
        Regex::new(r"(?:[¥￥$]\s*)?(-?\d{1,3}(?:,\d{3})+|-?\d+)(?:\.(\d{1,2}))?\s*(?:元|圆|块)?\s*$")
            .unwrap()
    });
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
    static PDF_BULLET_RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let bullet_re = PDF_BULLET_RE.get_or_init(|| {
        Regex::new(r"^\s*(?:[-*•·]|\d+[.)、]|[（(][一二三四五六七八九十\d]+[)）]|[一二三四五六七八九十]+、)\s*")
            .unwrap()
    });

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
    static PANGU_URL_RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let url_re = PANGU_URL_RE
        .get_or_init(|| Regex::new(r"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+").unwrap());
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

    if looks_like_markdown_document(raw) {
        if let Some(stripped) = strip_markdown_to_clean_text(raw) {
            if stripped != trimmed {
                actions.push(QuickAction {
                    id: "doc-strip-markdown",
                    title: "去 Markdown 纯文本".to_string(),
                    is_security: false,
                    result_text: stripped,
                    html_table_payload: None,
                    toast_text: "已剥除 Markdown 语法符号，转为干净可读纯文本".to_string(),
                });
            }
        }
    }

    if let Some(punct_cleaned) = normalize_width_and_cjk_punctuation(trimmed) {
        let polished = apply_pangu_spacing(&punct_cleaned);
        actions.push(QuickAction {
            id: "doc-normalize-punct",
            title: "全半角与标点精排".to_string(),
            is_security: false,
            result_text: polished,
            html_table_payload: None,
            toast_text: "已规整全角字母数字、中西文标点与中英间距".to_string(),
        });
    }

    let non_empty_lines: Vec<&str> = trimmed
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    if actions.is_empty() && non_empty_lines.len() >= 2 {
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
    if spaced != base && spaced != trimmed {
        let is_pdf_first = actions.first().is_some_and(|a| a.id == "doc-pdf-heal");
        actions.push(QuickAction {
            id: "doc-pangu-space",
            title: if is_pdf_first {
                "缝合+中英美化".to_string()
            } else {
                "中英空格美化".to_string()
            },
            is_security: false,
            result_text: spaced,
            html_table_payload: None,
            toast_text: "已规范化中英文数字间距".to_string(),
        });
    }

    actions
}

pub fn normalize_width_and_cjk_punctuation(raw: &str) -> Option<String> {
    if raw.is_empty() || raw.len() > 32_768 {
        return None;
    }
    let mut fix_count = 0usize;

    const FW_TECH: &[u32] = &[
        0xFF03, 0xFF04, 0xFF05, 0xFF06, 0xFF0B, 0xFF0D, 0xFF0F, 0xFF1D, 0xFF20,
    ];
    let mut stage1 = String::with_capacity(raw.len());
    for ch in raw.chars() {
        let v = ch as u32;
        if ((0xFF10..=0xFF19).contains(&v)
            || (0xFF21..=0xFF3A).contains(&v)
            || (0xFF41..=0xFF5A).contains(&v)
            || FW_TECH.contains(&v))
            && char::from_u32(v - 0xFEE0).is_some()
        {
            stage1.push(char::from_u32(v - 0xFEE0).unwrap());
            fix_count += 1;
        } else if v == 0x3000 {
            stage1.push(' ');
            fix_count += 1;
        } else {
            stage1.push(ch);
        }
    }

    let mut work: Vec<char> = stage1.chars().collect();
    let n = work.len();
    if n == 0 {
        return None;
    }

    let mut in_url = vec![false; n];
    let mut idx = 0usize;
    while idx < n {
        if idx + 7 <= n {
            let s7: String = work[idx..(idx + 7)]
                .iter()
                .collect::<String>()
                .to_ascii_lowercase();
            let s8: String = if idx + 8 <= n {
                work[idx..(idx + 8)]
                    .iter()
                    .collect::<String>()
                    .to_ascii_lowercase()
            } else {
                String::new()
            };
            if s7 == "http://" || s8 == "https://" {
                while idx < n && !work[idx].is_whitespace() {
                    in_url[idx] = true;
                    idx += 1;
                }
                continue;
            }
        }
        idx += 1;
    }

    let is_han =
        |c: Option<char>| -> bool { c.is_some_and(|ch| (0x4E00..=0x9FFF).contains(&(ch as u32))) };

    let mut open_stack: Vec<usize> = Vec::new();
    for i in 0..n {
        if in_url[i] {
            continue;
        }
        if work[i] == '(' {
            open_stack.push(i);
        } else if work[i] == ')' {
            if let Some(open_idx) = open_stack.pop() {
                let is_func = open_idx > 0 && {
                    let pc = work[open_idx - 1];
                    pc.is_ascii_alphanumeric() || pc == '_'
                };
                let inner = &work[(open_idx + 1)..i];
                if !is_func && !inner.contains(&'\n') && inner.iter().any(|&c| is_han(Some(c))) {
                    work[open_idx] = '（';
                    work[i] = '）';
                    fix_count += 1;
                }
            }
        }
    }

    let mut out: Vec<char> = Vec::with_capacity(n);
    let mut i = 0usize;
    while i < n {
        let ch = work[i];
        if in_url[i] {
            out.push(ch);
            i += 1;
            continue;
        }
        let prev_non_space = out.iter().rev().copied().find(|&c| c != ' ' && c != '\t');
        let next_non_space = {
            let mut k = i + 1;
            while k < n && (work[k] == ' ' || work[k] == '\t') {
                k += 1;
            }
            work.get(k).copied()
        };

        let replaced = match ch {
            ',' if is_han(prev_non_space) || is_han(next_non_space) => Some('，'),
            ';' if is_han(prev_non_space) || is_han(next_non_space) => Some('；'),
            '?' if is_han(prev_non_space) || is_han(next_non_space) => Some('？'),
            '!' if (is_han(prev_non_space) || is_han(next_non_space))
                && next_non_space != Some('=') =>
            {
                Some('！')
            }
            ':' if is_han(prev_non_space)
                && next_non_space != Some('/')
                && !next_non_space.is_some_and(|c| c.is_ascii_digit()) =>
            {
                Some('：')
            }
            '.' => {
                let next_imm = work.get(i + 1).copied();
                let is_dec_or_ext = next_imm.is_some_and(|c| c.is_ascii_alphanumeric());
                if is_han(prev_non_space)
                    && !is_dec_or_ext
                    && (next_non_space.is_none()
                        || next_non_space == Some('\n')
                        || is_han(next_non_space))
                {
                    Some('。')
                } else {
                    None
                }
            }
            _ => None,
        };

        if let Some(rep) = replaced {
            if out.last() == Some(&' ') && is_han(prev_non_space) {
                out.pop();
            }
            out.push(rep);
            fix_count += 1;
            if i + 1 < n && work[i + 1] == ' ' {
                i += 2;
                continue;
            }
        } else {
            out.push(ch);
        }
        i += 1;
    }

    let final_str: String = out.into_iter().collect();
    if fix_count >= 2 && final_str != raw {
        Some(final_str)
    } else {
        None
    }
}

pub fn looks_like_markdown_document(raw: &str) -> bool {
    use std::sync::OnceLock;
    let trimmed = raw.trim();
    if trimmed.chars().count() < 6
        || trimmed.starts_with("#!")
        || trimmed.contains("|---")
        || (!trimmed.contains('\n') && !trimmed.contains('\r') && trimmed.len() > 4_096)
    {
        return false;
    }
    let sample = crate::model::safe_utf8_prefix(trimmed, 16_384);
    if crate::security::explain_cron_expression(sample).is_some() {
        return false;
    }
    let lines: Vec<&str> = sample.lines().collect();
    if lines.len() == 2
        && lines[0].starts_with("# ")
        && crate::security::explain_cron_expression(lines[1]).is_some()
    {
        return false;
    }

    static MD_BOLD_RE: OnceLock<Regex> = OnceLock::new();
    static MD_LINK_RE: OnceLock<Regex> = OnceLock::new();
    static MD_STRIKE_RE: OnceLock<Regex> = OnceLock::new();
    static MD_CODE_RE: OnceLock<Regex> = OnceLock::new();
    static MD_HEADING_RE: OnceLock<Regex> = OnceLock::new();
    static MD_LIST_RE: OnceLock<Regex> = OnceLock::new();
    static MD_QUOTE_RE: OnceLock<Regex> = OnceLock::new();

    let bold_re = MD_BOLD_RE.get_or_init(|| {
        Regex::new(r"\*\*[^\s*](?:.*?[^\s*])?\*\*|__[^\s_](?:.*?[^\s_])?__").unwrap()
    });
    let link_re =
        MD_LINK_RE.get_or_init(|| Regex::new(r"\[[^\]]+\]\(https?://[^)\s]+\)").unwrap());
    let strike_re =
        MD_STRIKE_RE.get_or_init(|| Regex::new(r"~~[^\s~](?:.*?[^\s~])?~~").unwrap());
    let code_re = MD_CODE_RE.get_or_init(|| Regex::new(r"`[^`\n]+`").unwrap());
    let heading_re = MD_HEADING_RE.get_or_init(|| Regex::new(r"^\s*(#{1,6})\s+\S").unwrap());
    let list_re = MD_LIST_RE.get_or_init(|| Regex::new(r"^\s*[-*+]\s+\S").unwrap());
    let quote_re = MD_QUOTE_RE.get_or_init(|| Regex::new(r"^\s*>\s*\S").unwrap());

    let mut score = 0usize;
    score += bold_re.find_iter(sample).count() * 2;
    score += link_re.find_iter(sample).count() * 2;
    score += strike_re.find_iter(sample).count() * 2;
    if code_re.is_match(sample) {
        score += 1;
    }

    let mut fence_cnt = 0usize;
    for line in &lines {
        if line.trim_start().starts_with("```") {
            fence_cnt += 1;
            continue;
        }
        if let Some(caps) = heading_re.captures(line) {
            let hashes = caps.get(1).map(|m| m.as_str().len()).unwrap_or(1);
            score += if hashes >= 2 { 2 } else { 1 };
        } else if list_re.is_match(line) || quote_re.is_match(line) {
            score += 1;
        }
    }
    if fence_cnt >= 2 {
        score += 2;
    }
    score >= 2
}

pub fn strip_markdown_to_clean_text(raw: &str) -> Option<String> {
    use std::sync::OnceLock;
    let normalized = raw.replace("\r\n", "\n").replace('\r', "\n");

    static STRIP_HR_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_QUOTE_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_HEADING_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_TASK_UN_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_TASK_OK_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_UL_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_IMG_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_LINK_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_BOLD_STAR_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_BOLD_UNDER_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_STRIKE_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_INLINE_CODE_RE: OnceLock<Regex> = OnceLock::new();
    static STRIP_BLANK_RE: OnceLock<Regex> = OnceLock::new();

    let hr_re = STRIP_HR_RE.get_or_init(|| {
        Regex::new(r"^\s*(?:-\s*-\s*-[-\s]*|_\s*_\s*_[_\s]*|\*\s*\*\s*\*[\*\s]*)$").unwrap()
    });
    let quote_re = STRIP_QUOTE_RE.get_or_init(|| Regex::new(r"^(\s*)(?:>\s?)+").unwrap());
    let heading_re = STRIP_HEADING_RE.get_or_init(|| Regex::new(r"^(\s*)#{1,6}\s+").unwrap());
    let task_un_re =
        STRIP_TASK_UN_RE.get_or_init(|| Regex::new(r"^(\s*)[-*+]\s+\[\s\]\s+").unwrap());
    let task_ok_re =
        STRIP_TASK_OK_RE.get_or_init(|| Regex::new(r"^(\s*)[-*+]\s+\[[xX]\]\s+").unwrap());
    let ul_re = STRIP_UL_RE.get_or_init(|| Regex::new(r"^(\s*)[-*+]\s+").unwrap());
    let img_re = STRIP_IMG_RE.get_or_init(|| Regex::new(r"!\s*\[([^\]]*)\]\(([^)\n]+)\)").unwrap());
    let link_re =
        STRIP_LINK_RE.get_or_init(|| Regex::new(r"\[([^\]]+)\]\((https?://[^)\s]+)\)").unwrap());
    let bold_star_re =
        STRIP_BOLD_STAR_RE.get_or_init(|| Regex::new(r"\*\*([^\s*](?:.*?[^\s*])?)\*\*").unwrap());
    let bold_under_re =
        STRIP_BOLD_UNDER_RE.get_or_init(|| Regex::new(r"__([^\s_](?:.*?[^\s_])?)__").unwrap());
    let strike_re =
        STRIP_STRIKE_RE.get_or_init(|| Regex::new(r"~~([^\s~](?:.*?[^\s~])?)~~").unwrap());
    let inline_code_re =
        STRIP_INLINE_CODE_RE.get_or_init(|| Regex::new(r"`([^`\n]+)`").unwrap());
    let blank_re = STRIP_BLANK_RE.get_or_init(|| Regex::new(r"\n{3,}").unwrap());

    let mut out_lines = Vec::new();
    let mut in_fence = false;

    for raw_line in normalized.lines() {
        if raw_line.trim_start().starts_with("```") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence {
            out_lines.push(raw_line.to_string());
            continue;
        }
        if hr_re.is_match(raw_line) {
            out_lines.push(String::new());
            continue;
        }
        let mut line = quote_re.replace(raw_line, "$1").into_owned();
        line = heading_re.replace(&line, "$1").into_owned();
        if task_un_re.is_match(&line) {
            line = task_un_re.replace(&line, "${1}☐ ").into_owned();
        } else if task_ok_re.is_match(&line) {
            line = task_ok_re.replace(&line, "${1}☑ ").into_owned();
        } else {
            line = ul_re.replace(&line, "${1}• ").into_owned();
        }
        line = img_re
            .replace_all(&line, |caps: &regex_lite::Captures| {
                let alt = caps.get(1).map(|m| m.as_str().trim()).unwrap_or("");
                if alt.is_empty() {
                    String::new()
                } else {
                    format!("[图片: {alt}]")
                }
            })
            .into_owned();
        line = link_re
            .replace_all(&line, |caps: &regex_lite::Captures| {
                let label = caps.get(1).map(|m| m.as_str().trim()).unwrap_or("");
                let url = caps.get(2).map(|m| m.as_str()).unwrap_or("");
                if label.is_empty() || label == url {
                    url.to_string()
                } else {
                    format!("{label} ({url})")
                }
            })
            .into_owned();
        line = bold_star_re.replace_all(&line, "$1").into_owned();
        line = bold_under_re.replace_all(&line, "$1").into_owned();
        line = strike_re.replace_all(&line, "$1").into_owned();
        line = inline_code_re.replace_all(&line, "$1").into_owned();
        out_lines.push(line);
    }

    let joined = out_lines.join("\n");
    let collapsed = blank_re.replace_all(&joined, "\n\n");
    let cleaned = collapsed.trim().to_string();
    if cleaned.is_empty() {
        None
    } else {
        Some(cleaned)
    }
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
            let safe_cell = crate::security::sanitize_spreadsheet_cell(cell);
            let bidi_clean: String = safe_cell
                .chars()
                .filter(|&c| {
                    let v = c as u32;
                    !((0x202A..=0x202E).contains(&v)
                        || (0x2066..=0x2069).contains(&v)
                        || v == 0x061C)
                })
                .collect();
            let escaped = bidi_clean
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;")
                .replace('"', "&quot;")
                .replace('\'', "&#39;");
            html.push_str(&format!("<{tag}>{escaped}</{tag}>"));
        }
        html.push_str("</tr>");
    }
    html.push_str("</table>");
    Some(html)
}

pub fn analyze_table_bridge(raw: &str) -> Vec<QuickAction> {
    if !raw.contains('\n')
        || raw.len() > 65_536
        || (!raw.contains('|')
            && !raw.contains('\t')
            && !raw.contains('│')
            && !raw.contains('┃')
            && !raw.contains('║'))
    {
        return Vec::new();
    }

    // 1. Markdown 表格或终端数据库框线表（MySQL / psql / DuckDB / ClickHouse） -> Excel (TSV + CF_HTML) / JSON / CSV
    if let Some(grid) = parse_markdown_table(raw).or_else(|| parse_database_box_table(raw)) {
        let tsv: String = grid
            .iter()
            .map(|r| {
                r.iter()
                    .map(|c| {
                        let flat = c.replace(['\t', '\n'], " ");
                        crate::security::sanitize_spreadsheet_cell(&flat)
                    })
                    .collect::<Vec<_>>()
                    .join("\t")
            })
            .collect::<Vec<_>>()
            .join("\n");
        let csv: String = grid
            .iter()
            .map(|r| {
                r.iter()
                    .map(|raw_cell| {
                        let cell = crate::security::sanitize_spreadsheet_cell(raw_cell);
                        if cell.contains(',') || cell.contains('"') || cell.contains('\n') {
                            format!("\"{}\"", cell.replace('"', "\"\""))
                        } else {
                            cell
                        }
                    })
                    .collect::<Vec<_>>()
                    .join(",")
            })
            .collect::<Vec<_>>()
            .join("\n");
        let cf_html = to_html_table_fragment(&tsv).map(|frag| build_windows_cf_html_payload(&frag));
        let has_secret = crate::security::classify_sensitive_text(raw).is_some();

        let mut out = vec![QuickAction {
            id: "tbl-md-to-excel",
            title: "转 Excel 分列直粘".to_string(),
            is_security: has_secret,
            result_text: tsv,
            html_table_payload: cf_html,
            toast_text: format!("已转为 Excel 双协议分列格式（{} 行）", grid.len()),
        }];
        if grid.len() >= 2 {
            let headers = &grid[0];
            let mut objs = Vec::with_capacity(grid.len() - 1);
            for row in grid.iter().skip(1) {
                let mut map = serde_json::Map::new();
                for (c, key) in headers.iter().enumerate() {
                    let val = row.get(c).cloned().unwrap_or_default();
                    map.insert(key.clone(), Value::String(val));
                }
                objs.push(Value::Object(map));
            }
            if let Ok(json_str) = serde_json::to_string_pretty(&objs) {
                out.push(QuickAction {
                    id: "tbl-tsv-to-json",
                    title: "转 JSON 数组".to_string(),
                    is_security: has_secret,
                    result_text: json_str,
                    html_table_payload: None,
                    toast_text: "已按表头转为 JSON 对象数组".to_string(),
                });
            }
        }
        out.push(QuickAction {
            id: "tbl-md-to-csv",
            title: "转 CSV".to_string(),
            is_security: has_secret,
            result_text: csv,
            html_table_payload: None,
            toast_text: "已转为标准 CSV 表格".to_string(),
        });
        return out;
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
    let raw_lines: Vec<&str> = raw.lines().collect();
    if raw_lines.len() < 3 {
        return None;
    }
    static MD_TBL_SEP_RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let sep_re = MD_TBL_SEP_RE
        .get_or_init(|| Regex::new(r"^\s*\|?(?:\s*:?-{2,}:?\s*\|)+\s*:?-{2,}:?\s*\|?\s*$").unwrap());

    // 在混排文本（如带前置引导与结尾总结的 AI 回复）中自动寻址首个合法的 Markdown 表格连续区块（跳过代码围栏）
    let mut table_lines: Vec<&str> = Vec::new();
    let mut in_fence = false;
    let mut idx = 0usize;
    while idx < raw_lines.len() {
        let trimmed = raw_lines[idx].trim();
        if trimmed.starts_with("```") {
            in_fence = !in_fence;
            idx += 1;
            continue;
        }
        if !in_fence && trimmed.contains('|') && idx + 1 < raw_lines.len() {
            let next_trimmed = raw_lines[idx + 1].trim();
            if sep_re.is_match(next_trimmed) {
                table_lines.push(trimmed);
                let mut cur = idx + 2;
                while cur < raw_lines.len() {
                    let row_t = raw_lines[cur].trim();
                    if row_t.is_empty() || !row_t.contains('|') || row_t.starts_with("```") {
                        break;
                    }
                    if !sep_re.is_match(row_t) {
                        table_lines.push(row_t);
                    }
                    cur += 1;
                }
                if table_lines.len() >= 2 {
                    break;
                }
                table_lines.clear();
            }
        }
        idx += 1;
    }

    if table_lines.len() < 2 {
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

    let expected_cols = split_row(table_lines[0]).len();
    if expected_cols < 2 {
        return None;
    }
    let mut grid = Vec::with_capacity(table_lines.len());
    for line in table_lines {
        let mut row = split_row(line);
        if row.is_empty() {
            continue;
        }
        if row.len() > expected_cols {
            row.truncate(expected_cols);
        } else if row.len() < expected_cols {
            row.resize(expected_cols, String::new());
        }
        grid.push(row);
    }
    if grid.len() >= 2 {
        Some(grid)
    } else {
        None
    }
}

fn parse_database_box_table(raw: &str) -> Option<Vec<Vec<String>>> {
    use std::sync::OnceLock;
    let lines: Vec<&str> = raw.lines().collect();
    if lines.len() < 3 {
        return None;
    }
    static DB_BORDER_RE: OnceLock<Regex> = OnceLock::new();
    static PSQL_FOOTER_RE: OnceLock<Regex> = OnceLock::new();
    let border_re = DB_BORDER_RE.get_or_init(|| {
        Regex::new(
            r"^\s*(?:\+[-=+]+\+|┌[─┬]+┐|├[─┼]+┤|└[─┴]+┘|╔[═╦]+╗|╠[═╬]+╣|╚[═╩]+╝|(?:[-─═]{2,}\s*[+┼╬]\s*)+[-─═]{2,})\s*$",
        )
        .unwrap()
    });
    let footer_re =
        PSQL_FOOTER_RE.get_or_init(|| Regex::new(r"(?i)^\s*\(\d+\s+rows?\)\s*$").unwrap());

    let mut border_hits = 0usize;
    let mut data_rows: Vec<Vec<String>> = Vec::new();
    let mut expected_cols: Option<usize> = None;

    for raw_line in lines {
        let trimmed = raw_line.trim();
        if trimmed.is_empty() || footer_re.is_match(trimmed) {
            continue;
        }
        if border_re.is_match(trimmed) {
            border_hits += 1;
            continue;
        }
        let sep_opt = if trimmed.contains('│') {
            Some('│')
        } else if trimmed.contains('┃') {
            Some('┃')
        } else if trimmed.contains('║') {
            Some('║')
        } else if trimmed.contains('|') {
            Some('|')
        } else {
            None
        };
        let Some(sep) = sep_opt else {
            if !data_rows.is_empty() && border_hits >= 1 {
                break;
            }
            continue;
        };

        let mut work = trimmed;
        if let Some(s) = work.strip_prefix(sep) {
            work = s;
        }
        if let Some(s) = work.strip_suffix(sep) {
            work = s;
        }
        let cols: Vec<String> = work.split(sep).map(|c| c.trim().to_string()).collect();
        if cols.len() < 2 {
            continue;
        }
        if let Some(exp) = expected_cols {
            if cols.len() != exp {
                continue;
            }
        } else {
            expected_cols = Some(cols.len());
        }
        data_rows.push(cols);
    }

    if border_hits >= 1 && data_rows.len() >= 2 && expected_cols.unwrap_or(0) >= 2 {
        Some(data_rows)
    } else {
        None
    }
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

/// 零像素分配前置校验图像宽高，阻断恶意压缩炸弹（Decompression Bomb / CWE-409）耗尽进程内存
pub fn has_safe_raster_dimensions_in_memory(bytes: &[u8]) -> bool {
    let Ok(reader) = image::ImageReader::new(std::io::Cursor::new(bytes)).with_guessed_format()
    else {
        return false;
    };
    let Ok((w, h)) = reader.into_dimensions() else {
        return false;
    };
    w > 0 && h > 0 && w <= 12_000 && h <= 12_000 && (w as u64) * (h as u64) <= 67_108_864
}

pub fn compress_png_to_white_bg_jpeg(png_bytes: &[u8], quality: u8) -> Option<Vec<u8>> {
    if !has_safe_raster_dimensions_in_memory(png_bytes) {
        return None;
    }
    let img = image::load_from_memory(png_bytes).ok()?.to_rgba8();
    let (w, h) = img.dimensions();
    let mut rgb_buf = Vec::with_capacity((w as usize).saturating_mul(h as usize).saturating_mul(3));

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
    if !has_safe_raster_dimensions_in_memory(png_bytes) {
        return None;
    }
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
    static OTP_WORD_RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let has_kw = OTP_KEYWORDS.iter().any(|&kw| {
        if kw == "otp" {
            OTP_WORD_RE
                .get_or_init(|| Regex::new(r"\botp\b").unwrap())
                .is_match(&lower)
        } else {
            lower.contains(kw)
        }
    });
    if !has_kw {
        return None;
    }

    static OTP_NOISE_RES: std::sync::OnceLock<[Regex; 4]> = std::sync::OnceLock::new();
    let noise_res = OTP_NOISE_RES.get_or_init(|| {
        [
            Regex::new(r"(?i)(?:尾号(?:为|是)?|ending\s+in)\s*[0-9A-Za-z]{3,6}").unwrap(),
            Regex::new(r"(?i)\b\d{1,4}\s*(?:分钟|分|秒钟|秒|小时|min|mins|minute|minutes|sec|secs|second|seconds|hr|hrs|hours)\b").unwrap(),
            Regex::new(r"(?i)(?:[¥￥$€£]\s*\d+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?\s*(?:元|圆|RMB|USD))").unwrap(),
            Regex::new(r"\b(?:\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?|\d{1,2}:\d{2}(?::\d{2})?)\b").unwrap(),
        ]
    });

    let mut sanitized = trimmed.to_string();
    for re in noise_res {
        sanitized = re.replace_all(&sanitized, " ").into_owned();
    }

    // 紧跟关键词后的 4~8 位数字或含数字的混合码
    static OTP_AFTER_RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let after_re = OTP_AFTER_RE.get_or_init(|| {
        Regex::new(
            r##"(?i)(?:验证码|校验码|动态码|安全码|确认码|登录码|授权码|提取码|认证码|(?:verification|security|auth|authentication|login|confirmation|one-time)\s+code|passcode|\botp\b)\s*(?:为|是|is)?\s*[:：]?\s*[\(\[【「『"']?([A-Za-z0-9]{4,8})[\)\]】」』"']?"##,
        )
        .unwrap()
    });

    if let Some(caps) = after_re.captures(&sanitized) {
        let code = caps.get(1).unwrap().as_str();
        if code.bytes().any(|b| b.is_ascii_digit()) {
            return Some(code.to_string());
        }
    }

    // 验证码在前的英文/中文句式
    static OTP_BEFORE_RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let before_re = OTP_BEFORE_RE.get_or_init(|| {
        Regex::new(
            r#"(?i)\b([A-Za-z0-9]{4,8})\b[^\n]{0,28}?(?:验证码|校验码|动态码|安全码|确认码|(?:verification|security|auth|login|confirmation|one-time)\s+code|passcode|\botp\b)"#,
        )
        .unwrap()
    });
    if let Some(caps) = before_re.captures(&sanitized) {
        let code = caps.get(1).unwrap().as_str();
        if code.bytes().any(|b| b.is_ascii_digit()) {
            return Some(code.to_string());
        }
    }

    // 兜底：清洗干扰后的首个独立 4~8 位纯数字
    static OTP_DIGITS_RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let digits_re = OTP_DIGITS_RE.get_or_init(|| Regex::new(r"\b([0-9]{4,8})\b").unwrap());
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

    use std::sync::OnceLock;
    static MEET_LOG_EXCL_RE: OnceLock<Regex> = OnceLock::new();
    let log_excl = MEET_LOG_EXCL_RE.get_or_init(|| {
        Regex::new(
            r"(?:\[(?:INFO|WARN|WARNING|ERROR|DEBUG|TRACE|FATAL)\]|Exception\b|Traceback\b|\bHTTP/\d\.\d\b|\b(?:GET|POST|PUT|DELETE)\s+/|\berrno\b|\bpid=\d+)",
        )
        .unwrap()
    });
    if log_excl.is_match(raw) {
        return None;
    }

    let normalized = raw.replace("\r\n", "\n");
    let lines: Vec<&str> = normalized.split('\n').collect();
    if lines.len() < 2 {
        return None;
    }

    static MEET_SRT_RE: OnceLock<Regex> = OnceLock::new();
    static MEET_STANDALONE_TS_RE: OnceLock<Regex> = OnceLock::new();
    static MEET_HEADER_RE: OnceLock<Regex> = OnceLock::new();
    static MEET_INLINE_RE: OnceLock<Regex> = OnceLock::new();

    let srt_re = MEET_SRT_RE.get_or_init(|| {
        Regex::new(
            r"^\s*\d{1,2}:\d{2}(?::\d{2})?[.,]\d{1,3}\s*-->\s*\d{1,2}:\d{2}(?::\d{2})?[.,]\d{1,3}.*$",
        )
        .unwrap()
    });
    let standalone_ts_re = MEET_STANDALONE_TS_RE
        .get_or_init(|| Regex::new(r"^\s*[\(\[（【]?(\d{1,2}:\d{2}(?::\d{2})?)[\)\]）】]?\s*$").unwrap());
    let header_re = MEET_HEADER_RE.get_or_init(|| {
        Regex::new(r"^\s*([^\d\[\]\n:：]{1,24}?(?:\s*\d{1,2})?)\s*[\(\[（【]?\b(\d{1,2}:\d{2}(?::\d{2})?)\b[\)\]）】]?\s*$").unwrap()
    });
    let inline_re = MEET_INLINE_RE.get_or_init(|| {
        Regex::new(r"^\s*[\(\[（【]?\b(\d{1,2}:\d{2}(?::\d{2})?)\b[\)\]）】]?\s*(?:([^\d\[\]\n:：]{1,20}?)\s*[:：]\s*)?(.+)$").unwrap()
    });

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
    if crate::security::classify_sensitive_text(text).is_some() {
        return true;
    }
    redact_secrets(text) != text
}

pub fn redact_secrets(text: &str) -> String {
    use std::sync::OnceLock;
    let mut out = text.to_string();
    if out.contains("-----BEGIN ")
        && (out.contains("PRIVATE KEY-----") || out.contains("PRIVATE KEY BLOCK-----"))
    {
        static RED_PEM_RE: OnceLock<Regex> = OnceLock::new();
        let pem_re = RED_PEM_RE.get_or_init(|| {
            Regex::new(
                r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----",
            )
            .unwrap()
        });
        out = pem_re
            .replace_all(&out, |caps: &regex_lite::Captures| {
                let s = &caps[0];
                if !s.contains('\n') && s.contains("\\n") {
                    "-----BEGIN PRIVATE KEY-----\\n[REDACTED_BY_iCLIP]\\n-----END PRIVATE KEY-----"
                } else {
                    "-----BEGIN PRIVATE KEY-----\n[REDACTED_BY_iCLIP]\n-----END PRIVATE KEY-----"
                }
            })
            .into_owned();
    }
    if out.contains("PuTTY-User-Key-File-") {
        static RED_PPK_RE: OnceLock<Regex> = OnceLock::new();
        let ppk_re = RED_PPK_RE.get_or_init(|| {
            Regex::new(r"PuTTY-User-Key-File-[23]:[\s\S]*?Private-MAC:\s*[0-9a-fA-F]+").unwrap()
        });
        out = ppk_re
            .replace_all(&out, "PuTTY-User-Key-File-3: [REDACTED_BY_iCLIP]")
            .into_owned();
    }
    if out.contains("client-key-data") {
        static RED_KUBE_RE: OnceLock<Regex> = OnceLock::new();
        let kube_re = RED_KUBE_RE.get_or_init(|| {
            Regex::new(r"(?im)^(\s*client-key-data\s*:\s*)([A-Za-z0-9+/=]{32,})(\s*)$").unwrap()
        });
        out = kube_re
            .replace_all(&out, "${1}***KUBE_KEY_REDACTED***${3}")
            .into_owned();
    }
    if out.to_ascii_lowercase().contains("jdbc:") {
        static RED_JDBC_RE: OnceLock<Regex> = OnceLock::new();
        let jdbc_re = RED_JDBC_RE.get_or_init(|| {
            Regex::new(
                r##"(?i)(jdbc:[a-z0-9+:-]+://[^\s'"]*?(?:[?&;]|user=[^&\s;]+[?&;])password=)([^&\s;'"]{4,})"##,
            )
            .unwrap()
        });
        out = jdbc_re.replace_all(&out, "${1}***REDACTED***").into_owned();
    }
    if out.contains("AGE-SECRET-KEY-1") {
        static RED_AGE_RE: OnceLock<Regex> = OnceLock::new();
        let age_re =
            RED_AGE_RE.get_or_init(|| Regex::new(r"\bAGE-SECRET-KEY-1[A-Z0-9]{50,}\b").unwrap());
        out = age_re
            .replace_all(&out, "AGE-SECRET-KEY-1***REDACTED***")
            .into_owned();
    }
    if out.contains("://") {
        static RED_WEBHOOK_RE: OnceLock<Regex> = OnceLock::new();
        let webhook_re = RED_WEBHOOK_RE.get_or_init(|| {
            Regex::new(
                r"(?i)(https?://(?:open\.(?:feishu\.cn|larksuite\.com)/open-apis/bot/v2/hook/|qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?(?:[^&#\s]+&)*key=|hooks\.slack\.com/services/[A-Z0-9]{8,}/[A-Z0-9]{8,}/|(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d{10,}/))([A-Za-z0-9_\-]{12,})",
            )
            .unwrap()
        });
        out = webhook_re
            .replace_all(&out, "${1}***WEBHOOK_REDACTED***")
            .into_owned();
        if out.to_ascii_lowercase().contains("otpauth") {
            static RED_OTPAUTH_RE: OnceLock<Regex> = OnceLock::new();
            let otp_re = RED_OTPAUTH_RE
                .get_or_init(|| Regex::new(r##"(?i)([?&](?:secret|data)=)([^&\s#'"]+)"##).unwrap());
            out = otp_re
                .replace_all(&out, "${1}***2FA_SECRET_REDACTED***")
                .into_owned();
        }
    }
    if out.to_ascii_uppercase().contains("WIFI:") {
        static RED_WIFI_RE: OnceLock<Regex> = OnceLock::new();
        let wifi_re = RED_WIFI_RE
            .get_or_init(|| Regex::new(r"(?i)(WIFI:(?:[^;\r\n]*;)*?P:)([^;\r\n]{4,})(;)").unwrap());
        out = wifi_re
            .replace_all(&out, "${1}***WIFI_REDACTED***${3}")
            .into_owned();
    }

    let rules: &[(&str, &str, &str)] = &[
        ("sk-", r"sk-[A-Za-z0-9_\-]{18,}", "sk-***REDACTED***"),
        (
            "glsa_",
            r"\bglsa_[A-Za-z0-9_-]{24,}\b",
            "glsa_***REDACTED***",
        ),
        (
            "glc_",
            r"\bglc_[A-Za-z0-9_=+-]{24,}\b",
            "glc_***REDACTED***",
        ),
        ("dapi", r"\bdapi[a-fA-F0-9]{32}\b", "dapi***REDACTED***"),
        ("re_", r"\bre_[A-Za-z0-9_]{20,}\b", "re_***REDACTED***"),
        (
            "_live_",
            r"\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\b",
            "stripe_***REDACTED***",
        ),
        (
            "_test_",
            r"\b(?:sk|rk)_test_[A-Za-z0-9]{16,}\b",
            "stripe_***REDACTED***",
        ),
        (
            "whsec_",
            r"\bwhsec_[A-Za-z0-9]{16,}\b",
            "whsec_***REDACTED***",
        ),
        (
            "tskey-",
            r"\btskey-(?:auth|api|client|webhook)-[A-Za-z0-9_-]{16,}\b",
            "tskey-***REDACTED***",
        ),
        ("vcp_", r"\bvcp_[A-Za-z0-9]{24,}\b", "vcp_***REDACTED***"),
        (
            "cfut_",
            r"\bcfut_[A-Za-z0-9_-]{24,}\b",
            "cfut_***REDACTED***",
        ),
        (
            "gh",
            r"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{30,}",
            "gh_***REDACTED***",
        ),
        ("AKIA", r"AKIA[0-9A-Z]{16}", "AKIA***REDACTED***"),
        ("LTAI", r"\bLTAI[A-Za-z0-9]{12,24}\b", "LTAI***REDACTED***"),
        ("AKID", r"\bAKID[A-Za-z0-9]{13,32}\b", "AKID***REDACTED***"),
        ("AIza", r"AIza[0-9A-Za-z\-_]{35}", "AIza***REDACTED***"),
        (
            ":AA",
            r"\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b",
            "tg_bot:***REDACTED***",
        ),
        ("npm_", r"\bnpm_[A-Za-z0-9]{36}\b", "npm_***REDACTED***"),
        (
            "pypi-",
            r"\bpypi-[A-Za-z0-9_-]{40,}\b",
            "pypi-***REDACTED***",
        ),
        (
            "SG.",
            r"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b",
            "SG.***REDACTED***",
        ),
        ("hf_", r"\bhf_[A-Za-z0-9]{24,}\b", "hf_***REDACTED***"),
        ("gsk_", r"\bgsk_[A-Za-z0-9]{24,}\b", "gsk_***REDACTED***"),
        ("pplx-", r"\bpplx-[A-Za-z0-9]{24,}\b", "pplx-***REDACTED***"),
        ("r8_", r"\br8_[A-Za-z0-9]{24,}\b", "r8_***REDACTED***"),
        ("ntn_", r"\bntn_[A-Za-z0-9]{24,}\b", "ntn_***REDACTED***"),
        (
            "secret_",
            r"\bsecret_[A-Za-z0-9]{32,}\b",
            "secret_***REDACTED***",
        ),
        ("sbp_", r"\bsbp_[a-fA-F0-9]{32,}\b", "sbp_***REDACTED***"),
        (
            "figd_",
            r"\bfigd_[A-Za-z0-9_-]{24,}\b",
            "figd_***REDACTED***",
        ),
        (
            "lin_api_",
            r"\blin_api_[A-Za-z0-9]{24,}\b",
            "lin_api_***REDACTED***",
        ),
        (
            "PMAK-",
            r"\bPMAK-[a-fA-F0-9]{24}-[a-fA-F0-9]{34}\b",
            "PMAK-***REDACTED***",
        ),
        (
            "dop_v1_",
            r"\bdop_v1_[a-fA-F0-9]{64}\b",
            "dop_v1_***REDACTED***",
        ),
        (
            "dckr_pat_",
            r"\bdckr_pat_[A-Za-z0-9_-]{20,}\b",
            "dckr_pat_***REDACTED***",
        ),
        ("hvs.", r"\bhvs\.[A-Za-z0-9_-]{20,}\b", "hvs.***REDACTED***"),
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
            "curl",
            r##"(?i)(\bcurl\b[\s\S]{0,600}?\s(?:-u|--user|-b|--cookie)\s+['"]?)([^'"\s]{6,})(['"]?)"##,
            "${1}***REDACTED***${3}",
        ),
        (
            "://",
            r"([a-zA-Z][a-zA-Z0-9+.\-]*://[^:\s/@]*:)([^@\s/]+)(@)",
            "${1}***REDACTED***${3}",
        ),
        (
            "://",
            r"(?i)\b(https?://)([A-Za-z0-9._~-]{16,})(@[A-Za-z0-9.-]+)",
            "${1}***REDACTED***${3}",
        ),
        (
            "=",
            r"(?i)([?&](?:api_key|apikey|access_token|auth_token|id_token|refresh_token|session_token|jwt|client_secret|secret|password|passwd|x-amz-signature|x-amz-security-token|x-goog-signature|q-signature|ossaccesskeyid|signature)=)([^&\s#*]{8,})",
            "${1}***REDACTED***",
        ),
        (
            "sig=",
            r"(?i)([?&]sig=)([A-Za-z0-9%/+=_-]{24,})",
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
        let wg_re = Regex::new(
            r"(?im)^(\s*(?:PrivateKey|PresharedKey)\s*=\s*)([A-Za-z0-9+/]{42,44}=)(\s*)$",
        )
        .unwrap();
        out = wg_re
            .replace_all(&out, "${1}***WG_KEY_REDACTED***${3}")
            .into_owned();

        let env_re = Regex::new(
            r##"(?im)^(\s*(?:export\s+)?[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|API_KEY|ACCESS_KEY|PRIVATE_KEY|SIGNING_KEY|MASTER_KEY|ENCRYPTION_KEY|ACCOUNT_KEY|(?:AUTH|ACCESS|REFRESH|SESSION|API|WEBHOOK|BOT|DEPLOY|GITLAB|GITHUB|VERCEL|CLOUDFLARE|RAILWAY|FLY|SUPABASE)_TOKEN)[A-Z0-9_]*\s*[:=]\s*['"]?)([^\s'"#]{6,})(['"]?)"##,
        )
        .unwrap();
        out = env_re
            .replace_all(&out, "${1}***REDACTED***${3}")
            .into_owned();

        let az_re = Regex::new(r"(?i)(\bAccountKey\s*=\s*)([A-Za-z0-9+/=]{20,})").unwrap();
        out = az_re.replace_all(&out, "${1}***REDACTED***").into_owned();

        let http_hdr_re = Regex::new(
            r##"(?i)(\b(?:cookie|set-cookie|x-api-key|x-auth-token|x-csrf-token)\s*:\s*)([^\r\n'"]{8,})"##,
        )
        .unwrap();
        out = http_hdr_re
            .replace_all(&out, "${1}***REDACTED***")
            .into_owned();

        let http_basic_re = Regex::new(
            r"(?i)(\b(?:authorization|proxy-authorization)\s*:\s*basic\s+)([A-Za-z0-9+/=]{8,})",
        )
        .unwrap();
        out = http_basic_re
            .replace_all(&out, "${1}***REDACTED***")
            .into_owned();

        let json_sec_re = Regex::new(
            r##"(?i)("(?:password|passwd|secret|client_secret|app_secret|appsecret|bot_token|webhook_secret|signing_secret|api_key|apikey|access_token|refresh_token|id_token|session_token|private_key)"\s*:\s*")([^"\r\n]{6,})(")"##,
        )
        .unwrap();
        out = json_sec_re
            .replace_all(&out, "${1}***REDACTED***${3}")
            .into_owned();
    }

    out = crate::security::mask_verified_identity_and_cards(&out);
    out
}

/// 100% 离线零联网解码 JWT Header + Payload，并计算 exp 有效/过期状态（彻底告别向外部网站粘贴 Token）
pub fn decode_jwt_inspection(input: &str, now_secs: u64) -> Option<(String, Option<bool>)> {
    let mut candidate = input.trim();
    if candidate.as_bytes().len() >= 7 && candidate.as_bytes()[..7].eq_ignore_ascii_case(b"bearer ")
    {
        candidate = candidate[7..].trim();
    }
    if !(24..=8192).contains(&candidate.len())
        || candidate.contains(' ')
        || candidate.contains('\n')
        || candidate.contains('\r')
    {
        return None;
    }
    let mut parts = candidate.split('.');
    let h_b64 = parts.next()?;
    let p_b64 = parts.next()?;
    let _sig = parts.next()?;
    if parts.next().is_some() || !h_b64.starts_with("eyJ") || !p_b64.starts_with("ey") {
        return None;
    }

    let decode_seg = |seg: &str| -> Option<Value> {
        let clean = seg
            .trim_end_matches('=')
            .replace('+', "-")
            .replace('/', "_");
        let bytes = URL_SAFE_NO_PAD.decode(clean).ok()?;
        serde_json::from_slice::<Value>(&bytes).ok()
    };

    let header_val = decode_seg(h_b64)?;
    let payload_val = decode_seg(p_b64)?;
    let header_str = serde_json::to_string_pretty(&header_val).ok()?;
    let payload_str = serde_json::to_string_pretty(&payload_val).ok()?;

    let mut summary_lines = Vec::new();
    let mut unexpired_flag = None;
    if let Some(obj) = payload_val.as_object() {
        let parse_epoch = |v: Option<&Value>| -> Option<u64> {
            let v = v?;
            v.as_u64()
                .or_else(|| v.as_f64().filter(|f| *f > 0.0).map(|f| f as u64))
        };
        if let Some(exp_s) = parse_epoch(obj.get("exp")) {
            let valid = exp_s > now_secs;
            unexpired_flag = Some(valid);
            let iso = crate::model::unix_secs_to_iso8601(exp_s)
                .replace('T', " ")
                .trim_end_matches('Z')
                .to_string();
            let status = if valid { "有效" } else { "已过期" };
            summary_lines.push(format!("// 过期时间 (exp): {iso} UTC（{status}）"));
        }
        if let Some(iat_s) = parse_epoch(obj.get("iat")) {
            let iso = crate::model::unix_secs_to_iso8601(iat_s)
                .replace('T', " ")
                .trim_end_matches('Z')
                .to_string();
            summary_lines.push(format!("// 签发时间 (iat): {iso} UTC"));
        }
    }

    let mut blocks = Vec::new();
    if !summary_lines.is_empty() {
        blocks.push(summary_lines.join("\n"));
    }
    blocks.push(format!("// Header\n{header_str}"));
    blocks.push(format!("// Payload\n{payload_str}"));
    Some((blocks.join("\n\n"), unexpired_flag))
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

/// 外发公域链接安全净享：一键同时剥离 HTTP Basic Auth 账密、URL 鉴权/云预签名令牌参数与营销追踪尾巴，保留干净业务参数
pub fn sanitize_url_for_public_share(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.len() > 4096
        || trimmed.contains('\n')
        || trimmed.contains('\r')
        || trimmed.contains(' ')
        || crate::security::is_webhook_url(trimmed)
    {
        return None;
    }
    let scheme_len = if trimmed
        .as_bytes()
        .get(..8)
        .map(|s| s.eq_ignore_ascii_case(b"https://"))
        .unwrap_or(false)
    {
        8usize
    } else if trimmed
        .as_bytes()
        .get(..7)
        .map(|s| s.eq_ignore_ascii_case(b"http://"))
        .unwrap_or(false)
    {
        7usize
    } else {
        return None;
    };

    let scheme = &trimmed[..scheme_len];
    let rest = &trimmed[scheme_len..];
    let (before_frag, frag) = match rest.split_once('#') {
        Some((b, f)) => (b, Some(f)),
        None => (rest, None),
    };
    let (authority_and_path, query_opt) = match before_frag.split_once('?') {
        Some((ap, q)) => (ap, Some(q)),
        None => (before_frag, None),
    };
    let (authority, path_part) = match authority_and_path.find('/') {
        Some(idx) => (&authority_and_path[..idx], &authority_and_path[idx..]),
        None => (authority_and_path, ""),
    };
    let (has_basic_auth, clean_host) = match authority.rfind('@') {
        Some(at_idx) => {
            let userinfo = &authority[..at_idx];
            let host = &authority[at_idx + 1..];
            (!userinfo.is_empty(), host)
        }
        None => (false, authority),
    };
    if clean_host.is_empty() {
        return None;
    }

    const AUTH_KEYS: &[&str] = &[
        "token",
        "access_token",
        "auth_token",
        "id_token",
        "refresh_token",
        "session_token",
        "jwt",
        "api_key",
        "apikey",
        "secret",
        "client_secret",
        "password",
        "passwd",
        "sig",
        "signature",
        "x-amz-signature",
        "x-amz-credential",
        "x-amz-security-token",
        "x-goog-signature",
        "x-goog-credential",
        "ossaccesskeyid",
        "q-signature",
        "q-ak",
    ];
    const COMPANION_KEYS: &[&str] = &[
        "expires",
        "x-amz-date",
        "x-amz-expires",
        "x-amz-algorithm",
        "x-amz-signedheaders",
        "x-goog-date",
        "x-goog-expires",
        "x-goog-algorithm",
        "x-goog-signedheaders",
        "q-key-time",
        "q-sign-time",
        "q-sign-algorithm",
        "q-header-list",
        "q-url-param-list",
        "sv",
        "se",
        "sp",
        "spr",
        "srt",
        "ss",
    ];
    const TRACKING_KEYS: &[&str] = &[
        "utm_source",
        "utm_medium",
        "utm_campaign",
        "utm_term",
        "utm_content",
        "utm_id",
        "spm",
        "spm_id_from",
        "vd_source",
        "from_spmid",
        "from_source",
        "share_source",
        "share_medium",
        "share_plat",
        "share_from",
        "share_tag",
        "share_session_id",
        "unique_k",
        "xhsshare",
        "xsec_source",
        "apptime",
        "appuid",
        "author_share",
        "tt_from",
        "u_code",
        "iid",
        "from_copylink",
        "fbclid",
        "gclid",
        "dclid",
        "msclkid",
        "twclid",
        "igshid",
        "igsh",
        "mc_cid",
        "mc_eid",
        "_hsenc",
        "_hsmi",
        "mkt_tok",
        "yclid",
        "wickedid",
        "si",
    ];

    let mut has_auth_query = false;
    let mut kept_pairs: Vec<&str> = Vec::new();
    if let Some(q) = query_opt {
        for pair in q.split('&') {
            if pair.is_empty() {
                continue;
            }
            let (raw_k, raw_v) = match pair.split_once('=') {
                Some((k, v)) => (k, v),
                None => (pair, ""),
            };
            let key = raw_k.to_ascii_lowercase();
            if AUTH_KEYS.contains(&key.as_str()) && !raw_v.trim().is_empty() {
                has_auth_query = true;
                continue;
            }
            if AUTH_KEYS.contains(&key.as_str())
                || COMPANION_KEYS.contains(&key.as_str())
                || TRACKING_KEYS.contains(&key.as_str())
                || key.starts_with("utm_")
            {
                continue;
            }
            kept_pairs.push(pair);
        }
    }

    if !has_basic_auth && !has_auth_query {
        return None;
    }

    let mut out = format!("{scheme}{clean_host}{path_part}");
    if !kept_pairs.is_empty() {
        out.push('?');
        out.push_str(&kept_pairs.join("&"));
    }
    if let Some(f) = frag {
        out.push('#');
        out.push_str(f);
    }
    if out == trimmed {
        None
    } else {
        Some(out)
    }
}

pub fn contains_dynamic_template_placeholders(text: &str) -> bool {
    if !text.contains("{{") || !text.contains("}}") {
        return false;
    }
    static TPL_RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let re = TPL_RE.get_or_init(|| {
        Regex::new(r"(?i)\{\{\s*(clip|clip_redacted|date|time|datetime|weekday|ts|uuid)\s*\}\}")
            .unwrap()
    });
    re.is_match(text)
}

#[cfg(target_os = "windows")]
fn resolve_local_datetime_parts(_now_secs: u64) -> (String, String, &'static str) {
    #[repr(C)]
    #[derive(Default)]
    struct WinSystemTime {
        w_year: u16,
        w_month: u16,
        w_day_of_week: u16,
        w_day: u16,
        w_hour: u16,
        w_minute: u16,
        w_second: u16,
        w_milliseconds: u16,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetLocalTime(lp: *mut WinSystemTime);
    }
    const WEEKDAYS: [&str; 7] = [
        "星期日",
        "星期一",
        "星期二",
        "星期三",
        "星期四",
        "星期五",
        "星期六",
    ];
    let mut st = WinSystemTime::default();
    unsafe {
        GetLocalTime(&mut st as *mut WinSystemTime);
    }
    let date_only = format!("{:04}-{:02}-{:02}", st.w_year, st.w_month, st.w_day);
    let time_only = format!("{:02}:{:02}:{:02}", st.w_hour, st.w_minute, st.w_second);
    let wd = WEEKDAYS[(st.w_day_of_week as usize) % 7];
    (date_only, time_only, wd)
}

#[cfg(not(target_os = "windows"))]
fn resolve_local_datetime_parts(now_secs: u64) -> (String, String, &'static str) {
    const WEEKDAYS: [&str; 7] = [
        "星期日",
        "星期一",
        "星期二",
        "星期三",
        "星期四",
        "星期五",
        "星期六",
    ];
    let local_secs = now_secs.saturating_add(8 * 3600);
    let iso_local = crate::model::unix_secs_to_iso8601(local_secs);
    let date_only = iso_local[0..10].to_string();
    let time_only = iso_local[11..19].to_string();
    let weekday_idx = (((local_secs / 86_400) + 4) % 7) as usize;
    (date_only, time_only, WEEKDAYS[weekday_idx])
}

pub fn render_dynamic_template(template: &str, latest_context: Option<&str>) -> String {
    const MAX_TEMPLATE_EXPANSIONS: usize = 64;
    const MAX_RENDERED_BYTES: usize = 1_048_576;
    const MAX_REDACTION_INPUT_BYTES: usize = 262_144;

    if template.len() > MAX_RENDERED_BYTES || !contains_dynamic_template_placeholders(template) {
        return template.to_string();
    }
    let ctx = latest_context.unwrap_or("");
    let mut cached_redacted: Option<String> = None;
    let now_secs = crate::model::now_unix_secs();
    let (date_only, time_only, weekday_str) = resolve_local_datetime_parts(now_secs);
    let datetime_pretty = format!("{date_only} {time_only}");
    let ts_str = now_secs.to_string();

    static TPL_REP_RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let re = TPL_REP_RE.get_or_init(|| {
        Regex::new(r"(?i)\{\{\s*(clip|clip_redacted|date|time|datetime|weekday|ts|uuid)\s*\}\}")
            .unwrap()
    });

    let mut out =
        String::with_capacity((template.len() + ctx.len().min(16_384)).min(MAX_RENDERED_BYTES));
    let mut last = 0usize;
    let mut uuid_seq = 0u32;
    let mut expanded_cnt = 0usize;

    for caps in re.captures_iter(template) {
        let Some(full_m) = caps.get(0) else { continue };
        let Some(key_m) = caps.get(1) else { continue };
        out.push_str(&template[last..full_m.start()]);
        last = full_m.end();

        if expanded_cnt >= MAX_TEMPLATE_EXPANSIONS || out.len() >= MAX_RENDERED_BYTES {
            out.push_str(full_m.as_str());
            continue;
        }

        let uuid_buf: String;
        let rep: &str = match key_m.as_str().to_ascii_lowercase().as_str() {
            "clip" => ctx,
            "clip_redacted" => {
                if cached_redacted.is_none() {
                    let bounded = crate::model::safe_utf8_prefix(ctx, MAX_REDACTION_INPUT_BYTES);
                    cached_redacted = Some(redact_pii_and_private_ip(&redact_secrets(bounded)));
                }
                cached_redacted.as_deref().unwrap_or("")
            }
            "date" => &date_only,
            "time" => &time_only,
            "datetime" => &datetime_pretty,
            "weekday" => weekday_str,
            "ts" => &ts_str,
            "uuid" => {
                uuid_seq += 1;
                uuid_buf =
                    crate::model::generate_pseudo_uuid(&format!("tpl-{now_secs}-{uuid_seq}"));
                &uuid_buf
            }
            _ => full_m.as_str(),
        };

        if out.len() + rep.len() > MAX_RENDERED_BYTES {
            let remain = MAX_RENDERED_BYTES.saturating_sub(out.len());
            if remain > 0 {
                out.push_str(crate::model::safe_utf8_prefix(rep, remain));
            }
            expanded_cnt = MAX_TEMPLATE_EXPANSIONS;
        } else {
            out.push_str(rep);
            expanded_cnt += 1;
        }
    }
    out.push_str(&template[last..]);
    out
}

/// 零像素解码快速嗅探本地 JPEG / PNG 照片是否携带 EXIF / GPS / XMP / 文本隐私元数据块
pub fn file_has_privacy_metadata(path: &std::path::Path) -> bool {
    use std::io::{Read, Seek, SeekFrom};

    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();
    if !matches!(ext.as_str(), "jpg" | "jpeg" | "png") {
        return false;
    }
    let Ok(mut file) = std::fs::File::open(path) else {
        return false;
    };
    let mut sig = [0u8; 8];
    if file.read_exact(&mut sig).is_err() {
        return false;
    }

    // 1. JPEG 段标记扫描（SOI 0xFFD8 -> APP1 EXIF/XMP 0xFFE1 / APP13 IPTC 0xFFED / COM 0xFFFE）
    if sig[0] == 0xFF && sig[1] == 0xD8 {
        if file.seek(SeekFrom::Start(2)).is_err() {
            return false;
        }
        for _ in 0..64 {
            let mut hdr = [0u8; 4];
            if file.read_exact(&mut hdr).is_err() || hdr[0] != 0xFF {
                break;
            }
            let mut marker = hdr[1];
            while marker == 0xFF {
                let mut b = [0u8; 1];
                if file.read_exact(&mut b).is_err() {
                    return false;
                }
                marker = b[0];
                // 若跳过了填充 0xFF，需补读长度低字节
                hdr[2] = hdr[3];
                if file.read_exact(&mut hdr[3..4]).is_err() {
                    return false;
                }
            }
            if marker == 0xDA || marker == 0xD9 {
                break;
            }
            let seg_len = u16::from_be_bytes([hdr[2], hdr[3]]) as usize;
            if seg_len < 2 {
                break;
            }
            if matches!(marker, 0xE1 | 0xED | 0xFE) {
                return true;
            }
            if file.seek(SeekFrom::Current((seg_len - 2) as i64)).is_err() {
                break;
            }
        }
        return false;
    }

    // 2. PNG 块头扫描（eXIf / tEXt / iTXt / zTXt）
    if &sig == b"\x89PNG\r\n\x1a\n" {
        for _ in 0..128 {
            let mut chunk_hdr = [0u8; 8];
            if file.read_exact(&mut chunk_hdr).is_err() {
                break;
            }
            let chunk_len =
                u32::from_be_bytes([chunk_hdr[0], chunk_hdr[1], chunk_hdr[2], chunk_hdr[3]]) as i64;
            let chunk_type = &chunk_hdr[4..8];
            if matches!(chunk_type, b"eXIf" | b"tEXt" | b"iTXt" | b"zTXt") {
                return true;
            }
            if chunk_type == b"IEND" || chunk_len < 0 {
                break;
            }
            // 跳过 chunk_data + 4B CRC
            if file.seek(SeekFrom::Current(chunk_len + 4)).is_err() {
                break;
            }
        }
    }

    false
}

/// 纯像素级重绘剥离照片全部 GPS / EXIF / XMP / 文本隐私块，输出纯净 PNG 字节流
pub fn strip_file_metadata_to_clean_png(path: &std::path::Path) -> Option<Vec<u8>> {
    let (pw, ph) = image::image_dimensions(path).ok()?;
    if pw == 0 || ph == 0 || pw > 12_000 || ph > 12_000 || (pw as u64) * (ph as u64) > 67_108_864 {
        return None;
    }
    let dyn_img = image::open(path).ok()?;
    let rgba = dyn_img.to_rgba8();
    let (w, h) = rgba.dimensions();
    let mut clean_png = Vec::new();
    PngEncoder::new(&mut clean_png)
        .write_image(&rgba, w, h, ColorType::Rgba8.into())
        .ok()?;
    Some(clean_png)
}

/// 本地文件模态专属隐私动作（检测到照片携带 EXIF/GPS 时生成一键净图粘贴胶囊）
pub fn analyze_file_actions(paths: &[String], minimal_mode: bool) -> Vec<QuickAction> {
    if minimal_mode || paths.is_empty() {
        return Vec::new();
    }
    let first = &paths[0];
    if file_has_privacy_metadata(std::path::Path::new(first)) {
        vec![QuickAction {
            id: "file-strip-exif",
            title: "抹除定位/EXIF粘贴".to_string(),
            is_security: true,
            result_text: first.clone(),
            html_table_payload: None,
            toast_text: "已抹除照片 GPS 定位与拍摄设备 EXIF 隐私元数据".to_string(),
        }]
    } else {
        Vec::new()
    }
}
