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

        // 0. AI 回复 / 笔记文档「去 Markdown 纯文本」（一键剥除 **加粗**、### 标题、[链接](url)、`代码` 直发微信/飞书/公文）
        if looksLikeMarkdownDocument(rawText),
           let stripped = stripMarkdownToCleanText(rawText),
           stripped != trimmed {
            actions.append(FinanceQuickAction(
                id: "doc-strip-markdown",
                title: "去 Markdown 纯文本",
                symbolName: "doc.plaintext",
                resultText: stripped,
                toastText: "已剥除 Markdown 语法符号，转为干净可读纯文本"
            ))
        }

        // 0.5 OCR / 旧文档「全半角与中西文标点精排」（自动还原 `２０２６` 全角数字字母并修正汉字旁半角 `,!():` 标点，保护小数与 URL）
        if let punctCleaned = normalizeWidthAndCJKPunctuation(trimmed) {
            let polished = containsUnspacedCJKAndLatin(punctCleaned) ? applyPanguSpacing(punctCleaned) : punctCleaned
            actions.append(FinanceQuickAction(
                id: "doc-normalize-punct",
                title: "全半角与标点精排",
                symbolName: "textformat.abc.dottedunderline",
                resultText: polished,
                toastText: "已规整全角字母数字、中西文标点与中英间距"
            ))
        }

        // 1. PDF 硬折行愈合检测（排除 Markdown 文档避免误缝标题）
        if actions.isEmpty && looksLikeBrokenPDFParagraphs(rawText) {
            let healed = healPDFLineBreaks(rawText)
            if healed != trimmed {
                actions.append(FinanceQuickAction(
                    id: "doc-pdf-heal",
                    title: "缝合 PDF 断行",
                    symbolName: "text.redaction",
                    resultText: healed,
                    toastText: "已智能缝合 PDF 跨行断句并保留真实分段"
                ))
            }
        }

        // 2. 中英数字盘古空格排版规范化
        if containsUnspacedCJKAndLatin(trimmed) {
            let base = actions.first?.resultText ?? trimmed
            let spaced = applyPanguSpacing(base)
            if spaced != base && spaced != trimmed {
                actions.append(FinanceQuickAction(
                    id: "doc-pangu-space",
                    title: actions.isEmpty ? "中英空格美化" : (actions.first?.id == "doc-pdf-heal" ? "缝合+中英美化" : "中英空格美化"),
                    symbolName: "character.textbox",
                    resultText: spaced,
                    toastText: "已完成中英数字间距排版美化"
                ))
            }
        }

        return actions
    }

    // MARK: - AI 回复与笔记 Markdown 语法剥除净文器

    private static let mdHeadingLineRegex = try! NSRegularExpression(pattern: #"^(\s*)(#{1,6})\s+\S"#)
    private static let mdHeadingStripRegex = try! NSRegularExpression(pattern: #"^(\s*)#{1,6}\s+"#)
    private static let mdTaskUncheckedRegex = try! NSRegularExpression(pattern: #"^(\s*)[-*+]\s+\[\s\]\s+"#)
    private static let mdTaskCheckedRegex = try! NSRegularExpression(pattern: #"^(\s*)[-*+]\s+\[[xX]\]\s+"#)
    private static let mdUnorderedListRegex = try! NSRegularExpression(pattern: #"^(\s*)[-*+]\s+"#)
    private static let mdBlockquoteRegex = try! NSRegularExpression(pattern: #"^(\s*)(?:>\s?)+"#)
    private static let mdHrRegex = try! NSRegularExpression(pattern: #"^\s*(?:-\s*-\s*-[-\s]*|_\s*_\s*_[_\s]*|\*\s*\*\s*\*[\*\s]*)$"#)
    private static let mdImageRegex = try! NSRegularExpression(pattern: #"!\s*\[([^\]]*)\]\(([^)\n]+)\)"#)
    private static let mdLinkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#)
    private static let mdBoldStarRegex = try! NSRegularExpression(pattern: #"\*\*([^\s*](?:.*?[^\s*])?)\*\*"#)
    private static let mdBoldUnderRegex = try! NSRegularExpression(pattern: #"__([^\s_](?:.*?[^\s_])?)__"#)
    private static let mdStrikeRegex = try! NSRegularExpression(pattern: #"~~([^\s~](?:.*?[^\s~])?)~~"#)
    private static let mdInlineCodeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let mdMultiBlankRegex = try! NSRegularExpression(pattern: #"\n{3,}"#)

    static func looksLikeMarkdownDocument(_ rawText: String) -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6, !trimmed.hasPrefix("#!") else { return false }
        if CronAndPathHelper.explainCronExpression(trimmed) != nil { return false }

        let lines = trimmed.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.count == 2 && lines[0].hasPrefix("# ") && CronAndPathHelper.explainCronExpression(lines[1]) != nil {
            return false
        }

        var score = 0
        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let boldCount = mdBoldStarRegex.numberOfMatches(in: trimmed, range: fullRange)
            + mdBoldUnderRegex.numberOfMatches(in: trimmed, range: fullRange)
        score += boldCount * 2
        score += mdLinkRegex.numberOfMatches(in: trimmed, range: fullRange) * 2
        score += mdStrikeRegex.numberOfMatches(in: trimmed, range: fullRange) * 2
        if mdInlineCodeRegex.firstMatch(in: trimmed, range: fullRange) != nil {
            score += 1
        }

        var fenceCount = 0
        for line in lines {
            let lr = NSRange(line.startIndex..<line.endIndex, in: line)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenceCount += 1
                continue
            }
            if let m = mdHeadingLineRegex.firstMatch(in: line, range: lr),
               let hashesRange = Range(m.range(at: 2), in: line) {
                score += (line[hashesRange].count >= 2) ? 2 : 1
            } else if mdUnorderedListRegex.firstMatch(in: line, range: lr) != nil {
                score += 1
            } else if mdBlockquoteRegex.firstMatch(in: line, range: lr) != nil {
                score += 1
            }
        }
        if fenceCount >= 2 { score += 2 }
        return score >= 2
    }

    static func stripMarkdownToCleanText(_ rawText: String) -> String? {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var outLines: [String] = []
        outLines.reserveCapacity(lines.count)
        var inFence = false

        for rawLine in lines {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                outLines.append(rawLine)
                continue
            }

            var line = rawLine
            let fullLineRange = { NSRange(line.startIndex..<line.endIndex, in: line) }
            if mdHrRegex.firstMatch(in: line, range: fullLineRange()) != nil {
                outLines.append("")
                continue
            }
            line = mdBlockquoteRegex.stringByReplacingMatches(in: line, range: fullLineRange(), withTemplate: "$1")
            line = mdHeadingStripRegex.stringByReplacingMatches(in: line, range: fullLineRange(), withTemplate: "$1")
            if mdTaskUncheckedRegex.firstMatch(in: line, range: fullLineRange()) != nil {
                line = mdTaskUncheckedRegex.stringByReplacingMatches(in: line, range: fullLineRange(), withTemplate: "$1☐ ")
            } else if mdTaskCheckedRegex.firstMatch(in: line, range: fullLineRange()) != nil {
                line = mdTaskCheckedRegex.stringByReplacingMatches(in: line, range: fullLineRange(), withTemplate: "$1☑ ")
            } else {
                line = mdUnorderedListRegex.stringByReplacingMatches(in: line, range: fullLineRange(), withTemplate: "$1• ")
            }

            // 图片语法 ![alt](url)
            let imgMatches = mdImageRegex.matches(in: line, range: fullLineRange())
            for m in imgMatches.reversed() {
                guard let fullR = Range(m.range, in: line),
                      let altR = Range(m.range(at: 1), in: line) else { continue }
                let alt = line[altR].trimmingCharacters(in: .whitespaces)
                line.replaceSubrange(fullR, with: alt.isEmpty ? "" : "[图片: \(alt)]")
            }

            // 链接语法 [title](https://...)
            let linkMatches = mdLinkRegex.matches(in: line, range: fullLineRange())
            for m in linkMatches.reversed() {
                guard let fullR = Range(m.range, in: line),
                      let titleR = Range(m.range(at: 1), in: line),
                      let urlR = Range(m.range(at: 2), in: line) else { continue }
                let label = line[titleR].trimmingCharacters(in: .whitespaces)
                let url = String(line[urlR])
                line.replaceSubrange(fullR, with: (label == url || label.isEmpty) ? url : "\(label) (\(url))")
            }

            line = mdBoldStarRegex.stringByReplacingMatches(in: line, range: fullLineRange(), withTemplate: "$1")
            line = mdBoldUnderRegex.stringByReplacingMatches(in: line, range: fullLineRange(), withTemplate: "$1")
            line = mdStrikeRegex.stringByReplacingMatches(in: line, range: fullLineRange(), withTemplate: "$1")
            line = mdInlineCodeRegex.stringByReplacingMatches(in: line, range: fullLineRange(), withTemplate: "$1")
            outLines.append(line)
        }

        var joined = outLines.joined(separator: "\n")
        joined = mdMultiBlankRegex.stringByReplacingMatches(
            in: joined,
            range: NSRange(joined.startIndex..<joined.endIndex, in: joined),
            withTemplate: "\n\n"
        )
        let cleaned = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
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

    /// 将全角 ASCII 字母/数字/算术符号还原为半角，并将汉字两侧误用的半角英文标点精准规整为标准中文标点（严格保护 URL、小数 `3.14` 与时间 `18:30`）
    static func normalizeWidthAndCJKPunctuation(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 32_768 else { return nil }
        var fixCount = 0

        // Step 1: 全角 ASCII 字母/数字与常见技术符号 -> 半角
        let fullwidthTechSymbols: Set<UInt32> = [
            0xFF03, 0xFF04, 0xFF05, 0xFF06, 0xFF0B, 0xFF0D, 0xFF0F, 0xFF1D, 0xFF20
        ]
        var halfConverted = String.UnicodeScalarView()
        halfConverted.reserveCapacity(raw.unicodeScalars.count)
        for sc in raw.unicodeScalars {
            let v = sc.value
            if (v >= 0xFF10 && v <= 0xFF19)
                || (v >= 0xFF21 && v <= 0xFF3A)
                || (v >= 0xFF41 && v <= 0xFF5A)
                || fullwidthTechSymbols.contains(v),
               let mapped = UnicodeScalar(v - 0xFEE0) {
                halfConverted.append(mapped)
                fixCount += 1
            } else if v == 0x3000 {
                halfConverted.append(UnicodeScalar(0x0020)!)
                fixCount += 1
            } else {
                halfConverted.append(sc)
            }
        }

        let stage1 = String(halfConverted)
        let chars = Array(stage1)
        let n = chars.count
        guard n > 0 else { return nil }

        // 标记 URL 区间，防止误改 URL 中的符号
        var inURL = Array(repeating: false, count: n)
        var idx = 0
        while idx < n {
            if idx + 7 < n {
                let prefix7 = String(chars[idx..<(idx + 7)]).lowercased()
                let prefix8 = (idx + 8 <= n) ? String(chars[idx..<(idx + 8)]).lowercased() : ""
                if prefix7 == "http://" || prefix8 == "https://" {
                    while idx < n && !chars[idx].isWhitespace {
                        inURL[idx] = true
                        idx += 1
                    }
                    continue
                }
            }
            idx += 1
        }

        func isHan(_ c: Character?) -> Bool {
            guard let c else { return false }
            return c.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        }

        // Step 2: 规整成对半角括号 `(...)`（当括号内含汉字且非函数调用标识符时转为 `（...）`）
        var work = chars
        var openStack: [Int] = []
        for i in 0..<n where !inURL[i] {
            if work[i] == "(" {
                openStack.append(i)
            } else if work[i] == ")", let openIdx = openStack.popLast() {
                let prevChar: Character? = openIdx > 0 ? work[openIdx - 1] : nil
                let isFuncCall = prevChar.map { ($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")) } ?? false
                let innerSlice = work[(openIdx + 1)..<i]
                if !isFuncCall && !innerSlice.contains("\n") && innerSlice.contains(where: { isHan($0) }) {
                    work[openIdx] = "（"
                    work[i] = "）"
                    fixCount += 1
                }
            }
        }

        // Step 3: 规整紧邻汉字的 `,` `;` `?` `!` `:` `.`
        var out: [Character] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            let ch = work[i]
            if inURL[i] {
                out.append(ch)
                i += 1
                continue
            }
            let prevNonSpace: Character? = out.last(where: { $0 != " " && $0 != "\t" })
            let nextNonSpace: Character? = {
                var k = i + 1
                while k < n && (work[k] == " " || work[k] == "\t") { k += 1 }
                return k < n ? work[k] : nil
            }()

            var replaced: Character? = nil
            switch ch {
            case ",":
                if isHan(prevNonSpace) || isHan(nextNonSpace) { replaced = "，" }
            case ";":
                if isHan(prevNonSpace) || isHan(nextNonSpace) { replaced = "；" }
            case "?":
                if isHan(prevNonSpace) || isHan(nextNonSpace) { replaced = "？" }
            case "!":
                if (isHan(prevNonSpace) || isHan(nextNonSpace)) && nextNonSpace != "=" { replaced = "！" }
            case ":":
                if isHan(prevNonSpace) && nextNonSpace != "/" && !(nextNonSpace?.isNumber ?? false) {
                    replaced = "："
                }
            case ".":
                let nextImmediate: Character? = (i + 1 < n) ? work[i + 1] : nil
                let isDecimalOrExt = (nextImmediate?.isASCII == true) && (nextImmediate?.isLetter == true || nextImmediate?.isNumber == true)
                if isHan(prevNonSpace) && !isDecimalOrExt && (nextNonSpace == nil || nextNonSpace == "\n" || isHan(nextNonSpace)) {
                    replaced = "。"
                }
            default:
                break
            }

            if let rep = replaced {
                if out.last == " " && isHan(prevNonSpace) {
                    out.removeLast()
                }
                out.append(rep)
                fixCount += 1
                if i + 1 < n && work[i + 1] == " " {
                    i += 2
                    continue
                }
            } else {
                out.append(ch)
            }
            i += 1
        }

        let finalStr = String(out)
        guard fixCount >= 2, finalStr != raw else { return nil }
        return finalStr
    }
}
