import AppKit
import SwiftUI

/// macOS 26+ Liquid Glass 官方级无毛边光学表面控制器
///
/// 遵循 Apple HIG 的核心原则：
/// 1. 直接将原生 `NSGlassEffectView` 作为窗口唯一根视图，与 macOS 26 Tahoe 官方连续 R 角（26pt）、
///    边缘光学折射与 WindowServer 阴影 100% 统一，彻底消除双层圆角曲率偏差与四角毛边；
/// 2. 在 `glassView.contentView` 内部嵌入严格同心裁切（`.continuous`）的柔焦缓冲层，
///    将背后深色 IDE / 网页锐利字符打散为柔和光晕，保证大面积文字与表单 100% 清晰可读；
/// 3. 实时响应系统浅/深外观切换、辅助功能「降低透明度」与原生内容拖放复制。
@MainActor
final class LiquidGlassSurfaceHost {
    private var containerView: LiquidGlassContentContainerView?
    private weak var backdropBlurView: NSVisualEffectView?
    private weak var activeGlassView: AnyObject?
    private var accessibilityObserver: NSObjectProtocol?

    private var currentStyle: PanelSurfaceStyle = .liquidGlass
    private var currentAppearance: LiquidGlassAppearance = .tinted
    private var currentMaskOpacity: Double = 0.38
    private var cornerRadius: CGFloat = 26

    var onDragTargetedChanged: ((Bool) -> Void)?
    var onPerformDrop: ((NSPasteboard) -> Bool)?

    init() {
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshInPlace()
            }
        }
    }

    deinit {
        if let observer = accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// 挂载原生材质根容器到目标面板（支持透明阴影出血边距，根除 macOS 26 NSGlassEffectView 外发光/SDF 阴影在窗口边界被直角截断）
    func install(
        on panel: NSWindow,
        hostingView: NSView,
        bounds: NSRect,
        bleed: CGFloat = 0,
        cornerRadius: CGFloat,
        style: PanelSurfaceStyle,
        appearance: LiquidGlassAppearance,
        maskOpacity: Double
    ) {
        self.cornerRadius = cornerRadius
        self.currentStyle = style
        self.currentAppearance = appearance
        self.currentMaskOpacity = maskOpacity

        let cardBounds = NSRect(origin: .zero, size: bounds.size)
        hostingView.removeFromSuperview()
        hostingView.frame = cardBounds
        hostingView.autoresizingMask = [.width, .height]

        switch style {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                installNativeLiquidGlass(
                    on: panel,
                    hostingView: hostingView,
                    cardBounds: cardBounds,
                    bleed: bleed,
                    cornerRadius: cornerRadius,
                    appearance: appearance,
                    maskOpacity: maskOpacity
                )
                return
            }
            installFrostedSurface(on: panel, hostingView: hostingView, cardBounds: cardBounds, bleed: bleed, cornerRadius: cornerRadius)

        case .frosted:
            installFrostedSurface(on: panel, hostingView: hostingView, cardBounds: cardBounds, bleed: bleed, cornerRadius: cornerRadius)
        }
    }

    /// 零重建原地热更新液态玻璃档位与浓度
    func updateLiquidGlass(appearance: LiquidGlassAppearance, maskOpacity: Double) {
        self.currentAppearance = appearance
        self.currentMaskOpacity = maskOpacity
        refreshInPlace()
    }

    /// 系统外观或辅助功能变化时原地刷新
    func refreshInPlace() {
        guard currentStyle == .liquidGlass else { return }
        if #available(macOS 26.0, *), let glassView = activeGlassView as? NSGlassEffectView {
            applyCompositeParameters(
                glassView: glassView,
                blurView: backdropBlurView,
                appearance: currentAppearance,
                maskOpacity: currentMaskOpacity
            )
        }
    }

    @available(macOS 26.0, *)
    private func installNativeLiquidGlass(
        on panel: NSWindow,
        hostingView: NSView,
        cardBounds: NSRect,
        bleed: CGFloat,
        cornerRadius: CGFloat,
        appearance: LiquidGlassAppearance,
        maskOpacity: Double
    ) {
        let cardFrame = NSRect(x: bleed, y: bleed, width: cardBounds.width, height: cardBounds.height)
        let glassView = NSGlassEffectView(frame: cardFrame)
        glassView.autoresizingMask = bleed > 0 ? [] : [.width, .height]
        glassView.cornerRadius = cornerRadius

        // 内部内容容器：严格同心连续圆角裁切，承接外观监听与拖拽复制
        let contentContainer = LiquidGlassContentContainerView(frame: cardBounds)
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
        contentContainer.layer?.cornerCurve = .continuous
        contentContainer.layer?.cornerRadius = cornerRadius
        contentContainer.layer?.masksToBounds = true
        contentContainer.onAppearanceChanged = { [weak self] in
            self?.refreshInPlace()
        }
        contentContainer.onDragTargetedChanged = { [weak self] targeted in
            self?.onDragTargetedChanged?(targeted)
        }
        contentContainer.onPerformDrop = { [weak self] pasteboard in
            self?.onPerformDrop?(pasteboard) ?? false
        }

        contentContainer.addSubview(hostingView)
        glassView.contentView = contentContainer

        self.containerView = contentContainer
        self.backdropBlurView = nil
        self.activeGlassView = glassView

        panel.hasShadow = true
        if bleed > 0 {
            let windowBounds = NSRect(
                x: 0,
                y: 0,
                width: cardBounds.width + bleed * 2,
                height: cardBounds.height + bleed * 2
            )
            let bleedRoot = LiquidGlassBleedRootView(frame: windowBounds, cardFrame: cardFrame)
            bleedRoot.addSubview(glassView)
            panel.contentView = bleedRoot
        } else {
            panel.contentView = glassView
        }
        applyCompositeParameters(
            glassView: glassView,
            blurView: nil,
            appearance: appearance,
            maskOpacity: maskOpacity
        )
        panel.invalidateShadow()
    }

    private func installFrostedSurface(
        on panel: NSWindow,
        hostingView: NSView,
        cardBounds: NSRect,
        bleed: CGFloat,
        cornerRadius: CGFloat
    ) {
        self.activeGlassView = nil

        let cardFrame = NSRect(x: bleed, y: bleed, width: cardBounds.width, height: cardBounds.height)
        let effectView = NSVisualEffectView(frame: cardFrame)
        effectView.autoresizingMask = bleed > 0 ? [] : [.width, .height]
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.continuousCornerMaskImage(size: cardBounds.size, radius: cornerRadius)
        effectView.wantsLayer = true
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true

        let contentContainer = LiquidGlassContentContainerView(frame: cardBounds)
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
        contentContainer.layer?.cornerCurve = .continuous
        contentContainer.layer?.cornerRadius = cornerRadius
        contentContainer.layer?.masksToBounds = true
        contentContainer.onDragTargetedChanged = { [weak self] targeted in
            self?.onDragTargetedChanged?(targeted)
        }
        contentContainer.onPerformDrop = { [weak self] pasteboard in
            self?.onPerformDrop?(pasteboard) ?? false
        }
        contentContainer.addSubview(hostingView)
        effectView.addSubview(contentContainer)

        self.containerView = contentContainer
        self.backdropBlurView = effectView
        panel.hasShadow = true
        if bleed > 0 {
            let windowBounds = NSRect(
                x: 0,
                y: 0,
                width: cardBounds.width + bleed * 2,
                height: cardBounds.height + bleed * 2
            )
            let bleedRoot = LiquidGlassBleedRootView(frame: windowBounds, cardFrame: cardFrame)
            bleedRoot.addSubview(effectView)
            panel.contentView = bleedRoot
        } else {
            panel.contentView = effectView
        }
        panel.invalidateShadow()
    }

    @available(macOS 26.0, *)
    private func applyCompositeParameters(
        glassView: NSGlassEffectView,
        blurView: NSVisualEffectView?,
        appearance: LiquidGlassAppearance,
        maskOpacity: Double
    ) {
        let clamped = min(max(maskOpacity, 0.0), 1.0)
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let isDark = glassView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // 100% 遵循 macOS 26 Tahoe 官方 NSGlassEffectView 规范：
        // - 透明 (.clear) 对应官方 .clear 高清透镜折射玻璃（Spotlight / Control Center 风格）
        // - 着色 (.tinted) 对应官方 .regular 标准高可读液态玻璃
        // - 滑块为 0% 时 tintColor = nil，完全保留系统原生光学透镜折射与环境光反射，不糊死通透感
        glassView.style = (appearance == .clear) ? .clear : .regular

        if reduceTransparency {
            glassView.style = .regular
            glassView.tintColor = isDark
                ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 0.96)
                : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 0.96)
            return
        }

        if clamped <= 0.01 {
            glassView.tintColor = nil
        } else {
            // 黄金能见度配比：保留官方边缘透镜折射与通透感，同时柔和压制背后刺眼字符
            let alpha: CGFloat
            if appearance == .clear {
                alpha = isDark
                    ? CGFloat(0.10 + clamped * 0.42)
                    : CGFloat(0.08 + clamped * 0.40)
            } else {
                alpha = CGFloat(clamped * 0.48)
            }
            let tintBase = isDark
                ? NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1.0)
                : NSColor(srgbRed: 0.985, green: 0.988, blue: 0.995, alpha: 1.0)
            glassView.tintColor = tintBase.withAlphaComponent(alpha)
        }
    }

    /// 生成真正符合苹果 `.continuous` 连续曲率（Squircle）的 `@2x` 高清圆角遮罩
    /// 彻底根除 `NSVisualEffectView(.behindWindow)` 在 WindowServer 合成层的四角直角灰块溢出
    static func continuousCornerMaskImage(size: NSSize, radius: CGFloat) -> NSImage {
        let minSide = radius * 2 + 4
        let safeSize = NSSize(width: max(size.width, minSide), height: max(size.height, minSide))
        let scale: CGFloat = 2.0
        let pixelWidth = max(1, Int(ceil(safeSize.width * scale)))
        let pixelHeight = max(1, Int(ceil(safeSize.height * scale)))

        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: safeSize)
        layer.backgroundColor = NSColor.black.cgColor
        layer.cornerCurve = .continuous
        layer.cornerRadius = radius
        layer.masksToBounds = true
        layer.contentsScale = scale

        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            rep.size = safeSize
            NSGraphicsContext.saveGraphicsState()
            if let nsCtx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = nsCtx
                let cg = nsCtx.cgContext
                cg.clear(CGRect(origin: .zero, size: safeSize))
                layer.render(in: cg)
            }
            NSGraphicsContext.restoreGraphicsState()

            let image = NSImage(size: safeSize)
            image.addRepresentation(rep)
            image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            image.resizingMode = .stretch
            return image
        }

        return roundedMaskImage(size: safeSize, radius: radius)
    }

    /// 生成精确圆角遮罩（兜底使用）
    static func roundedMaskImage(size: NSSize, radius: CGFloat) -> NSImage {
        let safeSize = NSSize(width: max(size.width, radius * 2 + 2), height: max(size.height, radius * 2 + 2))
        let image = NSImage(size: safeSize, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 透明阴影出血根容器：隔离 NSNextStepFrame 对 NSGlassEffectView 的直角边框挂钩，并为连续圆角卡片预留无裁切外圈空间
final class LiquidGlassBleedRootView: NSView {
    var cardFrame: NSRect

    init(frame frameRect: NSRect, cardFrame: NSRect) {
        self.cardFrame = cardFrame
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        self.cardFrame = .zero
        super.init(coder: coder)
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard cardFrame.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// 监听系统深/浅外观实时变更并接收外部内容拖放复制的内容容器视图
private final class LiquidGlassContentContainerView: NSView {
    var onAppearanceChanged: (() -> Void)?
    var onDragTargetedChanged: ((Bool) -> Void)?
    var onPerformDrop: ((NSPasteboard) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ClipboardStore.supportedDragTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(ClipboardStore.supportedDragTypes)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              !ClipboardStore.shared.isInternalDragActive,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else { return [] }
        onDragTargetedChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              !ClipboardStore.shared.isInternalDragActive,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargetedChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragTargetedChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource == nil &&
        !ClipboardStore.shared.isInternalDragActive &&
        ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragTargetedChanged?(false)
        return onPerformDrop?(sender.draggingPasteboard) ?? false
    }
}

/// SwiftUI 液态玻璃语义表面色板（边缘保留 100% 官方液态透明折射，文字承载玉片保证高能见度 ≥ 7:1）
struct LiquidGlassPalette {
    let colorScheme: ColorScheme
    let surfaceStyle: PanelSurfaceStyle
    let appearance: LiquidGlassAppearance

    private var isDark: Bool { colorScheme == .dark }
    private var isLiquid: Bool { surfaceStyle == .liquidGlass }
    private var isClearGlass: Bool { isLiquid && appearance == .clear }

    /// 深色模式专用深曜石基色（阻隔背后刺眼白字穿透，同时保持玻璃冷冽质感）
    private var obsidianBase: Color {
        Color(red: 0.10, green: 0.11, blue: 0.135)
    }

    /// 设置页分组卡片 / 面板二级容器底色
    var groupFill: Color {
        if isLiquid {
            if isDark {
                return obsidianBase.opacity(isClearGlass ? 0.76 : 0.56)
            } else {
                return Color.white.opacity(isClearGlass ? 0.80 : 0.68)
            }
        } else {
            return isDark
                ? Color.white.opacity(0.07)
                : Color.white.opacity(0.58)
        }
    }

    /// 分组卡片与内嵌区块的光学切面描边
    var groupStroke: Color {
        if isDark {
            return Color.white.opacity(isClearGlass ? 0.16 : 0.12)
        } else {
            return Color.white.opacity(isLiquid ? 0.76 : 0.55)
        }
    }

    /// 嵌套子卡片底色（如角色版本双卡片、忽略应用行）
    var nestedCardFill: Color {
        if isDark {
            return Color.white.opacity(isClearGlass ? 0.085 : 0.065)
        } else {
            return Color.white.opacity(isClearGlass ? 0.62 : 0.50)
        }
    }

    /// 剪贴板单条卡片底色（透明玻璃下用高能见度曜石/乳白玉片托住文字，四周缝隙透出纯粹玻璃折射）
    func clipCardFill(isHovered: Bool) -> Color {
        if isLiquid {
            if isDark {
                if isClearGlass {
                    return obsidianBase.opacity(isHovered ? 0.86 : 0.74)
                } else {
                    return obsidianBase.opacity(isHovered ? 0.66 : 0.48)
                }
            } else {
                if isClearGlass {
                    return Color.white.opacity(isHovered ? 0.88 : 0.78)
                } else {
                    return Color.white.opacity(isHovered ? 0.80 : 0.64)
                }
            }
        } else {
            return Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.72 : 0.48)
        }
    }

    /// 置顶/收藏卡片底层缓冲色
    func pinnedCardBackdrop(isHovered: Bool) -> Color {
        if isLiquid {
            if isDark {
                return obsidianBase.opacity(isClearGlass ? (isHovered ? 0.84 : 0.72) : (isHovered ? 0.62 : 0.46))
            } else {
                return Color.white.opacity(isClearGlass ? (isHovered ? 0.88 : 0.78) : (isHovered ? 0.76 : 0.62))
            }
        } else {
            return Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.72 : 0.52)
        }
    }

    /// 剪贴板卡片常态/悬停描边
    func clipCardStroke(isHovered: Bool) -> Color {
        if isDark {
            return Color.white.opacity(isHovered ? 0.26 : (isClearGlass ? 0.15 : 0.11))
        } else {
            return isHovered
                ? Color.white.opacity(0.92)
                : (isLiquid ? Color.white.opacity(0.70) : Color.black.opacity(0.06))
        }
    }

    /// 顶部搜索栏、功能圆钮、分段筛选底槽等导航控件填充
    var controlCapsuleFill: Color {
        if isDark {
            return obsidianBase.opacity(isClearGlass ? 0.76 : (isLiquid ? 0.54 : 0.35))
        } else {
            return Color.white.opacity(isClearGlass ? 0.76 : (isLiquid ? 0.60 : 0.48))
        }
    }

    /// 顶部导航控件光学描边
    var controlCapsuleStroke: Color {
        if isDark {
            return Color.white.opacity(isClearGlass ? 0.18 : (isLiquid ? 0.14 : 0.10))
        } else {
            return Color.white.opacity(isLiquid ? 0.82 : 0.55)
        }
    }

    /// 分段筛选器选中胶囊填充
    var activeSegmentFill: Color {
        if isDark {
            return Color.white.opacity(isClearGlass ? 0.24 : 0.20)
        } else {
            return Color.white.opacity(0.95)
        }
    }

    /// 分段筛选器悬停微提示填充（让不可见点击框符合直觉）
    var hoverSegmentFill: Color {
        if isDark {
            return Color.white.opacity(0.11)
        } else {
            return Color.white.opacity(0.48)
        }
    }

    /// 底部状态栏轻托底色（避免小号快捷键文字在透明玻璃下被背后文字干扰）
    var footerBackdrop: Color {
        if isLiquid {
            if isDark {
                return obsidianBase.opacity(isClearGlass ? 0.68 : 0.32)
            } else {
                return Color.white.opacity(isClearGlass ? 0.66 : 0.32)
            }
        } else {
            return Color.clear
        }
    }
}
