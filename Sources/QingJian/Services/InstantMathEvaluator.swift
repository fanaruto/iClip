import Foundation

/// 搜索框即时四则速算结果（支持加减乘除、括号、千分位与人民币会计大写直出，零异常崩溃风险）
struct InstantMathResult: Equatable {
    let expressionDisplay: String
    let plainValue: String
    let formattedThousands: String
    let rmbUppercase: String?
}

enum InstantMathEvaluator {
    /// 安全解析搜索框中的四则运算表达式（要求以 `=` 开头，或包含至少一个二元四则运算符）
    static func evaluate(_ rawQuery: String) -> InstantMathResult? {
        var input = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= 128 else { return nil }

        let hasLeadingEquals = input.hasPrefix("=") || input.hasPrefix("＝")
        if hasLeadingEquals {
            input = String(input.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !input.isEmpty else { return nil }

        // 归一化中文全角符号与乘除号、剥离数字千分位逗号
        let normalized = input
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "X", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")

        // 仅允许合法算术字符集，排除普通路径、日期（如 2026-11-23 若无前导 = 且形如日期则不误判）或英文搜索词
        guard isLikelyMathExpression(normalized, hasLeadingEquals: hasLeadingEquals) else {
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
        if !hasLeadingEquals && !parser.didPerformBinaryOp {
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
            expressionDisplay: input,
            plainValue: plain,
            formattedThousands: thousands,
            rmbUppercase: rmb
        )
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
