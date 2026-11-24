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

        // 优先检测离线全能单位换算（存储 B/KB/MB/GB/TB、时长 ms/s/min/h/d、温度 C/F、重量长度 kg/lb、cm/in、km/mi）
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
}
