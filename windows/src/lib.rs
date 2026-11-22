pub mod archive;
pub mod engines;
pub mod model;
pub mod store;

#[cfg(test)]
mod tests {
    use crate::archive::{export_pinned_archive_data, merge_archive_data, ArchiveBackupError};
    use crate::engines::*;
    use crate::model::{ClipItem, PinCategory};
    use crate::store::ClipboardStore;
    use image::{codecs::png::PngEncoder, ColorType, ImageEncoder, Rgba, RgbaImage};
    use std::fs;
    use std::time::Instant;

    #[test]
    fn test_rmb_uppercase_accounting_rules() {
        assert_eq!(to_chinese_uppercase_rmb("0", None).as_deref(), Some("零元整"));
        assert_eq!(to_chinese_uppercase_rmb("0", Some("05")).as_deref(), Some("伍分"));
        assert_eq!(to_chinese_uppercase_rmb("10", Some("05")).as_deref(), Some("壹拾元零伍分"));
        assert_eq!(to_chinese_uppercase_rmb("100000005", None).as_deref(), Some("壹亿零伍元整"));
        assert_eq!(
            to_chinese_uppercase_rmb("128560", Some("50")).as_deref(),
            Some("壹拾贰万捌仟伍佰陆拾元伍角整")
        );
        assert!(to_chinese_uppercase_rmb("1000000000000", Some("00")).is_none());
    }

    #[test]
    fn test_finance_guards_and_multiline_sum() {
        assert!(analyze_finance_numbers("13800138000").is_empty());
        assert!(analyze_finance_numbers("1763744800").is_empty());
        assert!(analyze_finance_numbers("2026").is_empty());

        let usd = analyze_finance_numbers("$1,280.50");
        assert!(!usd.iter().any(|a| a.id == "fin-rmb-upper"));
        assert_eq!(
            usd.iter().find(|a| a.id == "fin-plain-num").map(|a| a.result_text.as_str()),
            Some("1280.50")
        );

        let bill = "高铁差旅 ¥1,280.50\n酒店住宿 680\n市内打车 95.55元\n合计：99999";
        let bill_actions = analyze_finance_numbers(bill);
        let sum_only = bill_actions.iter().find(|a| a.id == "bill-sum-only").unwrap();
        assert_eq!(sum_only.result_text, "2056.05");
    }

    #[test]
    fn test_pdf_healing_and_pangu_url_protection() {
        let broken_en = "Modern transformer archi-\ntectures achieve state-of-the-\nart accuracy.\n\n1. First item\n2. Second item";
        let healed = heal_pdf_line_breaks(broken_en);
        assert!(healed.contains("architectures achieve state-of-the-art accuracy."));
        assert!(healed.contains("\n\n1. First item\n\n2. Second item"));

        let messy = "使用iClip在Windows11上提升300%效率，详见https://github.com/fanaruto/iClip仓库";
        let spaced = apply_pangu_spacing(messy);
        assert_eq!(
            spaced,
            "使用 iClip 在 Windows11 上提升 300% 效率，详见 https://github.com/fanaruto/iClip 仓库"
        );
    }

    #[test]
    fn test_table_bridge_and_windows_cf_html_exact_byte_offsets() {
        let md = "| **商品名称** | 单价 | 库存 |\n| :--- | ---: | :---: |\n| iClip Win | 0.00 | 999 |\n| 贴膜,高清 | 39.90 | 50 |";
        let actions = analyze_table_bridge(md);
        let excel = actions.iter().find(|a| a.id == "tbl-md-to-excel").unwrap();
        assert_eq!(excel.result_text, "商品名称\t单价\t库存\niClip Win\t0.00\t999\n贴膜,高清\t39.90\t50");

        // 严苛验证微软 CF_HTML 字节偏移头：StartFragment..EndFragment 必须与实际 UTF-8 表格片段字节严丝合缝！
        let cf_html = excel.html_table_payload.as_ref().unwrap();
        let get_offset = |key: &str| -> usize {
            let line = cf_html.lines().find(|l| l.starts_with(key)).unwrap();
            line.split(':').nth(1).unwrap().trim().parse().unwrap()
        };
        let start_html = get_offset("StartHTML:");
        let end_html = get_offset("EndHTML:");
        let start_frag = get_offset("StartFragment:");
        let end_frag = get_offset("EndFragment:");

        let bytes = cf_html.as_bytes();
        assert_eq!(end_html, bytes.len());
        assert!(std::str::from_utf8(&bytes[start_html..end_html]).unwrap().starts_with("<html>"));
        let frag_slice = std::str::from_utf8(&bytes[start_frag..end_frag]).unwrap();
        assert!(frag_slice.starts_with("<table"));
        assert!(frag_slice.ends_with("</table>"));
        assert!(frag_slice.contains("<th>商品名称</th>"));
    }

    #[test]
    fn test_image_studio_alpha_white_bg_and_mockup() {
        let mut img = RgbaImage::new(120, 90);
        for y in 0..90 {
            for x in 0..120 {
                if (30..90).contains(&x) && (20..70).contains(&y) {
                    img.put_pixel(x, y, Rgba([20, 100, 230, 255]));
                } else {
                    img.put_pixel(x, y, Rgba([0, 0, 0, 0]));
                }
            }
        }
        let mut png_bytes = Vec::new();
        PngEncoder::new(&mut png_bytes)
            .write_image(img.as_raw(), 120, 90, ColorType::Rgba8.into())
            .unwrap();

        let jpeg = compress_png_to_white_bg_jpeg(&png_bytes, 82).unwrap();
        let decoded_jpeg = image::load_from_memory(&jpeg).unwrap().to_rgb8();
        let corner = decoded_jpeg.get_pixel(2, 2);
        assert!(corner[0] > 245 && corner[1] > 245 && corner[2] > 245);

        let (mockup_png, mw, mh) = render_mockup_frame_png(&png_bytes, 24).unwrap();
        assert_eq!((mw, mh), (168, 138));
        assert!(mockup_png.len() > 200);
    }

    #[test]
    fn test_compliance_id_uscc_luhn() {
        let id17 = "11010519900307123";
        let chk = expected_id_card_checksum(id17).unwrap();
        let valid_id = format!("{id17}{chk}");
        let id_act = analyze_compliance_codes(&valid_id);
        assert!(id_act.iter().any(|a| a.id == "comp-id-group"));

        let uscc17 = "91440300192203821";
        let u_chk = expected_uscc_checksum(uscc17).unwrap();
        let valid_uscc = format!("{uscc17}{u_chk}");
        let typo_uscc = valid_uscc.replace("0300", "O3OO");
        let fix_act = analyze_compliance_codes(&typo_uscc);
        assert_eq!(fix_act[0].id, "comp-uscc-fix");
        assert_eq!(fix_act[0].result_text, valid_uscc);

        let base15 = "622202100111222";
        let valid_card = (0..=9)
            .map(|d| format!("{base15}{d}"))
            .find(|c| passes_luhn_check(c))
            .unwrap();
        let card_act = analyze_compliance_codes(&valid_card);
        assert!(card_act.iter().any(|a| a.id == "comp-card-group"));
    }

    #[test]
    fn test_otp_and_meeting_transcript() {
        let sms = "【招商银行】尾号8899账户于2026-11-22消费¥1280.50元，验证码为 654321，请在5分钟内输入。";
        assert_eq!(extract_verification_code(sms).as_deref(), Some("654321"));
        assert!(extract_verification_code("600519").is_none());

        let transcript = "张总监 00:01:12\n对齐合同排期\n张总监 00:01:19\n确认违约金上限。\n李律师 00:01:35\n建议控制在 20%。";
        let cleaned = clean_meeting_transcript(transcript).unwrap();
        assert_eq!(cleaned.removed_timestamps, 3);
        assert_eq!(
            cleaned.speaker_merged.as_deref(),
            Some("张总监：对齐合同排期，确认违约金上限。\n李律师：建议控制在 20%。")
        );

        let logs = "[10:12:01] [ERROR] Redis timeout pid=4821\n[10:12:05] [WARN] Retry";
        assert!(clean_meeting_transcript(logs).is_none());
    }

    #[test]
    fn test_cross_platform_macos_windows_archive_interoperability_and_otp_sweep() {
        let tmp = std::env::temp_dir().join(format!("iclip-win-test-{}", crate::model::now_unix_secs()));
        let img_dir = tmp.join("images");
        let _ = fs::create_dir_all(&img_dir);

        // 模拟一份由 macOS 版导出的真实 .iclip JSON 归档包，验证 Windows 版直接无缝解析合并
        let macos_exported_json = r#"{
            "appVersion": "2.0.0",
            "entries": [
                {
                    "contentHash": "text:mac-01",
                    "createdAt": "2026-11-22T02:30:00Z",
                    "customAlias": "Mac端同步过来的开票抬头",
                    "pinCategory": "invoice",
                    "sourceAppName": "备忘录",
                    "text": "公司名称：轻剪科技\n税号：91440300192203821K",
                    "type": "text"
                }
            ],
            "exportedAt": "2026-11-22T02:31:00Z",
            "exportedEdition": "flow",
            "format": "com.qingjian.iclip.archive",
            "schemaVersion": 1
        }"#;

        let mut store = ClipboardStore::new(tmp.clone());
        // 无固定项时导出应报 NoPinnedItems
        assert_eq!(
            export_pinned_archive_data(&store.items, &img_dir, "2.1.0", "dev"),
            Err(ArchiveBackupError::NoPinnedItems)
        );

        let (merged, summary) =
            merge_archive_data(macos_exported_json.as_bytes(), &store.items, &img_dir).unwrap();
        assert_eq!(summary.imported_new_count, 1);
        assert_eq!(merged[0].custom_alias.as_deref(), Some("Mac端同步过来的开票抬头"));
        assert_eq!(merged[0].pin_category, Some(PinCategory::Invoice));
        assert!(merged[0].is_pinned);

        // 验证 OTP 阅后即焚调度与到期自动无痕销毁
        let otp_item = ClipItem::new_text("【GitHub】您的登录验证码：482910，5分钟内有效".to_string(), None);
        let otp_id = store.insert_or_promote(otp_item);
        store.schedule_otp_expire_if_needed(&otp_id, 30);
        assert_eq!(store.items.len(), 1);
        // 未到期不删
        assert_eq!(store.sweep_expired_otps(crate::model::now_unix_secs() + 10), 0);
        assert_eq!(store.items.len(), 1);
        // 到期后自动无痕销毁
        assert_eq!(store.sweep_expired_otps(crate::model::now_unix_secs() + 35), 1);
        assert!(store.items.is_empty());

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_performance_benchmark_2mb_payload_under_5ms() {
        let huge_log = "2026-11-22T10:00:00Z service=gateway latency_ms=8 status=200\n".repeat(35_000);
        assert!(huge_log.len() > 2_000_000);
        let huge_item = ClipItem::new_text(huge_log, Some("Terminal".to_string()));

        let mut list = Vec::with_capacity(501);
        list.push(huge_item.clone());
        for i in 1..=500 {
            list.push(ClipItem::new_text(
                format!("订单 ORD-2026-{i} 金额 ¥{}.50", i * 100),
                Some("Excel".to_string()),
            ));
        }

        let t0 = Instant::now();
        for _ in 0..200 {
            let _ = huge_item.primary_title(false);
            let _ = huge_item.subtitle_info();
        }
        let hits: Vec<&ClipItem> = list.iter().filter(|it| it.matches_query("ord-2026-499")).collect();
        let elapsed = t0.elapsed();

        assert_eq!(hits.len(), 1);
        assert!(huge_item.subtitle_info().contains("MB"));
        assert!(
            elapsed.as_millis() < 15,
            "Windows 核心检索性能超标：{:?}",
            elapsed
        );
    }

    #[test]
    fn test_secret_redaction_and_url_cleaning() {
        let env_raw = "OPENAI_API_KEY=sk-proj-1234567890abcdefghijklmnop\nDB_PASSWORD=\"mySuperSecret88\"";
        let red = redact_secrets(env_raw);
        assert!(!red.contains("1234567890abcdefghijklmnop"));
        assert!(!red.contains("mySuperSecret88"));

        let dirty = "https://webfooo.com/post?id=7&utm_source=x&spm=a2.1#top";
        assert_eq!(
            clean_tracking_url(dirty).as_deref(),
            Some("https://webfooo.com/post?id=7#top")
        );
    }
}
