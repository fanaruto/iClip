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
    private func liveVisibleScreenRect(for itemID: UUID) -> NSRect? {
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

// MARK: - 2. Apple TV 3D 视差高光 + 官方 Force Touch 二段压感弹簧引擎

enum PhysicalCardSurfaceKind {
    /// 标准文本/链接/文件行卡片（克制 1.15° 倾角 + 1.0 原尺寸锐利文字渲染，杜绝字体光栅化发虚）
    case standardRow
    /// 3 列正方形图片宫格砖块（Apple TV 海报级立体倾角 ±3.6°）
    case imageTile

    var maxTiltDegrees: Double {
        switch self {
        case .standardRow: return 1.15
        case .imageTile:   return 3.6
        }
    }

    var hoverLiftScale: CGFloat {
        switch self {
        case .standardRow: return 1.0
        case .imageTile:   return 1.026
        }
    }

    var pressSinkScale: CGFloat {
        switch self {
        case .standardRow: return 0.984
        case .imageTile:   return 0.962
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
/// - 实时向 `SystemQuickLookController` 注册弱引用视图以供滚动后精确屏幕坐标换算；
/// - 捕获左键阻尼下沉与 MacBook Force Touch 压感触控板 `stage >= 2` 原厂二段重按 Peek-Pop（普通长按不误弹，100% 兼容按住拖拽）。
private struct ForceTouchWindowProbe: NSViewRepresentable {
    let itemID: UUID
    let surfaceKind: PhysicalCardSurfaceKind
    let isHovered: Bool
    let trailingExclusionWidth: CGFloat
    let bottomExclusionHeight: CGFloat
    let onPointerNormUpdate: (CGPoint) -> Void
    let onPressStageChange: (Int) -> Void
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
        context.coordinator.onPointerNormUpdate = onPointerNormUpdate
        context.coordinator.onPressStageChange = onPressStageChange
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
            onPointerNormUpdate: onPointerNormUpdate,
            onPressStageChange: onPressStageChange,
            onDeepPressTrigger: onDeepPressTrigger,
            onPanelDidHideReset: onPanelDidHideReset
        )
    }

    final class Coordinator {
        var itemID: UUID
        var surfaceKind: PhysicalCardSurfaceKind
        var trailingExclusionWidth: CGFloat
        var bottomExclusionHeight: CGFloat
        var onPointerNormUpdate: (CGPoint) -> Void
        var onPressStageChange: (Int) -> Void
        var onDeepPressTrigger: () -> Void
        var onPanelDidHideReset: () -> Void

        init(
            itemID: UUID,
            surfaceKind: PhysicalCardSurfaceKind,
            trailingExclusionWidth: CGFloat,
            bottomExclusionHeight: CGFloat,
            onPointerNormUpdate: @escaping (CGPoint) -> Void,
            onPressStageChange: @escaping (Int) -> Void,
            onDeepPressTrigger: @escaping () -> Void,
            onPanelDidHideReset: @escaping () -> Void
        ) {
            self.itemID = itemID
            self.surfaceKind = surfaceKind
            self.trailingExclusionWidth = trailingExclusionWidth
            self.bottomExclusionHeight = bottomExclusionHeight
            self.onPointerNormUpdate = onPointerNormUpdate
            self.onPressStageChange = onPressStageChange
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
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .pressure, .scrollWheel]
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
            if isMouseDownInside {
                isMouseDownInside = false
                didFireDeepPress = false
                coordinator?.onPressStageChange(0)
            }
        }

        private func handleEvent(_ event: NSEvent) {
            guard let win = window, event.window === win, bounds.width > 8, bounds.height > 8 else { return }

            if event.type == .scrollWheel {
                resetPressState()
                coordinator?.onPointerNormUpdate(.zero)
                return
            }

            let localPt = convert(event.locationInWindow, from: nil)
            let inside = bounds.contains(localPt)

            switch event.type {
            case .mouseMoved:
                if inside {
                    let nx = max(-1, min(1, ((localPt.x / bounds.width) - 0.5) * 2.0))
                    let visualY = isFlipped ? localPt.y : (bounds.height - localPt.y)
                    let ny = max(-1, min(1, ((visualY / bounds.height) - 0.5) * 2.0))
                    coordinator?.onPointerNormUpdate(CGPoint(x: nx, y: ny))
                }

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
                downPointInWindow = event.locationInWindow
                coordinator?.onPressStageChange(1)

            case .pressure:
                // 原生 MacBook Force Touch 压感板二级深按（stage >= 2）清脆触发 Peek-Pop（硬件自带二段物理震感，不重复叠加 Taptic）
                if isMouseDownInside && !didFireDeepPress && event.stage >= 2 {
                    triggerDeepPop()
                }

            case .leftMouseDragged:
                guard isMouseDownInside else { return }
                let dx = hypot(event.locationInWindow.x - downPointInWindow.x, event.locationInWindow.y - downPointInWindow.y)
                if dx > 4.0 {
                    resetPressState()
                }

            case .leftMouseUp:
                resetPressState()

            default:
                break
            }
        }

        private func triggerDeepPop() {
            didFireDeepPress = true
            let currentID = coordinator?.itemID
            Task { @MainActor in
                if let currentID {
                    ForceTouchSuppressionRegistry.markDeepPopTriggered(for: currentID)
                }
                TactileFeedbackEngine.shared.playPopChimeOnly()
            }
            coordinator?.onPressStageChange(2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                self?.coordinator?.onPressStageChange(0)
            }
            coordinator?.onDeepPressTrigger()
        }

        deinit {
            teardownMonitor()
            removeHideObserver()
        }
    }
}

/// Apple TV 级 3D 视差光泽 + Force Touch 阻尼弹簧按压修饰器（单轴合成透视、支持 Reduce Motion、零 Layout 抖动）
struct AppleTVPhysicalCardModifier: ViewModifier {
    let itemID: UUID
    let surfaceKind: PhysicalCardSurfaceKind
    let isHovered: Bool
    let isSelected: Bool
    var trailingActionWidth: CGFloat = 0
    var bottomChipHeight: CGFloat = 0
    var onResetHoverFromHide: (() -> Void)? = nil
    var onDeepPressPreview: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var normPointer: CGPoint = .zero
    @State private var pressStage: Int = 0
    @State private var lastQuantizedNorm: CGPoint = .zero

    private var effectiveScale: CGFloat {
        if pressStage == 1 {
            return reduceMotion ? 0.99 : surfaceKind.pressSinkScale
        }
        if pressStage == 2 {
            return reduceMotion ? 1.0 : (surfaceKind.hoverLiftScale + 0.012)
        }
        if reduceMotion {
            return 1.0
        }
        return isHovered ? surfaceKind.hoverLiftScale : 1.0
    }

    /// 合并俯仰与偏航为单次合成旋转轴与角度，避免双次透视矩阵叠加导致文字发虚
    private var combinedTilt: (angle: Double, axisX: CGFloat, axisY: CGFloat) {
        guard !reduceMotion, isHovered, pressStage == 0 else {
            return (0, 1, 0)
        }
        let pitch = Double(-normPointer.y) * surfaceKind.maxTiltDegrees
        let yaw = Double(normPointer.x) * surfaceKind.maxTiltDegrees
        let mag = hypot(pitch, yaw)
        guard mag > 0.02 else { return (0, 1, 0) }
        return (min(mag, surfaceKind.maxTiltDegrees), CGFloat(pitch / mag), CGFloat(yaw / mag))
    }

    func body(content: Content) -> some View {
        let tilt = combinedTilt
        content
            .overlay {
                if isHovered {
                    GeometryReader { geo in
                        let w = max(1, geo.size.width)
                        let h = max(1, geo.size.height)
                        let glareX = w * (0.5 - (reduceMotion ? 0 : normPointer.x * 0.34))
                        let glareY = h * (0.5 - (reduceMotion ? 0 : normPointer.y * 0.34))
                        let radius = max(w, h) * 0.78
                        let baseAlpha: Double = pressStage == 1
                            ? 0.05
                            : (isSelected ? 0.15 : 0.11)
                        let peakAlpha = reduceMotion ? (baseAlpha * 0.5) : baseAlpha

                        RoundedRectangle(cornerRadius: surfaceKind.cornerRadius, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color.white.opacity(peakAlpha),
                                        Color.white.opacity(peakAlpha * 0.28),
                                        Color.clear
                                    ],
                                    center: UnitPoint(x: glareX / w, y: glareY / h),
                                    startRadius: 2,
                                    endRadius: radius
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: surfaceKind.cornerRadius, style: .continuous)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(isSelected ? 0.40 : 0.32),
                                                Color.white.opacity(0.04)
                                            ],
                                            startPoint: UnitPoint(
                                                x: 0.5 - (reduceMotion ? 0 : normPointer.x * 0.42),
                                                y: 0.0
                                            ),
                                            endPoint: UnitPoint(
                                                x: 0.5 + (reduceMotion ? 0 : normPointer.x * 0.42),
                                                y: 1.0
                                            )
                                        ),
                                        lineWidth: 0.75
                                    )
                            )
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
                    onPointerNormUpdate: { pt in
                        if abs(pt.x - lastQuantizedNorm.x) >= 0.05 || abs(pt.y - lastQuantizedNorm.y) >= 0.05 || pt == .zero {
                            lastQuantizedNorm = pt
                            normPointer = pt
                        }
                    },
                    onPressStageChange: { stage in
                        if pressStage != stage {
                            pressStage = stage
                        }
                    },
                    onDeepPressTrigger: {
                        onDeepPressPreview?()
                    },
                    onPanelDidHideReset: {
                        lastQuantizedNorm = .zero
                        normPointer = .zero
                        pressStage = 0
                        onResetHoverFromHide?()
                    }
                )
            )
            .scaleEffect(effectiveScale)
            .rotation3DEffect(
                .degrees(tilt.angle),
                axis: (x: tilt.axisX, y: tilt.axisY, z: 0),
                perspective: surfaceKind == .imageTile ? 0.36 : 0.25
            )
            .animation(.interpolatingSpring(mass: 0.66, stiffness: 380, damping: 26), value: effectiveScale)
            .animation(.interpolatingSpring(mass: 0.62, stiffness: 280, damping: 25), value: normPointer)
            .onChange(of: isHovered) { _, hovering in
                if !hovering {
                    lastQuantizedNorm = .zero
                    normPointer = .zero
                    pressStage = 0
                }
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
                let extraCut = max(0, reservedActionWidth - 36)
                let fadeEnd = max(0.18, min(0.98, (totalW - extraCut) / totalW))
                let fadeStart = max(0.08, fadeEnd - (24.0 / totalW))
                let maskedRightOpacity: Double = (isHovered && extraCut > 0) ? 0.0 : 1.0
                let firstLineBandHeight = min(geo.size.height, 19.0)

                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: fadeStart),
                            .init(color: .black.opacity(maskedRightOpacity), location: fadeEnd),
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
            .padding(.vertical, 2.5)
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
