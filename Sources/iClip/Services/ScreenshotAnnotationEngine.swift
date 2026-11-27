import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - 1. 屏幕取景、窗口自动吸附与操作岛锚点几何引擎（统一采用 AppKit NSView 左下原点局部坐标）

/// 可吸附的桌面窗口描述（rect 为目标屏幕 NSView 局部点坐标：左下为原点，Y 轴向上）
struct SnappableWindowRect: Equatable {
    let windowID: CGWindowID
    let ownerName: String
    let rect: CGRect
}

enum ScreenshotGeometryEngine {
    /// 选区调整的 8 个交互句柄
    enum ResizeHandle: CaseIterable, Equatable {
        case topLeft
        case topCenter
        case topRight
        case middleLeft
        case middleRight
        case bottomLeft
        case bottomCenter
        case bottomRight

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .topCenter: return CGPoint(x: rect.midX, y: rect.maxY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            case .middleLeft: return CGPoint(x: rect.minX, y: rect.midY)
            case .middleRight: return CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .bottomCenter: return CGPoint(x: rect.midX, y: rect.minY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
            }
        }
    }

    /// 规范化起止点之间的拖拽选区，支持 `⇧` 锁定正方并严格钳制于屏幕边界内
    static func normalizedRect(
        from start: CGPoint,
        to end: CGPoint,
        lockSquare: Bool,
        bounds: CGRect
    ) -> CGRect {
        let clampedStart = CGPoint(
            x: min(max(start.x, bounds.minX), bounds.maxX),
            y: min(max(start.y, bounds.minY), bounds.maxY)
        )
        var clampedEnd = CGPoint(
            x: min(max(end.x, bounds.minX), bounds.maxX),
            y: min(max(end.y, bounds.minY), bounds.maxY)
        )

        if lockSquare {
            let rawDx = clampedEnd.x - clampedStart.x
            let rawDy = clampedEnd.y - clampedStart.y
            let signX: CGFloat = rawDx >= 0 ? 1 : -1
            let signY: CGFloat = rawDy >= 0 ? 1 : -1
            let maxAvailX = signX > 0 ? (bounds.maxX - clampedStart.x) : (clampedStart.x - bounds.minX)
            let maxAvailY = signY > 0 ? (bounds.maxY - clampedStart.y) : (clampedStart.y - bounds.minY)
            let side = min(max(abs(rawDx), abs(rawDy)), min(maxAvailX, maxAvailY))
            clampedEnd = CGPoint(
                x: clampedStart.x + signX * side,
                y: clampedStart.y + signY * side
            )
        }

        let minX = min(clampedStart.x, clampedEnd.x)
        let minY = min(clampedStart.y, clampedEnd.y)
        let maxX = max(clampedStart.x, clampedEnd.x)
        let maxY = max(clampedStart.y, clampedEnd.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 按住 Space 平移整个选区或拖拽选区内部移动时，严密钳制在画布内（绝不越出屏幕）
    static func translateRect(_ rect: CGRect, delta: CGVector, within bounds: CGRect) -> CGRect {
        let w = min(rect.width, bounds.width)
        let h = min(rect.height, bounds.height)
        let maxX = max(bounds.minX, bounds.maxX - w)
        let maxY = max(bounds.minY, bounds.maxY - h)
        let nx = min(max(rect.minX + delta.dx, bounds.minX), maxX)
        let ny = min(max(rect.minY + delta.dy, bounds.minY), maxY)
        return CGRect(x: nx, y: ny, width: w, height: h)
    }

    /// 命中当前光标最上层可见桌面窗口（数组须按前端 z-order 从前到后排列）
    static func snappedWindowRect(
        at point: CGPoint,
        windows: [SnappableWindowRect]
    ) -> SnappableWindowRect? {
        for win in windows {
            if win.rect.width >= 24, win.rect.height >= 24, win.rect.contains(point) {
                return win
            }
        }
        return nil
    }

    /// 命中 8 向调整句柄
    static func hitTestHandle(
        at point: CGPoint,
        in rect: CGRect,
        tolerance: CGFloat = 10
    ) -> ResizeHandle? {
        var best: (handle: ResizeHandle, dist: CGFloat)?
        for handle in ResizeHandle.allCases {
            let hp = handle.point(in: rect)
            let d = hypot(point.x - hp.x, point.y - hp.y)
            if d <= tolerance && (best == nil || d < best!.dist) {
                best = (handle, d)
            }
        }
        return best?.handle
    }

    /// 拖拽句柄缩放选区（保持最小 8×8 点尺寸并钳制于 bounds 内）
    static func resizedRect(
        from rect: CGRect,
        handle: ResizeHandle,
        to point: CGPoint,
        bounds: CGRect,
        minSize: CGFloat = 8
    ) -> CGRect {
        let px = min(max(point.x, bounds.minX), bounds.maxX)
        let py = min(max(point.y, bounds.minY), bounds.maxY)

        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .topLeft:
            minX = min(px, maxX - minSize)
            maxY = max(py, minY + minSize)
        case .topCenter:
            maxY = max(py, minY + minSize)
        case .topRight:
            maxX = max(px, minX + minSize)
            maxY = max(py, minY + minSize)
        case .middleLeft:
            minX = min(px, maxX - minSize)
        case .middleRight:
            maxX = max(px, minX + minSize)
        case .bottomLeft:
            minX = min(px, maxX - minSize)
            minY = min(py, maxY - minSize)
        case .bottomCenter:
            minY = min(py, maxY - minSize)
        case .bottomRight:
            maxX = max(px, minX + minSize)
            minY = min(py, maxY - minSize)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 计算操作岛的最佳安全原点（AppKit 左下原点坐标系）：
    /// 优先置于选区下方居右/居中，下方空间不足时翻转至选区上方，上下均接近满屏时平滑内嵌于选区底缘内侧
    static func toolbarOrigin(
        for selection: CGRect,
        toolbarSize: CGSize,
        bounds: CGRect,
        margin: CGFloat = 10
    ) -> CGPoint {
        let minAllowedX = bounds.minX + margin
        let maxAllowedX = max(minAllowedX, bounds.maxX - toolbarSize.width - margin)
        let centeredX = selection.midX - toolbarSize.width * 0.5
        let x = min(max(centeredX, minAllowedX), maxAllowedX)

        let gap: CGFloat = 10
        let belowY = selection.minY - gap - toolbarSize.height
        if belowY >= bounds.minY + margin {
            return CGPoint(x: x, y: belowY)
        }

        let aboveY = selection.maxY + gap
        if aboveY + toolbarSize.height <= bounds.maxY - margin {
            return CGPoint(x: x, y: aboveY)
        }

        let insetY = selection.minY + gap
        let minAllowedY = bounds.minY + margin
        let maxAllowedY = max(minAllowedY, bounds.maxY - toolbarSize.height - margin)
        return CGPoint(x: x, y: min(max(insetY, minAllowedY), maxAllowedY))
    }
}

// MARK: - 2. 完整轻量标注模型与色彩线宽预设

enum ScreenshotAnnotationTool: String, CaseIterable, Codable, Identifiable {
    case rectangle
    case arrow
    case mosaic
    case brush
    case text
    case stepBadge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: return "矩形"
        case .arrow: return "箭头"
        case .mosaic: return "马赛克"
        case .brush: return "画笔"
        case .text: return "文字"
        case .stepBadge: return "序号"
        }
    }

    var symbolName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .mosaic: return "checkerboard.rectangle"
        case .brush: return "scribble.variable"
        case .text: return "t.square"
        case .stepBadge: return "1.circle"
        }
    }
}

struct ScreenshotColorPreset: Equatable, Identifiable {
    let id: String
    let name: String
    let hex: String

    static let presets: [ScreenshotColorPreset] = [
        ScreenshotColorPreset(id: "coral", name: "珊瑚红", hex: "#FF3B30"),
        ScreenshotColorPreset(id: "cobalt", name: "电光蓝", hex: "#1E5EFF"),
        ScreenshotColorPreset(id: "amber", name: "琥珀金", hex: "#F59E0B"),
        ScreenshotColorPreset(id: "emerald", name: "翡翠绿", hex: "#10B981"),
        ScreenshotColorPreset(id: "white", name: "纯白", hex: "#FFFFFF")
    ]

    static func cgColor(fromHex hex: String) -> CGColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let val = UInt64(cleaned, radix: 16) else {
            return NSColor.systemRed.cgColor
        }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

enum ScreenshotStrokeWidth: CGFloat, CaseIterable, Identifiable {
    case thin = 2.5
    case medium = 4.0
    case thick = 6.5

    var id: CGFloat { rawValue }

    var dotSize: CGFloat {
        switch self {
        case .thin: return 5
        case .medium: return 8
        case .thick: return 11.5
        }
    }

    var mosaicWidth: CGFloat {
        switch self {
        case .thin: return 14
        case .medium: return 22
        case .thick: return 32
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .thin: return 14
        case .medium: return 18
        case .thick: return 24
        }
    }
}

enum ScreenshotAnnotationKind: Equatable {
    case rectangle(rect: CGRect, colorHex: String, lineWidth: CGFloat)
    case arrow(start: CGPoint, end: CGPoint, colorHex: String, lineWidth: CGFloat)
    case mosaic(points: [CGPoint], brushWidth: CGFloat)
    case brush(points: [CGPoint], colorHex: String, lineWidth: CGFloat)
    case text(origin: CGPoint, text: String, colorHex: String, fontSize: CGFloat)
    case stepBadge(center: CGPoint, number: Int, colorHex: String)
    case privacyMosaic(rects: [CGRect])

    var isMosaicLayer: Bool {
        switch self {
        case .mosaic, .privacyMosaic:
            return true
        case .rectangle, .arrow, .brush, .text, .stepBadge:
            return false
        }
    }
}

struct ScreenshotAnnotation: Identifiable, Equatable {
    let id: UUID
    let kind: ScreenshotAnnotationKind

    init(id: UUID = UUID(), kind: ScreenshotAnnotationKind) {
        self.id = id
        self.kind = kind
    }

    /// 计算下一个递增序号标点编号（支持撤销后自动衔接当前最大序号 + 1）
    static func nextStepNumber(in annotations: [ScreenshotAnnotation]) -> Int {
        var maxNum = 0
        for ann in annotations {
            if case .stepBadge(_, let number, _) = ann.kind {
                maxNum = max(maxNum, number)
            }
        }
        return maxNum + 1
    }
}

/// 预提取不可变位图数据缓冲，避免高频绘制马赛克时逐块复制 `CGDataProvider`
struct ScreenshotPixelBuffer {
    private let cfData: CFData
    private let ptr: UnsafePointer<UInt8>
    private let totalLen: Int
    let width: Int
    let height: Int
    private let bytesPerRow: Int
    private let bytesPerPixel: Int
    private let isLittle32: Bool

    init?(image: CGImage) {
        guard let dp = image.dataProvider,
              let data = dp.data,
              let bytePtr = CFDataGetBytePtr(data),
              image.width > 0,
              image.height > 0 else {
            return nil
        }
        self.cfData = data
        self.ptr = bytePtr
        self.totalLen = CFDataGetLength(data)
        self.width = image.width
        self.height = image.height
        self.bytesPerRow = image.bytesPerRow
        self.bytesPerPixel = max(1, image.bitsPerPixel / 8)
        self.isLittle32 = image.bitmapInfo.contains(.byteOrder32Little)
    }

    func sampleColor(atBlockRect blockRect: CGRect, canvasBounds: CGRect, col: Int, row: Int) -> CGColor {
        guard canvasBounds.width > 0, canvasBounds.height > 0 else {
            let shade = ((col + row) % 2 == 0) ? 0.56 : 0.42
            return CGColor(srgbRed: shade, green: shade, blue: shade, alpha: 1.0)
        }
        let scaleX = CGFloat(width) / canvasBounds.width
        let scaleY = CGFloat(height) / canvasBounds.height
        let px = min(max(Int(blockRect.midX * scaleX), 0), max(0, width - 1))
        let pyTopDown = min(max(Int((canvasBounds.height - blockRect.midY) * scaleY), 0), max(0, height - 1))

        let offset = pyTopDown * bytesPerRow + px * bytesPerPixel
        guard offset >= 0 && offset + 3 < totalLen else {
            return CGColor(srgbRed: 0.48, green: 0.48, blue: 0.50, alpha: 1.0)
        }

        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        if bytesPerPixel >= 8 {
            // 16bpc (8 bytes/px) 取每个通道高位字节近似采样
            if isLittle32 {
                b = CGFloat(ptr[offset + 1]) / 255.0
                g = CGFloat(ptr[offset + 3]) / 255.0
                r = CGFloat(ptr[offset + 5]) / 255.0
            } else {
                r = CGFloat(ptr[offset]) / 255.0
                g = CGFloat(ptr[offset + 2]) / 255.0
                b = CGFloat(ptr[offset + 4]) / 255.0
            }
        } else if isLittle32 {
            b = CGFloat(ptr[offset]) / 255.0
            g = CGFloat(ptr[offset + 1]) / 255.0
            r = CGFloat(ptr[offset + 2]) / 255.0
        } else {
            r = CGFloat(ptr[offset]) / 255.0
            g = CGFloat(ptr[offset + 1]) / 255.0
            b = CGFloat(ptr[offset + 2]) / 255.0
        }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - 3. 高分辨率 CoreGraphics 所见即所得标注合成器

enum ScreenshotAnnotationRenderer {
    /// 分层有序绘制标注：马赛克与隐私打码层永远垫底（底图之上、矢量线条/文字/序号之下），避免遮挡先前绘出的箭头与方框
    static func drawOrderedAnnotations(
        _ annotations: [ScreenshotAnnotation],
        draft: ScreenshotAnnotation? = nil,
        in ctx: CGContext,
        baseImage: CGImage?,
        canvasBounds: CGRect,
        pixelBuffer: ScreenshotPixelBuffer? = nil
    ) {
        let resolvedBuffer = pixelBuffer ?? baseImage.flatMap { ScreenshotPixelBuffer(image: $0) }
        for ann in annotations where ann.kind.isMosaicLayer {
            drawAnnotation(ann, in: ctx, baseImage: baseImage, canvasBounds: canvasBounds, pixelBuffer: resolvedBuffer)
        }
        if let draft, draft.kind.isMosaicLayer {
            drawAnnotation(draft, in: ctx, baseImage: baseImage, canvasBounds: canvasBounds, pixelBuffer: resolvedBuffer)
        }
        for ann in annotations where !ann.kind.isMosaicLayer {
            drawAnnotation(ann, in: ctx, baseImage: baseImage, canvasBounds: canvasBounds, pixelBuffer: resolvedBuffer)
        }
        if let draft, !draft.kind.isMosaicLayer {
            drawAnnotation(draft, in: ctx, baseImage: baseImage, canvasBounds: canvasBounds, pixelBuffer: resolvedBuffer)
        }
    }

    /// 在当前视图坐标系（AppKit 左下原点局部点坐标）中绘制单条标注，实时预览与导出 100% 复用
    static func drawAnnotation(
        _ annotation: ScreenshotAnnotation,
        in ctx: CGContext,
        baseImage: CGImage?,
        canvasBounds: CGRect,
        pixelBuffer: ScreenshotPixelBuffer? = nil
    ) {
        ctx.saveGState()
        switch annotation.kind {
        case .rectangle(let rect, let colorHex, let lineWidth):
            let color = ScreenshotColorPreset.cgColor(fromHex: colorHex)
            let radius = min(8.0, min(rect.width, rect.height) * 0.2)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()

        case .arrow(let start, let end, let colorHex, let lineWidth):
            drawArrow(from: start, to: end, color: ScreenshotColorPreset.cgColor(fromHex: colorHex), lineWidth: lineWidth, in: ctx)

        case .brush(let points, let colorHex, let lineWidth):
            guard !points.isEmpty else { break }
            let color = ScreenshotColorPreset.cgColor(fromHex: colorHex)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if points.count == 1 {
                let r = lineWidth * 0.5
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: points[0].x - r, y: points[0].y - r, width: lineWidth, height: lineWidth))
            } else {
                ctx.beginPath()
                ctx.move(to: points[0])
                for i in 1..<points.count {
                    let prev = points[i - 1]
                    let curr = points[i]
                    let mid = CGPoint(x: (prev.x + curr.x) * 0.5, y: (prev.y + curr.y) * 0.5)
                    ctx.addQuadCurve(to: mid, control: prev)
                }
                if let last = points.last {
                    ctx.addLine(to: last)
                }
                ctx.strokePath()
            }

        case .mosaic(let points, let brushWidth):
            guard !points.isEmpty else { break }
            drawMosaicStroke(points: points, brushWidth: brushWidth, baseImage: baseImage, canvasBounds: canvasBounds, pixelBuffer: pixelBuffer, in: ctx)

        case .privacyMosaic(let rects):
            let buffer = pixelBuffer ?? baseImage.flatMap { ScreenshotPixelBuffer(image: $0) }
            for rect in rects where rect.width > 1 && rect.height > 1 {
                drawMosaicRect(rect, blockSize: 8.0, baseImage: baseImage, canvasBounds: canvasBounds, pixelBuffer: buffer, in: ctx)
            }

        case .text(let origin, let text, let colorHex, let fontSize):
            guard !text.isEmpty else { break }
            drawTextAnnotation(text, at: origin, colorHex: colorHex, fontSize: fontSize, in: ctx)

        case .stepBadge(let center, let number, let colorHex):
            drawStepBadge(number: number, center: center, colorHex: colorHex, in: ctx)
        }
        ctx.restoreGState()
    }

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        color: CGColor,
        lineWidth: CGFloat,
        in ctx: CGContext
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1.5 else { return }

        let angle = atan2(dy, dx)
        let headLength = min(length * 0.45, max(12.0, lineWidth * 4.0))
        let headHalfWidth = max(6.0, lineWidth * 2.15)
        let tailWidth = max(1.5, lineWidth * 0.65)
        let neckWidth = lineWidth * 1.15

        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * headLength * 0.72,
            y: end.y - sin(angle) * headLength * 0.72
        )

        let perpX = -sin(angle)
        let perpY = cos(angle)

        let p0 = CGPoint(x: start.x + perpX * tailWidth * 0.5, y: start.y + perpY * tailWidth * 0.5)
        let p1 = CGPoint(x: shaftEnd.x + perpX * neckWidth * 0.5, y: shaftEnd.y + perpY * neckWidth * 0.5)
        let p2 = CGPoint(
            x: end.x - cos(angle) * headLength + perpX * headHalfWidth,
            y: end.y - sin(angle) * headLength + perpY * headHalfWidth
        )
        let p3 = end
        let p4 = CGPoint(
            x: end.x - cos(angle) * headLength - perpX * headHalfWidth,
            y: end.y - sin(angle) * headLength - perpY * headHalfWidth
        )
        let p5 = CGPoint(x: shaftEnd.x - perpX * neckWidth * 0.5, y: shaftEnd.y - perpY * neckWidth * 0.5)
        let p6 = CGPoint(x: start.x - perpX * tailWidth * 0.5, y: start.y - perpY * tailWidth * 0.5)

        ctx.setFillColor(color)
        ctx.beginPath()
        ctx.move(to: p0)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.addLine(to: p3)
        ctx.addLine(to: p4)
        ctx.addLine(to: p5)
        ctx.addLine(to: p6)
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawMosaicStroke(
        points: [CGPoint],
        brushWidth: CGFloat,
        baseImage: CGImage?,
        canvasBounds: CGRect,
        pixelBuffer: ScreenshotPixelBuffer?,
        in ctx: CGContext
    ) {
        let blockSize: CGFloat = max(7.0, min(12.0, brushWidth * 0.45))
        let radius = brushWidth * 0.5
        let resolvedBuffer = pixelBuffer ?? baseImage.flatMap { ScreenshotPixelBuffer(image: $0) }
        var visitedBlocks = Set<Int64>()

        // 沿画笔轨迹插值覆盖连续像素格
        var expanded: [CGPoint] = []
        expanded.reserveCapacity(points.count * 2)
        for i in 0..<points.count {
            let p = points[i]
            expanded.append(p)
            if i + 1 < points.count {
                let next = points[i + 1]
                let dist = hypot(next.x - p.x, next.y - p.y)
                let steps = Int(ceil(dist / (blockSize * 0.5)))
                if steps > 1 {
                    for s in 1..<steps {
                        let t = CGFloat(s) / CGFloat(steps)
                        expanded.append(CGPoint(x: p.x + (next.x - p.x) * t, y: p.y + (next.y - p.y) * t))
                    }
                }
            }
        }

        for pt in expanded {
            let minCol = Int(floor((pt.x - radius) / blockSize))
            let maxCol = Int(floor((pt.x + radius) / blockSize))
            let minRow = Int(floor((pt.y - radius) / blockSize))
            let maxRow = Int(floor((pt.y + radius) / blockSize))

            for col in minCol...maxCol {
                for row in minRow...maxRow {
                    let blockRect = CGRect(
                        x: CGFloat(col) * blockSize,
                        y: CGFloat(row) * blockSize,
                        width: blockSize,
                        height: blockSize
                    )
                    let center = CGPoint(x: blockRect.midX, y: blockRect.midY)
                    guard hypot(center.x - pt.x, center.y - pt.y) <= radius else { continue }
                    let key = (Int64(col) << 32) ^ Int64(row & 0xFFFF_FFFF)
                    guard !visitedBlocks.contains(key) else { continue }
                    visitedBlocks.insert(key)

                    let color = sampleBlockColor(in: blockRect, pixelBuffer: resolvedBuffer, canvasBounds: canvasBounds, col: col, row: row)
                    ctx.setFillColor(color)
                    ctx.fill(blockRect)
                }
            }
        }
    }

    private static func drawMosaicRect(
        _ rect: CGRect,
        blockSize: CGFloat,
        baseImage: CGImage?,
        canvasBounds: CGRect,
        pixelBuffer: ScreenshotPixelBuffer?,
        in ctx: CGContext
    ) {
        let minCol = Int(floor(rect.minX / blockSize))
        let maxCol = Int(floor((rect.maxX - 0.1) / blockSize))
        let minRow = Int(floor(rect.minY / blockSize))
        let maxRow = Int(floor((rect.maxY - 0.1) / blockSize))
        guard maxCol >= minCol && maxRow >= minRow else { return }

        let resolvedBuffer = pixelBuffer ?? baseImage.flatMap { ScreenshotPixelBuffer(image: $0) }

        ctx.saveGState()
        ctx.clip(to: rect)
        for col in minCol...maxCol {
            for row in minRow...maxRow {
                let blockRect = CGRect(
                    x: CGFloat(col) * blockSize,
                    y: CGFloat(row) * blockSize,
                    width: blockSize,
                    height: blockSize
                )
                let color = sampleBlockColor(in: blockRect, pixelBuffer: resolvedBuffer, canvasBounds: canvasBounds, col: col, row: row)
                ctx.setFillColor(color)
                ctx.fill(blockRect)
            }
        }
        ctx.restoreGState()
    }

    private static func sampleBlockColor(
        in blockRect: CGRect,
        pixelBuffer: ScreenshotPixelBuffer?,
        canvasBounds: CGRect,
        col: Int,
        row: Int
    ) -> CGColor {
        guard let pixelBuffer else {
            let shade = ((col + row) % 2 == 0) ? 0.56 : 0.42
            return CGColor(srgbRed: shade, green: shade, blue: shade, alpha: 1.0)
        }
        return pixelBuffer.sampleColor(atBlockRect: blockRect, canvasBounds: canvasBounds, col: col, row: row)
    }

    private static func drawTextAnnotation(
        _ text: String,
        at origin: CGPoint,
        colorHex: String,
        fontSize: CGFloat,
        in ctx: CGContext
    ) {
        let color = NSColor(cgColor: ScreenshotColorPreset.cgColor(fromHex: colorHex)) ?? .systemRed
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(colorHex.uppercased() == "#FFFFFF" ? 0.55 : 0.35)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
            .shadow: shadow
        ]
        let nsText = NSAttributedString(string: text, attributes: attrs)
        let textSize = nsText.size()

        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        nsText.draw(at: NSPoint(x: origin.x, y: origin.y - textSize.height * 0.5))
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawStepBadge(
        number: Int,
        center: CGPoint,
        colorHex: String,
        in ctx: CGContext
    ) {
        let radius: CGFloat = 12.0
        let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let fillCG = ScreenshotColorPreset.cgColor(fromHex: colorHex)

        ctx.setFillColor(fillCG)
        ctx.fillEllipse(in: circleRect)

        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: circleRect.insetBy(dx: 0.75, dy: 0.75))

        let textColor: NSColor = (colorHex.uppercased() == "#FFFFFF") ? .black : .white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: number >= 10 ? 11.5 : 13, weight: .bold),
            .foregroundColor: textColor
        ]
        let label = NSAttributedString(string: "\(number)", attributes: attrs)
        let size = label.size()

        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        label.draw(at: NSPoint(x: center.x - size.width * 0.5, y: center.y - size.height * 0.5))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 按 Retina 原始像素裁切选区并合成全部轻量标注，输出高质量 PNG 数据
    static func renderCompositeImage(
        baseImage: CGImage,
        cropRectInViewPoints: CGRect,
        viewBounds: CGRect,
        annotations: [ScreenshotAnnotation]
    ) -> (cgImage: CGImage, pngData: Data)? {
        guard cropRectInViewPoints.width >= 2,
              cropRectInViewPoints.height >= 2,
              viewBounds.width > 0,
              viewBounds.height > 0 else {
            return nil
        }

        let scaleX = CGFloat(baseImage.width) / viewBounds.width
        let scaleY = CGFloat(baseImage.height) / viewBounds.height

        let pixelX = max(0, Int(floor(cropRectInViewPoints.minX * scaleX)))
        let pixelTopY = max(0, Int(floor((viewBounds.height - cropRectInViewPoints.maxY) * scaleY)))
        let pixelW = min(baseImage.width - pixelX, max(2, Int(round(cropRectInViewPoints.width * scaleX))))
        let pixelH = min(baseImage.height - pixelTopY, max(2, Int(round(cropRectInViewPoints.height * scaleY))))
        guard pixelW >= 2, pixelH >= 2 else { return nil }

        let cropPixelRect = CGRect(x: pixelX, y: pixelTopY, width: pixelW, height: pixelH)
        guard let cropped = baseImage.cropping(to: cropPixelRect) else { return nil }

        let preferredSpace = baseImage.colorSpace
        let fallbackSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx: CGContext
        if let preferredSpace,
           let directCtx = CGContext(
               data: nil,
               width: pixelW,
               height: pixelH,
               bitsPerComponent: 8,
               bytesPerRow: 0,
               space: preferredSpace,
               bitmapInfo: bitmapInfo
           ) {
            ctx = directCtx
        } else if let safeCtx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: fallbackSpace,
            bitmapInfo: bitmapInfo
        ) {
            ctx = safeCtx
        } else {
            return nil
        }

        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        if !annotations.isEmpty {
            let pixelBuffer = ScreenshotPixelBuffer(image: baseImage)
            ctx.saveGState()
            ctx.scaleBy(x: scaleX, y: scaleY)
            ctx.translateBy(x: -cropRectInViewPoints.minX, y: -cropRectInViewPoints.minY)
            drawOrderedAnnotations(annotations, in: ctx, baseImage: baseImage, canvasBounds: viewBounds, pixelBuffer: pixelBuffer)
            ctx.restoreGState()
        }

        guard let outImage = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: outImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return (outImage, pngData)
    }
}
