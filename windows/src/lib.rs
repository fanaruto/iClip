pub mod archive;
pub mod canvas_ui;
pub mod engines;
pub mod hotkey;
pub mod intelligence;
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
        let (md_out, md_cnt) = store.format_todos_as_markdown().expect("应导出 Markdown 清单");
        assert_eq!(md_cnt, 1);
        assert_eq!(md_out, "- [ ] 优先复盘 — 第一项待办");

        let _ = std::fs::remove_dir_all(tmp_dir);
    }
}
