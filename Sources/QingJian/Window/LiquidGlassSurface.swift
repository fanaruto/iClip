import AppKit
import SwiftUI

/// macOS 26+ Liquid Glass 官方级双层光学表面控制器
///
/// 遵循 Apple HIG 的核心原则：
/// 1. 大面积文字/表单悬浮面板绝不使用无模糊的裸 `.clear` 玻璃直接铺底，避免背后 IDE/终端的尖锐字符穿透干扰阅读；
/// 2. 底层由 WindowServer 原生 `NSVisualEffectView` 提供真正的高斯柔焦隔断，将复杂背景打散为柔和光晕；
/// 3. 顶层由 macOS 26 原生 `NSGlassEffectView(.regular)` 提供光学透镜折射、边缘高光与环境光采样；
/// 4. 实时响应系统浅/深外观切换与辅助功能「降低透明度」，保证任意背景下均具备高对比度与通透质感。
@MainActor
final class LiquidGlassSurfaceHost {
    private var containerView: LiquidGlassRootContainerView?
    private weak var backdropBlurView: NSVisualEffectView?
    private weak var activeGlassView: AnyObject?
    private var accessibilityObserver: NSObjectProtocol?

    private var currentStyle: PanelSurfaceStyle = .liquidGlass
    private var currentAppearance: LiquidGlassAppearance = .tinted
    private var currentMaskOpacity: Double = 0.38
    private var cornerRadius: CGFloat = 22

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

    /// 挂载原生材质根容器到目标面板
    func install(
        on panel: NSWindow,
        hostingView: NSView,
        bounds: NSRect,
        cornerRadius: CGFloat,
        style: PanelSurfaceStyle,
        appearance: LiquidGlassAppearance,
        maskOpacity: Double
    ) {
        self.cornerRadius = cornerRadius
        self.currentStyle = style
        self.currentAppearance = appearance
        self.currentMaskOpacity = maskOpacity

        hostingView.removeFromSuperview()
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]

        switch style {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                installCompositeLiquidGlass(
                    on: panel,
                    hostingView: hostingView,
                    bounds: bounds,
                    cornerRadius: cornerRadius,
                    appearance: appearance,
                    maskOpacity: maskOpacity
                )
                return
            }
            installFrostedSurface(on: panel, hostingView: hostingView, bounds: bounds, cornerRadius: cornerRadius)

        case .frosted:
            installFrostedSurface(on: panel, hostingView: hostingView, bounds: bounds, cornerRadius: cornerRadius)
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
    private func installCompositeLiquidGlass(
        on panel: NSWindow,
        hostingView: NSView,
        bounds: NSRect,
        cornerRadius: CGFloat,
        appearance: LiquidGlassAppearance,
        maskOpacity: Double
    ) {
        let root = LiquidGlassRootContainerView(frame: bounds)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.onAppearanceChanged = { [weak self] in
            self?.refreshInPlace()
        }

        // Layer 0：底层高斯柔焦隔断层，把背后深色 IDE / 网页锐利字符打散成柔和光晕
        let blurView = NSVisualEffectView(frame: bounds)
        blurView.autoresizingMask = [.width, .height]
        blurView.material = .popover
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.maskImage = Self.roundedMaskImage(size: bounds.size, radius: cornerRadius)
        root.addSubview(blurView)

        // Layer 1：顶层 macOS 26 原生 Liquid Glass 光学透镜外壳
        let glassView = NSGlassEffectView(frame: bounds)
        glassView.autoresizingMask = [.width, .height]
        glassView.cornerRadius = cornerRadius
        glassView.contentView = hostingView
        root.addSubview(glassView)

        self.containerView = root
        self.backdropBlurView = blurView
        self.activeGlassView = glassView

        panel.contentView = root
        applyCompositeParameters(
            glassView: glassView,
            blurView: blurView,
            appearance: appearance,
            maskOpacity: maskOpacity
        )
        panel.invalidateShadow()
    }

    private func installFrostedSurface(
        on panel: NSWindow,
        hostingView: NSView,
        bounds: NSRect,
        cornerRadius: CGFloat
    ) {
        self.containerView = nil
        self.activeGlassView = nil

        let effectView = NSVisualEffectView(frame: bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMaskImage(size: bounds.size, radius: cornerRadius)
        effectView.addSubview(hostingView)

        self.backdropBlurView = effectView
        panel.contentView = effectView
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

        // 遵循 Apple HIG：大面积文字面板统一采用 `.regular` 标准液态玻璃光学折射，绝不让文字裸奔在无模糊 `.clear` 上
        glassView.style = .regular

        if reduceTransparency {
            blurView?.alphaValue = 1.0
            glassView.tintColor = isDark
                ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 0.96)
                : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 0.96)
            return
        }

        // 底层柔焦隔断强度：通透档保持色彩流动同时柔化背后字迹；着色档进一步压制高反差杂色
        let blurAlpha: CGFloat
        let tintAlpha: CGFloat
        switch appearance {
        case .clear:
            blurAlpha = CGFloat(0.56 + clamped * 0.30)   // 0.56 ... 0.86
            tintAlpha = isDark
                ? CGFloat(0.10 + clamped * 0.24)
                : CGFloat(0.12 + clamped * 0.26)
        case .tinted:
            blurAlpha = CGFloat(0.76 + clamped * 0.20)   // 0.76 ... 0.96
            tintAlpha = isDark
                ? CGFloat(0.24 + clamped * 0.34)
                : CGFloat(0.28 + clamped * 0.36)
        }

        blurView?.alphaValue = blurAlpha

        // 使用纯净中性高光色 / 深曜石色着色，避免 windowBackgroundColor 浅灰混在深色 IDE 上产生浑浊脏灰
        let tintBase = isDark
            ? NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
            : NSColor(srgbRed: 0.985, green: 0.988, blue: 0.995, alpha: 1.0)
        glassView.tintColor = tintBase.withAlphaComponent(tintAlpha)
    }

    /// 生成精确连续圆角遮罩，让底层 NSVisualEffectView 配合 WindowServer 原生阴影零锯齿、无方框
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

/// 监听系统深/浅外观实时变更的轻量根视图
private final class LiquidGlassRootContainerView: NSView {
    var onAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}

/// SwiftUI 液态玻璃语义表面色板（确保浅/深双外观、任意复杂背景下文字对比度 ≥ 4.5:1）
struct LiquidGlassPalette {
    let colorScheme: ColorScheme
    let surfaceStyle: PanelSurfaceStyle
    let appearance: LiquidGlassAppearance

    private var isDark: Bool { colorScheme == .dark }
    private var isLiquid: Bool { surfaceStyle == .liquidGlass }
    private var isTinted: Bool { appearance == .tinted }

    /// 设置页分组卡片 / 面板二级容器底色（浅色用温润通透白玉片，深色用微亮暗玉片）
    var groupFill: Color {
        if isLiquid {
            if isDark {
                return Color.white.opacity(isTinted ? 0.095 : 0.08)
            } else {
                return Color.white.opacity(isTinted ? 0.68 : 0.56)
            }
        } else {
            return isDark
                ? Color.white.opacity(0.06)
                : Color.white.opacity(0.54)
        }
    }

    /// 分组卡片与内嵌区块的光学切面描边
    var groupStroke: Color {
        if isDark {
            return Color.white.opacity(isLiquid ? 0.13 : 0.09)
        } else {
            return Color.white.opacity(isLiquid ? 0.72 : 0.55)
        }
    }

    /// 嵌套子卡片底色（如角色版本双卡片、忽略应用行）
    var nestedCardFill: Color {
        if isDark {
            return Color.white.opacity(isLiquid ? 0.075 : 0.055)
        } else {
            return Color.white.opacity(isLiquid ? 0.52 : 0.44)
        }
    }

    /// 剪贴板单条卡片底色
    func clipCardFill(isHovered: Bool) -> Color {
        if isLiquid {
            if isDark {
                return Color.white.opacity(isHovered ? 0.145 : (isTinted ? 0.095 : 0.078))
            } else {
                return Color.white.opacity(isHovered ? 0.80 : (isTinted ? 0.64 : 0.54))
            }
        } else {
            return Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.72 : 0.48)
        }
    }

    /// 置顶卡片底层缓冲色
    func pinnedCardBackdrop(isHovered: Bool) -> Color {
        if isLiquid {
            if isDark {
                return Color.white.opacity(isHovered ? 0.11 : 0.07)
            } else {
                return Color.white.opacity(isHovered ? 0.72 : 0.56)
            }
        } else {
            return Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.72 : 0.52)
        }
    }

    /// 剪贴板卡片常态/悬停描边
    func clipCardStroke(isHovered: Bool) -> Color {
        if isDark {
            return Color.white.opacity(isHovered ? 0.22 : (isLiquid ? 0.12 : 0.08))
        } else {
            return isHovered
                ? Color.white.opacity(0.88)
                : (isLiquid ? Color.white.opacity(0.62) : Color.black.opacity(0.06))
        }
    }

    /// 顶部搜索栏、功能圆钮、分段筛选底槽等导航控件填充（HIG：导航层浮于内容层之上）
    var controlCapsuleFill: Color {
        if isDark {
            return Color.white.opacity(isLiquid ? 0.11 : 0.08)
        } else {
            return Color.white.opacity(isLiquid ? 0.56 : 0.48)
        }
    }

    /// 顶部导航控件光学描边
    var controlCapsuleStroke: Color {
        if isDark {
            return Color.white.opacity(isLiquid ? 0.16 : 0.10)
        } else {
            return Color.white.opacity(isLiquid ? 0.76 : 0.55)
        }
    }

    /// 分段筛选器选中胶囊填充
    var activeSegmentFill: Color {
        if isDark {
            return Color.white.opacity(0.20)
        } else {
            return Color.white.opacity(0.92)
        }
    }

    /// 整窗外缘光学镜面高光环（Liquid Glass 标志性顶部折射亮边 -> 底部柔和收敛）
    var panelSpecularGradient: LinearGradient {
        if isDark {
            return LinearGradient(
                colors: [
                    Color.white.opacity(isLiquid ? 0.26 : 0.14),
                    Color.white.opacity(isLiquid ? 0.09 : 0.06),
                    Color.white.opacity(isLiquid ? 0.16 : 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color.white.opacity(isLiquid ? 0.82 : 0.55),
                    Color.white.opacity(isLiquid ? 0.34 : 0.20),
                    Color.white.opacity(isLiquid ? 0.52 : 0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}
