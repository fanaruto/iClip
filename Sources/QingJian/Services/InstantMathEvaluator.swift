import Foundation

/// 搜索框即时四则速算结果（支持加减乘除、括号、百分比、万/亿单位、剪贴板首条续算与会计大写直出）
struct InstantMathResult: Equatable {
    let expressionDisplay: String
    let plainValue: String
    let formattedThousands: String
    let rmbUppercase: String?
    var isExplicitOrContextual: Bool = false
}

enum InstantMathEvaluator {
    private static let cnUnitRegex = try! NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*(亿|万)"#
    )
    private static let trailingYuanRegex = try! NSRegularExpression(
        pattern: #"(\d)\s*(?:元整|元|圆)"#
    )

    /// 安全解析搜索框中的四则运算表达式（支持 `* 13%` / `/ 1.06` / `+ 500` 免重敲直接续算 `#1` 剪贴板金额）
    static func evaluate(_ rawQuery: String, latestClipboardText: String? = nil) -> InstantMathResult? {
        let rawTrimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmed.isEmpty, rawTrimmed.utf8.count <= 128 else { return nil }

        var input = rawTrimmed
        let hasLeadingEquals = input.hasPrefix("=") || input.hasPrefix("＝")
        if hasLeadingEquals {
            input = String(input.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !input.isEmpty else { return nil }

        // 0. 优先检测离线时间/时区/日期加减/Unix 时间戳直算（如 `2026-11-24 + 90天`、`30天后`、`10:00 pst`、`ts 1763971200`）
        if let temporalRes = evaluateTemporalExpression(input, hasLeadingEquals: hasLeadingEquals) {
            return temporalRes
        }

        // 0.5 检测商业折扣、环比涨跌幅与程序员进制直算（如 `1280 85折`、`299 7.5折`、`12500 -> 16000`、`0xff`、`255 to hex`）
        if let bizRes = evaluateBusinessAndRadixExpression(input, latestClipboardText: latestClipboardText) {
            return bizRes
        }

        // 0.6 检测离线色彩制式互转（`#1E5EFF` / `rgb(...)` / `hsl(...)`）与 WCAG 2.1 无障碍对比度直算（`#FFFFFF vs #1E5EFF`）
        if let colorRes = evaluateColorAndContrastExpression(input, hasLeadingEquals: hasLeadingEquals, latestClipboardText: latestClipboardText) {
            return colorRes
        }

        // 0.7 检测命名风格直转（`camel user_order_id`、`snake userOrderId`、`kebab ...`、`const ...` 或剪贴板续算 `to snake` / `转驼峰`）
        if let caseRes = evaluateIdentifierCaseExpression(input, latestClipboardText: latestClipboardText) {
            return caseRes
        }

        // 1. 离线全能单位换算（存储 B/KB/MB/GB/TB、时长 ms/s/min/h/d、温度 C/F、重量长度 kg/lb、cm/in、km/mi）
        if let unitRes = evaluateUnitConversion(input, hasLeadingEquals: hasLeadingEquals) {
            return unitRes
        }

        // 检测「免重敲剪贴板续算」：如刚复制 ¥12,800 后直接输入 `* 13%`、`/ 1.06`、`+ 350` 或 `= - 200`
        let firstChar = input.first!
        let wantsContextContinuation: Bool = {
            if firstChar == "*" || firstChar == "×" || firstChar == "/" || firstChar == "÷" {
                return true
            }
            if hasLeadingEquals && (firstChar == "+" || firstChar == "-") {
                return true
            }
            if !hasLeadingEquals && rawTrimmed.hasPrefix("+ ") {
                return true
            }
            return false
        }()

        let displayInput: String
        let workingInput: String
        let usedClipboardContext: Bool

        if wantsContextContinuation {
            guard let ctx = extractCleanClipboardNumber(from: latestClipboardText) else {
                return nil
            }
            displayInput = "\(ctx.display) \(input)"
            workingInput = "\(ctx.plainNumeric) \(input)"
            usedClipboardContext = true
        } else {
            displayInput = input
            workingInput = input
            usedClipboardContext = false
        }

        // 归一化货币符号、中文单位（万/亿）、全角乘除括号与千分位逗号
        var normalized = workingInput
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "X", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "％", with: "%")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")

        let yuanRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        normalized = trailingYuanRegex.stringByReplacingMatches(
            in: normalized,
            options: [],
            range: yuanRange,
            withTemplate: "$1"
        )

        var expandedChineseUnit = false
        if normalized.contains("万") || normalized.contains("亿") {
            let nsRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            let matches = cnUnitRegex.matches(in: normalized, options: [], range: nsRange)
            if !matches.isEmpty {
                expandedChineseUnit = true
                for match in matches.reversed() {
                    guard let fullR = Range(match.range, in: normalized),
                          let numR = Range(match.range(at: 1), in: normalized),
                          let unitR = Range(match.range(at: 2), in: normalized) else { continue }
                    let numStr = String(normalized[numR])
                    let mult = normalized[unitR] == "亿" ? "100000000" : "10000"
                    normalized.replaceSubrange(fullR, with: "(\(numStr)*\(mult))")
                }
            }
        }

        // 仅允许合法算术字符集，排除普通路径、日期（如 2026-11-23 若无前导 = 且形如日期则不误判）或英文搜索词
        guard isLikelyMathExpression(normalized, hasLeadingEquals: hasLeadingEquals || usedClipboardContext) else {
            return nil
        }

        var parser = Parser(normalized)
        guard let value = parser.parseExpression(),
              parser.isAtEnd,
              value.isFinite,
              abs(value) < 1_000_000_000_000 else {
            return nil
        }

        // 若未加 `=` 且算出来与原纯数字完全相同（例如单输入 "-50"），不作算式展示
        if !hasLeadingEquals && !usedClipboardContext && !expandedChineseUnit && !parser.didPerformBinaryOp {
            return nil
        }

        let plain = formatCleanDouble(value)
        let parts = plain.hasPrefix("-") ? String(plain.dropFirst()).split(separator: ".", omittingEmptySubsequences: false) : plain.split(separator: ".", omittingEmptySubsequences: false)
        let intDigits = parts.first.map(String.init) ?? "0"
        let fracDigits = parts.count > 1 ? String(parts[1]) : nil

        let sign = plain.hasPrefix("-") ? "-" : ""
        let thousands = sign + addThousandsGrouping(intDigits) + (fracDigits != nil ? ".\(fracDigits!)" : "")

        let rmb: String?
        if value >= 0 && intDigits.count <= 12 {
            let twoDecFrac = fracDigits.map { String($0.prefix(2)) }
            rmb = FinanceNumberEngine.toChineseUppercaseRMB(intDigits: intDigits, fracDigits: twoDecFrac)
        } else {
            rmb = nil
        }

        return InstantMathResult(
            expressionDisplay: displayInput,
            plainValue: plain,
            formattedThousands: thousands,
            rmbUppercase: rmb,
            isExplicitOrContextual: hasLeadingEquals || usedClipboardContext
        )
    }

    private static let unitConversionRegex = try! NSRegularExpression(
        pattern: #"^(-?\d+(?:\.\d+)?)\s*(°?[a-zA-Z\u4e00-\u9fa5]+)(?:\s*(?:to|in|->|=>|转)\s*(°?[a-zA-Z\u4e00-\u9fa5]+))?$"#,
        options: [.caseInsensitive]
    )

    private enum UnitFamily {
        case dataBytes(Double, String)
        case durationSec(Double, String)
        case tempC
        case tempF
        case massKg(Double, String)
        case lengthCm(Double, String)
    }

    private static func classifyUnitToken(_ rawTok: String, explicitSyntax: Bool) -> UnitFamily? {
        let hadDegree = rawTok.hasPrefix("°")
        let u = rawTok.replacingOccurrences(of: "°", with: "").lowercased()
        switch u {
        case "kb", "kib": return .dataBytes(1024.0, "KB")
        case "mb", "mib": return .dataBytes(1048576.0, "MB")
        case "gb", "gib": return .dataBytes(1073741824.0, "GB")
        case "tb", "tib": return .dataBytes(1099511627776.0, "TB")
        case "byte", "bytes": return .dataBytes(1.0, "B")
        case "b" where explicitSyntax: return .dataBytes(1.0, "B")

        case "ms", "msec": return .durationSec(0.001, "ms")
        case "sec", "secs", "second", "seconds", "秒": return .durationSec(1.0, "s")
        case "s" where explicitSyntax: return .durationSec(1.0, "s")
        case "min", "mins", "minute", "minutes", "分钟": return .durationSec(60.0, "min")
        case "hr", "hrs", "hour", "hours", "小时": return .durationSec(3600.0, "h")
        case "h" where explicitSyntax: return .durationSec(3600.0, "h")
        case "day", "days", "天": return .durationSec(86400.0, "d")
        case "d" where explicitSyntax: return .durationSec(86400.0, "d")

        case "celsius", "摄氏度": return .tempC
        case "c" where hadDegree || explicitSyntax: return .tempC
        case "fahrenheit", "华氏度": return .tempF
        case "f" where hadDegree || explicitSyntax: return .tempF

        case "kg", "kgs", "千克", "公斤": return .massKg(1.0, "kg")
        case "lb", "lbs", "pound", "pounds", "磅": return .massKg(0.45359237, "lb")

        case "cm", "厘米": return .lengthCm(1.0, "cm")
        case "inch", "inches", "英寸": return .lengthCm(2.54, "in")
        case "in" where explicitSyntax: return .lengthCm(2.54, "in")
        case "km", "公里", "千米": return .lengthCm(100000.0, "km")
        case "mi", "mile", "miles", "英里": return .lengthCm(160934.4, "mi")
        default: return nil
        }
    }

    private static func evaluateUnitConversion(_ input: String, hasLeadingEquals: Bool) -> InstantMathResult? {
        let cleaned = input.replacingOccurrences(of: ",", with: "")
        let nsRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        guard let m = unitConversionRegex.firstMatch(in: cleaned, range: nsRange),
              let numR = Range(m.range(at: 1), in: cleaned),
              let srcR = Range(m.range(at: 2), in: cleaned),
              let val = Double(cleaned[numR]), val.isFinite else {
            return nil
        }
        let dstTok: String? = (m.range(at: 3).location != NSNotFound) ? Range(m.range(at: 3), in: cleaned).map { String(cleaned[$0]) } : nil
        let explicit = hasLeadingEquals || dstTok != nil || cleaned.contains(" ")
        guard let srcUnit = classifyUnitToken(String(cleaned[srcR]), explicitSyntax: explicit) else {
            return nil
        }
        let dstUnit = dstTok.flatMap { classifyUnitToken($0, explicitSyntax: true) }
        if dstTok != nil && dstUnit == nil { return nil }

        let outVal: Double
        let outUnitLabel: String

        switch (srcUnit, dstUnit) {
        case (.tempC, nil), (.tempC, .some(.tempF)):
            if val < -273.15 { return nil }
            outVal = val * 9.0 / 5.0 + 32.0
            outUnitLabel = "°F"
        case (.tempF, nil), (.tempF, .some(.tempC)):
            if val < -459.67 { return nil }
            outVal = (val - 32.0) * 5.0 / 9.0
            outUnitLabel = "°C"

        case let (.dataBytes(srcFactor, srcLbl), .some(.dataBytes(dstFactor, dstLbl))):
            if val < 0 { return nil }
            if srcLbl == dstLbl { return nil }
            outVal = (val * srcFactor) / dstFactor
            outUnitLabel = dstLbl
        case let (.dataBytes(srcFactor, srcLbl), nil):
            if val < 0 { return nil }
            let bytes = val * srcFactor
            if srcLbl == "B" {
                (outVal, outUnitLabel) = bytes >= 1073741824.0 ? (bytes / 1073741824.0, "GB") : (bytes >= 1048576.0 ? (bytes / 1048576.0, "MB") : (bytes / 1024.0, "KB"))
            } else if srcLbl == "KB" {
                (outVal, outUnitLabel) = bytes >= 1073741824.0 ? (bytes / 1073741824.0, "GB") : (val / 1024.0, "MB")
            } else if srcLbl == "MB" {
                (outVal, outUnitLabel) = val >= 1024.0 ? (val / 1024.0, "GB") : (val * 1024.0, "KB")
            } else if srcLbl == "GB" {
                (outVal, outUnitLabel) = val >= 1024.0 ? (val / 1024.0, "TB") : (val * 1024.0, "MB")
            } else {
                (outVal, outUnitLabel) = (val * 1024.0, "GB")
            }

        case let (.durationSec(srcFactor, srcLbl), .some(.durationSec(dstFactor, dstLbl))):
            if val < 0 || srcLbl == dstLbl { return nil }
            outVal = (val * srcFactor) / dstFactor
            outUnitLabel = dstLbl
        case let (.durationSec(srcFactor, srcLbl), nil):
            if val < 0 { return nil }
            let secs = val * srcFactor
            if srcLbl == "ms" {
                (outVal, outUnitLabel) = secs >= 60.0 ? (secs / 60.0, "min") : (secs, "s")
            } else if srcLbl == "s" {
                (outVal, outUnitLabel) = secs >= 86400.0 ? (secs / 86400.0, "d") : (secs >= 3600.0 ? (secs / 3600.0, "h") : (secs / 60.0, "min"))
            } else if srcLbl == "min" {
                (outVal, outUnitLabel) = secs >= 3600.0 ? (secs / 3600.0, "h") : (secs, "s")
            } else if srcLbl == "h" {
                (outVal, outUnitLabel) = val >= 24.0 ? (val / 24.0, "d") : (val * 60.0, "min")
            } else {
                (outVal, outUnitLabel) = (val * 24.0, "h")
            }

        case let (.massKg(srcFactor, srcLbl), .some(.massKg(dstFactor, dstLbl))):
            if val < 0 || srcLbl == dstLbl { return nil }
            outVal = (val * srcFactor) / dstFactor
            outUnitLabel = dstLbl
        case let (.massKg(srcFactor, srcLbl), nil):
            if val < 0 { return nil }
            if srcLbl == "kg" {
                (outVal, outUnitLabel) = (val / 0.45359237, "lb")
            } else {
                (outVal, outUnitLabel) = ((val * srcFactor), "kg")
            }

        case let (.lengthCm(srcFactor, srcLbl), .some(.lengthCm(dstFactor, dstLbl))):
            if val < 0 || srcLbl == dstLbl { return nil }
            outVal = (val * srcFactor) / dstFactor
            outUnitLabel = dstLbl
        case let (.lengthCm(srcFactor, srcLbl), nil):
            if val < 0 { return nil }
            if srcLbl == "in" {
                (outVal, outUnitLabel) = (val * srcFactor, "cm")
            } else if srcLbl == "cm" {
                (outVal, outUnitLabel) = (val / 2.54, "in")
            } else if srcLbl == "mi" {
                (outVal, outUnitLabel) = ((val * srcFactor) / 100000.0, "km")
            } else {
                (outVal, outUnitLabel) = ((val * srcFactor) / 160934.4, "mi")
            }
        default:
            return nil
        }

        let rounded = (outVal * 10000.0).rounded() / 10000.0
        let numPlain = formatCleanDouble(rounded)
        let plainWithUnit = "\(numPlain) \(outUnitLabel)"
        return InstantMathResult(
            expressionDisplay: input,
            plainValue: plainWithUnit,
            formattedThousands: plainWithUnit,
            rmbUppercase: nil,
            isExplicitOrContextual: true
        )
    }

    /// 从首条剪贴板文本中提取干净的可计算金额/数值（严格排除 11+ 位纯数字手机号/订单号/身份证号）
    static func extractCleanClipboardNumber(from rawText: String?) -> (value: Double, plainNumeric: String, display: String)? {
        guard let raw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.utf8.count <= 48,
              !raw.contains("\n"),
              !raw.contains("\r") else {
            return nil
        }

        var s = raw
        let hadFormattingHint = s.contains(",") || s.contains("，") || s.contains(".")
            || s.contains("¥") || s.contains("￥") || s.contains("$")
            || s.contains("元") || s.contains("万") || s.contains("亿")

        for prefix in ["RMB", "rmb", "CNY", "cny", "USD", "usd", "¥", "￥", "$"] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        for suffix in ["元整", "圆整", "元", "圆"] {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        var unitMultiplier: Double = 1.0
        if s.hasSuffix("亿") {
            unitMultiplier = 100_000_000
            s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
        } else if s.hasSuffix("万") {
            unitMultiplier = 10_000
            s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        let cleanDigits = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
        guard !cleanDigits.isEmpty else { return nil }

        // 排除无千分位/小数点/货币符的 11 位及以上长数字串（如手机号 13800138000、时间戳、运单号）
        let unsignedDigits = (cleanDigits.hasPrefix("-") || cleanDigits.hasPrefix("+"))
            ? String(cleanDigits.dropFirst())
            : cleanDigits
        if !hadFormattingHint && unsignedDigits.count >= 11 && unsignedDigits.allSatisfy(\.isNumber) {
            return nil
        }

        guard let baseVal = Double(cleanDigits), baseVal.isFinite else {
            return nil
        }
        let finalVal = baseVal * unitMultiplier
        guard abs(finalVal) < 1_000_000_000_000 else { return nil }

        let plainNum = formatCleanDouble(finalVal)
        let parts = plainNum.hasPrefix("-")
            ? String(plainNum.dropFirst()).split(separator: ".", omittingEmptySubsequences: false)
            : plainNum.split(separator: ".", omittingEmptySubsequences: false)
        let intD = parts.first.map(String.init) ?? "0"
        let fracD = parts.count > 1 ? ".\(parts[1])" : ""
        let sign = plainNum.hasPrefix("-") ? "-" : ""
        let prettyDisplay = sign + addThousandsGrouping(intD) + fracD
        return (finalVal, plainNum, prettyDisplay)
    }

    private static func isLikelyMathExpression(_ s: String, hasLeadingEquals: Bool) -> Bool {
        var hasDigit = false
        var opCount = 0
        for ch in s {
            if ch.isWholeNumber && ch.isASCII {
                hasDigit = true
            } else if "+-*/%(). ".contains(ch) {
                if "+-*/%".contains(ch) {
                    opCount += 1
                }
            } else {
                return false
            }
        }
        guard hasDigit else { return false }
        if !hasLeadingEquals {
            guard opCount >= 1 else { return false }
            // 排除标准 YYYY-MM-DD 日期串被误当减法（例如 2026-11-23）
            if looksLikeISODate(s) { return false }
        }
        return true
    }

    private static func looksLikeISODate(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        if parts.count == 3,
           parts[0].count == 4, parts[0].allSatisfy(\.isNumber),
           (1...2).contains(parts[1].count), parts[1].allSatisfy(\.isNumber),
           (1...2).contains(parts[2].count), parts[2].allSatisfy(\.isNumber) {
            return true
        }
        return false
    }

    private static func formatCleanDouble(_ val: Double) -> String {
        if abs(val) < 1e-12 { return "0" }
        // 保留最多 6 位有效小数并剥离末尾多余 0，消除二进制浮点尾数毛刺（如 0.1 + 0.2 = 0.3）
        let rounded = (val * 1_000_000).rounded() / 1_000_000
        if abs(rounded - rounded.rounded()) < 1e-9 {
            return String(format: "%.0f", rounded)
        }
        var str = String(format: "%.6f", rounded)
        while str.last == "0" { str.removeLast() }
        if str.last == "." { str.removeLast() }
        return str
    }

    private static func addThousandsGrouping(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        var out = ""
        let chars = Array(digits)
        for (i, ch) in chars.enumerated() {
            if i > 0 && (chars.count - i) % 3 == 0 {
                out.append(",")
            }
            out.append(ch)
        }
        return out
    }

    // MARK: - 零异常递归下降算术解析器

    private struct Parser {
        private let chars: [Character]
        private var pos: Int = 0
        private(set) var didPerformBinaryOp: Bool = false

        init(_ input: String) {
            self.chars = Array(input)
        }

        var isAtEnd: Bool {
            var idx = pos
            while idx < chars.count && chars[idx] == " " { idx += 1 }
            return idx == chars.count
        }

        private mutating func skipSpaces() {
            while pos < chars.count && chars[pos] == " " { pos += 1 }
        }

        mutating func parseExpression() -> Double? {
            guard var lhs = parseTerm() else { return nil }
            while true {
                skipSpaces()
                guard pos < chars.count else { break }
                let op = chars[pos]
                guard op == "+" || op == "-" else { break }
                pos += 1
                guard let rhs = parseTerm() else { return nil }
                didPerformBinaryOp = true
                lhs = (op == "+") ? (lhs + rhs) : (lhs - rhs)
            }
            return lhs
        }

        private mutating func parseTerm() -> Double? {
            guard var lhs = parseFactor() else { return nil }
            while true {
                skipSpaces()
                guard pos < chars.count else { break }
                let op = chars[pos]
                guard op == "*" || op == "/" || op == "%" else { break }
                pos += 1
                guard let rhs = parseFactor() else { return nil }
                didPerformBinaryOp = true
                if op == "*" {
                    lhs *= rhs
                } else if op == "/" {
                    guard abs(rhs) > 1e-15 else { return nil }
                    lhs /= rhs
                } else {
                    guard abs(rhs) > 1e-15 else { return nil }
                    lhs = lhs.truncatingRemainder(dividingBy: rhs)
                }
            }
            return lhs
        }

        private mutating func parseFactor() -> Double? {
            guard var val = parsePrimary() else { return nil }
            // 智能区分后缀百分号（如 `12800 * 13%`、`1 / (1 + 6%)`）与二元取模（如 `17 % 5`）
            while true {
                skipSpaces()
                guard pos < chars.count, chars[pos] == "%" else { break }
                var lookahead = pos + 1
                while lookahead < chars.count && chars[lookahead] == " " {
                    lookahead += 1
                }
                let isBinaryModulo: Bool
                if lookahead < chars.count {
                    let nextCh = chars[lookahead]
                    isBinaryModulo = (nextCh.isWholeNumber && nextCh.isASCII) || nextCh == "." || nextCh == "("
                } else {
                    isBinaryModulo = false
                }
                if isBinaryModulo {
                    break
                }
                pos += 1
                didPerformBinaryOp = true
                val /= 100.0
            }
            return val
        }

        private mutating func parsePrimary() -> Double? {
            skipSpaces()
            guard pos < chars.count else { return nil }
            let ch = chars[pos]
            if ch == "+" {
                pos += 1
                return parseFactor()
            }
            if ch == "-" {
                pos += 1
                guard let v = parseFactor() else { return nil }
                return -v
            }
            if ch == "(" {
                pos += 1
                guard let inside = parseExpression() else { return nil }
                skipSpaces()
                guard pos < chars.count && chars[pos] == ")" else { return nil }
                pos += 1
                return inside
            }
            return parseNumber()
        }

        private mutating func parseNumber() -> Double? {
            skipSpaces()
            let start = pos
            var hasDot = false
            while pos < chars.count {
                let c = chars[pos]
                if c.isWholeNumber && c.isASCII {
                    pos += 1
                } else if c == "." && !hasDot {
                    hasDot = true
                    pos += 1
                } else {
                    break
                }
            }
            guard pos > start else { return nil }
            let token = String(chars[start..<pos])
            guard token != "." else { return nil }
            return Double(token)
        }
    }

    // MARK: - 离线零延迟日期推算、跨时区秒换算与 Unix 时间戳双向直算（Howard Hinnant 公历整数公式，0 外部依赖）

    private static let relativeDateSuffixRegex = try! NSRegularExpression(
        pattern: #"^([+-]?\d{1,4})\s*(天|日|周|星期|d|day|days|w|week|weeks)\s*(后|之后|前|之前|later|ago)?$"#,
        options: [.caseInsensitive]
    )
    private static let explicitDateShiftRegex = try! NSRegularExpression(
        pattern: #"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\s*([+-])\s*(\d{1,4})\s*(天|日|周|星期|d|day|days|w|week|weeks)?$"#,
        options: [.caseInsensitive]
    )
    private static let timezoneConvertRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*([a-z]{2,4})(?:\s*(?:to|in|->|=>|转)\s*([a-z]{2,4}))?$"#,
        options: [.caseInsensitive]
    )
    private static let tsDateRegex = try! NSRegularExpression(
        pattern: #"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?\s*(utc|z)?$"#,
        options: [.caseInsensitive]
    )

    private static func timezoneOffsetMinutes(_ code: String) -> (minutes: Int, label: String)? {
        switch code.lowercased() {
        case "utc", "gmt": return (0, "UTC")
        case "cst", "bj", "bjt", "hkt", "sgt": return (480, "UTC+8")
        case "jst", "kst": return (540, "UTC+9")
        case "pst": return (-480, "PST")
        case "pdt": return (-420, "PDT")
        case "est": return (-300, "EST")
        case "edt": return (-240, "EDT")
        case "cet": return (60, "CET")
        case "cest", "bst": return (120, code.uppercased())
        case "ist": return (330, "IST")
        case "aest": return (600, "AEST")
        default: return nil
        }
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int? {
        guard (1...12).contains(month), (1...31).contains(day), (1970...9999).contains(year) else { return nil }
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month + (month > 2 ? -3 : 9)
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let z = era * 146_097 + doe - 719_468
        // 反向校验防止 2 月 30 日等非法日期
        let check = civilFromDays(z)
        guard check.year == year && check.month == month && check.day == day else { return nil }
        return z
    }

    private static func civilFromDays(_ z: Int) -> (year: Int, month: Int, day: Int, weekdayCN: String) {
        let zShift = z + 719_468
        let era = (zShift >= 0 ? zShift : zShift - 146_096) / 146_097
        let doe = zShift - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        if m <= 2 { y += 1 }
        let wdIdx = ((z + 4) % 7 + 7) % 7
        let wdNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return (y, m, d, wdNames[wdIdx])
    }

    private static func evaluateTemporalExpression(_ input: String, hasLeadingEquals: Bool) -> InstantMathResult? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)

        // A. 指定日期加减：如 `2026-11-24 + 90天` / `2026-11-24 - 15d`
        if let m = explicitDateShiftRegex.firstMatch(in: trimmed, range: fullRange),
           let yR = Range(m.range(at: 1), in: trimmed),
           let moR = Range(m.range(at: 2), in: trimmed),
           let dR = Range(m.range(at: 3), in: trimmed),
           let opR = Range(m.range(at: 4), in: trimmed),
           let nR = Range(m.range(at: 5), in: trimmed),
           let y = Int(trimmed[yR]), let mo = Int(trimmed[moR]), let d = Int(trimmed[dR]),
           let n = Int(trimmed[nR]),
           let baseZ = daysFromCivil(year: y, month: mo, day: d) {
            let unitStr = m.range(at: 6).location != NSNotFound ? String(trimmed[Range(m.range(at: 6), in: trimmed)!]).lowercased() : "d"
            let mult = (unitStr == "周" || unitStr == "星期" || unitStr.hasPrefix("w")) ? 7 : 1
            let sign = trimmed[opR] == "-" ? -1 : 1
            let target = civilFromDays(baseZ + sign * n * mult)
            let iso = String(format: "%04d-%02d-%02d", target.year, target.month, target.day)
            return InstantMathResult(
                expressionDisplay: trimmed,
                plainValue: iso,
                formattedThousands: "\(iso)（\(target.weekdayCN)）",
                rmbUppercase: nil,
                isExplicitOrContextual: true
            )
        }

        // B. 相对今日推算：如 `90天后`、`15天前`、`+30天`、`-7天`、`2周后`（无符号且无前后缀的 `30天` 留给单位换算转小时）
        if let m = relativeDateSuffixRegex.firstMatch(in: trimmed, range: fullRange),
           let numR = Range(m.range(at: 1), in: trimmed),
           let unitR = Range(m.range(at: 2), in: trimmed),
           let rawNum = Int(trimmed[numR]) {
            let numStr = String(trimmed[numR])
            let hasExplicitSign = numStr.hasPrefix("+") || numStr.hasPrefix("-")
            let dirStr = m.range(at: 3).location != NSNotFound ? String(trimmed[Range(m.range(at: 3), in: trimmed)!]).lowercased() : ""
            if hasExplicitSign || !dirStr.isEmpty {
                let unitStr = String(trimmed[unitR]).lowercased()
                let mult = (unitStr == "周" || unitStr == "星期" || unitStr.hasPrefix("w")) ? 7 : 1
                var delta = abs(rawNum) * mult
                if numStr.hasPrefix("-") || dirStr == "前" || dirStr == "之前" || dirStr == "ago" {
                    delta = -delta
                }
                let cal = Calendar(identifier: .gregorian)
                let comps = cal.dateComponents([.year, .month, .day], from: Date())
                if let y = comps.year, let mo = comps.month, let d = comps.day,
                   let todayZ = daysFromCivil(year: y, month: mo, day: d) {
                    let target = civilFromDays(todayZ + delta)
                    let iso = String(format: "%04d-%02d-%02d", target.year, target.month, target.day)
                    return InstantMathResult(
                        expressionDisplay: trimmed,
                        plainValue: iso,
                        formattedThousands: "\(iso)（\(target.weekdayCN)）",
                        rmbUppercase: nil,
                        isExplicitOrContextual: true
                    )
                }
            }
        }

        // C. Unix 时间戳 ↔ 标准时间双向秒转：`ts 1763971200` / `= 1763971200` / `ts 2026-11-24 18:00:00`
        let lower = trimmed.lowercased()
        let isTSPrefix = lower.hasPrefix("ts ") || lower.hasPrefix("unix ")
        if isTSPrefix || hasLeadingEquals {
            let body = isTSPrefix
                ? String(trimmed.drop(while: { !$0.isWhitespace })).trimmingCharacters(in: .whitespaces)
                : trimmed
            if (body.count == 10 || body.count == 13), body.allSatisfy({ $0.isASCII && $0.isNumber }),
               let rawInt = Int64(body) {
                let sec = body.count == 13 ? rawInt / 1_000 : rawInt
                if (946_684_800...4_102_444_800).contains(sec) {
                    let bjTotal = sec + 8 * 3_600
                    let dayZ = Int(bjTotal >= 0 ? bjTotal / 86_400 : (bjTotal - 86_399) / 86_400)
                    let rem = Int(((bjTotal % 86_400) + 86_400) % 86_400)
                    let hh = rem / 3_600
                    let mm = (rem % 3_600) / 60
                    let ss = rem % 60
                    let civ = civilFromDays(dayZ)
                    let formatted = String(format: "%04d-%02d-%02d %02d:%02d:%02d", civ.year, civ.month, civ.day, hh, mm, ss)
                    return InstantMathResult(
                        expressionDisplay: "Unix \(sec)",
                        plainValue: formatted,
                        formattedThousands: "\(formatted) (UTC+8)",
                        rmbUppercase: nil,
                        isExplicitOrContextual: true
                    )
                }
            }
            if isTSPrefix {
                let bodyRange = NSRange(body.startIndex..<body.endIndex, in: body)
                if let dm = tsDateRegex.firstMatch(in: body, range: bodyRange),
                   let y = Int(body[Range(dm.range(at: 1), in: body)!]),
                   let mo = Int(body[Range(dm.range(at: 2), in: body)!]),
                   let d = Int(body[Range(dm.range(at: 3), in: body)!]),
                   let z = daysFromCivil(year: y, month: mo, day: d) {
                    let hh = dm.range(at: 4).location != NSNotFound ? (Int(body[Range(dm.range(at: 4), in: body)!]) ?? 0) : 0
                    let mm = dm.range(at: 5).location != NSNotFound ? (Int(body[Range(dm.range(at: 5), in: body)!]) ?? 0) : 0
                    let ss = dm.range(at: 6).location != NSNotFound ? (Int(body[Range(dm.range(at: 6), in: body)!]) ?? 0) : 0
                    guard (0...23).contains(hh), (0...59).contains(mm), (0...59).contains(ss) else { return nil }
                    let isUTC = dm.range(at: 7).location != NSNotFound
                    let tzShift = isUTC ? 0 : (8 * 3_600)
                    let epochSec = Int64(z) * 86_400 + Int64(hh * 3_600 + mm * 60 + ss - tzShift)
                    let secStr = String(epochSec)
                    return InstantMathResult(
                        expressionDisplay: body,
                        plainValue: secStr,
                        formattedThousands: "\(secStr) s",
                        rmbUppercase: nil,
                        isExplicitOrContextual: true
                    )
                }
            }
        }

        // D. 跨时区钟点换算：如 `10:00 pst`、`14:30 utc`、`9am est`、`20:00 bj to pst`
        if let tm = timezoneConvertRegex.firstMatch(in: trimmed, range: fullRange),
           let hR = Range(tm.range(at: 1), in: trimmed),
           let srcTzR = Range(tm.range(at: 4), in: trimmed),
           var hour = Int(trimmed[hR]),
           let srcTZ = timezoneOffsetMinutes(String(trimmed[srcTzR])) {
            let minute = tm.range(at: 2).location != NSNotFound ? (Int(trimmed[Range(tm.range(at: 2), in: trimmed)!]) ?? 0) : 0
            let hasColon = tm.range(at: 2).location != NSNotFound
            let ampm = tm.range(at: 3).location != NSNotFound ? String(trimmed[Range(tm.range(at: 3), in: trimmed)!]).lowercased() : ""
            let dstRaw = tm.range(at: 5).location != NSNotFound ? String(trimmed[Range(tm.range(at: 5), in: trimmed)!]) : nil
            // 防误伤：若既无冒号、无 am/pm、无目标时区且无前导 `=`（例如搜型号 `10 pst` 除外，要求带冒号或 am/pm 或 to）
            guard hasColon || !ampm.isEmpty || dstRaw != nil || hasLeadingEquals else { return nil }
            if !ampm.isEmpty {
                guard (1...12).contains(hour) else { return nil }
                if ampm == "pm" && hour != 12 { hour += 12 }
                if ampm == "am" && hour == 12 { hour = 0 }
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            let dstTZ: (minutes: Int, label: String)
            if let dr = dstRaw {
                guard let parsed = timezoneOffsetMinutes(dr) else { return nil }
                dstTZ = parsed
            } else {
                dstTZ = (srcTZ.minutes == 480) ? (0, "UTC") : (480, "UTC+8")
            }
            guard dstTZ.minutes != srcTZ.minutes else { return nil }
            let totalTargetMin = hour * 60 + minute - srcTZ.minutes + dstTZ.minutes
            var dayShift = 0
            var normMin = totalTargetMin
            while normMin < 0 {
                normMin += 1_440
                dayShift -= 1
            }
            while normMin >= 1_440 {
                normMin -= 1_440
                dayShift += 1
            }
            let outHH = normMin / 60
            let outMM = normMin % 60
            let daySuffix = dayShift > 0 ? " (+\(dayShift)天)" : (dayShift < 0 ? " (\(dayShift)天)" : "")
            let plain = String(format: "%02d:%02d%@", outHH, outMM, daySuffix)
            return InstantMathResult(
                expressionDisplay: trimmed,
                plainValue: plain,
                formattedThousands: "\(plain) · \(dstTZ.label)",
                rmbUppercase: nil,
                isExplicitOrContextual: true
            )
        }

        return nil
    }

    // MARK: - 商业折扣（`1280 85折` / `7.5折`）、环比涨跌幅（`12500 -> 16000`）与进制双向直算（`0xff` / `255 to hex`）

    private static let cnDiscountFullRegex = try! NSRegularExpression(
        pattern: #"^(?:[¥￥$]?\s*(\d[\d,]*(?:\.\d+)?)\s*(?:[*×xX]\s*|\s+|打))?打?\s*(\d(?:\.\d{1,2})?|[1-9]\d)\s*折$"#
    )
    private static let pctDeltaRegex = try! NSRegularExpression(
        pattern: #"^[¥￥$]?\s*(-?\d[\d,]*(?:\.\d+)?)\s*(?:->|=>|vs|VS)\s*[¥￥$]?\s*(-?\d[\d,]*(?:\.\d+)?)$"#
    )
    private static let radixConvertRegex = try! NSRegularExpression(
        pattern: #"^(?:0x([0-9a-fA-F]{2,16})|0b([01]{4,63})|(\d{1,19})\s+(?:to|in|->|=>|转)\s*(hex|bin|binary|dec))$"#,
        options: [.caseInsensitive]
    )
    private static let invoiceTaxRegex = try! NSRegularExpression(
        pattern: #"^(?:[¥￥$]?\s*(\d[\d,]*(?:\.\d+)?)\s*)?(含税|价税分离|去税|除税|加税|不含税|税前)\s*(?:(\d{1,2}(?:\.\d{1,2})?)\s*[%％]?)?$"#
    )
    private static let salaryWageRegex = try! NSRegularExpression(
        pattern: #"^(?:[¥￥$]?\s*(\d[\d,]*(?:\.\d+)?)\s*([kKwW万])?\s*)?(?:算|折算|转)?(日薪|时薪|月薪|加班费)$"#
    )
    private static let aaSplitRegex = try! NSRegularExpression(
        pattern: #"^(?:[¥￥$]?\s*(\d[\d,]*(?:\.\d+)?)\s*)?(?:(?:aa|AA|平摊|分摊|均摊)\s*(\d{1,5})\s*人?|[/÷]\s*(\d{1,5})\s*人)$"#
    )

    private static func evaluateBusinessAndRadixExpression(
        _ input: String,
        latestClipboardText: String?
    ) -> InstantMathResult? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)

        // 0a. 职场法定计薪折算（国家标准 21.75 计薪日 × 8h = 174h/月）：`25000 日薪`、`25k 时薪`、`2.5万 加班费` 或剪贴板续算 `日薪`
        if let sm = salaryWageRegex.firstMatch(in: trimmed, range: fullRange),
           let modeR = Range(sm.range(at: 3), in: trimmed) {
            let modeStr = String(trimmed[modeR])
            let monthlySalary: Double
            if sm.range(at: 1).location != NSNotFound,
               let amtR = Range(sm.range(at: 1), in: trimmed),
               let rawNum = Double(trimmed[amtR].replacingOccurrences(of: ",", with: "")),
               rawNum > 0 {
                var mul = 1.0
                if sm.range(at: 2).location != NSNotFound,
                   let unitR = Range(sm.range(at: 2), in: trimmed) {
                    let u = trimmed[unitR].lowercased()
                    if u == "k" { mul = 1_000.0 }
                    else if u == "w" || u == "万" { mul = 10_000.0 }
                }
                monthlySalary = rawNum * mul
            } else if let ctx = extractCleanClipboardNumber(from: latestClipboardText),
                      let v = Double(ctx.plainNumeric), v > 0 {
                monthlySalary = v
            } else {
                return nil
            }

            let daily = (monthlySalary / 21.75 * 100.0).rounded() / 100.0
            let hourly = (monthlySalary / 174.0 * 100.0).rounded() / 100.0
            let ot15 = (hourly * 1.5 * 100.0).rounded() / 100.0
            let ot20 = (hourly * 2.0 * 100.0).rounded() / 100.0
            let dailyStr = formatCleanDouble(daily)
            let hourlyStr = formatCleanDouble(hourly)
            let ot15Str = formatCleanDouble(ot15)
            let ot20Str = formatCleanDouble(ot20)

            let wantsHourly = (modeStr == "时薪" || modeStr == "加班费")
            let primaryOut = wantsHourly ? hourlyStr : dailyStr
            let exprTitle = "月薪 \(formatCleanDouble(monthlySalary)) 法定折算"
            let richSummary = wantsHourly
                ? "时薪 \(hourlyStr) · 日薪 \(dailyStr)（1.5倍 \(ot15Str)/h · 2倍 \(ot20Str)/h）"
                : "日薪 \(dailyStr) · 时薪 \(hourlyStr)（法定21.75天 · 1.5倍 \(ot15Str)/h）"

            return InstantMathResult(
                expressionDisplay: exprTitle,
                plainValue: primaryOut,
                formattedThousands: richSummary,
                rmbUppercase: nil,
                isExplicitOrContextual: true
            )
        }

        // 0b. 多人 AA 平摊零尾差直算：`1286 / 6人`、`1286 aa 6` 或复制账单金额后直接敲 `aa 6` / `平摊 6人`
        if let am = aaSplitRegex.firstMatch(in: trimmed, range: fullRange) {
            let countRange = (am.range(at: 2).location != NSNotFound) ? am.range(at: 2) : am.range(at: 3)
            guard countRange.location != NSNotFound,
                  let cntR = Range(countRange, in: trimmed),
                  let people = Int(trimmed[cntR]),
                  (2...10_000).contains(people) else {
                return nil
            }
            let totalAmount: Double
            if am.range(at: 1).location != NSNotFound,
               let amtR = Range(am.range(at: 1), in: trimmed),
               let v = Double(trimmed[amtR].replacingOccurrences(of: ",", with: "")),
               v > 0 {
                totalAmount = v
            } else if let ctx = extractCleanClipboardNumber(from: latestClipboardText),
                      let v = Double(ctx.plainNumeric), v > 0 {
                totalAmount = v
            } else {
                return nil
            }

            let totalCents = Int64((totalAmount * 100.0).rounded())
            let perCents = Int64((Double(totalCents) / Double(people)).rounded())
            let diffCents = perCents * Int64(people) - totalCents
            let perVal = Double(perCents) / 100.0
            let perStr = formatCleanDouble(perVal)
            let diffDesc: String
            if diffCents == 0 {
                diffDesc = "刚好整除无尾差"
            } else if diffCents > 0 {
                diffDesc = String(format: "合计多收 +%.2f", Double(diffCents) / 100.0)
            } else {
                diffDesc = String(format: "合计尾差 %.2f", Double(diffCents) / 100.0)
            }
            let parts = perStr.split(separator: ".", omittingEmptySubsequences: false)
            let intDigits = parts.first.map(String.init) ?? "0"
            let fracDigits = parts.count > 1 ? String(parts[1]) : nil
            let rmb = intDigits.count <= 12
                ? FinanceNumberEngine.toChineseUppercaseRMB(intDigits: intDigits, fracDigits: fracDigits.map { String($0.prefix(2)) })
                : nil

            return InstantMathResult(
                expressionDisplay: "\(formatCleanDouble(totalAmount)) ÷ \(people)人 AA",
                plainValue: perStr,
                formattedThousands: "每人 \(perStr)（共 \(people) 人 · \(diffDesc)）",
                rmbUppercase: rmb,
                isExplicitOrContextual: true
            )
        }

        // 0. 零尾差发票价税分离 & 加税开票直算：`12800 含税 6%`、`1130 含税`（默认 13%）、`10000 加税 6%` 或剪贴板免重敲 `含税 6%`
        if let tm = invoiceTaxRegex.firstMatch(in: trimmed, range: fullRange),
           let modeR = Range(tm.range(at: 2), in: trimmed) {
            let modeStr = String(trimmed[modeR])
            let taxPct: Double
            if tm.range(at: 3).location != NSNotFound,
               let rateR = Range(tm.range(at: 3), in: trimmed),
               let parsedRate = Double(trimmed[rateR]) {
                taxPct = parsedRate
            } else {
                taxPct = 13.0
            }
            guard taxPct > 0.0 && taxPct <= 50.0 else { return nil }

            let baseAmount: Double
            if tm.range(at: 1).location != NSNotFound,
               let amtR = Range(tm.range(at: 1), in: trimmed) {
                guard let v = Double(trimmed[amtR].replacingOccurrences(of: ",", with: "")), v > 0 else { return nil }
                baseAmount = v
            } else if let ctx = extractCleanClipboardNumber(from: latestClipboardText),
                      let v = Double(ctx.plainNumeric), v > 0 {
                baseAmount = v
            } else {
                return nil
            }

            let rate = taxPct / 100.0
            let rateLabel = formatCleanDouble(taxPct) + "%"
            let isInclusive = (modeStr == "含税" || modeStr == "价税分离" || modeStr == "去税" || modeStr == "除税")

            let primaryCents: Int64
            let taxCents: Int64
            let exprTitle: String
            let richSummary: String

            let totalInputCents = Int64((baseAmount * 100.0).rounded())
            if isInclusive {
                let netCents = Int64((Double(totalInputCents) / (1.0 + rate)).rounded())
                let diffTaxCents = totalInputCents - netCents
                primaryCents = netCents
                taxCents = diffTaxCents
                let netStr = formatCleanDouble(Double(netCents) / 100.0)
                let taxStr = formatCleanDouble(Double(diffTaxCents) / 100.0)
                exprTitle = "\(formatCleanDouble(baseAmount)) 含\(rateLabel)税拆分"
                richSummary = "不含税 \(netStr) · 税额 \(taxStr)（\(rateLabel)）"
            } else {
                let grossCents = Int64((Double(totalInputCents) * (1.0 + rate)).rounded())
                let addedTaxCents = grossCents - totalInputCents
                primaryCents = grossCents
                taxCents = addedTaxCents
                let grossStr = formatCleanDouble(Double(grossCents) / 100.0)
                let taxStr = formatCleanDouble(Double(addedTaxCents) / 100.0)
                exprTitle = "\(formatCleanDouble(baseAmount)) +\(rateLabel)税"
                richSummary = "含税 \(grossStr) · 税额 \(taxStr)（\(rateLabel)）"
            }
            _ = taxCents

            let primaryVal = Double(primaryCents) / 100.0
            let plainOut = formatCleanDouble(primaryVal)
            let parts = plainOut.split(separator: ".", omittingEmptySubsequences: false)
            let intDigits = parts.first.map(String.init) ?? "0"
            let fracDigits = parts.count > 1 ? String(parts[1]) : nil
            let rmb = intDigits.count <= 12
                ? FinanceNumberEngine.toChineseUppercaseRMB(intDigits: intDigits, fracDigits: fracDigits.map { String($0.prefix(2)) })
                : nil

            return InstantMathResult(
                expressionDisplay: exprTitle,
                plainValue: plainOut,
                formattedThousands: richSummary,
                rmbUppercase: rmb,
                isExplicitOrContextual: true
            )
        }

        // 1. 中式商业折扣秒算：`1280 85折`、`299 7.5折`、或结合 `#1` 剪贴板金额免重敲输入 `85折`
        if let dm = cnDiscountFullRegex.firstMatch(in: trimmed, range: fullRange),
           let rateR = Range(dm.range(at: 2), in: trimmed) {
            let rateRawStr = String(trimmed[rateR])
            guard let rateVal = Double(rateRawStr), rateVal > 0 else { return nil }
            let factor: Double
            if rateRawStr.contains(".") || rateVal < 10.0 {
                factor = rateVal / 10.0
            } else {
                factor = rateVal / 100.0
            }
            guard factor > 0 && factor < 1.0 else { return nil }

            let baseAmount: Double
            let baseDisplay: String
            if dm.range(at: 1).location != NSNotFound,
               let amtR = Range(dm.range(at: 1), in: trimmed) {
                let amtStr = trimmed[amtR].replacingOccurrences(of: ",", with: "")
                guard let v = Double(amtStr), v > 0 else { return nil }
                baseAmount = v
                baseDisplay = String(trimmed[amtR])
            } else if let ctx = extractCleanClipboardNumber(from: latestClipboardText),
                      let v = Double(ctx.plainNumeric), v > 0 {
                baseAmount = v
                baseDisplay = ctx.display
            } else {
                return nil
            }

            let discounted = baseAmount * factor
            let plain = formatCleanDouble(discounted)
            let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
            let intDigits = parts.first.map(String.init) ?? "0"
            let fracDigits = parts.count > 1 ? String(parts[1]) : nil
            let thousands = addThousandsGrouping(intDigits) + (fracDigits != nil ? ".\(fracDigits!)" : "")
            let rmb = intDigits.count <= 12
                ? FinanceNumberEngine.toChineseUppercaseRMB(intDigits: intDigits, fracDigits: fracDigits.map { String($0.prefix(2)) })
                : nil
            return InstantMathResult(
                expressionDisplay: "\(baseDisplay) × \(rateRawStr)折",
                plainValue: plain,
                formattedThousands: thousands,
                rmbUppercase: rmb,
                isExplicitOrContextual: true
            )
        }

        // 2. 两点涨跌幅与倍数秒算：`12500 -> 16000` / `200 vs 150`
        if let pm = pctDeltaRegex.firstMatch(in: trimmed, range: fullRange),
           let aR = Range(pm.range(at: 1), in: trimmed),
           let bR = Range(pm.range(at: 2), in: trimmed),
           let a = Double(trimmed[aR].replacingOccurrences(of: ",", with: "")),
           let b = Double(trimmed[bR].replacingOccurrences(of: ",", with: "")),
           abs(a) > 1e-9, a != b {
            let pct = ((b - a) / abs(a)) * 100.0
            let diff = b - a
            let sign = pct > 0 ? "+" : ""
            let pctPlain = "\(sign)\(formatCleanDouble(pct))%"
            let diffSign = diff > 0 ? "+" : ""
            let ratioStr = a > 0 && b >= 0 ? String(format: " · %.2fx", b / a) : ""
            return InstantMathResult(
                expressionDisplay: "\(trimmed[aR]) → \(trimmed[bR])",
                plainValue: pctPlain,
                formattedThousands: "\(pctPlain)（差额 \(diffSign)\(formatCleanDouble(diff))\(ratioStr)）",
                rmbUppercase: nil,
                isExplicitOrContextual: true
            )
        }

        // 3. 程序员十六进制 / 二进制双向秒转：`0xff`、`0b101010`、`255 to hex`、`42 to bin`
        if let rm = radixConvertRegex.firstMatch(in: trimmed, range: fullRange) {
            if rm.range(at: 1).location != NSNotFound,
               let hexR = Range(rm.range(at: 1), in: trimmed),
               let val = UInt64(trimmed[hexR], radix: 16) {
                let decStr = String(val)
                let binSuffix = val <= 0xFFFF ? " · 0b\(String(val, radix: 2))" : ""
                return InstantMathResult(
                    expressionDisplay: "0x\(trimmed[hexR].uppercased())",
                    plainValue: decStr,
                    formattedThousands: "\(addThousandsGrouping(decStr))\(binSuffix)",
                    rmbUppercase: nil,
                    isExplicitOrContextual: true
                )
            }
            if rm.range(at: 2).location != NSNotFound,
               let binR = Range(rm.range(at: 2), in: trimmed),
               let val = UInt64(trimmed[binR], radix: 2) {
                let decStr = String(val)
                let hexStr = "0x" + String(val, radix: 16, uppercase: true)
                return InstantMathResult(
                    expressionDisplay: "0b\(trimmed[binR])",
                    plainValue: decStr,
                    formattedThousands: "\(decStr) · \(hexStr)",
                    rmbUppercase: nil,
                    isExplicitOrContextual: true
                )
            }
            if rm.range(at: 3).location != NSNotFound,
               rm.range(at: 4).location != NSNotFound,
               let decR = Range(rm.range(at: 3), in: trimmed),
               let dstR = Range(rm.range(at: 4), in: trimmed),
               let val = UInt64(trimmed[decR]) {
                let dst = trimmed[dstR].lowercased()
                if dst == "hex" {
                    let hexOut = "0x" + String(val, radix: 16, uppercase: true)
                    return InstantMathResult(
                        expressionDisplay: "\(val) → HEX",
                        plainValue: hexOut,
                        formattedThousands: hexOut,
                        rmbUppercase: nil,
                        isExplicitOrContextual: true
                    )
                } else if dst == "bin" || dst == "binary" {
                    let binOut = "0b" + String(val, radix: 2)
                    return InstantMathResult(
                        expressionDisplay: "\(val) → BIN",
                        plainValue: binOut,
                        formattedThousands: binOut,
                        rmbUppercase: nil,
                        isExplicitOrContextual: true
                    )
                }
            }
        }

        return nil
    }

    // MARK: - 色彩全制式互转（HEX / RGB / HSL）与 WCAG 2.1 无障碍对比度直算（`#FFFFFF vs #1E5EFF`）

    private static let colorHexTokenRegex = try! NSRegularExpression(
        pattern: #"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#
    )
    private static let colorRGBTokenRegex = try! NSRegularExpression(
        pattern: #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})(?:\s*,\s*([0-9]*\.?[0-9]+))?\s*\)$"#,
        options: [.caseInsensitive]
    )
    private static let colorHSLTokenRegex = try! NSRegularExpression(
        pattern: #"^hsla?\(\s*(\d{1,3}(?:\.\d+)?)\s*,\s*(\d{1,3}(?:\.\d+)?)%\s*,\s*(\d{1,3}(?:\.\d+)?)%(?:\s*,\s*([0-9]*\.?[0-9]+))?\s*\)$"#,
        options: [.caseInsensitive]
    )
    private static let colorConvertTailRegex = try! NSRegularExpression(
        pattern: #"^(.+?)\s+(?:to|in|->|=>|转)\s*(hex|rgb|hsl)$"#,
        options: [.caseInsensitive]
    )
    private static let colorContrastPairRegex = try! NSRegularExpression(
        pattern: #"^(?:(?:对比|contrast)\s*(#\S+|rgba?\([^)]+\)|hsla?\([^)]+\))\s+(#\S+|rgba?\([^)]+\)|hsla?\([^)]+\))|(#\S+|rgba?\([^)]+\)|hsla?\([^)]+\))\s+(?:vs|on|对比|with)\s+(#\S+|rgba?\([^)]+\)|hsla?\([^)]+\))|(?:vs|on|对比)\s+(#\S+|rgba?\([^)]+\)|hsla?\([^)]+\)))$"#,
        options: [.caseInsensitive]
    )

    private enum ColorSourceKind {
        case hex(digits: Int)
        case rgb
        case hsl
    }

    private struct ParsedColorValue {
        let r: Double
        let g: Double
        let b: Double
        let a: Double
        let sourceKind: ColorSourceKind
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        let hue = ((h.truncatingRemainder(dividingBy: 360.0)) + 360.0).truncatingRemainder(dividingBy: 360.0)
        let c = (1.0 - abs(2.0 * l - 1.0)) * s
        let x = c * (1.0 - abs((hue / 60.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = l - c / 2.0
        let (r1, g1, b1): (Double, Double, Double)
        switch hue {
        case 0..<60:   (r1, g1, b1) = (c, x, 0)
        case 60..<120: (r1, g1, b1) = (x, c, 0)
        case 120..<180:(r1, g1, b1) = (0, c, x)
        case 180..<240:(r1, g1, b1) = (0, x, c)
        case 240..<300:(r1, g1, b1) = (x, 0, c)
        default:       (r1, g1, b1) = (c, 0, x)
        }
        return (min(max(r1 + m, 0), 1), min(max(g1 + m, 0), 1), min(max(b1 + m, 0), 1))
    }

    static func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Int, s: Int, l: Int) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let l = (maxC + minC) / 2.0
        var h = 0.0
        var s = 0.0
        if delta > 1e-7 {
            s = delta / (1.0 - abs(2.0 * l - 1.0))
            if maxC == r {
                h = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6.0))
            } else if maxC == g {
                h = 60.0 * (((b - r) / delta) + 2.0)
            } else {
                h = 60.0 * (((r - g) / delta) + 4.0)
            }
            if h < 0 { h += 360.0 }
        }
        return (Int(round(h)) % 360, Int(round(s * 100.0)), Int(round(l * 100.0)))
    }

    static func formatHSL(r: Double, g: Double, b: Double, a: Double = 1.0) -> String {
        let hsl = rgbToHSL(r: r, g: g, b: b)
        if a < 0.995 {
            return String(format: "hsla(%d, %d%%, %d%%, %.2f)", hsl.h, hsl.s, hsl.l, a)
        }
        return "hsl(\(hsl.h), \(hsl.s)%, \(hsl.l)%)"
    }

    private static func formatColorHex(_ c: ParsedColorValue) -> String {
        let r = Int(round(c.r * 255.0))
        let g = Int(round(c.g * 255.0))
        let b = Int(round(c.b * 255.0))
        if c.a < 0.995 {
            let a = Int(round(c.a * 255.0))
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func formatColorRGB(_ c: ParsedColorValue) -> String {
        let r = Int(round(c.r * 255.0))
        let g = Int(round(c.g * 255.0))
        let b = Int(round(c.b * 255.0))
        if c.a < 0.995 {
            return String(format: "rgba(%d, %d, %d, %.2f)", r, g, b, c.a)
        }
        return "rgb(\(r), \(g), \(b))"
    }

    private static func parseSingleColorToken(_ raw: String, allowShortHex: Bool) -> ParsedColorValue? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 4, s.count <= 64 else { return nil }
        let nsRange = NSRange(s.startIndex..<s.endIndex, in: s)

        if let m = colorHexTokenRegex.firstMatch(in: s, range: nsRange),
           let hexR = Range(m.range(at: 1), in: s) {
            let hex = String(s[hexR])
            if hex.count == 3 && !allowShortHex { return nil }
            guard let val = UInt64(hex, radix: 16) else { return nil }
            switch hex.count {
            case 3:
                return ParsedColorValue(
                    r: Double((val >> 8) & 0xF) / 15.0,
                    g: Double((val >> 4) & 0xF) / 15.0,
                    b: Double(val & 0xF) / 15.0,
                    a: 1.0,
                    sourceKind: .hex(digits: 3)
                )
            case 6:
                return ParsedColorValue(
                    r: Double((val >> 16) & 0xFF) / 255.0,
                    g: Double((val >> 8) & 0xFF) / 255.0,
                    b: Double(val & 0xFF) / 255.0,
                    a: 1.0,
                    sourceKind: .hex(digits: 6)
                )
            case 8:
                return ParsedColorValue(
                    r: Double((val >> 24) & 0xFF) / 255.0,
                    g: Double((val >> 16) & 0xFF) / 255.0,
                    b: Double((val >> 8) & 0xFF) / 255.0,
                    a: Double(val & 0xFF) / 255.0,
                    sourceKind: .hex(digits: 8)
                )
            default:
                return nil
            }
        }

        if let m = colorRGBTokenRegex.firstMatch(in: s, range: nsRange),
           let rR = Range(m.range(at: 1), in: s),
           let gR = Range(m.range(at: 2), in: s),
           let bR = Range(m.range(at: 3), in: s),
           let ri = Int(s[rR]), let gi = Int(s[gR]), let bi = Int(s[bR]),
           (0...255).contains(ri), (0...255).contains(gi), (0...255).contains(bi) {
            var a = 1.0
            if m.range(at: 4).location != NSNotFound,
               let aR = Range(m.range(at: 4), in: s),
               let av = Double(s[aR]) {
                a = min(max(av, 0.0), 1.0)
            }
            return ParsedColorValue(
                r: Double(ri) / 255.0,
                g: Double(gi) / 255.0,
                b: Double(bi) / 255.0,
                a: a,
                sourceKind: .rgb
            )
        }

        if let m = colorHSLTokenRegex.firstMatch(in: s, range: nsRange),
           let hR = Range(m.range(at: 1), in: s),
           let sR = Range(m.range(at: 2), in: s),
           let lR = Range(m.range(at: 3), in: s),
           let hd = Double(s[hR]), let sp = Double(s[sR]), let lp = Double(s[lR]),
           (0.0...360.0).contains(hd), (0.0...100.0).contains(sp), (0.0...100.0).contains(lp) {
            var a = 1.0
            if m.range(at: 4).location != NSNotFound,
               let aR = Range(m.range(at: 4), in: s),
               let av = Double(s[aR]) {
                a = min(max(av, 0.0), 1.0)
            }
            let rgb = hslToRGB(h: hd, s: sp / 100.0, l: lp / 100.0)
            return ParsedColorValue(r: rgb.r, g: rgb.g, b: rgb.b, a: a, sourceKind: .hsl)
        }

        return nil
    }

    private static func wcagRelativeLuminance(_ c: ParsedColorValue) -> Double {
        func linearize(_ v: Double) -> Double {
            v <= 0.04045 ? (v / 12.92) : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b)
    }

    private static func evaluateColorAndContrastExpression(
        _ input: String,
        hasLeadingEquals: Bool,
        latestClipboardText: String?
    ) -> InstantMathResult? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)

        // 1. 双色 WCAG 2.1 无障碍对比度直算：`#FFFFFF vs #1E5EFF`、`对比 #FFF #1E5EFF` 或免重敲 `vs #FFFFFF`
        if let cm = colorContrastPairRegex.firstMatch(in: trimmed, range: fullRange) {
            let pairTokens: (String, String)? = {
                if cm.range(at: 1).location != NSNotFound, cm.range(at: 2).location != NSNotFound,
                   let r1 = Range(cm.range(at: 1), in: trimmed), let r2 = Range(cm.range(at: 2), in: trimmed) {
                    return (String(trimmed[r1]), String(trimmed[r2]))
                }
                if cm.range(at: 3).location != NSNotFound, cm.range(at: 4).location != NSNotFound,
                   let r3 = Range(cm.range(at: 3), in: trimmed), let r4 = Range(cm.range(at: 4), in: trimmed) {
                    return (String(trimmed[r3]), String(trimmed[r4]))
                }
                if cm.range(at: 5).location != NSNotFound,
                   let r5 = Range(cm.range(at: 5), in: trimmed),
                   let clipRaw = latestClipboardText?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    return (clipRaw, String(trimmed[r5]))
                }
                return nil
            }()

            if let (tokA, tokB) = pairTokens,
               let colA = parseSingleColorToken(tokA, allowShortHex: true),
               let colB = parseSingleColorToken(tokB, allowShortHex: true) {
                let lumA = wcagRelativeLuminance(colA)
                let lumB = wcagRelativeLuminance(colB)
                let ratio = (max(lumA, lumB) + 0.05) / (min(lumA, lumB) + 0.05)
                let ratioStr = String(format: "%.2f:1", ratio)
                let grade: String
                if ratio >= 7.0 {
                    grade = "WCAG AAA 极佳"
                } else if ratio >= 4.5 {
                    grade = "WCAG AA 达标（大字 AAA）"
                } else if ratio >= 3.0 {
                    grade = "仅大字 AA 达标"
                } else {
                    grade = "未达标（对比偏弱）"
                }
                return InstantMathResult(
                    expressionDisplay: "\(formatColorHex(colA)) vs \(formatColorHex(colB))",
                    plainValue: ratioStr,
                    formattedThousands: "\(ratioStr) · \(grade)",
                    rmbUppercase: nil,
                    isExplicitOrContextual: true
                )
            }
        }

        // 2. 单色全制式互转：`#1E5EFF`、`rgb(30, 94, 255)`、`hsl(223, 100%, 56%)`（支持 `to rgb/hsl/hex`）
        var targetFormat: String? = nil
        var colorCandidate = trimmed
        if let tm = colorConvertTailRegex.firstMatch(in: trimmed, range: fullRange),
           let bodyR = Range(tm.range(at: 1), in: trimmed),
           let dstR = Range(tm.range(at: 2), in: trimmed) {
            colorCandidate = String(trimmed[bodyR])
            targetFormat = trimmed[dstR].lowercased()
        }

        guard let parsed = parseSingleColorToken(colorCandidate, allowShortHex: hasLeadingEquals || targetFormat != nil) else {
            return nil
        }

        let hexStr = formatColorHex(parsed)
        let rgbStr = formatColorRGB(parsed)
        let hslStr = formatHSL(r: parsed.r, g: parsed.g, b: parsed.b, a: parsed.a)

        let primaryOut: String
        let richDisplay: String
        if let dst = targetFormat {
            switch dst {
            case "hex":
                primaryOut = hexStr
                richDisplay = "\(hexStr) · \(rgbStr)"
            case "hsl":
                primaryOut = hslStr
                richDisplay = "\(hslStr) · \(hexStr)"
            default:
                primaryOut = rgbStr
                richDisplay = "\(rgbStr) · \(hslStr)"
            }
        } else {
            switch parsed.sourceKind {
            case .hex:
                primaryOut = rgbStr
                richDisplay = "\(rgbStr) · \(hslStr)"
            case .rgb:
                primaryOut = hexStr
                richDisplay = "\(hexStr) · \(hslStr)"
            case .hsl:
                primaryOut = hexStr
                richDisplay = "\(hexStr) · \(rgbStr)"
            }
        }

        return InstantMathResult(
            expressionDisplay: hexStr,
            plainValue: primaryOut,
            formattedThousands: richDisplay,
            rmbUppercase: nil,
            isExplicitOrContextual: true
        )
    }

    // MARK: - 编程与数据库命名风格搜索框直转（`camel user_id` / `snake userOrderId` / `to snake` / `转驼峰`）

    private static let casePrefixCmdRegex = try! NSRegularExpression(
        pattern: #"^(camel|camelcase|pascal|pascalcase|snake|snakecase|kebab|kebabcase|const|constant|upper|转驼峰|驼峰|转下划线|下划线|转短横线|转常量)\s+([A-Za-z0-9_\-\s]{2,96})$"#,
        options: [.caseInsensitive]
    )
    private static let caseSuffixCmdRegex = try! NSRegularExpression(
        pattern: #"^(?:([A-Za-z0-9_\-]{2,96})\s+)?(?:to|in|->|=>|转)\s*(camel|camelcase|pascal|pascalcase|snake|snakecase|kebab|kebabcase|const|constant|驼峰|下划线|短横线|常量)$"#,
        options: [.caseInsensitive]
    )

    private static func tokenizeIdentifierWords(_ raw: String) -> [String] {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == " ") }) else {
            return []
        }
        var normalized = ""
        let chars = Array(s)
        for i in 0..<chars.count {
            let c = chars[i]
            if c == "_" || c == "-" || c == " " {
                normalized.append(" ")
                continue
            }
            if i > 0 {
                let prev = chars[i - 1]
                let prevLowerOrDigit = prev.isLowercase || prev.isNumber
                let nextLower = (i + 1 < chars.count) ? chars[i + 1].isLowercase : false
                if c.isUppercase && (prevLowerOrDigit || (prev.isUppercase && nextLower)) {
                    normalized.append(" ")
                }
            }
            normalized.append(c)
        }
        return normalized.split(separator: " ").map { String($0).lowercased() }.filter { !$0.isEmpty }
    }

    private static func evaluateIdentifierCaseExpression(
        _ input: String,
        latestClipboardText: String?
    ) -> InstantMathResult? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)

        var styleRaw: String? = nil
        var sourceIdent: String? = nil

        if let pm = casePrefixCmdRegex.firstMatch(in: trimmed, range: nsRange),
           let stR = Range(pm.range(at: 1), in: trimmed),
           let idR = Range(pm.range(at: 2), in: trimmed) {
            styleRaw = String(trimmed[stR]).lowercased()
            sourceIdent = String(trimmed[idR])
        } else if let sm = caseSuffixCmdRegex.firstMatch(in: trimmed, range: nsRange),
                  let stR = Range(sm.range(at: 2), in: trimmed) {
            styleRaw = String(trimmed[stR]).lowercased()
            if sm.range(at: 1).location != NSNotFound, let idR = Range(sm.range(at: 1), in: trimmed) {
                sourceIdent = String(trimmed[idR])
            } else if let clip = latestClipboardText?.trimmingCharacters(in: .whitespacesAndNewlines),
                      clip.count >= 2, clip.count <= 96 {
                sourceIdent = clip
            }
        }

        guard let style = styleRaw, let ident = sourceIdent else { return nil }
        let words = tokenizeIdentifierWords(ident)
        guard words.count >= 2 else { return nil }

        let outText: String
        let styleLabel: String
        switch style {
        case "camel", "camelcase", "驼峰", "转驼峰":
            outText = words[0] + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            styleLabel = "camelCase"
        case "pascal", "pascalcase":
            outText = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            styleLabel = "PascalCase"
        case "kebab", "kebabcase", "短横线", "转短横线":
            outText = words.joined(separator: "-")
            styleLabel = "kebab-case"
        case "const", "constant", "upper", "常量", "转常量":
            outText = words.map { $0.uppercased() }.joined(separator: "_")
            styleLabel = "UPPER_SNAKE"
        default:
            outText = words.joined(separator: "_")
            styleLabel = "snake_case"
        }

        return InstantMathResult(
            expressionDisplay: "\(ident) → \(styleLabel)",
            plainValue: outText,
            formattedThousands: outText,
            rmbUppercase: nil,
            isExplicitOrContextual: true
        )
    }
}
