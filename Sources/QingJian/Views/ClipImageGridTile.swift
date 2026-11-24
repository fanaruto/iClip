import SwiftUI
import AppKit

/// iOS 相册风格的图片网格卡片（3 列一行排列，Apple TV 3D 视差卡片质感；空格或二段 Force Touch 触发系统官方大屏预览）
struct ClipImageGridTile: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
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
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false
    @State private var hoverNorm: CGPoint = .zero
    @State private var tileSize: CGSize = CGSize(width: 124, height: 98)
    @State private var asyncThumbnail: NSImage? = nil
    @State private var lastTapUptime: TimeInterval = 0
    @State private var showCopiedInlineFlash: Bool = false

    var body: some View {
        let pnx = (isHovered && !reduceMotion) ? hoverNorm.x : 0
        let pny = (isHovered && !reduceMotion) ? hoverNorm.y : 0
        ZStack(alignment: .bottom) {
            // 缩略图主体（Apple TV 底层视差微放大 + 光标反向纵深位移，零 I/O 缓存读取）
            Color.clear
                .overlay {
                    if let nsImage = ClipboardStore.shared.cachedThumbnail(for: item) ?? asyncThumbnail {
                        let veilImg = ClipboardStore.shared.maskSensitivePreviews && !isSelected && !isHovered && item.detectedSensitiveKind != nil
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .scaleEffect(isHovered && !reduceMotion ? 1.07 : 1.0)
                            .offset(x: -pnx * 3.0, y: -pny * 2.8)
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
            .offset(x: pnx * 2.2, y: pny * 2.2)
            .allowsHitTesting(false)
        }
        .frame(height: 98)
        .overlay(alignment: .topLeading) {
            if !isHovered && index < 9 {
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
            if isHovered {
                HStack(spacing: 4) {
                    if !ClipboardStore.shared.minimalModeEnabled, let onExtractOCR {
                        let hasQR = !(item.qrCodePayload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        let isTOTPQR = TOTPAuthenticator.isTOTPURI(item.qrCodePayload)
                        HoverActionCircleButton(
                            symbolName: isTOTPQR ? "key.viewfinder" : (hasQR ? "qrcode.viewfinder" : "text.viewfinder"),
                            size: 22,
                            iconSize: 10,
                            surface: .onImageTile,
                            kind: .ocr,
                            helpText: isTOTPQR ? "实时算出 2FA 动态验证码并键入（⇧↵）" : (hasQR ? "提取二维码内容并键入（⇧↵）" : "提取图中文字并键入（⇧↵）"),
                            action: { onExtractOCR(true) }
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
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.88), lineWidth: 3.6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        item.isPinned
                            ? Color.orange.opacity(isHovered ? 0.92 : 0.72)
                            : (isHovered ? Color.white.opacity(0.75) : Color.primary.opacity(0.1)),
                        lineWidth: item.isPinned ? 1.5 : (isHovered ? 1.2 : 0.75)
                    )
            }
        }
        .modifier(
            AppleTVPhysicalCardModifier(
                itemID: item.id,
                surfaceKind: .imageTile,
                isHovered: isHovered,
                isSelected: isSelected,
                pointerNorm: hoverNorm,
                trailingActionWidth: {
                    var cnt = 2
                    if !ClipboardStore.shared.minimalModeEnabled {
                        if onExtractOCR != nil { cnt += 1 }
                        if onToggleTodo != nil { cnt += 1 }
                    }
                    return CGFloat(cnt) * 25.0 + 10.0
                }(),
                bottomChipHeight: 0,
                onResetHoverFromHide: {
                    if isHovered {
                        isHovered = false
                        hoverNorm = .zero
                    }
                },
                onDeepPressPreview: {
                    onSelect()
                    onOpenQuickLook?()
                }
            )
        )
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: isHovered)
        .animation(.spring(response: 0.2, dampingFraction: 0.88), value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        tileSize = geo.size
                    }
                    .onChange(of: geo.size) { _, newSize in
                        tileSize = newSize
                    }
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let loc):
                let allowed: Bool
                if let onHoverSelect {
                    allowed = onHoverSelect()
                } else {
                    onSelect()
                    allowed = true
                }
                if allowed {
                    if !isHovered {
                        isHovered = true
                    }
                    let w = max(1, tileSize.width)
                    let h = max(1, tileSize.height)
                    let nx = max(-1, min(1, ((loc.x / w) - 0.5) * 2.0))
                    let ny = max(-1, min(1, ((loc.y / h) - 0.5) * 2.0))
                    if abs(nx - hoverNorm.x) >= 0.03 || abs(ny - hoverNorm.y) >= 0.03 {
                        hoverNorm = CGPoint(x: nx, y: ny)
                    }
                }
            case .ended:
                if isHovered {
                    isHovered = false
                }
                if hoverNorm != .zero {
                    hoverNorm = .zero
                }
            }
        }
        .onDrag {
            ClipboardStore.shared.makeDragItemProvider(for: item)
        }
        .onTapGesture {
            if ForceTouchSuppressionRegistry.consumeSuppressionIfNeeded(for: item.id) {
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let clickCount = (NSApp.currentEvent?.type == .leftMouseUp) ? (NSApp.currentEvent?.clickCount ?? 1) : 1
            let isDouble = clickCount >= 2 || (now - lastTapUptime) <= min(NSEvent.doubleClickInterval, 0.32)
            lastTapUptime = isDouble ? 0 : now
            if !isHovered { isHovered = true }
            if isDouble {
                onSelect()
                onPaste()
            } else {
                onSelect()
                onCopyOnly()
                withAnimation(.easeOut(duration: 0.14)) { showCopiedInlineFlash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.easeOut(duration: 0.2)) { showCopiedInlineFlash = false }
                }
            }
        }
        .contextMenu {
            Button("键入光标处（双击）") {
                onPaste()
            }
            Button("仅复制到剪贴板（⌘C）") {
                onCopyOnly()
            }
            if let onOpenQuickLook {
                Button("系统大屏预览原图（Space / 重按）") {
                    onOpenQuickLook()
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
                        Button("提取图中文字并键入（⇧↵）") {
                            onExtractOCR(true)
                        }
                        Button("仅复制图中文字") {
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
    }
}
