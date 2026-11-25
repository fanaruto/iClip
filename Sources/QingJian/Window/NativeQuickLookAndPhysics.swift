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

    /// 键盘联动回调：方向键切换条目、复制选中、外部打开与回车直接上屏粘贴
    var onStepSelection: ((PanelNavigationDirection) -> ClipItem?)?
    var onCommitPasteFromPreview: (() -> Void)?
    var onCommitPasteRawFromPreview: (() -> Void)?
    var onCopySelectedFromPreview: (() -> Void)?
    var onOpenExternalFromPreview: (() -> Void)?
    var onFallbackPreviewItem: ((ClipItem) -> Void)?

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
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])

        if event.keyCode == 53
            || (flags.isEmpty && event.keyCode == 49)
            || (flags == .command && (event.keyCode == 16 || event.keyCode == 13)) {
            dismiss()
            return true
        }

        if flags == .command, event.keyCode == 8 {
            Task { @MainActor in
                self.onCopySelectedFromPreview?()
            }
            return true
        }

        if flags == .command, event.keyCode == 31 {
            dismiss()
            Task { @MainActor in
                self.onOpenExternalFromPreview?()
            }
            return true
        }

        if !flags.contains(.command) && !flags.contains(.control) && (event.keyCode == 36 || event.keyCode == 76) {
            let forceRaw = flags.contains(.option)
            dismiss()
            Task { @MainActor in
                if forceRaw, let rawHandler = self.onCommitPasteRawFromPreview {
                    rawHandler()
                } else {
                    self.onCommitPasteFromPreview?()
                }
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
                    self.onFallbackPreviewItem?(nextItem)
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

// MARK: - 2. 轻量化双皮肤物理弹簧引擎（原生雅致默认极速 / 立体光影克制 3D 视差）

enum PhysicalCardSurfaceKind {
    /// 标准文本/链接/文件行卡片（克制 0.85°/1.15° 光学微倾、1.012x 悬停、0.986x 轻按、1.022x 蓄力）
    case standardRow
    /// 3 列正方形图片砖块（克制 2.6°/3.0° 光学悬浮、1.028x 悬停、0.972x 轻按、1.044x 蓄力）
    case imageTile

    var maxPitchDegrees: Double {
        switch self {
        case .standardRow: return 0.85
        case .imageTile:   return 2.6
        }
    }

    var maxYawDegrees: Double {
        switch self {
        case .standardRow: return 1.15
        case .imageTile:   return 3.0
        }
    }

    var hoverLiftScale: CGFloat {
        switch self {
        case .standardRow: return 1.012
        case .imageTile:   return 1.028
        }
    }

    var pressSinkScale: CGFloat {
        switch self {
        case .standardRow: return 0.986
        case .imageTile:   return 0.972
        }
    }

    var peekChargeScale: CGFloat {
        switch self {
        case .standardRow: return 1.022
        case .imageTile:   return 1.044
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .standardRow: return 14
        case .imageTile:   return 13
        }
    }

    /// 计算当前皮肤下的 3D 合成倾角与方向轴（原生皮肤严格归零，Zero GPU Tilt）
    func effectiveTilt(
        skin: CardSkinStyle,
        isHovered: Bool,
        isScrollDamped: Bool,
        pressStage: Int,
        pressureProgress: CGFloat,
        reduceMotion: Bool,
        norm: CGPoint
    ) -> (angle: Double, axisX: CGFloat, axisY: CGFloat) {
        guard skin == .spatialGlass,
              !reduceMotion,
              isHovered,
              !isScrollDamped,
              (pressStage == 0 || pressStage == 1) else {
            return (0, 1, 0)
        }
        let damp = pressStage == 1 ? max(0.35, 1.0 - Double(pressureProgress) * 0.65) : 1.0
        let pitch = Double(-norm.y) * maxPitchDegrees * damp
        let yaw = Double(norm.x) * maxYawDegrees * damp
        let mag = hypot(pitch, yaw)
        guard mag > 0.03 else { return (0, 1, 0) }
        return (mag, CGFloat(pitch / mag), CGFloat(yaw / mag))
    }

    /// 卡片顶部镜面柔光峰值不透明度（原生皮肤为 0；立体光影皮肤悬停呈现克制高光，无斜条纹）
    static func specularPeakOpacity(
        skin: CardSkinStyle,
        isHovered: Bool,
        isSelected: Bool,
        colorScheme: ColorScheme,
        reduceMotion: Bool
    ) -> Double {
        guard skin == .spatialGlass, isHovered else { return 0 }
        let base = colorScheme == .dark
            ? (isSelected ? 0.16 : 0.13)
            : (isSelected ? 0.18 : 0.22)
        return reduceMotion ? base * 0.55 : base
    }

    /// 离散稳态 GPU 投影规格（不依赖逐帧光标坐标，彻底杜绝滑卡重绘阴影高斯模糊）
    func shadowSpec(
        skin: CardSkinStyle,
        isHovered: Bool,
        isSelected: Bool,
        colorScheme: ColorScheme
    ) -> (opacity: Double, radius: CGFloat, y: CGFloat, usesAccentColor: Bool) {
        switch self {
        case .standardRow:
            if isSelected {
                return (0.28, 6, 2, true)
            }
            if skin == .spatialGlass && isHovered {
                return (colorScheme == .dark ? 0.28 : 0.12, 9, 3.5, false)
            }
            return (0, 0, 0, false)

        case .imageTile:
            if isSelected {
                if skin == .nativeApple {
                    return colorScheme == .dark
                        ? (0.32, 6, 2, true)
                        : (0.16, 6, 2, false)
                }
                let r: CGFloat = isHovered ? 10 : 8
                let y: CGFloat = isHovered ? 3.5 : 2
                return colorScheme == .dark
                    ? (0.38, r, y, true)
                    : (0.18, r, y, false)
            }
            if isHovered {
                return (
                    skin == .spatialGlass ? (colorScheme == .dark ? 0.34 : 0.18) : 0.18,
                    skin == .spatialGlass ? 11 : 9,
                    4,
                    false
                )
            }
            return (0.05, 4, 2, false)
        }
    }
}

/// 严格位于圆角裁切内部、唯一边框之下的轻量化顶部径向镜面高光（原生皮肤透明归零，零离屏纹理与零边框压叠）
struct CardSpatialSpecularLayer: View {
    let cornerRadius: CGFloat
    let cardSkin: CardSkinStyle
    let isHovered: Bool
    let isSelected: Bool
    let pointerNorm: CGPoint

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let peak = PhysicalCardSurfaceKind.specularPeakOpacity(
            skin: cardSkin,
            isHovered: isHovered,
            isSelected: isSelected,
            colorScheme: colorScheme,
            reduceMotion: reduceMotion
        )
        let nx = (cardSkin == .spatialGlass && isHovered && !reduceMotion) ? pointerNorm.x : 0
        let ny = (cardSkin == .spatialGlass && isHovered && !reduceMotion) ? pointerNorm.y : 0

        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                RadialGradient(
                    colors: [
                        Color.white,
                        Color.white.opacity(0.28),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.5 - nx * 0.24, y: max(0.06, 0.22 - ny * 0.16)),
                    startRadius: 2,
                    endRadius: cornerRadius <= 13 ? 115 : 210
                )
            )
            .opacity(peak)
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: cardSkin)
            .allowsHitTesting(false)
    }
}

/// 全局共享指针与压感探针协调器：全应用最多挂载 1 个 Core 本地事件监视器与按需 `.mouseMoved` 监视器，
/// 彻底消除鼠标高速上下扫卡时逐卡反复向 AppKit 装拆监听器的主线程卡顿。
@MainActor
final class PanelForceTouchCoordinator {
    static let shared = PanelForceTouchCoordinator()

    private weak var activeProbe: ForceTouchWindowProbe.ProbeNSView?
    private weak var pendingUnlockProbe: ForceTouchWindowProbe.ProbeNSView?
    private var pendingUnlockRetry: (() -> Void)?
    private let trackedHoverProbes = NSHashTable<ForceTouchWindowProbe.ProbeNSView>.weakObjects()
    private var coreMonitor: Any?
    private var moveMonitor: Any?
    private var hideObserver: NSObjectProtocol?

    var hasActiveCoreMonitor: Bool { coreMonitor != nil }
    var hasActiveMoveMonitor: Bool { moveMonitor != nil }

    private init() {
        hideObserver = NotificationCenter.default.addObserver(
            forName: .iClipPanelDidHide,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePanelDidHide()
            }
        }
    }

    func setActiveProbe(_ probe: ForceTouchWindowProbe.ProbeNSView) {
        if pendingUnlockProbe === probe {
            pendingUnlockProbe = nil
            pendingUnlockRetry = nil
        }
        trackedHoverProbes.add(probe)
        if activeProbe !== probe {
            activeProbe?.resetPressState()
            activeProbe = probe
        }
        ensureCoreMonitorIfNeeded()
        syncMoveMonitor()
        if probe.coordinator?.cardSkin == .spatialGlass,
           let win = probe.window {
            probe.dispatchSpatialPointer(windowPoint: win.mouseLocationOutsideOfEventStream)
        }
    }

    func setPendingUnlockProbe(_ probe: ForceTouchWindowProbe.ProbeNSView, onRetryEnter: @escaping () -> Void) {
        pendingUnlockProbe = probe
        pendingUnlockRetry = onRetryEnter
        trackedHoverProbes.add(probe)
        syncMoveMonitor()
    }

    func clearProbe(_ probe: ForceTouchWindowProbe.ProbeNSView) {
        trackedHoverProbes.remove(probe)
        if pendingUnlockProbe === probe {
            pendingUnlockProbe = nil
            pendingUnlockRetry = nil
        }
        if activeProbe === probe {
            probe.resetPressState()
            activeProbe = nil
        }
        syncMoveMonitor()
    }

    func refreshSkinState(for probe: ForceTouchWindowProbe.ProbeNSView) {
        if activeProbe === probe {
            syncMoveMonitor()
        }
    }

    private func handlePanelDidHide() {
        pendingUnlockProbe = nil
        pendingUnlockRetry = nil
        let snapshot = trackedHoverProbes.allObjects
        trackedHoverProbes.removeAllObjects()
        for probe in snapshot {
            probe.resetHoverActiveFlag()
            probe.resetPressState()
            probe.coordinator?.onPanelDidHideReset()
        }
        activeProbe?.resetPressState()
        activeProbe = nil
        teardownMoveMonitor()
        teardownCoreMonitor()
    }

    private func ensureCoreMonitorIfNeeded() {
        guard coreMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .pressure, .scrollWheel]
        coreMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleCoreEvent(event)
            }
            return event
        }
    }

    func syncMoveMonitorIfIdle() {
        syncMoveMonitor()
    }

    private func syncMoveMonitor() {
        let needsMove = (pendingUnlockProbe != nil) || (activeProbe?.coordinator?.cardSkin == .spatialGlass)
        if needsMove {
            guard moveMonitor == nil else { return }
            moveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleMouseMoved(event)
                }
                return event
            }
        } else {
            teardownMoveMonitor()
        }
    }

    private func teardownCoreMonitor() {
        if let monitor = coreMonitor {
            NSEvent.removeMonitor(monitor)
            coreMonitor = nil
        }
    }

    private func teardownMoveMonitor() {
        if let monitor = moveMonitor {
            NSEvent.removeMonitor(monitor)
            moveMonitor = nil
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        if let pending = pendingUnlockProbe,
           let retry = pendingUnlockRetry,
           let win = pending.window,
           event.window === win {
            retry()
        }
        if let active = activeProbe,
           let win = active.window,
           event.window === win,
           active.coordinator?.cardSkin == .spatialGlass {
            active.dispatchSpatialPointer(windowPoint: event.locationInWindow)
        }
    }

    private func handleCoreEvent(_ event: NSEvent) {
        if event.type == .scrollWheel {
            activeProbe?.handleEvent(event)
            return
        }
        if event.type == .leftMouseDragged,
           let active = activeProbe,
           let win = active.window,
           event.window === win,
           active.coordinator?.cardSkin == .spatialGlass {
            active.dispatchSpatialPointer(windowPoint: event.locationInWindow)
        }
        activeProbe?.handleEvent(event)
    }
}

final class ForceTouchProbeBridge {
    weak var probe: ForceTouchWindowProbe.ProbeNSView?
}

/// 完全穿透命中测试（`hitTest -> nil`，绝不拦截 SwiftUI 点击、右键菜单、`.onDrag` 拖拽或列表滚动）的原生探针：
/// - 向 `SystemQuickLookController` 注册弱引用视图供滚动后精确屏幕坐标换算；
/// - 共享 `PanelForceTouchCoordinator` 处理触控板一段轻按与二段 Force Touch 深按弹出（零逐卡监听器装拆）。
struct ForceTouchWindowProbe: NSViewRepresentable {
    let itemID: UUID
    let surfaceKind: PhysicalCardSurfaceKind
    let cardSkin: CardSkinStyle
    let isHovered: Bool
    let trailingActionWidth: CGFloat
    let leadingExclusionWidth: CGFloat
    let bottomExclusionHeight: CGFloat
    let probeBridge: ForceTouchProbeBridge
    let onSpatialPointerNormChange: (CGPoint) -> Void
    let onPressStateChange: (Int, CGFloat) -> Void
    let onScrollReset: () -> Void
    let onDeepPressTrigger: () -> Void
    let onPanelDidHideReset: () -> Void

    func makeNSView(context: Context) -> ProbeNSView {
        let v = ProbeNSView()
        v.coordinator = context.coordinator
        probeBridge.probe = v
        return v
    }

    func updateNSView(_ nsView: ProbeNSView, context: Context) {
        let oldID = context.coordinator.itemID
        let skinChanged = context.coordinator.cardSkin != cardSkin
        context.coordinator.itemID = itemID
        context.coordinator.surfaceKind = surfaceKind
        context.coordinator.cardSkin = cardSkin
        context.coordinator.trailingExclusionWidth = trailingActionWidth
        context.coordinator.leadingExclusionWidth = leadingExclusionWidth
        context.coordinator.bottomExclusionHeight = bottomExclusionHeight
        context.coordinator.onSpatialPointerNormChange = onSpatialPointerNormChange
        context.coordinator.onPressStateChange = onPressStateChange
        context.coordinator.onScrollReset = onScrollReset
        context.coordinator.onDeepPressTrigger = onDeepPressTrigger
        context.coordinator.onPanelDidHideReset = onPanelDidHideReset
        probeBridge.probe = nsView
        if oldID != itemID {
            SystemQuickLookController.shared.unregisterProbeView(nsView, for: oldID)
            if nsView.window != nil {
                SystemQuickLookController.shared.registerProbeView(nsView, for: itemID, window: nsView.window)
            }
        }
        nsView.setHoverMonitoring(active: isHovered)
        if skinChanged {
            PanelForceTouchCoordinator.shared.refreshSkinState(for: nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            itemID: itemID,
            surfaceKind: surfaceKind,
            cardSkin: cardSkin,
            trailingExclusionWidth: trailingActionWidth,
            leadingExclusionWidth: leadingExclusionWidth,
            bottomExclusionHeight: bottomExclusionHeight,
            onSpatialPointerNormChange: onSpatialPointerNormChange,
            onPressStateChange: onPressStateChange,
            onScrollReset: onScrollReset,
            onDeepPressTrigger: onDeepPressTrigger,
            onPanelDidHideReset: onPanelDidHideReset
        )
    }

    final class Coordinator {
        var itemID: UUID
        var surfaceKind: PhysicalCardSurfaceKind
        var cardSkin: CardSkinStyle
        var trailingExclusionWidth: CGFloat
        var leadingExclusionWidth: CGFloat
        var bottomExclusionHeight: CGFloat
        var onSpatialPointerNormChange: (CGPoint) -> Void
        var onPressStateChange: (Int, CGFloat) -> Void
        var onScrollReset: () -> Void
        var onDeepPressTrigger: () -> Void
        var onPanelDidHideReset: () -> Void

        init(
            itemID: UUID,
            surfaceKind: PhysicalCardSurfaceKind,
            cardSkin: CardSkinStyle,
            trailingExclusionWidth: CGFloat,
            leadingExclusionWidth: CGFloat,
            bottomExclusionHeight: CGFloat,
            onSpatialPointerNormChange: @escaping (CGPoint) -> Void,
            onPressStateChange: @escaping (Int, CGFloat) -> Void,
            onScrollReset: @escaping () -> Void,
            onDeepPressTrigger: @escaping () -> Void,
            onPanelDidHideReset: @escaping () -> Void
        ) {
            self.itemID = itemID
            self.surfaceKind = surfaceKind
            self.cardSkin = cardSkin
            self.trailingExclusionWidth = trailingExclusionWidth
            self.leadingExclusionWidth = leadingExclusionWidth
            self.bottomExclusionHeight = bottomExclusionHeight
            self.onSpatialPointerNormChange = onSpatialPointerNormChange
            self.onPressStateChange = onPressStateChange
            self.onScrollReset = onScrollReset
            self.onDeepPressTrigger = onDeepPressTrigger
            self.onPanelDidHideReset = onPanelDidHideReset
        }
    }

    final class ProbeNSView: NSView {
        weak var coordinator: Coordinator?
        private var isMouseDownInside = false
        private var didFireDeepPress = false
        private var isHoverActive = false
        private var downPointInWindow: NSPoint = .zero
        private var lastReportedProgress: CGFloat = 0
        private var maxStageTransition: CGFloat = 0
        private var deepPopResetEpoch: UInt64 = 0
        private var lastDispatchedSpatialNorm: CGPoint = .zero

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let win = window, let id = coordinator?.itemID {
                SystemQuickLookController.shared.registerProbeView(self, for: id, window: win)
            } else {
                isHoverActive = false
                if let id = coordinator?.itemID {
                    SystemQuickLookController.shared.unregisterProbeView(self, for: id)
                }
                PanelForceTouchCoordinator.shared.clearProbe(self)
            }
        }

        func resetHoverActiveFlag() {
            isHoverActive = false
        }

        func setHoverMonitoring(active: Bool) {
            guard active != isHoverActive else { return }
            isHoverActive = active
            if active {
                if let win = window, let id = coordinator?.itemID {
                    SystemQuickLookController.shared.registerProbeView(self, for: id, window: win)
                }
                PanelForceTouchCoordinator.shared.setActiveProbe(self)
            } else {
                PanelForceTouchCoordinator.shared.clearProbe(self)
            }
        }

        func resetPressState() {
            deepPopResetEpoch &+= 1
            lastDispatchedSpatialNorm = .zero
            if isMouseDownInside || lastReportedProgress != 0 || maxStageTransition != 0 {
                isMouseDownInside = false
                didFireDeepPress = false
                lastReportedProgress = 0
                maxStageTransition = 0
                coordinator?.onPressStateChange(0, 0)
            }
        }

        func dispatchSpatialPointer(windowPoint: NSPoint) {
            guard bounds.width > 8, bounds.height > 8 else { return }
            let localPt = convert(windowPoint, from: nil)
            let rawY = isFlipped ? localPt.y : (bounds.height - localPt.y)
            let nx = max(-1, min(1, ((localPt.x / bounds.width) - 0.5) * 2.0))
            let ny = max(-1, min(1, ((rawY / bounds.height) - 0.5) * 2.0))
            if abs(nx - lastDispatchedSpatialNorm.x) >= 0.08 || abs(ny - lastDispatchedSpatialNorm.y) >= 0.08 {
                let next = CGPoint(x: nx, y: ny)
                lastDispatchedSpatialNorm = next
                coordinator?.onSpatialPointerNormChange(next)
            }
        }

        func handleEvent(_ event: NSEvent) {
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
                let leadW = coordinator?.leadingExclusionWidth ?? 0
                let inLeadingControlZone = !isTile && leadW > 0 && localPt.x <= leadW && visualY <= 56

                guard !inTrailingActionZone && !inBottomChipZone && !inLeadingControlZone else { return }

                deepPopResetEpoch &+= 1
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
                    if coordinator?.cardSkin == .spatialGlass {
                        let progress = max(0, min(1, max(CGFloat(event.pressure), CGFloat(event.stageTransition))))
                        if abs(progress - lastReportedProgress) >= 0.08 || progress == 0 || progress >= 0.95 {
                            lastReportedProgress = progress
                            coordinator?.onPressStateChange(1, progress)
                        }
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
            deepPopResetEpoch &+= 1
            let epoch = deepPopResetEpoch
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
                guard let self, self.deepPopResetEpoch == epoch else { return }
                self.lastReportedProgress = 0
                self.coordinator?.onPressStateChange(0, 0)
            }
            coordinator?.onDeepPressTrigger()
        }

        deinit {
            Task { @MainActor in
                PanelForceTouchCoordinator.shared.syncMoveMonitorIfIdle()
            }
        }
    }
}

/// 轻量双皮肤卡片物理引擎修饰器（原生雅致默认零 3D / 零逐帧刷新；立体光影使用纯 GPU 单轴倾角与静态稳态投影，零第二边框）
struct AppleTVPhysicalCardModifier: ViewModifier {
    let itemID: UUID
    let surfaceKind: PhysicalCardSurfaceKind
    var cardSkin: CardSkinStyle = .nativeApple
    let isHovered: Bool
    let isSelected: Bool
    /// 若调用方需共享外部归一化偏移（如图片 Tile 的 Z 轴视差），可传入外部 `pointerNorm`
    var pointerNorm: CGPoint? = nil
    var trailingActionWidth: CGFloat = 0
    var leadingExclusionWidth: CGFloat = 0
    var bottomExclusionHeight: CGFloat = 0
    var onHoverEnterSelect: (() -> Bool)? = nil
    var onHoverEnded: (() -> Void)? = nil
    var onResetHoverFromHide: (() -> Void)? = nil
    var onPointerNormChange: ((CGPoint) -> Void)? = nil
    var onDeepPressActiveChanged: ((Bool) -> Void)? = nil
    var onDeepPressPreview: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// 滚动防抖递增代数，避免连续滚动中旧延迟任务误复位 scrollDamped
    @State private var scrollDebounceEpoch: Int = 0
    @State private var internalPointerNorm: CGPoint = .zero
    @State private var pressStage: Int = 0
    @State private var pressureProgress: CGFloat = 0
    @State private var scrollDamped: Bool = false
    @State private var probeBridge = ForceTouchProbeBridge()

    private var activeNorm: CGPoint {
        (cardSkin == .spatialGlass && isHovered && !scrollDamped && pressStage != 2)
            ? (pointerNorm ?? internalPointerNorm)
            : .zero
    }

    private var effectiveScale: CGFloat {
        if pressStage == 1 {
            if reduceMotion {
                return 0.99
            }
            if cardSkin == .nativeApple {
                return surfaceKind.pressSinkScale
            }
            let chargeCurve = pow(pressureProgress, 1.25)
            return surfaceKind.pressSinkScale + (surfaceKind.peekChargeScale - surfaceKind.pressSinkScale) * chargeCurve
        }
        if pressStage == 2 {
            return reduceMotion ? 1.0 : (surfaceKind.peekChargeScale + 0.010)
        }
        if reduceMotion {
            return 1.0
        }
        return isHovered ? surfaceKind.hoverLiftScale : 1.0
    }

    func body(content: Content) -> some View {
        let tilt = surfaceKind.effectiveTilt(
            skin: cardSkin,
            isHovered: isHovered,
            isScrollDamped: scrollDamped,
            pressStage: pressStage,
            pressureProgress: pressureProgress,
            reduceMotion: reduceMotion,
            norm: activeNorm
        )
        let shadow = surfaceKind.shadowSpec(
            skin: cardSkin,
            isHovered: isHovered,
            isSelected: isSelected,
            colorScheme: colorScheme
        )

        content
            .background(
                ForceTouchWindowProbe(
                    itemID: itemID,
                    surfaceKind: surfaceKind,
                    cardSkin: cardSkin,
                    isHovered: isHovered,
                    trailingActionWidth: trailingActionWidth,
                    leadingExclusionWidth: leadingExclusionWidth,
                    bottomExclusionHeight: bottomExclusionHeight,
                    probeBridge: probeBridge,
                    onSpatialPointerNormChange: { next in
                        if pointerNorm != nil {
                            onPointerNormChange?(next)
                        } else if internalPointerNorm != next {
                            internalPointerNorm = next
                        }
                    },
                    onPressStateChange: { stage, progress in
                        let prevStage = pressStage
                        if pressStage != stage {
                            pressStage = stage
                        }
                        if stage == 2 {
                            if internalPointerNorm != .zero {
                                internalPointerNorm = .zero
                            }
                            onPointerNormChange?(.zero)
                            if prevStage != 2 {
                                onDeepPressActiveChanged?(true)
                            }
                        } else if prevStage == 2 {
                            onDeepPressActiveChanged?(false)
                        }
                        if cardSkin == .spatialGlass {
                            if abs(pressureProgress - progress) >= 0.06 || progress == 0 || progress == 1 {
                                pressureProgress = progress
                            }
                        } else if pressureProgress != 0 {
                            pressureProgress = 0
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
                        onPointerNormChange?(.zero)
                        onDeepPressActiveChanged?(false)
                        onHoverEnded?()
                        onResetHoverFromHide?()
                    }
                )
            )
            .shadow(
                color: shadow.usesAccentColor
                    ? Color(nsColor: .controlAccentColor).opacity(shadow.opacity)
                    : Color.black.opacity(shadow.opacity),
                radius: shadow.radius,
                x: 0,
                y: shadow.y
            )
            .scaleEffect(effectiveScale)
            .rotation3DEffect(
                .degrees(tilt.angle),
                axis: (x: tilt.axisX, y: tilt.axisY, z: 0),
                perspective: 0.78
            )
            .animation(.easeOut(duration: 0.13), value: effectiveScale)
            .animation(.easeOut(duration: 0.14), value: tilt.angle)
            .animation(.interpolatingSpring(mass: 0.52, stiffness: 420, damping: 26), value: pressStage)
            .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.86), value: activeNorm)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: cardSkin)
            .onChange(of: isHovered) { _, hovering in
                if !hovering {
                    pressStage = 0
                    pressureProgress = 0
                    scrollDamped = false
                    internalPointerNorm = .zero
                    onPointerNormChange?(.zero)
                    onDeepPressActiveChanged?(false)
                }
            }
            .onChange(of: cardSkin) { _, newSkin in
                if newSkin == .nativeApple {
                    pressureProgress = 0
                    if internalPointerNorm != .zero {
                        internalPointerNorm = .zero
                    }
                    onPointerNormChange?(.zero)
                }
            }
            .onHover { hovering in
                if hovering {
                    let allowed = onHoverEnterSelect?() ?? true
                    if allowed {
                        if let p = probeBridge.probe {
                            PanelForceTouchCoordinator.shared.setActiveProbe(p)
                        }
                    } else if let p = probeBridge.probe {
                        PanelForceTouchCoordinator.shared.setPendingUnlockProbe(p) {
                            let unlocked = onHoverEnterSelect?() ?? true
                            if unlocked, let probe = probeBridge.probe {
                                PanelForceTouchCoordinator.shared.setActiveProbe(probe)
                            }
                        }
                    }
                } else {
                    if let p = probeBridge.probe {
                        PanelForceTouchCoordinator.shared.clearProbe(p)
                    }
                    if internalPointerNorm != .zero {
                        internalPointerNorm = .zero
                    }
                    onPointerNormChange?(.zero)
                    onHoverEnded?()
                }
            }
    }
}

// MARK: - 3. 长文本与右上角胶囊按钮 100% 零重叠 + 零身份重建重影 + 无 GeometryReader 零二阶段布局开销渐隐遮罩

extension View {
    /// 始终挂载恒定无 GeometryReader 遮罩结构（零二阶段布局重排 + 零视图重建闪烁）：
    /// 仅在悬停展示操作浮岛时对首行右侧 `reservedActionWidth` 区域做 24pt 线性羽化渐隐，第 2 行完整保留不切字。
    func hoverActionSafeTextMask(isHovered: Bool, reservedActionWidth: CGFloat) -> some View {
        let maskedRightOpacity: Double = (isHovered && reservedActionWidth > 0) ? 0.0 : 1.0
        let solidRightW = max(0, reservedActionWidth)
        let fadeSpanW: CGFloat = 24
        return self.mask(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(
                        colors: [.black, Color.black.opacity(maskedRightOpacity)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: fadeSpanW)
                    if solidRightW > 0 {
                        Color.black.opacity(maskedRightOpacity)
                            .frame(width: solidRightW)
                    }
                }
                .frame(height: 19.5)

                Color.black
                    .frame(minHeight: 0, maxHeight: .infinity)
            }
        }
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
