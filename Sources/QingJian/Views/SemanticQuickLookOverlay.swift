import SwiftUI
import AppKit

/// 速览文本安全加工辅助：识别多行与 Shell 续行符，支持一键压平为无回车安全单行
enum QuickLookTextHelper {
    private static let backslashContinuationRegex = try! NSRegularExpression(
        pattern: #"[ \t]*\\[ \t]*\n[ \t]*"#,
        options: []
    )

    static func containsMultiLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("\n") || trimmed.contains("\r") || text.hasSuffix("\n") || text.hasSuffix("\r")
    }

    /// 剥离 Shell `\` 续行符并将多行段落合并为无换行符的安全单行，彻底消除贴入终端自动回车执行的风险
    static func flattenToSingleLine(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let fullRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let unwrapped = backslashContinuationRegex.stringByReplacingMatches(
            in: normalized,
            options: [],
            range: fullRange,
            withTemplate: " "
        )
        let parts = unwrapped
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }
}

/// 速览浮层单个标签页模型（支持高清原图页与文本/智变页）
struct QuickLookTabItem: Identifiable, Equatable {
    enum Payload: Equatable {
        case image
        case text(String)
    }

    let id: String
    let title: String
    let payload: Payload
    let toast: String
    let supportsSaveBack: Bool

    var textValue: String? {
        if case .text(let s) = payload { return s }
        return nil
    }
}

/// 双角色统一的速览页签构建器（确保键盘左右切换与视图渲染共享唯一数据源）
@MainActor
enum QuickLookTabBuilder {
    static func buildTabs(for item: ClipItem, store: ClipboardStore) -> [QuickLookTabItem] {
        if item.type == .image {
            var tabs: [QuickLookTabItem] = [
                QuickLookTabItem(
                    id: "image",
                    title: "高清原图",
                    payload: .image,
                    toast: "已键入图片",
                    supportsSaveBack: false
                )
            ]
            if let ocr = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                tabs.append(
                    QuickLookTabItem(
                        id: "ocr",
                        title: "实况文本",
                        payload: .text(ocr),
                        toast: "已键入图中文字",
                        supportsSaveBack: true
                    )
                )
            }
            return tabs
        }

        let rawText: String = {
            if let t = item.text { return t }
            if let paths = item.filePaths { return paths.joined(separator: "\n") }
            return item.rawContentPreview
        }()
        let canSaveBack = (item.type == .text || item.type == .link)

        var list: [QuickLookTabItem] = [
            QuickLookTabItem(
                id: "raw",
                title: "原始文本",
                payload: .text(rawText),
                toast: "已键入原始文本",
                supportsSaveBack: canSaveBack
            )
        ]

        #if ICLIP_EDITION_FLOW
        if !store.minimalModeEnabled {
            for action in store.financeActions(for: item) {
                list.append(
                    QuickLookTabItem(
                        id: action.id,
                        title: action.title,
                        payload: .text(action.resultText),
                        toast: action.toastText,
                        supportsSaveBack: canSaveBack
                    )
                )
            }
        }
        #else
        if !store.minimalModeEnabled {
            for action in store.semanticSnapshot(for: item).actions {
                list.append(
                    QuickLookTabItem(
                        id: action.id,
                        title: action.title,
                        payload: .text(action.resultText),
                        toast: action.toastText,
                        supportsSaveBack: canSaveBack
                    )
                )
            }
        }
        #endif

        return list
    }

    static func defaultTabIndex(for item: ClipItem, tabs: [QuickLookTabItem]) -> Int {
        if item.type == .image {
            return 0
        }
        return tabs.count > 1 ? 1 : 0
    }
}

/// 苹果 Finder QuickLook 风格全模态速览与原位微调舱（Space / ⌘Y 呼出，双角色通用）
struct SemanticQuickLookOverlay: View {
    let item: ClipItem
    let tabs: [QuickLookTabItem]
    @Binding var selectedPreviewIndex: Int
    @Binding var isEditing: Bool
    @Binding var draftText: String
    let onCommitPasteText: (String, String) -> Void
    let onCommitPasteImage: () -> Void
    let onSaveToItem: (String) -> Void
    let onClose: () -> Void

    @FocusState private var isEditorFocused: Bool
    @State private var loadedImage: NSImage? = nil

    private var safeIndex: Int {
        min(max(selectedPreviewIndex, 0), max(0, tabs.count - 1))
    }

    private var activeTab: QuickLookTabItem? {
        guard !tabs.isEmpty else { return nil }
        return tabs[safeIndex]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .onTapGesture {
                    if isEditing {
                        isEditing = false
                    } else {
                        onClose()
                    }
                }

            VStack(alignment: .leading, spacing: 10) {
                headerRow

                if tabs.count > 1 && !isEditing {
                    tabBar
                }

                contentViewport

                footerRow
            }
            .padding(14)
            .frame(width: 392, height: 444)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: Color.black.opacity(0.28), radius: 22, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
            )
        }
        .onAppear {
            resetStateForCurrentItem()
        }
        .onChange(of: item.id) { _, _ in
            resetStateForCurrentItem()
        }
        .onChange(of: isEditing) { _, editing in
            if editing {
                if let currentText = activeTab?.textValue, draftText.isEmpty {
                    draftText = currentText
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    isEditorFocused = true
                }
            } else {
                isEditorFocused = false
            }
        }
    }

    private func resetStateForCurrentItem() {
        isEditing = false
        draftText = ""
        selectedPreviewIndex = QuickLookTabBuilder.defaultTabIndex(for: item, tabs: tabs)
        if item.type == .image {
            loadedImage = ClipboardStore.shared.cachedPreviewImage(for: item)
                ?? ClipboardStore.shared.cachedThumbnail(for: item)
            let targetItem = item
            Task {
                if let decoded = await ClipboardStore.shared.loadPreviewImage(for: targetItem),
                   targetItem.id == item.id {
                    loadedImage = decoded
                }
            }
        } else {
            loadedImage = nil
        }
    }

    private var headerRow: some View {
        HStack(spacing: 7) {
            Image(systemName: isEditing ? "pencil.and.outline" : item.type.symbolName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isEditing ? Color.accentColor : .secondary)

            Text(isEditing ? "原位微调" : item.primaryTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)

            Text("· \(item.subtitleInfo)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let textVal = activeTab?.textValue {
                if !isEditing && QuickLookTextHelper.containsMultiLine(textVal) {
                    Button {
                        let single = QuickLookTextHelper.flattenToSingleLine(textVal)
                        onCommitPasteText(single, "已剥离换行安全键入单行")
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.right.to.line.compact")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("单行键入")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(Color.primary.opacity(0.86))
                        .padding(.horizontal, 7.5)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("自动剥离换行与续行符，防止贴入终端直接回车执行")
                }

                Button {
                    if isEditing {
                        isEditing = false
                    } else {
                        draftText = textVal
                        isEditing = true
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isEditing ? "eye" : "slider.horizontal.3")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(isEditing ? "返回预览" : "微调 ⌘E")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(isEditing ? Color.white : Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        Capsule()
                            .fill(isEditing ? Color.accentColor : Color.accentColor.opacity(0.13))
                    )
                }
                .buttonStyle(.plain)
                .help(isEditing ? "退出微调（ESC）" : "在粘贴前原位修改几个字（⌘E）")
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("关闭速览（Space / ESC）")
        }
    }

    private var tabBar: some View {
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

    @ViewBuilder
    private var contentViewport: some View {
        if let tab = activeTab {
            switch tab.payload {
            case .image:
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.black.opacity(0.08))

                    if let nsImage = loadedImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(8)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .text(let content):
                if isEditing {
                    TextEditor(text: $draftText)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .focused($isEditorFocused)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.065))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.0)
                        )
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(content)
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
                }
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            if isEditing {
                Text("ESC 退出 · ⌘↵ 直接键入")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if activeTab?.supportsSaveBack == true {
                    Button {
                        onSaveToItem(draftText)
                    } label: {
                        Text("存回条目 ⌘S")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.88))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
                            .background(Capsule().fill(Color.primary.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .help("将微调后的内容原地保存回此剪贴条目（保留收藏与备注）")
                }

                Button {
                    onCommitPasteText(draftText, "已键入微调内容")
                } label: {
                    HStack(spacing: 4) {
                        Text("键入微调版")
                        Text("⌘↵")
                            .opacity(0.82)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            } else {
                Text(tabs.count > 1 ? "← → 切版本 · ↑ ↓ 换条 · Space 关闭" : "↑ ↓ 连续扫视 · Space 关闭")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    guard let current = activeTab else { return }
                    switch current.payload {
                    case .image:
                        onCommitPasteImage()
                    case .text(let text):
                        onCommitPasteText(text, current.toast)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(activeTab?.payload == .image ? "键入此图片" : "键入当前版本")
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
    }
}
