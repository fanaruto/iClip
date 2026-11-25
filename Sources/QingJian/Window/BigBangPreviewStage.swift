import AppKit
import SwiftUI
import Combine

enum BigBangInitialPreviewMode: Equatable {
    /// 图片默认纯净全图大屏预览（支持一键/O 切换原位大爆炸）；文本/链接默认大爆炸形态展开
    case autoDefault
    /// 从图片卡片 OCR 入口直接进入全图原位大爆炸选字
    case imageBigBangOCR
    /// ⌥Space 直达文本差异比对页签
    case textDiff
}

/// 无边框非激活独立大画幅预览窗口：不抢夺目标应用光标焦点，并跟随系统投屏隐私屏蔽开关
final class BigBangStagePanel: UnifiedActiveFloatingPanel {
    var allowBecomeKeyForEditing: Bool = false

    override var canBecomeKey: Bool { allowBecomeKeyForEditing }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseStageHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class TokenFrameRegistry {
    private var activeSession: String = ""
    private var frames: [Int: CGRect] = [:]

    func setFrame(_ rect: CGRect, for id: Int, session: String) {
        if session != activeSession {
            activeSession = session
            frames.removeAll(keepingCapacity: true)
        }
        frames[id] = rect
    }

    func replaceFrames(_ nextFrames: [Int: CGRect], session: String) {
        activeSession = session
        frames = nextFrames
    }

    func frames(for session: String) -> [Int: CGRect] {
        guard session == activeSession else { return [:] }
        return frames
    }

    func hitTestTokenID(
        at point: CGPoint,
        session: String,
        insetX: CGFloat = -3,
        insetY: CGFloat = -4
    ) -> Int? {
        let currentFrames = frames(for: session)
        guard !currentFrames.isEmpty else { return nil }

        var exactMatchID: Int? = nil
        for (id, rect) in currentFrames where rect.contains(point) {
            if let existing = exactMatchID {
                if id < existing { exactMatchID = id }
            } else {
                exactMatchID = id
            }
        }
        if let exactMatchID {
            return exactMatchID
        }

        guard insetX < 0 || insetY < 0 else { return nil }
        var bestID: Int? = nil
        var bestDistSq: CGFloat = .infinity
        for (id, rect) in currentFrames where rect.insetBy(dx: insetX, dy: insetY).contains(point) {
            let dx = point.x - rect.midX
            let dy = point.y - rect.midY
            let distSq = dx * dx + dy * dy
            if bestID == nil || distSq < bestDistSq || (distSq == bestDistSq && id < bestID!) {
                bestID = id
                bestDistSq = distSq
            }
        }
        return bestID
    }
}

/// SwiftUI 原生 Layout 流式分词排布（zero-jitter、零 GeometryReader 反馈环）
struct BigBangFlowLayoutResult: Equatable {
    let size: CGSize
    let frames: [CGRect]
}

struct BigBangFlowLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 8
    var fullWidthRows: Bool = false
    var tokenIDs: [Int] = []
    var sessionKey: String = ""
    var frameRegistry: TokenFrameRegistry? = nil

    static func computeLayout(
        items: [(size: CGSize, isBreak: Bool)],
        maxWidth: CGFloat,
        spacing: CGFloat,
        lineSpacing: CGFloat,
        fullWidthRows: Bool
    ) -> BigBangFlowLayoutResult {
        let maxW = max(1, maxWidth)
        var frames: [CGRect] = []
        frames.reserveCapacity(items.count)

        let lastContentIdx = items.lastIndex(where: { !$0.isBreak })
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var usedW: CGFloat = 0
        var hasRow = false

        for (idx, item) in items.enumerated() {
            if item.isBreak {
                frames.append(CGRect(x: 0, y: y, width: 0, height: 0))
                if let lastContentIdx, idx > lastContentIdx {
                    continue
                }
                if lastContentIdx == nil {
                    continue
                }
                usedW = max(usedW, x)
                x = 0
                y += (rowH > 0 ? rowH + lineSpacing : 14)
                rowH = 0
                continue
            }
            if fullWidthRows {
                if hasRow {
                    y += lineSpacing
                }
                frames.append(CGRect(x: 0, y: y, width: maxW, height: item.size.height))
                y += item.size.height
                hasRow = true
                usedW = maxW
                continue
            }
            let clampedW = min(item.size.width, maxW)
            if x > 0 && x + clampedW > maxW {
                usedW = max(usedW, x)
                x = 0
                y += rowH + lineSpacing
                rowH = 0
            }
            frames.append(CGRect(x: x, y: y, width: clampedW, height: item.size.height))
            x += clampedW + spacing
            rowH = max(rowH, item.size.height)
            usedW = max(usedW, x - spacing)
        }

        let totalH = fullWidthRows ? y : (y + rowH)
        let finalSize = CGSize(width: min(maxW, max(usedW, maxW)), height: totalH)
        return BigBangFlowLayoutResult(size: finalSize, frames: frames)
    }

    private func measureItems(subviews: Subviews, maxWidth: CGFloat) -> [(size: CGSize, isBreak: Bool)] {
        let maxW = max(1, maxWidth)
        return subviews.map { sub in
            let ideal = sub.sizeThatFits(.unspecified)
            let isBreak = ideal.width <= 0.5 && ideal.height <= 0.5
            if isBreak {
                return (ideal, true)
            }
            if fullWidthRows || ideal.width > maxW {
                let constrained = sub.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
                return (constrained, false)
            }
            return (ideal, false)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = max(1, proposal.width ?? 620)
        let items = measureItems(subviews: subviews, maxWidth: maxW)
        return Self.computeLayout(
            items: items,
            maxWidth: maxW,
            spacing: spacing,
            lineSpacing: lineSpacing,
            fullWidthRows: fullWidthRows
        ).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = max(1, bounds.width)
        let items = measureItems(subviews: subviews, maxWidth: maxW)
        let result = Self.computeLayout(
            items: items,
            maxWidth: maxW,
            spacing: spacing,
            lineSpacing: lineSpacing,
            fullWidthRows: fullWidthRows
        )
        var registered: [Int: CGRect] = [:]
        if frameRegistry != nil && !sessionKey.isEmpty && tokenIDs.count == subviews.count {
            registered.reserveCapacity(subviews.count)
        }
        for (idx, sub) in subviews.enumerated() where idx < result.frames.count {
            let rect = result.frames[idx]
            let isBreak = items[idx].isBreak
            let placedOrigin = CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY)
            sub.place(
                at: placedOrigin,
                anchor: .topLeading,
                proposal: isBreak ? ProposedViewSize(.zero) : ProposedViewSize(width: rect.width, height: rect.height)
            )
            if !isBreak, idx < tokenIDs.count {
                registered[tokenIDs[idx]] = CGRect(origin: placedOrigin, size: rect.size)
            }
        }
        if let frameRegistry, !sessionKey.isEmpty, tokenIDs.count == subviews.count {
            frameRegistry.replaceFrames(registered, session: sessionKey)
        }
    }
}

/// 锤子大爆炸（Big Bang）零重叠流式词阵 + 原位二次爆炸拆分与丝滑独立大屏预览控制器
@MainActor
final class BigBangStageController: ObservableObject {
    static let shared = BigBangStageController()

    @Published private(set) var currentItem: ClipItem? = nil
    @Published private(set) var activeModeIsImage: Bool = false
    @Published var isImageBigBangActive: Bool = false
    @Published var imageZoomScale: CGFloat = 1.0
    private(set) var zoomExternalEpoch: Int = 0
    @Published private(set) var presentationEpoch: Int = 0
    @Published private(set) var isAnalyzingOCR: Bool = false
    @Published var granularity: BigBangGranularity = .smart {
        didSet {
            guard oldValue != granularity else { return }
            rebuildActiveTokensForGranularity()
        }
    }

    @Published private(set) var fullPreviewImage: NSImage? = nil
    @Published private(set) var imageWordBoxes: [BigBangImageWordBox] = []
    @Published private(set) var recognizedImageFullText: String = ""
    @Published var imageSelectedBoxIDs: Set<Int> = []
    @Published private(set) var imageOCRMessage: String? = nil
    @Published private(set) var imageOCRCanRetry: Bool = false

    @Published private(set) var textTabs: [QuickLookTabItem] = []
    /// 在文本视图中：true 显示顶部「大爆炸选词」；false 显示 `textTabs[selectedTabIndex]`
    @Published var isTextBigBangActive: Bool = true
    @Published var selectedTabIndex: Int = 0
    @Published private(set) var textTokens: [BigBangTextToken] = []
    @Published private(set) var isTextTokensTruncated: Bool = false
    @Published var textSelectedTokenIDs: Set<Int> = []
    @Published private(set) var explosionUndoStack: [([BigBangTextToken], Set<Int>)] = []
    private var nextDynamicTokenID: Int = 10_000
    private var burstEpoch: Int = 0
    @Published var isEditingText: Bool = false {
        didSet {
            panel?.allowBecomeKeyForEditing = isEditingText
            if isEditingText {
                panel?.makeKey()
                panel?.enforceUnifiedActiveAppearance()
                surfaceHost.refreshInPlace()
            } else {
                panel?.makeFirstResponder(nil)
                if panel?.isKeyWindow == true {
                    panel?.resignKey()
                }
                panel?.enforceUnifiedActiveAppearance()
                surfaceHost.refreshInPlace()
            }
        }
    }
    @Published var draftText: String = ""

    var onStepSelection: ((PanelNavigationDirection) -> ClipItem?)?
    var onAdjacentItemsProvider: ((ClipItem) -> [ClipItem])?
    var onCommitPasteText: ((String, ClipItem, String, Bool) -> Void)?
    var onCommitPasteImage: ((ClipItem) -> Void)?
    var onCopyText: ((String, ClipItem, String) -> Void)?
    var onCopyFullItem: ((ClipItem) -> Void)?
    var onSaveToItem: ((String, ClipItem) -> Void)?
    var onHandoffToSystemQuickLook: ((ClipItem) -> Void)?
    var onPrepareSystemQuickLookCallbacks: (() -> Void)?
    var onDismissHostPanel: (() -> Void)?

    private var panel: BigBangStagePanel?
    private weak var hostWindow: NSWindow?
    private weak var storeRef: ClipboardStore?
    private var hostingView: NSHostingView<BigBangStageRootView>?
    private let surfaceHost = LiquidGlassSurfaceHost()
    private var surfaceCancellables = Set<AnyCancellable>()
    private let stageCornerRadius: CGFloat = 20
    private let stageShadowBleed: CGFloat = 24
    private var imageDecodeTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var hideWorkItem: DispatchWorkItem?
    private var fadeCoordinator = ActionSparkFadeCoordinator()
    private var stickyDiffSelected: Bool = false

    private init() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            self,
            selector: #selector(handleSystemPrivacyLock),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(handleSystemPrivacyLock),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSystemPrivacyLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
    }

    @objc private func handleSystemPrivacyLock() {
        dismissImmediatelyAndPurge()
    }

    var isVisible: Bool {
        (panel?.isVisible ?? false) && !fadeCoordinator.isFadingOut && hideWorkItem == nil
    }

    var visiblePanelScreenFrame: NSRect? {
        guard isVisible, let frame = panel?.frame else { return nil }
        return frame.insetBy(dx: stageShadowBleed, dy: stageShadowBleed)
    }

    var effectiveGranularityForActiveMode: BigBangGranularity {
        Self.resolveEffectiveGranularity(granularity, isImageMode: activeModeIsImage)
    }

    var canUndoExplosion: Bool {
        !explosionUndoStack.isEmpty
    }

    static func resolveEffectiveGranularity(_ granularity: BigBangGranularity, isImageMode: Bool) -> BigBangGranularity {
        granularity
    }

    static func nextCycledGranularity(from granularity: BigBangGranularity, isImageMode: Bool) -> BigBangGranularity {
        let options = BigBangGranularity.allCases
        let normalized = resolveEffectiveGranularity(granularity, isImageMode: isImageMode)
        guard let idx = options.firstIndex(of: normalized) else { return .smart }
        return options[(idx + 1) % options.count]
    }

    /// 计算进出场过渡卡片尺寸与重心偏移：保持 >= 85% 原画幅宽度避免顶底栏胶囊与 600 词块逐帧重排抖动
    static func transitionCardRect(anchorRect: NSRect?, targetCardRect: NSRect, scale: CGFloat = 0.92) -> NSRect {
        let clampedScale = min(max(scale, 0.85), 1.0)
        let w = targetCardRect.width * clampedScale
        let h = targetCardRect.height * clampedScale
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if let anchor = anchorRect, anchor.width > 12, anchor.height > 12 {
            dx = min(max((anchor.midX - targetCardRect.midX) * 0.18, -72), 72)
            dy = min(max((anchor.midY - targetCardRect.midY) * 0.18, -56), 56)
        }
        let cx = targetCardRect.midX + dx
        let cy = targetCardRect.midY + dy
        return NSRect(x: cx - w * 0.5, y: cy - h * 0.5, width: w, height: h)
    }

    func syncSharingType(_ sharingType: NSWindow.SharingType) {
        panel?.sharingType = sharingType
    }

    @discardableResult
    func presentOrToggle(
        for item: ClipItem,
        in store: ClipboardStore,
        hostWindow: NSWindow?,
        initialMode: BigBangInitialPreviewMode = .autoDefault
    ) -> Bool {
        if isVisible && currentItem?.id == item.id {
            if initialMode == .imageBigBangOCR && item.type == .image && !isImageBigBangActive {
                enterImageBigBangOCR(for: item)
                return true
            }
            if initialMode == .textDiff && !activeModeIsImage {
                if let diffIdx = textTabs.firstIndex(where: { $0.id == QuickLookTabItem.diffLatestTabID }) {
                    isTextBigBangActive = false
                    selectedTabIndex = diffIdx
                    stickyDiffSelected = true
                    return true
                }
            }
            dismiss()
            return true
        }
        return presentOrUpdate(for: item, in: store, hostWindow: hostWindow, initialMode: initialMode)
    }

    @discardableResult
    func presentOrUpdate(
        for item: ClipItem,
        in store: ClipboardStore,
        hostWindow: NSWindow? = nil,
        initialMode: BigBangInitialPreviewMode = .autoDefault
    ) -> Bool {
        guard item.type == .image || item.type == .text || item.type == .link else {
            return false
        }
        let wasActivelyVisible = isVisible
        fadeCoordinator.beginPresentation()
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if let hostWindow {
            self.hostWindow = hostWindow
        }
        self.storeRef = store
        if !wasActivelyVisible && self.granularity == .character {
            self.granularity = .smart
        }
        self.currentItem = item
        self.isEditingText = false
        self.draftText = ""
        self.imageSelectedBoxIDs = []
        self.textSelectedTokenIDs = []
        self.explosionUndoStack = []
        self.burstEpoch = 0
        self.imageOCRMessage = nil
        self.imageOCRCanRetry = false

        ensurePanelCreated(store: store)
        guard let stagePanel = panel else { return false }

        if let host = self.hostWindow {
            let levelRaw = max(host.level.rawValue + 1, NSWindow.Level.floating.rawValue)
            stagePanel.level = NSWindow.Level(rawValue: levelRaw)
            stagePanel.sharingType = host.sharingType
        } else {
            stagePanel.level = .floating
            stagePanel.sharingType = (store.screenSharePrivacyEnabled && !ProcessInfo.processInfo.arguments.contains("--demo")) ? .none : .readOnly
        }

        if item.type == .image {
            activeModeIsImage = true
            isImageBigBangActive = (initialMode == .imageBigBangOCR)
            configureImageSession(for: item, store: store)
        } else {
            activeModeIsImage = false
            isImageBigBangActive = false
            configureTextSession(for: item, store: store, initialMode: initialMode)
        }

        let targetCardFrame = computeTargetScreenFrame(for: item, image: fullPreviewImage)
        let targetWindowFrame = windowFrame(forCardRect: targetCardFrame)
        if !wasActivelyVisible {
            presentationEpoch &+= 1
            let sourceRect = SystemQuickLookController.shared.liveVisibleScreenRect(for: item.id)
            let startCardFrame = Self.transitionCardRect(
                anchorRect: sourceRect,
                targetCardRect: targetCardFrame,
                scale: 0.92
            )
            stagePanel.setFrame(windowFrame(forCardRect: startCardFrame), display: false)
            stagePanel.alphaValue = 0.08
            stagePanel.orderFrontRegardless()
            stagePanel.enforceUnifiedActiveAppearance()
            surfaceHost.refreshInPlace()
            stagePanel.invalidateShadow()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.21
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 1.0, 0.32, 1.0)
                stagePanel.animator().setFrame(targetWindowFrame, display: true)
                stagePanel.animator().alphaValue = 1.0
            }
        } else {
            stagePanel.enforceUnifiedActiveAppearance()
            surfaceHost.refreshInPlace()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                stagePanel.animator().setFrame(targetWindowFrame, display: true)
                stagePanel.animator().alphaValue = 1.0
            }
        }
        return true
    }

    func dismiss() {
        cancelAsyncTasks()
        guard let stagePanel = panel, stagePanel.isVisible else {
            fadeCoordinator.invalidatePendingFade()
            hideWorkItem?.cancel()
            hideWorkItem = nil
            clearTransientState()
            return
        }
        guard !fadeCoordinator.isFadingOut else { return }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let scheduledEpoch = fadeCoordinator.beginFadeSchedule()
        _ = fadeCoordinator.markFadeStarted(for: scheduledEpoch)
        presentationEpoch &+= 1

        isEditingText = false
        let sourceRect = currentItem.flatMap { SystemQuickLookController.shared.liveVisibleScreenRect(for: $0.id) }
        let currentCardRect = stagePanel.frame.insetBy(dx: stageShadowBleed, dy: stageShadowBleed)
        let endCardRect = Self.transitionCardRect(
            anchorRect: sourceRect,
            targetCardRect: currentCardRect,
            scale: 0.94
        )
        let endWindowRect = windowFrame(forCardRect: endCardRect)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            stagePanel.animator().setFrame(endWindowRect, display: true)
            stagePanel.animator().alphaValue = 0.0
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.fadeCoordinator.shouldCompleteFadeOut(scheduledEpoch: scheduledEpoch) else {
                    return
                }
                self.hideWorkItem = nil
                self.fadeCoordinator.invalidatePendingFade()
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1.0
                self.clearTransientState()
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func dismissImmediatelyAndPurge() {
        fadeCoordinator.invalidatePendingFade()
        hideWorkItem?.cancel()
        hideWorkItem = nil
        cancelAsyncTasks()
        isEditingText = false
        panel?.orderOut(nil)
        panel?.alphaValue = 1.0
        clearTransientState()
    }

    // MARK: - 会话准备与异步零阻塞预热

    private func configureImageSession(for item: ClipItem, store: ClipboardStore) {
        cancelAsyncTasks()
        self.imageZoomScale = 1.0
        let cachedPreview = store.cachedPreviewImage(for: item)
        let cachedThumb = store.cachedThumbnail(for: item)
        self.fullPreviewImage = cachedPreview ?? cachedThumb
        self.imageWordBoxes = []
        self.recognizedImageFullText = item.ocrText ?? ""
        self.isAnalyzingOCR = false
        if !self.recognizedImageFullText.isEmpty {
            applyBoundedTextTokens(from: self.recognizedImageFullText)
        } else {
            self.textTokens = []
            self.isTextTokensTruncated = false
        }

        let targetItem = item
        if cachedPreview == nil {
            imageDecodeTask = Task { [weak self] in
                let decoded = await store.loadPreviewImage(for: targetItem)
                guard !Task.isCancelled, let self, self.currentItem?.id == targetItem.id else { return }
                if let decoded {
                    self.fullPreviewImage = decoded
                }
            }
        }

        // 后台预热视觉排序 OCR 全文 + 相邻两张图片高清图，切换时 0 延迟
        if let url = store.imageURL(for: targetItem) {
            if let cached = VisionOCRService.cachedWordBoxResult(at: url, granularity: .smart) {
                applyWordBoxResult(cached)
            } else {
                self.isAnalyzingOCR = self.recognizedImageFullText.isEmpty
                ocrTask = Task { [weak self] in
                    let res = await VisionOCRService.recognizeWordBoxesDetailed(at: url, granularity: .smart)
                    guard !Task.isCancelled, let self, self.currentItem?.id == targetItem.id else { return }
                    self.isAnalyzingOCR = false
                    self.applyWordBoxResult(res)
                }
            }
        }

        if let neighbors = onAdjacentItemsProvider?(targetItem), !neighbors.isEmpty {
            let candidates = neighbors.filter { $0.type == .image }.prefix(2)
            prewarmTask = Task {
                for n in candidates {
                    if Task.isCancelled { break }
                    _ = await store.loadPreviewImage(for: n)
                    if let url = store.imageURL(for: n) {
                        _ = await VisionOCRService.recognizeWordBoxesDetailed(at: url, granularity: .smart)
                    }
                }
            }
        }
    }

    private func configureTextSession(
        for item: ClipItem,
        store: ClipboardStore,
        initialMode: BigBangInitialPreviewMode
    ) {
        cancelAsyncTasks()
        self.fullPreviewImage = nil
        self.imageWordBoxes = []
        let tabs = QuickLookTabBuilder.buildTabs(for: item, store: store)
        self.textTabs = tabs

        if initialMode == .textDiff,
           let diffIdx = tabs.firstIndex(where: { $0.id == QuickLookTabItem.diffLatestTabID }) {
            self.stickyDiffSelected = true
            self.isTextBigBangActive = false
            self.selectedTabIndex = diffIdx
        } else if stickyDiffSelected,
                  let diffIdx = tabs.firstIndex(where: { $0.id == QuickLookTabItem.diffLatestTabID }) {
            self.isTextBigBangActive = false
            self.selectedTabIndex = diffIdx
        } else {
            self.stickyDiffSelected = false
            self.isTextBigBangActive = true
            self.selectedTabIndex = QuickLookTabBuilder.defaultTabIndex(for: item, tabs: tabs, preferDiff: false)
        }

        let source = activeSourceTextForTextBigBang()
        applyBoundedTextTokens(from: source)
    }

    private func applyBoundedTextTokens(from rawSource: String) {
        let maxTokenizeUTF16 = 16_384
        let clippedInput: String
        let wasInputClipped: Bool
        if rawSource.utf16.count > maxTokenizeUTF16 {
            clippedInput = BigBangTokenizer.utf16Prefix(rawSource, maxUTF16: maxTokenizeUTF16)
            wasInputClipped = true
        } else {
            clippedInput = rawSource
            wasInputClipped = false
        }
        let all = BigBangTokenizer.tokenize(clippedInput, granularity: granularity)
        let maxInteractiveTokens = 600
        var kept: [BigBangTextToken] = []
        var nonBreakCount = 0
        var hitCap = false
        for tok in all {
            if !tok.isLineBreak {
                if nonBreakCount >= maxInteractiveTokens {
                    hitCap = true
                    break
                }
                nonBreakCount += 1
            }
            kept.append(tok)
        }
        self.textTokens = kept
        self.nextDynamicTokenID = max(10_000, (kept.map(\.id).max() ?? 0) + 1)
        self.isTextTokensTruncated = wasInputClipped || hitCap
    }

    func activeSourceTextForTextBigBang() -> String {
        if let raw = currentItem?.text, !raw.isEmpty {
            return raw
        }
        return textTabs.first?.textValue ?? currentItem?.rawContentPreview ?? ""
    }

    private func applyWordBoxResult(_ result: VisionOCRService.WordBoxRecognitionResult) {
        let fallbackOCRText = currentItem?.ocrText ?? ""
        let prevText = self.recognizedImageFullText
        let userHasInteracted = !self.explosionUndoStack.isEmpty || !self.textSelectedTokenIDs.isEmpty
        switch result {
        case .recognized(let fullText, let boxes):
            self.imageWordBoxes = boxes
            let resolved = fullText.isEmpty ? fallbackOCRText : fullText
            if self.textTokens.isEmpty || (!userHasInteracted && resolved != prevText) {
                self.recognizedImageFullText = resolved
                self.explosionUndoStack = []
                self.applyBoundedTextTokens(from: resolved)
            }
            self.imageOCRMessage = self.textTokens.isEmpty ? "未在图片中检测到可选文字" : nil
            self.imageOCRCanRetry = false
        case .emptyImage:
            self.imageWordBoxes = []
            if self.textTokens.isEmpty {
                self.recognizedImageFullText = fallbackOCRText
                self.applyBoundedTextTokens(from: fallbackOCRText)
            }
            self.imageOCRMessage = self.textTokens.isEmpty ? "未在图片中检测到可选文字" : nil
            self.imageOCRCanRetry = false
        case .unsupportedDimensions:
            self.imageWordBoxes = []
            if self.textTokens.isEmpty {
                self.recognizedImageFullText = fallbackOCRText
                self.applyBoundedTextTokens(from: fallbackOCRText)
            }
            self.imageOCRMessage = self.textTokens.isEmpty ? "图片分辨率过高，已跳过离线识字" : nil
            self.imageOCRCanRetry = false
        case .failed:
            self.imageWordBoxes = []
            if self.textTokens.isEmpty {
                self.recognizedImageFullText = fallbackOCRText
                self.applyBoundedTextTokens(from: fallbackOCRText)
            }
            self.imageOCRMessage = self.textTokens.isEmpty ? "离线识字暂时不可用，请点击重试" : nil
            self.imageOCRCanRetry = self.textTokens.isEmpty
        }
    }

    private func startImageWordBoxRecognition(for item: ClipItem, url: URL) {
        ocrTask?.cancel()
        ocrTask = nil
        if let cached = VisionOCRService.cachedWordBoxResult(at: url, granularity: .smart) {
            isAnalyzingOCR = false
            applyWordBoxResult(cached)
            return
        }
        imageOCRMessage = nil
        imageOCRCanRetry = false
        isAnalyzingOCR = textTokens.isEmpty
        ocrTask = Task { [weak self] in
            let res = await VisionOCRService.recognizeWordBoxesDetailed(at: url, granularity: .smart)
            guard !Task.isCancelled, let self, self.currentItem?.id == item.id else { return }
            self.isAnalyzingOCR = false
            self.applyWordBoxResult(res)
        }
    }

    private func rebuildActiveTokensForGranularity() {
        explosionUndoStack = []
        textSelectedTokenIDs = []
        imageSelectedBoxIDs = []
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let anim: Animation = reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.28, dampingFraction: 0.84)
        withAnimation(anim) {
            if activeModeIsImage {
                applyBoundedTextTokens(from: recognizedImageFullText)
            } else {
                let source = activeSourceTextForTextBigBang()
                applyBoundedTextTokens(from: source)
            }
        }
    }

    private func enterImageBigBangOCR(for item: ClipItem) {
        imageZoomScale = 1.0
        isImageBigBangActive = true
        if textTokens.isEmpty && !recognizedImageFullText.isEmpty {
            applyBoundedTextTokens(from: recognizedImageFullText)
        }
        if (textTokens.isEmpty || imageOCRCanRetry) && !isAnalyzingOCR,
           let url = storeRef?.imageURL(for: item) {
            startImageWordBoxRecognition(for: item, url: url)
        }
        TactileFeedbackEngine.shared.perform(.tabSwitch)
    }

    func retryImageBigBangOCR() {
        guard activeModeIsImage, let item = currentItem, let url = storeRef?.imageURL(for: item), !isAnalyzingOCR else {
            return
        }
        startImageWordBoxRecognition(for: item, url: url)
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    // MARK: - 原位二次爆炸拆分与回退栈

    /// 将指定复合词块原位二次爆炸拆分为下一级子词块，保持周围兄弟词块 ID 恒定以实现 120Hz 顺滑弹簧让位
    @discardableResult
    func explodeTokenInPlace(id: Int) -> Bool {
        guard let idx = textTokens.firstIndex(where: { $0.id == id && !$0.isLineBreak }) else {
            return false
        }
        let nextBurst = burstEpoch &+ 1
        var candidateNextID = nextDynamicTokenID
        guard let children = BigBangTokenizer.subdivideToken(
            textTokens[idx],
            nextID: &candidateNextID,
            burstGeneration: nextBurst
        ) else {
            return false
        }

        pushExplosionSnapshot()
        burstEpoch = nextBurst
        nextDynamicTokenID = candidateNextID

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let anim: Animation = reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.30, dampingFraction: 0.78)
        withAnimation(anim) {
            textSelectedTokenIDs.remove(id)
            textTokens.replaceSubrange(idx...idx, with: children)
        }
        TactileFeedbackEngine.shared.perform(.tabSwitch)
        return true
    }

    /// 优先将当前选中的可拆词块全部原位二次炸开；若未选中，则炸开悬停词块或将全局粒度向下一级细分
    @discardableResult
    func explodeSelectedOrHoveredOrStepFiner(hoveredTokenID: Int? = nil) -> Bool {
        let splittableSelected = textTokens.filter {
            !$0.isLineBreak && textSelectedTokenIDs.contains($0.id) && BigBangTokenizer.canSubdivide($0.text)
        }
        if !splittableSelected.isEmpty {
            pushExplosionSnapshot()
            let nextBurst = burstEpoch &+ 1
            var candidateNextID = nextDynamicTokenID
            var rebuilt: [BigBangTextToken] = []
            rebuilt.reserveCapacity(textTokens.count + splittableSelected.count * 2)
            var nextSel = textSelectedTokenIDs

            for tok in textTokens {
                if !tok.isLineBreak,
                   textSelectedTokenIDs.contains(tok.id),
                   let children = BigBangTokenizer.subdivideToken(
                       tok,
                       nextID: &candidateNextID,
                       burstGeneration: nextBurst
                   ) {
                    nextSel.remove(tok.id)
                    rebuilt.append(contentsOf: children)
                } else {
                    rebuilt.append(tok)
                }
            }

            burstEpoch = nextBurst
            nextDynamicTokenID = candidateNextID
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let anim: Animation = reduceMotion
                ? .easeOut(duration: 0.14)
                : .spring(response: 0.30, dampingFraction: 0.78)
            withAnimation(anim) {
                textSelectedTokenIDs = nextSel
                textTokens = rebuilt
            }
            TactileFeedbackEngine.shared.perform(.tabSwitch)
            return true
        }

        if let hid = hoveredTokenID, explodeTokenInPlace(id: hid) {
            return true
        }

        let finerTarget: BigBangGranularity? = {
            switch granularity {
            case .line: return .smart
            case .smart: return .word
            case .word: return .character
            case .character: return nil
            }
        }()
        if let finerTarget {
            granularity = finerTarget
            TactileFeedbackEngine.shared.perform(.tabSwitch)
            return true
        }
        return false
    }

    @discardableResult
    func undoLastExplosion() -> Bool {
        guard let (prevTokens, prevSelected) = explosionUndoStack.popLast() else {
            return false
        }
        let settledTokens = prevTokens.map { tok -> BigBangTextToken in
            var copy = tok
            copy.burstGeneration = 0
            copy.burstSpreadIndex = 0
            return copy
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let anim: Animation = reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.26, dampingFraction: 0.86)
        withAnimation(anim) {
            textTokens = settledTokens
            textSelectedTokenIDs = prevSelected
        }
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
        return true
    }

    private func pushExplosionSnapshot() {
        if explosionUndoStack.count >= 24 {
            explosionUndoStack.removeFirst()
        }
        explosionUndoStack.append((textTokens, textSelectedTokenIDs))
    }

    // MARK: - 实时组装与交互指令

    var currentSelectedAssembledText: String {
        if !textSelectedTokenIDs.isEmpty {
            return BigBangTokenizer.assembleSelected(textTokens, selectedIDs: textSelectedTokenIDs)
        }
        if activeModeIsImage && !imageSelectedBoxIDs.isEmpty {
            return BigBangTokenizer.assembleSelectedImageBoxes(imageWordBoxes, selectedIDs: imageSelectedBoxIDs)
        }
        return ""
    }

    func zoomInImage() {
        guard activeModeIsImage, !isImageBigBangActive else { return }
        zoomExternalEpoch &+= 1
        imageZoomScale = min(3.0, ((imageZoomScale + 0.5) * 2).rounded() / 2)
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    func zoomOutImage() {
        guard activeModeIsImage, !isImageBigBangActive else { return }
        zoomExternalEpoch &+= 1
        imageZoomScale = max(1.0, ((imageZoomScale - 0.5) * 2).rounded() / 2)
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    func resetImageZoom() {
        guard imageZoomScale != 1.0 else { return }
        zoomExternalEpoch &+= 1
        imageZoomScale = 1.0
    }

    func toggleImageZoom() {
        guard activeModeIsImage, !isImageBigBangActive else { return }
        zoomExternalEpoch &+= 1
        imageZoomScale = (imageZoomScale > 1.05) ? 1.0 : 2.0
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    func setImageZoomScale(_ scale: CGFloat) {
        guard activeModeIsImage, !isImageBigBangActive else { return }
        let clamped = min(3.0, max(1.0, scale))
        if abs(imageZoomScale - clamped) >= 0.005 || clamped == 1.0 || clamped == 3.0 {
            imageZoomScale = clamped
        }
    }

    func toggleImageBigBangMode() {
        guard activeModeIsImage, let item = currentItem else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let anim: Animation = reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.28, dampingFraction: 0.85)
        if isImageBigBangActive {
            withAnimation(anim) {
                isImageBigBangActive = false
                imageSelectedBoxIDs = []
                textSelectedTokenIDs = []
            }
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
        } else {
            withAnimation(anim) {
                enterImageBigBangOCR(for: item)
            }
        }
    }

    func cycleGranularity() {
        granularity = Self.nextCycledGranularity(from: granularity, isImageMode: activeModeIsImage)
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    func selectAllTokens() {
        if activeModeIsImage {
            guard isImageBigBangActive else { return }
        } else {
            guard isTextBigBangActive else { return }
        }
        textSelectedTokenIDs = Set(textTokens.filter { !$0.isLineBreak }.map(\.id))
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    func clearTokenSelection() {
        imageSelectedBoxIDs = []
        textSelectedTokenIDs = []
    }

    func stepTab(delta: Int) {
        guard !activeModeIsImage, !isEditingText else { return }
        // 排布顺序：[-1: 大爆炸选词, 0..<textTabs.count: 常规页签]
        let totalCount = textTabs.count + 1
        let currentPos = isTextBigBangActive ? 0 : (selectedTabIndex + 1)
        let nextPos = (currentPos + delta + totalCount) % totalCount
        if nextPos == 0 {
            isTextBigBangActive = true
            stickyDiffSelected = false
        } else {
            isTextBigBangActive = false
            selectedTabIndex = nextPos - 1
            stickyDiffSelected = (textTabs[selectedTabIndex].id == QuickLookTabItem.diffLatestTabID)
        }
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    func stepSelection(direction: PanelNavigationDirection) {
        guard !isEditingText, let nextItem = onStepSelection?(direction) else { return }
        guard let store = storeRef else { return }
        if nextItem.type == .file {
            dismiss()
            onPrepareSystemQuickLookCallbacks?()
            if SystemQuickLookController.supportsNativeLargePreview(nextItem) {
                _ = SystemQuickLookController.shared.presentOrUpdate(for: nextItem, in: store, hostWindow: hostWindow)
            }
            return
        }
        let mode: BigBangInitialPreviewMode = (nextItem.type == .image && isImageBigBangActive) ? .imageBigBangOCR : .autoDefault
        _ = presentOrUpdate(for: nextItem, in: store, hostWindow: hostWindow, initialMode: mode)
    }

    func enterTextEditMode() -> Bool {
        guard !activeModeIsImage else { return false }
        if isEditingText {
            isEditingText = false
            return true
        }
        let idx = min(max(selectedTabIndex, 0), max(0, textTabs.count - 1))
        let seedText: String
        if isTextBigBangActive {
            let sel = currentSelectedAssembledText
            seedText = sel.isEmpty ? activeSourceTextForTextBigBang() : sel
            isTextBigBangActive = false
            selectedTabIndex = 0
        } else if textTabs.indices.contains(idx), let txt = textTabs[idx].textValue {
            seedText = txt
        } else {
            seedText = activeSourceTextForTextBigBang()
        }
        draftText = seedText
        isEditingText = true
        return true
    }

    func saveDraftBackToItem() {
        guard !activeModeIsImage, isEditingText, let item = currentItem else { return }
        let updated = draftText
        onSaveToItem?(updated, item)
        isEditingText = false
        if let store = storeRef, let refreshed = store.items.first(where: { $0.id == item.id }) {
            currentItem = refreshed
            textTabs = QuickLookTabBuilder.buildTabs(for: refreshed, store: store)
            applyBoundedTextTokens(from: updated)
        } else {
            applyBoundedTextTokens(from: updated)
        }
    }

    func commitPrimaryPaste() {
        guard let item = currentItem else { return }
        if activeModeIsImage {
            if isImageBigBangActive {
                let sel = currentSelectedAssembledText
                let payload = !sel.isEmpty ? sel : recognizedImageFullText
                if !payload.isEmpty {
                    let toast = !sel.isEmpty ? "已键入所选图中文字（\(sel.count)字）" : "已键入图中全部文字"
                    dismissImmediatelyAndPurge()
                    onCommitPasteText?(payload, item, toast, false)
                    return
                }
            }
            dismissImmediatelyAndPurge()
            onCommitPasteImage?(item)
            return
        }

        if isEditingText {
            let draft = draftText
            isEditingText = false
            dismissImmediatelyAndPurge()
            onCommitPasteText?(draft, item, "已键入微调内容", false)
            return
        }

        if isTextBigBangActive {
            let sel = currentSelectedAssembledText
            let payload = !sel.isEmpty ? sel : activeSourceTextForTextBigBang()
            let toast = !sel.isEmpty ? "已键入大爆炸所选（\(sel.count)字）" : "已键入全文"
            dismissImmediatelyAndPurge()
            onCommitPasteText?(payload, item, toast, false)
            return
        }

        let idx = min(max(selectedTabIndex, 0), max(0, textTabs.count - 1))
        if textTabs.indices.contains(idx), let txt = textTabs[idx].textValue {
            let isDiff = (textTabs[idx].id == QuickLookTabItem.diffLatestTabID)
            let toast = textTabs[idx].toast
            dismissImmediatelyAndPurge()
            onCommitPasteText?(txt, item, toast, isDiff)
        } else {
            let fallback = activeSourceTextForTextBigBang()
            dismissImmediatelyAndPurge()
            onCommitPasteText?(fallback, item, "已键入文本", false)
        }
    }

    func commitCopyOnly() {
        guard let item = currentItem else { return }
        if activeModeIsImage {
            if isImageBigBangActive {
                let sel = currentSelectedAssembledText
                let payload = !sel.isEmpty ? sel : recognizedImageFullText
                if !payload.isEmpty {
                    let toast = !sel.isEmpty ? "已复制所选图中文字（\(sel.count)字）" : "已复制图中文字"
                    onCopyText?(payload, item, toast)
                    return
                }
            }
            onCopyFullItem?(item)
            return
        }

        if isEditingText {
            onCopyText?(draftText, item, "已复制微调内容")
            return
        }

        if isTextBigBangActive {
            let sel = currentSelectedAssembledText
            let payload = !sel.isEmpty ? sel : activeSourceTextForTextBigBang()
            let toast = !sel.isEmpty ? "已复制所选内容（\(sel.count)字）" : "已复制全部文本"
            onCopyText?(payload, item, toast)
            return
        }

        let idx = min(max(selectedTabIndex, 0), max(0, textTabs.count - 1))
        if textTabs.indices.contains(idx), let txt = textTabs[idx].textValue {
            onCopyText?(txt, item, "已复制当前页内容")
        } else {
            onCopyFullItem?(item)
        }
    }

    func handoffToSystemQuickLook() {
        guard let item = currentItem, activeModeIsImage else { return }
        dismissImmediatelyAndPurge()
        onHandoffToSystemQuickLook?(item)
    }

    // MARK: - 内部窗口与尺寸辅助

    private func windowFrame(forCardRect cardRect: NSRect) -> NSRect {
        let minCardEdge = max(72, ceil(stageCornerRadius * 3.2) + 8)
        let w = max(minCardEdge, cardRect.width)
        let h = max(minCardEdge, cardRect.height)
        let safeCard = NSRect(
            x: cardRect.midX - w * 0.5,
            y: cardRect.midY - h * 0.5,
            width: w,
            height: h
        )
        return safeCard.insetBy(dx: -stageShadowBleed, dy: -stageShadowBleed)
    }

    private func ensurePanelCreated(store: ClipboardStore) {
        if panel != nil { return }
        let initialCardSize = NSSize(width: 720, height: 540)
        let p = BigBangStagePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: initialCardSize.width + stageShadowBleed * 2,
                height: initialCardSize.height + stageShadowBleed * 2
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = BigBangStageRootView(controller: self, store: store)
        let hv = FirstMouseStageHostingView(rootView: rootView)
        hv.sizingOptions = []
        hv.frame = NSRect(origin: .zero, size: initialCardSize)
        hv.autoresizingMask = [.width, .height]
        hv.wantsLayer = true
        hv.layer?.backgroundColor = NSColor.clear.cgColor
        hv.layer?.cornerCurve = .continuous
        hv.layer?.cornerRadius = stageCornerRadius
        hv.layer?.masksToBounds = true

        self.panel = p
        self.hostingView = hv
        applyNativeSurface(style: store.surfaceStyle, store: store)
        observeSurfaceStyle(store: store)
        p.enforceUnifiedActiveAppearance()
    }

    private func applyNativeSurface(style: PanelSurfaceStyle, store: ClipboardStore) {
        guard let stagePanel = panel, let hv = hostingView else { return }
        let cardW = max(64, stagePanel.frame.width - stageShadowBleed * 2)
        let cardH = max(64, stagePanel.frame.height - stageShadowBleed * 2)
        let bounds = NSRect(origin: .zero, size: NSSize(width: cardW, height: cardH))
        surfaceHost.install(
            on: stagePanel,
            hostingView: hv,
            bounds: bounds,
            bleed: stageShadowBleed,
            cornerRadius: stageCornerRadius,
            style: style,
            appearance: store.liquidGlassAppearance,
            maskOpacity: store.liquidGlassMaskOpacity,
            autoResizeWithWindow: true
        )
    }

    private func observeSurfaceStyle(store: ClipboardStore) {
        surfaceCancellables.removeAll()
        store.$surfaceStyle
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] newStyle in
                guard let self, let store else { return }
                self.applyNativeSurface(style: newStyle, store: store)
            }
            .store(in: &surfaceCancellables)

        Publishers.CombineLatest(store.$liquidGlassAppearance, store.$liquidGlassMaskOpacity)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] appearance, opacity in
                guard let self, store?.surfaceStyle == .liquidGlass else { return }
                self.surfaceHost.updateLiquidGlass(appearance: appearance, maskOpacity: opacity)
            }
            .store(in: &surfaceCancellables)

        Publishers.Merge(
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification),
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.panel?.enforceUnifiedActiveAppearance()
            self.surfaceHost.refreshInPlace()
        }
        .store(in: &surfaceCancellables)
    }

    private func computeTargetScreenFrame(for item: ClipItem, image: NSImage?) -> NSRect {
        let targetScreen: NSScreen? = {
            if let hostScreen = hostWindow?.screen { return hostScreen }
            let mouse = NSEvent.mouseLocation
            if let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
                return mouseScreen
            }
            return NSScreen.main ?? NSScreen.screens.first
        }()

        let visible = targetScreen?.visibleFrame ?? NSRect(x: 120, y: 120, width: 1200, height: 800)

        let winW: CGFloat
        let winH: CGFloat

        if item.type == .image {
            let imgSize: CGSize = {
                if let img = image, img.size.width > 1, img.size.height > 1 {
                    return img.size
                }
                if let w = item.imageWidth, let h = item.imageHeight, w > 1, h > 1 {
                    return CGSize(width: w, height: h)
                }
                return CGSize(width: 900, height: 640)
            }()
            let maxCanvasW = min(1040, visible.width * 0.72)
            let maxCanvasH = min(760, visible.height * 0.74)
            let chromeH: CGFloat = 104
            let chromeW: CGFloat = 32
            let fit = BigBangTokenizer.aspectFitImageRect(
                imageSize: imgSize,
                in: CGSize(width: maxCanvasW - chromeW, height: maxCanvasH - chromeH)
            )
            winW = max(580, min(maxCanvasW, fit.width + chromeW))
            winH = max(440, min(maxCanvasH, fit.height + chromeH))
        } else {
            winW = min(700, max(540, visible.width * 0.56))
            winH = min(560, max(440, visible.height * 0.64))
        }

        let originX = visible.minX + (visible.width - winW) * 0.5
        let originY = visible.minY + (visible.height - winH) * 0.5
        return NSRect(x: originX, y: originY, width: winW, height: winH)
    }

    private func cancelAsyncTasks() {
        imageDecodeTask?.cancel()
        imageDecodeTask = nil
        ocrTask?.cancel()
        ocrTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    private func clearTransientState() {
        currentItem = nil
        fullPreviewImage = nil
        imageWordBoxes = []
        recognizedImageFullText = ""
        imageSelectedBoxIDs = []
        imageOCRMessage = nil
        imageOCRCanRetry = false
        textTokens = []
        isTextTokensTruncated = false
        textSelectedTokenIDs = []
        explosionUndoStack = []
        burstEpoch = 0
        textTabs = []
        stickyDiffSelected = false
        isImageBigBangActive = false
        imageZoomScale = 1.0
        isAnalyzingOCR = false
        presentationEpoch &+= 1
    }
}

// MARK: - 独立大屏预览 + 零重叠大爆炸（Big Bang）SwiftUI 视图

struct BigBangStageRootView: View {
    @ObservedObject var controller: BigBangStageController
    @ObservedObject var store: ClipboardStore

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isEditorFocused: Bool

    @State private var tokenDragTargetSelect: Bool? = nil
    @State private var tokenSweepVisited: Set<Int> = []
    @State private var lastTextSweepPoint: CGPoint? = nil
    @State private var hoveredTextTokenID: Int? = nil
    @State private var lastTappedToken: (id: Int, uptime: TimeInterval)? = nil
    @State private var tokenFrameStore = TokenFrameRegistry()
    @State private var imagePanOffset: CGSize = .zero
    @State private var lastImagePanTranslation: CGSize? = nil
    @State private var pinchStartZoom: CGFloat? = nil
    @State private var pinchStartEpoch: Int = -1
    @State private var suppressNextProportionalPan: Bool = false
    @GestureState private var isPinchingImage: Bool = false

    private var brandCobalt: Color { Color(red: 0.118, green: 0.369, blue: 1.0) }

    var body: some View {
        VStack(spacing: 0) {
            topHeaderBar
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 10)
                .background(
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(colorScheme == .dark ? 0.56 : 0.82)
                )

            Divider().opacity(0.24)

            if controller.activeModeIsImage {
                imagePreviewCanvas
            } else {
                textPreviewCanvas
            }

            Divider().opacity(0.24)

            bottomActionIsland
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(colorScheme == .dark ? 0.56 : 0.82)
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.14 : 0.42),
                    lineWidth: 0.85
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.stageHoverResetEpoch, controller.presentationEpoch)
        .onChange(of: controller.currentItem?.id) { _, _ in
            imagePanOffset = .zero
            lastImagePanTranslation = nil
            suppressNextProportionalPan = false
            pinchStartZoom = nil
            pinchStartEpoch = -1
            tokenDragTargetSelect = nil
            tokenSweepVisited = []
            lastTextSweepPoint = nil
            hoveredTextTokenID = nil
            lastTappedToken = nil
        }
        .onChange(of: controller.isImageBigBangActive) { _, active in
            hoveredTextTokenID = nil
            tokenDragTargetSelect = nil
            tokenSweepVisited = []
            lastTextSweepPoint = nil
            lastTappedToken = nil
            if active {
                imagePanOffset = .zero
                lastImagePanTranslation = nil
                pinchStartZoom = nil
                pinchStartEpoch = -1
            }
        }
        .onChange(of: controller.isTextBigBangActive) { _, _ in
            hoveredTextTokenID = nil
            tokenDragTargetSelect = nil
            tokenSweepVisited = []
            lastTextSweepPoint = nil
        }
        .onChange(of: isPinchingImage) { _, pinching in
            if !pinching {
                pinchStartZoom = nil
                pinchStartEpoch = -1
            }
        }
        .onDisappear {
            pinchStartZoom = nil
            pinchStartEpoch = -1
            hoveredTextTokenID = nil
        }
        .onChange(of: controller.granularity) { _, _ in
            tokenDragTargetSelect = nil
            tokenSweepVisited = []
            lastTextSweepPoint = nil
            hoveredTextTokenID = nil
        }
        .onChange(of: controller.isEditingText) { _, editing in
            hoveredTextTokenID = nil
            if editing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    if controller.isEditingText && controller.isVisible {
                        isEditorFocused = true
                    }
                }
            } else {
                isEditorFocused = false
            }
        }
    }

    // MARK: - 顶部标题与模式胶囊

    private var topHeaderBar: some View {
        HStack(spacing: 10) {
            if let item = controller.currentItem {
                Image(systemName: controller.activeModeIsImage
                      ? (controller.isImageBigBangActive ? "text.viewfinder" : "photo.fill")
                      : (controller.isTextBigBangActive ? "sparkles" : item.type.symbolName))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(
                        (controller.isImageBigBangActive || controller.isTextBigBangActive)
                            ? brandCobalt
                            : .secondary
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.primaryTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(headerSubtitle(for: item))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if !controller.activeModeIsImage && !controller.isEditingText {
                // 文本模式页签：大爆炸选词（默认） + 原始文本 + 智变 / 对比 #1
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        tabPill(
                            title: "大爆炸选词",
                            active: controller.isTextBigBangActive
                        ) {
                            controller.isTextBigBangActive = true
                            TactileFeedbackEngine.shared.perform(.tabSwitch)
                        }

                        ForEach(Array(controller.textTabs.enumerated()), id: \.element.id) { idx, tab in
                            tabPill(
                                title: tab.title,
                                active: !controller.isTextBigBangActive && controller.selectedTabIndex == idx
                            ) {
                                controller.isTextBigBangActive = false
                                controller.selectedTabIndex = idx
                                TactileFeedbackEngine.shared.perform(.tabSwitch)
                            }
                        }
                    }
                }
                .frame(maxWidth: 360)
            } else if controller.activeModeIsImage && controller.isImageBigBangActive {
                granularityBar(options: BigBangGranularity.allCases)
            }

            Button {
                controller.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(StageInteractiveCapsuleButtonStyle(isCircle: true, destructive: true))
            .help("关闭预览（Space / ESC）")
        }
    }

    private func headerSubtitle(for item: ClipItem) -> String {
        if controller.activeModeIsImage {
            let dim: String = {
                if let w = item.imageWidth, let h = item.imageHeight {
                    return "\(w)×\(h)"
                }
                if let img = controller.fullPreviewImage {
                    return "\(Int(img.size.width))×\(Int(img.size.height))"
                }
                return "高清原图"
            }()
            if controller.isImageBigBangActive {
                if controller.isAnalyzingOCR && controller.textTokens.isEmpty {
                    return "\(dim) · 正在识别并智能组合图中文字..."
                }
                return "\(dim) · 单击/横扫选词 · 双击或 ⌥单击词块原位再拆分"
            }
            let zoomSuffix = controller.imageZoomScale > 1.01 ? " · \(Int(round(controller.imageZoomScale * 100)))%（双击还原）" : ""
            return "\(dim) · Space 关闭 · 双击/双指/⌘+/- 缩放 · O 大爆炸选字\(zoomSuffix)"
        }

        let base = QuickLookTextHelper.textMetricsSummary(
            for: controller.isEditingText ? controller.draftText : controller.activeSourceTextForTextBigBang()
        )
        if controller.isTextBigBangActive && !controller.isEditingText {
            return "\(base) · 双击或 ⌥单击词块可原位再拆分"
        }
        return base
    }

    private func tabPill(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? .white : .primary.opacity(0.84))
                .padding(.horizontal, 9.5)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(active ? brandCobalt : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(StageInteractiveCapsuleButtonStyle(prominent: active))
    }

    private func granularityBar(options: [BigBangGranularity]) -> some View {
        let activeGranularity = controller.effectiveGranularityForActiveMode
        return HStack(spacing: 4) {
            ForEach(options, id: \.self) { mode in
                let selected = (activeGranularity == mode)
                Button {
                    guard controller.effectiveGranularityForActiveMode != mode else { return }
                    controller.granularity = mode
                    TactileFeedbackEngine.shared.performNavigationStepHaptic()
                } label: {
                    Text(mode.title)
                        .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .white : .primary.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule().fill(selected ? brandCobalt : Color.primary.opacity(0.08))
                        )
                }
                .buttonStyle(StageInteractiveCapsuleButtonStyle(prominent: selected))
            }
        }
    }

    // MARK: - 图片高清画布 + 毛玻璃景深零重叠大爆炸词阵

    private var imagePreviewCanvas: some View {
        GeometryReader { geo in
            let containerSize = CGSize(width: max(1, geo.size.width - 24), height: max(1, geo.size.height - 20))
            let imgSize: CGSize = {
                if let img = controller.fullPreviewImage, img.size.width > 1, img.size.height > 1 {
                    return img.size
                }
                if let w = controller.currentItem?.imageWidth, let h = controller.currentItem?.imageHeight, w > 1, h > 1 {
                    return CGSize(width: w, height: h)
                }
                return containerSize
            }()
            let fitRect = BigBangTokenizer.aspectFitImageRect(imageSize: imgSize, in: containerSize)
            let absImageRect = fitRect.offsetBy(dx: 12, dy: 10)
            let clampedPan = controller.isImageBigBangActive
                ? .zero
                : BigBangTokenizer.clampedImagePanOffset(
                    offset: imagePanOffset,
                    imageSize: absImageRect.size,
                    zoomScale: controller.imageZoomScale,
                    viewportSize: containerSize
                )

            ZStack(alignment: .topLeading) {
                Color.black.opacity(colorScheme == .dark ? 0.16 : 0.04)

                if let nsImage = controller.fullPreviewImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: absImageRect.width, height: absImageRect.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .opacity(controller.isImageBigBangActive ? 0.0 : 1.0)
                        .scaleEffect(controller.isImageBigBangActive ? 0.96 : controller.imageZoomScale)
                        .animation(
                            isPinchingImage ? nil : .interactiveSpring(response: 0.26, dampingFraction: 0.86),
                            value: controller.imageZoomScale
                        )
                        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: controller.isImageBigBangActive)
                        .offset(clampedPan)
                        .animation(
                            (isPinchingImage || lastImagePanTranslation != nil) ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.86),
                            value: clampedPan
                        )
                        .position(x: absImageRect.midX, y: absImageRect.midY)
                        .allowsHitTesting(!controller.isImageBigBangActive)
                } else if !controller.isImageBigBangActive {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if controller.isImageBigBangActive {
                    // 纯净漫射玻璃画布：原图随 0.28s 弹簧缩隐退场，彻底杜绝底字重影、边缘接缝与实时大图模糊掉帧
                    Rectangle()
                        .fill(
                            colorScheme == .dark
                                ? Color(red: 0.09, green: 0.10, blue: 0.14).opacity(0.92)
                                : Color(red: 0.945, green: 0.955, blue: 0.975).opacity(0.96)
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)

                    if controller.isAnalyzingOCR && controller.textTokens.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在提取并智能聚合图中文字...")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8.5)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                        )
                        .position(x: geo.size.width * 0.5, y: geo.size.height * 0.5)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    } else if controller.textTokens.isEmpty {
                        HStack(spacing: 10) {
                            Text(controller.imageOCRMessage ?? "未在图片中检测到可选文字")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)

                            if controller.imageOCRCanRetry {
                                Button("重试") {
                                    controller.retryImageBigBangOCR()
                                }
                                .buttonStyle(StageInteractiveCapsuleButtonStyle(prominent: true))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(brandCobalt))
                            }
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8.5)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                        )
                        .position(x: geo.size.width * 0.5, y: geo.size.height * 0.5)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    } else {
                        bigBangTokenStageCanvas(showInlineGranularityHeader: false, isOverFrostedImage: true)
                            .transition(
                                .opacity.combined(
                                    with: .scale(
                                        scale: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.0 : 0.96
                                    )
                                )
                            )
                    }
                }
            }
            .contentShape(Rectangle())
            .clipped()
            .onChange(of: controller.imageZoomScale) { oldScale, newScale in
                if newScale <= 1.01 {
                    suppressNextProportionalPan = false
                    imagePanOffset = .zero
                    lastImagePanTranslation = nil
                } else if suppressNextProportionalPan {
                    suppressNextProportionalPan = false
                    imagePanOffset = BigBangTokenizer.clampedImagePanOffset(
                        offset: imagePanOffset,
                        imageSize: absImageRect.size,
                        zoomScale: newScale,
                        viewportSize: containerSize
                    )
                } else {
                    let preZoomClampedPan = BigBangTokenizer.clampedImagePanOffset(
                        offset: imagePanOffset,
                        imageSize: absImageRect.size,
                        zoomScale: oldScale,
                        viewportSize: containerSize
                    )
                    imagePanOffset = BigBangTokenizer.cursorAnchoredZoomPanOffset(
                        currentPan: preZoomClampedPan,
                        oldZoom: oldScale,
                        newZoom: newScale,
                        cursorRelativeToCenter: .zero,
                        imageSize: absImageRect.size,
                        viewportSize: containerSize
                    )
                }
            }
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        guard controller.activeModeIsImage, !controller.isImageBigBangActive else { return }
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            if controller.imageZoomScale > 1.05 {
                                suppressNextProportionalPan = false
                                imagePanOffset = .zero
                                controller.resetImageZoom()
                                TactileFeedbackEngine.shared.performNavigationStepHaptic()
                            } else {
                                let cursorRel = CGPoint(
                                    x: value.location.x - absImageRect.midX,
                                    y: value.location.y - absImageRect.midY
                                )
                                let targetPan = BigBangTokenizer.cursorAnchoredZoomPanOffset(
                                    currentPan: imagePanOffset,
                                    oldZoom: controller.imageZoomScale,
                                    newZoom: 2.0,
                                    cursorRelativeToCenter: cursorRel,
                                    imageSize: absImageRect.size,
                                    viewportSize: containerSize
                                )
                                suppressNextProportionalPan = true
                                imagePanOffset = targetPan
                                controller.toggleImageZoom()
                            }
                        }
                    }
            )
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        guard !controller.isImageBigBangActive, controller.imageZoomScale > 1.01 else { return }
                        let prev = lastImagePanTranslation ?? .zero
                        let delta = CGSize(
                            width: value.translation.width - prev.width,
                            height: value.translation.height - prev.height
                        )
                        lastImagePanTranslation = value.translation
                        imagePanOffset = BigBangTokenizer.clampedImagePanOffset(
                            offset: CGSize(width: clampedPan.width + delta.width, height: clampedPan.height + delta.height),
                            imageSize: absImageRect.size,
                            zoomScale: controller.imageZoomScale,
                            viewportSize: containerSize
                        )
                    }
                    .onEnded { _ in
                        lastImagePanTranslation = nil
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($isPinchingImage) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        guard controller.activeModeIsImage, !controller.isImageBigBangActive else { return }
                        if pinchStartZoom == nil || pinchStartEpoch != controller.zoomExternalEpoch {
                            pinchStartZoom = controller.imageZoomScale / max(0.05, value.magnification)
                            pinchStartEpoch = controller.zoomExternalEpoch
                        }
                        controller.setImageZoomScale((pinchStartZoom ?? 1.0) * value.magnification)
                    }
                    .onEnded { _ in
                        guard pinchStartZoom != nil else { return }
                        pinchStartZoom = nil
                        pinchStartEpoch = -1
                        if controller.imageZoomScale < 1.06 {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                                controller.resetImageZoom()
                            }
                        }
                    }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sampleSweepPoints(from start: CGPoint, to end: CGPoint, includeStart: Bool = false) -> [CGPoint] {
        let dist = hypot(end.x - start.x, end.y - start.y)
        let steps = max(1, Int(ceil(dist / 8.0)))
        guard steps > 1 else { return includeStart && start != end ? [start, end] : [end] }
        let begin = includeStart ? 0 : 1
        return (begin...steps).map { idx in
            let t = CGFloat(idx) / CGFloat(steps)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
    }

    // MARK: - 文本大爆炸 + 语义页签 + 原位编辑画布

    private var textPreviewCanvas: some View {
        VStack(spacing: 0) {
            if controller.isEditingText {
                TextEditor(text: $controller.draftText)
                    .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($isEditorFocused)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.04))
            } else if controller.isTextBigBangActive {
                bigBangTokenStageCanvas(showInlineGranularityHeader: true, isOverFrostedImage: false)
            } else {
                let idx = min(max(controller.selectedTabIndex, 0), max(0, controller.textTabs.count - 1))
                let tab = controller.textTabs.indices.contains(idx) ? controller.textTabs[idx] : nil
                if let diff = tab?.diffResult {
                    diffDetailView(diff)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(tab?.textValue ?? controller.activeSourceTextForTextBigBang())
                            .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 统一零重叠流式词块舞台（图片 OCR 与纯文本共享：支持智能组合、双击/⌥单击单块再炸开、选中批量再拆与 ⌘Z 还原）
    private func bigBangTokenStageCanvas(
        showInlineGranularityHeader: Bool,
        isOverFrostedImage: Bool
    ) -> some View {
        let splittableSelectedCount = controller.textTokens.reduce(into: 0) { acc, tok in
            if !tok.isLineBreak,
               controller.textSelectedTokenIDs.contains(tok.id),
               BigBangTokenizer.canSubdivide(tok.text) {
                acc += 1
            }
        }
        let canStepOrSplit = splittableSelectedCount > 0 || controller.granularity != .character
        let sessionKey = textCanvasSessionKey
        let orderedIDs = controller.textTokens.map(\.id)

        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                if showInlineGranularityHeader {
                    granularityBar(options: BigBangGranularity.allCases)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(brandCobalt)
                        Text("双击或 ⌥单击复合词块可原位再次炸开")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if canStepOrSplit {
                    Button {
                        _ = controller.explodeSelectedOrHoveredOrStepFiner(hoveredTokenID: hoveredTextTokenID)
                    } label: {
                        HStack(spacing: 3.5) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 9.5, weight: .bold))
                            Text(splittableSelectedCount > 0 ? "再拆分 · \(splittableSelectedCount) (X)" : "再拆分 (X)")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(splittableSelectedCount > 0 ? .white : brandCobalt)
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule().fill(
                                splittableSelectedCount > 0
                                    ? brandCobalt
                                    : brandCobalt.opacity(colorScheme == .dark ? 0.18 : 0.11)
                            )
                        )
                    }
                    .buttonStyle(StageInteractiveCapsuleButtonStyle(prominent: splittableSelectedCount > 0))
                    .help("将所选词块原位再次爆炸拆细（快捷键 X，双击单个词块亦可原位拆开）")
                }

                if controller.canUndoExplosion {
                    Button {
                        _ = controller.undoLastExplosion()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("还原")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.primary.opacity(0.86))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(StageInteractiveCapsuleButtonStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .help("还原上一次原位拆分（⌘Z）")
                }

                Button {
                    controller.selectAllTokens()
                } label: {
                    Text("全选 (⌘A)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(brandCobalt)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(brandCobalt.opacity(0.10)))
                }
                .buttonStyle(StageInteractiveCapsuleButtonStyle())

                if !controller.textSelectedTokenIDs.isEmpty {
                    Button {
                        controller.clearTokenSelection()
                    } label: {
                        Text("清空")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(StageInteractiveCapsuleButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            GeometryReader { scrollGeo in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        GeometryReader { g in
                            let minY = g.frame(in: .named("bigBangTextScrollViewport")).minY
                            Color.clear
                                .onChange(of: minY) { _, _ in
                                    if hoveredTextTokenID != nil {
                                        hoveredTextTokenID = nil
                                    }
                                }
                        }
                        .frame(height: 0)

                        BigBangFlowLayout(
                            spacing: 7,
                            lineSpacing: 8,
                            fullWidthRows: controller.granularity == .line,
                            tokenIDs: orderedIDs,
                            sessionKey: sessionKey,
                            frameRegistry: tokenFrameStore
                        ) {
                            ForEach(controller.textTokens) { tok in
                                if tok.isLineBreak {
                                    Color.clear.frame(width: 0, height: 0)
                                } else {
                                    let isSel = controller.textSelectedTokenIDs.contains(tok.id)
                                    let isHovered = (hoveredTextTokenID == tok.id)
                                    let canSplit = BigBangTokenizer.canSubdivide(tok.text)
                                    BigBangTokenChipView(
                                        token: tok,
                                        isSelected: isSel,
                                        isHovered: isHovered,
                                        canSubdivide: canSplit,
                                        isOverFrostedImage: isOverFrostedImage,
                                        brandCobalt: brandCobalt,
                                        onTap: {
                                            handleChipTap(token: tok, canSplit: canSplit)
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 22)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if controller.isTextTokensTruncated {
                            Text("已展开前 600 个词块以保障 120Hz 丝滑体验 · 可切换「按行」查看完整段落")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 10)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: scrollGeo.size.height, alignment: .topLeading)
                    .coordinateSpace(name: "bigBangTextCanvas")
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .named("bigBangTextCanvas")) { phase in
                        switch phase {
                        case .active(let loc):
                            let hit = tokenFrameStore.hitTestTokenID(
                                at: loc,
                                session: sessionKey,
                                insetX: 0,
                                insetY: 0
                            )
                            if hoveredTextTokenID != hit {
                                hoveredTextTokenID = hit
                            }
                        case .ended:
                            if hoveredTextTokenID != nil {
                                hoveredTextTokenID = nil
                            }
                        }
                    }
                    .onTapGesture {
                        if !controller.textSelectedTokenIDs.isEmpty {
                            controller.clearTokenSelection()
                            TactileFeedbackEngine.shared.performNavigationStepHaptic()
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .named("bigBangTextCanvas"))
                            .onChanged { value in
                                let isFirst = (lastTextSweepPoint == nil)
                                let fromPt = lastTextSweepPoint ?? value.startLocation
                                lastTextSweepPoint = value.location
                                for pt in sampleSweepPoints(from: fromPt, to: value.location, includeStart: isFirst) {
                                    handleTextSweepChanged(location: pt)
                                }
                            }
                            .onEnded { _ in
                                tokenDragTargetSelect = nil
                                tokenSweepVisited = []
                                lastTextSweepPoint = nil
                            }
                    )
                }
            }
            .coordinateSpace(name: "bigBangTextScrollViewport")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func handleChipTap(token: BigBangTextToken, canSplit: Bool) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.option), canSplit {
            lastTappedToken = nil
            _ = controller.explodeTokenInPlace(id: token.id)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if canSplit,
           let prev = lastTappedToken,
           prev.id == token.id,
           (now - prev.uptime) <= 0.34 {
            lastTappedToken = nil
            _ = controller.explodeTokenInPlace(id: token.id)
            return
        }

        lastTappedToken = (token.id, now)
        if controller.textSelectedTokenIDs.contains(token.id) {
            controller.textSelectedTokenIDs.remove(token.id)
        } else {
            controller.textSelectedTokenIDs.insert(token.id)
        }
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    private var textCanvasSessionKey: String {
        let headID = controller.textTokens.first?.id ?? -1
        let tailID = controller.textTokens.last?.id ?? -1
        return "\(controller.currentItem?.id.uuidString ?? "none")-\(controller.activeModeIsImage ? "img" : "txt")-\(controller.granularity.rawValue)-\(controller.textTokens.count)-\(headID)-\(tailID)"
    }

    private func handleTextSweepChanged(location: CGPoint) {
        guard let id = tokenFrameStore.hitTestTokenID(
            at: location,
            session: textCanvasSessionKey,
            insetX: -3,
            insetY: -4
        ) else { return }
        guard !tokenSweepVisited.contains(id) else { return }
        tokenSweepVisited.insert(id)
        let targetState: Bool
        if let existing = tokenDragTargetSelect {
            targetState = existing
        } else {
            targetState = !controller.textSelectedTokenIDs.contains(id)
            tokenDragTargetSelect = targetState
        }
        if targetState {
            controller.textSelectedTokenIDs.insert(id)
        } else {
            controller.textSelectedTokenIDs.remove(id)
        }
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    private func diffDetailView(_ diff: ClipboardDiffResult) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(diff.rows) { row in
                    switch row {
                    case .unchanged(_, let newLine, let text):
                        diffRowLine(num: "\(newLine)", mark: " ", text: text, bg: .clear, fg: .secondary)
                    case .removed(let oldLine, let text):
                        diffRowLine(
                            num: "\(oldLine)",
                            mark: "-",
                            text: text,
                            bg: Color.red.opacity(colorScheme == .dark ? 0.22 : 0.12),
                            fg: colorScheme == .dark ? Color(red: 1.0, green: 0.56, blue: 0.56) : Color(red: 0.75, green: 0.12, blue: 0.12)
                        )
                    case .added(let newLine, let text):
                        diffRowLine(
                            num: "\(newLine)",
                            mark: "+",
                            text: text,
                            bg: Color.green.opacity(colorScheme == .dark ? 0.22 : 0.12),
                            fg: colorScheme == .dark ? Color(red: 0.45, green: 0.92, blue: 0.60) : Color(red: 0.08, green: 0.52, blue: 0.24)
                        )
                    case .collapsedContext(let hidden):
                        Text("⋯ 已折叠 \(hidden) 行相同上下文 ⋯")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 3)
                    }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func diffRowLine(num: String, mark: String, text: String, bg: Color, fg: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(num)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.65))
                .frame(width: 28, alignment: .trailing)
            Text(mark)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(fg)
                .frame(width: 10)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(bg))
    }

    // MARK: - 底部液态玻璃浮岛操作栏

    private var bottomActionIsland: some View {
        HStack(spacing: 8) {
            if controller.activeModeIsImage {
                if controller.isImageBigBangActive {
                    let selected = controller.currentSelectedAssembledText
                    Text(selected.isEmpty
                         ? (controller.recognizedImageFullText.isEmpty ? "单击或横扫选取词块" : "未点选将使用全文 · 按 X 再拆分 · 按 O 返回纯图")
                         : "已选 \(controller.textSelectedTokenIDs.count) 处（\(selected.count)字）：\(selected.replacingOccurrences(of: "\n", with: " "))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(selected.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                    islandSecondaryButton("返回纯图 (O)") {
                        controller.toggleImageBigBangMode()
                    }
                    islandSecondaryButton("复制所选 (⌘C)") {
                        controller.commitCopyOnly()
                    }
                    islandPrimaryButton(selected.isEmpty ? "键入全文 (↵)" : "贴入所选 (↵)") {
                        controller.commitPrimaryPaste()
                    }
                } else {
                    let nonBreakCount = controller.textTokens.filter { !$0.isLineBreak }.count
                    Button {
                        controller.toggleImageBigBangMode()
                    } label: {
                        HStack(spacing: 5) {
                            if controller.isAnalyzingOCR {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "text.viewfinder")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(nonBreakCount == 0
                                 ? "大爆炸选字 (O)"
                                 : "大爆炸选字 · \(nonBreakCount) 组 (O)")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(brandCobalt)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background(Capsule().fill(brandCobalt.opacity(0.14)))
                    }
                    .buttonStyle(StageInteractiveCapsuleButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)

                    islandSecondaryButton("系统预览 (⌘L)") {
                        controller.handoffToSystemQuickLook()
                    }

                    Spacer(minLength: 6)

                    islandSecondaryButton("复制原图 (⌘C)") {
                        controller.commitCopyOnly()
                    }
                    islandPrimaryButton("直贴原图 (↵)") {
                        controller.commitPrimaryPaste()
                    }
                }
            } else if controller.isEditingText {
                Text("ESC 返回浏览 · ⌘S 存回条目 · ⌘↵ 直接贴入")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                islandSecondaryButton("保存条目 (⌘S)") {
                    controller.saveDraftBackToItem()
                }
                islandPrimaryButton("直接键入 (⌘↵)") {
                    controller.commitPrimaryPaste()
                }
            } else if controller.isTextBigBangActive {
                let selected = controller.currentSelectedAssembledText
                Text(selected.isEmpty
                     ? "点击或按住鼠标横扫划选词块"
                     : "已选 \(controller.textSelectedTokenIDs.count) 词（\(selected.count)字）：\(selected.replacingOccurrences(of: "\n", with: " "))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                islandSecondaryButton("微调 (⌘E)") {
                    _ = controller.enterTextEditMode()
                }
                islandSecondaryButton("复制所选 (⌘C)") {
                    controller.commitCopyOnly()
                }
                islandPrimaryButton(selected.isEmpty ? "直贴全文 (↵)" : "贴入所选 (↵)") {
                    controller.commitPrimaryPaste()
                }
            } else {
                Text("←/→ 切换形态 · ⌘E 原位微调 · ↑/↓ 切换历史")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                islandSecondaryButton("微调 (⌘E)") {
                    _ = controller.enterTextEditMode()
                }
                islandSecondaryButton("复制 (⌘C)") {
                    controller.commitCopyOnly()
                }
                islandPrimaryButton("键入当前 (↵)") {
                    controller.commitPrimaryPaste()
                }
            }
        }
    }

    private func islandSecondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(StageInteractiveCapsuleButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
    }

    private func islandPrimaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5.5)
                .background(Capsule().fill(brandCobalt))
        }
        .buttonStyle(StageInteractiveCapsuleButtonStyle(prominent: true))
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct StageHoverResetEpochKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

private extension EnvironmentValues {
    var stageHoverResetEpoch: Int {
        get { self[StageHoverResetEpochKey.self] }
        set { self[StageHoverResetEpochKey.self] = newValue }
    }
}

private struct StageInteractiveCapsuleButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var isCircle: Bool = false
    var destructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StageInteractiveCapsuleButtonBody(
            configuration: configuration,
            prominent: prominent,
            isCircle: isCircle,
            destructive: destructive
        )
    }
}

private struct StageInteractiveCapsuleButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    let isCircle: Bool
    let destructive: Bool
    @Environment(\.stageHoverResetEpoch) private var hoverResetEpoch: Int
    @State private var isHovered: Bool = false

    var body: some View {
        configuration.label
            .overlay {
                if isHovered {
                    if isCircle {
                        Circle()
                            .fill(hoverFillColor)
                            .overlay(Circle().strokeBorder(hoverStrokeColor, lineWidth: 0.75))
                            .allowsHitTesting(false)
                    } else {
                        Capsule()
                            .fill(hoverFillColor)
                            .overlay(Capsule().strokeBorder(hoverStrokeColor, lineWidth: 0.75))
                            .allowsHitTesting(false)
                    }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.84), value: isHovered)
            .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.82), value: configuration.isPressed)
            .onHover { hovering in
                if isHovered != hovering {
                    isHovered = hovering
                }
            }
            .onChange(of: hoverResetEpoch) { _, _ in
                if isHovered {
                    isHovered = false
                }
            }
    }

    private var hoverFillColor: Color {
        if destructive { return Color.red.opacity(0.18) }
        if prominent { return Color.white.opacity(0.14) }
        return Color.primary.opacity(0.08)
    }

    private var hoverStrokeColor: Color {
        if destructive { return Color.red.opacity(0.55) }
        if prominent { return Color.white.opacity(0.32) }
        return Color.primary.opacity(0.16)
    }
}

/// 零抖动词块胶囊组件（恒定字重杜绝点击/悬停宽度跳变 + 原位二次爆炸离心弹簧动效与电光钴蓝冲击波光环）
private struct BigBangTokenChipView: View {
    let token: BigBangTextToken
    let isSelected: Bool
    let isHovered: Bool
    let canSubdivide: Bool
    let isOverFrostedImage: Bool
    let brandCobalt: Color
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var burstSettled: Bool = true
    @State private var burstGlowOpacity: Double = 0.0
    @State private var lastAnimatedBurstGeneration: Int = 0

    var body: some View {
        let isLine = (token.granularity == .line)
        let hoverScale: CGFloat = isLine ? 1.005 : 1.028
        let selScale: CGFloat = isLine ? 1.003 : 1.015
        let baseFill: Color = {
            if isSelected {
                return brandCobalt
            }
            if isHovered {
                return brandCobalt.opacity(colorScheme == .dark ? 0.25 : 0.14)
            }
            if isOverFrostedImage {
                return colorScheme == .dark
                    ? Color.white.opacity(0.12)
                    : Color.white.opacity(0.82)
            }
            return Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.065)
        }()
        let baseStroke: Color = {
            if isSelected {
                return Color.white.opacity(isHovered ? 0.68 : 0.34)
            }
            if isHovered {
                return brandCobalt.opacity(colorScheme == .dark ? 0.78 : 0.62)
            }
            if isOverFrostedImage {
                return colorScheme == .dark
                    ? Color.white.opacity(0.18)
                    : Color.black.opacity(0.09)
            }
            return Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.085)
        }()

        let spreadOffset: CGFloat = burstSettled ? 0 : CGFloat(-token.burstSpreadIndex * 15.0)
        let burstScale: CGFloat = burstSettled ? 1.0 : 0.84
        let burstAlpha: Double = burstSettled ? 1.0 : 0.90

        Text(token.text)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(isLine ? 3 : 1)
            .truncationMode(.middle)
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .frame(maxWidth: isLine ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .fill(baseFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                            .fill(brandCobalt.opacity(burstGlowOpacity * 0.18))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .strokeBorder(
                        burstGlowOpacity > 0.02
                            ? brandCobalt.opacity(max(burstGlowOpacity, isHovered ? 0.75 : 0.25))
                            : baseStroke,
                        lineWidth: (isHovered || burstGlowOpacity > 0.1) ? 1.1 : 0.75
                    )
            )
            .overlay(alignment: .topTrailing) {
                if canSubdivide && isHovered && !isSelected && !isLine {
                    Circle()
                        .fill(brandCobalt.opacity(0.85))
                        .frame(width: 4, height: 4)
                        .padding(.top, 3.5)
                        .padding(.trailing, 3.5)
                        .transition(.opacity)
                }
            }
            .offset(x: spreadOffset, y: 0)
            .scaleEffect((isSelected ? selScale : (isHovered ? hoverScale : 1.0)) * burstScale)
            .opacity(burstAlpha)
            .zIndex(burstGlowOpacity > 0.05 ? 12 : (isHovered ? 10 : (isSelected ? 5 : 0)))
            .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.84), value: isHovered)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.86), value: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 8.5, style: .continuous))
            .onTapGesture(perform: onTap)
            .onAppear {
                triggerBurstIfNeeded()
            }
            .onChange(of: token.burstGeneration) { _, _ in
                triggerBurstIfNeeded()
            }
    }

    private func triggerBurstIfNeeded() {
        guard token.burstGeneration > 0, token.burstGeneration != lastAnimatedBurstGeneration else { return }
        lastAnimatedBurstGeneration = token.burstGeneration
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            burstSettled = true
            burstGlowOpacity = 0.72
            withAnimation(.easeOut(duration: 0.36)) {
                burstGlowOpacity = 0.0
            }
            return
        }
        burstSettled = false
        burstGlowOpacity = 0.92
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                burstSettled = true
            }
            withAnimation(.easeOut(duration: 0.46)) {
                burstGlowOpacity = 0.0
            }
        }
    }
}
