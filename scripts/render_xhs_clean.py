#!/usr/bin/env python3
"""
渲染 iClip v2.1 小红书专属无外链/无外部平台/无长串号码纯净版宣发视频与 3:4 封面：
- 彻底去除一切网址（github.com/...、postgres://...）、外部平台名（GitHub / OpenAI / 飞书 / 腾讯会议 / 企业微信 / Cursor）
- 彻底去除一切长串数字/编码（18位税号数字串、11位测试手机号、6位数字串、sk-随机串），杜绝小红书机审误判「疑似外部联系方式」
"""
import os
import subprocess
import sys
import time
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render_promo_video as base  # noqa: E402
from render_promo_video import (  # noqa: E402
    W, H, FPS, TOTAL_FRAMES, SmartDraw, font_cjk, F_H1, F_HERO, F_SUB,
    F_BODY, F_BODY_B, F_MONO, F_CAP, F_HUD, CURSOR_KF, KEY_PULSES,
    build_base_backdrop, build_iclip_panel_sprite, draw_app_window,
    paste_sprite_animated, draw_cursor, ease_out_expo, ease_in_out_cubic, lerp, clamp,
)

MAITIAN_DIR = "/Users/fanaruto/maitian/videos/超级个体/iClip-v21"
SRC_MP4 = os.path.join(MAITIAN_DIR, "成片.mp4")
OUT_XHS_MP4 = os.path.join(MAITIAN_DIR, "成片-xhs.mp4")
OUT_XHS_COVER = os.path.join(MAITIAN_DIR, "封面", "cover-3x4-xhs.png")

SPRITE_S1_MAC_CLEAN = build_iclip_panel_sprite(
    False,
    "搜索剪贴历史或快捷指令...",
    "⌘E 极简",
    [
        {
            "title": "壹拾贰万捌仟伍佰陆拾元伍角整",
            "meta": "开票财务 · 十进制零误差大写转换",
            "hotkey": "⌘1",
            "selected": True,
            "chips": [("复制大写 ⇧↵", "ok"), ("千分位格式化", "norm")],
        },
        {
            "title": "接口调用密钥 = [本地已自动打码]",
            "meta": "敏感凭据识别 · 本地掩码保护",
            "hotkey": "⌘2",
        },
        {
            "title": "高清截图 · 实况文字已离线提取",
            "meta": "支持白底轻量压缩与圆角阴影衬底",
            "hotkey": "⌘3",
        },
    ],
)

SPRITE_S1_WIN_CLEAN = build_iclip_panel_sprite(
    True,
    "搜索剪贴历史... (Alt+V)",
    "Ctrl+E 极简",
    [
        {
            "title": "| 商品名称 | 渠道单价 | 实时库存 |",
            "meta": "双协议直粘电子表格自动分列",
            "hotkey": "Ctrl+1",
            "selected": True,
            "chips": [("直粘表格分列 ⇧↵", "ok"), ("导出表格", "norm")],
        },
        {
            "title": "企业开票信用代码 · 格式校验通过",
            "meta": "离线自动检出字母 O 与数字零手误",
            "hotkey": "Ctrl+2",
        },
        {
            "title": "短信临时登录校验码（自动无痕清理）",
            "meta": "抗干扰提取 · 粘贴 30 秒后自动清空",
            "hotkey": "Ctrl+3",
        },
    ],
)

SPRITE_S2_DEV_CLEAN = build_iclip_panel_sprite(
    False,
    "已筛选含敏感密钥的配置片段",
    "极客开发版",
    [
        {
            "title": "接口访问密钥与内网配置参数",
            "meta": "终端 · 检测到接口密钥 + 数据库口令 + 内网地址",
            "hotkey": "⌘1",
            "selected": True,
            "chips": [("一键脱敏粘贴 ⇧↵", "warn"), ("仅隐藏密钥", "norm")],
        },
        {
            "title": "{\"service\":\"gateway\",\"p99_ms\":8}",
            "meta": "结构化数据 · 一键缩进排版",
            "hotkey": "⌘2",
        },
    ],
)

SPRITE_S3_BILL_CLEAN = build_iclip_panel_sprite(
    False,
    "智能财务核算与开票校验",
    "心流办公版",
    [
        {
            "title": "差旅交通 / 酒店住宿 / 市内打车明细",
            "meta": "已识别多笔报销金额 · 自动跳过已有合计行",
            "hotkey": "⌘1",
            "selected": True,
            "chips": [("追加合计与大写 ⇧↵", "ok"), ("仅贴数字总和", "norm")],
        },
        {
            "title": "企业开票税号（检出字母 O 误输）",
            "meta": "国标离线校验异常提醒",
            "hotkey": "⌘2",
        },
    ],
)

SPRITE_S3_USCC_CLEAN = build_iclip_panel_sprite(
    False,
    "智能财务核算与开票校验",
    "心流办公版",
    [
        {
            "title": "差旅交通 / 酒店住宿 / 市内打车明细",
            "meta": "已识别多笔报销金额",
            "hotkey": "⌘1",
        },
        {
            "title": "企业开票税号（检出字母 O 误输）",
            "meta": "离线检出将数字零误敲为字母 O",
            "hotkey": "⌘2",
            "selected": True,
            "chips": [("一键修正手误字母 O", "warn")],
        },
    ],
)

SPRITE_S6_ADV_CLEAN = build_iclip_panel_sprite(
    False,
    "搜索剪贴历史...",
    "进阶模式",
    [
        {
            "title": "常用公司抬头与开票核算资料",
            "meta": "[已固定] 财务常用 · 支持双端互导",
            "hotkey": "⌘1",
            "selected": True,
            "chips": [("✓ 校验通过", "ok"), ("分节核对", "norm")],
        },
        {
            "title": "标准客户解答话术与发货说明",
            "meta": "[已固定] 常用话术 · Mac / Win 同步",
            "hotkey": "⌘2",
        },
        {
            "title": "代码排查提问模板（自动打码）",
            "meta": "[已固定] 动态脱敏模板",
            "hotkey": "⌘3",
        },
    ],
    minimal_active=False,
)

SPRITE_S6_MIN_CLEAN = build_iclip_panel_sprite(
    False,
    "搜索剪贴历史...",
    "极简纯净开",
    [
        {
            "title": "常用公司抬头与开票核算资料",
            "meta": "[已固定] 备忘笔记",
            "hotkey": "⌘1",
            "selected": True,
        },
        {
            "title": "标准客户解答话术与发货说明",
            "meta": "[已固定] 办公文档",
            "hotkey": "⌘2",
        },
        {
            "title": "代码排查提问模板（自动打码）",
            "meta": "[已固定] 编辑器",
            "hotkey": "⌘3",
        },
    ],
    minimal_active=True,
)

CAPTIONS_CLEAN = [
    (0.0, 3.2, "仅 0.85 MB 纯原生打造 · macOS 液态玻璃 + Windows 11 云母版同步升级"),
    (3.2, 6.5, "内核事件级监听 后台 0.00% CPU · 两兆大文本毫秒级秒搜"),
    (6.5, 10.4, "写代码向 AI 提问前：自动识别配置中的接口密钥、口令与内网地址"),
    (10.4, 14.5, "按下 ⇧↵ 一键本地打码脱敏，安心粘贴排查报错，敏感配置不外泄"),
    (14.5, 19.2, "财务报销核算：复制多行账单零误差自动求和，秒出人民币会计大写"),
    (19.2, 23.0, "开票核对：离线检查税号格式，把数字零敲成字母 O 也能自动纠错"),
    (23.0, 27.6, "运营做表与文献阅读：表格一键直粘 Excel 自动分列 + PDF 断行缝合"),
    (27.6, 31.5, "视觉设计与工单反馈：五兆高清截图一键白底瘦身，秒加圆角阴影底板"),
    (31.5, 36.2, "登记填表：连按 ⌃⌥V / Ctrl+Alt+V 免开面板自动跳格，三秒填完整张表单"),
    (36.2, 40.0, "会议纪要一键剥离时间轴 · 短信临时校验码粘贴 30 秒后自动无痕清理"),
    (40.0, 44.2, "只想安静复制粘贴？按 ⌘E / Ctrl+E 一键切回「极简纯净基础版」"),
    (44.2, 48.1, "收藏夹常用话术支持在 Mac 与 Windows 之间无损同步 · 纯粹丝滑体验"),
]


def render_clean_frame(base_bg: Image.Image, frame_idx: int) -> Image.Image:
    t = frame_idx / FPS
    canvas = base_bg.copy()
    d = SmartDraw(canvas)

    if t < 6.5:
        d.text((56, 114), "告别百兆臃肿，macOS 与 Windows 双端纯原生同步升级", font=F_H1, fill=(247, 249, 254, 255))
        d.text((56, 168), "按下 ⌥V 或 Alt+V，面板在光标旁瞬时滑落 · 开发与办公双模式按需切换", font=F_SUB, fill=(162, 178, 210, 255))

        draw_app_window(canvas, 56, 216, 880, 710, "macOS · 原生液态玻璃外观", "849 KB", False)
        d.text((92, 286), "性能实测：大文本毫秒检索基准", font=F_BODY_B, fill=(110, 231, 183, 255))
        d.text((92, 318), "通过 · 检索耗时低于 2ms · 屏幕休眠 0.00% CPU", font=F_BODY_B, fill=(232, 240, 252, 255))

        draw_app_window(canvas, 984, 216, 880, 710, "Windows 11 · 原生云母毛玻璃外观", "", True)
        d.text((1020, 286), "内核级剪贴板事件中断监听", font=F_BODY_B, fill=(96, 165, 250, 255))
        d.text((1020, 318), "通过 · 零后台轮询占用 · 单文件免安装即开即用", font=F_BODY_B, fill=(232, 240, 252, 255))

        pop_p = (t - 2.08) / 0.42
        paste_sprite_animated(canvas, SPRITE_S1_MAC_CLEAN, 220, 340, pop_p)
        paste_sprite_animated(canvas, SPRITE_S1_WIN_CLEAN, 1148, 340, pop_p)

    elif t < 14.5:
        d.text((56, 114), "代码排查与 AI 提问：敏感密钥自动打码，安心粘贴报错日志", font=F_H1, fill=(247, 249, 254, 255))
        d.text((56, 168), "本地毫秒级识别接口密钥、数据库口令与内网地址，按 ⇧↵ 一键脱敏上屏", font=F_SUB, fill=(162, 178, 210, 255))

        draw_app_window(canvas, 56, 216, 1160, 710, "智能编程助手 · 报错排查输入框", "UTF-8", False)
        d.rounded_rectangle((92, 290, 1180, 620), radius=14, fill=(13, 18, 29, 255))
        d.text((118, 314), "// 请帮我分析这段服务连接超时的配置原因：", font=F_MONO, fill=(148, 163, 184, 255))

        if t < 10.42:
            d.text((118, 358), "等待粘贴环境配置参数...", font=F_BODY, fill=(120, 136, 164, 255))
        else:
            lines = [
                "SERVICE_KEY = \"[已自动打码隐藏密钥]\"",
                "DB_CONFIG   = \"[账号口令与内网地址已脱敏]\"",
                "ENV_OWNER   = \"[内部敏感字段已本地保护]\"",
            ]
            reveal = ease_out_expo((t - 10.42) / 0.55)
            full_txt = "\n".join(lines)
            cut = int(len(full_txt) * reveal)
            for li, ln in enumerate(full_txt[:cut].split("\n")):
                d.text((118, 358 + li * 38), ln, font=F_BODY_B, fill=(110, 231, 183, 255))

            if t > 10.85:
                d.rounded_rectangle((92, 650, 780, 700), radius=25, fill=(16, 82, 64, 220))
                d.text((118, 663), "✓ 真实密钥、口令与内网地址已在本地完成掩码保护", font=F_BODY_B, fill=(110, 231, 183, 255))

        paste_sprite_animated(canvas, SPRITE_S2_DEV_CLEAN, 1270, 290, (t - 8.55) / 0.40)

    elif t < 23.0:
        d.text((56, 114), "财务报销与票据核对：多行账单秒算大写，税号手误自动纠错", font=F_H1, fill=(247, 249, 254, 255))
        d.text((56, 168), "十进制精确运算杜绝浮点误差 · 离线核对票据代码并自动修复字母 O 误输", font=F_SUB, fill=(162, 178, 210, 255))

        draw_app_window(canvas, 56, 216, 1160, 710, "日常差旅报销核算单 & 票据校验", "精确十进制", False)
        d.rounded_rectangle((92, 286, 1180, 560), radius=14, fill=(14, 20, 32, 255))
        for idx, item_txt in enumerate(["1. 高铁差旅费      ¥ 1,280.50", "2. 酒店住宿费      ¥ 680.00", "3. 市内交通费      ¥ 95.55"]):
            d.text((122, 310 + idx * 42), item_txt, font=F_BODY, fill=(226, 234, 248, 255))
        d.line((122, 452, 1140, 452), fill=(46, 58, 82, 255), width=1)
        if t >= 16.82:
            d.text((122, 476), "合计：¥2,056.05（贰仟零伍拾陆元零伍分）", font=font_cjk(23, True), fill=(94, 234, 212, 255))
        else:
            d.text((122, 476), "等待追加精确合计与会计国标大写...", font=F_BODY, fill=(118, 132, 160, 255))

        d.rounded_rectangle((92, 590, 1180, 740), radius=14, fill=(14, 20, 32, 255))
        d.text((122, 614), "购方企业开票代码核验（自动拦截把数字零误敲成字母 O）：", font=font_cjk(15), fill=(154, 168, 196, 255))
        if t >= 20.42:
            d.text((122, 656), "✓ 已自动将误输的字母 O 修正为数字零 · 离线核验通过", font=font_cjk(23, True), fill=(52, 211, 153, 255))
        else:
            d.text((122, 656), "[纠错提醒] 检出代码第 5、7 位误输入了英文字母 O", font=font_cjk(23, True), fill=(251, 191, 36, 255))

        sp = SPRITE_S3_BILL_CLEAN if t < 19.2 else SPRITE_S3_USCC_CLEAN
        paste_sprite_animated(canvas, sp, 1270, 290, 1.0)

    elif t < 31.5:
        d.text((56, 114), "运营做表与视觉设计：表格直粘 Excel 自动分列，截图一键瘦身加壳", font=F_H1, fill=(247, 249, 254, 255))
        d.text((56, 168), "双协议写入彻底告别挤进单格 · 五兆透明截图白底压至三百多 KB 防黑边", font=F_SUB, fill=(162, 178, 210, 255))

        draw_app_window(canvas, 56, 216, 920, 710, "电子表格工作簿 · 双协议自动分列直粘", "Sheet1", True)
        headers = ["A · 方案名称", "B · 内存占用", "C · 检索响应"]
        col_x = [88, 430, 690, 944]
        d.rectangle((col_x[0], 290, col_x[3], 340), fill=(30, 41, 59, 255))
        for ci in range(3):
            d.rectangle((col_x[ci], 290, col_x[ci + 1], 340), outline=(64, 78, 104, 255), width=1)
            d.text((col_x[ci] + 16, 304), headers[ci], font=F_BODY_B, fill=(147, 197, 253, 255))

        if t < 25.4:
            d.rectangle((col_x[0], 340, col_x[3], 410), outline=(64, 78, 104, 255), width=1)
            d.text((104, 364), "普通粘贴痛点：整段竖线表格全部挤在 A1 同一个单元格里！", font=F_BODY, fill=(248, 113, 113, 255))
        else:
            rows = [
                ("极客开发模式", "低开销常驻", "< 2 毫秒"),
                ("心流办公模式", "低开销常驻", "< 2 毫秒"),
                ("极简纯净模式", "零后台扫描", "瞬时响应"),
            ]
            shown = int(clamp((t - 25.4) / 0.20 + 1, 1, 3))
            for ri in range(shown):
                ry = 340 + ri * 58
                d.rectangle((col_x[0], ry, col_x[3], ry + 58), fill=(16, 48, 44, 150))
                for ci in range(3):
                    d.rectangle((col_x[ci], ry, col_x[ci + 1], ry + 58), outline=(64, 88, 104, 255), width=1)
                    d.text((col_x[ci] + 16, ry + 17), rows[ri][ci], font=F_BODY_B if ci == 0 else F_BODY, fill=(241, 245, 249, 255))

        d.rounded_rectangle((88, 560, 944, 650), radius=12, fill=(14, 20, 32, 255))
        d.text((112, 578), "双栏文献 PDF 断行智能愈合：", font=F_BODY_B, fill=(96, 165, 250, 255))
        d.text((112, 610), "跨行断词与多余硬回车自动拼接（保留自然段落与中英间距）", font=F_BODY, fill=(203, 213, 225, 255))

        draw_app_window(canvas, 1012, 216, 852, 710, "文档配图与视觉整理 · 硬件加速图像工坊", "ImageIO", False)
        if t >= 29.2:
            d.rounded_rectangle((1140, 336, 1736, 704), radius=26, fill=(226, 235, 248, 255))
            d.rounded_rectangle((1178, 382, 1698, 666), radius=16, fill=(18, 26, 42, 255))
            d.rounded_rectangle((1174, 374, 1694, 658), radius=16, fill=(29, 40, 58, 255))
            stat_txt = "✓ 已白底瘦身至 380 KB (-92%) + 柔光圆角阴影样机衬底"
            stat_col = (52, 211, 153, 255)
        else:
            d.rounded_rectangle((1174, 374, 1694, 658), radius=12, fill=(29, 40, 58, 255), outline=(72, 86, 112, 255), width=1)
            stat_txt = "原始高清截图：5,240 KB（直接插入文档体积过大）"
            stat_col = (156, 170, 196, 255)

        d.text((1210, 404), "月度效率提升趋势概览", font=F_BODY_B, fill=(248, 250, 255, 255))
        for bi, bh in enumerate([70, 115, 165]):
            bx = 1220 + bi * 145
            bcol = (52, 211, 153, 255) if bi == 2 else (59, 130, 246, 255)
            d.rounded_rectangle((bx, 620 - bh, bx + 96, 620), radius=8, fill=bcol)
        d.text((1140, 742), stat_txt, font=F_BODY_B, fill=stat_col)

    elif t < 40.0:
        d.text((56, 114), "连续填表与隐私守护：⌃⌥V 免开面板连填表单，临时码贴完自动清理", font=F_H1, fill=(247, 249, 254, 255))
        d.text((56, 168), "顺序粘贴队列自动按 Tab 跳格连填多项资料 · 会议记录一键剥离时间轴", font=F_SUB, fill=(162, 178, 210, 255))

        draw_app_window(canvas, 56, 216, 880, 710, "项目信息登记表单 · 顺序出队自动跳格连填", "⌃ ⌥ V", False)
        fields = [
            ("1. 登记项目名称", 33.05, "双端原生效率工具桌面端迭代"),
            ("2. 所属业务部门", 33.80, "桌面基础架构研发组 · 张经理"),
            ("3. 交付验收节点", 34.55, "第四季度里程碑全量单测通过"),
        ]
        for fi, (lbl, trig, val) in enumerate(fields):
            fy = 296 + fi * 124
            d.text((96, fy), lbl, font=font_cjk(15), fill=(154, 168, 196, 255))
            filled = t >= trig
            b_col = (16, 185, 129, 255) if filled else (56, 68, 92, 255)
            d.rounded_rectangle((96, fy + 32, 896, fy + 86), radius=11, fill=(13, 19, 32, 255), outline=b_col, width=2 if filled else 1)
            if filled:
                d.text((118, fy + 47), val, font=F_BODY_B, fill=(244, 248, 255, 255))

        hud_msg = (
            "✓ 队列 3 项已自动按 Tab 跳格全部填完！"
            if t >= 34.55
            else "连按 ⌃⌥V / Ctrl+Alt+V 免开面板逐项填入并自动跳格"
        )
        d.rounded_rectangle((96, 690, 896, 746), radius=12, fill=(16, 74, 58, 210))
        d.text((120, 707), hud_msg, font=F_BODY_B, fill=(110, 231, 183, 255))

        draw_app_window(canvas, 984, 216, 880, 710, "会议逐字稿清洗 & 一次性校验码阅后即焚", "Auto-Clean", False)
        d.rounded_rectangle((1020, 292, 1828, 510), radius=14, fill=(13, 19, 32, 255))
        d.text((1046, 314), "会议录音逐字稿与字幕时间轴剥离：", font=font_cjk(15, True), fill=(147, 197, 253, 255))
        if t < 36.2:
            d.text((1046, 356), "产品负责人 00:01:12  本周先把双端待机内存和检索速度压到极致", font=F_BODY, fill=(136, 150, 178, 255))
            d.text((1046, 396), "产品负责人 00:01:19  同时保留一键切回极简基础版的纯净开关。", font=F_BODY, fill=(136, 150, 178, 255))
        else:
            d.text((1046, 358), "产品负责人：本周先把双端性能压到极致，同时保留极简纯净开关。", font=F_BODY_B, fill=(110, 231, 183, 255))
            d.text((1046, 404), "✓ 已自动剥离时间轴并合并同一发言人连续语句", font=font_cjk(15), fill=(162, 178, 206, 255))

        d.rounded_rectangle((1020, 540, 1828, 760), radius=14, fill=(13, 19, 32, 255))
        d.text((1046, 564), "排除金额干扰 · 精准提取一次性登录校验码：", font=font_cjk(15, True), fill=(251, 191, 36, 255))
        d.text((1046, 600), "自动跳过通知文本中的日期与金额，仅提取核心动态校验码", font=font_cjk(15), fill=(154, 168, 196, 255))
        if t >= 37.8:
            d.text((1046, 658), "✓ 动态校验码已提取上屏", font=font_cjk(26, True), fill=(94, 234, 212, 255))
            rem = max(26, 30 - int((t - 37.8) * 1.5))
            d.rounded_rectangle((1440, 656, 1800, 704), radius=24, fill=(136, 28, 52, 230))
            d.text((1466, 669), f"阅后即焚：{rem}s 后无痕销毁", font=F_BODY_B, fill=(254, 205, 211, 255))
        else:
            d.text((1046, 658), "等待提取动态校验码...", font=font_cjk(24), fill=(100, 116, 139, 255))

    else:
        d.text((84, 220), "想强大时全副武装，", font=F_HERO, fill=(247, 249, 254, 255))
        d.text((84, 294), "想安静时 ⌘E 一键回归极简。", font=F_HERO, fill=(52, 211, 153, 255))
        d.text((84, 396), "开启「极简纯净模式（基础功能版）」，隐藏一切进阶胶囊并停止后台扫描。", font=F_SUB, fill=(176, 190, 218, 255))
        d.text((84, 438), "支持导出自包含收藏包，在 macOS 与 Windows 电脑之间无损互导。", font=F_SUB, fill=(176, 190, 218, 255))

        d.rounded_rectangle((84, 536, 910, 624), radius=18, fill=(37, 99, 235, 255))
        d.text((120, 565), "iClip 2.1 双端纯原生剪贴板  ·  0.85MB 丝滑轻量", font=font_cjk(25, True), fill=(255, 255, 255, 255))
        d.text((84, 656), "macOS 液态玻璃 + Windows 11 云母原生 · 极客开发与心流办公双模式", font=font_cjk(17), fill=(148, 164, 196, 255))

        sp6 = SPRITE_S6_MIN_CLEAN if t >= 41.6 else SPRITE_S6_ADV_CLEAN
        paste_sprite_animated(canvas, sp6, 1220, 210, 1.0)

    cx, cy = 960.0, 540.0
    for i in range(len(CURSOR_KF) - 1):
        t0, x0, y0 = CURSOR_KF[i]
        t1, x1, y1 = CURSOR_KF[i + 1]
        if t0 <= t <= t1:
            p = ease_in_out_cubic((t - t0) / max(0.001, t1 - t0))
            cx = lerp(x0, x1, p)
            cy = lerp(y0, y1, p)
            break

    pulse_dt = None
    pulse_label = None
    for pt, lbl in KEY_PULSES:
        if pt <= t <= pt + 0.85:
            pulse_dt = t - pt
            pulse_label = lbl
            break

    draw_cursor(canvas, cx, cy, pulse_dt)

    if pulse_dt is not None and pulse_label:
        hw = int(d.textlength(pulse_label, font=F_HUD)) + 64
        hx = (W - hw) // 2
        hy = 486
        d.rounded_rectangle((hx, hy, hx + hw, hy + 68), radius=18, fill=(14, 19, 30, 242), outline=(110, 158, 255, 255), width=2)
        d.text((hx + 32, hy + 18), pulse_label, font=F_HUD, fill=(255, 255, 255, 255))

    for cs, ce, cap in CAPTIONS_CLEAN:
        if cs <= t < ce:
            cw = int(d.textlength(cap, font=F_CAP)) + 64
            bx = (W - cw) // 2
            by = H - 86
            d.rounded_rectangle((bx, by, bx + cw, by + 54), radius=27, fill=(13, 17, 27, 240), outline=(66, 80, 108, 255), width=1)
            d.text((bx + 32, by + 13), cap, font=F_CAP, fill=(248, 250, 252, 255))
            break

    return canvas.convert("RGB")


def generate_clean_xhs_cover( out_path: str):
    c3x4 = Image.new("RGBA", (1080, 1440), (11, 14, 21, 255))
    d3 = SmartDraw(c3x4)
    d3.rounded_rectangle((68, 84, 440, 138), radius=27, fill=(37, 99, 235, 255))
    d3.text((98, 97), "0.85 MB · 零待机占用", font=font_cjk(24, True), fill=(255, 255, 255, 255))
    d3.text((68, 176), "macOS + Windows", font=font_cjk(58, True), fill=(248, 250, 255, 255))
    d3.text((68, 262), "双端纯原生剪贴板 iClip 2.1", font=font_cjk(52, True), fill=(94, 234, 212, 255))
    d3.text((68, 352), "密钥脱敏 · 报销大写求和 · 表格直粘分列 · 截图瘦身", font=font_cjk(26), fill=(176, 190, 218, 255))
    c3x4.alpha_composite(SPRITE_S1_MAC_CLEAN, (60, 440))
    c3x4.alpha_composite(SPRITE_S1_WIN_CLEAN, (470, 880))
    c3x4.convert("RGB").save(out_path)


def main():
    t0 = time.time()
    base_bg = build_base_backdrop()
    generate_clean_xhs_cover(OUT_XHS_COVER)
    print("Generated clean XHS cover:", OUT_XHS_COVER)

    cmd = [
        "/opt/homebrew/bin/ffmpeg",
        "-y",
        "-f", "rawvideo",
        "-pix_fmt", "rgb24",
        "-s", f"{W}x{H}",
        "-r", str(FPS),
        "-i", "-",
        "-i", SRC_MP4,
        "-map", "0:v:0",
        "-map", "1:a:0",
        "-c:v", "libx264",
        "-preset", "medium",
        "-crf", "17",
        "-pix_fmt", "yuv420p",
        "-colorspace", "bt709",
        "-color_primaries", "bt709",
        "-color_trc", "bt709",
        "-c:a", "copy",
        "-shortest",
        "-movflags", "+faststart",
        OUT_XHS_MP4,
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdin is not None
    for f in range(TOTAL_FRAMES):
        rgb_img = render_clean_frame(base_bg, f)
        proc.stdin.write(rgb_img.tobytes())
        if f > 0 and f % 600 == 0:
            print(f"Progress: {f}/{TOTAL_FRAMES} ({time.time() - t0:.1f}s)", flush=True)
    proc.stdin.close()
    err = proc.stderr.read() if proc.stderr else b""
    rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"ffmpeg failed ({rc}): {err.decode('utf-8', 'ignore')[-500:]}")
    print(f"CLEAN_XHS_RENDER_DONE in {time.time() - t0:.1f}s -> {OUT_XHS_MP4}")


if __name__ == "__main__":
    main()
