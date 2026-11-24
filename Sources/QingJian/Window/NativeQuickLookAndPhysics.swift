import AppKit
import SwiftUI
import Quartz

extension Notification.Name {
    static let iClipPanelDidHide = Notification.Name("com.qingjian.iclip.panelDidHide")
}

// MARK: - 1. 官方系统级大屏独立预览控制器（QLPreviewPanel + 实时视口坐标缩放 + 投屏隐私同步 + 临时缓存即焚）

final class EphemeralQLItem: NSObject, QLPreviewItem {
    let itemURL: URL
    let itemTitle: String

    init(url: URL, title: String) {
        self.itemURL = url
        self.itemTitle = title
        super.init()
    }

    var previewItemURL: URL? { itemURL }
    var previewItemTitle: String? { itemTitle }
}

/// 记录最近一次 Force Touch 二级重按触发，抑制紧随其后的松手单击误改写剪贴板
@MainActor
enum ForceTouchSuppressionRegistry {
    private static var suppressedItemID: UUID?
    private static var deadlineUptime: TimeInterval = 0

    static func markDeepPopTriggered(for itemID: UUID) {
        suppressedItemID = itemID
        deadlineUptime = ProcessInfo.processInfo.systemUptime + 0.85
    }

    static func consumeSuppressionIfNeeded(for itemID: UUID) -> Bool {
        guard suppressedItemID == itemID else { return false }
        suppressedItemID = nil
        return ProcessInfo.processInfo.systemUptime <= deadlineUptime
    }
}

/// 驱动 macOS 原厂 `QLPreviewPanel` 在 `420×560` 面板之外大画幅独立预览图片与本地文件：
/// - 实时查询卡片当前可见屏幕坐标（含滚动后位置与视口裁剪），支持英雄飞出放大与原路缩回；
/// - 同步宿主窗口 `sharingType`（投屏/录屏隐身护盾）与 `hidesOnDeactivate = false`（非激活零失焦悬浮兼容）；
/// - 加密 Vault 图片解密至 `0700` 防软链且排除备份的会话目录，启动/关闭/切换/面板收起/锁屏/休眠/退出全链路即焚。
final class SystemQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = SystemQuickLookController()

    private final class WeakViewBox {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private var currentPreviewItem: EphemeralQLItem?
    private(set) var currentClipID: UUID?
    private var currentTransitionImage: NSImage?
    private weak var hostWindow: NSWindow?
    private var probeViews: [UUID: WeakViewBox] = [:]
    private var ephemeralFilesToScrub: Set<URL> = []

    /// 键盘联动回调：方向键切换条目、回车直接上屏粘贴
    var onStepSelection: ((PanelNavigationDirection) -> ClipItem?)?
    var onCommitPasteFromPreview: (() -> Void)?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePanelWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        // 锁屏与屏幕休眠时立即关闭预览并彻底抹除明文临时文件
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSecurityLockOrSleep(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSecurityLockOrSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSecurityLockOrSleep(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
    }

    /// 启动或退出时清理任何异常残留的 `.ql-ephemeral` 目录
    static func wipeAllStaleEphemeralFiles(appSupportURL: URL) {
        let dir = appSupportURL.appendingPathComponent(".ql-ephemeral", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    func registerProbeView(_ view: NSView, for itemID: UUID, window: NSWindow?) {
        probeViews[itemID] = WeakViewBox(view)
        if let window {
            hostWindow = window
        }
        if probeViews.count > 160 {
            probeViews = probeViews.filter { $0.value.view?.window != nil }
        }
    }

    func unregisterProbeView(_ view: NSView, for itemID: UUID) {
        if probeViews[itemID]?.view === view {
            probeViews.removeValue(forKey: itemID)
        }
    }

    var isVisible: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else {
            return false
        }
        return panel.isVisible
    }

    var visiblePanelScreenFrame: NSRect? {
        guard isVisible, let panel = QLPreviewPanel.shared() else { return nil }
        return panel.frame
    }

    /// 实时同步投屏/录屏隐身状态至已打开的 `QLPreviewPanel`
    func syncSharingType(_ sharingType: NSWindow.SharingType) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let qlPanel = QLPreviewPanel.shared() else {
            return
        }
        qlPanel.sharingType = sharingType
    }

    /// 判断条目是否适合使用系统官方大屏 `QLPreviewPanel` 独立预览
    static func supportsNativeLargePreview(_ item: ClipItem) -> Bool {
        switch item.type {
        case .image:
            return true
        case .file:
            guard let first = item.filePaths?.first, !first.isEmpty else { return false }
            if first.hasPrefix("/Volumes/") { return false }
            return FileManager.default.isReadableFile(atPath: first)
        case .text, .link:
            return false
        }
    }

    @MainActor
    @discardableResult
    func presentOrToggle(
        for item: ClipItem,
        in store: ClipboardStore,
        hostWindow: NSWindow?,
        playPopSound: Bool = false
    ) -> Bool {
        if let hostWindow {
            self.hostWindow = hostWindow
        }
        if isVisible && currentClipID == item.id {
            dismiss()
            return true
        }
        return presentOrUpdate(for: item, in: store, hostWindow: hostWindow, playPopSound: playPopSound)
    }

    @MainActor
    @discardableResult
    func presentOrUpdate(
        for item: ClipItem,
        in store: ClipboardStore,
        hostWindow: NSWindow? = nil,
        playPopSound: Bool = false
    ) -> Bool {
        if let hostWindow {
            self.hostWindow = hostWindow
        }
        guard let materialized = materializePreviewTarget(for: item, in: store) else {
            return false
        }
        scrubEphemeralFiles(keeping: materialized.isEphemeral ? materialized.url : nil)
        if materialized.isEphemeral {
            ephemeralFilesToScrub.insert(materialized.url)
        }

        currentClipID = item.id
        currentPreviewItem = EphemeralQLItem(url: materialized.url, title: materialized.title)
        currentTransitionImage = materialized.transitionImage

        guard let qlPanel = QLPreviewPanel.shared() else { return false }
        qlPanel.hidesOnDeactivate = false
        qlPanel.dataSource = self
        qlPanel.delegate = self

        if let host = self.hostWindow {
            let targetLevel = max(host.level.rawValue + 1, NSWindow.Level.floating.rawValue)
            qlPanel.level = NSWindow.Level(rawValue: targetLevel)
            qlPanel.sharingType = host.sharingType
        } else {
            qlPanel.level = .floating
            qlPanel.sharingType = store.screenSharePrivacyEnabled ? .none : .readOnly
        }

        qlPanel.reloadData()
        qlPanel.refreshCurrentPreviewItem()
        if !qlPanel.isVisible {
            if playPopSound {
                TactileFeedbackEngine.shared.playPopChimeOnly()
            }
            if NSApp.isActive {
                qlPanel.makeKeyAndOrderFront(nil)
            } else {
                qlPanel.orderFrontRegardless()
            }
        }
        return true
    }

    func dismiss() {
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let qlPanel = QLPreviewPanel.shared(),
           qlPanel.isVisible {
            qlPanel.orderOut(nil)
        }
        cleanupAllSessionState(removeDirectory: false)
    }

    func dismissAndPurge(appSupportURL: URL) {
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let qlPanel = QLPreviewPanel.shared(),
           qlPanel.isVisible {
            qlPanel.orderOut(nil)
        }
        cleanupAllSessionState(removeDirectory: true)
        Self.wipeAllStaleEphemeralFiles(appSupportURL: appSupportURL)
    }

    func attachControl(to panel: QLPreviewPanel) {
        panel.hidesOnDeactivate = false
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func detachControl(from panel: QLPreviewPanel) {
        if panel.dataSource === self {
            panel.dataSource = nil
        }
        if panel.delegate === self {
            panel.delegate = nil
        }
        if !panel.isVisible {
            cleanupAllSessionState(removeDirectory: false)
        }
    }

    @objc private func handlePanelWillClose(_ note: Notification) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let qlPanel = QLPreviewPanel.shared(),
              note.object as AnyObject? === qlPanel else {
            return
        }
        cleanupAllSessionState(removeDirectory: false)
    }

    @objc private func handleSecurityLockOrSleep(_ note: Notification) {
        dismiss()
    }

    private func cleanupAllSessionState(removeDirectory: Bool) {
        let trackedDirs = Set(ephemeralFilesToScrub.map { $0.deletingLastPathComponent() })
        currentPreviewItem = nil
        currentClipID = nil
        currentTransitionImage = nil
        scrubEphemeralFiles(keeping: nil)
        if removeDirectory {
            let fm = FileManager.default
            for dir in trackedDirs {
                try? fm.removeItem(at: dir)
            }
        }
    }

    /// 实时计算当前卡片在屏幕上的可见矩形；若已滚出列表视口则返回 `.zero`（由系统优雅退化为中心淡入）
    func liveVisibleScreenRect(for itemID: UUID) -> NSRect? {
        guard let view = probeViews[itemID]?.view,
              let win = view.window,
              view.bounds.width > 4,
              view.bounds.height > 4 else {
            return nil
        }
        var rectInWin = view.convert(view.bounds, to: nil)
        if let scrollView = view.enclosingScrollView {
            let clipInWin = scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
            rectInWin = rectInWin.intersection(clipInWin)
            if rectInWin.isNull || rectInWin.width < 8 || rectInWin.height < 8 {
                return .zero
            }
        }
        let screenRect = win.convertToScreen(rectInWin)
        return (screenRect.width > 4 && screenRect.height > 4) ? screenRect : .zero
    }

    // MARK: - QLPreviewPanelDataSource & Delegate

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentPreviewItem == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        currentPreviewItem
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        if let id = currentClipID, let liveRect = liveVisibleScreenRect(for: id) {
            return liveRect
        }
        return .zero
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        transitionImageFor item: (any QLPreviewItem)!,
        contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        currentTransitionImage
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53
            || (flags.isEmpty && event.keyCode == 49)
            || (flags == .command && (event.keyCode == 16 || event.keyCode == 13)) {
            dismiss()
            return true
        }

        if flags.isEmpty && (event.keyCode == 36 || event.keyCode == 76) {
            dismiss()
            Task { @MainActor in
                self.onCommitPasteFromPreview?()
            }
            return true
        }

        if flags.isEmpty, [123, 124, 125, 126].contains(event.keyCode) {
            let dir: PanelNavigationDirection
            switch event.keyCode {
            case 126: dir = .up
            case 125: dir = .down
            case 123: dir = .left
            default:  dir = .right
            }
            Task { @MainActor in
                guard let nextItem = self.onStepSelection?(dir) else { return }
                if Self.supportsNativeLargePreview(nextItem) {
                    _ = self.presentOrUpdate(for: nextItem, in: ClipboardStore.shared)
                } else {
                    self.dismiss()
                }
            }
            return true
        }

        return false
    }

    // MARK: - 安全解密物化与无痕擦除

    @MainActor
    private func materializePreviewTarget(
        for item: ClipItem,
        in store: ClipboardStore
    ) -> (url: URL, title: String, transitionImage: NSImage?, isEphemeral: Bool)? {
        switch item.type {
        case .image:
            guard let vaultURL = store.imageURL(for: item),
                  let pngData = LocalVaultCrypto.readDecryptedImageData(at: vaultURL) else {
                return nil
            }
            var dir = store.appSupportURL.appendingPathComponent(".ql-ephemeral", isDirectory: true)
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: dir.path),
               (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                return nil
            }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? dir.setResourceValues(rv)

            let previewFile = dir.appendingPathComponent("iClip-Preview-\(UUID().uuidString.prefix(12)).png")
            do {
                try LocalVaultCrypto.writeProtectedFile(pngData, to: previewFile)
            } catch {
                return nil
            }

            let dimsText: String = {
                if let w = item.imageWidth, let h = item.imageHeight {
                    return "\(w) × \(h)"
                }
                return "高清原图"
            }()
            let alias = item.customAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (alias?.isEmpty == false)
                ? "\(alias!) · \(dimsText)"
                : "\(item.sourceAppName ?? "iClip 图片") · \(dimsText)"
            let thumb = store.cachedThumbnail(for: item) ?? NSImage(data: pngData)
            return (previewFile, title, thumb, true)

        case .file:
            guard let firstPath = item.filePaths?.first,
                  !firstPath.isEmpty,
                  !firstPath.hasPrefix("/Volumes/"),
                  FileManager.default.isReadableFile(atPath: firstPath) else {
                return nil
            }
            let url = URL(fileURLWithPath: firstPath)
            let title = url.lastPathComponent
            let icon = store.fileIcon(for: item)
            return (url, title, icon, false)

        case .text, .link:
            return nil
        }
    }

    private func scrubEphemeralFiles(keeping keepURL: URL?) {
        let fm = FileManager.default
        for url in ephemeralFilesToScrub where url != keepURL {
            try? fm.removeItem(at: url)
        }
        if let keepURL, ephemeralFilesToScrub.contains(keepURL) {
            ephemeralFilesToScrub = [keepURL]
        } else {
            ephemeralFilesToScrub.removeAll()
        }
    }
}

// MARK: - 2. Apple TV 3D 视差卡片 + 触控板原厂一段/二段式 Force Touch 物理弹簧引擎

enum PhysicalCardSurfaceKind {
    /// 标准文本/链接/文件行卡片（显性 3D 浮起 1.018 + 俯仰 4.8° / 偏航 3.2°，一段加压至满蓄力膨起至 1.042）
    case standardRow
    /// 3 列正方形图片海报砖块（Apple TV 原厂级立体浮起 1.045 + 俯仰/偏航 8.5°，一段加压蓄力至 1.078）
    case imageTile

    var maxPitchDegrees: Double {
        switch self {
        case .standardRow: return 4.8
        case .imageTile:   return 8.5
        }
    }

    var maxYawDegrees: Double {
        switch self {
        case .standardRow: return 3.2
        case .imageTile:   return 8.5
        }
    }

    var hoverLiftScale: CGFloat {
        switch self {
        case .standardRow: return 1.018
        case .imageTile:   return 1.045
        }
    }

    var pressSinkScale: CGFloat {
        switch self {
        case .standardRow: return 0.976
        case .imageTile:   return 0.952
        }
    }

    var peekChargeScale: CGFloat {
        switch self {
        case .standardRow: return 1.042
        case .imageTile:   return 1.078
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .standardRow: return 14
        case .imageTile:   return 13
        }
    }
}

/// 完全穿透命中测试（`hitTest -> nil`，绝不拦截 SwiftUI 点击、右键菜单、`.onDrag` 拖拽或列表滚动）的原生探针：
/// - 向 `SystemQuickLookController` 注册弱引用视图供滚动后精确屏幕坐标换算；
/// - 配置 `NSPressureConfiguration(.primaryDeepClick)` 解锁触控板一段轻按 + `stageTransition` 连续蓄力 + 二段深按（Stage 2）弹出！
private struct ForceTouchWindowProbe: NSViewRepresentable {
    let itemID: UUID
    let surfaceKind: PhysicalCardSurfaceKind
    let isHovered: Bool
    let trailingExclusionWidth: CGFloat
    let bottomExclusionHeight: CGFloat
    let onPressStateChange: (Int, CGFloat) -> Void
    let onScrollReset: () -> Void
    let onDeepPressTrigger: () -> Void
    let onPanelDidHideReset: () -> Void

    func makeNSView(context: Context) -> ProbeNSView {
        let v = ProbeNSView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ nsView: ProbeNSView, context: Context) {
        let oldID = context.coordinator.itemID
        context.coordinator.itemID = itemID
        context.coordinator.surfaceKind = surfaceKind
        context.coordinator.trailingExclusionWidth = trailingExclusionWidth
        context.coordinator.bottomExclusionHeight = bottomExclusionHeight
        context.coordinator.onPressStateChange = onPressStateChange
        context.coordinator.onScrollReset = onScrollReset
        context.coordinator.onDeepPressTrigger = onDeepPressTrigger
        context.coordinator.onPanelDidHideReset = onPanelDidHideReset
        if oldID != itemID {
            SystemQuickLookController.shared.unregisterProbeView(nsView, for: oldID)
            if nsView.window != nil {
                SystemQuickLookController.shared.registerProbeView(nsView, for: itemID, window: nsView.window)
            }
        }
        nsView.setHoverMonitoring(active: isHovered)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            itemID: itemID,
            surfaceKind: surfaceKind,
            trailingExclusionWidth: trailingExclusionWidth,
            bottomExclusionHeight: bottomExclusionHeight,
            onPressStateChange: onPressStateChange,
            onScrollReset: onScrollReset,
            onDeepPressTrigger: onDeepPressTrigger,
            onPanelDidHideReset: onPanelDidHideReset
        )
    }

    final class Coordinator {
        var itemID: UUID
        var surfaceKind: PhysicalCardSurfaceKind
        var trailingExclusionWidth: CGFloat
        var bottomExclusionHeight: CGFloat
        var onPressStateChange: (Int, CGFloat) -> Void
        var onScrollReset: () -> Void
        var onDeepPressTrigger: () -> Void
        var onPanelDidHideReset: () -> Void

        init(
            itemID: UUID,
            surfaceKind: PhysicalCardSurfaceKind,
            trailingExclusionWidth: CGFloat,
            bottomExclusionHeight: CGFloat,
            onPressStateChange: @escaping (Int, CGFloat) -> Void,
            onScrollReset: @escaping () -> Void,
            onDeepPressTrigger: @escaping () -> Void,
            onPanelDidHideReset: @escaping () -> Void
        ) {
            self.itemID = itemID
            self.surfaceKind = surfaceKind
            self.trailingExclusionWidth = trailingExclusionWidth
            self.bottomExclusionHeight = bottomExclusionHeight
            self.onPressStateChange = onPressStateChange
            self.onScrollReset = onScrollReset
            self.onDeepPressTrigger = onDeepPressTrigger
            self.onPanelDidHideReset = onPanelDidHideReset
        }
    }

    final class ProbeNSView: NSView {
        weak var coordinator: Coordinator?
        private var localMonitor: Any?
        private var hideObserver: NSObjectProtocol?
        private var isMouseDownInside = false
        private var didFireDeepPress = false
        private var downPointInWindow: NSPoint = .zero
        private var lastReportedProgress: CGFloat = 0
        private var maxStageTransition: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let win = window, let id = coordinator?.itemID {
                SystemQuickLookController.shared.registerProbeView(self, for: id, window: win)
                installHideObserverIfNeeded()
            } else {
                if let id = coordinator?.itemID {
                    SystemQuickLookController.shared.unregisterProbeView(self, for: id)
                }
                teardownMonitor()
                removeHideObserver()
            }
        }

        private func installHideObserverIfNeeded() {
            guard hideObserver == nil else { return }
            hideObserver = NotificationCenter.default.addObserver(
                forName: .iClipPanelDidHide,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.resetPressState()
                self.teardownMonitor()
                self.coordinator?.onPanelDidHideReset()
            }
        }

        private func removeHideObserver() {
            if let obs = hideObserver {
                NotificationCenter.default.removeObserver(obs)
                hideObserver = nil
            }
        }

        func setHoverMonitoring(active: Bool) {
            if active {
                if let win = window, let id = coordinator?.itemID {
                    SystemQuickLookController.shared.registerProbeView(self, for: id, window: win)
                }
                installMonitorIfNeeded()
            } else {
                resetPressState()
                teardownMonitor()
            }
        }

        private func installMonitorIfNeeded() {
            guard localMonitor == nil else { return }
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .pressure, .scrollWheel]
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleEvent(event)
                return event
            }
        }

        private func teardownMonitor() {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
        }

        private func resetPressState() {
            if isMouseDownInside || lastReportedProgress != 0 || maxStageTransition != 0 {
                isMouseDownInside = false
                didFireDeepPress = false
                lastReportedProgress = 0
                maxStageTransition = 0
                coordinator?.onPressStateChange(0, 0)
            }
        }

        private func handleEvent(_ event: NSEvent) {
            guard let win = window, event.window === win, bounds.width > 8, bounds.height > 8 else { return }

            if event.type == .scrollWheel {
                resetPressState()
                coordinator?.onScrollReset()
                return
            }

            let localPt = convert(event.locationInWindow, from: nil)
            let inside = bounds.contains(localPt)

            switch event.type {
            case .leftMouseDown:
                // 排除 Control+左键唤起上下文菜单场景
                guard inside, !event.modifierFlags.contains(.control) else { return }
                let visualY = isFlipped ? localPt.y : (bounds.height - localPt.y)
                let trailW = coordinator?.trailingExclusionWidth ?? 0
                let botH = coordinator?.bottomExclusionHeight ?? 0
                let isTile = (coordinator?.surfaceKind == .imageTile)

                let inTrailingActionZone = trailW > 0
                    && localPt.x >= (bounds.width - trailW)
                    && visualY <= (isTile ? 30 : 32)
                let inBottomChipZone = botH > 0
                    && visualY >= (bounds.height - botH)
                let inLeadingControlZone = !isTile && localPt.x <= 48 && visualY <= 52

                guard !inTrailingActionZone && !inBottomChipZone && !inLeadingControlZone else { return }

                isMouseDownInside = true
                didFireDeepPress = false
                lastReportedProgress = 0
                maxStageTransition = 0
                downPointInWindow = event.locationInWindow
                coordinator?.onPressStateChange(1, 0)

            case .pressure:
                guard isMouseDownInside, !didFireDeepPress else { return }
                if event.stage >= 2 {
                    triggerDeepPop()
                } else if event.stage == 1 {
                    maxStageTransition = max(maxStageTransition, CGFloat(event.stageTransition))
                    // 优先融合连续 pressure 与 stageTransition，让一段轻按后持续加压的每克力度都实时驱动卡片蓄力胀大
                    let progress = max(0, min(1, max(CGFloat(event.pressure), CGFloat(event.stageTransition))))
                    if abs(progress - lastReportedProgress) >= 0.025 || progress == 0 || progress >= 0.95 {
                        lastReportedProgress = progress
                        coordinator?.onPressStateChange(1, progress)
                    }
                } else if event.stage == 0 {
                    lastReportedProgress = 0
                    coordinator?.onPressStateChange(1, 0)
                }

            case .leftMouseDragged:
                guard isMouseDownInside else { return }
                let dx = hypot(event.locationInWindow.x - downPointInWindow.x, event.locationInWindow.y - downPointInWindow.y)
                if dx > 4.0 {
                    resetPressState()
                }

            case .leftMouseUp:
                // 若用户在卡片内一段加压深入（stageTransition ≥ 0.48）后松手取消，仍同步拦截当次松手单击防误贴；拖离卡片外则不再误伤后续点击
                if isMouseDownInside && inside && !didFireDeepPress && maxStageTransition >= 0.48,
                   let currentID = coordinator?.itemID {
                    MainActor.assumeIsolated {
                        ForceTouchSuppressionRegistry.markDeepPopTriggered(for: currentID)
                    }
                }
                resetPressState()

            default:
                break
            }
        }

        private func triggerDeepPop() {
            didFireDeepPress = true
            lastReportedProgress = 1.0
            let currentID = coordinator?.itemID
            Task { @MainActor in
                if let currentID {
                    ForceTouchSuppressionRegistry.markDeepPopTriggered(for: currentID)
                }
                TactileFeedbackEngine.shared.playPopChimeOnly()
            }
            coordinator?.onPressStateChange(2, 1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                self?.lastReportedProgress = 0
                self?.coordinator?.onPressStateChange(0, 0)
            }
            coordinator?.onDeepPressTrigger()
        }

        deinit {
            teardownMonitor()
            removeHideObserver()
        }
    }
}

/// Apple TV 原厂级 3D 视差卡片 + 触控板一段连续蓄力 / 二段 Force Touch 弹出修饰器（纯 GPU 复合层渲染，零外框抖动）
struct AppleTVPhysicalCardModifier: ViewModifier {
    let itemID: UUID
    let surfaceKind: PhysicalCardSurfaceKind
    let isHovered: Bool
    let isSelected: Bool
    /// 若调用方需共享外部归一化偏移（如图片 Tile 的 Z 轴视差），可传入外部 `pointerNorm`；为 `nil` 时由修饰器内部接管 120Hz 指针追踪，避免卡片宿主视图逐帧重算 `body`
    var pointerNorm: CGPoint? = nil
    var trailingActionWidth: CGFloat = 0
    var bottomChipHeight: CGFloat = 0
    var onHoverEnterSelect: (() -> Bool)? = nil
    var onHoverEnded: (() -> Void)? = nil
    var onResetHoverFromHide: (() -> Void)? = nil
    var onDeepPressPreview: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// 滚动防抖递增代数，避免连续滚动中旧延迟任务误复位 scrollDamped
    @State private var scrollDebounceEpoch: Int = 0
    @State private var internalPointerNorm: CGPoint = .zero
    @State private var surfaceSize: CGSize = CGSize(width: 392, height: 68)
    @State private var pressStage: Int = 0
    @State private var pressureProgress: CGFloat = 0
    @State private var scrollDamped: Bool = false

    private var activeNorm: CGPoint {
        (isHovered && !scrollDamped) ? (pointerNorm ?? internalPointerNorm) : .zero
    }

    private var effectiveScale: CGFloat {
        if pressStage == 1 {
            if reduceMotion {
                return 0.99
            }
            // 一段轻按先阻尼下沉；持续重压读取触控板连续压力蓄力膨起至 `peekChargeScale`
            let chargeCurve = pow(pressureProgress, 1.25)
            return surfaceKind.pressSinkScale + (surfaceKind.peekChargeScale - surfaceKind.pressSinkScale) * chargeCurve
        }
        if pressStage == 2 {
            return reduceMotion ? 1.0 : (surfaceKind.peekChargeScale + 0.014)
        }
        if reduceMotion {
            return 1.0
        }
        return isHovered ? surfaceKind.hoverLiftScale : 1.0
    }

    /// 合并俯仰与偏航为单次合成旋转轴与角度（光标所在角落微沉下按，对角微微翘起迎向光源）
    private var combinedTilt: (angle: Double, axisX: CGFloat, axisY: CGFloat) {
        guard !reduceMotion, isHovered, !scrollDamped, (pressStage == 0 || pressStage == 1) else {
            return (0, 1, 0)
        }
        let damp = pressStage == 1 ? max(0.35, 1.0 - Double(pressureProgress) * 0.65) : 1.0
        let pitch = Double(-activeNorm.y) * surfaceKind.maxPitchDegrees * damp
        let yaw = Double(activeNorm.x) * surfaceKind.maxYawDegrees * damp
        let mag = hypot(pitch, yaw)
        guard mag > 0.03 else { return (0, 1, 0) }
        return (mag, CGFloat(pitch / mag), CGFloat(yaw / mag))
    }

    private var dynamicShadowColor: Color {
        if isHovered {
            if isSelected && surfaceKind == .imageTile {
                return Color(nsColor: .controlAccentColor).opacity(pressStage == 1 ? 0.56 : 0.44)
            }
            let extra = (pressStage == 1) ? Double(pressureProgress) * 0.14 : 0
            return Color.black.opacity((colorScheme == .dark ? 0.36 : 0.18) + extra)
        }
        if surfaceKind == .imageTile {
            return isSelected
                ? Color(nsColor: .controlAccentColor).opacity(0.32)
                : Color.black.opacity(0.05)
        }
        return Color.clear
    }

    private var dynamicShadowRadius: CGFloat {
        if isHovered {
            if pressStage == 1 && pressureProgress > 0.05 {
                return 14 + pressureProgress * 10
            }
            return surfaceKind == .imageTile ? 14 : 11
        }
        if surfaceKind == .imageTile {
            return isSelected ? 6 : 4
        }
        return 0
    }

    private var dynamicShadowOffset: CGSize {
        if !isHovered {
            return surfaceKind == .imageTile ? CGSize(width: 0, height: 2) : .zero
        }
        guard !reduceMotion else {
            return CGSize(width: 0, height: surfaceKind == .imageTile ? 4 : 2)
        }
        let magX: CGFloat = (surfaceKind == .imageTile ? -10 : -7) * activeNorm.x
        let baseY: CGFloat = (pressStage == 1) ? (5 + pressureProgress * 8) : (surfaceKind == .imageTile ? 7 : 5.5)
        let magY: CGFloat = baseY - (surfaceKind == .imageTile ? 5 : 3.5) * activeNorm.y
        return CGSize(width: magX, height: magY)
    }

    func body(content: Content) -> some View {
        let tilt = combinedTilt
        let transformed = content
            .overlay {
                if isHovered || (pressStage == 1 && pressureProgress > 0.04) {
                    GeometryReader { geo in
                        let w = max(1, geo.size.width)
                        let h = max(1, geo.size.height)
                        let nx = reduceMotion ? 0 : activeNorm.x
                        let ny = reduceMotion ? 0 : activeNorm.y
                        // 统一物理光源：光斑与折射亮缘同位于斜倾翘起的对侧高坡，背光阴面随按压下沉侧自然落影，绝不自相矛盾
                        let glareX = w * (0.5 - nx * 0.36)
                        let glareY = h * (0.5 - ny * 0.36)
                        let radius = max(w, h) * 0.85

                        let darkPeak = isSelected ? 0.28 : 0.22
                        let lightPeak = isSelected ? 0.32 : 0.42
                        let rawPeak = (colorScheme == .dark ? darkPeak : lightPeak)
                        let finalPeak = (reduceMotion ? rawPeak * 0.5 : rawPeak) * (pressStage == 1 ? Double(1.0 + pressureProgress * 0.3) : 1.0)

                        ZStack {
                            // 1) 浅色模式下于迎光翘起侧提亮、按压下沉侧微铺冷灰蓝，确保曲面立体感一眼可辨
                            if colorScheme == .light {
                                RoundedRectangle(cornerRadius: surfaceKind.cornerRadius, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.16),
                                                Color.clear,
                                                Color(red: 0.14, green: 0.22, blue: 0.38).opacity(0.07)
                                            ],
                                            startPoint: UnitPoint(x: 0.5 - nx * 0.45, y: 0.5 - ny * 0.45),
                                            endPoint: UnitPoint(x: 0.5 + nx * 0.45, y: 0.5 + ny * 0.45)
                                        )
                                    )
                            }

                            // 2) Apple TV 流动宽幅径向镜面光斑
                            RoundedRectangle(cornerRadius: surfaceKind.cornerRadius, style: .continuous)
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            Color.white.opacity(finalPeak),
                                            Color.white.opacity(finalPeak * 0.32),
                                            Color.clear
                                        ],
                                        center: UnitPoint(x: glareX / w, y: glareY / h),
                                        startRadius: 2,
                                        endRadius: radius
                                    )
                                )

                            // 3) 斜 45° 细柔玻璃扫光带
                            if !reduceMotion {
                                RoundedRectangle(cornerRadius: surfaceKind.cornerRadius, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            stops: [
                                                .init(color: .clear, location: max(0.0, 0.26 - nx * 0.18)),
                                                .init(color: Color.white.opacity(colorScheme == .dark ? 0.12 : 0.22), location: 0.50 - nx * 0.18),
                                                .init(color: .clear, location: min(1.0, 0.74 - nx * 0.18))
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }

                            // 4) 统一光源方向折射高光棱边（迎光翘起侧晶透高亮，按压下沉侧柔和收暗）
                            RoundedRectangle(cornerRadius: surfaceKind.cornerRadius, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(colorScheme == .dark ? 0.58 : 0.88),
                                            Color.white.opacity(colorScheme == .dark ? 0.06 : 0.12)
                                        ],
                                        startPoint: UnitPoint(x: 0.5 - nx * 0.46, y: 0.5 - ny * 0.46),
                                        endPoint: UnitPoint(x: 0.5 + nx * 0.46, y: 0.5 + ny * 0.46)
                                    ),
                                    lineWidth: 1.0
                                )

                            if pressStage == 1 && pressureProgress > 0.04 {
                                RoundedRectangle(cornerRadius: surfaceKind.cornerRadius, style: .continuous)
                                    .strokeBorder(
                                        Color(nsColor: .controlAccentColor).opacity(0.28 + Double(pressureProgress) * 0.68),
                                        lineWidth: 1.1 + pressureProgress * 1.5
                                    )
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .background(
                ForceTouchWindowProbe(
                    itemID: itemID,
                    surfaceKind: surfaceKind,
                    isHovered: isHovered,
                    trailingExclusionWidth: trailingActionWidth,
                    bottomExclusionHeight: bottomChipHeight,
                    onPressStateChange: { stage, progress in
                        if pressStage != stage {
                            pressStage = stage
                        }
                        if abs(pressureProgress - progress) >= 0.02 || progress == 0 || progress == 1 {
                            pressureProgress = progress
                        }
                    },
                    onScrollReset: {
                        scrollDebounceEpoch &+= 1
                        let token = scrollDebounceEpoch
                        scrollDamped = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            if scrollDebounceEpoch == token {
                                scrollDamped = false
                            }
                        }
                    },
                    onDeepPressTrigger: {
                        onDeepPressPreview?()
                    },
                    onPanelDidHideReset: {
                        pressStage = 0
                        pressureProgress = 0
                        scrollDamped = false
                        internalPointerNorm = .zero
                        onHoverEnded?()
                        onResetHoverFromHide?()
                    }
                )
            )
            .shadow(
                color: dynamicShadowColor,
                radius: dynamicShadowRadius,
                x: dynamicShadowOffset.width,
                y: dynamicShadowOffset.height
            )
            .scaleEffect(effectiveScale)
            .rotation3DEffect(
                .degrees(tilt.angle),
                axis: (x: tilt.axisX, y: tilt.axisY, z: 0),
                perspective: 0.44
            )
            .animation(.interpolatingSpring(mass: 0.58, stiffness: 360, damping: 24), value: effectiveScale)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.84), value: activeNorm)
            .onChange(of: isHovered) { _, hovering in
                if !hovering {
                    pressStage = 0
                    pressureProgress = 0
                    scrollDamped = false
                    internalPointerNorm = .zero
                }
            }

        attachInternalHoverIfNeeded(transformed)
    }

    @ViewBuilder
    private func attachInternalHoverIfNeeded<V: View>(_ view: V) -> some View {
        if pointerNorm == nil {
            view
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { surfaceSize = geo.size }
                            .onChange(of: geo.size) { _, newSize in surfaceSize = newSize }
                    }
                }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let loc):
                        let allowed: Bool
                        if !isHovered || !isSelected {
                            allowed = onHoverEnterSelect?() ?? true
                        } else {
                            allowed = true
                        }
                        if allowed {
                            let w = max(1, surfaceSize.width)
                            let h = max(1, surfaceSize.height)
                            let nx = max(-1, min(1, ((loc.x / w) - 0.5) * 2.0))
                            let ny = max(-1, min(1, ((loc.y / h) - 0.5) * 2.0))
                            if abs(nx - internalPointerNorm.x) >= 0.03 || abs(ny - internalPointerNorm.y) >= 0.03 {
                                internalPointerNorm = CGPoint(x: nx, y: ny)
                            }
                        }
                    case .ended:
                        if internalPointerNorm != .zero {
                            internalPointerNorm = .zero
                        }
                        onHoverEnded?()
                    }
                }
        } else {
            view
        }
    }
}

// MARK: - 3. 长文本与右上角胶囊按钮 100% 零重叠 + 零身份重建重影 + 零切半字形的渐隐遮罩

extension View {
    /// 始终挂载恒定遮罩结构（避免 `if/else` 切换引发 Text 视图重建闪烁）：
    /// 悬停时仅对首行右侧按钮托盘覆盖区（高度精确收束于首行 `19pt`，落在两行文字行距空白处）做丝滑渐隐，第 2 行完整保留不切字。
    func hoverActionSafeTextMask(isHovered: Bool, reservedActionWidth: CGFloat) -> some View {
        self.mask(
            GeometryReader { geo in
                let totalW = max(1, geo.size.width)
                let stops = ClipCardLayoutMetrics.hoverActionMaskStops(
                    totalWidth: totalW,
                    reservedActionWidth: reservedActionWidth
                )
                let maskedRightOpacity: Double = (isHovered && reservedActionWidth > 0) ? 0.0 : 1.0
                let firstLineBandHeight = min(geo.size.height, 19.5)

                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: stops.fadeStart),
                            .init(color: .black.opacity(maskedRightOpacity), location: stops.fadeEnd),
                            .init(color: .black.opacity(maskedRightOpacity), location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: firstLineBandHeight)

                    if geo.size.height > firstLineBandHeight {
                        Rectangle()
                            .fill(Color.black)
                    }
                }
            }
        )
    }

    /// 为卡片右上角操作圆钮组包裹温润液态毛玻璃浮岛胶囊托盘，彻底隔绝底层文字笔画干扰
    func floatingActionIslandBackdrop(isSelected: Bool, colorScheme: ColorScheme) -> some View {
        self
            .padding(.horizontal, 4.5)
            .padding(.vertical, 2.0)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isSelected
                            ? Color.black.opacity(0.24)
                            : (colorScheme == .dark
                                ? Color(white: 0.15).opacity(0.92)
                                : Color.white.opacity(0.94))
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.white.opacity(0.26)
                            : (colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.07)),
                        lineWidth: 0.65
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08),
                radius: 5,
                y: 1.5
            )
    }
}
