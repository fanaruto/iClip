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

// MARK: - 2. 锤子大爆炸（Big Bang）智能语义聚合、原位二次爆炸拆分与坐标映射引擎

enum BigBangGranularity: String, CaseIterable, Equatable, Hashable {
    case smart = "smart"
    case word = "word"
    case character = "char"
    case line = "line"

    var title: String {
        switch self {
        case .smart: return "智能组合"
        case .word: return "按词"
        case .character: return "按字"
        case .line: return "按行"
        }
    }

    var shortTitle: String {
        switch self {
        case .smart: return "智"
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
    /// 在源行字符串中的 UTF-16 偏移，用于精确还原原词内紧贴与跨空格拼接
    let utf16Location: Int
    let utf16Length: Int
    let granularity: BigBangGranularity
    /// 原位二次爆炸动效代数（0 表示初始静态词块，>0 表示刚从父词块炸出的子词块）
    var burstGeneration: Int = 0
    /// 相对父词块中心的横向离心展开索引（例如 3 个子词块为 -1.0, 0.0, +1.0）
    var burstSpreadIndex: Double = 0.0
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
    /// 按词模式原子实体保护正则（URL -> 邮箱 -> UUID -> IPv4 -> 大陆手机号 -> 代码标识符/版本号）
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

    /// 智能组合模式复合实体保护正则（额外保护文件路径、日期时间、分辨率尺寸、比值、金额、带单位数值、快捷键与斜杠对）
    private static let smartEntityRegex: NSRegularExpression? = {
        let pattern = [
            #"https?://[^\s\u4E00-\u9FFF\u3000-\u303F\uFF00-\uFFEF<>"'`（）()【】\[\]{}]+"#,
            #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            #"(?:~|/[A-Za-z0-9._\-]+)(?:/[A-Za-z0-9._\-\u4E00-\u9FFF]+)+"#,
            #"[A-Za-z]:\\(?:[^\s\\/:*?"<>|\r\n]+\\)*[^\s\\/:*?"<>|\r\n]+"#,
            #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#,
            #"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b"#,
            #"\b\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}日?(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?"#,
            #"\b\d{1,2}:\d{2}(?::\d{2})?\b"#,
            #"[¥￥$€£]\s*\d[\d,]*(?:\.\d+)?(?:\s*[万亿元])?"#,
            #"\b\d[\d,]*(?:\.\d+)?\s*[×xX*]\s*\d[\d,]*(?:\.\d+)?\b"#,
            #"\b\d+(?:/\d+)+\b"#,
            #"\b\d[\d,]*(?:\.\d+)?\s*(?:小时前|分钟前|秒前|天前|周前|个月前|年前|小时|分钟|毫秒|ms|KB|MB|GB|TB|Hz|fps|px|pt|rem|em|%|折|万元|亿元|元|万|亿|字|条|项|处|个|次|版|轮)"#,
            #"(?<!\d)1[3-9]\d(?:[- ]?\d{4}){2}(?!\d)"#,
            #"[⌘⌥⌃⇧]+[A-Za-z0-9↵⌫⇥]+"#,
            #"@[A-Za-z0-9_\u4E00-\u9FFF]+"#,
            #"\b[A-Za-z0-9]+(?:[_\-./][A-Za-z0-9]+)+\b"#
        ].joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let cjkHardStopParticles: Set<String> = [
        "的", "了", "着", "过", "吗", "呢", "吧", "啊", "呀", "哦",
        "和", "与", "或", "及", "而", "但", "却", "把", "被", "让",
        "给", "向", "从", "在", "对", "于", "是", "有", "为", "供", "并", "且"
    ]

    private static let cjkClauseFunctionWords: Set<String> = [
        "而且", "但是", "虽然", "因为", "所以", "如果", "或者", "以及",
        "应该", "可以", "需要", "已经", "正在", "通过", "我们", "你们", "他们", "还是"
    ]

    private static let cjkDemonstrativeNumChars: Set<Character> = Set(
        "这那哪每某上下前后第近约共头末一二三四五六七八九十百千万亿两零半几多各全单双"
    )

    private static let cjkAttachPrefixes: Set<String> = [
        "不", "没", "未", "已", "非", "无", "超", "总", "再", "可", "免", "零",
        "防", "抗", "纯", "原", "新", "旧", "老", "小", "大", "高", "低", "微",
        "轻", "重", "快", "慢", "真", "假", "好", "易", "难"
    ]

    private static let cjkAttachSuffixes: Set<String> = [
        "区", "框", "栏", "板", "页", "窗", "端", "器", "机", "库", "表", "单",
        "卡", "包", "码", "号", "键", "钮", "标", "签", "项", "态", "度", "率",
        "量", "感", "性", "化", "式", "型", "法", "流", "源", "池", "层", "级",
        "者", "员", "师", "家", "们", "中", "内", "外", "前", "后", "上", "下",
        "里", "间", "时", "完", "好", "掉", "出", "入", "起", "开", "住", "到",
        "成", "个", "条", "次", "版", "轮", "天", "日", "周", "月", "年", "处",
        "套", "款", "种", "类", "位", "名", "人", "步", "方", "面", "边", "侧",
        "体", "字", "词", "行", "图", "片", "文", "件", "点", "线", "角"
    ]

    private static let cjkAdverbModifiers: Set<String> = [
        "自动", "直接", "快速", "立即", "一键", "原位", "智能", "实时", "离线",
        "全局", "无缝", "丝滑", "精准", "批量", "手动", "重新", "继续", "禁止",
        "允许", "方便", "无法", "正常", "轻松", "安全", "无损", "动态", "静态"
    ]

    private static let cjkActionVerbStarters: Set<Character> = Set(
        "吐发打点按切选看用做改修加删开关输粘贴复制保存导设进退返跳拉拖拽放释拦截识别执运行调支持创建"
    )

    /// 判断词块是否还能继续原位二次爆炸拆分（长度 > 1 个字符即可再拆）
    static func canSubdivide(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count > 1
    }

    /// 将单个复合词块按语义层级向下原位爆炸拆分为下一级子词块（例如：短语 -> 词 -> 单字；URL -> 域名/路径 -> 分段 -> 字符）
    static func subdivideToken(
        _ token: BigBangTextToken,
        nextID: inout Int,
        burstGeneration: Int
    ) -> [BigBangTextToken]? {
        guard !token.isLineBreak else { return nil }
        let raw = token.text
        guard raw.count > 1 else { return nil }

        let slices = computeSubdivisionSlices(for: raw)
        guard slices.count >= 2 else { return nil }

        let count = slices.count
        var children: [BigBangTextToken] = []
        children.reserveCapacity(count)

        for (idx, slice) in slices.enumerated() {
            let spread = Double(idx) - Double(count - 1) * 0.5
            children.append(
                BigBangTextToken(
                    id: nextID,
                    text: slice.text,
                    isLineBreak: false,
                    lineIndex: token.lineIndex,
                    utf16Location: token.utf16Location + slice.utf16Offset,
                    utf16Length: slice.utf16Length,
                    granularity: slice.granularity,
                    burstGeneration: burstGeneration,
                    burstSpreadIndex: spread
                )
            )
            nextID += 1
        }
        return children
    }

    private static func computeSubdivisionSlices(
        for raw: String
    ) -> [(text: String, utf16Offset: Int, utf16Length: Int, granularity: BigBangGranularity)] {
        func makeEntry(_ range: Range<String.Index>, forceChar: Bool = false) -> (String, Int, Int, BigBangGranularity)? {
            let sub = String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sub.isEmpty else { return nil }
            let ns = NSRange(range, in: raw)
            let gran: BigBangGranularity = (forceChar || sub.count == 1) ? .character : .word
            return (sub, ns.location, ns.length, gran)
        }

        // 1. 结构分隔符优先（URL / 文件路径 / 邮箱 / 下划线 / 连字符 / 分辨率 × / 空格短语 / 逗号千分位）
        let primaryDelimiters: Set<Character> = ["/", "\\", "_", "-", ":", "@", "?", "&", "=", "×", "·", ",", "，", " ", "\t"]
        if raw.contains(where: { primaryDelimiters.contains($0) }) {
            let parts = splitByCharacterSet(raw, delimiters: primaryDelimiters).compactMap { makeEntry($0) }
            if parts.count >= 2 {
                return parts
            }
        }

        // 2. 点号层级拆分（域名 app.webfooo.com、版本号 v3.0.1、文件名 iClip.app、IP 127.0.0.1）
        if raw.contains(".") {
            let parts = splitByCharacterSet(raw, delimiters: ["."]).compactMap { makeEntry($0) }
            if parts.count >= 2 {
                return parts
            }
        }

        // 3. 混合文字体系切换（中英数字粘连如 3034字 / 1080p60 / 缝合PDF断行）与 camelCase / PascalCase（WindowServer）
        let scriptCamelRanges = splitByScriptAndCamelCase(raw)
        if scriptCamelRanges.count >= 2 {
            let parts = scriptCamelRanges.compactMap { makeEntry($0) }
            if parts.count >= 2 {
                return parts
            }
        }

        // 4. 多词中文短语（如「好多朋友」->「好多」+「朋友」，「评论区」->「评论」+「区」）
        let fullRange = raw.startIndex..<raw.endIndex
        var nlRanges: [Range<String.Index>] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = raw
        tokenizer.enumerateTokens(in: fullRange) { tokRange, _ in
            if !raw[tokRange].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nlRanges.append(tokRange)
            }
            return true
        }
        if nlRanges.count >= 2 {
            // 若 4 字中文短语被切成 1+1+2（如「好+多+朋友」）或 2+1+1，先将相邻单字收拢为 2+2 双字词层级
            var normalizedRanges = nlRanges
            if isPureCJKString(raw), raw.count == 4, nlRanges.count == 3 {
                let lens = nlRanges.map { raw.distance(from: $0.lowerBound, to: $0.upperBound) }
                if lens == [1, 1, 2] {
                    normalizedRanges = [nlRanges[0].lowerBound..<nlRanges[1].upperBound, nlRanges[2]]
                } else if lens == [2, 1, 1] {
                    normalizedRanges = [nlRanges[0], nlRanges[1].lowerBound..<nlRanges[2].upperBound]
                }
            }
            let parts = normalizedRanges.compactMap { makeEntry($0) }
            if parts.count >= 2 {
                return parts
            }
        }

        // 四字及以上纯中文成语/专名先对半拆为双字词，再拆单字
        if isPureCJKString(raw) && raw.count >= 4 {
            var chunks: [(String, Int, Int, BigBangGranularity)] = []
            var cursor = raw.startIndex
            while cursor < raw.endIndex {
                let step = (raw.distance(from: cursor, to: raw.endIndex) == 3) ? 2 : min(2, raw.distance(from: cursor, to: raw.endIndex))
                let next = raw.index(cursor, offsetBy: step)
                if let entry = makeEntry(cursor..<next) {
                    chunks.append(entry)
                }
                cursor = next
            }
            if chunks.count >= 2 {
                return chunks
            }
        }

        // 5. 最终级：逐字炸开（如「朋友」->「朋」+「友」，「Window」-> W i n d o w）
        var charEntries: [(String, Int, Int, BigBangGranularity)] = []
        var idx = raw.startIndex
        while idx < raw.endIndex {
            let next = raw.index(after: idx)
            if let entry = makeEntry(idx..<next, forceChar: true) {
                charEntries.append(entry)
            }
            idx = next
        }
        return charEntries
    }

    private static func splitByCharacterSet(_ text: String, delimiters: Set<Character>) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var segStart: String.Index? = nil
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if delimiters.contains(ch) {
                if let s = segStart {
                    ranges.append(s..<idx)
                    segStart = nil
                }
            } else if segStart == nil {
                segStart = idx
            }
            idx = text.index(after: idx)
        }
        if let s = segStart {
            ranges.append(s..<text.endIndex)
        }
        return ranges
    }

    private static func splitByScriptAndCamelCase(_ text: String) -> [Range<String.Index>] {
        enum CharClass {
            case cjk, upper, lower, digit, symbol
        }
        func classify(_ ch: Character) -> CharClass {
            guard let sc = ch.unicodeScalars.first else { return .symbol }
            if (0x4E00...0x9FFF).contains(sc.value) || (0x3400...0x4DBF).contains(sc.value) {
                return .cjk
            }
            if ch.isASCII && ch.isUppercase { return .upper }
            if ch.isASCII && ch.isLowercase { return .lower }
            if ch.isASCII && ch.isNumber { return .digit }
            return .symbol
        }

        let indices = Array(text.indices)
        guard indices.count >= 2 else { return [] }
        let classes = indices.map { classify(text[$0]) }

        var ranges: [Range<String.Index>] = []
        var startPos = 0
        for i in 1..<indices.count {
            let prev = classes[i - 1]
            let cur = classes[i]
            let next: CharClass? = (i + 1 < classes.count) ? classes[i + 1] : nil

            var shouldSplit = false
            if prev != cur {
                // 允许 Upper -> lower 组成单个首字母大写英文词（如 Window / Server）
                if !(prev == .upper && cur == .lower) {
                    shouldSplit = true
                }
            }
            // 处理连续大写缩写接首字母大写词：HTTPResponse -> HTTP + Response
            if prev == .upper && cur == .upper && next == .lower {
                shouldSplit = true
            }

            if shouldSplit {
                ranges.append(indices[startPos]..<indices[i])
                startPos = i
            }
        }
        ranges.append(indices[startPos]..<text.endIndex)
        return ranges
    }

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
                let pairs = tokenizeLineWordRanges(rawLine, smartMode: false)
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

            case .smart:
                let pairs = tokenizeLineWordRanges(rawLine, smartMode: true)
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
                            granularity: .smart
                        )
                    )
                    nextID += 1
                }
            }
        }
        return result
    }

    /// 对单行文本执行实体保护 + 自然分词/智能词组聚合，返回词串与在原行中的 exact `Range<String.Index>`
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
            return tokenizeLineWordRanges(line, smartMode: false)

        case .smart:
            return tokenizeLineWordRanges(line, smartMode: true)
        }
    }

    private static func tokenizeLineWordRanges(_ line: String, smartMode: Bool) -> [(text: String, range: Range<String.Index>)] {
        let fullNSRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard fullNSRange.length > 0 else { return [] }

        let activeRegex = smartMode ? smartEntityRegex : protectedEntityRegex
        let matches = activeRegex?.matches(in: line, options: [], range: fullNSRange) ?? []
        var entityRanges: [Range<String.Index>] = []
        var lastEnd = line.startIndex
        for m in matches {
            guard var swiftRange = Range(m.range, in: line) else { continue }
            if swiftRange.lowerBound < lastEnd { continue }
            if line[swiftRange].hasPrefix("http") {
                swiftRange = trimTrailingURLPunctuation(in: line, range: swiftRange)
            }
            guard swiftRange.lowerBound < swiftRange.upperBound else { continue }
            entityRanges.append(swiftRange)
            lastEnd = swiftRange.upperBound
        }

        var rawOutput: [(text: String, range: Range<String.Index>, isProtected: Bool)] = []
        var cursor = line.startIndex

        for entityRange in entityRanges {
            if cursor < entityRange.lowerBound {
                var natural: [(String, Range<String.Index>)] = []
                appendNaturalWords(in: line, range: cursor..<entityRange.lowerBound, into: &natural)
                for item in natural {
                    rawOutput.append((item.0, item.1, false))
                }
            }
            let raw = String(line[entityRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                rawOutput.append((raw, entityRange, true))
            }
            cursor = entityRange.upperBound
        }

        if cursor < line.endIndex {
            var natural: [(String, Range<String.Index>)] = []
            appendNaturalWords(in: line, range: cursor..<line.endIndex, into: &natural)
            for item in natural {
                rawOutput.append((item.0, item.1, false))
            }
        }

        if rawOutput.isEmpty {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let r = line.range(of: trimmed) {
                return [(trimmed, r)]
            }
            return []
        }

        guard smartMode else {
            return rawOutput.map { ($0.text, $0.range) }
        }

        return coalesceSmartPhraseRanges(in: line, items: rawOutput)
    }

    /// 智能组合聚合器：在保持标点断句边界的前提下，自动黏合数量短语（前两天 / 上一版 / 待办 2）、前后缀词（不美观 / 评论区 / 剪贴板）与紧凑意群（好多朋友 / 真实痛点）
    private static func coalesceSmartPhraseRanges(
        in line: String,
        items: [(text: String, range: Range<String.Index>, isProtected: Bool)]
    ) -> [(text: String, range: Range<String.Index>)] {
        guard items.count >= 2 else {
            return items.map { ($0.text, $0.range) }
        }

        let cjkDirectionalLeadChars: Set<String> = ["上", "下", "前", "后", "头", "末", "第", "近", "约", "共"]
        let cjkNumericFollowerChars: Set<Character> = Set("一二三四五六七八九十百千万亿两零半几多1234567890")

        // 第一遍：黏合紧密语法词缀、指代数量结构与「中文标签 + 数字」（如 待办 2）
        var pass1: [(text: String, range: Range<String.Index>, isProtected: Bool)] = []
        var i = 0
        while i < items.count {
            var cur = items[i]
            while i + 1 < items.count {
                let nxt = items[i + 1]
                if cur.isProtected || nxt.isProtected { break }
                guard cur.range.lowerBound >= line.startIndex,
                      cur.range.upperBound <= nxt.range.lowerBound,
                      nxt.range.upperBound <= line.endIndex else {
                    break
                }
                let gap = String(line[cur.range.upperBound..<nxt.range.lowerBound])

                // 若 nxt 是「上/下/前/后/第」且紧邻后方是数词（如「发完」+「上」+「一版」），禁止前词吞并，留给「上一版」
                if gap.isEmpty,
                   cjkDirectionalLeadChars.contains(nxt.text),
                   !cur.text.allSatisfy({ cjkDemonstrativeNumChars.contains($0) }),
                   i + 2 < items.count {
                    let afterNxt = items[i + 2]
                    if nxt.range.upperBound <= afterNxt.range.lowerBound && afterNxt.range.upperBound <= line.endIndex {
                        let nextGap = String(line[nxt.range.upperBound..<afterNxt.range.lowerBound])
                        if nextGap.isEmpty, let firstCh = afterNxt.text.first, cjkNumericFollowerChars.contains(firstCh) {
                            break
                        }
                    }
                }

                if shouldMergeGrammarAffixOrQuantifier(left: cur.text, right: nxt.text, gap: gap) {
                    let mergedRange = cur.range.lowerBound..<nxt.range.upperBound
                    let mergedText = String(line[mergedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    cur = (mergedText, mergedRange, false)
                    i += 1
                } else {
                    break
                }
            }
            pass1.append(cur)
            i += 1
        }

        // 第二遍：将相邻双字修饰+名词或副词+动词意群（如 好多+朋友、真实+痛点、智能+组合、一键+切换）聚合为 4 字黄金选词块
        var pass2: [(text: String, range: Range<String.Index>)] = []
        var j = 0
        while j < pass1.count {
            let cur = pass1[j]
            if j + 1 < pass1.count {
                let nxt = pass1[j + 1]
                if cur.range.lowerBound >= line.startIndex,
                   cur.range.upperBound <= nxt.range.lowerBound,
                   nxt.range.upperBound <= line.endIndex {
                    let gap = String(line[cur.range.upperBound..<nxt.range.lowerBound])
                    if !cur.isProtected, !nxt.isProtected,
                       gap.isEmpty,
                       shouldMergeFourCharSemanticPair(left: cur.text, right: nxt.text) {
                        let mergedRange = cur.range.lowerBound..<nxt.range.upperBound
                        pass2.append((String(line[mergedRange]), mergedRange))
                        j += 2
                        continue
                    }
                }
            }
            pass2.append((cur.text, cur.range))
            j += 1
        }
        return pass2
    }

    private static func isPureCJKString(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }
    }

    private static func isPureASCIIInteger(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func shouldMergeGrammarAffixOrQuantifier(left: String, right: String, gap: String) -> Bool {
        // 允许「待办 2」「第 1」这类带单空格的短标签数字组合
        if (gap.isEmpty || gap == " ")
            && isPureCJKString(left) && left.count <= 2
            && isPureASCIIInteger(right) && right.count <= 3
            && !cjkHardStopParticles.contains(left) {
            return true
        }
        guard gap.isEmpty, isPureCJKString(left), isPureCJKString(right) else { return false }
        let total = left.count + right.count
        guard total <= 4 else { return false }

        if cjkHardStopParticles.contains(left) || cjkHardStopParticles.contains(right) {
            // 特例：「有」+「一些/一点/可能」组成自然短语
            if left == "有" && (right == "一些" || right == "一点" || right == "很多" || right == "部分") {
                return true
            }
            return false
        }

        // 1. 指示/序数/数词 + 量词/时间/名词（前+两+天 -> 前两天，上+一+版 -> 上一版，两+个 -> 两个）
        if left.allSatisfy({ cjkDemonstrativeNumChars.contains($0) }) && right.count <= 2 {
            return true
        }
        // 2. 单字高频前缀 + 词干（不+美观 -> 不美观，零+闪烁 -> 零闪烁，全+单字 -> 全单字）
        if left.count == 1 && cjkAttachPrefixes.contains(left) && right.count <= 2 {
            return true
        }
        // 2b. 相邻两个非助词孤立单字优先收拢为双字词（如 OCR 切碎的「待+办」->「待办」），彻底消除碎单字
        if left.count == 1 && right.count == 1 {
            return true
        }
        // 3. 词干 + 单字名词/趋向/量词后缀（评论+区 -> 评论区，发+完 -> 发完，剪贴+板 -> 剪贴板）
        if right.count == 1
            && cjkAttachSuffixes.contains(right)
            && left.count <= 3
            && !cjkClauseFunctionWords.contains(left) {
            return true
        }
        return false
    }

    private static func shouldMergeFourCharSemanticPair(left: String, right: String) -> Bool {
        guard isPureCJKString(left), isPureCJKString(right),
              left.count == 2, right.count == 2 else {
            return false
        }
        if cjkClauseFunctionWords.contains(left) || cjkClauseFunctionWords.contains(right) {
            return false
        }
        if cjkAdverbModifiers.contains(left) {
            return true
        }
        if let firstRight = right.first, cjkActionVerbStarters.contains(firstRight) {
            return false
        }
        return true
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
        var lastUpper = range.lowerBound
        tokenizer.enumerateTokens(in: range) { tokRange, _ in
            // 严格钳制在当前子区间内且单调递增，彻底根除 NLTokenizer 跨过受保护实体边界导致的 upperBound > lowerBound 闪退
            let lower = max(tokRange.lowerBound, lastUpper)
            let upper = min(tokRange.upperBound, range.upperBound)
            guard lower < upper else { return true }
            let clamped = lower..<upper
            let piece = String(line[clamped]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                output.append((piece, clamped))
                lastUpper = upper
            }
            return true
        }
    }

    /// 按原始出现顺序智能拼合所选文字词块（源行中原本紧贴的拆分子块无缝还原，跨词英文/数字自动补单空格，跨行保留换行）
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
                areAdjacentCharacters: cur.lineIndex == prev.lineIndex
                    && prev.utf16Length > 0
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

    /// 限制大图预览缩放后的二维平移偏移，确保图片边缘不脱离视口产生黑边
    static func clampedImagePanOffset(
        offset: CGSize,
        imageSize: CGSize,
        zoomScale: CGFloat,
        viewportSize: CGSize
    ) -> CGSize {
        guard zoomScale > 1.001,
              imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return .zero
        }
        let maxPanX = max(0, (imageSize.width * zoomScale - viewportSize.width) * 0.5)
        let maxPanY = max(0, (imageSize.height * zoomScale - viewportSize.height) * 0.5)
        return CGSize(
            width: min(maxPanX, max(-maxPanX, offset.width)),
            height: min(maxPanY, max(-maxPanY, offset.height))
        )
    }

    /// 以指定视口相对中心点为锚计算缩放后的平移偏移，确保双击/缩放时焦点像素紧跟锚点且绝不露出黑边
    static func cursorAnchoredZoomPanOffset(
        currentPan: CGSize,
        oldZoom: CGFloat,
        newZoom: CGFloat,
        cursorRelativeToCenter: CGPoint,
        imageSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        guard newZoom > 1.001, oldZoom > 0.01 else { return .zero }
        let ratio = newZoom / oldZoom
        let rawX = cursorRelativeToCenter.x - (cursorRelativeToCenter.x - currentPan.width) * ratio
        let rawY = cursorRelativeToCenter.y - (cursorRelativeToCenter.y - currentPan.height) * ratio
        return clampedImagePanOffset(
            offset: CGSize(width: rawX, height: rawY),
            imageSize: imageSize,
            zoomScale: newZoom,
            viewportSize: viewportSize
        )
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
