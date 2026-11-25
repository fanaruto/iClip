import SwiftUI
import AppKit

struct InlineFlashGate: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var isActive: Bool = false

    mutating func trigger() -> UInt64 {
        generation &+= 1
        isActive = true
        return generation
    }

    mutating func completeIfCurrent(generation token: UInt64) -> Bool {
        guard isActive, generation == token else { return false }
        isActive = false
        return true
    }

    mutating func cancel() {
        generation &+= 1
        isActive = false
    }
}

/// 单条 iOS 风格剪贴板卡片（搭载微秒级语义感知与瞬时变换胶囊条）
struct ClipCardView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let surfaceStyle: PanelSurfaceStyle
    let liquidGlassAppearance: LiquidGlassAppearance
    let borderlessPanel: Bool
    var cardSkin: CardSkinStyle = .nativeApple
    let onSelect: () -> Void
    var onHoverSelect: (() -> Bool)? = nil
    let onPaste: (Bool) -> Void
    let onCopyOnly: (Bool) -> Void
    let onApplyTransform: (TransformAction, Bool) -> Void
    let onTogglePin: () -> Void
    var onSelectPinCategory: ((PinCategory?) -> Void)? = nil
    var onEditAlias: (() -> Void)? = nil
    var onToggleTodo: (() -> Void)? = nil
    var onToggleTodoCompletion: (() -> Void)? = nil
    var onRemoveTodo: (() -> Void)? = nil
    var onOpenQuickLook: (() -> Void)? = nil
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered: Bool = false
    @State private var showHoverActions: Bool = false
    @State private var hoverActionsDwellGate = HoverActionsDwellGate()
    @State private var hoverActionsDwellTask: Task<Void, Never>? = nil
    @State private var asyncThumbnail: NSImage? = nil
    @State private var lastTapUptime: TimeInterval = 0
    @State private var showCopiedInlineFlash: Bool = false
    @State private var copiedFlashGate = InlineFlashGate()
    @State private var copiedFlashTask: Task<Void, Never>? = nil

    private var glassPalette: LiquidGlassPalette {
        LiquidGlassPalette(colorScheme: colorScheme, surfaceStyle: surfaceStyle, appearance: liquidGlassAppearance)
    }

    private var renderMeta: ClipCardRenderMeta {
        ClipboardStore.shared.cardRenderMeta(for: item)
    }

    private var semantic: SemanticSnapshot {
        ClipboardStore.shared.semanticSnapshot(for: item)
    }

    private var hasEmbeddedWebLink: Bool {
        renderMeta.hasEmbeddedWebLink
    }

    private var hasLeadingVisual: Bool {
        if item.type == .text {
            return semantic.parsedColorRGBA != nil || renderMeta.hasEmbeddedWebLink
        }
        return true
    }

    private var hasInteractiveLeadingLink: Bool {
        item.type == .link || (item.type == .text && semantic.parsedColorRGBA == nil && renderMeta.hasEmbeddedWebLink)
    }

    private var showsTodoCheckbox: Bool {
        !ClipboardStore.shared.minimalModeEnabled && item.isTodo
    }

    private var hoverActionBarEstimateWidth: CGFloat {
        let count = 2 + ((!ClipboardStore.shared.minimalModeEnabled && onToggleTodo != nil) ? 1 : 0)
        return ClipCardLayoutMetrics.hoverActionBarWidth(buttonCount: count)
    }

    var body: some View {
        let store = ClipboardStore.shared
        let minimalMode = store.minimalModeEnabled
        let meta = store.cardRenderMeta(for: item)
        let snap = store.semanticSnapshot(for: item)
        let todoCheckboxVisible = !minimalMode && item.isTodo
        let embeddedWebLink = meta.hasEmbeddedWebLink
        let leadingVisualVisible: Bool = {
            if item.type == .text {
                return snap.parsedColorRGBA != nil || embeddedWebLink
            }
            return true
        }()
        let interactiveLeadingLink = item.type == .link || (item.type == .text && snap.parsedColorRGBA == nil && embeddedWebLink)
        let actionBarWidth: CGFloat = {
            let count = 2 + ((!minimalMode && onToggleTodo != nil) ? 1 : 0)
            return ClipCardLayoutMetrics.hoverActionBarWidth(buttonCount: count)
        }()

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 11) {
                if todoCheckboxVisible {
                    TodoLeadingCheckboxButton(
                        isCompleted: item.isTodoCompleted,
                        isSelected: isSelected,
                        isHovered: isHovered,
                        action: {
                            (onToggleTodoCompletion ?? onToggleTodo)?()
                        }
                    )
                }

                if leadingVisualVisible {
                    leadingThumbnail(semantic: snap, hasEmbeddedURL: embeddedWebLink)
                }

                VStack(alignment: .leading, spacing: 5.5) {
                    let veilOn = store.maskSensitivePreviews && !isSelected && !isHovered
                    Text(veilOn ? meta.veiledDisplayTitle : meta.plainDisplayTitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineSpacing(2.5)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .strikethrough(todoCheckboxVisible && item.isTodoCompleted, color: isSelected ? Color.white.opacity(0.75) : Color.secondary)
                        .opacity((todoCheckboxVisible && item.isTodoCompleted) ? 0.54 : 1.0)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, index < 9 ? 40 : 4)
                        .hoverActionSafeTextMask(isHovered: isHovered && showHoverActions, reservedActionWidth: actionBarWidth)

                    HStack(spacing: 6) {
                        if item.isPinned {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.orange)
                        }

                        if !minimalMode, let cat = item.pinCategory {
                            HStack(spacing: 3.5) {
                                Circle()
                                    .fill(isSelected ? Color.white : cat.dotColor)
                                    .frame(width: 5.5, height: 5.5)
                                Text(cat.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(isSelected ? Color.white.opacity(0.95) : cat.dotColor)
                            .layoutPriority(1)
                            Text("·")
                        }

                        // 单一优先状态徽标（高危/即焚 > 待办 > OneMind 常用回忆 > 语义种类），避免多标签堆砌
                        let contextBadge = !minimalMode
                            ? OneMindKernel.shared.preferredTargetAppBadge(for: item.contentHash, activeTargetApp: store.activeTargetAppName)
                            : nil
                        let reuse = (!minimalMode && !item.isPinned) ? OneMindKernel.shared.reuseCount(for: item.contentHash) : 0

                        if item.isBurnAfterPaste {
                            Text("粘贴即焚")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.red)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text("·")
                        } else if case .pastejackingOrBidi = meta.detectedPoisonThreat {
                            Text("含隐藏控制符")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.red)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text("·")
                        } else if let linkRisk = meta.detectedLinkRisk {
                            Text(linkRisk.badgeTitle)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.red)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text("·")
                        } else if !item.isBurnAfterPaste, let secKind = meta.detectedSensitiveKind {
                            let ttlHint = (!item.isPinned && !item.isPendingTodo && store.autoExpireUnpinnedSecrets) ? " · 24h自毁" : ""
                            Text(secKind.shieldBadgeTitle + ttlHint)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.orange)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text("·")
                        } else if todoCheckboxVisible {
                            Text(item.isTodoCompleted ? "已完成" : "待办")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(
                                    isSelected
                                        ? Color.white.opacity(0.95)
                                        : (item.isTodoCompleted ? Color.green : Color.accentColor)
                                )
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text("·")
                        } else if let contextBadge {
                            Text(contextBadge)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.accentColor)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text("·")
                        } else if reuse >= 3 {
                            Text("高频 ×\(reuse)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.orange)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text("·")
                        } else if let kind = snap.primaryKind {
                            Text(kind.badgeTitle)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.accentColor)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text("·")
                        }

                        Text(veilOn ? meta.veiledSubtitle : meta.plainSubtitle)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let appName = item.sourceAppName, !appName.isEmpty {
                            Text("·")
                            Text(appName)
                                .lineLimit(1)
                        }

                        if showCopiedInlineFlash {
                            Text("·")
                            Text("✓ 已复制")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white : Color.green)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(2)
                                .transition(.opacity)
                        }

                        Spacer(minLength: 4)

                        Text(item.relativeTimeText)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(3)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                }
                .animation(.easeOut(duration: 0.10), value: isSelected)
                .overlay(alignment: .topTrailing) {
                    if isHovered && showHoverActions {
                        hoverActions
                            .floatingActionIslandBackdrop(isSelected: isSelected, colorScheme: colorScheme)
                            .offset(y: -6.5)
                            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
                    } else if index < 9 {
                        shortcutBadge
                    }
                }
            }
        }
        .padding(.horizontal, leadingVisualVisible ? 12 : 14)
        .padding(.vertical, leadingVisualVisible ? 10 : 11)
        .background(
            ZStack {
                cardBackground
                CardSpatialSpecularLayer(
                    cornerRadius: 14,
                    cardSkin: cardSkin,
                    isHovered: isHovered,
                    isSelected: isSelected,
                    pointerNorm: .zero
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.10), value: isSelected)
            .animation(.spring(response: 0.30, dampingFraction: 0.86), value: cardSkin)
        )
        .overlay(
            cardBorder
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.10), value: isSelected)
                .animation(.spring(response: 0.30, dampingFraction: 0.86), value: cardSkin)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .modifier(
            AppleTVPhysicalCardModifier(
                itemID: item.id,
                surfaceKind: .standardRow,
                cardSkin: cardSkin,
                isHovered: isHovered,
                isSelected: isSelected,
                trailingActionWidth: actionBarWidth,
                leadingExclusionWidth: ClipCardLayoutMetrics.leadingForceTouchExclusionWidth(
                    hasTodoCheckbox: todoCheckboxVisible,
                    hasInteractiveLeadingLink: interactiveLeadingLink
                ),
                bottomExclusionHeight: 0,
                onHoverEnterSelect: {
                    let allowed = onHoverSelect?() ?? {
                        onSelect()
                        return true
                    }()
                    if allowed {
                        if !isHovered {
                            isHovered = true
                        }
                        hoverActionsDwellTask?.cancel()
                        let token = hoverActionsDwellGate.beginHover()
                        hoverActionsDwellTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 42_000_000)
                            guard !Task.isCancelled, hoverActionsDwellGate.shouldReveal(for: token) else { return }
                            if !showHoverActions {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    showHoverActions = true
                                }
                            }
                        }
                    }
                    return allowed
                },
                onHoverEnded: {
                    hoverActionsDwellTask?.cancel()
                    hoverActionsDwellTask = nil
                    hoverActionsDwellGate.endHover()
                    if showHoverActions {
                        showHoverActions = false
                    }
                    if isHovered {
                        isHovered = false
                    }
                },
                onDeepPressPreview: {
                    onSelect()
                    onOpenQuickLook?()
                }
            )
        )
        .zIndex(isHovered ? 30 : (isSelected ? 5 : 0))
        .onDrag {
            ClipboardStore.shared.makeDragItemProvider(for: item)
        }
        .onTapGesture {
            handleCardTap()
        }
        .contextMenu {
            contextMenuItems
        }
        .onDisappear {
            copiedFlashTask?.cancel()
            copiedFlashTask = nil
            copiedFlashGate.cancel()
            hoverActionsDwellTask?.cancel()
            hoverActionsDwellTask = nil
            hoverActionsDwellGate.endHover()
            showHoverActions = false
            isHovered = false
            showCopiedInlineFlash = false
        }
    }

    private func handleCardTap() {
        let suppressed = ForceTouchSuppressionRegistry.consumeSuppressionIfNeeded(for: item.id)
        let now = ProcessInfo.processInfo.systemUptime
        let eventClickCount = (NSApp.currentEvent?.type == .leftMouseUp) ? (NSApp.currentEvent?.clickCount ?? 1) : 1
        let mode = ClipboardStore.shared.cardClickPasteMode
        let effectiveClickCount = CardClickGestureResolver.effectiveClickCount(
            mode: mode,
            eventClickCount: eventClickCount,
            elapsedSinceLastTap: now - lastTapUptime,
            maxInterval: min(NSEvent.doubleClickInterval, 0.32)
        )
        let outcome = CardClickGestureResolver.resolve(
            mode: mode,
            clickCount: effectiveClickCount,
            modifiers: NSEvent.modifierFlags,
            isLink: (item.type == .link || hasEmbeddedWebLink),
            isForceTouchSuppressed: suppressed
        )
        lastTapUptime = CardClickGestureResolver.nextLastTapUptime(
            mode: mode,
            outcome: outcome,
            now: now
        )
        switch outcome {
        case .ignore:
            return
        case .openExternalLink:
            if !isHovered { isHovered = true }
            onSelect()
            _ = ClipboardStore.shared.openItemExternally(item)
        case .paste(let plainTextOnly):
            if !isHovered { isHovered = true }
            onSelect()
            onPaste(plainTextOnly)
        case .copyOnly:
            if !isHovered { isHovered = true }
            onSelect()
            onCopyOnly(false)
            triggerCopiedInlineFlash()
        }
    }

    private func triggerCopiedInlineFlash() {
        copiedFlashTask?.cancel()
        let gen = copiedFlashGate.trigger()
        withAnimation(.easeOut(duration: 0.14)) {
            showCopiedInlineFlash = true
        }
        copiedFlashTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled, copiedFlashGate.completeIfCurrent(generation: gen) else { return }
            copiedFlashTask = nil
            withAnimation(.easeOut(duration: 0.22)) {
                showCopiedInlineFlash = false
            }
        }
    }

    // MARK: - 左侧视觉预览

    @ViewBuilder
    private func leadingThumbnail(semantic snap: SemanticSnapshot, hasEmbeddedURL: Bool) -> some View {
        switch item.type {
        case .image:
            if let nsImage = ClipboardStore.shared.cachedThumbnail(for: item) ?? asyncThumbnail {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
            } else {
                iconBadge(symbol: "photo", tint: .purple)
                    .task(id: item.id) {
                        if let img = await ClipboardStore.shared.loadThumbnail(for: item), !Task.isCancelled {
                            asyncThumbnail = img
                        }
                    }
            }

        case .file:
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: ClipboardStore.shared.fileIcon(for: item))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                if let count = item.filePaths?.count, count > 1 {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 3, y: 3)
                }
            }
            .frame(width: 46, height: 46)

        case .link:
            let isDirty = (snap.primaryKind == .dirtyURL)
            LinkLaunchLogoButton(
                defaultSymbol: isDirty ? "sparkles" : "link",
                tint: isDirty ? .teal : .blue,
                isSelectedCard: isSelected
            ) {
                ClipboardStore.shared.openLinkInBrowser(item)
            }

        case .text:
            if let rgba = snap.parsedColorRGBA {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a))
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)
            } else if hasEmbeddedURL {
                LinkLaunchLogoButton(
                    defaultSymbol: "link",
                    tint: .blue,
                    isSelectedCard: isSelected
                ) {
                    _ = ClipboardStore.shared.openItemExternally(item)
                }
            } else {
                EmptyView()
            }
        }
    }

    private func iconBadge(symbol: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.22) : tint.opacity(0.13))
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : tint)
        }
        .frame(width: 42, height: 42)
    }

    // MARK: - 右上角快捷键与悬停操作

    private var shortcutBadge: some View {
        Text("⌘\(index + 1)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isSelected ? Color.white.opacity(0.2) : Color.primary.opacity(0.06))
            )
    }

    private var hoverActions: some View {
        let surface: HoverActionSurface = isSelected ? .onSelectedCard : .onStandardCard
        return HStack(spacing: 5) {
            if !ClipboardStore.shared.minimalModeEnabled, let onToggleTodo {
                HoverActionCircleButton(
                    symbolName: item.isTodoCompleted ? "checkmark.circle.fill" : (item.isTodo ? "circle.inset.filled" : "checkmark.circle"),
                    size: 22,
                    iconSize: 10.5,
                    surface: surface,
                    kind: .todo(isTodo: item.isTodo, isCompleted: item.isTodoCompleted),
                    helpText: item.isTodoCompleted ? "已完成 · 点击恢复未完成（⌘T）" : (item.isTodo ? "标记待办已完成（⌘T）" : "加入待办清单（⌘T）"),
                    action: onToggleTodo
                )
            }

            HoverActionCircleButton(
                symbolName: item.isPinned ? "star.fill" : "star",
                size: 22,
                iconSize: 10.5,
                surface: surface,
                kind: .star(isPinned: item.isPinned),
                helpText: item.isPinned ? "取消收藏" : "收藏",
                action: onTogglePin
            )

            HoverActionCircleButton(
                symbolName: "trash",
                hoverSymbolName: "trash.fill",
                size: 22,
                iconSize: 10.5,
                surface: surface,
                kind: .delete,
                helpText: "删除此条记录",
                action: onDelete
            )
        }
    }

    // MARK: - 卡片背景与唯一连续边框（恒定视图身份，零双边与零闪框）

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(glassPalette.clipCardFill(isHovered: isHovered))

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.orange.opacity(isHovered ? 0.22 : 0.16),
                            Color.yellow.opacity(isHovered ? 0.14 : 0.09)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(glassPalette.pinnedCardBackdrop(isHovered: isHovered))
                )
                .opacity(!isSelected && item.isPinned ? 1 : 0)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .controlAccentColor),
                            Color(nsColor: .controlAccentColor).opacity(0.88)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .opacity(isSelected ? 1 : 0)
        }
    }

    private var cardBorder: some View {
        let showStroke = !borderlessPanel || item.isPinned || surfaceStyle == .liquidGlass || isSelected
        let strokeWidth: CGFloat = (!isSelected && item.isPinned) ? 1.0 : (isSelected ? 0.75 : (borderlessPanel ? 0.65 : 0.75))
        let baseStrokeColor: Color = {
            if !showStroke { return .clear }
            if isSelected { return Color.white.opacity(0.32) }
            if item.isPinned { return Color.orange.opacity(isHovered ? 0.62 : 0.45) }
            return glassPalette.clipCardStroke(isHovered: isHovered)
        }()
        let topStrokeColor: Color = {
            if !showStroke { return .clear }
            if cardSkin == .spatialGlass && isHovered && !isSelected {
                return Color.white.opacity(colorScheme == .dark ? 0.36 : 0.96)
            }
            return baseStrokeColor
        }()

        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [topStrokeColor, baseStrokeColor],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: showStroke ? strokeWidth : 0
            )
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private var contextMenuItems: some View {
        let clickMode = ClipboardStore.shared.cardClickPasteMode
        Button(clickMode == .singleClick ? "键入光标处（单击）" : "键入光标处（双击）") {
            onPaste(false)
        }

        Button(clickMode == .singleClick ? "仅复制到剪贴板（⌥单击 / ⌘C）" : "仅复制到剪贴板（单击 / ⌘C）") {
            onCopyOnly(false)
        }

        if let onOpenQuickLook {
            Button(item.type == .image ? "大屏预览 / 大爆炸选字（Space / 重按）" : "大爆炸分词速览（Space / 重按）") {
                onOpenQuickLook()
            }
        }

        if !ClipboardStore.shared.minimalModeEnabled && CopyAppendHelper.extractAppendableText(from: item) != nil {
            Button("追加至当前剪贴板（⇧⌘C）") {
                ClipboardStore.shared.appendItemToCurrentClipboard(item)
            }
        }

        if !ClipboardStore.shared.minimalModeEnabled && item.type == .image {
            Divider()
            Button("隐私智能打码粘贴（遮盖号/码/密钥）") {
                ClipboardStore.shared.pastePrivacyRedactedImage(for: item, shouldAutoPaste: true)
            }
            Button("复制隐私打码图（PNG）") {
                ClipboardStore.shared.pastePrivacyRedactedImage(for: item, shouldAutoPaste: false)
            }
            Button("复制无定位/无 EXIF 纯净图") {
                ClipboardStore.shared.pasteMetadataStrippedImage(for: item, shouldAutoPaste: false)
            }
            Button("复制轻量瘦身图（JPEG）") {
                ClipboardStore.shared.pasteCompressedJPEG(for: item, shouldAutoPaste: false)
            }
            Button("复制圆角阴影样机图（PNG）") {
                ClipboardStore.shared.pasteAppleMockupImage(for: item, shouldAutoPaste: false)
            }
        }

        if !semantic.actions.isEmpty {
            Divider()
            ForEach(semantic.actions) { action in
                Button("智变键入：\(action.title)") {
                    onApplyTransform(action, true)
                }
            }
        }

        if item.type == .file,
           let first = item.filePaths?.first,
           ImageStudioEngine.fileContainsPrivacyMetadata(at: URL(fileURLWithPath: first)) {
            Divider()
            Button("抹除照片 GPS 定位与 EXIF 后粘贴") {
                ClipboardStore.shared.pasteMetadataStrippedImage(for: item, shouldAutoPaste: true)
            }
            Button("复制无定位/无 EXIF 纯净图") {
                ClipboardStore.shared.pasteMetadataStrippedImage(for: item, shouldAutoPaste: false)
            }
        }

        if item.type == .file {
            Button("键入文件路径（纯文本 · ⌥⌘C）") {
                onPaste(true)
            }
            if let first = item.filePaths?.first {
                Button("在访达中显示（⌘O）") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
                }
            }
        }

        if item.type == .link, ClipboardStore.shared.resolvedBrowserURL(for: item) != nil {
            Button("在浏览器中打开（⌘O）") {
                ClipboardStore.shared.openLinkInBrowser(item)
            }
        } else if item.type == .text, let rawText = item.text {
            if URLTrackingCleaner.extractFirstCleanedWebURL(from: rawText) != nil {
                Button("在浏览器中打开内嵌链接（⌘O）") {
                    _ = ClipboardStore.shared.openItemExternally(item)
                }
            } else if URLTrackingCleaner.resolveExistingLocalFileURL(from: rawText) != nil {
                Button("在访达中定位路径（⌘O）") {
                    _ = ClipboardStore.shared.openItemExternally(item)
                }
            }
        }

        Divider()

        if !ClipboardStore.shared.minimalModeEnabled, let onToggleTodo {
            if !item.isTodo {
                Button("加入待办清单（⌘T）") {
                    onToggleTodo()
                }
            } else if item.isPendingTodo {
                Button("✓ 标记待办已完成（⌘T）") {
                    onToggleTodo()
                }
                if let onRemoveTodo {
                    Button("移出待办清单") {
                        onRemoveTodo()
                    }
                }
            } else {
                Button("恢复为未完成待办（⌘T）") {
                    onToggleTodo()
                }
                if let onRemoveTodo {
                    Button("移出待办清单") {
                        onRemoveTodo()
                    }
                }
            }
        }

        Button(item.isPinned ? "取消收藏" : "收藏") {
            onTogglePin()
        }

        if item.isPinned, !ClipboardStore.shared.minimalModeEnabled, let onSelectPinCategory {
            Menu("归入收藏分组") {
                ForEach(PinCategory.allCases) { cat in
                    Button {
                        onSelectPinCategory(cat)
                    } label: {
                        Text(item.pinCategory == cat ? "✓ \(cat.title)" : cat.title)
                    }
                }
                if item.pinCategory != nil {
                    Divider()
                    Button("移除分组标签") {
                        onSelectPinCategory(nil)
                    }
                }
            }
        }

        if !ClipboardStore.shared.minimalModeEnabled {
            if let onOpenQuickLook {
                Button("速览与原位微调（Space）") {
                    onOpenQuickLook()
                }
            }
            if let onEditAlias {
                Button(item.customAlias != nil ? "修改备注标题（⌘R）..." : "设置备注标题（⌘R）...") {
                    onEditAlias()
                }
            }
        }

        Button(item.isBurnAfterPaste ? "取消「粘贴即焚」（⌘B）" : "设为「粘贴即焚」（⌘B）") {
            ClipboardStore.shared.toggleBurnAfterPaste(item)
        }

        if let appName = item.sourceAppName, !appName.isEmpty, item.sourceAppBundleID != nil {
            Button("忽略来自「\(appName)」的复制") {
                _ = ClipboardStore.shared.ignoreSourceApp(of: item)
            }
        }

        Button("删除", role: .destructive) {
            onDelete()
        }
    }
}

enum ClipCardLayoutMetrics {
    static func hoverActionBarWidth(buttonCount: Int) -> CGFloat {
        let count = max(0, buttonCount)
        guard count > 0 else { return 0 }
        return CGFloat(count) * 27.0 + 6.0
    }

    static func hoverActionMaskStops(totalWidth: CGFloat, reservedActionWidth: CGFloat) -> (fadeStart: CGFloat, fadeEnd: CGFloat) {
        let totalW = max(1, totalWidth)
        let fadeEnd = max(0.05, min(0.98, (totalW - max(0, reservedActionWidth)) / totalW))
        let fadeStart = max(0.0, fadeEnd - (22.0 / totalW))
        return (fadeStart, fadeEnd)
    }

    static func leadingForceTouchExclusionWidth(hasTodoCheckbox: Bool, hasInteractiveLeadingLink: Bool) -> CGFloat {
        switch (hasTodoCheckbox, hasInteractiveLeadingLink) {
        case (false, false): return 0
        case (true, false): return 40
        case (false, true): return 58
        case (true, true): return 89
        }
    }

    static func imageTileTrailingActionWidth(hasOCRButton: Bool, hasTodoButton: Bool) -> CGFloat {
        var count = 2
        if hasOCRButton { count += 1 }
        if hasTodoButton { count += 1 }
        return CGFloat(count) * 26.0 + 8.0
    }
}

// MARK: - 默认克制半透明 + 悬停唤醒专属物理特性微动效圆钮

enum HoverActionSurface {
    case onSelectedCard
    case onStandardCard
    case onImageTile
}

enum HoverActionKind: Equatable {
    case merge(isActive: Bool)
    case queue(isActive: Bool)
    case todo(isTodo: Bool, isCompleted: Bool)
    case alias
    case star(isPinned: Bool)
    case delete
    case ocr
    case openURL
}

/// 待办卡片左侧 Things 3 风格原生圆环复选框（独立高优先级点击热区，0.0px 尺寸零抖动）
struct TodoLeadingCheckboxButton: View {
    let isCompleted: Bool
    let isSelected: Bool
    let isHovered: Bool
    let action: () -> Void

    @State private var checkboxHovered: Bool = false

    var body: some View {
        ZStack {
            if isCompleted {
                Circle()
                    .fill(isSelected ? Color.white : Color(red: 0.06, green: 0.72, blue: 0.51))
                    .frame(width: 18, height: 18)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.white)
            } else {
                Circle()
                    .fill(checkboxHovered ? Color.accentColor.opacity(isSelected ? 0.22 : 0.10) : Color.clear)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isSelected
                                    ? Color.white.opacity(checkboxHovered ? 1.0 : 0.85)
                                    : Color.accentColor.opacity(checkboxHovered ? 0.95 : (isHovered ? 0.78 : 0.56)),
                                lineWidth: 1.65
                            )
                    )
            }
        }
        .frame(width: 24, height: 24)
        .contentShape(Circle())
        .scaleEffect(checkboxHovered ? 1.08 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.74), value: checkboxHovered)
        .animation(.spring(response: 0.22, dampingFraction: 0.76), value: isCompleted)
        .onHover { hovering in
            checkboxHovered = hovering
        }
        .highPriorityGesture(
            TapGesture().onEnded {
                action()
            }
        )
        .help(isCompleted ? "已完成 · 点击恢复未完成（⌘T）" : "点击标记待办已完成（⌘T）")
    }
}

private struct HoverActionSpringButtonStyle: ButtonStyle {
    let isHovered: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : (isHovered && !reduceMotion ? 1.08 : 1.0))
            .animation(.easeOut(duration: 0.13), value: isHovered)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }
}

struct HoverActionCircleButton: View {
    let symbolName: String
    var hoverSymbolName: String? = nil
    let size: CGFloat
    let iconSize: CGFloat
    var surface: HoverActionSurface = .onSelectedCard
    let kind: HoverActionKind
    let helpText: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false
    @State private var ringBurstScale: CGFloat = 0.6
    @State private var ringBurstOpacity: Double = 0.0

    private var effectiveSymbol: String {
        if isHovered, let hoverSymbolName {
            return hoverSymbolName
        }
        return symbolName
    }

    private var foregroundColor: Color {
        if isHovered {
            return .white
        }
        switch kind {
        case .star(let isPinned) where isPinned:
            return surface == .onSelectedCard
                ? Color(red: 1.0, green: 0.86, blue: 0.36)
                : Color.orange
        case .merge(let isActive) where isActive:
            return surface == .onSelectedCard ? .white : .green
        case .queue(let isActive) where isActive:
            return surface == .onSelectedCard ? .white : .accentColor
        case .todo(_, let isCompleted) where isCompleted:
            return surface == .onSelectedCard ? .white : Color(red: 0.06, green: 0.72, blue: 0.51)
        case .todo(let isTodo, _) where isTodo:
            return surface == .onSelectedCard ? .white : .accentColor
        default:
            switch surface {
            case .onSelectedCard, .onImageTile:
                return Color.white.opacity(0.95)
            case .onStandardCard:
                return Color.primary.opacity(0.76)
            }
        }
    }

    private var backgroundColor: Color {
        if isHovered {
            switch kind {
            case .merge:
                return Color(red: 0.15, green: 0.76, blue: 0.46).opacity(0.94)
            case .queue:
                return Color(red: 0.16, green: 0.54, blue: 0.98).opacity(0.94)
            case .todo(_, let isCompleted):
                return isCompleted
                    ? Color(red: 0.06, green: 0.72, blue: 0.51).opacity(0.94)
                    : Color(red: 0.12, green: 0.37, blue: 1.0).opacity(0.94)
            case .alias:
                return Color(red: 0.14, green: 0.52, blue: 0.98).opacity(0.94)
            case .star:
                return Color(red: 0.98, green: 0.64, blue: 0.12).opacity(0.94)
            case .delete:
                return Color(red: 0.94, green: 0.24, blue: 0.28).opacity(0.94)
            case .ocr:
                return Color(red: 0.12, green: 0.66, blue: 0.90).opacity(0.94)
            case .openURL:
                return Color(red: 0.14, green: 0.52, blue: 0.98).opacity(0.95)
            }
        }

        // 默认态：纯净半透明同色系磨砂圆钮（严格复刻红框视觉，不抢戏）
        switch surface {
        case .onSelectedCard:
            return Color.white.opacity(0.20)
        case .onStandardCard:
            return Color.primary.opacity(0.08)
        case .onImageTile:
            return Color.black.opacity(0.46)
        }
    }

    private var borderColor: Color {
        if isHovered {
            return Color.white.opacity(0.42)
        }
        switch surface {
        case .onSelectedCard:
            return Color.white.opacity(0.22)
        case .onStandardCard:
            return Color.primary.opacity(0.10)
        case .onImageTile:
            return Color.white.opacity(0.24)
        }
    }

    private var shadowColor: Color {
        guard isHovered else { return .clear }
        switch kind {
        case .merge:  return Color(red: 0.12, green: 0.72, blue: 0.42).opacity(0.38)
        case .queue:  return Color(red: 0.14, green: 0.50, blue: 0.96).opacity(0.38)
        case .todo(_, let isCompleted):
            return isCompleted ? Color.green.opacity(0.38) : Color.blue.opacity(0.38)
        case .alias:  return Color.blue.opacity(0.36)
        case .star:   return Color.orange.opacity(0.42)
        case .delete: return Color.red.opacity(0.42)
        case .ocr:    return Color.cyan.opacity(0.38)
        case .openURL: return Color.blue.opacity(0.42)
        }
    }

    // 针对队列 `+` 按钮的常驻棘轮旋入角（hover 旋至 90°，移出丝滑回 0°）
    private var steadyRotation: Double {
        guard !reduceMotion else { return 0 }
        if case .queue(let isActive) = kind, !isActive {
            return isHovered ? 90 : 0
        }
        return 0
    }

    var body: some View {
        Button {
            triggerClickHaloIfNeeded()
            action()
        } label: {
            animatedIcon
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(backgroundColor)
                        .overlay(
                            Circle()
                                .strokeBorder(borderColor, lineWidth: 0.65)
                        )
                )
                .overlay {
                    // 点亮收藏或勾选时的零占位光环涟漪
                    Circle()
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.2)
                        .scaleEffect(ringBurstScale)
                        .opacity(ringBurstOpacity)
                        .allowsHitTesting(false)
                }
                .shadow(color: shadowColor, radius: isHovered ? 5 : 0, y: isHovered ? 2 : 0)
        }
        .buttonStyle(HoverActionSpringButtonStyle(isHovered: isHovered, reduceMotion: reduceMotion))
        .help(helpText)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: steadyRotation)
        .onHover { hovering in
            if hovering && !isHovered {
                TactileFeedbackEngine.shared.perform(.hoverTick)
            }
            isHovered = hovering
        }
    }

    private var animatedIcon: some View {
        Image(systemName: effectiveSymbol)
            .font(.system(size: iconSize, weight: .medium))
            .foregroundStyle(foregroundColor)
            .rotationEffect(.degrees(steadyRotation))
    }

    private func triggerClickHaloIfNeeded() {
        guard !reduceMotion else { return }
        switch kind {
        case .star(let isPinned) where !isPinned:
            ringBurstScale = 0.85
            ringBurstOpacity = 0.95
            withAnimation(.easeOut(duration: 0.34)) {
                ringBurstScale = 1.65
                ringBurstOpacity = 0.0
            }
        case .merge(let isActive) where !isActive, .queue(let isActive) where !isActive:
            ringBurstScale = 0.88
            ringBurstOpacity = 0.85
            withAnimation(.easeOut(duration: 0.28)) {
                ringBurstScale = 1.50
                ringBurstOpacity = 0.0
            }
        default:
            break
        }
    }
}

// MARK: - 链接卡片左侧专属直达跃迁徽标（固定 42×42 零布局位移 + 悬停 45° 对角发射微动效）

private struct LinkLaunchKeyframes {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var scale: CGFloat = 1.0
}

private final class PassivePointingHandNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private struct PointingHandCursorOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> PassivePointingHandNSView {
        PassivePointingHandNSView()
    }

    func updateNSView(_ nsView: PassivePointingHandNSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

struct LinkLaunchLogoButton: View {
    let defaultSymbol: String
    let tint: Color
    let isSelectedCard: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false
    @State private var launchTrigger: Int = 0
    @State private var haloScale: CGFloat = 0.92
    @State private var haloOpacity: Double = 0.0

    private var activeSymbol: String {
        isHovered ? "arrow.up.right" : defaultSymbol
    }

    private var iconColor: Color {
        if isHovered {
            return isSelectedCard ? Color(nsColor: .controlAccentColor) : .white
        }
        return isSelectedCard ? .white : tint
    }

    private func triggerOpen() {
        if !reduceMotion {
            haloScale = 0.96
            haloOpacity = 0.92
            withAnimation(.easeOut(duration: 0.30)) {
                haloScale = 1.38
                haloOpacity = 0.0
            }
        }
        action()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(badgeBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            isHovered
                                ? Color.white.opacity(isSelectedCard ? 0.90 : 0.45)
                                : Color.clear,
                            lineWidth: 0.85
                        )
                )

            animatedSymbol
        }
        .frame(width: 42, height: 42)
        .scaleEffect(isHovered && !reduceMotion ? 1.08 : 1.0)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.2)
                .scaleEffect(haloScale)
                .opacity(haloOpacity)
                .allowsHitTesting(false)
        }
        .overlay {
            PointingHandCursorOverlay()
                .allowsHitTesting(false)
        }
        .shadow(
            color: isHovered
                ? (isSelectedCard ? Color.black.opacity(0.20) : tint.opacity(0.42))
                : .clear,
            radius: isHovered ? 6 : 0,
            y: isHovered ? 2 : 0
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .highPriorityGesture(
            TapGesture().onEnded {
                triggerOpen()
            }
        )
        .help("点击直接在浏览器中访问链接（或按 ⌘O / ⌘单击卡片）")
        .animation(.spring(response: 0.22, dampingFraction: 0.74), value: isHovered)
        .onHover { hovering in
            if hovering && !isHovered {
                launchTrigger &+= 1
                TactileFeedbackEngine.shared.perform(.hoverTick)
            }
            isHovered = hovering
        }
    }

    private var badgeBackground: AnyShapeStyle {
        if isHovered {
            if isSelectedCard {
                return AnyShapeStyle(Color.white.opacity(0.96))
            }
            return AnyShapeStyle(
                LinearGradient(
                    colors: [tint, Color(red: 0.12, green: 0.64, blue: 0.98)],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            )
        }
        return AnyShapeStyle(isSelectedCard ? Color.white.opacity(0.22) : tint.opacity(0.13))
    }

    private var animatedSymbol: some View {
        let isReduced = reduceMotion
        let symbolView = Image(systemName: activeSymbol)
            .font(.system(size: isHovered ? 17 : 18, weight: isHovered ? .semibold : .medium))
            .foregroundStyle(iconColor)
            .contentTransition(.symbolEffect(.replace.upUp.byLayer))

        return symbolView.keyframeAnimator(
            initialValue: LinkLaunchKeyframes(),
            trigger: launchTrigger,
            content: { content, val in
                content
                    .scaleEffect(isReduced ? 1.0 : val.scale)
                    .offset(
                        x: isReduced ? 0.0 : val.offsetX,
                        y: isReduced ? 0.0 : val.offsetY
                    )
            },
            keyframes: { _ in
                KeyframeTrack(\.offsetX) {
                    CubicKeyframe(-1.4, duration: 0.065)
                    SpringKeyframe(2.2, duration: 0.12, spring: .bouncy)
                    SpringKeyframe(0.0, duration: 0.16, spring: .smooth)
                }
                KeyframeTrack(\.offsetY) {
                    CubicKeyframe(1.4, duration: 0.065)
                    SpringKeyframe(-2.2, duration: 0.12, spring: .bouncy)
                    SpringKeyframe(0.0, duration: 0.16, spring: .smooth)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(0.90, duration: 0.065)
                    SpringKeyframe(1.15, duration: 0.12, spring: .bouncy)
                    SpringKeyframe(1.00, duration: 0.16, spring: .smooth)
                }
            }
        )
    }
}
