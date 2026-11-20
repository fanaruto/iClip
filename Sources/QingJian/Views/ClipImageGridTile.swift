import SwiftUI
import AppKit

/// iOS 相册风格的图片网格卡片（3 列一行排列，悬停弹性放大）
struct ClipImageGridTile: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onHoverChange: (Bool, CGFloat) -> Void

    @State private var isHovered: Bool = false
    @ObservedObject private var store = ClipboardStore.shared

    var body: some View {
        GeometryReader { geo in
            let midY = geo.frame(in: .named("clipListArea")).midY

            ZStack(alignment: .bottom) {
                // 缩略图主体
                Group {
                    if let nsImage = store.thumbnailImage(for: item) {
                        Image(nsImage: nsImage)
                            .resizable()
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
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                // 底部渐变信息条（像素尺寸 / 时间）
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.58)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 34)
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
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color(nsColor: .controlAccentColor)
                            : (isHovered ? Color.white.opacity(0.65) : Color.primary.opacity(0.1)),
                        lineWidth: isSelected ? 2.2 : (isHovered ? 1.2 : 0.75)
                    )
            )
            .shadow(
                color: Color.black.opacity(isHovered ? 0.24 : (isSelected ? 0.16 : 0.06)),
                radius: isHovered ? 12 : 4,
                y: isHovered ? 5 : 2
            )
            .scaleEffect(isHovered ? 1.09 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.76), value: isHovered)
            .animation(.spring(response: 0.2, dampingFraction: 0.82), value: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    onSelect()
                }
                onHoverChange(hovering, midY)
            }
            .onTapGesture {
                onCopy()
            }
            .contextMenu {
                Button("复制并粘贴") {
                    onCopy()
                }
                Button(item.isPinned ? "取消固定" : "固定到顶部") {
                    onTogglePin()
                }
                Divider()
                Button("删除", role: .destructive) {
                    onDelete()
                }
            }
        }
        .frame(height: 98)
        .zIndex(isHovered ? 20 : (isSelected ? 5 : 0))
    }
}

/// 悬停在图片网格时弹出的高清原比例放大预览浮层（不阻挡点击）
struct ImageHoverPreviewOverlay: View {
    let item: ClipItem
    @ObservedObject private var store = ClipboardStore.shared

    var body: some View {
        VStack(spacing: 8) {
            if let img = store.previewImage(for: item) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 368, maxHeight: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
                    )
            }

            HStack(spacing: 8) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)

                if let w = item.imageWidth, let h = item.imageHeight {
                    Text("\(w) × \(h)")
                        .monospacedDigit()
                }

                if let app = item.sourceAppName, !app.isEmpty {
                    Text("·")
                    Text(app)
                        .lineLimit(1)
                }

                Text("·")
                Text(item.relativeTimeText)

                Spacer()

                Text("点击粘贴")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 4)
        }
        .padding(10)
        .frame(maxWidth: 388)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.26), radius: 20, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
        )
        .allowsHitTesting(false)
    }
}
