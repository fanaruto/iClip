#if !ICLIP_EDITION_FLOW
import Foundation

/// 动态模板插值引擎：支持 {{clip}}、{{clip_redacted}}、{{date}}、{{time}}、{{datetime}}、{{ts}}、{{uuid}}
enum SnippetTemplateEngine {
    private static let placeholderRegex = try! NSRegularExpression(
        pattern: #"\{\{\s*(clip|clip_redacted|date|time|datetime|ts|uuid)\s*\}\}"#,
        options: [.caseInsensitive]
    )

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 判断文本是否包含受支持的动态模板占位符
    static func containsPlaceholders(_ text: String) -> Bool {
        guard text.contains("{{") && text.contains("}}") else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return placeholderRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// 实时展开动态模板占位符
    static func render(template: String, latestContextText: String?) -> String {
        let now = Date()
        let contextRaw = latestContextText ?? ""
        let contextRedacted = contextRaw.isEmpty ? "" : SemanticEngine.redactSecrets(in: contextRaw)

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
                replacement = dateFormatter.string(from: now)
            case "time":
                replacement = timeFormatter.string(from: now)
            case "datetime":
                replacement = dateTimeFormatter.string(from: now)
            case "ts":
                replacement = "\(Int(now.timeIntervalSince1970))"
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
#endif
