import SwiftUI
import AppKit

/// 单条 iOS 风格剪贴板卡片
struct ClipCardView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onPaste: (Bool) -> Void
    let onCopyOnly: (Bool) -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false
    @ObservedObject private var store = ClipboardStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leadingThumbnail

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Text(item.primaryTitle)
                        .font(.system(size: 13.5, weight: .medium, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isHovered {
                        hoverActions
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    } else if index < 9 {
                        shortcutBadge
                    }
                }

                HStack(spacing: 6) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.orange)
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
        .onTapGesture(count: 1) {
            onSelect()
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
            if let nsImage = store.thumbnailImage(for: item) {
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
            }

        case .file:
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: store.fileIcon(for: item))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                if let count = item.filePaths?.count, count > 1 {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
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
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isSelected ? Color.white.opacity(0.2) : Color.primary.opacity(0.06))
            )
    }

    private var hoverActions: some View {
        HStack(spacing: 5) {
            Button(action: onTogglePin) {
                Image(systemName: item.isPinned ? "pin.slash.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : (item.isPinned ? Color.orange : Color.secondary))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.07))
                    )
            }
            .buttonStyle(.plain)
            .help(item.isPinned ? "取消固定" : "固定到顶部")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.red.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.white.opacity(0.22) : Color.red.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
            .help("删除此条记录")
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
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.72 : 0.48))
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                isSelected
                    ? Color.white.opacity(0.28)
                    : Color.primary.opacity(isHovered ? 0.12 : 0.06),
                lineWidth: 0.75
            )
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

        Button(item.isPinned ? "取消固定" : "固定到顶部") {
            onTogglePin()
        }

        Button("删除", role: .destructive) {
            onDelete()
        }
    }
}
