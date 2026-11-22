import Foundation

/// 财务与商务数值转换动作（双角色通用，极简模式下自动静默隐藏）
struct FinanceQuickAction: Identifiable, Equatable {
    let id: String
    let title: String
    let symbolName: String
    let resultText: String
    let toastText: String
}

/// 零浮点误差的财务票据大写人民币、千分位格式化与多行明细账单自动求和引擎
enum FinanceNumberEngine {
    private static let cnDigits = ["零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖"]
    private static let sectionUnits = ["", "拾", "佰", "仟"]
    private static let groupUnits = ["", "万", "亿", "兆"]

    /// 最大支持的整数位数（12 位：千亿级 999,999,999,999.99，严格防范溢出与离谱订单号误判）
    private static let maxIntegerDigits = 12

    private static let singleAmountRegex = try! NSRegularExpression(
        pattern: #"^\s*([¥￥$€£]?)\s*([0-9][0-9,]*)(?:\.([0-9]{1,2}))?\s*(元|圆|RMB|CNY)?\s*$"#,
        options: [.caseInsensitive]
    )

    private static let lineTrailingAmountRegex = try! NSRegularExpression(
        pattern: #"(?:[¥￥$]\s*)?(-?\d{1,3}(?:,\d{3})+|-?\d+)(?:\.(\d{1,2}))?\s*(?:元|圆|块)?\s*$"#
    )

    // MARK: - 主分析入口

    static func analyze(_ rawText: String) -> [FinanceQuickAction] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 16_384 else { return [] }

        // 1. 单行金额识别（中文财务大写 + 千分位 + 去符号纯数字）
        if !trimmed.contains("\n"), let singleActions = analyzeSingleAmount(trimmed), !singleActions.isEmpty {
            return singleActions
        }

        // 2. 多行报销/报价明细账单自动求和
        if trimmed.contains("\n"), let sumActions = analyzeMultilineBill(rawText), !sumActions.isEmpty {
            return sumActions
        }

        return []
    }

    // MARK: - 单笔金额解析与防误判守卫

    private static func analyzeSingleAmount(_ input: String) -> [FinanceQuickAction]? {
        let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = singleAmountRegex.firstMatch(in: input, options: [], range: nsRange),
              let intRange = Range(match.range(at: 2), in: input) else {
            return nil
        }

        let currencyPrefix = match.range(at: 1).location != NSNotFound
            ? String(input[Range(match.range(at: 1), in: input)!])
            : ""
        let rawIntPart = String(input[intRange])
        let hasComma = rawIntPart.contains(",")
        let cleanIntDigits = rawIntPart.replacingOccurrences(of: ",", with: "")

        // 若含逗号，必须符合合法千分位分组格式（如 12,345,678），拒绝 "1,2,3" 这类列表
        if hasComma {
            guard rawIntPart.range(of: #"^\d{1,3}(?:,\d{3})+$"#, options: .regularExpression) != nil else {
                return nil
            }
        }

        let fracDigits: String? = {
            guard match.range(at: 3).location != NSNotFound,
                  let r = Range(match.range(at: 3), in: input) else { return nil }
            return String(input[r])
        }()

        let unitSuffix = match.range(at: 4).location != NSNotFound
            ? String(input[Range(match.range(at: 4), in: input)!])
            : ""

        let hasExplicitMoneyHint = !currencyPrefix.isEmpty || !unitSuffix.isEmpty || hasComma || fracDigits != nil

        // 去除前导零（保留单个 "0"）
        let normalizedInt = cleanIntDigits.drop(while: { $0 == "0" })
        let intStr = normalizedInt.isEmpty ? "0" : String(normalizedInt)

        // 严苛防误判守卫：排除手机号、Unix 时间戳、年份、长单号与普通单个小整数
        if !hasExplicitMoneyHint {
            // 无小数点、无货币符号的纯整数：
            // - 排除 < 100 的普通序号
            // - 排除 1900~2099 年份
            // - 排除 ≥ 10 位的手机号 (11位)、秒级时间戳 (10位)、毫秒时间戳 (13位)、身份证/卡号
            if cleanIntDigits.hasPrefix("0") && cleanIntDigits.count > 1 { return nil }
            guard intStr.count >= 3 && intStr.count <= 9, let intVal = Int(intStr) else { return nil }
            if (1900...2099).contains(intVal) { return nil }
        } else {
            guard intStr.count <= maxIntegerDigits else { return nil }
        }

        // 人民币大写仅针对人民币或无特定外币符号的金额（若明确写了 $ / € / £ 则不转人民币「元整」，只转纯数字/千分位）
        let isForeignCurrency = (currencyPrefix == "$" || currencyPrefix == "€" || currencyPrefix == "£")

        var actions: [FinanceQuickAction] = []
        let plainNumber = formatPlainDecimal(intPart: intStr, fracPart: fracDigits)
        let groupedNumber = formatThousands(intPart: intStr, fracPart: fracDigits)

        if !isForeignCurrency, let rmbUpper = toChineseUppercaseRMB(intDigits: intStr, fracDigits: fracDigits) {
            actions.append(FinanceQuickAction(
                id: "fin-rmb-upper",
                title: rmbUpper.count > 14 ? "大写：\(rmbUpper.prefix(12))…" : rmbUpper,
                symbolName: "yensign.circle.fill",
                resultText: rmbUpper,
                toastText: "已转换财务大写：\(rmbUpper)"
            ))
        }

        if hasComma || !currencyPrefix.isEmpty || !unitSuffix.isEmpty {
            actions.append(FinanceQuickAction(
                id: "fin-plain-num",
                title: "纯数字 \(plainNumber)",
                symbolName: "number",
                resultText: plainNumber,
                toastText: "已提取纯数字 \(plainNumber)"
            ))
        }

        if !hasComma && intStr.count >= 4 {
            actions.append(FinanceQuickAction(
                id: "fin-thousands",
                title: "千分位 \(groupedNumber)",
                symbolName: "textformat.123",
                resultText: groupedNumber,
                toastText: "已格式化千分位 \(groupedNumber)"
            ))
        }

        return Array(actions.prefix(3))
    }

    // MARK: - 会计级零浮点误差人民币大写算法

    /// 将纯数字整数串与最多两位小数串精确转换为会计标准人民币大写
    static func toChineseUppercaseRMB(intDigits: String, fracDigits: String?) -> String? {
        let cleanInt = intDigits.trimmingCharacters(in: .whitespaces)
        guard !cleanInt.isEmpty, cleanInt.allSatisfy(\.isNumber) else { return nil }

        let strippedInt = String(cleanInt.drop(while: { $0 == "0" }))
        let normInt = strippedInt.isEmpty ? "0" : strippedInt
        guard normInt.count <= maxIntegerDigits else { return nil }

        let paddedFrac: String = {
            guard let f = fracDigits, !f.isEmpty else { return "00" }
            if f.count == 1 { return f + "0" }
            return String(f.prefix(2))
        }()
        guard paddedFrac.count == 2, paddedFrac.allSatisfy(\.isNumber) else { return nil }

        let jiao = Int(String(paddedFrac.first!)) ?? 0
        let fen = Int(String(paddedFrac.last!)) ?? 0

        if normInt == "0" && jiao == 0 && fen == 0 {
            return "零元整"
        }

        var result = ""

        // 1. 整数部分按 4 位一组（个、万、亿）切分转换
        if normInt != "0" {
            let digits = normInt.compactMap { Int(String($0)) }
            let totalLen = digits.count
            let groupCount = (totalLen + 3) / 4

            var needZeroAcrossGroup = false

            for g in 0..<groupCount {
                let startIdx = max(0, totalLen - (groupCount - g) * 4)
                let endIdx = totalLen - (groupCount - g - 1) * 4
                let slice = Array(digits[startIdx..<endIdx])
                let groupValue = slice.reduce(0) { $0 * 10 + $1 }
                let groupUnit = groupUnits[groupCount - 1 - g]

                if groupValue == 0 {
                    // 整组为 0（例如 1,0000,0005 中的万组），标记跨组补零但不加「万」字
                    if !result.isEmpty {
                        needZeroAcrossGroup = true
                    }
                    continue
                }

                // 若上一非空组与当前组之间跨了全零组，或当前组千位为 0（如 1,0200 -> 壹万零贰佰），补一个「零」
                if !result.isEmpty && (needZeroAcrossGroup || slice.count < 4 || slice[0] == 0) {
                    if !result.hasSuffix("零") {
                        result += "零"
                    }
                }
                needZeroAcrossGroup = false

                var zeroPendingInSection = false
                let sliceLen = slice.count
                for (i, d) in slice.enumerated() {
                    let posInSection = sliceLen - 1 - i
                    if d == 0 {
                        zeroPendingInSection = true
                    } else {
                        if zeroPendingInSection && !result.hasSuffix("零") {
                            result += "零"
                        }
                        zeroPendingInSection = false
                        result += cnDigits[d] + sectionUnits[posInSection]
                    }
                }

                result += groupUnit
            }

            result += "元"
        }

        // 2. 小数角分部分
        if jiao == 0 && fen == 0 {
            result += "整"
        } else if jiao > 0 && fen == 0 {
            result += "\(cnDigits[jiao])角整"
        } else if jiao == 0 && fen > 0 {
            // 整数大于 0 时（如 10.05）读作「壹拾元零伍分」；整数为 0 时（如 0.05）直接读「伍分」
            if normInt != "0" {
                result += "零\(cnDigits[fen])分"
            } else {
                result += "\(cnDigits[fen])分"
            }
        } else {
            result += "\(cnDigits[jiao])角\(cnDigits[fen])分"
        }

        return result
    }

    // MARK: - 多行账单明细精确十进制求和

    static func analyzeMultilineBill(_ rawText: String) -> [FinanceQuickAction]? {
        let lines = rawText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 && lines.count <= 200 else { return nil }

        var matchedCount = 0
        var total = Decimal.zero

        for line in lines {
            // 跳过已有的“合计/总计”行避免重复累加
            if line.hasPrefix("合计") || line.hasPrefix("总计") || line.lowercased().hasPrefix("total") {
                continue
            }
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = lineTrailingAmountRegex.firstMatch(in: line, options: [], range: nsRange),
                  let intR = Range(match.range(at: 1), in: line) else {
                continue
            }
            // 要求行内除了数字外带有条目名称（或全部都是纯金额列），排除代码行
            if line.contains("{") || line.contains("}") || line.contains(";") || line.hasPrefix("http") {
                return nil
            }

            let rawInt = String(line[intR]).replacingOccurrences(of: ",", with: "")
            // 排除行尾是 11 位手机号或超长单号的情况
            let absDigits = rawInt.hasPrefix("-") ? String(rawInt.dropFirst()) : rawInt
            if absDigits.count > 9 { continue }

            var numStr = rawInt
            if match.range(at: 2).location != NSNotFound, let fracR = Range(match.range(at: 2), in: line) {
                numStr += "." + String(line[fracR])
            }

            if let dec = Decimal(string: numStr) {
                total += dec
                matchedCount += 1
            }
        }

        // 至少匹配到 2 行金额，且占有效非空行的 60% 以上
        guard matchedCount >= 2, Double(matchedCount) / Double(lines.count) >= 0.6 else {
            return nil
        }

        let sumFormatted = formatDecimalWithThousands(total)
        let sumPlain = formatDecimalPlain(total)

        var actions: [FinanceQuickAction] = [
            FinanceQuickAction(
                id: "bill-sum-only",
                title: "∑ 求和 \(sumFormatted)",
                symbolName: "sum",
                resultText: sumPlain,
                toastText: "已计算 \(matchedCount) 项合计：\(sumFormatted)"
            )
        ]

        // 构造「原明细 + 合计行（附中文大写）」一键完整账单文本
        var summaryLine = "合计：\(sumFormatted)"
        if total >= 0, let rmb = decimalToRMB(total) {
            summaryLine += "（\(rmb)）"
        }
        let trimmedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        actions.append(FinanceQuickAction(
            id: "bill-append-total",
            title: "附合计行粘贴",
            symbolName: "doc.append",
            resultText: "\(trimmedRaw)\n\(summaryLine)",
            toastText: "已追加合计与大写金额并键入"
        ))

        return actions
    }

    // MARK: - 格式化辅助

    private static func formatPlainDecimal(intPart: String, fracPart: String?) -> String {
        guard let fracPart, !fracPart.isEmpty else { return intPart }
        return "\(intPart).\(fracPart)"
    }

    private static func formatThousands(intPart: String, fracPart: String?) -> String {
        var chars: [Character] = []
        let rev = Array(intPart.reversed())
        for (idx, ch) in rev.enumerated() {
            if idx > 0 && idx % 3 == 0 {
                chars.append(",")
            }
            chars.append(ch)
        }
        let grouped = String(chars.reversed())
        guard let fracPart, !fracPart.isEmpty else { return grouped }
        return "\(grouped).\(fracPart)"
    }

    private static func formatDecimalPlain(_ dec: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: dec as NSDecimalNumber) ?? "\(dec)"
    }

    private static func formatDecimalWithThousands(_ dec: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: dec as NSDecimalNumber) ?? "\(dec)"
    }

    private static func decimalToRMB(_ dec: Decimal) -> String? {
        let plain = formatDecimalPlain(dec)
        guard !plain.hasPrefix("-") else { return nil }
        let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
        let iPart = String(parts[0])
        let fPart = parts.count > 1 ? String(parts[1]) : nil
        return toChineseUppercaseRMB(intDigits: iPart, fracDigits: fPart)
    }
}
