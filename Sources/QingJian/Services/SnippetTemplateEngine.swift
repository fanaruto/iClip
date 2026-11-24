import Foundation

/// 一行闪念速记与「备注 :: 正文」直存解析结果
struct QuickCaptureIntent: Equatable {
    let customAlias: String?
    let bodyText: String
    let defaultPin: Bool
    let defaultTodo: Bool

    init(customAlias: String?, bodyText: String, defaultPin: Bool, defaultTodo: Bool = false) {
        self.customAlias = customAlias
        self.bodyText = bodyText
        self.defaultPin = defaultPin
        self.defaultTodo = defaultTodo
    }

    var isEmptyBody: Bool {
        bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 搜索框一行速记与闪念待办解析器：
/// - 支持 `[] 待办事项` / `- 待办事项` / `+待办 事项` / `todo: 事项`（↵ 直接入待办库且不冲掉当前剪贴板，⇧↵ 存入待办并复制）
/// - 支持 `> 临时备忘` / `@记 临时备忘`（↵ 存入剪贴板与历史，⇧↵ 直接收藏）
/// - 支持 `> 备注名 :: 正文内容` 或 `@新建 正文`（↵ 直接创建带备注收藏并复制）
enum QuickCaptureParser {
    static func parse(from rawQuery: String) -> QuickCaptureIntent? {
        let leadingTrimmed = rawQuery.drop(while: { $0 == " " || $0 == "\t" })
        guard !leadingTrimmed.isEmpty else { return nil }
        let s = String(leadingTrimmed)
        let lower = s.lowercased()

        // 1. 优先识别零歧义闪念待办前缀（严密避开负数数学运算如 `- 50` / `-3.14` 及纯搜索词 `@todo`）
        if let todoPayload = extractTodoPayload(from: s, lower: lower) {
            let (alias, body) = splitAliasAndBody(todoPayload)
            return QuickCaptureIntent(
                customAlias: alias,
                bodyText: body,
                defaultPin: false,
                defaultTodo: true
            )
        }

        var payload: String? = nil
        var forcePin = false

        if s == ">" || s == "＞" {
            payload = ""
        } else if s.hasPrefix("> ") || s.hasPrefix("＞ ") || s.hasPrefix(">\t") || s.hasPrefix("＞\t") {
            payload = String(s.dropFirst(2))
        } else {
            let pinPrefixes = ["@新建", "@添加", "@add"]
            let notePrefixes = ["@记", "@速记", "@note"]
            for p in pinPrefixes where lower.hasPrefix(p) {
                let rest = String(s.dropFirst(p.count))
                if rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t") {
                    payload = rest.trimmingCharacters(in: .whitespaces)
                    forcePin = true
                    break
                }
            }
            if payload == nil {
                for p in notePrefixes where lower.hasPrefix(p) {
                    let rest = String(s.dropFirst(p.count))
                    if rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t") {
                        payload = rest.trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
        }

        guard let unwrapped = payload else { return nil }
        let (alias, body) = splitAliasAndBody(unwrapped)
        let shouldDefaultPin = forcePin || (alias != nil)
        return QuickCaptureIntent(
            customAlias: alias,
            bodyText: body,
            defaultPin: shouldDefaultPin,
            defaultTodo: false
        )
    }

    private static func extractTodoPayload(from s: String, lower: String) -> String? {
        let exactBoxMarkers = ["- [ ]", "* [ ]", "[ ]", "[]", "【 】", "【】"]
        for marker in exactBoxMarkers {
            if s == marker {
                return ""
            }
            if s.hasPrefix(marker + " ") || s.hasPrefix(marker + "\t") {
                return String(s.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // 紧凑复选框如 `[]下午核对报表` 或 `【】下午核对报表`
        for compactMarker in ["[]", "【】"] where s.hasPrefix(compactMarker) && s.count > compactMarker.count {
            return String(s.dropFirst(compactMarker.count)).trimmingCharacters(in: .whitespaces)
        }

        let explicitPrefixes = ["+待办", "@加待办", "@新建待办", "+todo"]
        for p in explicitPrefixes where lower.hasPrefix(p) {
            let rest = String(s.dropFirst(p.count))
            if rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t") {
                return rest.trimmingCharacters(in: .whitespaces)
            }
        }

        let colonPrefixes = ["todo:", "todo：", "待办:", "待办："]
        for p in colonPrefixes where lower.hasPrefix(p) {
            return String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }

        // 短横线闪念待办 `- 下午回电话`：严格排除数学减法 `- 50` / `-3.14` / `-(1+2)` 与 CLI flag `--help`
        if s.hasPrefix("- ") || s.hasPrefix("－ ") {
            let rest = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                return ""
            }
            if let first = rest.unicodeScalars.first {
                let isMathOrFlag = (first.value >= 48 && first.value <= 57)
                    || first == "."
                    || first == "("
                    || first == "-"
                    || first == "+"
                if !isMathOrFlag {
                    return rest
                }
            }
        }

        return nil
    }

    /// 拆分可选的「备注名 :: 正文」（兼容中文全角 `：：`）
    static func splitAliasAndBody(_ text: String) -> (alias: String?, body: String) {
        let separators = ["::", "：："]
        for sep in separators {
            if let range = text.range(of: sep) {
                let left = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !left.isEmpty && !right.isEmpty {
                    return (left, right)
                }
            }
        }
        return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// 剪贴板多行清单拆解与单条行动意图嗅探引擎（双角色共享，纯本地 O(N) 扫描）
enum TodoChecklistExtractor {
    private static let uncheckedMarkers = ["- [ ]", "* [ ]", "+ [ ]", "[ ]", "[]", "【 】", "【】", "□", "☐"]
    private static let checkedMarkers = ["- [x]", "- [X]", "* [x]", "* [X]", "[x]", "[X]", "☑", "✅", "✓"]
    private static let codeNoiseHints = ["func ", "struct ", "class ", "import ", "const ", "return ", "SELECT ", "INSERT ", "CREATE TABLE", "curl ", "docker ", "git "]

    /// 从多行剪贴文本中提取可独立勾选的待办事项列表（至少 2 条未完成项时才返回，已完成 `[x]` 项自动跳过）
    static func extractChecklistItems(from rawText: String) -> [String] {
        guard rawText.utf8.count <= 16_384 else { return [] }
        let rawLines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard rawLines.count >= 2 && rawLines.count <= 30 else { return [] }

        // 形态 A：显式复选框清单（如 Markdown / 飞书 / Notion `- [ ] xxx`）
        var explicitUnchecked: [String] = []
        var explicitTotalCount = 0
        for line in rawLines {
            if checkedMarkers.contains(where: { line.hasPrefix($0) }) {
                explicitTotalCount += 1
                continue
            }
            if let stripped = stripUncheckedMarker(line), !stripped.isEmpty {
                explicitTotalCount += 1
                explicitUnchecked.append(stripped)
            }
        }
        if explicitTotalCount >= 2 && explicitUnchecked.count >= 2 {
            return deduplicatePreservingOrder(explicitUnchecked)
        }

        // 形态 B：整齐项目符号或编号行动清单（排除代码块、JSON、终端脚本与纯数字账单）
        guard rawLines.count <= 20 else { return [] }
        for hint in codeNoiseHints where rawText.contains(hint) {
            return []
        }
        if rawText.contains("{") && rawText.contains("}") {
            return []
        }

        var bulletExtracted: [String] = []
        for line in rawLines {
            guard let body = stripBulletOrNumberPrefix(line),
                  body.count >= 2 && body.count <= 120,
                  !isPureNumberOrCurrency(body) else {
                return []
            }
            bulletExtracted.append(body)
        }
        let unique = deduplicatePreservingOrder(bulletExtracted)
        return unique.count >= 2 ? unique : []
    }

    /// 识别单条短文本是否包含明确的待办行动交代（用于光标角微星标一键转待办）
    static func hasActionableSingleTodoIntent(_ rawText: String) -> Bool {
        guard rawText.utf8.count <= 420 else { return false }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let charCount = trimmed.count
        guard charCount >= 4 && charCount <= 110 else { return false }
        if trimmed.contains("\n") && trimmed.components(separatedBy: .newlines).count > 2 {
            return false
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.contains("{") {
            return false
        }
        let lower = trimmed.lowercased()
        let leadingTriggers = ["todo:", "todo：", "fixme:", "待办:", "待办：", "[] ", "[ ] ", "□ "]
        if leadingTriggers.contains(where: { lower.hasPrefix($0) }) {
            return true
        }
        let actionPhrases = [
            "记得", "别忘了", "下班前", "中午前", "今晚前", "发给", "提交给",
            "麻烦把", "请把", "核对一下", "跟进一下", "回复一下", "待处理"
        ]
        return actionPhrases.contains(where: { trimmed.contains($0) })
    }

    /// 清洗单条转待办时的前导复选符号（如复制了 `- [ ] 交周报` 按 ⌘T 时展示干净正文）
    static func cleanLeadingCheckboxIfPresent(_ rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stripped = stripUncheckedMarker(trimmed), !stripped.isEmpty {
            return stripped
        }
        return rawText
    }

    private static func stripUncheckedMarker(_ line: String) -> String? {
        for marker in uncheckedMarkers where line.hasPrefix(marker) {
            let rest = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return rest
        }
        return nil
    }

    private static func stripBulletOrNumberPrefix(_ line: String) -> String? {
        for bullet in ["- ", "* ", "• ", "· "] where line.hasPrefix(bullet) {
            let rest = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        // 匹配 `1. xxx` / `1、xxx` / `1) xxx`
        var digits = 0
        var idx = line.startIndex
        while idx < line.endIndex, let scalar = line[idx].unicodeScalars.first, scalar.value >= 48 && scalar.value <= 57, digits < 3 {
            digits += 1
            idx = line.index(after: idx)
        }
        if digits > 0 && idx < line.endIndex {
            let sep = line[idx]
            if sep == "." || sep == "、" || sep == ")" || sep == "）" {
                let afterSep = line.index(after: idx)
                let rest = String(line[afterSep...]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    // 避免把 `3.14` 浮点数误判为编号
                    if sep == ".", let firstRest = rest.unicodeScalars.first, firstRest.value >= 48 && firstRest.value <= 57 {
                        return nil
                    }
                    return rest
                }
            }
        }
        return nil
    }

    private static func isPureNumberOrCurrency(_ s: String) -> Bool {
        var hasLetterOrHan = false
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 0x4E00 && v <= 0x9FFF) {
                hasLetterOrHan = true
                break
            }
        }
        return !hasLetterOrHan
    }

    private static func deduplicatePreservingOrder(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in list where seen.insert(item).inserted {
            result.append(item)
        }
        return result
    }
}

/// 动态模板插值引擎（双角色全量共享）：
/// 支持 {{clip}}、{{clip_redacted}}、{{date}}、{{time}}、{{datetime}}、{{weekday}}、{{ts}}、{{uuid}}
enum SnippetTemplateEngine {
    private static let placeholderRegex = try! NSRegularExpression(
        pattern: #"\{\{\s*(clip|clip_redacted|date|time|datetime|weekday|ts|uuid)\s*\}\}"#,
        options: [.caseInsensitive]
    )

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEE"
        return f
    }()

    private static let fallbackPhoneRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)(1[3-9]\d)\d{4}(\d{4})(?!\d)"#
    )
    private static let fallbackEmailRegex = try! NSRegularExpression(
        pattern: #"\b([A-Za-z0-9])[A-Za-z0-9._%+-]*(@[A-Za-z0-9.-]+\.[A-Za-z]{2,18})\b"#
    )
    private static let fallbackPrivateIPRegex = try! NSRegularExpression(
        pattern: #"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3})\b"#
    )

    /// 判断文本是否包含受支持的动态模板占位符
    static func containsPlaceholders(_ text: String) -> Bool {
        guard text.contains("{{") && text.contains("}}") else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return placeholderRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// 最大模板展开占位符数与输出字节上限（阻断恶意多 `{{clip}}` 乘数级内存膨胀炸弹 CWE-400）
    private static let maxPlaceholderExpansions = 64
    private static let maxRenderedUTF8Bytes = 1_048_576
    private static let maxRedactionInputUTF16 = 262_144

    /// 实时展开动态模板占位符（按需惰性脱敏 + O(N) 前向单遍拼接 + 1MB 膨胀熔断）
    static func render(template: String, latestContextText: String?, referenceDate: Date = Date()) -> String {
        guard template.contains("{{") && template.contains("}}"),
              template.utf8.count <= maxRenderedUTF8Bytes else {
            return template
        }
        let nsString = template as NSString
        let matches = placeholderRegex.matches(in: template, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return template }

        let contextRaw = latestContextText ?? ""
        var cachedRedacted: String? = nil
        func resolveRedactedContext() -> String {
            if let hit = cachedRedacted { return hit }
            guard !contextRaw.isEmpty else {
                cachedRedacted = ""
                return ""
            }
            let boundedCtx: String
            if contextRaw.utf16.count > maxRedactionInputUTF16 {
                let endIdx = String.Index(utf16Offset: maxRedactionInputUTF16, in: contextRaw)
                boundedCtx = String(contextRaw[..<endIdx])
            } else {
                boundedCtx = contextRaw
            }
            let computed: String
            let step1 = SemanticEngine.redactSecrets(in: boundedCtx)
            computed = SemanticEngine.redactPIIAndPrivateIP(in: SensitiveCredentialVeil.redactForExternalSharing(step1))
            cachedRedacted = computed
            return computed
        }

        var out = ""
        out.reserveCapacity(min(template.utf8.count + min(contextRaw.utf8.count, 16_384), maxRenderedUTF8Bytes))
        var cursor = template.startIndex
        var expandedCount = 0

        for match in matches {
            guard let fullRange = Range(match.range, in: template),
                  let keyRange = Range(match.range(at: 1), in: template),
                  fullRange.lowerBound >= cursor else {
                continue
            }
            out.append(contentsOf: template[cursor..<fullRange.lowerBound])
            cursor = fullRange.upperBound

            if expandedCount >= maxPlaceholderExpansions || out.utf8.count >= maxRenderedUTF8Bytes {
                out.append(contentsOf: template[fullRange])
                continue
            }

            let key = template[keyRange].lowercased()
            let replacement: String
            switch key {
            case "clip":
                replacement = contextRaw
            case "clip_redacted":
                replacement = resolveRedactedContext()
            case "date":
                replacement = dateFormatter.string(from: referenceDate)
            case "time":
                replacement = timeFormatter.string(from: referenceDate)
            case "datetime":
                replacement = dateTimeFormatter.string(from: referenceDate)
            case "weekday":
                replacement = weekdayFormatter.string(from: referenceDate)
            case "ts":
                replacement = "\(Int(referenceDate.timeIntervalSince1970))"
            case "uuid":
                replacement = UUID().uuidString.lowercased()
            default:
                replacement = String(template[fullRange])
            }

            if out.utf8.count + replacement.utf8.count > maxRenderedUTF8Bytes {
                let remain = max(0, maxRenderedUTF8Bytes - out.utf8.count)
                if remain > 0 {
                    out.append(String(replacement.utf8.prefix(remain)) ?? "")
                }
                expandedCount = maxPlaceholderExpansions
            } else {
                out.append(replacement)
                expandedCount += 1
            }
        }
        if cursor < template.endIndex {
            out.append(contentsOf: template[cursor..<template.endIndex])
        }
        return out
    }
}
