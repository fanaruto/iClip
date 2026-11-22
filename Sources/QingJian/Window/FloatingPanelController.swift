#if ICLIP_EDITION_FLOW
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
    private let surfaceHost = LiquidGlassSurfaceHost()
    let nav = PanelNavigationModel()
    private let store = ClipboardStore.shared
    private var rootView: ClipboardPopoverView!
    private var demoRunner: DemoShowcaseRunner?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var hideWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private let panelSize = NSSize(width: 420, height: 560)
    private let cornerRadius: CGFloat = 26

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
        surfaceHost.onDragTargetedChanged = { [weak self] targeted in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                self.nav.isDragTargeted = targeted
            }
        }
        surfaceHost.onPerformDrop = { [weak self] draggingPasteboard in
            guard let self else { return false }
            let ok = self.store.importAndCopy(from: draggingPasteboard, sourceLabel: "拖拽复制")
            if ok {
                self.nav.selectedIndex = 0
                self.nav.preferredGridColumn = nil
                self.nav.scrollRequestEpoch &+= 1
            }
            return ok
        }
        applyNativeSurface(style: store.surfaceStyle)
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            let runner = DemoShowcaseRunner(panelController: self, store: store, nav: nav)
            self.demoRunner = runner
            runner.start()
        }
    }

    /// 供实机演示编排调用：在指定屏幕位置带丝滑动画弹出真实面板
    func showForDemo(origin: NSPoint, entryDelta: NSPoint) {
        nav.isPresented = false
        nav.resetOnOpen()
        store.onPanelShown(visibleItems: nav.cachedFilteredItems)
        nav.suppressAutoHide = true

        let startOrigin = NSPoint(x: origin.x + entryDelta.x, y: origin.y + entryDelta.y)
        panel.setFrameOrigin(startOrigin)
        panel.alphaValue = 0

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }

        DispatchQueue.main.async { [weak self] in
            self?.nav.isPresented = true
        }
    }

    /// 供实机演示编排调用：丝滑淡出收起真实面板
    func hideForDemo() {
        nav.isPresented = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        }
    }

    private func observeSurfaceStyle() {
        store.$surfaceStyle
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newStyle in
                self?.applyNativeSurface(style: newStyle)
            }
            .store(in: &cancellables)

        // 液态蒙版风格与浓度变化时，仅原地更新 NSGlassEffectView 属性，零视图重建、零性能抖动
        Publishers.CombineLatest(store.$liquidGlassAppearance, store.$liquidGlassMaskOpacity)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] appearance, opacity in
                self?.updateLiquidGlassInPlace(appearance: appearance, maskOpacity: opacity)
            }
            .store(in: &cancellables)
    }

    /// 按苹果官方 Liquid Glass 分层规范挂载原生材质根容器（底层柔焦隔断 + 顶层 NSGlassEffectView 光学壳体）
    private func applyNativeSurface(style: PanelSurfaceStyle) {
        let bounds = NSRect(origin: .zero, size: panelSize)
        surfaceHost.install(
            on: panel,
            hostingView: hostingView,
            bounds: bounds,
            cornerRadius: cornerRadius,
            style: style,
            appearance: store.liquidGlassAppearance,
            maskOpacity: store.liquidGlassMaskOpacity
        )
    }

    /// 零重建原地热更新苹果官方 Liquid Glass 蒙版风格与浓度
    private func updateLiquidGlassInPlace(appearance: LiquidGlassAppearance, maskOpacity: Double) {
        guard store.surfaceStyle == .liquidGlass else { return }
        surfaceHost.updateLiquidGlass(appearance: appearance, maskOpacity: maskOpacity)
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
        store.onPanelShown(visibleItems: nav.cachedFilteredItems)

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
        store.onPanelHidden()

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
        if nav.suppressAutoHide || nav.isRecordingHotKey || nav.isRecordingQueueHotKey {
            return
        }
        hide(restoreFocus: false)
    }

    // MARK: - 键盘快捷键流

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            if self.nav.isRecordingHotKey || self.nav.isRecordingQueueHotKey {
                return self.handleHotKeyRecording(event)
            }
            return self.handleKeyDown(event)
        }
    }

    /// 录制自定义全局快捷键（要求至少含一个修饰键 + 主键；按 ESC 取消）
    private func handleHotKeyRecording(_ event: NSEvent) -> NSEvent? {
        // ESC 取消录制并恢复原快捷键
        if nav.isEditingAlias {
            return event
        }

        if event.keyCode == 53 {
            nav.isRecordingHotKey = false
            nav.isRecordingQueueHotKey = false
            HotKeyManager.shared.resumeAfterRecording()
            return nil
        }

        // 忽略单独按下的修饰键
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if modifierKeyCodes.contains(event.keyCode) {
            return nil
        }

        let carbonMods = HotKeyShortcut.carbonModifiers(from: event.modifierFlags)
        guard carbonMods != 0 else {
            store.showToast("请至少搭配一个修饰键（⌥ / ⌘ / ⌃ / ⇧）")
            return nil
        }

        let newShortcut = HotKeyShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods)
        if nav.isRecordingQueueHotKey {
            nav.isRecordingQueueHotKey = false
            store.queuePopShortcut = newShortcut
            HotKeyManager.shared.resumeAfterRecording()
            store.showToast("顺序出队快捷键已更新为 \(newShortcut.displayString)")
        } else {
            nav.isRecordingHotKey = false
            store.hotKeyShortcut = newShortcut
            HotKeyManager.shared.resumeAfterRecording()
            store.showToast("全局快捷键已更新为 \(newShortcut.displayString)")
        }
        return nil
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if nav.isEditingAlias {
            return event
        }

        if event.keyCode == 53 {
            if nav.showSettings {
                nav.showSettings = false
            } else if !store.selectedMergeIDs.isEmpty {
                withAnimation(.easeOut(duration: 0.15)) {
                    store.clearMergeSelection()
                }
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

        // ⌘E (keyCode 14)：一键切换极简纯净模式（基础功能版）
        if flags == .command, event.keyCode == 14 {
            store.toggleMinimalMode()
            return nil
        }

        if flags == .command, event.keyCode == 51 {
            rootView.deleteSelected()
            return nil
        }

        // ⌘K (keyCode 40)：加入 / 移出顺序粘贴队列
        if !store.minimalModeEnabled, flags == .command, event.keyCode == 40 {
            rootView.toggleQueueForSelected()
            return nil
        }

        // ⌘M (keyCode 46)：勾选 / 取消勾选加入合并粘贴篮
        if !store.minimalModeEnabled, flags == .command, event.keyCode == 46 {
            rootView.toggleMergeForSelected()
            return nil
        }

        // ⇥ Tab / ⇧⇥ Shift+Tab (keyCode 48)：队列非空且按纯 Tab 时优先 FIFO 出队；其余场景左/右切换类目
        if event.keyCode == 48 {
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            if !store.minimalModeEnabled, flags.isEmpty, rootView.dequeueAndPasteFromQueue() {
                return nil
            }
            if flags.isEmpty {
                rootView.stepFilterTab(delta: 1)
                return nil
            }
            if flags == .shift {
                rootView.stepFilterTab(delta: -1)
                return nil
            }
        }

        // ← / → 左右方向键：搜索框为空且处于图片格（或图片类目）时直接左右操控图片选中焦点
        if (event.keyCode == 123 || event.keyCode == 124), nav.searchText.isEmpty, rootView.canMoveHorizontallyInGrid {
            rootView.moveSelection(
                direction: event.keyCode == 123 ? .left : .right,
                extendMergeSelection: flags.contains(.shift)
            )
            return nil
        }

        if event.keyCode == 126 {
            rootView.moveSelection(direction: .up, extendMergeSelection: flags.contains(.shift))
            return nil
        }

        if event.keyCode == 125 {
            rootView.moveSelection(direction: .down, extendMergeSelection: flags.contains(.shift))
            return nil
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            if flags.contains(.command), rootView.mergePasteIfActive() {
                return nil
            }
            if flags.contains(.shift) {
                rootView.pasteSecondaryActionForSelected()
            } else {
                rootView.pasteSelected()
            }
            return nil
        }

        return event
    }
}
#else
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
    private let surfaceHost = LiquidGlassSurfaceHost()
    let nav = PanelNavigationModel()
    private let store = ClipboardStore.shared
    private var rootView: ClipboardPopoverView!
    private var demoRunner: DemoShowcaseRunner?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var hideWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private let panelSize = NSSize(width: 420, height: 560)
    private let cornerRadius: CGFloat = 26

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
        surfaceHost.onDragTargetedChanged = { [weak self] targeted in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                self.nav.isDragTargeted = targeted
            }
        }
        surfaceHost.onPerformDrop = { [weak self] draggingPasteboard in
            guard let self else { return false }
            let ok = self.store.importAndCopy(from: draggingPasteboard, sourceLabel: "拖拽复制")
            if ok {
                self.nav.selectedIndex = 0
                self.nav.preferredGridColumn = nil
                self.nav.scrollRequestEpoch &+= 1
            }
            return ok
        }
        applyNativeSurface(style: store.surfaceStyle)
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            let runner = DemoShowcaseRunner(panelController: self, store: store, nav: nav)
            self.demoRunner = runner
            runner.start()
        }
    }

    /// 供实机演示编排调用：在指定屏幕位置带丝滑动画弹出真实面板
    func showForDemo(origin: NSPoint, entryDelta: NSPoint) {
        nav.isPresented = false
        nav.resetOnOpen()
        store.onPanelShown(visibleItems: nav.cachedFilteredItems)
        nav.suppressAutoHide = true

        let startOrigin = NSPoint(x: origin.x + entryDelta.x, y: origin.y + entryDelta.y)
        panel.setFrameOrigin(startOrigin)
        panel.alphaValue = 0

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }

        DispatchQueue.main.async { [weak self] in
            self?.nav.isPresented = true
        }
    }

    /// 供实机演示编排调用：丝滑淡出收起真实面板
    func hideForDemo() {
        nav.isPresented = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        }
    }

    private func observeSurfaceStyle() {
        store.$surfaceStyle
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newStyle in
                self?.applyNativeSurface(style: newStyle)
            }
            .store(in: &cancellables)

        // 液态蒙版风格与浓度变化时，仅原地更新 NSGlassEffectView 属性，零视图重建、零性能抖动
        Publishers.CombineLatest(store.$liquidGlassAppearance, store.$liquidGlassMaskOpacity)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] appearance, opacity in
                self?.updateLiquidGlassInPlace(appearance: appearance, maskOpacity: opacity)
            }
            .store(in: &cancellables)
    }

    /// 按苹果官方 Liquid Glass 分层规范挂载原生材质根容器（底层柔焦隔断 + 顶层 NSGlassEffectView 光学壳体）
    private func applyNativeSurface(style: PanelSurfaceStyle) {
        let bounds = NSRect(origin: .zero, size: panelSize)
        surfaceHost.install(
            on: panel,
            hostingView: hostingView,
            bounds: bounds,
            cornerRadius: cornerRadius,
            style: style,
            appearance: store.liquidGlassAppearance,
            maskOpacity: store.liquidGlassMaskOpacity
        )
    }

    /// 零重建原地热更新苹果官方 Liquid Glass 蒙版风格与浓度
    private func updateLiquidGlassInPlace(appearance: LiquidGlassAppearance, maskOpacity: Double) {
        guard store.surfaceStyle == .liquidGlass else { return }
        surfaceHost.updateLiquidGlass(appearance: appearance, maskOpacity: maskOpacity)
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
        store.onPanelShown(visibleItems: nav.cachedFilteredItems)

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
        store.onPanelHidden()

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
        if nav.suppressAutoHide || nav.isRecordingHotKey {
            return
        }
        hide(restoreFocus: false)
    }

    // MARK: - 键盘快捷键流

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            if self.nav.isRecordingHotKey {
                return self.handleHotKeyRecording(event)
            }
            return self.handleKeyDown(event)
        }
    }

    /// 录制自定义全局快捷键（要求至少含一个修饰键 + 主键；按 ESC 取消）
    private func handleHotKeyRecording(_ event: NSEvent) -> NSEvent? {
        // ESC 取消录制并恢复原快捷键
        if event.keyCode == 53 {
            nav.isRecordingHotKey = false
            HotKeyManager.shared.resumeAfterRecording()
            return nil
        }

        // 忽略单独按下的修饰键
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if modifierKeyCodes.contains(event.keyCode) {
            return nil
        }

        let carbonMods = HotKeyShortcut.carbonModifiers(from: event.modifierFlags)
        guard carbonMods != 0 else {
            store.showToast("请至少搭配一个修饰键（⌥ / ⌘ / ⌃ / ⇧）")
            return nil
        }

        let newShortcut = HotKeyShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods)
        nav.isRecordingHotKey = false
        store.hotKeyShortcut = newShortcut
        store.showToast("全局快捷键已更新为 \(newShortcut.displayString)")
        return nil
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
            if nav.showQuickLook {
                withAnimation(.easeOut(duration: 0.15)) {
                    nav.showQuickLook = false
                }
            } else if nav.showSettings {
                nav.showSettings = false
            } else {
                hide(restoreFocus: true)
            }
            return nil
        }

        if nav.showSettings || nav.isCreatingTemplate {
            if event.keyCode == 53 && nav.isCreatingTemplate {
                nav.isCreatingTemplate = false
                return nil
            }
            return event
        }

        // ⌘Y (keyCode 16) 随时切换 QuickLook 对照速览；搜索框为空时按 Space (keyCode 49) 同样触发 QuickLook
        if !store.minimalModeEnabled && ((flags == .command && event.keyCode == 16) ||
           (flags.isEmpty && event.keyCode == 49 && nav.searchText.isEmpty)) {
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                nav.showQuickLook.toggle()
            }
            return nil
        }

        if flags == .command, let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1...9).contains(digit) {
            rootView.pasteItem(at: digit - 1)
            return nil
        }

        if !store.minimalModeEnabled, flags == .control, let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1...3).contains(digit) {
            rootView.pasteTransformAtIndexForSelected(digit - 1)
            return nil
        }

        // ⌘E (keyCode 14)：一键切换极简纯净模式（基础功能版）
        if flags == .command, event.keyCode == 14 {
            store.toggleMinimalMode()
            return nil
        }

        if flags == .command, event.keyCode == 51 {
            rootView.deleteSelected()
            return nil
        }

        // ⇥ Tab / ⇧⇥ Shift+Tab (keyCode 48)：快速左/右切换内容类目
        if event.keyCode == 48 {
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            if flags.isEmpty {
                rootView.stepFilterTab(delta: 1)
                return nil
            }
            if flags == .shift {
                rootView.stepFilterTab(delta: -1)
                return nil
            }
        }

        // QuickLook 开启时支持 ← / → 左右方向键无缝切换「原始文本」与「变换预览」
        if nav.showQuickLook && (event.keyCode == 123 || event.keyCode == 124) {
            rootView.stepQuickLookTab(delta: event.keyCode == 123 ? -1 : 1)
            return nil
        }

        // ← / → 左右方向键：搜索框为空且处于图片格（或图片类目）时直接左右操控图片选中焦点
        if !nav.showQuickLook, (event.keyCode == 123 || event.keyCode == 124), nav.searchText.isEmpty, rootView.canMoveHorizontallyInGrid {
            rootView.moveSelection(direction: event.keyCode == 123 ? .left : .right)
            return nil
        }

        if event.keyCode == 126 {
            rootView.moveSelection(direction: .up)
            return nil
        }

        if event.keyCode == 125 {
            rootView.moveSelection(direction: .down)
            return nil
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            if flags.contains(.shift) {
                rootView.pasteSmartTransformedSelected()
            } else if flags.contains(.option) {
                rootView.pasteSelected(forceRawSecret: true)
            } else {
                rootView.pasteSelected()
            }
            return nil
        }

        return event
    }
}
#endif
