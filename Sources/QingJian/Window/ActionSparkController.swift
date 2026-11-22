import AppKit
import SwiftUI

/// 复制瞬间浮现于鼠标右下角的「灵动微星标（Action Spark）」：
/// - 零抢夺焦点（.nonactivatingPanel），不影响当前输入框继续打字或直接 ⌘V；
/// - 单层 macOS 26 官方 NSGlassEffectView 胶囊，零矩形阴影毛边、锁死外框零抖动；
/// - 点击即转换写入剪贴板并强化个人习惯权重，支持连续使用后一键晋升「自动契约」，点 × 自动习得退避。
@MainActor
final class ActionSparkController {
    static let shared = ActionSparkController()

    fileprivate enum DisplayPhase: Equatable {
        case offering(AdaptiveSparkCandidate)
        case completed(message: String)
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

    /// 供外部查询当前主面板是否可见，避免主面板打开时重复弹出微星标
    var isMainPanelVisibleProvider: (() -> Bool)?

    private let compactSize = NSSize(width: 244, height: 38)
    private let promotableSize = NSSize(width: 304, height: 38)

    private init() {}

    func presentIfAppropriate(for item: ClipItem, reuseCount: Int, in store: ClipboardStore) {
        guard !(isMainPanelVisibleProvider?() ?? false) else { return }
        // 演示自动编排模式下不额外插入微星标
        if ProcessInfo.processInfo.arguments.contains("--demo") { return }

        guard let candidate = AdaptiveIntelligenceEngine.shared.evaluateSparkCandidate(
            for: item,
            reuseCount: reuseCount,
            minimalMode: store.minimalModeEnabled
        ) else {
            return
        }

        present(candidate: candidate, in: store)
    }

    func dismissImmediately() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        activeCandidate = nil
        panel?.orderOut(nil)
    }

    private func present(candidate: AdaptiveSparkCandidate, in store: ClipboardStore) {
        let targetSize = (candidate.promotableRule != nil) ? promotableSize : compactSize
        ensurePanel(size: targetSize, store: store)
        guard let panel else { return }

        dismissWorkItem?.cancel()
        activeCandidate = candidate
        didInteractInCurrentSession = false
        viewModel.isHovered = false
        viewModel.phase = .offering(candidate)

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

        scheduleAutoDismiss(after: AdaptiveIntelligenceEngine.shared.sparkDurationSeconds)
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
                self?.handleAccept(promoteToAuto: false, in: store)
            },
            onPromoteAndAccept: { [weak self] in
                self?.handleAccept(promoteToAuto: true, in: store)
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

    private func handleAccept(promoteToAuto: Bool, in store: ClipboardStore) {
        guard let candidate = activeCandidate else { return }
        didInteractInCurrentSession = true
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

        let doneMsg = promoteToAuto ? "已开启自动处理 · 直接 ⌘V" : "已就绪 · 直接 ⌘V 粘贴"
        withAnimation(.easeOut(duration: 0.14)) {
            viewModel.phase = .completed(message: doneMsg)
        }
        scheduleFadeOut(after: 0.72, recordPassiveTimeout: false)
    }

    private func handleExplicitDismiss() {
        guard let candidate = activeCandidate else { return }
        didInteractInCurrentSession = true
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
            case .offering(let candidate):
                HStack(spacing: 6) {
                    Button(action: onAccept) {
                        HStack(spacing: 6) {
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

                            if candidate.badgeHint != nil && candidate.promotableRule == nil {
                                Image(systemName: "sparkle")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(Color.accentColor.opacity(0.85))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

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
                        .font(.system(size: 12, weight: .semibold))
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
