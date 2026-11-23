#!/usr/bin/env python3
"""
Generate 4 distinct, geometrically rigorous SVG logo concepts + custom vector wordmark lockups
for iClip, plus 1024x1024 macOS Tahoe Liquid Glass squircle app icon masters.
"""
import math
from pathlib import Path

OUT_DIR = Path("/Users/fanaruto/Project/Personal/iClip/assets/brand")
CONCEPTS_DIR = OUT_DIR / "concepts"
CONCEPTS_DIR.mkdir(parents=True, exist_ok=True)


def fmt(v: float) -> str:
    if abs(v - round(v)) < 1e-4:
        return str(int(round(v)))
    return f"{v:.2f}".rstrip("0").rstrip(".")


def arc_ribbon_path(cx: float, cy: float, r_mid: float, half_w: float, deg_start: float, deg_end: float) -> str:
    """
    Construct a closed filled thick-arc stadium ribbon (exact circular outer/inner arcs + semicircular end caps).
    Angles in degrees (screen coords: +x right, +y down). Sweeps clockwise (positive angle direction)
    from deg_start to deg_end (where deg_end > deg_start).
    """
    r_out = r_mid + half_w
    r_in = r_mid - half_w
    a1 = math.radians(deg_start)
    a2 = math.radians(deg_end)
    large_arc = 1 if (deg_end - deg_start) > 180.0 else 0

    # Outer start -> Outer end (clockwise: sweep=1)
    ox1, oy1 = cx + r_out * math.cos(a1), cy + r_out * math.sin(a1)
    ox2, oy2 = cx + r_out * math.cos(a2), cy + r_out * math.sin(a2)
    # Inner end -> Inner start (counter-clockwise: sweep=0)
    ix2, iy2 = cx + r_in * math.cos(a2), cy + r_in * math.sin(a2)
    ix1, iy1 = cx + r_in * math.cos(a1), cy + r_in * math.sin(a1)

    return (
        f"M {fmt(ox1)} {fmt(oy1)} "
        f"A {fmt(r_out)} {fmt(r_out)} 0 {large_arc} 1 {fmt(ox2)} {fmt(oy2)} "
        f"A {fmt(half_w)} {fmt(half_w)} 0 0 1 {fmt(ix2)} {fmt(iy2)} "
        f"A {fmt(r_in)} {fmt(r_in)} 0 {large_arc} 0 {fmt(ix1)} {fmt(iy1)} "
        f"A {fmt(half_w)} {fmt(half_w)} 0 0 1 {fmt(ox1)} {fmt(oy1)} Z"
    )


def circle_path(cx: float, cy: float, r: float, ccw: bool = False) -> str:
    sweep = 0 if ccw else 1
    return (
        f"M {fmt(cx)} {fmt(cy - r)} "
        f"A {fmt(r)} {fmt(r)} 0 1 {sweep} {fmt(cx)} {fmt(cy + r)} "
        f"A {fmt(r)} {fmt(r)} 0 1 {sweep} {fmt(cx)} {fmt(cy - r)} Z"
    )


def rounded_rect_path(x: float, y: float, w: float, h: float, r: float, ccw: bool = False) -> str:
    r = min(r, w / 2, h / 2)
    if not ccw:
        return (
            f"M {fmt(x + r)} {fmt(y)} "
            f"H {fmt(x + w - r)} "
            f"A {fmt(r)} {fmt(r)} 0 0 1 {fmt(x + w)} {fmt(y + r)} "
            f"V {fmt(y + h - r)} "
            f"A {fmt(r)} {fmt(r)} 0 0 1 {fmt(x + w - r)} {fmt(y + h)} "
            f"H {fmt(x + r)} "
            f"A {fmt(r)} {fmt(r)} 0 0 1 {fmt(x)} {fmt(y + h - r)} "
            f"V {fmt(y + r)} "
            f"A {fmt(r)} {fmt(r)} 0 0 1 {fmt(x + r)} {fmt(y)} Z"
        )
    else:
        return (
            f"M {fmt(x + r)} {fmt(y)} "
            f"A {fmt(r)} {fmt(r)} 0 0 0 {fmt(x)} {fmt(y + r)} "
            f"V {fmt(y + h - r)} "
            f"A {fmt(r)} {fmt(r)} 0 0 0 {fmt(x + r)} {fmt(y + h)} "
            f"H {fmt(x + w - r)} "
            f"A {fmt(r)} {fmt(r)} 0 0 0 {fmt(x + w)} {fmt(y + h - r)} "
            f"V {fmt(y + r)} "
            f"A {fmt(r)} {fmt(r)} 0 0 0 {fmt(x + w - r)} {fmt(y)} Z"
        )


def rot_pt(x: float, y: float, cx: float, cy: float, deg: float) -> tuple[float, float]:
    rad = math.radians(deg)
    dx, dy = x - cx, y - cy
    return (cx + dx * math.cos(rad) - dy * math.sin(rad), cy + dx * math.sin(rad) + dy * math.cos(rad))


def stadium_segment_path(x1: float, y1: float, x2: float, y2: float, r: float) -> str:
    dx, dy = x2 - x1, y2 - y1
    L = math.hypot(dx, dy)
    nx, ny = -dy / L * r, dx / L * r
    p1x, p1y = x1 + nx, y1 + ny
    p2x, p2y = x2 + nx, y2 + ny
    p3x, p3y = x2 - nx, y2 - ny
    p4x, p4y = x1 - nx, y1 - ny
    return (
        f"M {fmt(p1x)} {fmt(p1y)} "
        f"L {fmt(p2x)} {fmt(p2y)} "
        f"A {fmt(r)} {fmt(r)} 0 0 1 {fmt(p3x)} {fmt(p3y)} "
        f"L {fmt(p4x)} {fmt(p4y)} "
        f"A {fmt(r)} {fmt(r)} 0 0 1 {fmt(p1x)} {fmt(p1y)} Z"
    )


# ---------------------------------------------------------------------------
# Concept A: 磁吸星环 · Magnetic i-Loop (Letterform + Abstract Monogram i + C)
# Bold sculpted C-arc (44-unit ribbon) + orbital magnetic i-dot sphere in upper-right pocket.
# ---------------------------------------------------------------------------
def build_concept_a_paths() -> list[str]:
    c_arc = arc_ribbon_path(cx=120, cy=128, r_mid=72, half_w=22, deg_start=24, deg_end=282)
    i_dot = circle_path(cx=198, cy=86, r=26)
    return [c_arc, i_dot]


# ---------------------------------------------------------------------------
# Concept B: 叠影流光 · Cascade Glass Layers (Negative-space twin cards + i-clasp)
# Rear rounded card + front offset rounded card separated by crisp L-moat, with a negative-space
# capsule clasp cut cleanly inside the front card, evoking ⌥V cascade & instant capture.
# ---------------------------------------------------------------------------
def build_concept_b_paths() -> list[str]:
    # Rear card [24..172, 24..172, r=36] separated by bold 24-unit moat from front card [84..232, 84..232, r=36]
    # Moat outer boundary is [60..256, 60..256, r=60] -> at x=172, y=60; at y=172, x=60!
    rear_l = (
        "M 60 24 "
        "H 136 "
        "A 36 36 0 0 1 172 60 "
        "H 120 "
        "A 60 60 0 0 0 60 120 "
        "V 172 "
        "A 36 36 0 0 1 24 136 "
        "V 60 "
        "A 36 36 0 0 1 60 24 Z"
    )
    front_outer = rounded_rect_path(84, 84, 148, 148, 36, ccw=False)
    hole_dot = circle_path(158, 120, 15, ccw=True)
    hole_stem = rounded_rect_path(144, 149, 28, 53, 14, ccw=True)
    return [rear_l, f"{front_outer} {hole_dot} {hole_stem}"]


# ---------------------------------------------------------------------------
# Concept C: 折光回形 · Swiss Isometric Clip (Continuous geometric clip + i-pearl)
# A heavy 28-unit stadium clip rotated at exact -45°, with generous 26-unit channels
# and a detached circular pearl at the inner focal point so it reads as both 'i' and a modern clip.
# ---------------------------------------------------------------------------
def build_concept_c_paths() -> list[str]:
    # Constant 28-unit stadium clip rotated +45°, scaled and optically centred at (128, 128)
    # so L/R/T/B margins are balanced (~31..34) and every channel stays >= 24 units wide.
    cx0, cy0 = 120.5, 130.5
    ang = 45.0
    scale = 1.12

    def P(ux: float, uy: float) -> str:
        rx, ry = rot_pt(cx0 + ux * scale, cy0 + uy * scale, cx0, cy0, ang)
        return f"{fmt(rx)} {fmt(ry)}"

    r65 = fmt(65 * scale)
    r39 = fmt(39 * scale)
    r13 = fmt(13 * scale)

    clip_ribbon = (
        f"M {P(-65, 34)} "
        f"L {P(-65, -34)} "
        f"A {r65} {r65} 0 0 1 {P(65, -34)} "
        f"L {P(65, 38)} "
        f"A {r39} {r39} 0 0 1 {P(-13, 38)} "
        f"L {P(-13, 12)} "
        f"A {r13} {r13} 0 0 1 {P(13, 12)} "
        f"L {P(13, 38)} "
        f"A {r13} {r13} 0 0 0 {P(39, 38)} "
        f"L {P(39, -34)} "
        f"A {r39} {r39} 0 0 0 {P(-39, -34)} "
        f"L {P(-39, 34)} "
        f"A {r13} {r13} 0 0 1 {P(-65, 34)} Z"
    )
    dot_cx, dot_cy = rot_pt(cx0, cy0 - 34 * scale, cx0, cy0, ang)
    dot_path = circle_path(dot_cx, dot_cy, round(15.5 * scale, 1))
    return [clip_ribbon, dot_path]


# ---------------------------------------------------------------------------
# Concept D: 光标虹吸 · Cursor Portal (Rounded squircle C-frame + precision cursor arrow)
# Visualizes ⌥V / Alt+V summoning the Liquid Glass panel right beside your cursor.
# ---------------------------------------------------------------------------
def build_concept_d_paths() -> list[str]:
    # Bold open rounded-frame (34..202, 34..202) open at bottom-right + crisp geometric cursor arrow
    # Frame outer: x=30..202, y=30..202, rx=48, wall thickness=34 (inner x=64..168, y=64..168, rx=22)
    # Open on right below y=108 and bottom right of x=108, with semicircular end caps (r=17)!
    # Let's trace cleanly:
    # Top-right cap centered at (185, 104), r=17 -> outer (202, 104), inner (168, 104)
    # Bottom-left-ish cap centered at (104, 185), r=17 -> outer (104, 202), inner (104, 168)
    frame = (
        "M 202 96 "
        "V 78 "
        "A 48 48 0 0 0 154 30 "
        "H 78 "
        "A 48 48 0 0 0 30 78 "
        "V 154 "
        "A 48 48 0 0 0 78 202 "
        "H 96 "
        "A 17 17 0 0 0 96 168 "
        "H 86 "
        "A 22 22 0 0 1 64 146 "
        "V 86 "
        "A 22 22 0 0 1 86 64 "
        "H 146 "
        "A 22 22 0 0 1 168 86 "
        "V 96 "
        "A 17 17 0 0 0 202 96 Z"
    )
    cursor = (
        "M 129 120 "
        "L 222 154 "
        "A 8 8 0 0 1 222 169 "
        "L 186 186 "
        "L 169 222 "
        "A 8 8 0 0 1 154 222 "
        "L 120 129 "
        "A 7 7 0 0 1 129 120 Z"
    )
    return [frame, cursor]


# ---------------------------------------------------------------------------
# Custom Outlined Vector Wordmark "iClip" (height 256, placed in lockup 0 0 760 256)
# Zero <text> elements — 100% bespoke geometric letterforms matching the symbol's stroke DNA!
# ---------------------------------------------------------------------------
def build_wordmark_paths(ox: float = 276.0) -> list[str]:
    """
    Constructs 'i', 'C', 'l', 'i', 'p' on baseline y=188, cap-height y=68 (H=120), x-height y=100 (h=88),
    descender y=222, stem width s=22. All pure paths!
    """
    paths = []
    s = 22.0
    hs = s / 2.0

    # 1. 'i' at x = ox + 0..22
    ix = ox
    paths.append(circle_path(ix + hs, 74, 13))
    paths.append(rounded_rect_path(ix, 100, s, 88, hs))

    # 2. 'C' at x = ox + 44..154
    cx = ox + 104
    paths.append(arc_ribbon_path(cx, 128, 49, 11.5, 38, 322))

    # 3. 'l' at x = ox + 176..198 (balanced kerning after open 'C')
    lx = ox + 176
    paths.append(rounded_rect_path(lx, 64, s, 124, hs))

    # 4. 'i' at x = ox + 220..242
    i2x = ox + 220
    paths.append(circle_path(i2x + hs, 74, 13))
    paths.append(rounded_rect_path(i2x, 100, s, 88, hs))

    # 5. 'p' at x = ox + 264..354: exact circle-circle intersection at top shoulder (zero self-overlap!)
    px = ox + 264
    c1x, c1y, r1 = px + 11.0, 111.0, 11.0
    c2x, c2y, r2 = px + 45.0, 144.0, 45.0
    dx, dy = c2x - c1x, c2y - c1y
    dist = math.hypot(dx, dy)
    a_len = (r1 * r1 - r2 * r2 + dist * dist) / (2.0 * dist)
    h_len = math.sqrt(max(0.0, r1 * r1 - a_len * a_len))
    mx = c1x + a_len * dx / dist
    my = c1y + a_len * dy / dist
    # Upper shoulder intersection (smaller y):
    sh_x = mx + h_len * dy / dist
    sh_y = my - h_len * dx / dist
    # Bottom join where bowl meets x = px + 22:
    bot_join_y = c2y + math.sqrt(r2 * r2 - (c2x - (px + 22.0)) ** 2)

    stem_and_bowl_outer = (
        f"M {fmt(px)} 111 "
        f"A 11 11 0 0 1 {fmt(sh_x)} {fmt(sh_y)} "
        f"A 45 45 0 1 1 {fmt(px + 22)} {fmt(bot_join_y)} "
        f"V 211 "
        f"A 11 11 0 0 1 {fmt(px)} 211 "
        f"Z "
        + circle_path(c2x, c2y, 23, ccw=True)
    )
    paths.append(stem_and_bowl_outer)
    return paths


def write_symbol_svg(path: Path, title: str, subpaths: list[str], fill: str = "#111827") -> None:
    body = "\n  ".join(
        f'<path fill="{fill}" fill-rule="evenodd" d="{d}"/>' if "Z M" in d else f'<path fill="{fill}" d="{d}"/>'
        for d in subpaths
    )
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256" role="img" aria-labelledby="title">
  <title id="title">{title}</title>
  <g id="symbol">
  {body}
  </g>
</svg>
"""
    path.write_text(svg, encoding="utf-8")


def write_lockup_svg(path: Path, title: str, sym_paths: list[str], fill: str = "#111827") -> None:
    wm_paths = build_wordmark_paths(ox=272.0)
    sym_body = "\n    ".join(
        f'<path fill="{fill}" fill-rule="evenodd" d="{d}"/>' if "Z M" in d else f'<path fill="{fill}" d="{d}"/>'
        for d in sym_paths
    )
    wm_body = "\n    ".join(
        f'<path fill="{fill}" fill-rule="evenodd" d="{d}"/>' if "Z M" in d else f'<path fill="{fill}" d="{d}"/>'
        for d in wm_paths
    )
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 656 256" width="656" height="256" role="img" aria-labelledby="title">
  <title id="title">{title}</title>
  <g id="symbol">
    {sym_body}
  </g>
  <g id="wordmark">
    {wm_body}
  </g>
</svg>
"""
    path.write_text(svg, encoding="utf-8")


def main() -> None:
    concepts = [
        ("a", "iClip Concept A — Magnetic i-Loop", build_concept_a_paths()),
        ("b", "iClip Concept B — Cascade Glass", build_concept_b_paths()),
        ("c", "iClip Concept C — Swiss Isometric Clip", build_concept_c_paths()),
        ("d", "iClip Concept D — Cursor Portal", build_concept_d_paths()),
    ]
    for key, title, paths in concepts:
        write_symbol_svg(CONCEPTS_DIR / f"concept-{key}-symbol.svg", title, paths)
        write_lockup_svg(CONCEPTS_DIR / f"concept-{key}-lockup.svg", f"{title} Lockup", paths)
    print("Generated 4 symbol + lockup SVG pairs in", CONCEPTS_DIR)


if __name__ == "__main__":
    main()
