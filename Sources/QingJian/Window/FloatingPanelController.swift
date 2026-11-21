import AppKit
import SwiftUI

/// 支持获取键盘焦点且不抢占空间切换的悬浮面板
final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 悬浮窗控制器：负责丝滑显隐、智能定位、键盘导航与焦点恢复
@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private var panel: KeyableFloatingPanel!
    private let nav = PanelNavigationModel()
    private let store = ClipboardStore.shared
    private var rootView: ClipboardPopoverView!
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var hideWorkItem: DispatchWorkItem?
    private let outerPadding: CGFloat = 24

    var isVisible: Bool {
        (panel?.isVisible ?? false) && nav.isPresented
    }

    override init() {
        super.init()
        setupPanel()
    }

    private func setupPanel() {
        let panelSize = NSSize(width: 468, height: 608)
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
        // 使用 SwiftUI 动态阴影跟随 3D 透视变形
        p.hasShadow = false
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

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = contentRect
        p.contentView = hostingView

        self.panel = p
    }

    /// 切换显隐状态
    func toggle(anchorRect: NSRect? = nil) {
        if isVisible {
            hide(restoreFocus: true)
        } else {
            show(anchorRect: anchorRect)
        }
    }

    /// 弹出面板（顶部 3D 透视瀑布滑落）
    func show(anchorRect: NSRect? = nil) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        nav.isPresented = false
        nav.resetOnOpen()
        positionPanel(anchorRect: anchorRect)

        panel.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // 下一帧触发 SwiftUI 3D 透视 + 卡片错峰瀑布滑落
        DispatchQueue.main.async { [weak self] in
            self?.nav.isPresented = true
        }

        installKeyMonitor()
    }

    /// 隐藏面板（向上微仰收起，并立即交还焦点给原应用以加速粘贴）
    func hide(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        removeKeyMonitor()
        hideWorkItem?.cancel()

        let appToRestore = restoreFocus ? previousApp : nil
        nav.isPresented = false

        // 立刻交还焦点，让收起动画与自动粘贴并行，消除体感延迟
        if let app = appToRestore {
            app.activate()
        }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, !self.nav.isPresented else { return }
                self.panel.orderOut(nil)
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    // MARK: - 智能定位（菜单栏下方 / 鼠标光标旁直觉弹出）

    private func positionPanel(anchorRect: NSRect?) {
        let size = panel.frame.size
        let cardWidth = size.width - outerPadding * 2
        let cardHeight = size.height - outerPadding * 2

        if let anchor = anchorRect {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            var cardLeft = anchor.midX - cardWidth / 2
            var cardBottom = anchor.minY - cardHeight - 6

            cardLeft = max(visible.minX + 10, min(cardLeft, visible.maxX - cardWidth - 10))
            cardBottom = max(visible.minY + 10, min(cardBottom, visible.maxY - cardHeight - 6))

            nav.appearAnchor = .top
            nav.appearOffsetX = 0
            nav.appearOffsetY = -24
            panel.setFrameOrigin(NSPoint(x: cardLeft - outerPadding, y: cardBottom - outerPadding))
            return
        }

        // 快捷键呼出：贴近当前鼠标光标旁直觉出现，自动避让屏幕边缘
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let gap: CGFloat = 14

        // 优先出现在鼠标右侧，空间不足则自然翻转到鼠标左侧
        let placeOnRight = (mouse.x + gap + cardWidth) <= (visible.maxX - 10)
        var cardLeft = placeOnRight ? (mouse.x + gap) : (mouse.x - gap - cardWidth)
        cardLeft = max(visible.minX + 10, min(cardLeft, visible.maxX - cardWidth - 10))

        // 面板顶部略高于鼠标，使光标平齐列表前排卡片，手腕移动最短
        var cardTop = mouse.y + 52
        cardTop = min(cardTop, visible.maxY - 10)
        var cardBottom = cardTop - cardHeight
        if cardBottom < visible.minY + 10 {
            cardBottom = visible.minY + 10
            cardTop = cardBottom + cardHeight
        }

        // 根据鼠标在面板上的相对位置计算出场缩放锚点与微位移方向
        let relY = max(0.08, min(0.92, (cardTop - mouse.y) / cardHeight))
        nav.appearAnchor = UnitPoint(x: placeOnRight ? 0.04 : 0.96, y: relY)
        nav.appearOffsetX = placeOnRight ? -16 : 16
        nav.appearOffsetY = -14

        panel.setFrameOrigin(NSPoint(x: cardLeft - outerPadding, y: cardBottom - outerPadding))
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

        // ESC 关闭面板（设置页则先返回列表）
        if event.keyCode == 53 {
            if nav.showSettings {
                nav.showSettings = false
            } else {
                hide(restoreFocus: true)
            }
            return nil
        }

        // 设置页不拦截列表导航键
        if nav.showSettings {
            return event
        }

        // ⌘1 ~ ⌘9 快速粘贴对应序号
        if flags == .command, let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1...9).contains(digit) {
            rootView.pasteItem(at: digit - 1)
            return nil
        }

        // ⌘⌫ 删除当前选中项
        if flags == .command, event.keyCode == 51 {
            rootView.deleteSelected()
            return nil
        }

        // ↑ 上移
        if event.keyCode == 126 {
            rootView.moveSelection(delta: -1)
            return nil
        }

        // ↓ 下移
        if event.keyCode == 125 {
            rootView.moveSelection(delta: 1)
            return nil
        }

        // 回车粘贴选中项（兼容主键盘 Return 与小键盘 Enter）
        if event.keyCode == 36 || event.keyCode == 76 {
            // 如果输入法正在组字，交还给系统输入法确认选词
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            rootView.pasteSelected()
            return nil
        }

        return event
    }
}
