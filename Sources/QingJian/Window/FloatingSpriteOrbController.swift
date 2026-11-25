import AppKit
import Combine
import SwiftUI

/// 悬浮精灵吸附的屏幕边缘方向
enum SpriteOrbEdgeSide: String, Equatable {
    case left
    case right
}

/// 悬浮精灵根据复制内容或智能建议实时映射的心情光色
enum SpriteOrbMoodAccent: Equatable {
    case cobalt
    case emerald
    case amber

    var swiftUIColor: Color {
        switch self {
        case .cobalt:
            return Color(red: 0.118, green: 0.369, blue: 1.0) // #1E5EFF 电光蓝
        case .emerald:
            return Color(red: 0.063, green: 0.725, blue: 0.506) // #10B981 翡翠绿
        case .amber:
            return Color(red: 0.961, green: 0.620, blue: 0.043) // #F59E0B 琥珀金
        }
    }

    var secondaryColor: Color {
        switch self {
        case .cobalt:
            return Color(red: 0.22, green: 0.74, blue: 0.97)
        case .emerald:
            return Color(red: 0.20, green: 0.86, blue: 0.70)
        case .amber:
            return Color(red: 0.99, green: 0.78, blue: 0.28)
        }
    }
}

/// 悬浮精灵纯几何定位、手势阈值与多窗贴边算法（无窗口副作用，供单元测试直接覆盖）
enum SpriteOrbPhysicsGeometry {
    static let panelDimension: CGFloat = 68
    static let orbVisualRadius: CGFloat = 21
    static let hitTestRadius: CGFloat = 25
    static let dragThreshold: CGFloat = 5.0

    /// 判定指针移动距离是否属于「单击启动剪贴板」而非「拖拽换位」
    static func isClickGesture(dragDistance: CGFloat) -> Bool {
        dragDistance <= dragThreshold
    }

    /// 由 68×68 含光晕透明面板的外框推导出中心 42×42 实球体的屏幕坐标
    static func orbCoreFrame(fromPanelFrame panelFrame: NSRect) -> NSRect {
        let side = orbVisualRadius * 2
        return NSRect(
            x: panelFrame.midX - orbVisualRadius,
            y: panelFrame.midY - orbVisualRadius,
            width: side,
            height: side
        )
    }

    /// 首次启动时的默认初始位置：贴靠主屏右侧中下区（视觉不遮挡工作区正文）
    static func defaultInitialOrigin(panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        let x = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        let rawY = visibleFrame.minY + visibleFrame.height * 0.34
        let minY = visibleFrame.minY + 10
        let maxY = max(minY, visibleFrame.maxY - panelSize.height - 10)
        let clampedY = min(max(rawY, minY), maxY)
        return NSPoint(x: x, y: clampedY)
    }

    /// 拖拽松手或屏幕参数变化后计算最终静止原点与吸附边向
    static func resolvedRestingOrigin(
        currentOrigin: NSPoint,
        panelSize: NSSize,
        visibleFrame: NSRect,
        dockMode: SpriteOrbDockMode
    ) -> (origin: NSPoint, dockedSide: SpriteOrbEdgeSide?) {
        let minY = visibleFrame.minY + 10
        let maxY = max(minY, visibleFrame.maxY - panelSize.height - 10)
        let clampedY = min(max(currentOrigin.y, minY), maxY)

        switch dockMode {
        case .edgeSnap:
            let midX = currentOrigin.x + panelSize.width * 0.5
            let snapRight = midX >= visibleFrame.midX
            let snapX = snapRight
                ? max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
                : visibleFrame.minX
            return (NSPoint(x: snapX, y: clampedY), snapRight ? .right : .left)

        case .freeFloat:
            let minX = visibleFrame.minX + 4
            let maxX = max(minX, visibleFrame.maxX - panelSize.width - 4)
            let clampedX = min(max(currentOrigin.x, minX), maxX)
            return (NSPoint(x: clampedX, y: clampedY), nil)
        }
    }

    /// 将持久化归一化比例还原为目标屏幕的窗口原点
    static func origin(
        fromRatios ratioX: CGFloat,
        ratioY: CGFloat,
        panelSize: NSSize,
        visibleFrame: NSRect,
        dockMode: SpriteOrbDockMode
    ) -> (origin: NSPoint, dockedSide: SpriteOrbEdgeSide?) {
        let usableWidth = max(1, visibleFrame.width - panelSize.width)
        let usableHeight = max(1, visibleFrame.height - panelSize.height)
        let raw = NSPoint(
            x: visibleFrame.minX + min(max(ratioX, 0), 1) * usableWidth,
            y: visibleFrame.minY + min(max(ratioY, 0), 1) * usableHeight
        )
        return resolvedRestingOrigin(
            currentOrigin: raw,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            dockMode: dockMode
        )
    }

    /// 将当前屏幕窗口原点映射回与分辨率无关的归一化比例（0...1）
    static func normalizedRatios(
        forOrigin origin: NSPoint,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> (x: CGFloat, y: CGFloat) {
        let usableWidth = max(1, visibleFrame.width - panelSize.width)
        let usableHeight = max(1, visibleFrame.height - panelSize.height)
        let rx = min(max((origin.x - visibleFrame.minX) / usableWidth, 0), 1)
        let ry = min(max((origin.y - visibleFrame.minY) / usableHeight, 0), 1)
        return (rx, ry)
    }

    /// 计算单击精灵时主剪贴板面板的就近绽放坐标（避让精灵本体的同时完整收敛在可用屏幕内）
    static func panelAnchorOrigin(
        forOrbCoreFrame orbRect: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect,
        shadowBleed: CGFloat
    ) -> (origin: NSPoint, entryDelta: NSPoint) {
        let placeOnLeft = orbRect.midX >= visibleFrame.midX
        let rawLeft = placeOnLeft
            ? (orbRect.minX - panelSize.width - 12)
            : (orbRect.maxX + 12)
        let minLeft = visibleFrame.minX + 10
        let maxLeft = max(minLeft, visibleFrame.maxX - panelSize.width - 10)
        let cardLeft = min(max(rawLeft, minLeft), maxLeft)

        let rawBottom = orbRect.midY - panelSize.height * 0.5
        let minBottom = visibleFrame.minY + 10
        let maxBottom = max(minBottom, visibleFrame.maxY - panelSize.height - 10)
        let cardBottom = min(max(rawBottom, minBottom), maxBottom)

        return (
            NSPoint(x: cardLeft - shadowBleed, y: cardBottom - shadowBleed),
            NSPoint(x: placeOnLeft ? 10 : -10, y: 0)
        )
    }

    /// 计算智能提醒胶囊（Action Spark）紧贴精灵旁侧的安全坐标
    static func sparkAnchorOrigin(
        forOrbCoreFrame orbRect: NSRect,
        sparkSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let placeOnLeft = orbRect.midX >= visibleFrame.midX
        let rawX = placeOnLeft
            ? (orbRect.minX - sparkSize.width - 10)
            : (orbRect.maxX + 10)
        let minX = visibleFrame.minX + 10
        let maxX = max(minX, visibleFrame.maxX - sparkSize.width - 10)
        let x = min(max(rawX, minX), maxX)

        let rawY = orbRect.midY - sparkSize.height * 0.5
        let minY = visibleFrame.minY + 10
        let maxY = max(minY, visibleFrame.maxY - sparkSize.height - 10)
        let y = min(max(rawY, minY), maxY)
        return NSPoint(x: x, y: y)
    }
}

/// 驱动悬浮精灵实时物理、呼吸波形与情绪着色的状态容器
@MainActor
final class SpriteOrbViewModel: ObservableObject {
    @Published var style: SpriteOrbStyle = .prismDew
    @Published var dockMode: SpriteOrbDockMode = .edgeSnap
    @Published var dockedSide: SpriteOrbEdgeSide? = .right

    @Published var isHovered: Bool = false
    @Published var isPressed: Bool = false
    @Published var isDragging: Bool = false
    @Published var isDragTargeted: Bool = false
    @Published var isClipboardPanelOpen: Bool = false
    @Published var isIdleResting: Bool = false

    @Published var hoverOffset: CGPoint = .zero
    @Published var dragVelocity: CGVector = .zero
    @Published var lastDragTime: TimeInterval = 0

    @Published var capturePulseStartTime: TimeInterval = -100
    @Published var captureAccent: SpriteOrbMoodAccent = .cobalt
    @Published var smartSuggestionActive: Bool = false
    @Published var smartSuggestionAccent: SpriteOrbMoodAccent = .emerald
    @Published var acceptedPulseStartTime: TimeInterval = -100
    @Published var pulseWindowActive: Bool = false

    /// 高频（120Hz）与待机呼吸（30Hz）自适应帧率门控
    var needsHighFrameRate: Bool {
        isHovered || isPressed || isDragging || isDragTargeted || smartSuggestionActive || pulseWindowActive
    }
}

/// 原生 120Hz 悬浮精灵控制器：全天候非抢焦常驻，串联点击呼出、拖拽吸边与智能提醒联动
@MainActor
final class FloatingSpriteOrbController {
    static let shared = FloatingSpriteOrbController()

    private static let posXDefaultsKey = "spriteOrbPosXRatio"
    private static let posYDefaultsKey = "spriteOrbPosYRatio"

    var onToggleClipboardPanel: ((NSRect) -> Void)?
    var onOpenTodoList: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let viewModel = SpriteOrbViewModel()
    private var panel: UnifiedActiveFloatingPanel?
    private var hostingView: NSHostingView<SpriteOrbRootView>?
    private var interactiveView: SpriteOrbInteractiveView?
    private weak var boundStore: ClipboardStore?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var isStarted: Bool = false

    private var idleRestWorkItem: DispatchWorkItem?
    private var pulseCooldownWorkItem: DispatchWorkItem?

    private init() {}

    /// 若精灵可见，返回其核心球体屏幕边框（供主面板与微星标旁侧定位）
    var visibleOrbCoreScreenFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return SpriteOrbPhysicsGeometry.orbCoreFrame(fromPanelFrame: panel.frame)
    }

    /// 供主面板外部点击豁免判断（包含微光晕扩边），避免收起面板同时误触发二次呼出
    var visibleHitScreenFrame: NSRect? {
        guard let core = visibleOrbCoreScreenFrame else { return nil }
        return core.insetBy(dx: -4, dy: -4)
    }

    func start(store: ClipboardStore) {
        boundStore = store
        guard !isStarted else {
            syncPreferences(from: store)
            updatePanelVisibility()
            return
        }
        isStarted = true
        syncPreferences(from: store)

        store.$spriteOrbEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePanelVisibility()
            }
            .store(in: &cancellables)

        store.$spriteOrbStyle
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] style in
                guard let self else { return }
                self.viewModel.style = style
                self.bumpInteractionWakefulness()
            }
            .store(in: &cancellables)

        store.$spriteOrbDockMode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                guard let self else { return }
                self.viewModel.dockMode = mode
                self.reanchorCurrentPosition(animated: true)
            }
            .store(in: &cancellables)

        store.$screenSharePrivacyEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.panel?.sharingType = enabled ? .none : .readOnly
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reanchorCurrentPosition(animated: false)
            }
        }

        updatePanelVisibility()
    }

    func stop() {
        idleRestWorkItem?.cancel()
        idleRestWorkItem = nil
        pulseCooldownWorkItem?.cancel()
        pulseCooldownWorkItem = nil
        cancellables.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panel?.orderOut(nil)
        isStarted = false
    }

    func setClipboardPanelVisible(_ visible: Bool) {
        viewModel.isClipboardPanelOpen = visible
        if visible {
            wakeFromIdle()
        } else {
            scheduleIdleRestIfEligible()
        }
    }

    /// 监听新剪贴板内容流入：点亮相应心情色并触发水墨吸收脉冲（未启动时零副作用返回）
    func notifyClipboardCaptured(itemType: ClipContentType, previewText: String?) {
        guard isStarted, boundStore?.spriteOrbEnabled == true else { return }
        let accent: SpriteOrbMoodAccent
        if let text = previewText, TodoChecklistExtractor.hasActionableSingleTodoIntent(text) {
            accent = .amber
        } else {
            switch itemType {
            case .text:
                accent = .cobalt
            case .link:
                accent = .emerald
            case .image, .file:
                accent = .cobalt
            }
        }
        viewModel.captureAccent = accent
        viewModel.capturePulseStartTime = ProcessInfo.processInfo.systemUptime
        activateHighFrameRatePulseWindow(duration: 1.1)
        bumpInteractionWakefulness()
    }

    /// 由 ActionSparkController 同步当前智能提醒胶囊显隐，点亮精灵待命呼应环
    func setSmartSuggestionState(active: Bool, categoryKey: String?) {
        guard isStarted else { return }
        viewModel.smartSuggestionActive = active
        if active {
            switch categoryKey {
            case "todo_capture":
                viewModel.smartSuggestionAccent = .amber
            case "frequent_reuse", "security":
                viewModel.smartSuggestionAccent = .emerald
            default:
                viewModel.smartSuggestionAccent = .cobalt
            }
            wakeFromIdle()
        } else {
            scheduleIdleRestIfEligible()
        }
    }

    /// 当用户采纳提醒动作后触发一圈轻快翡翠绿成功光晕
    func triggerSuggestionAcceptedPulse() {
        guard isStarted else { return }
        viewModel.smartSuggestionActive = false
        viewModel.acceptedPulseStartTime = ProcessInfo.processInfo.systemUptime
        activateHighFrameRatePulseWindow(duration: 0.9)
        bumpInteractionWakefulness()
    }

    // MARK: - 窗口装配与显隐调度

    private func syncPreferences(from store: ClipboardStore) {
        viewModel.style = store.spriteOrbStyle
        viewModel.dockMode = store.spriteOrbDockMode
        panel?.sharingType = store.screenSharePrivacyEnabled ? .none : .readOnly
    }

    private func updatePanelVisibility() {
        guard let store = boundStore else { return }
        if !store.spriteOrbEnabled || ProcessInfo.processInfo.arguments.contains("--demo") {
            idleRestWorkItem?.cancel()
            panel?.orderOut(nil)
            return
        }
        ensurePanel()
        guard let panel else { return }
        if !panel.isVisible {
            restoreSavedOriginOnLaunch()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.enforceUnifiedActiveAppearance()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.enforceUnifiedActiveAppearance()
        }
        scheduleIdleRestIfEligible()
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let side = SpriteOrbPhysicsGeometry.panelDimension
        let rect = NSRect(origin: .zero, size: NSSize(width: side, height: side))

        let p = UnifiedActiveFloatingPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.sharingType = (boundStore?.screenSharePrivacyEnabled ?? true) ? .none : .readOnly

        let interactive = SpriteOrbInteractiveView(frame: rect)
        interactive.autoresizingMask = [.width, .height]

        let rootView = SpriteOrbRootView(model: viewModel)
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        hosting.frame = rect
        hosting.autoresizingMask = [.width, .height]
        interactive.addSubview(hosting)

        interactive.onHoverStateChanged = { [weak self] hovering, normalizedOffset in
            self?.handleHoverStateChanged(hovering: hovering, offset: normalizedOffset)
        }
        interactive.onPressChanged = { [weak self] pressed in
            self?.handlePressChanged(pressed)
        }
        interactive.onDragMoved = { [weak self] newOrigin, velocity in
            self?.handleDragMoved(to: newOrigin, velocity: velocity)
        }
        interactive.onPointerReleased = { [weak self] didDrag, finalOrigin in
            self?.handlePointerReleased(didDrag: didDrag, finalOrigin: finalOrigin)
        }
        interactive.onDragTargetedChanged = { [weak self] targeted in
            self?.handleExternalDragTargeted(targeted)
        }
        interactive.onPerformExternalDrop = { [weak self] pb in
            self?.handleExternalDrop(pasteboard: pb) ?? false
        }
        interactive.onBuildContextMenu = { [weak self] in
            self?.buildContextMenu() ?? NSMenu()
        }

        p.contentView = interactive
        self.interactiveView = interactive
        self.hostingView = hosting
        self.panel = p
    }

    private func restoreSavedOriginOnLaunch() {
        guard let panel else { return }
        let size = panel.frame.size
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let defaults = UserDefaults.standard
        if let ratioX = defaults.object(forKey: Self.posXDefaultsKey) as? Double,
           let ratioY = defaults.object(forKey: Self.posYDefaultsKey) as? Double {
            let screen = targetScreenForOrigin(panel.frame.origin)
            let resolved = SpriteOrbPhysicsGeometry.origin(
                fromRatios: CGFloat(ratioX),
                ratioY: CGFloat(ratioY),
                panelSize: size,
                visibleFrame: screen.visibleFrame,
                dockMode: viewModel.dockMode
            )
            panel.setFrameOrigin(resolved.origin)
            viewModel.dockedSide = resolved.dockedSide
        } else {
            let screen = NSScreen.main ?? screens[0]
            let initial = SpriteOrbPhysicsGeometry.defaultInitialOrigin(
                panelSize: size,
                visibleFrame: screen.visibleFrame
            )
            panel.setFrameOrigin(initial)
            viewModel.dockedSide = (viewModel.dockMode == .edgeSnap) ? .right : nil
        }
    }

    private func reanchorCurrentPosition(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        let screen = targetScreenForOrigin(panel.frame.origin)
        let resolved = SpriteOrbPhysicsGeometry.resolvedRestingOrigin(
            currentOrigin: panel.frame.origin,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame,
            dockMode: viewModel.dockMode
        )
        viewModel.dockedSide = resolved.dockedSide
        saveNormalizedOrigin(resolved.origin, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame)
        movePanel(panel, to: resolved.origin, animated: animated)
        bumpInteractionWakefulness()
    }

    private func movePanel(_ panel: NSPanel, to origin: NSPoint, animated: Bool) {
        guard animated else {
            panel.setFrameOrigin(origin)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().setFrameOrigin(origin)
        }
    }

    private func targetScreenForOrigin(_ origin: NSPoint) -> NSScreen {
        let screens = NSScreen.screens
        let side = SpriteOrbPhysicsGeometry.panelDimension
        let center = NSPoint(x: origin.x + side * 0.5, y: origin.y + side * 0.5)
        if let matched = screens.first(where: { $0.frame.contains(center) }) {
            return matched
        }
        let mouse = NSEvent.mouseLocation
        if let mouseScreen = screens.first(where: { $0.frame.contains(mouse) }) {
            return mouseScreen
        }
        return NSScreen.main ?? screens[0]
    }

    private func saveNormalizedOrigin(_ origin: NSPoint, panelSize: NSSize, visibleFrame: NSRect) {
        let ratios = SpriteOrbPhysicsGeometry.normalizedRatios(
            forOrigin: origin,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        UserDefaults.standard.set(Double(ratios.x), forKey: Self.posXDefaultsKey)
        UserDefaults.standard.set(Double(ratios.y), forKey: Self.posYDefaultsKey)
    }

    // MARK: - 交互事件协调

    private func handleHoverStateChanged(hovering: Bool, offset: CGPoint) {
        viewModel.isHovered = hovering
        viewModel.hoverOffset = hovering ? offset : .zero
        if hovering {
            wakeFromIdle()
        } else if !viewModel.isDragging {
            scheduleIdleRestIfEligible()
        }
    }

    private func handlePressChanged(_ pressed: Bool) {
        viewModel.isPressed = pressed
        if pressed {
            wakeFromIdle()
        }
    }

    private func handleDragMoved(to newOrigin: NSPoint, velocity: CGVector) {
        guard let panel else { return }
        viewModel.isDragging = true
        viewModel.dragVelocity = velocity
        viewModel.lastDragTime = ProcessInfo.processInfo.systemUptime
        panel.setFrameOrigin(newOrigin)
        wakeFromIdle()
    }

    private func handlePointerReleased(didDrag: Bool, finalOrigin: NSPoint) {
        guard let panel else { return }
        viewModel.isPressed = false
        viewModel.isDragging = false
        viewModel.lastDragTime = ProcessInfo.processInfo.systemUptime

        if !didDrag {
            TactileFeedbackEngine.shared.perform(.tabSwitch)
            if let orbCore = visibleOrbCoreScreenFrame {
                onToggleClipboardPanel?(orbCore)
            }
            activateHighFrameRatePulseWindow(duration: 0.65)
            bumpInteractionWakefulness()
            return
        }

        let screen = targetScreenForOrigin(finalOrigin)
        let resolved = SpriteOrbPhysicsGeometry.resolvedRestingOrigin(
            currentOrigin: finalOrigin,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame,
            dockMode: viewModel.dockMode
        )
        viewModel.dockedSide = resolved.dockedSide
        saveNormalizedOrigin(resolved.origin, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame)
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
        movePanel(panel, to: resolved.origin, animated: true)
        activateHighFrameRatePulseWindow(duration: 0.75)
        bumpInteractionWakefulness()
    }

    private func handleExternalDragTargeted(_ targeted: Bool) {
        if targeted && !viewModel.isDragTargeted {
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
        }
        viewModel.isDragTargeted = targeted
        if targeted {
            wakeFromIdle()
        } else {
            scheduleIdleRestIfEligible()
        }
    }

    private func handleExternalDrop(pasteboard: NSPasteboard) -> Bool {
        viewModel.isDragTargeted = false
        let ok = ClipboardStore.shared.importAndCopy(from: pasteboard, sourceLabel: "悬浮精灵")
        if ok {
            TactileFeedbackEngine.shared.perform(.magicTransform)
            viewModel.captureAccent = .emerald
            viewModel.capturePulseStartTime = ProcessInfo.processInfo.systemUptime
            activateHighFrameRatePulseWindow(duration: 1.05)
            bumpInteractionWakefulness()
        }
        return ok
    }

    // MARK: - 右键快捷菜单

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "iClip 悬浮精灵", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let toggleTitle = viewModel.isClipboardPanelOpen ? "收起剪贴板面板" : "打开 iClip 剪贴板"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(contextTogglePanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let todoItem = NSMenuItem(title: "打开待办清单", action: #selector(contextOpenTodos), keyEquivalent: "")
        todoItem.target = self
        menu.addItem(todoItem)

        menu.addItem(.separator())

        let currentStyle = boundStore?.spriteOrbStyle ?? viewModel.style
        for (idx, style) in SpriteOrbStyle.allCases.enumerated() {
            let item = NSMenuItem(
                title: "\(idx + 1) · \(style.title)",
                action: #selector(contextSelectStyle(_:)),
                keyEquivalent: ""
            )
            item.representedObject = style.rawValue
            item.state = (style == currentStyle) ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let currentDock = boundStore?.spriteOrbDockMode ?? viewModel.dockMode
        for mode in SpriteOrbDockMode.allCases {
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(contextSelectDockMode(_:)),
                keyEquivalent: ""
            )
            item.representedObject = mode.rawValue
            item.state = (mode == currentDock) ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "偏好设置...", action: #selector(contextOpenSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let hideItem = NSMenuItem(title: "隐藏悬浮精灵", action: #selector(contextHideOrb), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        return menu
    }

    @objc private func contextTogglePanel() {
        if let orbCore = visibleOrbCoreScreenFrame {
            onToggleClipboardPanel?(orbCore)
        }
    }

    @objc private func contextOpenTodos() {
        onOpenTodoList?()
    }

    @objc private func contextSelectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = SpriteOrbStyle(rawValue: raw),
              let store = boundStore else { return }
        store.spriteOrbStyle = style
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    @objc private func contextSelectDockMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = SpriteOrbDockMode(rawValue: raw),
              let store = boundStore else { return }
        store.spriteOrbDockMode = mode
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    @objc private func contextOpenSettings() {
        onOpenSettings?()
    }

    @objc private func contextHideOrb() {
        boundStore?.spriteOrbEnabled = false
    }

    // MARK: - 空闲柔隐与 120Hz 窗口控制

    private func wakeFromIdle() {
        idleRestWorkItem?.cancel()
        idleRestWorkItem = nil
        if viewModel.isIdleResting {
            withAnimation(.easeOut(duration: 0.18)) {
                viewModel.isIdleResting = false
            }
        }
    }

    private func bumpInteractionWakefulness() {
        wakeFromIdle()
        scheduleIdleRestIfEligible()
    }

    private func scheduleIdleRestIfEligible() {
        idleRestWorkItem?.cancel()
        idleRestWorkItem = nil
        guard viewModel.dockMode == .edgeSnap,
              !viewModel.isHovered,
              !viewModel.isPressed,
              !viewModel.isDragging,
              !viewModel.isDragTargeted,
              !viewModel.isClipboardPanelOpen,
              !viewModel.smartSuggestionActive else {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.viewModel.dockMode == .edgeSnap,
                      !self.viewModel.isHovered,
                      !self.viewModel.isPressed,
                      !self.viewModel.isDragging,
                      !self.viewModel.isDragTargeted,
                      !self.viewModel.isClipboardPanelOpen,
                      !self.viewModel.smartSuggestionActive else {
                    return
                }
                withAnimation(.easeInOut(duration: 0.45)) {
                    self.viewModel.isIdleResting = true
                }
            }
        }
        idleRestWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func activateHighFrameRatePulseWindow(duration: TimeInterval) {
        pulseCooldownWorkItem?.cancel()
        viewModel.pulseWindowActive = true
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.viewModel.pulseWindowActive = false
            }
        }
        pulseCooldownWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

/// 负责点击/拖拽手势仲裁、透明周边穿透与外部拖入吸收的 AppKit 交互层
private final class SpriteOrbInteractiveView: NSView {
    var onHoverStateChanged: ((Bool, CGPoint) -> Void)?
    var onPressChanged: ((Bool) -> Void)?
    var onDragMoved: ((NSPoint, CGVector) -> Void)?
    var onPointerReleased: ((Bool, NSPoint) -> Void)?
    var onDragTargetedChanged: ((Bool) -> Void)?
    var onPerformExternalDrop: ((NSPasteboard) -> Bool)?
    var onBuildContextMenu: (() -> NSMenu)?

    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownScreenPoint: NSPoint = .zero
    private var panelOriginOnMouseDown: NSPoint = .zero
    private var lastDragScreenPoint: NSPoint = .zero
    private var didExceedDragThreshold: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ClipboardStore.supportedDragTypes)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        let dist = hypot(dx, dy)
        guard dist <= SpriteOrbPhysicsGeometry.hitTestRadius else {
            return nil
        }
        // 纯视觉画布子视图无需截获事件，统一由宿主视图处理按压、拖拽、右键与外部拖入
        return self
    }

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

    override func mouseEntered(with event: NSEvent) {
        onHoverStateChanged?(true, normalizedCursorOffset(from: event))
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let insideHit = hypot(pt.x - bounds.midX, pt.y - bounds.midY) <= SpriteOrbPhysicsGeometry.hitTestRadius
        onHoverStateChanged?(insideHit, normalizedCursorOffset(from: event))
    }

    override func mouseExited(with event: NSEvent) {
        onHoverStateChanged?(false, .zero)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        mouseDownScreenPoint = NSEvent.mouseLocation
        lastDragScreenPoint = mouseDownScreenPoint
        panelOriginOnMouseDown = window.frame.origin
        didExceedDragThreshold = false
        onPressChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let currentScreen = NSEvent.mouseLocation
        let totalDx = currentScreen.x - mouseDownScreenPoint.x
        let totalDy = currentScreen.y - mouseDownScreenPoint.y
        let totalDist = hypot(totalDx, totalDy)

        if !SpriteOrbPhysicsGeometry.isClickGesture(dragDistance: totalDist) {
            didExceedDragThreshold = true
        }
        guard didExceedDragThreshold else { return }

        let stepDx = currentScreen.x - lastDragScreenPoint.x
        let stepDy = currentScreen.y - lastDragScreenPoint.y
        lastDragScreenPoint = currentScreen

        let nextOrigin = NSPoint(
            x: panelOriginOnMouseDown.x + totalDx,
            y: panelOriginOnMouseDown.y + totalDy
        )
        let velocity = CGVector(
            dx: min(max(stepDx, -24), 24),
            dy: min(max(stepDy, -24), 24)
        )
        onDragMoved?(nextOrigin, velocity)
        _ = window
    }

    override func mouseUp(with event: NSEvent) {
        let finalOrigin = window?.frame.origin ?? panelOriginOnMouseDown
        let movedBeyondClick = didExceedDragThreshold
        didExceedDragThreshold = false
        onPointerReleased?(movedBeyondClick, finalOrigin)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = onBuildContextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else {
            return []
        }
        onDragTargetedChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else {
            return []
        }
        onDragTargetedChanged?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargetedChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource == nil && ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerformExternalDrop?(sender.draggingPasteboard) ?? false
    }

    private func normalizedCursorOffset(from event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        let r = max(1, SpriteOrbPhysicsGeometry.orbVisualRadius)
        let nx = min(max((local.x - bounds.midX) / r, -1), 1)
        let ny = min(max((local.y - bounds.midY) / r, -1), 1)
        // AppKit 坐标 Y 向上，翻转后与 SwiftUI 渲染坐标系保持一致
        return CGPoint(x: nx, y: -ny)
    }
}

/// 精灵根视图：根据高/低活跃状态自动在 120Hz 与 30Hz 之间切换时间轴驱动画布
private struct SpriteOrbRootView: View {
    @ObservedObject var model: SpriteOrbViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let interval = model.needsHighFrameRate ? (1.0 / 120.0) : (1.0 / 30.0)
        TimelineView(.animation(minimumInterval: interval)) { _ in
            SpriteOrbCanvasView(model: model, colorScheme: colorScheme)
        }
        .frame(
            width: SpriteOrbPhysicsGeometry.panelDimension,
            height: SpriteOrbPhysicsGeometry.panelDimension
        )
        .opacity(model.isIdleResting ? 0.86 : 1.0)
    }
}

/// 4 套悬浮精灵矢量渲染画布（光学色散露珠 / 精密点阵表冠 / 活体有机软玉 / 无框极光丝灵）
private struct SpriteOrbCanvasView: View {
    @ObservedObject var model: SpriteOrbViewModel
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { ctx, size in
            let now = ProcessInfo.processInfo.systemUptime
            let isDark = (colorScheme == .dark)

            // 闲置贴边时的轻柔内缩偏移（始终留在安全屏内）
            let idleShiftX: CGFloat = {
                guard model.isIdleResting, model.dockMode == .edgeSnap, let side = model.dockedSide else {
                    return 0
                }
                return side == .right ? 4.0 : -4.0
            }()

            // 光标磁吸跟随与拖拽按压缩放
            let followX = model.isHovered ? model.hoverOffset.x * 2.1 : 0
            let followY = model.isHovered ? model.hoverOffset.y * 2.1 : 0
            let center = CGPoint(x: size.width * 0.5 + idleShiftX + followX, y: size.height * 0.5 + followY)

            let breath = sin(now * 2.2)
            let baseRadius = SpriteOrbPhysicsGeometry.orbVisualRadius
            let hoverScale: CGFloat = model.isDragTargeted ? 1.12 : (model.isHovered ? 1.08 : 1.0)
            let pressScale: CGFloat = model.isPressed ? 0.92 : 1.0
            let pulseAge = max(0, now - model.capturePulseStartTime)
            let captureBump: CGFloat = (pulseAge < 0.45) ? CGFloat(sin((pulseAge / 0.45) * .pi) * 0.14) : 0
            let radius = baseRadius * hoverScale * pressScale * (1.0 + 0.028 * CGFloat(breath) + captureBump)

            // 拖拽惯性形变（松手后顺滑指数回弹）
            let dragDecayAge = max(0, now - model.lastDragTime)
            let decayFactor = model.isDragging ? 1.0 : exp(-dragDecayAge * 9.5)
            let velX = model.dragVelocity.dx * CGFloat(decayFactor)
            let velY = -model.dragVelocity.dy * CGFloat(decayFactor) // AppKit Y 向上转为 SwiftUI Y 向下
            let speed = hypot(velX, velY)

            // 当前活跃心情色（智能建议优先于复制余温，再回退默认电光蓝）
            let activeAccent: SpriteOrbMoodAccent = {
                if model.smartSuggestionActive {
                    return model.smartSuggestionAccent
                }
                if pulseAge < 3.5 {
                    return model.captureAccent
                }
                return .cobalt
            }()

            // 0. 剪贴板展开态 / 智能建议呼应环（处于底层的克制氛围光圈）
            if model.isClipboardPanelOpen {
                let openRing = Path(ellipseIn: CGRect(x: center.x - radius - 4, y: center.y - radius - 4, width: (radius + 4) * 2, height: (radius + 4) * 2))
                ctx.stroke(openRing, with: .color(SpriteOrbMoodAccent.cobalt.swiftUIColor.opacity(isDark ? 0.72 : 0.58)), lineWidth: 1.5)
            } else if model.smartSuggestionActive {
                let ringPulse = 0.45 + 0.45 * sin(now * 4.2)
                let ringRadius = radius + 4.5 + CGFloat(ringPulse) * 1.8
                let ringPath = Path(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
                ctx.stroke(ringPath, with: .color(activeAccent.swiftUIColor.opacity(0.32 + 0.25 * ringPulse)), lineWidth: 1.4)
            }

            // 1. 按所选视觉风格绘制球体主体
            switch model.style {
            case .prismDew:
                drawPrismDew(ctx: &ctx, center: center, radius: radius, now: now, isDark: isDark, accent: activeAccent)
            case .matrixCrown:
                drawMatrixCrown(ctx: &ctx, center: center, radius: radius, now: now, isDark: isDark, accent: activeAccent)
            case .organicJade:
                drawOrganicJade(ctx: &ctx, center: center, radius: radius, now: now, isDark: isDark, accent: activeAccent, velX: velX, velY: velY, speed: speed)
            case .auroraRibbon:
                drawAuroraRibbon(ctx: &ctx, center: center, radius: radius, now: now, isDark: isDark, accent: activeAccent)
            }

            // 2. 外部拖入磁吸高亮环
            if model.isDragTargeted {
                let magnetR = radius + 6.5 + CGFloat(sin(now * 7.5)) * 1.2
                let magnetRect = CGRect(x: center.x - magnetR, y: center.y - magnetR, width: magnetR * 2, height: magnetR * 2)
                ctx.stroke(
                    Path(ellipseIn: magnetRect),
                    with: .color(SpriteOrbMoodAccent.emerald.swiftUIColor.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1.8, dash: [5, 3.5], dashPhase: CGFloat(now * 24))
                )
            }

            // 3. 复制内容注入涟漪（0 ~ 0.9s 双层扩展光环）
            if pulseAge < 0.9 {
                let p = CGFloat(pulseAge / 0.9)
                let eased = 1 - pow(1 - p, 3)
                let waveR = radius + eased * 12.5
                let waveOpacity = (1 - Double(p)) * 0.65
                let waveRect = CGRect(x: center.x - waveR, y: center.y - waveR, width: waveR * 2, height: waveR * 2)
                ctx.stroke(Path(ellipseIn: waveRect), with: .color(model.captureAccent.swiftUIColor.opacity(waveOpacity)), lineWidth: 1.6)
            }

            // 4. 采纳待办/智能建议后的翡翠绿成功闪徽环（0 ~ 0.72s）
            let acceptedAge = max(0, now - model.acceptedPulseStartTime)
            if acceptedAge < 0.72 {
                let p = CGFloat(acceptedAge / 0.72)
                let eased = 1 - pow(1 - p, 2.5)
                let okR = radius + 2 + eased * 13
                let okRect = CGRect(x: center.x - okR, y: center.y - okR, width: okR * 2, height: okR * 2)
                ctx.stroke(Path(ellipseIn: okRect), with: .color(SpriteOrbMoodAccent.emerald.swiftUIColor.opacity((1 - Double(p)) * 0.88)), lineWidth: 2.0)
            }
        }
    }

    // MARK: - 风格 1：光学色散露珠（Prism Dew）

    private func drawPrismDew(
        ctx: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        now: TimeInterval,
        isDark: Bool,
        accent: SpriteOrbMoodAccent
    ) {
        // 柔和底影
        let shadowRect = CGRect(x: center.x - radius, y: center.y - radius + 2.5, width: radius * 2, height: radius * 2)
        ctx.fill(
            Path(ellipseIn: shadowRect),
            with: .radialGradient(
                Gradient(colors: [Color.black.opacity(isDark ? 0.42 : 0.16), .clear]),
                center: CGPoint(x: center.x, y: center.y + 3),
                startRadius: radius * 0.3,
                endRadius: radius * 1.25
            )
        )

        let bodyRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let bodyCircle = Path(ellipseIn: bodyRect)

        // 主露珠通透底座
        let baseColors: [Color] = isDark
            ? [Color(red: 0.22, green: 0.28, blue: 0.38).opacity(0.92), Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.95)]
            : [Color.white.opacity(0.96), Color(red: 0.87, green: 0.92, blue: 0.99).opacity(0.92)]
        ctx.fill(
            bodyCircle,
            with: .linearGradient(
                Gradient(colors: baseColors),
                startPoint: CGPoint(x: center.x - radius * 0.6, y: center.y - radius * 0.8),
                endPoint: CGPoint(x: center.x + radius * 0.7, y: center.y + radius * 0.8)
            )
        )

        // 内部漂浮焦散微光核
        let causticOffset = CGPoint(
            x: model.isHovered ? model.hoverOffset.x * 5.0 : CGFloat(cos(now * 1.4)) * 2.5,
            y: model.isHovered ? model.hoverOffset.y * 5.0 : CGFloat(sin(now * 1.8)) * 2.5
        )
        let causticCenter = CGPoint(x: center.x + causticOffset.x, y: center.y + causticOffset.y)
        ctx.fill(
            bodyCircle,
            with: .radialGradient(
                Gradient(colors: [
                    accent.swiftUIColor.opacity(isDark ? 0.62 : 0.44),
                    accent.secondaryColor.opacity(isDark ? 0.26 : 0.18),
                    .clear
                ]),
                center: causticCenter,
                startRadius: 1,
                endRadius: radius * 0.92
            )
        )

        // 双色边缘色散折射环（左上冷青 -> 右下蓝紫微光）
        ctx.stroke(
            bodyCircle,
            with: .conicGradient(
                Gradient(colors: [
                    Color.white.opacity(isDark ? 0.62 : 0.92),
                    accent.secondaryColor.opacity(0.65),
                    accent.swiftUIColor.opacity(0.60),
                    Color(red: 0.85, green: 0.45, blue: 0.95).opacity(0.35),
                    Color.white.opacity(isDark ? 0.62 : 0.92)
                ]),
                center: center,
                angle: .degrees(now * 28)
            ),
            lineWidth: 1.2
        )

        // 左上镜面月牙高光
        let specRect = CGRect(x: center.x - radius * 0.58, y: center.y - radius * 0.62, width: radius * 0.72, height: radius * 0.34)
        ctx.fill(
            Path(ellipseIn: specRect),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(isDark ? 0.56 : 0.88), .clear]),
                center: CGPoint(x: specRect.midX, y: specRect.midY),
                startRadius: 0.5,
                endRadius: radius * 0.42
            )
        )

        // 核心微小剪贴符号指示点
        let coreDot = CGRect(x: causticCenter.x - 2.4, y: causticCenter.y - 2.4, width: 4.8, height: 4.8)
        ctx.fill(Path(ellipseIn: coreDot), with: .color(Color.white.opacity(0.85)))
    }

    // MARK: - 风格 2：精密点阵表冠（Matrix Crown）

    private func drawMatrixCrown(
        ctx: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        now: TimeInterval,
        isDark: Bool,
        accent: SpriteOrbMoodAccent
    ) {
        let bodyRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let bodyCircle = Path(ellipseIn: bodyRect)

        // 拉丝暗金/磨砂白工业表冠底座
        let baseGrad = isDark
            ? Gradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.17), Color(red: 0.06, green: 0.07, blue: 0.09)])
            : Gradient(colors: [Color(red: 0.98, green: 0.985, blue: 1.0), Color(red: 0.89, green: 0.91, blue: 0.95)])
        ctx.fill(
            bodyCircle,
            with: .linearGradient(
                baseGrad,
                startPoint: CGPoint(x: center.x, y: center.y - radius),
                endPoint: CGPoint(x: center.x, y: center.y + radius)
            )
        )

        // 表冠外圈微刻环
        ctx.stroke(
            bodyCircle,
            with: .color(isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)),
            lineWidth: 1.1
        )
        let innerCrownR = radius - 3.0
        ctx.stroke(
            Path(ellipseIn: CGRect(x: center.x - innerCrownR, y: center.y - innerCrownR, width: innerCrownR * 2, height: innerCrownR * 2)),
            with: .color(isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)),
            lineWidth: 0.7
        )

        // 7×7 精密微点阵（仅保留圆形内有效点）
        let spacing = radius * 0.225
        let gazeX = model.isHovered ? model.hoverOffset.x * 1.45 : CGFloat(cos(now * 1.5)) * 0.35
        let gazeY = model.isHovered ? model.hoverOffset.y * 1.45 : CGFloat(sin(now * 1.5)) * 0.35
        let pulseWave = CGFloat(sin(now * 3.4) * 0.5 + 0.5)

        for row in -3...3 {
            for col in -3...3 {
                let gridDist = hypot(Double(col), Double(row))
                guard gridDist <= 3.15 else { continue }

                let px = center.x + CGFloat(col) * spacing
                let py = center.y + CGFloat(row) * spacing
                let distToGaze = hypot(CGFloat(col) - gazeX, CGFloat(row) - gazeY)

                var intensity: Double = 0.20 + 0.14 * Double(pulseWave) * max(0, 1.0 - gridDist / 3.2)
                if model.isClipboardPanelOpen {
                    // 剪贴板展开时亮起 3 条横向记录线条轮廓
                    let isBarRow = (row == -1 || row == 0 || row == 1) && abs(col) <= 2
                    intensity = isBarRow ? 0.95 : 0.14
                } else {
                    let focusGlow = max(0, 1.0 - Double(distToGaze) / 2.2)
                    intensity = min(1.0, intensity + focusGlow * 0.78)
                }

                let dotSize = (1.6 + CGFloat(intensity) * 1.35) * (radius / SpriteOrbPhysicsGeometry.orbVisualRadius)
                let dotRect = CGRect(x: px - dotSize * 0.5, y: py - dotSize * 0.5, width: dotSize, height: dotSize)
                let dotColor: Color = intensity > 0.55
                    ? accent.swiftUIColor.opacity(intensity)
                    : (isDark ? Color.white.opacity(intensity * 0.75) : Color.black.opacity(intensity * 0.55))
                ctx.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
            }
        }
    }

    // MARK: - 风格 3：活体有机软玉（Organic Jade）

    private func drawOrganicJade(
        ctx: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        now: TimeInterval,
        isDark: Bool,
        accent: SpriteOrbMoodAccent,
        velX: CGFloat,
        velY: CGFloat,
        speed: CGFloat
    ) {
        let stretchAngle = atan2(velY, velX)
        let stretchAmt = min(0.24, speed * 0.014)
        let segments = 56
        var path = Path()

        for i in 0...segments {
            let theta = (Double(i) / Double(segments)) * Double.pi * 2.0
            let wobble =
                0.042 * sin(theta * 3.0 + now * 2.7) +
                0.028 * cos(theta * 5.0 - now * 1.9) +
                0.016 * sin(theta * 2.0 + now * 3.8)
            var localR = radius * (1.0 + CGFloat(wobble))
            if stretchAmt > 0.002 {
                let alignment = cos(theta - Double(stretchAngle))
                // 沿移动轴伸长、垂直轴保持体积微缩
                localR *= 1.0 + CGFloat(stretchAmt) * CGFloat(alignment * alignment * 1.4 - 0.4)
            }
            let x = center.x + localR * CGFloat(cos(theta))
            let y = center.y + localR * CGFloat(sin(theta))
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()

        // 次表面散射通透温润渐变
        let outerAlpha = isDark ? 0.88 : 0.92
        ctx.fill(
            path,
            with: .radialGradient(
                Gradient(colors: [
                    accent.secondaryColor.opacity(outerAlpha),
                    accent.swiftUIColor.opacity(isDark ? 0.78 : 0.85),
                    Color(red: 0.07, green: 0.14, blue: 0.25).opacity(isDark ? 0.86 : 0.35)
                ]),
                center: CGPoint(x: center.x - radius * 0.22, y: center.y - radius * 0.25),
                startRadius: 2,
                endRadius: radius * 1.15
            )
        )

        // 游动流体内核光团
        let innerCenter = CGPoint(
            x: center.x + CGFloat(cos(now * 2.1)) * radius * 0.18 + (model.isHovered ? model.hoverOffset.x * 3.2 : 0),
            y: center.y + CGFloat(sin(now * 1.7)) * radius * 0.18 + (model.isHovered ? model.hoverOffset.y * 3.2 : 0)
        )
        let innerR = radius * 0.56
        ctx.fill(
            Path(ellipseIn: CGRect(x: innerCenter.x - innerR, y: innerCenter.y - innerR, width: innerR * 2, height: innerR * 2)),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.62), accent.secondaryColor.opacity(0.22), .clear]),
                center: innerCenter,
                startRadius: 1,
                endRadius: innerR
            )
        )

        // 软玉包膜柔光边
        ctx.stroke(path, with: .color(Color.white.opacity(isDark ? 0.32 : 0.65)), lineWidth: 1.0)
    }

    // MARK: - 风格 4：无框极光丝灵（Aurora Ribbon）

    private func drawAuroraRibbon(
        ctx: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        now: TimeInterval,
        isDark: Bool,
        accent: SpriteOrbMoodAccent
    ) {
        // 无刚性实体边界，外围极轻氛围呼吸光
        let haloR = radius * 1.18
        ctx.fill(
            Path(ellipseIn: CGRect(x: center.x - haloR, y: center.y - haloR, width: haloR * 2, height: haloR * 2)),
            with: .radialGradient(
                Gradient(colors: [accent.swiftUIColor.opacity(isDark ? 0.36 : 0.24), .clear]),
                center: center,
                startRadius: 2,
                endRadius: haloR
            )
        )

        // 3 条不同倾角与频率的流光丝带弧环
        let speedBoost = model.isHovered ? 1.65 : 1.0
        let ribbons: [(tilt: Double, phase: Double, rxRatio: CGFloat, ryRatio: CGFloat, color: Color, width: CGFloat)] = [
            (0.35 + now * 0.85 * speedBoost, 0.0, 0.94, 0.54, accent.swiftUIColor, 2.2),
            (-0.65 - now * 1.10 * speedBoost, 2.1, 0.90, 0.48, accent.secondaryColor, 1.8),
            (1.25 + now * 0.65 * speedBoost, 4.2, 0.82, 0.62, SpriteOrbMoodAccent.emerald.swiftUIColor, 1.5)
        ]

        for ribbon in ribbons {
            var ribbonPath = Path()
            let steps = 48
            for i in 0...steps {
                let t = (Double(i) / Double(steps)) * Double.pi * 2.0
                let wave = 1.0 + 0.08 * sin(t * 2.0 + now * 2.4 + ribbon.phase)
                let lx = Double(radius * ribbon.rxRatio) * cos(t) * wave
                let ly = Double(radius * ribbon.ryRatio) * sin(t) * wave
                let rx = lx * cos(ribbon.tilt) - ly * sin(ribbon.tilt)
                let ry = lx * sin(ribbon.tilt) + ly * cos(ribbon.tilt)
                let pt = CGPoint(x: center.x + CGFloat(rx), y: center.y + CGFloat(ry))
                if i == 0 {
                    ribbonPath.move(to: pt)
                } else {
                    ribbonPath.addLine(to: pt)
                }
            }
            ribbonPath.closeSubpath()
            ctx.stroke(
                ribbonPath,
                with: .color(ribbon.color.opacity(isDark ? 0.86 : 0.78)),
                lineWidth: ribbon.width
            )
        }

        // 中心悬浮高透露芯
        let coreR = radius * (model.isClipboardPanelOpen ? 0.38 : 0.30)
        let coreRect = CGRect(x: center.x - coreR, y: center.y - coreR, width: coreR * 2, height: coreR * 2)
        ctx.fill(
            Path(ellipseIn: coreRect),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.95), accent.secondaryColor.opacity(0.75), .clear]),
                center: center,
                startRadius: 0.5,
                endRadius: coreR * 1.3
            )
        )
    }
}
