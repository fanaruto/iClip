use crate::model::{ClipContentType, ClipItem, PinCategory};
use crate::store::GlassAppearance;

/// RGBA 颜色（底层写入 Win32 32-bit DIB 时自动转为 0xAARRGGBB 小端 BGRA）
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

    /// 转换为 Win32 GDI `SetTextColor` 所需的 `COLORREF` (`0x00BBGGRR`)
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

/// 对齐 macOS `v2.4` 液态玻璃深曜石与 DESIGN.md 电光钴蓝调色板（遵循 Tinted-Neutral 与 Single-Accent 铁律）
#[derive(Debug, Clone, Copy)]
pub struct GlassPalette {
    pub window_bg: Color4,
    pub window_border: Color4,
    pub track_bg: Color4,
    pub track_border: Color4,
    pub search_bg: Color4,
    pub search_border: Color4,
    pub card_bg: Color4,
    pub card_hover_bg: Color4,
    pub card_pinned_bg: Color4,
    pub card_pinned_hover_bg: Color4,
    pub card_border: Color4,
    pub card_pinned_border: Color4,
    pub select_top: Color4,
    pub select_bottom: Color4,
    pub select_border: Color4,
    pub cobalt: Color4,
    pub cobalt_deep: Color4,
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
            GlassAppearance::Solid => 98,
        };
        Self::for_blur_concentration(pct)
    }

    /// 苹果官方风格液态玻璃单轴背景模糊浓度（0% 清澈折射 ~ 38% 柔焦默认 ~ 100% 实色浓雾）
    pub fn for_blur_concentration(pct: u8) -> Self {
        let t = (pct.min(100) as f32) / 100.0;
        let win_a = (168.0 + t * 87.0).round() as u8;
        let card_a = (182.0 + t * 73.0).round() as u8;
        let hover_a = (206.0 + t * 49.0).round() as u8;
        let track_a = (190.0 + t * 65.0).round() as u8;

        let win_bg = Color4::rgba(13, 18, 30, win_a);
        let card_bg = Color4::rgba(23, 30, 46, card_a);
        let card_hover = Color4::rgba(31, 40, 60, hover_a);
        let track_bg = Color4::rgba(19, 25, 40, track_a);

        Self {
            window_bg: win_bg,
            window_border: Color4::rgba(148, 172, 214, 36),
            track_bg,
            track_border: Color4::rgba(148, 172, 214, 28),
            search_bg: Color4::rgba(25, 33, 50, 242),
            search_border: Color4::rgba(148, 172, 214, 42),
            card_bg,
            card_hover_bg: card_hover,
            card_pinned_bg: Color4::rgba(46, 36, 24, 232),
            card_pinned_hover_bg: Color4::rgba(58, 45, 29, 244),
            card_border: Color4::rgba(148, 172, 214, 28),
            card_pinned_border: Color4::rgba(245, 158, 11, 110),
            // DESIGN.md Electric Cobalt (#1e5eff -> #1549d6)
            select_top: Color4::rgb(34, 98, 255),
            select_bottom: Color4::rgb(21, 73, 214),
            select_border: Color4::rgba(132, 176, 255, 168),
            cobalt: Color4::rgb(30, 94, 255),
            cobalt_deep: Color4::rgb(21, 73, 214),
            emerald: Color4::rgb(16, 185, 129),
            amber: Color4::rgb(245, 158, 11),
            danger: Color4::rgb(225, 66, 78),
            text_primary: Color4::rgb(244, 247, 253),
            text_secondary: Color4::rgb(158, 172, 196),
            text_muted: Color4::rgb(112, 126, 150),
        }
    }

    pub fn pin_category_color(cat: PinCategory) -> Color4 {
        match cat {
            PinCategory::Reply => Color4::rgb(56, 139, 253),
            PinCategory::Invoice => Color4::rgb(245, 158, 11),
            PinCategory::Contact => Color4::rgb(16, 185, 129),
            PinCategory::Template => Color4::rgb(168, 108, 252),
        }
    }
}

/// 连续图片 3 列宫格与常规单列卡片统一布局行（与 macOS `ClipDisplayRow` 同构）
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DisplayRow {
    StandardCard { vis_pos: usize, store_idx: usize },
    ImageGridRow { cells: Vec<(usize, usize)> }, // (vis_pos, store_idx)，每行 1..=3 张
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GridMoveDir {
    Up,
    Down,
    Left,
    Right,
}

pub fn build_display_rows(filtered_indices: &[usize], items: &[ClipItem]) -> Vec<DisplayRow> {
    let mut rows = Vec::with_capacity(filtered_indices.len());
    let mut img_buf: Vec<(usize, usize)> = Vec::with_capacity(3);

    for (vis_pos, &store_idx) in filtered_indices.iter().enumerate() {
        let is_img = items
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

/// 零抖动卡片高度预算：高度仅取决于内容固有属性（是否含快捷胶囊），绝不随选中/悬停跳变！
pub fn standard_card_height(has_chips: bool, scale: f32) -> i32 {
    let base = if has_chips { 86.0 } else { 62.0 };
    (base * scale).round() as i32
}

pub fn image_grid_row_height(scale: f32) -> i32 {
    (102.0 * scale).round() as i32
}

// ============================================================================
// 亚像素 SDF 抗锯齿 32-bit BGRA 内存画布（兼容 Win32 Top-Down CreateDIBSection）
// ============================================================================

pub struct PixelCanvas<'a> {
    pub pixels: &'a mut [u32],
    pub width: i32,
    pub height: i32,
}

impl<'a> PixelCanvas<'a> {
    pub fn new(pixels: &'a mut [u32], width: i32, height: i32) -> Self {
        debug_assert!((width * height) as usize <= pixels.len());
        Self {
            pixels,
            width,
            height,
        }
    }

    #[inline]
    pub fn clear(&mut self, c: Color4) {
        let packed = pack_premultiplied_bgra(c, 255);
        self.pixels[..(self.width * self.height) as usize].fill(packed);
    }

    #[inline]
    fn blend_pixel(&mut self, x: i32, y: i32, c: Color4, coverage: f32) {
        if x < 0 || y < 0 || x >= self.width || y >= self.height {
            return;
        }
        let eff_a = ((c.a as f32) * coverage.clamp(0.0, 1.0)).round() as u32;
        if eff_a == 0 {
            return;
        }
        let idx = (y * self.width + x) as usize;
        if eff_a >= 255 {
            self.pixels[idx] =
                (255u32 << 24) | ((c.r as u32) << 16) | ((c.g as u32) << 8) | (c.b as u32);
            return;
        }
        let dst = self.pixels[idx];
        let db = dst & 0xFF;
        let dg = (dst >> 8) & 0xFF;
        let dr = (dst >> 16) & 0xFF;
        let da = (dst >> 24) & 0xFF;

        let inv = 255 - eff_a;
        let out_r = ((c.r as u32) * eff_a + dr * inv + 127) / 255;
        let out_g = ((c.g as u32) * eff_a + dg * inv + 127) / 255;
        let out_b = ((c.b as u32) * eff_a + db * inv + 127) / 255;
        let out_a = (eff_a + (da * inv + 127) / 255).min(255);
        self.pixels[idx] = (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
    }

    /// 亚像素抗锯齿填充圆角矩形（中心区域走快速扫描线，四角走精确圆弧 SDF）
    pub fn fill_round_rect(&mut self, x: i32, y: i32, w: i32, h: i32, radius: f32, c: Color4) {
        self.fill_vgrad_round_rect(x, y, w, h, radius, c, c);
    }

    /// 亚像素抗锯齿纵向渐变圆角矩形
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
        let h_denom = (h.max(1) - 1).max(1) as f32;

        for py in y0..y1 {
            let t = ((py - y) as f32 / h_denom).clamp(0.0, 1.0);
            let row_c = if top_color == bottom_color {
                top_color
            } else {
                top_color.lerp(bottom_color, t)
            };
            let dy = ((py as f32 + 0.5) - cy).abs() - hy;

            // 若当前行不在上下圆角带内，整行中间全部满覆盖度极速填充！
            if dy <= -0.75 && row_c.a == 255 && x >= 0 && (x + w) <= self.width {
                let packed = (255u32 << 24)
                    | ((row_c.r as u32) << 16)
                    | ((row_c.g as u32) << 8)
                    | (row_c.b as u32);
                let row_start = (py * self.width + x0) as usize;
                let row_end = (py * self.width + x1) as usize;
                self.pixels[row_start..row_end].fill(packed);
                continue;
            }

            for px in x0..x1 {
                let dx = ((px as f32 + 0.5) - cx).abs() - hx;
                let dist = if dx > 0.0 && dy > 0.0 {
                    (dx * dx + dy * dy).sqrt() - r
                } else {
                    dx.max(dy) - r
                };
                let cov = (0.5 - dist).clamp(0.0, 1.0);
                if cov > 0.0 {
                    self.blend_pixel(px, py, row_c, cov);
                }
            }
        }
    }

    /// 1px~2px 丝滑抗锯齿内描边圆角矩形（严格落在 `[x..x+w, y..y+h]` 边界内，绝不向外溢出半像素）
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
        let band = (r + thickness + 2.0).ceil() as i32;

        for py in y0..y1 {
            let in_y_band = (py - y) < band || (y + h - 1 - py) < band;
            let dy = ((py as f32 + 0.5) - cy).abs() - hy;

            for px in x0..x1 {
                if !in_y_band && (px - x) >= band && (x + w - 1 - px) >= band {
                    continue;
                }
                let dx = ((px as f32 + 0.5) - cx).abs() - hx;
                let dist_outer = if dx > 0.0 && dy > 0.0 {
                    (dx * dx + dy * dy).sqrt() - r
                } else {
                    dx.max(dy) - r
                };
                if dist_outer >= 0.5 || dist_outer <= -(thickness + 0.5) {
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

    /// 胶囊端帽抗锯齿矢量线段（用于绘制全部 `1.7px` 精密几何图标）
    pub fn draw_line(&mut self, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, c: Color4) {
        let r = (thickness * 0.5).max(0.45);
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

    /// Aspect-Fill 居中裁剪 + 双线性插值圆角贴图（用于 3 列图片宫格与速览缩略图）
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
                let dist = if dx > 0.0 && dy > 0.0 {
                    (dx * dx + dy * dy).sqrt() - r
                } else {
                    dx.max(dy) - r
                };
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

    // ========================================================================
    // 1.7px 几何矢量图标集（100% 纯几何绘制，零 Emoji、零系统字体缺字方块）
    // ========================================================================

    pub fn draw_icon_search(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let r = size * 0.34;
        let ox = cx - size * 0.08;
        let oy = cy - size * 0.08;
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
        let d = size * 0.32;
        self.draw_line(cx - d, cy - d, cx + d, cy + d, stroke, c);
        self.draw_line(cx + d, cy - d, cx - d, cy + d, stroke, c);
    }

    /// 极简纯净模式绿叶图标
    pub fn draw_icon_leaf(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let r = size * 0.38;
        // 叶片上下双弧折线逼近流线叶轮廓 + 对角叶脉
        let p_tip = (cx + r * 0.85, cy - r * 0.85);
        let p_base = (cx - r * 0.65, cy + r * 0.65);
        let p_top = (cx - r * 0.25, cy - r * 0.72);
        let p_right = (cx + r * 0.72, cy + r * 0.25);
        self.draw_line(p_base.0, p_base.1, p_top.0, p_top.1, stroke, c);
        self.draw_line(p_top.0, p_top.1, p_tip.0, p_tip.1, stroke, c);
        self.draw_line(p_base.0, p_base.1, p_right.0, p_right.1, stroke, c);
        self.draw_line(p_right.0, p_right.1, p_tip.0, p_tip.1, stroke, c);
        // 叶柄与主叶脉
        self.draw_line(
            cx - r * 0.92,
            cy + r * 0.92,
            cx + r * 0.32,
            cy - r * 0.32,
            stroke,
            c,
        );
    }

    /// 窗口始终在前图钉图标
    pub fn draw_icon_pin(
        &mut self,
        cx: f32,
        cy: f32,
        size: f32,
        stroke: f32,
        c: Color4,
        filled: bool,
    ) {
        let u = size * 0.42;
        // 顶帽横杠
        self.draw_line(
            cx - u * 0.55,
            cy - u * 0.82,
            cx + u * 0.55,
            cy - u * 0.82,
            stroke,
            c,
        );
        // 锥腰梯形
        self.draw_line(
            cx - u * 0.40,
            cy - u * 0.82,
            cx - u * 0.68,
            cy + u * 0.08,
            stroke,
            c,
        );
        self.draw_line(
            cx + u * 0.40,
            cy - u * 0.82,
            cx + u * 0.68,
            cy + u * 0.08,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.78,
            cy + u * 0.08,
            cx + u * 0.78,
            cy + u * 0.08,
            stroke,
            c,
        );
        if filled {
            self.fill_circle(cx, cy - u * 0.36, u * 0.36, c);
        }
        // 下方针尖
        self.draw_line(cx, cy + u * 0.08, cx, cy + u * 0.92, stroke, c);
    }

    /// 偏好设置 6 齿齿轮图标
    pub fn draw_icon_gear(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let r_mid = size * 0.30;
        let r_tooth = size * 0.43;
        self.stroke_circle(cx, cy, r_mid, stroke, c);
        for i in 0..6 {
            let angle = (i as f32) * std::f32::consts::PI / 3.0;
            let cos_a = angle.cos();
            let sin_a = angle.sin();
            self.draw_line(
                cx + cos_a * (r_mid - stroke * 0.2),
                cy + sin_a * (r_mid - stroke * 0.2),
                cx + cos_a * r_tooth,
                cy + sin_a * r_tooth,
                stroke * 1.15,
                c,
            );
        }
    }

    /// 左返回尖括号 `<`
    pub fn draw_icon_back(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let d = size * 0.34;
        self.draw_line(cx + d * 0.55, cy - d, cx - d * 0.55, cy, stroke, c);
        self.draw_line(cx - d * 0.55, cy, cx + d * 0.55, cy + d, stroke, c);
    }

    /// 链接跃迁对角发射箭头 `↗`（对齐 macOS `arrow.up.forward.app`）
    pub fn draw_icon_external_link(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let d = size * 0.34;
        let tx = cx + d;
        let ty = cy - d;
        let bx = cx - d;
        let by = cy + d;
        self.draw_line(bx, by, tx, ty, stroke, c);
        self.draw_line(tx - d * 1.05, ty, tx, ty, stroke, c);
        self.draw_line(tx, ty, tx, ty + d * 1.05, stroke, c);
    }

    /// 本地文件文档折角图标
    pub fn draw_icon_file(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let w = size * 0.34;
        let h = size * 0.42;
        let fold = size * 0.22;
        let l = cx - w;
        let r = cx + w;
        let t = cy - h;
        let b = cy + h;
        self.draw_line(l, t, r - fold, t, stroke, c);
        self.draw_line(r - fold, t, r, t + fold, stroke, c);
        self.draw_line(r, t + fold, r, b, stroke, c);
        self.draw_line(r, b, l, b, stroke, c);
        self.draw_line(l, b, l, t, stroke, c);
        // 折角内折线
        self.draw_line(r - fold, t, r - fold, t + fold, stroke * 0.85, c);
        self.draw_line(r - fold, t + fold, r, t + fold, stroke * 0.85, c);
    }

    /// 收藏五角星（支持实心抗锯齿填充与空心描边）
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
                    // 2x2 超采样抗锯齿填充五角星
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

    /// 精致垃圾桶矢量图标
    pub fn draw_icon_trash(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let u = size * 0.38;
        // 顶盖与提手
        self.draw_line(
            cx - u * 0.92,
            cy - u * 0.52,
            cx + u * 0.92,
            cy - u * 0.52,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.35,
            cy - u * 0.84,
            cx + u * 0.35,
            cy - u * 0.84,
            stroke,
            c,
        );
        // 桶身外轮廓
        self.draw_line(
            cx - u * 0.70,
            cy - u * 0.48,
            cx - u * 0.58,
            cy + u * 0.88,
            stroke,
            c,
        );
        self.draw_line(
            cx + u * 0.70,
            cy - u * 0.48,
            cx + u * 0.58,
            cy + u * 0.88,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.58,
            cy + u * 0.88,
            cx + u * 0.58,
            cy + u * 0.88,
            stroke,
            c,
        );
        // 桶内双竖线
        self.draw_line(
            cx - u * 0.22,
            cy - u * 0.12,
            cx - u * 0.20,
            cy + u * 0.54,
            stroke * 0.85,
            c,
        );
        self.draw_line(
            cx + u * 0.22,
            cy - u * 0.12,
            cx + u * 0.20,
            cy + u * 0.54,
            stroke * 0.85,
            c,
        );
    }

    /// 快捷变换微闪电几何图标
    pub fn draw_icon_bolt(&mut self, cx: f32, cy: f32, size: f32, stroke: f32, c: Color4) {
        let u = size * 0.40;
        self.draw_line(
            cx + u * 0.15,
            cy - u * 0.95,
            cx - u * 0.55,
            cy + u * 0.06,
            stroke,
            c,
        );
        self.draw_line(
            cx - u * 0.55,
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
            cy + u * 0.95,
            stroke,
            c,
        );
    }

    /// 原生质感胶囊拨动开关（对齐 macOS Toggle Switch）
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
        let track_color = if is_on {
            accent
        } else {
            Color4::rgba(62, 74, 98, 220)
        };
        self.fill_round_rect(x, y, w, h, r, track_color);
        if !is_on {
            self.stroke_round_rect(x, y, w, h, r, 1.0, Color4::rgba(148, 172, 214, 48));
        }
        let pad = ((h as f32) * 0.14).max(2.0);
        let knob_r = r - pad;
        let knob_cx = if is_on {
            (x + w) as f32 - r
        } else {
            (x as f32) + r
        };
        let knob_cy = (y as f32) + r;
        self.fill_circle(knob_cx, knob_cy, knob_r, Color4::rgb(255, 255, 255));
    }

    /// 液态玻璃背景模糊浓度无级滑杆（0% ~ 100%）
    pub fn draw_concentration_slider(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        pct: u8,
        accent: Color4,
    ) {
        let track_h = ((h as f32) * 0.30).round().max(4.0) as i32;
        let ty = y + (h - track_h) / 2;
        let tr = (track_h as f32) * 0.5;
        self.fill_round_rect(x, ty, w, track_h, tr, Color4::rgba(62, 74, 98, 210));
        let ratio = (pct.min(100) as f32) / 100.0;
        let fill_w = ((w as f32) * ratio).round() as i32;
        if fill_w > 0 {
            self.fill_round_rect(x, ty, fill_w.max(track_h), track_h, tr, accent);
        }
        let knob_r = ((h as f32) * 0.38).max(6.5);
        let knob_cx =
            (x as f32 + (w as f32) * ratio).clamp(x as f32 + knob_r, (x + w) as f32 - knob_r);
        let knob_cy = (y as f32) + (h as f32) * 0.5;
        self.fill_circle(knob_cx, knob_cy, knob_r, Color4::rgb(255, 255, 255));
        self.stroke_circle(knob_cx, knob_cy, knob_r, 1.2, accent);
    }
}

#[inline]
fn pack_premultiplied_bgra(c: Color4, _unused: u8) -> u32 {
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
