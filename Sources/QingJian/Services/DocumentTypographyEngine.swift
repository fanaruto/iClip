import Foundation

/// 学术科研、法律翻译、跨境外贸与出版编辑专属：PDF 断行智能愈合与中英混排盘古清洗引擎
enum DocumentTypographyEngine {
    /// 句末合法终止标点集合（行尾若是这些字符且下一行疑似新段，则保留段落边界）
    private static let sentenceEndCharacters: Set<Character> = [
        "。", "！", "？", "；", "：", ".", "!", "?", ";", ":", "”", "\"", "’", "）", ")", "】", "]"
    ]

    /// 跨行英文连字符需要保留连字符 `-` 的常见复合词前缀
    private static let hyphenKeepPrefixes: [String] = [
        "state-of-the", "end-to", "up-to", "out-of", "one-to", "peer-to",
        "self", "non", "multi", "cross", "inter", "intra", "co", "re", "pre", "post",
        "high", "low", "real", "open", "long", "short", "well", "full", "half", "zero"
    ]

    private static let listBulletRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•·]|\d+[.)、]|[（(][一二三四五六七八九十\d]+[)）]|[一二三四五六七八九十]+、)\s*"#
    )

    // 中英混排粘连检测与替换正则（汉字与 ASCII 字母/数字之间补空格）
    private static let cjkLeftRegex = try! NSRegularExpression(
        pattern: #"([\u4e00-\u9fa5])([A-Za-z0-9@#\$])"#
    )
    private static let cjkRightRegex = try! NSRegularExpression(
        pattern: #"([A-Za-z0-9%])([\u4e00-\u9fa5])"#
    )

    // MARK: - 主分析入口

    static func analyze(_ rawText: String) -> [FinanceQuickAction] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6, rawText.utf16.count <= 32_768 else { return [] }

        // 排除代码、JSON、URL、cURL 与 Markdown 表格
        if looksLikeCodeOrStructuredData(trimmed) {
            return []
        }

        var actions: [FinanceQuickAction] = []

        // 1. PDF 硬折行愈合检测
        if looksLikeBrokenPDFParagraphs(rawText) {
            let healed = healPDFLineBreaks(rawText)
            if healed != trimmed {
                // 若愈合后还包含中英粘连，顺便提供一个「断行愈合 + 中英美化」一步到位动作
                actions.append(FinanceQuickAction(
                    id: "doc-pdf-heal",
                    title: "缝合 PDF 断行",
                    symbolName: "doc.text.below.ecg",
                    resultText: healed,
                    toastText: "已智能缝合 PDF 跨行断句并保留真实分段"
                ))
            }
        }

        // 2. 中英数字盘古空格排版规范化
        if containsUnspacedCJKAndLatin(trimmed) {
            let base = actions.first?.resultText ?? trimmed
            let spaced = applyPanguSpacing(base)
            if spaced != trimmed {
                actions.append(FinanceQuickAction(
                    id: "doc-pangu-space",
                    title: actions.isEmpty ? "中英空格美化" : "缝合+中英美化",
                    symbolName: "text.justify",
                    resultText: spaced,
                    toastText: "已完成中英数字间距排版美化"
                ))
            }
        }

        // 修正 SF Symbol 标准有效名称
        return actions.map { act in
            let validSym = (act.id == "doc-pdf-heal") ? "text.redaction" : "character.textbox"
            return FinanceQuickAction(
                id: act.id,
                title: act.title,
                symbolName: validSym,
                resultText: act.resultText,
                toastText: act.toastText
            )
        }
    }

    // MARK: - PDF 断行愈合核心算法

    static func healPDFLineBreaks(_ rawText: String) -> String {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let rawLines = normalized.components(separatedBy: "\n")
        var paragraphs: [String] = []
        var buffer = ""

        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // 空行代表明确的段落分隔
            if line.isEmpty {
                if !buffer.isEmpty {
                    paragraphs.append(buffer)
                    buffer = ""
                }
                continue
            }

            if buffer.isEmpty {
                buffer = line
                continue
            }

            // 如果新行是明确的列表编号开头（如 "1. "、"- "、"（一）"），则独立成新段
            if isListItemLine(line) {
                paragraphs.append(buffer)
                buffer = line
                continue
            }

            // 将 line 缝合进 buffer
            buffer = joinTwoBrokenLines(prev: buffer, next: line)
        }

        if !buffer.isEmpty {
            paragraphs.append(buffer)
        }

        return paragraphs.joined(separator: "\n\n")
    }

    private static func joinTwoBrokenLines(prev: String, next: String) -> String {
        guard let lastChar = prev.last, let firstNext = next.first else {
            return prev + next
        }

        // 处理英文行尾连字符断词（例如 "archi-" + "tecture" 或 "state-of-the-" + "art"）
        if lastChar == "-", prev.count >= 2 {
            let beforeHyphen = prev.dropLast()
            if let charBeforeHyphen = beforeHyphen.last,
               charBeforeHyphen.isASCII && charBeforeHyphen.isLetter,
               firstNext.isASCII && firstNext.isLetter {
                let lowerTail = prev.dropLast().lowercased()
                let shouldKeepHyphen = hyphenKeepPrefixes.contains { prefix in
                    lowerTail == prefix || lowerTail.hasSuffix(" " + prefix) || lowerTail.hasSuffix("-" + prefix)
                }
                if shouldKeepHyphen {
                    return prev + next
                } else {
                    return String(beforeHyphen) + next
                }
            }
        }

        // 判断中英文边界：若两侧有一侧是 CJK 汉字或全角标点，直接无缝拼接；若两侧都是 ASCII 字符/标点则补单个空格
        if isCJKOrFullWidth(lastChar) || isCJKOrFullWidth(firstNext) {
            return prev + next
        } else {
            return prev + " " + next
        }
    }

    // MARK: - 盘古中英数字间距美化（保护 URL 不被拆散）

    static func applyPanguSpacing(_ text: String) -> String {
        // 按空白与换行保留 URL token 不被改动
        let lines = text.components(separatedBy: "\n")
        let processedLines = lines.map { line -> String in
            if line.contains("http://") || line.contains("https://") {
                return applyPanguProtectingURLs(in: line)
            }
            return applyPanguRaw(line)
        }
        return processedLines.joined(separator: "\n")
    }

    private static func applyPanguProtectingURLs(in line: String) -> String {
        guard let urlRegex = try? NSRegularExpression(pattern: #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#) else {
            return applyPanguRaw(line)
        }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = urlRegex.matches(in: line, options: [], range: nsRange)
        guard !matches.isEmpty else { return applyPanguRaw(line) }

        var result = ""
        var currentIndex = line.startIndex
        for match in matches {
            guard let urlRange = Range(match.range, in: line) else { continue }
            let before = String(line[currentIndex..<urlRange.lowerBound])
            let urlStr = String(line[urlRange])
            result += applyPanguRaw(before)
            if let last = result.last, isCJKCharacter(last) {
                result += " "
            }
            result += urlStr
            currentIndex = urlRange.upperBound
            if currentIndex < line.endIndex, isCJKCharacter(line[currentIndex]) {
                result += " "
            }
        }
        if currentIndex < line.endIndex {
            result += applyPanguRaw(String(line[currentIndex...]))
        }
        return result
    }

    private static func applyPanguRaw(_ segment: String) -> String {
        var out = segment
        var range = NSRange(out.startIndex..<out.endIndex, in: out)
        out = cjkLeftRegex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "$1 $2")
        range = NSRange(out.startIndex..<out.endIndex, in: out)
        out = cjkRightRegex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "$1 $2")
        return out
    }

    // MARK: - 启发式检测与防误判守卫

    static func looksLikeBrokenPDFParagraphs(_ rawText: String) -> Bool {
        guard rawText.contains("\n") else { return false }
        let lines = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let nonEmpty = lines.filter { !$0.isEmpty }
        guard nonEmpty.count >= 2 else { return false }

        var brokenContinuationCount = 0
        for i in 0..<(lines.count - 1) {
            let cur = lines[i]
            let nxt = lines[i + 1]
            guard !cur.isEmpty, !nxt.isEmpty, !isListItemLine(nxt) else { continue }

            let hasEnoughWidth = containsCJK(cur) ? (cur.count >= 10) : (cur.count >= 24)
            guard hasEnoughWidth else { continue }

            if let last = cur.last, !sentenceEndCharacters.contains(last) {
                brokenContinuationCount += 1
            }
        }

        return brokenContinuationCount >= 1
    }

    static func containsUnspacedCJKAndLatin(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return cjkLeftRegex.firstMatch(in: text, options: [], range: range) != nil
            || cjkRightRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func looksLikeCodeOrStructuredData(_ trimmed: String) -> Bool {
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return true
        }
        if trimmed.lowercased().hasPrefix("curl ") || trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return true
        }
        // 代码与配置典型特征
        let codeSignals = ["func ", "let ", "var ", "import ", "class ", "struct ", "def ", "const ", "return ", "=>", "};", "|---"]
        if codeSignals.contains(where: { trimmed.contains($0) }) {
            return true
        }
        // 文件路径
        if !trimmed.contains("\n") && (trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")) {
            return true
        }
        return false
    }

    private static func isListItemLine(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return listBulletRegex.firstMatch(in: line, options: [], range: range) != nil
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }

    private static func isCJKCharacter(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }

    private static func isCJKOrFullWidth(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (v >= 0x4E00 && v <= 0x9FFF)     // CJK 汉字
                || (v >= 0x3000 && v <= 0x303F)     // 中文标点
                || (v >= 0xFF00 && v <= 0xFFEF)     // 全角字符
        }
    }
}
