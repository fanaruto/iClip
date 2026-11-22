#if ICLIP_EDITION_FLOW
import SwiftUI
import AppKit

/// 非状态矩形容器：记录当前图片格坐标，滚动时绝不触发 SwiftUI @State 重绘
private final class TileFrameBox {
    var rect: CGRect = .zero
}

/// iOS 相册风格的图片网格卡片（3 列一行排列，悬停克制微抬并弹出纯净原图预览）
struct ClipImageGridTile: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let queueRank: Int?
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onCopyOnly: () -> Void
    let onToggleQueue: () -> Void
    let onExtractOCR: (Bool) -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onHoverChange: (Bool, CGRect) -> Void

    @State private var isHovered: Bool = false
    @State private var asyncThumbnail: NSImage? = nil
    @State private var frameBox = TileFrameBox()

    var body: some View {
        ZStack(alignment: .bottom) {
            // 缩略图主体（纯内存零 I/O 读取 + 后台异步解码，滚动满帧不卡顿）
            Color.clear
                .overlay {
                    if let nsImage = ClipboardStore.shared.cachedThumbnail(for: item) ?? asyncThumbnail {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
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
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.orange)
                }
                if let w = item.imageWidth, let h = item.imageHeight {
                    Text("\(w)×\(h)")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
                    Text(item.relativeTimeText)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                }
                Spacer(minLength: 0)
                if let ocr = item.ocrText, !ocr.isEmpty {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.95))
                }
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 7)
            .padding(.bottom, 5)
            .allowsHitTesting(false)
        }
        .frame(height: 98)
        .overlay(alignment: .topLeading) {
            if let rank = queueRank {
                Text("#\(rank)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .padding(6)
                    .allowsHitTesting(false)
            } else if index < 9 {
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
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovered {
                HStack(spacing: 4) {
                    Button {
                        onExtractOCR(true)
                    } label: {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 21, height: 21)
                            .background(Circle().fill(Color.accentColor.opacity(0.88)))
                    }
                    .buttonStyle(.plain)
                    .help("提取图中文字并键入（⇧↵）")

                    Button(action: onTogglePin) {
                        Image(systemName: item.isPinned ? "pin.slash.fill" : "pin.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(item.isPinned ? Color.orange : Color.white)
                            .frame(width: 21, height: 21)
                            .background(Circle().fill(Color.black.opacity(0.58)))
                    }
                    .buttonStyle(.plain)
                    .help(item.isPinned ? "取消固定" : "固定到顶部")

                    Button(action: onDelete) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 21, height: 21)
                            .background(Circle().fill(Color.red.opacity(0.82)))
                    }
                    .buttonStyle(.plain)
                    .help("删除图片")
                }
                .padding(5)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color(nsColor: .controlAccentColor)
                        : (isHovered ? Color.white.opacity(0.6) : Color.primary.opacity(0.1)),
                    lineWidth: isSelected ? 2.0 : (isHovered ? 1.1 : 0.75)
                )
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.18 : (isSelected ? 0.14 : 0.05)),
            radius: isHovered ? 9 : 4,
            y: isHovered ? 4 : 2
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: isHovered)
        .animation(.spring(response: 0.2, dampingFraction: 0.88), value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .background {
            GeometryReader { geo in
                let frame = geo.frame(in: .named("panelRoot"))
                Color.clear
                    .onAppear {
                        frameBox.rect = frame
                    }
                    .onChange(of: frame) { _, newFrame in
                        frameBox.rect = newFrame
                        if isHovered {
                            onHoverChange(true, newFrame)
                        }
                    }
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onSelect()
            }
            onHoverChange(hovering, frameBox.rect)
        }
        .onTapGesture(count: 2) {
            onPaste()
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .contextMenu {
            Button("键入光标处（双击）") {
                onPaste()
            }
            Button("仅复制到剪贴板") {
                onCopyOnly()
            }
            Divider()
            Button("提取图中文字并键入（⇧↵）") {
                onExtractOCR(true)
            }
            Button("仅复制图中文字") {
                onExtractOCR(false)
            }
            Divider()
            Button(queueRank != nil ? "移出顺序队列（⌘K）" : "加入顺序队列（⌘K）") {
                onToggleQueue()
            }
            Button(item.isPinned ? "取消固定" : "固定到顶部") {
                onTogglePin()
            }
            Divider()
            Button("删除", role: .destructive) {
                onDelete()
            }
        }
        .zIndex(isHovered ? 20 : (isSelected ? 5 : 0))
    }
}

/// 苹果风纯净原图放大预览浮层：无灰底卡片、无冗余底部栏，紧贴原图自然宽高比从缩略图方向顺滑绽放
struct ImageHoverPreviewLayer: View {
    let item: ClipItem?
    let tileRect: CGRect
    let isVisible: Bool
    let panelSize: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var asyncLoadedImage: NSImage? = nil
    @State private var asyncLoadedItemID: UUID? = nil

    private struct PreviewLayout {
        let size: CGSize
        let center: CGPoint
        let anchor: UnitPoint
        let placeBelow: Bool
    }

    var body: some View {
        ZStack {
            if let item, let img = resolvedImage(for: item) {
                let layout = computeLayout(for: item, image: img)

                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: layout.size.width, height: layout.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.48),
                                        Color.white.opacity(0.14),
                                        Color.black.opacity(0.08)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if let ocr = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                            HStack(spacing: 4.5) {
                                Image(systemName: "text.viewfinder")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("实况文本 \(ocr.count) 字 · ⇧↵ 键入")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(0.66))
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.6))
                            )
                            .padding(8)
                        }
                    }
                    .compositingGroup()
                    .shadow(color: Color.black.opacity(isVisible ? 0.14 : 0.0), radius: 6, y: 3)
                    .shadow(color: Color.black.opacity(isVisible ? 0.28 : 0.0), radius: 26, y: 14)
                    .scaleEffect(isVisible || reduceMotion ? 1.0 : 0.88, anchor: layout.anchor)
                    .offset(y: isVisible || reduceMotion ? 0 : (layout.placeBelow ? -8 : 8))
                    .opacity(isVisible ? 1.0 : 0.0)
                    .position(layout.center)
                    .id("pure-image-preview")
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .allowsHitTesting(false)
        .task(id: item?.id) {
            guard let item else { return }
            if ClipboardStore.shared.cachedPreviewImage(for: item) != nil {
                return
            }
            if let loaded = await ClipboardStore.shared.loadPreviewImage(for: item), !Task.isCancelled {
                asyncLoadedItemID = item.id
                asyncLoadedImage = loaded
            }
        }
    }

    private func resolvedImage(for item: ClipItem) -> NSImage? {
        if let cached = ClipboardStore.shared.cachedPreviewImage(for: item) {
            return cached
        }
        if asyncLoadedItemID == item.id, let loaded = asyncLoadedImage {
            return loaded
        }
        return ClipboardStore.shared.cachedThumbnail(for: item)
    }

    private func computeLayout(for item: ClipItem, image: NSImage) -> PreviewLayout {
        let rawW: CGFloat = {
            if image.size.width > 0, image.size.height > 0 { return image.size.width }
            if let w = item.imageWidth, w > 0 { return CGFloat(w) }
            return 1
        }()
        let rawH: CGFloat = {
            if image.size.width > 0, image.size.height > 0 { return image.size.height }
            if let h = item.imageHeight, h > 0 { return CGFloat(h) }
            return 1
        }()

        let edgeInset: CGFloat = 14
        let horizontalInset: CGFloat = 20
        let tileGap: CGFloat = 10

        let validTileRect = tileRect.width > 0 && tileRect.height > 0
            ? tileRect
            : CGRect(x: panelSize.width / 2 - 60, y: 120, width: 120, height: 98)

        let clampedTileMinY = min(max(validTileRect.minY, edgeInset), panelSize.height - edgeInset)
        let clampedTileMaxY = min(max(validTileRect.maxY, edgeInset), panelSize.height - edgeInset)

        let spaceBelow = max(0, panelSize.height - edgeInset - (clampedTileMaxY + tileGap))
        let spaceAbove = max(0, (clampedTileMinY - tileGap) - edgeInset)
        let placeBelow = spaceBelow >= 230 || spaceBelow >= spaceAbove

        let availableH = max(120, min(placeBelow ? spaceBelow : spaceAbove, 344))
        let maxW = max(120, panelSize.width - horizontalInset * 2)

        // 严格保持原图自然比例，防止极小图标过度放大失真
        let fitScale = min(maxW / rawW, availableH / rawH, 1.5)
        let width = max(1, round(rawW * fitScale))
        let height = max(1, round(rawH * fitScale))

        let minCenterX = horizontalInset + width / 2
        let maxCenterX = panelSize.width - horizontalInset - width / 2
        let centerX = minCenterX <= maxCenterX
            ? min(max(validTileRect.midX, minCenterX), maxCenterX)
            : panelSize.width / 2

        let rawCenterY = placeBelow
            ? (clampedTileMaxY + tileGap + height / 2)
            : (clampedTileMinY - tileGap - height / 2)
        let minCenterY = edgeInset + height / 2
        let maxCenterY = panelSize.height - edgeInset - height / 2
        let centerY = minCenterY <= maxCenterY
            ? min(max(rawCenterY, minCenterY), maxCenterY)
            : panelSize.height / 2

        let leftEdge = centerX - width / 2
        let anchorX = min(max((validTileRect.midX - leftEdge) / max(width, 1), 0.15), 0.85)
        let anchor = UnitPoint(x: anchorX, y: placeBelow ? 0.0 : 1.0)

        return PreviewLayout(
            size: CGSize(width: width, height: height),
            center: CGPoint(x: centerX, y: centerY),
            anchor: anchor,
            placeBelow: placeBelow
        )
    }
}
#else
import SwiftUI
import AppKit

/// 非状态矩形容器：记录当前图片格坐标，滚动时绝不触发 SwiftUI @State 重绘
private final class TileFrameBox {
    var rect: CGRect = .zero
}

/// iOS 相册风格的图片网格卡片（3 列一行排列，悬停克制微抬并弹出纯净原图预览）
struct ClipImageGridTile: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onCopyOnly: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onHoverChange: (Bool, CGRect) -> Void

    @State private var isHovered: Bool = false
    @State private var asyncThumbnail: NSImage? = nil
    @State private var frameBox = TileFrameBox()

    var body: some View {
        ZStack(alignment: .bottom) {
            // 缩略图主体（纯内存零 I/O 读取 + 后台异步解码，滚动满帧不卡顿）
            Color.clear
                .overlay {
                    if let nsImage = ClipboardStore.shared.cachedThumbnail(for: item) ?? asyncThumbnail {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
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
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.orange)
                }
                if let w = item.imageWidth, let h = item.imageHeight {
                    Text("\(w)×\(h)")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
                    Text(item.relativeTimeText)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 7)
            .padding(.bottom, 5)
            .allowsHitTesting(false)
        }
        .frame(height: 98)
        .overlay(alignment: .topLeading) {
            if index < 9 {
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
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovered {
                HStack(spacing: 4) {
                    Button(action: onTogglePin) {
                        Image(systemName: item.isPinned ? "pin.slash.fill" : "pin.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(item.isPinned ? Color.orange : Color.white)
                            .frame(width: 21, height: 21)
                            .background(Circle().fill(Color.black.opacity(0.58)))
                    }
                    .buttonStyle(.plain)
                    .help(item.isPinned ? "取消固定" : "固定到顶部")

                    Button(action: onDelete) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 21, height: 21)
                            .background(Circle().fill(Color.red.opacity(0.82)))
                    }
                    .buttonStyle(.plain)
                    .help("删除图片")
                }
                .padding(5)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color(nsColor: .controlAccentColor)
                        : (isHovered ? Color.white.opacity(0.6) : Color.primary.opacity(0.1)),
                    lineWidth: isSelected ? 2.0 : (isHovered ? 1.1 : 0.75)
                )
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.18 : (isSelected ? 0.14 : 0.05)),
            radius: isHovered ? 9 : 4,
            y: isHovered ? 4 : 2
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: isHovered)
        .animation(.spring(response: 0.2, dampingFraction: 0.88), value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .background {
            GeometryReader { geo in
                let frame = geo.frame(in: .named("panelRoot"))
                Color.clear
                    .onAppear {
                        frameBox.rect = frame
                    }
                    .onChange(of: frame) { _, newFrame in
                        frameBox.rect = newFrame
                        if isHovered {
                            onHoverChange(true, newFrame)
                        }
                    }
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onSelect()
            }
            onHoverChange(hovering, frameBox.rect)
        }
        .onTapGesture(count: 2) {
            onPaste()
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .contextMenu {
            Button("键入光标处（双击）") {
                onPaste()
            }
            Button("仅复制到剪贴板") {
                onCopyOnly()
            }
            Button(item.isPinned ? "取消固定" : "固定到顶部") {
                onTogglePin()
            }
            Divider()
            Button("删除", role: .destructive) {
                onDelete()
            }
        }
        .zIndex(isHovered ? 20 : (isSelected ? 5 : 0))
    }
}

/// 苹果风纯净原图放大预览浮层：无灰底卡片、无冗余底部栏，紧贴原图自然宽高比从缩略图方向顺滑绽放
struct ImageHoverPreviewLayer: View {
    let item: ClipItem?
    let tileRect: CGRect
    let isVisible: Bool
    let panelSize: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var asyncLoadedImage: NSImage? = nil
    @State private var asyncLoadedItemID: UUID? = nil

    private struct PreviewLayout {
        let size: CGSize
        let center: CGPoint
        let anchor: UnitPoint
        let placeBelow: Bool
    }

    var body: some View {
        ZStack {
            if let item, let img = resolvedImage(for: item) {
                let layout = computeLayout(for: item, image: img)

                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: layout.size.width, height: layout.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.48),
                                        Color.white.opacity(0.14),
                                        Color.black.opacity(0.08)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                    )
                    .compositingGroup()
                    .shadow(color: Color.black.opacity(isVisible ? 0.14 : 0.0), radius: 6, y: 3)
                    .shadow(color: Color.black.opacity(isVisible ? 0.28 : 0.0), radius: 26, y: 14)
                    .scaleEffect(isVisible || reduceMotion ? 1.0 : 0.88, anchor: layout.anchor)
                    .offset(y: isVisible || reduceMotion ? 0 : (layout.placeBelow ? -8 : 8))
                    .opacity(isVisible ? 1.0 : 0.0)
                    .position(layout.center)
                    .id("pure-image-preview")
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .allowsHitTesting(false)
        .task(id: item?.id) {
            guard let item else { return }
            if ClipboardStore.shared.cachedPreviewImage(for: item) != nil {
                return
            }
            if let loaded = await ClipboardStore.shared.loadPreviewImage(for: item), !Task.isCancelled {
                asyncLoadedItemID = item.id
                asyncLoadedImage = loaded
            }
        }
    }

    private func resolvedImage(for item: ClipItem) -> NSImage? {
        if let cached = ClipboardStore.shared.cachedPreviewImage(for: item) {
            return cached
        }
        if asyncLoadedItemID == item.id, let loaded = asyncLoadedImage {
            return loaded
        }
        return ClipboardStore.shared.cachedThumbnail(for: item)
    }

    private func computeLayout(for item: ClipItem, image: NSImage) -> PreviewLayout {
        let rawW: CGFloat = {
            if image.size.width > 0, image.size.height > 0 { return image.size.width }
            if let w = item.imageWidth, w > 0 { return CGFloat(w) }
            return 1
        }()
        let rawH: CGFloat = {
            if image.size.width > 0, image.size.height > 0 { return image.size.height }
            if let h = item.imageHeight, h > 0 { return CGFloat(h) }
            return 1
        }()

        let edgeInset: CGFloat = 14
        let horizontalInset: CGFloat = 20
        let tileGap: CGFloat = 10

        let validTileRect = tileRect.width > 0 && tileRect.height > 0
            ? tileRect
            : CGRect(x: panelSize.width / 2 - 60, y: 120, width: 120, height: 98)

        let clampedTileMinY = min(max(validTileRect.minY, edgeInset), panelSize.height - edgeInset)
        let clampedTileMaxY = min(max(validTileRect.maxY, edgeInset), panelSize.height - edgeInset)

        let spaceBelow = max(0, panelSize.height - edgeInset - (clampedTileMaxY + tileGap))
        let spaceAbove = max(0, (clampedTileMinY - tileGap) - edgeInset)
        let placeBelow = spaceBelow >= 230 || spaceBelow >= spaceAbove

        let availableH = max(120, min(placeBelow ? spaceBelow : spaceAbove, 344))
        let maxW = max(120, panelSize.width - horizontalInset * 2)

        // 严格保持原图自然比例，防止极小图标过度放大失真
        let fitScale = min(maxW / rawW, availableH / rawH, 1.5)
        let width = max(1, round(rawW * fitScale))
        let height = max(1, round(rawH * fitScale))

        let minCenterX = horizontalInset + width / 2
        let maxCenterX = panelSize.width - horizontalInset - width / 2
        let centerX = minCenterX <= maxCenterX
            ? min(max(validTileRect.midX, minCenterX), maxCenterX)
            : panelSize.width / 2

        let rawCenterY = placeBelow
            ? (clampedTileMaxY + tileGap + height / 2)
            : (clampedTileMinY - tileGap - height / 2)
        let minCenterY = edgeInset + height / 2
        let maxCenterY = panelSize.height - edgeInset - height / 2
        let centerY = minCenterY <= maxCenterY
            ? min(max(rawCenterY, minCenterY), maxCenterY)
            : panelSize.height / 2

        let leftEdge = centerX - width / 2
        let anchorX = min(max((validTileRect.midX - leftEdge) / max(width, 1), 0.15), 0.85)
        let anchor = UnitPoint(x: anchorX, y: placeBelow ? 0.0 : 1.0)

        return PreviewLayout(
            size: CGSize(width: width, height: height),
            center: CGPoint(x: centerX, y: centerY),
            anchor: anchor,
            placeBelow: placeBelow
        )
    }
}
#endif
