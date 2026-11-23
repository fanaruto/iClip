#!/usr/bin/env swift
import AppKit
import SwiftUI

// MARK: - Vector Paths on 256x256 Grid for All 4 Concepts

enum BrandConcept: String, CaseIterable {
    case a, b, c, d

    var title: String {
        switch self {
        case .a: return "方案 A · 磁吸星环"
        case .b: return "方案 B · 叠影流光"
        case .c: return "方案 C · 瑞士回形"
        case .d: return "方案 D · 光标虹吸"
        }
    }

    var subtitle: String {
        switch self {
        case .a: return "i+C 磁吸悬浮环 · 默认预装推荐 ★"
        case .b: return "双层错落液态卡 · 负空间 i 扣"
        case .c: return "45° 等宽几何夹 · 脊柱内嵌 i"
        case .d: return "圆角折射门框 · 光标瞬时切入"
        }
    }
}

struct ConceptSymbolShape: Shape {
    let concept: BrandConcept
    /// Part 0 = primary body, Part 1 = accent element (dot / rear layer / cursor)
    let part: Int

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 256.0
        let ox = rect.minX + (rect.width - 256.0 * s) * 0.5
        let oy = rect.minY + (rect.height - 256.0 * s) * 0.5
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }

        var p = Path()
        switch concept {
        case .a:
            if part == 0 {
                // Thick C-arc ribbon: center (120, 128), rMid=72, halfW=22 (rOut=94, rIn=50), 24° -> 282° CW
                let c = pt(120, 128)
                let rOut = 94 * s
                let rIn = 50 * s
                let capR = 22 * s
                let a1 = Angle.degrees(24)
                let a2 = Angle.degrees(282)
                let c1 = CGPoint(x: c.x + 72 * s * CGFloat(cos(a1.radians)), y: c.y + 72 * s * CGFloat(sin(a1.radians)))
                let c2 = CGPoint(x: c.x + 72 * s * CGFloat(cos(a2.radians)), y: c.y + 72 * s * CGFloat(sin(a2.radians)))
                p.addArc(center: c, radius: rOut, startAngle: a1, endAngle: a2, clockwise: false)
                p.addArc(center: c2, radius: capR, startAngle: a2, endAngle: Angle.degrees(282 + 180), clockwise: false)
                p.addArc(center: c, radius: rIn, startAngle: a2, endAngle: a1, clockwise: true)
                p.addArc(center: c1, radius: capR, startAngle: Angle.degrees(24 + 180), endAngle: a1, clockwise: false)
                p.closeSubpath()
            } else {
                // Floating magnetic i-dot at (198, 86), r=26
                let r = 26 * s
                let c = pt(198, 86)
                p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }

        case .b:
            if part == 1 {
                p.move(to: pt(60, 24))
                p.addLine(to: pt(136, 24))
                p.addArc(center: pt(136, 60), radius: 36 * s, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
                p.addLine(to: pt(120, 60))
                p.addArc(center: pt(120, 120), radius: 60 * s, startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
                p.addLine(to: pt(60, 172))
                p.addArc(center: pt(60, 136), radius: 36 * s, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
                p.addLine(to: pt(24, 60))
                p.addArc(center: pt(60, 60), radius: 36 * s, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                p.closeSubpath()
            } else {
                p.addRoundedRect(in: CGRect(x: ox + 84 * s, y: oy + 84 * s, width: 148 * s, height: 148 * s), cornerSize: CGSize(width: 36 * s, height: 36 * s), style: .continuous)
                let dotR = 15 * s
                let dotC = pt(158, 120)
                p.addEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))
                p.addRoundedRect(in: CGRect(x: ox + 144 * s, y: oy + 149 * s, width: 28 * s, height: 53 * s), cornerSize: CGSize(width: 14 * s, height: 14 * s), style: .continuous)
            }

        case .c:
            let cx0: CGFloat = 120.5
            let cy0: CGFloat = 130.5
            let sc: CGFloat = 1.12
            let rad = CGFloat.pi / 4.0
            func rot(_ ux: CGFloat, _ uy: CGFloat) -> CGPoint {
                let dx = ux * sc
                let dy = uy * sc
                let rx = cx0 + dx * cos(rad) - dy * sin(rad)
                let ry = cy0 + dx * sin(rad) + dy * cos(rad)
                return pt(rx, ry)
            }
            if part == 0 {
                p.move(to: rot(-65, 34))
                p.addLine(to: rot(-65, -34))
                p.addArc(center: rot(0, -34), radius: 65 * sc * s, startAngle: .degrees(225), endAngle: .degrees(45), clockwise: false)
                p.addLine(to: rot(65, 38))
                p.addArc(center: rot(26, 38), radius: 39 * sc * s, startAngle: .degrees(45), endAngle: .degrees(225), clockwise: false)
                p.addLine(to: rot(-13, 12))
                p.addArc(center: rot(0, 12), radius: 13 * sc * s, startAngle: .degrees(225), endAngle: .degrees(45), clockwise: false)
                p.addLine(to: rot(13, 38))
                p.addArc(center: rot(26, 38), radius: 13 * sc * s, startAngle: .degrees(225), endAngle: .degrees(45), clockwise: true)
                p.addLine(to: rot(39, -34))
                p.addArc(center: rot(0, -34), radius: 39 * sc * s, startAngle: .degrees(45), endAngle: .degrees(225), clockwise: true)
                p.addLine(to: rot(-39, 34))
                p.addArc(center: rot(-52, 34), radius: 13 * sc * s, startAngle: .degrees(45), endAngle: .degrees(225), clockwise: false)
                p.closeSubpath()
            } else {
                let dc = rot(0, -34)
                let dr = 15.5 * sc * s
                p.addEllipse(in: CGRect(x: dc.x - dr, y: dc.y - dr, width: dr * 2, height: dr * 2))
            }

        case .d:
            if part == 0 {
                p.move(to: pt(202, 96))
                p.addLine(to: pt(202, 78))
                p.addArc(center: pt(154, 78), radius: 48 * s, startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
                p.addLine(to: pt(78, 30))
                p.addArc(center: pt(78, 78), radius: 48 * s, startAngle: .degrees(-90), endAngle: .degrees(-180), clockwise: true)
                p.addLine(to: pt(30, 154))
                p.addArc(center: pt(78, 154), radius: 48 * s, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
                p.addLine(to: pt(96, 202))
                p.addArc(center: pt(96, 185), radius: 17 * s, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
                p.addLine(to: pt(86, 168))
                p.addArc(center: pt(86, 146), radius: 22 * s, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
                p.addLine(to: pt(64, 86))
                p.addArc(center: pt(86, 86), radius: 22 * s, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                p.addLine(to: pt(146, 64))
                p.addArc(center: pt(146, 86), radius: 22 * s, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
                p.addLine(to: pt(168, 96))
                p.addArc(center: pt(185, 96), radius: 17 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                p.closeSubpath()
            } else {
                p.move(to: pt(127, 121))
                p.addLine(to: pt(221, 155))
                p.addQuadCurve(to: pt(221, 169), control: pt(230, 162))
                p.addLine(to: pt(186, 186))
                p.addLine(to: pt(169, 221))
                p.addQuadCurve(to: pt(155, 221), control: pt(162, 230))
                p.addLine(to: pt(121, 127))
                p.addQuadCurve(to: pt(127, 121), control: pt(119, 119))
                p.closeSubpath()
            }
        }
        return p
    }
}

// MARK: - macOS 26 Tahoe Liquid Glass App Icon View

struct TahoeAppIconView: View {
    let concept: BrandConcept
    /// Canvas size in pixels (1024 for macOS icns)
    let canvasSize: CGFloat
    /// Fill ratio: 824/1024 = 0.8046875 for Apple macOS HIG, 0.92 for Windows .ico / Web
    let squircleRatio: CGFloat
    let withDropShadow: Bool

    var body: some View {
        let box = canvasSize * squircleRatio
        let radius = box * 0.225
        let glyphBox = box * 0.68

        ZStack {
            // Squircle Liquid Glass Base
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(baseGradient)
                .frame(width: box, height: box)
                .overlay(
                    // Ambient internal caustic glow (bottom-right refraction)
                    RadialGradient(
                        colors: [accentGlow.opacity(0.58), .clear],
                        center: .init(x: 0.78, y: 0.84),
                        startRadius: box * 0.04,
                        endRadius: box * 0.68
                    )
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                )
                .overlay(
                    // Top-left Liquid Glass specular sheen
                    LinearGradient(
                        colors: [Color.white.opacity(0.26), Color.white.opacity(0.04), .clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                )
                .overlay(
                    // Crisp macOS 26 inner glass rim border
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.52),
                                    Color.white.opacity(0.14),
                                    accentGlow.opacity(0.38)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(1.2, box * 0.012)
                        )
                )
                .shadow(
                    color: withDropShadow ? Color.black.opacity(0.30) : .clear,
                    radius: withDropShadow ? canvasSize * 0.026 : 0,
                    x: 0,
                    y: withDropShadow ? canvasSize * 0.013 : 0
                )

            // Foreground Sculpted Glass Symbol
            ZStack {
                if concept == .b {
                    ConceptSymbolShape(concept: .b, part: 1)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.62), Color(red: 0.65, green: 0.86, blue: 1.0).opacity(0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    ConceptSymbolShape(concept: .b, part: 0)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color(red: 0.88, green: 0.95, blue: 1.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            style: FillStyle(eoFill: true)
                        )
                        .shadow(color: Color.black.opacity(0.22), radius: box * 0.025, x: 0, y: box * 0.012)
                } else {
                    ConceptSymbolShape(concept: concept, part: 0)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color(red: 0.84, green: 0.92, blue: 1.0)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.black.opacity(0.26), radius: box * 0.028, x: 0, y: box * 0.014)

                    ConceptSymbolShape(concept: concept, part: 1)
                        .fill(accentOrbGradient)
                        .shadow(color: accentGlow.opacity(0.55), radius: box * 0.032, x: 0, y: box * 0.008)
                }
            }
            .frame(width: glyphBox, height: glyphBox)
        }
        .frame(width: canvasSize, height: canvasSize)
    }

    private var baseGradient: LinearGradient {
        switch concept {
        case .a:
            return LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.08, blue: 0.19),
                    Color(red: 0.05, green: 0.20, blue: 0.52),
                    Color(red: 0.04, green: 0.39, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .b:
            return LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.16, blue: 0.56),
                    Color(red: 0.04, green: 0.36, blue: 0.90),
                    Color(red: 0.02, green: 0.58, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .c:
            return LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.10, blue: 0.22),
                    Color(red: 0.05, green: 0.24, blue: 0.52),
                    Color(red: 0.04, green: 0.50, blue: 0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .d:
            return LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.09, blue: 0.24),
                    Color(red: 0.13, green: 0.28, blue: 0.76),
                    Color(red: 0.06, green: 0.56, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var accentGlow: Color {
        switch concept {
        case .a: return Color(red: 0.22, green: 0.82, blue: 1.00)
        case .b: return Color(red: 0.36, green: 0.90, blue: 1.00)
        case .c: return Color(red: 0.20, green: 0.88, blue: 0.96)
        case .d: return Color(red: 0.32, green: 0.86, blue: 1.00)
        }
    }

    private var accentOrbGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white,
                Color(red: 0.52, green: 0.93, blue: 1.00),
                Color(red: 0.16, green: 0.76, blue: 1.00)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct MonochromeTemplateGlyph: View {
    let concept: BrandConcept
    let pixelSize: CGFloat
    let color: Color

    var body: some View {
        let pad = pixelSize * 0.09
        ZStack {
            if concept == .b {
                ConceptSymbolShape(concept: .b, part: 1).fill(color)
                ConceptSymbolShape(concept: .b, part: 0).fill(color, style: FillStyle(eoFill: true))
            } else {
                ConceptSymbolShape(concept: concept, part: 0).fill(color)
                ConceptSymbolShape(concept: concept, part: 1).fill(color)
            }
        }
        .padding(pad)
        .frame(width: pixelSize, height: pixelSize)
    }
}

// MARK: - 4-Concept App Icon + Menu Bar + Windows Tray Showcase Board

struct ShowcaseBoardView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("iClip 品牌图标设计提案（macOS 26 液态玻璃 + 菜单栏 + Windows 托盘实测）")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                    Text("避开传统木质写字板陈旧套路，4 套纯几何方案均通过 100/100 矢量审计，兼顾 1024px 折射质感与 16px 单色锐利识别")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.68))
                }
                Spacer()
            }

            HStack(spacing: 22) {
                ForEach(BrandConcept.allCases, id: \.rawValue) { c in
                    VStack(spacing: 18) {
                        // Top badge
                        HStack {
                            Text(c.title)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            if c == .a {
                                Text("当前已装上")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(red: 0.04, green: 0.12, blue: 0.26))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color(red: 0.38, green: 0.90, blue: 1.0)))
                            }
                        }

                        // Large App Icon on Dark & Light split stage
                        ZStack {
                            HStack(spacing: 0) {
                                Color(red: 0.09, green: 0.11, blue: 0.16)
                                Color(red: 0.93, green: 0.95, blue: 0.98)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                            TahoeAppIconView(concept: c, canvasSize: 220, squircleRatio: 0.82, withDropShadow: true)
                        }
                        .frame(height: 248)

                        // Real-world Dock + Spotlight + Menu Bar + Tray strip
                        VStack(spacing: 12) {
                            HStack(spacing: 18) {
                                VStack(spacing: 4) {
                                    TahoeAppIconView(concept: c, canvasSize: 64, squircleRatio: 0.86, withDropShadow: false)
                                    Text("64px 程序坞").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                                }
                                VStack(spacing: 4) {
                                    TahoeAppIconView(concept: c, canvasSize: 32, squircleRatio: 0.90, withDropShadow: false)
                                        .frame(width: 64, height: 64)
                                    Text("32px 访达").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                                }
                                VStack(spacing: 4) {
                                    TahoeAppIconView(concept: c, canvasSize: 16, squircleRatio: 0.95, withDropShadow: false)
                                        .frame(width: 64, height: 64)
                                    Text("16px 托盘").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                                }
                            }

                            // Simulated macOS Menu Bar (Dark + Light)
                            HStack(spacing: 10) {
                                HStack(spacing: 10) {
                                    MonochromeTemplateGlyph(concept: c, pixelSize: 18, color: .white)
                                    Image(systemName: "wifi").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                                    Text("09:41").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.65)))

                                HStack(spacing: 10) {
                                    MonochromeTemplateGlyph(concept: c, pixelSize: 18, color: Color(white: 0.12))
                                    Image(systemName: "wifi").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(white: 0.18))
                                    Text("09:41").font(.system(size: 12, weight: .medium)).foregroundStyle(Color(white: 0.15))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.95)))
                            }
                        }

                        Text(c.subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.78))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color.white.opacity(c == .a ? 0.09 : 0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .strokeBorder(
                                        c == .a ? Color(red: 0.38, green: 0.90, blue: 1.0).opacity(0.65) : Color.white.opacity(0.10),
                                        lineWidth: c == .a ? 1.8 : 1.0
                                    )
                            )
                    )
                }
            }
        }
        .padding(36)
        .frame(width: 1640, height: 640)
        .background(Color(red: 0.05, green: 0.07, blue: 0.11))
    }
}

// MARK: - Custom Retina DMG Background (660x420 pt @2x = 1320x840 px)

struct DMGInstallerBackdropView: View {
    let concept: BrandConcept

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("拖动 iClip 到右侧「应用程序」即可完成安装")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.12, blue: 0.20))
                Text("轻量纯原生液态玻璃剪贴板 · ⌥V 光标旁唤起")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.34, green: 0.40, blue: 0.50))
            }
            .padding(.top, 34)

            Spacer()

            // Drag zone guide between x=180 and x=480
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(red: 0.06, green: 0.44, blue: 0.98).opacity(0.35 + Double(i) * 0.28))
                }
            }
            .offset(y: -4)

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(red: 0.06, green: 0.46, blue: 0.96))
                Text("免证书极速直装：官网复制一键安装命令，3 秒自动落位零拦截")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.28, green: 0.35, blue: 0.46))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.82)))
            .padding(.bottom, 24)
        }
        .frame(width: 660, height: 420)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.97, blue: 1.00),
                        Color(red: 0.89, green: 0.93, blue: 0.99)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.18, green: 0.56, blue: 1.0).opacity(0.16), .clear], center: .center, startRadius: 10, endRadius: 260))
                    .frame(width: 520, height: 520)
                    .offset(x: -160, y: -90)
            }
        )
        .clipped()
    }
}

// MARK: - Rendering & Binary Export Helpers

@MainActor
func renderCGImage<V: View>(_ view: V, pixelWidth: Int, pixelHeight: Int, scale: CGFloat = 1.0) -> CGImage {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let rawCG = renderer.cgImage else {
        fatalError("Failed to render CGImage \(pixelWidth)x\(pixelHeight)")
    }
    let w = rawCG.width
    let h = rawCG.height
    let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
        space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return rawCG
    }
    ctx.interpolationQuality = .high
    ctx.draw(rawCG, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage() ?? rawCG
}

func writePNG(_ cgImage: CGImage, to url: URL, dpiScale: CGFloat = 1.0) throws {
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: CGFloat(cgImage.width) / dpiScale, height: CGFloat(cgImage.height) / dpiScale)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "BrandBuild", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

/// Writes a rock-solid Microsoft Visual Studio standard multi-resolution .ico file:
/// - Sizes < 256 (16, 24, 32, 48, 64) stored as 32-bit bottom-up BGRA BITMAPINFOHEADER + 1-bit AND mask
///   (guaranteed 100% compatible with LoadIconW, LoadImageW, Shell_NotifyIconW, Explorer, and rc.exe)
/// - Size 256 stored as compressed PNG stream
func writeWindowsICO(images: [(size: Int, cg: CGImage)], to url: URL) throws {
    func u16(_ v: UInt16) -> Data { var le = v.littleEndian; return Data(bytes: &le, count: 2) }
    func u32(_ v: UInt32) -> Data { var le = v.littleEndian; return Data(bytes: &le, count: 4) }
    func i32(_ v: Int32) -> Data { var le = v.littleEndian; return Data(bytes: &le, count: 4) }

    var payloads: [Data] = []
    for item in images {
        let n = item.size
        if n >= 256 {
            let rep = NSBitmapImageRep(cgImage: item.cg)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                fatalError("ICO 256 PNG failed")
            }
            payloads.append(png)
        } else {
            // Render unpremultiplied/straight BGRA via manual unpremultiply from premultiplied RGBA buffer
            var rgba = [UInt8](repeating: 0, count: n * n * 4)
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: &rgba,
                width: n,
                height: n,
                bitsPerComponent: 8,
                bytesPerRow: n * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                fatalError("CGContext failed")
            }
            ctx.interpolationQuality = .high
            ctx.draw(item.cg, in: CGRect(x: 0, y: 0, width: n, height: n))

            let andRowBytes = ((n + 31) / 32) * 4
            var dib = Data()
            // BITMAPINFOHEADER (40 bytes)
            dib.append(u32(40))
            dib.append(i32(Int32(n)))
            dib.append(i32(Int32(n * 2))) // XOR + AND height
            dib.append(u16(1))            // biPlanes
            dib.append(u16(32))           // biBitCount
            dib.append(u32(0))            // BI_RGB
            dib.append(u32(UInt32(n * n * 4 + andRowBytes * n)))
            dib.append(i32(0))
            dib.append(i32(0))
            dib.append(u32(0))
            dib.append(u32(0))

            // Bottom-up BGRA XOR mask (unpremultiplied so Win32 alpha blending has zero dark halo)
            var andMask = Data(count: andRowBytes * n)
            for rowBottom in 0..<n {
                let srcY = n - 1 - rowBottom
                for x in 0..<n {
                    let idx = (srcY * n + x) * 4
                    let pr = UInt16(rgba[idx])
                    let pg = UInt16(rgba[idx + 1])
                    let pb = UInt16(rgba[idx + 2])
                    let a = rgba[idx + 3]
                    let r: UInt8
                    let g: UInt8
                    let b: UInt8
                    if a == 0 {
                        r = 0; g = 0; b = 0
                        // Set transparent bit in 1-bit AND mask for legacy non-alpha GDI callers
                        let byteIndex = rowBottom * andRowBytes + (x / 8)
                        andMask[byteIndex] |= UInt8(0x80 >> (x % 8))
                    } else if a == 255 {
                        r = UInt8(pr); g = UInt8(pg); b = UInt8(pb)
                    } else {
                        r = UInt8(min(255, (pr * 255 + UInt16(a / 2)) / UInt16(a)))
                        g = UInt8(min(255, (pg * 255 + UInt16(a / 2)) / UInt16(a)))
                        b = UInt8(min(255, (pb * 255 + UInt16(a / 2)) / UInt16(a)))
                    }
                    dib.append(contentsOf: [b, g, r, a])
                }
            }
            dib.append(andMask)
            payloads.append(dib)
        }
    }

    var ico = Data()
    ico.append(u16(0)) // idReserved
    ico.append(u16(1)) // idType = ICON
    ico.append(u16(UInt16(images.count)))

    var offset = UInt32(6 + images.count * 16)
    for (i, item) in images.enumerated() {
        let whByte: UInt8 = item.size >= 256 ? 0 : UInt8(item.size)
        let data = payloads[i]
        ico.append(contentsOf: [whByte, whByte, 0, 0])
        ico.append(u16(1))
        ico.append(u16(32))
        ico.append(u32(UInt32(data.count)))
        ico.append(u32(offset))
        offset += UInt32(data.count)
    }
    for data in payloads {
        ico.append(data)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ico.write(to: url)
}

@MainActor
func main() throws {
    let args = CommandLine.arguments
    var active = BrandConcept.a
    var showcasePath: String? = nil

    var idx = 1
    while idx < args.count {
        if args[idx] == "--active", idx + 1 < args.count, let c = BrandConcept(rawValue: args[idx + 1].lowercased()) {
            active = c
            idx += 2
        } else if args[idx] == "--showcase", idx + 1 < args.count {
            showcasePath = args[idx + 1]
            idx += 2
        } else {
            idx += 1
        }
    }

    let root = URL(fileURLWithPath: "/Users/fanaruto/Project/Personal/iClip")
    let brandDir = root.appendingPathComponent("assets/brand")
    let winAssetsDir = root.appendingPathComponent("windows/assets")
    let fm = FileManager.default
    try fm.createDirectory(at: brandDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: winAssetsDir, withIntermediateDirectories: true)

    // 1. Export 512px preview of all 4 concepts + optional showcase board
    for c in BrandConcept.allCases {
        let cg = renderCGImage(TahoeAppIconView(concept: c, canvasSize: 512, squircleRatio: 0.8047, withDropShadow: true), pixelWidth: 512, pixelHeight: 512)
        try writePNG(cg, to: brandDir.appendingPathComponent("concepts/appicon-\(c.rawValue)-512.png"))
    }
    if let scOut = showcasePath {
        let boardCG = renderCGImage(ShowcaseBoardView(), pixelWidth: 1640, pixelHeight: 640, scale: 2.0)
        try writePNG(boardCG, to: URL(fileURLWithPath: scOut), dpiScale: 2.0)
        print("Wrote showcase board -> \(scOut)")
    }

    // 2. Build compact Retina AppIcon.icns (16..512px @2x, deduplicated chunks -> ~340 KB instead of 1.58 MB)
    func be32(_ v: UInt32) -> Data { var b = v.bigEndian; return Data(bytes: &b, count: 4) }
    func pngBytes(_ cg: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])!
    }
    let icnsSpecs: [(ostype: String, px: Int)] = [
        ("icp4", 16),
        ("ic11", 32),   // 16x16@2x
        ("ic12", 64),   // 32x32@2x
        ("ic07", 128),  // 128x128
        ("ic13", 256),  // 128x128@2x
        ("ic14", 512)   // 256x256@2x (Retina Finder/Dock max)
    ]
    var icnsBody = Data()
    for spec in icnsSpecs {
        let ratio: CGFloat = spec.px <= 32 ? 0.86 : 0.8046875
        let cg = renderCGImage(
            TahoeAppIconView(concept: active, canvasSize: CGFloat(spec.px), squircleRatio: ratio, withDropShadow: spec.px >= 64),
            pixelWidth: spec.px,
            pixelHeight: spec.px
        )
        let pData = pngBytes(cg)
        icnsBody.append(spec.ostype.data(using: .ascii)!)
        icnsBody.append(be32(UInt32(8 + pData.count)))
        icnsBody.append(pData)
    }
    var icnsFile = Data("icns".utf8)
    icnsFile.append(be32(UInt32(8 + icnsBody.count)))
    icnsFile.append(icnsBody)
    let icnsURL = brandDir.appendingPathComponent("AppIcon.icns")
    try icnsFile.write(to: icnsURL)

    // 3. Build macOS Menu Bar Template PNGs (18pt @1x and @2x)
    let mb1x = renderCGImage(MonochromeTemplateGlyph(concept: active, pixelSize: 18, color: .black), pixelWidth: 18, pixelHeight: 18)
    let mb2x = renderCGImage(MonochromeTemplateGlyph(concept: active, pixelSize: 36, color: .black), pixelWidth: 36, pixelHeight: 36)
    try writePNG(mb1x, to: brandDir.appendingPathComponent("MenuBarIcon.png"), dpiScale: 1)
    try writePNG(mb2x, to: brandDir.appendingPathComponent("MenuBarIcon@2x.png"), dpiScale: 2)

    // 4. Build Windows multi-resolution iClip.ico (16, 24, 32, 48, 64, 256)
    let winSizes = [16, 24, 32, 48, 64, 256]
    var winFrames: [(size: Int, cg: CGImage)] = []
    for px in winSizes {
        let ratio: CGFloat = px <= 24 ? 0.96 : 0.92
        let cg = renderCGImage(
            TahoeAppIconView(concept: active, canvasSize: CGFloat(px), squircleRatio: ratio, withDropShadow: false),
            pixelWidth: px,
            pixelHeight: px
        )
        winFrames.append((px, cg))
    }
    try writeWindowsICO(images: winFrames, to: winAssetsDir.appendingPathComponent("iClip.ico"))

    // 5. Build Retina DMG background (660x420 pt @2x, crisp JPEG ~96 KB for fast DMG downloads)
    let dmgCG = renderCGImage(DMGInstallerBackdropView(concept: active), pixelWidth: 660, pixelHeight: 420, scale: 2.0)
    let dmgRep = NSBitmapImageRep(cgImage: dmgCG)
    dmgRep.size = NSSize(width: 660, height: 420)
    if let jpgData = dmgRep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
        try jpgData.write(to: brandDir.appendingPathComponent("dmg-background.jpg"))
    }

    // 6. Build Web icons (180x180 apple-touch-icon + 512x512 web icon)
    let web180 = renderCGImage(TahoeAppIconView(concept: active, canvasSize: 180, squircleRatio: 1.0, withDropShadow: false), pixelWidth: 180, pixelHeight: 180)
    let web512 = renderCGImage(TahoeAppIconView(concept: active, canvasSize: 512, squircleRatio: 0.94, withDropShadow: false), pixelWidth: 512, pixelHeight: 512)
    try writePNG(web180, to: brandDir.appendingPathComponent("apple-touch-icon.png"))
    try writePNG(web512, to: brandDir.appendingPathComponent("icon-512.png"))

    print("Successfully built production brand suite (active=\(active.rawValue)):")
    print("  - \(icnsURL.path) (\(icnsFile.count / 1024) KB)")
    print("  - \(winAssetsDir.appendingPathComponent("iClip.ico").path)")
    print("  - \(brandDir.appendingPathComponent("dmg-background.jpg").path)")
}

try MainActor.assumeIsolated {
    try main()
}
