#if ICLIP_EDITION_FLOW
import AppKit
import SwiftUI
import Combine

/// 支持获取键盘焦点且不抢占空间切换的悬浮面板
final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 允许悬浮面板在非激活态（如「始终在前」跨应用对照时）首次鼠标点击直接穿透触发内部链接跳转与操作按钮
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    private var recordingTapMachine = ModifierDoubleTapStateMachine(maxHoldDuration: 0.35, maxTapGap: 0.48)
    private var previousApp: NSRunningApplication?
    private var hideWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private let panelSize = NSSize(width: 420, height: 560)
    private let cornerRadius: CGFloat = 26
    /// 为 macOS 26+ NSGlassEffectView 原生 SDF 外发光/投影预留透明出血边距，防止被窗口矩形边界截成四角灰三角
    private let shadowBleed: CGFloat = 36
    private var windowSize: NSSize {
        NSSize(width: panelSize.width + shadowBleed * 2, height: panelSize.height + shadowBleed * 2)
    }

    var isVisible: Bool {
        (panel?.isVisible ?? false) && nav.isPresented
    }

    override init() {
        super.init()
        setupPanel()
        observeSurfaceStyle()
        observeExternalActiveApp()
        ActionSparkController.shared.isMainPanelVisibleProvider = { [weak self] in
            self?.isVisible ?? false
        }
        CursorDropPodController.shared.isMainPanelVisibleProvider = { [weak self] in
            self?.isVisible ?? false
        }
    }

    private func observeExternalActiveApp() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self,
                      let app = activated,
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else {
                    return
                }
                self.previousApp = app
                if self.store.activeTargetAppName != app.localizedName {
                    self.store.activeTargetAppName = app.localizedName
                }
            }
        }
    }

    private func handleDismissForPaste() {
        if store.alwaysOnTop {
            previousApp?.activate()
        } else {
            hide(restoreFocus: true)
        }
    }

    private func setupPanel() {
        let cardRect = NSRect(origin: .zero, size: panelSize)
        let windowRect = NSRect(origin: .zero, size: windowSize)

        let p = KeyableFloatingPanel(
            contentRect: windowRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = store.alwaysOnTop ? .statusBar : .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        // 配合透明出血根容器渲染苹果原生 WindowServer 连续圆角 360° 柔和阴影，零四角毛边
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.minSize = windowSize
        p.maxSize = windowSize
        p.sharingType = (store.screenSharePrivacyEnabled && !ProcessInfo.processInfo.arguments.contains("--demo")) ? .none : .readOnly
        p.delegate = self

        let view = ClipboardPopoverView(
            store: store,
            nav: nav,
            onDismiss: { [weak self] in
                self?.handleDismissForPaste()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        self.rootView = view

        let hosting = FirstMouseHostingView(rootView: view)
        // 锁死 NSHostingView 尺寸反推：彻底禁止任何内部子视图状态切换反向拉宽或撑高 NSPanel 外框
        hosting.sizingOptions = []
        hosting.frame = cardRect
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.cornerRadius = cornerRadius
        hosting.layer?.masksToBounds = true
        self.hostingView = hosting

        self.panel = p
        store.onAfterOpenExternalURL = { [weak self] in
            guard let self, !self.store.alwaysOnTop else { return }
            self.hide(restoreFocus: false)
        }
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
                TactileFeedbackEngine.shared.perform(.pasteCommit)
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

        let targetWindowOrigin = NSPoint(x: origin.x - shadowBleed, y: origin.y - shadowBleed)
        let startOrigin = NSPoint(x: targetWindowOrigin.x + entryDelta.x, y: targetWindowOrigin.y + entryDelta.y)
        panel.setFrameOrigin(startOrigin)
        panel.alphaValue = 0

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(targetWindowOrigin)
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

        store.$alwaysOnTop
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] pinned in
                self?.panel?.level = pinned ? .statusBar : .floating
            }
            .store(in: &cancellables)

        store.$screenSharePrivacyEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shielded in
                guard let self, !ProcessInfo.processInfo.arguments.contains("--demo") else { return }
                self.panel?.sharingType = shielded ? .none : .readOnly
            }
            .store(in: &cancellables)

        // 系统锁屏或合盖休眠隐私保护：立即关闭速览浮层、清空草稿并自动收起悬浮窗
        let wsCenter = NSWorkspace.shared.notificationCenter
        Publishers.Merge(
            wsCenter.publisher(for: NSWorkspace.willSleepNotification),
            wsCenter.publisher(for: NSWorkspace.screensDidSleepNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.lockDownPanelForSystemSleepOrLock()
        }
        .store(in: &cancellables)

        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lockDownPanelForSystemSleepOrLock()
            }
            .store(in: &cancellables)
    }

    private func lockDownPanelForSystemSleepOrLock() {
        nav.showQuickLook = false
        nav.isQuickLookEditing = false
        nav.quickLookDraftText = ""
        nav.selectedIndex = 0
        if panel?.isVisible == true {
            nav.isPresented = false
            panel?.orderOut(nil)
            store.onPanelHidden()
        }
    }

    /// 按苹果官方 Liquid Glass 分层规范挂载原生材质根容器（含透明阴影出血区 + 顶层 NSGlassEffectView 光学壳体）
    private func applyNativeSurface(style: PanelSurfaceStyle) {
        let bounds = NSRect(origin: .zero, size: panelSize)
        surfaceHost.install(
            on: panel,
            hostingView: hostingView,
            bounds: bounds,
            bleed: shadowBleed,
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

    /// 供全局 ⌃⌥C 快捷键在面板已打开时直接追加当前选中条目
    func appendSelectedCardToClipboard() {
        rootView.appendSelectedToClipboard()
    }

    /// 检查当前聚焦输入框/预览框是否存在用户手动拖选的局部文本（存在时放行系统原生 ⌘C 局部拷贝）
    private var editorHasSelectedText: Bool {
        guard let tv = panel?.firstResponder as? NSTextView else { return false }
        return tv.selectedRange().length > 0
    }

    /// 聚焦并全选顶部搜索框（⌘F），消除失焦状态下按 ⌘F 触发的系统报错音
    private func focusAndSelectSearchField() {
        nav.focusTrigger = UUID()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let tv = self?.panel?.firstResponder as? NSTextView else { return }
            tv.selectAll(nil)
        }
    }

    /// 弹出面板（鼠标旁直觉位置 + 原生窗口级轻柔滑入 + 内部卡片错峰浮现）
    func show(anchorRect: NSRect? = nil) {
        ActionSparkController.shared.dismissImmediately()
        CursorDropPodController.shared.dismissImmediately()
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
            if store.activeTargetAppName != front.localizedName {
                store.activeTargetAppName = front.localizedName
            }
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

            return (NSPoint(x: cardLeft - shadowBleed, y: cardBottom - shadowBleed), NSPoint(x: 0, y: 10))
        }

        // 「始终在前」空间记忆：若用户已固定窗口并手动摆放过工位，快捷键重开时回到专属桌面工位
        if store.alwaysOnTop, let pinned = store.savedPinnedPanelOrigin {
            let targetCenter = NSPoint(x: pinned.x + cardWidth / 2, y: pinned.y + cardHeight / 2)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(targetCenter) }) ?? NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            let clampedX = max(visible.minX + 8, min(pinned.x, visible.maxX - cardWidth - 8))
            let clampedY = max(visible.minY + 8, min(pinned.y, visible.maxY - cardHeight - 8))
            return (NSPoint(x: clampedX - shadowBleed, y: clampedY - shadowBleed), NSPoint(x: 0, y: 6))
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
            NSPoint(x: cardLeft - shadowBleed, y: cardBottom - shadowBleed),
            NSPoint(x: placeOnRight ? -8 : 8, y: 6)
        )
    }

    // MARK: - 失焦自动隐藏与钉住工位记忆

    func windowDidMove(_ notification: Notification) {
        guard store.alwaysOnTop, isVisible, let frame = panel?.frame else { return }
        store.savePinnedPanelOrigin(NSPoint(x: frame.origin.x + shadowBleed, y: frame.origin.y + shadowBleed))
    }

    func windowDidResignKey(_ notification: Notification) {
        if store.alwaysOnTop || nav.suppressAutoHide || nav.isRecordingHotKey || nav.isRecordingQueueHotKey {
            return
        }
        hide(restoreFocus: false)
    }

    // MARK: - 键盘快捷键流

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            if self.nav.isRecordingHotKey || self.nav.isRecordingQueueHotKey {
                return self.handleHotKeyRecording(event)
            }
            guard event.type == .keyDown else { return event }
            return self.handleKeyDown(event)
        }
    }

    /// 录制自定义全局快捷键（支持「修饰键+主键」组合键，或连按两次 ⌘/⌥/⌃/⇧/Fn 单键双击；按 ESC 取消）
    private func handleHotKeyRecording(_ event: NSEvent) -> NSEvent? {
        if nav.isEditingAlias {
            return event
        }

        let role: HotKeySlotRole = nav.isRecordingQueueHotKey ? .queuePop : .mainToggle

        if event.type == .flagsChanged {
            let outcome = recordingTapMachine.handleFlagsChanged(
                keyCode: event.keyCode,
                flags: event.modifierFlags,
                uptime: ProcessInfo.processInfo.systemUptime
            )
            switch outcome {
            case .none:
                return nil
            case .firstTapCompleted(let kind):
                nav.hotKeyConflictWarning = nil
                nav.hotKeyRecordingHint = "再按一次 \(kind.symbol) 设为「双击 \(kind.symbol)」，或按下组合键"
                return nil
            case .doubleTapTriggered(let kind):
                nav.hotKeyRecordingHint = nil
                return commitRecordedShortcut(.doubleTap(kind), role: role)
            }
        }

        recordingTapMachine.markInterferingEvent()
        nav.hotKeyRecordingHint = nil

        if event.keyCode == 53 {
            recordingTapMachine.reset()
            nav.isRecordingHotKey = false
            nav.isRecordingQueueHotKey = false
            nav.hotKeyConflictWarning = nil
            HotKeyManager.shared.resumeAfterRecording()
            return nil
        }

        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if modifierKeyCodes.contains(event.keyCode) {
            return nil
        }

        let carbonMods = HotKeyShortcut.carbonModifiers(from: event.modifierFlags)
        let newShortcut = HotKeyShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods)
        return commitRecordedShortcut(newShortcut, role: role)
    }

    private func commitRecordedShortcut(_ newShortcut: HotKeyShortcut, role: HotKeySlotRole) -> NSEvent? {
        if let conflictReason = HotKeyManager.shared.validateAndProbeShortcut(
            newShortcut,
            for: role,
            copyAppendEnabled: AdaptiveIntelligenceEngine.shared.copyAppendEnabled && !store.minimalModeEnabled
        ) {
            NSSound.beep()
            nav.hotKeyConflictWarning = conflictReason
            store.showToast(conflictReason, duration: 3.0)
            return nil
        }

        recordingTapMachine.reset()
        nav.hotKeyConflictWarning = nil
        nav.hotKeyRecordingHint = nil
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
            if event.keyCode == 53 {
                rootView.cancelAliasEdit()
                return nil
            }
            return event
        }

        if InteractivePlaygroundController.shared.isActive, !nav.showSettings {
            if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 {
                InteractivePlaygroundController.shared.dismiss(in: store)
                return nil
            }
        }

        // QuickLook 原位微调编辑态：放行全部原生文本编辑键，支持 ESC 退出、⌘↵ 直贴、⌘S 存回原条目
        if nav.showQuickLook && nav.isQuickLookEditing {
            if event.keyCode == 53 {
                nav.isQuickLookEditing = false
                return nil
            }
            if flags.contains(.command), (event.keyCode == 36 || event.keyCode == 76) {
                rootView.commitQuickLookDraftPaste()
                return nil
            }
            if flags == .command, event.keyCode == 1 {
                rootView.saveQuickLookDraftToItem()
                return nil
            }
            return event
        }

        // QuickLook 速览态：支持 Space/ESC/⌘Y 关闭、⌘E 原位微调、←/→ 切页、↑/↓ 连续扫视、↵ 键入
        if nav.showQuickLook {
            if event.keyCode == 53 || (flags.isEmpty && event.keyCode == 49) || (flags == .command && event.keyCode == 16) {
                withAnimation(.easeOut(duration: 0.15)) {
                    nav.showQuickLook = false
                }
                return nil
            }
            if flags == .command, event.keyCode == 14, rootView.enterQuickLookEditMode() {
                return nil
            }
            if flags == .command, event.keyCode == 8, !editorHasSelectedText {
                _ = rootView.copySelectedOnly(plainPathOrText: false)
                return nil
            }
            if flags == .command, event.keyCode == 31 {
                _ = rootView.openSelectedExternally()
                return nil
            }
            if flags == .option, event.keyCode == 49 {
                rootView.selectQuickLookDiffTabIfAvailable()
                return nil
            }
            if event.keyCode == 123 || event.keyCode == 124 {
                rootView.stepQuickLookTab(delta: event.keyCode == 123 ? -1 : 1)
                return nil
            }
            if event.keyCode == 126 || event.keyCode == 125 {
                rootView.moveSelection(direction: event.keyCode == 126 ? .up : .down)
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                rootView.pasteSelected()
                return nil
            }
        }

        if event.keyCode == 53 {
            if nav.showSettings {
                nav.showSettings = false
            } else if !store.selectedMergeIDs.isEmpty {
                withAnimation(.easeOut(duration: 0.15)) {
                    store.clearMergeSelection()
                }
            } else if !nav.searchText.isEmpty {
                nav.searchText = ""
                nav.focusTrigger = UUID()
            } else {
                hide(restoreFocus: true)
            }
            return nil
        }

        if nav.showSettings {
            return event
        }

        // ⌘F (keyCode 3)：随时聚焦并全选顶部搜索框
        if flags == .command, event.keyCode == 3 {
            focusAndSelectSearchField()
            return nil
        }

        // ⌥Space (keyCode 49)：一键打开速览并直定位至「对比最新剪贴 #1」行级差异标签页
        if !store.minimalModeEnabled, flags == .option, event.keyCode == 49 {
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            nav.quickLookPreferDiff = true
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                nav.showQuickLook = true
            }
            return nil
        }

        // ⌘Y (keyCode 16) 或搜索框为空时按 Space (keyCode 49)：呼出 Finder 级全模态速览与原位微调舱
        if !store.minimalModeEnabled && ((flags == .command && event.keyCode == 16) ||
           (flags.isEmpty && event.keyCode == 49 && nav.searchText.isEmpty)) {
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            nav.quickLookPreferDiff = false
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                nav.showQuickLook = true
            }
            return nil
        }

        // ⌘R (keyCode 15)：对当前选中条目设置/修改记忆备注标题
        if !store.minimalModeEnabled, flags == .command, event.keyCode == 15 {
            rootView.beginAliasEditForSelected()
            return nil
        }

        // ⇧⌘C (keyCode 8)：将当前选中条目换行追加至系统剪贴板末尾（免切窗连环续接）
        if !store.minimalModeEnabled, flags == [.command, .shift], event.keyCode == 8 {
            rootView.appendSelectedToClipboard()
            return nil
        }

        // ⌘C (keyCode 8)：搜索框无选中文本时，仅复制当前选中卡片到系统剪贴板（不自动发送 ⌘V 粘贴）
        if flags == .command, event.keyCode == 8, !editorHasSelectedText {
            if rootView.copySelectedOnly(plainPathOrText: false), !store.alwaysOnTop {
                hide(restoreFocus: true)
            }
            return nil
        }

        // ⌥⌘C (keyCode 8)：对齐 Finder 拷贝路径肌肉记忆，将文件/原图复制为本地纯文本路径
        if flags == [.command, .option], event.keyCode == 8 {
            _ = rootView.copySelectedOnly(plainPathOrText: true)
            return nil
        }

        // ⌘O (keyCode 31)：链接直接在浏览器打开，文件与本地原图直接在访达中高亮定位
        if flags == .command, event.keyCode == 31 {
            _ = rootView.openSelectedExternally()
            return nil
        }

        if let digit = ClipFilterTab.digitFromKeyCode(event.keyCode) {
            if flags == .command {
                rootView.pasteItem(at: digit - 1)
                return nil
            }
            if flags == [.command, .option] {
                rootView.pasteItem(at: digit - 1, plainTextOnly: true)
                return nil
            }
            if flags == [.command, .shift] {
                rootView.pasteItem(at: digit - 1, smartTransform: true)
                return nil
            }
        }

        // ⌥1 ~ ⌥7（极简模式下 ⌥1 ~ ⌥6）：全键盘一键直达顶部分类
        if flags == .option, let targetTab = ClipFilterTab.fromOptionKeyCode(event.keyCode, minimalMode: store.minimalModeEnabled) {
            rootView.selectFilterTab(targetTab)
            return nil
        }

        // ⌘E (keyCode 14)：一键切换极简纯净模式（基础功能版）
        if flags == .command, event.keyCode == 14 {
            store.toggleMinimalMode()
            return nil
        }

        // ⌘P (keyCode 35)：一键切换窗口「始终在前（Always on Top）」
        if flags == .command, event.keyCode == 35 {
            store.toggleAlwaysOnTop()
            return nil
        }

        // ⌘T (keyCode 17)：一键加入待办 / 标记完成 / 恢复未完成
        if !store.minimalModeEnabled, flags == .command, event.keyCode == 17 {
            rootView.toggleTodoForSelected()
            return nil
        }

        // ⌘B (keyCode 11)：一键开启 / 取消「粘贴即焚」（粘贴 5 秒后连同系统剪贴板无痕自毁）
        if flags == .command, event.keyCode == 11 {
            rootView.toggleBurnAfterPasteForSelected()
            return nil
        }

        // ⌘S (keyCode 1) / ⌘D (keyCode 2)：全键盘一键收藏 / 取消收藏当前选中条目
        if flags == .command, (event.keyCode == 1 || event.keyCode == 2) {
            rootView.togglePinForSelected()
            return nil
        }

        // ⌘Z (keyCode 6)：若搜索框为空且存在 8 秒保护窗口内的删除/清空快照，一键原位恢复
        if flags == .command, event.keyCode == 6, nav.searchText.isEmpty, store.canUndoLastDeletion {
            _ = store.undoLastDeletion()
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
            if flags.contains(.command),
               rootView.commitEmptySearchCaptureIfApplicable(forcePin: flags.contains(.shift)) {
                return nil
            }
            if flags == .command, rootView.pasteAndCompleteTodoIfApplicable() {
                return nil
            }
            if flags.contains(.shift) {
                rootView.pasteSecondaryActionForSelected()
            } else if flags.contains(.option) {
                rootView.pasteSelected(plainTextOnly: true)
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

/// 允许悬浮面板在非激活态（如「始终在前」跨应用对照时）首次鼠标点击直接穿透触发内部链接跳转与操作按钮
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    private var recordingTapMachine = ModifierDoubleTapStateMachine(maxHoldDuration: 0.35, maxTapGap: 0.48)
    private var previousApp: NSRunningApplication?
    private var hideWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private let panelSize = NSSize(width: 420, height: 560)
    private let cornerRadius: CGFloat = 26
    /// 为 macOS 26+ NSGlassEffectView 原生 SDF 外发光/投影预留透明出血边距，防止被窗口矩形边界截成四角灰三角
    private let shadowBleed: CGFloat = 36
    private var windowSize: NSSize {
        NSSize(width: panelSize.width + shadowBleed * 2, height: panelSize.height + shadowBleed * 2)
    }

    var isVisible: Bool {
        (panel?.isVisible ?? false) && nav.isPresented
    }

    override init() {
        super.init()
        setupPanel()
        observeSurfaceStyle()
        observeExternalActiveApp()
        ActionSparkController.shared.isMainPanelVisibleProvider = { [weak self] in
            self?.isVisible ?? false
        }
        CursorDropPodController.shared.isMainPanelVisibleProvider = { [weak self] in
            self?.isVisible ?? false
        }
    }

    private func observeExternalActiveApp() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self,
                      let app = activated,
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else {
                    return
                }
                self.previousApp = app
                if self.store.activeTargetAppName != app.localizedName {
                    self.store.activeTargetAppName = app.localizedName
                }
            }
        }
    }

    private func handleDismissForPaste() {
        if store.alwaysOnTop {
            previousApp?.activate()
        } else {
            hide(restoreFocus: true)
        }
    }

    private func setupPanel() {
        let cardRect = NSRect(origin: .zero, size: panelSize)
        let windowRect = NSRect(origin: .zero, size: windowSize)

        let p = KeyableFloatingPanel(
            contentRect: windowRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = store.alwaysOnTop ? .statusBar : .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        // 配合透明出血根容器渲染苹果原生 WindowServer 连续圆角 360° 柔和阴影，零四角毛边
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.minSize = windowSize
        p.maxSize = windowSize
        p.sharingType = (store.screenSharePrivacyEnabled && !ProcessInfo.processInfo.arguments.contains("--demo")) ? .none : .readOnly
        p.delegate = self

        let view = ClipboardPopoverView(
            store: store,
            nav: nav,
            onDismiss: { [weak self] in
                self?.handleDismissForPaste()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        self.rootView = view

        let hosting = FirstMouseHostingView(rootView: view)
        // 锁死 NSHostingView 尺寸反推：彻底禁止任何内部子视图状态切换反向拉宽或撑高 NSPanel 外框
        hosting.sizingOptions = []
        hosting.frame = cardRect
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.cornerRadius = cornerRadius
        hosting.layer?.masksToBounds = true
        self.hostingView = hosting

        self.panel = p
        store.onAfterOpenExternalURL = { [weak self] in
            guard let self, !self.store.alwaysOnTop else { return }
            self.hide(restoreFocus: false)
        }
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
                TactileFeedbackEngine.shared.perform(.pasteCommit)
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

        let targetWindowOrigin = NSPoint(x: origin.x - shadowBleed, y: origin.y - shadowBleed)
        let startOrigin = NSPoint(x: targetWindowOrigin.x + entryDelta.x, y: targetWindowOrigin.y + entryDelta.y)
        panel.setFrameOrigin(startOrigin)
        panel.alphaValue = 0

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(targetWindowOrigin)
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

        store.$alwaysOnTop
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] pinned in
                self?.panel?.level = pinned ? .statusBar : .floating
            }
            .store(in: &cancellables)

        store.$screenSharePrivacyEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shielded in
                guard let self, !ProcessInfo.processInfo.arguments.contains("--demo") else { return }
                self.panel?.sharingType = shielded ? .none : .readOnly
            }
            .store(in: &cancellables)

        // 系统锁屏或合盖休眠隐私保护：立即关闭速览浮层、清空草稿并自动收起悬浮窗
        let wsCenter = NSWorkspace.shared.notificationCenter
        Publishers.Merge(
            wsCenter.publisher(for: NSWorkspace.willSleepNotification),
            wsCenter.publisher(for: NSWorkspace.screensDidSleepNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.lockDownPanelForSystemSleepOrLock()
        }
        .store(in: &cancellables)

        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lockDownPanelForSystemSleepOrLock()
            }
            .store(in: &cancellables)
    }

    private func lockDownPanelForSystemSleepOrLock() {
        nav.showQuickLook = false
        nav.isQuickLookEditing = false
        nav.quickLookDraftText = ""
        nav.selectedIndex = 0
        if panel?.isVisible == true {
            nav.isPresented = false
            panel?.orderOut(nil)
            store.onPanelHidden()
        }
    }

    /// 按苹果官方 Liquid Glass 分层规范挂载原生材质根容器（含透明阴影出血区 + 顶层 NSGlassEffectView 光学壳体）
    private func applyNativeSurface(style: PanelSurfaceStyle) {
        let bounds = NSRect(origin: .zero, size: panelSize)
        surfaceHost.install(
            on: panel,
            hostingView: hostingView,
            bounds: bounds,
            bleed: shadowBleed,
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

    /// 供全局 ⌃⌥C 快捷键在面板已打开时直接追加当前选中条目
    func appendSelectedCardToClipboard() {
        rootView.appendSelectedToClipboard()
    }

    /// 检查当前聚焦输入框/预览框是否存在用户手动拖选的局部文本（存在时放行系统原生 ⌘C 局部拷贝）
    private var editorHasSelectedText: Bool {
        guard let tv = panel?.firstResponder as? NSTextView else { return false }
        return tv.selectedRange().length > 0
    }

    /// 聚焦并全选顶部搜索框（⌘F），消除失焦状态下按 ⌘F 触发的系统报错音
    private func focusAndSelectSearchField() {
        nav.focusTrigger = UUID()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let tv = self?.panel?.firstResponder as? NSTextView else { return }
            tv.selectAll(nil)
        }
    }

    /// 弹出面板（鼠标旁直觉位置 + 原生窗口级轻柔滑入 + 内部卡片错峰浮现）
    func show(anchorRect: NSRect? = nil) {
        ActionSparkController.shared.dismissImmediately()
        CursorDropPodController.shared.dismissImmediately()
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
            if store.activeTargetAppName != front.localizedName {
                store.activeTargetAppName = front.localizedName
            }
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

            return (NSPoint(x: cardLeft - shadowBleed, y: cardBottom - shadowBleed), NSPoint(x: 0, y: 10))
        }

        // 「始终在前」空间记忆：若用户已固定窗口并手动摆放过工位，快捷键重开时回到专属桌面工位
        if store.alwaysOnTop, let pinned = store.savedPinnedPanelOrigin {
            let targetCenter = NSPoint(x: pinned.x + cardWidth / 2, y: pinned.y + cardHeight / 2)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(targetCenter) }) ?? NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            let clampedX = max(visible.minX + 8, min(pinned.x, visible.maxX - cardWidth - 8))
            let clampedY = max(visible.minY + 8, min(pinned.y, visible.maxY - cardHeight - 8))
            return (NSPoint(x: clampedX - shadowBleed, y: clampedY - shadowBleed), NSPoint(x: 0, y: 6))
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
            NSPoint(x: cardLeft - shadowBleed, y: cardBottom - shadowBleed),
            NSPoint(x: placeOnRight ? -8 : 8, y: 6)
        )
    }

    // MARK: - 失焦自动隐藏与钉住工位记忆

    func windowDidMove(_ notification: Notification) {
        guard store.alwaysOnTop, isVisible, let frame = panel?.frame else { return }
        store.savePinnedPanelOrigin(NSPoint(x: frame.origin.x + shadowBleed, y: frame.origin.y + shadowBleed))
    }

    func windowDidResignKey(_ notification: Notification) {
        if store.alwaysOnTop || nav.suppressAutoHide || nav.isRecordingHotKey {
            return
        }
        hide(restoreFocus: false)
    }

    // MARK: - 键盘快捷键流

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            if self.nav.isRecordingHotKey {
                return self.handleHotKeyRecording(event)
            }
            guard event.type == .keyDown else { return event }
            return self.handleKeyDown(event)
        }
    }

    /// 录制自定义全局快捷键（支持「修饰键+主键」组合键，或连按两次 ⌘/⌥/⌃/⇧/Fn 单键双击；按 ESC 取消）
    private func handleHotKeyRecording(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            let outcome = recordingTapMachine.handleFlagsChanged(
                keyCode: event.keyCode,
                flags: event.modifierFlags,
                uptime: ProcessInfo.processInfo.systemUptime
            )
            switch outcome {
            case .none:
                return nil
            case .firstTapCompleted(let kind):
                nav.hotKeyConflictWarning = nil
                nav.hotKeyRecordingHint = "再按一次 \(kind.symbol) 设为「双击 \(kind.symbol)」，或按下组合键"
                return nil
            case .doubleTapTriggered(let kind):
                nav.hotKeyRecordingHint = nil
                return commitRecordedShortcut(.doubleTap(kind))
            }
        }

        recordingTapMachine.markInterferingEvent()
        nav.hotKeyRecordingHint = nil

        if event.keyCode == 53 {
            recordingTapMachine.reset()
            nav.isRecordingHotKey = false
            nav.hotKeyConflictWarning = nil
            HotKeyManager.shared.resumeAfterRecording()
            return nil
        }

        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if modifierKeyCodes.contains(event.keyCode) {
            return nil
        }

        let carbonMods = HotKeyShortcut.carbonModifiers(from: event.modifierFlags)
        let newShortcut = HotKeyShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods)
        return commitRecordedShortcut(newShortcut)
    }

    private func commitRecordedShortcut(_ newShortcut: HotKeyShortcut) -> NSEvent? {
        if let conflictReason = HotKeyManager.shared.validateAndProbeShortcut(
            newShortcut,
            for: .mainToggle,
            copyAppendEnabled: AdaptiveIntelligenceEngine.shared.copyAppendEnabled && !store.minimalModeEnabled
        ) {
            NSSound.beep()
            nav.hotKeyConflictWarning = conflictReason
            store.showToast(conflictReason, duration: 3.0)
            return nil
        }

        recordingTapMachine.reset()
        nav.hotKeyConflictWarning = nil
        nav.hotKeyRecordingHint = nil
        nav.isRecordingHotKey = false
        store.hotKeyShortcut = newShortcut
        HotKeyManager.shared.resumeAfterRecording()
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

        if nav.isEditingAlias {
            if event.keyCode == 53 {
                rootView.cancelAliasEdit()
                return nil
            }
            return event
        }

        if InteractivePlaygroundController.shared.isActive, !nav.showSettings {
            if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 {
                InteractivePlaygroundController.shared.dismiss(in: store)
                return nil
            }
        }

        // QuickLook 原位微调编辑态：放行全部原生文本编辑键，支持 ESC 退出、⌘↵ 直贴、⌘S 存回原条目
        if nav.showQuickLook && nav.isQuickLookEditing {
            if event.keyCode == 53 {
                nav.isQuickLookEditing = false
                return nil
            }
            if flags.contains(.command), (event.keyCode == 36 || event.keyCode == 76) {
                rootView.commitQuickLookDraftPaste()
                return nil
            }
            if flags == .command, event.keyCode == 1 {
                rootView.saveQuickLookDraftToItem()
                return nil
            }
            return event
        }

        // QuickLook 速览态：支持 Space/ESC/⌘Y 关闭、⌘E 原位微调、←/→ 切页、↑/↓ 连续扫视、↵ 键入
        if nav.showQuickLook {
            if event.keyCode == 53 || (flags.isEmpty && event.keyCode == 49) || (flags == .command && event.keyCode == 16) {
                withAnimation(.easeOut(duration: 0.15)) {
                    nav.showQuickLook = false
                }
                return nil
            }
            if flags == .command, event.keyCode == 14, rootView.enterQuickLookEditMode() {
                return nil
            }
            if flags == .command, event.keyCode == 8, !editorHasSelectedText {
                _ = rootView.copySelectedOnly(plainPathOrText: false)
                return nil
            }
            if flags == .command, event.keyCode == 31 {
                _ = rootView.openSelectedExternally()
                return nil
            }
            if flags == .option, event.keyCode == 49 {
                rootView.selectQuickLookDiffTabIfAvailable()
                return nil
            }
            if event.keyCode == 123 || event.keyCode == 124 {
                rootView.stepQuickLookTab(delta: event.keyCode == 123 ? -1 : 1)
                return nil
            }
            if event.keyCode == 126 || event.keyCode == 125 {
                rootView.moveSelection(direction: event.keyCode == 126 ? .up : .down)
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                rootView.pasteSelected()
                return nil
            }
        }

        if event.keyCode == 53 {
            if nav.showSettings {
                nav.showSettings = false
            } else if nav.isCreatingTemplate {
                nav.isCreatingTemplate = false
            } else if !nav.searchText.isEmpty {
                nav.searchText = ""
                nav.focusTrigger = UUID()
            } else {
                hide(restoreFocus: true)
            }
            return nil
        }

        if nav.showSettings || nav.isCreatingTemplate {
            return event
        }

        // ⌘F (keyCode 3)：随时聚焦并全选顶部搜索框
        if flags == .command, event.keyCode == 3 {
            focusAndSelectSearchField()
            return nil
        }

        // ⌥Space (keyCode 49)：一键打开速览并直定位至「对比最新剪贴 #1」行级差异标签页
        if !store.minimalModeEnabled, flags == .option, event.keyCode == 49 {
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            nav.quickLookPreferDiff = true
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                nav.showQuickLook = true
            }
            return nil
        }

        // ⌘Y (keyCode 16) 随时切换 QuickLook 对照速览；搜索框为空时按 Space (keyCode 49) 同样触发 QuickLook
        if !store.minimalModeEnabled && ((flags == .command && event.keyCode == 16) ||
           (flags.isEmpty && event.keyCode == 49 && nav.searchText.isEmpty)) {
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            nav.quickLookPreferDiff = false
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                nav.showQuickLook = true
            }
            return nil
        }

        // ⌘R (keyCode 15)：对当前选中条目设置/修改记忆备注标题
        if !store.minimalModeEnabled, flags == .command, event.keyCode == 15 {
            rootView.beginAliasEditForSelected()
            return nil
        }

        // ⇧⌘C (keyCode 8)：将当前选中条目换行追加至系统剪贴板末尾（免切窗连环续接）
        if !store.minimalModeEnabled, flags == [.command, .shift], event.keyCode == 8 {
            rootView.appendSelectedToClipboard()
            return nil
        }

        // ⌘C (keyCode 8)：搜索框无选中文本时，仅复制当前选中卡片到系统剪贴板（不自动发送 ⌘V 粘贴）
        if flags == .command, event.keyCode == 8, !editorHasSelectedText {
            if rootView.copySelectedOnly(plainPathOrText: false), !store.alwaysOnTop {
                hide(restoreFocus: true)
            }
            return nil
        }

        // ⌥⌘C (keyCode 8)：对齐 Finder 拷贝路径肌肉记忆，将文件/原图复制为本地纯文本路径
        if flags == [.command, .option], event.keyCode == 8 {
            _ = rootView.copySelectedOnly(plainPathOrText: true)
            return nil
        }

        // ⌘O (keyCode 31)：链接直接在浏览器打开，文件与本地原图直接在访达中高亮定位
        if flags == .command, event.keyCode == 31 {
            _ = rootView.openSelectedExternally()
            return nil
        }

        if let digit = ClipFilterTab.digitFromKeyCode(event.keyCode) {
            if flags == .command {
                rootView.pasteItem(at: digit - 1)
                return nil
            }
            if flags == [.command, .option] {
                rootView.pasteItem(at: digit - 1, plainTextOnly: true)
                return nil
            }
            if flags == [.command, .shift] {
                rootView.pasteItem(at: digit - 1, smartTransform: true)
                return nil
            }
        }

        // ⌥1 ~ ⌥7（极简模式下 ⌥1 ~ ⌥6）：全键盘一键直达顶部分类
        if flags == .option, let targetTab = ClipFilterTab.fromOptionKeyCode(event.keyCode, minimalMode: store.minimalModeEnabled) {
            rootView.selectFilterTab(targetTab)
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

        // ⌘P (keyCode 35)：一键切换窗口「始终在前（Always on Top）」
        if flags == .command, event.keyCode == 35 {
            store.toggleAlwaysOnTop()
            return nil
        }

        // ⌘T (keyCode 17)：一键加入待办 / 标记完成 / 恢复未完成
        if !store.minimalModeEnabled, flags == .command, event.keyCode == 17 {
            rootView.toggleTodoForSelected()
            return nil
        }

        // ⌘B (keyCode 11)：一键开启 / 取消「粘贴即焚」（粘贴 5 秒后连同系统剪贴板无痕自毁）
        if flags == .command, event.keyCode == 11 {
            rootView.toggleBurnAfterPasteForSelected()
            return nil
        }

        // ⌘S (keyCode 1) / ⌘D (keyCode 2)：全键盘一键收藏 / 取消收藏当前选中条目
        if flags == .command, (event.keyCode == 1 || event.keyCode == 2) {
            rootView.togglePinForSelected()
            return nil
        }

        // ⌘Z (keyCode 6)：若搜索框为空且存在 8 秒保护窗口内的删除/清空快照，一键原位恢复
        if flags == .command, event.keyCode == 6, nav.searchText.isEmpty, store.canUndoLastDeletion {
            _ = store.undoLastDeletion()
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
            if flags.contains(.command),
               rootView.commitEmptySearchCaptureIfApplicable(forcePin: flags.contains(.shift)) {
                return nil
            }
            if flags == .command, rootView.pasteAndCompleteTodoIfApplicable() {
                return nil
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
