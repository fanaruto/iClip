#!/usr/bin/env python3
"""
iClip v2.1 高帧率 (1920x1080 @ 60fps) 跨行业宣发大片确定性渲染引擎
严格遵循 Impeccable 视觉准则：高对比排版、中性柔和阴影、零廉价渐变字、60fps 指数阻尼丝滑交互。
"""
import math
import os
import subprocess
import time
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1920, 1080
FPS = 60
DURATION = 48.0
TOTAL_FRAMES = int(FPS * DURATION)

SCRATCH = "/Users/fanaruto/.gemini/antigravity/brain/80166cf8-d5df-4b0e-a1ad-70b10eeecfc0/scratch/promo-video"
AUDIO_WAV = os.path.join(SCRATCH, "audio.wav")
OUT_MP4 = os.path.join(SCRATCH, "iClip-v2.1-promo.mp4")

CJK_FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"
if not os.path.exists(CJK_FONT_PATH):
    CJK_FONT_PATH = "/System/Library/Fonts/STHeiti Medium.ttc"
SYM_FONT_PATH = "/System/Library/Fonts/SFNS.ttf"
MONO_FONT_PATH = "/System/Library/Fonts/SFNSMono.ttf"
if not os.path.exists(MONO_FONT_PATH):
    MONO_FONT_PATH = "/System/Library/Fonts/Menlo.ttc"

APPLE_SYM_CHARS = set("⌘⌥⌃⇧↵✓←→↑↓□✕─")
_SYM_CACHE: dict[int, ImageFont.FreeTypeFont] = {}


def font_sym(size: int) -> ImageFont.FreeTypeFont:
    if size not in _SYM_CACHE:
        _SYM_CACHE[size] = ImageFont.truetype(SYM_FONT_PATH, size)
    return _SYM_CACHE[size]


def split_runs(text: str):
    if not text:
        return []
    text = text.replace("⚠️", "[纠错]").replace("↵", "Enter")
    runs = []
    cur = [text[0]]
    cur_is_sym = text[0] in APPLE_SYM_CHARS
    for ch in text[1:]:
        is_sym = ch in APPLE_SYM_CHARS
        if is_sym == cur_is_sym:
            cur.append(ch)
        else:
            runs.append((cur_is_sym, "".join(cur)))
            cur = [ch]
            cur_is_sym = is_sym
    runs.append((cur_is_sym, "".join(cur)))
    return runs


class SmartDraw:
    """自动对 ⌘⌥⌃⇧↵✓ 切换苹果官方 SFNS 字体，彻底消除 CJK 字体缺字方框 ☒"""
    def __init__(self, img: Image.Image):
        self._d = ImageDraw.Draw(img)

    def __getattr__(self, name):
        return getattr(self._d, name)

    def textlength(self, text: str, font: ImageFont.FreeTypeFont) -> float:
        size = getattr(font, "size", 18)
        total = 0.0
        for is_sym, seg in split_runs(text):
            f = font_sym(size) if is_sym else font
            total += self._d.textlength(seg, font=f)
        return total

    def text(self, xy, text: str, font: ImageFont.FreeTypeFont, fill):
        x, y = float(xy[0]), float(xy[1])
        size = getattr(font, "size", 18)
        for is_sym, seg in split_runs(text):
            f = font_sym(size) if is_sym else font
            y_off = 1.0 if is_sym else 0.0
            self._d.text((x, y + y_off), seg, font=f, fill=fill)
            x += self._d.textlength(seg, font=f)


def font_cjk(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    idx = 1 if (bold and CJK_FONT_PATH.endswith("Hiragino Sans GB.ttc")) else 0
    try:
        return ImageFont.truetype(CJK_FONT_PATH, size, index=idx)
    except Exception:
        return ImageFont.truetype(CJK_FONT_PATH, size)


def font_mono(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(MONO_FONT_PATH, size)


F_H1 = font_cjk(40, True)
F_HERO = font_cjk(50, True)
F_SUB = font_cjk(20, False)
F_BODY = font_cjk(18, False)
F_BODY_B = font_cjk(18, True)
F_CARD_T = font_cjk(16, True)
F_CARD_M = font_cjk(13, False)
F_CHIP = font_cjk(13, True)
F_CAP = font_cjk(22, True)
F_HUD = font_cjk(26, True)
F_MONO = font_mono(17)
F_MONO_LG = font_mono(23)
F_MONO_SM = font_mono(14)


def clamp(v: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, v))


def ease_out_expo(x: float) -> float:
    t = clamp(x)
    return 1.0 if t >= 1.0 else 1.0 - math.pow(2.0, -10.0 * t)


def ease_in_out_cubic(x: float) -> float:
    t = clamp(x)
    return 4 * t * t * t if t < 0.5 else 1 - math.pow(-2 * t + 2, 3) / 2


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def build_base_backdrop() -> Image.Image:
    """构建带柔和深空环境光与顶部实时性能标尺的底板"""
    bg = Image.new("RGBA", (W, H), (11, 14, 21, 255))
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = SmartDraw(glow)
    gd.ellipse((140, -80, 980, 640), fill=(48, 98, 218, 42))
    gd.ellipse((1020, 420, 1860, 1140), fill=(26, 148, 122, 34))
    glow = glow.filter(ImageFilter.GaussianBlur(110))
    bg = Image.alpha_composite(bg, glow)

    d = SmartDraw(bg)
    # 顶部左侧品牌胶囊
    d.rounded_rectangle((56, 32, 570, 82), radius=25, fill=(22, 27, 40, 230), outline=(58, 68, 92, 255), width=1)
    d.ellipse((76, 51, 88, 63), fill=(78, 140, 255, 255))
    d.text((100, 44), "iClip v2.1", font=F_BODY_B, fill=(246, 248, 253, 255))
    d.text((212, 45), "｜ macOS 液态玻璃 + Windows 11 云母原生", font=font_cjk(15), fill=(162, 178, 208, 255))

    # 顶部右侧真实性能指标胶囊
    d.rounded_rectangle((1120, 32, 1864, 82), radius=25, fill=(20, 25, 37, 235), outline=(64, 82, 116, 255), width=1)
    d.text((1146, 45), "0.85 MB", font=font_cjk(15, True), fill=(94, 234, 212, 255))
    d.text((1222, 45), "纯原生体积   ·", font=font_cjk(15), fill=(198, 210, 232, 255))
    d.text((1346, 45), "0.00% CPU", font=font_cjk(15, True), fill=(94, 234, 212, 255))
    d.text((1442, 45), "零轮询待机   ·", font=font_cjk(15), fill=(198, 210, 232, 255))
    d.text((1566, 45), "117× 提速", font=font_cjk(15, True), fill=(94, 234, 212, 255))
    d.text((1656, 45), "2MB 大文本秒搜", font=font_cjk(15), fill=(198, 210, 232, 255))
    return bg


def make_shadow_box(w: int, h: int, radius: int = 18, pad: int = 36, alpha: int = 120) -> Image.Image:
    im = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    d = SmartDraw(im)
    d.rounded_rectangle((pad, pad + 10, pad + w, pad + h + 10), radius=radius, fill=(0, 0, 0, alpha))
    return im.filter(ImageFilter.GaussianBlur(16))


def build_iclip_panel_sprite(
    is_win11: bool,
    search_hint: str,
    right_badge: str,
    cards: list,
    minimal_active: bool = False,
) -> Image.Image:
    """绘制高保真 iClip 原生悬浮面板图层（支持 macOS 圆润液态玻璃与 Win11 云母亚克力双外观）"""
    pw, ph = 500, 420
    pad = 36
    sprite = make_shadow_box(pw, ph, radius=16 if is_win11 else 22, pad=pad, alpha=145)
    d = SmartDraw(sprite)
    ox, oy = pad, pad

    bg_col = (22, 27, 39, 242) if is_win11 else (28, 34, 50, 236)
    border_col = (72, 92, 132, 255) if is_win11 else (76, 88, 114, 255)
    rad = 15 if is_win11 else 22
    d.rounded_rectangle((ox, oy, ox + pw, oy + ph), radius=rad, fill=bg_col, outline=border_col, width=1)

    # 搜索栏
    d.rounded_rectangle((ox + 16, oy + 16, ox + pw - 16, oy + 58), radius=11, fill=(40, 47, 66, 255))
    d.text((ox + 30, oy + 27), search_hint, font=font_cjk(14), fill=(172, 186, 214, 255))
    badge_bg = (16, 185, 129, 255) if minimal_active else (54, 64, 88, 255)
    badge_fg = (6, 42, 32, 255) if minimal_active else (212, 222, 242, 255)
    bw = int(d.textlength(right_badge, font=F_CHIP)) + 22
    d.rounded_rectangle((ox + pw - 24 - bw, oy + 23, ox + pw - 24, oy + 51), radius=14, fill=badge_bg)
    d.text((ox + pw - 24 - bw + 11, oy + 28), right_badge, font=F_CHIP, fill=badge_fg)

    # 分类胶囊
    tabs = ["全部", "收藏", "文本", "链接", "图片", "文件"]
    tx = ox + 16
    for idx, tb in enumerate(tabs):
        tw = int(d.textlength(tb, font=F_CHIP)) + 24
        t_fill = (59, 118, 246, 255) if idx == 0 else (38, 45, 62, 255)
        t_fg = (255, 255, 255, 255) if idx == 0 else (164, 176, 200, 255)
        d.rounded_rectangle((tx, oy + 70, tx + tw, oy + 98), radius=14, fill=t_fill)
        d.text((tx + 12, oy + 75), tb, font=F_CHIP, fill=t_fg)
        tx += tw + 8

    # 卡片列表
    cy = oy + 112
    for c in cards:
        sel = c.get("selected", False)
        chips = [] if minimal_active else c.get("chips", [])
        ch = 96 if chips else 68
        if cy + ch > oy + ph - 14:
            break
        c_fill = (47, 104, 230, 255) if sel else (38, 44, 62, 255)
        d.rounded_rectangle((ox + 16, cy, ox + pw - 16, cy + ch), radius=13, fill=c_fill)
        d.text((ox + 30, cy + 11), c["title"], font=F_CARD_T, fill=(248, 250, 255, 255))
        d.text(
            (ox + 30, cy + 37),
            c["meta"],
            font=F_CARD_M,
            fill=(220, 232, 255, 255) if sel else (152, 164, 190, 255),
        )
        if c.get("hotkey"):
            hk_w = int(d.textlength(c["hotkey"], font=F_CARD_M))
            d.text((ox + pw - 30 - hk_w, cy + 13), c["hotkey"], font=F_CARD_M, fill=(214, 226, 250, 255))

        if chips:
            cx = ox + 30
            for ch_txt, ch_kind in chips:
                cw = int(d.textlength(ch_txt, font=F_CHIP)) + 22
                if ch_kind == "warn":
                    cf, cfg = (230, 118, 32, 255), (255, 255, 255, 255)
                elif ch_kind == "ok":
                    cf, cfg = (16, 185, 129, 255), (5, 42, 30, 255)
                else:
                    cf, cfg = (28, 66, 162, 255), (240, 246, 255, 255)
                d.rounded_rectangle((cx, cy + 61, cx + cw, cy + 87), radius=13, fill=cf)
                d.text((cx + 11, cy + 65), ch_txt, font=F_CHIP, fill=cfg)
                cx += cw + 8
        cy += ch + 10

    return sprite


def draw_app_window(
    canvas: Image.Image,
    x: int,
    y: int,
    w: int,
    h: int,
    title: str,
    right_tag: str = "",
    is_windows: bool = False,
):
    d = SmartDraw(canvas)
    d.rounded_rectangle((x, y + 8, x + w, y + h + 8), radius=16, fill=(0, 0, 0, 95))
    d.rounded_rectangle((x, y, x + w, y + h), radius=16, fill=(19, 24, 36, 255), outline=(48, 58, 80, 255), width=1)
    d.rounded_rectangle((x + 1, y + 1, x + w - 1, y + 46), radius=15, fill=(26, 33, 49, 255))
    d.rectangle((x + 1, y + 32, x + w - 1, y + 46), fill=(26, 33, 49, 255))
    d.line((x, y + 46, x + w, y + 46), fill=(44, 54, 74, 255), width=1)

    if not is_windows:
        for idx, col in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            cx = x + 18 + idx * 19
            d.ellipse((cx, y + 17, cx + 12, y + 29), fill=col + (255,))
        d.text((x + 84, y + 13), title, font=font_cjk(14, True), fill=(176, 190, 216, 255))
    else:
        d.text((x + 20, y + 13), title, font=font_cjk(14, True), fill=(176, 190, 216, 255))
        # 绘制像素级锐利的原生 Windows 11 最小化 / 最大化 / 关闭几何图标
        ic_col = (152, 166, 192, 255)
        d.line((x + w - 96, y + 23, x + w - 84, y + 23), fill=ic_col, width=2)
        d.rectangle((x + w - 64, y + 17, x + w - 53, y + 28), outline=ic_col, width=1)
        d.line((x + w - 33, y + 17, x + w - 22, y + 28), fill=ic_col, width=2)
        d.line((x + w - 33, y + 28, x + w - 22, y + 17), fill=ic_col, width=2)

    if right_tag and not is_windows:
        tw = int(d.textlength(right_tag, font=F_MONO_SM))
        d.text((x + w - 20 - tw, y + 14), right_tag, font=F_MONO_SM, fill=(134, 150, 180, 255))


# 预构建常用悬浮窗 Sprite（提速 10 倍）
SPRITE_S1_MAC = build_iclip_panel_sprite(
    False,
    "搜索历史或输入 @json / @otp...",
    "⌘E 极简",
    [
        {
            "title": "壹拾贰万捌仟伍佰陆拾元伍角整",
            "meta": "开票财务 · 十进制零误差大写",
            "hotkey": "⌘1",
            "selected": True,
            "chips": [("复制大写 ⇧↵", "ok"), ("千分位 128,560.50", "norm")],
        },
        {
            "title": "OPENAI_API_KEY=sk-***REDACTED***",
            "meta": "含敏感凭据 · 本地掩码守护",
            "hotkey": "⌘2",
        },
        {
            "title": "截图 · 2560×1440 · 实况文本已提取",
            "meta": "支持白底瘦身 JPEG 与圆角样机壳",
            "hotkey": "⌘3",
        },
    ],
)

SPRITE_S1_WIN = build_iclip_panel_sprite(
    True,
    "搜索剪贴历史... (Alt+V)",
    "Ctrl+E 极简",
    [
        {
            "title": "| 商品名称 | 单价 | 库存 | → Excel",
            "meta": "CF_HTML 双协议直粘自动分列",
            "hotkey": "Ctrl+1",
            "selected": True,
            "chips": [("转 Excel 分列直粘 ⇧↵", "ok"), ("转 CSV", "norm")],
        },
        {
            "title": "91440300192203821K",
            "meta": "GB 32100 企业税号校验无误 · 与 Mac 互通",
            "hotkey": "Ctrl+2",
        },
        {
            "title": "【招行】验证码 654321（30s 自动焚毁）",
            "meta": "一次性验证码抗干扰提取",
            "hotkey": "Ctrl+3",
        },
    ],
)

SPRITE_S2_DEV = build_iclip_panel_sprite(
    False,
    "@secret 已筛选敏感密钥与隐私",
    "极客开发版",
    [
        {
            "title": "OPENAI_API_KEY=sk-proj-9f8a7bc21...",
            "meta": "终端 · 检测到 API 密钥 + 数据库密码 + 内网 IP",
            "hotkey": "⌘1",
            "selected": True,
            "chips": [("深度脱敏(含IP/隐私) ⇧↵", "warn"), ("仅掩码密钥", "norm")],
        },
        {
            "title": "{\"service\":\"gateway\",\"p99_ms\":8}",
            "meta": "JSON · 一键美化缩进 / SQL IN 子句",
            "hotkey": "⌘2",
        },
    ],
)

SPRITE_S3_FIN_BILL = build_iclip_panel_sprite(
    False,
    "智能财务与国标合规核验",
    "心流办公版",
    [
        {
            "title": "高铁 ¥1,280.50 / 住宿 680 / 打车 95.55元",
            "meta": "已识别 3 笔报销明细 · 自动跳过已有合计行",
            "hotkey": "⌘1",
            "selected": True,
            "chips": [("追加合计与大写 ⇧↵", "ok"), ("仅贴总和 2056.05", "norm")],
        },
        {
            "title": "9144O3OO192203821K",
            "meta": "企业税号校验异常（含手误字母 O）",
            "hotkey": "⌘2",
        },
    ],
)

SPRITE_S3_FIN_USCC = build_iclip_panel_sprite(
    False,
    "智能财务与国标合规核验",
    "心流办公版",
    [
        {
            "title": "高铁 ¥1,280.50 / 住宿 680 / 打车 95.55元",
            "meta": "已识别 3 笔报销明细",
            "hotkey": "⌘1",
        },
        {
            "title": "9144O3OO192203821K",
            "meta": "GB 32100 MOD-31 检出手误字母 O",
            "hotkey": "⌘2",
            "selected": True,
            "chips": [("修正手误 → 91440300192203821K", "warn")],
        },
    ],
)

SPRITE_S6_ADV = build_iclip_panel_sprite(
    False,
    "搜索剪贴历史...",
    "进阶模式",
    [
        {
            "title": "深圳总部开票资料 · 91440300192203821K",
            "meta": "[已固定] 开票财务 · 支持 .iclip 导出",
            "hotkey": "⌘1",
            "selected": True,
            "chips": [("✓ 税号无误", "ok"), ("分节核对", "norm")],
        },
        {
            "title": "标准售后话术 · 顺丰次日达物流说明",
            "meta": "[已固定] 常用话术 · Mac / Win 互通",
            "hotkey": "⌘2",
        },
        {
            "title": "请帮我审查代码隐患：{{clip_redacted}}",
            "meta": "[已固定] AI 动态脱敏模板",
            "hotkey": "⌘3",
        },
    ],
    minimal_active=False,
)

SPRITE_S6_MIN = build_iclip_panel_sprite(
    False,
    "搜索剪贴历史...",
    "极简纯净开",
    [
        {
            "title": "深圳总部开票资料 · 91440300192203821K",
            "meta": "[已固定] 42 字 · 备忘录",
            "hotkey": "⌘1",
            "selected": True,
        },
        {
            "title": "标准售后话术 · 顺丰次日达物流说明",
            "meta": "[已固定] 68 字 · 企业微信",
            "hotkey": "⌘2",
        },
        {
            "title": "请帮我审查代码隐患：{{clip_redacted}}",
            "meta": "[已固定] 31 字 · Cursor",
            "hotkey": "⌘3",
        },
    ],
    minimal_active=True,
)

CAPTIONS = [
    (0.0, 3.2, "仅 0.85 MB 纯原生打造 · macOS 液态玻璃 + Windows 11 云母版同步上线"),
    (3.2, 6.5, "内核事件级监听 后台 0.00% CPU · 2MB 超大文本检索提速 117 倍"),
    (6.5, 10.4, "程序员与 AI 用户：自动识别代码中的 API Key、数据库密码与内网 IP"),
    (10.4, 14.5, "按下 ⇧↵ 一键结构化掩码脱敏，安心把报错贴给大模型，敏感凭据零泄露"),
    (14.5, 19.2, "财务会计与商务：多行报销账单零误差自动求和，秒出会计国标大写人民币"),
    (19.2, 23.0, "法务与出纳：离线核验身份证、银行卡与 18 位税号 O/0 手误实时纠错"),
    (23.0, 27.6, "电商运营与学术外贸：AI 表格一键直粘 Excel 自动分列 + PDF 断行缝合"),
    (27.6, 31.5, "UI 设计与客服工单：5MB 截图一键白底瘦身 92%，秒套柔光圆角样机衬底"),
    (31.5, 36.2, "销售与行政：连按 ⌃⌥V / Ctrl+Alt+V 免开面板自动跳格，3 秒填完整张表单"),
    (36.2, 40.0, "飞书/腾讯会议逐字稿一键去时间轴 · 短信验证码提取后 30 秒自动无痕销毁"),
    (40.0, 44.2, "嫌功能复杂？按 ⌘E / Ctrl+E 一键切回「极简纯净基础版」，零打扰零后台扫描"),
    (44.2, 48.1, "支持 .iclip 收藏包 Mac ↔ Windows 互导 · GitHub 搜索 fanaruto/iClip 免费获取"),
]

KEY_PULSES = [
    (2.05, "⌥ V  /  Alt + V  光标旁丝滑唤起"),
    (8.55, "⌥ V  唤起语义总线"),
    (10.35, "⇧ ↵  一键深度脱敏键入"),
    (16.75, "⇧ ↵  追加合计与会计大写"),
    (20.35, "↵  一键修正国标税号"),
    (25.35, "⇧ ↵  TSV + CF_HTML 分列直粘"),
    (33.00, "⌃ ⌥ V  顺序出队 #1 + 自动 Tab"),
    (33.75, "⌃ ⌥ V  顺序出队 #2 + 自动 Tab"),
    (34.50, "⌃ ⌥ V  顺序出队 #3 填表完成"),
    (41.55, "⌘ E / Ctrl + E  极简纯净模式"),
]

CURSOR_KF = [
    (0.0, 960, 520),
    (1.9, 540, 430),
    (4.4, 1420, 430),
    (6.5, 1450, 440),
    (9.9, 1420, 465),
    (11.0, 580, 430),
    (14.5, 1440, 440),
    (16.7, 1430, 455),
    (19.8, 1430, 560),
    (23.0, 520, 420),
    (25.4, 520, 470),
    (28.8, 1420, 500),
    (31.5, 480, 390),
    (33.8, 480, 495),
    (34.6, 480, 600),
    (37.6, 1380, 640),
    (40.0, 1580, 310),
    (41.6, 1690, 290),
    (45.0, 520, 710),
    (48.0, 520, 710),
]


def paste_sprite_animated(canvas: Image.Image, sprite: Image.Image, x: int, y: int, progress: float):
    p = clamp(progress)
    if p <= 0.01:
        return
    e = ease_out_expo(p)
    dy = int(round((1.0 - e) * -26.0))
    if p >= 0.99:
        canvas.alpha_composite(sprite, (x, y))
    else:
        faded = sprite.copy()
        alpha = faded.getchannel("A").point(lambda a: int(a * p))
        faded.putalpha(alpha)
        canvas.alpha_composite(faded, (x, y + dy))


def draw_cursor(canvas: Image.Image, cx: float, cy: float, pulse_dt: float | None):
    d = SmartDraw(canvas)
    x, y = int(round(cx)), int(round(cy))
    if pulse_dt is not None and 0.0 <= pulse_dt <= 0.42:
        rp = pulse_dt / 0.42
        rad = int(14 + 34 * rp)
        alpha = int(220 * (1.0 - rp))
        ring_layer = Image.new("RGBA", (rad * 2 + 6, rad * 2 + 6), (0, 0, 0, 0))
        rd = SmartDraw(ring_layer)
        rd.ellipse((3, 3, rad * 2 + 3, rad * 2 + 3), outline=(96, 165, 250, alpha), width=3)
        canvas.alpha_composite(ring_layer, (x - rad - 3, y - rad - 3))

    scale = 0.85 if (pulse_dt is not None and pulse_dt < 0.10) else 1.0
    pts = [
        (x, y),
        (x + int(22 * scale), y + int(12 * scale)),
        (x + int(12 * scale), y + int(15 * scale)),
        (x + int(7 * scale), y + int(25 * scale)),
    ]
    shadow_pts = [(px + 2, py + 4) for px, py in pts]
    d.polygon(shadow_pts, fill=(0, 0, 0, 140))
    d.polygon(pts, fill=(255, 255, 255, 255), outline=(15, 23, 42, 255))


def render_frame(base_bg: Image.Image, frame_idx: int) -> Image.Image:
    t = frame_idx / FPS
    canvas = base_bg.copy()
    d = SmartDraw(canvas)

    # ---- 镜头 1: 双平台同框 (0.0 - 6.5s) ----
    if t < 6.5:
        d.text((56, 114), "告别百兆臃肿，macOS 与 Windows 双端纯原生同步上线", font=F_H1, fill=(247, 249, 254, 255))
        d.text((56, 168), "按下 ⌥V 或 Alt+V，面板在光标旁瞬时滑落 · 极客开发版与心流办公版按需选择", font=F_SUB, fill=(162, 178, 210, 255))

        draw_app_window(canvas, 56, 216, 880, 710, "macOS · Apple Liquid Glass 液态玻璃", "849 KB", False)
        d.text((92, 286), "$ ./iClip --benchmark-2mb", font=F_MONO, fill=(110, 231, 183, 255))
        d.text((92, 318), "PASS · 500 条检索 < 2ms · 休眠 0.00% CPU", font=F_BODY_B, fill=(232, 240, 252, 255))

        draw_app_window(canvas, 984, 216, 880, 710, "Windows 11 · DWM Mica / Acrylic 云母原生", "", True)
        d.text((1020, 286), "PS C:\\> iClip-Win.exe --self-test", font=F_MONO, fill=(96, 165, 250, 255))
        d.text((1020, 318), "PASS · AddClipboardFormatListener 零轮询监听", font=F_BODY_B, fill=(232, 240, 252, 255))

        pop_p = (t - 2.08) / 0.42
        paste_sprite_animated(canvas, SPRITE_S1_MAC, 220, 340, pop_p)
        paste_sprite_animated(canvas, SPRITE_S1_WIN, 1148, 340, pop_p)

    # ---- 镜头 2: 极客开发与 AI 脱敏 (6.5 - 14.5s) ----
    elif t < 14.5:
        d.text((56, 114), "极客开发与 AI 人群：敏感密钥自动掩码，安心把报错喂给大模型", font=F_H1, fill=(247, 249, 254, 255))
        d.text((56, 168), "微秒级识别 API Key、数据库密码与内网 IP，按 ⇧↵ 一键结构化脱敏上屏", font=F_SUB, fill=(162, 178, 210, 255))

        draw_app_window(canvas, 56, 216, 1160, 710, "AI 编程助手 · Prompt 提问框", "UTF-8", False)
        d.rounded_rectangle((92, 290, 1180, 620), radius=14, fill=(13, 18, 29, 255))
        d.text((118, 314), "// 请帮我排查线上连接池超时原因：", font=F_MONO, fill=(148, 163, 184, 255))

        if t < 10.42:
            d.text((118, 358), "等待粘贴环境配置...", font=F_BODY, fill=(120, 136, 164, 255))
        else:
            lines = [
                'export OPENAI_API_KEY="sk-***REDACTED***"',
                'export DB_URI="postgres://admin:***REDACTED***@*.*.*.*:5432/prod"',
                'export ONCALL_PHONE="138****8000"',
            ]
            reveal = ease_out_expo((t - 10.42) / 0.55)
            full_txt = "\n".join(lines)
            cut = int(len(full_txt) * reveal)
            for li, ln in enumerate(full_txt[:cut].split("\n")):
                d.text((118, 358 + li * 38), ln, font=F_MONO, fill=(110, 231, 183, 255))

            if t > 10.85:
                d.rounded_rectangle((92, 650, 760, 700), radius=25, fill=(16, 82, 64, 220))
                d.text((118, 663), "✓ 真实密钥、密码与内网 IP 已在本地 100% 掩码拦截，零泄露风险", font=F_BODY_B, fill=(110, 231, 183, 255))

        paste_sprite_animated(canvas, SPRITE_S2_DEV, 1270, 290, (t - 8.55) / 0.40)

    # ---- 镜头 3: 财务大写求和 & 法务税号纠错 (14.5 - 23.0s) ----
    elif t < 23.0:
        d.text((56, 114), "财务会计与法务出纳：多行报销秒算大写，18 位税号手误实时纠错", font=F_H1, fill=(247, 249, 254, 255))
        d.text((56, 168), "十进制分位精确运算杜绝浮点误差 · 离线核验身份证 GB11643 / 税号 GB32100 / 银行卡 Luhn", font=F_SUB, fill=(162, 178, 210, 255))

        draw_app_window(canvas, 56, 216, 1160, 710, "商务采购报销结算单 & 开票核对", "RMB Decimal", False)
        d.rounded_rectangle((92, 286, 1180, 560), radius=14, fill=(14, 20, 32, 255))
        for idx, item_txt in enumerate(["1. 高铁差旅费      ¥ 1,280.50", "2. 酒店住宿费      ¥ 680.00", "3. 市内交通费      ¥ 95.55"]):
            d.text((122, 310 + idx * 42), item_txt, font=F_BODY, fill=(226, 234, 248, 255))
        d.line((122, 452, 1140, 452), fill=(46, 58, 82, 255), width=1)
        if t >= 16.82:
            d.text((122, 476), "合计：¥2,056.05（贰仟零伍拾陆元零伍分）", font=font_cjk(23, True), fill=(94, 234, 212, 255))
        else:
            d.text((122, 476), "等待追加精确合计与会计国标大写...", font=F_BODY, fill=(118, 132, 160, 255))

        d.rounded_rectangle((92, 590, 1180, 740), radius=14, fill=(14, 20, 32, 255))
        d.text((122, 614), "购方统一社会信用代码（自动拦截字母 O / 数字 0 手误）：", font=font_cjk(15), fill=(154, 168, 196, 255))
        if t >= 20.42:
            d.text((122, 656), "91440300192203821K   ✓ 国标 GB 32100 核验通过", font=font_cjk(24, True), fill=(52, 211, 153, 255))
        else:
            d.text((122, 656), "9144O3OO192203821K   ⚠️ 检出误输字母 O", font=font_cjk(24, True), fill=(251, 191, 36, 255))

        sp = SPRITE_S3_FIN_BILL if t < 19.2 else SPRITE_S3_FIN_USCC
        paste_sprite_animated(canvas, sp, 1270, 290, 1.0)

    # ---- 镜头 4: 电商运营 Excel 分列 & 设计师截图瘦身加壳 (23.0 - 31.5s) ----
    elif t < 31.5:
        d.text((56, 114), "电商运营与视觉设计：AI 表格直粘 Excel 自动分列，截图一键瘦身加样机壳", font=F_H1, fill=(247, 249, 254, 255))
        d.text((56, 168), "同时写入 TSV + CF_HTML 双协议破除单元格粘连 · 5MB 透明截图白底压至 380KB 防黑边", font=F_SUB, fill=(162, 178, 210, 255))

        draw_app_window(canvas, 56, 216, 920, 710, "Excel / 飞书电子表格 · 双协议分列直粘", "Sheet1", True)
        headers = ["A · 商品名称", "B · 渠道单价", "C · 实时库存"]
        col_x = [88, 430, 690, 944]
        d.rectangle((col_x[0], 290, col_x[3], 340), fill=(30, 41, 59, 255))
        for ci in range(3):
            d.rectangle((col_x[ci], 290, col_x[ci + 1], 340), outline=(64, 78, 104, 255), width=1)
            d.text((col_x[ci] + 16, 304), headers[ci], font=F_BODY_B, fill=(147, 197, 253, 255))

        if t < 25.4:
            d.rectangle((col_x[0], 340, col_x[3], 410), outline=(64, 78, 104, 255), width=1)
            d.text((104, 364), "传统粘贴痛点：| iClip Pro | 0.00 | 999 | （全挤在 A1 单格！）", font=F_BODY, fill=(248, 113, 113, 255))
        else:
            rows = [
                ("iClip 极客开发版", "¥ 0.00 (开源)", "99,999"),
                ("iClip 心流办公版", "¥ 0.00 (双端)", "99,999"),
                ("液态高清防窥膜,旗舰款", "¥ 39.90", "1,280"),
            ]
            shown = int(clamp((t - 25.4) / 0.20 + 1, 1, 3))
            for ri in range(shown):
                ry = 340 + ri * 58
                d.rectangle((col_x[0], ry, col_x[3], ry + 58), fill=(16, 48, 44, 150))
                for ci in range(3):
                    d.rectangle((col_x[ci], ry, col_x[ci + 1], ry + 58), outline=(64, 88, 104, 255), width=1)
                    d.text((col_x[ci] + 16, ry + 17), rows[ri][ci], font=F_BODY_B if ci == 0 else F_BODY, fill=(241, 245, 249, 255))

        d.rounded_rectangle((88, 560, 944, 650), radius=12, fill=(14, 20, 32, 255))
        d.text((112, 578), "学术/外贸 PDF 断行缝合：", font=F_BODY_B, fill=(96, 165, 250, 255))
        d.text((112, 610), "archi-↵ tectures  →  architectures（保留分段与中英盘古空格）", font=F_BODY, fill=(203, 213, 225, 255))

        draw_app_window(canvas, 1012, 216, 852, 710, "设计师工单与社媒发图 · 硬件加速图像工坊", "ImageIO", False)
        if t >= 29.2:
            d.rounded_rectangle((1140, 336, 1736, 704), radius=26, fill=(226, 235, 248, 255))
            d.rounded_rectangle((1178, 382, 1698, 666), radius=16, fill=(18, 26, 42, 255))
            d.rounded_rectangle((1174, 374, 1694, 658), radius=16, fill=(29, 40, 58, 255))
            stat_txt = "✓ 已白底瘦身至 380 KB (-92%) + 柔光圆角阴影样机壳"
            stat_col = (52, 211, 153, 255)
        else:
            d.rounded_rectangle((1174, 374, 1694, 658), radius=12, fill=(29, 40, 58, 255), outline=(72, 86, 112, 255), width=1)
            stat_txt = "原始 Retina 截图：5,240 KB（工单后台常因超体积报错）"
            stat_col = (156, 170, 196, 255)

        d.text((1210, 404), "季度转化率增长看板", font=F_BODY_B, fill=(248, 250, 255, 255))
        for bi, bh in enumerate([70, 115, 165]):
            bx = 1220 + bi * 145
            bcol = (52, 211, 153, 255) if bi == 2 else (59, 130, 246, 255)
            d.rounded_rectangle((bx, 620 - bh, bx + 96, 620), radius=8, fill=bcol)
        d.text((1140, 742), stat_txt, font=F_BODY_B, fill=stat_col)

    # ---- 镜头 5: ⌃⌥V 三连填表 + 会议去时间轴 + OTP 阅后即焚 (31.5 - 40.0s) ----
    elif t < 40.0:
        d.text((56, 114), "销售管理与隐私高敏：⌃⌥V 免开面板连填表单，短信验证码贴完自动焚毁", font=F_H1, fill=(247, 249, 254, 255))
        d.text((56, 168), "FIFO 队列自动按 Tab 跳格连填客户资料 · 飞书/腾讯会议逐字稿一键剥离时间轴", font=F_SUB, fill=(162, 178, 210, 255))

        draw_app_window(canvas, 56, 216, 880, 710, "CRM 客户签约建档表单 · FIFO 顺序出队连填", "⌃ ⌥ V", False)
        fields = [
            ("1. 签约客户名称", 33.05, "轻剪科技（深圳）有限公司"),
            ("2. 负责人电话", 33.80, "138-0013-8000（张总监）"),
            ("3. 合同寄送地址", 34.55, "深圳市南山区科技南十二路 18 号"),
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

        draw_app_window(canvas, 984, 216, 880, 710, "会议纪要清洗 & 一次性验证码 (OTP) 阅后即焚", "Auto-Expire", False)
        d.rounded_rectangle((1020, 292, 1828, 510), radius=14, fill=(13, 19, 32, 255))
        d.text((1046, 314), "飞书妙记 / 腾讯会议 / SRT 字幕时间轴剥离：", font=font_cjk(15, True), fill=(147, 197, 253, 255))
        if t < 36.2:
            d.text((1046, 356), "张总监 00:01:12  对齐 Q4 大客户交付排期", font=F_BODY, fill=(136, 150, 178, 255))
            d.text((1046, 396), "张总监 00:01:19  违约金上限控制在 20%。", font=F_BODY, fill=(136, 150, 178, 255))
        else:
            d.text((1046, 358), "张总监：对齐 Q4 大客户交付排期，违约金上限控制在 20%。", font=F_BODY_B, fill=(110, 231, 183, 255))
            d.text((1046, 404), "✓ 已剥离 2 处时间轴并合并同发言人连续碎片", font=font_cjk(15), fill=(162, 178, 206, 255))

        d.rounded_rectangle((1020, 540, 1828, 760), radius=14, fill=(13, 19, 32, 255))
        d.text((1046, 564), "抗尾号/金额干扰提取纯验证码：", font=font_cjk(15, True), fill=(251, 191, 36, 255))
        d.text((1046, 600), "“【招行】尾号8899消费¥1280，验证码 654321，5分钟有效”", font=font_cjk(15), fill=(154, 168, 196, 255))
        if t >= 37.8:
            d.text((1046, 654), "6 5 4 3 2 1", font=font_mono(34), fill=(94, 234, 212, 255))
            rem = max(26, 30 - int((t - 37.8) * 1.5))
            d.rounded_rectangle((1440, 656, 1800, 704), radius=24, fill=(136, 28, 52, 230))
            d.text((1466, 669), f"阅后即焚：{rem}s 后无痕销毁", font=F_BODY_B, fill=(254, 205, 211, 255))
        else:
            d.text((1046, 654), "- - - - - -", font=font_mono(34), fill=(100, 116, 139, 255))

    # ---- 镜头 6: ⌘E 极简纯净开关 & .iclip 跨机归档收尾 (40.0 - 48.0s) ----
    else:
        d.text((84, 220), "想强大时全副武装，", font=F_HERO, fill=(247, 249, 254, 255))
        d.text((84, 294), "想安静时 ⌘E 一键回归极简。", font=F_HERO, fill=(52, 211, 153, 255))
        d.text((84, 396), "开启「极简纯净模式（基础功能版）」，隐藏一切行业胶囊并停止后台扫描。", font=F_SUB, fill=(176, 190, 218, 255))
        d.text((84, 438), "支持导出自包含 .iclip 收藏资产包，在 macOS 与 Windows 间无损互导。", font=F_SUB, fill=(176, 190, 218, 255))

        d.rounded_rectangle((84, 536, 910, 624), radius=18, fill=(37, 99, 235, 255))
        d.text((120, 565), "GitHub 免费开源  ·  github.com/fanaruto/iClip", font=font_cjk(25, True), fill=(255, 255, 255, 255))
        d.text((84, 656), "提供安装包：iClip-Dev / iClip-Flow（macOS & Windows x64 双端完备测试）", font=font_cjk(17), fill=(148, 164, 196, 255))

        sp6 = SPRITE_S6_MIN if t >= 41.6 else SPRITE_S6_ADV
        paste_sprite_animated(canvas, sp6, 1220, 210, 1.0)

    # ---- 光标与快捷键 HUD ----
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

    # ---- 底部高对比字幕胶囊 ----
    for cs, ce, cap in CAPTIONS:
        if cs <= t < ce:
            cw = int(d.textlength(cap, font=F_CAP)) + 64
            bx = (W - cw) // 2
            by = H - 86
            d.rounded_rectangle((bx, by, bx + cw, by + 54), radius=27, fill=(13, 17, 27, 240), outline=(66, 80, 108, 255), width=1)
            d.text((bx + 32, by + 13), cap, font=F_CAP, fill=(248, 250, 252, 255))
            break

    return canvas.convert("RGB")


def generate_covers(base_bg: Image.Image, out_dir: str):
    os.makedirs(out_dir, exist_ok=True)
    # 16:9 高清封面（取第 190 帧双端同框高潮画面）
    c16x9 = render_frame(base_bg, 190)
    c16x9.save(os.path.join(out_dir, "cover-16x9.jpg"), quality=95)

    # 4:3 封面 (1440x1080)
    c4x3 = Image.new("RGBA", (1440, 1080), (11, 14, 21, 255))
    d4 = SmartDraw(c4x3)
    d4.text((68, 78), "iClip v2.1 双端正式发布", font=font_cjk(32, True), fill=(96, 165, 250, 255))
    d4.text((68, 138), "0.85 MB 纯原生剪贴板 · Mac & Win 同享", font=font_cjk(52, True), fill=(248, 250, 255, 255))
    d4.text((68, 220), "0% 后台 CPU · 7 大行业痛点工具箱 · ⌘E 一键极简纯净模式", font=font_cjk(25), fill=(168, 184, 214, 255))
    c4x3.alpha_composite(SPRITE_S1_MAC, (96, 320))
    c4x3.alpha_composite(SPRITE_S1_WIN, (740, 320))
    c4x3.convert("RGB").save(os.path.join(out_dir, "cover-4x3.png"))

    # 3:4 竖版封面 (1080x1440 适配小红书/抖音)
    c3x4 = Image.new("RGBA", (1080, 1440), (11, 14, 21, 255))
    d3 = SmartDraw(c3x4)
    d3.rounded_rectangle((68, 84, 420, 138), radius=27, fill=(37, 99, 235, 255))
    d3.text((98, 97), "0.85 MB · 免费开源", font=font_cjk(24, True), fill=(255, 255, 255, 255))
    d3.text((68, 176), "macOS + Windows", font=font_cjk(58, True), fill=(248, 250, 255, 255))
    d3.text((68, 262), "双端纯原生剪贴板 iClip 2.1", font=font_cjk(52, True), fill=(94, 234, 212, 255))
    d3.text((68, 352), "AI 密钥脱敏 · 财务大写求和 · 表格直粘 Excel · 截图瘦身", font=font_cjk(26), fill=(176, 190, 218, 255))
    c3x4.alpha_composite(SPRITE_S1_MAC, (60, 440))
    c3x4.alpha_composite(SPRITE_S1_WIN, (470, 880))
    c3x4.convert("RGB").save(os.path.join(out_dir, "cover-3x4.png"))


def main():
    t0 = time.time()
    base_bg = build_base_backdrop()
    covers_dir = os.path.join(SCRATCH, "covers")
    generate_covers(base_bg, covers_dir)

    cmd = [
        "/opt/homebrew/bin/ffmpeg",
        "-y",
        "-f", "rawvideo",
        "-pix_fmt", "rgb24",
        "-s", f"{W}x{H}",
        "-r", str(FPS),
        "-i", "-",
        "-i", AUDIO_WAV,
        "-c:v", "libx264",
        "-preset", "medium",
        "-crf", "17",
        "-pix_fmt", "yuv420p",
        "-colorspace", "bt709",
        "-color_primaries", "bt709",
        "-color_trc", "bt709",
        "-c:a", "aac",
        "-b:a", "192k",
        "-shortest",
        "-movflags", "+faststart",
        OUT_MP4,
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdin is not None

    for f in range(TOTAL_FRAMES):
        rgb_img = render_frame(base_bg, f)
        proc.stdin.write(rgb_img.tobytes())
        if f > 0 and f % 600 == 0:
            print(f"Progress: {f}/{TOTAL_FRAMES} frames ({time.time() - t0:.1f}s)")

    proc.stdin.close()
    stderr_bytes = proc.stderr.read() if proc.stderr else b""
    rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"ffmpeg failed ({rc}): {stderr_bytes.decode('utf-8', 'ignore')[-600:]}")
    print(f"RENDER_COMPLETE in {time.time() - t0:.1f}s -> {OUT_MP4}")


if __name__ == "__main__":
    main()
