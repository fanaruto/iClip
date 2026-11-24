import Foundation

/// 电商运营、数据分析、HR 行政专属：表格协议破壁器（Markdown 表格 ↔ Excel TSV/HTML Table ↔ CSV / JSON 数组）
enum TableBridgeEngine {

    private static let mdSeparatorRegex = try! NSRegularExpression(
        pattern: #"^\s*\|?(?:\s*:?-{2,}:?\s*\|)+\s*:?-{2,}:?\s*\|?\s*$"#
    )

    // MARK: - 主分析入口

    static func analyze(_ rawText: String) -> [FinanceQuickAction] {
        guard rawText.utf16.count <= 65_536,
              rawText.contains("\n"),
              (rawText.contains("|") || rawText.contains("\t")) else { return [] }

        // 1. Markdown 表格 -> Excel 直粘 (TSV + HTML Table) / CSV
        if let grid = parseMarkdownTable(rawText) {
            let tsv = toTSV(grid)
            let csv = toCSV(grid)
            return [
                FinanceQuickAction(
                    id: "tbl-md-to-excel",
                    title: "转 Excel 分列直粘",
                    symbolName: "tablecells.fill",
                    resultText: tsv,
                    toastText: "已转为 Excel/飞书表格分列格式（\(grid.count) 行）"
                ),
                FinanceQuickAction(
                    id: "tbl-md-to-csv",
                    title: "转 CSV",
                    symbolName: "doc.plaintext",
                    resultText: csv,
                    toastText: "已转为标准 CSV 表格"
                )
            ]
        }

        // 2. Excel / 飞书复制出的 TSV 制表符表格 -> Markdown 表格 / JSON 对象数组
        if let grid = parseTSVTable(rawText) {
            let md = toMarkdownTable(grid)
            var actions = [
                FinanceQuickAction(
                    id: "tbl-tsv-to-md",
                    title: "转 Markdown 表格",
                    symbolName: "tablecells",
                    resultText: md,
                    toastText: "已转为标准 Markdown 表格"
                )
            ]
            if let json = toJSONObjects(grid) {
                actions.append(FinanceQuickAction(
                    id: "tbl-tsv-to-json",
                    title: "转 JSON 数组",
                    symbolName: "curlybraces.square",
                    resultText: json,
                    toastText: "已按表头转为 JSON 对象数组"
                ))
            }
            return actions
        }

        return []
    }

    // MARK: - Markdown Table 解析

    static func parseMarkdownTable(_ rawText: String) -> [[String]]? {
        let rawLines = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        // 自动在混排段落（如带前置说明与结尾建议的 AI 回复）中扫描首个合法的 Markdown 表格连续块（跳过 ``` 代码围栏内部）
        var cleanTableLines: [String] = []
        var inFence = false
        var idx = 0
        while idx < rawLines.count {
            let trimmed = rawLines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                idx += 1
                continue
            }
            if !inFence && trimmed.contains("|") && idx + 1 < rawLines.count {
                let nextTrimmed = rawLines[idx + 1].trimmingCharacters(in: .whitespaces)
                let sepRange = NSRange(nextTrimmed.startIndex..<nextTrimmed.endIndex, in: nextTrimmed)
                if mdSeparatorRegex.firstMatch(in: nextTrimmed, options: [], range: sepRange) != nil {
                    cleanTableLines.append(trimmed)
                    var cursor = idx + 2
                    while cursor < rawLines.count {
                        let rowTrimmed = rawLines[cursor].trimmingCharacters(in: .whitespaces)
                        if rowTrimmed.isEmpty || !rowTrimmed.contains("|") || rowTrimmed.hasPrefix("```") {
                            break
                        }
                        let rowSepR = NSRange(rowTrimmed.startIndex..<rowTrimmed.endIndex, in: rowTrimmed)
                        if mdSeparatorRegex.firstMatch(in: rowTrimmed, options: [], range: rowSepR) == nil {
                            cleanTableLines.append(rowTrimmed)
                        }
                        cursor += 1
                    }
                    if cleanTableLines.count >= 2 {
                        break
                    }
                    cleanTableLines.removeAll()
                }
            }
            idx += 1
        }

        guard cleanTableLines.count >= 2 else { return nil }
        let rows = cleanTableLines.map { splitMarkdownRow($0) }.filter { !$0.isEmpty }
        guard rows.count >= 2, let colCount = rows.first?.count, colCount >= 2 else { return nil }
        // 对齐各行列数
        return rows.map { row in
            if row.count == colCount { return row }
            if row.count > colCount { return Array(row.prefix(colCount)) }
            return row + Array(repeating: "", count: colCount - row.count)
        }
    }

    private static func splitMarkdownRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix(#"\|"#) { trimmed.removeLast() }

        // 支持转义竖线 \|
        let placeholder = "\u{001F}"
        let safe = trimmed.replacingOccurrences(of: #"\|"#, with: placeholder)
        return safe.components(separatedBy: "|").map { cell in
            var c = cell.replacingOccurrences(of: placeholder, with: "|")
                .trimmingCharacters(in: .whitespaces)
            // 剥离常见外层加粗 **xx** 与行内代码 `xx` 以便贴入 Excel 更干净
            if c.hasPrefix("**") && c.hasSuffix("**") && c.count > 4 {
                c = String(c.dropFirst(2).dropLast(2))
            } else if c.hasPrefix("`") && c.hasSuffix("`") && c.count > 2 {
                c = String(c.dropFirst().dropLast())
            }
            return c
        }
    }

    // MARK: - TSV (Excel 复制区域) 解析与防代码缩进守卫

    static func parseTSVTable(_ rawText: String) -> [[String]]? {
        guard rawText.contains("\t") else { return nil }
        let rawLines = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard rawLines.count >= 2 else { return nil }

        // 防误判守卫：如果存在以 Tab 缩进开头的代码行，或包含典型代码花括号分号，立即排除
        for line in rawLines {
            if line.hasPrefix("\t") || line.contains("{") || line.contains("}") || line.hasSuffix(";") {
                return nil
            }
        }

        let rows = rawLines.map { line in
            line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        guard let expectedCols = rows.first?.count, expectedCols >= 2 else { return nil }
        // 每一行都必须至少包含相同列数（允许末尾空单元格差 1 列以内）
        let consistent = rows.allSatisfy { abs($0.count - expectedCols) <= 1 && $0.count >= 2 }
        guard consistent else { return nil }

        return rows.map { row in
            if row.count == expectedCols { return row }
            if row.count > expectedCols { return Array(row.prefix(expectedCols)) }
            return row + Array(repeating: "", count: expectedCols - row.count)
        }
    }

    // MARK: - 多格式输出生成器（TSV / HTML Table / CSV / Markdown / JSON）

    /// 防御 OWASP CWE-1236 电子表格公式与 DDE 命令注入（如 `=CMD|...`、`+HYPERLINK(...)`、`@SUM(...)`），
    /// 同时精准豁免合法负数、金额百分比与国际电话号码（如 `-128.50`、`-3.14%`、`+86-13800138000`），不破坏 Excel 数值求和
    static func sanitizeSpreadsheetCell(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        if raw.hasPrefix("'") { return raw }
        let trimmedLead = raw.drop(while: { $0 == " " })
        guard let first = trimmedLead.first else { return raw }
        if first == "=" || first == "@" || first == "|" || first == "\t" || first == "\r" || first == "\n" {
            return "'" + raw
        }
        if first == "+" || first == "-" {
            let rest = trimmedLead.dropFirst()
            let hasDigit = rest.contains(where: { $0 >= "0" && $0 <= "9" })
            let isSafeNumericOrPhone = hasDigit && rest.allSatisfy { ch in
                (ch >= "0" && ch <= "9") || ch == "." || ch == "," || ch == "%" || ch == " " || ch == "-"
            }
            if !isSafeNumericOrPhone {
                return "'" + raw
            }
        }
        return raw
    }

    static func toTSV(_ grid: [[String]]) -> String {
        grid.map { row in
            row.map { cell in
                let flat = cell.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                return sanitizeSpreadsheetCell(flat)
            }
            .joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// 生成标准 HTML `<table>` 供 Excel / Numbers / 飞书文档粘贴时精准识别二维单元格边界
    static func toHTMLTable(fromTSV tsv: String) -> String? {
        let rows = tsv.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        guard rows.count >= 2 else { return nil }
        var html = "<table><thead><tr>"
        for cell in rows[0] {
            html += "<th>\(escapeHTML(sanitizeSpreadsheetCell(cell)))</th>"
        }
        html += "</tr></thead><tbody>"
        for row in rows.dropFirst() {
            html += "<tr>"
            for cell in row {
                html += "<td>\(escapeHTML(sanitizeSpreadsheetCell(cell)))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    static func toCSV(_ grid: [[String]]) -> String {
        grid.map { row in
            row.map { rawCell -> String in
                let cell = sanitizeSpreadsheetCell(rawCell)
                if cell.contains(",") || cell.contains("\"") || cell.contains("\n") {
                    let escaped = cell.replacingOccurrences(of: "\"", with: "\"\"")
                    return "\"\(escaped)\""
                }
                return cell
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    static func toMarkdownTable(_ grid: [[String]]) -> String {
        guard let header = grid.first, !header.isEmpty else { return "" }
        let escapeCell: (String) -> String = { cell in
            cell.replacingOccurrences(of: "|", with: #"\|"#).replacingOccurrences(of: "\n", with: " ")
        }

        var lines: [String] = []
        lines.append("| " + header.map(escapeCell).joined(separator: " | ") + " |")
        lines.append("| " + header.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in grid.dropFirst() {
            lines.append("| " + row.map(escapeCell).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    static func toJSONObjects(_ grid: [[String]]) -> String? {
        guard grid.count >= 2, let headers = grid.first else { return nil }
        let keys = headers.enumerated().map { idx, h in h.isEmpty ? "col_\(idx + 1)" : h }
        var objects: [[String: String]] = []
        for row in grid.dropFirst() {
            var dict: [String: String] = [:]
            for (i, key) in keys.enumerated() where i < row.count {
                dict[key] = row[i]
            }
            objects.append(dict)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
