import AppKit
import Carbon.HIToolbox
import SwiftUI
import Combine
import Quartz

/// iClip 合成键盘事件专属标记魔数（"ICLP"），确保面板悬停时合成 ⌘V / ⌘C / Tab 零阻断穿透至宿主输入框
let iClipSyntheticEventMagic: Int64 = 0x4943_4C50

/// 支持按需获取键盘焦点且唤醒时绝不抢夺宿主窗口 Key Window / 输入框焦点的原生非激活悬浮面板
final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var becomesKeyOnlyIfNeeded: Bool {
        get { true }
        set {}
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        SystemQuickLookController.shared.attachControl(to: panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        SystemQuickLookController.shared.detachControl(from: panel)
    }
}

/// 允许悬浮面板在非激活态首次鼠标点击直接触发内部卡片粘贴、胶囊转换与按钮操作，无需抢夺外部输入框焦点
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 唤醒零失焦与顺手粘贴焦点保持策略
enum PanelFocusPreservationPolicy {
    /// 判断在非 Key 悬浮态下敲击的按键是否应自动激活顶部搜索框开始盲打搜索
    static func shouldBeginSearchTyping(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        showSettings: Bool,
        showQuickLook: Bool
    ) -> Bool {
        guard !showSettings, !showQuickLook else { return false }
        let clean = flags.intersection(.deviceIndependentFlagsMask)
        if clean.contains(.command) || clean.contains(.control) || clean.contains(.option) {
            return false
        }
        let reservedCodes: Set<UInt16> = [36, 48, 49, 51, 53, 76, 123, 124, 125, 126]
        if reservedCodes.contains(keyCode) {
            return false
        }
        guard let chars = charactersIgnoringModifiers, !chars.isEmpty else { return false }
        for scalar in chars.unicodeScalars {
            if scalar.value < 0x20 || (0xF700...0xF8FF).contains(scalar.value) || scalar.value == 0x7F {
                return false
            }
        }
        return true
    }

    /// 若宿主应用已处于 Active 状态（零失焦唤醒常态），不重复调用 activate()，避免重置微信等应用的搜索弹层焦点
    static func shouldActivatePreviousApp(isPreviousAppActive: Bool) -> Bool {
        !isPreviousAppActive
    }

    @MainActor
    static func findEditableSearchTextField(in root: NSView?) -> NSTextField? {
        guard let root, !root.isHidden, root.alphaValue > 0.01 else { return nil }
        if let tf = root as? NSTextField, tf.isEditable, tf.isEnabled {
            return tf
        }
        for sub in root.subviews {
            if let found = findEditableSearchTextField(in: sub) {
                return found
            }
        }
        return nil
    }
}

private func nonActivatingPanelEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    cgEvent: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(cgEvent)
    }
    let tapController = Unmanaged<PanelNonActivatingTapController>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            tapController.reenableTapIfNeeded()
        }
        return Unmanaged.passUnretained(cgEvent)
    }
    if cgEvent.getIntegerValueField(.eventSourceUserData) == iClipSyntheticEventMagic {
        return Unmanaged.passUnretained(cgEvent)
    }
    let consumed = MainActor.assumeIsolated {
        tapController.dispatchInterceptedCGEvent(type: type, cgEvent: cgEvent)
    }
    return consumed ? nil : Unmanaged.passUnretained(cgEvent)
}

/// 仅在面板可见期间按需挂载的会话级键盘拦截与外部点击收起控制器（面板隐藏即彻底卸载，后台待机 0 开销）
@MainActor
final class PanelNonActivatingTapController {
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var outsideMouseMonitor: Any?
    private var onInterceptEvent: ((NSEvent) -> Bool)?

    func start(
        onInterceptEvent: @escaping (NSEvent) -> Bool,
        onOutsideMouseDown: @escaping (NSPoint) -> Void
    ) -> Bool {
        stop()
        self.onInterceptEvent = onInterceptEvent

        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            let mouseLoc = NSEvent.mouseLocation
            Task { @MainActor in
                onOutsideMouseDown(mouseLoc)
            }
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: nonActivatingPanelEventTapCallback,
            userInfo: refcon
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return false
        }
        self.tapPort = port
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        onInterceptEvent = nil
        if let monitor = outsideMouseMonitor {
            NSEvent.removeMonitor(monitor)
            outsideMouseMonitor = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let port = tapPort {
            CFMachPortInvalidate(port)
            tapPort = nil
        }
    }

    fileprivate func reenableTapIfNeeded() {
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    fileprivate func dispatchInterceptedCGEvent(type: CGEventType, cgEvent: CGEvent) -> Bool {
        guard (type == .keyDown || type == .flagsChanged),
              let handler = onInterceptEvent,
              let nsEvent = NSEvent(cgEvent: cgEvent) else {
            return false
        }
        return handler(nsEvent)
    }
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
    private let nonActivatingTap = PanelNonActivatingTapController()
    var statusItemScreenRectProvider: (() -> NSRect?)?
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
            panel.makeFirstResponder(nil)
            if panel.isKeyWindow {
                panel.resignKey()
            }
            if let app = previousApp,
               PanelFocusPreservationPolicy.shouldActivatePreviousApp(isPreviousAppActive: app.isActive) {
                app.activate()
            }
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
                let targetSharing: NSWindow.SharingType = shielded ? .none : .readOnly
                self.panel?.sharingType = targetSharing
                SystemQuickLookController.shared.syncSharingType(targetSharing)
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

        Publishers.Merge3(nav.$isEditingAlias, nav.$isQuickLookEditing, nav.$isCreatingTemplate)
            .receive(on: RunLoop.main)
            .sink { [weak self] needsKey in
                guard let self, needsKey, self.isVisible, !self.panel.isKeyWindow else { return }
                self.panel.makeKey()
            }
            .store(in: &cancellables)
    }

    private func lockDownPanelForSystemSleepOrLock() {
        removeKeyMonitor()
        DragFileExportHelper.wipeAllExports()
        ActionSparkController.shared.dismiss()
        CursorDropPodController.shared.dismiss()
        store.lockDownEphemeralBuffers()
        nav.searchText = ""
        nav.showQuickLook = false
        nav.isQuickLookEditing = false
        nav.quickLookDraftText = ""
        nav.selectedIndex = 0
        SystemQuickLookController.shared.dismiss()
        if panel?.isVisible == true {
            nav.isPresented = false
            panel?.makeFirstResponder(nil)
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

    /// 切换显隐状态（仅当真正按下全局快捷键时才触发新手引导试按推进，点击菜单栏图标不误触发）
    func toggle(anchorRect: NSRect? = nil, isFromGlobalHotKey: Bool = false) {
        if isVisible {
            if isFromGlobalHotKey && InteractivePlaygroundController.shared.consumeHotKeyTrialIfNeeded() {
                return
            }
            hide(restoreFocus: true)
        } else {
            show(anchorRect: anchorRect)
            if isFromGlobalHotKey {
                _ = InteractivePlaygroundController.shared.consumeHotKeyTrialIfNeeded()
            }
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

    /// 聚焦并全选顶部搜索框（⌘F），按需提升为非激活 Key Window
    private func focusAndSelectSearchField() {
        if !panel.isKeyWindow {
            panel.makeKey()
        }
        nav.focusTrigger = UUID()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let tv = self?.panel?.firstResponder as? NSTextView else { return }
            tv.selectAll(nil)
        }
    }

    private func beginSearchTypingFromNonKeyPanel(_ event: NSEvent) {
        panel.makeKey()
        if let tf = PanelFocusPreservationPolicy.findEditableSearchTextField(in: hostingView) {
            _ = panel.makeFirstResponder(tf)
            if let retargeted = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: event.characters ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) {
                panel.sendEvent(retargeted)
                return
            }
        }
        if let chars = event.characters, !chars.isEmpty {
            nav.searchText.append(chars)
        }
        nav.focusTrigger = UUID()
    }

    /// 弹出面板（零失焦非激活悬浮：不抢夺外部应用 Active / Key Window 与已 focus 输入框焦点）
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

        panel.makeFirstResponder(nil)
        panel.setFrameOrigin(startOrigin)
        panel.alphaValue = 0

        let tapReady = installKeyMonitor()
        if tapReady && !IsSecureEventInputEnabled() {
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
            nav.focusTrigger = UUID()
        }
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
    }

    /// 隐藏面板（粘贴时 0ms 同步移出窗口栈并保护宿主原输入框焦点；普通收起时柔和淡出）
    func hide(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        removeKeyMonitor()
        hideWorkItem?.cancel()

        nav.isPresented = false
        SystemQuickLookController.shared.dismiss()
        NotificationCenter.default.post(name: .iClipPanelDidHide, object: nil)
        store.onPanelHidden()
        panel.makeFirstResponder(nil)

        if restoreFocus {
            panel.orderOut(nil)
            panel.alphaValue = 1
            if let app = previousApp,
               PanelFocusPreservationPolicy.shouldActivatePreviousApp(isPreviousAppActive: app.isActive) {
                app.activate()
            }
            return
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
        if SystemQuickLookController.shared.isVisible {
            return
        }
        if store.alwaysOnTop || nav.suppressAutoHide || nav.isRecordingHotKey {
            return
        }
        hide(restoreFocus: false)
    }

    // MARK: - 键盘快捷键流

    @discardableResult
    private func installKeyMonitor() -> Bool {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            if self.nav.isRecordingHotKey {
                return self.handleHotKeyRecording(event)
            }
            guard event.type == .keyDown else { return event }
            return self.handleKeyDown(event)
        }
        return nonActivatingTap.start(
            onInterceptEvent: { [weak self] event in
                guard let self, self.isVisible else { return false }
                return self.handleNonKeyPanelInterceptedEvent(event)
            },
            onOutsideMouseDown: { [weak self] mouseLoc in
                guard let self, self.isVisible else { return }
                if self.store.alwaysOnTop || self.nav.suppressAutoHide || self.nav.isRecordingHotKey {
                    return
                }
                if let qlFrame = SystemQuickLookController.shared.visiblePanelScreenFrame,
                   qlFrame.insetBy(dx: -10, dy: -10).contains(mouseLoc) {
                    return
                }
                if let statusRect = self.statusItemScreenRectProvider?(),
                   statusRect.insetBy(dx: -4, dy: -4).contains(mouseLoc) {
                    return
                }
                let cardFrame = self.panel.frame.insetBy(dx: self.shadowBleed - 2, dy: self.shadowBleed - 2)
                if !cardFrame.contains(mouseLoc) {
                    self.hide(restoreFocus: false)
                }
            }
        )
    }

    private func handleNonKeyPanelInterceptedEvent(_ event: NSEvent) -> Bool {
        if panel.isKeyWindow {
            return false
        }
        if nav.isRecordingHotKey {
            _ = handleHotKeyRecording(event)
            return true
        }
        if event.type == .flagsChanged {
            InteractivePlaygroundController.shared.updateModifierFlags(event.modifierFlags)
            return false
        }
        guard event.type == .keyDown else { return false }
        if handleKeyDown(event) == nil {
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 51 && !flags.contains(.command) && !flags.contains(.option) && !flags.contains(.control) {
            if !nav.searchText.isEmpty {
                nav.searchText.removeLast()
            }
            return true
        }
        if PanelFocusPreservationPolicy.shouldBeginSearchTyping(
            keyCode: event.keyCode,
            flags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            showSettings: nav.showSettings,
            showQuickLook: nav.showQuickLook
        ) {
            beginSearchTypingFromNonKeyPanel(event)
            return true
        }
        return !flags.contains(.command) && !flags.contains(.control)
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
        nonActivatingTap.stop()
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
            if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 || (flags == .command && event.keyCode == 13) {
                InteractivePlaygroundController.shared.dismiss(in: store)
            }
            return nil
        }

        // 系统官方大屏 QLPreviewPanel 激活态：优先接管 Space/ESC/⌘Y 关闭、方向键切图与 ↵ 原位直贴
        if SystemQuickLookController.shared.isVisible {
            if event.keyCode == 53
                || (flags.isEmpty && event.keyCode == 49)
                || (flags == .command && (event.keyCode == 16 || event.keyCode == 13)) {
                SystemQuickLookController.shared.dismiss()
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
            if flags.isEmpty, [123, 124, 125, 126].contains(event.keyCode) {
                let dir: PanelNavigationDirection
                switch event.keyCode {
                case 126: dir = .up
                case 125: dir = .down
                case 123: dir = .left
                default:  dir = .right
                }
                rootView.moveSelection(direction: dir)
                let visible = nav.cachedFilteredItems
                if nav.selectedIndex >= 0, nav.selectedIndex < visible.count {
                    let nextItem = visible[nav.selectedIndex]
                    if SystemQuickLookController.supportsNativeLargePreview(nextItem) {
                        _ = SystemQuickLookController.shared.presentOrUpdate(for: nextItem, in: store, hostWindow: panel)
                    } else {
                        SystemQuickLookController.shared.dismiss()
                        if !store.minimalModeEnabled {
                            nav.quickLookPreferDiff = false
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                nav.showQuickLook = true
                            }
                        }
                    }
                }
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                SystemQuickLookController.shared.dismiss()
                if flags.contains(.option) {
                    rootView.pasteSelected(forceRawSecret: true)
                } else {
                    rootView.pasteSelected()
                }
                return nil
            }
            if flags.contains(.command) || flags.contains(.control) {
                return event
            }
            return nil
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
            if event.keyCode == 53 || (flags.isEmpty && event.keyCode == 49) || (flags == .command && (event.keyCode == 16 || event.keyCode == 13)) {
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

        // ⌘Y (keyCode 16) 或搜索框为空时按 Space (keyCode 49)：图片/文件唤起系统官方大屏 QLPreviewPanel，文本/链接唤起语义速览与编辑舱
        if (flags == .command && event.keyCode == 16) ||
           (flags.isEmpty && event.keyCode == 49 && nav.searchText.isEmpty) {
            if let fieldEditor = panel.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
                return event
            }
            if SystemQuickLookController.shared.isVisible {
                SystemQuickLookController.shared.dismiss()
                return nil
            }
            let visible = nav.cachedFilteredItems
            if nav.selectedIndex >= 0, nav.selectedIndex < visible.count {
                let target = visible[nav.selectedIndex]
                if SystemQuickLookController.supportsNativeLargePreview(target) {
                    SystemQuickLookController.shared.onStepSelection = { [weak self] dir in
                        guard let self else { return nil }
                        self.rootView.moveSelection(direction: dir)
                        let items = self.nav.cachedFilteredItems
                        guard self.nav.selectedIndex >= 0, self.nav.selectedIndex < items.count else { return nil }
                        return items[self.nav.selectedIndex]
                    }
                    SystemQuickLookController.shared.onCommitPasteFromPreview = { [weak self] in
                        self?.rootView.pasteSelected()
                    }
                    if SystemQuickLookController.shared.presentOrToggle(for: target, in: store, hostWindow: panel) {
                        return nil
                    }
                }
            }
            if !store.minimalModeEnabled {
                nav.quickLookPreferDiff = false
                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                    nav.showQuickLook = true
                }
                return nil
            }
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

        // ⌘W (keyCode 13)：收起 iClip 悬浮面板，严防零失焦模式下 ⌘W 穿透误关底层浏览器标签页
        if flags == .command, event.keyCode == 13 {
            hide(restoreFocus: true)
            return nil
        }

        // ⌘V (keyCode 9)：当面板处于零失焦非 Key 态（或搜索框为空且未在编辑文本）时，直接将当前选中的卡片粘贴至目标位置
        if flags == .command, event.keyCode == 9, (!panel.isKeyWindow || nav.searchText.isEmpty && !(panel.firstResponder is NSTextView)) {
            rootView.pasteSelected()
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
