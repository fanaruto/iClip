import Foundation
import AppKit
import NaturalLanguage
import CoreGraphics

// MARK: - 1. 默认点击键入方式与零冲突配套手势解析器

enum CardClickGestureOutcome: Equatable {
    case paste(plainTextOnly: Bool)
    case copyOnly
    case openExternalLink
    case ignore
}

enum CardClickGestureResolver {
    /// 根据用户选择的「默认键入方式」与当前修饰键、点击次数、Force Touch 状态，唯一确定无冲突响应动作
    static func resolve(
        mode: CardClickPasteMode,
        clickCount: Int,
        modifiers: NSEvent.ModifierFlags,
        isLink: Bool,
        isForceTouchSuppressed: Bool
    ) -> CardClickGestureOutcome {
        if isForceTouchSuppressed {
            return .ignore
        }
        if modifiers.contains(.command) && isLink {
            return .openExternalLink
        }

        switch mode {
        case .singleClick:
            if clickCount >= 2 {
                return .ignore
            }
            if modifiers.contains(.option) {
                return .copyOnly
            }
            if modifiers.contains(.shift) {
                return .paste(plainTextOnly: true)
            }
            return .paste(plainTextOnly: false)

        case .doubleClick:
            if clickCount >= 3 {
                return .ignore
            }
            if clickCount == 2 {
                return .paste(plainTextOnly: modifiers.contains(.shift))
            }
            return .copyOnly
        }
    }

    static func effectiveClickCount(
        mode: CardClickPasteMode,
        eventClickCount: Int,
        elapsedSinceLastTap: TimeInterval,
        maxInterval: TimeInterval
    ) -> Int {
        let withinDebounce = elapsedSinceLastTap >= 0 && elapsedSinceLastTap <= maxInterval
        switch mode {
        case .singleClick:
            return withinDebounce ? max(2, eventClickCount) : 1
        case .doubleClick:
            if eventClickCount >= 2 {
                return eventClickCount
            }
            return withinDebounce ? 2 : 1
        }
    }

    /// 计算本次点击结算后的 `lastTapUptime`，确保 `.singleClick` 粘贴或连击拦截后顺延防误连击窗口，`.doubleClick` 首击等待升级双击
    static func nextLastTapUptime(
        mode: CardClickPasteMode,
        outcome: CardClickGestureOutcome,
        now: TimeInterval
    ) -> TimeInterval {
        switch outcome {
        case .paste:
            return (mode == .singleClick) ? now : 0
        case .copyOnly:
            return (mode == .doubleClick) ? now : 0
        case .ignore:
            return (mode == .singleClick) ? now : 0
        case .openExternalLink:
            return 0
        }
    }
}

// MARK: - 2. 锤子大爆炸（Big Bang）智能分词、实体保护与坐标映射引擎

enum BigBangGranularity: String, CaseIterable, Equatable, Hashable {
    case word = "word"
    case character = "char"
    case line = "line"

    var title: String {
        switch self {
        case .word: return "按词"
        case .character: return "按字"
        case .line: return "按行"
        }
    }

    var shortTitle: String {
        switch self {
        case .word: return "词"
        case .character: return "字"
        case .line: return "行"
        }
    }
}

struct BigBangTextToken: Identifiable, Equatable, Hashable {
    let id: Int
    let text: String
    let isLineBreak: Bool
    let lineIndex: Int
    /// 在源字符串中的 UTF-16 偏移，用于 .character 模式下区分原词内连字与跨空格拆字
    let utf16Location: Int
    let utf16Length: Int
    let granularity: BigBangGranularity
}

struct BigBangImageWordBox: Identifiable, Equatable {
    let id: Int
    let text: String
    /// 归一化矩形（左上角原点，x/y/width/height ∈ [0, 1]，可直接映射至 SwiftUI 图片绘制区）
    let normalizedRect: CGRect
    let lineIndex: Int
    let granularity: BigBangGranularity
}

enum BigBangTokenizer {
    /// 原子实体保护正则（优先级从长/特异到通用：URL -> 邮箱 -> UUID -> IPv4 -> 大陆手机号 -> 代码标识符/版本号）
    private static let protectedEntityRegex: NSRegularExpression? = {
        let pattern = [
            #"https?://[^\s\u4E00-\u9FFF\u3000-\u303F\uFF00-\uFFEF<>"'`（）()【】\[\]{}]+"#,
            #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#,
            #"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b"#,
            #"(?<!\d)1[3-9]\d(?:[- ]?\d{4}){2}(?!\d)"#,
            #"\b[A-Za-z0-9]+(?:[_\-.][A-Za-z0-9]+)+\b"#
        ].joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// 将文本按指定粒度拆解为可点选/划选的 BigBang token（保留换行占位以还原段落结构）
    static func tokenize(_ text: String, granularity: BigBangGranularity) -> [BigBangTextToken] {
        guard !text.isEmpty else { return [] }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var result: [BigBangTextToken] = []
        var nextID = 0

        for (lineIdx, rawLine) in lines.enumerated() {
            if lineIdx > 0 && granularity != .line {
                result.append(
                    BigBangTextToken(
                        id: nextID,
                        text: "\n",
                        isLineBreak: true,
                        lineIndex: lineIdx,
                        utf16Location: 0,
                        utf16Length: 0,
                        granularity: granularity
                    )
                )
                nextID += 1
            }

            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            switch granularity {
            case .line:
                let nsLen = (trimmed as NSString).length
                result.append(
                    BigBangTextToken(
                        id: nextID,
                        text: trimmed,
                        isLineBreak: false,
                        lineIndex: lineIdx,
                        utf16Location: 0,
                        utf16Length: nsLen,
                        granularity: .line
                    )
                )
                nextID += 1

            case .character:
                var idx = rawLine.startIndex
                while idx < rawLine.endIndex {
                    let next = rawLine.index(after: idx)
                    let ch = String(rawLine[idx..<next])
                    if !ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let range = NSRange(idx..<next, in: rawLine)
                        result.append(
                            BigBangTextToken(
                                id: nextID,
                                text: ch,
                                isLineBreak: false,
                                lineIndex: lineIdx,
                                utf16Location: range.location,
                                utf16Length: range.length,
                                granularity: .character
                            )
                        )
                        nextID += 1
                    }
                    idx = next
                }

            case .word:
                let pairs = tokenizeLineWordRanges(rawLine)
                for (tokStr, range) in pairs {
                    let nsRange = NSRange(range, in: rawLine)
                    result.append(
                        BigBangTextToken(
                            id: nextID,
                            text: tokStr,
                            isLineBreak: false,
                            lineIndex: lineIdx,
                            utf16Location: nsRange.location,
                            utf16Length: nsRange.length,
                            granularity: .word
                        )
                    )
                    nextID += 1
                }
            }
        }
        return result
    }

    /// 对单行文本执行原子实体保护 + `NLTokenizer(unit: .word)` 分词，返回词串与在原行中的 exact `Range<String.Index>`
    static func tokenizeWithRanges(_ line: String, granularity: BigBangGranularity) -> [(text: String, range: Range<String.Index>)] {
        switch granularity {
        case .line:
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let r = line.range(of: trimmed) else { return [] }
            return [(trimmed, r)]

        case .character:
            var out: [(String, Range<String.Index>)] = []
            var idx = line.startIndex
            while idx < line.endIndex {
                let next = line.index(after: idx)
                let sub = String(line[idx..<next])
                if !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append((sub, idx..<next))
                }
                idx = next
            }
            return out

        case .word:
            return tokenizeLineWordRanges(line)
        }
    }

    private static func tokenizeLineWordRanges(_ line: String) -> [(text: String, range: Range<String.Index>)] {
        let fullNSRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard fullNSRange.length > 0 else { return [] }

        let matches = protectedEntityRegex?.matches(in: line, options: [], range: fullNSRange) ?? []
        var entityRanges: [Range<String.Index>] = []
        var lastEnd = line.startIndex
        for m in matches {
            guard var swiftRange = Range(m.range, in: line) else { continue }
            if swiftRange.lowerBound < lastEnd { continue }
            // 若保护的是 URL，剥离尾部常见标点符号
            if line[swiftRange].hasPrefix("http") {
                swiftRange = trimTrailingURLPunctuation(in: line, range: swiftRange)
            }
            guard swiftRange.lowerBound < swiftRange.upperBound else { continue }
            entityRanges.append(swiftRange)
            lastEnd = swiftRange.upperBound
        }

        var output: [(String, Range<String.Index>)] = []
        var cursor = line.startIndex

        for entityRange in entityRanges {
            if cursor < entityRange.lowerBound {
                appendNaturalWords(in: line, range: cursor..<entityRange.lowerBound, into: &output)
            }
            let raw = String(line[entityRange])
            if !raw.isEmpty {
                output.append((raw, entityRange))
            }
            cursor = entityRange.upperBound
        }

        if cursor < line.endIndex {
            appendNaturalWords(in: line, range: cursor..<line.endIndex, into: &output)
        }

        // 若全行均被过滤（如纯符号行），按非空连续字符段保底产出，避免预览为空
        if output.isEmpty {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let r = line.range(of: trimmed) {
                output.append((trimmed, r))
            }
        }
        return output
    }

    private static func trimTrailingURLPunctuation(in line: String, range: Range<String.Index>) -> Range<String.Index> {
        let trailingPunct: Set<Character> = [".", ",", ";", ":", "!", "?", "。", "，", "；", "：", "！", "？", "）", ")", "]", "}", "\""]
        var end = range.upperBound
        while end > range.lowerBound {
            let prev = line.index(before: end)
            if trailingPunct.contains(line[prev]) {
                end = prev
            } else {
                break
            }
        }
        return range.lowerBound..<end
    }

    private static func appendNaturalWords(
        in line: String,
        range: Range<String.Index>,
        into output: inout [(String, Range<String.Index>)]
    ) {
        let sub = String(line[range])
        guard !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = line
        tokenizer.enumerateTokens(in: range) { tokRange, _ in
            let piece = String(line[tokRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                output.append((piece, tokRange))
            }
            return true
        }
    }

    /// 按原始出现顺序智能拼合所选文字词块（相邻英文/数字词自动补单空格，中文紧贴，跨行保留换行）
    static func assembleSelected(_ tokens: [BigBangTextToken], selectedIDs: Set<Int>) -> String {
        let picked = tokens.filter { !$0.isLineBreak && selectedIDs.contains($0.id) }
        guard let first = picked.first else { return "" }

        var out = first.text
        var prev = first

        for cur in picked.dropFirst() {
            if cur.lineIndex > prev.lineIndex {
                out.append("\n")
            } else if shouldInsertSpaceBetween(
                prevText: prev.text,
                curText: cur.text,
                areAdjacentCharacters: cur.granularity == .character
                    && prev.granularity == .character
                    && cur.utf16Location == prev.utf16Location + prev.utf16Length
            ) {
                out.append(" ")
            }
            out.append(cur.text)
            prev = cur
        }
        return out
    }

    /// 智能拼合图片原位 OCR 选中的词框
    static func assembleSelectedImageBoxes(_ boxes: [BigBangImageWordBox], selectedIDs: Set<Int>) -> String {
        let picked = boxes.filter { selectedIDs.contains($0.id) }
        guard let first = picked.first else { return "" }

        var out = first.text
        var prev = first

        for cur in picked.dropFirst() {
            if cur.lineIndex > prev.lineIndex {
                out.append("\n")
            } else if shouldInsertSpaceBetween(
                prevText: prev.text,
                curText: cur.text,
                areAdjacentCharacters: false
            ) {
                out.append(" ")
            }
            out.append(cur.text)
            prev = cur
        }
        return out
    }

    private static func shouldInsertSpaceBetween(
        prevText: String,
        curText: String,
        areAdjacentCharacters: Bool
    ) -> Bool {
        if areAdjacentCharacters {
            return false
        }
        guard let lastScalar = prevText.unicodeScalars.last,
              let firstScalar = curText.unicodeScalars.first else {
            return false
        }
        return isLatinOrDigitTokenBoundary(lastScalar) && isLatinOrDigitTokenBoundary(firstScalar)
    }

    private static func isLatinOrDigitTokenBoundary(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 128 {
            return (scalar.value >= 48 && scalar.value <= 57)   // 0-9
                || (scalar.value >= 65 && scalar.value <= 90)   // A-Z
                || (scalar.value >= 97 && scalar.value <= 122)  // a-z
                || scalar.value == 95                           // _
                || scalar.value == 47                           // /
        }
        return false
    }

    // MARK: - 3. 图片原位 OCR 坐标精确映射（AspectFit 画幅对齐）

    /// 计算图片以 `.scaledToFit()` 绘入容器 `containerSize` 时实际占用的像素矩形
    static func aspectFitImageRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let drawW = imageSize.width * scale
        let drawH = imageSize.height * scale
        let drawX = (containerSize.width - drawW) * 0.5
        let drawY = (containerSize.height - drawH) * 0.5
        return CGRect(x: drawX, y: drawY, width: drawW, height: drawH)
    }

    /// 将左上角归一化词框 `normalized` 映射至实际图片渲染区域 `imageRect` 内的屏幕坐标
    static func mapNormalizedBox(_ normalized: CGRect, into imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + normalized.minX * imageRect.width,
            y: imageRect.minY + normalized.minY * imageRect.height,
            width: normalized.width * imageRect.width,
            height: normalized.height * imageRect.height
        )
    }

    /// 计算图片原位词框胶囊在画面内的最终显示及命中对齐矩形（最小 `20×18` 并将边缘胶囊夹紧在 `imageRect` 内）
    static func displayImageBoxRect(for box: BigBangImageWordBox, in imageRect: CGRect) -> CGRect {
        let mapped = mapNormalizedBox(box.normalizedRect, into: imageRect)
        let chipW = min(imageRect.width, max(20, mapped.width + 6))
        let chipH = min(imageRect.height, max(18, mapped.height + 4))
        let clampedX = min(max(imageRect.minX + chipW * 0.5, mapped.midX), imageRect.maxX - chipW * 0.5)
        let clampedY = min(max(imageRect.minY + chipH * 0.5, mapped.midY), imageRect.maxY - chipH * 0.5)
        return CGRect(
            x: clampedX - chipW * 0.5,
            y: clampedY - chipH * 0.5,
            width: chipW,
            height: chipH
        )
    }

    /// 计算图片原位词框的悬停/点选/划选命中矩形（按比例覆盖选中态 `1.04x` / 悬停态 `1.03x` 外扩边缘）
    static func displayImageBoxHitRect(for box: BigBangImageWordBox, in imageRect: CGRect) -> CGRect {
        let chipRect = displayImageBoxRect(for: box, in: imageRect)
        let padX = max(2.0, chipRect.width * 0.02 + 1.0)
        let padY = max(2.0, chipRect.height * 0.02 + 1.0)
        return chipRect.insetBy(dx: -padX, dy: -padY)
    }

    /// 按字素簇（Character）边界安全截取不超过 `maxUTF16` 码元的前缀，杜绝 emoji/CRLF 截断归零
    static func utf16Prefix(_ text: String, maxUTF16: Int) -> String {
        guard maxUTF16 > 0 else { return "" }
        guard text.utf16.count > maxUTF16 else { return text }
        var endIdx = text.startIndex
        var utf16Acc = 0
        while endIdx < text.endIndex {
            let nextIdx = text.index(after: endIdx)
            let stepLen = text[endIdx..<nextIdx].utf16.count
            if utf16Acc + stepLen > maxUTF16 {
                break
            }
            utf16Acc += stepLen
            endIdx = nextIdx
        }
        return String(text[..<endIdx])
    }
}
