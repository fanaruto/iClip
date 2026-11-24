#!/usr/bin/env python3
"""
iClip v2.7 新功能宣发大片确定性渲染引擎 (1920x1080 @ 60fps, 36.0s)
支持一键输出：
  1. 通用完整版 成片.mp4（含官网剧场版与全平台封面）
  2. 小红书绝对纯净版 成片-xhs.mp4 + cover-3x4-xhs.png（零网址/零裸域名/零仓库名/零长串号码/零竞品与外部平台词）
严格遵循 Impeccable 视觉规范：高对比文字、单一品牌强调色、克制液态玻璃层级、零眉标、60fps 指数阻尼动画与 -16 LUFS 立体声配乐。
"""
import argparse
import math
import os
import struct
import subprocess
import time
import wave
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1920, 1080
FPS = 60
DURATION = 36.0
TOTAL_FRAMES = int(FPS * DURATION)

CJK_FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"
if not os.path.exists(CJK_FONT_PATH):
    CJK_FONT_PATH = "/System/Library/Fonts/STHeiti Medium.ttc"
SYM_FONT_PATH = "/System/Library/Fonts/SFNS.ttf"
MONO_FONT_PATH = "/System/Library/Fonts/SFNSMono.ttf"
if not os.path.exists(MONO_FONT_PATH):
    MONO_FONT_PATH = "/System/Library/Fonts/Menlo.ttc"

APPLE_SYM_CHARS = set("⌘⌥⌃⇧↵✓←→↑↓□✕─•")
_SYM_CACHE: dict[int, ImageFont.FreeTypeFont] = {}
_CJK_CACHE: dict[tuple[int, bool], ImageFont.FreeTypeFont] = {}
_MONO_CACHE: dict[int, ImageFont.FreeTypeFont] = {}


def font_sym(size: int) -> ImageFont.FreeTypeFont:
    if size not in _SYM_CACHE:
        _SYM_CACHE[size] = ImageFont.truetype(SYM_FONT_PATH, size)
    return _SYM_CACHE[size]


def font_cjk(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    key = (size, bold)
    if key not in _CJK_CACHE:
        idx = 1 if (bold and CJK_FONT_PATH.endswith("Hiragino Sans GB.ttc")) else 0
        try:
            _CJK_CACHE[key] = ImageFont.truetype(CJK_FONT_PATH, size, index=idx)
        except Exception:
            _CJK_CACHE[key] = ImageFont.truetype(CJK_FONT_PATH, size)
    return _CJK_CACHE[key]


def font_mono(size: int) -> ImageFont.FreeTypeFont:
    if size not in _MONO_CACHE:
        _MONO_CACHE[size] = ImageFont.truetype(MONO_FONT_PATH, size)
    return _MONO_CACHE[size]


def split_runs(text: str):
    if not text:
        return []
    text = text.replace("↵", "Enter")
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
    """自动对 Apple 修饰键与几何符号切换 SFNS 字体，杜绝 CJK 缺字方框"""
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


F_HERO = font_cjk(52, True)
F_H1 = font_cjk(40, True)
F_H2 = font_cjk(26, True)
F_SUB = font_cjk(20, False)
F_BODY = font_cjk(18, False)
F_BODY_B = font_cjk(18, True)
F_CARD_T = font_cjk(16, True)
F_CARD_M = font_cjk(13, False)
F_CHIP = font_cjk(13, True)
F_CAP = font_cjk(22, True)
F_HUD = font_cjk(24, True)
F_MONO = font_mono(17)
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


def synthesize_soundtrack(raw_wav: str, norm_wav: str, duration: float = DURATION):
    """合成清新现代的 Apple 发布会风格极简温暖电子律动 + 关键交互音效，并标准化至 -16 LUFS"""
    sr = 44100
    n_samples = int(sr * duration)
    bpm = 112.0
    beat_sec = 60.0 / bpm

    # 温暖和弦进行 (Fmaj7 -> G6 -> Em7 -> Am9)
    chords = [
        (174.61, 220.00, 261.63, 329.63),
        (196.00, 246.94, 293.66, 329.63),
        (164.81, 196.00, 246.94, 293.66),
        (220.00, 261.63, 329.63, 392.00),
    ]
    arp_notes = [523.25, 659.25, 783.99, 659.25, 587.33, 659.25, 783.99, 987.77]

    # 与画面动作严丝合缝对齐的清脆按键/唤醒音效时间点
    ui_clicks = [1.05, 1.24, 3.65, 9.60, 12.60, 17.60, 20.10, 24.40, 27.10, 30.20, 32.80]
    whooshes = [0.15, 7.50, 15.00, 22.50, 29.50]

    buf = bytearray(n_samples * 4)
    two_pi = 2.0 * math.pi

    for i in range(n_samples):
        t = i / sr
        fade_in = clamp(t / 0.6)
        fade_out = clamp((duration - t) / 1.4)
        master_env = fade_in * fade_out

        bar_idx = int(t / (beat_sec * 4.0)) % len(chords)
        chord = chords[bar_idx]

        # 柔和电钢琴铺底 (左右声道微立体声展开)
        pad_l = 0.0
        pad_r = 0.0
        for idx, freq in enumerate(chord):
            detune = 1.0015 if idx % 2 == 0 else 0.9985
            s_l = math.sin(two_pi * freq * t) * 0.7 + math.sin(two_pi * freq * 2.0 * t) * 0.15
            s_r = math.sin(two_pi * freq * detune * t) * 0.7 + math.sin(two_pi * freq * 2.0 * detune * t) * 0.15
            pad_l += s_l * 0.055
            pad_r += s_r * 0.055

        # 轻盈八分音符木琴泛音琶音
        step = int(t / (beat_sec * 0.5))
        step_t = t - step * (beat_sec * 0.5)
        arp_f = arp_notes[step % len(arp_notes)]
        arp_env = math.exp(-step_t * 11.5)
        arp_sig = (math.sin(two_pi * arp_f * t) + 0.25 * math.sin(two_pi * arp_f * 3.0 * t)) * arp_env * 0.075
        pan = 0.65 if step % 2 == 0 else 0.35

        # 干净温润的低频心跳律动
        beat_pos = t % beat_sec
        kick_env = math.exp(-beat_pos * 16.0)
        kick_f = 58.0 + 62.0 * math.exp(-beat_pos * 34.0)
        kick = math.sin(two_pi * kick_f * beat_pos) * kick_env * 0.19

        # 关键交互清脆玻璃微响
        sfx = 0.0
        for ct in ui_clicks:
            dt = t - ct
            if 0.0 <= dt < 0.18:
                c_env = math.exp(-dt * 38.0)
                sfx += (math.sin(two_pi * 1320.0 * dt) * 0.6 + math.sin(two_pi * 1980.0 * dt) * 0.4) * c_env * 0.16

        for wt in whooshes:
            dt = t - wt
            if 0.0 <= dt < 0.32:
                w_env = math.sin(math.pi * (dt / 0.32))
                w_f = 280.0 + 340.0 * (dt / 0.32)
                sfx += math.sin(two_pi * w_f * dt) * w_env * 0.065

        l_val = (pad_l + arp_sig * pan + kick + sfx) * master_env
        r_val = (pad_r + arp_sig * (1.0 - pan) + kick + sfx) * master_env

        li = max(-32000, min(32000, int(l_val * 32767.0)))
        ri = max(-32000, min(32000, int(r_val * 32767.0)))
        struct.pack_into("<hh", buf, i * 4, li, ri)

    with wave.open(raw_wav, "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.writeframes(bytes(buf))

    subprocess.run(
        [
            "/opt/homebrew/bin/ffmpeg",
            "-y",
            "-v",
            "error",
            "-i",
            raw_wav,
            "-af",
            "loudnorm=I=-16:TP=-1.5:LRA=11",
            "-ar",
            "44100",
            "-ac",
            "2",
            norm_wav,
        ],
        check=True,
    )


def make_shadow_box(w: int, h: int, radius: int = 20, pad: int = 34, alpha: int = 125) -> Image.Image:
    im = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    d = SmartDraw(im)
    d.rounded_rectangle((pad, pad + 10, pad + w, pad + h + 10), radius=radius, fill=(0, 0, 0, alpha))
    return im.filter(ImageFilter.GaussianBlur(15))


def build_base_backdrop(clean_xhs: bool) -> Image.Image:
    bg = Image.new("RGBA", (W, H), (11, 14, 21, 255))
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = SmartDraw(glow)
    gd.ellipse((120, -90, 960, 620), fill=(44, 96, 220, 40))
    gd.ellipse((1040, 430, 1880, 1130), fill=(22, 146, 124, 30))
    glow = glow.filter(ImageFilter.GaussianBlur(115))
    bg = Image.alpha_composite(bg, glow)

    d = SmartDraw(bg)
    # 顶部品牌与双端标识胶囊
    d.rounded_rectangle((56, 30, 618, 80), radius=25, fill=(20, 26, 39, 235), outline=(56, 68, 94, 255), width=1)
    d.ellipse((78, 49, 90, 61), fill=(59, 130, 246, 255))
    d.text((102, 42), "iClip v2.7", font=F_BODY_B, fill=(248, 250, 252, 255))
    d.text((212, 44), "｜ macOS + Windows 液态玻璃原生剪贴板", font=font_cjk(15), fill=(164, 180, 210, 255))

    # 顶部右侧实测硬核指标胶囊
    d.rounded_rectangle((1084, 30, 1864, 80), radius=25, fill=(20, 26, 39, 235), outline=(56, 68, 94, 255), width=1)
    d.text((1112, 44), "0ms 零失焦", font=font_cjk(15, True), fill=(94, 234, 212, 255))
    d.text((1210, 44), "顺手直贴   ·", font=font_cjk(15), fill=(196, 208, 230, 255))
    d.text((1318, 44), "零信任加密", font=font_cjk(15, True), fill=(94, 234, 212, 255))
    d.text((1412, 44), "隐私沙盒   ·", font=font_cjk(15), fill=(196, 208, 230, 255))
    d.text((1520, 44), "0.00% CPU", font=font_cjk(15, True), fill=(94, 234, 212, 255))
    d.text((1622, 44), "待机零轮询", font=font_cjk(15), fill=(196, 208, 230, 255))
    if not clean_xhs:
        d.text((1724, 44), " · 免费开源", font=font_cjk(15), fill=(164, 180, 210, 255))
    else:
        d.text((1724, 44), " · 极速轻量", font=font_cjk(15), fill=(164, 180, 210, 255))
    return bg


def build_iclip_panel_sprite(
    is_win11: bool,
    search_hint: str,
    right_badge: str,
    cards: list,
    active_tab: int = 0,
    minimal_active: bool = False,
) -> Image.Image:
    pw, ph = 510, 424
    pad = 34
    rad = 18 if is_win11 else 22
    sprite = make_shadow_box(pw, ph, radius=rad, pad=pad, alpha=140)
    d = SmartDraw(sprite)
    ox, oy = pad, pad

    bg_col = (24, 30, 44, 242) if is_win11 else (27, 33, 49, 238)
    border_col = (74, 92, 128, 255)
    d.rounded_rectangle((ox, oy, ox + pw, oy + ph), radius=rad, fill=bg_col, outline=border_col, width=1)
    # 顶部液态玻璃高光折射边
    d.line((ox + rad, oy + 1, ox + pw - rad, oy + 1), fill=(255, 255, 255, 55), width=1)

    # 搜索胶囊栏
    d.rounded_rectangle((ox + 16, oy + 16, ox + pw - 16, oy + 58), radius=12, fill=(39, 47, 66, 255))
    d.text((ox + 30, oy + 27), search_hint, font=font_cjk(14), fill=(186, 198, 224, 255))
    badge_bg = (16, 185, 129, 255) if minimal_active else (54, 65, 90, 255)
    badge_fg = (6, 42, 32, 255) if minimal_active else (216, 226, 246, 255)
    bw = int(d.textlength(right_badge, font=F_CHIP)) + 22
    d.rounded_rectangle((ox + pw - 24 - bw, oy + 23, ox + pw - 24, oy + 51), radius=14, fill=badge_bg)
    d.text((ox + pw - 24 - bw + 11, oy + 28), right_badge, font=F_CHIP, fill=badge_fg)

    # 分类胶囊（含 v2.7 待办）
    tabs = ["全部", "待办", "收藏", "文本", "图片", "文件"]
    tx = ox + 16
    for idx, tb in enumerate(tabs):
        tw = int(d.textlength(tb, font=F_CHIP)) + 24
        t_fill = (47, 104, 230, 255) if idx == active_tab else (37, 44, 62, 255)
        t_fg = (255, 255, 255, 255) if idx == active_tab else (164, 176, 202, 255)
        d.rounded_rectangle((tx, oy + 69, tx + tw, oy + 97), radius=14, fill=t_fill)
        d.text((tx + 12, oy + 74), tb, font=F_CHIP, fill=t_fg)
        tx += tw + 8

    cy = oy + 111
    for c in cards:
        sel = c.get("selected", False)
        chips = [] if minimal_active else c.get("chips", [])
        ch = 96 if chips else 68
        if cy + ch > oy + ph - 12:
            break
        c_fill = (47, 104, 230, 255) if sel else (37, 44, 62, 255)
        d.rounded_rectangle((ox + 16, cy, ox + pw - 16, cy + ch), radius=13, fill=c_fill)
        d.text((ox + 30, cy + 11), c["title"], font=F_CARD_T, fill=(248, 250, 255, 255))
        d.text(
            (ox + 30, cy + 37),
            c["meta"],
            font=F_CARD_M,
            fill=(222, 234, 255, 255) if sel else (154, 168, 194, 255),
        )
        if c.get("hotkey"):
            hk_w = int(d.textlength(c["hotkey"], font=F_CARD_M))
            d.text((ox + pw - 30 - hk_w, cy + 13), c["hotkey"], font=F_CARD_M, fill=(216, 228, 252, 255))

        if chips:
            cx = ox + 30
            for ch_txt, ch_kind in chips:
                cw = int(d.textlength(ch_txt, font=F_CHIP)) + 22
                if ch_kind == "warn":
                    cf, cfg = (217, 119, 6, 255), (255, 255, 255, 255)
                elif ch_kind == "ok":
                    cf, cfg = (16, 185, 129, 255), (5, 42, 30, 255)
                else:
                    cf, cfg = (28, 66, 162, 255), (242, 247, 255, 255)
                d.rounded_rectangle((cx, cy + 61, cx + cw, cy + 87), radius=13, fill=cf)
                d.text((cx + 11, cy + 65), ch_txt, font=F_CHIP, fill=cfg)
                cx += cw + 8
        cy += ch + 10

    return sprite


def build_highlights_v27_sprite() -> Image.Image:
    """1:1 还原 v2.7 全新 Tahoe 液态玻璃新手与新功能引导卡片"""
    pw, ph = 520, 442
    pad = 34
    sprite = make_shadow_box(pw, ph, radius=24, pad=pad, alpha=150)
    d = SmartDraw(sprite)
    ox, oy = pad, pad
    d.rounded_rectangle((ox, oy, ox + pw, oy + ph), radius=24, fill=(25, 31, 46, 245), outline=(78, 96, 134, 255), width=1)
    d.line((ox + 24, oy + 1, ox + pw - 24, oy + 1), fill=(255, 255, 255, 65), width=1)

    d.rounded_rectangle((ox + 28, oy + 24, ox + 74, oy + 70), radius=13, fill=(38, 62, 112, 255))
    d.ellipse((ox + 44, oy + 40, ox + 58, oy + 54), fill=(96, 165, 250, 255))
    d.text((ox + 90, oy + 24), "iClip 2.7 核心亮点", font=font_cjk(22, True), fill=(248, 250, 255, 255))
    d.text((ox + 90, oy + 52), "零失焦顺手直贴 · 零信任隐私护盾 · 剪贴即待办", font=font_cjk(14), fill=(164, 180, 210, 255))

    rows = [
        ("唤醒零失焦直贴", "搜索框与弹层纹丝不收起，支持单键双击，回车 0ms 直贴", (59, 130, 246)),
        ("零信任隐私护盾", "全库硬件级加密，密钥遮罩、双向替身脱敏、投屏自动隐身", (16, 185, 129)),
        ("剪贴即待办与净文", "⌘T 一键转待办，一键去 Markdown 符号，表格直粘自动分列", (245, 158, 11)),
        ("自由拖拽与极简开关", "图文直接拖入目标窗口，按 ⌘E 随时切回纯粹复制粘贴", (99, 102, 241)),
    ]
    ry = oy + 92
    for title, desc, col in rows:
        d.rounded_rectangle((ox + 24, ry, ox + pw - 24, ry + 64), radius=13, fill=(35, 43, 62, 255))
        d.rounded_rectangle((ox + 36, ry + 14, ox + 72, ry + 50), radius=10, fill=(col[0], col[1], col[2], 42))
        d.ellipse((ox + 49, ry + 27, ox + 59, ry + 37), fill=col + (255,))
        d.text((ox + 86, ry + 11), title, font=font_cjk(15, True), fill=(246, 249, 255, 255))
        d.text((ox + 86, ry + 36), desc, font=font_cjk(12), fill=(162, 176, 204, 255))
        ry += 72

    d.rounded_rectangle((ox + 24, oy + ph - 56, ox + pw - 24, oy + ph - 18), radius=12, fill=(47, 104, 230, 255))
    btn_txt = "开始使用  Enter"
    bw = int(d.textlength(btn_txt, font=font_cjk(15, True)))
    d.text((ox + (pw - bw) // 2, oy + ph - 47), btn_txt, font=font_cjk(15, True), fill=(255, 255, 255, 255))
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
    d.rounded_rectangle((x, y, x + w, y + h), radius=16, fill=(18, 23, 35, 255), outline=(48, 60, 84, 255), width=1)
    d.rounded_rectangle((x + 1, y + 1, x + w - 1, y + 46), radius=15, fill=(25, 32, 48, 255))
    d.rectangle((x + 1, y + 32, x + w - 1, y + 46), fill=(25, 32, 48, 255))
    d.line((x, y + 46, x + w, y + 46), fill=(44, 54, 74, 255), width=1)

    if not is_windows:
        for idx, col in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            cx = x + 18 + idx * 19
            d.ellipse((cx, y + 17, cx + 12, y + 29), fill=col + (255,))
        d.text((x + 84, y + 13), title, font=font_cjk(14, True), fill=(180, 194, 220, 255))
    else:
        d.text((x + 20, y + 13), title, font=font_cjk(14, True), fill=(180, 194, 220, 255))
        ic_col = (152, 166, 192, 255)
        d.line((x + w - 96, y + 23, x + w - 84, y + 23), fill=ic_col, width=2)
        d.rectangle((x + w - 64, y + 17, x + w - 53, y + 28), outline=ic_col, width=1)
        d.line((x + w - 33, y + 17, x + w - 22, y + 28), fill=ic_col, width=2)
        d.line((x + w - 33, y + 28, x + w - 22, y + 17), fill=ic_col, width=2)

    if right_tag and not is_windows:
        tw = int(d.textlength(right_tag, font=F_MONO_SM))
        d.text((x + w - 20 - tw, y + 14), right_tag, font=F_MONO_SM, fill=(134, 150, 180, 255))


def paste_sprite_animated(canvas: Image.Image, sprite: Image.Image, x: int, y: int, prog: float):
    p = clamp(prog)
    if p <= 0.01:
        return
    e = ease_out_expo(p)
    dy = int((1.0 - e) * 26)
    if p >= 0.99:
        canvas.alpha_composite(sprite, (x, y))
        return
    faded = sprite.copy()
    alpha = faded.getchannel("A").point(lambda a: int(a * e))
    faded.putalpha(alpha)
    canvas.alpha_composite(faded, (x, y + dy))


def draw_key_hud(d: SmartDraw, text: str, prog: float):
    """顶部偏中按键脉冲提示条"""
    p = clamp(prog)
    if p <= 0.0 or p >= 1.0:
        return
    env = math.sin(math.pi * p)
    kw = int(d.textlength(text, font=F_HUD)) + 52
    kx = (W - kw) // 2
    ky = 96
    d.rounded_rectangle(
        (kx, ky, kx + kw, ky + 48),
        radius=24,
        fill=(37, 99, 235, int(235 * env)),
        outline=(147, 197, 253, int(255 * env)),
        width=2,
    )
    d.text((kx + 26, ky + 10), text, font=F_HUD, fill=(255, 255, 255, int(255 * env)))


class SceneAssets:
    def __init__(self, clean_xhs: bool):
        self.clean_xhs = clean_xhs
        self.base_bg = build_base_backdrop(clean_xhs)
        self.highlights = build_highlights_v27_sprite()

        # Scene 1: 零失焦顺手直贴
        self.s1_mac = build_iclip_panel_sprite(
            False,
            "盲打直搜剪贴历史 (原窗口保持焦点)...",
            "零失焦直贴",
            [
                {
                    "title": "季度产品复盘纪要与关键里程碑",
                    "meta": "刚刚复制 · 按 Enter 0ms 顺手直贴入框",
                    "hotkey": "⌘1",
                    "selected": True,
                    "chips": [("0ms 顺手直贴 ⇧↵", "ok"), ("保持原框焦点", "norm")],
                },
                {
                    "title": "壹拾肆万肆仟陆佰肆拾元整",
                    "meta": "财务核算 · 含税金额自动转大写",
                    "hotkey": "⌘2",
                },
                {
                    "title": "高清界面截图 · 离线文字已秒提",
                    "meta": "支持直接拖出至任意对话或文档",
                    "hotkey": "⌘3",
                },
            ],
        )
        self.s1_win = build_iclip_panel_sprite(
            True,
            "搜索剪贴历史... (双击 Ctrl 呼出)",
            "Win11 同步",
            [
                {
                    "title": "| 模块名称 | 迭代状态 | 负责人 |",
                    "meta": "双协议直粘电子表格自动整齐分列",
                    "hotkey": "Ctrl+1",
                    "selected": True,
                    "chips": [("直粘表格分列 ⇧↵", "ok"), ("去格式纯文本", "norm")],
                },
                {
                    "title": "接口访问凭据 = ••••••••••••",
                    "meta": "零信任防肩窥遮罩 · 粘贴即焚保护",
                    "hotkey": "Ctrl+2",
                },
            ],
        )

        # Scene 2: 零信任隐私护盾
        self.s2_shield = build_iclip_panel_sprite(
            False,
            "@secret 已开启零信任防肩窥遮罩",
            "安全护盾",
            [
                {
                    "title": "生产环境接口密钥 = ••••••••••••••••",
                    "meta": "硬件级静态加密 · 自动识别密钥与连接口令",
                    "hotkey": "⌘1",
                    "selected": True,
                    "chips": [("AI 替身脱敏粘贴 ⇧↵", "warn"), ("⌘B 粘贴 5s 即焚", "norm")],
                },
                {
                    "title": "@pw 20 → 高熵硬件随机强密码已就绪",
                    "meta": "不落盘记忆 · 贴完自动从系统剪贴板销毁",
                    "hotkey": "⌘2",
                },
                {
                    "title": "含敏感信息截图 · 支持 0.2s 离线打码",
                    "meta": "在线会议共享屏幕时面板自动光学隐身",
                    "hotkey": "⌘3",
                },
            ],
        )

        # Scene 3: 去 Markdown 纯文本 + 表格直粘分列
        self.s3_md = build_iclip_panel_sprite(
            False,
            "智能识别 Markdown 符号与竖线表格",
            "净文引擎",
            [
                {
                    "title": "### 方案总结：**核心指标**提升 `42%`",
                    "meta": "大模型回复 · 含标题井号、星号与代码块标记",
                    "hotkey": "⌘1",
                    "selected": True,
                    "chips": [("去 Markdown 纯文本 ⇧↵", "ok"), ("保留段落层级", "norm")],
                },
                {
                    "title": "| 季度 | 营收增速 | 净利率 |",
                    "meta": "竖线表格 · 原生 CF_HTML 直粘表格自动分列",
                    "hotkey": "⌘2",
                    "chips": [("直粘表格分列", "ok")],
                },
            ],
        )

        # Scene 4: 剪贴即待办 + 智能算账 + 收件名片连填
        self.s4_todo = build_iclip_panel_sprite(
            False,
            "12800 * 1.13 = 14,464 (壹万肆仟肆佰陆拾肆元整)",
            "待办与算账",
            [
                {
                    "title": "□ 周五前确认新版视觉走查与压测报告",
                    "meta": "待办清单 · 按 ⌘T 一键转待办 · 勾选自动沉底",
                    "hotkey": "⌘1",
                    "selected": True,
                    "chips": [("完成打钩 ✓", "ok"), ("导出任务清单", "norm")],
                },
                {
                    "title": "收件信息：陈明 / 浦东新区张江高科园区",
                    "meta": "智能提取姓名、电话、地址胶囊一键连填",
                    "hotkey": "⌘2",
                    "chips": [("复制姓名", "norm"), ("复制地址", "norm")],
                },
            ],
            active_tab=1,
        )

        # Scene 5: 极简纯净模式对比
        self.s5_min = build_iclip_panel_sprite(
            False,
            "搜索剪贴历史...",
            "极简纯净开",
            [
                {
                    "title": "季度产品复盘纪要与关键里程碑",
                    "meta": "刚刚 · 备忘文档",
                    "hotkey": "⌘1",
                    "selected": True,
                },
                {
                    "title": "常用项目周报模板与汇报提纲",
                    "meta": "[已收藏] 跨 Mac / Win 加密同步",
                    "hotkey": "⌘2",
                },
                {
                    "title": "周五前确认新版视觉走查与压测报告",
                    "meta": "2 分钟前 · 团队协作",
                    "hotkey": "⌘3",
                },
            ],
            minimal_active=True,
        )

        if clean_xhs:
            self.captions = [
                (0.0, 3.8, "搜索框正在输入时呼出剪贴板，总会失焦收起下拉列表？"),
                (3.8, 7.5, "iClip v2.7 唤醒零失焦：原框焦点纹丝不动，双击单键秒呼出、回车 0ms 直贴"),
                (7.5, 11.4, "零信任隐私护盾：全库硬件级加密，敏感密钥默认防肩窥遮罩"),
                (11.4, 15.0, "向大模型提问自动替换一致性替身，共享屏幕投屏自动隐身，支持粘贴即焚"),
                (15.0, 18.8, "复制的 AI 回复满屏星号井号？一键「去 Markdown 纯文本」瞬间清爽"),
                (18.8, 22.5, "竖线表格原生写入双协议，直接粘贴进电子表格自动整齐分列"),
                (22.5, 26.2, "剪贴即待办：按 ⌘T / Ctrl+T 一键转待办勾选沉底，搜索框直算含税大写金额"),
                (26.2, 29.5, "混排收件信息自动拆出姓名与地址胶囊，免手拆三秒连填表单"),
                (29.5, 33.0, "焕新 v2.7 液态玻璃新手引导 · 按 ⌘E 随时一键切回极简纯净复制粘贴"),
                (33.0, 36.1, "iClip v2.7 正式发布 · macOS 与 Windows 双端纯原生同步升级"),
            ]
        else:
            self.captions = [
                (0.0, 3.8, "搜索框聚焦输入时呼出剪贴板，总会失焦收起下拉弹层？"),
                (3.8, 7.5, "iClip v2.7 唤醒零失焦：原框焦点纹丝不动，支持双击单键呼出与 0ms 直贴"),
                (7.5, 11.4, "零信任隐私护盾：本地 AES-GCM 硬件级加密，敏感凭据默认防肩窥遮罩"),
                (11.4, 15.0, "双向 AI 替身沙盒脱敏还原 · 会议投屏自动光学隐身 · ⌘B 粘贴 5s 即焚"),
                (15.0, 18.8, "AI 回复满屏 ### 与 **星号**？一键「去 Markdown 纯文本」瞬间干净清爽"),
                (18.8, 22.5, "Markdown 表格原生写入 CF_HTML，直粘 Excel 自动整齐分列"),
                (22.5, 26.2, "剪贴即待办：⌘T / Ctrl+T 一键转待办勾选沉底，搜索框秒算含税大写金额"),
                (26.2, 29.5, "混排收件名片自动拆解姓名、手机、地址胶囊，免开面板极速连填"),
                (29.5, 33.0, "全新 v2.7 液态玻璃新手引导 · 按 ⌘E 随时切回零打扰极简纯净模式"),
                (33.0, 36.1, "iClip v2.7 免费开源发布 · macOS 与 Windows 双端原生同享"),
            ]


def render_frame(assets: SceneAssets, f: int) -> Image.Image:
    t = f / FPS
    canvas = assets.base_bg.copy()
    d = SmartDraw(canvas)

    # ==================== 第 1 幕 (0.0 - 7.5s)：唤醒零失焦顺手直贴 ====================
    if t < 7.5:
        d.text((64, 108), "痛点终结：唤醒零失焦，搜索框与下拉弹层纹丝不动", font=F_H1, fill=(248, 250, 252, 255))
        d.text((64, 162), "支持双击单个修饰键（⇧ / ⌃ / ⌥ / ⌘）呼出，盲打筛选后按 Enter 0ms 顺手直贴入框", font=F_SUB, fill=(164, 180, 210, 255))

        # 左侧：保持绿色聚焦环与下拉建议框的桌面应用窗口
        draw_app_window(canvas, 64, 214, 720, 620, "即时协作搜索 — 原窗口始终保持键盘焦点", "FOCUS LOCKED")
        d = SmartDraw(canvas)
        # 聚焦态搜索输入框（翠绿焦点外环全程不消失！）
        d.rounded_rectangle((96, 282, 750, 342), radius=14, fill=(26, 35, 52, 255), outline=(16, 185, 129, 255), width=3)
        pasted = t >= 3.70
        if not pasted:
            cursor_on = (int(t * 3.0) % 2) == 0
            inp_txt = "正在查找：" + ("|" if cursor_on else "")
            d.text((120, 300), inp_txt, font=F_BODY_B, fill=(226, 236, 252, 255))
        else:
            flash = clamp(1.0 - (t - 3.70) / 0.6)
            if flash > 0:
                d.rounded_rectangle((98, 284, 748, 340), radius=13, fill=(16, 185, 129, int(55 * flash)))
            d.text((120, 300), "季度产品复盘纪要与关键里程碑", font=F_BODY_B, fill=(94, 234, 212, 255))
            d.text((586, 302), "✓ 0ms 已直贴", font=font_cjk(15, True), fill=(16, 185, 129, 255))

        # 下拉搜索弹层（重点证明：呼出剪贴板时弹层绝不失焦收起！）
        d.rounded_rectangle((96, 354, 620, 688), radius=14, fill=(29, 37, 56, 255), outline=(64, 80, 112, 255), width=1)
        d.text((120, 374), "实时关联建议（呼出 iClip 时保持展开不收起）", font=font_cjk(14, True), fill=(94, 234, 212, 255))
        items = [
            "最近检索 · 产品体验走查清单",
            "最近检索 · 双端液态玻璃视觉规范",
            "最近检索 · 零信任本地加密白皮书",
            "团队共享 · 季度里程碑评审归档",
        ]
        for idx, it in enumerate(items):
            iy = 414 + idx * 60
            d.rounded_rectangle((116, iy, 600, iy + 46), radius=10, fill=(38, 47, 68, 255))
            d.text((136, iy + 13), it, font=font_cjk(15), fill=(214, 224, 244, 255))

        d.rounded_rectangle((96, 720, 750, 796), radius=12, fill=(22, 48, 44, 230), outline=(16, 185, 129, 180), width=1)
        d.text((120, 736), "✓ 非抢占焦点悬浮引擎：macOS NSPanel 零失焦 + Windows WS_EX_NOACTIVATE", font=font_cjk(15, True), fill=(110, 231, 183, 255))
        d.text((120, 764), "告别「点开搜索框 → 呼出剪贴板 → 弹层瞬间消失重来」的日常挫败感", font=font_cjk(14), fill=(186, 216, 206, 255))

        # 右侧：双击 Shift 呼出 macOS 面板，随后同框展示 Win11 同步面板
        if t >= 1.15:
            paste_sprite_animated(canvas, assets.s1_mac, 820, 198, (t - 1.15) / 0.45)
        if t >= 4.40:
            paste_sprite_animated(canvas, assets.s1_win, 1336, 388, (t - 4.40) / 0.50)

        d = SmartDraw(canvas)
        if 0.95 <= t <= 2.15:
            draw_key_hud(d, "双击 ⇧ Shift · 零失焦呼出", (t - 0.95) / 1.20)
        elif 3.45 <= t <= 4.35:
            draw_key_hud(d, "按 Enter · 0ms 顺手直贴入框", (t - 3.45) / 0.90)

    # ==================== 第 2 幕 (7.5 - 15.0s)：零信任隐私护盾 ====================
    elif t < 15.0:
        lt = t - 7.5
        d.text((64, 108), "零信任隐形隐私护盾：防肩窥、防泄密、防投屏尴尬", font=F_H1, fill=(248, 250, 252, 255))
        d.text((64, 162), "全库硬件级加密存储 · 双向 AI 替身沙盒 · 共享屏幕自动隐身 · ⌘B 粘贴 5 秒即焚", font=F_SUB, fill=(164, 180, 210, 255))

        paste_sprite_animated(canvas, assets.s2_shield, 54, 204, lt / 0.45)

        # 右上：双向 AI 替身沙盒对话窗口
        draw_app_window(canvas, 636, 214, 1220, 344, "大模型助手对话 — 双向隐私替身沙盒", "PRIVACY TWIN")
        d = SmartDraw(canvas)
        swapped = lt >= 2.10
        d.text((668, 278), "向 AI 提问发送内容：", font=font_cjk(15, True), fill=(164, 180, 210, 255))
        if not swapped:
            d.rounded_rectangle((668, 310, 1820, 378), radius=12, fill=(58, 34, 38, 255), outline=(239, 68, 68, 255), width=1)
            d.text((692, 332), "请排查连接异常：凭证 [高敏密钥已拦截，按 ⇧↵ 转为安全替身发送]", font=F_BODY_B, fill=(252, 165, 165, 255))
        else:
            d.rounded_rectangle((668, 310, 1820, 378), radius=12, fill=(22, 48, 44, 255), outline=(16, 185, 129, 255), width=1)
            d.text((692, 332), "请排查连接异常：凭证 key=[ICLIP_KEY_1]  host=[ICLIP_HOST_1]   ✓ 真值零外泄", font=F_BODY_B, fill=(110, 231, 183, 255))

        if lt >= 3.20:
            p_back = ease_out_expo((lt - 3.20) / 0.5)
            d.rounded_rectangle((668, 398, 1820, 532), radius=12, fill=(28, 37, 58, int(255 * p_back)), outline=(59, 130, 246, int(220 * p_back)), width=1)
            d.text((692, 418), "AI 返回修复代码后 → 一键无损回填本地真值（支持记忆会话映射，云端零留存）", font=font_cjk(16, True), fill=(147, 197, 253, int(255 * p_back)))
            d.text((692, 456), "连接池超时已修正：connect(key=本地真实密钥已自动还原, timeout_ms=3000)", font=F_MONO, fill=(236, 242, 255, int(255 * p_back)))
            d.text((692, 492), "✓ 全程无需手改任何配置，既享 AI 排障效率，又守住核心机密底线", font=font_cjk(14), fill=(164, 180, 210, int(255 * p_back)))

        # 右下双卡：投屏自动隐身 + 粘贴即焚倒计时
        if lt >= 4.30:
            p_cards = ease_out_expo((lt - 4.30) / 0.5)
            # 卡1：投屏光学隐身
            d.rounded_rectangle((636, 582, 1214, 834), radius=16, fill=(22, 28, 42, int(250 * p_cards)), outline=(64, 80, 112, int(255 * p_cards)), width=1)
            d.rounded_rectangle((664, 608, 846, 642), radius=17, fill=(37, 99, 235, int(255 * p_cards)))
            d.text((682, 615), "共享屏幕自动隐身", font=font_cjk(14, True), fill=(255, 255, 255, int(255 * p_cards)))
            d.text((664, 664), "开启在线会议屏幕共享时：", font=F_BODY_B, fill=(244, 247, 254, int(255 * p_cards)))
            d.text((664, 702), "• 自己屏幕正常查看与搜索剪贴板", font=font_cjk(16), fill=(182, 196, 224, int(255 * p_cards)))
            d.text((664, 738), "• 参会者投屏与录屏画面中完全透明不可见", font=font_cjk(16), fill=(94, 234, 212, int(255 * p_cards)))
            d.text((664, 778), "• 敏感截图支持 0.2s 离线文字识别自动打码", font=font_cjk(15), fill=(154, 168, 196, int(255 * p_cards)))

            # 卡2：粘贴即焚
            remain = max(0.0, 5.0 - max(0.0, lt - 4.6) * 1.8)
            d.rounded_rectangle((1242, 582, 1856, 834), radius=16, fill=(22, 28, 42, int(250 * p_cards)), outline=(217, 119, 6, int(255 * p_cards)), width=1)
            d.rounded_rectangle((1270, 608, 1460, 642), radius=17, fill=(217, 119, 6, int(255 * p_cards)))
            d.text((1288, 615), "⌘B 粘贴 5 秒即焚", font=font_cjk(14, True), fill=(255, 255, 255, int(255 * p_cards)))
            d.text((1270, 664), "一次性密码与临时验证码：", font=F_BODY_B, fill=(244, 247, 254, int(255 * p_cards)))
            bar_w = int(530 * (remain / 5.0))
            d.rounded_rectangle((1270, 710, 1800, 734), radius=12, fill=(38, 46, 66, int(255 * p_cards)))
            if bar_w > 12:
                d.rounded_rectangle((1270, 710, 1270 + bar_w, 734), radius=12, fill=(245, 158, 11, int(255 * p_cards)))
            status_txt = f"贴后自动销毁倒计时：{remain:0.1f}s" if remain > 0.1 else "✓ 已连同系统剪贴板与历史记录彻底无痕擦除"
            d.text((1270, 756), status_txt, font=font_cjk(16, True), fill=(253, 224, 71 if remain > 0.1 else 167, int(255 * p_cards)))
            d.text((1270, 792), "支持 @pw 20 一键生成硬件级高熵强密码", font=font_cjk(14), fill=(154, 168, 196, int(255 * p_cards)))

        if 1.85 <= lt <= 2.85:
            draw_key_hud(d, "按 ⇧↵ · 一键替身脱敏粘贴", (lt - 1.85) / 1.0)

    # ==================== 第 3 幕 (15.0 - 22.5s)：去 Markdown 纯文本 + 表格自动分列 ====================
    elif t < 22.5:
        lt = t - 15.0
        d.text((64, 108), "AI 办公净文利器：一键去 Markdown 符号 + 表格直粘分列", font=F_H1, fill=(248, 250, 252, 255))
        d.text((64, 162), "告别手动删星号井号，告别表格粘进单元格挤成一团", font=F_SUB, fill=(164, 180, 210, 255))

        paste_sprite_animated(canvas, assets.s3_md, 54, 204, lt / 0.45)

        # 中上：去 Markdown 前后对比窗口
        draw_app_window(canvas, 636, 214, 1220, 300, "正式汇报文档 — 一键剥离 Markdown 格式噪音", "CLEAN TEXT")
        d = SmartDraw(canvas)
        cleaned = lt >= 2.35
        if not cleaned:
            d.text((668, 276), "原始复制内容（满屏标记符号干扰阅读）：", font=font_cjk(15, True), fill=(248, 113, 113, 255))
            raw_lines = [
                "### 一、季度经营复盘结论",
                "- **核心转化率**较上月稳步提升 `42.8%`，达成阶段目标；",
                "- 重点推进 [双端统一交互](doc) 与 **零失焦粘贴** 体验升级。",
            ]
            for idx, ln in enumerate(raw_lines):
                d.text((668, 316 + idx * 42), ln, font=F_MONO, fill=(198, 210, 232, 255))
        else:
            d.text((668, 276), "✓ 已执行「去 Markdown 纯文本」直贴（保留清晰段落，符号清零）：", font=font_cjk(15, True), fill=(52, 211, 153, 255))
            clean_lines = [
                "一、季度经营复盘结论",
                "• 核心转化率较上月稳步提升 42.8%，达成阶段目标；",
                "• 重点推进双端统一交互与零失焦粘贴体验升级。",
            ]
            for idx, ln in enumerate(clean_lines):
                d.text((668, 316 + idx * 42), ln, font=F_BODY_B, fill=(244, 248, 255, 255))

        # 下方：电子表格自动分列窗口
        draw_app_window(canvas, 636, 536, 1220, 304, "电子表格 — 原生 CF_HTML 双协议自动整齐分列", "AUTO COLUMNS", is_windows=True)
        d = SmartDraw(canvas)
        table_in = lt >= 4.60
        cols_x = [668, 940, 1240, 1540, 1816]
        headers = ["模块名称", "响应耗时", "内存占用", "双端状态"]
        rows_data = [
            ["零失焦直贴引擎", "0.2 ms", "极低常驻", "✓ 已同步上线"],
            ["零信任加密沙盒", "0.4 ms", "硬件加速", "✓ 已同步上线"],
            ["净文与表格桥接", "0.3 ms", "按需唤醒", "✓ 已同步上线"],
        ]
        # 表头
        d.rectangle((cols_x[0], 598, cols_x[-1], 642), fill=(32, 42, 64, 255))
        for ci in range(4):
            d.text((cols_x[ci] + 18, 609), headers[ci], font=font_cjk(15, True), fill=(164, 186, 226, 255))
        for ri in range(3):
            ry = 642 + ri * 54
            if table_in:
                d.rectangle((cols_x[0], ry, cols_x[-1], ry + 54), fill=(22, 42, 46, 210) if ri % 2 == 0 else (20, 34, 44, 210))
                for ci in range(4):
                    col_fg = (94, 234, 212, 255) if ci == 3 else (238, 244, 255, 255)
                    d.text((cols_x[ci] + 18, ry + 15), rows_data[ri][ci], font=font_cjk(15, ci == 3), fill=col_fg)
            elif ri == 0:
                d.text((cols_x[0] + 18, ry + 15), "等待粘贴竖线表格（告别挤在首个单元格）...", font=font_cjk(15), fill=(134, 150, 180, 255))
        # 网格线
        for cx in cols_x:
            d.line((cx, 598, cx, 804), fill=(54, 68, 96, 255), width=1)
        for rline in [598, 642, 696, 750, 804]:
            d.line((cols_x[0], rline, cols_x[-1], rline), fill=(54, 68, 96, 255), width=1)

        if 2.05 <= lt <= 3.05:
            draw_key_hud(d, "⇧↵ 去 Markdown 纯文本", (lt - 2.05) / 1.0)
        elif 4.35 <= lt <= 5.25:
            draw_key_hud(d, "⇧↵ 直粘表格自动分列", (lt - 4.35) / 0.90)

    # ==================== 第 4 幕 (22.5 - 29.5s)：剪贴即待办 + 智能算账 + 收件名片连填 ====================
    elif t < 29.5:
        lt = t - 22.5
        d.text((64, 108), "剪贴即待办、秒算含税大写与收件信息一键拆解", font=F_H1, fill=(248, 250, 252, 255))
        d.text((64, 162), "把复制过的碎片消息顺手变成行动清单，日常算账填表一步到位", font=F_SUB, fill=(164, 180, 210, 255))

        paste_sprite_animated(canvas, assets.s4_todo, 54, 204, lt / 0.45)

        # 右上：剪贴即待办勾选交互
        draw_app_window(canvas, 636, 214, 1220, 292, "剪贴即待办 — ⌘T / Ctrl+T 一键收件，勾选自动沉底", "TODO FLOW")
        d = SmartDraw(canvas)
        done_first = lt >= 2.0
        todos = [
            ("确认 v2.7 双端液态玻璃新手引导交互走查", done_first),
            ("核对季度采购合同含税总价与会计大写金额", True),
            ("导出本周已完成事项清单归档", False),
        ]
        ordered = sorted(todos, key=lambda x: x[1])
        for idx, (td_txt, is_done) in enumerate(ordered):
            ty = 278 + idx * 66
            bg_c = (24, 32, 46, 255) if is_done else (32, 44, 68, 255)
            d.rounded_rectangle((668, ty, 1820, ty + 52), radius=12, fill=bg_c, outline=(56, 72, 104, 255), width=1)
            if is_done:
                d.ellipse((688, ty + 14, 712, ty + 38), fill=(16, 185, 129, 255))
                d.text((694, ty + 15), "✓", font=font_cjk(15, True), fill=(6, 42, 30, 255))
                d.text((730, ty + 15), td_txt + "  （已完成并自动沉底）", font=font_cjk(16), fill=(134, 152, 182, 255))
            else:
                d.ellipse((688, ty + 14, 712, ty + 38), outline=(96, 165, 250, 255), width=2)
                d.text((730, ty + 15), td_txt, font=font_cjk(16, True), fill=(244, 248, 255, 255))

        # 右下：智能财务算账 + 收件名片拆解
        draw_app_window(canvas, 636, 532, 1220, 308, "搜索框直算财务大写 & 混排收件地址智能分拆", "SMART EXTRACT")
        d = SmartDraw(canvas)
        d.rounded_rectangle((668, 596, 1226, 810), radius=14, fill=(25, 34, 52, 255), outline=(59, 130, 246, 180), width=1)
        d.text((692, 616), "实时表达式与多行账单求和", font=font_cjk(15, True), fill=(147, 197, 253, 255))
        d.text((692, 658), "输入：12800 * 1.13", font=F_MONO, fill=(224, 234, 252, 255))
        d.text((692, 698), "= 14,464.00", font=font_cjk(26, True), fill=(94, 234, 212, 255))
        d.text((692, 744), "大写：壹万肆仟肆佰陆拾肆元整", font=font_cjk(16, True), fill=(248, 250, 255, 255))
        d.text((692, 776), "十进制零浮点误差 · 回车即贴", font=font_cjk(13), fill=(154, 168, 196, 255))

        d.rounded_rectangle((1254, 596, 1820, 810), radius=14, fill=(25, 34, 52, 255), outline=(16, 185, 129, 180), width=1)
        d.text((1278, 616), "混排收件信息自动净提连填", font=font_cjk(15, True), fill=(110, 231, 183, 255))
        d.text((1278, 656), "原文：「寄给陈明 浦东新区张江高科科苑路办公楼」", font=font_cjk(14), fill=(186, 198, 224, 255))
        pills = [("姓名：陈明", 1278), ("地区：浦东新区", 1430), ("详细地址一键贴", 1608)]
        for p_txt, px in pills:
            pw_i = int(d.textlength(p_txt, font=font_cjk(14, True))) + 26
            d.rounded_rectangle((px, 706, px + pw_i, 744), radius=19, fill=(16, 185, 129, 255))
            d.text((px + 13, 715), p_txt, font=font_cjk(14, True), fill=(5, 42, 30, 255))
        d.text((1278, 768), "配合 ⌃⌥V / Ctrl+Alt+V 免开面板自动跳格连填整张表单", font=font_cjk(13), fill=(154, 168, 196, 255))

        if 1.75 <= lt <= 2.75:
            draw_key_hud(d, "⌘T 转待办 · 点击圆圈完成沉底", (lt - 1.75) / 1.0)

    # ==================== 第 5 幕 (29.5 - 36.0s)：v2.7 新手引导 + ⌘E 极简模式 + 正式落版 ====================
    else:
        lt = t - 29.5
        d.text((64, 108), "焕新 v2.7 引导，保留一键回归纯粹的克制", font=F_H1, fill=(248, 250, 252, 255))
        d.text((64, 162), "随时在设置中重温新功能引导 · 按 ⌘E / Ctrl+E 一键收起全部进阶胶囊", font=F_SUB, fill=(164, 180, 210, 255))

        # 左侧：全新 v2.7 新手引导浮层
        paste_sprite_animated(canvas, assets.highlights, 62, 206, lt / 0.45)

        # 中间：⌘E 极简纯净面板
        if lt >= 0.6:
            paste_sprite_animated(canvas, assets.s5_min, 650, 214, (lt - 0.6) / 0.45)

        # 右侧：v2.7 正式版发布落版卡
        d = SmartDraw(canvas)
        rx, ry, rw, rh = 1236, 228, 620, 424
        d.rounded_rectangle((rx, ry, rx + rw, ry + rh), radius=22, fill=(22, 28, 42, 245), outline=(74, 96, 138, 255), width=1)
        d.rounded_rectangle((rx + 32, ry + 30, rx + 252, ry + 66), radius=18, fill=(37, 99, 235, 255))
        d.text((rx + 50, ry + 38), "iClip v2.7 正式发布", font=font_cjk(16, True), fill=(255, 255, 255, 255))

        d.text((rx + 32, ry + 88), "轻如无物，越用越顺手", font=font_cjk(36, True), fill=(248, 250, 255, 255))
        summary_pts = [
            "✓ 唤醒零失焦直贴 + 单键双击极速呼出",
            "✓ 零信任本地加密 + AI 替身沙盒 + 投屏隐身",
            "✓ 一键去 Markdown 纯文本 + 表格直粘分列",
            "✓ 剪贴即待办 + 跨软件一键无损搬家导入",
        ]
        for idx, pt in enumerate(summary_pts):
            d.text((rx + 32, ry + 156 + idx * 42), pt, font=font_cjk(17, True), fill=(198, 214, 242, 255))

        d.rounded_rectangle((rx + 32, ry + 336, rx + rw - 32, ry + 394), radius=14, fill=(32, 43, 66, 255), outline=(64, 86, 126, 255), width=1)
        if assets.clean_xhs:
            d.text((rx + 54, ry + 354), "macOS 液态玻璃 + Windows 11 原生版同步升级", font=font_cjk(17, True), fill=(94, 234, 212, 255))
        else:
            d.text((rx + 54, ry + 354), "开源与下载：github.com/fanaruto/iClip", font=font_cjk(17, True), fill=(94, 234, 212, 255))

        if 2.60 <= lt <= 3.60:
            draw_key_hud(d, "按 ⌘E / Ctrl+E · 秒切极简纯净模式", (lt - 2.60) / 1.0)

    # ==================== 底部字幕胶囊 ====================
    for cs, ce, cap in assets.captions:
        if cs <= t < ce:
            cw = int(d.textlength(cap, font=F_CAP)) + 64
            bx = (W - cw) // 2
            by = H - 84
            d.rounded_rectangle((bx, by, bx + cw, by + 52), radius=26, fill=(13, 17, 27, 242), outline=(66, 82, 112, 255), width=1)
            d.text((bx + 32, by + 12), cap, font=F_CAP, fill=(248, 250, 252, 255))
            break

    return canvas.convert("RGB")


def generate_covers(general_assets: SceneAssets, xhs_assets: SceneAssets, covers_dir: str, web_poster_webp: str):
    os.makedirs(covers_dir, exist_ok=True)
    # 1. 16:9 封面 (取第 1 幕双端面板 + 聚焦搜索框同框高潮帧 f=310, t=5.16s)
    c16x9 = render_frame(general_assets, 310)
    jpg_16x9 = os.path.join(covers_dir, "cover-16x9.jpg")
    c16x9.save(jpg_16x9, quality=95)
    if web_poster_webp:
        os.makedirs(os.path.dirname(web_poster_webp), exist_ok=True)
        c16x9.save(web_poster_webp, format="WEBP", quality=90)

    # 2. 4:3 横版封面 (1440x1080，B站/抖音/视频号横版)
    c4x3 = Image.new("RGBA", (1440, 1080), (11, 14, 21, 255))
    glow = Image.new("RGBA", (1440, 1080), (0, 0, 0, 0))
    SmartDraw(glow).ellipse((80, -60, 880, 560), fill=(47, 104, 230, 48))
    SmartDraw(glow).ellipse((760, 420, 1420, 1060), fill=(16, 185, 129, 36))
    c4x3 = Image.alpha_composite(c4x3, glow.filter(ImageFilter.GaussianBlur(100)))
    d4 = SmartDraw(c4x3)
    d4.rounded_rectangle((68, 66, 396, 118), radius=26, fill=(37, 99, 235, 255))
    d4.text((94, 79), "iClip v2.7 双端大更新", font=font_cjk(23, True), fill=(255, 255, 255, 255))
    d4.text((68, 146), "唤醒零失焦直贴 · 零信任隐私护盾", font=font_cjk(52, True), fill=(248, 250, 255, 255))
    d4.text((68, 228), "一键去 Markdown 符号 · 剪贴即待办 · 表格直粘分列 · Mac & Win 原生", font=font_cjk(24), fill=(168, 184, 214, 255))
    c4x3.alpha_composite(general_assets.s1_mac, (56, 304))
    c4x3.alpha_composite(general_assets.highlights, (748, 296))
    c4x3.convert("RGB").save(os.path.join(covers_dir, "cover-4x3.png"))

    # 3. 3:4 通用竖版封面 (1080x1440)
    def build_vertical_cover(is_xhs: bool) -> Image.Image:
        cv = Image.new("RGBA", (1080, 1440), (11, 14, 21, 255))
        gl = Image.new("RGBA", (1080, 1440), (0, 0, 0, 0))
        SmartDraw(gl).ellipse((60, -40, 820, 620), fill=(47, 104, 230, 50))
        SmartDraw(gl).ellipse((340, 740, 1060, 1400), fill=(16, 185, 129, 38))
        cv = Image.alpha_composite(cv, gl.filter(ImageFilter.GaussianBlur(105)))
        dv = SmartDraw(cv)
        pill_txt = "双端纯原生 · 2.7 正式版" if is_xhs else "免费开源 · iClip 2.7 正式版"
        pw_t = int(dv.textlength(pill_txt, font=font_cjk(24, True))) + 56
        dv.rounded_rectangle((64, 78, 64 + pw_t, 134), radius=28, fill=(37, 99, 235, 255))
        dv.text((92, 92), pill_txt, font=font_cjk(24, True), fill=(255, 255, 255, 255))
        dv.text((64, 168), "搜索框呼出再也不失焦", font=font_cjk(56, True), fill=(248, 250, 255, 255))
        dv.text((64, 252), "零信任隐私护盾 · 剪贴即待办", font=font_cjk(46, True), fill=(94, 234, 212, 255))
        dv.text((64, 334), "去 Markdown 纯文本 · 表格自动分列 · Mac & Win 同步", font=font_cjk(25), fill=(174, 190, 218, 255))
        src_assets = xhs_assets if is_xhs else general_assets
        cv.alpha_composite(src_assets.s1_mac, (44, 412))
        cv.alpha_composite(src_assets.highlights, (436, 864))
        return cv.convert("RGB")

    build_vertical_cover(False).save(os.path.join(covers_dir, "cover-3x4.png"))
    build_vertical_cover(True).save(os.path.join(covers_dir, "cover-3x4-xhs.png"))


def encode_video(assets: SceneAssets, audio_wav: str, out_mp4: str, label: str):
    t0 = time.time()
    os.makedirs(os.path.dirname(out_mp4), exist_ok=True)
    cmd = [
        "/opt/homebrew/bin/ffmpeg",
        "-y",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-s",
        f"{W}x{H}",
        "-r",
        str(FPS),
        "-i",
        "-",
        "-i",
        audio_wav,
        "-c:v",
        "libx264",
        "-preset",
        "medium",
        "-crf",
        "17",
        "-pix_fmt",
        "yuv420p",
        "-colorspace",
        "bt709",
        "-color_primaries",
        "bt709",
        "-color_trc",
        "bt709",
        "-c:a",
        "aac",
        "-b:a",
        "192k",
        "-shortest",
        "-movflags",
        "+faststart",
        out_mp4,
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdin is not None
    for f in range(TOTAL_FRAMES):
        rgb = render_frame(assets, f)
        proc.stdin.write(rgb.tobytes())
        if f > 0 and f % 720 == 0:
            print(f"[{label}] {f}/{TOTAL_FRAMES} frames ({time.time() - t0:.1f}s)", flush=True)
    proc.stdin.close()
    stderr_bytes = proc.stderr.read() if proc.stderr else b""
    rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"ffmpeg failed ({rc}): {stderr_bytes.decode('utf-8', 'ignore')[-600:]}")
    print(f"[{label}] DONE in {time.time() - t0:.1f}s -> {out_mp4}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--maitian-dir", default="/Users/fanaruto/maitian/videos/超级个体/iClip-v27")
    parser.add_argument("--web-video", default="/Users/fanaruto/Project/Personal/webfooo-apps/.artifacts-cache/iClip/iclip-v27-whatsnew-1080p60.mp4")
    parser.add_argument("--web-poster", default="/Users/fanaruto/Project/Personal/webfooo-apps/public/iClip/media/poster-v27-whatsnew.webp")
    parser.add_argument("--scratch-dir", default="/tmp/iclip-v27-video-build")
    args = parser.parse_args()

    os.makedirs(args.scratch_dir, exist_ok=True)
    os.makedirs(args.maitian_dir, exist_ok=True)
    raw_wav = os.path.join(args.scratch_dir, "raw.wav")
    norm_wav = os.path.join(args.scratch_dir, "audio_norm.wav")

    print("1/4 Synthesizing & normalizing stereo soundtrack (-16 LUFS)...", flush=True)
    synthesize_soundtrack(raw_wav, norm_wav)

    print("2/4 Building scene sprites & 4-aspect covers...", flush=True)
    general_assets = SceneAssets(clean_xhs=False)
    xhs_assets = SceneAssets(clean_xhs=True)
    covers_dir = os.path.join(args.maitian_dir, "封面")
    generate_covers(general_assets, xhs_assets, covers_dir, args.web_poster)

    main_mp4 = os.path.join(args.maitian_dir, "成片.mp4")
    xhs_mp4 = os.path.join(args.maitian_dir, "成片-xhs.mp4")

    print("3/4 Rendering general 1080p60 showcase video...", flush=True)
    encode_video(general_assets, norm_wav, main_mp4, "GENERAL")

    if args.web_video:
        os.makedirs(os.path.dirname(args.web_video), exist_ok=True)
        subprocess.run(["cp", main_mp4, args.web_video], check=True)

    print("4/4 Rendering Xiaohongshu zero-link / zero-competitor pure video...", flush=True)
    encode_video(xhs_assets, norm_wav, xhs_mp4, "XHS_CLEAN")


if __name__ == "__main__":
    main()
