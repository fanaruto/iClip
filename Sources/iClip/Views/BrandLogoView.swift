import AppKit
import SwiftUI

/// iClip 统一品牌视觉标识组件（默认采用方案 A「磁吸星环 · Magnetic i-Loop」）
/// - 提供菜单栏 `isTemplate` 矢量单色图标（16~18pt 像素级锐利）
/// - 提供设置页与关于头部内嵌的 macOS 26 液态玻璃圆角徽标
enum BrandLogo {

    /// 生成 macOS 顶部菜单栏单色自适应模板图标（自动适配浅色/深色状态栏与壁纸反色）
    @MainActor
    static func menuBarTemplateImage(pointSize: CGFloat = 17) -> NSImage {
        if let bundled = Bundle.main.image(forResource: NSImage.Name("MenuBarIcon")) {
            let copy = (bundled.copy() as? NSImage) ?? bundled
            copy.size = NSSize(width: pointSize, height: pointSize)
            copy.isTemplate = true
            return copy
        }

        let size = NSSize(width: pointSize, height: pointSize)
        let img = NSImage(size: size, flipped: true) { rect in
            let pad = rect.width * 0.06
            let box = rect.insetBy(dx: pad, dy: pad)
            let s = min(box.width, box.height) / 256.0
            let ox = box.minX + (box.width - 256.0 * s) * 0.5
            let oy = box.minY + (box.height - 256.0 * s) * 0.5

            NSColor.black.setFill()

            // C 型磁吸环（与 SVG 母版坐标 1:1 对齐）
            let cx = ox + 120.0 * s
            let cy = oy + 128.0 * s
            let rOut = 94.0 * s
            let rIn = 50.0 * s
            let rMid = 72.0 * s
            let capR = 22.0 * s
            let a1Deg: CGFloat = 24.0
            let a2Deg: CGFloat = 282.0
            let a1Rad = a1Deg * .pi / 180.0
            let a2Rad = a2Deg * .pi / 180.0

            let cPath = NSBezierPath()
            cPath.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: rOut, startAngle: a1Deg, endAngle: a2Deg, clockwise: false)
            let cap2 = NSPoint(x: cx + rMid * cos(a2Rad), y: cy + rMid * sin(a2Rad))
            cPath.appendArc(withCenter: cap2, radius: capR, startAngle: a2Deg, endAngle: a2Deg + 180.0, clockwise: false)
            cPath.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: rIn, startAngle: a2Deg, endAngle: a1Deg, clockwise: true)
            let cap1 = NSPoint(x: cx + rMid * cos(a1Rad), y: cy + rMid * sin(a1Rad))
            cPath.appendArc(withCenter: cap1, radius: capR, startAngle: a1Deg + 180.0, endAngle: a1Deg, clockwise: false)
            cPath.close()
            cPath.fill()

            // 右上悬浮 i 圆珠
            let dotR = 26.0 * s
            let dotX = ox + 198.0 * s - dotR
            let dotY = oy + 86.0 * s - dotR
            let dotPath = NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotR * 2, height: dotR * 2))
            dotPath.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// 256×256 母版坐标系下的「磁吸星环」双部件矢量 Shape
private struct MagneticILoopShape: Shape {
    let isOrb: Bool

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 256.0
        let ox = rect.minX + (rect.width - 256.0 * s) * 0.5
        let oy = rect.minY + (rect.height - 256.0 * s) * 0.5

        var p = Path()
        if isOrb {
            let r = 26.0 * s
            let cx = ox + 198.0 * s
            let cy = oy + 86.0 * s
            p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        } else {
            let c = CGPoint(x: ox + 120.0 * s, y: oy + 128.0 * s)
            let a1 = Angle.degrees(24)
            let a2 = Angle.degrees(282)
            let c1 = CGPoint(x: c.x + 72.0 * s * CGFloat(cos(a1.radians)), y: c.y + 72.0 * s * CGFloat(sin(a1.radians)))
            let c2 = CGPoint(x: c.x + 72.0 * s * CGFloat(cos(a2.radians)), y: c.y + 72.0 * s * CGFloat(sin(a2.radians)))
            p.addArc(center: c, radius: 94.0 * s, startAngle: a1, endAngle: a2, clockwise: false)
            p.addArc(center: c2, radius: 22.0 * s, startAngle: a2, endAngle: .degrees(462), clockwise: false)
            p.addArc(center: c, radius: 50.0 * s, startAngle: a2, endAngle: a1, clockwise: true)
            p.addArc(center: c1, radius: 22.0 * s, startAngle: .degrees(204), endAngle: a1, clockwise: false)
            p.closeSubpath()
        }
        return p
    }
}

/// 设置页标题栏与关于卡片使用的 macOS 26 液态玻璃小徽标
/// 采用纯 CoreGraphics `Canvas` 同心绘制并严格圆角裁切，根除 macOS 26 SwiftUI `Shape.fill(LinearGradient)` 在右下角溢出浅蓝方块的渲染缺陷
struct BrandAppIconBadge: View {
    var size: CGFloat = 22

    var body: some View {
        let radius = size * 0.23
        let badgeShape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        Canvas { ctx, canvasSize in
            let fullRect = CGRect(origin: .zero, size: canvasSize)
            let bgPath = Path(roundedRect: fullRect, cornerRadius: radius, style: .continuous)
            ctx.fill(
                bgPath,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.04, green: 0.09, blue: 0.22),
                        Color(red: 0.05, green: 0.24, blue: 0.62),
                        Color(red: 0.05, green: 0.44, blue: 0.98)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: canvasSize.width, y: canvasSize.height)
                )
            )

            let inset = min(canvasSize.width, canvasSize.height) * 0.16
            let artRect = fullRect.insetBy(dx: inset, dy: inset)
            let cPath = MagneticILoopShape(isOrb: false).path(in: artRect)
            ctx.fill(cPath, with: .color(.white))

            let orbPath = MagneticILoopShape(isOrb: true).path(in: artRect)
            let orbBounds = orbPath.boundingRect
            ctx.fill(
                orbPath,
                with: .linearGradient(
                    Gradient(colors: [Color.white, Color(red: 0.46, green: 0.90, blue: 1.0)]),
                    startPoint: CGPoint(x: orbBounds.minX, y: orbBounds.minY),
                    endPoint: CGPoint(x: orbBounds.maxX, y: orbBounds.maxY)
                )
            )
        }
        .frame(width: size, height: size)
        .clipShape(badgeShape)
        .overlay(
            badgeShape
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
    }
}
