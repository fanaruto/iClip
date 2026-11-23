import AppKit
import SwiftUI

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
    }

    private var panel: NSPanel?
    private var glassViewRef: NSView?
    private var hostingView: NSHostingView<ActionSparkPillView>?
    private let viewModel = ViewModel()
    private var dismissWorkItem: DispatchWorkItem?
    private var activeCandidate: AdaptiveSparkCandidate?
    private var didInteractInCurrentSession: Bool = false
    private var doubleCopyMachine = DoubleCopySparkStateMachine()

    /// 供外部查询当前主面板是否可见，避免主面板打开时重复弹出微星标
    var isMainPanelVisibleProvider: (() -> Bool)?

    private let compactSize = NSSize(width: 274, height: 38)
    private let promotableSize = NSSize(width: 328, height: 38)

    private init() {}

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
            dismissWorkItem?.cancel()
            activeCandidate = nil
            didInteractInCurrentSession = true
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
            ensurePanel(size: compactSize, store: store)
            resizePanelIfNeeded(to: compactSize)
            if let panel, !panel.isVisible {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
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

    /// 在光标右下角轻浮一条非抢焦液态玻璃状态胶囊（用于 ⌃⌥C 跨处续接复制等瞬时反馈）
    func presentTransientNotice(symbolName: String, message: String, duration: Double = 1.15, in store: ClipboardStore) {
        if ProcessInfo.processInfo.arguments.contains("--demo") { return }
        dismissWorkItem?.cancel()
        activeCandidate = nil
        didInteractInCurrentSession = true
        doubleCopyMachine.clearActiveOffer()

        ensurePanel(size: compactSize, store: store)
        guard let panel else { return }
        resizePanelIfNeeded(to: compactSize)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var originX = mouse.x + 14
        if originX + compactSize.width > visible.maxX - 10 {
            originX = max(visible.minX + 10, mouse.x - compactSize.width - 14)
        }
        var originY = mouse.y - compactSize.height - 12
        if originY < visible.minY + 10 {
            originY = min(visible.maxY - compactSize.height - 10, mouse.y + 18)
        }

        viewModel.phase = .notice(symbolName: symbolName, message: message)
        if !panel.isVisible {
            panel.setFrameOrigin(NSPoint(x: originX, y: originY - 4))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(NSPoint(x: originX, y: originY))
            }
        }
        scheduleFadeOut(after: duration, recordPassiveTimeout: false)
    }

    func dismissImmediately() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        activeCandidate = nil
        doubleCopyMachine.clearAll()
        panel?.orderOut(nil)
    }

    private func present(candidate: AdaptiveSparkCandidate, contentHash: String, in store: ClipboardStore) {
        let targetSize = (candidate.promotableRule != nil) ? promotableSize : compactSize
        ensurePanel(size: targetSize, store: store)
        guard let panel else { return }

        dismissWorkItem?.cancel()
        activeCandidate = candidate
        didInteractInCurrentSession = false
        let duration = AdaptiveIntelligenceEngine.shared.sparkDurationSeconds
        let doubleCopyOn = AdaptiveIntelligenceEngine.shared.doubleCopySparkEnabled
        doubleCopyMachine.recordOffer(
            contentHash: contentHash,
            at: ProcessInfo.processInfo.systemUptime,
            windowSeconds: duration + 0.35
        )
        viewModel.isHovered = false
        viewModel.phase = .offering(candidate, showDoubleCopyHint: doubleCopyOn)

        resizePanelIfNeeded(to: targetSize)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        // 默认紧贴光标右下角 14pt 处，不遮挡光标正前方输入行；靠近屏幕边缘自动镜像避让
        var originX = mouse.x + 14
        if originX + targetSize.width > visible.maxX - 10 {
            originX = max(visible.minX + 10, mouse.x - targetSize.width - 14)
        }
        var originY = mouse.y - targetSize.height - 12
        if originY < visible.minY + 10 {
            originY = min(visible.maxY - targetSize.height - 10, mouse.y + 18)
        }

        panel.setFrameOrigin(NSPoint(x: originX, y: originY - 5))
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(NSPoint(x: originX, y: originY))
        }

        scheduleAutoDismiss(after: duration)
    }

    private func resizePanelIfNeeded(to size: NSSize) {
        guard let panel else { return }
        if panel.frame.size != size {
            panel.setContentSize(size)
            hostingView?.frame = NSRect(origin: .zero, size: size)
            glassViewRef?.frame = NSRect(origin: .zero, size: size)
            if #available(macOS 26.0, *), let glass = glassViewRef as? NSGlassEffectView {
                glass.cornerRadius = size.height / 2
            } else {
                glassViewRef?.layer?.cornerRadius = size.height / 2
            }
        }
    }

    private func ensurePanel(size: NSSize, store: ClipboardStore) {
        guard panel == nil else { return }
        let rect = NSRect(origin: .zero, size: size)
        let p = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.isMovable = false

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

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: rect)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = size.height / 2
            glass.style = .regular
            glass.tintColor = nil
            glass.contentView = hosting
            // 严格关闭 borderless NSPanel 矩形窗口阴影，根除四角毛边
            p.hasShadow = false
            p.contentView = glass
            self.glassViewRef = glass
        } else {
            let effect = NSVisualEffectView(frame: rect)
            effect.autoresizingMask = [.width, .height]
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = LiquidGlassSurfaceHost.continuousCornerMaskImage(size: size, radius: size.height / 2)
            effect.wantsLayer = true
            effect.layer?.cornerRadius = size.height / 2
            effect.layer?.masksToBounds = true
            effect.addSubview(hosting)
            p.hasShadow = true
            p.contentView = effect
            self.glassViewRef = effect
        }

        self.hostingView = hosting
        self.panel = p
    }

    private func handleHoverChanged(_ hovering: Bool) {
        viewModel.isHovered = hovering
        if hovering {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
        } else if activeCandidate != nil && !didInteractInCurrentSession {
            scheduleAutoDismiss(after: 0.95)
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
            #if !ICLIP_EDITION_FLOW
            if rule == .cleanTrackingURL {
                store.autoCleanTrackingURL = true
            }
            #endif
        }

        store.executeSparkCandidate(candidate)

        let doneMsg: String
        if promoteToAuto {
            doneMsg = "已开启自动处理 · 直接 ⌘V"
        } else if triggeredByDoubleCopy && candidate.actionID != "habit-pin-frequent" {
            doneMsg = "已智变 · ⌘V 粘贴（再 ⌘C 还原）"
        } else {
            doneMsg = "已就绪 · 直接 ⌘V 粘贴"
        }
        withAnimation(.easeOut(duration: 0.14)) {
            viewModel.phase = .completed(message: doneMsg)
        }
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
        scheduleFadeOut(after: 0.02, recordPassiveTimeout: false)
    }

    private func scheduleAutoDismiss(after seconds: Double) {
        scheduleFadeOut(after: seconds, recordPassiveTimeout: true)
    }

    private func scheduleFadeOut(after seconds: Double, recordPassiveTimeout: Bool) {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
                    guard let self, self.activeCandidate == nil else { return }
                    self.panel?.orderOut(nil)
                }
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
        ZStack {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(colorScheme == .dark ? Color.black.opacity(0.46) : Color.white.opacity(0.68))

            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.09),
                    lineWidth: 0.65
                )

            switch viewModel.phase {
            case .offering(let candidate, let showDoubleCopyHint):
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

            case .completed(let message):
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
}
