import SwiftUI
import AppKit

/// iOS 相册风格的图片网格卡片（3 列一行排列，Apple TV 3D 视差卡片质感；空格或二段 Force Touch 触发系统官方大屏预览）
struct ClipImageGridTile: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    var cardSkin: CardSkinStyle = .nativeApple
    let onSelect: () -> Void
    var onHoverSelect: (() -> Bool)? = nil
    let onPaste: () -> Void
    let onCopyOnly: () -> Void
    var onExtractOCR: ((Bool) -> Void)? = nil
    let onTogglePin: () -> Void
    var onToggleTodo: (() -> Void)? = nil
    var onRemoveTodo: (() -> Void)? = nil
    var onEditAlias: (() -> Void)? = nil
    var onOpenQuickLook: (() -> Void)? = nil
    var onOpenOCRBigBang: (() -> Void)? = nil
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered: Bool = false
    @State private var showHoverActions: Bool = false
    @State private var hoverDwellGate = HoverActionsDwellGate()
    @State private var hoverDwellTask: Task<Void, Never>? = nil
    @State private var hoverNorm: CGPoint = .zero
    @State private var asyncThumbnail: NSImage? = nil
    @State private var lastTapUptime: TimeInterval = 0
    @State private var showCopiedInlineFlash: Bool = false
    @State private var copiedFlashGate = InlineFlashGate()
    @State private var copiedFlashTask: Task<Void, Never>? = nil
    @State private var isDeepPressFlat: Bool = false

    var body: some View {
        let renderMeta = ClipboardStore.shared.cardRenderMeta(for: item)
        let applySpatialParallax = (cardSkin == .spatialGlass && isHovered && !isDeepPressFlat && !reduceMotion)
        let pnx = applySpatialParallax ? hoverNorm.x : 0
        let pny = applySpatialParallax ? hoverNorm.y : 0
        ZStack(alignment: .bottom) {
            // 缩略图主体（原生皮肤保持静止零开销；立体光影皮肤启用克制 1.045x 与 ±2pt 内视差）
            Color.clear
                .overlay {
                    if let nsImage = ClipboardStore.shared.cachedThumbnail(for: item) ?? asyncThumbnail {
                        let veilImg = ClipboardStore.shared.maskSensitivePreviews && !isSelected && !isHovered && renderMeta.detectedSensitiveKind != nil
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .scaleEffect(applySpatialParallax ? 1.045 : 1.0)
                            .offset(x: -pnx * 2.0, y: -pny * 1.8)
                            .animation(.spring(response: 0.22, dampingFraction: 0.88), value: isDeepPressFlat)
                            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: cardSkin)
                            .blur(radius: veilImg ? 11 : 0)
                            .overlay {
                                if veilImg {
                                    ZStack {
                                        Color.black.opacity(0.24)
                                        HStack(spacing: 3.5) {
                                            Image(systemName: "lock.shield.fill")
                                                .font(.system(size: 10, weight: .semibold))
                                            Text("隐私雾化")
                                                .font(.system(size: 10, weight: .semibold))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.black.opacity(0.54)))
                                    }
                                }
                            }
                    } else {
                        ZStack {
                            Color.primary.opacity(0.06)
                            Image(systemName: "photo")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .clipped()
                .task(id: item.id) {
                    if ClipboardStore.shared.cachedThumbnail(for: item) != nil {
                        return
                    }
                    if let loaded = await ClipboardStore.shared.loadThumbnail(for: item), !Task.isCancelled {
                        asyncThumbnail = loaded
                    }
                }

            // 底部渐变信息条（像素尺寸 / 时间）
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.56)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 32)
            .allowsHitTesting(false)

            HStack(spacing: 4) {
                if item.isPinned {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.orange)
                }
                if showCopiedInlineFlash {
                    Text("✓ 已复制")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.green)
                } else if let alias = item.customAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
                    Text(alias)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                } else if let w = item.imageWidth, let h = item.imageHeight {
                    Text("\(w)×\(h)")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
                    Text(item.relativeTimeText)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                }
                Spacer(minLength: 0)
                if !ClipboardStore.shared.minimalModeEnabled {
                    let hasQR = !(item.qrCodePayload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    let isTOTPQR = TOTPAuthenticator.isTOTPURI(item.qrCodePayload)
                    let hasOCR = !(item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    if hasQR || hasOCR {
                        Image(systemName: isTOTPQR ? "key.viewfinder" : (hasQR ? "qrcode.viewfinder" : "text.viewfinder"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.95))
                    }
                }
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 7)
            .padding(.bottom, 5)
            .offset(x: pnx * 1.4, y: pny * 1.4)
            .allowsHitTesting(false)
        }
        .frame(height: 98)
        .overlay {
            CardSpatialSpecularLayer(
                cornerRadius: 13,
                cardSkin: cardSkin,
                isHovered: isHovered,
                isSelected: isSelected,
                pointerNorm: hoverNorm
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(alignment: .topLeading) {
            if !showHoverActions && index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color(nsColor: .controlAccentColor) : Color.black.opacity(0.52))
                    )
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showHoverActions {
                HStack(spacing: 4) {
                    if !ClipboardStore.shared.minimalModeEnabled, (onExtractOCR != nil || onOpenOCRBigBang != nil) {
                        let hasQR = !(item.qrCodePayload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        let isTOTPQR = TOTPAuthenticator.isTOTPURI(item.qrCodePayload)
                        HoverActionCircleButton(
                            symbolName: isTOTPQR ? "key.viewfinder" : (hasQR ? "qrcode.viewfinder" : "text.viewfinder"),
                            size: 22,
                            iconSize: 10,
                            surface: .onImageTile,
                            kind: .ocr,
                            helpText: isTOTPQR ? "实时算出 2FA 动态验证码并键入（⇧↵）" : (hasQR ? "提取二维码内容并键入（⇧↵）" : "大图原位大爆炸选字（OCR）"),
                            action: {
                                if !hasQR, let onOpenOCRBigBang {
                                    onOpenOCRBigBang()
                                } else {
                                    onExtractOCR?(true)
                                }
                            }
                        )
                    }

                    if !ClipboardStore.shared.minimalModeEnabled, let onToggleTodo {
                        HoverActionCircleButton(
                            symbolName: item.isTodoCompleted ? "checkmark.circle.fill" : (item.isTodo ? "circle.inset.filled" : "checkmark.circle"),
                            size: 22,
                            iconSize: 10,
                            surface: .onImageTile,
                            kind: .todo(isTodo: item.isTodo, isCompleted: item.isTodoCompleted),
                            helpText: item.isTodoCompleted ? "已完成 · 点击恢复未完成（⌘T）" : (item.isTodo ? "标记待办已完成（⌘T）" : "加入待办清单（⌘T）"),
                            action: onToggleTodo
                        )
                    }

                    HoverActionCircleButton(
                        symbolName: item.isPinned ? "star.fill" : "star",
                        size: 22,
                        iconSize: 10,
                        surface: .onImageTile,
                        kind: .star(isPinned: item.isPinned),
                        helpText: item.isPinned ? "取消收藏" : "收藏",
                        action: onTogglePin
                    )

                    HoverActionCircleButton(
                        symbolName: "trash",
                        hoverSymbolName: "trash.fill",
                        size: 22,
                        iconSize: 10,
                        surface: .onImageTile,
                        kind: .delete,
                        helpText: "删除图片",
                        action: onDelete
                    )
                }
                .padding(5)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
            } else if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color(nsColor: .controlAccentColor)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.24), radius: 3, y: 1)
                    .padding(5)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .overlay {
            let idleStrokeColor: Color = {
                if item.isPinned {
                    return Color.orange.opacity(isHovered ? 0.92 : 0.72)
                }
                if cardSkin == .spatialGlass && isHovered {
                    return Color.white.opacity(colorScheme == .dark ? 0.44 : 0.86)
                }
                return isHovered ? Color.white.opacity(0.75) : Color.primary.opacity(0.10)
            }()
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        idleStrokeColor,
                        lineWidth: item.isPinned ? 1.5 : (isHovered ? 1.15 : 0.75)
                    )
                    .opacity(isSelected ? 0 : 1)

                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.84), lineWidth: 1.0)
                        .padding(2.0)

                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2.2)
                }
                .opacity(isSelected ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.10), value: isSelected)
        }
        .modifier(
            AppleTVPhysicalCardModifier(
                itemID: item.id,
                surfaceKind: .imageTile,
                cardSkin: cardSkin,
                isHovered: isHovered,
                isSelected: isSelected,
                pointerNorm: hoverNorm,
                trailingActionWidth: ClipCardLayoutMetrics.imageTileTrailingActionWidth(
                    hasOCRButton: !ClipboardStore.shared.minimalModeEnabled && (onExtractOCR != nil || onOpenOCRBigBang != nil),
                    hasTodoButton: !ClipboardStore.shared.minimalModeEnabled && onToggleTodo != nil
                ),
                bottomExclusionHeight: 0,
                onHoverEnterSelect: {
                    let allowed = onHoverSelect?() ?? {
                        onSelect()
                        return true
                    }()
                    if allowed {
                        beginTileHover()
                    }
                    return allowed
                },
                onHoverEnded: {
                    endTileHover()
                },
                onResetHoverFromHide: {
                    endTileHover()
                    if isDeepPressFlat {
                        isDeepPressFlat = false
                    }
                },
                onPointerNormChange: { newNorm in
                    guard cardSkin == .spatialGlass && !isDeepPressFlat else {
                        if hoverNorm != .zero {
                            hoverNorm = .zero
                        }
                        return
                    }
                    if hoverNorm != newNorm {
                        hoverNorm = newNorm
                    }
                },
                onDeepPressActiveChanged: { active in
                    if isDeepPressFlat != active {
                        isDeepPressFlat = active
                    }
                    if active && hoverNorm != .zero {
                        hoverNorm = .zero
                    }
                },
                onDeepPressPreview: {
                    onSelect()
                    onOpenQuickLook?()
                }
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onChange(of: cardSkin) { _, newSkin in
            if newSkin == .nativeApple && hoverNorm != .zero {
                hoverNorm = .zero
            }
        }
        .onDrag {
            ClipboardStore.shared.makeDragItemProvider(for: item)
        }
        .onTapGesture {
            let suppressed = ForceTouchSuppressionRegistry.consumeSuppressionIfNeeded(for: item.id)
            let now = ProcessInfo.processInfo.systemUptime
            let clickCount = (NSApp.currentEvent?.type == .leftMouseUp) ? (NSApp.currentEvent?.clickCount ?? 1) : 1
            let mode = ClipboardStore.shared.cardClickPasteMode
            let effectiveClickCount = CardClickGestureResolver.effectiveClickCount(
                mode: mode,
                eventClickCount: clickCount,
                elapsedSinceLastTap: now - lastTapUptime,
                maxInterval: min(NSEvent.doubleClickInterval, 0.32)
            )
            let outcome = CardClickGestureResolver.resolve(
                mode: mode,
                clickCount: effectiveClickCount,
                modifiers: NSEvent.modifierFlags,
                isLink: false,
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
            case .paste:
                if !isHovered { isHovered = true }
                onSelect()
                onPaste()
            case .copyOnly:
                if !isHovered { isHovered = true }
                onSelect()
                onCopyOnly()
                copiedFlashTask?.cancel()
                let gen = copiedFlashGate.trigger()
                withAnimation(.easeOut(duration: 0.14)) { showCopiedInlineFlash = true }
                copiedFlashTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, copiedFlashGate.completeIfCurrent(generation: gen) else { return }
                    copiedFlashTask = nil
                    withAnimation(.easeOut(duration: 0.2)) { showCopiedInlineFlash = false }
                }
            }
        }
        .contextMenu {
            let clickMode = ClipboardStore.shared.cardClickPasteMode
            Button(clickMode == .singleClick ? "键入光标处（单击）" : "键入光标处（双击）") {
                onPaste()
            }
            Button(clickMode == .singleClick ? "仅复制到剪贴板（⌥单击 / ⌘C）" : "仅复制到剪贴板（单击 / ⌘C）") {
                onCopyOnly()
            }
            if let onOpenQuickLook {
                Button("全图大屏预览（Space / 重按）") {
                    onOpenQuickLook()
                }
            }
            if !ClipboardStore.shared.minimalModeEnabled, let onOpenOCRBigBang {
                Button("大爆炸原位选字（OCR）") {
                    onOpenOCRBigBang()
                }
            }
            Button("在访达中显示（⌘O）") {
                _ = ClipboardStore.shared.openItemExternally(item)
            }
            if !ClipboardStore.shared.minimalModeEnabled {
                Divider()
                if let onExtractOCR {
                    if let qr = item.qrCodePayload?.trimmingCharacters(in: .whitespacesAndNewlines), !qr.isEmpty {
                        if ClipboardStore.isValidWebURL(qr) {
                            Button("打开图中二维码链接") {
                                ClipboardStore.shared.openImageQRCodeURLIfAvailable(item)
                            }
                        }
                        Button("提取二维码内容并键入（⇧↵）") {
                            onExtractOCR(true)
                        }
                        Button("仅复制二维码内容") {
                            onExtractOCR(false)
                        }
                    } else {
                        Button("提取全部文字并键入（⇧↵）") {
                            onExtractOCR(true)
                        }
                        Button("仅复制图中全部文字") {
                            onExtractOCR(false)
                        }
                    }
                    Divider()
                }
                Button("隐私智能打码粘贴（自动遮盖号/码/密钥）") {
                    ClipboardStore.shared.pastePrivacyRedactedImage(for: item, shouldAutoPaste: true)
                }
                Button("复制隐私打码图（PNG）") {
                    ClipboardStore.shared.pastePrivacyRedactedImage(for: item, shouldAutoPaste: false)
                }
                Button("轻量瘦身粘贴（转 JPEG 省 80%+ 体积）") {
                    ClipboardStore.shared.pasteCompressedJPEG(for: item, shouldAutoPaste: false)
                }
                Button("圆角阴影加壳（生成苹果风样机图）") {
                    ClipboardStore.shared.pasteAppleMockupImage(for: item, shouldAutoPaste: false)
                }
            }
            if !ClipboardStore.shared.minimalModeEnabled, let onToggleTodo {
                Button(!item.isTodo ? "加入待办清单（⌘T）" : (item.isPendingTodo ? "✓ 标记待办已完成（⌘T）" : "恢复为未完成待办（⌘T）")) {
                    onToggleTodo()
                }
                if item.isTodo, let onRemoveTodo {
                    Button("移出待办清单") {
                        onRemoveTodo()
                    }
                }
            }
            Button(item.isPinned ? "取消收藏" : "收藏") {
                onTogglePin()
            }
            if !ClipboardStore.shared.minimalModeEnabled, let onEditAlias {
                Button(item.customAlias != nil ? "修改备注标题（⌘R）..." : "设置备注标题（⌘R）...") {
                    onEditAlias()
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                onDelete()
            }
        }
        .zIndex(isHovered ? 30 : (isSelected ? 5 : 0))
        .onDisappear {
            hoverDwellTask?.cancel()
            hoverDwellTask = nil
            hoverDwellGate.endHover()
            showHoverActions = false
            isHovered = false
            copiedFlashTask?.cancel()
            copiedFlashTask = nil
            copiedFlashGate.cancel()
            showCopiedInlineFlash = false
        }
    }

    private func beginTileHover() {
        if !isHovered {
            isHovered = true
        }
        guard !showHoverActions else { return }
        hoverDwellTask?.cancel()
        let gen = hoverDwellGate.beginHover()
        hoverDwellTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 42_000_000)
            guard !Task.isCancelled, hoverDwellGate.shouldReveal(for: gen) else { return }
            hoverDwellTask = nil
            withAnimation(.spring(response: 0.18, dampingFraction: 0.88)) {
                showHoverActions = true
            }
        }
    }

    private func endTileHover() {
        hoverDwellTask?.cancel()
        hoverDwellTask = nil
        hoverDwellGate.endHover()
        if showHoverActions {
            withAnimation(.easeOut(duration: 0.12)) {
                showHoverActions = false
            }
        }
        if isHovered {
            isHovered = false
        }
        if hoverNorm != .zero {
            hoverNorm = .zero
        }
    }
}
