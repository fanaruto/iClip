import AppKit
import SwiftUI
import ObjectiveC

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
        maskOpacity: Double,
        autoResizeWithWindow: Bool = false
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
                    maskOpacity: maskOpacity,
                    autoResizeWithWindow: autoResizeWithWindow
                )
                return
            }
            installFrostedSurface(
                on: panel,
                hostingView: hostingView,
                cardBounds: cardBounds,
                bleed: bleed,
                cornerRadius: cornerRadius,
                autoResizeWithWindow: autoResizeWithWindow
            )

        case .frosted:
            installFrostedSurface(
                on: panel,
                hostingView: hostingView,
                cardBounds: cardBounds,
                bleed: bleed,
                cornerRadius: cornerRadius,
                autoResizeWithWindow: autoResizeWithWindow
            )
        }
    }

    /// 零重建原地热更新液态玻璃档位与浓度
    func updateLiquidGlass(appearance: LiquidGlassAppearance, maskOpacity: Double) {
        self.currentAppearance = appearance
        self.currentMaskOpacity = maskOpacity
        refreshInPlace()
    }

    /// 伴生浮卡等动态尺寸切换时，同步更新出血根框、玻璃透镜与柔焦层几何
    func updateGeometry(cardSize: NSSize, bleed: CGFloat, cornerRadius: CGFloat, on panel: NSWindow) {
        self.cornerRadius = cornerRadius
        let totalSize = NSSize(width: cardSize.width + bleed * 2, height: cardSize.height + bleed * 2)
        let cardFrame = NSRect(x: bleed, y: bleed, width: cardSize.width, height: cardSize.height)
        let zeroBounds = NSRect(origin: .zero, size: cardSize)

        if panel.contentView?.frame.size != totalSize {
            panel.setContentSize(totalSize)
        }
        if let bleedRoot = panel.contentView as? LiquidGlassBleedRootView {
            bleedRoot.frame = NSRect(origin: .zero, size: totalSize)
            bleedRoot.cardFrame = cardFrame
        }
        if let blur = backdropBlurView {
            blur.frame = cardFrame
            blur.maskImage = Self.continuousCornerMaskImage(size: cardSize, radius: cornerRadius)
            blur.layer?.cornerRadius = cornerRadius
        }
        if #available(macOS 26.0, *), let glass = activeGlassView as? NSGlassEffectView {
            glass.frame = cardFrame
            glass.cornerRadius = cornerRadius
        }
        if let container = containerView {
            container.frame = zeroBounds
            container.layer?.cornerRadius = cornerRadius
            for sub in container.subviews {
                sub.frame = zeroBounds
            }
        }
        panel.invalidateShadow()
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
        maskOpacity: Double,
        autoResizeWithWindow: Bool
    ) {
        let cardFrame = NSRect(x: bleed, y: bleed, width: cardBounds.width, height: cardBounds.height)

        // 底层：支持动态无级调节高斯模糊半径（0pt ~ 38pt）的连续圆角柔焦层，彻底消除传统半透明叠加导致的背后文字重影
        let blurBackdrop = ConfigurableBlurVisualEffectView(frame: cardFrame)
        blurBackdrop.autoresizingMask = (bleed > 0 && !autoResizeWithWindow) ? [] : [.width, .height]
        blurBackdrop.material = .popover
        blurBackdrop.blendingMode = .behindWindow
        blurBackdrop.state = .active
        blurBackdrop.maskImage = Self.continuousCornerMaskImage(size: cardBounds.size, radius: cornerRadius)
        blurBackdrop.wantsLayer = true
        blurBackdrop.layer?.cornerCurve = .continuous
        blurBackdrop.layer?.cornerRadius = cornerRadius
        blurBackdrop.layer?.masksToBounds = true

        // 顶层：macOS 26 原生 NSGlassEffectView 光学透镜外壳，保留边缘折射与高光
        let glassView = NSGlassEffectView(frame: cardFrame)
        glassView.autoresizingMask = (bleed > 0 && !autoResizeWithWindow) ? [] : [.width, .height]
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
        self.backdropBlurView = blurBackdrop
        self.activeGlassView = glassView

        panel.hasShadow = true
        let windowBounds = NSRect(
            x: 0,
            y: 0,
            width: cardBounds.width + bleed * 2,
            height: cardBounds.height + bleed * 2
        )
        let bleedRoot = LiquidGlassBleedRootView(
            frame: windowBounds,
            cardFrame: cardFrame,
            autoLayoutBleed: autoResizeWithWindow ? bleed : nil
        )
        if bleed == 0 || autoResizeWithWindow {
            bleedRoot.autoresizingMask = [.width, .height]
        }
        bleedRoot.addSubview(blurBackdrop)
        bleedRoot.addSubview(glassView)
        panel.contentView = bleedRoot

        applyCompositeParameters(
            glassView: glassView,
            blurView: blurBackdrop,
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
        cornerRadius: CGFloat,
        autoResizeWithWindow: Bool
    ) {
        self.activeGlassView = nil

        let cardFrame = NSRect(x: bleed, y: bleed, width: cardBounds.width, height: cardBounds.height)
        let effectView = NSVisualEffectView(frame: cardFrame)
        effectView.autoresizingMask = (bleed > 0 && !autoResizeWithWindow) ? [] : [.width, .height]
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
            let bleedRoot = LiquidGlassBleedRootView(
                frame: windowBounds,
                cardFrame: cardFrame,
                autoLayoutBleed: autoResizeWithWindow ? bleed : nil
            )
            if autoResizeWithWindow {
                bleedRoot.autoresizingMask = [.width, .height]
            }
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
        let effectiveApp = glassView.window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDark = effectiveApp.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        if reduceTransparency {
            blurView?.isHidden = true
            blurView?.alphaValue = 0
            glassView.style = .regular
            glassView.tintColor = isDark
                ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 0.96)
                : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 0.96)
            return
        }

        // 驱动底层 CABackdropLayer 真实高斯模糊半径（0pt ~ 38pt），零文字重影、零档位跳变
        glassView.style = .clear

        if clamped <= 0.01 {
            (blurView as? ConfigurableBlurVisualEffectView)?.applyBlurConcentration(0)
            blurView?.isHidden = true
            glassView.tintColor = nil
        } else {
            blurView?.isHidden = false
            blurView?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            blurView?.alphaValue = CGFloat(min(1.0, clamped / 0.18))
            if let configurable = blurView as? ConfigurableBlurVisualEffectView {
                configurable.applyBlurConcentration(clamped)
            }

            let alpha: CGFloat = isDark
                ? CGFloat(0.06 + clamped * 0.44)
                : CGFloat(0.08 + clamped * 0.46)
            let tintBase = isDark
                ? NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
                : NSColor(srgbRed: 0.985, green: 0.99, blue: 1.0, alpha: 1.0)
            glassView.tintColor = tintBase.withAlphaComponent(alpha)
        }
    }

    /// 生成真正符合苹果 `.continuous` 连续曲率（Squircle）的 `@2x` 高清圆角遮罩
    /// 彻底根除 `NSVisualEffectView(.behindWindow)` 在 WindowServer 合成层的四角直角灰块溢出
    /// 苹果 `.continuous` squircle 曲线沿边缘延伸至约 `1.53 × radius`，`capInsets` 取 `1.55 × radius` 防止缩放变形
    static func continuousCornerMaskImage(size: NSSize, radius: CGFloat) -> NSImage {
        let desiredCap = max(radius, ceil(radius * 1.55))
        let halfShortSide = floor(min(size.width, size.height) * 0.5)
        let capInset = max(radius, min(desiredCap, halfShortSide))
        let minSide = radius * 2 + 2
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
            image.capInsets = NSEdgeInsets(top: capInset, left: capInset, bottom: capInset, right: capInset)
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

/// 支持实时无级控制底层 WindowServer `CABackdropLayer` 高斯模糊半径的原生视觉材质视图
private final class ConfigurableBlurVisualEffectView: NSVisualEffectView {
    private var concentration: Double = 0.45

    func applyBlurConcentration(_ value: Double) {
        concentration = min(max(value, 0.0), 1.0)
        syncBackdropFilter()
    }

    override func layout() {
        super.layout()
        syncBackdropFilter()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncBackdropFilter()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncBackdropFilter()
    }

    override func updateLayer() {
        super.updateLayer()
        syncBackdropFilter()
    }

    private func syncBackdropFilter() {
        guard let rootLayer = self.layer else { return }
        // 真实高斯核半径：1% 约 1.2pt 微柔焦 -> 45% 约 17pt 标准柔焦 -> 100% 达 38pt 浓厚磨砂
        let radius = concentration <= 0.01 ? 0.0 : (1.0 + pow(concentration, 1.08) * 37.0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyRadiusRecursively(in: rootLayer, radius: radius, tintScale: CGFloat(concentration))
        CATransaction.commit()
    }

    private func applyRadiusRecursively(in layer: CALayer, radius: Double, tintScale: CGFloat) {
        let clsName = String(describing: type(of: layer))
        if clsName.contains("Backdrop") {
            if layer.value(forKeyPath: "filters.gaussianBlur.inputRadius") != nil {
                layer.setValue(radius, forKeyPath: "filters.gaussianBlur.inputRadius")
            }
        }
        for sub in layer.sublayers ?? [] {
            applyRadiusRecursively(in: sub, radius: radius, tintScale: tintScale)
        }
    }
}

/// 透明阴影出血根容器：隔离 NSNextStepFrame 对 NSGlassEffectView 的直角边框挂钩，并为连续圆角卡片预留无裁切外圈空间
final class LiquidGlassBleedRootView: NSView {
    var cardFrame: NSRect
    var autoLayoutBleed: CGFloat?

    init(frame frameRect: NSRect, cardFrame: NSRect, autoLayoutBleed: CGFloat? = nil) {
        self.cardFrame = cardFrame
        self.autoLayoutBleed = autoLayoutBleed
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        self.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
    }

    required init?(coder: NSCoder) {
        self.cardFrame = .zero
        self.autoLayoutBleed = nil
        super.init(coder: coder)
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        guard let bleed = autoLayoutBleed else { return }
        let insetRect = NSRect(
            x: bleed,
            y: bleed,
            width: max(1, bounds.width - bleed * 2),
            height: max(1, bounds.height - bleed * 2)
        )
        self.cardFrame = insetRect
        for sub in subviews {
            if sub.frame != insetRect {
                sub.frame = insetRect
            }
            if #available(macOS 26.0, *),
               let glass = sub as? NSGlassEffectView,
               let contentView = glass.contentView {
                let zeroOriginRect = NSRect(origin: .zero, size: insetRect.size)
                if contentView.frame != zeroOriginRect {
                    contentView.frame = zeroOriginRect
                }
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let activeCardFrame: NSRect = {
            if let bleed = autoLayoutBleed {
                return NSRect(
                    x: bleed,
                    y: bleed,
                    width: max(1, bounds.width - bleed * 2),
                    height: max(1, bounds.height - bleed * 2)
                )
            }
            return cardFrame
        }()
        guard activeCardFrame.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// 统一全天候激活态非抢焦悬浮面板基类：
/// 解决以 `orderFrontRegardless()` 零失焦唤出与点击聚焦 / 失焦后 AppKit `_hasActiveAppearance`、`NSGlassEffectView` 外折射与 SwiftUI `.controlActiveState` 前后质感不一致问题。
class UnifiedActiveFloatingPanel: NSPanel {
    @objc var _hasActiveAppearance: Bool { true }
    @objc var _hasKeyAppearance: Bool { true }
    @objc var _hasActiveControls: Bool { true }
    @objc var _hasMainAppearance: Bool { true }

    /// 通过精确 C-ABI IMP 同步窗口内部激活外观、控件活跃态与阴影活跃态（绝不触发 `NSApp.activate` 或抢夺宿主窗口焦点）
    func enforceUnifiedActiveAppearance() {
        let forceSel = Selector(("_setForceActiveControls:"))
        if let m = class_getInstanceMethod(object_getClass(self), forceSel),
           method_getNumberOfArguments(m) == 3 {
            var argBuf = [CChar](repeating: 0, count: 16)
            method_getArgumentType(m, 2, &argBuf, argBuf.count)
            let code = argBuf.first ?? 0
            if code == 66 /* 'B' */ || code == 99 /* 'c' */ {
                typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
                let fn = unsafeBitCast(method_getImplementation(m), to: Fn.self)
                fn(self, forceSel, true)
            }
        }

        for zeroArgName in ["acquireKeyAppearance", "_setShadowActiveState"] {
            let sel = Selector((zeroArgName))
            if let m = class_getInstanceMethod(object_getClass(self), sel),
               method_getNumberOfArguments(m) == 2 {
                let retPtr = method_copyReturnType(m)
                let retCode = retPtr.pointee
                free(retPtr)
                if retCode == 118 /* 'v' */ {
                    typealias Fn0 = @convention(c) (AnyObject, Selector) -> Void
                    let fn = unsafeBitCast(method_getImplementation(m), to: Fn0.self)
                    fn(self, sel)
                }
            }
        }
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        enforceUnifiedActiveAppearance()
    }

    override func resignKey() {
        super.resignKey()
        enforceUnifiedActiveAppearance()
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

// MARK: - 苹果官方风格「液态玻璃」实景预览与背景模糊浓度单轴控制器

/// 对标 macOS 系统设置「外观 -> Liquid Glass」：单一连续滑块调节背景模糊浓度，上方实景胶囊实时呈现折射与柔焦变化
struct LiquidGlassBlurStyleCard: View {
    @Binding var blurConcentration: Double
    @Environment(\.colorScheme) private var colorScheme
    @State private var lastDetentIndex: Int? = nil

    private var concentrationLabel: String {
        let pct = Int(round(blurConcentration * 100))
        if blurConcentration < 0.22 {
            return "清透折射 · \(pct)%"
        } else if blurConcentration < 0.68 {
            return "均衡柔焦 · \(pct)%"
        } else {
            return "浓厚磨砂 · \(pct)%"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("背景模糊浓度")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(concentrationLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // 实景光学折射与背景模糊预览窗
            ZStack(alignment: .top) {
                LiquidGlassScenicBackdrop(isDark: colorScheme == .dark)

                // 与底层景物 100% 像素对齐的液态玻璃模糊采样层
                ZStack {
                    LiquidGlassScenicBackdrop(isDark: colorScheme == .dark)
                        .scaleEffect(1.025 - blurConcentration * 0.02)
                        .blur(radius: 1.4 + blurConcentration * 15.5)

                    (colorScheme == .dark
                        ? Color(red: 0.10, green: 0.12, blue: 0.16)
                        : Color.white)
                        .opacity(0.14 + blurConcentration * 0.62)
                }
                .mask(alignment: .top) {
                    previewToolbarMask
                        .padding(.horizontal, 12)
                        .padding(.top, 11)
                }

                // 顶层悬浮胶囊高光切面与图标文字
                previewToolbarForeground
                    .padding(.horizontal, 12)
                    .padding(.top, 11)
            }
            .frame(height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 0.6)
            )

            // 苹果官方单轴滑块：左清透双框 -> 三档刻度滑轨 -> 右磨砂实心双框
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                        blurConcentration = 0.08
                    }
                    TactileFeedbackEngine.shared.performNavigationStepHaptic()
                } label: {
                    OverlappingGlassSquaresGlyph(frosted: false)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("清透折射（低背景模糊）")

                VStack(spacing: 3) {
                    Slider(value: $blurConcentration, in: 0.0...1.0)
                        .controlSize(.small)
                        .onChange(of: blurConcentration) { _, newVal in
                            let currentDetent: Int?
                            if abs(newVal - 0.08) < 0.025 {
                                currentDetent = 0
                            } else if abs(newVal - 0.45) < 0.025 {
                                currentDetent = 1
                            } else if abs(newVal - 0.88) < 0.025 {
                                currentDetent = 2
                            } else {
                                currentDetent = nil
                            }
                            if let d = currentDetent, d != lastDetentIndex {
                                TactileFeedbackEngine.shared.performNavigationStepHaptic()
                            }
                            lastDetentIndex = currentDetent
                        }

                    // 三枚对齐官方的微刻度锚点（清透 · 均衡 · 浓厚柔焦）
                    GeometryReader { geo in
                        let w = geo.size.width
                        ZStack(alignment: .leading) {
                            ForEach([0.08, 0.45, 0.88], id: \.self) { pos in
                                Circle()
                                    .fill(Color.secondary.opacity(0.45))
                                    .frame(width: 2.5, height: 2.5)
                                    .offset(x: max(0, min(w - 2.5, (w - 14) * pos + 5.75)))
                            }
                        }
                    }
                    .frame(height: 3)
                }

                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                        blurConcentration = 0.88
                    }
                    TactileFeedbackEngine.shared.performNavigationStepHaptic()
                } label: {
                    OverlappingGlassSquaresGlyph(frosted: true)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("浓厚磨砂（高背景模糊）")
            }
            .padding(.top, 1)
        }
    }

    private var previewToolbarMask: some View {
        HStack(spacing: 8) {
            Capsule(style: .continuous)
                .frame(width: 68, height: 32)
            Circle()
                .frame(width: 32, height: 32)
            Capsule(style: .continuous)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
        }
    }

    private var previewToolbarForeground: some View {
        let rimGradient = LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.48 : 0.88),
                Color.white.opacity(colorScheme == .dark ? 0.14 : 0.32),
                Color.white.opacity(colorScheme == .dark ? 0.28 : 0.56)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let fgColor: Color = colorScheme == .dark ? .white : Color(white: 0.10)

        return HStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(fgColor)
            .frame(width: 68, height: 32)
            .overlay(Capsule(style: .continuous).strokeBorder(rimGradient, lineWidth: 0.85))
            .shadow(color: .black.opacity(0.10), radius: 4, y: 2)

            Image(systemName: "square.on.square")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(fgColor)
                .frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(rimGradient, lineWidth: 0.85))
                .shadow(color: .black.opacity(0.10), radius: 4, y: 2)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(fgColor.opacity(0.68))
                Text("搜索")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(fgColor.opacity(0.68))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .overlay(Capsule(style: .continuous).strokeBorder(rimGradient, lineWidth: 0.85))
            .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
        }
    }
}

/// 苹果官方风格双叠圆角方框刻度图标（左侧清透线框 / 右侧磨砂实心）
private struct OverlappingGlassSquaresGlyph: View {
    let frosted: Bool

    var body: some View {
        Canvas { ctx, size in
            let backRect = CGRect(x: 1.5, y: 1.5, width: 10.5, height: 10.5)
            let frontRect = CGRect(x: 6.0, y: 6.0, width: 10.5, height: 10.5)
            let backPath = Path(roundedRect: backRect, cornerRadius: 2.8, style: .continuous)
            let frontPath = Path(roundedRect: frontRect, cornerRadius: 2.8, style: .continuous)
            let strokeColor = Color.secondary.opacity(0.85)

            if frosted {
                ctx.fill(backPath, with: .color(Color.secondary.opacity(0.30)))
                ctx.stroke(backPath, with: .color(strokeColor), lineWidth: 1.15)
                ctx.fill(frontPath, with: .color(Color.secondary.opacity(0.88)))
            } else {
                ctx.stroke(backPath, with: .color(strokeColor), lineWidth: 1.15)
                ctx.fill(frontPath, with: .color(Color.secondary.opacity(0.08)))
                ctx.stroke(frontPath, with: .color(strokeColor), lineWidth: 1.15)
            }
        }
    }
}

/// 零外部位图体积的 macOS Tahoe 原生流光缎带与桌面文稿预览舞台（供液态玻璃胶囊实时折射与模糊采样）
private struct LiquidGlassScenicBackdrop: View {
    let isDark: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Canvas { ctx, size in
                let w = size.width
                let h = size.height

                // 1. macOS 原生晴空 / 午夜深海基底渐变
                let baseColors: [Color] = isDark
                    ? [Color(red: 0.06, green: 0.11, blue: 0.24), Color(red: 0.11, green: 0.21, blue: 0.42), Color(red: 0.18, green: 0.30, blue: 0.54)]
                    : [Color(red: 0.24, green: 0.54, blue: 0.94), Color(red: 0.48, green: 0.74, blue: 0.98), Color(red: 0.84, green: 0.92, blue: 1.00)]
                ctx.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: baseColors),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: w, y: h * 0.85)
                    )
                )

                // 2. Tahoe 标志性多层流体色带（横贯顶部胶囊下方的青蓝、暖珀与靛紫光弧，清晰呈现折射过渡）
                let ribbon1 = Path { p in
                    p.move(to: CGPoint(x: -w * 0.08, y: h * 0.56))
                    p.addCurve(
                        to: CGPoint(x: w * 1.08, y: h * 0.08),
                        control1: CGPoint(x: w * 0.28, y: h * 0.02),
                        control2: CGPoint(x: w * 0.66, y: h * 0.62)
                    )
                    p.addLine(to: CGPoint(x: w * 1.08, y: h * 0.85))
                    p.addLine(to: CGPoint(x: -w * 0.08, y: h * 0.85))
                    p.closeSubpath()
                }
                ctx.fill(
                    ribbon1,
                    with: .linearGradient(
                        Gradient(colors: isDark
                            ? [Color(red: 0.16, green: 0.48, blue: 0.88).opacity(0.85), Color(red: 0.38, green: 0.26, blue: 0.78).opacity(0.80)]
                            : [Color(red: 0.14, green: 0.66, blue: 0.96).opacity(0.82), Color(red: 0.32, green: 0.42, blue: 0.94).opacity(0.75)]
                        ),
                        startPoint: CGPoint(x: 0, y: h * 0.15),
                        endPoint: CGPoint(x: w, y: h * 0.75)
                    )
                )

                let ribbon2 = Path { p in
                    p.move(to: CGPoint(x: w * 0.18, y: h * 0.85))
                    p.addCurve(
                        to: CGPoint(x: w * 1.06, y: h * 0.16),
                        control1: CGPoint(x: w * 0.46, y: h * 0.18),
                        control2: CGPoint(x: w * 0.78, y: h * 0.46)
                    )
                    p.addLine(to: CGPoint(x: w * 1.06, y: h * 0.85))
                    p.closeSubpath()
                }
                ctx.fill(
                    ribbon2,
                    with: .linearGradient(
                        Gradient(colors: isDark
                            ? [Color(red: 0.92, green: 0.52, blue: 0.28).opacity(0.72), Color(red: 0.18, green: 0.62, blue: 0.68).opacity(0.78)]
                            : [Color(red: 0.99, green: 0.68, blue: 0.36).opacity(0.86), Color(red: 0.22, green: 0.76, blue: 0.78).opacity(0.82)]
                        ),
                        startPoint: CGPoint(x: w * 0.25, y: h * 0.22),
                        endPoint: CGPoint(x: w * 0.95, y: h * 0.78)
                    )
                )
            }

            // 右侧局部桌面文稿卡片（上沿穿过顶部搜索胶囊后方，直观检验锐利内容随滑块柔焦消融的过程）
            VStack(alignment: .leading, spacing: 3.5) {
                HStack(spacing: 4) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 5.5, height: 5.5)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 5.5, height: 5.5)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 5.5, height: 5.5)
                    Text("Notes.md")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text("原生连续曲率与无级背景柔焦")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isDark ? Color.white.opacity(0.92) : Color(white: 0.14))
                    .lineLimit(1)
                Text("LiquidGlass(blur: smooth)")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6.5)
            .frame(width: 186, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDark ? Color(red: 0.13, green: 0.15, blue: 0.20).opacity(0.94) : Color.white.opacity(0.94))
            )
            .padding(.leading, 144)
            .padding(.bottom, 38)

            // 底部标题底栏
            HStack {
                Text("iClip 液态玻璃 · 实时背景柔焦预览")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isDark ? Color.white.opacity(0.90) : Color(white: 0.14))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 25)
            .background(isDark ? Color(red: 0.12, green: 0.13, blue: 0.16) : Color(red: 0.95, green: 0.95, blue: 0.96))
        }
    }
}

/// 卡片皮肤选择器（原生雅致默认轻量 vs 轻量化立体光影：常驻唯一选框 120Hz 滑移过渡，零边框割裂）
struct CardSkinStylePickerCard: View {
    @Binding var cardSkin: CardSkinStyle
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredSkin: CardSkinStyle? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("卡片皮肤")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(cardSkin.badgeTitle)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12)))
                    .animation(.easeInOut(duration: 0.2), value: cardSkin)
            }

            HStack(spacing: 10) {
                ForEach(CardSkinStyle.allCases) { skin in
                    let isSelected = (cardSkin == skin)
                    let isItemHovered = (hoveredSkin == skin)
                    Button {
                        guard cardSkin != skin else { return }
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                            cardSkin = skin
                        }
                        TactileFeedbackEngine.shared.performNavigationStepHaptic()
                    } label: {
                        skinOptionTile(skin: skin, isSelected: isSelected, isItemHovered: isItemHovered)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.14)) {
                            hoveredSkin = hovering ? skin : (hoveredSkin == skin ? nil : hoveredSkin)
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    let tileW = max(0, (geo.size.width - 10) * 0.5)
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .frame(width: tileW, height: geo.size.height)
                        .offset(x: cardSkin == .nativeApple ? 0 : tileW + 10)
                        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: cardSkin)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func skinOptionTile(skin: CardSkinStyle, isSelected: Bool, isItemHovered: Bool) -> some View {
        let previewBaseFill = colorScheme == .dark
            ? Color.white.opacity(isSelected ? 0.10 : (isItemHovered ? 0.08 : 0.05))
            : Color.white.opacity(isSelected ? 0.88 : (isItemHovered ? 0.72 : 0.56))
        let hairlineColor = colorScheme == .dark
            ? Color.white.opacity(isItemHovered ? 0.20 : 0.11)
            : Color.black.opacity(isItemHovered ? 0.11 : 0.06)

        return VStack(alignment: .leading, spacing: 7) {
            miniCardPreview(skin: skin)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    Text(skin.title)
                        .font(.system(size: 12.2, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(skin.subtitle)
                    .font(.system(size: 10.2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(previewBaseFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(hairlineColor, lineWidth: 0.7)
                .opacity(isSelected ? 0 : 1)
                .animation(.spring(response: 0.36, dampingFraction: 0.86), value: isSelected)
        }
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func miniCardPreview(skin: CardSkinStyle) -> some View {
        let cardFill = colorScheme == .dark
            ? Color(red: 0.15, green: 0.16, blue: 0.19)
            : Color.white.opacity(0.95)
        let cardStroke = colorScheme == .dark
            ? Color.white.opacity(skin == .spatialGlass ? 0.24 : 0.12)
            : Color.black.opacity(skin == .spatialGlass ? 0.06 : 0.08)

        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color.black.opacity(0.24) : Color(red: 0.91, green: 0.93, blue: 0.97))

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 68, height: 5.5)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 44, height: 4.5)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(cardFill)
            )
            .overlay {
                if skin == .spatialGlass {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(colorScheme == .dark ? 0.15 : 0.45), .clear],
                                center: UnitPoint(x: 0.35, y: 0.15),
                                startRadius: 1,
                                endRadius: 56
                            )
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(cardStroke, lineWidth: 0.7)
            )
            .shadow(
                color: Color.black.opacity(skin == .spatialGlass ? (colorScheme == .dark ? 0.36 : 0.13) : (colorScheme == .dark ? 0.18 : 0.05)),
                radius: skin == .spatialGlass ? 5 : 2,
                y: skin == .spatialGlass ? 2.5 : 1
            )
            .rotation3DEffect(
                .degrees(skin == .spatialGlass ? 4.2 : 0),
                axis: (x: 0.35, y: -0.9, z: 0),
                perspective: 0.78
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(height: 52)
    }
}

/// 苹果物理按压微弹簧按钮样式（全应用微交互共用）
struct PhysicalSpringButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

/// 悬浮精灵小球设置卡片：控制显隐、4 套视觉皮肤选择及靠边/自由停靠习惯
struct SpriteOrbSettingsCard: View {
    @Binding var enabled: Bool
    @Binding var style: SpriteOrbStyle
    @Binding var dockMode: SpriteOrbDockMode
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var styleSelectionNS
    @State private var hoveredStyle: SpriteOrbStyle? = nil

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled.animation(.spring(response: 0.34, dampingFraction: 0.82))) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("悬浮精灵小球")
                        .font(.system(size: 13.5, weight: .medium))
                    Text("单击剪贴板 · 拖动换位 · 长按语音记待办")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if enabled {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(SpriteOrbStyle.allCases) { item in
                            let isSelected = (style == item)
                            let isHovered = (hoveredStyle == item)
                            Button {
                                guard style != item else { return }
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                    style = item
                                }
                                TactileFeedbackEngine.shared.performNavigationStepHaptic()
                            } label: {
                                styleOptionCard(item: item, isSelected: isSelected, isHovered: isHovered)
                            }
                            .buttonStyle(PhysicalSpringButtonStyle())
                            .onHover { hovering in
                                withAnimation(.easeOut(duration: 0.14)) {
                                    hoveredStyle = hovering ? item : (hoveredStyle == item ? nil : hoveredStyle)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("闲置停靠方式")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $dockMode.animation(.spring(response: 0.30, dampingFraction: 0.82))) {
                            ForEach(SpriteOrbDockMode.allCases) { mode in
                                Text(mode.shortLabel).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(dockMode.subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: enabled)
    }

    private func styleOptionCard(item: SpriteOrbStyle, isSelected: Bool, isHovered: Bool) -> some View {
        let fillColor = colorScheme == .dark
            ? Color.white.opacity(isSelected ? 0.11 : (isHovered ? 0.08 : 0.045))
            : Color.white.opacity(isSelected ? 0.90 : (isHovered ? 0.76 : 0.58))
        let idleBorder = colorScheme == .dark
            ? Color.white.opacity(isHovered ? 0.22 : 0.11)
            : Color.black.opacity(isHovered ? 0.13 : 0.07)

        return HStack(spacing: 8) {
            miniStyleGlyph(for: item)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.shortLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 9.8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(idleBorder, lineWidth: 0.7)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .matchedGeometryEffect(id: "orbStyleSelectionRing", in: styleSelectionNS)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func miniStyleGlyph(for item: SpriteOrbStyle) -> some View {
        switch item {
        case .prismDew:
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(red: 0.118, green: 0.369, blue: 1.0).opacity(0.65), Color.cyan.opacity(0.25)],
                            center: .center,
                            startRadius: 1,
                            endRadius: 12
                        )
                    )
                Circle()
                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.1)
                Circle()
                    .fill(Color.white.opacity(0.88))
                    .frame(width: 4.5, height: 4.5)
                    .offset(x: -3.5, y: -3.5)
            }
        case .matrixCrown:
            ZStack {
                Circle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06))
                Circle()
                    .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.0)
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        case .organicJade:
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.063, green: 0.725, blue: 0.506), Color(red: 0.118, green: 0.369, blue: 1.0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .rotationEffect(.degrees(18))
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 6, height: 6)
                    .offset(x: -2.5, y: -2.5)
            }
        case .auroraRibbon:
            ZStack {
                Circle()
                    .stroke(Color(red: 0.118, green: 0.369, blue: 1.0).opacity(0.78), lineWidth: 1.4)
                    .scaleEffect(x: 1.0, y: 0.6)
                    .rotationEffect(.degrees(25))
                Circle()
                    .stroke(Color(red: 0.063, green: 0.725, blue: 0.506).opacity(0.78), lineWidth: 1.3)
                    .scaleEffect(x: 1.0, y: 0.58)
                    .rotationEffect(.degrees(-35))
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 4.5, height: 4.5)
            }
        }
    }
}
