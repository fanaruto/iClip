#if !ICLIP_EDITION_FLOW
import SwiftUI
import AppKit

/// 苹果 Finder QuickLook 风格的语义原文与变换结果实时对照浮层（Space / ⌘Y 呼出）
struct SemanticQuickLookOverlay: View {
    let item: ClipItem
    let snapshot: SemanticSnapshot
    @Binding var selectedPreviewIndex: Int
    let onCommitPaste: (String, String) -> Void
    let onClose: () -> Void

    /// 预览标签页：0 为原始文本，1...N 为可用语义变换结果
    private var tabs: [(id: String, title: String, content: String, toast: String)] {
        let rawText: String = {
            if let t = item.text { return t }
            if let paths = item.filePaths { return paths.joined(separator: "\n") }
            return item.primaryTitle
        }()
        var list: [(String, String, String, String)] = [
            ("raw", "原始文本", rawText, "已键入原始文本")
        ]
        for action in snapshot.actions {
            list.append((action.id, action.title, action.resultText, action.toastText))
        }
        return list
    }

    private var safeIndex: Int {
        min(max(selectedPreviewIndex, 0), max(0, tabs.count - 1))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            VStack(alignment: .leading, spacing: 10) {
                // 顶部栏：语义标题 + 关闭按钮
                HStack(spacing: 8) {
                    if let kind = snapshot.primaryKind {
                        Image(systemName: kind.symbolName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(nsColor: kind.tintColor))
                        Text(kind.badgeTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                    } else {
                        Image(systemName: "eye")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("速览预览")
                            .font(.system(size: 12.5, weight: .semibold))
                    }

                    Text("· \(item.subtitleInfo)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("关闭速览（Space / ESC）")
                }

                // 切换胶囊（当存在语义变换时默认自动切到第 1 个变换结果方便直观比对）
                if tabs.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { idx, tab in
                                let active = idx == safeIndex
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        selectedPreviewIndex = idx
                                    }
                                } label: {
                                    Text(tab.title)
                                        .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                                        .foregroundStyle(active ? Color.white : Color.primary.opacity(0.85))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4.5)
                                        .background(
                                            Capsule()
                                                .fill(active ? Color.accentColor : Color.primary.opacity(0.07))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // 代码级等宽文本对照滚动视窗
                ScrollView(.vertical, showsIndicators: true) {
                    Text(tabs[safeIndex].content)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                )

                // 底部操作条
                HStack {
                    Text("按 ← → 切换版本 · Space 关闭")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        let current = tabs[safeIndex]
                        onCommitPaste(current.content, current.toast)
                    } label: {
                        HStack(spacing: 4) {
                            Text("键入当前版本")
                            Text("↵")
                                .opacity(0.8)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .frame(width: 392, height: 430)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: Color.black.opacity(0.26), radius: 22, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
            )
        }
        .onAppear {
            selectedPreviewIndex = snapshot.actions.isEmpty ? 0 : 1
        }
    }
}
#endif
