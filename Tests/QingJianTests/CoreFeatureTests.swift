import XCTest
@testable import QingJian

final class CoreFeatureTests: XCTestCase {

    // MARK: - 1. 会计国标人民币大写零误差边界测试

    func testChineseUppercaseRMB_ZeroAndDecimals() {
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "0", fracDigits: nil), "零元整")
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "0", fracDigits: "00"), "零元整")
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "0", fracDigits: "05"), "伍分")
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "0", fracDigits: "5"), "伍角整")
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "0", fracDigits: "56"), "伍角陆分")
    }

    func testChineseUppercaseRMB_ComplexZeroRules() {
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "10", fracDigits: "05"), "壹拾元零伍分")
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "10", fracDigits: "50"), "壹拾元伍角整")
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "1005", fracDigits: nil), "壹仟零伍元整")
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "10200", fracDigits: nil), "壹万零贰佰元整")
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "100000", fracDigits: nil), "壹拾万元整")
        // 跨万级全零：1_0000_0005 应读作「壹亿零伍元整」，绝不能出现「万」字
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "100000005", fracDigits: nil), "壹亿零伍元整")
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "128560", fracDigits: "50"), "壹拾贰万捌仟伍佰陆拾元伍角整")
        // 经典浮点陷阱值 19.99 / 999999999999.99 零精度丢失
        XCTAssertEqual(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "19", fracDigits: "99"), "壹拾玖元玖角玖分")
        XCTAssertNotNil(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "999999999999", fracDigits: "99"))
        // 超过 12 位千亿上限安全返回 nil
        XCTAssertNil(FinanceNumberEngine.toChineseUppercaseRMB(intDigits: "1000000000000", fracDigits: "00"))
    }

    // MARK: - 2. 防误判守卫测试（手机号 / 时间戳 / 年份 / 外币）

    func testFinanceFalsePositiveGuards() {
        // 11 位中国大陆手机号绝不能误判为金额
        XCTAssertTrue(FinanceNumberEngine.analyze("13800138000").isEmpty)
        // 10 位与 13 位 Unix 时间戳绝不能误判为金额
        XCTAssertTrue(FinanceNumberEngine.analyze("1763744800").isEmpty)
        XCTAssertTrue(FinanceNumberEngine.analyze("1763744800123").isEmpty)
        // 单独年份 2026 不误判，但 ¥2026 或 2,026.50 正常识别
        XCTAssertTrue(FinanceNumberEngine.analyze("2026").isEmpty)
        XCTAssertFalse(FinanceNumberEngine.analyze("¥2026").isEmpty)
        XCTAssertFalse(FinanceNumberEngine.analyze("¥128,560.50").isEmpty)

        // 美元符号只提供纯数字提取，不错误生成「人民币元整」
        let usdActions = FinanceNumberEngine.analyze("$1,280.50")
        XCTAssertFalse(usdActions.contains(where: { $0.id == "fin-rmb-upper" }))
        XCTAssertEqual(usdActions.first(where: { $0.id == "fin-plain-num" })?.resultText, "1280.50")
    }

    // MARK: - 3. 多行报销/报价账单精确求和与防重累加测试

    func testMultilineBillExactDecimalSum() {
        let bill = """
        高铁差旅 ¥1,280.50
        酒店住宿 680
        市内打车 95.55元
        合计：99999
        """
        let actions = FinanceNumberEngine.analyze(bill)
        let sumOnly = actions.first(where: { $0.id == "bill-sum-only" })
        // 1280.50 + 680 + 95.55 = 2056.05，且自动忽略已有的「合计：99999」行
        XCTAssertEqual(sumOnly?.resultText, "2056.05")

        let withFooter = actions.first(where: { $0.id == "bill-append-total" })
        XCTAssertTrue(withFooter?.resultText.contains("贰仟零伍拾陆元零伍分") == true)

        // 代码片段绝不能误判为多行账单
        let codeSnippet = """
        let width = 420;
        let height = 560;
        """
        XCTAssertTrue(FinanceNumberEngine.analyze(codeSnippet).isEmpty)
    }

    // MARK: - 4. 跨角色持久化 Schema 向后兼容与无损往返测试

    func testClipItemCrossEditionLosslessPersistence() throws {
        let item = ClipItem(
            type: .image,
            imageFileName: "test.png",
            imageWidth: 800,
            imageHeight: 600,
            ocrText: "发票号码 12345678",
            ocrChecked: true,
            contentHash: "img:abc",
            sourceAppName: "预览",
            isPinned: true,
            pinCategory: .invoice,
            customAlias: "11月差旅电子发票"
        )
        let data = try JSONEncoder().encode([item])
        let decoded = try JSONDecoder().decode([ClipItem].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].ocrText, "发票号码 12345678")
        XCTAssertEqual(decoded[0].ocrChecked, true)
        XCTAssertEqual(decoded[0].pinCategory, .invoice)
        XCTAssertEqual(decoded[0].customAlias, "11月差旅电子发票")
        XCTAssertEqual(decoded[0].primaryTitle, "11月差旅电子发票")

        // 模拟旧版 v1.7.x 不含新字段的 history.json 无缝解码
        let legacyJSON = """
        [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","type":"text","text":"Hello","contentHash":"text:1","createdAt":0,"isPinned":false}]
        """.data(using: .utf8)!
        let legacyDecoded = try JSONDecoder().decode([ClipItem].self, from: legacyJSON)
        XCTAssertEqual(legacyDecoded.first?.text, "Hello")
        XCTAssertNil(legacyDecoded.first?.pinCategory)
    }

    // MARK: - 5. PDF 断行智能愈合与盘古中英排版边界测试

    func testPDFLineBreakHealingAndHyphenation() {
        let brokenEnglishPDF = """
        Modern transformer archi-
        tectures achieve state-of-the-
        art accuracy in real-time tasks.

        1. First key contribution
        2. Second key contribution
        """
        let healed = DocumentTypographyEngine.healPDFLineBreaks(brokenEnglishPDF)
        XCTAssertTrue(healed.contains("architectures achieve state-of-the-art accuracy in real-time tasks."))
        // 真实空行分段与列表项必须完整保留，不被粘成一坨
        XCTAssertTrue(healed.contains("\n\n1. First key contribution\n\n2. Second key contribution"))

        let brokenChinesePDF = """
        在跨语言合同与双栏学术论文阅读场景下，复制出
        来的文字经常在句中出现硬折行，严重影响大模型翻
        译与笔记摘录体验。
        """
        let healedCN = DocumentTypographyEngine.healPDFLineBreaks(brokenChinesePDF)
        XCTAssertEqual(healedCN, "在跨语言合同与双栏学术论文阅读场景下，复制出来的文字经常在句中出现硬折行，严重影响大模型翻译与笔记摘录体验。")
    }

    func testPanguSpacingProtectsURLsAndCode() {
        let messy = "使用iClip在macOS15上提升300%效率，详见https://github.com/fanaruto/iClip仓库"
        let spaced = DocumentTypographyEngine.applyPanguSpacing(messy)
        XCTAssertEqual(spaced, "使用 iClip 在 macOS15 上提升 300% 效率，详见 https://github.com/fanaruto/iClip 仓库")

        // 代码块绝不能误触发 PDF 断行或盘古排版
        let swiftCode = """
        func computeValue(x: Int) -> Int {
            let result = x * 2
            return result
        }
        """
        XCTAssertTrue(DocumentTypographyEngine.analyze(swiftCode).isEmpty)
    }

    // MARK: - 6. 二维表格协议双向无损转换与防代码缩进误判测试

    func testMarkdownAndExcelTSVTableBridge() {
        let mdTable = """
        | **商品名称** | 单价 | 库存 |
        | :--- | ---: | :---: |
        | iClip Pro | 0.00 | 999 |
        | 液态贴膜,高清 | 39.90 | 50 |
        """
        let mdActions = TableBridgeEngine.analyze(mdTable)
        let excelTSV = mdActions.first(where: { $0.id == "tbl-md-to-excel" })?.resultText
        XCTAssertEqual(excelTSV, "商品名称\t单价\t库存\niClip Pro\t0.00\t999\n液态贴膜,高清\t39.90\t50")

        // CSV 对包含逗号的单元格必须自动加双引号保护
        let csv = mdActions.first(where: { $0.id == "tbl-md-to-csv" })?.resultText
        XCTAssertTrue(csv?.contains("\"液态贴膜,高清\",39.90,50") == true)

        // HTML Table 双协议校验
        let html = TableBridgeEngine.toHTMLTable(fromTSV: excelTSV ?? "")
        XCTAssertTrue(html?.contains("<th>商品名称</th>") == true)
        XCTAssertTrue(html?.contains("<td>999</td>") == true)

        // Excel TSV 逆向转 Markdown 与 JSON 对象数组
        let tsvInput = "姓名\t部门\t职级\n张三\t研发\tP7\n李四\t电商运营\tP6"
        let tsvActions = TableBridgeEngine.analyze(tsvInput)
        let backToMD = tsvActions.first(where: { $0.id == "tbl-tsv-to-md" })?.resultText
        XCTAssertTrue(backToMD?.contains("| 姓名 | 部门 | 职级 |") == true)
        let toJSON = tsvActions.first(where: { $0.id == "tbl-tsv-to-json" })?.resultText
        XCTAssertTrue(toJSON?.contains("\"部门\" : \"电商运营\"") == true)

        // Tab 缩进的代码块严禁误判为 Excel TSV 表格
        let tabIndentedCode = "\tlet a = 1\n\tlet b = 2"
        XCTAssertTrue(TableBridgeEngine.analyze(tabIndentedCode).isEmpty)
    }

    // MARK: - 7. 图像工坊透明通道防黑底瘦身与圆角样机渲染测试

    func testImageStudioCompressionAndMockupRendering() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-studio-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 生成一张 400x300 全透明背景 + 中心蓝色块测试 PNG
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: 400,
            height: 300,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Failed to create test CGContext")
            return
        }
        ctx.clear(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1.0))
        ctx.fill(CGRect(x: 100, y: 80, width: 200, height: 140))

        guard let cgImg = ctx.makeImage() else {
            XCTFail("Failed to make test CGImage")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImg)
        let pngData = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try pngData.write(to: tempURL)

        // 1. 验证 JPEG 瘦身成功且左上角原透明区域被垫为纯白（RGB > 245，绝不变纯黑）
        let jpegRes = try XCTUnwrap(ImageStudioEngine.compressToLightweightJPEG(at: tempURL))
        XCTAssertGreaterThan(jpegRes.byteCount, 100)
        let decodedJPEG = try XCTUnwrap(NSBitmapImageRep(data: jpegRes.data))
        XCTAssertEqual(decodedJPEG.pixelsWide, 400)
        XCTAssertEqual(decodedJPEG.pixelsHigh, 300)
        let cornerColor = try XCTUnwrap(decodedJPEG.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(cornerColor.redComponent, 0.95)
        XCTAssertGreaterThan(cornerColor.greenComponent, 0.95)
        XCTAssertGreaterThan(cornerColor.blueComponent, 0.95)

        // 2. 验证圆角阴影样机加壳输出尺寸精确加上了四周留白（400 + 40*2 = 480, 300 + 40*2 = 380）
        let mockupRes = try XCTUnwrap(ImageStudioEngine.renderAppleMockupFrame(at: tempURL))
        let decodedMockup = try XCTUnwrap(NSBitmapImageRep(data: mockupRes.data))
        XCTAssertEqual(decodedMockup.pixelsWide, 480)
        XCTAssertEqual(decodedMockup.pixelsHigh, 380)
    }

    // MARK: - 5. 语义脱敏、净链与动态模板回归测试

    #if !ICLIP_EDITION_FLOW
    func testSemanticRedactionAndTemplateInterpolation() {
        let envText = "OPENAI_API_KEY=sk-proj-1234567890abcdefghijklmnop\nDB_PASSWORD=\"superSecret999\""
        let redacted = SemanticEngine.redactSecrets(in: envText)
        XCTAssertFalse(redacted.contains("1234567890abcdefghijklmnop"))
        XCTAssertFalse(redacted.contains("superSecret999"))
        XCTAssertTrue(redacted.contains("DB_PASSWORD=\"***REDACTED***\""))

        let dirty = "https://webfooo.com/article?id=42&utm_source=twitter&spm=a2c.11"
        XCTAssertEqual(SemanticEngine.cleanTrackingURL(dirty), "https://webfooo.com/article?id=42")

        let tpl = "请审查：\n{{clip_redacted}}"
        let rendered = SnippetTemplateEngine.render(template: tpl, latestContextText: "token: sk-1234567890abcdefghij1234")
        XCTAssertTrue(rendered.contains("sk-***REDACTED***"))
    }
    #endif
}
