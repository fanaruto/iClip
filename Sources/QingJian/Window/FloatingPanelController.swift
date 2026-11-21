import AppKit
import SwiftUI
import Combine

/// 支持获取键盘焦点且不抢占空间切换的悬浮面板
final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 悬浮窗控制器：使用苹果官方 WindowServer 级原生材质根容器（NSGlassEffectView / NSVisualEffectView）
/// 彻底消除透明大画布阴影截断方框，保留系统原生连续圆角与柔和投影
@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private var panel: KeyableFloatingPanel!
    private var hostingView: NSHostingView<ClipboardPopoverView>!
    private let nav = PanelNavigationModel()
    private let store = ClipboardStore.shared
    private var rootView: ClipboardPopoverView!
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var hideWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private let panelSize = NSSize(width: 420, height: 560)
    private let cornerRadius: CGFloat = 22

    var isVisible: Bool {
        (panel?.isVisible ?? false) && nav.isPresented
    }

    override init() {
        super.init()
        setupPanel()
        observeSurfaceStyle()
    }

    private func setupPanel() {
        let contentRect = NSRect(origin: .zero, size: panelSize)

        let p = KeyableFloatingPanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        // 交由 macOS WindowServer 渲染真正的原生连续圆角阴影，永不截断、零方框感
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.delegate = self

        let view = ClipboardPopoverView(
            store: store,
            nav: nav,
            onDismiss: { [weak self] in
                self?.hide(restoreFocus: true)
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        self.rootView = view

        let hosting = NSHostingView(rootView: view)
        hosting.frame = contentRect
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        self.hostingView = hosting

        self.panel = p
        applyNativeSurface(style: store.surfaceStyle)
    }

    private func observeSurfaceStyle() {
        store.$surfaceStyle
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] newStyle in
                self?.applyNativeSurface(style: newStyle)
            }
            .store(in: &cancellables)
    }

    /// 按苹果官方文档方式将 NSHostingView 直接挂载为 NSGlassEffectView / NSVisualEffectView 的原生内容视图
    private func applyNativeSurface(style: PanelSurfaceStyle) {
        let bounds = NSRect(origin: .zero, size: panelSize)
        hostingView.removeFromSuperview()
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]

        switch style {
        case .liquidGlass, .clearGlass:
            if #available(macOS 26.0, *) {
                let glassView = NSGlassEffectView(frame: bounds)
                glassView.autoresizingMask = [.width, .height]
                glassView.style = (style == .clearGlass) ? .clear : .regular
                glassView.cornerRadius = cornerRadius
                glassView.tintColor = nil
                glassView.contentView = hostingView
                panel.contentView = glassView
                panel.invalidateShadow()
                return
            }
            // macOS 26 以下优雅降级为系统毛玻璃
            installVisualEffectSurface(material: style == .clearGlass ? .underWindowBackground : .popover, bounds: bounds)

        case .frosted:
            installVisualEffectSurface(material: .popover, bounds: bounds)
        }
    }

    private func installVisualEffectSurface(material: NSVisualEffectView.Material, bounds: NSRect) {
        let effectView = NSVisualEffectView(frame: bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = material
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMaskImage(size: bounds.size, radius: cornerRadius)
        effectView.addSubview(hostingView)
        panel.contentView = effectView
        panel.invalidateShadow()
    }

    /// 生成精确连续圆角遮罩，让 NSVisualEffectView 配合 WindowServer 原生阴影完美无锯齿、无外框
    private static func roundedMaskImage(size: NSSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// 切换显隐状态
    func toggle(anchorRect: NSRect? = nil) {
        if isVisible {
            hide(restoreFocus: true)
        } else {
            show(anchorRect: anchorRect)
        }
    }

    /// 弹出面板（鼠标旁直觉位置 + 原生窗口级轻柔滑入 + 内部卡片错峰浮现）
    func show(anchorRect: NSRect? = nil) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        nav.isPresented = false
        nav.resetOnOpen()

        let (finalOrigin, entryDelta) = computePanelOrigin(anchorRect: anchorRect)
        let startOrigin = NSPoint(x: finalOrigin.x + entryDelta.x, y: finalOrigin.y + entryDelta.y)

        panel.setFrameOrigin(startOrigin)
        panel.alphaValue = 0

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        }

        DispatchQueue.main.async { [weak self] in
            self?.nav.isPresented = true
        }

        installKeyMonitor()
    }

    /// 隐藏面板（顺滑淡出并立即交还焦点给原应用以加速键入）
    func hide(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        removeKeyMonitor()
        hideWorkItem?.cancel()

        let appToRestore = restoreFocus ? previousApp : nil
        nav.isPresented = false

        if let app = appToRestore {
            app.activate()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, !self.nav.isPresented else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: work)
    }

    // MARK: - 智能定位（菜单栏下方 / 鼠标光标旁直觉出现）

    private func computePanelOrigin(anchorRect: NSRect?) -> (origin: NSPoint, entryDelta: NSPoint) {
        let cardWidth = panelSize.width
        let cardHeight = panelSize.height

        if let anchor = anchorRect {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            var cardLeft = anchor.midX - cardWidth / 2
            var cardBottom = anchor.minY - cardHeight - 6

            cardLeft = max(visible.minX + 10, min(cardLeft, visible.maxX - cardWidth - 10))
            cardBottom = max(visible.minY + 10, min(cardBottom, visible.maxY - cardHeight - 6))

            return (NSPoint(x: cardLeft, y: cardBottom), NSPoint(x: 0, y: 10))
        }

        // 快捷键呼出：紧贴当前鼠标光标旁直觉出现，自动避让屏幕边缘
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let gap: CGFloat = 14

        let placeOnRight = (mouse.x + gap + cardWidth) <= (visible.maxX - 10)
        var cardLeft = placeOnRight ? (mouse.x + gap) : (mouse.x - gap - cardWidth)
        cardLeft = max(visible.minX + 10, min(cardLeft, visible.maxX - cardWidth - 10))

        var cardTop = mouse.y + 52
        cardTop = min(cardTop, visible.maxY - 10)
        var cardBottom = cardTop - cardHeight
        if cardBottom < visible.minY + 10 {
            cardBottom = visible.minY + 10
        }

        return (
            NSPoint(x: cardLeft, y: cardBottom),
            NSPoint(x: placeOnRight ? -8 : 8, y: 6)
        )
    }

    // MARK: - 失焦自动隐藏

    func windowDidResignKey(_ notification: Notification) {
        hide(restoreFocus: false)
    }

    // MARK: - 键盘快捷键流

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 {
            if nav.showSettings {
                nav.showSettings = false
            } else {
                hide(restoreFocus: true)
            }
            return nil
        }

        if nav.showSettings {
            return event
        }

        if flags == .command, let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1...9).contains(digit) {
            rootView.pasteItem(at: digit - 1)
            return nil
        }

        if flags == .command, event.keyCode == 51 {
            rootView.deleteSelected()
            return nil
        }

        if event.keyCode == 126 {
            rootView.moveSelection(delta: -1)
            return nil
        }

        if event.keyCode == 125 {
            rootView.moveSelection(delta: 1)
            return nil
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            rootView.pasteSelected()
            return nil
        }

        return event
    }
}
