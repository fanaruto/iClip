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

    private var glassPalette: LiquidGlassPalette {
        LiquidGlassPalette(colorScheme: colorScheme, surfaceStyle: surfaceStyle, appearance: liquidGlassAppearance)
    }

    private var financeActions: [FinanceQuickAction] {
        minimalMode ? [] : ClipboardStore.shared.financeActions(for: item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                leadingThumbnail

                VStack(alignment: .leading, spacing: 4) {
                    Text(minimalMode ? item.rawContentPreview : item.primaryTitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 36)

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

            if !minimalMode && (isSelected || isHovered) && !financeActions.isEmpty {
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
                            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.88))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.white.opacity(0.20) : Color.primary.opacity(0.075))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 54)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(cardBackground)
        .overlay(cardBorder)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(isHovered && !isSelected ? 1.005 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isHovered)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: isSelected)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onSelect()
            }
        }
        .onTapGesture(count: 2) {
            onPaste(false)
        }
        .onDrag {
            ClipboardStore.shared.makeDragItemProvider(for: item)
        }
        .onTapGesture(count: 1) {
            if !minimalMode && NSEvent.modifierFlags.contains(.command) {
                onToggleMerge()
            } else {
                onSelect()
            }
        }
        .contextMenu {
            contextMenuItems
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
            iconBadge(symbol: "link", tint: .blue)

        case .text:
            iconBadge(symbol: "doc.text", tint: .indigo)
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
        HStack(spacing: 4) {
            if !minimalMode {
                HoverActionCircleButton(
                    symbolName: mergeRank != nil ? "checkmark.square.fill" : "square.stack",
                    size: 22,
                    iconSize: 10,
                    kind: .standard(activeColor: mergeRank != nil ? .green : nil),
                    helpText: mergeRank != nil ? "取消勾选合并" : "勾选加入合并粘贴（⌘单击 / ⌘M）",
                    action: onToggleMerge
                )

                HoverActionCircleButton(
                    symbolName: queueRank != nil ? "checkmark.circle.fill" : "plus.circle",
                    size: 22,
                    iconSize: 10,
                    kind: .standard(activeColor: queueRank != nil ? .accentColor : nil),
                    helpText: queueRank != nil ? "移出顺序粘贴队列" : "加入顺序粘贴队列（⌘K）",
                    action: onToggleQueue
                )
            }

            HoverActionCircleButton(
                symbolName: item.isPinned ? "star.fill" : "star",
                size: 22,
                iconSize: 10,
                kind: .star(isPinned: item.isPinned),
                helpText: item.isPinned ? "取消收藏" : "收藏",
                action: onTogglePin
            )

            HoverActionCircleButton(
                symbolName: "trash.fill",
                size: 22,
                iconSize: 10,
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

        if item.type == .link,
           let raw = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw) {
            Button("在浏览器中打开") {
                NSWorkspace.shared.open(url)
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

    private var glassPalette: LiquidGlassPalette {
        LiquidGlassPalette(colorScheme: colorScheme, surfaceStyle: surfaceStyle, appearance: liquidGlassAppearance)
    }

    private var semantic: SemanticSnapshot {
        ClipboardStore.shared.semanticSnapshot(for: item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                leadingThumbnail

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.primaryTitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 34)

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

            // 仅在选中或悬停且存在语义变换时浮现原生胶囊动作条，零常驻视觉噪音
            if (isSelected || isHovered) && !semantic.actions.isEmpty {
                transformActionStrip(actions: semantic.actions)
                    .padding(.leading, 54)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(cardBackground)
        .overlay(cardBorder)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(isHovered && !isSelected ? 1.005 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: isHovered)
        .animation(.spring(response: 0.2, dampingFraction: 0.86), value: isSelected)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onSelect()
            }
        }
        .onTapGesture(count: 2) {
            onPaste(false)
        }
        .onDrag {
            ClipboardStore.shared.makeDragItemProvider(for: item)
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .contextMenu {
            contextMenuItems
        }
    }

    // MARK: - 瞬时语义变换胶囊条

    private func transformActionStrip(actions: [TransformAction]) -> some View {
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
            Spacer(minLength: 0)
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
            if let kind = semantic.primaryKind, kind == .dirtyURL {
                iconBadge(symbol: "sparkles", tint: .teal)
            } else {
                iconBadge(symbol: "link", tint: .blue)
            }

        case .text:
            if let rgba = semantic.parsedColorRGBA {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a))
                    .frame(width: 42, height: 42)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)
            } else if let kind = semantic.primaryKind {
                iconBadge(symbol: kind.symbolName, tint: Color(nsColor: kind.tintColor))
            } else {
                iconBadge(symbol: "doc.text", tint: .indigo)
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
        HStack(spacing: 4) {
            HoverActionCircleButton(
                symbolName: item.isPinned ? "star.fill" : "star",
                size: 22,
                iconSize: 10,
                kind: .star(isPinned: item.isPinned),
                helpText: item.isPinned ? "取消收藏" : "收藏",
                action: onTogglePin
            )

            HoverActionCircleButton(
                symbolName: "trash.fill",
                size: 22,
                iconSize: 10,
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

        if item.type == .link,
           let raw = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw) {
            Button("在浏览器中打开") {
                NSWorkspace.shared.open(url)
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

// MARK: - 统一高对比悬停操作圆钮（带语义微动效与弹性按压反馈）

enum HoverActionKind {
    case star(isPinned: Bool)
    case delete
    case standard(activeColor: Color?)
}

private struct HoverActionSpringButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : (isHovered ? 1.14 : 1.0))
            .offset(y: isHovered && !configuration.isPressed ? -0.5 : 0)
            .animation(.spring(response: 0.24, dampingFraction: 0.58), value: isHovered)
            .animation(.spring(response: 0.16, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

struct HoverActionCircleButton: View {
    let symbolName: String
    let size: CGFloat
    let iconSize: CGFloat
    let kind: HoverActionKind
    let helpText: String
    let action: () -> Void

    @State private var isHovered: Bool = false

    private var foregroundColor: Color {
        switch kind {
        case .star(let isPinned):
            if isPinned {
                return Color(red: 1.0, green: 0.72, blue: 0.16)
            }
            return isHovered ? Color(red: 1.0, green: 0.86, blue: 0.42) : .white
        case .delete, .standard:
            return .white
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .star(let isPinned):
            if isHovered {
                return Color.black.opacity(isPinned ? 0.78 : 0.72)
            }
            return Color.black.opacity(0.58)
        case .delete:
            return isHovered ? Color.red.opacity(0.96) : Color.red.opacity(0.82)
        case .standard(let activeColor):
            if let activeColor {
                return activeColor.opacity(isHovered ? 0.98 : 0.88)
            }
            return Color.black.opacity(isHovered ? 0.74 : 0.58)
        }
    }

    private var glowColor: Color {
        guard isHovered else { return .clear }
        switch kind {
        case .star:
            return Color.orange.opacity(0.45)
        case .delete:
            return Color.red.opacity(0.52)
        case .standard(let activeColor):
            return (activeColor ?? Color.white).opacity(0.32)
        }
    }

    private var iconRotation: Angle {
        guard isHovered else { return .zero }
        switch kind {
        case .star:
            return .degrees(16)
        case .delete:
            return .degrees(-10)
        case .standard:
            return .zero
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .rotationEffect(iconRotation)
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .symbolEffect(.bounce, value: symbolName)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(backgroundColor)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    Color.white.opacity(isHovered ? 0.34 : 0.0),
                                    lineWidth: 0.75
                                )
                        )
                )
                .shadow(color: glowColor, radius: isHovered ? 5 : 0, y: isHovered ? 1.5 : 0)
        }
        .buttonStyle(HoverActionSpringButtonStyle(isHovered: isHovered))
        .help(helpText)
        .animation(.spring(response: 0.24, dampingFraction: 0.58), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
