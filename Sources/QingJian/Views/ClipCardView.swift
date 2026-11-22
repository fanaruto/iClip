#if ICLIP_EDITION_FLOW
import SwiftUI
import AppKit

/// 单条 iOS 风格剪贴板卡片
struct ClipCardView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let minimalMode: Bool
    let queueRank: Int?
    let mergeRank: Int?
    let surfaceStyle: PanelSurfaceStyle
    let liquidGlassAppearance: LiquidGlassAppearance
    let borderlessPanel: Bool
    let onSelect: () -> Void
    let onPaste: (Bool) -> Void
    let onCopyOnly: (Bool) -> Void
    let onToggleQueue: () -> Void
    let onToggleMerge: () -> Void
    let onExtractOCR: (Bool) -> Void
    let onApplyFinanceAction: (FinanceQuickAction, Bool) -> Void
    let onTogglePin: () -> Void
    let onSelectPinCategory: (PinCategory?) -> Void
    let onEditAlias: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered: Bool = false
    @State private var asyncThumbnail: NSImage? = nil
    @State private var lastTapUptime: TimeInterval = 0
    @State private var showCopiedInlineFlash: Bool = false

    private var glassPalette: LiquidGlassPalette {
        LiquidGlassPalette(colorScheme: colorScheme, surfaceStyle: surfaceStyle, appearance: liquidGlassAppearance)
    }

    private var financeActions: [FinanceQuickAction] {
        minimalMode ? [] : ClipboardStore.shared.financeActions(for: item)
    }

    private var hasLeadingVisual: Bool {
        item.type != .text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                if hasLeadingVisual {
                    leadingThumbnail
                }

                VStack(alignment: .leading, spacing: 5.5) {
                    Text(minimalMode ? item.rawContentPreview : item.primaryTitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineSpacing(2.5)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 42)

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
                                    .frame(width: 6, height: 6)
                                Text(cat.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(isSelected ? Color.white.opacity(0.95) : cat.dotColor)
                            }
                            Text("·")
                        }

                        Text(item.subtitleInfo)
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
                                .transition(.opacity)
                        }

                        Spacer(minLength: 4)

                        Text(item.relativeTimeText)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                }
                .overlay(alignment: .topTrailing) {
                    if isHovered {
                        hoverActions
                            .offset(y: -2)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    } else if !minimalMode, let mRank = mergeRank {
                        mergeBadge(rank: mRank)
                    } else if !minimalMode, let rank = queueRank {
                        queueBadge(rank: rank)
                    } else if index < 9 {
                        shortcutBadge
                    }
                }
            }

            if !minimalMode && !financeActions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(financeActions.enumerated()), id: \.element.id) { idx, action in
                            Button {
                                onApplyFinanceAction(action, true)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: action.symbolName)
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(action.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    if idx == 0 {
                                        Text("⇧↵")
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .opacity(0.75)
                                    }
                                }
                                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(isHovered ? 0.90 : 0.72))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.white.opacity(0.20) : Color.primary.opacity(isHovered ? 0.085 : 0.055))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.leading, hasLeadingVisual ? 58 : 0)
            }
        }
        .padding(.horizontal, hasLeadingVisual ? 12 : 14)
        .padding(.vertical, hasLeadingVisual ? 10 : 11)
        .background(cardBackground)
        .overlay(cardBorder)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(isHovered ? 1.012 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isHovered)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: isSelected)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onSelect()
            }
        }
        .onDrag {
            ClipboardStore.shared.makeDragItemProvider(for: item)
        }
        .onTapGesture {
            handleCardTap()
        }
        .contextMenu {
            contextMenuItems
        }
    }

    private func handleCardTap() {
        let now = ProcessInfo.processInfo.systemUptime
        let eventClickCount = (NSApp.currentEvent?.type == .leftMouseUp) ? (NSApp.currentEvent?.clickCount ?? 1) : 1
        let isDoubleTap = eventClickCount >= 2 || (now - lastTapUptime) <= min(NSEvent.doubleClickInterval, 0.32)
        lastTapUptime = isDoubleTap ? 0 : now

        if isDoubleTap {
            onPaste(false)
            return
        }
        if !minimalMode && NSEvent.modifierFlags.contains(.command) {
            onToggleMerge()
        } else if item.type == .link {
            onSelect()
            onCopyOnly(false)
            triggerCopiedInlineFlash()
        } else {
            onSelect()
        }
    }

    private func triggerCopiedInlineFlash() {
        withAnimation(.easeOut(duration: 0.14)) {
            showCopiedInlineFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.22)) {
                showCopiedInlineFlash = false
            }
        }
    }

    // MARK: - 左侧视觉预览

    @ViewBuilder
    private var leadingThumbnail: some View {
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
            LinkLaunchLogoButton(
                defaultSymbol: "link",
                tint: .blue,
                isSelectedCard: isSelected
            ) {
                ClipboardStore.shared.openLinkInBrowser(item)
            }

        case .text:
            EmptyView()
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

    private func mergeBadge(rank: Int) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: "checkmark")
                .font(.system(size: 8.5, weight: .bold))
            Text("\(rank)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.green)
        )
    }

    private func queueBadge(rank: Int) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: "list.number")
                .font(.system(size: 8.5, weight: .bold))
            Text("#\(rank)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(isSelected ? Color.white.opacity(0.28) : Color.accentColor)
        )
    }

    private var hoverActions: some View {
        let surface: HoverActionSurface = isSelected ? .onSelectedCard : .onStandardCard
        return HStack(spacing: 5) {
            if !minimalMode {
                HoverActionCircleButton(
                    symbolName: mergeRank != nil ? "checkmark.square.fill" : "square.stack",
                    size: 24,
                    iconSize: 11,
                    surface: surface,
                    kind: .merge(isActive: mergeRank != nil),
                    helpText: mergeRank != nil ? "取消勾选合并" : "勾选加入合并粘贴（⌘单击 / ⌘M）",
                    action: onToggleMerge
                )

                HoverActionCircleButton(
                    symbolName: queueRank != nil ? "checkmark.circle.fill" : "plus.circle",
                    size: 24,
                    iconSize: 11,
                    surface: surface,
                    kind: .queue(isActive: queueRank != nil),
                    helpText: queueRank != nil ? "移出顺序粘贴队列" : "加入顺序粘贴队列（⌘K）",
                    action: onToggleQueue
                )
            }

            HoverActionCircleButton(
                symbolName: item.isPinned ? "star.fill" : "star",
                size: 24,
                iconSize: 11,
                surface: surface,
                kind: .star(isPinned: item.isPinned),
                helpText: item.isPinned ? "取消收藏" : "收藏",
                action: onTogglePin
            )

            HoverActionCircleButton(
                symbolName: "trash",
                hoverSymbolName: "trash.fill",
                size: 24,
                iconSize: 11,
                surface: surface,
                kind: .delete,
                helpText: "删除此条记录",
                action: onDelete
            )
        }
    }

    // MARK: - 卡片背景与边框

    @ViewBuilder
    private var cardBackground: some View {
        if isSelected {
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
                .shadow(color: Color(nsColor: .controlAccentColor).opacity(0.28), radius: 6, y: 2)
        } else if item.isPinned {
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
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(glassPalette.clipCardFill(isHovered: isHovered))
        }
    }

    @ViewBuilder
    private var cardBorder: some View {
        if borderlessPanel && !item.isPinned {
            if surfaceStyle == .liquidGlass {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(glassPalette.clipCardStroke(isHovered: isHovered), lineWidth: 0.65)
            } else {
                EmptyView()
            }
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color.white.opacity(0.32)
                        : (item.isPinned
                            ? Color.orange.opacity(isHovered ? 0.62 : 0.45)
                            : glassPalette.clipCardStroke(isHovered: isHovered)),
                    lineWidth: (!isSelected && item.isPinned) ? 1.0 : 0.75
                )
        }
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("键入光标处（双击）") {
            onPaste(false)
        }

        Button("仅复制到剪贴板") {
            onCopyOnly(false)
        }

        if !ClipboardStore.shared.minimalModeEnabled && item.type == .image {
            Divider()
            Button("复制轻量瘦身图（JPEG）") {
                ClipboardStore.shared.pasteCompressedJPEG(for: item, shouldAutoPaste: false)
            }
            Button("复制圆角阴影样机图（PNG）") {
                ClipboardStore.shared.pasteAppleMockupImage(for: item, shouldAutoPaste: false)
            }
        }

        if !minimalMode {
            if !financeActions.isEmpty {
                Divider()
                ForEach(financeActions) { action in
                    Button("财务转换：\(action.title)") {
                        onApplyFinanceAction(action, true)
                    }
                }
            }

            Button(queueRank != nil ? "移出顺序队列（⌘K）" : "加入顺序队列（⌘K）") {
                onToggleQueue()
            }

            Button(mergeRank != nil ? "取消合并勾选（⌘M）" : "勾选加入合并粘贴（⌘M）") {
                onToggleMerge()
            }

            if item.type == .image {
                Divider()
                Button("提取图中文字并键入（⇧↵）") {
                    onExtractOCR(true)
                }
                Button("仅复制图中文字") {
                    onExtractOCR(false)
                }
            }
        }

        if item.type == .file {
            Button("键入文件路径（纯文本）") {
                onPaste(true)
            }
            if let first = item.filePaths?.first {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
                }
            }
        }

        if item.type == .link, ClipboardStore.shared.resolvedBrowserURL(for: item) != nil {
            Button("在浏览器中打开") {
                ClipboardStore.shared.openLinkInBrowser(item)
            }
        }

        Divider()

        Button(item.isPinned ? "取消收藏" : "收藏") {
            onTogglePin()
        }

        if !minimalMode {
            Menu("归入收藏分组") {
                ForEach(PinCategory.allCases) { cat in
                    Button {
                        onSelectPinCategory(cat)
                    } label: {
                        if item.pinCategory == cat {
                            Text("✓ \(cat.title)")
                        } else {
                            Text(cat.title)
                        }
                    }
                }
                if item.pinCategory != nil {
                    Divider()
                    Button("移除分组标签") {
                        onSelectPinCategory(nil)
                    }
                }
            }

            Button(item.customAlias != nil ? "修改备注标题..." : "设置备注标题（如：公司税号）...") {
                onEditAlias()
            }
        }

        Button("删除", role: .destructive) {
            onDelete()
        }
    }
}
#else
import SwiftUI
import AppKit

/// 单条 iOS 风格剪贴板卡片（搭载微秒级语义感知与瞬时变换胶囊条）
struct ClipCardView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let surfaceStyle: PanelSurfaceStyle
    let liquidGlassAppearance: LiquidGlassAppearance
    let borderlessPanel: Bool
    let onSelect: () -> Void
    let onPaste: (Bool) -> Void
    let onCopyOnly: (Bool) -> Void
    let onApplyTransform: (TransformAction, Bool) -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered: Bool = false
    @State private var asyncThumbnail: NSImage? = nil
    @State private var lastTapUptime: TimeInterval = 0
    @State private var showCopiedInlineFlash: Bool = false

    private var glassPalette: LiquidGlassPalette {
        LiquidGlassPalette(colorScheme: colorScheme, surfaceStyle: surfaceStyle, appearance: liquidGlassAppearance)
    }

    private var semantic: SemanticSnapshot {
        ClipboardStore.shared.semanticSnapshot(for: item)
    }

    private var hasLeadingVisual: Bool {
        if item.type == .text {
            return semantic.parsedColorRGBA != nil
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                if hasLeadingVisual {
                    leadingThumbnail
                }

                VStack(alignment: .leading, spacing: 5.5) {
                    Text(item.primaryTitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineSpacing(2.5)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 40)

                    HStack(spacing: 6) {
                        if item.isPinned {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.orange)
                        }

                        if let kind = semantic.primaryKind {
                            Text(kind.badgeTitle)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(
                                    isSelected
                                        ? Color.white.opacity(0.95)
                                        : (kind == .sensitiveSecret ? Color.orange : Color.accentColor)
                                )
                            Text("·")
                        }

                        Text(item.subtitleInfo)
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
                                .transition(.opacity)
                        }

                        Spacer(minLength: 4)

                        Text(item.relativeTimeText)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                }
                .overlay(alignment: .topTrailing) {
                    if isHovered {
                        hoverActions
                            .offset(y: -2)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    } else if index < 9 {
                        shortcutBadge
                    }
                }
            }

            // 常驻布局占位 + 悬停/选中亮度提振：彻底根除鼠标滑过卡片时的纵向伸缩抖动与横向撑宽
            if !semantic.actions.isEmpty {
                transformActionStrip(actions: semantic.actions)
                    .opacity((isSelected || isHovered) ? 1.0 : 0.78)
                    .padding(.leading, hasLeadingVisual ? (item.type == .text ? 48 : 54) : 0)
            }
        }
        .padding(.horizontal, hasLeadingVisual ? 12 : 14)
        .padding(.vertical, hasLeadingVisual ? 10 : 11)
        .background(cardBackground)
        .overlay(cardBorder)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(isHovered ? 1.012 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: isHovered)
        .animation(.spring(response: 0.2, dampingFraction: 0.86), value: isSelected)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onSelect()
            }
        }
        .onDrag {
            ClipboardStore.shared.makeDragItemProvider(for: item)
        }
        .onTapGesture {
            handleCardTap()
        }
        .contextMenu {
            contextMenuItems
        }
    }

    private func handleCardTap() {
        let now = ProcessInfo.processInfo.systemUptime
        let eventClickCount = (NSApp.currentEvent?.type == .leftMouseUp) ? (NSApp.currentEvent?.clickCount ?? 1) : 1
        let isDoubleTap = eventClickCount >= 2 || (now - lastTapUptime) <= min(NSEvent.doubleClickInterval, 0.32)
        lastTapUptime = isDoubleTap ? 0 : now

        if isDoubleTap {
            onPaste(false)
            return
        }
        if item.type == .link {
            onSelect()
            onCopyOnly(false)
            triggerCopiedInlineFlash()
        } else {
            onSelect()
        }
    }

    private func triggerCopiedInlineFlash() {
        withAnimation(.easeOut(duration: 0.14)) {
            showCopiedInlineFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.22)) {
                showCopiedInlineFlash = false
            }
        }
    }

    // MARK: - 瞬时语义变换胶囊条

    private func transformActionStrip(actions: [TransformAction]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
                    Button {
                        onApplyTransform(action, true)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: action.symbolName)
                                .font(.system(size: 10, weight: .semibold))
                            Text(action.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Text(idx == 0 ? "⇧↵" : "⌃\(idx + 1)")
                                .font(.system(size: 9.5, weight: .semibold))
                                .opacity(0.72)
                        }
                        .foregroundStyle(chipForeground(for: action))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(chipBackground(for: action))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("点击直接执行「\(action.title)」并键入光标处")
                }
            }
        }
    }

    private func chipForeground(for action: TransformAction) -> Color {
        if isSelected {
            return .white
        }
        return action.isSecurityAction ? Color.orange : Color.primary.opacity(0.88)
    }

    private func chipBackground(for action: TransformAction) -> Color {
        if isSelected {
            return action.isSecurityAction ? Color.orange.opacity(0.38) : Color.white.opacity(0.20)
        }
        return action.isSecurityAction ? Color.orange.opacity(0.14) : Color.primary.opacity(0.075)
    }

    // MARK: - 左侧视觉预览

    @ViewBuilder
    private var leadingThumbnail: some View {
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
            let isDirty = (semantic.primaryKind == .dirtyURL)
            LinkLaunchLogoButton(
                defaultSymbol: isDirty ? "sparkles" : "link",
                tint: isDirty ? .teal : .blue,
                isSelectedCard: isSelected
            ) {
                ClipboardStore.shared.openLinkInBrowser(item)
            }

        case .text:
            if let rgba = semantic.parsedColorRGBA {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a))
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)
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
            HoverActionCircleButton(
                symbolName: item.isPinned ? "star.fill" : "star",
                size: 24,
                iconSize: 11,
                surface: surface,
                kind: .star(isPinned: item.isPinned),
                helpText: item.isPinned ? "取消收藏" : "收藏",
                action: onTogglePin
            )

            HoverActionCircleButton(
                symbolName: "trash",
                hoverSymbolName: "trash.fill",
                size: 24,
                iconSize: 11,
                surface: surface,
                kind: .delete,
                helpText: "删除此条记录",
                action: onDelete
            )
        }
    }

    // MARK: - 卡片背景与边框

    @ViewBuilder
    private var cardBackground: some View {
        if isSelected {
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
                .shadow(color: Color(nsColor: .controlAccentColor).opacity(0.28), radius: 6, y: 2)
        } else if item.isPinned {
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
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(glassPalette.clipCardFill(isHovered: isHovered))
        }
    }

    @ViewBuilder
    private var cardBorder: some View {
        if borderlessPanel && !item.isPinned {
            if surfaceStyle == .liquidGlass {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(glassPalette.clipCardStroke(isHovered: isHovered), lineWidth: 0.65)
            } else {
                EmptyView()
            }
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color.white.opacity(0.32)
                        : (item.isPinned
                            ? Color.orange.opacity(isHovered ? 0.62 : 0.45)
                            : glassPalette.clipCardStroke(isHovered: isHovered)),
                    lineWidth: (!isSelected && item.isPinned) ? 1.0 : 0.75
                )
        }
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("键入光标处（双击）") {
            onPaste(false)
        }

        Button("仅复制到剪贴板") {
            onCopyOnly(false)
        }

        if !ClipboardStore.shared.minimalModeEnabled && item.type == .image {
            Divider()
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

        if item.type == .file {
            Button("键入文件路径（纯文本）") {
                onPaste(true)
            }
            if let first = item.filePaths?.first {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
                }
            }
        }

        if item.type == .link, ClipboardStore.shared.resolvedBrowserURL(for: item) != nil {
            Button("在浏览器中打开") {
                ClipboardStore.shared.openLinkInBrowser(item)
            }
        }

        Divider()

        Button(item.isPinned ? "取消收藏" : "收藏") {
            onTogglePin()
        }

        Button("删除", role: .destructive) {
            onDelete()
        }
    }
}
#endif

// MARK: - 默认克制半透明 + 悬停唤醒专属物理特性微动效圆钮

enum HoverActionSurface {
    case onSelectedCard
    case onStandardCard
    case onImageTile
}

enum HoverActionKind: Equatable {
    case merge(isActive: Bool)
    case queue(isActive: Bool)
    case star(isPinned: Bool)
    case delete
    case ocr
}

private struct IconMotionKeyframes {
    var rotation: Double = 0
    var scaleX: CGFloat = 1.0
    var scaleY: CGFloat = 1.0
    var offsetY: CGFloat = 0
}

private struct HoverActionSpringButtonStyle: ButtonStyle {
    let isHovered: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : (isHovered && !reduceMotion ? 1.12 : 1.0))
            .animation(.spring(response: 0.22, dampingFraction: 0.66), value: isHovered)
            .animation(.spring(response: 0.14, dampingFraction: 0.72), value: configuration.isPressed)
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
    @State private var hoverTrigger: Int = 0
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
            case .star:
                return Color(red: 0.98, green: 0.64, blue: 0.12).opacity(0.94)
            case .delete:
                return Color(red: 0.94, green: 0.24, blue: 0.28).opacity(0.94)
            case .ocr:
                return Color(red: 0.12, green: 0.66, blue: 0.90).opacity(0.94)
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
        case .star:   return Color.orange.opacity(0.42)
        case .delete: return Color.red.opacity(0.42)
        case .ocr:    return Color.cyan.opacity(0.38)
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
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isHovered)
        .animation(.spring(response: 0.26, dampingFraction: 0.66), value: steadyRotation)
        .onHover { hovering in
            if hovering && !isHovered {
                hoverTrigger &+= 1
                TactileFeedbackEngine.shared.perform(.hoverTick)
            }
            isHovered = hovering
        }
    }

    private var animatedIcon: some View {
        let isReduced = reduceMotion
        let currentKind = kind
        let baseIcon = Image(systemName: effectiveSymbol)
            .font(.system(size: iconSize, weight: .medium))
            .foregroundStyle(foregroundColor)
            .rotationEffect(.degrees(steadyRotation))
            .symbolEffect(.bounce, value: symbolName)

        return baseIcon.keyframeAnimator(
            initialValue: IconMotionKeyframes(),
            trigger: hoverTrigger,
            content: { content, val in
                content
                    .scaleEffect(x: isReduced ? 1.0 : val.scaleX, y: isReduced ? 1.0 : val.scaleY)
                    .rotationEffect(.degrees(isReduced ? 0.0 : val.rotation))
                    .offset(y: isReduced ? 0.0 : val.offsetY)
            },
            keyframes: { _ in
                KeyframeTrack(\.rotation) {
                    if currentKind == .delete {
                        CubicKeyframe(-13.0, duration: 0.07)
                        CubicKeyframe(10.0, duration: 0.08)
                        CubicKeyframe(-6.0, duration: 0.08)
                        SpringKeyframe(0.0, duration: 0.14, spring: .smooth)
                    } else if case .star = currentKind {
                        CubicKeyframe(20.0, duration: 0.12)
                        SpringKeyframe(0.0, duration: 0.24, spring: .bouncy)
                    } else {
                        LinearKeyframe(0.0, duration: 0.01)
                    }
                }
                KeyframeTrack(\.offsetY) {
                    if case .star = currentKind {
                        CubicKeyframe(-2.2, duration: 0.12)
                        SpringKeyframe(0.0, duration: 0.22, spring: .bouncy)
                    } else if currentKind == .delete {
                        CubicKeyframe(-1.0, duration: 0.08)
                        SpringKeyframe(0.0, duration: 0.16, spring: .smooth)
                    } else {
                        LinearKeyframe(0.0, duration: 0.01)
                    }
                }
                KeyframeTrack(\.scaleX) {
                    if case .merge = currentKind {
                        SpringKeyframe(1.12, duration: 0.10, spring: .snappy)
                        SpringKeyframe(0.95, duration: 0.13, spring: .bouncy)
                        SpringKeyframe(1.00, duration: 0.13, spring: .smooth)
                    } else if currentKind == .ocr {
                        CubicKeyframe(1.22, duration: 0.09)
                        CubicKeyframe(0.93, duration: 0.09)
                        SpringKeyframe(1.00, duration: 0.15, spring: .snappy)
                    } else if case .star = currentKind {
                        CubicKeyframe(1.18, duration: 0.12)
                        SpringKeyframe(1.00, duration: 0.22, spring: .bouncy)
                    } else if case .queue(let isActive) = currentKind {
                        SpringKeyframe(isActive ? 1.15 : 1.08, duration: 0.12, spring: .bouncy)
                        SpringKeyframe(1.00, duration: 0.15, spring: .smooth)
                    } else {
                        LinearKeyframe(1.00, duration: 0.01)
                    }
                }
                KeyframeTrack(\.scaleY) {
                    if case .merge = currentKind {
                        SpringKeyframe(0.80, duration: 0.10, spring: .snappy)
                        SpringKeyframe(1.12, duration: 0.13, spring: .bouncy)
                        SpringKeyframe(1.00, duration: 0.13, spring: .smooth)
                    } else if currentKind == .ocr {
                        CubicKeyframe(1.22, duration: 0.09)
                        CubicKeyframe(0.93, duration: 0.09)
                        SpringKeyframe(1.00, duration: 0.15, spring: .snappy)
                    } else if case .star = currentKind {
                        CubicKeyframe(1.18, duration: 0.12)
                        SpringKeyframe(1.00, duration: 0.22, spring: .bouncy)
                    } else if case .queue(let isActive) = currentKind {
                        SpringKeyframe(isActive ? 1.15 : 1.08, duration: 0.12, spring: .bouncy)
                        SpringKeyframe(1.00, duration: 0.15, spring: .smooth)
                    } else {
                        LinearKeyframe(1.00, duration: 0.01)
                    }
                }
            }
        )
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

private struct LinkLaunchSpringButtonStyle: ButtonStyle {
    let isHovered: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : (isHovered && !reduceMotion ? 1.08 : 1.0))
            .animation(.spring(response: 0.22, dampingFraction: 0.66), value: isHovered)
            .animation(.spring(response: 0.14, dampingFraction: 0.72), value: configuration.isPressed)
    }
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

    var body: some View {
        let baseButton = Button {
            if !reduceMotion {
                haloScale = 0.96
                haloOpacity = 0.92
                withAnimation(.easeOut(duration: 0.30)) {
                    haloScale = 1.38
                    haloOpacity = 0.0
                }
            }
            action()
        } label: {
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
        }
        .buttonStyle(LinkLaunchSpringButtonStyle(isHovered: isHovered, reduceMotion: reduceMotion))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .help("点击直接在浏览器中访问链接")
        .animation(.spring(response: 0.22, dampingFraction: 0.74), value: isHovered)
        .onHover { hovering in
            if hovering && !isHovered {
                launchTrigger &+= 1
                TactileFeedbackEngine.shared.perform(.hoverTick)
            }
            isHovered = hovering
        }

        if #available(macOS 15.0, *) {
            baseButton.pointerStyle(.link)
        } else {
            baseButton
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
