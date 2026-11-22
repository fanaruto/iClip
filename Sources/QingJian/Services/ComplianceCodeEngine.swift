import Foundation

/// 财务出纳、法务合规、HR 行政、私域客服专属：
/// 离线国标校验（GB 11643 身份证 / GB 32100 统一社会信用代码 / Luhn 银行卡）与分节阅读、合规掩码引擎
enum ComplianceCodeEngine {

    private static let validProvincePrefixes: Set<String> = [
        "11", "12", "13", "14", "15",
        "21", "22", "23",
        "31", "32", "33", "34", "35", "36", "37",
        "41", "42", "43", "44", "45", "46",
        "50", "51", "52", "53", "54",
        "61", "62", "63", "64", "65",
        "71", "81", "82", "83"
    ]

    private static let idWeights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    private static let idCheckMap: [Character] = ["1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2"]

    private static let usccAlphabet = Array("0123456789ABCDEFGHJKLMNPQRTUWXY")
    private static let usccCharToValue: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (idx, ch) in usccAlphabet.enumerated() {
            map[ch] = idx
        }
        return map
    }()
    private static let usccWeights = [1, 3, 9, 27, 19, 26, 16, 17, 20, 29, 25, 13, 8, 24, 10, 30, 28]

    private static let birthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        f.isLenient = false
        return f
    }()

    // MARK: - 主分析入口

    static func analyze(_ rawText: String) -> [FinanceQuickAction] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 15 && trimmed.count <= 32, !trimmed.contains("\n") else { return [] }

        let compact = trimmed
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()

        // 1. 18 位中国公民身份号码检测（GB 11643-1999）
        if let idActions = analyzeChineseIDCard(compact: compact, original: trimmed) {
            return idActions
        }

        // 2. 18 位统一社会信用代码 / 企业税号检测（GB 32100-2015）
        if let usccActions = analyzeUSCC(compact: compact, original: trimmed) {
            return usccActions
        }

        // 3. 16 ~ 19 位银行卡号 Luhn 校验与四位分节（ISO/IEC 7812）
        if let cardActions = analyzeBankCard(compact: compact, original: trimmed) {
            return cardActions
        }

        return []
    }

    // MARK: - 1. GB 11643-1999 身份证校验与分节/掩码

    static func expectedIDCardChecksum(first17: String) -> Character? {
        guard first17.count == 17, first17.allSatisfy(\.isNumber) else { return nil }
        let prefix2 = String(first17.prefix(2))
        guard validProvincePrefixes.contains(prefix2) else { return nil }

        let birthSlice = String(first17.dropFirst(6).prefix(8))
        guard let birthDate = birthFormatter.date(from: birthSlice),
              birthDate <= Date() else {
            return nil
        }

        let digits = first17.compactMap { Int(String($0)) }
        var sum = 0
        for i in 0..<17 {
            sum += digits[i] * idWeights[i]
        }
        return idCheckMap[sum % 11]
    }

    private static func analyzeChineseIDCard(compact: String, original: String) -> [FinanceQuickAction]? {
        guard compact.count == 18 else { return nil }
        let first17 = String(compact.prefix(17))
        let lastChar = compact.last!
        guard lastChar.isNumber || lastChar == "X",
              let expected = expectedIDCardChecksum(first17: first17) else {
            return nil
        }

        if lastChar != expected {
            let corrected = first17 + String(expected)
            return [
                FinanceQuickAction(
                    id: "comp-id-invalid",
                    title: "⚠️ 末位应为 \(expected)（点击修正）",
                    symbolName: "exclamationmark.triangle.fill",
                    resultText: corrected,
                    toastText: "已按国标校验位修正末位为 \(expected)"
                )
            ]
        }

        // 6-8-4 分节：110101 19900307 123X
        let p1 = compact.prefix(6)
        let p2 = compact.dropFirst(6).prefix(8)
        let p3 = compact.suffix(4)
        let grouped = "\(p1) \(p2) \(p3)"
        let masked = "\(compact.prefix(4))**********\(compact.suffix(4))"

        var actions: [FinanceQuickAction] = []
        if original != compact {
            actions.append(FinanceQuickAction(
                id: "comp-id-plain",
                title: "✓ 证件有效 · 纯号码",
                symbolName: "checkmark.seal.fill",
                resultText: compact,
                toastText: "身份证校验通过，已去空格键入"
            ))
        } else {
            actions.append(FinanceQuickAction(
                id: "comp-id-group",
                title: "✓ 有效 · 6-8-4 分节",
                symbolName: "checkmark.seal.fill",
                resultText: grouped,
                toastText: "身份证校验通过，已按 6-8-4 分节"
            ))
        }
        actions.append(FinanceQuickAction(
            id: "comp-id-mask",
            title: "合规掩码",
            symbolName: "eye.slash",
            resultText: masked,
            toastText: "已掩码出生年月保留首尾四位"
        ))
        return actions
    }

    // MARK: - 2. GB 32100-2015 统一社会信用代码（18 位企业税号）校验

    static func expectedUSCCChecksum(first17: String) -> Character? {
        guard first17.count == 17 else { return nil }
        // 第 1 位登记管理部门代码（1 机构编制 / 5 民政 / 9 市场监管 / Y 其他），第 3~4 位为合法省级行政区划代码（兼容三证合一纯数字老企业税号与含字母新税号）
        let province2 = String(first17.dropFirst(2).prefix(2))
        guard let first = first17.first, ["1", "5", "9", "Y"].contains(first),
              validProvincePrefixes.contains(province2) else {
            return nil
        }

        var sum = 0
        for (i, ch) in first17.enumerated() {
            guard let val = usccCharToValue[ch] else { return nil }
            sum += val * usccWeights[i]
        }
        let remainder = (31 - (sum % 31)) % 31
        return usccAlphabet[remainder]
    }

    private static func analyzeUSCC(compact: String, original: String) -> [FinanceQuickAction]? {
        guard compact.count == 18 else { return nil }
        // 财务常见手误：把数字 0 敲成字母 O，把 1 敲成 I
        let normalized = compact.replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1")
        let first17 = String(normalized.prefix(17))
        guard let expected = expectedUSCCChecksum(first17: first17) else {
            return nil
        }
        let actualLast = normalized.last!

        if actualLast != expected || compact != normalized {
            let corrected = first17 + String(expected)
            return [
                FinanceQuickAction(
                    id: "comp-uscc-fix",
                    title: "⚠️ 税号有误（修正为 \(expected)）",
                    symbolName: "exclamationmark.triangle.fill",
                    resultText: corrected,
                    toastText: "已按 GB32100 国标修正税号校验位"
                )
            ]
        }

        // 6-10-2 或 4-4-4-6 分节阅读：9144 0300 MA5D XXXX XX
        let grouped = groupEveryFour(compact)
        var actions: [FinanceQuickAction] = []
        if original != compact {
            actions.append(FinanceQuickAction(
                id: "comp-uscc-plain",
                title: "✓ 税号有效 · 纯文本",
                symbolName: "checkmark.seal.fill",
                resultText: compact,
                toastText: "企业税号校验通过，已去空格键入"
            ))
        } else {
            actions.append(FinanceQuickAction(
                id: "comp-uscc-group",
                title: "✓ 税号有效 · 分节核对",
                symbolName: "checkmark.seal.fill",
                resultText: grouped,
                toastText: "企业税号校验通过，已分节便于核对"
            ))
        }
        return actions
    }

    // MARK: - 3. ISO/IEC 7812 银行卡 Luhn 校验与四位分节

    static func passesLuhnCheck(_ digitsStr: String) -> Bool {
        guard (16...19).contains(digitsStr.count), digitsStr.allSatisfy(\.isNumber) else { return false }
        let digits = digitsStr.compactMap { Int(String($0)) }
        guard Set(digits).count > 1 else { return false } // 排除全 0000...

        var sum = 0
        let reversed = digits.reversed()
        for (idx, d) in reversed.enumerated() {
            if idx % 2 == 1 {
                let doubled = d * 2
                sum += (doubled > 9) ? (doubled - 9) : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    private static func analyzeBankCard(compact: String, original: String) -> [FinanceQuickAction]? {
        guard (16...19).contains(compact.count),
              compact.allSatisfy(\.isNumber),
              let first = compact.first,
              ["3", "4", "5", "6"].contains(first),
              passesLuhnCheck(compact) else {
            return nil
        }

        let grouped = groupEveryFour(compact)
        let masked = "\(compact.prefix(4)) **** **** \(compact.suffix(4))"

        var actions: [FinanceQuickAction] = []
        if original != compact {
            actions.append(FinanceQuickAction(
                id: "comp-card-plain",
                title: "去空格纯卡号",
                symbolName: "creditcard.fill",
                resultText: compact,
                toastText: "银行卡 Luhn 校验通过，已转为连续纯数字"
            ))
        }
        if original != grouped {
            actions.append(FinanceQuickAction(
                id: "comp-card-group",
                title: "四位分节核对",
                symbolName: "creditcard",
                resultText: grouped,
                toastText: "已按每 4 位分节便于出纳核对"
            ))
        }
        actions.append(FinanceQuickAction(
            id: "comp-card-mask",
            title: "首尾四位掩码",
            symbolName: "eye.slash",
            resultText: masked,
            toastText: "已生成合规掩码卡号"
        ))
        return Array(actions.prefix(3))
    }

    private static func groupEveryFour(_ s: String) -> String {
        var chunks: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 4, limitedBy: s.endIndex) ?? s.endIndex
            chunks.append(String(s[idx..<next]))
            idx = next
        }
        return chunks.joined(separator: " ")
    }
}
