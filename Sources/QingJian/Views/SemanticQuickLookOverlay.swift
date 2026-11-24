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

    /// 实时计算速览文本的字符数、行数与 AI 上下文 Token 估算（CJK 字约 1.2 tok，ASCII 词约 0.25 tok/char）
    static func textMetricsSummary(for text: String) -> String {
        let charCount = text.count
        guard charCount > 0 else { return "0 字" }
        var lines = 1
        var asciiCount = 0
        var nonAsciiCount = 0
        for scalar in text.unicodeScalars {
            if scalar.value == 10 { lines += 1 }
            if scalar.value < 128 {
                asciiCount += 1
            } else {
                nonAsciiCount += 1
            }
        }
        let estTokens = max(1, Int((Double(asciiCount) * 0.26 + Double(nonAsciiCount) * 1.15).rounded()))
        if lines > 1 {
            return "\(charCount)字 · \(lines)行 · ≈\(estTokens) tok"
        }
        return "\(charCount)字 · ≈\(estTokens) tok"
    }
}

/// 剪贴板历史条目与最新剪贴（`#1`）的行级差异模型
enum ClipboardDiffRow: Equatable, Identifiable {
    case unchanged(oldLine: Int, newLine: Int, text: String)
    case removed(oldLine: Int, text: String)
    case added(newLine: Int, text: String)
    case collapsedContext(hiddenLineCount: Int)

    var id: String {
        switch self {
        case .unchanged(let o, let n, _): return "u-\(o)-\(n)"
        case .removed(let o, _): return "r-\(o)"
        case .added(let n, _): return "a-\(n)"
        case .collapsedContext(let c): return "c-\(c)"
        }
    }
}

/// 剪贴板两段文本 / JSON 的微秒级原位差异计算结果
struct ClipboardDiffResult: Equatable {
    let addedCount: Int
    let removedCount: Int
    let isJSONNormalized: Bool
    let isTruncated: Bool
    let rows: [ClipboardDiffRow]
    let unifiedPatchText: String

    var hasChanges: Bool {
        addedCount > 0 || removedCount > 0
    }

    var tabBadgeTitle: String {
        if !hasChanges && isJSONNormalized {
            return "对比 #1 (语义一致)"
        }
        return "对比 #1 (+\(addedCount)/-\(removedCount))"
    }
}

/// 纯本地有界 LCS 剪贴板差异比对引擎（支持单行/乱序 JSON 自动对齐、前后公共行 O(N) 裁剪与长上下文折叠）
enum ClipboardDiffEngine {
    static let maxLineCap = 360

    static func computeDiff(older: String, newer: String, contextLines: Int = 2) -> ClipboardDiffResult? {
        let rawOld = older.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let rawNew = newer.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard rawOld != rawNew else { return nil }
        guard !rawOld.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rawNew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var workOld = rawOld
        var workNew = rawNew
        var jsonNormalized = false

        if let normOld = normalizeJSONIfApplicable(rawOld),
           let normNew = normalizeJSONIfApplicable(rawNew) {
            workOld = normOld
            workNew = normNew
            jsonNormalized = true
            if normOld == normNew {
                let previewLines = normNew.components(separatedBy: "\n")
                var unchangedRows: [ClipboardDiffRow] = previewLines.prefix(10).enumerated().map { idx, line in
                    .unchanged(oldLine: idx + 1, newLine: idx + 1, text: line)
                }
                if previewLines.count > 10 {
                    unchangedRows.append(.collapsedContext(hiddenLineCount: previewLines.count - 10))
                }
                return ClipboardDiffResult(
                    addedCount: 0,
                    removedCount: 0,
                    isJSONNormalized: true,
                    isTruncated: false,
                    rows: unchangedRows,
                    unifiedPatchText: "// 两段 JSON 键值语义完全一致（仅空白缩进或字段顺序不同）\n" + normNew
                )
            }
        }

        let fullOldLines = workOld.components(separatedBy: "\n")
        let fullNewLines = workNew.components(separatedBy: "\n")
        let truncated = fullOldLines.count > maxLineCap || fullNewLines.count > maxLineCap
        let oldLines = truncated ? Array(fullOldLines.prefix(maxLineCap)) : fullOldLines
        let newLines = truncated ? Array(fullNewLines.prefix(maxLineCap)) : fullNewLines

        // 1. O(N) 剥除首尾完全相同的公共前缀与公共后缀，将常规局部修改压缩至极小矩阵
        var prefixLen = 0
        let minCount = min(oldLines.count, newLines.count)
        while prefixLen < minCount && oldLines[prefixLen] == newLines[prefixLen] {
            prefixLen += 1
        }

        var suffixLen = 0
        while (prefixLen + suffixLen) < oldLines.count &&
              (prefixLen + suffixLen) < newLines.count &&
              oldLines[oldLines.count - 1 - suffixLen] == newLines[newLines.count - 1 - suffixLen] {
            suffixLen += 1
        }

        let oldMid = Array(oldLines[prefixLen..<(oldLines.count - suffixLen)])
        let newMid = Array(newLines[prefixLen..<(newLines.count - suffixLen)])
        let m = oldMid.count
        let n = newMid.count

        var rawOps: [ClipboardDiffRow] = []
        rawOps.reserveCapacity(oldLines.count + newLines.count)

        for p in 0..<prefixLen {
            rawOps.append(.unchanged(oldLine: p + 1, newLine: p + 1, text: oldLines[p]))
        }

        // 2. 反向 LCS DP，前向贪心回溯确保修改处严格呈现「先 - 旧行，后 + 新行」的 Git 标准顺序
        if m == 0 {
            for j in 0..<n {
                rawOps.append(.added(newLine: prefixLen + j + 1, text: newMid[j]))
            }
        } else if n == 0 {
            for i in 0..<m {
                rawOps.append(.removed(oldLine: prefixLen + i + 1, text: oldMid[i]))
            }
        } else {
            let cols = n + 1
            var dp = [UInt16](repeating: 0, count: (m + 1) * cols)
            for i in stride(from: m - 1, through: 0, by: -1) {
                let rowOffset = i * cols
                let nextRowOffset = (i + 1) * cols
                let oldLine = oldMid[i]
                for j in stride(from: n - 1, through: 0, by: -1) {
                    if oldLine == newMid[j] {
                        dp[rowOffset + j] = dp[nextRowOffset + j + 1] &+ 1
                    } else {
                        let down = dp[nextRowOffset + j]
                        let right = dp[rowOffset + j + 1]
                        dp[rowOffset + j] = down >= right ? down : right
                    }
                }
            }

            var i = 0
            var j = 0
            while i < m && j < n {
                if oldMid[i] == newMid[j] {
                    rawOps.append(.unchanged(oldLine: prefixLen + i + 1, newLine: prefixLen + j + 1, text: oldMid[i]))
                    i += 1
                    j += 1
                } else if dp[(i + 1) * cols + j] >= dp[i * cols + (j + 1)] {
                    rawOps.append(.removed(oldLine: prefixLen + i + 1, text: oldMid[i]))
                    i += 1
                } else {
                    rawOps.append(.added(newLine: prefixLen + j + 1, text: newMid[j]))
                    j += 1
                }
            }
            while i < m {
                rawOps.append(.removed(oldLine: prefixLen + i + 1, text: oldMid[i]))
                i += 1
            }
            while j < n {
                rawOps.append(.added(newLine: prefixLen + j + 1, text: newMid[j]))
                j += 1
            }
        }

        let oldSuffixStart = oldLines.count - suffixLen
        let newSuffixStart = newLines.count - suffixLen
        for s in 0..<suffixLen {
            rawOps.append(.unchanged(
                oldLine: oldSuffixStart + s + 1,
                newLine: newSuffixStart + s + 1,
                text: oldLines[oldSuffixStart + s]
            ))
        }

        var added = 0
        var removed = 0
        var keepMask = [Bool](repeating: false, count: rawOps.count)
        let radius = max(0, contextLines)

        for (idx, op) in rawOps.enumerated() {
            switch op {
            case .added:
                added += 1
                let lo = max(0, idx - radius)
                let hi = min(rawOps.count - 1, idx + radius)
                for k in lo...hi { keepMask[k] = true }
            case .removed:
                removed += 1
                let lo = max(0, idx - radius)
                let hi = min(rawOps.count - 1, idx + radius)
                for k in lo...hi { keepMask[k] = true }
            case .unchanged, .collapsedContext:
                break
            }
        }

        // 3. 折叠远离变更区的冗余相同行，确保打开速览第一屏直击改动焦点
        var displayRows: [ClipboardDiffRow] = []
        var patchLines: [String] = ["--- 选中历史记录", "+++ 最新剪贴 (#1)"]
        var cursor = 0
        while cursor < rawOps.count {
            if keepMask[cursor] {
                let op = rawOps[cursor]
                displayRows.append(op)
                switch op {
                case .unchanged(_, _, let t): patchLines.append("  \(t)")
                case .removed(_, let t): patchLines.append("- \(t)")
                case .added(_, let t): patchLines.append("+ \(t)")
                case .collapsedContext: break
                }
                cursor += 1
            } else {
                var end = cursor
                while end < rawOps.count && !keepMask[end] {
                    end += 1
                }
                let hiddenCount = end - cursor
                if hiddenCount == 1 {
                    let op = rawOps[cursor]
                    displayRows.append(op)
                    if case .unchanged(_, _, let t) = op {
                        patchLines.append("  \(t)")
                    }
                } else {
                    displayRows.append(.collapsedContext(hiddenLineCount: hiddenCount))
                    patchLines.append("@@ ... 省略 \(hiddenCount) 行相同内容 ... @@")
                }
                cursor = end
            }
        }

        return ClipboardDiffResult(
            addedCount: added,
            removedCount: removed,
            isJSONNormalized: jsonNormalized,
            isTruncated: truncated,
            rows: displayRows,
            unifiedPatchText: patchLines.joined(separator: "\n")
        )
    }

    private static func normalizeJSONIfApplicable(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 32_768 else { return nil }
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
              (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              JSONSerialization.isValidJSONObject(obj),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let str = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        return str
    }
}

/// 速览浮层单个标签页模型（支持高清原图页、文本/智变页与原位差异比对页）
struct QuickLookTabItem: Identifiable, Equatable {
    static let diffLatestTabID = "diff-latest"

    enum Payload: Equatable {
        case image
        case text(String)
    }

    let id: String
    let title: String
    let payload: Payload
    let toast: String
    let supportsSaveBack: Bool
    var diffResult: ClipboardDiffResult? = nil

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
            let qr = item.qrCodePayload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !qr.isEmpty {
                tabs.append(
                    QuickLookTabItem(
                        id: "qrcode",
                        title: "二维码内容",
                        payload: .text(qr),
                        toast: "已键入图中二维码内容",
                        supportsSaveBack: false
                    )
                )
            }
            if let ocr = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ocr.isEmpty,
               ocr != qr {
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
        if !store.minimalModeEnabled && (item.type == .text || item.type == .link) {
            let ranked = store.financeActions(for: item).filter {
                $0.id != "todo-split-checklist" && $0.id != "contact-split-queue"
            }
            for action in ranked {
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

        // 历史文本/链接条目自动挂载「与最新剪贴 #1 行级差异比对」标签页（严格隔离粘贴即焚机密与 ICLPMSG1 密文信封防旁路泄露）
        if !store.minimalModeEnabled,
           (item.type == .text || item.type == .link),
           !item.isBurnAfterPaste,
           !SecretCapsuleMessenger.containsCapsule(item.text),
           let latestItem = store.items.first(where: {
               ($0.type == .text || $0.type == .link)
                   && !$0.isBurnAfterPaste
                   && !SecretCapsuleMessenger.containsCapsule($0.text)
           }),
           latestItem.id != item.id,
           let latestText = latestItem.text,
           let diff = ClipboardDiffEngine.computeDiff(older: rawText, newer: latestText) {
            list.append(
                QuickLookTabItem(
                    id: QuickLookTabItem.diffLatestTabID,
                    title: diff.tabBadgeTitle,
                    payload: .text(diff.unifiedPatchText),
                    toast: "已键入差异对比补丁",
                    supportsSaveBack: false,
                    diffResult: diff
                )
            )
        }

        return list
    }

    static func defaultTabIndex(
        for item: ClipItem,
        tabs: [QuickLookTabItem],
        preferDiff: Bool = false
    ) -> Int {
        if item.type == .image {
            return 0
        }
        if preferDiff, let diffIdx = tabs.firstIndex(where: { $0.id == QuickLookTabItem.diffLatestTabID }) {
            return diffIdx
        }
        if tabs.count > 1 && tabs[1].id != QuickLookTabItem.diffLatestTabID {
            return 1
        }
        return 0
    }
}

/// 苹果 Finder QuickLook 风格全模态速览与原位微调舱（Space / ⌘Y 呼出，⌥Space 直达差异对比）
struct SemanticQuickLookOverlay: View {
    let item: ClipItem
    let tabs: [QuickLookTabItem]
    @Binding var selectedPreviewIndex: Int
    @Binding var isEditing: Bool
    @Binding var draftText: String
    var preferDiffOnOpen: Bool = false
    let onCommitPasteText: (String, String) -> Void
    let onCommitPasteImage: () -> Void
    let onSaveToItem: (String) -> Void
    let onClose: () -> Void

    @FocusState private var isEditorFocused: Bool
    @State private var loadedImage: NSImage? = nil
    @State private var stickyDiffSelected: Bool = false

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
            stickyDiffSelected = preferDiffOnOpen
            resetStateForCurrentItem(preferDiff: preferDiffOnOpen)
        }
        .onChange(of: item.id) { _, _ in
            resetStateForCurrentItem(preferDiff: stickyDiffSelected || preferDiffOnOpen)
        }
        .onChange(of: selectedPreviewIndex) { _, newIdx in
            if newIdx >= 0, newIdx < tabs.count {
                stickyDiffSelected = (tabs[newIdx].id == QuickLookTabItem.diffLatestTabID)
            }
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

    private func resetStateForCurrentItem(preferDiff: Bool) {
        isEditing = false
        draftText = ""
        selectedPreviewIndex = QuickLookTabBuilder.defaultTabIndex(
            for: item,
            tabs: tabs,
            preferDiff: preferDiff
        )
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

            Text(
                activeTab?.textValue != nil
                    ? "· \(QuickLookTextHelper.textMetricsSummary(for: isEditing ? draftText : (activeTab?.textValue ?? "")))"
                    : "· \(item.subtitleInfo)"
            )
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
                } else if let diff = tab.diffResult {
                    diffViewport(diff)
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

    private func diffViewport(_ diff: ClipboardDiffResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("选中历史 → 最新剪贴 #1")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                if diff.isJSONNormalized {
                    Text("JSON 对齐")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.indigo)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.indigo.opacity(0.13)))
                }
                Spacer(minLength: 4)
                if diff.hasChanges {
                    Text("+\(diff.addedCount)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.green)
                    Text("-\(diff.removedCount)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.red)
                } else {
                    Text("语义完全一致")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 1.5) {
                    ForEach(diff.rows) { row in
                        switch row {
                        case .removed(let oldLine, let lineText):
                            diffLineView(prefix: "-", lineNo: oldLine, text: lineText, tint: .red, prominent: true)
                        case .added(let newLine, let lineText):
                            diffLineView(prefix: "+", lineNo: newLine, text: lineText, tint: .green, prominent: true)
                        case .unchanged(_, let newLine, let lineText):
                            diffLineView(prefix: " ", lineNo: newLine, text: lineText, tint: nil, prominent: false)
                        case .collapsedContext(let count):
                            Text("⋯ 折叠 \(count) 行相同内容 ⋯")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.035))
                        }
                    }
                    if diff.isTruncated {
                        Text("⋯ 已比较前 \(ClipboardDiffEngine.maxLineCap) 行 ⋯")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private func diffLineView(prefix: String, lineNo: Int, text: String, tint: Color?, prominent: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(lineNo)")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.65))
                .frame(width: 24, alignment: .trailing)
            Text(prefix)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 10, alignment: .center)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(prominent ? Color.primary : Color.primary.opacity(0.75))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill((tint ?? Color.clear).opacity(tint == nil ? 0 : 0.14))
        )
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
                        Text(
                            activeTab?.payload == .image
                                ? "键入此图片"
                                : (activeTab?.diffResult != nil ? "键入差异补丁" : "键入当前版本")
                        )
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
