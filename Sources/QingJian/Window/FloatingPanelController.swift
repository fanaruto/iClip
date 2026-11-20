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

    /// 隐藏面板（向上微仰收起）
    func hide(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        removeKeyMonitor()
        hideWorkItem?.cancel()

        let appToRestore = restoreFocus ? previousApp : nil
        nav.isPresented = false

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, !self.nav.isPresented else { return }
                self.panel.orderOut(nil)
                if let app = appToRestore {
                    app.activate()
                }
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    // MARK: - 智能定位

    private func positionPanel(anchorRect: NSRect?) {
        let size = panel.frame.size

        if let anchor = anchorRect {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            var x = anchor.midX - size.width / 2
            var y = anchor.minY - size.height + outerPadding - 6

            x = max(visible.minX - outerPadding + 10, min(x, visible.maxX - size.width + outerPadding - 10))
            y = max(visible.minY - outerPadding + 10, min(y, visible.maxY - size.height + outerPadding - 6))

            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        // 快捷键呼出时，贴合当前屏幕顶部居中下方，配合瀑布滑落视觉最佳
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height + outerPadding - 12
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY, y)))
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
