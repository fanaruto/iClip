import Foundation

/// 一行闪念速记与「备注 :: 正文」直存解析结果
struct QuickCaptureIntent: Equatable {
    let customAlias: String?
    let bodyText: String
    let defaultPin: Bool

    var isEmptyBody: Bool {
        bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 搜索框一行速记解析器：
/// - 支持 `> 临时备忘` / `@记 临时备忘`（↵ 存入剪贴板与历史，⇧↵ 直接收藏）
/// - 支持 `> 备注名 :: 正文内容` 或 `@新建 正文`（↵ 直接创建带备注收藏并复制）
enum QuickCaptureParser {
    static func parse(from rawQuery: String) -> QuickCaptureIntent? {
        let leadingTrimmed = rawQuery.drop(while: { $0 == " " || $0 == "\t" })
        guard !leadingTrimmed.isEmpty else { return nil }
        let s = String(leadingTrimmed)
        let lower = s.lowercased()

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
            defaultPin: shouldDefaultPin
        )
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

    /// 判断文本是否包含受支持的动态模板占位符
    static func containsPlaceholders(_ text: String) -> Bool {
        guard text.contains("{{") && text.contains("}}") else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return placeholderRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// 实时展开动态模板占位符
    static func render(template: String, latestContextText: String?, referenceDate: Date = Date()) -> String {
        let contextRaw = latestContextText ?? ""
        let contextRedacted: String = {
            guard !contextRaw.isEmpty else { return "" }
            #if !ICLIP_EDITION_FLOW
            return SemanticEngine.redactSecrets(in: contextRaw)
            #else
            let full = NSRange(contextRaw.startIndex..<contextRaw.endIndex, in: contextRaw)
            return fallbackPhoneRegex.stringByReplacingMatches(in: contextRaw, range: full, withTemplate: "$1****$2")
            #endif
        }()

        let nsString = template as NSString
        let matches = placeholderRegex.matches(in: template, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return template }

        var result = template
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let keyRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            let key = result[keyRange].lowercased()
            let replacement: String
            switch key {
            case "clip":
                replacement = contextRaw
            case "clip_redacted":
                replacement = contextRedacted
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
                replacement = String(result[fullRange])
            }
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }
}
