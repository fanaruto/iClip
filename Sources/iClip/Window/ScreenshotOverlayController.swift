import AppKit
import Carbon
import Combine
import CoreGraphics
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 1. 全屏原生截图舞台控制器（ScreenCaptureKit 零闪烁定格 + 同源 Liquid Glass 操作岛）

@MainActor
final class ScreenshotOverlayController: NSObject {
    static let shared = ScreenshotOverlayController()

    private struct CapturedDisplaySession {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        let snapshotCGImage: CGImage
        let snappableWindows: [SnappableWindowRect]
        let panel: KeyableScreenshotPanel
        let canvasView: ScreenshotCanvasView
    }

    @MainActor
    fileprivate final class ToolbarViewModel: ObservableObject {
        @Published var activeTool: ScreenshotAnnotationTool? = nil
        @Published var selectedColorHex: String = ScreenshotOverlayController.loadPreferredColorHex()
        @Published var strokeWidth: ScreenshotStrokeWidth = ScreenshotOverlayController.loadPreferredStrokeWidth()
        @Published var canUndo: Bool = false
        @Published var hasSensitiveHint: Bool = false
        @Published var isPrivacyRedactedApplied: Bool = false
        @Published var isProcessingAction: Bool = false
    }

    private weak var boundStore: ClipboardStore?
    private var displaySessions: [CapturedDisplaySession] = []
    private weak var activeDisplayCanvas: ScreenshotCanvasView?

    // 独立同源 Liquid Glass 操作岛
    private var toolbarPanel: UnifiedActiveFloatingPanel?
    private let toolbarSurfaceHost = LiquidGlassSurfaceHost()
    private let toolbarBleed: CGFloat = 16
    private var toolbarHostingView: NSHostingView<ScreenshotToolbarView>?
    private let toolbarVM = ToolbarViewModel()

    // 屏幕录制权限引导卡
    private var permissionPanel: UnifiedActiveFloatingPanel?
    private let permissionSurfaceHost = LiquidGlassSurfaceHost()
    private var permissionHideWorkItem: DispatchWorkItem?

    private var surfaceCancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var flagsMonitor: Any?
    private var isCapturingFrame: Bool = false
    private var isSessionVisible: Bool = false
    private var sensitiveScanEpoch: UInt64 = 0
    private var previousFrontmostApp: NSRunningApplication?

    private nonisolated static let colorDefaultsKey = "iClip.screenshotPreferredColorHex"
    private nonisolated static let widthDefaultsKey = "iClip.screenshotPreferredStrokeWidth"

    private override init() {
        super.init()
    }

    nonisolated static func loadPreferredColorHex() -> String {
        let saved = UserDefaults.standard.string(forKey: colorDefaultsKey)
        if let saved, ScreenshotColorPreset.presets.contains(where: { $0.hex == saved }) {
            return saved
        }
        return ScreenshotColorPreset.presets[0].hex
    }

    nonisolated static func loadPreferredStrokeWidth() -> ScreenshotStrokeWidth {
        let raw = UserDefaults.standard.double(forKey: widthDefaultsKey)
        if let found = ScreenshotStrokeWidth(rawValue: CGFloat(raw)) {
            return found
        }
        return .medium
    }

    /// 按下默认 `⌥A` 或从菜单发起截图
    func startCapture(store: ClipboardStore) {
        if isSessionVisible {
            dismissImmediately()
            return
        }
        guard !isCapturingFrame else { return }

        boundStore = store

        // 屏幕录制权限前置校验：统一打开独立果味权限授权中心并高亮「屏幕录制」条目
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            AppWindowCoordinator.shared.presentPermissionSetup(store: store, highlight: .screenRecording)
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        if let frontApp, frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousFrontmostApp = frontApp
        } else {
            previousFrontmostApp = nil
        }

        isCapturingFrame = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCapturingFrame = false }
            await self.prepareAndShowFrozenDisplays(store: store)
        }
    }

    func dismissImmediately(restorePreviousApp: Bool = true) {
        sensitiveScanEpoch &+= 1
        permissionHideWorkItem?.cancel()
        permissionHideWorkItem = nil
        permissionPanel?.orderOut(nil)
        permissionPanel = nil

        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }

        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        toolbarHostingView = nil

        for session in displaySessions {
            session.canvasView.cancelTextEditingIfNeeded()
            session.panel.orderOut(nil)
        }
        displaySessions.removeAll()
        activeDisplayCanvas = nil
        isSessionVisible = false
        NSCursor.arrow.set()

        if restorePreviousApp, let prevApp = previousFrontmostApp, !prevApp.isTerminated {
            prevApp.activate()
        }
        previousFrontmostApp = nil
    }

    // MARK: - 多屏零闪烁全分辨率抓帧 + 窗口坐标系对齐

    private func prepareAndShowFrozenDisplays(store: ClipboardStore) async {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let shareable: SCShareableContent
        do {
            shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                presentPermissionPrompt(store: store)
            } else {
                store.showToast("无法获取屏幕画面，请稍后重试")
            }
            return
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let ownSCWindows = shareable.windows.filter { $0.owningApplication?.processID == selfPID }
        let rawCGWindows = Self.collectCGWindows(excludingPID: selfPID)
        let mainCGHeight = CGDisplayBounds(CGMainDisplayID()).height

        var capturedSessions: [CapturedDisplaySession] = []

        for screen in screens {
            guard let displayID = MacOS27Capabilities.displayID(for: screen) else {
                continue
            }
            guard let scDisplay = shareable.displays.first(where: { $0.displayID == displayID }) else {
                continue
            }

            let scale = max(1.0, screen.backingScaleFactor)
            let pixelWidth = Int(round(screen.frame.width * scale))
            let pixelHeight = Int(round(screen.frame.height * scale))
            let filter = SCContentFilter(display: scDisplay, excludingWindows: ownSCWindows)

            var capturedSnapshot: CGImage?
            if #available(macOS 26.0, *) {
                let shotConfig = SCScreenshotConfiguration()
                shotConfig.width = pixelWidth
                shotConfig.height = pixelHeight
                shotConfig.showsCursor = false
                shotConfig.includeChildWindows = true
                shotConfig.displayIntent = .local
                shotConfig.dynamicRange = .sdr
                if let output = try? await SCScreenshotManager.captureScreenshot(
                    contentFilter: filter,
                    configuration: shotConfig
                ) {
                    capturedSnapshot = output.sdrImage
                }
            }
            if capturedSnapshot == nil {
                let config = SCStreamConfiguration()
                config.width = pixelWidth
                config.height = pixelHeight
                config.showsCursor = false
                config.scalesToFit = true
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.displayP3
                capturedSnapshot = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
            }
            guard let snapshot = capturedSnapshot else {
                continue
            }

            let viewBounds = NSRect(origin: .zero, size: screen.frame.size)
            let snapped = Self.mapWindowsToScreenLocal(
                rawCGWindows,
                screenFrame: screen.frame,
                mainCGHeight: mainCGHeight
            )

            let panel = KeyableScreenshotPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false

            let canvas = ScreenshotCanvasView(
                frame: viewBounds,
                baseImage: snapshot,
                snappableWindows: snapped,
                backingScale: scale
            )
            panel.contentView = canvas
            bindCanvasCallbacks(canvas, in: panel, screen: screen, store: store)

            capturedSessions.append(
                CapturedDisplaySession(
                    screen: screen,
                    displayID: displayID,
                    snapshotCGImage: snapshot,
                    snappableWindows: snapped,
                    panel: panel,
                    canvasView: canvas
                )
            )
        }

        guard !capturedSessions.isEmpty else {
            if !CGPreflightScreenCaptureAccess() {
                presentPermissionPrompt(store: store)
            } else {
                store.showToast("截图初始化失败，请检查系统屏幕录制权限")
            }
            return
        }

        self.displaySessions = capturedSessions
        self.toolbarVM.activeTool = nil
        self.toolbarVM.canUndo = false
        self.toolbarVM.hasSensitiveHint = false
        self.toolbarVM.isPrivacyRedactedApplied = false
        self.toolbarVM.isProcessingAction = false

        let mouse = NSEvent.mouseLocation
        _ = NSRunningApplication.current.activate(options: .activateAllWindows)
        NSApp.activate(ignoringOtherApps: true)
        var targetKeySession: CapturedDisplaySession? = nil
        for session in capturedSessions {
            session.panel.orderFrontRegardless()
            if session.screen.frame.contains(mouse) {
                targetKeySession = session
                self.activeDisplayCanvas = session.canvasView
                let localPt = session.panel.convertPoint(fromScreen: mouse)
                session.canvasView.updateInitialHoverPoint(localPt)
            }
        }
        if let keySession = targetKeySession ?? capturedSessions.first {
            self.activeDisplayCanvas = keySession.canvasView
            keySession.panel.makeKeyAndOrderFront(nil)
            keySession.panel.makeFirstResponder(keySession.canvasView)
        }
        NSCursor.crosshair.set()
        isSessionVisible = true
        installEventMonitors(store: store)
    }

    private func bindCanvasCallbacks(
        _ canvas: ScreenshotCanvasView,
        in panel: KeyableScreenshotPanel,
        screen: NSScreen,
        store: ClipboardStore
    ) {
        canvas.onSelectionBeganOrCleared = { [weak self, weak canvas] hasSelection in
            guard let self, let canvas else { return }
            self.activateCanvas(canvas, in: panel)
            if !hasSelection {
                self.toolbarPanel?.orderOut(nil)
                self.toolbarVM.activeTool = nil
                self.toolbarVM.canUndo = false
                self.toolbarVM.hasSensitiveHint = false
                self.toolbarVM.isPrivacyRedactedApplied = false
            }
        }

        canvas.onSelectionChanged = { [weak self, weak canvas] selection, isFinalized, instantCopyTriggered in
            guard let self, let canvas else { return }
            self.activateCanvas(canvas, in: panel)
            if instantCopyTriggered {
                self.performCommitCopy(from: canvas, store: store, recordOneMindActionID: "shot-quick-copy")
                return
            }
            if isFinalized, let selection, selection.width >= 6, selection.height >= 6 {
                self.showOrUpdateToolbar(for: selection, in: panel, screen: screen, store: store)
                self.scheduleSensitiveHintScan(for: canvas, selection: selection)
            } else {
                self.toolbarPanel?.orderOut(nil)
            }
        }

        canvas.onAnnotationsChanged = { [weak self, weak canvas] in
            guard let self, let canvas, canvas === self.activeDisplayCanvas else { return }
            self.toolbarVM.canUndo = !canvas.annotations.isEmpty
        }

        canvas.onDoubleClickSelection = { [weak self, weak canvas] in
            guard let self, let canvas else { return }
            self.performCommitCopy(from: canvas, store: store, recordOneMindActionID: "shot-copy")
        }

        canvas.onCancelRequested = { [weak self, weak canvas] in
            guard let self else { return }
            if let canvas, canvas.selectionRect != nil, canvas.activeTool == nil {
                // 右键先清空选区回吸附态，再次右键直接退出
                canvas.resetSelectionToHover()
            } else {
                self.dismissImmediately()
            }
        }
    }

    private func activateCanvas(_ canvas: ScreenshotCanvasView, in panel: KeyableScreenshotPanel) {
        if activeDisplayCanvas !== canvas {
            activeDisplayCanvas?.clearSelectionSilently()
            activeDisplayCanvas = canvas
            if !panel.isKeyWindow {
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - 键盘事件监听（ESC / ↵ / ⌘Z / ⌘S / Space / ⌘ / ⇧）

    private func installEventMonitors(store: ClipboardStore) {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isSessionVisible else { return event }

            // 文本框输入期间仅拦截 ESC / ↵ 交还 NSTextFieldDelegate 处理，避免全局快捷键误退截图
            if let canvas = self.activeDisplayCanvas, canvas.isEditingTextAnnotation {
                return event
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let code = Int(event.keyCode)

            if code == 53 { // ESC
                self.dismissImmediately()
                return nil
            }

            if code == 36 || code == 76 { // Enter / Return
                if let canvas = self.activeDisplayCanvas, canvas.selectionRect != nil {
                    self.performCommitCopy(from: canvas, store: store, recordOneMindActionID: "shot-copy")
                    return nil
                }
            }

            if flags.contains(.command) && code == kVK_ANSI_C {
                if let canvas = self.activeDisplayCanvas, canvas.selectionRect != nil {
                    self.performCommitCopy(from: canvas, store: store, recordOneMindActionID: "shot-copy")
                }
                return nil
            }

            if flags.contains(.command) && code == kVK_ANSI_Z {
                self.performUndo()
                return nil
            }

            if flags.contains(.command) && code == kVK_ANSI_S {
                if let canvas = self.activeDisplayCanvas, canvas.selectionRect != nil {
                    self.performSavePNG(from: canvas, store: store)
                }
                return nil
            }

            if code == 49 { // Space: 按住整体平移选区
                if !event.isARepeat {
                    self.activeDisplayCanvas?.setSpacePressed(true)
                }
                return nil
            }

            return event
        }

        // 同时监听 keyUp 以精确重置 Space 键状态 + flagsChanged 跟踪 ⌘ / ⇧
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.isSessionVisible else { return event }
            if event.type == .keyUp && Int(event.keyCode) == 49 {
                self.activeDisplayCanvas?.setSpacePressed(false)
                return nil
            }
            if event.type == .flagsChanged {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                self.activeDisplayCanvas?.updateModifierFlags(
                    shiftPressed: flags.contains(.shift),
                    commandPressed: flags.contains(.command)
                )
            }
            return event
        }

        // 兜底：极端情况下若系统浮窗抢走前台焦点，全局监控仍响应 ESC 与 ↵
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isSessionVisible, !NSApp.isActive else { return }
            let code = Int(event.keyCode)
            if code == 53 {
                DispatchQueue.main.async { self.dismissImmediately() }
            } else if (code == 36 || code == 76), let canvas = self.activeDisplayCanvas, canvas.selectionRect != nil {
                DispatchQueue.main.async { self.performCommitCopy(from: canvas, store: store, recordOneMindActionID: "shot-copy") }
            }
        }
    }

    // MARK: - 同源 Liquid Glass 操作岛窗口（100% 复刻主面板质感）

    private func toolbarSize(expanded: Bool) -> NSSize {
        NSSize(width: 472, height: expanded ? 86 : 46)
    }

    private func showOrUpdateToolbar(
        for selectionInView: CGRect,
        in hostPanel: KeyableScreenshotPanel,
        screen: NSScreen,
        store: ClipboardStore
    ) {
        let expanded = (toolbarVM.activeTool != nil)
        let cardSize = toolbarSize(expanded: expanded)
        let cornerRadius: CGFloat = 16.0
        let cardRect = NSRect(origin: .zero, size: cardSize)

        if !surfaceCancellables.isEmpty {
            surfaceCancellables.removeAll()
        }
        store.$liquidGlassMaskOpacity
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] opacity in
                guard let self, let store else { return }
                self.toolbarSurfaceHost.updateLiquidGlass(
                    appearance: store.liquidGlassAppearance,
                    maskOpacity: max(opacity, 0.44)
                )
            }
            .store(in: &surfaceCancellables)

        store.$surfaceStyle
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] newStyle in
                guard let self, let store, let panel = self.toolbarPanel, let hosting = self.toolbarHostingView else { return }
                let curSize = hosting.frame.size
                self.toolbarSurfaceHost.install(
                    on: panel,
                    hostingView: hosting,
                    bounds: NSRect(origin: .zero, size: curSize),
                    bleed: self.toolbarBleed,
                    cornerRadius: 16.0,
                    style: newStyle,
                    appearance: store.liquidGlassAppearance,
                    maskOpacity: max(store.liquidGlassMaskOpacity, 0.44),
                    autoResizeWithWindow: false
                )
            }
            .store(in: &surfaceCancellables)

        if toolbarPanel == nil {
            let winSize = NSSize(width: cardSize.width + toolbarBleed * 2, height: cardSize.height + toolbarBleed * 2)
            let p = UnifiedActiveFloatingPanel(
                contentRect: NSRect(origin: .zero, size: winSize),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isMovable = false

            let root = ScreenshotToolbarView(
                viewModel: toolbarVM,
                onSelectTool: { [weak self] tool in
                    self?.handleSelectTool(tool)
                },
                onSelectColor: { [weak self] hex in
                    self?.handleSelectColor(hex)
                },
                onSelectWidth: { [weak self] width in
                    self?.handleSelectWidth(width)
                },
                onUndo: { [weak self] in
                    self?.performUndo()
                },
                onPrivacyRedact: { [weak self] in
                    self?.performAIPrivacyRedact()
                },
                onExtractOCR: { [weak self] in
                    guard let self, let canvas = self.activeDisplayCanvas else { return }
                    self.performExtractOCRAndBigBang(from: canvas, store: store)
                },
                onSavePNG: { [weak self] in
                    guard let self, let canvas = self.activeDisplayCanvas else { return }
                    self.performSavePNG(from: canvas, store: store)
                },
                onCancel: { [weak self] in
                    self?.dismissImmediately()
                },
                onCommitCopy: { [weak self] in
                    guard let self, let canvas = self.activeDisplayCanvas else { return }
                    self.performCommitCopy(from: canvas, store: store, recordOneMindActionID: "shot-copy")
                }
            )
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            hosting.frame = cardRect
            hosting.autoresizingMask = [.width, .height]
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            hosting.layer?.cornerCurve = .continuous
            hosting.layer?.cornerRadius = cornerRadius
            hosting.layer?.masksToBounds = true

            toolbarSurfaceHost.install(
                on: p,
                hostingView: hosting,
                bounds: cardRect,
                bleed: toolbarBleed,
                cornerRadius: cornerRadius,
                style: store.surfaceStyle,
                appearance: store.liquidGlassAppearance,
                maskOpacity: max(store.liquidGlassMaskOpacity, 0.44),
                autoResizeWithWindow: false
            )

            self.toolbarHostingView = hosting
            self.toolbarPanel = p
        } else if let panel = toolbarPanel {
            toolbarSurfaceHost.updateGeometry(cardSize: cardSize, bleed: toolbarBleed, cornerRadius: cornerRadius, on: panel)
        }

        guard let panel = toolbarPanel else { return }
        let viewBounds = NSRect(origin: .zero, size: screen.frame.size)
        let cardOriginInView = ScreenshotGeometryEngine.toolbarOrigin(
            for: selectionInView,
            toolbarSize: cardSize,
            bounds: viewBounds,
            margin: 12
        )
        let screenPoint = hostPanel.convertToScreen(NSRect(origin: cardOriginInView, size: .zero)).origin
        let windowOrigin = NSPoint(x: screenPoint.x - toolbarBleed, y: screenPoint.y - toolbarBleed)

        let wasHidden = !panel.isVisible
        if wasHidden {
            panel.setFrameOrigin(NSPoint(x: windowOrigin.x, y: windowOrigin.y - 6))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.enforceUnifiedActiveAppearance()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(windowOrigin)
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().setFrameOrigin(windowOrigin)
            }
            panel.enforceUnifiedActiveAppearance()
        }
    }

    private func repositionToolbarIfVisible() {
        guard let canvas = activeDisplayCanvas,
              let selection = canvas.selectionRect,
              let store = boundStore,
              let session = displaySessions.first(where: { $0.canvasView === canvas }) else {
            return
        }
        showOrUpdateToolbar(for: selection, in: session.panel, screen: session.screen, store: store)
    }

    // MARK: - 工具岛动作响应与 OneMind 联动

    private func handleSelectTool(_ tool: ScreenshotAnnotationTool) {
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
        if toolbarVM.activeTool == tool {
            toolbarVM.activeTool = nil
        } else {
            toolbarVM.activeTool = tool
        }
        activeDisplayCanvas?.setActiveTool(
            toolbarVM.activeTool,
            colorHex: toolbarVM.selectedColorHex,
            strokeWidth: toolbarVM.strokeWidth
        )
        repositionToolbarIfVisible()
    }

    private func handleSelectColor(_ hex: String) {
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
        toolbarVM.selectedColorHex = hex
        UserDefaults.standard.set(hex, forKey: Self.colorDefaultsKey)
        activeDisplayCanvas?.setActiveTool(
            toolbarVM.activeTool,
            colorHex: hex,
            strokeWidth: toolbarVM.strokeWidth
        )
    }

    private func handleSelectWidth(_ width: ScreenshotStrokeWidth) {
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
        toolbarVM.strokeWidth = width
        UserDefaults.standard.set(Double(width.rawValue), forKey: Self.widthDefaultsKey)
        activeDisplayCanvas?.setActiveTool(
            toolbarVM.activeTool,
            colorHex: toolbarVM.selectedColorHex,
            strokeWidth: width
        )
    }

    private func performUndo() {
        guard let canvas = activeDisplayCanvas else { return }
        if canvas.undoLastAnnotation() {
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
            toolbarVM.canUndo = !canvas.annotations.isEmpty
            toolbarVM.isPrivacyRedactedApplied = canvas.annotations.contains {
                if case .privacyMosaic = $0.kind { return true }
                return false
            }
        }
    }

    private func performAIPrivacyRedact() {
        guard !toolbarVM.isProcessingAction,
              let canvas = activeDisplayCanvas,
              let selection = canvas.selectionRect else {
            return
        }
        guard let composite = ScreenshotAnnotationRenderer.renderCompositeImage(
            baseImage: canvas.baseImage,
            cropRectInViewPoints: selection,
            viewBounds: canvas.bounds,
            annotations: []
        ) else {
            return
        }

        toolbarVM.isProcessingAction = true
        TactileFeedbackEngine.shared.performNavigationStepHaptic()

        Task.detached(priority: .userInitiated) { [weak self, weak canvas] in
            let normBoxes = ImageStudioEngine.detectSensitiveNormalizedBoxes(in: composite.cgImage)
            await MainActor.run { [weak self, weak canvas] in
                guard let self else { return }
                self.toolbarVM.isProcessingAction = false
                guard self.isSessionVisible,
                      let canvas,
                      canvas === self.activeDisplayCanvas,
                      let curSelection = canvas.selectionRect else {
                    return
                }
                if normBoxes.isEmpty {
                    self.boundStore?.showToast("当前选区未识别到敏感号码、邮箱或二维码")
                    return
                }
                // 将 Vision 归一化坐标 [0, 1]（左下原点）精确映射到选区视图坐标
                let mappedRects: [CGRect] = normBoxes.map { norm in
                    CGRect(
                        x: curSelection.minX + norm.minX * curSelection.width - 3,
                        y: curSelection.minY + norm.minY * curSelection.height - 2,
                        width: norm.width * curSelection.width + 6,
                        height: norm.height * curSelection.height + 4
                    )
                }
                canvas.appendAnnotation(ScreenshotAnnotation(kind: .privacyMosaic(rects: mappedRects)))
                self.toolbarVM.canUndo = true
                self.toolbarVM.isPrivacyRedactedApplied = true
                OneMindKernel.shared.recordActionUsed(
                    actionID: "img-privacy-mosaic",
                    categoryKey: "security",
                    sourceApp: self.boundStore?.activeTargetAppName
                )
                TactileFeedbackEngine.shared.perform(.magicTransform)
            }
        }
    }

    private func scheduleSensitiveHintScan(for canvas: ScreenshotCanvasView, selection: CGRect) {
        guard selection.width >= 36, selection.height >= 20 else {
            toolbarVM.hasSensitiveHint = false
            return
        }
        guard let composite = ScreenshotAnnotationRenderer.renderCompositeImage(
            baseImage: canvas.baseImage,
            cropRectInViewPoints: selection,
            viewBounds: canvas.bounds,
            annotations: []
        ) else {
            return
        }
        sensitiveScanEpoch &+= 1
        let epoch = sensitiveScanEpoch
        Task.detached(priority: .utility) { [weak self] in
            let hasSensitive = !ImageStudioEngine.detectSensitiveNormalizedBoxes(in: composite.cgImage).isEmpty
            await MainActor.run { [weak self] in
                guard let self, self.isSessionVisible, self.sensitiveScanEpoch == epoch else { return }
                self.toolbarVM.hasSensitiveHint = hasSensitive
            }
        }
    }

    private func performCommitCopy(
        from canvas: ScreenshotCanvasView,
        store: ClipboardStore,
        recordOneMindActionID: String
    ) {
        guard let selection = canvas.selectionRect else { return }
        canvas.commitActiveTextFieldIfNeeded()
        guard let rendered = ScreenshotAnnotationRenderer.renderCompositeImage(
            baseImage: canvas.baseImage,
            cropRectInViewPoints: selection,
            viewBounds: canvas.bounds,
            annotations: canvas.annotations
        ) else {
            return
        }

        OneMindKernel.shared.recordActionUsed(
            actionID: recordOneMindActionID,
            categoryKey: "image",
            sourceApp: store.activeTargetAppName
        )
        TactileFeedbackEngine.shared.perform(.pasteCommit)
        dismissImmediately()
        _ = store.commitCapturedScreenshotPNG(
            rendered.pngData,
            sourceApp: "iClip 截图",
            toastTitle: "截图已复制到剪贴板（直接 ⌘V 粘贴）"
        )
    }

    private func performExtractOCRAndBigBang(from canvas: ScreenshotCanvasView, store: ClipboardStore) {
        guard let selection = canvas.selectionRect else { return }
        canvas.commitActiveTextFieldIfNeeded()
        guard let rendered = ScreenshotAnnotationRenderer.renderCompositeImage(
            baseImage: canvas.baseImage,
            cropRectInViewPoints: selection,
            viewBounds: canvas.bounds,
            annotations: canvas.annotations
        ) else {
            return
        }

        OneMindKernel.shared.recordActionUsed(
            actionID: "img-ocr",
            categoryKey: "image",
            sourceApp: store.activeTargetAppName
        )
        TactileFeedbackEngine.shared.perform(.magicTransform)
        dismissImmediately(restorePreviousApp: false)

        let committedItem = store.commitCapturedScreenshotPNG(
            rendered.pngData,
            sourceApp: "iClip 截图",
            toastTitle: store.minimalModeEnabled ? "正在提取截图文字..." : "已识别文字，呼出大爆炸选词舞台"
        )
        guard let item = committedItem else { return }

        if store.minimalModeEnabled {
            store.pasteExtractedOCRText(for: item, shouldAutoPaste: false, onBeforePaste: nil)
        } else {
            _ = BigBangStageController.shared.presentOrUpdate(for: item, in: store, initialMode: .imageBigBangOCR)
        }
    }

    private func performSavePNG(from canvas: ScreenshotCanvasView, store: ClipboardStore) {
        guard let selection = canvas.selectionRect else { return }
        canvas.commitActiveTextFieldIfNeeded()
        guard let rendered = ScreenshotAnnotationRenderer.renderCompositeImage(
            baseImage: canvas.baseImage,
            cropRectInViewPoints: selection,
            viewBounds: canvas.bounds,
            annotations: canvas.annotations
        ) else {
            return
        }

        let pngData = rendered.pngData
        OneMindKernel.shared.recordActionUsed(
            actionID: "shot-save-png",
            categoryKey: "image",
            sourceApp: store.activeTargetAppName
        )
        TactileFeedbackEngine.shared.perform(.favoriteOn)
        dismissImmediately(restorePreviousApp: false)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let defaultName = "iClip-截图-\(formatter.string(from: Date())).png"

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = defaultName
        savePanel.canCreateDirectories = true
        savePanel.level = .floating

        NSApp.activate(ignoringOtherApps: true)
        savePanel.begin { result in
            Task { @MainActor in
                guard result == .OK, let url = savePanel.url else { return }
                do {
                    try pngData.write(to: url, options: .atomic)
                    store.showToast("截图已保存至 \(url.lastPathComponent)")
                } catch {
                    store.showToast("保存失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 屏幕录制权限同源 Liquid Glass 指引卡

    private func presentPermissionPrompt(store: ClipboardStore) {
        permissionHideWorkItem?.cancel()
        permissionPanel?.orderOut(nil)

        let cardSize = NSSize(width: 318, height: 86)
        let bleed: CGFloat = 18
        let cornerRadius: CGFloat = 20
        let winSize = NSSize(width: cardSize.width + bleed * 2, height: cardSize.height + bleed * 2)

        let p = UnifiedActiveFloatingPanel(
            contentRect: NSRect(origin: .zero, size: winSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let view = ScreenshotPermissionGuideView(
            onOpenSettings: { [weak self] in
                self?.permissionPanel?.orderOut(nil)
                self?.permissionPanel = nil
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            },
            onDismiss: { [weak self] in
                self?.permissionPanel?.orderOut(nil)
                self?.permissionPanel = nil
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: cardSize)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.cornerRadius = cornerRadius
        hosting.layer?.masksToBounds = true

        permissionSurfaceHost.install(
            on: p,
            hostingView: hosting,
            bounds: NSRect(origin: .zero, size: cardSize),
            bleed: bleed,
            cornerRadius: cornerRadius,
            style: store.surfaceStyle,
            appearance: store.liquidGlassAppearance,
            maskOpacity: store.liquidGlassMaskOpacity,
            autoResizeWithWindow: false
        )

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let x = visible.midX - cardSize.width * 0.5 - bleed
        let y = visible.maxY - cardSize.height - 56 - bleed
        p.setFrameOrigin(NSPoint(x: x, y: y))
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.enforceUnifiedActiveAppearance()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            p.animator().alphaValue = 1
        }
        self.permissionPanel = p

        let hideWork = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.permissionPanel?.orderOut(nil)
                self?.permissionPanel = nil
            }
        }
        self.permissionHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: hideWork)
    }

    // MARK: - 桌面窗口采集与跨屏坐标换算

    private struct RawCGWindow {
        let windowID: CGWindowID
        let ownerName: String
        let bounds: CGRect
    }

    private static func collectCGWindows(excludingPID: pid_t) -> [RawCGWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var results: [RawCGWindow] = []
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != excludingPID else { continue }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.05 { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict),
                  cgRect.width >= 24,
                  cgRect.height >= 24 else {
                continue
            }
            let wid = CGWindowID((entry[kCGWindowNumber as String] as? UInt32) ?? 0)
            let owner = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            if owner == "Window Server" || owner == "Dock" { continue }
            results.append(RawCGWindow(windowID: wid, ownerName: owner, bounds: cgRect))
        }
        return results
    }

    private static func mapWindowsToScreenLocal(
        _ rawWindows: [RawCGWindow],
        screenFrame: CGRect,
        mainCGHeight: CGFloat
    ) -> [SnappableWindowRect] {
        var mapped: [SnappableWindowRect] = []
        for w in rawWindows {
            let appKitGlobal = CGRect(
                x: w.bounds.minX,
                y: mainCGHeight - w.bounds.maxY,
                width: w.bounds.width,
                height: w.bounds.height
            )
            let intersection = appKitGlobal.intersection(screenFrame)
            guard !intersection.isNull, intersection.width >= 24, intersection.height >= 24 else { continue }
            let local = CGRect(
                x: intersection.minX - screenFrame.minX,
                y: intersection.minY - screenFrame.minY,
                width: intersection.width,
                height: intersection.height
            )
            mapped.append(SnappableWindowRect(windowID: w.windowID, ownerName: w.ownerName, rect: local))
        }
        return mapped
    }
}

// MARK: - 2. 可成为 Key 窗的全屏截图窗

private final class KeyableScreenshotPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 3. 120Hz 原生截图画布视图（自动吸附 / 自由框选 / 完整轻量标注绘制）

@MainActor
private final class ScreenshotCanvasView: NSView, NSTextFieldDelegate {
    private enum DragInteractionMode {
        case none
        case creatingSelection(start: CGPoint)
        case resizingSelection(handle: ScreenshotGeometryEngine.ResizeHandle)
        case movingSelection(lastPoint: CGPoint)
        case drawingAnnotation(tool: ScreenshotAnnotationTool, start: CGPoint)
    }

    let baseImage: CGImage
    private let pixelBuffer: ScreenshotPixelBuffer?
    private let snappableWindows: [SnappableWindowRect]
    private let backingScale: CGFloat

    private(set) var selectionRect: CGRect? = nil
    private var hoveredWindow: SnappableWindowRect? = nil
    private var isSelectionFinalized: Bool = false

    private(set) var activeTool: ScreenshotAnnotationTool? = nil
    private var activeColorHex: String = ScreenshotColorPreset.presets[0].hex
    private var activeStrokeWidth: ScreenshotStrokeWidth = .medium
    private(set) var annotations: [ScreenshotAnnotation] = []
    private var draftAnnotation: ScreenshotAnnotation? = nil
    private var brushPointsBuffer: [CGPoint] = []

    private var dragMode: DragInteractionMode = .none
    private var dragAnchorRect: CGRect? = nil
    private var dragSpaceLastPoint: CGPoint = .zero
    private var isShiftPressed: Bool = false
    private var isCommandPressed: Bool = false
    private var isSpacePressed: Bool = false
    private var trackingAreaRef: NSTrackingArea? = nil

    private var activeTextField: NSTextField? = nil
    private var activeTextOrigin: CGPoint = .zero
    var isEditingTextAnnotation: Bool { activeTextField != nil }

    var onSelectionBeganOrCleared: ((Bool) -> Void)?
    var onSelectionChanged: ((_ selection: CGRect?, _ isFinalized: Bool, _ instantCopy: Bool) -> Void)?
    var onAnnotationsChanged: (() -> Void)?
    var onDoubleClickSelection: (() -> Void)?
    var onCancelRequested: (() -> Void)?

    init(
        frame frameRect: NSRect,
        baseImage: CGImage,
        snappableWindows: [SnappableWindowRect],
        backingScale: CGFloat
    ) {
        self.baseImage = baseImage
        self.pixelBuffer = ScreenshotPixelBuffer(image: baseImage)
        self.snappableWindows = snappableWindows
        self.backingScale = backingScale
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func updateInitialHoverPoint(_ point: CGPoint) {
        guard selectionRect == nil else { return }
        hoveredWindow = ScreenshotGeometryEngine.snappedWindowRect(at: point, windows: snappableWindows)
        needsDisplay = true
    }

    func clearSelectionSilently() {
        cancelTextEditingIfNeeded()
        selectionRect = nil
        hoveredWindow = nil
        isSelectionFinalized = false
        annotations.removeAll()
        draftAnnotation = nil
        dragMode = .none
        needsDisplay = true
    }

    func resetSelectionToHover() {
        cancelTextEditingIfNeeded()
        selectionRect = nil
        isSelectionFinalized = false
        annotations.removeAll()
        draftAnnotation = nil
        dragMode = .none
        onSelectionBeganOrCleared?(false)
        needsDisplay = true
    }

    func setActiveTool(_ tool: ScreenshotAnnotationTool?, colorHex: String, strokeWidth: ScreenshotStrokeWidth) {
        commitActiveTextFieldIfNeeded()
        self.activeTool = tool
        self.activeColorHex = colorHex
        self.activeStrokeWidth = strokeWidth
        needsDisplay = true
    }

    func updateModifierFlags(shiftPressed: Bool, commandPressed: Bool) {
        let changed = (isShiftPressed != shiftPressed) || (isCommandPressed != commandPressed)
        isShiftPressed = shiftPressed
        isCommandPressed = commandPressed
        if changed {
            needsDisplay = true
        }
    }

    func setSpacePressed(_ pressed: Bool) {
        guard isSpacePressed != pressed else { return }
        isSpacePressed = pressed
        if pressed, case .creatingSelection = dragMode, let window = self.window {
            let pt = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            dragSpaceLastPoint = pt
        }
    }

    func appendAnnotation(_ annotation: ScreenshotAnnotation) {
        annotations.append(annotation)
        onAnnotationsChanged?()
        needsDisplay = true
    }

    @discardableResult
    func undoLastAnnotation() -> Bool {
        guard !annotations.isEmpty else { return false }
        annotations.removeLast()
        onAnnotationsChanged?()
        needsDisplay = true
        return true
    }

    // MARK: - CoreGraphics 120Hz 高效重绘（底图 + 暗幕 + 镂空选区 + 标注 + 句柄 + 微缩尺寸胶囊）

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high

        // 1. 绘制全屏定格原图
        ctx.draw(baseImage, in: bounds)

        // 2. 统一柔和暗幕（有选区时用奇偶路径精确镂空，零重影边缘）
        let activeHighlightRect = selectionRect ?? hoveredWindow?.rect
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        if let hole = activeHighlightRect, hole.width >= 2, hole.height >= 2 {
            let path = CGMutablePath()
            path.addRect(bounds)
            if selectionRect == nil && hoveredWindow != nil {
                let r = min(10.0, min(hole.width, hole.height) * 0.15)
                path.addPath(CGPath(roundedRect: hole, cornerWidth: r, cornerHeight: r, transform: nil))
            } else {
                path.addRect(hole)
            }
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }
        ctx.restoreGState()

        // 3. 已确定/正在框选时绘制选中区内实时标注 + 边框 + 8 向句柄 + 尺寸胶囊
        if let sel = selectionRect, sel.width >= 2, sel.height >= 2 {
            ctx.saveGState()
            ctx.clip(to: sel)
            ScreenshotAnnotationRenderer.drawOrderedAnnotations(
                annotations,
                draft: draftAnnotation,
                in: ctx,
                baseImage: baseImage,
                canvasBounds: bounds,
                pixelBuffer: pixelBuffer
            )
            ctx.restoreGState()

            // 电光钴蓝高对比双线框（按住 ⌘ 时呈现翡翠直出脉冲边框）
            let frameColor = (isCommandPressed && !isSelectionFinalized)
                ? NSColor(srgbRed: 0.063, green: 0.725, blue: 0.506, alpha: 0.96)
                : NSColor(srgbRed: 0.118, green: 0.369, blue: 1.0, alpha: 0.95)
            ctx.saveGState()
            ctx.setStrokeColor(frameColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(sel.insetBy(dx: -0.75, dy: -0.75))

            if isSelectionFinalized && activeTool == nil {
                for handle in ScreenshotGeometryEngine.ResizeHandle.allCases {
                    let hp = handle.point(in: sel)
                    let dot = CGRect(x: hp.x - 4.0, y: hp.y - 4.0, width: 8.0, height: 8.0)
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fillEllipse(in: dot)
                    ctx.setStrokeColor(frameColor.cgColor)
                    ctx.setLineWidth(1.4)
                    ctx.strokeEllipse(in: dot)
                }
            }
            ctx.restoreGState()

            drawSizeCapsule(for: sel, in: ctx)
        } else if let win = hoveredWindow {
            // 窗口自动吸附高亮外框（苹果连续圆角光晕）
            let r = min(10.0, min(win.rect.width, win.rect.height) * 0.15)
            let path = CGPath(roundedRect: win.rect, cornerWidth: r, cornerHeight: r, transform: nil)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor(srgbRed: 0.118, green: 0.369, blue: 1.0, alpha: 0.92).cgColor)
            ctx.setLineWidth(2.2)
            ctx.strokePath()
            ctx.restoreGState()

            drawHoverHintCapsule(for: win, in: ctx)
        }
    }

    private func drawSizeCapsule(for sel: CGRect, in ctx: CGContext) {
        let pxW = Int(round(sel.width * backingScale))
        let pxH = Int(round(sel.height * backingScale))
        let instantMode = (isCommandPressed && !isSelectionFinalized)
        let title = instantMode ? "⌘ 松手即复制 · \(pxW)×\(pxH)" : "\(pxW) × \(pxH)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attrStr = NSAttributedString(string: title, attributes: attrs)
        let textSize = attrStr.size()
        let pillSize = CGSize(width: textSize.width + 16, height: 22)

        var x = sel.minX
        if x + pillSize.width > bounds.maxX - 8 {
            x = max(bounds.minX + 8, bounds.maxX - pillSize.width - 8)
        }
        var y = sel.maxY + 6
        let toolbarMayFlipAbove = (sel.minY < 78)
        if y + pillSize.height > bounds.maxY - 28 || toolbarMayFlipAbove {
            // 近顶部菜单栏或工具岛需上翻时，尺寸胶囊内嵌于选区左上角内侧避免碰撞
            x = min(max(sel.minX + 6, bounds.minX + 8), max(bounds.minX + 8, bounds.maxX - pillSize.width - 8))
            y = max(bounds.minY + 6, sel.maxY - pillSize.height - 6)
        }

        let pillRect = CGRect(x: x, y: y, width: pillSize.width, height: pillSize.height)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillSize.height * 0.5, cornerHeight: pillSize.height * 0.5, transform: nil)
        ctx.saveGState()
        ctx.addPath(pillPath)
        ctx.setFillColor(
            instantMode
                ? NSColor(srgbRed: 0.063, green: 0.725, blue: 0.506, alpha: 0.90).cgColor
                : NSColor.black.withAlphaComponent(0.68).cgColor
        )
        ctx.fillPath()
        ctx.addPath(pillPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(0.7)
        ctx.strokePath()
        ctx.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attrStr.draw(at: NSPoint(x: pillRect.minX + 8, y: pillRect.midY - textSize.height * 0.5))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHoverHintCapsule(for win: SnappableWindowRect, in ctx: CGContext) {
        let name = win.ownerName.isEmpty ? "窗口" : win.ownerName
        let title = "单击截取「\(name)」· 拖动自由框选"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let attrStr = NSAttributedString(string: title, attributes: attrs)
        let textSize = attrStr.size()
        let pillSize = CGSize(width: textSize.width + 18, height: 24)
        let centeredX = win.rect.midX - pillSize.width * 0.5
        let x = min(max(centeredX, bounds.minX + 10), max(bounds.minX + 10, bounds.maxX - pillSize.width - 10))
        let topLimit = max(bounds.minY + 10, bounds.maxY - pillSize.height - 34)
        let desiredY = win.rect.maxY + 8
        let y = (desiredY <= topLimit) ? desiredY : min(win.rect.maxY - pillSize.height - 10, topLimit)
        let pillRect = CGRect(x: x, y: max(bounds.minY + 10, y), width: pillSize.width, height: pillSize.height)
        let path = CGPath(roundedRect: pillRect, cornerWidth: 12, cornerHeight: 12, transform: nil)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.64).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
        ctx.setLineWidth(0.7)
        ctx.strokePath()
        ctx.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attrStr.draw(at: NSPoint(x: pillRect.minX + 9, y: pillRect.midY - textSize.height * 0.5))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 鼠标交互（自动窗口吸附 / 选区缩放 / 6 标注绘制 / 双击秒复制）

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if selectionRect == nil {
            let next = ScreenshotGeometryEngine.snappedWindowRect(at: pt, windows: snappableWindows)
            if next != hoveredWindow {
                hoveredWindow = next
                needsDisplay = true
            }
            NSCursor.crosshair.set()
            return
        }

        if let tool = activeTool, let sel = selectionRect, sel.contains(pt) {
            if tool == .text {
                NSCursor.iBeam.set()
            } else {
                NSCursor.crosshair.set()
            }
            return
        }

        if let sel = selectionRect {
            if ScreenshotGeometryEngine.hitTestHandle(at: pt, in: sel) != nil {
                NSCursor.crosshair.set()
            } else if sel.contains(pt) {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let win = self.window, (!NSApp.isActive || !win.isKeyWindow) {
            _ = NSRunningApplication.current.activate(options: .activateAllWindows)
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            if !isEditingTextAnnotation {
                win.makeFirstResponder(self)
            }
        }
        let pt = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        isShiftPressed = flags.contains(.shift)
        isCommandPressed = flags.contains(.command)

        if event.clickCount >= 2,
           let sel = selectionRect,
           sel.contains(pt),
           activeTool == nil {
            onDoubleClickSelection?()
            return
        }

        // 若正处于文字输入且点击别处，先提交文字
        if isEditingTextAnnotation {
            commitActiveTextFieldIfNeeded()
        }

        // 1. 若已激活轻量标注工具，仅允许在选区内落笔；点到选区外安全忽略以防误清已有标注
        if let tool = activeTool, let sel = selectionRect {
            guard sel.contains(pt) else { return }
            if tool == .stepBadge {
                let nextNum = ScreenshotAnnotation.nextStepNumber(in: annotations)
                appendAnnotation(ScreenshotAnnotation(kind: .stepBadge(center: pt, number: nextNum, colorHex: activeColorHex)))
                TactileFeedbackEngine.shared.performNavigationStepHaptic()
                return
            }
            if tool == .text {
                beginTextEditing(at: pt)
                return
            }
            dragMode = .drawingAnnotation(tool: tool, start: pt)
            if tool == .brush || tool == .mosaic {
                brushPointsBuffer = [pt]
                updateDraftAnnotation(tool: tool, start: pt, current: pt)
            }
            return
        }

        // 2. 已选定区域且无激活工具：判断命中 8 向缩放句柄 / 选区内部拖拽 / 重框选
        if let sel = selectionRect {
            if let handle = ScreenshotGeometryEngine.hitTestHandle(at: pt, in: sel) {
                dragMode = .resizingSelection(handle: handle)
                dragAnchorRect = sel
                onSelectionChanged?(sel, false, false)
                return
            }
            if sel.contains(pt) {
                dragMode = .movingSelection(lastPoint: pt)
                NSCursor.closedHand.set()
                return
            }
        }

        // 3. 尚未选定或重新拖拽选区
        dragMode = .creatingSelection(start: pt)
        dragAnchorRect = hoveredWindow?.rect
        dragSpaceLastPoint = pt
        isSelectionFinalized = false
        annotations.removeAll()
        draftAnnotation = nil
        onSelectionBeganOrCleared?(true)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        isShiftPressed = flags.contains(.shift)
        isCommandPressed = flags.contains(.command)

        switch dragMode {
        case .creatingSelection(let start):
            if isSpacePressed, let current = selectionRect {
                let dx = pt.x - dragSpaceLastPoint.x
                let dy = pt.y - dragSpaceLastPoint.y
                dragSpaceLastPoint = pt
                let moved = ScreenshotGeometryEngine.translateRect(current, delta: CGVector(dx: dx, dy: dy), within: bounds)
                selectionRect = moved
                dragMode = .creatingSelection(start: CGPoint(x: start.x + dx, y: start.y + dy))
            } else {
                let rect = ScreenshotGeometryEngine.normalizedRect(
                    from: start,
                    to: pt,
                    lockSquare: isShiftPressed,
                    bounds: bounds
                )
                selectionRect = rect
                dragSpaceLastPoint = pt
            }
            onSelectionChanged?(selectionRect, false, false)
            needsDisplay = true

        case .resizingSelection(let handle):
            guard let cur = selectionRect else { return }
            let resized = ScreenshotGeometryEngine.resizedRect(from: cur, handle: handle, to: pt, bounds: bounds)
            selectionRect = resized
            onSelectionChanged?(resized, false, false)
            needsDisplay = true

        case .movingSelection(let lastPt):
            guard let cur = selectionRect else { return }
            let dx = pt.x - lastPt.x
            let dy = pt.y - lastPt.y
            let moved = ScreenshotGeometryEngine.translateRect(cur, delta: CGVector(dx: dx, dy: dy), within: bounds)
            selectionRect = moved
            dragMode = .movingSelection(lastPoint: pt)
            onSelectionChanged?(moved, false, false)
            needsDisplay = true

        case .drawingAnnotation(let tool, let start):
            guard let sel = selectionRect else { return }
            let clamped = CGPoint(
                x: min(max(pt.x, sel.minX), sel.maxX),
                y: min(max(pt.y, sel.minY), sel.maxY)
            )
            if tool == .brush || tool == .mosaic {
                if let last = brushPointsBuffer.last, hypot(clamped.x - last.x, clamped.y - last.y) >= 2.0 {
                    brushPointsBuffer.append(clamped)
                }
            }
            updateDraftAnnotation(tool: tool, start: start, current: clamped)
            needsDisplay = true

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let instantCopy = event.modifierFlags.contains(.command)

        switch dragMode {
        case .creatingSelection(let start):
            let dragDist = hypot(pt.x - start.x, pt.y - start.y)
            if dragDist < 5.0 {
                // 单击未拖动：若光标位于高亮窗口上则直接整窗选中
                if let hovered = hoveredWindow ?? ScreenshotGeometryEngine.snappedWindowRect(at: pt, windows: snappableWindows) {
                    selectionRect = hovered.rect
                    isSelectionFinalized = true
                    TactileFeedbackEngine.shared.performNavigationStepHaptic()
                    onSelectionChanged?(hovered.rect, true, instantCopy)
                } else {
                    selectionRect = nil
                    isSelectionFinalized = false
                    onSelectionBeganOrCleared?(false)
                }
            } else if let sel = selectionRect, sel.width >= 6, sel.height >= 6 {
                isSelectionFinalized = true
                TactileFeedbackEngine.shared.performNavigationStepHaptic()
                onSelectionChanged?(sel, true, instantCopy)
            } else {
                selectionRect = nil
                isSelectionFinalized = false
                onSelectionBeganOrCleared?(false)
            }

        case .resizingSelection:
            isSelectionFinalized = true
            if let sel = selectionRect {
                onSelectionChanged?(sel, true, false)
            }

        case .movingSelection:
            isSelectionFinalized = true
            NSCursor.openHand.set()
            if let sel = selectionRect {
                onSelectionChanged?(sel, true, false)
            }

        case .drawingAnnotation:
            if let draft = draftAnnotation {
                appendAnnotation(draft)
                draftAnnotation = nil
            }
            brushPointsBuffer.removeAll()

        case .none:
            break
        }

        dragMode = .none
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancelRequested?()
    }

    // MARK: - 轻量标注草稿与原位文本输入框

    private func updateDraftAnnotation(tool: ScreenshotAnnotationTool, start: CGPoint, current: CGPoint) {
        switch tool {
        case .rectangle:
            let r = ScreenshotGeometryEngine.normalizedRect(from: start, to: current, lockSquare: isShiftPressed, bounds: selectionRect ?? bounds)
            guard r.width >= 2, r.height >= 2 else { draftAnnotation = nil; return }
            draftAnnotation = ScreenshotAnnotation(kind: .rectangle(rect: r, colorHex: activeColorHex, lineWidth: activeStrokeWidth.rawValue))

        case .arrow:
            guard hypot(current.x - start.x, current.y - start.y) >= 3 else { draftAnnotation = nil; return }
            draftAnnotation = ScreenshotAnnotation(kind: .arrow(start: start, end: current, colorHex: activeColorHex, lineWidth: activeStrokeWidth.rawValue))

        case .brush:
            draftAnnotation = ScreenshotAnnotation(kind: .brush(points: brushPointsBuffer, colorHex: activeColorHex, lineWidth: activeStrokeWidth.rawValue))

        case .mosaic:
            draftAnnotation = ScreenshotAnnotation(kind: .mosaic(points: brushPointsBuffer, brushWidth: activeStrokeWidth.mosaicWidth))

        case .text, .stepBadge:
            draftAnnotation = nil
        }
    }

    private func beginTextEditing(at point: CGPoint) {
        commitActiveTextFieldIfNeeded()
        activeTextOrigin = point
        let font = NSFont.systemFont(ofSize: activeStrokeWidth.fontSize, weight: .semibold)
        let container = selectionRect ?? bounds
        let fieldHeight = font.pointSize + 12
        let availableWidth = max(72, container.maxX - (point.x - 4) - 6)
        let fieldWidth = min(220, availableWidth)
        let originX = min(max(point.x - 4, container.minX + 4), max(container.minX + 4, container.maxX - fieldWidth - 6))
        let originY = min(max(point.y - font.pointSize * 0.7, container.minY + 4), max(container.minY + 4, container.maxY - fieldHeight - 4))
        let field = NSTextField(frame: NSRect(x: originX, y: originY, width: fieldWidth, height: fieldHeight))
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.32)
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.font = font
        field.textColor = NSColor(cgColor: ScreenshotColorPreset.cgColor(fromHex: activeColorHex)) ?? .systemRed
        field.placeholderAttributedString = NSAttributedString(
            string: "输入批注，按 ↵ 落笔",
            attributes: [
                .font: NSFont.systemFont(ofSize: max(11, activeStrokeWidth.fontSize - 2), weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.55)
            ]
        )
        field.focusRingType = .none
        field.delegate = self

        addSubview(field)
        window?.makeFirstResponder(field)
        activeTextField = field
    }

    func commitActiveTextFieldIfNeeded() {
        guard let field = activeTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = activeTextOrigin
        activeTextField = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if !text.isEmpty {
            appendAnnotation(
                ScreenshotAnnotation(
                    kind: .text(
                        origin: origin,
                        text: text,
                        colorHex: activeColorHex,
                        fontSize: activeStrokeWidth.fontSize
                    )
                )
            )
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
        }
    }

    func cancelTextEditingIfNeeded() {
        guard let field = activeTextField else { return }
        activeTextField = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitActiveTextFieldIfNeeded()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEditingIfNeeded()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitActiveTextFieldIfNeeded()
    }
}

// MARK: - 4. 同源 Liquid Glass 极简操作岛视图

private struct ScreenshotToolbarView: View {
    @ObservedObject var viewModel: ScreenshotOverlayController.ToolbarViewModel
    let onSelectTool: (ScreenshotAnnotationTool) -> Void
    let onSelectColor: (String) -> Void
    let onSelectWidth: (ScreenshotStrokeWidth) -> Void
    let onUndo: () -> Void
    let onPrivacyRedact: () -> Void
    let onExtractOCR: () -> Void
    let onSavePNG: () -> Void
    let onCancel: () -> Void
    let onCommitCopy: () -> Void

    @Namespace private var toolNS

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TahoeGlassContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(ScreenshotAnnotationTool.allCases) { tool in
                        let active = (viewModel.activeTool == tool)
                        Button {
                            onSelectTool(tool)
                        } label: {
                            Group {
                                if tool == .text {
                                    Text("T")
                                        .font(.system(size: 13.5, weight: .bold, design: .serif))
                                } else {
                                    Image(systemName: tool.symbolName)
                                        .font(.system(size: 12.5, weight: active ? .bold : .medium))
                                }
                            }
                            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.88))
                            .frame(width: 28, height: 28)
                            .background {
                                if active {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.accentColor)
                                        .matchedGeometryEffect(id: "screenshotActiveToolPill", in: toolNS)
                                        .macOS27GlassMorph(id: "screenshotActiveToolGlass", in: toolNS)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(PhysicalSpringButtonStyle())
                        .help(tool.title)
                    }

                Divider()
                    .frame(height: 16)
                    .opacity(0.32)
                    .padding(.horizontal, 2)

                Button(action: onUndo) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(viewModel.canUndo ? Color.primary.opacity(0.90) : Color.primary.opacity(0.32))
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PhysicalSpringButtonStyle())
                .disabled(!viewModel.canUndo)
                .help("撤销标注（⌘Z）")

                Button(action: onPrivacyRedact) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: viewModel.isPrivacyRedactedApplied ? "eye.slash.fill" : "eye.trianglebadge.exclamationmark")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(
                                viewModel.isPrivacyRedactedApplied
                                    ? Color.green
                                    : (viewModel.hasSensitiveHint ? Color.orange : Color.primary.opacity(0.88))
                            )
                            .frame(width: 28, height: 28)

                        if viewModel.hasSensitiveHint && !viewModel.isPrivacyRedactedApplied {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                                .offset(x: -3, y: 4)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PhysicalSpringButtonStyle())
                .help(viewModel.hasSensitiveHint ? "检测到敏感信息，点击 AI 一键隐私打码" : "AI 一键识别隐私内容并打码")

                Button(action: onExtractOCR) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.88))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PhysicalSpringButtonStyle())
                .help("识别文字与大爆炸选词")

                Button(action: onSavePNG) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.88))
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PhysicalSpringButtonStyle())
                .help("保存为 PNG 文件（⌘S）")

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PhysicalSpringButtonStyle())
                .help("取消截图（ESC）")

                Spacer(minLength: 2)

                Button(action: onCommitCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                        Text("完成")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5.5)
                    .background(Capsule().fill(Color.accentColor))
                    .macOS27GlassCapsule(tint: Color.accentColor.opacity(0.35), interactive: true)
                }
                .buttonStyle(PhysicalSpringButtonStyle())
                .help("复制截图到剪贴板（↵ / 双击选区）")
            }
            }

            if let tool = viewModel.activeTool {
                HStack(spacing: 10) {
                    if tool != .mosaic {
                        HStack(spacing: 7) {
                            ForEach(ScreenshotColorPreset.presets) { preset in
                                let chosen = (viewModel.selectedColorHex == preset.hex)
                                Button {
                                    onSelectColor(preset.hex)
                                } label: {
                                    Circle()
                                        .fill(Color(cgColor: ScreenshotColorPreset.cgColor(fromHex: preset.hex)))
                                        .frame(width: 15, height: 15)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.white.opacity(chosen ? 0.95 : 0.45), lineWidth: chosen ? 2.0 : 0.7)
                                        )
                                        .scaleEffect(chosen ? 1.15 : 1.0)
                                }
                                .buttonStyle(PhysicalSpringButtonStyle())
                                .help(preset.name)
                            }
                        }
                    } else {
                        Text("马赛克粗细")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if tool != .stepBadge {
                        Divider()
                            .frame(height: 14)
                            .opacity(0.32)

                        HStack(spacing: 6) {
                            let activeSwatchColor: Color = (tool == .mosaic)
                                ? Color.primary.opacity(0.92)
                                : Color(cgColor: ScreenshotColorPreset.cgColor(fromHex: viewModel.selectedColorHex))
                            ForEach(ScreenshotStrokeWidth.allCases) { w in
                                let chosen = (viewModel.strokeWidth == w)
                                Button {
                                    onSelectWidth(w)
                                } label: {
                                    Circle()
                                        .fill(chosen ? activeSwatchColor : Color.primary.opacity(0.45))
                                        .overlay(
                                            Circle()
                                                .strokeBorder(
                                                    (chosen && tool != .mosaic && viewModel.selectedColorHex.uppercased() == "#FFFFFF")
                                                        ? Color.black.opacity(0.32)
                                                        : Color.clear,
                                                    lineWidth: 0.75
                                                )
                                        )
                                        .frame(width: w.dotSize, height: w.dotSize)
                                        .frame(width: 22, height: 22)
                                        .background(
                                            Circle()
                                                .fill(chosen ? Color.primary.opacity(0.14) : Color.clear)
                                        )
                                        .overlay(
                                            Circle()
                                                .strokeBorder(chosen ? Color.primary.opacity(0.28) : Color.clear, lineWidth: 1.0)
                                        )
                                }
                                .buttonStyle(PhysicalSpringButtonStyle())
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    Text(tool == .text ? "点击输入 · ↵ 落笔" : (tool == .stepBadge ? "点击标序号" : "拖曳绘制 · ⌘Z 撤销"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: viewModel.activeTool)
    }
}

private struct ScreenshotPermissionGuideView: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text("需要开启屏幕录制权限")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(PhysicalSpringButtonStyle())
            }

            HStack(spacing: 8) {
                Text("在系统隐私设置中勾选 iClip 后即可使用 ⌥A 极速截图")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("前往开启", action: onOpenSettings)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor))
                    .buttonStyle(PhysicalSpringButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
