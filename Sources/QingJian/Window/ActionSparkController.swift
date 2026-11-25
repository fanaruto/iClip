import AppKit
import Combine
import SwiftUI

/// 确定性淡出代际守卫：防止早期气泡淡出计时器误杀后续紧接出现的 ⌘C×3 还原或 ⌃⌥C 续接复制提示胶囊
struct ActionSparkFadeCoordinator: Equatable {
    private(set) var epoch: Int = 0
    private(set) var isFadingOut: Bool = false

    @discardableResult
    mutating func beginPresentation() -> Int {
        epoch &+= 1
        isFadingOut = false
        return epoch
    }

    @discardableResult
    mutating func beginFadeSchedule() -> Int {
        epoch &+= 1
        isFadingOut = false
        return epoch
    }

    mutating func markFadeStarted(for scheduledEpoch: Int) -> Bool {
        guard scheduledEpoch == epoch else { return false }
        isFadingOut = true
        return true
    }

    mutating func invalidatePendingFade() {
        epoch &+= 1
        isFadingOut = false
    }

    func shouldCompleteFadeOut(scheduledEpoch: Int) -> Bool {
        scheduledEpoch == epoch
    }
}

/// 连按 ⌘C 触发微星标与第 3 次 ⌘C 无损还原的状态机判果
enum DoubleCopySparkOutcome: Equatable {
    case normalCopy
    case triggerCandidate
    case restoreOriginal
    case suppressReoffer
}

/// 纯值类型确定性状态机：零键盘钩子、零辅助功能权限依赖，顺应系统剪贴板物理特性实现「⌘C×2 智变 / ⌘C×3 还原」
struct DoubleCopySparkStateMachine {
    private(set) var activeHash: String? = nil
    private(set) var offeredAtUptime: TimeInterval = -100
    private(set) var activeWindowSeconds: TimeInterval = 2.2

    private(set) var restorableHash: String? = nil
    private(set) var triggeredAtUptime: TimeInterval = -100

    private(set) var suppressedHash: String? = nil
    private(set) var suppressUntilUptime: TimeInterval = -100

    mutating func clearActiveOffer() {
        activeHash = nil
        offeredAtUptime = -100
    }

    mutating func clearAll() {
        activeHash = nil
        offeredAtUptime = -100
        restorableHash = nil
        triggeredAtUptime = -100
        suppressedHash = nil
        suppressUntilUptime = -100
    }

    mutating func recordOffer(contentHash: String, at uptime: TimeInterval, windowSeconds: TimeInterval) {
        activeHash = contentHash
        offeredAtUptime = uptime
        activeWindowSeconds = max(1.0, windowSeconds)
    }

    mutating func evaluateIncomingCopy(
        contentHash: String,
        at uptime: TimeInterval,
        doubleCopyEnabled: Bool
    ) -> DoubleCopySparkOutcome {
        guard !contentHash.isEmpty else { return .normalCopy }

        if doubleCopyEnabled,
           let active = activeHash,
           active == contentHash {
            let elapsed = uptime - offeredAtUptime
            // 过滤 < 140ms 的单次复制应用内部双通道重写，仅响应真实人类二次按键
            if elapsed >= 0.14 && elapsed <= activeWindowSeconds {
                activeHash = nil
                restorableHash = contentHash
                triggeredAtUptime = uptime
                return .triggerCandidate
            }
        }

        if let restorable = restorableHash, restorable == contentHash {
            let elapsed = uptime - triggeredAtUptime
            if elapsed >= 0.12 && elapsed <= 2.4 {
                restorableHash = nil
                suppressedHash = contentHash
                suppressUntilUptime = uptime + 1.8
                return .restoreOriginal
            }
            if elapsed > 2.4 {
                restorableHash = nil
            }
        }

        if let sup = suppressedHash, sup == contentHash, uptime <= suppressUntilUptime {
            return .suppressReoffer
        }

        return .normalCopy
    }
}

/// 复制瞬间浮现于鼠标右下角的「灵动微星标（Action Spark）」：
/// - 零抢夺焦点（.nonactivatingPanel），不影响当前输入框继续打字或直接 ⌘V；
/// - 支持微星标在屏时直接「再按一次 ⌘C」零离手触发智变，按第 3 次 ⌘C 自动还原原文；
/// - 单层 macOS 26 官方 NSGlassEffectView 胶囊，零矩形阴影毛边、锁死外框零抖动。
@MainActor
final class ActionSparkController {
    static let shared = ActionSparkController()

    fileprivate enum DisplayPhase: Equatable {
        case offering(AdaptiveSparkCandidate, showDoubleCopyHint: Bool)
        case completed(message: String)
        case restored(message: String)
        case notice(symbolName: String, message: String)
    }

    @MainActor
    fileprivate final class ViewModel: ObservableObject {
        @Published var phase: DisplayPhase? = nil
        @Published var isHovered: Bool = false
        @Published var isOrbCompanion: Bool = false
    }

    private var panel: NSPanel?
    private var bleedRootRef: LiquidGlassBleedRootView?
    private var glassViewRef: NSView?
    private var hostingView: NSHostingView<ActionSparkPillView>?
    private let viewModel = ViewModel()
    private var dismissWorkItem: DispatchWorkItem?
    private var fadeCompletionWorkItem: DispatchWorkItem?
    private var activeCandidate: AdaptiveSparkCandidate?
    private var didInteractInCurrentSession: Bool = false
    private var doubleCopyMachine = DoubleCopySparkStateMachine()
    private var fadeCoordinator = ActionSparkFadeCoordinator()
    private var appActivityCancellables = Set<AnyCancellable>()

    /// 供外部查询当前主面板是否可见，避免主面板打开时重复弹出微星标
    var isMainPanelVisibleProvider: (() -> Bool)?
    /// 悬浮精灵核心屏框提供器：存在且可见时切换为紧贴精灵的两行伴生卡片
    var spriteOrbAnchorFrameProvider: (() -> NSRect?)?
    /// 智能建议卡片显示/隐藏状态变化回调（传递 active, categoryKey, actionID）
    var onSuggestionVisibilityChanged: ((Bool, String?, String?) -> Void)?
    /// 智能建议被采纳时的完成反馈回调
    var onSuggestionAccepted: ((String) -> Void)?
    /// 用户主动关闭建议卡片的收拢反馈回调
    var onSuggestionDismissed: (() -> Void)?

    private let compactSize = NSSize(width: 274, height: 38)
    private let contextualSize = NSSize(width: 318, height: 40)
    private let promotableSize = NSSize(width: 328, height: 38)
    private let orbCardSize = NSSize(width: 292, height: 82)
    private let orbPromotableCardSize = NSSize(width: 306, height: 88)
    private let orbFeedbackSize = NSSize(width: 256, height: 42)

    private init() {
        Publishers.Merge(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self, let p = self.panel, p.isVisible else { return }
            (p as? UnifiedActiveFloatingPanel)?.enforceUnifiedActiveAppearance()
        }
        .store(in: &appActivityCancellables)
    }

    private func cancelFadeTimersAndRestoreOpacity(of panel: NSPanel) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        fadeCompletionWorkItem?.cancel()
        fadeCompletionWorkItem = nil
        if panel.alphaValue < 0.99 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                panel.animator().alphaValue = 1.0
            }
        }
    }

    private func computeAnchorOrigin(for size: NSSize) -> (origin: NSPoint, placedOnLeftOfOrb: Bool) {
        if let orbFrame = spriteOrbAnchorFrameProvider?() {
            let orbCenter = NSPoint(x: orbFrame.midX, y: orbFrame.midY)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(orbCenter) }) ?? NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            let origin = SpriteOrbPhysicsGeometry.sparkAnchorOrigin(
                forOrbCoreFrame: orbFrame,
                sparkSize: size,
                visibleFrame: visible
            )
            return (origin, orbFrame.midX >= visible.midX)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var originX = mouse.x + 14
        if originX + size.width > visible.maxX - 10 {
            originX = max(visible.minX + 10, mouse.x - size.width - 14)
        }
        var originY = mouse.y - size.height - 12
        if originY < visible.minY + 10 {
            originY = min(visible.maxY - size.height - 10, mouse.y + 18)
        }
        return (NSPoint(x: originX, y: originY), false)
    }

    /// 锁屏、休眠或主面板收起时立即静默关闭光标微星标并清空内存候选
    func dismiss() {
        fadeCoordinator.invalidatePendingFade()
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        fadeCompletionWorkItem?.cancel()
        fadeCompletionWorkItem = nil
        activeCandidate = nil
        doubleCopyMachine.clearActiveOffer()
        panel?.orderOut(nil)
        onSuggestionVisibilityChanged?(false, nil, nil)
    }

    /// 在剪贴板捕获到相同哈希时优先判定是否命中「⌘C×2 原位智变」或「⌘C×3 无损还原」
    func handleIncomingCopy(contentHash: String, in store: ClipboardStore) -> DoubleCopySparkOutcome {
        let now = ProcessInfo.processInfo.systemUptime
        let outcome = doubleCopyMachine.evaluateIncomingCopy(
            contentHash: contentHash,
            at: now,
            doubleCopyEnabled: AdaptiveIntelligenceEngine.shared.doubleCopySparkEnabled
        )
        switch outcome {
        case .triggerCandidate:
            if activeCandidate != nil {
                handleAccept(promoteToAuto: false, triggeredByDoubleCopy: true, in: store)
                return .triggerCandidate
            }
            return .normalCopy

        case .restoreOriginal:
            fadeCoordinator.beginPresentation()
            activeCandidate = nil
            didInteractInCurrentSession = true
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
            let hasOrb = (spriteOrbAnchorFrameProvider?() != nil)
            let feedbackSize = hasOrb ? orbFeedbackSize : compactSize
            let cornerRadius = feedbackSize.height / 2
            viewModel.isOrbCompanion = hasOrb
            ensurePanel(size: feedbackSize, cornerRadius: cornerRadius, store: store)
            resizePanelIfNeeded(to: feedbackSize, cornerRadius: cornerRadius)
            if let panel {
                cancelFadeTimersAndRestoreOpacity(of: panel)
                if !panel.isVisible {
                    let targetOrigin = computeAnchorOrigin(for: feedbackSize).origin
                    panel.setFrameOrigin(targetOrigin)
                    panel.alphaValue = 1
                    panel.orderFrontRegardless()
                }
                (panel as? UnifiedActiveFloatingPanel)?.enforceUnifiedActiveAppearance()
            }
            withAnimation(.easeOut(duration: 0.14)) {
                viewModel.phase = .restored(message: "已还原原文 · 直接 ⌘V")
            }
            scheduleFadeOut(after: 0.85, recordPassiveTimeout: false)
            return .restoreOriginal

        case .suppressReoffer, .normalCopy:
            return outcome
        }
    }

    func presentIfAppropriate(
        for item: ClipItem,
        reuseCount: Int,
        hasRichFormatting: Bool = false,
        in store: ClipboardStore
    ) {
        guard !(isMainPanelVisibleProvider?() ?? false) else { return }
        if ProcessInfo.processInfo.arguments.contains("--demo") { return }

        guard let candidate = AdaptiveIntelligenceEngine.shared.evaluateSparkCandidate(
            for: item,
            reuseCount: reuseCount,
            minimalMode: store.minimalModeEnabled,
            hasRichFormatting: hasRichFormatting
        ) else {
            doubleCopyMachine.clearActiveOffer()
            return
        }

        present(candidate: candidate, contentHash: item.contentHash, in: store)
    }

    /// 在光标或精灵旁侧轻浮一条非抢焦液态玻璃状态胶囊（用于 ⌃⌥C 跨处续接复制等瞬时反馈）
    func presentTransientNotice(symbolName: String, message: String, duration: Double = 1.15, in store: ClipboardStore) {
        if ProcessInfo.processInfo.arguments.contains("--demo") { return }
        fadeCoordinator.beginPresentation()
        activeCandidate = nil
        didInteractInCurrentSession = true
        doubleCopyMachine.clearActiveOffer()

        let hasOrb = (spriteOrbAnchorFrameProvider?() != nil)
        let noticeSize = hasOrb ? orbFeedbackSize : compactSize
        let cornerRadius = noticeSize.height / 2
        viewModel.isOrbCompanion = hasOrb

        ensurePanel(size: noticeSize, cornerRadius: cornerRadius, store: store)
        guard let panel else { return }
        resizePanelIfNeeded(to: noticeSize, cornerRadius: cornerRadius)
        cancelFadeTimersAndRestoreOpacity(of: panel)

        let targetOrigin = computeAnchorOrigin(for: noticeSize).origin
        viewModel.phase = .notice(symbolName: symbolName, message: message)
        if !panel.isVisible {
            panel.setFrameOrigin(NSPoint(x: targetOrigin.x, y: targetOrigin.y - 4))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            (panel as? UnifiedActiveFloatingPanel)?.enforceUnifiedActiveAppearance()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(targetOrigin)
            }
        } else {
            panel.setFrameOrigin(targetOrigin)
            (panel as? UnifiedActiveFloatingPanel)?.enforceUnifiedActiveAppearance()
        }
        scheduleFadeOut(after: duration, recordPassiveTimeout: false)
    }

    func dismissImmediately() {
        fadeCoordinator.invalidatePendingFade()
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        fadeCompletionWorkItem?.cancel()
        fadeCompletionWorkItem = nil
        activeCandidate = nil
        doubleCopyMachine.clearAll()
        panel?.orderOut(nil)
        onSuggestionVisibilityChanged?(false, nil, nil)
    }

    private func present(candidate: AdaptiveSparkCandidate, contentHash: String, in store: ClipboardStore) {
        let isOrb = (spriteOrbAnchorFrameProvider?() != nil)
        let targetSize: NSSize
        if isOrb {
            targetSize = (candidate.promotableRule != nil) ? orbPromotableCardSize : orbCardSize
        } else if candidate.promotableRule != nil {
            targetSize = promotableSize
        } else if candidate.shortTitle.count > 9 {
            targetSize = contextualSize
        } else {
            targetSize = compactSize
        }
        let targetCornerRadius: CGFloat = isOrb ? 16.0 : (targetSize.height / 2)
        viewModel.isOrbCompanion = isOrb

        ensurePanel(size: targetSize, cornerRadius: targetCornerRadius, store: store)
        guard let panel else { return }

        fadeCoordinator.beginPresentation()
        cancelFadeTimersAndRestoreOpacity(of: panel)
        activeCandidate = candidate
        didInteractInCurrentSession = false
        let baseDuration = AdaptiveIntelligenceEngine.shared.sparkDurationSeconds
        let duration = isOrb ? max(4.5, baseDuration) : baseDuration
        let doubleCopyOn = AdaptiveIntelligenceEngine.shared.doubleCopySparkEnabled
        doubleCopyMachine.recordOffer(
            contentHash: contentHash,
            at: ProcessInfo.processInfo.systemUptime,
            windowSeconds: duration + 0.35
        )
        viewModel.isHovered = false
        viewModel.phase = .offering(candidate, showDoubleCopyHint: doubleCopyOn)
        onSuggestionVisibilityChanged?(true, candidate.categoryKey, candidate.actionID)

        resizePanelIfNeeded(to: targetSize, cornerRadius: targetCornerRadius)

        let anchor = computeAnchorOrigin(for: targetSize)
        let targetOrigin = anchor.origin
        let startOrigin: NSPoint = isOrb
            ? NSPoint(x: targetOrigin.x + (anchor.placedOnLeftOfOrb ? 10 : -10), y: targetOrigin.y)
            : NSPoint(x: targetOrigin.x, y: targetOrigin.y - 5)
        panel.setFrameOrigin(startOrigin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        (panel as? UnifiedActiveFloatingPanel)?.enforceUnifiedActiveAppearance()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = isOrb ? 0.22 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(targetOrigin)
        }

        scheduleAutoDismiss(after: duration)
    }

    private func resizePanelIfNeeded(to size: NSSize, cornerRadius: CGFloat) {
        guard let panel else { return }
        if panel.frame.size != size {
            panel.setContentSize(size)
            let rect = NSRect(origin: .zero, size: size)
            bleedRootRef?.frame = rect
            bleedRootRef?.cardFrame = rect
            hostingView?.frame = rect
            glassViewRef?.frame = rect
        }
        if #available(macOS 26.0, *), let glass = glassViewRef as? NSGlassEffectView {
            if abs(glass.cornerRadius - cornerRadius) > 0.2 {
                glass.cornerRadius = cornerRadius
            }
        } else if let effect = glassViewRef as? NSVisualEffectView {
            effect.maskImage = LiquidGlassSurfaceHost.continuousCornerMaskImage(size: size, radius: cornerRadius)
            effect.layer?.cornerRadius = cornerRadius
        }
        panel.invalidateShadow()
    }

    private func ensurePanel(size: NSSize, cornerRadius: CGFloat, store: ClipboardStore) {
        if let existing = panel {
            existing.sharingType = store.screenSharePrivacyEnabled ? .none : .readOnly
            return
        }
        let rect = NSRect(origin: .zero, size: size)
        let p = UnifiedActiveFloatingPanel(
            contentRect: rect,
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
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.sharingType = store.screenSharePrivacyEnabled ? .none : .readOnly

        let root = ActionSparkPillView(
            viewModel: viewModel,
            onAccept: { [weak self] in
                self?.handleAccept(promoteToAuto: false, triggeredByDoubleCopy: false, in: store)
            },
            onPromoteAndAccept: { [weak self] in
                self?.handleAccept(promoteToAuto: true, triggeredByDoubleCopy: false, in: store)
            },
            onExplicitDismiss: { [weak self] in
                self?.handleExplicitDismiss()
            },
            onHoverChanged: { [weak self] hovering in
                self?.handleHoverChanged(hovering)
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = rect
        hosting.autoresizingMask = [.width, .height]

        let bleedRoot = LiquidGlassBleedRootView(frame: rect, cardFrame: rect)
        bleedRoot.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: rect)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.tintColor = nil
            glass.contentView = hosting
            bleedRoot.addSubview(glass)
            p.contentView = bleedRoot
            self.glassViewRef = glass
        } else {
            let effect = NSVisualEffectView(frame: rect)
            effect.autoresizingMask = [.width, .height]
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = LiquidGlassSurfaceHost.continuousCornerMaskImage(size: size, radius: cornerRadius)
            effect.wantsLayer = true
            effect.layer?.cornerCurve = .continuous
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(hosting)
            bleedRoot.addSubview(effect)
            p.contentView = bleedRoot
            self.glassViewRef = effect
        }

        self.bleedRootRef = bleedRoot
        self.hostingView = hosting
        self.panel = p
    }

    private func handleHoverChanged(_ hovering: Bool) {
        let isOfferingPhase: Bool = {
            if case .offering = viewModel.phase { return true }
            return false
        }()
        if hovering {
            // 正在最后的 alpha 淡出期间（或候选已被注销但视图仍停留在 .offering），绝不复活已失效按键的胶囊
            if fadeCoordinator.isFadingOut || (activeCandidate == nil && isOfferingPhase) {
                viewModel.isHovered = false
                return
            }
            viewModel.isHovered = true
            fadeCoordinator.invalidatePendingFade()
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            fadeCompletionWorkItem?.cancel()
            fadeCompletionWorkItem = nil
            if let panel, panel.alphaValue < 0.99 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.08
                    panel.animator().alphaValue = 1.0
                }
            }
        } else {
            viewModel.isHovered = false
            if activeCandidate != nil && !didInteractInCurrentSession {
                scheduleAutoDismiss(after: 0.95)
            } else if panel?.isVisible == true && !fadeCoordinator.isFadingOut && dismissWorkItem == nil {
                scheduleFadeOut(after: 0.6, recordPassiveTimeout: false)
            }
        }
    }

    private func handleAccept(promoteToAuto: Bool, triggeredByDoubleCopy: Bool, in store: ClipboardStore) {
        guard let candidate = activeCandidate else { return }
        didInteractInCurrentSession = true
        activeCandidate = nil
        if !triggeredByDoubleCopy {
            doubleCopyMachine.clearActiveOffer()
        }
        dismissWorkItem?.cancel()

        AdaptiveIntelligenceEngine.shared.recordActionUsed(
            actionID: candidate.actionID,
            categoryKey: candidate.categoryKey,
            sourceApp: candidate.sourceApp
        )

        if promoteToAuto, let rule = candidate.promotableRule {
            AdaptiveIntelligenceEngine.shared.setAutoRule(rule, enabled: true)
            if rule == .cleanTrackingURL {
                store.autoCleanTrackingURL = true
            }
        }

        store.executeSparkCandidate(candidate)

        let doneMsg: String
        if promoteToAuto {
            doneMsg = "已开启自动处理 · 直接 ⌘V"
        } else if candidate.actionID == "todo-mark-item" || candidate.actionID == "todo-split-checklist" {
            doneMsg = "✓ 已加入待办（⌥2 查看）"
        } else if triggeredByDoubleCopy && candidate.actionID != "habit-pin-frequent" {
            doneMsg = "已智变 · ⌘V 粘贴（再 ⌘C 还原）"
        } else {
            doneMsg = "已就绪 · 直接 ⌘V 粘贴"
        }
        withAnimation(.easeOut(duration: 0.14)) {
            viewModel.phase = .completed(message: doneMsg)
        }
        onSuggestionAccepted?(candidate.categoryKey)
        scheduleFadeOut(after: triggeredByDoubleCopy ? 1.25 : 0.72, recordPassiveTimeout: false)
    }

    private func handleExplicitDismiss() {
        guard let candidate = activeCandidate else { return }
        didInteractInCurrentSession = true
        activeCandidate = nil
        doubleCopyMachine.clearActiveOffer()
        dismissWorkItem?.cancel()

        AdaptiveIntelligenceEngine.shared.recordSparkExplicitDismiss(
            actionID: candidate.actionID,
            categoryKey: candidate.categoryKey,
            sourceApp: candidate.sourceApp
        )
        if let rule = candidate.promotableRule {
            AdaptiveIntelligenceEngine.shared.declineAutoRulePromotion(rule)
        }
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
        onSuggestionDismissed?()
        scheduleFadeOut(after: 0.02, recordPassiveTimeout: false)
    }

    private func scheduleAutoDismiss(after seconds: Double) {
        scheduleFadeOut(after: seconds, recordPassiveTimeout: true)
    }

    private func scheduleFadeOut(after seconds: Double, recordPassiveTimeout: Bool) {
        dismissWorkItem?.cancel()
        fadeCompletionWorkItem?.cancel()
        fadeCompletionWorkItem = nil
        let scheduledEpoch = fadeCoordinator.beginFadeSchedule()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.fadeCoordinator.markFadeStarted(for: scheduledEpoch),
                      let panel = self.panel else {
                    return
                }
                self.dismissWorkItem = nil
                if recordPassiveTimeout, !self.didInteractInCurrentSession, let candidate = self.activeCandidate {
                    AdaptiveIntelligenceEngine.shared.recordSparkPassiveTimeout(categoryKey: candidate.categoryKey)
                }
                self.activeCandidate = nil
                self.doubleCopyMachine.clearActiveOffer()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().alphaValue = 0
                }
                let completion = DispatchWorkItem { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.fadeCoordinator.shouldCompleteFadeOut(scheduledEpoch: scheduledEpoch) else {
                            return
                        }
                        self.fadeCompletionWorkItem = nil
                        self.dismissWorkItem = nil
                        self.fadeCoordinator.invalidatePendingFade()
                        self.panel?.orderOut(nil)
                        self.onSuggestionVisibilityChanged?(false, nil, nil)
                    }
                }
                self.fadeCompletionWorkItem = completion
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.17, execute: completion)
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

private struct ActionSparkPillView: View {
    @ObservedObject var viewModel: ActionSparkController.ViewModel
    let onAccept: () -> Void
    let onPromoteAndAccept: () -> Void
    let onExplicitDismiss: () -> Void
    let onHoverChanged: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isCard = viewModel.isOrbCompanion && {
            switch viewModel.phase {
            case .offering, .completed: return true
            case .restored, .notice, .none: return false
            }
        }()
        let cornerRadius: CGFloat = isCard ? 16 : 19

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(colorScheme == .dark ? Color.black.opacity(0.46) : Color.white.opacity(0.68))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.09),
                    lineWidth: 0.65
                )

            switch viewModel.phase {
            case .offering(let candidate, let showDoubleCopyHint):
                if viewModel.isOrbCompanion {
                    orbCompanionOfferingCard(candidate: candidate, showDoubleCopyHint: showDoubleCopyHint)
                } else {
                    compactOfferingRow(candidate: candidate, showDoubleCopyHint: showDoubleCopyHint)
                }

            case .completed(let message):
                if viewModel.isOrbCompanion {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(red: 0.063, green: 0.725, blue: 0.506))
                        Text(message)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.green)
                        Text(message)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                }

            case .restored(let message):
                HStack(spacing: 7) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.orange)
                    Text(message)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)

            case .notice(let symbolName, let message):
                HStack(spacing: 7) {
                    Image(systemName: symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(message)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)

            case .none:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering in
            onHoverChanged(hovering)
        }
    }

    private func orbCompanionOfferingCard(candidate: AdaptiveSparkCandidate, showDoubleCopyHint: Bool) -> some View {
        let moodColor = orbAccentColor(for: candidate)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(moodColor)
                    .frame(width: 6.5, height: 6.5)

                Text(orbSceneHeader(for: candidate))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if showDoubleCopyHint && candidate.promotableRule == nil {
                    Text("⌘C×2")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(moodColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(moodColor.opacity(0.14)))
                }

                Spacer(minLength: 0)

                Button(action: onExplicitDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("收拢并减少此类推荐")
            }

            HStack(spacing: 8) {
                Button(action: onAccept) {
                    Text(candidate.shortTitle)
                        .font(.system(size: 12.2, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if candidate.promotableRule != nil {
                    Button(action: onPromoteAndAccept) {
                        Text("设为自动")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(moodColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4.5)
                            .background(Capsule().fill(moodColor.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .help("以后复制同类内容直接自动处理")
                }

                Button(action: onAccept) {
                    Text(orbPrimaryActionLabel(for: candidate))
                        .font(.system(size: 11.2, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(moodColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func compactOfferingRow(candidate: AdaptiveSparkCandidate, showDoubleCopyHint: Bool) -> some View {
        HStack(spacing: 5) {
            Button(action: onAccept) {
                HStack(spacing: 5.5) {
                    Image(systemName: candidate.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(Color.accentColor.opacity(0.15))
                        )

                    Text(candidate.shortTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if showDoubleCopyHint && candidate.promotableRule == nil {
                        Text("⌘C×2")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                    } else if candidate.badgeHint != nil && candidate.promotableRule == nil {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.accentColor.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showDoubleCopyHint ? "点击或直接再按一次 ⌘C 立即执行" : "点击立即执行")

            if candidate.promotableRule != nil {
                Button(action: onPromoteAndAccept) {
                    Text("设为自动")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .help("以后复制同类内容时直接自动处理")
            }

            Button(action: onExplicitDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("忽略并减少此类推荐")
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
    }

    private func orbAccentColor(for candidate: AdaptiveSparkCandidate) -> Color {
        switch candidate.categoryKey {
        case "todo_capture":
            return Color(red: 0.961, green: 0.620, blue: 0.043)
        case "frequent_reuse", "security":
            return Color(red: 0.063, green: 0.725, blue: 0.506)
        default:
            return Color.accentColor
        }
    }

    private func orbSceneHeader(for candidate: AdaptiveSparkCandidate) -> String {
        if candidate.actionID == "todo-mark-item" { return "识别到待办事项" }
        if candidate.actionID == "todo-split-checklist" { return "识别到行动清单" }
        if candidate.actionID == "habit-pin-frequent" { return "高频复用记忆" }
        if candidate.actionID == "restore-privacy-twin" { return "隐私替身可回填" }
        if candidate.actionID == "strip-rich-style" { return "已捕获富文本样式" }
        if candidate.categoryKey == "qrcode" { return "识别到图中二维码" }
        if candidate.categoryKey == "image" { return "截图处理建议" }
        if candidate.categoryKey == "security" { return "敏感信息防护" }
        if candidate.actionID.contains("url") || candidate.actionID.contains("link") {
            return "识别到可净化链接"
        }
        return candidate.badgeHint ?? "智能处理建议"
    }

    private func orbPrimaryActionLabel(for candidate: AdaptiveSparkCandidate) -> String {
        if candidate.actionID == "todo-mark-item" || candidate.actionID == "todo-split-checklist" {
            return "设为待办"
        }
        if candidate.actionID == "habit-pin-frequent" {
            return "一键收藏"
        }
        if candidate.actionID == "strip-rich-style" {
            return "转纯文本"
        }
        if candidate.actionID == "img-ocr" {
            return "提取文字"
        }
        return "立即执行"
    }
}
