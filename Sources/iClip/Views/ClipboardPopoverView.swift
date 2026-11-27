import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// 列表行模型：连续图片自动聚合成按真实宽高比排布的自适应流式图片墙，非图片保持单行精致卡片
enum ClipDisplayRow: Identifiable {
    struct PlacedImageEntry {
        let index: Int
        let item: ClipItem
        let width: CGFloat
        let height: CGFloat
    }

    case standard(index: Int, item: ClipItem)
    case imageGrid(entries: [PlacedImageEntry])
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
    @Published private(set) var listRevision: UInt64 = 0
    let selection = PanelSelectionStore()
    var selectedIndex: Int {
        get { selection.selectedIndex }
        set { selection.setSelectedIndex(newValue) }
    }
    @Published var focusTrigger: UUID = UUID()
    @Published var blurSearchTrigger: UUID = UUID()
    @Published var showSettings: Bool = false
    @Published var isPresented: Bool = false
    @Published var presentationEpoch: Int = 0
    @Published var scrollRequestEpoch: Int = 0
    @Published var isRecordingHotKey: Bool = false {
        didSet {
            if !isRecordingHotKey {
                recordingHotKeySlot = nil
            }
        }
    }
    @Published var recordingHotKeySlot: HotKeySlotRole? = nil
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
    /// 当前面板内容区可用宽度（随用户手动拖拽面板宽度动态同步，驱动自适应流式图片墙重排）
    @Published var panelContentWidth: CGFloat = 392
    /// 当前是否处于搜索输入框聚焦态（聚焦期间锁定为无列表选区并锚定当前光标）
    var isSearchInputFocused: Bool = false {
        didSet {
            if isSearchInputFocused {
                if selectedIndex >= 0 {
                    selectedIndex = -1
                }
                lockPointerAtCurrentMouse()
            }
        }
    }
    var onResignSearchFocus: (() -> Void)? = nil
    var onResetSpacePreviewGesture: (() -> Void)? = nil
    private var lastRebuildFilterKey: String = ""
    private var settlingWorkItems: [UUID: DispatchWorkItem] = [:]
    var suppressAutoHide: Bool = false

    private(set) var cachedFilteredItems: [ClipItem] = []
    private(set) var cachedDisplayRows: [ClipDisplayRow] = []
    private(set) var cachedVisualRows: [[Int]] = []
    private(set) var cachedTopTriggerMatchedID: UUID? = nil
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
                guard let self else { return }
                let nextKey = "\(tab.rawValue)|\(pinCat?.rawValue ?? "")|\(query)"
                let shouldAnimate = self.isPresented && !self.lastRebuildFilterKey.isEmpty && self.lastRebuildFilterKey == nextKey
                self.rebuildCache(
                    items: items,
                    tab: tab,
                    pinCat: pinCat,
                    query: query,
                    animateReorder: shouldAnimate
                )
            }
            .store(in: &cancellables)

        $panelContentWidth
            .dropFirst()
            .removeDuplicates { abs($0 - $1) < 2 }
            .sink { [weak self] newWidth in
                guard let self, let s = self.storeRef else { return }
                self.rebuildCache(
                    items: s.items,
                    tab: self.selectedTab,
                    pinCat: self.selectedPinCategory,
                    query: self.searchText,
                    contentWidthOverride: newWidth
                )
            }
            .store(in: &cancellables)

        $settlingCompletedTodoIDs
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, let s = self.storeRef else { return }
                self.rebuildCache(items: s.items, tab: self.selectedTab, pinCat: self.selectedPinCategory, query: self.searchText)
            }
            .store(in: &cancellables)

        Publishers.Merge4(
            resolvedStore.$activeTargetAppName.dropFirst().map { _ in () },
            resolvedStore.$minimalModeEnabled.dropFirst().map { _ in () },
            resolvedStore.$financeAssistantEnabled.dropFirst().map { _ in () },
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

        selection.onSelectionDidChange = { [weak self] _, _ in
            guard let self else { return }
            if self.showQuickLook || SecretCapsuleMessenger.isCapsuleCommandPrefix(self.searchText) {
                self.objectWillChange.send()
            }
        }
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

    private func rebuildCache(
        items: [ClipItem],
        tab: ClipFilterTab,
        pinCat: PinCategory? = nil,
        query: String,
        contentWidthOverride: CGFloat? = nil,
        animateReorder: Bool = false
    ) {
        lastRebuildFilterKey = "\(tab.rawValue)|\(pinCat?.rawValue ?? "")|\(query)"
        // 解析可选的 @语义 速筛前缀（例如 "@json user" 或 "@secret"）
        let isCommandInput = (QuickSuggestionCommandBanner.extractPayload(from: query) != nil)
            || (QuickCaptureParser.parse(from: query) != nil)
            || (SecurePasswordGenerator.evaluate(query) != nil)
            || SecretCapsuleMessenger.isCapsuleCommandPrefix(query)
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
            // 设为待办的内容统一收归「待办」专属列表，不再在普通剪贴板各分类中重复干扰显示
            case .all: tabMatches = !item.isTodo
            case .todo: tabMatches = item.isTodo
            case .pinned:
                if let pinCat, !resolvedStore.minimalModeEnabled {
                    tabMatches = !item.isTodo && item.isPinned && item.pinCategory == pinCat
                } else {
                    tabMatches = !item.isTodo && item.isPinned
                }
            case .text: tabMatches = !item.isTodo && item.type == .text
            case .link: tabMatches = !item.isTodo && item.type == .link
            case .image: tabMatches = !item.isTodo && item.type == .image
            case .file: tabMatches = !item.isTodo && item.type == .file
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
                return lhs.effectiveSortTimestamp > rhs.effectiveSortTimestamp
            }
        } else if resolvedStore.minimalModeEnabled {
            let trimmedTextQ = textQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            filtered = trimmedTextQ.isEmpty
                ? rawMatched
                : SmartSearchRanker.prioritizeTriggerKeywordMatches(rawMatched, query: trimmedTextQ)
        } else if !textQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = SmartSearchRanker.rankSearchResults(
                rawMatched,
                query: textQuery,
                targetApp: resolvedStore.activeTargetAppName,
                engine: .shared
            )
        } else if tab == .pinned {
            if rawMatched.contains(where: { $0.manualSortTimestamp != nil }) {
                filtered = rawMatched
            } else {
                filtered = SmartSearchRanker.rankPinnedItemsForContext(
                    rawMatched,
                    targetApp: resolvedStore.activeTargetAppName,
                    engine: .shared
                )
            }
        } else {
            filtered = rawMatched
        }

        let trimmedTextQuery = textQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTextQuery.isEmpty,
           let firstItem = filtered.first,
           firstItem.triggerMatchTier(for: trimmedTextQuery) != .none {
            self.cachedTopTriggerMatchedID = firstItem.id
        } else {
            self.cachedTopTriggerMatchedID = nil
        }

        var rows: [ClipDisplayRow] = []
        rows.reserveCapacity(filtered.count + 1)
        var visualRows: [[Int]] = []
        visualRows.reserveCapacity(filtered.count + 1)
        var imageBuffer: [(index: Int, item: ClipItem)] = []
        let sunkDoneCount = (tab == .todo) ? filtered.filter { $0.isTodoCompleted && !settling.contains($0.id) }.count : 0
        var hasInsertedDoneHeader = false
        let contentW = max(240, contentWidthOverride ?? panelContentWidth)

        func flushImageWallBuffer() {
            guard !imageBuffer.isEmpty else { return }
            let placedRows = AdaptiveImageWallLayout.buildRows(
                entries: imageBuffer,
                containerWidth: contentW,
                targetRowHeight: contentW >= 540 ? 124 : 104,
                minRowHeight: 78,
                maxRowHeight: contentW >= 540 ? 204 : 148,
                spacing: 8,
                dimensionsOf: { ($0.imageWidth, $0.imageHeight) }
            )
            for placedRow in placedRows {
                let rowEntries = placedRow.map {
                    ClipDisplayRow.PlacedImageEntry(index: $0.index, item: $0.item, width: $0.width, height: $0.height)
                }
                rows.append(.imageGrid(entries: rowEntries))
                visualRows.append(placedRow.map(\.index))
            }
            imageBuffer.removeAll(keepingCapacity: true)
        }

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
                flushImageWallBuffer()
                rows.append(.standard(index: index, item: item))
                visualRows.append([index])
            }
        }
        flushImageWallBuffer()

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
        if animateReorder {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                self.cachedFilteredItems = filtered
                self.cachedDisplayRows = rows
                self.cachedVisualRows = visualRows
            }
        } else {
            self.cachedFilteredItems = filtered
            self.cachedDisplayRows = rows
            self.cachedVisualRows = visualRows
        }
        self.listRevision &+= 1
    }

    func resetOnOpen() {
        searchText = ""
        isSearchInputFocused = false
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
        blurSearchTrigger = UUID()
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
    func resignSearchFocusIfMovedOut() -> Bool {
        guard isSearchInputFocused else { return false }
        guard pointerGuard.allowHoverSelection(
            currentMouseLocation: NSEvent.mouseLocation,
            uptime: ProcessInfo.processInfo.systemUptime
        ) else {
            return false
        }
        isSearchInputFocused = false
        blurSearchTrigger = UUID()
        onResignSearchFocus?()
        return true
    }

    @discardableResult
    func selectByHover(_ index: Int) -> Bool {
        guard pointerGuard.allowHoverSelection(
            currentMouseLocation: NSEvent.mouseLocation,
            uptime: ProcessInfo.processInfo.systemUptime
        ) else {
            return false
        }
        if isSearchInputFocused {
            isSearchInputFocused = false
            blurSearchTrigger = UUID()
            onResignSearchFocus?()
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
    @ObservedObject private var oneMind = OneMindKernel.shared
    var onResignSearchFocus: (() -> Void)? = nil
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
    @State private var templateDraftText: String = "请帮我审查以下代码并指出潜在问题：\n\n{{clip_redacted}}"
    @State private var templateKeywordDraft: String = ""
    @State private var templateAliasDraft: String = ""
    @State private var aliasEditingItem: ClipItem? = nil
    @State private var aliasDraftText: String = ""
    @State private var keywordDraftText: String = ""
    @State private var showShortcutReference: Bool = false
    @State private var showAdvancedPrivacyControls: Bool = false
    @StateObject private var reorderCoordinator = ClipReorderCoordinator()
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
                    .background(WindowNativeDragHandleView())

                if nav.showSettings {
                    settingsView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                } else {
                    filterBar
                        .padding(.horizontal, 14)
                        .padding(.bottom, nav.searchText.trimmingCharacters(in: .whitespaces).hasPrefix("@") ? 6 : 10)
                        .background(WindowNativeDragHandleView())
                        .onHover { hovering in
                            if hovering {
                                _ = nav.resignSearchFocusIfMovedOut()
                            }
                        }

                    searchCommandOverlayBanner

                    oneMindRecallBanner

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

                    if !store.minimalModeEnabled && (nav.selectedTab == .pinned || nav.isCreatingTemplate) {
                        if nav.selectedTab == .pinned {
                            pinCategoryBar
                                .padding(.horizontal, 14)
                                .padding(.bottom, 6)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

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

                    if let blockedChatApp = store.blockedChatImageAppName {
                        chatImagePermissionBanner(
                            appName: blockedChatApp,
                            needsRedrop: store.blockedChatImageNeedsRedrop
                        )
                            .padding(.horizontal, 14)
                            .padding(.bottom, 7)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else if store.isPermissionGateActive {
                        deferredPermissionStatusBanner
                            .padding(.horizontal, 14)
                            .padding(.bottom, 7)
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
                            ZStack {
                                WindowNativeDragHandleView()
                                Capsule()
                                    .fill(glassPalette.footerBackdrop)
                                    .allowsHitTesting(false)
                            }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // iOS 灵动胶囊轻提示
            if let message = store.toastMessage {
                toastPill(message)
                    .padding(.bottom, 46)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            PanelCornerResizeGripIndicator()
                .padding(.trailing, 8)
                .padding(.bottom, 8)
                .allowsHitTesting(false)
        }
        .overlay {
            if store.surfaceStyle != .liquidGlass && !store.borderlessPanel {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        // 外部内容拖放复制高亮反馈浮层
        .overlay {
            if nav.isDragTargeted {
                dragDropOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
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
                        let currentTabs = QuickLookTabBuilder.buildTabs(for: target, store: store)
                        let activeTabID = currentTabs.indices.contains(nav.quickLookTabIndex) ? currentTabs[nav.quickLookTabIndex].id : nil
                        let latestSensitiveDiff: Bool = {
                            guard activeTabID == QuickLookTabItem.diffLatestTabID,
                                  let latest = store.items.first(where: {
                                      ($0.type == .text || $0.type == .link)
                                          && !$0.isBurnAfterPaste
                                          && !SecretCapsuleMessenger.containsCapsule($0.text)
                                  }) else {
                                return false
                            }
                            return latest.detectedSensitiveKind != nil
                        }()
                        nav.isQuickLookEditing = false
                        nav.showQuickLook = false
                        store.pasteCustomString(
                            content,
                            sourceItem: target,
                            toast: toast,
                            shouldAutoPaste: true,
                            extraForceProtected: latestSensitiveDiff,
                            onBeforePaste: onDismiss
                        )
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
        .animation(.easeOut(duration: 0.16), value: nav.showSettings)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: store.toastMessage)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: store.isPermissionGateActive)
        .onAppear {
            nav.onResignSearchFocus = onResignSearchFocus
        }
        .onChange(of: nav.isPresented) { _, presented in
            if presented {
                nav.onResignSearchFocus = onResignSearchFocus
                playground.cleanupLegacySamplesIfAny(in: store)
                store.onPanelShown(visibleItems: filteredItems)
            } else {
                aliasEditingItem = nil
                reorderCoordinator.cancelAll()
                store.onPanelHidden()
            }
        }
        .onChange(of: isSearchFocused) { _, focused in
            nav.isSearchInputFocused = focused
            if focused {
                nav.selectedIndex = -1
                nav.lockPointerAtCurrentMouse()
            } else {
                onResignSearchFocus?()
            }
        }
        .onChange(of: nav.focusTrigger) { _, _ in
            nav.isSearchInputFocused = true
            nav.selectedIndex = -1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
        .onChange(of: nav.blurSearchTrigger) { _, _ in
            nav.isSearchInputFocused = false
            isSearchFocused = false
        }
        .onChange(of: nav.searchText) { _, newValue in
            reorderCoordinator.cancelAll()
            if isSearchFocused || nav.isSearchInputFocused {
                nav.selectedIndex = -1
            } else if newValue.isEmpty {
                nav.selectedIndex = 0
            }
            nav.lockPointerAtCurrentMouse()
        }
        .onChange(of: nav.selectedTab) { _, _ in
            reorderCoordinator.cancelAll()
            TactileFeedbackEngine.shared.perform(.tabSwitch)
            nav.selectedIndex = (isSearchFocused || nav.isSearchInputFocused) ? -1 : 0
            nav.lockPointerAtCurrentMouse()
        }
        .onChange(of: nav.demoPreviewIndex) { _, targetIdx in
            if let idx = targetIdx, idx >= 0, idx < filteredItems.count {
                let item = filteredItems[idx]
                nav.selectedIndex = idx
                triggerSmartQuickLook(for: item)
            } else {
                BigBangStageController.shared.dismiss()
                SystemQuickLookController.shared.dismiss()
            }
        }
        .onChange(of: nav.showSettings) { _, showing in
            if showing {
                store.refreshAccessibilityStatus()
                store.refreshFullDiskAccessStatus()
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
        } else if let capsuleState = currentSecretCapsuleState {
            SecretCapsuleCardView(
                state: capsuleState,
                onCommitPrimary: {
                    _ = commitSecretCapsuleAction(forcePin: false)
                },
                onCommitPinDecrypted: {
                    if case .unlockDecrypted = capsuleState {
                        return { _ = commitSecretCapsuleAction(forcePin: true) }
                    }
                    return nil
                }()
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if SecurityPostureAudit.isAuditQuery(nav.searchText) {
            SecurityAuditCardView(
                report: store.securityPostureReport,
                onSweepRisks: {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                        _ = store.sweepAllUnpinnedSensitiveItems()
                        clampSelection()
                    }
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

    @ViewBuilder
    private var oneMindRecallBanner: some View {
        if !store.minimalModeEnabled,
           nav.selectedTab == .all,
           nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let recall = oneMind.preferredRecallItem(from: filteredItems, activeTargetApp: store.activeTargetAppName) {
            let meta = store.cardRenderMeta(for: recall.item)
            HStack(spacing: 7) {
                HStack(spacing: 3.5) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .bold))
                    Text(recall.badge)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.accentColor)
                .fixedSize(horizontal: true, vertical: false)

                Text(meta.plainDisplayTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    store.copyAndOptionallyPaste(
                        recall.item,
                        plainTextOnly: false,
                        shouldAutoPaste: true,
                        onBeforePaste: onDismiss
                    )
                } label: {
                    Text("直出")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - 顶部胶囊搜索栏

    private var headerBar: some View {
        TahoeGlassContainer(spacing: 8) {
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
                    Text("iClip 偏好设置")
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
                            ? "搜索待办或输入事项..."
                            : "搜索历史或输入待办...",
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
                .onHover { hovering in
                    if !hovering {
                        _ = nav.resignSearchFocusIfMovedOut()
                    }
                }

                // 常驻「始终在前」图钉按钮：随时一键固定或取消置顶，零隐藏寻路成本
                AlwaysOnTopPinButton(store: store, glassPalette: glassPalette)

                if store.isPaused {
                    Button {
                        store.toggleTimedPause(defaultMinutes: 15)
                    } label: {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.orange)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(glassPalette.controlCapsuleFill))
                            .overlay(Circle().strokeBorder(glassPalette.controlCapsuleStroke.opacity(0.85), lineWidth: 0.65))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("恢复记录剪贴板")
                    .help(store.pauseStatusSummary)
                    .contextMenu {
                        Button("立即恢复记录剪贴板") { store.resumeCapture() }
                        Divider()
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
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
                }

                // 常驻右侧圆钮：直开独立苹果风偏好设置窗口（右键可直达权限中心/入门引导/置顶/暂停）
                Button {
                    AppWindowCoordinator.shared.presentSettings(section: .appearance, store: store)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(glassPalette.controlCapsuleFill))
                            .overlay(Circle().strokeBorder(glassPalette.controlCapsuleStroke.opacity(0.85), lineWidth: 0.65))

                        if updater.hasUpdateAvailable || store.isPermissionGateActive {
                            Circle()
                                .fill(store.isPermissionGateActive ? Color.orange : Color.accentColor)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
                                .offset(x: -1, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("偏好设置")
                .help("打开独立偏好设置（⌘,）· 右键可直达权限中心与入门引导")
                .contextMenu {
                    Button("打开独立偏好设置（⌘,）") {
                        AppWindowCoordinator.shared.presentSettings(section: .appearance, store: store)
                    }
                    Button("打开独立权限授权中心…") {
                        AppWindowCoordinator.shared.presentPermissionSetup(store: store)
                    }
                    Button("打开新手入门引导与沙盒…") {
                        AppWindowCoordinator.shared.presentOnboarding(store: store)
                    }
                    Divider()
                    Button(store.alwaysOnTop ? "✓ 取消窗口置顶（⌘P）" : "固定窗口始终在前（⌘P）") {
                        store.alwaysOnTop.toggle()
                    }
                    Button(store.isPaused ? "立即恢复记录剪贴板" : "无痕暂停 15 分钟（自动恢复）") {
                        store.toggleTimedPause(defaultMinutes: 15)
                    }
                }
            }
        }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: store.alwaysOnTop)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: store.isPaused)
    }

    // MARK: - iOS 滑动胶囊分类条（独立隔离渲染 + 常驻 GPU 硬件偏移滑块，120Hz 满帧零列表重绘干扰）

    private var filterBar: some View {
        FilterTabBarView(
            tabs: ClipFilterTab.visibleTabs(minimalMode: store.minimalModeEnabled),
            selectedTab: nav.selectedTab,
            minimalMode: store.minimalModeEnabled,
            pendingTodos: store.pendingTodoCount,
            glassPalette: glassPalette,
            colorScheme: colorScheme,
            onSelectTab: { tab in
                guard nav.selectedTab != tab else { return }
                nav.selectedTab = tab
            }
        )
    }

    private var currentSecretCapsuleState: SecretCapsuleMessenger.CommandState? {
        guard SecretCapsuleMessenger.isCapsuleCommandPrefix(nav.searchText) else { return nil }
        let selectedItem = (nav.selectedIndex >= 0 && nav.selectedIndex < filteredItems.count) ? filteredItems[nav.selectedIndex] : nil
        return SecretCapsuleMessenger.evaluateCommand(
            query: nav.searchText,
            latestPlainCandidate: store.latestPlainTextForCapsuleLock,
            latestCapsuleCandidate: store.latestCapsuleText(prioritizing: selectedItem)
        )
    }

    private func commitSecretCapsuleAction(forcePin: Bool) -> Bool {
        guard let state = currentSecretCapsuleState else { return false }
        switch state {
        case .lockReady(let passphrase, let plainSource, _):
            nav.searchText = ""
            store.pasteLockedCapsuleEnvelope(plainText: plainSource, passphrase: passphrase, shouldAutoPaste: true, onBeforePaste: onDismiss)
            return true
        case .unlockDecrypted(let decryptedPlain):
            nav.searchText = ""
            if forcePin {
                store.captureQuickNote(body: decryptedPlain, alias: "已解锁机密信封", pin: true)
                onDismiss()
            } else {
                store.pasteEphemeralSecret(
                    decryptedPlain,
                    toast: "已无痕键入解锁明文（不写入历史 · 30s 后自动擦除）",
                    scrubDelaySeconds: 30.0,
                    shouldAutoPaste: true,
                    onBeforePaste: onDismiss
                )
            }
            return true
        case .lockAwaitingInput(let hint):
            store.showToast(hint)
            return true
        case .unlockPending(let hasTarget, _):
            store.showToast(hasTarget ? "请输入正确的解锁口令" : "未在剪贴历史中找到 ICLPMSG1 密文信封")
            return true
        }
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

    private var pinCategoryBar: some View {
        PinCategoryBarView(
            selectedCategory: nav.selectedPinCategory,
            onSelectCategory: { category in
                withAnimation(.easeOut(duration: 0.16)) {
                    nav.selectedPinCategory = category
                }
            }
        )
    }

    private var pinnedTemplateToolbar: some View {
        let presets: [(label: String, keyword: String, alias: String, body: String)] = [
            ("收货地址", "地址 addr", "我的收货地址", "收件人：\n手机：\n地址："),
            ("开票信息", "开票 fapiao", "公司开票资料", "公司抬头：\n纳税人识别号：\n开户行及账号："),
            ("代码审查", "审查 review", "AI 代码审查模板", "请帮我审查以下代码并指出潜在隐患：\n\n{{clip_redacted}}")
        ]
        let variableChips: [(label: String, token: String)] = [
            ("+ 当前剪贴板", "{{clip}}"),
            ("+ 脱敏剪贴板", "{{clip_redacted}}"),
            ("+ 当前时间", "{{datetime}}"),
            ("+ 随机编号", "{{uuid}}")
        ]

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.badge.checkmark.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.purple)
                    Text("快捷短语与模板")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("· 已设 \(store.phraseWithKeywordCount) 个口令")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        nav.isCreatingTemplate.toggle()
                    }
                    TactileFeedbackEngine.shared.performNavigationStepHaptic()
                } label: {
                    Text(nav.isCreatingTemplate ? "收起" : "+ 新建短语 / 模板")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(nav.isCreatingTemplate ? Color.secondary : Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(PhysicalSpringButtonStyle())
            }

            if nav.isCreatingTemplate {
                VStack(alignment: .leading, spacing: 8) {
                    // 1. 开箱即用预设灵感
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            Text("预设:")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            ForEach(presets, id: \.label) { preset in
                                Button {
                                    templateKeywordDraft = preset.keyword
                                    templateAliasDraft = preset.alias
                                    templateDraftText = preset.body
                                    TactileFeedbackEngine.shared.performNavigationStepHaptic()
                                } label: {
                                    Text(preset.label)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 7.5)
                                        .padding(.vertical, 2.5)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.11)))
                                }
                                .buttonStyle(PhysicalSpringButtonStyle())
                            }
                        }
                    }

                    // 2. 口令关键词 + 名称（搜索框敲口令即置顶第一位，回车直接键入）
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "command")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.purple)
                            TextField("口令词（如：地址 / addr）", text: $templateKeywordDraft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.055))
                        )

                        TextField("短语名称（可选）", text: $templateAliasDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.055))
                            )
                    }

                    // 3. 正文编辑区
                    TextEditor(text: $templateDraftText)
                        .font(.system(size: 12))
                        .frame(height: 68)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.055))
                        )

                    // 4. 中文可视化变量胶囊 + 保存
                    HStack(spacing: 5) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4.5) {
                                ForEach(variableChips, id: \.token) { chip in
                                    Button {
                                        templateDraftText += chip.token
                                        TactileFeedbackEngine.shared.perform(.hoverTick)
                                    } label: {
                                        Text(chip.label)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                                    }
                                    .buttonStyle(PhysicalSpringButtonStyle())
                                }
                            }
                        }

                        Button {
                            let kw = templateKeywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            let alias = templateAliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            store.addPinnedTemplate(
                                templateDraftText,
                                alias: alias.isEmpty ? nil : alias,
                                triggerKeyword: kw.isEmpty ? nil : kw
                            )
                            templateKeywordDraft = ""
                            templateAliasDraft = ""
                            withAnimation(.easeOut(duration: 0.16)) {
                                nav.isCreatingTemplate = false
                            }
                        } label: {
                            Text("保存并置顶")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        .buttonStyle(PhysicalSpringButtonStyle())
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.purple)

                TextField("口令词（空格分隔多个，如：地址 addr）", text: $keywordDraftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($isAliasFieldFocused)
                    .onSubmit {
                        commitPhraseAndAliasEdit(for: target)
                    }

                Button("保存") {
                    commitPhraseAndAliasEdit(for: target)
                }
                .buttonStyle(PhysicalSpringButtonStyle())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
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

            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                TextField("记忆备注标题（可选，留空仅保留原正文）", text: $aliasDraftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .onSubmit {
                        commitPhraseAndAliasEdit(for: target)
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.065))
        )
    }

    private func commitPhraseAndAliasEdit(for target: ClipItem) {
        let trimmedKw = keywordDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlias = aliasDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKw.isEmpty || target.triggerKeyword != nil {
            store.setTriggerKeyword(trimmedKw.isEmpty ? nil : trimmedKw, alias: trimmedAlias.isEmpty ? nil : trimmedAlias, for: target)
        } else {
            store.setCustomAlias(trimmedAlias.isEmpty ? nil : trimmedAlias, for: target)
        }
        aliasEditingItem = nil
        nav.isEditingAlias = false
    }

    // MARK: - 剪贴记录列表（等高自适应流式图片墙 + 弹性文本卡片）

    private var contentList: some View {
        Group {
            if filteredItems.isEmpty {
                emptyStateView
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            Color.clear
                                .frame(height: 0)
                                .id("clipboard-list-top-anchor")

                            ForEach(Array(displayRows.enumerated()), id: \.element.id) { rowIndex, row in
                                switch row {
                                case .standard(let index, let item):
                                    let canDragReorder = nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        && !item.isTodoCompleted
                                    let isDraggedCard = (reorderCoordinator.draggedItemID == item.id)
                                    SelectableClipCardRow(
                                        selection: nav.selection,
                                        listRevision: nav.listRevision,
                                        item: item,
                                        index: index,
                                        surfaceStyle: store.surfaceStyle,
                                        liquidGlassAppearance: store.liquidGlassAppearance,
                                        borderlessPanel: store.borderlessPanel,
                                        cardSkin: store.cardSkin,
                                        isTriggerKeywordTopMatch: (index == 0 && nav.cachedTopTriggerMatchedID == item.id),
                                        onSelect: {
                                            nav.selectExplicitly(index)
                                        },
                                        onHoverSelect: {
                                            guard !reorderCoordinator.isReordering else { return false }
                                            return nav.selectByHover(index)
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
                                        onSelectPinCategory: { cat in
                                            withAnimation(.easeOut(duration: 0.16)) {
                                                store.setPinCategory(cat, for: item)
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
                                            nav.onResetSpacePreviewGesture?()
                                            nav.selectedIndex = index
                                            triggerSmartQuickLook(for: item)
                                        },
                                        onOpenBigBang: {
                                            nav.onResetSpacePreviewGesture?()
                                            nav.selectedIndex = index
                                            triggerSmartQuickLook(for: item, initialMode: .textBigBang)
                                        },
                                        onConsumeReorderTapSuppression: {
                                            reorderCoordinator.consumeTapSuppressionIfNeeded(for: item.id)
                                        },
                                        onCancelPendingReorder: {
                                            reorderCoordinator.cancelAll()
                                        },
                                        onDelete: {
                                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                                store.delete(item)
                                                clampSelection()
                                            }
                                        }
                                    )
                                    .background(
                                        GeometryReader { geo in
                                            let frame = geo.frame(in: .named("clipListScrollSpace"))
                                            Color.clear
                                                .onAppear {
                                                    reorderCoordinator.updateRowGeometry(
                                                        itemID: item.id,
                                                        minY: frame.minY,
                                                        height: frame.height,
                                                        isLockedBottom: item.isTodoCompleted
                                                    )
                                                }
                                                .onChange(of: frame.minY) { _, newMinY in
                                                    reorderCoordinator.updateRowGeometry(
                                                        itemID: item.id,
                                                        minY: newMinY,
                                                        height: frame.height,
                                                        isLockedBottom: item.isTodoCompleted
                                                    )
                                                }
                                                .onChange(of: frame.height) { _, newH in
                                                    reorderCoordinator.updateRowGeometry(
                                                        itemID: item.id,
                                                        minY: frame.minY,
                                                        height: newH,
                                                        isLockedBottom: item.isTodoCompleted
                                                    )
                                                }
                                        }
                                    )
                                    .overlay {
                                        if canDragReorder {
                                            ReorderLongPressMouseProbe {
                                                let standardIDs = displayRows.compactMap { row -> UUID? in
                                                    if case .standard(_, let rowItem) = row { return rowItem.id }
                                                    return nil
                                                }
                                                reorderCoordinator.syncVisibleOrder(standardIDs)
                                                reorderCoordinator.beginPotentialLongPress(
                                                    itemID: item.id,
                                                    isLockedBottom: item.isTodoCompleted,
                                                    isAllowed: canDragReorder,
                                                    onSwap: { draggedID, targetID in
                                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                            _ = store.reorderItem(draggedID: draggedID, swappingWith: targetID)
                                                        }
                                                    },
                                                    onCommit: {
                                                        store.commitManualReorderPersistence()
                                                    }
                                                )
                                            }
                                        }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if isDraggedCard && reorderCoordinator.isLifted {
                                            HStack(spacing: 4) {
                                                Image(systemName: "line.3.horizontal")
                                                    .font(.system(size: 9.5, weight: .bold))
                                                Text("拖动排序")
                                                    .font(.system(size: 10, weight: .semibold))
                                            }
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(Color(red: 0.12, green: 0.37, blue: 1.0)))
                                            .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
                                            .padding(.top, 6)
                                            .padding(.trailing, 8)
                                            .allowsHitTesting(false)
                                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                                        }
                                    }
                                    .overlay {
                                        if isDraggedCard && reorderCoordinator.isLifted {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .strokeBorder(Color(red: 0.12, green: 0.37, blue: 1.0).opacity(0.72), lineWidth: 1.4)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .scaleEffect(isDraggedCard && reorderCoordinator.isLifted ? 1.028 : 1.0)
                                    .offset(y: isDraggedCard ? reorderCoordinator.dragOffsetY : 0)
                                    .shadow(
                                        color: isDraggedCard && reorderCoordinator.isLifted ? Color.black.opacity(0.24) : .clear,
                                        radius: isDraggedCard && reorderCoordinator.isLifted ? 16 : 0,
                                        y: isDraggedCard && reorderCoordinator.isLifted ? 8 : 0
                                    )
                                    .zIndex(isDraggedCard ? 120 : 0)
                                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isDraggedCard && reorderCoordinator.isLifted)
                                    .cascadeAppear(
                                        isPresented: nav.isPresented,
                                        delay: Double(min(rowIndex, 8)) * 0.028
                                    )
                                    .id(item.id)

                                case .imageGrid(let entries):
                                    SelectableImageGridRow(
                                        selection: nav.selection,
                                        listRevision: nav.listRevision,
                                        entries: entries,
                                        rowIndex: rowIndex,
                                        isPresented: nav.isPresented,
                                        cardSkin: store.cardSkin,
                                        onSelect: { idx in
                                            nav.selectExplicitly(idx)
                                        },
                                        onHoverSelect: { idx in
                                            nav.selectByHover(idx)
                                        },
                                        onPaste: { target in
                                            store.copyAndOptionallyPaste(
                                                target,
                                                plainTextOnly: false,
                                                shouldAutoPaste: true,
                                                onBeforePaste: onDismiss
                                            )
                                        },
                                        onCopyOnly: { target in
                                            store.copyAndOptionallyPaste(
                                                target,
                                                plainTextOnly: false,
                                                shouldAutoPaste: false,
                                                onBeforePaste: nil
                                            )
                                        },
                                        onExtractOCR: { target, autoPaste in
                                            store.pasteExtractedOCRText(
                                                for: target,
                                                shouldAutoPaste: autoPaste,
                                                onBeforePaste: autoPaste ? onDismiss : nil
                                            )
                                        },
                                        onTogglePin: { target in
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                store.togglePin(target)
                                            }
                                        },
                                        onToggleTodo: { target in
                                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                                store.toggleTodo(target)
                                            }
                                        },
                                        onRemoveTodo: { target in
                                            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                                                store.removeFromTodo(target)
                                                clampSelection()
                                            }
                                        },
                                        onEditAlias: { target in
                                            beginAliasEdit(for: target)
                                        },
                                        onOpenQuickLook: { idx, target in
                                            nav.onResetSpacePreviewGesture?()
                                            nav.selectedIndex = idx
                                            triggerSmartQuickLook(for: target)
                                        },
                                        onOpenOCRBigBang: { idx, target in
                                            nav.onResetSpacePreviewGesture?()
                                            nav.selectedIndex = idx
                                            triggerSmartQuickLook(for: target, initialMode: .imageBigBangOCR)
                                        },
                                        onDelete: { target in
                                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                                store.delete(target)
                                                clampSelection()
                                            }
                                        }
                                    )

                                case .todoCompletedHeader(let count):
                                    todoCompletedSectionHeader(count: count)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .tahoeSoftScrollEdges()
                    .coordinateSpace(name: "clipListScrollSpace")
                    .onChange(of: nav.scrollRequestEpoch) { _, _ in
                        let idx = nav.selectedIndex
                        guard idx >= 0, idx < filteredItems.count else { return }
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo(filteredItems[idx].id, anchor: .center)
                        }
                    }
                    .onChange(of: store.promoteAnimationEpoch) { _, _ in
                        guard store.alwaysOnTop, nav.isPresented else { return }
                        nav.lockPointerAtCurrentMouse()
                        if let promotedID = store.lastPromotedItemID,
                           let promotedIdx = filteredItems.firstIndex(where: { $0.id == promotedID }) {
                            nav.selectedIndex = promotedIdx
                        } else if !filteredItems.isEmpty {
                            nav.selectedIndex = 0
                        }
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                            proxy.scrollTo("clipboard-list-top-anchor", anchor: .top)
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
        let selectedItem: ClipItem? = (nav.selectedIndex >= 0 && nav.selectedIndex < filteredItems.count)
            ? filteredItems[nav.selectedIndex]
            : nil
        let primaryAction: TransformAction? = (!store.minimalModeEnabled
            ? selectedItem.flatMap { store.semanticSnapshot(for: $0).actions.first }
            : nil)

        return HStack(spacing: 8) {
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

            // 固定 22pt 行高的按需回显区：依据当前焦点与 OneMind 记忆只呈现最需要的一项行动，零抖动
            Group {
                if let action = primaryAction, let item = selectedItem {
                    let habitTop = oneMind.isHabitPreferred(actionID: action.id, sourceApp: item.sourceAppName)
                    Button {
                        pasteSmartTransformedSelected()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: habitTop ? "sparkle" : action.symbolName)
                                .font(.system(size: 10, weight: .semibold))
                            Text(action.title)
                                .font(.system(size: 10.8, weight: .semibold))
                                .lineLimit(1)
                            Text("⇧↵")
                                .font(.system(size: 9.5, weight: .semibold))
                                .opacity(0.75)
                        }
                        .foregroundStyle(action.isSecurityAction ? Color.orange : Color.accentColor)
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill((action.isSecurityAction ? Color.orange : Color.accentColor).opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("按 ⇧↵ 直接执行「\(action.title)」并键入")
                } else if !store.minimalModeEnabled, let item = selectedItem, item.isPendingTodo {
                    Button {
                        toggleTodoForSelected()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 10, weight: .semibold))
                            Text("完成待办 ⌘T")
                                .font(.system(size: 10.8, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                } else if !store.minimalModeEnabled && oneMind.totalLearnedInteractions > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("OneMind · 已记 \(oneMind.totalLearnedInteractions) 次习惯")
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    keyHint("↵", "键入")
                }
            }

            if store.items.contains(where: { !$0.isPinned }) {
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
        .frame(height: 22)
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
                                Text(store.cardClickPasteMode == .singleClick ? "授权后单击或按回车即可直接粘贴至当前光标位置" : "授权后双击或按回车即可直接粘贴至当前光标位置")
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

                // 1. 外观与悬浮精灵
                settingsGroup(title: "外观与悬浮精灵") {
                    LiquidGlassBlurStyleCard(blurConcentration: $store.liquidGlassMaskOpacity)
                    Divider().opacity(0.35)
                    CardSkinStylePickerCard(cardSkin: $store.cardSkin)
                    Divider().opacity(0.35)
                    SpriteOrbSettingsCard(
                        enabled: $store.spriteOrbEnabled,
                        style: $store.spriteOrbStyle,
                        dockMode: $store.spriteOrbDockMode
                    )
                }

                // 2. 智能模式与扩展能力（含物理微动效四磁贴、财务独立开关与口令短语直达）
                settingsGroup(title: "智能模式与扩展能力") {
                    AdaptiveIntelligenceSettingsSection(
                        store: store,
                        onOpenPhraseCreator: {
                            nav.showSettings = false
                            nav.selectedTab = .pinned
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                nav.isCreatingTemplate = true
                            }
                        }
                    )
                }

                // 3. 隐私护盾与历史（一主开关 + 默认收起细项 + 历史管理）
                settingsGroup(title: "隐私护盾与历史") {
                    let shieldMasterOn = store.screenSharePrivacyEnabled
                        && store.maskSensitivePreviews
                        && store.autoRedactOnPaste

                    HStack(spacing: 7) {
                        Image(systemName: shieldMasterOn ? "lock.shield.fill" : "shield")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(shieldMasterOn ? Color.green : .secondary)
                        Text("本机钥匙串 AES-256-GCM 透明加密 · 零联网上传")
                            .font(.system(size: 11.2, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(shieldMasterOn ? "护盾守护中" : "基础保护")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(shieldMasterOn ? Color.green : .secondary)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((shieldMasterOn ? Color.green : Color.primary).opacity(0.10)))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((shieldMasterOn ? Color.green : Color.primary).opacity(0.08))
                    )
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: shieldMasterOn)

                    HStack {
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("隐私安全护盾")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("一键开启投屏隐身、防肩窥圆点遮罩与粘贴自动脱敏")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LiquidPhysicsTogglePill(
                            isOn: Binding(
                                get: { shieldMasterOn },
                                set: { newVal in
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                        store.screenSharePrivacyEnabled = newVal
                                        store.maskSensitivePreviews = newVal
                                        store.autoRedactOnPaste = newVal
                                    }
                                }
                            ),
                            tint: .green
                        )
                    }

                    Divider().opacity(0.35)

                    Button {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                            showAdvancedPrivacyControls.toggle()
                        }
                        TactileFeedbackEngine.shared.performNavigationStepHaptic()
                    } label: {
                        HStack {
                            Text("细项护盾、微落点与忽略应用")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.88))
                            Spacer()
                            Image(systemName: showAdvancedPrivacyControls ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PhysicalSpringButtonStyle())

                    if showAdvancedPrivacyControls {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text("投屏与录屏光学隐身")
                                    .font(.system(size: 12.5))
                                Spacer()
                                LiquidPhysicsTogglePill(isOn: $store.screenSharePrivacyEnabled, tint: .green, isCompact: true)
                            }
                            HStack {
                                Text("敏感凭据防肩窥圆点遮罩")
                                    .font(.system(size: 12.5))
                                Spacer()
                                LiquidPhysicsTogglePill(isOn: $store.maskSensitivePreviews, tint: .green, isCompact: true)
                            }
                            HStack {
                                Text("粘贴敏感凭据自动脱敏（⌥↵ 贴明文）")
                                    .font(.system(size: 12.5))
                                Spacer()
                                LiquidPhysicsTogglePill(isOn: $store.autoRedactOnPaste, tint: .green, isCompact: true)
                            }
                            HStack {
                                Text("密码剪贴板 60 秒残留擦除")
                                    .font(.system(size: 12.5))
                                Spacer()
                                LiquidPhysicsTogglePill(isOn: $store.autoClearConcealedPasteboard, tint: .green, isCompact: true)
                            }
                            HStack {
                                Text("未收藏敏感凭据 24h 自动销毁")
                                    .font(.system(size: 12.5))
                                Spacer()
                                LiquidPhysicsTogglePill(isOn: $store.autoExpireUnpinnedSecrets, tint: .green, isCompact: true)
                            }
                            HStack {
                                Text("复制链接自动剥离追踪尾巴")
                                    .font(.system(size: 12.5))
                                Spacer()
                                LiquidPhysicsTogglePill(isOn: $store.autoCleanTrackingURL, isCompact: true)
                            }
                            HStack {
                                Text("拖拽途中按 ⌥ 呼出「微落点」")
                                    .font(.system(size: 12.5))
                                Spacer()
                                LiquidPhysicsTogglePill(
                                    isOn: Binding(
                                        get: { oneMind.cursorDropPodEnabled },
                                        set: { oneMind.cursorDropPodEnabled = $0 }
                                    ),
                                    isCompact: true
                                )
                            }

                            Divider().opacity(0.3)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("隐私忽略应用（不记录其复制内容）")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)

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
                                                    .font(.system(size: 12, weight: .medium))
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
                                                .buttonStyle(PhysicalSpringButtonStyle())
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
                        }
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }

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

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("收藏归档")
                                .font(.system(size: 13, weight: .medium))
                            Text("已收藏 \(store.pinnedItemCount) 条 · 支持 .iclip / Raycast / Maccy")
                                .font(.system(size: 11))
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

                // 4. 通用与关于
                settingsGroup(title: "通用与关于") {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("默认键入方式")
                                .font(.system(size: 13.5, weight: .medium))
                            Spacer()
                        }
                        Picker("", selection: $store.cardClickPasteMode) {
                            Text("单击直接粘贴").tag(CardClickPasteMode.singleClick)
                            Text("双击直接粘贴").tag(CardClickPasteMode.doubleClick)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: store.cardClickPasteMode) { _, _ in
                            TactileFeedbackEngine.shared.performNavigationStepHaptic()
                        }
                        Text(store.cardClickPasteMode.companionGestureSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().opacity(0.35)

                    HStack(spacing: 8) {
                        let isDefaultSize = abs(store.panelWidth - 420) < 1 && abs(store.panelHeight - 560) < 1
                        VStack(alignment: .leading, spacing: 2) {
                            Text("面板窗口尺寸")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("当前 \(Int(store.panelWidth)) × \(Int(store.panelHeight)) px · 拖动边缘四向自由拉伸，双击边缘还原")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复默认") {
                            TactileFeedbackEngine.shared.performNavigationStepHaptic()
                            store.resetPanelDimensions()
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(isDefaultSize ? Color.secondary : Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .background(Capsule().fill(isDefaultSize ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.12)))
                        .buttonStyle(PhysicalSpringButtonStyle())
                        .disabled(isDefaultSize)
                    }

                    Divider().opacity(0.35)

                    let isRecordingMain = nav.isRecordingHotKey && (nav.recordingHotKeySlot == nil || nav.recordingHotKeySlot == .mainToggle)
                    let isRecordingShot = nav.isRecordingHotKey && nav.recordingHotKeySlot == .screenshot

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("全局呼出快捷键")
                                .font(.system(size: 13.5, weight: .medium))
                            if isRecordingMain, let conflict = nav.hotKeyConflictWarning {
                                Text(conflict)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.red)
                            } else if isRecordingMain, let hint = nav.hotKeyRecordingHint {
                                Text(hint)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Text(isRecordingMain ? "按下组合键，或双击 ⌘/⌥/⌃/⇧ 单键（ESC 取消）" : "点击录制组合键或双击 ⌘/⌥/⌃/⇧ 单键")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(isRecordingMain ? Color.accentColor : .secondary)
                            }
                        }
                        Spacer()

                        Button {
                            if isRecordingMain {
                                nav.isRecordingHotKey = false
                                nav.hotKeyConflictWarning = nil
                                HotKeyManager.shared.resumeAfterRecording()
                            } else {
                                nav.hotKeyConflictWarning = nil
                                nav.hotKeyRecordingHint = nil
                                HotKeyManager.shared.suspendForRecording()
                                nav.recordingHotKeySlot = .mainToggle
                                nav.isRecordingHotKey = true
                            }
                        } label: {
                            let hasConflict = isRecordingMain && nav.hotKeyConflictWarning != nil
                            Text(hasConflict ? "冲突 · 请重按" : (isRecordingMain ? "等待按键..." : store.hotKeyShortcut.displayString))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isRecordingMain ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(hasConflict ? Color.red : (isRecordingMain ? Color.accentColor : Color.primary.opacity(0.08)))
                                )
                        }
                        .buttonStyle(PhysicalSpringButtonStyle())

                        if store.hotKeyShortcut != .defaultShortcut && !isRecordingMain {
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
                            .buttonStyle(PhysicalSpringButtonStyle())
                            .help("恢复默认 ⌥ V")
                        }
                    }

                    Divider().opacity(0.35)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("截图快捷键")
                                .font(.system(size: 13.5, weight: .medium))
                            if isRecordingShot, let conflict = nav.hotKeyConflictWarning {
                                Text(conflict)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.red)
                            } else if isRecordingShot, let hint = nav.hotKeyRecordingHint {
                                Text(hint)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Text(isRecordingShot ? "按下组合键，或双击修饰键（ESC 取消）" : "自动吸附窗口与自由框选（默认 ⌥ A）")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(isRecordingShot ? Color.accentColor : .secondary)
                            }
                        }
                        Spacer()

                        Button {
                            if isRecordingShot {
                                nav.isRecordingHotKey = false
                                nav.hotKeyConflictWarning = nil
                                HotKeyManager.shared.resumeAfterRecording()
                            } else {
                                nav.hotKeyConflictWarning = nil
                                nav.hotKeyRecordingHint = nil
                                HotKeyManager.shared.suspendForRecording()
                                nav.recordingHotKeySlot = .screenshot
                                nav.isRecordingHotKey = true
                            }
                        } label: {
                            let hasConflict = isRecordingShot && nav.hotKeyConflictWarning != nil
                            Text(hasConflict ? "冲突 · 请重按" : (isRecordingShot ? "等待按键..." : store.screenshotHotKeyShortcut.displayString))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isRecordingShot ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(hasConflict ? Color.red : (isRecordingShot ? Color.accentColor : Color.primary.opacity(0.08)))
                                )
                        }
                        .buttonStyle(PhysicalSpringButtonStyle())

                        if store.screenshotHotKeyShortcut != .defaultScreenshotShortcut && !isRecordingShot {
                            Button {
                                nav.hotKeyConflictWarning = nil
                                store.screenshotHotKeyShortcut = .defaultScreenshotShortcut
                                store.showToast("已恢复默认截图快捷键 ⌥ A")
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.primary.opacity(0.07)))
                            }
                            .buttonStyle(PhysicalSpringButtonStyle())
                            .help("恢复默认 ⌥ A")
                        }
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
                        LiquidPhysicsTogglePill(
                            isOn: Binding(
                                get: { store.launchAtLoginEnabled },
                                set: { store.setLaunchAtLogin($0) }
                            )
                        )
                    }

                    Divider().opacity(0.35)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("交互音效反馈")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("键入与转换时播放轻柔微音效（开启即刻试音）")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LiquidPhysicsTogglePill(isOn: $store.soundEffectsEnabled)
                    }
                    .onChange(of: store.soundEffectsEnabled) { _, on in
                        if on {
                            TactileFeedbackEngine.shared.perform(.pasteCommit)
                        } else {
                            TactileFeedbackEngine.shared.performNavigationStepHaptic()
                        }
                    }

                    Divider().opacity(0.35)

                    RoleAndOTASettingsSection(store: store, updater: updater)

                    Divider().opacity(0.35)

                    HStack(spacing: 12) {
                        Button {
                            nav.showSettings = false
                            playground.showHighlights()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                Text("新手引导")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PhysicalSpringButtonStyle())

                        Spacer()

                        Button {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                                showShortcutReference.toggle()
                            }
                            TactileFeedbackEngine.shared.performNavigationStepHaptic()
                        } label: {
                            HStack(spacing: 4) {
                                Text("快捷键速查")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Image(systemName: showShortcutReference ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PhysicalSpringButtonStyle())
                    }

                    if showShortcutReference {
                        Divider().opacity(0.35)
                        shortcutRow("鼠标旁呼出 / 隐藏", store.hotKeyShortcut.displayString)
                        Divider().opacity(0.35)
                        shortcutRow("区域 / 窗口截图（按住 ⌘ 松手秒复制）", store.screenshotHotKeyShortcut.displayString)
                        Divider().opacity(0.35)
                        shortcutRow(
                            "直接键入光标所在区域",
                            store.cardClickPasteMode == .singleClick ? "单击 / ↵" : "双击 / ↵"
                        )
                        Divider().opacity(0.35)
                        shortcutRow(
                            "仅复制到系统剪贴板",
                            store.cardClickPasteMode == .singleClick ? "⌥ 单击 / ⌘ C" : "单击 / ⌘ C"
                        )
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
                        shortcutRow("QuickLook 全图缩放 / 大爆炸速览（先用 ↓ 选卡）", "Space / ⌘ Y")
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
                    .buttonStyle(PhysicalSpringButtonStyle())

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
                    .buttonStyle(PhysicalSpringButtonStyle())
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
        if commitSecretCapsuleAction(forcePin: false) {
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
        let effectiveIndex: Int = {
            if nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count {
                return nav.selectedIndex
            }
            if !nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !filteredItems.isEmpty {
                return 0
            }
            return -1
        }()
        guard effectiveIndex >= 0, effectiveIndex < filteredItems.count else { return }
        let item = filteredItems[effectiveIndex]
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
        keywordDraftText = item.triggerKeyword ?? ""
        nav.isEditingAlias = true
        withAnimation(.easeOut(duration: 0.16)) {
            aliasEditingItem = item
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isAliasFieldFocused = true
        }
    }

    func beginAliasEditForSelected() {
        guard !filteredItems.isEmpty else { return }
        let idx = (nav.selectedIndex >= 0 && nav.selectedIndex < filteredItems.count) ? nav.selectedIndex : 0
        beginAliasEdit(for: filteredItems[idx])
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
        if commitSecretCapsuleAction(forcePin: true) {
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
        NSApp.activate(ignoringOtherApps: true)
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
        NSApp.activate(ignoringOtherApps: true)
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
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "导入 .iclip 或 Paste / Maccy / Raycast / Alfred / Clipy / Ditto / CSV 数据"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        var allowed: [UTType] = [.json, .commaSeparatedText, .tabSeparatedText, .plainText, .xml, .propertyList, .data]
        for ext in ["md", "markdown", "alfredsnippets", "alfredsnippet", "clipy", "dto"] {
            if let ut = UTType(filenameExtension: ext), !allowed.contains(ut) {
                allowed.append(ut)
            }
        }
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
            let catSuffix = summary.categoryBreakdown.map { "（\($0)）" } ?? ""
            if playground.isActive {
                playground.lastImportFeedback = "✓ 已从\(summary.sourceFormatLabel)导入 \(summary.importedNewCount) 条\(catSuffix)"
            }
            if summary.importedNewCount > 0 && summary.updatedExistingCount > 0 {
                store.showToast("已从\(summary.sourceFormatLabel)迁入 \(summary.importedNewCount) 条\(catSuffix)，更新 \(summary.updatedExistingCount) 条")
            } else if summary.importedNewCount > 0 {
                store.showToast("已从\(summary.sourceFormatLabel)迁入 \(summary.importedNewCount) 条\(catSuffix)")
            } else if summary.updatedExistingCount > 0 {
                store.showToast("已合并更新 \(summary.updatedExistingCount) 条既有收藏")
            } else {
                store.showToast("\(summary.sourceFormatLabel)内 \(summary.totalInBundle) 条记录均已在本地存在")
            }
        } catch {
            store.showToast(error.localizedDescription)
        }
    }

    func triggerQuickLookForSelected(initialMode: BigBangInitialPreviewMode = .autoDefault) {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        triggerSmartQuickLook(for: filteredItems[nav.selectedIndex], initialMode: initialMode)
    }

    private func wireBigBangCallbacks(for controller: BigBangStageController) {
        controller.onStepSelection = { dir in
            self.moveSelection(direction: dir)
            let visible = self.filteredItems
            guard self.nav.selectedIndex >= 0, self.nav.selectedIndex < visible.count else { return nil }
            return visible[self.nav.selectedIndex]
        }
        controller.onAdjacentItemsProvider = { target in
            let visible = self.filteredItems
            guard let idx = visible.firstIndex(where: { $0.id == target.id }) else { return [] }
            var neighbors: [ClipItem] = []
            if idx + 1 < visible.count { neighbors.append(visible[idx + 1]) }
            if idx - 1 >= 0 { neighbors.append(visible[idx - 1]) }
            return neighbors
        }
        controller.onCommitPasteText = { content, sourceItem, toast, isDiffTab in
            let latestSensitiveDiff: Bool = {
                guard isDiffTab,
                      let latest = self.store.items.first(where: {
                          ($0.type == .text || $0.type == .link)
                              && !$0.isBurnAfterPaste
                              && !SecretCapsuleMessenger.containsCapsule($0.text)
                      }) else {
                    return false
                }
                return latest.detectedSensitiveKind != nil
            }()
            self.store.pasteCustomString(
                content,
                sourceItem: sourceItem,
                toast: toast,
                shouldAutoPaste: true,
                extraForceProtected: latestSensitiveDiff,
                onBeforePaste: self.onDismiss
            )
        }
        controller.onCommitPasteImage = { target in
            self.store.copyAndOptionallyPaste(
                target,
                plainTextOnly: false,
                shouldAutoPaste: true,
                onBeforePaste: self.onDismiss
            )
        }
        controller.onCopyText = { content, target, toast in
            self.store.pasteCustomString(
                content,
                sourceItem: target,
                toast: toast,
                shouldAutoPaste: false,
                onBeforePaste: nil
            )
        }
        controller.onCopyFullItem = { target in
            self.store.copyAndOptionallyPaste(
                target,
                plainTextOnly: false,
                shouldAutoPaste: false,
                onBeforePaste: nil
            )
            self.store.showToast("✓ 已复制到剪贴板")
        }
        controller.onSaveToItem = { updatedText, target in
            _ = self.store.updateItemText(updatedText, for: target)
        }
        controller.onHandoffToSystemQuickLook = { target in
            let host = NSApp.windows.first(where: { $0 is KeyableFloatingPanel })
            self.configureSystemQuickLookCallbacks()
            _ = SystemQuickLookController.shared.presentOrUpdate(for: target, in: self.store, hostWindow: host)
        }
        controller.onPrepareSystemQuickLookCallbacks = {
            self.configureSystemQuickLookCallbacks()
        }
        controller.onDismissHostPanel = {
            self.onDismiss()
        }
    }

    private func configureSystemQuickLookCallbacks() {
        let ql = SystemQuickLookController.shared
        ql.onStepSelection = { dir in
            self.moveSelection(direction: dir)
            let visible = self.filteredItems
            guard self.nav.selectedIndex >= 0, self.nav.selectedIndex < visible.count else { return nil }
            return visible[self.nav.selectedIndex]
        }
        ql.onCommitPasteFromPreview = {
            self.pasteSelected()
        }
        ql.onCommitPasteRawFromPreview = {
            self.pasteSelected(forceRawSecret: true)
        }
        ql.onCopySelectedFromPreview = {
            _ = self.copySelectedOnly(plainPathOrText: false)
        }
        ql.onOpenExternalFromPreview = {
            _ = self.openSelectedExternally()
        }
        ql.onFallbackPreviewItem = { nextItem in
            self.triggerSmartQuickLook(for: nextItem, initialMode: .autoDefault)
        }
    }

    private func triggerSmartQuickLook(for item: ClipItem, initialMode: BigBangInitialPreviewMode = .autoDefault) {
        let host = NSApp.windows.first(where: { $0 is KeyableFloatingPanel })
        if item.type == .image || ((item.type == .text || item.type == .link) && !store.minimalModeEnabled) {
            let bb = BigBangStageController.shared
            wireBigBangCallbacks(for: bb)
            if bb.presentOrToggle(for: item, in: store, hostWindow: host, initialMode: initialMode) {
                SystemQuickLookController.shared.dismiss()
                nav.showQuickLook = false
                return
            }
        }
        if SystemQuickLookController.supportsNativeLargePreview(item) {
            configureSystemQuickLookCallbacks()
            if SystemQuickLookController.shared.presentOrUpdate(for: item, in: store, hostWindow: host) {
                BigBangStageController.shared.dismissImmediatelyAndPurge()
                nav.showQuickLook = false
                return
            }
        }
        BigBangStageController.shared.dismissImmediatelyAndPurge()
        SystemQuickLookController.shared.dismiss()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            nav.showQuickLook = true
        }
    }

    private func chatImagePermissionBanner(appName: String, needsRedrop: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange)

            Text(
                needsRedrop
                    ? "未能直接读取\(appName)图片 · 开启完全磁盘访问权限后请重新拖入"
                    : "未能直接读取\(appName)图片原图 · 开启完全磁盘访问权限后自动显示"
            )
                .font(.system(size: 11.2, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                AppWindowCoordinator.shared.presentPermissionSetup(store: store, highlight: .fullDiskAccess)
            } label: {
                Text("开启权限")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color(red: 0.12, green: 0.37, blue: 1.0)))
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    store.blockedChatImageAppName = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.7)
        )
    }

    private var deferredPermissionStatusBanner: some View {
        let missingCount = (store.isAccessibilityGranted ? 0 : 1)
            + (store.isFullDiskAccessGranted ? 0 : 1)
            + (store.isScreenRecordingGranted ? 0 : 1)
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange)

            Text("有 \(missingCount) 项系统权限未开启 · 补齐后解锁一键直贴、原图与截屏")
                .font(.system(size: 11.2, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                AppWindowCoordinator.shared.presentPermissionSetup(store: store)
            } label: {
                Text("去授权")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color(red: 0.12, green: 0.37, blue: 1.0)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.15 : 0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 0.7)
        )
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

/// 隔离式选中行包装：仅在自身 index 成为/退出选中项时重绘，根除快速扫过列表时的全屏重算
private struct SelectableClipCardRow: View {
    let selection: PanelSelectionStore
    let listRevision: UInt64
    let item: ClipItem
    let index: Int
    let surfaceStyle: PanelSurfaceStyle
    let liquidGlassAppearance: LiquidGlassAppearance
    let borderlessPanel: Bool
    let cardSkin: CardSkinStyle
    var isTriggerKeywordTopMatch: Bool = false
    let onSelect: () -> Void
    let onHoverSelect: () -> Bool
    let onPaste: (Bool) -> Void
    let onCopyOnly: (Bool) -> Void
    let onApplyTransform: (TransformAction, Bool) -> Void
    let onTogglePin: () -> Void
    let onSelectPinCategory: (PinCategory?) -> Void
    let onEditAlias: () -> Void
    let onToggleTodo: () -> Void
    let onToggleTodoCompletion: () -> Void
    let onRemoveTodo: () -> Void
    let onOpenQuickLook: () -> Void
    var onOpenBigBang: (() -> Void)? = nil
    var onConsumeReorderTapSuppression: (() -> Bool)? = nil
    var onCancelPendingReorder: (() -> Void)? = nil
    let onDelete: () -> Void

    @State private var isSelected: Bool
    @State private var listenerToken: UUID? = nil
    @State private var registeredIndex: Int? = nil

    init(
        selection: PanelSelectionStore,
        listRevision: UInt64,
        item: ClipItem,
        index: Int,
        surfaceStyle: PanelSurfaceStyle,
        liquidGlassAppearance: LiquidGlassAppearance,
        borderlessPanel: Bool,
        cardSkin: CardSkinStyle,
        isTriggerKeywordTopMatch: Bool = false,
        onSelect: @escaping () -> Void,
        onHoverSelect: @escaping () -> Bool,
        onPaste: @escaping (Bool) -> Void,
        onCopyOnly: @escaping (Bool) -> Void,
        onApplyTransform: @escaping (TransformAction, Bool) -> Void,
        onTogglePin: @escaping () -> Void,
        onSelectPinCategory: @escaping (PinCategory?) -> Void,
        onEditAlias: @escaping () -> Void,
        onToggleTodo: @escaping () -> Void,
        onToggleTodoCompletion: @escaping () -> Void,
        onRemoveTodo: @escaping () -> Void,
        onOpenQuickLook: @escaping () -> Void,
        onOpenBigBang: (() -> Void)? = nil,
        onConsumeReorderTapSuppression: (() -> Bool)? = nil,
        onCancelPendingReorder: (() -> Void)? = nil,
        onDelete: @escaping () -> Void
    ) {
        self.selection = selection
        self.listRevision = listRevision
        self.item = item
        self.index = index
        self.surfaceStyle = surfaceStyle
        self.liquidGlassAppearance = liquidGlassAppearance
        self.borderlessPanel = borderlessPanel
        self.cardSkin = cardSkin
        self.isTriggerKeywordTopMatch = isTriggerKeywordTopMatch
        self.onSelect = onSelect
        self.onHoverSelect = onHoverSelect
        self.onPaste = onPaste
        self.onCopyOnly = onCopyOnly
        self.onApplyTransform = onApplyTransform
        self.onTogglePin = onTogglePin
        self.onSelectPinCategory = onSelectPinCategory
        self.onEditAlias = onEditAlias
        self.onToggleTodo = onToggleTodo
        self.onToggleTodoCompletion = onToggleTodoCompletion
        self.onRemoveTodo = onRemoveTodo
        self.onOpenQuickLook = onOpenQuickLook
        self.onOpenBigBang = onOpenBigBang
        self.onConsumeReorderTapSuppression = onConsumeReorderTapSuppression
        self.onCancelPendingReorder = onCancelPendingReorder
        self.onDelete = onDelete
        _isSelected = State(initialValue: selection.selectedIndex == index)
    }

    var body: some View {
        ClipCardView(
            item: item,
            index: index,
            isSelected: isSelected,
            surfaceStyle: surfaceStyle,
            liquidGlassAppearance: liquidGlassAppearance,
            borderlessPanel: borderlessPanel,
            cardSkin: cardSkin,
            isTriggerKeywordTopMatch: isTriggerKeywordTopMatch,
            onSelect: onSelect,
            onHoverSelect: onHoverSelect,
            onPaste: onPaste,
            onCopyOnly: onCopyOnly,
            onApplyTransform: onApplyTransform,
            onTogglePin: onTogglePin,
            onSelectPinCategory: onSelectPinCategory,
            onEditAlias: onEditAlias,
            onToggleTodo: onToggleTodo,
            onToggleTodoCompletion: onToggleTodoCompletion,
            onRemoveTodo: onRemoveTodo,
            onOpenQuickLook: onOpenQuickLook,
            onOpenBigBang: onOpenBigBang,
            onConsumeReorderTapSuppression: onConsumeReorderTapSuppression,
            onCancelPendingReorder: onCancelPendingReorder,
            onDelete: onDelete
        )
        .onAppear {
            syncSelectionListener()
        }
        .onChange(of: index) { _, _ in
            syncSelectionListener()
        }
        .onChange(of: listRevision) { _, _ in
            syncSelectionListener()
        }
        .onDisappear {
            if let token = listenerToken, let idx = registeredIndex {
                selection.unregisterIndexListener(token: token, for: idx)
            }
            listenerToken = nil
            registeredIndex = nil
        }
    }

    private func syncSelectionListener() {
        let nowSelected = (selection.selectedIndex == index)
        if isSelected != nowSelected {
            isSelected = nowSelected
        }
        if registeredIndex != index || listenerToken == nil {
            if let oldToken = listenerToken, let oldIdx = registeredIndex {
                selection.unregisterIndexListener(token: oldToken, for: oldIdx)
            }
            registeredIndex = index
            listenerToken = selection.registerIndexListener(for: index) { selected in
                if isSelected != selected {
                    isSelected = selected
                }
            }
        }
    }
}

private struct SelectableImageGridRow: View {
    let selection: PanelSelectionStore
    let listRevision: UInt64
    let entries: [ClipDisplayRow.PlacedImageEntry]
    let rowIndex: Int
    let isPresented: Bool
    let cardSkin: CardSkinStyle
    let onSelect: (Int) -> Void
    let onHoverSelect: (Int) -> Bool
    let onPaste: (ClipItem) -> Void
    let onCopyOnly: (ClipItem) -> Void
    let onExtractOCR: (ClipItem, Bool) -> Void
    let onTogglePin: (ClipItem) -> Void
    let onToggleTodo: (ClipItem) -> Void
    let onRemoveTodo: (ClipItem) -> Void
    let onEditAlias: (ClipItem) -> Void
    let onOpenQuickLook: (Int, ClipItem) -> Void
    let onOpenOCRBigBang: (Int, ClipItem) -> Void
    let onDelete: (ClipItem) -> Void

    @State private var containsSelection: Bool
    @State private var rangeToken: UUID? = nil
    @State private var registeredRange: ClosedRange<Int>? = nil

    private var indexRange: ClosedRange<Int>? {
        guard let first = entries.first?.index, let last = entries.last?.index else { return nil }
        return min(first, last)...max(first, last)
    }

    init(
        selection: PanelSelectionStore,
        listRevision: UInt64,
        entries: [ClipDisplayRow.PlacedImageEntry],
        rowIndex: Int,
        isPresented: Bool,
        cardSkin: CardSkinStyle,
        onSelect: @escaping (Int) -> Void,
        onHoverSelect: @escaping (Int) -> Bool,
        onPaste: @escaping (ClipItem) -> Void,
        onCopyOnly: @escaping (ClipItem) -> Void,
        onExtractOCR: @escaping (ClipItem, Bool) -> Void,
        onTogglePin: @escaping (ClipItem) -> Void,
        onToggleTodo: @escaping (ClipItem) -> Void,
        onRemoveTodo: @escaping (ClipItem) -> Void,
        onEditAlias: @escaping (ClipItem) -> Void,
        onOpenQuickLook: @escaping (Int, ClipItem) -> Void,
        onOpenOCRBigBang: @escaping (Int, ClipItem) -> Void,
        onDelete: @escaping (ClipItem) -> Void
    ) {
        self.selection = selection
        self.listRevision = listRevision
        self.entries = entries
        self.rowIndex = rowIndex
        self.isPresented = isPresented
        self.cardSkin = cardSkin
        self.onSelect = onSelect
        self.onHoverSelect = onHoverSelect
        self.onPaste = onPaste
        self.onCopyOnly = onCopyOnly
        self.onExtractOCR = onExtractOCR
        self.onTogglePin = onTogglePin
        self.onToggleTodo = onToggleTodo
        self.onRemoveTodo = onRemoveTodo
        self.onEditAlias = onEditAlias
        self.onOpenQuickLook = onOpenQuickLook
        self.onOpenOCRBigBang = onOpenOCRBigBang
        self.onDelete = onDelete
        let initialRange: ClosedRange<Int>? = {
            guard let first = entries.first?.index, let last = entries.last?.index else { return nil }
            return min(first, last)...max(first, last)
        }()
        _containsSelection = State(initialValue: initialRange?.contains(selection.selectedIndex) ?? false)
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.element.item.id) { colIndex, entry in
                SelectableImageGridTileSlot(
                    selection: selection,
                    listRevision: listRevision,
                    item: entry.item,
                    index: entry.index,
                    tileWidth: entry.width,
                    tileHeight: entry.height,
                    cardSkin: cardSkin,
                    onSelect: { onSelect(entry.index) },
                    onHoverSelect: { onHoverSelect(entry.index) },
                    onPaste: { onPaste(entry.item) },
                    onCopyOnly: { onCopyOnly(entry.item) },
                    onExtractOCR: { autoPaste in onExtractOCR(entry.item, autoPaste) },
                    onTogglePin: { onTogglePin(entry.item) },
                    onToggleTodo: { onToggleTodo(entry.item) },
                    onRemoveTodo: { onRemoveTodo(entry.item) },
                    onEditAlias: { onEditAlias(entry.item) },
                    onOpenQuickLook: { onOpenQuickLook(entry.index, entry.item) },
                    onOpenOCRBigBang: { onOpenOCRBigBang(entry.index, entry.item) },
                    onDelete: { onDelete(entry.item) }
                )
                .cascadeAppear(
                    isPresented: isPresented,
                    delay: Double(min(rowIndex, 7)) * 0.028 + Double(min(colIndex, 8)) * 0.02
                )
                .id(entry.item.id)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .zIndex(containsSelection ? 30 : 0)
        .onAppear {
            syncRangeListener()
        }
        .onChange(of: listRevision) { _, _ in
            syncRangeListener()
        }
        .onDisappear {
            if let token = rangeToken {
                selection.unregisterRangeListener(token: token)
            }
            rangeToken = nil
            registeredRange = nil
        }
    }

    private func syncRangeListener() {
        guard let targetRange = indexRange else {
            containsSelection = false
            return
        }
        let nowContains = targetRange.contains(selection.selectedIndex)
        if containsSelection != nowContains {
            containsSelection = nowContains
        }
        if registeredRange != targetRange || rangeToken == nil {
            if let oldToken = rangeToken {
                selection.unregisterRangeListener(token: oldToken)
            }
            registeredRange = targetRange
            rangeToken = selection.registerRangeListener(for: targetRange) { active in
                if containsSelection != active {
                    containsSelection = active
                }
            }
        }
    }
}

private struct SelectableImageGridTileSlot: View {
    let selection: PanelSelectionStore
    let listRevision: UInt64
    let item: ClipItem
    let index: Int
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let cardSkin: CardSkinStyle
    let onSelect: () -> Void
    let onHoverSelect: () -> Bool
    let onPaste: () -> Void
    let onCopyOnly: () -> Void
    let onExtractOCR: (Bool) -> Void
    let onTogglePin: () -> Void
    let onToggleTodo: () -> Void
    let onRemoveTodo: () -> Void
    let onEditAlias: () -> Void
    let onOpenQuickLook: () -> Void
    let onOpenOCRBigBang: () -> Void
    let onDelete: () -> Void

    @State private var isSelected: Bool
    @State private var listenerToken: UUID? = nil
    @State private var registeredIndex: Int? = nil

    init(
        selection: PanelSelectionStore,
        listRevision: UInt64,
        item: ClipItem,
        index: Int,
        tileWidth: CGFloat,
        tileHeight: CGFloat,
        cardSkin: CardSkinStyle,
        onSelect: @escaping () -> Void,
        onHoverSelect: @escaping () -> Bool,
        onPaste: @escaping () -> Void,
        onCopyOnly: @escaping () -> Void,
        onExtractOCR: @escaping (Bool) -> Void,
        onTogglePin: @escaping () -> Void,
        onToggleTodo: @escaping () -> Void,
        onRemoveTodo: @escaping () -> Void,
        onEditAlias: @escaping () -> Void,
        onOpenQuickLook: @escaping () -> Void,
        onOpenOCRBigBang: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.selection = selection
        self.listRevision = listRevision
        self.item = item
        self.index = index
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.cardSkin = cardSkin
        self.onSelect = onSelect
        self.onHoverSelect = onHoverSelect
        self.onPaste = onPaste
        self.onCopyOnly = onCopyOnly
        self.onExtractOCR = onExtractOCR
        self.onTogglePin = onTogglePin
        self.onToggleTodo = onToggleTodo
        self.onRemoveTodo = onRemoveTodo
        self.onEditAlias = onEditAlias
        self.onOpenQuickLook = onOpenQuickLook
        self.onOpenOCRBigBang = onOpenOCRBigBang
        self.onDelete = onDelete
        _isSelected = State(initialValue: selection.selectedIndex == index)
    }

    var body: some View {
        ClipImageGridTile(
            item: item,
            index: index,
            isSelected: isSelected,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            cardSkin: cardSkin,
            onSelect: onSelect,
            onHoverSelect: onHoverSelect,
            onPaste: onPaste,
            onCopyOnly: onCopyOnly,
            onExtractOCR: onExtractOCR,
            onTogglePin: onTogglePin,
            onToggleTodo: onToggleTodo,
            onRemoveTodo: onRemoveTodo,
            onEditAlias: onEditAlias,
            onOpenQuickLook: onOpenQuickLook,
            onOpenOCRBigBang: onOpenOCRBigBang,
            onDelete: onDelete
        )
        .onAppear {
            syncSelectionListener()
        }
        .onChange(of: index) { _, _ in
            syncSelectionListener()
        }
        .onChange(of: listRevision) { _, _ in
            syncSelectionListener()
        }
        .onDisappear {
            if let token = listenerToken, let idx = registeredIndex {
                selection.unregisterIndexListener(token: token, for: idx)
            }
            listenerToken = nil
            registeredIndex = nil
        }
    }

    private func syncSelectionListener() {
        let nowSelected = (selection.selectedIndex == index)
        if isSelected != nowSelected {
            isSelected = nowSelected
        }
        if registeredIndex != index || listenerToken == nil {
            if let oldToken = listenerToken, let oldIdx = registeredIndex {
                selection.unregisterIndexListener(token: oldToken, for: oldIdx)
            }
            registeredIndex = index
            listenerToken = selection.registerIndexListener(for: index) { selected in
                if isSelected != selected {
                    isSelected = selected
                }
            }
        }
    }
}

/// 独立隔离分类标签条：仅自身感知 hover 微光胶囊与触感反馈，零触发主面板及卡片列表重绘
private struct FilterTabBarView: View {
    let tabs: [ClipFilterTab]
    let selectedTab: ClipFilterTab
    let minimalMode: Bool
    let pendingTodos: Int
    let glassPalette: LiquidGlassPalette
    let colorScheme: ColorScheme
    let onSelectTab: (ClipFilterTab) -> Void

    @State private var hoveredTab: ClipFilterTab? = nil

    var body: some View {
        let selectedIdx = tabs.firstIndex(of: selectedTab) ?? 0

        return GeometryReader { geo in
            let inset: CGFloat = 3
            let innerWidth = max(0, geo.size.width - inset * 2)
            let pillWidth = innerWidth / CGFloat(max(1, tabs.count))

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        let isTabHovered = (hoveredTab == tab && selectedTab != tab)
                        Capsule()
                            .fill(
                                isTabHovered
                                    ? Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.06)
                                    : Color.clear
                            )
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                            .frame(width: pillWidth, height: 28)
                    }
                }
                .padding(.horizontal, inset)
                .animation(.easeOut(duration: 0.12), value: hoveredTab)

                // 常驻单一选中胶囊滑块：仅做 GPU 水平位移，在 macOS 26/27 叠加原生交互式液态玻璃光学折射，永不销毁重建
                Group {
                    if #available(macOS 26.0, *) {
                        Capsule()
                            .fill(glassPalette.activeSegmentFill.opacity(0.65))
                            .glassEffect(.regular.interactive(), in: Capsule())
                    } else {
                        Capsule()
                            .fill(glassPalette.activeSegmentFill)
                            .overlay(
                                Capsule()
                                    .strokeBorder(glassPalette.controlCapsuleStroke, lineWidth: 0.6)
                            )
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: 2.5, y: 1)
                    }
                }
                .frame(width: pillWidth, height: 28)
                .offset(x: inset + CGFloat(selectedIdx) * pillWidth)
                .animation(.spring(response: 0.22, dampingFraction: 0.84), value: selectedTab)

                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        let isSelected = (selectedTab == tab)
                        let isHovered = (hoveredTab == tab)
                        Button {
                            onSelectTab(tab)
                        } label: {
                            HStack(spacing: 2.5) {
                                Text(tab.title)
                                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(
                                        isSelected
                                            ? Color.primary
                                            : (isHovered ? Color.primary.opacity(0.88) : Color.secondary)
                                    )
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
                        .onHover { hovering in
                            if hovering {
                                if hoveredTab != tab {
                                    hoveredTab = tab
                                    if !isSelected {
                                        TactileFeedbackEngine.shared.perform(.hoverTick)
                                    }
                                }
                            } else if hoveredTab == tab {
                                hoveredTab = nil
                            }
                        }
                        .help("\(tab.title)（\(tab.optionShortcutLabel(minimalMode: minimalMode))）")
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
        .onDisappear {
            hoveredTab = nil
        }
    }
}

/// 独立隔离收藏子类目筛选条：自带苹果微悬浮提亮，零触发主列表重建
private struct PinCategoryBarView: View {
    let selectedCategory: PinCategory?
    let onSelectCategory: (PinCategory?) -> Void

    @State private var hoveredCategory: PinCategory? = nil
    @State private var isHoveringAll: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            TahoeGlassContainer(spacing: 5) {
                HStack(spacing: 5) {
                let allActive = (selectedCategory == nil)
                Button {
                    onSelectCategory(nil)
                } label: {
                    Text("全部收藏")
                        .font(.system(size: 11, weight: allActive ? .semibold : .medium))
                        .foregroundStyle(
                            allActive
                                ? Color.white
                                : (isHoveringAll ? Color.primary.opacity(0.9) : Color.secondary)
                        )
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                allActive
                                    ? Color.accentColor
                                    : Color.primary.opacity(isHoveringAll ? 0.11 : 0.06)
                            )
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                (!allActive && isHoveringAll) ? Color.primary.opacity(0.14) : Color.clear,
                                lineWidth: 0.6
                            )
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering && !isHoveringAll && !allActive {
                        TactileFeedbackEngine.shared.perform(.hoverTick)
                    }
                    isHoveringAll = hovering
                }
                .animation(.easeOut(duration: 0.12), value: isHoveringAll)

                ForEach(PinCategory.allCases) { cat in
                    let active = (selectedCategory == cat)
                    let hovered = (hoveredCategory == cat)
                    Button {
                        onSelectCategory(active ? nil : cat)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(active ? Color.white : cat.dotColor)
                                .frame(width: 6, height: 6)
                            Text(cat.title)
                                .font(.system(size: 11, weight: active ? .semibold : .medium))
                        }
                        .foregroundStyle(
                            active
                                ? Color.white
                                : (hovered ? Color.primary : Color.primary.opacity(0.82))
                        )
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                active
                                    ? cat.dotColor
                                    : (hovered ? cat.dotColor.opacity(0.14) : Color.primary.opacity(0.06))
                            )
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                (!active && hovered) ? cat.dotColor.opacity(0.32) : Color.clear,
                                lineWidth: 0.6
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            if hoveredCategory != cat {
                                hoveredCategory = cat
                                if !active {
                                    TactileFeedbackEngine.shared.perform(.hoverTick)
                                }
                            }
                        } else if hoveredCategory == cat {
                            hoveredCategory = nil
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: hoveredCategory)
                }
            }
            }
        }
        .tahoeSoftScrollEdges()
        .onDisappear {
            isHoveringAll = false
            hoveredCategory = nil
        }
    }
}

