use crate::model::{ClipContentType, ClipItem, PinCategory};
use crate::store::GlassAppearance;

/// RGBA 颜色（底层写入 Win32 32-bit DIB 时自动转为 Porter-Duff 预乘 0xAARRGGBB 小端 BGRA）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Color4 {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Color4 {
    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }

    pub const fn rgba(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }

    pub const fn with_alpha(self, a: u8) -> Self {
        Self {
            r: self.r,
            g: self.g,
            b: self.b,
            a,
        }
    }

    /// 转换为 Win32 GDI `COLORREF` (`0x00BBGGRR`)
    pub const fn to_colorref(self) -> u32 {
        (self.r as u32) | ((self.g as u32) << 8) | ((self.b as u32) << 16)
    }

    pub fn lerp(self, other: Self, t: f32) -> Self {
        let t = t.clamp(0.0, 1.0);
        let inv = 1.0 - t;
        Self {
            r: (self.r as f32 * inv + other.r as f32 * t).round() as u8,
            g: (self.g as f32 * inv + other.g as f32 * t).round() as u8,
            b: (self.b as f32 * inv + other.b as f32 * t).round() as u8,
            a: (self.a as f32 * inv + other.a as f32 * t).round() as u8,
        }
    }
}

/// 1:1 移植自 macOS `LiquidGlassSurface.swift` 的浅色冰晶 / 深色冷曜石双模语义表面色板
#[derive(Debug, Clone, Copy)]
pub struct GlassPalette {
    pub is_dark: bool,
    pub window_bg: Color4,
    pub window_border: Color4,
    pub track_bg: Color4,
    pub track_border: Color4,
    pub active_segment_fill: Color4,
    pub active_segment_shadow: Color4,
    pub search_bg: Color4,
    pub search_border: Color4,
    pub group_fill: Color4,
    pub group_stroke: Color4,
    pub nested_fill: Color4,
    pub divider: Color4,
    pub footer_backdrop: Color4,
    pub card_bg: Color4,
    pub card_hover_bg: Color4,
    pub card_pinned_top: Color4,
    pub card_pinned_bottom: Color4,
    pub card_pinned_hover_top: Color4,
    pub card_pinned_hover_bottom: Color4,
    pub card_pinned_bg: Color4,
    pub card_pinned_hover_bg: Color4,
    pub card_border: Color4,
    pub card_hover_border: Color4,
    pub card_pinned_border: Color4,
    pub chip_bg: Color4,
    pub chip_hover_bg: Color4,
    pub select_top: Color4,
    pub select_bottom: Color4,
    pub select_border: Color4,
    pub select_shadow: Color4,
    pub select_indicator: Color4,
    pub glass_top_highlight: Color4,
    pub cobalt: Color4,
    pub cobalt_deep: Color4,
    pub cobalt_text: Color4,
    pub emerald: Color4,
    pub amber: Color4,
    pub danger: Color4,
    pub text_primary: Color4,
    pub text_secondary: Color4,
    pub text_muted: Color4,
}

impl GlassPalette {
    pub fn for_appearance(appearance: GlassAppearance) -> Self {
        let pct = match appearance {
            GlassAppearance::Clear => 15,
            GlassAppearance::Tinted => 38,
            GlassAppearance::Solid => 95,
        };
        Self::for_macos_liquid_glass(true, pct)
    }

    pub fn for_blur_concentration(pct: u8) -> Self {
        Self::for_macos_liquid_glass(true, pct)
    }

    /// 严格复刻 macOS `LiquidGlassPalette` 浅色/深色与背景模糊浓度（0%..=100%）光学参数
    pub fn for_macos_liquid_glass(is_dark: bool, pct: u8) -> Self {
        let t = (pct.min(100) as f32) / 100.0;

        if is_dark {
            // 深色冷曜石分层液态玻璃（打破死黑灰线框：清晰 3 级明度阶梯 + 顶亮镜面高光 + 提亮可读钴蓝）
            let win_a = (158.0 + t * 94.0).round() as u8;
            let card_a = (148.0 + t * 76.0).round() as u8;
            let hover_a = (182.0 + t * 56.0).round() as u8;
            let ctrl_a = (156.0 + t * 68.0).round() as u8;
            let group_a = (164.0 + t * 66.0).round() as u8;

            // 收藏卡片不再染成浑浊黄块，仅在深曜石玻璃基底融入克制暖金微光
            let pin_top = Color4::rgba(42, 39, 34, (158.0 + t * 66.0).round() as u8);
            let pin_bot = Color4::rgba(33, 34, 41, (152.0 + t * 68.0).round() as u8);
            let pin_h_top = Color4::rgba(52, 48, 41, (186.0 + t * 54.0).round() as u8);
            let pin_h_bot = Color4::rgba(42, 43, 52, (178.0 + t * 56.0).round() as u8);

            Self {
                is_dark: true,
                window_bg: Color4::rgba(16, 19, 27, win_a),
                window_border: Color4::rgba(226, 232, 240, 34),
                track_bg: Color4::rgba(26, 31, 42, ctrl_a),
                track_border: Color4::rgba(226, 232, 240, 26),
                active_segment_fill: Color4::rgba(255, 255, 255, 38),
                active_segment_shadow: Color4::rgba(0, 0, 0, 56),
                search_bg: Color4::rgba(28, 33, 45, ctrl_a),
                search_border: Color4::rgba(226, 232, 240, 30),
                group_fill: Color4::rgba(29, 34, 46, group_a),
                group_stroke: Color4::rgba(226, 232, 240, 24),
                nested_fill: Color4::rgba(255, 255, 255, 16),
                divider: Color4::rgba(226, 232, 240, 20),
                footer_backdrop: Color4::rgba(22, 26, 36, (154.0 + t * 76.0).round() as u8),
                card_bg: Color4::rgba(31, 36, 48, card_a),
                card_hover_bg: Color4::rgba(42, 49, 64, hover_a),
                card_pinned_top: pin_top,
                card_pinned_bottom: pin_bot,
                card_pinned_hover_top: pin_h_top,
                card_pinned_hover_bottom: pin_h_bot,
                card_pinned_bg: pin_top,
                card_pinned_hover_bg: pin_h_top,
                card_border: Color4::rgba(226, 232, 240, 20),
                card_hover_border: Color4::rgba(226, 232, 240, 52),
                card_pinned_border: Color4::rgba(251, 191, 36, 86),
                chip_bg: Color4::rgba(226, 232, 240, 20),
                chip_hover_bg: Color4::rgba(226, 232, 240, 34),
                select_top: Color4::rgba(46, 116, 255, 58),
                select_bottom: Color4::rgba(30, 92, 224, 38),
                select_border: Color4::rgba(120, 182, 255, 116),
                select_shadow: Color4::rgba(0, 0, 0, 42),
                select_indicator: Color4::rgb(96, 165, 250),
                glass_top_highlight: Color4::rgba(255, 255, 255, 42),
                cobalt: Color4::rgb(46, 118, 255),
                cobalt_deep: Color4::rgb(28, 92, 232),
                cobalt_text: Color4::rgb(112, 178, 255),
                emerald: Color4::rgb(52, 211, 153),
                amber: Color4::rgb(251, 191, 36),
                danger: Color4::rgb(248, 113, 113),
                text_primary: Color4::rgb(241, 245, 249),
                text_secondary: Color4::rgba(203, 213, 225, 150),
                text_muted: Color4::rgba(148, 163, 184, 138),
            }
        } else {
            // 浅色冰晶瓷白液态玻璃（冷调中性基底 + 轻透冰蓝选中层 + 纯净暖金星标点缀）
            let win_a = (176.0 + t * 76.0).round() as u8;
            let card_a = (204.0 + t * 48.0).round() as u8;
            let hover_a = (232.0 + t * 22.0).round() as u8;
            let ctrl_a = (188.0 + t * 60.0).round() as u8;
            let group_a = (208.0 + t * 44.0).round() as u8;

            // 收藏卡保持瓷白通透底色，仅带极克制 5% 暖琥珀微光，彻底告别发黄便利贴感
            let pin_top = Color4::rgba(255, 252, 244, (214.0 + t * 38.0).round() as u8);
            let pin_bot = Color4::rgba(255, 254, 250, (210.0 + t * 40.0).round() as u8);
            let pin_h_top = Color4::rgba(255, 249, 236, 246);
            let pin_h_bot = Color4::rgba(255, 253, 246, 246);

            Self {
                is_dark: false,
                window_bg: Color4::rgba(243, 246, 251, win_a),
                window_border: Color4::rgba(15, 23, 42, 22),
                track_bg: Color4::rgba(226, 232, 242, ctrl_a),
                track_border: Color4::rgba(15, 23, 42, 14),
                active_segment_fill: Color4::rgba(255, 255, 255, 252),
                active_segment_shadow: Color4::rgba(15, 23, 42, 18),
                search_bg: Color4::rgba(255, 255, 255, ctrl_a),
                search_border: Color4::rgba(15, 23, 42, 20),
                group_fill: Color4::rgba(255, 255, 255, group_a),
                group_stroke: Color4::rgba(15, 23, 42, 16),
                nested_fill: Color4::rgba(15, 23, 42, 10),
                divider: Color4::rgba(15, 23, 42, 16),
                footer_backdrop: Color4::rgba(255, 255, 255, (186.0 + t * 62.0).round() as u8),
                card_bg: Color4::rgba(255, 255, 255, card_a),
                card_hover_bg: Color4::rgba(255, 255, 255, hover_a),
                card_pinned_top: pin_top,
                card_pinned_bottom: pin_bot,
                card_pinned_hover_top: pin_h_top,
                card_pinned_hover_bottom: pin_h_bot,
                card_pinned_bg: pin_top,
                card_pinned_hover_bg: pin_h_top,
                card_border: Color4::rgba(15, 23, 42, 15),
                card_hover_border: Color4::rgba(30, 94, 255, 54),
                card_pinned_border: Color4::rgba(245, 158, 11, 78),
                chip_bg: Color4::rgba(15, 23, 42, 12),
                chip_hover_bg: Color4::rgba(15, 23, 42, 21),
                select_top: Color4::rgba(30, 94, 255, 25),
                select_bottom: Color4::rgba(30, 94, 255, 13),
                select_border: Color4::rgba(30, 94, 255, 86),
                select_shadow: Color4::rgba(15, 23, 42, 14),
                select_indicator: Color4::rgb(30, 94, 255),
                glass_top_highlight: Color4::rgba(255, 255, 255, 165),
                cobalt: Color4::rgb(30, 94, 255),
                cobalt_deep: Color4::rgb(21, 73, 214),
                cobalt_text: Color4::rgb(21, 73, 214),
                emerald: Color4::rgb(16, 185, 129),
                amber: Color4::rgb(217, 119, 6),
                danger: Color4::rgb(239, 68, 68),
                text_primary: Color4::rgb(15, 23, 42),
                text_secondary: Color4::rgba(51, 65, 85, 192),
                text_muted: Color4::rgba(100, 116, 139, 168),
            }
        }
    }

    pub fn pin_category_color(cat: PinCategory) -> Color4 {
        match cat {
            PinCategory::Reply => Color4::rgb(0, 122, 255),
            PinCategory::Invoice => Color4::rgb(245, 158, 11),
            PinCategory::Contact => Color4::rgb(52, 199, 89),
            PinCategory::Template => Color4::rgb(175, 82, 222),
        }
    }
}

/// 连续图片 3 列宫格与常规单列卡片统一布局行（与 macOS `ClipDisplayRow` 同构）
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DisplayRow {
    StandardCard { vis_pos: usize, store_idx: usize },
    ImageGridRow { cells: Vec<(usize, usize)> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GridMoveDir {
    Up,
    Down,
    Left,
    Right,
}

pub fn build_display_rows(filtered_indices: &[usize], items: &[ClipItem]) -> Vec<DisplayRow> {
    build_display_rows_ext(filtered_indices, items, true)
}

pub fn build_display_rows_ext(
    filtered_indices: &[usize],
    items: &[ClipItem],
    collapse_images: bool,
) -> Vec<DisplayRow> {
    let mut rows = Vec::with_capacity(filtered_indices.len());
    let mut img_buf: Vec<(usize, usize)> = Vec::with_capacity(3);

    for (vis_pos, &store_idx) in filtered_indices.iter().enumerate() {
        let is_img = collapse_images
            && items
                .get(store_idx)
                .map(|it| it.kind == ClipContentType::Image)
                .unwrap_or(false);
        if is_img {
            img_buf.push((vis_pos, store_idx));
            if img_buf.len() == 3 {
                rows.push(DisplayRow::ImageGridRow {
                    cells: std::mem::take(&mut img_buf),
                });
            }
        } else {
            if !img_buf.is_empty() {
                rows.push(DisplayRow::ImageGridRow {
                    cells: std::mem::take(&mut img_buf),
                });
            }
            rows.push(DisplayRow::StandardCard { vis_pos, store_idx });
        }
    }
    if !img_buf.is_empty() {
        rows.push(DisplayRow::ImageGridRow { cells: img_buf });
    }
    rows
}

pub fn find_row_and_col(rows: &[DisplayRow], target_vis_pos: usize) -> Option<(usize, usize)> {
    for (r_idx, row) in rows.iter().enumerate() {
        match row {
            DisplayRow::StandardCard { vis_pos, .. } if *vis_pos == target_vis_pos => {
                return Some((r_idx, 0));
            }
            DisplayRow::ImageGridRow { cells } => {
                if let Some(c_idx) = cells.iter().position(|(vp, _)| *vp == target_vis_pos) {
                    return Some((r_idx, c_idx));
                }
            }
            _ => {}
        }
    }
    None
}

pub fn grid_move_selection(
    rows: &[DisplayRow],
    current_vis_pos: usize,
    total_filtered: usize,
    dir: GridMoveDir,
) -> usize {
    if rows.is_empty() || total_filtered == 0 {
        return 0;
    }
    let cur = current_vis_pos.min(total_filtered - 1);
    let Some((r_idx, c_idx)) = find_row_and_col(rows, cur) else {
        return 0;
    };

    match dir {
        GridMoveDir::Left => {
            if let DisplayRow::ImageGridRow { cells } = &rows[r_idx] {
                if c_idx > 0 {
                    return cells[c_idx - 1].0;
                }
            }
            cur
        }
        GridMoveDir::Right => {
            if let DisplayRow::ImageGridRow { cells } = &rows[r_idx] {
                if c_idx + 1 < cells.len() {
                    return cells[c_idx + 1].0;
                }
            }
            cur
        }
        GridMoveDir::Up => {
            if r_idx == 0 {
                return cur;
            }
            match &rows[r_idx - 1] {
                DisplayRow::StandardCard { vis_pos, .. } => *vis_pos,
                DisplayRow::ImageGridRow { cells } => cells[c_idx.min(cells.len() - 1)].0,
            }
        }
        GridMoveDir::Down => {
            if r_idx + 1 >= rows.len() {
                return cur;
            }
            match &rows[r_idx + 1] {
                DisplayRow::StandardCard { vis_pos, .. } => *vis_pos,
                DisplayRow::ImageGridRow { cells } => cells[c_idx.min(cells.len() - 1)].0,
            }
        }
    }
}

/// 零抖动卡片高度预算：高度仅取决于内容固有属性，切换选中/悬停 0.0px 零跳动
pub fn standard_card_height(has_chips: bool, scale: f32) -> i32 {
    let base = if has_chips { 86.0 } else { 62.0 };
    (base * scale).round() as i32
}

pub fn image_grid_row_height(scale: f32) -> i32 {
    (98.0 * scale).round() as i32
}

/// 跨平台 UI 单行文本像素宽度精确估算（区分 CJK 全角、大写、小写/数字、窄标点与键符，误差 <= 1pt）
pub fn estimate_text_px(text: &str, font_px: f32) -> i32 {
    let mut w = 0.0f32;
    for ch in text.chars() {
        let adv = if ch == ' ' {
            0.30
        } else if matches!(
            ch,
            '.' | ','
                | ':'
                | ';'
                | '!'
                | '|'
                | '\''
                | '`'
                | '/'
                | '\\'
                | '-'
                | '('
                | ')'
                | '['
                | ']'
        ) {
            0.34
        } else if ch.is_ascii_uppercase() || matches!(ch, '%' | '@' | '&' | 'M' | 'W') {
            0.66
        } else if ch.is_ascii_alphanumeric() || ch.is_ascii_punctuation() {
            0.55
        } else if matches!(ch, '⇧' | '↵' | '⇥' | '⌘' | '⌥' | '⌃' | '·') {
            0.78
        } else {
            1.02
        };
        w += adv * font_px;
    }
    w.ceil() as i32
}

/// 等宽字体（KeyCap / Mono）单行像素宽度精确估算（避免空格与窄符号按比例字体低估导致键帽截断）
pub fn estimate_mono_text_px(text: &str, font_px: f32) -> i32 {
    let w: f32 = text
        .chars()
        .map(|ch| if ch.is_ascii() { 0.62 } else { 1.05 } * font_px)
        .sum();
    w.ceil().max(0.0) as i32
}

// ============================================================================
// 连续曲率 Squircle SDF 抗锯齿 + Porter-Duff 预乘 Alpha 32-bit BGRA 画布
// ============================================================================

#[inline]
fn squircle_corner_dist(dx: f32, dy: f32, r: f32) -> f32 {
    if dx > 0.0 && dy > 0.0 {
        // 融合 L2 圆弧与 L2.4 连续超椭圆曲率（还原 Apple .continuous 圆角柔顺拐点，胶囊全圆时退化为标准正圆）
        let l2 = (dx * dx + dy * dy).sqrt();
        let nx = dx / r.max(1.0);
        let ny = dy / r.max(1.0);
        let sq = (nx.powf(2.25) + ny.powf(2.25)).powf(1.0 / 2.25) * r;
        (l2 * 0.45 + sq * 0.55) - r
    } else {
        dx.max(dy) - r
    }
}

pub struct PixelCanvas<'a> {
    pub pixels: &'a mut [u32],
    pub width: i32,
    pub height: i32,
    pub clip_y0: i32,
    pub clip_y1: i32,
}

impl<'a> PixelCanvas<'a> {
    pub fn new(pixels: &'a mut [u32], width: i32, height: i32) -> Self {
        debug_assert!((width * height) as usize <= pixels.len());
        Self {
            pixels,
            width,
            height,
            clip_y0: 0,
            clip_y1: height,
        }
    }

    #[inline]
    pub fn set_vertical_clip(&mut self, y0: i32, y1: i32) {
        self.clip_y0 = y0.clamp(0, self.height);
        self.clip_y1 = y1.clamp(self.clip_y0, self.height);
    }

    #[inline]
    pub fn reset_vertical_clip(&mut self) {
        self.clip_y0 = 0;
        self.clip_y1 = self.height;
    }

    #[inline]
    pub fn clear(&mut self, c: Color4) {
        let packed = pack_premultiplied_bgra(c);
        self.pixels[..(self.width * self.height) as usize].fill(packed);
    }

    /// 公开的 Porter-Duff Source-Over 预乘 Alpha 像素混合（供几何原语与离屏灰阶字体合成器统一调用）
    #[inline]
    pub fn blend_pixel(&mut self, x: i32, y: i32, c: Color4, coverage: f32) {
        if x < 0 || y < self.clip_y0 || x >= self.width || y >= self.clip_y1 {
            return;
        }
        let src_a = ((c.a as f32) * coverage.clamp(0.0, 1.0)).round() as u32;
        if src_a == 0 {
            return;
        }
        let idx = (y * self.width + x) as usize;
        if src_a >= 255 {
            self.pixels[idx] =
                (255u32 << 24) | ((c.r as u32) << 16) | ((c.g as u32) << 8) | (c.b as u32);
            return;
        }

        // 目标像素已是 Premultiplied BGRA: dst_rgb = true_rgb * dst_a / 255
        let dst = self.pixels[idx];
        let db = dst & 0xFF;
        let dg = (dst >> 8) & 0xFF;
        let dr = (dst >> 16) & 0xFF;
        let da = (dst >> 24) & 0xFF;

        let sr_pre = ((c.r as u32) * src_a + 127) / 255;
        let sg_pre = ((c.g as u32) * src_a + 127) / 255;
        let sb_pre = ((c.b as u32) * src_a + 127) / 255;

        let inv_sa = 255 - src_a;
        let out_r = (sr_pre + (dr * inv_sa + 127) / 255).min(255);
        let out_g = (sg_pre + (dg * inv_sa + 127) / 255).min(255);
        let out_b = (sb_pre + (db * inv_sa + 127) / 255).min(255);
        let out_a = (src_a + (da * inv_sa + 127) / 255).min(255);
        self.pixels[idx] = (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
    }

    /// 解析式柔和偏移扩散阴影（支持 x/y 双轴视差偏移，对标 SwiftUI `.shadow(color:radius:x:y:)`）
    pub fn draw_soft_shadow_round_rect(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: f32,
        offset_y: f32,
        blur_radius: f32,
        shadow_color: Color4,
    ) {
        self.draw_soft_shadow_round_rect_xy(
            x,
            y,
            w,
            h,
            radius,
            0.0,
            offset_y,
            blur_radius,
            shadow_color,
        );
    }

    #[allow(clippy::too_many_arguments)]
    pub fn draw_soft_shadow_round_rect_xy(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: f32,
        offset_x: f32,
        offset_y: f32,
        blur_radius: f32,
        shadow_color: Color4,
    ) {
        if w <= 0 || h <= 0 || blur_radius <= 0.2 || shadow_color.a == 0 {
            return;
        }
        let r = radius.clamp(0.0, (w.min(h) as f32) * 0.5);
        let spread = (blur_radius * 1.85).ceil() as i32;
        let sx = (x as f32 + offset_x).round() as i32;
        let sy = (y as f32 + offset_y).round() as i32;
        let x0 = (sx - spread).max(0);
        let y0 = (sy - spread).max(0);
        let x1 = (sx + w + spread).min(self.width);
        let y1 = (sy + h + spread).min(self.height);
        if x0 >= x1 || y0 >= y1 {
            return;
        }

        let cx = (x as f32) + offset_x + (w as f32) * 0.5;
        let cy = (y as f32) + offset_y + (h as f32) * 0.5;
        let hx = (w as f32) * 0.5 - r;
        let hy = (h as f32) * 0.5 - r;
        let inv_blur = 1.0 / (blur_radius * 1.65);

        for py in y0..y1 {
            let dy = ((py as f32 + 0.5) - cy).abs() - hy;
            for px in x0..x1 {
                let dx = ((px as f32 + 0.5) - cx).abs() - hx;
                let dist = if dx > 0.0 && dy > 0.0 {
                    (dx * dx + dy * dy).sqrt() - r
                } else {
                    dx.max(dy) - r
                };
                if dist >= blur_radius * 1.65 {
                    continue;
                }
                let u = (1.0 - (dist.max(-blur_radius * 0.35) + blur_radius * 0.35) * inv_blur)
                    .clamp(0.0, 1.0);
                let falloff = u * u * (3.0 - 2.0 * u);
                if falloff > 0.004 {
                    self.blend_pixel(px, py, shadow_color, falloff);
                }
            }
        }
    }

    pub fn fill_round_rect(&mut self, x: i32, y: i32, w: i32, h: i32, radius: f32, c: Color4) {
        self.fill_vgrad_round_rect(x, y, w, h, radius, c, c);
    }

    pub fn fill_vgrad_round_rect(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: f32,
        top_color: Color4,
        bottom_color: Color4,
    ) {
        if w <= 0 || h <= 0 {
            return;
        }
        let r = radius.clamp(0.0, (w.min(h) as f32) * 0.5);
        let is_pill = (r - (w.min(h) as f32) * 0.5).abs() < 0.6;
        let x0 = x.max(0);
        let y0 = y.max(self.clip_y0);
        let x1 = (x + w).min(self.width);
        let y1 = (y + h).min(self.clip_y1);
        if x0 >= x1 || y0 >= y1 {
            return;
        }

        let cx = (x as f32) + (w as f32) * 0.5;
        let cy = (y as f32) + (h as f32) * 0.5;
        let hx = (w as f32) * 0.5 - r;
        let hy = (h as f32) * 0.5 - r;
        let h_denom = (h.max(1) - 1).max(1) as f32;

        for py in y0..y1 {
            let t = ((py - y) as f32 / h_denom).clamp(0.0, 1.0);
            let row_c = if top_color == bottom_color {
                top_color
            } else {
                top_color.lerp(bottom_color, t)
            };
            let dy = ((py as f32 + 0.5) - cy).abs() - hy;

            if dy <= -0.8 && row_c.a == 255 && x >= 0 && (x + w) <= self.width {
                let packed = pack_premultiplied_bgra(row_c);
                let row_start = (py * self.width + x0) as usize;
                let row_end = (py * self.width + x1) as usize;
                self.pixels[row_start..row_end].fill(packed);
                continue;
            }

            for px in x0..x1 {
                let dx = ((px as f32 + 0.5) - cx).abs() - hx;
                let dist = if is_pill {
                    if dx > 0.0 && dy > 0.0 {
                        (dx * dx + dy * dy).sqrt() - r
                    } else {
                        dx.max(dy) - r
                    }
                } else {
                    squircle_corner_dist(dx, dy, r)
                };
                let cov = (0.5 - dist).clamp(0.0, 1.0);
                if cov > 0.0 {
                    self.blend_pixel(px, py, row_c, cov);
                }
            }
        }
    }

    /// 左上至右下对角微阶渐变连续圆角矩形（复刻 macOS 选中卡片与悬停链接徽标）
    pub fn fill_diag_grad_round_rect(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: f32,
        tl_color: Color4,
        br_color: Color4,
    ) {
        if w <= 0 || h <= 0 {
            return;
        }
        let r = radius.clamp(0.0, (w.min(h) as f32) * 0.5);
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = (x + w).min(self.width);
        let y1 = (y + h).min(self.height);
        if x0 >= x1 || y0 >= y1 {
            return;
        }
        let cx = (x as f32) + (w as f32) * 0.5;
        let cy = (y as f32) + (h as f32) * 0.5;
        let hx = (w as f32) * 0.5 - r;
        let hy = (h as f32) * 0.5 - r;
        let denom = (w + h).max(2) as f32;

        for py in y0..y1 {
            let dy = ((py as f32 + 0.5) - cy).abs() - hy;
            for px in x0..x1 {
                let dx = ((px as f32 + 0.5) - cx).abs() - hx;
                let dist = squircle_corner_dist(dx, dy, r);
                let cov = (0.5 - dist).clamp(0.0, 1.0);
                if cov > 0.0 {
                    let t = (((px - x) + (py - y)) as f32 / denom).clamp(0.0, 1.0);
                    self.blend_pixel(px, py, tl_color.lerp(br_color, t), cov);
                }
            }
        }
    }

    /// Apple TV 级反向流动视差镜面高光 + 45° 斜向玻璃扫光带（根据鼠标在卡片内的归一化坐标 nx, ny ∈ [-1, 1] 绘制柔焦光泽）
    #[allow(clippy::too_many_arguments)]
    pub fn draw_apple_tv_glare_round_rect(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: f32,
        nx: f32,
        ny: f32,
        peak_alpha: u8,
    ) {
        if w <= 0 || h <= 0 || peak_alpha == 0 {
            return;
        }
        let nxc = nx.clamp(-1.0, 1.0);
        let nyc = ny.clamp(-1.0, 1.0);
        let r = radius.clamp(0.0, (w.min(h) as f32) * 0.5);
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = (x + w).min(self.width);
        let y1 = (y + h).min(self.height);
        if x0 >= x1 || y0 >= y1 {
            return;
        }
        let cx = (x as f32) + (w as f32) * 0.5;
        let cy = (y as f32) + (h as f32) * 0.5;
        let hx = (w as f32) * 0.5 - r;
        let hy = (h as f32) * 0.5 - r;
        let gx = (x as f32) + (w as f32) * (0.5 - nxc * 0.38);
        let gy = (y as f32) + (h as f32) * (0.5 - nyc * 0.38);
        let wf = w as f32;
        let hf = h as f32;
        let inv_diag = 1.0 / (wf + hf).max(1.0);
        let band_center = 0.50 - nxc * 0.18;
        let glare_rad = (wf.max(hf) * 0.85).max(1.0);
        let inv_rad_sq = 1.0 / (glare_rad * glare_rad);

        for py in y0..y1 {
            let pyf = py as f32 + 0.5;
            let dy = (pyf - cy).abs() - hy;
            let gdy_sq = (pyf - gy) * (pyf - gy);
            let rel_y = pyf - (y as f32);
            for px in x0..x1 {
                let pxf = px as f32 + 0.5;
                let dx = (pxf - cx).abs() - hx;
                let dist = squircle_corner_dist(dx, dy, r);
                let cov = (0.5 - dist).clamp(0.0, 1.0);
                if cov > 0.0 {
                    let gdx = pxf - gx;
                    let norm_d2 = (gdx * gdx + gdy_sq) * inv_rad_sq;
                    let radial = if norm_d2 < 1.0 {
                        let falloff = (1.0 - norm_d2) * (1.0 - norm_d2);
                        (peak_alpha as f32) * falloff
                    } else {
                        0.0
                    };
                    let diag_t = ((pxf - (x as f32)) + rel_y) * inv_diag;
                    let diag_dist = ((diag_t - band_center) / 0.22).abs();
                    let sheen = if diag_dist < 1.0 {
                        let s_f = 1.0 - diag_dist * diag_dist;
                        (peak_alpha as f32) * 0.48 * s_f * s_f
                    } else {
                        0.0
                    };
                    let a = (radial + sheen).min(115.0).round() as u8;
                    if a > 0 {
                        self.blend_pixel(px, py, Color4::rgba(255, 255, 255, a), cov);
                    }
                }
            }
        }
    }

    /// 顶亮底暗 1px 液态玻璃折射镜面高光描边（避免死板四面等亮灰线框，塑造真实玻璃厚度）
    #[allow(clippy::too_many_arguments)]
    pub fn stroke_glass_bevel_round_rect(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: f32,
        thickness: f32,
        top_c: Color4,
        bottom_c: Color4,
    ) {
        if w <= 0 || h <= 0 || thickness <= 0.0 || (top_c.a == 0 && bottom_c.a == 0) {
            return;
        }
        let r = radius.clamp(0.0, (w.min(h) as f32) * 0.5);
        let is_pill = (r - (w.min(h) as f32) * 0.5).abs() < 0.6;
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = (x + w).min(self.width);
        let y1 = (y + h).min(self.height);
        if x0 >= x1 || y0 >= y1 {
            return;
        }
        let cx = (x as f32) + (w as f32) * 0.5;
        let cy = (y as f32) + (h as f32) * 0.5;
        let hx = (w as f32) * 0.5 - r;
        let hy = (h as f32) * 0.5 - r;
        let band = (r + thickness + 2.5).ceil() as i32;
        let inv_h = 1.0 / (h.max(1) as f32);

        for py in y0..y1 {
            let in_y_band = (py - y) < band || (y + h - 1 - py) < band;
            let dy = ((py as f32 + 0.5) - cy).abs() - hy;
            let vf = ((py - y) as f32 * inv_h).clamp(0.0, 1.0);
            // 顶部 0..35% 保持清亮镜面高光，下方柔和渐弱到底色
            let t = (vf * 1.35).min(1.0);
            let row_c = top_c.lerp(bottom_c, t);
            if row_c.a == 0 {
                continue;
            }
            for px in x0..x1 {
                if !in_y_band && (px - x) >= band && (x + w - 1 - px) >= band {
                    continue;
                }
                let dx = ((px as f32 + 0.5) - cx).abs() - hx;
                let dist_outer = if is_pill {
                    if dx > 0.0 && dy > 0.0 {
                        (dx * dx + dy * dy).sqrt() - r
                    } else {
                        dx.max(dy) - r
                    }
                } else {
                    squircle_corner_dist(dx, dy, r)
                };
                if dist_outer >= 0.55 || dist_outer <= -(thickness + 0.55) {
                    continue;
                }
                let cov_outer = (0.5 - dist_outer).clamp(0.0, 1.0);
                let cov_inner = (dist_outer + thickness + 0.5).clamp(0.0, 1.0);
                let cov = cov_outer.min(cov_inner);
                if cov > 0.0 {
                    self.blend_pixel(px, py, row_c, cov);
                }
            }
        }
    }

    pub fn stroke_round_rect(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: f32,
        thickness: f32,
        c: Color4,
    ) {
        if w <= 0 || h <= 0 || thickness <= 0.0 || c.a == 0 {
            return;
        }
        let r = radius.clamp(0.0, (w.min(h) as f32) * 0.5);
        let is_pill = (r - (w.min(h) as f32) * 0.5).abs() < 0.6;
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = (x + w).min(self.width);
        let y1 = (y + h).min(self.height);
        if x0 >= x1 || y0 >= y1 {
            return;
        }

        let cx = (x as f32) + (w as f32) * 0.5;
        let cy = (y as f32) + (h as f32) * 0.5;
        let hx = (w as f32) * 0.5 - r;
        let hy = (h as f32) * 0.5 - r;
        let band = (r + thickness + 2.5).ceil() as i32;

        for py in y0..y1 {
            let in_y_band = (py - y) < band || (y + h - 1 - py) < band;
            let dy = ((py as f32 + 0.5) - cy).abs() - hy;

            for px in x0..x1 {
                if !in_y_band && (px - x) >= band && (x + w - 1 - px) >= band {
                    continue;
                }
                let dx = ((px as f32 + 0.5) - cx).abs() - hx;
                let dist_outer = if is_pill {
                    if dx > 0.0 && dy > 0.0 {
                        (dx * dx + dy * dy).sqrt() - r
                    } else {
                        dx.max(dy) - r
                    }
                } else {
                    squircle_corner_dist(dx, dy, r)
                };
                if dist_outer >= 0.55 || dist_outer <= -(thickness + 0.55) {
                    continue;
                }
                let outer_cov = (0.5 - dist_outer).clamp(0.0, 1.0);
                let inner_cov = (0.5 - (dist_outer + thickness)).clamp(0.0, 1.0);
                let ring_cov = (outer_cov - inner_cov).clamp(0.0, 1.0);
                if ring_cov > 0.0 {
                    self.blend_pixel(px, py, c, ring_cov);
                }
            }
        }
    }

    pub fn fill_circle(&mut self, cx: f32, cy: f32, radius: f32, c: Color4) {
        let x0 = (cx - radius - 1.5).floor() as i32;
        let y0 = (cy - radius - 1.5).floor() as i32;
        let x1 = (cx + radius + 1.5).ceil() as i32;
        let y1 = (cy + radius + 1.5).ceil() as i32;
        for py in y0..=y1 {
            for px in x0..=x1 {
                let dx = (px as f32 + 0.5) - cx;
                let dy = (py as f32 + 0.5) - cy;
                let dist = (dx * dx + dy * dy).sqrt() - radius;
                let cov = (0.5 - dist).clamp(0.0, 1.0);
                if cov > 0.0 {
                    self.blend_pixel(px, py, c, cov);
                }
            }
        }
    }

    pub fn stroke_circle(&mut self, cx: f32, cy: f32, radius: f32, thickness: f32, c: Color4) {
        let half_t = thickness * 0.5;
        let outer = radius + half_t + 1.5;
        let x0 = (cx - outer).floor() as i32;
        let y0 = (cy - outer).floor() as i32;
        let x1 = (cx + outer).ceil() as i32;
        let y1 = (cy + outer).ceil() as i32;
        for py in y0..=y1 {
            for px in x0..=x1 {
                let dx = (px as f32 + 0.5) - cx;
                let dy = (py as f32 + 0.5) - cy;
                let d = ((dx * dx + dy * dy).sqrt() - radius).abs() - half_t;
                let cov = (0.5 - d).clamp(0.0, 1.0);
                if cov > 0.0 {
                    self.blend_pixel(px, py, c, cov);
                }
            }
        }
    }

    pub fn draw_line(&mut self, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, c: Color4) {
        let r = (thickness * 0.5).max(0.42);
        let min_x = (x0.min(x1) - r - 1.5).floor() as i32;
        let max_x = (x0.max(x1) + r + 1.5).ceil() as i32;
        let min_y = (y0.min(y1) - r - 1.5).floor() as i32;
        let max_y = (y0.max(y1) + r + 1.5).ceil() as i32;

        let vx = x1 - x0;
        let vy = y1 - y0;
        let len_sq = vx * vx + vy * vy;

        for py in min_y..=max_y {
            for px in min_x..=max_x {
                let wx = (px as f32 + 0.5) - x0;
                let wy = (py as f32 + 0.5) - y0;
                let t = if len_sq > 1e-6 {
                    ((wx * vx + wy * vy) / len_sq).clamp(0.0, 1.0)
                } else {
                    0.0
                };
                let dx = wx - t * vx;
                let dy = wy - t * vy;
                let dist = (dx * dx + dy * dy).sqrt() - r;
                let cov = (0.55 - dist).clamp(0.0, 1.0);
                if cov > 0.0 {
                    self.blend_pixel(px, py, c, cov);
                }
            }
        }
    }

    /// 双线性平滑插值 + 连续曲率圆角裁切缩略图贴图
    pub fn blit_rgba_round_rect(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: f32,
        src_rgba: &[u8],
        src_w: u32,
        src_h: u32,
    ) {
        if w <= 0
            || h <= 0
            || src_w == 0
            || src_h == 0
            || src_rgba.len() < (src_w * src_h * 4) as usize
        {
            return;
        }
        let r = radius.clamp(0.0, (w.min(h) as f32) * 0.5);
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = (x + w).min(self.width);
        let y1 = (y + h).min(self.height);
        if x0 >= x1 || y0 >= y1 {
            return;
        }

        let dst_aspect = (w as f32) / (h as f32);
        let src_aspect = (src_w as f32) / (src_h as f32);
        let (crop_x, crop_y, crop_w, crop_h) = if src_aspect > dst_aspect {
            let cw = (src_h as f32) * dst_aspect;
            (((src_w as f32) - cw) * 0.5, 0.0, cw, src_h as f32)
        } else {
            let ch = (src_w as f32) / dst_aspect;
            (0.0, ((src_h as f32) - ch) * 0.5, src_w as f32, ch)
        };

        let cx = (x as f32) + (w as f32) * 0.5;
        let cy = (y as f32) + (h as f32) * 0.5;
        let hx = (w as f32) * 0.5 - r;
        let hy = (h as f32) * 0.5 - r;

        for py in y0..y1 {
            let dy = ((py as f32 + 0.5) - cy).abs() - hy;
            let v = ((py - y) as f32 + 0.5) / (h as f32);
            let sy = (crop_y + v * crop_h).clamp(0.0, (src_h - 1) as f32) as usize;

            for px in x0..x1 {
                let dx = ((px as f32 + 0.5) - cx).abs() - hx;
                let dist = squircle_corner_dist(dx, dy, r);
                let cov = (0.5 - dist).clamp(0.0, 1.0);
                if cov <= 0.0 {
                    continue;
                }
                let u = ((px - x) as f32 + 0.5) / (w as f32);
                let sx = (crop_x + u * crop_w).clamp(0.0, (src_w - 1) as f32) as usize;
                let s_idx = (sy * (src_w as usize) + sx) * 4;
                let sc = Color4::rgba(
                    src_rgba[s_idx],
                    src_rgba[s_idx + 1],
                    src_rgba[s_idx + 2],
                    src_rgba[s_idx + 3],
                );
                self.blend_pixel(px, py, sc, cov);
            }
        }
    }

    /// 双线性插值 + 视口夹紧的大图缩放与平移渲染，杜绝拖出黑边或溢出操作栏
    #[allow(clippy::too_many_arguments)]
    pub fn blit_rgba_round_rect_zoomed(
        &mut self,
        vp_x: i32,
        vp_y: i32,
        vp_w: i32,
        vp_h: i32,
        radius: f32,
        src_rgba: &[u8],
        src_w: u32,
        src_h: u32,
        zoom_scale: f32,
        pan_x: f32,
        pan_y: f32,
    ) {
        let need_bytes = (src_w as usize)
            .saturating_mul(src_h as usize)
            .saturating_mul(4);
        if vp_w <= 0 || vp_h <= 0 || src_w == 0 || src_h == 0 || src_rgba.len() < need_bytes {
            return;
        }
        let zoom = zoom_scale.clamp(1.0, 3.0);
        let (base_w, base_h) = fit_image_in_viewport(src_w, src_h, vp_w, vp_h);
        let scaled_w = base_w * zoom;
        let scaled_h = base_h * zoom;
        let (c_pan_x, c_pan_y) = clamp_image_pan_offset(
            pan_x,
            pan_y,
            base_w,
            base_h,
            zoom,
            vp_w as f32,
            vp_h as f32,
        );
        let dst_w = (scaled_w.round() as i32).clamp(1, vp_w);
        let dst_h = (scaled_h.round() as i32).clamp(1, vp_h);
        let dst_x = vp_x + (vp_w - dst_w) / 2;
        let dst_y = vp_y + (vp_h - dst_h) / 2;

        let img_left = (vp_x as f32) + ((vp_w as f32) - scaled_w) * 0.5 + c_pan_x;
        let img_top = (vp_y as f32) + ((vp_h as f32) - scaled_h) * 0.5 + c_pan_y;

        if zoom <= 1.001
            && c_pan_x.abs() < 0.01
            && c_pan_y.abs() < 0.01
            && (dst_w as u32) == src_w
            && (dst_h as u32) == src_h
        {
            self.blit_rgba_round_rect(dst_x, dst_y, dst_w, dst_h, radius, src_rgba, src_w, src_h);
            return;
        }

        let r = radius.clamp(0.0, (dst_w.min(dst_h) as f32) * 0.5);
        let x0 = dst_x.max(0);
        let y0 = dst_y.max(0);
        let x1 = (dst_x + dst_w).min(self.width);
        let y1 = (dst_y + dst_h).min(self.height);
        if x0 >= x1 || y0 >= y1 {
            return;
        }

        let cx = (dst_x as f32) + (dst_w as f32) * 0.5;
        let cy = (dst_y as f32) + (dst_h as f32) * 0.5;
        let hx = (dst_w as f32) * 0.5 - r;
        let hy = (dst_h as f32) * 0.5 - r;
        let max_sx = (src_w - 1) as usize;
        let max_sy = (src_h - 1) as usize;
        let sw_f = (src_w - 1) as f32;
        let sh_f = (src_h - 1) as f32;
        let stride = src_w as usize;

        if (scaled_w + 0.5) < (src_w as f32) || (scaled_h + 0.5) < (src_h as f32) {
            // 缩小比率（< 1.0x）时采用基于像素覆盖面积的盒式预滤波，避免 1px 细线断裂与锯齿混叠
            let src_wf = src_w as f32;
            let src_hf = src_h as f32;
            let step_x = ((src_wf / scaled_w.max(1e-4)) / 12.0).ceil().max(1.0) as usize;
            let step_y = ((src_hf / scaled_h.max(1e-4)) / 12.0).ceil().max(1.0) as usize;
            for py in y0..y1 {
                let dy = ((py as f32 + 0.5) - cy).abs() - hy;
                let fy0 = ((((py as f32) - img_top) / scaled_h) * src_hf).clamp(0.0, src_hf);
                let fy1 = ((((py as f32 + 1.0) - img_top) / scaled_h) * src_hf)
                    .clamp(0.0, src_hf)
                    .max(fy0);
                let sy0 = (fy0.floor() as usize).min(max_sy);
                let sy1 = if fy1 > fy0 {
                    ((fy1 - 1e-4).floor().max(0.0) as usize).clamp(sy0, max_sy)
                } else {
                    sy0
                };

                for px in x0..x1 {
                    let dx = ((px as f32 + 0.5) - cx).abs() - hx;
                    let dist = squircle_corner_dist(dx, dy, r);
                    let cov = (0.5 - dist).clamp(0.0, 1.0);
                    if cov <= 0.0 {
                        continue;
                    }
                    let fx0 =
                        ((((px as f32) - img_left) / scaled_w) * src_wf).clamp(0.0, src_wf);
                    let fx1 = ((((px as f32 + 1.0) - img_left) / scaled_w) * src_wf)
                        .clamp(0.0, src_wf)
                        .max(fx0);
                    let sx0 = (fx0.floor() as usize).min(max_sx);
                    let sx1 = if fx1 > fx0 {
                        ((fx1 - 1e-4).floor().max(0.0) as usize).clamp(sx0, max_sx)
                    } else {
                        sx0
                    };

                    let mut acc_r = 0.0f32;
                    let mut acc_g = 0.0f32;
                    let mut acc_b = 0.0f32;
                    let mut acc_a = 0.0f32;
                    let mut w_sum = 0.0f32;
                    let mut sy = sy0;
                    while sy <= sy1 {
                        let wy = (fy1.min((sy + 1) as f32) - fy0.max(sy as f32)).max(0.0);
                        let row_off = sy * stride;
                        let mut sx = sx0;
                        while sx <= sx1 {
                            let wx = (fx1.min((sx + 1) as f32) - fx0.max(sx as f32)).max(0.0);
                            let w = wx * wy;
                            let idx = (row_off + sx) * 4;
                            acc_r += src_rgba[idx] as f32 * w;
                            acc_g += src_rgba[idx + 1] as f32 * w;
                            acc_b += src_rgba[idx + 2] as f32 * w;
                            acc_a += src_rgba[idx + 3] as f32 * w;
                            w_sum += w;
                            sx += step_x;
                        }
                        sy += step_y;
                    }
                    let sc = if w_sum > 1e-6 {
                        let inv_w = 1.0 / w_sum;
                        Color4::rgba(
                            (acc_r * inv_w).round().clamp(0.0, 255.0) as u8,
                            (acc_g * inv_w).round().clamp(0.0, 255.0) as u8,
                            (acc_b * inv_w).round().clamp(0.0, 255.0) as u8,
                            (acc_a * inv_w).round().clamp(0.0, 255.0) as u8,
                        )
                    } else {
                        let idx = (sy0 * stride + sx0) * 4;
                        Color4::rgba(
                            src_rgba[idx],
                            src_rgba[idx + 1],
                            src_rgba[idx + 2],
                            src_rgba[idx + 3],
                        )
                    };
                    self.blend_pixel(px, py, sc, cov);
                }
            }
            return;
        }

        for py in y0..y1 {
            let dy = ((py as f32 + 0.5) - cy).abs() - hy;
            let v = (((py as f32 + 0.5) - img_top) / scaled_h).clamp(0.0, 1.0);
            let fy = (v * (src_h as f32) - 0.5).clamp(0.0, sh_f);
            let y0i = fy.floor() as usize;
            let y1i = (y0i + 1).min(max_sy);
            let ty = fy - (y0i as f32);

            for px in x0..x1 {
                let dx = ((px as f32 + 0.5) - cx).abs() - hx;
                let dist = squircle_corner_dist(dx, dy, r);
                let cov = (0.5 - dist).clamp(0.0, 1.0);
                if cov <= 0.0 {
                    continue;
                }
                let u = (((px as f32 + 0.5) - img_left) / scaled_w).clamp(0.0, 1.0);
                let fx = (u * (src_w as f32) - 0.5).clamp(0.0, sw_f);
                let x0i = fx.floor() as usize;
                let x1i = (x0i + 1).min(max_sx);
                let tx = fx - (x0i as f32);

                let i00 = (y0i * stride + x0i) * 4;
                let i10 = (y0i * stride + x1i) * 4;
                let i01 = (y1i * stride + x0i) * 4;
                let i11 = (y1i * stride + x1i) * 4;

                let w00 = (1.0 - tx) * (1.0 - ty);
                let w10 = tx * (1.0 - ty);
                let w01 = (1.0 - tx) * ty;
                let w11 = tx * ty;

                let ch = |c: usize| -> u8 {
                    (src_rgba[i00 + c] as f32 * w00
                        + src_rgba[i10 + c] as f32 * w10
                        + src_rgba[i01 + c] as f32 * w01
                        + src_rgba[i11 + c] as f32 * w11)
                        .round()
                        .clamp(0.0, 255.0) as u8
                };
                let sc = Color4::rgba(ch(0), ch(1), ch(2), ch(3));
                self.blend_pixel(px, py, sc, cov);
            }
        }
    }

    /// 1:1 移植 macOS `LiquidGlassScenicBackdrop` 实景流光色带与实时背景模糊折射预览舞台
    pub fn draw_scenic_liquid_glass_preview(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        scale: f32,
        is_dark: bool,
        blur_pct: u8,
    ) {
        if w <= 16 || h <= 16 {
            return;
        }
        let sf = |v: f32| v * scale;
        let s = |v: i32| ((v as f32) * scale).round() as i32;
        let stage_h = h.max(8);
        let blur_t = (blur_pct.min(100) as f32) / 100.0;

        // 1. 生成底层晴空/午夜海蓝 + Tahoe 双流光缎带 + Notes.md 桌面文稿卡片离屏景物缓冲
        let sw = w as usize;
        let sh = stage_h as usize;
        let mut scene = vec![Color4::rgb(0, 0, 0); sw * sh];

        let (c0, c1, c2) = if is_dark {
            (
                Color4::rgb(15, 28, 61),
                Color4::rgb(28, 54, 107),
                Color4::rgb(46, 77, 138),
            )
        } else {
            (
                Color4::rgb(61, 138, 240),
                Color4::rgb(122, 189, 250),
                Color4::rgb(214, 235, 255),
            )
        };

        let doc_x0 = (w as f32 * 0.42) as i32;
        let doc_x1 = (w as f32 * 0.93) as i32;
        let doc_y0 = s(7);
        let doc_y1 = (stage_h - s(6)).max(doc_y0 + s(24));
        let doc_r = sf(9.5);
        let doc_cx = (doc_x0 + doc_x1) as f32 * 0.5;
        let doc_cy = (doc_y0 + doc_y1) as f32 * 0.5;
        let doc_hx = (doc_x1 - doc_x0) as f32 * 0.5 - doc_r;
        let doc_hy = (doc_y1 - doc_y0) as f32 * 0.5 - doc_r;

        for py in 0..stage_h {
            let vf = py as f32 / (stage_h.max(1) as f32);
            for px in 0..w {
                let uf = px as f32 / (w.max(1) as f32);
                let diag = (uf * 0.55 + vf * 0.65).clamp(0.0, 1.0);
                let mut col = if diag < 0.5 {
                    c0.lerp(c1, diag * 2.0)
                } else {
                    c1.lerp(c2, (diag - 0.5) * 2.0)
                };

                // Ribbon 1: S 型青蓝->靛紫流光缎带
                let r1_top = 0.54 - 0.42 * uf + 0.16 * (uf * 4.5).sin();
                if vf > r1_top {
                    let rc1 = if is_dark {
                        Color4::rgb(41, 122, 224).lerp(Color4::rgb(97, 66, 199), uf)
                    } else {
                        Color4::rgb(36, 168, 245).lerp(Color4::rgb(82, 107, 240), uf)
                    };
                    let edge = ((vf - r1_top) * 28.0).clamp(0.0, 0.82);
                    col = col.lerp(rc1, edge);
                }

                // Ribbon 2: 暖珀->翠青光弧
                let r2_top = 0.86 - 0.64 * uf - 0.10 * (uf * 3.6).sin();
                if uf > 0.14 && vf > r2_top {
                    let rc2 = if is_dark {
                        Color4::rgb(235, 133, 71).lerp(Color4::rgb(46, 158, 173), uf)
                    } else {
                        Color4::rgb(252, 173, 92).lerp(Color4::rgb(56, 194, 199), uf)
                    };
                    let edge = ((vf - r2_top) * 24.0).clamp(0.0, 0.82);
                    col = col.lerp(rc2, edge);
                }

                // 右侧圆角超椭圆 Notes.md 文稿卡片（带 1px 细边框与抗锯齿圆角，零死直角穿帮）
                let ddx = ((px as f32 + 0.5) - doc_cx).abs() - doc_hx;
                let ddy = ((py as f32 + 0.5) - doc_cy).abs() - doc_hy;
                let d_dist = squircle_corner_dist(ddx, ddy, doc_r);
                let doc_cov = (0.5 - d_dist).clamp(0.0, 1.0);
                if doc_cov > 0.0 {
                    let mut card_c = if is_dark {
                        Color4::rgb(34, 40, 54)
                    } else {
                        Color4::rgb(252, 253, 255)
                    };
                    let lx = px - doc_x0;
                    let ly = py - doc_y0;
                    // 模拟文稿内部骨骼条纹（位于胶囊下方与内部，检验不同模糊半径下的消融效果）
                    if (s(40)..s(44)).contains(&ly) && (s(12)..s(118)).contains(&lx) {
                        card_c = if is_dark {
                            Color4::rgb(198, 206, 224)
                        } else {
                            Color4::rgb(68, 78, 96)
                        };
                    } else if (s(50)..s(54)).contains(&ly) && (s(12)..s(92)).contains(&lx) {
                        card_c = if is_dark {
                            Color4::rgb(82, 140, 255)
                        } else {
                            Color4::rgb(48, 112, 245)
                        };
                    } else if (s(60)..s(63)).contains(&ly) && (s(12)..s(134)).contains(&lx) {
                        card_c = if is_dark {
                            Color4::rgb(112, 122, 144)
                        } else {
                            Color4::rgb(168, 178, 194)
                        };
                    }
                    // 卡片微细描边
                    let border_cov = (1.1 - d_dist.abs()).clamp(0.0, 1.0);
                    col = col.lerp(card_c, 0.92 * doc_cov);
                    if border_cov > 0.0 {
                        let bc = if is_dark {
                            Color4::rgb(96, 108, 134)
                        } else {
                            Color4::rgb(206, 216, 232)
                        };
                        col = col.lerp(bc, 0.45 * border_cov);
                    }
                }

                scene[(py as usize) * sw + (px as usize)] = col;
            }
        }

        // 2. 生成随 blur_pct 动态改变核半径的两趟分离盒式高斯模糊缓冲（O(W*H) 毫秒级）
        let radius = ((1.2 + blur_t * 14.0) * scale).round() as i32;
        let blurred = box_blur_2pass(&scene, sw, sh, radius.max(1) as usize);

        // 3. 将底层实景按圆角裁切绘入主画布
        let r_card = sf(12.0);
        let cx = (x as f32) + (w as f32) * 0.5;
        let cy = (y as f32) + (h as f32) * 0.5;
        let hx = (w as f32) * 0.5 - r_card;
        let hy = (h as f32) * 0.5 - r_card;

        for py in 0..h {
            let gy = y + py;
            if gy < 0 || gy >= self.height {
                continue;
            }
            let dy = ((gy as f32 + 0.5) - cy).abs() - hy;
            for px in 0..w {
                let gx = x + px;
                if gx < 0 || gx >= self.width {
                    continue;
                }
                let dx = ((gx as f32 + 0.5) - cx).abs() - hx;
                let dist = squircle_corner_dist(dx, dy, r_card);
                let cov = (0.5 - dist).clamp(0.0, 1.0);
                if cov <= 0.0 {
                    continue;
                }
                let src_c = if py < stage_h {
                    scene[(py as usize) * sw + (px as usize)]
                } else if is_dark {
                    Color4::rgb(31, 33, 41)
                } else {
                    Color4::rgb(243, 244, 247)
                };
                self.blend_pixel(gx, gy, src_c, cov);
            }
        }

        // 4. 在顶部悬浮三枚液态玻璃预览胶囊内写入折射模糊像素 + 浓度遮罩 + 斜向高光切面框
        let bar_y = s(11);
        let bar_h = s(32);
        let p1_x = s(12);
        let p1_w = s(64);
        let p2_x = p1_x + p1_w + s(8);
        let p2_w = s(32);
        let p3_x = p2_x + p2_w + s(8);
        let p3_w = (w - s(12) - p3_x).max(s(40));

        let tint_overlay = if is_dark {
            Color4::rgba(26, 30, 41, ((0.14 + blur_t * 0.64) * 255.0).round() as u8)
        } else {
            Color4::rgba(
                255,
                255,
                255,
                ((0.16 + blur_t * 0.64) * 255.0).round() as u8,
            )
        };
        let rim_c = if is_dark {
            Color4::rgba(255, 255, 255, 110)
        } else {
            Color4::rgba(255, 255, 255, 224)
        };

        for (px0, pw) in [(p1_x, p1_w), (p2_x, p2_w), (p3_x, p3_w)] {
            let pr = (bar_h as f32) * 0.5;
            let pcx = (x + px0) as f32 + (pw as f32) * 0.5;
            let pcy = (y + bar_y) as f32 + (bar_h as f32) * 0.5;
            let phx = (pw as f32) * 0.5 - pr;
            let phy = (bar_h as f32) * 0.5 - pr;

            for ly in bar_y..(bar_y + bar_h).min(stage_h) {
                let gy = y + ly;
                let dy = ((gy as f32 + 0.5) - pcy).abs() - phy;
                for lx in px0..(px0 + pw).min(w) {
                    let gx = x + lx;
                    let dx = ((gx as f32 + 0.5) - pcx).abs() - phx;
                    let d = if dx > 0.0 && dy > 0.0 {
                        (dx * dx + dy * dy).sqrt() - pr
                    } else {
                        dx.max(dy) - pr
                    };
                    let pcov = (0.5 - d).clamp(0.0, 1.0);
                    if pcov > 0.0 {
                        let bcol = blurred[(ly as usize) * sw + (lx as usize)];
                        self.blend_pixel(gx, gy, bcol, pcov);
                        self.blend_pixel(gx, gy, tint_overlay, pcov);
                    }
                }
            }
            self.stroke_round_rect(x + px0, y + bar_y, pw, bar_h, pr, sf(0.95), rim_c);
        }

        // 预览胶囊内的精致小图标（分享箭头 + 三圆点 / 叠放方框 / 搜索放大镜）
        let fg = if is_dark {
            Color4::rgb(255, 255, 255)
        } else {
            Color4::rgb(26, 28, 34)
        };
        let cy_bar = (y + bar_y + bar_h / 2) as f32;
        self.draw_icon_external_link((x + p1_x + s(20)) as f32, cy_bar, sf(11.0), sf(1.5), fg);
        for dot_i in -1..=1 {
            self.fill_circle(
                (x + p1_x + s(44)) as f32 + (dot_i as f32) * sf(4.2),
                cy_bar,
                sf(1.35),
                fg,
            );
        }
        self.draw_icon_overlapping_squares(
            (x + p2_x + p2_w / 2) as f32 - sf(7.0),
            cy_bar - sf(7.0),
            sf(14.0),
            fg,
            false,
        );
        self.draw_icon_search(
            (x + p3_x + s(16)) as f32,
            cy_bar,
            sf(11.5),
            sf(1.45),
            fg.with_alpha(180),
        );

        self.stroke_round_rect(
            x,
            y,
            w,
            h,
            r_card,
            sf(0.85),
            if is_dark {
                Color4::rgba(255, 255, 255, 36)
            } else {
                Color4::rgba(15, 23, 42, 22)
            },
        );
    }

    // ========================================================================
    // SF Symbols 级精密几何图标集（100% 亚像素抗锯齿矢量绘制）
    // ========================================================================

    pub fn draw_icon_search(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let r = size * 0.34;
        let ox = cx - size * 0.07;
        let oy = cy - size * 0.07;
        self.stroke_circle(ox, oy, r, stroke, c);
        let diag = r * 0.72;
        self.draw_line(
            ox + diag,
            oy + diag,
            cx + size * 0.38,
            cy + size * 0.38,
            stroke,
            c,
        );
    }

    pub fn draw_icon_close(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let d = size * 0.35;
        self.draw_line(cx - d, cy - d, cx + d, cy + d, stroke, c);
        self.draw_line(cx + d, cy - d, cx - d, cy + d, stroke, c);
    }

    /// 顶栏顺序粘贴队列 `list.number` 图标
    pub fn draw_icon_list_number(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let u = size * 0.42;
        for row in [-1i32, 0, 1] {
            let ry = cy + (row as f32) * u * 0.62;
            self.fill_circle(cx - u * 0.72, ry, stroke * 0.65, c);
            self.draw_line(cx - u * 0.25, ry, cx + u * 0.85, ry, stroke, c);
        }
    }

    /// 顶栏暂停/恢复监听 `record.circle` / `pause.circle.fill` 图标
    pub fn draw_icon_record_pause(
        &mut self,
        cx: f32,
        cy: f32,
        size: f32,
        stroke: f32,
        c: Color4,
        paused: bool,
    ) {
        let r = size * 0.43;
        self.stroke_circle(cx, cy, r, stroke, c);
        if paused {
            let dx = r * 0.28;
            let dy = r * 0.38;
            self.draw_line(cx - dx, cy - dy, cx - dx, cy + dy, stroke * 1.15, c);
            self.draw_line(cx + dx, cy - dy, cx + dx, cy + dy, stroke * 1.15, c);
        } else {
            self.fill_circle(cx, cy, r * 0.38, c);
        }
    }

    /// 极简纯净模式圆润树叶图标（用双三次平滑采样曲线绘制真实苹果叶弧度）
    pub fn draw_icon_leaf(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let r = size * 0.42;
        let base = (cx - r * 0.68, cy + r * 0.62);
        let tip = (cx + r * 0.82, cy - r * 0.78);
        let mut prev_u = base;
        let mut prev_l = base;
        for step in 1..=10 {
            let t = (step as f32) / 10.0;
            let inv = 1.0 - t;
            // 上叶弧控制点
            let ux = inv * inv * base.0 + 2.0 * inv * t * (cx - r * 0.55) + t * t * tip.0;
            let uy = inv * inv * base.1 + 2.0 * inv * t * (cy - r * 0.82) + t * t * tip.1;
            // 下叶弧控制点
            let lx = inv * inv * base.0 + 2.0 * inv * t * (cx + r * 0.82) + t * t * tip.0;
            let ly = inv * inv * base.1 + 2.0 * inv * t * (cy + r * 0.55) + t * t * tip.1;
            self.draw_line(prev_u.0, prev_u.1, ux, uy, stroke, c);
            self.draw_line(prev_l.0, prev_l.1, lx, ly, stroke, c);
            prev_u = (ux, uy);
            prev_l = (lx, ly);
        }
        self.draw_line(
            cx - r * 0.90,
            cy + r * 0.86,
            cx + r * 0.30,
            cy - r * 0.28,
            stroke * 0.95,
            c,
        );
    }

    /// 窗口始终在前图钉图标（激活态自动带 -18° 灵动倾角，对齐 macOS AlwaysOnTopPinButton）
    pub fn draw_icon_pin(
        &mut self,
        cx: f32,
        cy: f32,
        size: f32,
        stroke: f32,
        c: Color4,
        tilted_and_filled: bool,
    ) {
        let angle = if tilted_and_filled {
            -18.0f32.to_radians()
        } else {
            0.0
        };
        let cos_a = angle.cos();
        let sin_a = angle.sin();
        let rot = |dx: f32, dy: f32| -> (f32, f32) {
            (cx + dx * cos_a - dy * sin_a, cy + dx * sin_a + dy * cos_a)
        };

        let u = size * 0.40;
        let (tl_x, tl_y) = rot(-u * 0.46, -u * 0.88);
        let (tr_x, tr_y) = rot(u * 0.46, -u * 0.88);
        let (bl_x, bl_y) = rot(-u * 0.66, -u * 0.04);
        let (br_x, br_y) = rot(u * 0.66, -u * 0.04);
        let (ml_x, ml_y) = rot(-u * 0.32, -u * 0.88);
        let (mr_x, mr_y) = rot(u * 0.32, -u * 0.88);
        let (nb_x, nb_y) = rot(0.0, -u * 0.04);
        let (nt_x, nt_y) = rot(0.0, u * 1.12);

        self.draw_line(tl_x, tl_y, tr_x, tr_y, stroke, c);
        self.draw_line(ml_x, ml_y, bl_x, bl_y, stroke, c);
        self.draw_line(mr_x, mr_y, br_x, br_y, stroke, c);
        self.draw_line(bl_x, bl_y, br_x, br_y, stroke, c);
        if tilted_and_filled {
            let (fc_x, fc_y) = rot(0.0, -u * 0.44);
            self.fill_circle(fc_x, fc_y, u * 0.32, c);
        }
        self.draw_line(nb_x, nb_y, nt_x, nt_y, stroke * 1.05, c);
    }

    /// SF `gearshape` 8 齿正弦连续轮廓齿轮图标
    pub fn draw_icon_gear(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let r_base = size * 0.355;
        let amp = size * 0.068;
        let steps = 48;
        let mut prev = (0.0f32, 0.0f32);
        for i in 0..=steps {
            let theta = (i as f32) * std::f32::consts::TAU / (steps as f32);
            let wave = (8.0 * theta).cos().clamp(-0.7, 0.7) / 0.7;
            let rad = r_base + amp * wave;
            let pt = (cx + theta.cos() * rad, cy + theta.sin() * rad);
            if i > 0 {
                self.draw_line(prev.0, prev.1, pt.0, pt.1, stroke * 0.78, c);
            }
            prev = pt;
        }
        self.stroke_circle(cx, cy, size * 0.155, stroke * 0.78, c);
    }

    pub fn draw_icon_back(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let d = size * 0.34;
        self.draw_line(cx + d * 0.55, cy - d, cx - d * 0.55, cy, stroke, c);
        self.draw_line(cx - d * 0.55, cy, cx + d * 0.55, cy + d, stroke, c);
    }

    pub fn draw_icon_chevron_ud(
        &mut self,
        cx: f32,
        cy: f32,
        size: f32,
        stroke: f32,
        c: Color4,
        up: bool,
    ) {
        let dx = size * 0.36;
        let dy = size * 0.20 * if up { -1.0 } else { 1.0 };
        self.draw_line(cx - dx, cy - dy, cx, cy + dy, stroke, c);
        self.draw_line(cx, cy + dy, cx + dx, cy - dy, stroke, c);
    }

    /// 恢复默认 `arrow.uturn.backward` 图标
    pub fn draw_icon_undo_ccw(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let u = size * 0.36;
        self.draw_line(
            cx - u * 0.85,
            cy - u * 0.28,
            cx + u * 0.25,
            cy - u * 0.28,
            stroke,
            c,
        );
        self.draw_line(
            cx + u * 0.25,
            cy - u * 0.28,
            cx + u * 0.72,
            cy + u * 0.16,
            stroke,
            c,
        );
        self.draw_line(
            cx + u * 0.72,
            cy + u * 0.16,
            cx + u * 0.25,
            cy + u * 0.65,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.45,
            cy + u * 0.65,
            cx + u * 0.25,
            cy + u * 0.65,
            stroke,
            c,
        );
        // 左箭头尖
        self.draw_line(
            cx - u * 0.85,
            cy - u * 0.28,
            cx - u * 0.32,
            cy - u * 0.76,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.85,
            cy - u * 0.28,
            cx - u * 0.32,
            cy + u * 0.18,
            stroke,
            c,
        );
    }

    /// SF `link` 45° 双扣链环图标（用于链接卡片左侧徽标常态展示）
    pub fn draw_icon_link_chain(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let r = size * 0.20;
        let off = size * 0.16;
        self.stroke_circle(cx - off, cy + off, r, stroke, c);
        self.stroke_circle(cx + off, cy - off, r, stroke, c);
        self.draw_line(
            cx - off * 0.75,
            cy + off * 0.75,
            cx + off * 0.75,
            cy - off * 0.75,
            stroke * 1.05,
            c,
        );
    }

    /// 对角发射箭头 `↗`（用于链接徽标悬停态与右上角直达圆钮）
    pub fn draw_icon_external_link(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let d = size * 0.33;
        let tx = cx + d;
        let ty = cy - d;
        let bx = cx - d;
        let by = cy + d;
        self.draw_line(bx, by, tx, ty, stroke, c);
        self.draw_line(tx - d * 1.08, ty, tx, ty, stroke, c);
        self.draw_line(tx, ty, tx, ty + d * 1.08, stroke, c);
    }

    /// 回车折弯箭头 `↵`（用于图片选中角标）
    /// 精致像素对齐 Shift 空心上箭头矢量图标（替代发虚缩水的 Unicode `⇧`）
    pub fn draw_icon_shift_arrow(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let top_y = cy - size * 0.42;
        let mid_y = cy + size * 0.04;
        let bot_y = cy + size * 0.42;
        let wing_x = size * 0.44;
        let stem_x = size * 0.18;
        self.draw_line(cx, top_y, cx - wing_x, mid_y, stroke, c);
        self.draw_line(cx, top_y, cx + wing_x, mid_y, stroke, c);
        self.draw_line(cx - wing_x, mid_y, cx - stem_x, mid_y, stroke, c);
        self.draw_line(cx + wing_x, mid_y, cx + stem_x, mid_y, stroke, c);
        self.draw_line(cx - stem_x, mid_y, cx - stem_x, bot_y, stroke, c);
        self.draw_line(cx + stem_x, mid_y, cx + stem_x, bot_y, stroke, c);
        self.draw_line(cx - stem_x, bot_y, cx + stem_x, bot_y, stroke, c);
    }

    /// 精致矢量圆形双箭 OTA 更新图标
    pub fn draw_icon_refresh_update(
        &mut self,
        cx: f32,
        cy: f32,
        size: f32,
        stroke: f32,
        c: Color4,
    ) {
        let r = size * 0.38;
        let segs = 14;
        // 上弧 (-150° .. -20°)
        for i in 0..segs {
            let a0 = (-150.0 + 130.0 * (i as f32 / segs as f32)).to_radians();
            let a1 = (-150.0 + 130.0 * ((i + 1) as f32 / segs as f32)).to_radians();
            self.draw_line(
                cx + r * a0.cos(),
                cy + r * a0.sin(),
                cx + r * a1.cos(),
                cy + r * a1.sin(),
                stroke,
                c,
            );
        }
        // 下弧 (30° .. 160°)
        for i in 0..segs {
            let a0 = (30.0 + 130.0 * (i as f32 / segs as f32)).to_radians();
            let a1 = (30.0 + 130.0 * ((i + 1) as f32 / segs as f32)).to_radians();
            self.draw_line(
                cx + r * a0.cos(),
                cy + r * a0.sin(),
                cx + r * a1.cos(),
                cy + r * a1.sin(),
                stroke,
                c,
            );
        }
        // 上弧右端小箭尖
        let ax = cx + r * (-20.0f32).to_radians().cos();
        let ay = cy + r * (-20.0f32).to_radians().sin();
        self.draw_line(ax, ay, ax - size * 0.20, ay - size * 0.03, stroke, c);
        self.draw_line(ax, ay, ax - size * 0.02, ay - size * 0.21, stroke, c);
        // 下弧左端小箭尖
        let bx = cx + r * (160.0f32).to_radians().cos();
        let by = cy + r * (160.0f32).to_radians().sin();
        self.draw_line(bx, by, bx + size * 0.20, by + size * 0.03, stroke, c);
        self.draw_line(bx, by, bx + size * 0.02, by + size * 0.21, stroke, c);
    }

    pub fn draw_icon_return_arrow(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let u = size * 0.34;
        self.draw_line(
            cx + u * 0.75,
            cy - u * 0.65,
            cx + u * 0.75,
            cy + u * 0.22,
            stroke,
            c,
        );
        self.draw_line(
            cx + u * 0.75,
            cy + u * 0.22,
            cx - u * 0.75,
            cy + u * 0.22,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.75,
            cy + u * 0.22,
            cx - u * 0.22,
            cy - u * 0.28,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.75,
            cy + u * 0.22,
            cx - u * 0.22,
            cy + u * 0.72,
            stroke,
            c,
        );
    }

    /// Tab 右跳符号 `⇥`（用于底栏键帽矢量绘制，对齐 `[ESC]` 视觉字重）
    pub fn draw_icon_tab_arrow(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let u = size * 0.36;
        self.draw_line(cx - u * 0.85, cy, cx + u * 0.45, cy, stroke, c);
        self.draw_line(cx + u * 0.45, cy, cx - u * 0.05, cy - u * 0.52, stroke, c);
        self.draw_line(cx + u * 0.45, cy, cx - u * 0.05, cy + u * 0.52, stroke, c);
        self.draw_line(
            cx + u * 0.78,
            cy - u * 0.58,
            cx + u * 0.78,
            cy + u * 0.58,
            stroke,
            c,
        );
    }

    /// Finder 风格圆角文件夹图标（用于文件卡片左侧徽标）
    pub fn draw_icon_file(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let w = size * 0.42;
        let h = size * 0.32;
        let l = cx - w;
        let r = cx + w;
        let t = cy - h * 0.65;
        let b = cy + h;
        let tab_t = cy - h * 1.05;
        let tab_r = cx - w * 0.12;
        self.draw_line(l, b, l, tab_t, stroke, c);
        self.draw_line(l, tab_t, tab_r, tab_t, stroke, c);
        self.draw_line(tab_r, tab_t, tab_r + w * 0.22, t, stroke, c);
        self.draw_line(tab_r + w * 0.22, t, r, t, stroke, c);
        self.draw_line(r, t, r, b, stroke, c);
        self.draw_line(r, b, l, b, stroke, c);
    }

    pub fn draw_icon_star(
        &mut self,
        cx: f32,
        cy: f32,
        size: f32,
        stroke: f32,
        c: Color4,
        filled: bool,
    ) {
        let r_out = size * 0.44;
        let r_in = r_out * 0.42;
        let mut pts = [(0.0f32, 0.0f32); 10];
        for (i, pt) in pts.iter_mut().enumerate() {
            let angle = -std::f32::consts::FRAC_PI_2 + (i as f32) * std::f32::consts::PI / 5.0;
            let rad = if i % 2 == 0 { r_out } else { r_in };
            *pt = (cx + angle.cos() * rad, cy + angle.sin() * rad);
        }

        if filled {
            let min_x = (cx - r_out - 1.0).floor() as i32;
            let max_x = (cx + r_out + 1.0).ceil() as i32;
            let min_y = (cy - r_out - 1.0).floor() as i32;
            let max_y = (cy + r_out + 1.0).ceil() as i32;
            for py in min_y..=max_y {
                for px in min_x..=max_x {
                    let mut hits = 0;
                    for sy in [0.25f32, 0.75] {
                        for sx in [0.25f32, 0.75] {
                            if point_in_polygon(px as f32 + sx, py as f32 + sy, &pts) {
                                hits += 1;
                            }
                        }
                    }
                    if hits > 0 {
                        self.blend_pixel(px, py, c, (hits as f32) * 0.25);
                    }
                }
            }
        } else {
            for i in 0..10 {
                let (x0, y0) = pts[i];
                let (x1, y1) = pts[(i + 1) % 10];
                self.draw_line(x0, y0, x1, y1, stroke, c);
            }
        }
    }

    pub fn draw_icon_trash(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let u = size * 0.36;
        self.draw_line(
            cx - u * 0.90,
            cy - u * 0.52,
            cx + u * 0.90,
            cy - u * 0.52,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.34,
            cy - u * 0.84,
            cx + u * 0.34,
            cy - u * 0.84,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.68,
            cy - u * 0.48,
            cx - u * 0.56,
            cy + u * 0.88,
            stroke,
            c,
        );
        self.draw_line(
            cx + u * 0.68,
            cy - u * 0.48,
            cx + u * 0.56,
            cy + u * 0.88,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.56,
            cy + u * 0.88,
            cx + u * 0.56,
            cy + u * 0.88,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.20,
            cy - u * 0.10,
            cx - u * 0.18,
            cy + u * 0.52,
            stroke * 0.85,
            c,
        );
        self.draw_line(
            cx + u * 0.20,
            cy - u * 0.10,
            cx + u * 0.18,
            cy + u * 0.52,
            stroke * 0.85,
            c,
        );
    }

    pub fn draw_icon_bolt(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let u = size * 0.38;
        self.draw_line(
            cx + u * 0.15,
            cy - u * 0.92,
            cx - u * 0.52,
            cy + u * 0.06,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.52,
            cy + u * 0.06,
            cx + u * 0.12,
            cy + u * 0.06,
            stroke,
            c,
        );
        self.draw_line(
            cx + u * 0.12,
            cy + u * 0.06,
            cx - u * 0.15,
            cy + u * 0.92,
            stroke,
            c,
        );
    }

    /// 空状态中央剪贴板线性图标
    pub fn draw_icon_clipboard(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let w = (size * 0.62).round() as i32;
        let h = (size * 0.78).round() as i32;
        let x = (cx - (w as f32) * 0.5).round() as i32;
        let y = (cy - (h as f32) * 0.44).round() as i32;
        self.stroke_round_rect(x, y, w, h, size * 0.12, stroke, c);
        let cw = (size * 0.32).round() as i32;
        let ch = (size * 0.14).round() as i32;
        self.fill_round_rect(
            (cx - (cw as f32) * 0.5).round() as i32,
            y - ch / 2,
            cw,
            ch,
            size * 0.05,
            c,
        );
    }

    /// 苹果官方双叠圆角方框刻度图标（复刻 `OverlappingGlassSquaresGlyph`）
    pub fn draw_icon_overlapping_squares(
        &mut self,
        x: f32,
        y: f32,
        size: f32,
        c: Color4,
        frosted: bool,
    ) {
        let box_sz = (size * 0.58).round() as i32;
        let bx1 = (x + size * 0.08).round() as i32;
        let by1 = (y + size * 0.08).round() as i32;
        let bx2 = (x + size * 0.34).round() as i32;
        let by2 = (y + size * 0.34).round() as i32;
        let r = size * 0.16;
        let st = (size * 0.075).max(1.1);
        let stroke_c = c.with_alpha(215);

        if frosted {
            self.fill_round_rect(bx1, by1, box_sz, box_sz, r, c.with_alpha(78));
            self.stroke_round_rect(bx1, by1, box_sz, box_sz, r, st, stroke_c);
            self.fill_round_rect(bx2, by2, box_sz, box_sz, r, c.with_alpha(224));
        } else {
            self.stroke_round_rect(bx1, by1, box_sz, box_sz, r, st, stroke_c);
            self.fill_round_rect(bx2, by2, box_sz, box_sz, r, c.with_alpha(24));
            self.stroke_round_rect(bx2, by2, box_sz, box_sz, r, st, stroke_c);
        }
    }

    /// 待办圆环与对勾抗锯齿矢量图标（Things 3 风格）
    pub fn draw_icon_check_circle(
        &mut self,
        cx: f32,
        cy: f32,
        size: f32,
        stroke: f32,
        ring_or_fill: Color4,
        filled: bool,
        check_color: Color4,
    ) {
        let r = size * 0.44;
        if filled {
            self.fill_circle(cx, cy, r, ring_or_fill);
            let u = r * 0.55;
            self.draw_line(
                cx - u * 0.78,
                cy + u * 0.05,
                cx - u * 0.16,
                cy + u * 0.68,
                stroke * 1.15,
                check_color,
            );
            self.draw_line(
                cx - u * 0.16,
                cy + u * 0.68,
                cx + u * 0.88,
                cy - u * 0.56,
                stroke * 1.15,
                check_color,
            );
        } else {
            self.stroke_circle(cx, cy, r, stroke, ring_or_fill);
        }
    }

    /// 现代 Fluent / Tahoe 质感胶囊拨动开关（带细腻内描边与高光拨珠，告别扁平塑料感）
    pub fn draw_toggle_switch(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        is_on: bool,
        accent: Color4,
    ) {
        let r = (h as f32) * 0.5;
        if is_on {
            let top = accent.lerp(Color4::rgb(255, 255, 255), 0.08);
            let bot = accent.lerp(Color4::rgb(0, 0, 0), 0.12);
            self.fill_vgrad_round_rect(x, y, w, h, r, top, bot);
            self.stroke_round_rect(x, y, w, h, r, 0.8, Color4::rgba(255, 255, 255, 42));
        } else {
            self.fill_round_rect(x, y, w, h, r, Color4::rgba(148, 163, 184, 62));
            self.stroke_round_rect(x, y, w, h, r, 0.8, Color4::rgba(148, 163, 184, 58));
        }
        let pad = ((h as f32) * 0.12).max(2.2);
        let knob_r = r - pad;
        let knob_cx = if is_on {
            (x + w) as f32 - r
        } else {
            (x as f32) + r
        };
        let knob_cy = (y as f32) + r;
        self.fill_circle(
            knob_cx,
            knob_cy + 1.0,
            knob_r + 0.3,
            Color4::rgba(15, 23, 42, 46),
        );
        self.fill_circle(knob_cx, knob_cy, knob_r, Color4::rgb(255, 255, 255));
        self.stroke_circle(knob_cx, knob_cy, knob_r, 0.65, Color4::rgba(15, 23, 42, 22));
    }

    /// 苹果官方三档微刻度背景模糊浓度无级滑杆（0% ~ 100%，严格等距三档视觉刻度）
    pub fn draw_concentration_slider(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        pct: u8,
        accent: Color4,
    ) {
        let track_h = ((h as f32) * 0.22).round().max(4.0) as i32;
        let ty = y + (h - track_h) / 2 - 2;
        let tr = (track_h as f32) * 0.5;
        self.fill_round_rect(x, ty, w, track_h, tr, Color4::rgba(148, 163, 184, 68));
        let ratio = (pct.min(100) as f32) / 100.0;
        let fill_w = ((w as f32) * ratio).round() as i32;
        if fill_w > 0 {
            self.fill_round_rect(x, ty, fill_w.max(track_h), track_h, tr, accent);
        }

        // 下方三枚对称微刻度锚点（对应 清透 8% · 均衡 48% · 浓雾 88%）
        let tick_y = (ty + track_h) as f32 + (h as f32) * 0.22;
        for anchor in [0.08f32, 0.48, 0.88] {
            let tx = (x as f32) + (w as f32) * anchor;
            let active = (ratio - anchor).abs() < 0.06;
            self.fill_circle(
                tx,
                tick_y,
                (track_h as f32 * if active { 0.44 } else { 0.34 }).max(1.5),
                if active {
                    accent
                } else {
                    Color4::rgba(164, 178, 198, 196)
                },
            );
        }

        let knob_r = ((h as f32) * 0.33).max(6.5);
        let knob_cx =
            (x as f32 + (w as f32) * ratio).clamp(x as f32 + knob_r, (x + w) as f32 - knob_r);
        let knob_cy = ty as f32 + (track_h as f32) * 0.5;
        self.fill_circle(
            knob_cx,
            knob_cy + 1.1,
            knob_r + 0.5,
            Color4::rgba(15, 23, 42, 48),
        );
        self.fill_circle(knob_cx, knob_cy, knob_r, Color4::rgb(255, 255, 255));
        self.stroke_circle(knob_cx, knob_cy, knob_r, 0.95, Color4::rgba(15, 23, 42, 38));
    }
}

fn box_blur_2pass(src: &[Color4], w: usize, h: usize, radius: usize) -> Vec<Color4> {
    if radius == 0 || w == 0 || h == 0 {
        return src.to_vec();
    }
    let mut tmp = vec![Color4::rgb(0, 0, 0); w * h];
    let mut out = vec![Color4::rgb(0, 0, 0); w * h];
    let r = radius.min(w.saturating_sub(1)).min(h.saturating_sub(1));
    if r == 0 {
        return src.to_vec();
    }

    // 水平滑动窗口均值模糊
    for y in 0..h {
        let row = y * w;
        for x in 0..w {
            let x0 = x.saturating_sub(r);
            let x1 = (x + r).min(w - 1);
            let cnt = (x1 - x0 + 1) as u32;
            let (mut sr, mut sg, mut sb) = (0u32, 0u32, 0u32);
            for k in x0..=x1 {
                let c = src[row + k];
                sr += c.r as u32;
                sg += c.g as u32;
                sb += c.b as u32;
            }
            tmp[row + x] = Color4::rgb((sr / cnt) as u8, (sg / cnt) as u8, (sb / cnt) as u8);
        }
    }

    // 垂直滑动窗口均值模糊
    for x in 0..w {
        for y in 0..h {
            let y0 = y.saturating_sub(r);
            let y1 = (y + r).min(h - 1);
            let cnt = (y1 - y0 + 1) as u32;
            let (mut sr, mut sg, mut sb) = (0u32, 0u32, 0u32);
            for k in y0..=y1 {
                let c = tmp[k * w + x];
                sr += c.r as u32;
                sg += c.g as u32;
                sb += c.b as u32;
            }
            out[y * w + x] = Color4::rgb((sr / cnt) as u8, (sg / cnt) as u8, (sb / cnt) as u8);
        }
    }
    out
}

#[inline]
fn pack_premultiplied_bgra(c: Color4) -> u32 {
    let a = c.a as u32;
    let r = ((c.r as u32) * a + 127) / 255;
    let g = ((c.g as u32) * a + 127) / 255;
    let b = ((c.b as u32) * a + 127) / 255;
    (a << 24) | (r << 16) | (g << 8) | b
}

fn point_in_polygon(px: f32, py: f32, poly: &[(f32, f32)]) -> bool {
    let mut inside = false;
    let mut j = poly.len() - 1;
    for i in 0..poly.len() {
        let (xi, yi) = poly[i];
        let (xj, yj) = poly[j];
        if ((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / ((yj - yi) + 1e-9) + xi) {
            inside = !inside;
        }
        j = i;
    }
    inside
}

/// 在给定视口内按原图比例且不超 1.0x 适配后的基础显示尺寸（与大屏渲染保持同源几何）
pub fn fit_image_in_viewport(src_w: u32, src_h: u32, vp_w: i32, vp_h: i32) -> (f32, f32) {
    if src_w == 0 || src_h == 0 || vp_w <= 0 || vp_h <= 0 {
        return (1.0, 1.0);
    }
    let fit_r = ((vp_w as f32) / (src_w as f32))
        .min((vp_h as f32) / (src_h as f32))
        .min(1.0);
    ((src_w as f32 * fit_r).max(1.0), (src_h as f32 * fit_r).max(1.0))
}

/// 限制大图预览缩放后的二维平移偏移，确保边缘不脱离视口产生黑边
pub fn clamp_image_pan_offset(
    offset_x: f32,
    offset_y: f32,
    image_w: f32,
    image_h: f32,
    zoom_scale: f32,
    viewport_w: f32,
    viewport_h: f32,
) -> (f32, f32) {
    if zoom_scale <= 1.001
        || image_w <= 0.0
        || image_h <= 0.0
        || viewport_w <= 0.0
        || viewport_h <= 0.0
    {
        return (0.0, 0.0);
    }
    let max_x = ((image_w * zoom_scale - viewport_w) * 0.5).max(0.0);
    let max_y = ((image_h * zoom_scale - viewport_h) * 0.5).max(0.0);
    (offset_x.clamp(-max_x, max_x), offset_y.clamp(-max_y, max_y))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BigBangChipRowItem {
    pub token_idx: usize,
    pub x_offset: i32,
    pub width: i32,
}

/// 将大爆炸分词（索引、自然像素宽、是否显式换行）预先编排成逐行布局，便于按滚动窗口精准渲染与满宽“按行”展示
pub fn pack_big_bang_chip_rows(
    tokens: &[(usize, i32, bool)],
    max_width: i32,
    gap_x: i32,
    full_width_rows: bool,
    max_chips: usize,
) -> Vec<Vec<BigBangChipRowItem>> {
    let eff_max_w = max_width.max(1);
    let eff_gap = gap_x.max(0);
    let mut rows: Vec<Vec<BigBangChipRowItem>> = Vec::new();
    let mut cur_row: Vec<BigBangChipRowItem> = Vec::new();
    let mut cur_x: i32 = 0;
    let mut count: usize = 0;

    for &(tok_idx, nat_w, is_break) in tokens {
        if is_break {
            if !cur_row.is_empty() {
                rows.push(cur_row);
                cur_row = Vec::new();
                cur_x = 0;
            }
            continue;
        }
        if count >= max_chips {
            break;
        }
        if full_width_rows {
            if !cur_row.is_empty() {
                rows.push(cur_row);
                cur_row = Vec::new();
            }
            rows.push(vec![BigBangChipRowItem {
                token_idx: tok_idx,
                x_offset: 0,
                width: eff_max_w,
            }]);
            cur_x = 0;
            count += 1;
            continue;
        }
        let cw = nat_w.clamp(1, eff_max_w);
        if !cur_row.is_empty() && cur_x + cw > eff_max_w {
            rows.push(cur_row);
            cur_row = Vec::new();
            cur_x = 0;
        }
        cur_row.push(BigBangChipRowItem {
            token_idx: tok_idx,
            x_offset: cur_x,
            width: cw,
        });
        cur_x += cw + eff_gap;
        count += 1;
    }
    if !cur_row.is_empty() {
        rows.push(cur_row);
    }
    rows
}

/// 计算并钳制速览面板当前滚动行偏移与最大可滚行数
pub fn clamp_quick_look_scroll(
    scroll: usize,
    total_rows: usize,
    visible_rows: usize,
) -> (usize, usize) {
    let max_scroll = total_rows.saturating_sub(visible_rows.max(1));
    (scroll.min(max_scroll), max_scroll)
}

/// 计算经过 DT_WORDBREAK 自动折行后的最大可滚动逻辑行偏移与总视觉行数，保证长段落文本也可滚至最末尾
pub fn compute_wrapped_text_scroll_bounds(
    line_widths: &[i32],
    content_width: i32,
    visible_visual_lines: usize,
) -> (usize, usize) {
    let eff_w = content_width.max(1);
    let vis = visible_visual_lines.max(1);
    let line_vis_counts: Vec<usize> = line_widths
        .iter()
        .map(|&w| ((w.max(1) + eff_w - 1) / eff_w).max(1) as usize)
        .collect();
    let total_visual: usize = line_vis_counts.iter().sum();
    if total_visual <= vis || line_vis_counts.len() <= 1 {
        return (0, total_visual);
    }
    let mut tail_visual = 0usize;
    let mut max_scroll = line_vis_counts.len().saturating_sub(1);
    for (idx, &v) in line_vis_counts.iter().enumerate().rev() {
        if tail_visual > 0 && tail_visual + v > vis {
            break;
        }
        tail_visual += v;
        max_scroll = idx;
        if tail_visual >= vis {
            break;
        }
    }
    (max_scroll, total_visual)
}
