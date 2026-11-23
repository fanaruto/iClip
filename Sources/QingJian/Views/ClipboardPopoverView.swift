#if ICLIP_EDITION_FLOW
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// 列表行模型：连续图片自动聚合成 3 列网格，非图片保持单行精致卡片
enum ClipDisplayRow: Identifiable {
    case standard(index: Int, item: ClipItem)
    case imageGrid(entries: [(index: Int, item: ClipItem)])
    case todoCompletedHeader(count: Int)

    var id: String {
        switch self {
        case .standard(_, let item):
            return "row-\(item.id.uuidString)"
        case .imageGrid(let entries):
            return "grid-\(entries.first?.item.id.uuidString ?? "empty")"
        case .todoCompletedHeader:
            return "todo-completed-section-header"
        }
    }
}

/// 键盘导航、筛选缓存与出场动效控制桥接器（仅在数据/搜索/分类变动时重算列表，悬停与方向键零开销）
@MainActor
final class PanelNavigationModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var selectedTab: ClipFilterTab = .all
    @Published var selectedPinCategory: PinCategory? = nil
    @Published var selectedIndex: Int = 0
    @Published var focusTrigger: UUID = UUID()
    @Published var showSettings: Bool = false
    @Published var isPresented: Bool = false
    @Published var presentationEpoch: Int = 0
    @Published var scrollRequestEpoch: Int = 0
    @Published var isRecordingHotKey: Bool = false
    @Published var isRecordingQueueHotKey: Bool = false
    @Published var hotKeyConflictWarning: String? = nil
    @Published var hotKeyRecordingHint: String? = nil
    @Published var isEditingAlias: Bool = false
    @Published var showQuickLook: Bool = false {
        didSet {
            if showQuickLook {
                if selectedIndex >= 0 && selectedIndex < cachedFilteredItems.count {
                    quickLookAnchorID = cachedFilteredItems[selectedIndex].id
                }
            } else {
                quickLookAnchorID = nil
            }
        }
    }
    private var quickLookAnchorID: UUID? = nil
    @Published var quickLookTabIndex: Int = 0
    @Published var quickLookPreferDiff: Bool = false
    @Published var isQuickLookEditing: Bool = false
    @Published var quickLookDraftText: String = ""
    @Published var demoPreviewIndex: Int? = nil
    @Published var isDragTargeted: Bool = false
    /// Things 3 风格勾选驻留池：刚勾选完成的待办在原位停留 520ms 供视觉确认与随时撤回，随后平滑沉底
    @Published var settlingCompletedTodoIDs: Set<UUID> = []
    private var settlingWorkItems: [UUID: DispatchWorkItem] = [:]
    var suppressAutoHide: Bool = false

    private(set) var cachedFilteredItems: [ClipItem] = []
    private(set) var cachedDisplayRows: [ClipDisplayRow] = []
    private(set) var cachedVisualRows: [[Int]] = []
    var preferredGridColumn: Int? = nil
    var pointerGuard = PointerSelectionGuard()
    private weak var storeRef: ClipboardStore?
    private var cancellables = Set<AnyCancellable>()

    init(store: ClipboardStore? = nil) {
        let resolvedStore = store ?? .shared
        self.storeRef = resolvedStore
        rebuildCache(items: resolvedStore.items, tab: selectedTab, pinCat: selectedPinCategory, query: searchText)

        Publishers.CombineLatest4(resolvedStore.$items, $selectedTab, $selectedPinCategory, $searchText)
            .sink { [weak self] items, tab, pinCat, query in
                self?.rebuildCache(items: items, tab: tab, pinCat: pinCat, query: query)
            }
            .store(in: &cancellables)

        $settlingCompletedTodoIDs
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, let s = self.storeRef else { return }
                self.rebuildCache(items: s.items, tab: self.selectedTab, pinCat: self.selectedPinCategory, query: self.searchText)
            }
            .store(in: &cancellables)

        Publishers.Merge3(
            resolvedStore.$activeTargetAppName.dropFirst().map { _ in () },
            resolvedStore.$minimalModeEnabled.dropFirst().map { _ in () },
            AdaptiveIntelligenceEngine.shared.$revision.dropFirst().map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self, let s = self.storeRef else { return }
            if s.minimalModeEnabled && self.selectedTab == .todo {
                self.selectedTab = .all
                return
            }
            self.rebuildCache(items: s.items, tab: self.selectedTab, pinCat: self.selectedPinCategory, query: self.searchText)
        }
        .store(in: &cancellables)
    }

    func registerTodoCompletionSettle(for itemID: UUID, isNowCompleted: Bool) {
        settlingWorkItems[itemID]?.cancel()
        settlingWorkItems.removeValue(forKey: itemID)
        if isNowCompleted {
            settlingCompletedTodoIDs.insert(itemID)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.settlingWorkItems.removeValue(forKey: itemID)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    _ = self.settlingCompletedTodoIDs.remove(itemID)
                }
            }
            settlingWorkItems[itemID] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.52, execute: work)
        } else {
            settlingCompletedTodoIDs.remove(itemID)
        }
    }

    private func rebuildCache(items: [ClipItem], tab: ClipFilterTab, pinCat: PinCategory?, query: String) {
        let resolvedStore = storeRef ?? .shared
        let isCommandInput = (QuickSuggestionCommandBanner.extractPayload(from: query) != nil)
            || (QuickCaptureParser.parse(from: query) != nil)
            || (SecurePasswordGenerator.evaluate(query) != nil)
        let effectiveQuery = isCommandInput ? "" : query
        let rawMatched = items.filter { item in
            let tabMatches: Bool
            switch tab {
            case .all: tabMatches = true
            case .todo: tabMatches = item.isTodo
            case .pinned:
                if let pinCat {
                    tabMatches = item.isPinned && item.pinCategory == pinCat
                } else {
                    tabMatches = item.isPinned
                }
            case .text: tabMatches = item.type == .text
            case .link: tabMatches = item.type == .link
            case .image: tabMatches = item.type == .image
            case .file: tabMatches = item.type == .file
            }
            return tabMatches && item.matches(query: effectiveQuery)
        }

        let settling = self.settlingCompletedTodoIDs
        let filtered: [ClipItem]
        if tab == .todo {
            filtered = rawMatched.sorted { lhs, rhs in
                let lhsSunk = lhs.isTodoCompleted && !settling.contains(lhs.id)
                let rhsSunk = rhs.isTodoCompleted && !settling.contains(rhs.id)
                if lhsSunk != rhsSunk {
                    return !lhsSunk
                }
                if lhsSunk {
                    let ld = lhs.todoCompletedAt ?? lhs.createdAt
                    let rd = rhs.todoCompletedAt ?? rhs.createdAt
                    return ld > rd
                }
                return lhs.createdAt > rhs.createdAt
            }
        } else if resolvedStore.minimalModeEnabled {
            filtered = rawMatched
        } else if !effectiveQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = SmartSearchRanker.rankSearchResults(
                rawMatched,
                query: effectiveQuery,
                targetApp: resolvedStore.activeTargetAppName,
                engine: .shared
            )
        } else if tab == .pinned {
            filtered = SmartSearchRanker.rankPinnedItemsForContext(
                rawMatched,
                targetApp: resolvedStore.activeTargetAppName,
                engine: .shared
            )
        } else {
            filtered = rawMatched
        }

        var rows: [ClipDisplayRow] = []
        rows.reserveCapacity(filtered.count + 1)
        var imageBuffer: [(index: Int, item: ClipItem)] = []
        let sunkDoneCount = (tab == .todo) ? filtered.filter { $0.isTodoCompleted && !settling.contains($0.id) }.count : 0
        var hasInsertedDoneHeader = false

        for (index, item) in filtered.enumerated() {
            if tab == .todo && !hasInsertedDoneHeader && sunkDoneCount > 0 && item.isTodoCompleted && !settling.contains(item.id) {
                hasInsertedDoneHeader = true
                if index > 0 {
                    rows.append(.todoCompletedHeader(count: sunkDoneCount))
                }
            }
            if item.type == .image && tab != .todo {
                imageBuffer.append((index: index, item: item))
            } else {
                if !imageBuffer.isEmpty {
                    rows.append(.imageGrid(entries: imageBuffer))
                    imageBuffer.removeAll(keepingCapacity: true)
                }
                rows.append(.standard(index: index, item: item))
            }
        }
        if !imageBuffer.isEmpty {
            rows.append(.imageGrid(entries: imageBuffer))
        }

        self.cachedFilteredItems = filtered
        if showQuickLook {
            if let anchor = quickLookAnchorID, !filtered.contains(where: { $0.id == anchor }) {
                showQuickLook = false
                isQuickLookEditing = false
                quickLookDraftText = ""
            } else if filtered.isEmpty {
                showQuickLook = false
                isQuickLookEditing = false
                quickLookDraftText = ""
            }
        }
        self.cachedDisplayRows = rows
        self.cachedVisualRows = GridNavigationHelper.buildVisualRows(count: filtered.count, imageColumns: 3) {
            tab != .todo && filtered[$0].type == .image
        }
    }

    func resetOnOpen() {
        searchText = ""
        selectedIndex = 0
        preferredGridColumn = nil
        showSettings = false
        showQuickLook = false
        quickLookPreferDiff = false
        isQuickLookEditing = false
        quickLookDraftText = ""
        isEditingAlias = false
        isRecordingHotKey = false
        isRecordingQueueHotKey = false
        hotKeyConflictWarning = nil
        hotKeyRecordingHint = nil
        suppressAutoHide = false
        isDragTargeted = false
        lockPointerAtCurrentMouse()
        presentationEpoch &+= 1
        focusTrigger = UUID()
    }

    func lockPointerAtCurrentMouse() {
        pointerGuard.lock(
            at: NSEvent.mouseLocation,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    func selectExplicitly(_ index: Int) {
        pointerGuard.unlock()
        if selectedIndex != index {
            selectedIndex = index
        }
    }

    @discardableResult
    func selectByHover(_ index: Int) -> Bool {
        guard pointerGuard.allowHoverSelection(
            currentMouseLocation: NSEvent.mouseLocation,
            uptime: ProcessInfo.processInfo.systemUptime
        ) else {
            return false
        }
        if selectedIndex != index {
            selectedIndex = index
        }
        return true
    }
}

/// 主面板视图（苹果原生毛玻璃 / 液态玻璃内容层）
struct ClipboardPopoverView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var nav: PanelNavigationModel
    @ObservedObject private var updater = UpdateManager.shared
    @ObservedObject private var playground = InteractivePlaygroundController.shared
    let onDismiss: () -> Void
    let onQuit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFocused: Bool

    private var glassPalette: LiquidGlassPalette {
        LiquidGlassPalette(
            colorScheme: colorScheme,
            surfaceStyle: store.surfaceStyle,
            appearance: store.liquidGlassAppearance
        )
    }
    @State private var previewItem: ClipItem? = nil
    @State private var previewTileRect: CGRect = .zero
    @State private var isPreviewVisible: Bool = false
    @State private var hoveredTileItemID: UUID? = nil
    @State private var previewHideWorkItem: DispatchWorkItem? = nil
    @State private var aliasEditingItem: ClipItem? = nil
    @State private var aliasDraftText: String = ""
    @State private var showShortcutReference: Bool = false
    @FocusState private var isAliasFieldFocused: Bool

    var filteredItems: [ClipItem] {
        nav.cachedFilteredItems
    }

    private var displayRows: [ClipDisplayRow] {
        nav.cachedDisplayRows
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                if nav.showSettings {
                    settingsView
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    if !store.minimalModeEnabled && (!store.hasConfirmedRoleEdition || store.targetRoleEdition != AppRoleEdition.installed) {
                        RoleOnboardingBanner(
                            store: store,
                            updater: updater,
                            onOpenSettings: { nav.showSettings = true }
                        )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    filterBar
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)

                    searchCommandOverlayBanner

                    if !store.minimalModeEnabled && nav.selectedTab == .todo && (!filteredItems.isEmpty || store.completedTodoCount > 0) {
                        todoSummaryBar
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if !store.minimalModeEnabled && isSensitiveAuditQuery && store.unpinnedSensitiveCount > 0 {
                        sensitiveAuditSummaryBar
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if !store.minimalModeEnabled && nav.selectedTab == .pinned {
                        pinCategoryBar
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if !store.minimalModeEnabled && (store.isQueueModeActive || !store.pasteQueueIDs.isEmpty) {
                        pasteQueueBanner
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if let editing = aliasEditingItem {
                        inlineAliasEditorBar(for: editing)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if !store.borderlessPanel {
                        Divider()
                            .opacity(0.28)
                    }

                    contentList
                        .transition(.opacity)

                    if !store.borderlessPanel {
                        Divider()
                            .opacity(0.28)
                    }

                    if !store.minimalModeEnabled && !store.selectedMergeIDs.isEmpty {
                        mergeActionBar
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    footerBar
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(glassPalette.footerBackdrop)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(glassPalette.controlCapsuleStroke.opacity(store.surfaceStyle == .liquidGlass ? 0.6 : 0), lineWidth: 0.6)
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 5)
                        .padding(.bottom, 9)
                }
            }
            .frame(width: 420, height: 560)

            // iOS 灵动胶囊轻提示
            if let message = store.toastMessage {
                toastPill(message)
                    .padding(.bottom, 46)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 420, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            if store.surfaceStyle != .liquidGlass && !store.borderlessPanel {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        // 纯净原图放大预览浮层
        .overlay {
            ImageHoverPreviewLayer(
                item: previewItem,
                tileRect: previewTileRect,
                isVisible: isPreviewVisible,
                panelSize: CGSize(width: 420, height: 560)
            )
        }
        // 外部内容拖放复制高亮反馈浮层
        .overlay {
            if nav.isDragTargeted {
                dragDropOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        // 首次启动苹果风极简重点功能速览浮层
        .overlay {
            if playground.isActive && !nav.showSettings {
                CoreHighlightsOverlay(
                    controller: playground,
                    store: store,
                    glassPalette: glassPalette
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        // QuickLook 全模态速览与原位微调浮层（Space / ⌘Y）
        .overlay {
            if nav.showQuickLook,
               nav.selectedIndex >= 0,
               nav.selectedIndex < filteredItems.count {
                let target = filteredItems[nav.selectedIndex]
                SemanticQuickLookOverlay(
                    item: target,
                    tabs: QuickLookTabBuilder.buildTabs(for: target, store: store),
                    selectedPreviewIndex: $nav.quickLookTabIndex,
                    isEditing: $nav.isQuickLookEditing,
                    draftText: $nav.quickLookDraftText,
                    preferDiffOnOpen: nav.quickLookPreferDiff,
                    onCommitPasteText: { content, toast in
                        nav.isQuickLookEditing = false
                        nav.showQuickLook = false
                        store.pasteCustomString(content, sourceItem: target, toast: toast, shouldAutoPaste: true, onBeforePaste: onDismiss)
                    },
                    onCommitPasteImage: {
                        nav.isQuickLookEditing = false
                        nav.showQuickLook = false
                        store.copyAndOptionallyPaste(target, plainTextOnly: false, shouldAutoPaste: true, onBeforePaste: onDismiss)
                    },
                    onSaveToItem: { updatedText in
                        if store.updateItemText(updatedText, for: target) {
                            nav.isQuickLookEditing = false
                        }
                    },
                    onClose: {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                            nav.isQuickLookEditing = false
                            nav.showQuickLook = false
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .coordinateSpace(name: "panelRoot")
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: nav.showSettings)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: store.toastMessage)
        .onChange(of: nav.isPresented) { _, presented in
            if presented {
                playground.cleanupLegacySamplesIfAny(in: store)
                store.onPanelShown(visibleItems: filteredItems)
            } else {
                aliasEditingItem = nil
                dismissImagePreview(clearItem: true)
                store.onPanelHidden()
            }
        }
        .onChange(of: nav.focusTrigger) { _, _ in
            dismissImagePreview(clearItem: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
        .onChange(of: nav.searchText) { _, _ in
            nav.selectedIndex = 0
            nav.lockPointerAtCurrentMouse()
            dismissImagePreview(clearItem: true)
        }
        .onChange(of: nav.selectedTab) { _, _ in
            TactileFeedbackEngine.shared.perform(.tabSwitch)
            nav.selectedIndex = 0
            nav.lockPointerAtCurrentMouse()
            dismissImagePreview(clearItem: true)
        }
        .onChange(of: nav.demoPreviewIndex) { _, targetIdx in
            if let idx = targetIdx, idx >= 0, idx < filteredItems.count {
                let item = filteredItems[idx]
                nav.selectedIndex = idx
                // 估算第 1 行 3 列图片格在面板内的真实位置触发原生纯净原图放大浮层
                let col = max(0, min(2, idx - 1))
                let tileRect = CGRect(x: 14 + CGFloat(col) * 134, y: 196, width: 124, height: 98)
                handleImageHover(item: item, hovering: true, tileRect: tileRect)
            } else {
                dismissImagePreview(clearItem: true)
            }
        }
        .onChange(of: nav.showSettings) { _, showing in
            dismissImagePreview(clearItem: true)
            if showing {
                store.refreshAccessibilityStatus()
                store.pruneUnavailableIgnoredApps()
            } else if nav.isRecordingHotKey || nav.isRecordingQueueHotKey {
                nav.isRecordingHotKey = false
                nav.isRecordingQueueHotKey = false
                nav.hotKeyConflictWarning = nil
                HotKeyManager.shared.resumeAfterRecording()
            } else {
                nav.hotKeyConflictWarning = nil
            }
        }
    }

    @ViewBuilder
    private var searchCommandOverlayBanner: some View {
        if QuickSuggestionCommandBanner.extractPayload(from: nav.searchText) != nil {
            QuickSuggestionCommandBanner(rawQuery: nav.searchText) { payload in
                let outcome = AdaptiveIntelligenceEngine.shared.adoptUserSuggestion(payload, in: store)
                nav.searchText = ""
                store.showToast(outcome.message)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let capture = QuickCaptureParser.parse(from: nav.searchText) {
            QuickCaptureCommandBanner(
                intent: capture,
                onCommitDefault: {
                    guard !capture.isEmptyBody else { return }
                    if capture.defaultTodo {
                        store.captureQuickTodo(body: capture.bodyText, alias: capture.customAlias, copyToClipboard: false)
                    } else {
                        store.captureQuickNote(body: capture.bodyText, alias: capture.customAlias, pin: capture.defaultPin)
                    }
                    nav.searchText = ""
                },
                onCommitForcePin: {
                    guard !capture.isEmptyBody else { return }
                    if capture.defaultTodo {
                        store.captureQuickTodo(body: capture.bodyText, alias: capture.customAlias, copyToClipboard: true)
                    } else {
                        store.captureQuickNote(body: capture.bodyText, alias: capture.customAlias, pin: true)
                    }
                    nav.searchText = ""
                }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let pwGen = SecurePasswordGenerator.evaluate(nav.searchText) {
            SecurePasswordCardView(
                candidate: pwGen,
                onCommitEphemeral: {
                    nav.searchText = ""
                    store.pasteEphemeralSecret(pwGen.secretValue, toast: pwGen.ephemeralToast, shouldAutoPaste: true, onBeforePaste: onDismiss)
                },
                onCommitPinToVault: {
                    SecurePasswordGenerator.bumpGenerationSalt()
                    nav.searchText = ""
                    store.captureQuickNote(body: pwGen.secretValue, alias: pwGen.defaultVaultAlias, pin: true)
                    onDismiss()
                }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let math = InstantMathEvaluator.evaluate(nav.searchText, latestClipboardText: store.items.first?.text) {
            InstantMathCardView(
                math: math,
                onCommitPlain: {
                    nav.searchText = ""
                    store.pasteInstantValue(math.plainValue, toast: "已键入计算结果 \(math.plainValue)", shouldAutoPaste: true, onBeforePaste: onDismiss)
                },
                onCommitRMB: math.rmbUppercase.map { rmb in
                    {
                        nav.searchText = ""
                        store.pasteInstantValue(rmb, toast: "已键入大写金额", shouldAutoPaste: true, onBeforePaste: onDismiss)
                    }
                }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if nav.selectedTab == .todo,
                  !nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@") {
            todoInlineCreateBanner
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - 顶部胶囊搜索栏

    private var headerBar: some View {
        HStack(spacing: 8) {
            if nav.showSettings {
                Button {
                    nav.showSettings = false
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(
                        Capsule()
                            .fill(glassPalette.controlCapsuleFill)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(glassPalette.controlCapsuleStroke, lineWidth: 0.7)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 7) {
                    BrandAppIconBadge(size: 20)
                    Text("iClip 设置 · \(AppRoleEdition.installed.title)")
                        .font(.system(size: 14, weight: .semibold))
                }

                Spacer()

                Color.clear.frame(width: 48, height: 1)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField(
                        nav.selectedTab == .todo ? "搜索待办，或直接输入事项按 ↵ 新建..." : "搜索剪贴历史...",
                        text: $nav.searchText
                    )
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .focused($isSearchFocused)

                    if !nav.searchText.isEmpty {
                        Button {
                            nav.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(glassPalette.controlCapsuleFill)
                )
                .overlay {
                    Capsule()
                        .strokeBorder(glassPalette.controlCapsuleStroke, lineWidth: 0.75)
                }

                // 顺序粘贴队列采集开关按钮
                if !store.minimalModeEnabled {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        store.isQueueModeActive.toggle()
                    }
                    store.showToast(store.isQueueModeActive ? "已开启顺序采集：连续 ⌘C 按序入队" : "已结束顺序采集")
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "list.number")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(store.isQueueModeActive ? Color.white : Color.secondary)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(store.isQueueModeActive ? Color.accentColor : Color.primary.opacity(0.06))
                            )

                        if !store.pasteQueueIDs.isEmpty {
                            Text("\(min(store.pasteQueueIDs.count, 99))")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange))
                                .offset(x: 4, y: -3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isQueueModeActive ? "关闭顺序粘贴队列采集" : "开启顺序粘贴队列采集")
                .help(store.isQueueModeActive ? "关闭顺序队列采集" : "开启顺序粘贴队列（解决多字段来回切窗填表）")
                }

                // 窗口始终在前一键固定圆钮（⌘P）
                AlwaysOnTopPinButton(store: store, glassPalette: glassPalette)

                // 极简纯净模式（基础功能版）一键切换圆钮（⌘E）
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        store.toggleMinimalMode()
                    }
                } label: {
                    Image(systemName: store.minimalModeEnabled ? "leaf.fill" : "leaf")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(store.minimalModeEnabled ? Color.white : Color.secondary)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(store.minimalModeEnabled ? Color.green : glassPalette.controlCapsuleFill)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(glassPalette.controlCapsuleStroke.opacity(store.minimalModeEnabled ? 0.3 : 0.85), lineWidth: 0.65)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("极简纯净模式开关")
                .help(store.minimalModeEnabled ? "极简基础版已开启（点击或按 ⌘E 恢复进阶功能）" : "开启极简纯净模式（基础功能版 · ⌘E）")

                // 暂停/恢复监听按钮（单击开启 15 分钟无痕自动恢复暂停，右键可选时长或持续暂停）
                Button {
                    store.toggleTimedPause(defaultMinutes: 15)
                } label: {
                    Image(systemName: store.isPaused ? "pause.circle.fill" : "record.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(store.isPaused ? Color.orange : Color.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(glassPalette.controlCapsuleFill))
                        .overlay(Circle().strokeBorder(glassPalette.controlCapsuleStroke.opacity(0.85), lineWidth: 0.65))
                }
                .buttonStyle(.plain)
                .help(store.pauseStatusSummary)
                .contextMenu {
                    if store.isPaused {
                        Button("立即恢复记录剪贴板") { store.resumeCapture() }
                        Divider()
                    }
                    Button("无痕暂停 5 分钟（自动恢复）") {
                        store.pauseCapture(forMinutes: 5)
                        store.showToast("已开启 5 分钟无痕暂停（到点自动恢复）")
                    }
                    Button("无痕暂停 15 分钟（推荐 · 自动恢复）") {
                        store.pauseCapture(forMinutes: 15)
                        store.showToast("已开启 15 分钟无痕暂停（到点自动恢复）")
                    }
                    Button("无痕暂停 60 分钟（自动恢复）") {
                        store.pauseCapture(forMinutes: 60)
                        store.showToast("已开启 60 分钟无痕暂停（到点自动恢复）")
                    }
                    Divider()
                    Button("持续暂停（直到手动恢复）") {
                        store.pauseCapture(forMinutes: nil)
                        store.showToast("已持续暂停记录剪贴板")
                    }
                }

                // 设置按钮（有 GitHub 新版本时右上角展示蓝点提示）
                Button {
                    store.refreshAccessibilityStatus()
                    nav.showSettings = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(glassPalette.controlCapsuleFill))
                            .overlay(Circle().strokeBorder(glassPalette.controlCapsuleStroke.opacity(0.85), lineWidth: 0.65))

                        if updater.hasUpdateAvailable {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
                                .offset(x: -1, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(updater.hasUpdateAvailable ? "发现新版本，点击进入设置更新" : "偏好设置")
            }
        }
    }

    // MARK: - iOS 滑动胶囊分类条（独立隔离渲染 + 常驻 GPU 硬件偏移滑块，120Hz 满帧零列表重绘干扰）

    private var filterBar: some View {
        let tabs = ClipFilterTab.visibleTabs(minimalMode: store.minimalModeEnabled)
        let selectedIdx = tabs.firstIndex(of: nav.selectedTab) ?? 0
        let pendingTodos = store.pendingTodoCount

        return GeometryReader { geo in
            let inset: CGFloat = 3
            let innerWidth = max(0, geo.size.width - inset * 2)
            let pillWidth = innerWidth / CGFloat(max(1, tabs.count))

            ZStack(alignment: .leading) {
                // 常驻单一选中胶囊滑块：仅做 GPU 水平位移，永不销毁重建、永不被列表 diff 打断
                Capsule()
                    .fill(glassPalette.activeSegmentFill)
                    .overlay(
                        Capsule()
                            .strokeBorder(glassPalette.controlCapsuleStroke, lineWidth: 0.6)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: 2.5, y: 1)
                    .frame(width: pillWidth, height: 28)
                    .offset(x: inset + CGFloat(selectedIdx) * pillWidth)
                    .animation(.spring(response: 0.22, dampingFraction: 0.84), value: nav.selectedTab)

                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        let isSelected = nav.selectedTab == tab
                        Button {
                            guard nav.selectedTab != tab else { return }
                            nav.selectedTab = tab
                        } label: {
                            HStack(spacing: 2.5) {
                                Text(tab.title)
                                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                if tab == .todo && pendingTodos > 0 {
                                    Text("\(min(pendingTodos, 99))")
                                        .font(.system(size: 10, weight: .bold))
                                        .monospacedDigit()
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.accentColor.opacity(0.9))
                                }
                            }
                            .frame(width: pillWidth, height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(tab.title)（\(tab.optionShortcutLabel(minimalMode: store.minimalModeEnabled))）")
                    }
                }
                .padding(.horizontal, inset)
            }
            .frame(width: geo.size.width, height: 34)
            .background(
                Capsule()
                    .fill(glassPalette.controlCapsuleFill)
            )
            .overlay(
                Capsule()
                    .strokeBorder(glassPalette.controlCapsuleStroke.opacity(0.75), lineWidth: 0.6)
            )
        }
        .frame(height: 34)
    }

    private var isSensitiveAuditQuery: Bool {
        let q = nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let auditTokens = ["@敏感", "@密钥", "@隐私", "@secret", "敏感", "@即焚", "@burn"]
        return auditTokens.contains { q == $0 || q.hasPrefix($0 + " ") || q.hasSuffix(" " + $0) }
    }

    private var sensitiveAuditSummaryBar: some View {
        let count = store.unpinnedSensitiveCount
        return HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.orange)

            Text("检出 \(count) 条未收藏敏感凭据")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(0.88))

            Text("· 收藏项永久保护")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                    _ = store.sweepAllUnpinnedSensitiveItems()
                    clampSelection()
                }
            } label: {
                Text("一键无痕清扫")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.orange.opacity(0.13)))
            }
            .buttonStyle(.plain)
            .help("彻底清除所有未收藏、非待办的敏感密钥、身份证与即焚残留（收藏项不受影响）")
        }
    }

    private var todoSummaryBar: some View {
        let pending = store.pendingTodoCount
        let done = store.completedTodoCount
        return HStack(spacing: 6) {
            Circle()
                .fill(pending > 0 ? Color.accentColor : Color(red: 0.06, green: 0.72, blue: 0.51))
                .frame(width: 6.5, height: 6.5)

            Text(pending > 0 ? "待完成 \(pending) 项" : "待办已全部完成")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(pending > 0 ? Color.primary.opacity(0.88) : Color(red: 0.06, green: 0.72, blue: 0.51))

            Text("· ⌘T 勾销 · ⌘P 钉桌面")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if pending + done > 0 {
                Button {
                    _ = store.copyTodosAsMarkdownChecklist()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "list.clipboard")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("复制清单")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("导出为 Markdown 任务清单（- [ ] / - [x]），一键贴入周报或飞书")
            }

            if done > 0 {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                        _ = store.archiveCompletedTodos()
                        clampSelection()
                    }
                } label: {
                    Text("归档已完成 (\(done))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.11)))
                }
                .buttonStyle(.plain)
                .help("将已完成事项移出待办清单（保留原剪贴记录）")
            }
        }
    }

    private var todoInlineCreateBanner: some View {
        let trimmed = nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let (alias, body) = QuickCaptureParser.splitAliasAndBody(trimmed)
        let isEmptyMatch = filteredItems.isEmpty
        return HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let alias {
                        Text(alias)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                        Text("·")
                            .foregroundStyle(.secondary)
                    }
                    Text(body)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(isEmptyMatch ? "按 ↵ 直接新建为待办（保留当前剪贴板）" : "按 ⌘↵ 新建为待办（按 ↵ 粘贴下方匹配项）")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                _ = commitEmptySearchCaptureIfApplicable(forcePin: false, allowNonEmptyMatchInTodo: true)
            } label: {
                Text(isEmptyMatch ? "新建 ↵" : "新建 ⌘↵")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.accentColor.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.65)
        )
    }

    private func todoCompletedSectionHeader(count: Int) -> some View {
        HStack(spacing: 7) {
            Text("已完成 · \(count)")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.75)
            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                    _ = store.archiveCompletedTodos()
                    clampSelection()
                }
            } label: {
                Text("清空已完成")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 1)
    }

    private var pinCategoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                let allActive = (nav.selectedPinCategory == nil)
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        nav.selectedPinCategory = nil
                    }
                } label: {
                    Text("全部收藏")
                        .font(.system(size: 11, weight: allActive ? .semibold : .medium))
                        .foregroundStyle(allActive ? Color.white : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(allActive ? Color.accentColor : Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)

                ForEach(PinCategory.allCases) { cat in
                    let active = (nav.selectedPinCategory == cat)
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            nav.selectedPinCategory = active ? nil : cat
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(active ? Color.white : cat.dotColor)
                                .frame(width: 6, height: 6)
                            Text(cat.title)
                                .font(.system(size: 11, weight: active ? .semibold : .medium))
                        }
                        .foregroundStyle(active ? Color.white : Color.primary.opacity(0.82))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(active ? cat.dotColor : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func inlineAliasEditorBar(for target: ClipItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tag.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            TextField("输入备注名（如：深圳总公司税号），留空清除", text: $aliasDraftText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isAliasFieldFocused)
                .onSubmit {
                    store.setCustomAlias(aliasDraftText, for: target)
                    aliasEditingItem = nil
                    nav.isEditingAlias = false
                }

            Button("保存") {
                store.setCustomAlias(aliasDraftText, for: target)
                aliasEditingItem = nil
                nav.isEditingAlias = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(Color.accentColor))

            Button {
                aliasEditingItem = nil
                nav.isEditingAlias = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.065))
        )
    }

    // MARK: - 原生 FIFO 顺序粘贴队列状态条

    private var pasteQueueBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                if let next = store.nextQueuedItem {
                    Text("队列待贴 \(store.pasteQueueIDs.count) 项 · #1 \(next.primaryTitle)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                } else {
                    Text("顺序队列采集中 · 连续 ⌘C 或按 ⌘K 将条目按序排入")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if !store.pasteQueueIDs.isEmpty {
                Button {
                    store.dequeueAndPasteNext(onBeforePaste: onDismiss)
                } label: {
                    Text("键入 #1 ⇥")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        store.clearPasteQueue()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("清空顺序队列")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.accentColor.opacity(0.09))
        )
    }

    // MARK: - 剪贴记录列表

    private let imageGridColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 9),
        count: 3
    )

    private var contentList: some View {
        Group {
            if filteredItems.isEmpty {
                emptyStateView
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach(Array(displayRows.enumerated()), id: \.element.id) { rowIndex, row in
                                switch row {
                                case .standard(let index, let item):
                                    ClipCardView(
                                        item: item,
                                        index: index,
                                        isSelected: index == nav.selectedIndex,
                                        minimalMode: store.minimalModeEnabled,
                                        queueRank: store.queuePosition(for: item),
                                        mergeRank: store.mergeSelectionRank(for: item),
                                        surfaceStyle: store.surfaceStyle,
                                        liquidGlassAppearance: store.liquidGlassAppearance,
                                        borderlessPanel: store.borderlessPanel,
                                        onSelect: {
                                            nav.selectExplicitly(index)
                                        },
                                        onHoverSelect: {
                                            nav.selectByHover(index)
                                        },
                                        onPaste: { plainTextOnly in
                                            store.copyAndOptionallyPaste(
                                                item,
                                                plainTextOnly: plainTextOnly,
                                                shouldAutoPaste: true,
                                                onBeforePaste: onDismiss
                                            )
                                        },
                                        onCopyOnly: { plainTextOnly in
                                            store.copyAndOptionallyPaste(
                                                item,
                                                plainTextOnly: plainTextOnly,
                                                shouldAutoPaste: false,
                                                onBeforePaste: nil
                                            )
                                        },
                                        onToggleQueue: {
                                            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                                                store.toggleQueueMembership(item)
                                            }
                                        },
                                        onToggleMerge: {
                                            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                                                store.toggleMergeSelection(item)
                                            }
                                        },
                                        onExtractOCR: { autoPaste in
                                            store.pasteExtractedOCRText(
                                                for: item,
                                                shouldAutoPaste: autoPaste,
                                                onBeforePaste: autoPaste ? onDismiss : nil
                                            )
                                        },
                                        onApplyFinanceAction: { action, autoPaste in
                                            store.applyFinanceAction(
                                                action,
                                                for: item,
                                                shouldAutoPaste: autoPaste,
                                                onBeforePaste: autoPaste ? onDismiss : nil
                                            )
                                        },
                                        onTogglePin: {
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                store.togglePin(item)
                                            }
                                        },
                                        onSelectPinCategory: { category in
                                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                                store.setPinCategory(category, for: item)
                                            }
                                        },
                                        onEditAlias: {
                                            beginAliasEdit(for: item)
                                        },
                                        onToggleTodo: {
                                            let willComplete = item.isPendingTodo
                                            if nav.selectedTab == .todo {
                                                nav.registerTodoCompletionSettle(for: item.id, isNowCompleted: willComplete)
                                            }
                                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                                store.toggleTodo(item)
                                            }
                                        },
                                        onToggleTodoCompletion: {
                                            let willComplete = item.isPendingTodo
                                            if nav.selectedTab == .todo {
                                                nav.registerTodoCompletionSettle(for: item.id, isNowCompleted: willComplete)
                                            }
                                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                                store.toggleTodoCompletion(item)
                                            }
                                        },
                                        onRemoveTodo: {
                                            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                                                store.removeFromTodo(item)
                                                clampSelection()
                                            }
                                        },
                                        onOpenQuickLook: {
                                            nav.selectedIndex = index
                                            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                                nav.showQuickLook = true
                                            }
                                        },
                                        onImageThumbnailHover: { hovering, rect in
                                            handleImageHover(item: item, hovering: hovering, tileRect: rect)
                                        },
                                        onDelete: {
                                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                                store.delete(item)
                                                clampSelection()
                                            }
                                        }
                                    )
                                    .cascadeAppear(
                                        isPresented: nav.isPresented,
                                        delay: Double(min(rowIndex, 8)) * 0.028
                                    )
                                    .id(item.id)

                                case .imageGrid(let entries):
                                    LazyVGrid(columns: imageGridColumns, spacing: 9) {
                                        ForEach(Array(entries.enumerated()), id: \.element.item.id) { colIndex, entry in
                                            ClipImageGridTile(
                                                item: entry.item,
                                                index: entry.index,
                                                isSelected: entry.index == nav.selectedIndex,
                                                queueRank: store.queuePosition(for: entry.item),
                                                onSelect: {
                                                    nav.selectExplicitly(entry.index)
                                                },
                                                onHoverSelect: {
                                                    nav.selectByHover(entry.index)
                                                },
                                                onPaste: {
                                                    dismissImagePreview(clearItem: true)
                                                    store.copyAndOptionallyPaste(
                                                        entry.item,
                                                        plainTextOnly: false,
                                                        shouldAutoPaste: true,
                                                        onBeforePaste: onDismiss
                                                    )
                                                },
                                                onCopyOnly: {
                                                    store.copyAndOptionallyPaste(
                                                        entry.item,
                                                        plainTextOnly: false,
                                                        shouldAutoPaste: false,
                                                        onBeforePaste: nil
                                                    )
                                                },
                                                onToggleQueue: {
                                                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                                                        store.toggleQueueMembership(entry.item)
                                                    }
                                                },
                                                onExtractOCR: { autoPaste in
                                                    dismissImagePreview(clearItem: true)
                                                    store.pasteExtractedOCRText(
                                                        for: entry.item,
                                                        shouldAutoPaste: autoPaste,
                                                        onBeforePaste: autoPaste ? onDismiss : nil
                                                    )
                                                },
                                                onTogglePin: {
                                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                        store.togglePin(entry.item)
                                                    }
                                                },
                                                onToggleTodo: {
                                                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                                        store.toggleTodo(entry.item)
                                                    }
                                                },
                                                onRemoveTodo: {
                                                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                                                        store.removeFromTodo(entry.item)
                                                        clampSelection()
                                                    }
                                                },
                                                onEditAlias: {
                                                    beginAliasEdit(for: entry.item)
                                                },
                                                onOpenQuickLook: {
                                                    dismissImagePreview(clearItem: true)
                                                    nav.selectedIndex = entry.index
                                                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                                        nav.showQuickLook = true
                                                    }
                                                },
                                                onDelete: {
                                                    if previewItem?.id == entry.item.id {
                                                        dismissImagePreview(clearItem: true)
                                                    }
                                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                                        store.delete(entry.item)
                                                        clampSelection()
                                                    }
                                                },
                                                onHoverChange: { hovering, tileRect in
                                                    handleImageHover(item: entry.item, hovering: hovering, tileRect: tileRect)
                                                }
                                            )
                                            .cascadeAppear(
                                                isPresented: nav.isPresented,
                                                delay: Double(min(rowIndex, 7)) * 0.028 + Double(min(colIndex, 8)) * 0.02
                                            )
                                            .id(entry.item.id)
                                        }
                                    }
                                    .padding(.vertical, 2)

                                case .todoCompletedHeader(let count):
                                    todoCompletedSectionHeader(count: count)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: nav.scrollRequestEpoch) { _, _ in
                        let idx = nav.selectedIndex
                        guard idx >= 0, idx < filteredItems.count else { return }
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo(filteredItems[idx].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        let isTodoTab = (nav.selectedTab == .todo)
        return VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 64, height: 64)
                Image(systemName: nav.searchText.isEmpty ? (isTodoTab ? "checkmark.circle" : "clipboard") : "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text(nav.searchText.isEmpty ? (isTodoTab ? "暂无待办事项" : "暂无剪贴记录") : "未找到匹配的内容")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
            Text(
                nav.searchText.isEmpty
                    ? (isTodoTab ? "对任意剪贴记录按 ⌘T 加入待办，或在上方输入 - 事项 回车速记" : "复制文本、链接、图片或文件后将自动出现在这里")
                    : (isTodoTab ? "按回车将上方输入直接添加为新待办事项" : "试试更换关键词，或将上方输入直接沉淀为新剪贴记录")
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 36)

            let trimmedSearch = nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSearch.isEmpty && !trimmedSearch.hasPrefix("@") {
                HStack(spacing: 8) {
                    Button {
                        _ = commitEmptySearchCaptureIfApplicable(forcePin: false)
                    } label: {
                        Text(isTodoTab ? "新建待办 ↵" : "存为新记录 ⌘↵")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5.5)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)

                    if !isTodoTab {
                        Button {
                            _ = commitEmptySearchCaptureIfApplicable(forcePin: true)
                        } label: {
                            Text("直接收藏 ⇧⌘↵")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5.5)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 多选摘录合并工具条

    private var mergeActionBar: some View {
        HStack(spacing: 6) {
            Text("已选 \(store.selectedMergeIDs.count) 条")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.green)

            Spacer(minLength: 4)

            ForEach(MergeJoinStyle.allCases) { style in
                Button {
                    store.mergeAndPasteSelected(style: style, shouldAutoPaste: true, onBeforePaste: onDismiss)
                } label: {
                    HStack(spacing: 3) {
                        Text(style.title)
                        if style == .paragraphs {
                            Text("⌘↵")
                                .opacity(0.75)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(style == .paragraphs ? Color.white : Color.primary.opacity(0.88))
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(style == .paragraphs ? Color.accentColor : Color.primary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    store.clearMergeSelection()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("清空多选勾选")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.green.opacity(0.09))
        )
    }

    // MARK: - 底部状态栏

    private var footerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.isPaused ? Color.orange : Color.green)
                    .frame(width: 6.5, height: 6.5)
                Text("\(filteredItems.count) 条")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 6)

            // 恒定提示项：禁止在图片与文字 hover 切换时动态增删变长，保证底部胶囊零抖动
            HStack(spacing: 7) {
                keyHint("↵", "键入")
                if !store.minimalModeEnabled {
                    keyHint("⇧↵", "转换")
                }
                keyHint("⇥", store.pasteQueueIDs.isEmpty ? "类目" : "出队")
                keyHint("ESC", "关闭")
            }

            if !store.items.filter({ !$0.isPinned }).isEmpty {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        store.clearUnpinned()
                        nav.selectedIndex = 0
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("清空未收藏记录")
            }
        }
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            Text(label)
                .font(.system(size: 10.5))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(.secondary)
    }

    // MARK: - iOS 风格设置页

    private var settingsView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                if !store.isAccessibilityGranted {
                    settingsGroup(title: "辅助功能权限") {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("开启一键直接键入权限")
                                    .font(.system(size: 13.5, weight: .medium))
                                Text("授权后双击或按回车即可直接粘贴至当前光标位置")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button {
                                store.refreshAccessibilityStatus()
                                if store.isAccessibilityGranted {
                                    store.showToast("已检测到辅助功能授权")
                                } else {
                                    store.showToast("仍未生效：若已勾选旧版，请减号移除后重勾")
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(Color.primary.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .help("立即重新检测权限状态")

                            Button("前往开启") {
                                store.requestAccessibilityPermission()
                                store.openAccessibilitySettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }

                // 苹果官方风格液态玻璃背景模糊浓度（单一滑块 + 实时实景折射预览）
                settingsGroup(title: "液态玻璃") {
                    LiquidGlassBlurStyleCard(blurConcentration: $store.liquidGlassMaskOpacity)
                }

                // 模式与角色版本切换
                settingsGroup(title: "模式与版本") {
                    RoleAndOTASettingsSection(store: store, updater: updater)
                }

                // 通用与快捷键
                settingsGroup(title: "通用与快捷键") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("窗口始终在前（⌘P）")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("固定面板置顶，切换窗口与连续粘贴时不自动收起")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $store.alwaysOnTop)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.35)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自动启动")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("登录 macOS 后自动在菜单栏常驻运行")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLogin($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }

                    Divider().opacity(0.35)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("交互音效反馈")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("键入、收藏与转换时播放轻柔微音效（关闭后仍保留触控板震动）")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $store.soundEffectsEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.35)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("全局呼出快捷键")
                                .font(.system(size: 13.5, weight: .medium))
                            if nav.isRecordingHotKey, let conflict = nav.hotKeyConflictWarning {
                                Text(conflict)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.red)
                            } else if nav.isRecordingHotKey, let hint = nav.hotKeyRecordingHint {
                                Text(hint)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Text(nav.isRecordingHotKey ? "按下组合键，或双击 ⌘/⌥/⌃/⇧ 单键（ESC 取消）" : "点击录制组合键或双击 ⌘/⌥/⌃/⇧ 单键")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(nav.isRecordingHotKey ? Color.accentColor : .secondary)
                            }
                        }
                        Spacer()

                        Button {
                            if nav.isRecordingHotKey {
                                nav.isRecordingHotKey = false
                                nav.hotKeyConflictWarning = nil
                                HotKeyManager.shared.resumeAfterRecording()
                            } else {
                                nav.isRecordingQueueHotKey = false
                                nav.hotKeyConflictWarning = nil
                                HotKeyManager.shared.suspendForRecording()
                                nav.isRecordingHotKey = true
                            }
                        } label: {
                            let hasConflict = nav.isRecordingHotKey && nav.hotKeyConflictWarning != nil
                            Text(hasConflict ? "冲突 · 请重按" : (nav.isRecordingHotKey ? "等待按键..." : store.hotKeyShortcut.displayString))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(nav.isRecordingHotKey ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(hasConflict ? Color.red : (nav.isRecordingHotKey ? Color.accentColor : Color.primary.opacity(0.08)))
                                )
                        }
                        .buttonStyle(.plain)

                        if store.hotKeyShortcut != .defaultShortcut && !nav.isRecordingHotKey {
                            Button {
                                nav.hotKeyConflictWarning = nil
                                store.hotKeyShortcut = .defaultShortcut
                                store.showToast("已恢复默认快捷键 ⌥ V")
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.primary.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .help("恢复默认 ⌥ V")
                        }
                    }

                    Divider().opacity(0.35)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("免开面板顺序出队热键")
                                .font(.system(size: 13.5, weight: .medium))
                            if nav.isRecordingQueueHotKey, let conflict = nav.hotKeyConflictWarning {
                                Text(conflict)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.red)
                            } else if nav.isRecordingQueueHotKey, let hint = nav.hotKeyRecordingHint {
                                Text(hint)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Text(nav.isRecordingQueueHotKey ? "按下组合键，或双击 ⌘/⌥/⌃/⇧ 单键（ESC 取消）" : "在表格/表单中连按即可逐项填入队列内容")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(nav.isRecordingQueueHotKey ? Color.accentColor : .secondary)
                            }
                        }
                        Spacer()

                        Button {
                            if nav.isRecordingQueueHotKey {
                                nav.isRecordingQueueHotKey = false
                                nav.hotKeyConflictWarning = nil
                                HotKeyManager.shared.resumeAfterRecording()
                            } else {
                                nav.isRecordingHotKey = false
                                nav.hotKeyConflictWarning = nil
                                HotKeyManager.shared.suspendForRecording()
                                nav.isRecordingQueueHotKey = true
                            }
                        } label: {
                            let hasConflict = nav.isRecordingQueueHotKey && nav.hotKeyConflictWarning != nil
                            Text(hasConflict ? "冲突 · 请重按" : (nav.isRecordingQueueHotKey ? "等待按键..." : store.queuePopShortcut.displayString))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(nav.isRecordingQueueHotKey ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(hasConflict ? Color.red : (nav.isRecordingQueueHotKey ? Color.accentColor : Color.primary.opacity(0.08)))
                                )
                        }
                        .buttonStyle(.plain)

                        if store.queuePopShortcut != .defaultQueueShortcut && !nav.isRecordingQueueHotKey {
                            Button {
                                nav.hotKeyConflictWarning = nil
                                store.queuePopShortcut = .defaultQueueShortcut
                                store.showToast("已恢复默认出队快捷键 ⌃ ⌥ V")
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.primary.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .help("恢复默认 ⌃ ⌥ V")
                        }
                    }
                }

                // 智能辅助（极简模式下自动隐藏）
                if !store.minimalModeEnabled {
                    settingsGroup(title: "智能辅助") {
                        AdaptiveIntelligenceSettingsSection(store: store)
                    }
                }

                // 隐私护盾与迁移整合分组
                settingsGroup(title: "隐私护盾与迁移") {
                    HStack(spacing: 7) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.green)
                        Text("本机钥匙串 AES-256-GCM 透明加密已启用 · 零联网上传")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.green.opacity(0.09))
                    )

                    Toggle(isOn: $store.screenSharePrivacyEnabled) {
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("投屏与录屏光学隐身护盾")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("腾讯会议 / 飞书共享屏幕及录屏中自动隐去 iClip，本机可见")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Toggle(isOn: $store.maskSensitivePreviews) {
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("敏感凭据防肩窥圆点遮罩")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("API 密钥与私钥默认圆点雾化，选中或悬停即刻原位显影")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Toggle(isOn: $store.autoClearConcealedPasteboard) {
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("密码剪贴板 60 秒残留擦除")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("从 1Password / 系统密码复制密码后超时自动清空系统剪贴板")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Toggle(isOn: $store.autoExpireUnpinnedSecrets) {
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("未收藏敏感凭据 24h 自动销毁")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("临时密钥与身份证卡号满 24 小时自动无痕代谢，收藏项永久守护")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Divider().opacity(0.35)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("历史保留上限")
                                .font(.system(size: 13.5, weight: .medium))
                            Spacer()
                            Text("收藏记录永不清理")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Picker("", selection: $store.maxHistoryCount) {
                            Text("50 条").tag(50)
                            Text("100 条").tag(100)
                            Text("200 条").tag(200)
                            Text("500 条").tag(500)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Divider().opacity(0.35)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("隐私忽略应用（不记录其复制内容）")
                            .font(.system(size: 12.5, weight: .medium))

                        let visibleIgnoredApps = store.ignoredApps.filter {
                            ClipboardStore.isAppAvailableOnSystem(bundleIdentifier: $0.bundleIdentifier)
                        }

                        if !visibleIgnoredApps.isEmpty {
                            VStack(spacing: 5) {
                                ForEach(visibleIgnoredApps) { app in
                                    HStack(spacing: 8) {
                                        if let icon = store.appIcon(forBundleID: app.bundleIdentifier) {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 18, height: 18)
                                        }

                                        Text(app.displayName)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .lineLimit(1)

                                        Spacer()

                                        Button {
                                            withAnimation(.easeOut(duration: 0.16)) {
                                                store.removeIgnoredApp(bundleIdentifier: app.bundleIdentifier)
                                            }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary.opacity(0.75))
                                        }
                                        .buttonStyle(.plain)
                                        .help("移出忽略名单")
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Menu {
                                let candidates = store.runningCandidateAppsForIgnore()
                                if candidates.isEmpty {
                                    Text("暂无可添加的运行中应用")
                                } else {
                                    ForEach(candidates) { candidate in
                                        Button(candidate.displayName) {
                                            store.addIgnoredApp(
                                                bundleIdentifier: candidate.bundleIdentifier,
                                                displayName: candidate.displayName
                                            )
                                        }
                                    }
                                }
                            } label: {
                                Label("添加运行中应用", systemImage: "plus.circle")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()

                            Spacer()

                            Button("选择应用...") {
                                pickAppToIgnore()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Divider().opacity(0.35)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("收藏归档与跨软件一键搬家")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("已收藏 \(store.pinnedItemCount) 条 · 支持 .iclip / Raycast / Maccy / CSV")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Button("导入...") {
                            importPinnedArchiveAction()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("导出 (.iclip)") {
                            exportPinnedArchiveAction()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                // 按需展开的键盘快捷键速查表（默认折叠，告别长列表刷屏）
                settingsGroup(title: "帮助") {
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            showShortcutReference.toggle()
                        }
                    } label: {
                        HStack {
                            Text("键盘快捷键速查")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: showShortcutReference ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showShortcutReference {
                        Divider().opacity(0.35)
                        shortcutRow("鼠标旁呼出 / 隐藏", store.hotKeyShortcut.displayString)
                        Divider().opacity(0.35)
                        shortcutRow("直接键入光标所在区域", "双击 / ↵")
                        Divider().opacity(0.35)
                        shortcutRow("左 / 右切换内容类目", "⇧⇥ / ⇥")
                        Divider().opacity(0.35)
                        shortcutRow("图片网格方向导航", "↑ ↓ ← →")
                        Divider().opacity(0.35)
                        shortcutRow("加入 / 移出顺序粘贴队列", "⌘ K")
                        Divider().opacity(0.35)
                        shortcutRow("提取图片实况文本键入", "⇧ ↵")
                        Divider().opacity(0.35)
                        shortcutRow("勾选多条记录合并键入", "⌘ M → ⌘ ↵")
                        Divider().opacity(0.35)
                        shortcutRow("快速键入前 9 条", "⌘ 1 ~ 9")
                        Divider().opacity(0.35)
                        shortcutRow("删除当前选中项", "⌘ ⌫")
                    }
                }

                // 底部操作
                HStack(spacing: 10) {
                    Button {
                        store.clearUnpinned()
                        nav.showSettings = false
                    } label: {
                        Text("清空未收藏历史")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    Button {
                        onQuit()
                    } label: {
                        Text("退出 iClip")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.10)))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(glassPalette.groupFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(glassPalette.groupStroke, lineWidth: 0.75)
            )
        }
    }

    private func shortcutRow(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Text(shortcut)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
    }

    // MARK: - 拖拽复制接收浮层

    private var dragDropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10))

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(0.85),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
                .padding(10)

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("松手即复制到剪贴板")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("支持文字、链接、图片与文件")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(glassPalette.groupStroke, lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.16), radius: 14, y: 6)
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - 轻提示胶囊

    private func toastPill(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)

            if store.canUndoLastDeletion && message.contains("⌘Z") {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                        _ = store.undoLastDeletion()
                    }
                } label: {
                    Text("撤销")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.80))
                .shadow(color: Color.black.opacity(0.22), radius: 8, y: 3)
        )
    }

    // MARK: - 图片悬停纯净原图预览控制

    private func handleImageHover(item: ClipItem, hovering: Bool, tileRect: CGRect) {
        if hovering {
            previewHideWorkItem?.cancel()
            previewHideWorkItem = nil
            hoveredTileItemID = item.id

            let wasVisible = isPreviewVisible
            let isSameItem = previewItem?.id == item.id

            if !wasVisible {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    previewItem = item
                    previewTileRect = tileRect
                }
                let targetID = item.id
                // 下一帧再触发绽放动画，确保首次悬停也能完整演绎从缩略图边缘生长的弹簧动效
                DispatchQueue.main.async {
                    guard hoveredTileItemID == targetID else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.08)) {
                        isPreviewVisible = true
                    }
                }
            } else if isSameItem {
                // 列表滚动时实时贴合当前缩略图位置，不滞后
                previewTileRect = tileRect
            } else {
                // 跨图片网格滑动时连续平移与形变，无闪退重绘
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.1)) {
                    previewItem = item
                    previewTileRect = tileRect
                }
            }
        } else if hoveredTileItemID == item.id || previewItem?.id == item.id {
            if hoveredTileItemID == item.id {
                hoveredTileItemID = nil
            }
            previewHideWorkItem?.cancel()
            let itemID = item.id
            let work = DispatchWorkItem {
                guard hoveredTileItemID == nil, previewItem?.id == itemID else { return }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.94)) {
                    isPreviewVisible = false
                }
            }
            previewHideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
        }
    }

    private func dismissImagePreview(clearItem: Bool) {
        previewHideWorkItem?.cancel()
        previewHideWorkItem = nil
        hoveredTileItemID = nil
        if clearItem {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPreviewVisible = false
                previewItem = nil
            }
        } else {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.94)) {
                isPreviewVisible = false
            }
        }
    }

    // MARK: - 键盘控制辅助

    var canMoveHorizontallyInGrid: Bool {
        guard !filteredItems.isEmpty else { return false }
        if nav.selectedTab == .image { return true }
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return false }
        return filteredItems[nav.selectedIndex].type == .image
    }

    func stepFilterTab(delta: Int) {
        let tabs = ClipFilterTab.visibleTabs(minimalMode: store.minimalModeEnabled)
        guard let currentIdx = tabs.firstIndex(of: nav.selectedTab) else { return }
        let nextIdx = (currentIdx + delta + tabs.count) % tabs.count
        selectFilterTab(tabs[nextIdx])
    }

    func selectFilterTab(_ tab: ClipFilterTab) {
        if nav.selectedTab == tab {
            nav.selectedIndex = 0
            nav.preferredGridColumn = nil
            nav.lockPointerAtCurrentMouse()
            nav.scrollRequestEpoch &+= 1
            return
        }
        dismissImagePreview(clearItem: true)
        if nav.showQuickLook {
            nav.isQuickLookEditing = false
            nav.showQuickLook = false
        }
        nav.selectedIndex = 0
        nav.preferredGridColumn = nil
        nav.lockPointerAtCurrentMouse()
        nav.selectedTab = tab
    }

    func moveSelection(direction: PanelNavigationDirection, extendMergeSelection: Bool = false) {
        let count = filteredItems.count
        guard count > 0 else { return }
        dismissImagePreview(clearItem: false)
        if extendMergeSelection, nav.selectedIndex >= 0, nav.selectedIndex < count {
            store.ensureMergeSelected(filteredItems[nav.selectedIndex])
        }
        let result = GridNavigationHelper.nextIndex(
            from: nav.selectedIndex,
            direction: direction,
            visualRows: nav.cachedVisualRows,
            preferredColumn: nav.preferredGridColumn
        )
        nav.selectedIndex = result.index
        nav.preferredGridColumn = result.preferredColumn
        if extendMergeSelection {
            store.ensureMergeSelected(filteredItems[nav.selectedIndex])
        }
        nav.lockPointerAtCurrentMouse()
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
        nav.scrollRequestEpoch &+= 1
    }

    func toggleMergeForSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            store.toggleMergeSelection(item)
        }
    }

    func mergePasteIfActive() -> Bool {
        guard !store.selectedMergeIDs.isEmpty else { return false }
        dismissImagePreview(clearItem: true)
        store.mergeAndPasteSelected(style: .paragraphs, shouldAutoPaste: true, onBeforePaste: onDismiss)
        return true
    }

    func pasteSelected(plainTextOnly: Bool = false) {
        if let suggestionPayload = QuickSuggestionCommandBanner.extractPayload(from: nav.searchText) {
            guard !suggestionPayload.isEmpty else { return }
            let outcome = AdaptiveIntelligenceEngine.shared.adoptUserSuggestion(suggestionPayload, in: store)
            nav.searchText = ""
            store.showToast(outcome.message)
            return
        }
        if let capture = QuickCaptureParser.parse(from: nav.searchText) {
            guard !capture.isEmptyBody else { return }
            if capture.defaultTodo {
                store.captureQuickTodo(body: capture.bodyText, alias: capture.customAlias, copyToClipboard: false)
            } else {
                store.captureQuickNote(body: capture.bodyText, alias: capture.customAlias, pin: capture.defaultPin)
            }
            nav.searchText = ""
            return
        }
        if nav.selectedTab == .todo && filteredItems.isEmpty && commitEmptySearchCaptureIfApplicable(forcePin: false) {
            return
        }
        if let pwGen = SecurePasswordGenerator.evaluate(nav.searchText) {
            nav.searchText = ""
            store.pasteEphemeralSecret(pwGen.secretValue, toast: pwGen.ephemeralToast, shouldAutoPaste: true, onBeforePaste: onDismiss)
            return
        }
        if let math = InstantMathEvaluator.evaluate(nav.searchText, latestClipboardText: store.items.first?.text),
           (filteredItems.isEmpty || math.isExplicitOrContextual) {
            nav.searchText = ""
            store.pasteInstantValue(math.plainValue, toast: "已键入计算结果 \(math.plainValue)", shouldAutoPaste: true, onBeforePaste: onDismiss)
            return
        }
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        if nav.showQuickLook {
            let tabs = QuickLookTabBuilder.buildTabs(for: item, store: store)
            guard !tabs.isEmpty else { return }
            let idx = min(max(nav.quickLookTabIndex, 0), tabs.count - 1)
            let chosen = tabs[idx]
            nav.isQuickLookEditing = false
            nav.showQuickLook = false
            switch chosen.payload {
            case .image:
                store.copyAndOptionallyPaste(item, plainTextOnly: plainTextOnly, shouldAutoPaste: true, onBeforePaste: onDismiss)
            case .text(let text):
                if idx == 0 && item.type != .image {
                    store.copyAndOptionallyPaste(item, plainTextOnly: plainTextOnly, shouldAutoPaste: true, onBeforePaste: onDismiss)
                } else {
                    store.pasteCustomString(text, sourceItem: item, toast: chosen.toast, shouldAutoPaste: true, onBeforePaste: onDismiss)
                }
            }
            return
        }
        store.copyAndOptionallyPaste(item, plainTextOnly: plainTextOnly, shouldAutoPaste: true, onBeforePaste: onDismiss)
    }

    func stepQuickLookTab(delta: Int) {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let tabs = QuickLookTabBuilder.buildTabs(for: filteredItems[nav.selectedIndex], store: store)
        guard tabs.count > 1 else { return }
        nav.quickLookTabIndex = (nav.quickLookTabIndex + delta + tabs.count) % tabs.count
    }

    func selectQuickLookDiffTabIfAvailable() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let tabs = QuickLookTabBuilder.buildTabs(for: filteredItems[nav.selectedIndex], store: store)
        if let diffIdx = tabs.firstIndex(where: { $0.id == QuickLookTabItem.diffLatestTabID }) {
            nav.quickLookTabIndex = diffIdx
        }
    }

    func enterQuickLookEditMode() -> Bool {
        guard nav.showQuickLook,
              nav.selectedIndex >= 0,
              nav.selectedIndex < filteredItems.count else { return false }
        let item = filteredItems[nav.selectedIndex]
        let tabs = QuickLookTabBuilder.buildTabs(for: item, store: store)
        guard !tabs.isEmpty else { return false }
        let idx = min(max(nav.quickLookTabIndex, 0), tabs.count - 1)
        guard let text = tabs[idx].textValue else { return false }
        nav.quickLookDraftText = text
        nav.isQuickLookEditing = true
        return true
    }

    func commitQuickLookDraftPaste() {
        guard nav.showQuickLook,
              nav.isQuickLookEditing,
              nav.selectedIndex >= 0,
              nav.selectedIndex < filteredItems.count else { return }
        let target = filteredItems[nav.selectedIndex]
        let draft = nav.quickLookDraftText
        nav.isQuickLookEditing = false
        nav.showQuickLook = false
        store.pasteCustomString(draft, sourceItem: target, toast: "已键入微调内容", shouldAutoPaste: true, onBeforePaste: onDismiss)
    }

    func saveQuickLookDraftToItem() {
        guard nav.showQuickLook,
              nav.isQuickLookEditing,
              nav.selectedIndex >= 0,
              nav.selectedIndex < filteredItems.count else { return }
        let target = filteredItems[nav.selectedIndex]
        if store.updateItemText(nav.quickLookDraftText, for: target) {
            nav.isQuickLookEditing = false
        }
    }

    func beginAliasEdit(for item: ClipItem) {
        aliasDraftText = item.customAlias ?? ""
        nav.isEditingAlias = true
        withAnimation(.easeOut(duration: 0.16)) {
            aliasEditingItem = item
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isAliasFieldFocused = true
        }
    }

    func beginAliasEditForSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        beginAliasEdit(for: filteredItems[nav.selectedIndex])
    }

    @discardableResult
    func commitEmptySearchCaptureIfApplicable(forcePin: Bool, allowNonEmptyMatchInTodo: Bool = true) -> Bool {
        let canProceed = filteredItems.isEmpty || (allowNonEmptyMatchInTodo && nav.selectedTab == .todo && !forcePin)
        guard canProceed else { return false }
        let trimmed = nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("@") else { return false }
        let (alias, body) = QuickCaptureParser.splitAliasAndBody(trimmed)
        guard !body.isEmpty else { return false }
        if nav.selectedTab == .todo && !forcePin {
            store.captureQuickTodo(body: body, alias: alias, copyToClipboard: false)
        } else {
            store.captureQuickNote(body: body, alias: alias, pin: forcePin || (alias != nil))
        }
        nav.searchText = ""
        return true
    }

    func appendSelectedToClipboard() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        store.appendItemToCurrentClipboard(filteredItems[nav.selectedIndex])
    }

    func copySelectedOnly(plainPathOrText: Bool) -> Bool {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return false }
        let item = filteredItems[nav.selectedIndex]
        if nav.showQuickLook && !plainPathOrText {
            let tabs = QuickLookTabBuilder.buildTabs(for: item, store: store)
            if !tabs.isEmpty {
                let idx = min(max(nav.quickLookTabIndex, 0), tabs.count - 1)
                let chosen = tabs[idx]
                nav.isQuickLookEditing = false
                nav.showQuickLook = false
                switch chosen.payload {
                case .image:
                    store.copyAndOptionallyPaste(item, plainTextOnly: false, shouldAutoPaste: false, onBeforePaste: nil)
                    store.showToast("已复制图片")
                case .text(let text):
                    store.pasteCustomString(text, sourceItem: item, toast: "已复制预览内容", shouldAutoPaste: false, onBeforePaste: nil)
                }
                return true
            }
        }
        if plainPathOrText {
            store.copyPlainPathOrText(item)
        } else {
            store.copyAndOptionallyPaste(item, plainTextOnly: false, shouldAutoPaste: false, onBeforePaste: nil)
            store.showToast("✓ 已复制到剪贴板")
        }
        return true
    }

    @discardableResult
    func openSelectedExternally() -> Bool {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return false }
        let item = filteredItems[nav.selectedIndex]
        if nav.showQuickLook {
            nav.isQuickLookEditing = false
            nav.showQuickLook = false
        }
        return store.openItemExternally(item)
    }

    func cancelAliasEdit() {
        aliasEditingItem = nil
        nav.isEditingAlias = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            isSearchFocused = true
        }
    }

    func pasteSecondaryActionForSelected() {
        if let capture = QuickCaptureParser.parse(from: nav.searchText) {
            guard !capture.isEmptyBody else { return }
            if capture.defaultTodo {
                store.captureQuickTodo(body: capture.bodyText, alias: capture.customAlias, copyToClipboard: true)
            } else {
                store.captureQuickNote(body: capture.bodyText, alias: capture.customAlias, pin: true)
            }
            nav.searchText = ""
            return
        }
        if let pwGen = SecurePasswordGenerator.evaluate(nav.searchText) {
            SecurePasswordGenerator.bumpGenerationSalt()
            nav.searchText = ""
            store.captureQuickNote(body: pwGen.secretValue, alias: pwGen.defaultVaultAlias, pin: true)
            onDismiss()
            return
        }
        if let math = InstantMathEvaluator.evaluate(nav.searchText, latestClipboardText: store.items.first?.text),
           (filteredItems.isEmpty || math.isExplicitOrContextual),
           let rmb = math.rmbUppercase {
            nav.searchText = ""
            store.pasteInstantValue(rmb, toast: "已键入大写金额", shouldAutoPaste: true, onBeforePaste: onDismiss)
            return
        }
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        if !store.minimalModeEnabled && item.type == .image {
            dismissImagePreview(clearItem: true)
            store.pasteExtractedOCRText(for: item, shouldAutoPaste: true, onBeforePaste: onDismiss)
        } else if !store.minimalModeEnabled, let finAction = store.financeActions(for: item).first {
            store.applyFinanceAction(finAction, for: item, shouldAutoPaste: true, onBeforePaste: onDismiss)
        } else {
            store.copyAndOptionallyPaste(item, plainTextOnly: true, shouldAutoPaste: true, onBeforePaste: onDismiss)
        }
    }

    func toggleQueueForSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
            store.toggleQueueMembership(item)
        }
    }

    func dequeueAndPasteFromQueue() -> Bool {
        guard !store.pasteQueueIDs.isEmpty else { return false }
        dismissImagePreview(clearItem: true)
        store.dequeueAndPasteNext(onBeforePaste: onDismiss)
        return true
    }

    func pasteItem(at index: Int, plainTextOnly: Bool = false, smartTransform: Bool = false) {
        guard index >= 0, index < filteredItems.count else { return }
        if smartTransform {
            nav.selectedIndex = index
            pasteSecondaryActionForSelected()
            return
        }
        let item = filteredItems[index]
        store.copyAndOptionallyPaste(item, plainTextOnly: plainTextOnly, shouldAutoPaste: true, onBeforePaste: onDismiss)
    }

    func togglePinForSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            store.togglePin(item)
        }
    }

    func toggleTodoForSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        let willComplete = item.isPendingTodo
        if nav.selectedTab == .todo {
            nav.registerTodoCompletionSettle(for: item.id, isNowCompleted: willComplete)
        }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
            store.toggleTodo(item)
        }
    }

    func toggleBurnAfterPasteForSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        store.toggleBurnAfterPaste(filteredItems[nav.selectedIndex])
    }

    @discardableResult
    func pasteAndCompleteTodoIfApplicable() -> Bool {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return false }
        let item = filteredItems[nav.selectedIndex]
        guard item.isPendingTodo else { return false }
        store.markTodoCompletedSilently(item)
        store.copyAndOptionallyPaste(item, plainTextOnly: false, shouldAutoPaste: true, onBeforePaste: onDismiss)
        store.showToast("✓ 已键入并完成待办")
        return true
    }

    func deleteSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            store.delete(item)
            clampSelection()
        }
    }

    private func pickAppToIgnore() {
        nav.suppressAutoHide = true
        let panel = NSOpenPanel()
        panel.title = "选择要忽略剪贴记录的应用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        let response = panel.runModal()
        nav.suppressAutoHide = false

        guard response == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        store.addIgnoredApp(bundleIdentifier: bundleID, displayName: name)
    }

    private func exportPinnedArchiveAction() {
        guard store.pinnedItemCount > 0 else {
            store.showToast("暂无已收藏的记录可导出")
            return
        }

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let defaultName = "iClip-收藏资产-\(df.string(from: Date())).iclip"

        nav.suppressAutoHide = true
        let panel = NSSavePanel()
        panel.title = "导出 iClip 收藏与模板归档"
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true
        if let iclipType = UTType(filenameExtension: "iclip", conformingTo: .json) {
            panel.allowedContentTypes = [iclipType]
        }

        let passField = ArchivePassphraseUIHelper.attachExportPassphraseAccessory(
            to: panel,
            sensitivePinnedCount: store.pinnedSensitiveItemCount
        )

        let response = panel.runModal()
        nav.suppressAutoHide = false

        guard response == .OK, var targetURL = panel.url else { return }
        if targetURL.pathExtension.isEmpty {
            targetURL = targetURL.appendingPathExtension("iclip")
        }
        let pw = passField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let count = try store.exportPinnedArchive(to: targetURL, passphrase: pw.isEmpty ? nil : pw)
            store.showToast(pw.isEmpty ? "已导出 \(count) 条收藏至 \(targetURL.lastPathComponent)" : "已口令加密导出 \(count) 条收藏（Mac/Win 互通）")
        } catch {
            store.showToast(error.localizedDescription)
        }
    }

    private func importPinnedArchiveAction() {
        nav.suppressAutoHide = true
        let panel = NSOpenPanel()
        panel.title = "导入 .iclip 归档或 Raycast / Maccy / Paste / CSV 常用语"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        var allowed: [UTType] = [.json, .commaSeparatedText, .tabSeparatedText, .plainText, .data]
        if let iclipType = UTType(filenameExtension: "iclip") {
            allowed.insert(iclipType, at: 0)
        }
        panel.allowedContentTypes = allowed

        let response = panel.runModal()
        nav.suppressAutoHide = false

        guard response == .OK, let sourceURL = panel.url else { return }
        do {
            let summary: ArchiveImportSummary
            do {
                summary = try store.importPinnedArchive(from: sourceURL, passphrase: nil)
            } catch ArchiveBackupError.passphraseRequiredOrIncorrect {
                nav.suppressAutoHide = true
                let entered = ArchivePassphraseUIHelper.promptImportPassphrase(for: sourceURL.lastPathComponent)
                nav.suppressAutoHide = false
                guard let pw = entered else { return }
                summary = try store.importPinnedArchive(from: sourceURL, passphrase: pw)
            }
            if summary.importedNewCount > 0 && summary.updatedExistingCount > 0 {
                store.showToast("已从\(summary.sourceFormatLabel)迁入 \(summary.importedNewCount) 条，更新 \(summary.updatedExistingCount) 条")
            } else if summary.importedNewCount > 0 {
                store.showToast("已从\(summary.sourceFormatLabel)无损迁入 \(summary.importedNewCount) 条收藏")
            } else if summary.updatedExistingCount > 0 {
                store.showToast("已合并更新 \(summary.updatedExistingCount) 条既有收藏")
            } else {
                store.showToast("\(summary.sourceFormatLabel)内 \(summary.totalInBundle) 条记录均已在本地存在")
            }
        } catch {
            store.showToast(error.localizedDescription)
        }
    }

    private func clampSelection() {
        let count = filteredItems.count
        if count == 0 {
            nav.selectedIndex = 0
        } else if nav.selectedIndex >= count {
            nav.selectedIndex = count - 1
        }
    }
}

/// 卡片瀑布错峰浮现动效修饰器
private struct CascadeAppearModifier: ViewModifier {
    let isPresented: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .offset(y: isPresented ? 0 : -16)
            .scaleEffect(isPresented ? 1 : 0.94, anchor: .top)
            .animation(
                isPresented
                    ? .spring(response: 0.36, dampingFraction: 0.78).delay(delay)
                    : .easeOut(duration: 0.12),
                value: isPresented
            )
    }
}

private extension View {
    func cascadeAppear(isPresented: Bool, delay: Double) -> some View {
        modifier(CascadeAppearModifier(isPresented: isPresented, delay: delay))
    }
}

#else
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// 列表行模型：连续图片自动聚合成 3 列网格，非图片保持单行精致卡片
enum ClipDisplayRow: Identifiable {
    case standard(index: Int, item: ClipItem)
    case imageGrid(entries: [(index: Int, item: ClipItem)])
    case todoCompletedHeader(count: Int)

    var id: String {
        switch self {
        case .standard(_, let item):
            return "row-\(item.id.uuidString)"
        case .imageGrid(let entries):
            return "grid-\(entries.first?.item.id.uuidString ?? "empty")"
        case .todoCompletedHeader:
            return "todo-completed-section-header"
        }
    }
}

/// 键盘导航、筛选缓存与出场动效控制桥接器（仅在数据/搜索/分类变动时重算列表，悬停与方向键零开销）
@MainActor
final class PanelNavigationModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var selectedTab: ClipFilterTab = .all
    @Published var selectedIndex: Int = 0
    @Published var focusTrigger: UUID = UUID()
    @Published var showSettings: Bool = false
    @Published var isPresented: Bool = false
    @Published var presentationEpoch: Int = 0
    @Published var scrollRequestEpoch: Int = 0
    @Published var isRecordingHotKey: Bool = false
    @Published var hotKeyConflictWarning: String? = nil
    @Published var hotKeyRecordingHint: String? = nil
    @Published var isEditingAlias: Bool = false
    @Published var showQuickLook: Bool = false {
        didSet {
            if showQuickLook {
                if selectedIndex >= 0 && selectedIndex < cachedFilteredItems.count {
                    quickLookAnchorID = cachedFilteredItems[selectedIndex].id
                }
            } else {
                quickLookAnchorID = nil
            }
        }
    }
    private var quickLookAnchorID: UUID? = nil
    @Published var quickLookTabIndex: Int = 0
    @Published var quickLookPreferDiff: Bool = false
    @Published var isQuickLookEditing: Bool = false
    @Published var quickLookDraftText: String = ""
    @Published var isCreatingTemplate: Bool = false
    @Published var demoPreviewIndex: Int? = nil
    @Published var isDragTargeted: Bool = false
    @Published var settlingCompletedTodoIDs: Set<UUID> = []
    private var settlingWorkItems: [UUID: DispatchWorkItem] = [:]
    var suppressAutoHide: Bool = false

    private(set) var cachedFilteredItems: [ClipItem] = []
    private(set) var cachedDisplayRows: [ClipDisplayRow] = []
    private(set) var cachedVisualRows: [[Int]] = []
    var preferredGridColumn: Int? = nil
    var pointerGuard = PointerSelectionGuard()
    private weak var storeRef: ClipboardStore?
    private var cancellables = Set<AnyCancellable>()

    init(store: ClipboardStore? = nil) {
        let resolvedStore = store ?? .shared
        self.storeRef = resolvedStore
        rebuildCache(items: resolvedStore.items, tab: selectedTab, query: searchText)

        Publishers.CombineLatest3(resolvedStore.$items, $selectedTab, $searchText)
            .sink { [weak self] items, tab, query in
                self?.rebuildCache(items: items, tab: tab, query: query)
            }
            .store(in: &cancellables)

        $settlingCompletedTodoIDs
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, let s = self.storeRef else { return }
                self.rebuildCache(items: s.items, tab: self.selectedTab, query: self.searchText)
            }
            .store(in: &cancellables)

        Publishers.Merge3(
            resolvedStore.$activeTargetAppName.dropFirst().map { _ in () },
            resolvedStore.$minimalModeEnabled.dropFirst().map { _ in () },
            AdaptiveIntelligenceEngine.shared.$revision.dropFirst().map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self, let s = self.storeRef else { return }
            if s.minimalModeEnabled && self.selectedTab == .todo {
                self.selectedTab = .all
                return
            }
            self.rebuildCache(items: s.items, tab: self.selectedTab, query: self.searchText)
        }
        .store(in: &cancellables)
    }

    func registerTodoCompletionSettle(for itemID: UUID, isNowCompleted: Bool) {
        settlingWorkItems[itemID]?.cancel()
        settlingWorkItems.removeValue(forKey: itemID)
        if isNowCompleted {
            settlingCompletedTodoIDs.insert(itemID)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.settlingWorkItems.removeValue(forKey: itemID)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    _ = self.settlingCompletedTodoIDs.remove(itemID)
                }
            }
            settlingWorkItems[itemID] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.52, execute: work)
        } else {
            settlingCompletedTodoIDs.remove(itemID)
        }
    }

    private func rebuildCache(items: [ClipItem], tab: ClipFilterTab, query: String) {
        // 解析可选的 @语义 速筛前缀（例如 "@json user" 或 "@secret"）
        let isCommandInput = (QuickSuggestionCommandBanner.extractPayload(from: query) != nil)
            || (QuickCaptureParser.parse(from: query) != nil)
            || (SecurePasswordGenerator.evaluate(query) != nil)
        let trimmedQuery = isCommandInput
            ? ""
            : query.trimmingCharacters(in: .whitespacesAndNewlines)
        var requiredSemantic: SemanticKind? = nil
        var textQuery = trimmedQuery
        if trimmedQuery.hasPrefix("@") {
            let parts = trimmedQuery.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let firstToken = parts.first, let parsedKind = SemanticKind.fromSearchToken(String(firstToken)) {
                requiredSemantic = parsedKind
                textQuery = parts.count > 1 ? String(parts[1]) : ""
            }
        }

        let resolvedStore = storeRef ?? .shared
        let rawMatched = items.filter { item in
            let tabMatches: Bool
            switch tab {
            case .all: tabMatches = true
            case .todo: tabMatches = item.isTodo
            case .pinned: tabMatches = item.isPinned
            case .text: tabMatches = item.type == .text
            case .link: tabMatches = item.type == .link
            case .image: tabMatches = item.type == .image
            case .file: tabMatches = item.type == .file
            }
            guard tabMatches else { return false }
            if let requiredSemantic {
                let snap = resolvedStore.semanticSnapshot(for: item)
                guard snap.primaryKind == requiredSemantic else { return false }
            }
            return item.matches(query: textQuery)
        }

        let settling = self.settlingCompletedTodoIDs
        let filtered: [ClipItem]
        if tab == .todo {
            filtered = rawMatched.sorted { lhs, rhs in
                let lhsSunk = lhs.isTodoCompleted && !settling.contains(lhs.id)
                let rhsSunk = rhs.isTodoCompleted && !settling.contains(rhs.id)
                if lhsSunk != rhsSunk {
                    return !lhsSunk
                }
                if lhsSunk {
                    let ld = lhs.todoCompletedAt ?? lhs.createdAt
                    let rd = rhs.todoCompletedAt ?? rhs.createdAt
                    return ld > rd
                }
                return lhs.createdAt > rhs.createdAt
            }
        } else if resolvedStore.minimalModeEnabled {
            filtered = rawMatched
        } else if !textQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = SmartSearchRanker.rankSearchResults(
                rawMatched,
                query: textQuery,
                targetApp: resolvedStore.activeTargetAppName,
                engine: .shared
            )
        } else if tab == .pinned {
            filtered = SmartSearchRanker.rankPinnedItemsForContext(
                rawMatched,
                targetApp: resolvedStore.activeTargetAppName,
                engine: .shared
            )
        } else {
            filtered = rawMatched
        }

        var rows: [ClipDisplayRow] = []
        rows.reserveCapacity(filtered.count + 1)
        var imageBuffer: [(index: Int, item: ClipItem)] = []
        let sunkDoneCount = (tab == .todo) ? filtered.filter { $0.isTodoCompleted && !settling.contains($0.id) }.count : 0
        var hasInsertedDoneHeader = false

        for (index, item) in filtered.enumerated() {
            if tab == .todo && !hasInsertedDoneHeader && sunkDoneCount > 0 && item.isTodoCompleted && !settling.contains(item.id) {
                hasInsertedDoneHeader = true
                if index > 0 {
                    rows.append(.todoCompletedHeader(count: sunkDoneCount))
                }
            }
            if item.type == .image && tab != .todo {
                imageBuffer.append((index: index, item: item))
            } else {
                if !imageBuffer.isEmpty {
                    rows.append(.imageGrid(entries: imageBuffer))
                    imageBuffer.removeAll(keepingCapacity: true)
                }
                rows.append(.standard(index: index, item: item))
            }
        }
        if !imageBuffer.isEmpty {
            rows.append(.imageGrid(entries: imageBuffer))
        }

        self.cachedFilteredItems = filtered
        if showQuickLook {
            if let anchor = quickLookAnchorID, !filtered.contains(where: { $0.id == anchor }) {
                showQuickLook = false
                isQuickLookEditing = false
                quickLookDraftText = ""
            } else if filtered.isEmpty {
                showQuickLook = false
                isQuickLookEditing = false
                quickLookDraftText = ""
            }
        }
        self.cachedDisplayRows = rows
        self.cachedVisualRows = GridNavigationHelper.buildVisualRows(count: filtered.count, imageColumns: 3) {
            tab != .todo && filtered[$0].type == .image
        }
    }

    func resetOnOpen() {
        searchText = ""
        selectedIndex = 0
        preferredGridColumn = nil
        showSettings = false
        showQuickLook = false
        quickLookPreferDiff = false
        isQuickLookEditing = false
        quickLookDraftText = ""
        isEditingAlias = false
        isCreatingTemplate = false
        isRecordingHotKey = false
        hotKeyConflictWarning = nil
        hotKeyRecordingHint = nil
        suppressAutoHide = false
        isDragTargeted = false
        lockPointerAtCurrentMouse()
        presentationEpoch &+= 1
        focusTrigger = UUID()
    }

    func lockPointerAtCurrentMouse() {
        pointerGuard.lock(
            at: NSEvent.mouseLocation,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    func selectExplicitly(_ index: Int) {
        pointerGuard.unlock()
        if selectedIndex != index {
            selectedIndex = index
        }
    }

    @discardableResult
    func selectByHover(_ index: Int) -> Bool {
        guard pointerGuard.allowHoverSelection(
            currentMouseLocation: NSEvent.mouseLocation,
            uptime: ProcessInfo.processInfo.systemUptime
        ) else {
            return false
        }
        if selectedIndex != index {
            selectedIndex = index
        }
        return true
    }
}

/// 主面板视图（苹果原生毛玻璃 / 液态玻璃内容层）
struct ClipboardPopoverView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var nav: PanelNavigationModel
    @ObservedObject private var updater = UpdateManager.shared
    @ObservedObject private var playground = InteractivePlaygroundController.shared
    let onDismiss: () -> Void
    let onQuit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFocused: Bool

    private var glassPalette: LiquidGlassPalette {
        LiquidGlassPalette(
            colorScheme: colorScheme,
            surfaceStyle: store.surfaceStyle,
            appearance: store.liquidGlassAppearance
        )
    }
    @State private var previewItem: ClipItem? = nil
    @State private var previewTileRect: CGRect = .zero
    @State private var isPreviewVisible: Bool = false
    @State private var hoveredTileItemID: UUID? = nil
    @State private var previewHideWorkItem: DispatchWorkItem? = nil
    @State private var templateDraftText: String = "请帮我审查以下代码并指出潜在问题：\n\n{{clip_redacted}}"
    @State private var aliasEditingItem: ClipItem? = nil
    @State private var aliasDraftText: String = ""
    @State private var showShortcutReference: Bool = false
    @FocusState private var isAliasFieldFocused: Bool

    var filteredItems: [ClipItem] {
        nav.cachedFilteredItems
    }

    private var displayRows: [ClipDisplayRow] {
        nav.cachedDisplayRows
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                if nav.showSettings {
                    settingsView
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    if !store.minimalModeEnabled && (!store.hasConfirmedRoleEdition || store.targetRoleEdition != AppRoleEdition.installed) {
                        RoleOnboardingBanner(
                            store: store,
                            updater: updater,
                            onOpenSettings: { nav.showSettings = true }
                        )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    filterBar
                        .padding(.horizontal, 14)
                        .padding(.bottom, nav.searchText.trimmingCharacters(in: .whitespaces).hasPrefix("@") ? 6 : 10)

                    searchCommandOverlayBanner

                    if !store.minimalModeEnabled && nav.selectedTab == .todo && (!filteredItems.isEmpty || store.completedTodoCount > 0) {
                        todoSummaryBar
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if !store.minimalModeEnabled && isSensitiveAuditQuery && store.unpinnedSensitiveCount > 0 {
                        sensitiveAuditSummaryBar
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if !store.minimalModeEnabled && nav.selectedTab == .pinned {
                        pinnedTemplateToolbar
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if let editing = aliasEditingItem {
                        inlineAliasEditorBar(for: editing)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if !store.borderlessPanel {
                        Divider()
                            .opacity(0.28)
                    }

                    contentList
                        .transition(.opacity)

                    if !store.borderlessPanel {
                        Divider()
                            .opacity(0.28)
                    }

                    footerBar
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(glassPalette.footerBackdrop)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(glassPalette.controlCapsuleStroke.opacity(store.surfaceStyle == .liquidGlass ? 0.6 : 0), lineWidth: 0.6)
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 5)
                        .padding(.bottom, 9)
                }
            }
            .frame(width: 420, height: 560)

            // iOS 灵动胶囊轻提示
            if let message = store.toastMessage {
                toastPill(message)
                    .padding(.bottom, 46)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 420, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            if store.surfaceStyle != .liquidGlass && !store.borderlessPanel {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        // 纯净原图放大预览浮层
        .overlay {
            ImageHoverPreviewLayer(
                item: previewItem,
                tileRect: previewTileRect,
                isVisible: isPreviewVisible,
                panelSize: CGSize(width: 420, height: 560)
            )
        }
        // 外部内容拖放复制高亮反馈浮层
        .overlay {
            if nav.isDragTargeted {
                dragDropOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        // 首次启动苹果风极简重点功能速览浮层
        .overlay {
            if playground.isActive && !nav.showSettings {
                CoreHighlightsOverlay(
                    controller: playground,
                    store: store,
                    glassPalette: glassPalette
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        // QuickLook 全模态速览与原位微调浮层（⌘Y / Space）
        .overlay {
            if nav.showQuickLook,
               nav.selectedIndex >= 0,
               nav.selectedIndex < filteredItems.count {
                let target = filteredItems[nav.selectedIndex]
                SemanticQuickLookOverlay(
                    item: target,
                    tabs: QuickLookTabBuilder.buildTabs(for: target, store: store),
                    selectedPreviewIndex: $nav.quickLookTabIndex,
                    isEditing: $nav.isQuickLookEditing,
                    draftText: $nav.quickLookDraftText,
                    preferDiffOnOpen: nav.quickLookPreferDiff,
                    onCommitPasteText: { content, toast in
                        nav.isQuickLookEditing = false
                        nav.showQuickLook = false
                        store.pasteCustomString(content, sourceItem: target, toast: toast, shouldAutoPaste: true, onBeforePaste: onDismiss)
                    },
                    onCommitPasteImage: {
                        nav.isQuickLookEditing = false
                        nav.showQuickLook = false
                        store.copyAndOptionallyPaste(target, plainTextOnly: false, shouldAutoPaste: true, onBeforePaste: onDismiss)
                    },
                    onSaveToItem: { updatedText in
                        if store.updateItemText(updatedText, for: target) {
                            nav.isQuickLookEditing = false
                        }
                    },
                    onClose: {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                            nav.isQuickLookEditing = false
                            nav.showQuickLook = false
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .coordinateSpace(name: "panelRoot")
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: nav.showSettings)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: store.toastMessage)
        .onChange(of: nav.isPresented) { _, presented in
            if presented {
                playground.cleanupLegacySamplesIfAny(in: store)
                store.onPanelShown(visibleItems: filteredItems)
            } else {
                aliasEditingItem = nil
                dismissImagePreview(clearItem: true)
                store.onPanelHidden()
            }
        }
        .onChange(of: nav.focusTrigger) { _, _ in
            dismissImagePreview(clearItem: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
        .onChange(of: nav.searchText) { _, _ in
            nav.selectedIndex = 0
            nav.lockPointerAtCurrentMouse()
            dismissImagePreview(clearItem: true)
        }
        .onChange(of: nav.selectedTab) { _, _ in
            TactileFeedbackEngine.shared.perform(.tabSwitch)
            nav.selectedIndex = 0
            nav.lockPointerAtCurrentMouse()
            dismissImagePreview(clearItem: true)
        }
        .onChange(of: nav.demoPreviewIndex) { _, targetIdx in
            if let idx = targetIdx, idx >= 0, idx < filteredItems.count {
                let item = filteredItems[idx]
                nav.selectedIndex = idx
                // 估算第 1 行 3 列图片格在面板内的真实位置触发原生纯净原图放大浮层
                let col = max(0, min(2, idx - 1))
                let tileRect = CGRect(x: 14 + CGFloat(col) * 134, y: 196, width: 124, height: 98)
                handleImageHover(item: item, hovering: true, tileRect: tileRect)
            } else {
                dismissImagePreview(clearItem: true)
            }
        }
        .onChange(of: nav.showSettings) { _, showing in
            dismissImagePreview(clearItem: true)
            if showing {
                store.refreshAccessibilityStatus()
                store.pruneUnavailableIgnoredApps()
            } else if nav.isRecordingHotKey {
                nav.isRecordingHotKey = false
                nav.hotKeyConflictWarning = nil
                HotKeyManager.shared.resumeAfterRecording()
            } else {
                nav.hotKeyConflictWarning = nil
            }
        }
    }

    @ViewBuilder
    private var searchCommandOverlayBanner: some View {
        if QuickSuggestionCommandBanner.extractPayload(from: nav.searchText) != nil {
            QuickSuggestionCommandBanner(rawQuery: nav.searchText) { payload in
                let outcome = AdaptiveIntelligenceEngine.shared.adoptUserSuggestion(payload, in: store)
                nav.searchText = ""
                store.showToast(outcome.message)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let capture = QuickCaptureParser.parse(from: nav.searchText) {
            QuickCaptureCommandBanner(
                intent: capture,
                onCommitDefault: {
                    guard !capture.isEmptyBody else { return }
                    if capture.defaultTodo {
                        store.captureQuickTodo(body: capture.bodyText, alias: capture.customAlias, copyToClipboard: false)
                    } else {
                        store.captureQuickNote(body: capture.bodyText, alias: capture.customAlias, pin: capture.defaultPin)
                    }
                    nav.searchText = ""
                },
                onCommitForcePin: {
                    guard !capture.isEmptyBody else { return }
                    if capture.defaultTodo {
                        store.captureQuickTodo(body: capture.bodyText, alias: capture.customAlias, copyToClipboard: true)
                    } else {
                        store.captureQuickNote(body: capture.bodyText, alias: capture.customAlias, pin: true)
                    }
                    nav.searchText = ""
                }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let pwGen = SecurePasswordGenerator.evaluate(nav.searchText) {
            SecurePasswordCardView(
                candidate: pwGen,
                onCommitEphemeral: {
                    nav.searchText = ""
                    store.pasteEphemeralSecret(pwGen.secretValue, toast: pwGen.ephemeralToast, shouldAutoPaste: true, onBeforePaste: onDismiss)
                },
                onCommitPinToVault: {
                    SecurePasswordGenerator.bumpGenerationSalt()
                    nav.searchText = ""
                    store.captureQuickNote(body: pwGen.secretValue, alias: pwGen.defaultVaultAlias, pin: true)
                    onDismiss()
                }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let math = InstantMathEvaluator.evaluate(nav.searchText, latestClipboardText: store.items.first?.text) {
            InstantMathCardView(
                math: math,
                onCommitPlain: {
                    nav.searchText = ""
                    store.pasteInstantValue(math.plainValue, toast: "已键入计算结果 \(math.plainValue)", shouldAutoPaste: true, onBeforePaste: onDismiss)
                },
                onCommitRMB: math.rmbUppercase.map { rmb in
                    {
                        nav.searchText = ""
                        store.pasteInstantValue(rmb, toast: "已键入大写金额", shouldAutoPaste: true, onBeforePaste: onDismiss)
                    }
                }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if !store.minimalModeEnabled && nav.searchText.trimmingCharacters(in: .whitespaces).hasPrefix("@") {
            semanticTokenHintBar
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else if nav.selectedTab == .todo,
                  !nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            todoInlineCreateBanner
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - 顶部胶囊搜索栏

    private var headerBar: some View {
        HStack(spacing: 8) {
            if nav.showSettings {
                Button {
                    nav.showSettings = false
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(
                        Capsule()
                            .fill(glassPalette.controlCapsuleFill)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(glassPalette.controlCapsuleStroke, lineWidth: 0.7)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 7) {
                    BrandAppIconBadge(size: 20)
                    Text("iClip 设置 · \(AppRoleEdition.installed.title)")
                        .font(.system(size: 14, weight: .semibold))
                }

                Spacer()

                Color.clear.frame(width: 48, height: 1)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField(
                        nav.selectedTab == .todo
                            ? "搜索待办，或直接输入事项按 ↵ 新建..."
                            : (store.minimalModeEnabled ? "搜索剪贴历史..." : "搜索历史或输入 @rmb @json @secret..."),
                        text: $nav.searchText
                    )
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .focused($isSearchFocused)

                    if !nav.searchText.isEmpty {
                        Button {
                            nav.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(glassPalette.controlCapsuleFill)
                )
                .overlay {
                    Capsule()
                        .strokeBorder(glassPalette.controlCapsuleStroke, lineWidth: 0.75)
                }

                // 窗口始终在前一键固定圆钮（⌘P）
                AlwaysOnTopPinButton(store: store, glassPalette: glassPalette)

                // 极简纯净模式（基础功能版）一键切换圆钮（⌘E）
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        store.toggleMinimalMode()
                    }
                } label: {
                    Image(systemName: store.minimalModeEnabled ? "leaf.fill" : "leaf")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(store.minimalModeEnabled ? Color.white : Color.secondary)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(store.minimalModeEnabled ? Color.green : glassPalette.controlCapsuleFill)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(glassPalette.controlCapsuleStroke.opacity(store.minimalModeEnabled ? 0.3 : 0.85), lineWidth: 0.65)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("极简纯净模式开关")
                .help(store.minimalModeEnabled ? "极简基础版已开启（点击或按 ⌘E 恢复进阶功能）" : "开启极简纯净模式（基础功能版 · ⌘E）")

                // 暂停/恢复监听按钮（单击开启 15 分钟无痕自动恢复暂停，右键可选时长或持续暂停）
                Button {
                    store.toggleTimedPause(defaultMinutes: 15)
                } label: {
                    Image(systemName: store.isPaused ? "pause.circle.fill" : "record.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(store.isPaused ? Color.orange : Color.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(glassPalette.controlCapsuleFill))
                        .overlay(Circle().strokeBorder(glassPalette.controlCapsuleStroke.opacity(0.85), lineWidth: 0.65))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isPaused ? "恢复记录剪贴板" : "无痕暂停记录剪贴板")
                .help(store.pauseStatusSummary)
                .contextMenu {
                    if store.isPaused {
                        Button("立即恢复记录剪贴板") { store.resumeCapture() }
                        Divider()
                    }
                    Button("无痕暂停 5 分钟（自动恢复）") {
                        store.pauseCapture(forMinutes: 5)
                        store.showToast("已开启 5 分钟无痕暂停（到点自动恢复）")
                    }
                    Button("无痕暂停 15 分钟（推荐 · 自动恢复）") {
                        store.pauseCapture(forMinutes: 15)
                        store.showToast("已开启 15 分钟无痕暂停（到点自动恢复）")
                    }
                    Button("无痕暂停 60 分钟（自动恢复）") {
                        store.pauseCapture(forMinutes: 60)
                        store.showToast("已开启 60 分钟无痕暂停（到点自动恢复）")
                    }
                    Divider()
                    Button("持续暂停（直到手动恢复）") {
                        store.pauseCapture(forMinutes: nil)
                        store.showToast("已持续暂停记录剪贴板")
                    }
                }

                // 设置按钮（有 GitHub 新版本时右上角展示蓝点提示）
                Button {
                    store.refreshAccessibilityStatus()
                    nav.showSettings = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(glassPalette.controlCapsuleFill))
                            .overlay(Circle().strokeBorder(glassPalette.controlCapsuleStroke.opacity(0.85), lineWidth: 0.65))

                        if updater.hasUpdateAvailable {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
                                .offset(x: -1, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("偏好设置")
                .help(updater.hasUpdateAvailable ? "发现新版本，点击进入设置更新" : "偏好设置")
            }
        }
    }

    // MARK: - iOS 滑动胶囊分类条（独立隔离渲染 + 常驻 GPU 硬件偏移滑块，120Hz 满帧零列表重绘干扰）

    private var filterBar: some View {
        let tabs = ClipFilterTab.visibleTabs(minimalMode: store.minimalModeEnabled)
        let selectedIdx = tabs.firstIndex(of: nav.selectedTab) ?? 0
        let pendingTodos = store.pendingTodoCount

        return GeometryReader { geo in
            let inset: CGFloat = 3
            let innerWidth = max(0, geo.size.width - inset * 2)
            let pillWidth = innerWidth / CGFloat(max(1, tabs.count))

            ZStack(alignment: .leading) {
                // 常驻单一选中胶囊滑块：仅做 GPU 水平位移，永不销毁重建、永不被列表 diff 打断
                Capsule()
                    .fill(glassPalette.activeSegmentFill)
                    .overlay(
                        Capsule()
                            .strokeBorder(glassPalette.controlCapsuleStroke, lineWidth: 0.6)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: 2.5, y: 1)
                    .frame(width: pillWidth, height: 28)
                    .offset(x: inset + CGFloat(selectedIdx) * pillWidth)
                    .animation(.spring(response: 0.22, dampingFraction: 0.84), value: nav.selectedTab)

                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        let isSelected = nav.selectedTab == tab
                        Button {
                            guard nav.selectedTab != tab else { return }
                            nav.selectedTab = tab
                        } label: {
                            HStack(spacing: 2.5) {
                                Text(tab.title)
                                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                if tab == .todo && pendingTodos > 0 {
                                    Text("\(min(pendingTodos, 99))")
                                        .font(.system(size: 10, weight: .bold))
                                        .monospacedDigit()
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.accentColor.opacity(0.9))
                                }
                            }
                            .frame(width: pillWidth, height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(tab.title)（\(tab.optionShortcutLabel(minimalMode: store.minimalModeEnabled))）")
                    }
                }
                .padding(.horizontal, inset)
            }
            .frame(width: geo.size.width, height: 34)
            .background(
                Capsule()
                    .fill(glassPalette.controlCapsuleFill)
            )
            .overlay(
                Capsule()
                    .strokeBorder(glassPalette.controlCapsuleStroke.opacity(0.75), lineWidth: 0.6)
            )
        }
        .frame(height: 34)
    }

    private var isSensitiveAuditQuery: Bool {
        let q = nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let auditTokens = ["@敏感", "@密钥", "@隐私", "@secret", "敏感", "@即焚", "@burn"]
        return auditTokens.contains { q == $0 || q.hasPrefix($0 + " ") || q.hasSuffix(" " + $0) }
    }

    private var sensitiveAuditSummaryBar: some View {
        let count = store.unpinnedSensitiveCount
        return HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.orange)

            Text("检出 \(count) 条未收藏敏感凭据")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(0.88))

            Text("· 收藏项永久保护")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                    _ = store.sweepAllUnpinnedSensitiveItems()
                    clampSelection()
                }
            } label: {
                Text("一键无痕清扫")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.orange.opacity(0.13)))
            }
            .buttonStyle(.plain)
            .help("彻底清除所有未收藏、非待办的敏感密钥、身份证与即焚残留（收藏项不受影响）")
        }
    }

    private var todoSummaryBar: some View {
        let pending = store.pendingTodoCount
        let done = store.completedTodoCount
        return HStack(spacing: 6) {
            Circle()
                .fill(pending > 0 ? Color.accentColor : Color(red: 0.06, green: 0.72, blue: 0.51))
                .frame(width: 6.5, height: 6.5)

            Text(pending > 0 ? "待完成 \(pending) 项" : "待办已全部完成")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(pending > 0 ? Color.primary.opacity(0.88) : Color(red: 0.06, green: 0.72, blue: 0.51))

            Text("· ⌘T 勾销 · ⌘P 钉桌面")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if pending + done > 0 {
                Button {
                    _ = store.copyTodosAsMarkdownChecklist()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "list.clipboard")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("复制清单")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("导出为 Markdown 任务清单（- [ ] / - [x]），一键贴入周报或飞书")
            }

            if done > 0 {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                        _ = store.archiveCompletedTodos()
                        clampSelection()
                    }
                } label: {
                    Text("归档已完成 (\(done))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.11)))
                }
                .buttonStyle(.plain)
                .help("将已完成事项移出待办清单（保留原剪贴记录）")
            }
        }
    }

    private var todoInlineCreateBanner: some View {
        let trimmed = nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let (alias, body) = QuickCaptureParser.splitAliasAndBody(trimmed)
        let isEmptyMatch = filteredItems.isEmpty
        return HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let alias {
                        Text(alias)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                        Text("·")
                            .foregroundStyle(.secondary)
                    }
                    Text(body)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(isEmptyMatch ? "按 ↵ 直接新建为待办（保留当前剪贴板）" : "按 ⌘↵ 新建为待办（按 ↵ 粘贴下方匹配项）")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                _ = commitEmptySearchCaptureIfApplicable(forcePin: false, allowNonEmptyMatchInTodo: true)
            } label: {
                Text(isEmptyMatch ? "新建 ↵" : "新建 ⌘↵")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.accentColor.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.65)
        )
    }

    private func todoCompletedSectionHeader(count: Int) -> some View {
        HStack(spacing: 7) {
            Text("已完成 · \(count)")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.75)
            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                    _ = store.archiveCompletedTodos()
                    clampSelection()
                }
            } label: {
                Text("清空已完成")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 1)
    }

    private var semanticTokenHintBar: some View {
        let tokens: [(token: String, label: String)] = [
            ("@rmb", "金额大写"),
            ("@tpl", "模板"),
            ("@secret", "凭据"),
            ("@json", "JSON"),
            ("@curl", "cURL"),
            ("@list", "多行列"),
            ("@color", "色值"),
            ("@url", "脏链接"),
            ("@time", "时间戳")
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(tokens, id: \.token) { entry in
                    let active = nav.searchText.lowercased().hasPrefix(entry.token)
                    Button {
                        nav.searchText = entry.token + " "
                    } label: {
                        Text("\(entry.token) \(entry.label)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(active ? Color.white : Color.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(active ? Color.accentColor : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var pinnedTemplateToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.indigo)
                    Text("支持 {{clip}} / {{clip_redacted}} / {{datetime}} / {{uuid}} 动态插值")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        nav.isCreatingTemplate.toggle()
                    }
                } label: {
                    Text(nav.isCreatingTemplate ? "收起" : "+ 新建模板")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(nav.isCreatingTemplate ? Color.secondary : Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }

            if nav.isCreatingTemplate {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $templateDraftText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 68)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.055))
                        )

                    HStack(spacing: 5) {
                        ForEach(["{{clip}}", "{{clip_redacted}}", "{{datetime}}", "{{uuid}}"], id: \.self) { ph in
                            Button {
                                templateDraftText += ph
                            } label: {
                                Text(ph)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        Button {
                            store.addPinnedTemplate(templateDraftText)
                            withAnimation(.easeOut(duration: 0.16)) {
                                nav.isCreatingTemplate = false
                            }
                        } label: {
                            Text("保存收藏")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
            }
        }
    }

    private func inlineAliasEditorBar(for target: ClipItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tag.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            TextField("输入记忆备注（如：生产服 SSH / 常用 SQL），留空清除", text: $aliasDraftText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isAliasFieldFocused)
                .onSubmit {
                    store.setCustomAlias(aliasDraftText, for: target)
                    aliasEditingItem = nil
                    nav.isEditingAlias = false
                }

            Button("保存") {
                store.setCustomAlias(aliasDraftText, for: target)
                aliasEditingItem = nil
                nav.isEditingAlias = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(Color.accentColor))

            Button {
                cancelAliasEdit()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.065))
        )
    }

    // MARK: - 剪贴记录列表

    private let imageGridColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 9),
        count: 3
    )

    private var contentList: some View {
        Group {
            if filteredItems.isEmpty {
                emptyStateView
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach(Array(displayRows.enumerated()), id: \.element.id) { rowIndex, row in
                                switch row {
                                case .standard(let index, let item):
                                    ClipCardView(
                                        item: item,
                                        index: index,
                                        isSelected: index == nav.selectedIndex,
                                        surfaceStyle: store.surfaceStyle,
                                        liquidGlassAppearance: store.liquidGlassAppearance,
                                        borderlessPanel: store.borderlessPanel,
                                        onSelect: {
                                            nav.selectExplicitly(index)
                                        },
                                        onHoverSelect: {
                                            nav.selectByHover(index)
                                        },
                                        onPaste: { plainTextOnly in
                                            store.copyAndOptionallyPaste(
                                                item,
                                                plainTextOnly: plainTextOnly,
                                                shouldAutoPaste: true,
                                                onBeforePaste: onDismiss
                                            )
                                        },
                                        onCopyOnly: { plainTextOnly in
                                            store.copyAndOptionallyPaste(
                                                item,
                                                plainTextOnly: plainTextOnly,
                                                shouldAutoPaste: false,
                                                onBeforePaste: nil
                                            )
                                        },
                                        onApplyTransform: { action, autoPaste in
                                            store.applyTransformAction(
                                                action,
                                                for: item,
                                                shouldAutoPaste: autoPaste,
                                                onBeforePaste: autoPaste ? onDismiss : nil
                                            )
                                        },
                                        onTogglePin: {
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                store.togglePin(item)
                                            }
                                        },
                                        onEditAlias: {
                                            beginAliasEdit(for: item)
                                        },
                                        onToggleTodo: {
                                            let willComplete = item.isPendingTodo
                                            if nav.selectedTab == .todo {
                                                nav.registerTodoCompletionSettle(for: item.id, isNowCompleted: willComplete)
                                            }
                                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                                store.toggleTodo(item)
                                            }
                                        },
                                        onToggleTodoCompletion: {
                                            let willComplete = item.isPendingTodo
                                            if nav.selectedTab == .todo {
                                                nav.registerTodoCompletionSettle(for: item.id, isNowCompleted: willComplete)
                                            }
                                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                                store.toggleTodoCompletion(item)
                                            }
                                        },
                                        onRemoveTodo: {
                                            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                                                store.removeFromTodo(item)
                                                clampSelection()
                                            }
                                        },
                                        onOpenQuickLook: {
                                            nav.selectedIndex = index
                                            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                                nav.showQuickLook = true
                                            }
                                        },
                                        onImageThumbnailHover: { hovering, rect in
                                            handleImageHover(item: item, hovering: hovering, tileRect: rect)
                                        },
                                        onDelete: {
                                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                                store.delete(item)
                                                clampSelection()
                                            }
                                        }
                                    )
                                    .cascadeAppear(
                                        isPresented: nav.isPresented,
                                        delay: Double(min(rowIndex, 8)) * 0.028
                                    )
                                    .id(item.id)

                                case .imageGrid(let entries):
                                    LazyVGrid(columns: imageGridColumns, spacing: 9) {
                                        ForEach(Array(entries.enumerated()), id: \.element.item.id) { colIndex, entry in
                                            ClipImageGridTile(
                                                item: entry.item,
                                                index: entry.index,
                                                isSelected: entry.index == nav.selectedIndex,
                                                onSelect: {
                                                    nav.selectExplicitly(entry.index)
                                                },
                                                onHoverSelect: {
                                                    nav.selectByHover(entry.index)
                                                },
                                                onPaste: {
                                                    dismissImagePreview(clearItem: true)
                                                    store.copyAndOptionallyPaste(
                                                        entry.item,
                                                        plainTextOnly: false,
                                                        shouldAutoPaste: true,
                                                        onBeforePaste: onDismiss
                                                    )
                                                },
                                                onCopyOnly: {
                                                    store.copyAndOptionallyPaste(
                                                        entry.item,
                                                        plainTextOnly: false,
                                                        shouldAutoPaste: false,
                                                        onBeforePaste: nil
                                                    )
                                                },
                                                onExtractOCR: { autoPaste in
                                                    dismissImagePreview(clearItem: true)
                                                    store.pasteExtractedOCRText(
                                                        for: entry.item,
                                                        shouldAutoPaste: autoPaste,
                                                        onBeforePaste: autoPaste ? onDismiss : nil
                                                    )
                                                },
                                                onTogglePin: {
                                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                        store.togglePin(entry.item)
                                                    }
                                                },
                                                onToggleTodo: {
                                                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                                        store.toggleTodo(entry.item)
                                                    }
                                                },
                                                onRemoveTodo: {
                                                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                                                        store.removeFromTodo(entry.item)
                                                        clampSelection()
                                                    }
                                                },
                                                onEditAlias: {
                                                    beginAliasEdit(for: entry.item)
                                                },
                                                onOpenQuickLook: {
                                                    dismissImagePreview(clearItem: true)
                                                    nav.selectedIndex = entry.index
                                                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                                        nav.showQuickLook = true
                                                    }
                                                },
                                                onDelete: {
                                                    if previewItem?.id == entry.item.id {
                                                        dismissImagePreview(clearItem: true)
                                                    }
                                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                                        store.delete(entry.item)
                                                        clampSelection()
                                                    }
                                                },
                                                onHoverChange: { hovering, tileRect in
                                                    handleImageHover(item: entry.item, hovering: hovering, tileRect: tileRect)
                                                }
                                            )
                                            .cascadeAppear(
                                                isPresented: nav.isPresented,
                                                delay: Double(min(rowIndex, 7)) * 0.028 + Double(min(colIndex, 8)) * 0.02
                                            )
                                            .id(entry.item.id)
                                        }
                                    }
                                    .padding(.vertical, 2)

                                case .todoCompletedHeader(let count):
                                    todoCompletedSectionHeader(count: count)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: nav.scrollRequestEpoch) { _, _ in
                        let idx = nav.selectedIndex
                        guard idx >= 0, idx < filteredItems.count else { return }
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo(filteredItems[idx].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        let isTodoTab = (nav.selectedTab == .todo)
        return VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 64, height: 64)
                Image(systemName: nav.searchText.isEmpty ? (isTodoTab ? "checkmark.circle" : "clipboard") : "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text(nav.searchText.isEmpty ? (isTodoTab ? "暂无待办事项" : "暂无剪贴记录") : "未找到匹配的内容")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
            Text(
                nav.searchText.isEmpty
                    ? (isTodoTab ? "对任意剪贴记录按 ⌘T 加入待办，或在上方输入 - 事项 回车速记" : "复制文本、链接、图片或文件后将自动出现在这里")
                    : (isTodoTab ? "按回车将上方输入直接添加为新待办事项" : "试试更换关键词，或将上方输入直接沉淀为新剪贴记录")
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 36)

            let trimmedSearch = nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSearch.isEmpty && !trimmedSearch.hasPrefix("@") {
                HStack(spacing: 8) {
                    Button {
                        _ = commitEmptySearchCaptureIfApplicable(forcePin: false)
                    } label: {
                        Text(isTodoTab ? "新建待办 ↵" : "存为新记录 ⌘↵")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5.5)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)

                    if !isTodoTab {
                        Button {
                            _ = commitEmptySearchCaptureIfApplicable(forcePin: true)
                        } label: {
                            Text("直接收藏 ⇧⌘↵")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5.5)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部状态栏

    private var footerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.isPaused ? Color.orange : Color.green)
                    .frame(width: 6.5, height: 6.5)
                Text("\(filteredItems.count) 条")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 6)

            // 恒定提示项：禁止在图片与文字 hover 切换时动态增删胶囊，确保外框与底栏零抖动
            HStack(spacing: 7) {
                keyHint("↵", "键入")
                if !store.minimalModeEnabled {
                    keyHint("⇧↵", "智变")
                }
                keyHint("⇥", "类目")
                keyHint("ESC", "关闭")
            }

            if !store.items.filter({ !$0.isPinned }).isEmpty {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        store.clearUnpinned()
                        nav.selectedIndex = 0
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("清空未收藏记录")
            }
        }
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            Text(label)
                .font(.system(size: 10.5))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(.secondary)
    }

    // MARK: - iOS 风格设置页

    private var settingsView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                if !store.isAccessibilityGranted {
                    settingsGroup(title: "辅助功能权限") {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("开启一键直接键入权限")
                                    .font(.system(size: 13.5, weight: .medium))
                                Text("授权后双击或按回车即可直接粘贴至当前光标位置")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button {
                                store.refreshAccessibilityStatus()
                                if store.isAccessibilityGranted {
                                    store.showToast("已检测到辅助功能授权")
                                } else {
                                    store.showToast("仍未生效：若已勾选旧版，请减号移除后重勾")
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(Color.primary.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .help("立即重新检测权限状态")

                            Button("前往开启") {
                                store.requestAccessibilityPermission()
                                store.openAccessibilitySettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }

                // 苹果官方风格液态玻璃背景模糊浓度（单一滑块 + 实时实景折射预览）
                settingsGroup(title: "液态玻璃") {
                    LiquidGlassBlurStyleCard(blurConcentration: $store.liquidGlassMaskOpacity)
                }

                // 模式与角色版本切换
                settingsGroup(title: "模式与版本") {
                    RoleAndOTASettingsSection(store: store, updater: updater)
                }

                // 通用与快捷键
                settingsGroup(title: "通用与快捷键") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("窗口始终在前（⌘P）")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("固定面板置顶，切换窗口与连续粘贴时不自动收起")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $store.alwaysOnTop)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.35)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自动启动")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("登录 macOS 后自动在菜单栏常驻运行")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLogin($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }

                    Divider().opacity(0.35)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("交互音效反馈")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("键入、收藏与转换时播放轻柔微音效（关闭后仍保留触控板震动）")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $store.soundEffectsEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.35)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("全局呼出快捷键")
                                .font(.system(size: 13.5, weight: .medium))
                            if nav.isRecordingHotKey, let conflict = nav.hotKeyConflictWarning {
                                Text(conflict)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.red)
                            } else if nav.isRecordingHotKey, let hint = nav.hotKeyRecordingHint {
                                Text(hint)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Text(nav.isRecordingHotKey ? "按下组合键，或双击 ⌘/⌥/⌃/⇧ 单键（ESC 取消）" : "点击录制组合键或双击 ⌘/⌥/⌃/⇧ 单键")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(nav.isRecordingHotKey ? Color.accentColor : .secondary)
                            }
                        }
                        Spacer()

                        Button {
                            if nav.isRecordingHotKey {
                                nav.isRecordingHotKey = false
                                nav.hotKeyConflictWarning = nil
                                HotKeyManager.shared.resumeAfterRecording()
                            } else {
                                nav.hotKeyConflictWarning = nil
                                HotKeyManager.shared.suspendForRecording()
                                nav.isRecordingHotKey = true
                            }
                        } label: {
                            let hasConflict = nav.isRecordingHotKey && nav.hotKeyConflictWarning != nil
                            Text(hasConflict ? "冲突 · 请重按" : (nav.isRecordingHotKey ? "等待按键..." : store.hotKeyShortcut.displayString))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(nav.isRecordingHotKey ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(hasConflict ? Color.red : (nav.isRecordingHotKey ? Color.accentColor : Color.primary.opacity(0.08)))
                                )
                        }
                        .buttonStyle(.plain)

                        if store.hotKeyShortcut != .defaultShortcut && !nav.isRecordingHotKey {
                            Button {
                                nav.hotKeyConflictWarning = nil
                                store.hotKeyShortcut = .defaultShortcut
                                store.showToast("已恢复默认快捷键 ⌥ V")
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.primary.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .help("恢复默认 ⌥ V")
                        }
                    }
                }

                // 智能辅助（极简模式下自动隐藏）
                if !store.minimalModeEnabled {
                    settingsGroup(title: "智能辅助") {
                        AdaptiveIntelligenceSettingsSection(store: store)
                    }
                }

                // 隐私护盾与迁移整合分组
                settingsGroup(title: "隐私护盾与迁移") {
                    HStack(spacing: 7) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.green)
                        Text("本机钥匙串 AES-256-GCM 透明加密已启用 · 零联网上传")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.green.opacity(0.09))
                    )

                    Toggle(isOn: $store.screenSharePrivacyEnabled) {
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("投屏与录屏光学隐身护盾")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("腾讯会议 / 飞书共享屏幕及录屏中自动隐去 iClip，本机可见")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Toggle(isOn: $store.maskSensitivePreviews) {
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("敏感凭据防肩窥圆点遮罩")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("API 密钥与私钥默认圆点雾化，选中或悬停即刻原位显影")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Toggle(isOn: $store.autoClearConcealedPasteboard) {
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("密码剪贴板 60 秒残留擦除")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("从 1Password / 系统密码复制密码后超时自动清空系统剪贴板")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Toggle(isOn: $store.autoExpireUnpinnedSecrets) {
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("未收藏敏感凭据 24h 自动销毁")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("临时密钥与身份证卡号满 24 小时自动无痕代谢，收藏项永久守护")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Divider().opacity(0.35)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("历史保留上限")
                                .font(.system(size: 13.5, weight: .medium))
                            Spacer()
                            Text("收藏记录永不清理")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Picker("", selection: $store.maxHistoryCount) {
                            Text("50 条").tag(50)
                            Text("100 条").tag(100)
                            Text("200 条").tag(200)
                            Text("500 条").tag(500)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Divider().opacity(0.35)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("隐私忽略应用（不记录其复制内容）")
                            .font(.system(size: 12.5, weight: .medium))

                        let visibleIgnoredApps = store.ignoredApps.filter {
                            ClipboardStore.isAppAvailableOnSystem(bundleIdentifier: $0.bundleIdentifier)
                        }

                        if !visibleIgnoredApps.isEmpty {
                            VStack(spacing: 5) {
                                ForEach(visibleIgnoredApps) { app in
                                    HStack(spacing: 8) {
                                        if let icon = store.appIcon(forBundleID: app.bundleIdentifier) {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 18, height: 18)
                                        }

                                        Text(app.displayName)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .lineLimit(1)

                                        Spacer()

                                        Button {
                                            withAnimation(.easeOut(duration: 0.16)) {
                                                store.removeIgnoredApp(bundleIdentifier: app.bundleIdentifier)
                                            }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary.opacity(0.75))
                                        }
                                        .buttonStyle(.plain)
                                        .help("移出忽略名单")
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Menu {
                                let candidates = store.runningCandidateAppsForIgnore()
                                if candidates.isEmpty {
                                    Text("暂无可添加的运行中应用")
                                } else {
                                    ForEach(candidates) { candidate in
                                        Button(candidate.displayName) {
                                            store.addIgnoredApp(
                                                bundleIdentifier: candidate.bundleIdentifier,
                                                displayName: candidate.displayName
                                            )
                                        }
                                    }
                                }
                            } label: {
                                Label("添加运行中应用", systemImage: "plus.circle")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()

                            Spacer()

                            Button("选择应用...") {
                                pickAppToIgnore()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Divider().opacity(0.35)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("收藏归档与跨软件一键搬家")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("已收藏 \(store.pinnedItemCount) 条 · 支持 .iclip / Raycast / Maccy / CSV")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Button("导入...") {
                            importPinnedArchiveAction()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("导出 (.iclip)") {
                            exportPinnedArchiveAction()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                // 按需展开的键盘快捷键速查表（默认折叠，告别长列表刷屏）
                settingsGroup(title: "帮助") {
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            showShortcutReference.toggle()
                        }
                    } label: {
                        HStack {
                            Text("键盘快捷键速查")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: showShortcutReference ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showShortcutReference {
                        Divider().opacity(0.35)
                        shortcutRow("鼠标旁呼出 / 隐藏", store.hotKeyShortcut.displayString)
                        Divider().opacity(0.35)
                        shortcutRow("直接键入光标所在区域", "双击 / ↵")
                        Divider().opacity(0.35)
                        shortcutRow("左 / 右切换内容类目", "⇧⇥ / ⇥")
                        Divider().opacity(0.35)
                        shortcutRow("图片网格方向导航", "↑ ↓ ← →")
                        Divider().opacity(0.35)
                        shortcutRow("首选智能变换 / 脱敏键入", "⇧ ↵")
                        Divider().opacity(0.35)
                        shortcutRow("直达第 1~3 个语义变换", "⌃ 1 ~ 3")
                        Divider().opacity(0.35)
                        shortcutRow("忽略守护强制贴原始明文", "⌥ ↵")
                        Divider().opacity(0.35)
                        shortcutRow("QuickLook 原文与变换对照速览", "Space / ⌘ Y")
                        Divider().opacity(0.35)
                        shortcutRow("按语义类型速筛", "@json / @secret / @color")
                        Divider().opacity(0.35)
                        shortcutRow("快速键入前 9 条", "⌘ 1 ~ 9")
                        Divider().opacity(0.35)
                        shortcutRow("删除当前选中项", "⌘ ⌫")
                    }
                }

                // 底部操作
                HStack(spacing: 10) {
                    Button {
                        store.clearUnpinned()
                        nav.showSettings = false
                    } label: {
                        Text("清空未收藏历史")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    Button {
                        onQuit()
                    } label: {
                        Text("退出 iClip")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.10)))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(glassPalette.groupFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(glassPalette.groupStroke, lineWidth: 0.75)
            )
        }
    }

    private func shortcutRow(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Text(shortcut)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
    }

    // MARK: - 拖拽复制接收浮层

    private var dragDropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10))

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(0.85),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
                .padding(10)

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("松手即复制到剪贴板")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("支持文字、链接、图片与文件")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(glassPalette.groupStroke, lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.16), radius: 14, y: 6)
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - 轻提示胶囊

    private func toastPill(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)

            if store.canUndoLastDeletion && message.contains("⌘Z") {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                        _ = store.undoLastDeletion()
                    }
                } label: {
                    Text("撤销")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.80))
                .shadow(color: Color.black.opacity(0.22), radius: 8, y: 3)
        )
    }

    // MARK: - 图片悬停纯净原图预览控制

    private func handleImageHover(item: ClipItem, hovering: Bool, tileRect: CGRect) {
        if hovering {
            previewHideWorkItem?.cancel()
            previewHideWorkItem = nil
            hoveredTileItemID = item.id

            let wasVisible = isPreviewVisible
            let isSameItem = previewItem?.id == item.id

            if !wasVisible {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    previewItem = item
                    previewTileRect = tileRect
                }
                let targetID = item.id
                // 下一帧再触发绽放动画，确保首次悬停也能完整演绎从缩略图边缘生长的弹簧动效
                DispatchQueue.main.async {
                    guard hoveredTileItemID == targetID else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.08)) {
                        isPreviewVisible = true
                    }
                }
            } else if isSameItem {
                // 列表滚动时实时贴合当前缩略图位置，不滞后
                previewTileRect = tileRect
            } else {
                // 跨图片网格滑动时连续平移与形变，无闪退重绘
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.1)) {
                    previewItem = item
                    previewTileRect = tileRect
                }
            }
        } else if hoveredTileItemID == item.id || previewItem?.id == item.id {
            if hoveredTileItemID == item.id {
                hoveredTileItemID = nil
            }
            previewHideWorkItem?.cancel()
            let itemID = item.id
            let work = DispatchWorkItem {
                guard hoveredTileItemID == nil, previewItem?.id == itemID else { return }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.94)) {
                    isPreviewVisible = false
                }
            }
            previewHideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
        }
    }

    private func dismissImagePreview(clearItem: Bool) {
        previewHideWorkItem?.cancel()
        previewHideWorkItem = nil
        hoveredTileItemID = nil
        if clearItem {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPreviewVisible = false
                previewItem = nil
            }
        } else {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.94)) {
                isPreviewVisible = false
            }
        }
    }

    // MARK: - 键盘控制辅助

    var canMoveHorizontallyInGrid: Bool {
        guard !filteredItems.isEmpty else { return false }
        if nav.selectedTab == .image { return true }
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return false }
        return filteredItems[nav.selectedIndex].type == .image
    }

    func stepFilterTab(delta: Int) {
        let tabs = ClipFilterTab.visibleTabs(minimalMode: store.minimalModeEnabled)
        guard let currentIdx = tabs.firstIndex(of: nav.selectedTab) else { return }
        let nextIdx = (currentIdx + delta + tabs.count) % tabs.count
        selectFilterTab(tabs[nextIdx])
    }

    func selectFilterTab(_ tab: ClipFilterTab) {
        if nav.selectedTab == tab {
            nav.selectedIndex = 0
            nav.preferredGridColumn = nil
            nav.lockPointerAtCurrentMouse()
            nav.scrollRequestEpoch &+= 1
            return
        }
        dismissImagePreview(clearItem: true)
        if nav.showQuickLook {
            nav.isQuickLookEditing = false
            nav.showQuickLook = false
        }
        nav.selectedIndex = 0
        nav.preferredGridColumn = nil
        nav.lockPointerAtCurrentMouse()
        nav.selectedTab = tab
    }

    func moveSelection(direction: PanelNavigationDirection) {
        let count = filteredItems.count
        guard count > 0 else { return }
        dismissImagePreview(clearItem: false)
        let result = GridNavigationHelper.nextIndex(
            from: nav.selectedIndex,
            direction: direction,
            visualRows: nav.cachedVisualRows,
            preferredColumn: nav.preferredGridColumn
        )
        nav.selectedIndex = result.index
        nav.preferredGridColumn = result.preferredColumn
        nav.lockPointerAtCurrentMouse()
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
        nav.scrollRequestEpoch &+= 1
    }

    func pasteSelected(forceRawSecret: Bool = false) {
        if let suggestionPayload = QuickSuggestionCommandBanner.extractPayload(from: nav.searchText) {
            guard !suggestionPayload.isEmpty else { return }
            let outcome = AdaptiveIntelligenceEngine.shared.adoptUserSuggestion(suggestionPayload, in: store)
            nav.searchText = ""
            store.showToast(outcome.message)
            return
        }
        if let capture = QuickCaptureParser.parse(from: nav.searchText) {
            guard !capture.isEmptyBody else { return }
            if capture.defaultTodo {
                store.captureQuickTodo(body: capture.bodyText, alias: capture.customAlias, copyToClipboard: false)
            } else {
                store.captureQuickNote(body: capture.bodyText, alias: capture.customAlias, pin: capture.defaultPin)
            }
            nav.searchText = ""
            return
        }
        if nav.selectedTab == .todo && filteredItems.isEmpty && commitEmptySearchCaptureIfApplicable(forcePin: false) {
            return
        }
        if let pwGen = SecurePasswordGenerator.evaluate(nav.searchText) {
            nav.searchText = ""
            store.pasteEphemeralSecret(pwGen.secretValue, toast: pwGen.ephemeralToast, shouldAutoPaste: true, onBeforePaste: onDismiss)
            return
        }
        if let math = InstantMathEvaluator.evaluate(nav.searchText, latestClipboardText: store.items.first?.text),
           (filteredItems.isEmpty || math.isExplicitOrContextual) {
            nav.searchText = ""
            store.pasteInstantValue(math.plainValue, toast: "已键入计算结果 \(math.plainValue)", shouldAutoPaste: true, onBeforePaste: onDismiss)
            return
        }
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        if nav.showQuickLook {
            let tabs = QuickLookTabBuilder.buildTabs(for: item, store: store)
            guard !tabs.isEmpty else { return }
            let idx = min(max(nav.quickLookTabIndex, 0), tabs.count - 1)
            let chosen = tabs[idx]
            nav.isQuickLookEditing = false
            nav.showQuickLook = false
            switch chosen.payload {
            case .image:
                store.copyAndOptionallyPaste(item, plainTextOnly: false, shouldAutoPaste: true, forceRawSecret: true, onBeforePaste: onDismiss)
            case .text(let text):
                if idx == 0 && item.type != .image {
                    store.copyAndOptionallyPaste(item, plainTextOnly: false, shouldAutoPaste: true, forceRawSecret: true, onBeforePaste: onDismiss)
                } else {
                    let snapActions = store.semanticSnapshot(for: item).actions
                    if item.type != .image, (idx - 1) >= 0, (idx - 1) < snapActions.count {
                        store.applyTransformAction(snapActions[idx - 1], for: item, shouldAutoPaste: true, onBeforePaste: onDismiss)
                    } else {
                        store.pasteCustomString(text, sourceItem: item, toast: chosen.toast, shouldAutoPaste: true, onBeforePaste: onDismiss)
                    }
                }
            }
            return
        }
        store.copyAndOptionallyPaste(
            item,
            plainTextOnly: forceRawSecret,
            shouldAutoPaste: true,
            forceRawSecret: forceRawSecret,
            onBeforePaste: onDismiss
        )
    }

    func stepQuickLookTab(delta: Int) {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let tabs = QuickLookTabBuilder.buildTabs(for: filteredItems[nav.selectedIndex], store: store)
        guard tabs.count > 1 else { return }
        nav.quickLookTabIndex = (nav.quickLookTabIndex + delta + tabs.count) % tabs.count
    }

    func selectQuickLookDiffTabIfAvailable() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let tabs = QuickLookTabBuilder.buildTabs(for: filteredItems[nav.selectedIndex], store: store)
        if let diffIdx = tabs.firstIndex(where: { $0.id == QuickLookTabItem.diffLatestTabID }) {
            nav.quickLookTabIndex = diffIdx
        }
    }

    func enterQuickLookEditMode() -> Bool {
        guard nav.showQuickLook,
              nav.selectedIndex >= 0,
              nav.selectedIndex < filteredItems.count else { return false }
        let item = filteredItems[nav.selectedIndex]
        let tabs = QuickLookTabBuilder.buildTabs(for: item, store: store)
        guard !tabs.isEmpty else { return false }
        let idx = min(max(nav.quickLookTabIndex, 0), tabs.count - 1)
        guard let text = tabs[idx].textValue else { return false }
        nav.quickLookDraftText = text
        nav.isQuickLookEditing = true
        return true
    }

    func commitQuickLookDraftPaste() {
        guard nav.showQuickLook,
              nav.isQuickLookEditing,
              nav.selectedIndex >= 0,
              nav.selectedIndex < filteredItems.count else { return }
        let target = filteredItems[nav.selectedIndex]
        let draft = nav.quickLookDraftText
        nav.isQuickLookEditing = false
        nav.showQuickLook = false
        store.pasteCustomString(draft, sourceItem: target, toast: "已键入微调内容", shouldAutoPaste: true, onBeforePaste: onDismiss)
    }

    func saveQuickLookDraftToItem() {
        guard nav.showQuickLook,
              nav.isQuickLookEditing,
              nav.selectedIndex >= 0,
              nav.selectedIndex < filteredItems.count else { return }
        let target = filteredItems[nav.selectedIndex]
        if store.updateItemText(nav.quickLookDraftText, for: target) {
            nav.isQuickLookEditing = false
        }
    }

    func beginAliasEdit(for item: ClipItem) {
        aliasDraftText = item.customAlias ?? ""
        nav.isEditingAlias = true
        withAnimation(.easeOut(duration: 0.16)) {
            aliasEditingItem = item
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isAliasFieldFocused = true
        }
    }

    func beginAliasEditForSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        beginAliasEdit(for: filteredItems[nav.selectedIndex])
    }

    @discardableResult
    func commitEmptySearchCaptureIfApplicable(forcePin: Bool, allowNonEmptyMatchInTodo: Bool = true) -> Bool {
        let canProceed = filteredItems.isEmpty || (allowNonEmptyMatchInTodo && nav.selectedTab == .todo && !forcePin)
        guard canProceed else { return false }
        let trimmed = nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("@") else { return false }
        let (alias, body) = QuickCaptureParser.splitAliasAndBody(trimmed)
        guard !body.isEmpty else { return false }
        if nav.selectedTab == .todo && !forcePin {
            store.captureQuickTodo(body: body, alias: alias, copyToClipboard: false)
        } else {
            store.captureQuickNote(body: body, alias: alias, pin: forcePin || (alias != nil))
        }
        nav.searchText = ""
        return true
    }

    func appendSelectedToClipboard() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        store.appendItemToCurrentClipboard(filteredItems[nav.selectedIndex])
    }

    func copySelectedOnly(plainPathOrText: Bool) -> Bool {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return false }
        let item = filteredItems[nav.selectedIndex]
        if nav.showQuickLook && !plainPathOrText {
            let tabs = QuickLookTabBuilder.buildTabs(for: item, store: store)
            if !tabs.isEmpty {
                let idx = min(max(nav.quickLookTabIndex, 0), tabs.count - 1)
                let chosen = tabs[idx]
                nav.isQuickLookEditing = false
                nav.showQuickLook = false
                switch chosen.payload {
                case .image:
                    store.copyAndOptionallyPaste(item, plainTextOnly: false, shouldAutoPaste: false, onBeforePaste: nil)
                    store.showToast("已复制图片")
                case .text(let text):
                    store.pasteCustomString(text, sourceItem: item, toast: "已复制预览内容", shouldAutoPaste: false, onBeforePaste: nil)
                }
                return true
            }
        }
        if plainPathOrText {
            store.copyPlainPathOrText(item)
        } else {
            store.copyAndOptionallyPaste(item, plainTextOnly: false, shouldAutoPaste: false, onBeforePaste: nil)
            store.showToast("✓ 已复制到剪贴板")
        }
        return true
    }

    @discardableResult
    func openSelectedExternally() -> Bool {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return false }
        let item = filteredItems[nav.selectedIndex]
        if nav.showQuickLook {
            nav.isQuickLookEditing = false
            nav.showQuickLook = false
        }
        return store.openItemExternally(item)
    }

    func cancelAliasEdit() {
        aliasEditingItem = nil
        nav.isEditingAlias = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            isSearchFocused = true
        }
    }

    func pasteTransformAtIndexForSelected(_ actionIndex: Int) {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        let snapshot = store.semanticSnapshot(for: item)
        guard actionIndex >= 0, actionIndex < snapshot.actions.count else { return }
        store.applyTransformAction(snapshot.actions[actionIndex], for: item, shouldAutoPaste: true, onBeforePaste: onDismiss)
    }

    func pasteSmartTransformedSelected() {
        if let capture = QuickCaptureParser.parse(from: nav.searchText) {
            guard !capture.isEmptyBody else { return }
            if capture.defaultTodo {
                store.captureQuickTodo(body: capture.bodyText, alias: capture.customAlias, copyToClipboard: true)
            } else {
                store.captureQuickNote(body: capture.bodyText, alias: capture.customAlias, pin: true)
            }
            nav.searchText = ""
            return
        }
        if let pwGen = SecurePasswordGenerator.evaluate(nav.searchText) {
            SecurePasswordGenerator.bumpGenerationSalt()
            nav.searchText = ""
            store.captureQuickNote(body: pwGen.secretValue, alias: pwGen.defaultVaultAlias, pin: true)
            onDismiss()
            return
        }
        if let math = InstantMathEvaluator.evaluate(nav.searchText, latestClipboardText: store.items.first?.text),
           (filteredItems.isEmpty || math.isExplicitOrContextual),
           let rmb = math.rmbUppercase {
            nav.searchText = ""
            store.pasteInstantValue(rmb, toast: "已键入大写金额", shouldAutoPaste: true, onBeforePaste: onDismiss)
            return
        }
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        if !store.minimalModeEnabled && item.type == .image {
            dismissImagePreview(clearItem: true)
            store.pasteExtractedOCRText(for: item, shouldAutoPaste: true, onBeforePaste: onDismiss)
            return
        }
        let snapshot = store.semanticSnapshot(for: item)
        if let primaryAction = snapshot.actions.first {
            store.applyTransformAction(primaryAction, for: item, shouldAutoPaste: true, onBeforePaste: onDismiss)
        } else {
            store.copyAndOptionallyPaste(item, plainTextOnly: true, shouldAutoPaste: true, onBeforePaste: onDismiss)
        }
    }

    func pasteItem(at index: Int, plainTextOnly: Bool = false, smartTransform: Bool = false) {
        guard index >= 0, index < filteredItems.count else { return }
        if smartTransform {
            nav.selectedIndex = index
            pasteSmartTransformedSelected()
            return
        }
        let item = filteredItems[index]
        store.copyAndOptionallyPaste(item, plainTextOnly: plainTextOnly, shouldAutoPaste: true, onBeforePaste: onDismiss)
    }

    func togglePinForSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            store.togglePin(item)
        }
    }

    func toggleTodoForSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        let willComplete = item.isPendingTodo
        if nav.selectedTab == .todo {
            nav.registerTodoCompletionSettle(for: item.id, isNowCompleted: willComplete)
        }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
            store.toggleTodo(item)
        }
    }

    func toggleBurnAfterPasteForSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        store.toggleBurnAfterPaste(filteredItems[nav.selectedIndex])
    }

    @discardableResult
    func pasteAndCompleteTodoIfApplicable() -> Bool {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return false }
        let item = filteredItems[nav.selectedIndex]
        guard item.isPendingTodo else { return false }
        store.markTodoCompletedSilently(item)
        store.copyAndOptionallyPaste(item, plainTextOnly: false, shouldAutoPaste: true, onBeforePaste: onDismiss)
        store.showToast("✓ 已键入并完成待办")
        return true
    }

    func deleteSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            store.delete(item)
            clampSelection()
        }
    }

    private func pickAppToIgnore() {
        nav.suppressAutoHide = true
        let panel = NSOpenPanel()
        panel.title = "选择要忽略剪贴记录的应用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        let response = panel.runModal()
        nav.suppressAutoHide = false

        guard response == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        store.addIgnoredApp(bundleIdentifier: bundleID, displayName: name)
    }

    private func exportPinnedArchiveAction() {
        guard store.pinnedItemCount > 0 else {
            store.showToast("暂无已收藏的记录可导出")
            return
        }

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let defaultName = "iClip-收藏资产-\(df.string(from: Date())).iclip"

        nav.suppressAutoHide = true
        let panel = NSSavePanel()
        panel.title = "导出 iClip 收藏与模板归档"
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true
        if let iclipType = UTType(filenameExtension: "iclip", conformingTo: .json) {
            panel.allowedContentTypes = [iclipType]
        }

        let passField = ArchivePassphraseUIHelper.attachExportPassphraseAccessory(
            to: panel,
            sensitivePinnedCount: store.pinnedSensitiveItemCount
        )

        let response = panel.runModal()
        nav.suppressAutoHide = false

        guard response == .OK, var targetURL = panel.url else { return }
        if targetURL.pathExtension.isEmpty {
            targetURL = targetURL.appendingPathExtension("iclip")
        }
        let pw = passField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let count = try store.exportPinnedArchive(to: targetURL, passphrase: pw.isEmpty ? nil : pw)
            store.showToast(pw.isEmpty ? "已导出 \(count) 条收藏至 \(targetURL.lastPathComponent)" : "已口令加密导出 \(count) 条收藏（Mac/Win 互通）")
        } catch {
            store.showToast(error.localizedDescription)
        }
    }

    private func importPinnedArchiveAction() {
        nav.suppressAutoHide = true
        let panel = NSOpenPanel()
        panel.title = "导入 .iclip 归档或 Raycast / Maccy / Paste / CSV 常用语"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        var allowed: [UTType] = [.json, .commaSeparatedText, .tabSeparatedText, .plainText, .data]
        if let iclipType = UTType(filenameExtension: "iclip") {
            allowed.insert(iclipType, at: 0)
        }
        panel.allowedContentTypes = allowed

        let response = panel.runModal()
        nav.suppressAutoHide = false

        guard response == .OK, let sourceURL = panel.url else { return }
        do {
            let summary: ArchiveImportSummary
            do {
                summary = try store.importPinnedArchive(from: sourceURL, passphrase: nil)
            } catch ArchiveBackupError.passphraseRequiredOrIncorrect {
                nav.suppressAutoHide = true
                let entered = ArchivePassphraseUIHelper.promptImportPassphrase(for: sourceURL.lastPathComponent)
                nav.suppressAutoHide = false
                guard let pw = entered else { return }
                summary = try store.importPinnedArchive(from: sourceURL, passphrase: pw)
            }
            if summary.importedNewCount > 0 && summary.updatedExistingCount > 0 {
                store.showToast("已从\(summary.sourceFormatLabel)迁入 \(summary.importedNewCount) 条，更新 \(summary.updatedExistingCount) 条")
            } else if summary.importedNewCount > 0 {
                store.showToast("已从\(summary.sourceFormatLabel)无损迁入 \(summary.importedNewCount) 条收藏")
            } else if summary.updatedExistingCount > 0 {
                store.showToast("已合并更新 \(summary.updatedExistingCount) 条既有收藏")
            } else {
                store.showToast("\(summary.sourceFormatLabel)内 \(summary.totalInBundle) 条记录均已在本地存在")
            }
        } catch {
            store.showToast(error.localizedDescription)
        }
    }

    private func clampSelection() {
        let count = filteredItems.count
        if count == 0 {
            nav.selectedIndex = 0
        } else if nav.selectedIndex >= count {
            nav.selectedIndex = count - 1
        }
    }
}

/// 卡片瀑布错峰浮现动效修饰器
private struct CascadeAppearModifier: ViewModifier {
    let isPresented: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .offset(y: isPresented ? 0 : -16)
            .scaleEffect(isPresented ? 1 : 0.94, anchor: .top)
            .animation(
                isPresented
                    ? .spring(response: 0.36, dampingFraction: 0.78).delay(delay)
                    : .easeOut(duration: 0.12),
                value: isPresented
            )
    }
}

private extension View {
    func cascadeAppear(isPresented: Bool, delay: Double) -> some View {
        modifier(CascadeAppearModifier(isPresented: isPresented, delay: delay))
    }
}

#endif
