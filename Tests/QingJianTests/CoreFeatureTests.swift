import XCTest
import CoreImage
import Carbon
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

    // MARK: - 8. 法务与出纳离线国标校验（身份证 GB11643 / 企业税号 GB32100 / 银行卡 Luhn）测试

    func testComplianceCodeVerificationAndFormatting() {
        // 1. 构造合法的 18 位身份证号（11010519900307123 -> 计算国标校验位）
        let id17 = "11010519900307123"
        let expectedIDCheck = ComplianceCodeEngine.expectedIDCardChecksum(first17: id17)
        XCTAssertNotNil(expectedIDCheck)
        let validID = id17 + String(expectedIDCheck!)
        let idActions = ComplianceCodeEngine.analyze(validID)
        XCTAssertEqual(idActions.first(where: { $0.id == "comp-id-group" })?.resultText, "110105 19900307 123\(expectedIDCheck!)")

        // 故意输错末位，验证引擎精准检出错误并给出正确末位修正值
        let wrongLast: Character = (expectedIDCheck == "X") ? "0" : "X"
        let typoID = id17 + String(wrongLast)
        let typoActions = ComplianceCodeEngine.analyze(typoID)
        XCTAssertEqual(typoActions.first?.id, "comp-id-invalid")
        XCTAssertEqual(typoActions.first?.resultText, validID)

        // 2. 构造合法的 18 位统一社会信用代码（GB 32100）
        let uscc17 = "91440300192203821"
        let expectedUSCC = ComplianceCodeEngine.expectedUSCCChecksum(first17: uscc17)
        XCTAssertNotNil(expectedUSCC)
        let validUSCC = uscc17 + String(expectedUSCC!)
        let usccActions = ComplianceCodeEngine.analyze(validUSCC)
        XCTAssertTrue(usccActions.contains(where: { $0.id == "comp-uscc-group" }))

        // 模拟财务把税号里的 0 手误敲成字母 O，验证自动纠错检出
        let typoUSCC = validUSCC.replacingOccurrences(of: "0300", with: "O3OO")
        let fixUSCC = ComplianceCodeEngine.analyze(typoUSCC)
        XCTAssertEqual(fixUSCC.first?.id, "comp-uscc-fix")
        XCTAssertEqual(fixUSCC.first?.resultText, validUSCC)

        // 3. 标准银联 16 位卡号 Luhn 校验与四位分节
        let base15 = "622202100111222"
        var validLuhnCard = ""
        for d in 0...9 {
            let cand = base15 + "\(d)"
            if ComplianceCodeEngine.passesLuhnCheck(cand) {
                validLuhnCard = cand
                break
            }
        }
        XCTAssertFalse(validLuhnCard.isEmpty)
        let cardActions = ComplianceCodeEngine.analyze(validLuhnCard)
        XCTAssertTrue(cardActions.contains(where: { $0.id == "comp-card-group" }))
        XCTAssertTrue(cardActions.contains(where: { $0.id == "comp-card-mask" }))
    }

    // MARK: - 9. 一次性验证码（OTP）抗干扰提取与会议逐字稿时间轴清洗测试

    func testOTPExtractionAndNoiseImmunity() {
        // 含尾号、日期、金额、分钟数多重数字干扰的银行验证码短信
        let bankSMS = "【招商银行】您尾号8899的储蓄卡于2026-11-22消费¥1280.50元，动态验证码为 654321，请在5分钟内完成验证。"
        XCTAssertEqual(MeetingAndEphemeralEngine.extractVerificationCode(from: bankSMS), "654321")

        // 验证码在前、英文关键词在后
        let openaiSMS = "[OpenAI] 918273 is your security code. Expires in 10 minutes."
        XCTAssertEqual(MeetingAndEphemeralEngine.extractVerificationCode(from: openaiSMS), "918273")

        // 关键词与验证码中间隔着产品名
        let appleSMS = "Your verification code for Apple ID is 739104. Do not share it with anyone."
        XCTAssertEqual(MeetingAndEphemeralEngine.extractVerificationCode(from: appleSMS), "739104")

        // 字母+数字混合网盘提取码
        let shareCode = "通过网盘分享的文件，提取码：G7k9，24小时内有效"
        XCTAssertEqual(MeetingAndEphemeralEngine.extractVerificationCode(from: shareCode), "G7k9")

        // 防误判：纯 6 位股票代码、普通会议通知、不含数字的验证码提示均不误触发
        XCTAssertNil(MeetingAndEphemeralEngine.extractVerificationCode(from: "600519"))
        XCTAssertNil(MeetingAndEphemeralEngine.extractVerificationCode(from: "今天下午 14:30 在 1002 会议室讨论方案"))
        XCTAssertNil(MeetingAndEphemeralEngine.extractVerificationCode(from: "请先获取短信验证码后再登录系统"))
    }

    func testMeetingTranscriptCleaningAndLogExclusion() throws {
        // 1. 飞书妙记 / 腾讯会议格式（含同一发言人连续碎片合并）
        let feishuTranscript = """
        张总监 00:01:12
        今天我们对齐一下大客户合同交付排期
        张总监 00:01:19
        重点看下第三条违约金比例。
        李律师 00:01:35
        建议违约金上限控制在合同总额的 20% 以内。
        """
        let res = try XCTUnwrap(MeetingAndEphemeralEngine.cleanMeetingTranscript(feishuTranscript))
        XCTAssertEqual(res.removedTimestampCount, 3)
        XCTAssertEqual(res.plainBody, "今天我们对齐一下大客户合同交付排期，重点看下第三条违约金比例。建议违约金上限控制在合同总额的 20% 以内。")
        XCTAssertEqual(
            res.speakerMergedDialogue,
            "张总监：今天我们对齐一下大客户合同交付排期，重点看下第三条违约金比例。\n李律师：建议违约金上限控制在合同总额的 20% 以内。"
        )

        // 2. SRT 双语/视频字幕块剥离序号与时间轴
        let srtBlock = """
        1
        00:00:01,200 --> 00:00:04,500
        大家好，欢迎来到新品演示。

        2
        00:00:04,800 --> 00:00:08,150
        今天发布极简与全能兼备的新版本。
        """
        let srtRes = try XCTUnwrap(MeetingAndEphemeralEngine.cleanMeetingTranscript(srtBlock))
        XCTAssertEqual(srtRes.plainBody, "大家好，欢迎来到新品演示。今天发布极简与全能兼备的新版本。")
        XCTAssertNil(srtRes.speakerMergedDialogue)

        // 3. 服务器运维日志严禁误判为会议逐字稿
        let serverLogs = """
        [10:12:01] [ERROR] Redis connection timeout pid=4821
        [10:12:05] [WARN] Retrying upstream connection
        """
        XCTAssertNil(MeetingAndEphemeralEngine.cleanMeetingTranscript(serverLogs))
    }

    // MARK: - 10. 置顶收藏与模板自包含归档（.iclip）跨机迁移与幂等去重合并测试

    func testPinnedArchiveExportAndNonDestructiveMerge() throws {
        let fm = FileManager.default
        let srcImgDir = fm.temporaryDirectory.appendingPathComponent("iclip-arch-src-\(UUID().uuidString)", isDirectory: true)
        let dstImgDir = fm.temporaryDirectory.appendingPathComponent("iclip-arch-dst-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: srcImgDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstImgDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: srcImgDir)
            try? fm.removeItem(at: dstImgDir)
        }

        // 无固定项时导出应明确拒绝并抛出 .noPinnedItems
        let unpinnedSecret = ClipItem(
            type: .text,
            text: "临时短信验证码 839201",
            contentHash: "text:ephemeral-1",
            isPinned: false
        )
        XCTAssertThrowsError(try ArchiveBackupService.exportPinnedArchiveData(from: [unpinnedSecret], imagesDirectoryURL: srcImgDir)) { err in
            XCTAssertEqual(err as? ArchiveBackupError, .noPinnedItems)
        }

        // 准备真实 1x1 PNG 数据写入源图片目录
        let fakePNGBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02, 0x03])
        let srcImageName = "pinned-qr.png"
        try fakePNGBytes.write(to: srcImgDir.appendingPathComponent(srcImageName))

        let pinnedInvoice = ClipItem(
            type: .text,
            text: "公司名称：轻剪科技有限公司\n税号：91440300MA5F123456",
            contentHash: "text:invoice-01",
            isPinned: true,
            pinCategory: .invoice,
            customAlias: "深圳总部开票资料"
        )
        let pinnedQRImage = ClipItem(
            type: .image,
            imageFileName: srcImageName,
            imageWidth: 320,
            imageHeight: 320,
            ocrText: "企业对公收款码",
            ocrChecked: true,
            contentHash: "img:qr-01",
            isPinned: true,
            pinCategory: .reply,
            customAlias: "商务收款二维码"
        )

        // 1. 导出：验证未固定的临时记录绝不被打包进 .iclip
        let archiveData = try ArchiveBackupService.exportPinnedArchiveData(
            from: [unpinnedSecret, pinnedInvoice, pinnedQRImage],
            imagesDirectoryURL: srcImgDir,
            appVersion: "2.0.0",
            editionKey: "flow"
        )
        let archiveJSONStr = try XCTUnwrap(String(data: archiveData, encoding: .utf8))
        XCTAssertFalse(archiveJSONStr.contains("839201"))
        XCTAssertTrue(archiveJSONStr.contains("深圳总部开票资料"))

        // 2. 目标机器已有本地记录 + 一条同哈希但未固定无备注的相同开票文本
        let localNote = ClipItem(type: .text, text: "本地草稿笔记", contentHash: "text:local-draft", isPinned: false)
        let localUnpinnedInvoice = ClipItem(
            type: .text,
            text: pinnedInvoice.text,
            contentHash: "text:invoice-01",
            isPinned: false,
            pinCategory: nil,
            customAlias: nil
        )

        let (mergedOnce, summaryOnce) = try ArchiveBackupService.mergeArchiveData(
            archiveData,
            into: [localNote, localUnpinnedInvoice],
            imagesDirectoryURL: dstImgDir
        )
        XCTAssertEqual(summaryOnce.totalInBundle, 2)
        XCTAssertEqual(summaryOnce.importedNewCount, 1)      // 图片收款码为全新导入
        XCTAssertEqual(summaryOnce.updatedExistingCount, 1)  // 开票资料自动补齐置顶、分组与备注
        XCTAssertEqual(mergedOnce.count, 3)                  // 本地草稿完好无损

        let upgradedInvoice = try XCTUnwrap(mergedOnce.first(where: { $0.contentHash == "text:invoice-01" }))
        XCTAssertTrue(upgradedInvoice.isPinned)
        XCTAssertEqual(upgradedInvoice.pinCategory, .invoice)
        XCTAssertEqual(upgradedInvoice.customAlias, "深圳总部开票资料")

        let restoredQR = try XCTUnwrap(mergedOnce.first(where: { $0.contentHash == "img:qr-01" }))
        XCTAssertTrue(restoredQR.isPinned)
        XCTAssertEqual(restoredQR.ocrText, "企业对公收款码")
        let restoredFileName = try XCTUnwrap(restoredQR.imageFileName)
        let restoredDiskBytes = try Data(contentsOf: dstImgDir.appendingPathComponent(restoredFileName))
        XCTAssertEqual(restoredDiskBytes, fakePNGBytes)

        // 3. 幂等性验证：二次重复导入同一归档包零重复膨胀
        let (mergedTwice, summaryTwice) = try ArchiveBackupService.mergeArchiveData(
            archiveData,
            into: mergedOnce,
            imagesDirectoryURL: dstImgDir
        )
        XCTAssertEqual(summaryTwice.importedNewCount, 0)
        XCTAssertEqual(summaryTwice.updatedExistingCount, 0)
        XCTAssertEqual(mergedTwice.count, 3)

        // 4. 非法文件防御验证
        let invalidData = "{\"hello\":\"world\"}".data(using: .utf8)!
        XCTAssertThrowsError(try ArchiveBackupService.mergeArchiveData(invalidData, into: [], imagesDirectoryURL: dstImgDir)) { err in
            XCTAssertEqual(err as? ArchiveBackupError, .invalidArchiveFormat)
        }
    }

    // MARK: - 11. 性能开销基准门禁（2MB 大文本摘要 O(1) 截断 + 500 条零堆分配检索）

    func testPerformanceBenchmark_LargePayloadAndZeroAllocSearch() {
        // 构造一条 2.1 MB 的巨型日志/JSON 文本与 500 条混合历史记录
        let chunk = String(repeating: "2026-11-22T10:00:00Z service=gateway latency_ms=12 status=200\n", count: 35_000)
        let hugeItem = ClipItem(type: .text, text: chunk, contentHash: "text:huge-2mb")

        var dataset: [ClipItem] = [hugeItem]
        dataset.reserveCapacity(501)
        for idx in 1...500 {
            dataset.append(ClipItem(
                type: .text,
                text: "订单编号 ORD-2026-\(idx) 客户回款金额 ¥\(idx * 128).50 联系人张经理",
                contentHash: "text:\(idx)",
                sourceAppName: "飞书"
            ))
        }

        let start = CFAbsoluteTimeGetCurrent()
        // 连续执行 200 次 2MB 大文本预览与字数读取（必须 O(1) 瞬时返回）
        for _ in 0..<200 {
            _ = hugeItem.primaryTitle
            _ = hugeItem.subtitleInfo
        }
        // 在 501 条记录（含 2.1MB 大文本）中执行不区分大小写检索
        let matched = dataset.filter { $0.matches(query: "ord-2026-499") }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        XCTAssertEqual(matched.count, 1)
        XCTAssertLessThan(hugeItem.rawContentPreview.utf16.count, 250)
        XCTAssertTrue(hugeItem.subtitleInfo.contains("MB"))
        // 硬门禁：全套操作必须在 25ms 以内完成（实测通常 < 3ms）
        XCTAssertLessThan(elapsedMs, 25.0, "性能退化告警：耗时 \(elapsedMs) ms 超过阈值")
    }

    // MARK: - 12. 语义脱敏、净链与动态模板回归测试

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

    // MARK: - 13. 图片 3 列网格二维方向键导航（↑↓←→）回归测试

    func testGridNavigation2DImageRowsAndColumnMemory() {
        // 布局：5 张连续图片（2 行：[0,1,2], [3,4]）+ 1 条普通文本（[5]）+ 3 张图片（[6,7,8]）
        let imageIndices: Set<Int> = [0, 1, 2, 3, 4, 6, 7, 8]
        let rows = GridNavigationHelper.buildVisualRows(count: 9, imageColumns: 3) { imageIndices.contains($0) }
        XCTAssertEqual(rows, [[0, 1, 2], [3, 4], [5], [6, 7, 8]])

        // 1. 第 1 行第 2 列 (idx=1) 按 ↓ -> 精准落到第 2 行第 2 列 (idx=4)
        let step1 = GridNavigationHelper.nextIndex(from: 1, direction: .down, visualRows: rows, preferredColumn: nil)
        XCTAssertEqual(step1.index, 4)
        XCTAssertEqual(step1.preferredColumn, 1)

        // 2. 第 1 行第 3 列 (idx=2) 按 ↓ -> 第 2 行只有 2 张图，落到尾张 (idx=4)，但仍记忆第 3 列 (col=2)
        let step2 = GridNavigationHelper.nextIndex(from: 2, direction: .down, visualRows: rows, preferredColumn: nil)
        XCTAssertEqual(step2.index, 4)
        XCTAssertEqual(step2.preferredColumn, 2)

        // 3. 继续按 ↓ 跨过单行文本 (idx=5) 再按 ↓ -> 回到第 3 列 (idx=8)
        let step3 = GridNavigationHelper.nextIndex(from: step2.index, direction: .down, visualRows: rows, preferredColumn: step2.preferredColumn)
        XCTAssertEqual(step3.index, 5)
        let step4 = GridNavigationHelper.nextIndex(from: step3.index, direction: .down, visualRows: rows, preferredColumn: step3.preferredColumn)
        XCTAssertEqual(step4.index, 8)

        // 4. 左右方向键在网格中丝滑移动并同步列记忆
        let leftMove = GridNavigationHelper.nextIndex(from: 1, direction: .left, visualRows: rows, preferredColumn: 1)
        XCTAssertEqual(leftMove.index, 0)
        XCTAssertEqual(leftMove.preferredColumn, 0)

        let rightMove = GridNavigationHelper.nextIndex(from: 0, direction: .right, visualRows: rows, preferredColumn: 0)
        XCTAssertEqual(rightMove.index, 1)
        XCTAssertEqual(rightMove.preferredColumn, 1)
    }

    // MARK: - 14. 拖拽内容到 iClip 复制类型校验测试

    func testDragAndDropPasteboardTypeRecognition() {
        let dragPB = NSPasteboard.withUniqueName()
        defer { dragPB.releaseGlobally() }

        XCTAssertFalse(ClipboardStore.canAcceptDrag(from: dragPB))

        dragPB.clearContents()
        dragPB.setString("拖拽测试文本", forType: .string)
        XCTAssertTrue(ClipboardStore.canAcceptDrag(from: dragPB))

        dragPB.clearContents()
        dragPB.setString("https://github.com/fanaruto/iClip", forType: .URL)
        XCTAssertTrue(ClipboardStore.canAcceptDrag(from: dragPB))
    }

    // MARK: - 15. 首次打开「核心亮点速览」展示与关闭回归测试

    @MainActor
    func testCoreHighlightsShowAndDismiss() {
        let ctrl = InteractivePlaygroundController.shared
        ctrl.showHighlights()
        XCTAssertTrue(ctrl.isActive)
        ctrl.dismiss()
        XCTAssertFalse(ctrl.isActive)
    }

    // MARK: - 16. 自适应心智引擎：上下文习惯排序、晋升契约、忽略退避与高频复用记忆测试

    @MainActor
    func testAdaptiveIntelligenceLearningRankingAndAutoPromotion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-adaptive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = AdaptiveIntelligenceEngine(customDirectoryURL: tempDir)

        // 1. 模拟在 Cursor 中用户连续 2 次选择「压缩单行 JSON」，验证该来源应用下自动置顶且解锁「设为自动」契约检查
        let actions = ["json-pretty", "json-minify"]
        XCTAssertEqual(engine.rankActions(actions, idOf: { $0 }, sourceApp: "Cursor"), ["json-pretty", "json-minify"])

        engine.recordActionUsed(actionID: "json-minify", sourceApp: "Cursor")
        engine.recordActionUsed(actionID: "json-minify", sourceApp: "Cursor")
        XCTAssertEqual(engine.rankActions(actions, idOf: { $0 }, sourceApp: "Cursor"), ["json-minify", "json-pretty"])
        XCTAssertTrue(engine.isHabitPreferred(actionID: "json-minify", sourceApp: "Cursor"))

        // 2. 验证连续采纳 clean-url 后在微星标候选中点亮「设为自动（promotableRule）」
        engine.recordActionUsed(actionID: "clean-url", sourceApp: "Safari")
        engine.recordActionUsed(actionID: "clean-url", sourceApp: "Safari")
        let dirtyLink = ClipItem(
            type: .link,
            text: "https://webfooo.com/p?id=1&utm_source=x&utm_medium=social",
            contentHash: "link:dirty-test",
            sourceAppName: "Safari"
        )
        let spark = try XCTUnwrap(engine.evaluateSparkCandidate(for: dirtyLink, reuseCount: 1, minimalMode: false))
        XCTAssertEqual(spark.actionID, "clean-url")
        XCTAssertEqual(spark.promotableRule, .cleanTrackingURL)

        // 3. 验证用户连续点击 2 次 × 显式关闭某类推荐后自动习得退避静默
        engine.recordSparkExplicitDismiss(actionID: "clean-url", categoryKey: "url_tracking", sourceApp: "Safari")
        engine.recordSparkExplicitDismiss(actionID: "clean-url", categoryKey: "url_tracking", sourceApp: "Safari")
        XCTAssertNil(engine.evaluateSparkCandidate(for: dirtyLink, reuseCount: 1, minimalMode: false))

        // 4. 验证未收藏普通条目复用达到 3 次时触发「一键收藏」高粘性推荐
        let plainNote = ClipItem(type: .text, text: "公司统一开票抬头：上海怀道科技有限公司", contentHash: "text:company-title")
        _ = engine.recordContentActivity(contentHash: plainNote.contentHash)
        _ = engine.recordContentActivity(contentHash: plainNote.contentHash)
        let thirdCount = engine.recordContentActivity(contentHash: plainNote.contentHash)
        XCTAssertEqual(thirdCount, 3)
        let pinSpark = try XCTUnwrap(engine.evaluateSparkCandidate(for: plainNote, reuseCount: thirdCount, minimalMode: false))
        XCTAssertEqual(pinSpark.actionID, "habit-pin-frequent")
    }

    // MARK: - 17. 自然语言建议即时采纳与窗口始终在前状态测试

    @MainActor
    func testUserSuggestionNaturalLanguageAdoptionAndAlwaysOnTop() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-suggest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = AdaptiveIntelligenceEngine(customDirectoryURL: tempDir)
        let store = ClipboardStore.shared
        let prevAlwaysOnTop = store.alwaysOnTop
        defer { store.alwaysOnTop = prevAlwaysOnTop }

        // 1. 自然语言开启「始终在前」与「微信免打扰」
        let r1 = engine.adoptUserSuggestion("开启窗口始终在前，并且在微信里不要弹提示", in: store)
        XCTAssertTrue(r1.adoptedImmediately)
        XCTAssertTrue(store.alwaysOnTop)
        XCTAssertTrue(engine.isSourceAppMuted("微信"))

        // 2. 自然语言开启「复制 PDF 自动愈合断行」并验证自动契约即时净化生效
        let r2 = engine.adoptUserSuggestion("以后复制 PDF 断行自动愈合段落", in: store)
        XCTAssertTrue(r2.adoptedImmediately)
        XCTAssertTrue(engine.enabledAutoRules.contains(.healPDFLineBreaks))

        let brokenPDF = "Artificial intelligence is transforming modern soft-\nware engineering workflows across every industry."
        let healed = try XCTUnwrap(engine.applyLearnedAutoTextRuleIfEnabled(rawText: brokenPDF, isLink: false))
        XCTAssertEqual(healed.rule, .healPDFLineBreaks)
        XCTAssertTrue(healed.text.contains("software engineering"))

        // 3. 开放式新需求自动沉淀至自省进化队列
        let r3 = engine.adoptUserSuggestion("希望后续增加按颜色色相筛选历史色值的功能", in: store)
        XCTAssertFalse(r3.adoptedImmediately)
        XCTAssertEqual(r3.record.status, .queuedForEvolution)
        XCTAssertEqual(engine.suggestions.count, 3)
    }

    // MARK: - 18. 多词跨维度组合搜索与免切输入法拼音/首字母检索测试

    func testMultiTokenCrossFieldAndPinyinInitialsSearch() {
        let invoiceItem = ClipItem(
            type: .text,
            text: "开票抬头：上海怀道科技有限公司\n纳税人识别号：91310000MA1K88888X",
            contentHash: "text:hd-invoice",
            sourceAppName: "飞书",
            isPinned: true,
            pinCategory: .invoice,
            customAlias: "总部税号"
        )
        let wechatImg = ClipItem(
            type: .image,
            imageFileName: "demo.png",
            imageWidth: 1200,
            imageHeight: 800,
            contentHash: "img:wx-shot",
            sourceAppName: "微信"
        )

        // 1. 多词空格跨维度组合匹配（来源应用 + 正文关键词 / 类型名）
        XCTAssertTrue(invoiceItem.matches(query: "飞书 913100"))
        XCTAssertTrue(invoiceItem.matches(query: "总部 怀道"))
        XCTAssertTrue(wechatImg.matches(query: "微信 图片"))
        XCTAssertFalse(wechatImg.matches(query: "微信 税号"))

        // 2. 免切中文输入法：英文全拼与拼音首字母秒搜
        XCTAssertTrue(invoiceItem.matches(query: "shhdkj"))     // 上海怀道科技 首字母
        XCTAssertTrue(invoiceItem.matches(query: "huaidao"))    // 怀道 全拼
        XCTAssertTrue(invoiceItem.matches(query: "zbsh"))       // 总部税号 备注首字母
        XCTAssertTrue(invoiceItem.matches(query: "feishu 9131"))// 飞书全拼 + 税号片段混合组合
        XCTAssertTrue(wechatImg.matches(query: "wx tp"))        // 微信 + 图片 双首字母组合
    }

    // MARK: - 19. 拖拽途中按 ⌥「光标旁微落点」载荷识别、内存样机与自然语言调教测试

    @MainActor
    func testCursorDropPodPayloadDetectionAndInMemoryMockup() throws {
        let dragPB = NSPasteboard.withUniqueName()
        defer { dragPB.releaseGlobally() }

        // 1. 纯文本拖拽识别为单槽模式（非图片）
        dragPB.clearContents()
        dragPB.setString("拖拽文本片段", forType: .string)
        XCTAssertFalse(CursorDropPodController.containsImageDragPayload(in: dragPB))

        // 2. 构造一张 16x16 内存 PNG 图像，验证识别为双槽图片模式且支持零磁盘 I/O 直出圆角阴影样机
        let img = NSImage(size: NSSize(width: 64, height: 48), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let pngData = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        dragPB.clearContents()
        dragPB.setData(pngData, forType: .png)
        XCTAssertTrue(CursorDropPodController.containsImageDragPayload(in: dragPB))

        let mockup = try XCTUnwrap(ImageStudioEngine.renderAppleMockupFrame(from: pngData))
        XCTAssertGreaterThan(mockup.byteCount, 100)

        // 3. 验证自然语言调教可随时关闭/开启光标旁微落点
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-droppod-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let engine = AdaptiveIntelligenceEngine(customDirectoryURL: tempDir)
        XCTAssertTrue(engine.cursorDropPodEnabled)
        _ = engine.adoptUserSuggestion("关闭拖拽微落点", in: .shared)
        XCTAssertFalse(engine.cursorDropPodEnabled)
        _ = engine.adoptUserSuggestion("开启拖拽微落点", in: .shared)
        XCTAssertTrue(engine.cursorDropPodEnabled)
    }

    // MARK: - 20. 搜索框即时四则速算（精确小数除法/防日期误判/大写直出）与误删撤销测试

    @MainActor
    func testInstantMathEvaluatorAndSafetyGuards() throws {
        // 1. 浮点除法不丢小数、括号优先级与中文乘除号支持
        let r1 = try XCTUnwrap(InstantMathEvaluator.evaluate("5 / 2"))
        XCTAssertEqual(r1.plainValue, "2.5")
        XCTAssertEqual(r1.rmbUppercase, "贰元伍角整")

        let r2 = try XCTUnwrap(InstantMathEvaluator.evaluate("(3,200 + 800) × 1.13"))
        XCTAssertEqual(r2.plainValue, "4520")
        XCTAssertEqual(r2.formattedThousands, "4,520")
        XCTAssertEqual(r2.rmbUppercase, "肆仟伍佰贰拾元整")

        // 2. 边界安全守卫：半截算式、除以 0、ISO 日期与普通纯数字不触发误判且绝不崩溃
        XCTAssertNil(InstantMathEvaluator.evaluate("128 + "))
        XCTAssertNil(InstantMathEvaluator.evaluate("100 / 0"))
        XCTAssertNil(InstantMathEvaluator.evaluate("2026-11-23"))
        XCTAssertNil(InstantMathEvaluator.evaluate("91310000"))
    }

    // MARK: - 21. 全模态 Finder 速览（原图/实况文本/单行防执行压平）与原位微调回写无损测试

    @MainActor
    func testQuickLookTabsSingleLineFlattenAndInPlaceUpdate() throws {
        // 1. Shell 续行符与尾部换行安全压平（防止粘贴进终端直接回车执行）
        let shellCmd = """
        curl -X POST https://api.example.com/v1 \\
          -H "Authorization: Bearer token" \\
          -d '{"ok":true}'
        """
        XCTAssertTrue(QuickLookTextHelper.containsMultiLine(shellCmd))
        let flattened = QuickLookTextHelper.flattenToSingleLine(shellCmd + "\n")
        XCTAssertEqual(flattened, #"curl -X POST https://api.example.com/v1 -H "Authorization: Bearer token" -d '{"ok":true}'"#)
        XCTAssertFalse(flattened.contains("\n"))

        // 2. 图片速览页签构建：无 OCR 时仅展示「高清原图」，含 OCR 时自动生成「高清原图 + 实况文本」双页签
        let plainImg = ClipItem(type: .image, imageFileName: "a.png", contentHash: "img:1")
        let plainImgTabs = QuickLookTabBuilder.buildTabs(for: plainImg, store: .shared)
        XCTAssertEqual(plainImgTabs.map(\.id), ["image"])
        XCTAssertEqual(QuickLookTabBuilder.defaultTabIndex(for: plainImg, tabs: plainImgTabs), 0)

        let ocrImg = ClipItem(type: .image, imageFileName: "b.png", ocrText: "发票代码 044001900111", ocrChecked: true, contentHash: "img:2")
        let ocrImgTabs = QuickLookTabBuilder.buildTabs(for: ocrImg, store: .shared)
        XCTAssertEqual(ocrImgTabs.map(\.id), ["image", "ocr"])
        XCTAssertTrue(ocrImgTabs[1].supportsSaveBack)

        // 3. 原位微调回写（⌘S）：完整保留原 UUID、收藏、分组与备注名，并自动重判文本/链接类型与哈希
        let original = ClipItem(
            type: .text,
            text: "ssh -p 2222 root@10.0.0.8",
            contentHash: "text:old",
            sourceAppName: "Terminal",
            isPinned: true,
            pinCategory: .template,
            customAlias: "生产服 SSH"
        )
        let edited = try XCTUnwrap(ClipboardStore.updatedItem(from: original, withNewText: "ssh -p 22022 deploy@10.0.0.8"))
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.type, .text)
        XCTAssertEqual(edited.text, "ssh -p 22022 deploy@10.0.0.8")
        XCTAssertNotEqual(edited.contentHash, original.contentHash)
        XCTAssertTrue(edited.isPinned)
        XCTAssertEqual(edited.pinCategory, .template)
        XCTAssertEqual(edited.customAlias, "生产服 SSH")
        XCTAssertTrue(edited.matches(query: "scf")) // 备注拼音首字母依旧秒搜

        let linkEdited = try XCTUnwrap(ClipboardStore.updatedItem(from: edited, withNewText: "https://github.com/fanaruto/iClip"))
        XCTAssertEqual(linkEdited.type, .link)
        XCTAssertTrue(linkEdited.contentHash.hasPrefix("link:"))
        XCTAssertNil(ClipboardStore.updatedItem(from: edited, withNewText: "   \n  "))

        let ocrEdited = try XCTUnwrap(ClipboardStore.updatedItem(from: ocrImg, withNewText: "发票代码 044001900999"))
        XCTAssertEqual(ocrEdited.ocrText, "发票代码 044001900999")
    }

    // MARK: - 22. 零离手「⌘C×2 原位智变」与「⌘C×3 无损还原」确定性状态机测试

    @MainActor
    func testDoubleCopySparkTriggerMachineDebounceAndThirdCopyRestore() throws {
        var sm = DoubleCopySparkStateMachine()
        let hash = "link:dirty-utm"

        // 1. 首次复制记录微星标在屏窗口（t = 10.0s，窗口 2.4s）
        XCTAssertEqual(sm.evaluateIncomingCopy(contentHash: hash, at: 10.0, doubleCopyEnabled: true), .normalCopy)
        sm.recordOffer(contentHash: hash, at: 10.0, windowSeconds: 2.4)

        // 2. < 140ms 内的机器双通道重写严格过滤，绝不误触发
        XCTAssertEqual(sm.evaluateIncomingCopy(contentHash: hash, at: 10.06, doubleCopyEnabled: true), .normalCopy)

        // 3. 人类真实第 2 次 ⌘C（t = 10.45s）直接零离手触发微星标转换
        XCTAssertEqual(sm.evaluateIncomingCopy(contentHash: hash, at: 10.45, doubleCopyEnabled: true), .triggerCandidate)
        XCTAssertNil(sm.activeHash)

        // 4. 短窗口内按下第 3 次 ⌘C（t = 11.10s）无损还原原始内容，并在随后 1.8s 内静默抑制重弹防止死循环
        XCTAssertEqual(sm.evaluateIncomingCopy(contentHash: hash, at: 11.10, doubleCopyEnabled: true), .restoreOriginal)
        XCTAssertEqual(sm.evaluateIncomingCopy(contentHash: hash, at: 11.60, doubleCopyEnabled: true), .suppressReoffer)
        XCTAssertEqual(sm.evaluateIncomingCopy(contentHash: hash, at: 13.20, doubleCopyEnabled: true), .normalCopy)

        // 5. 自然语言调教随时可开关「连按两次 ⌘C 触发智变」
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-dblcopy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let engine = AdaptiveIntelligenceEngine(customDirectoryURL: tempDir)
        XCTAssertTrue(engine.doubleCopySparkEnabled)
        _ = engine.adoptUserSuggestion("关闭双击复制触发", in: .shared)
        XCTAssertFalse(engine.doubleCopySparkEnabled)
        _ = engine.adoptUserSuggestion("开启连按复制智变", in: .shared)
        XCTAssertTrue(engine.doubleCopySparkEnabled)
    }

    // MARK: - 23. 跨处选段「⌃⌥C 续接复制（Copy-Append）」纯净换行衔接与自然语言调教测试

    @MainActor
    func testCopyAppendSegmentJoiningAndNaturalLanguageToggle() throws {
        // 1. 多段换行去重衔接（消除首尾多余空行，保留段内缩进）
        let s1 = CopyAppendHelper.joinSegments(base: "第一段摘要\n\n", incoming: "\n  - 第二段要点")
        XCTAssertEqual(s1, "第一段摘要\n  - 第二段要点")
        let s2 = CopyAppendHelper.joinSegments(base: s1, incoming: "  - 第三段结论")
        XCTAssertEqual(s2, "第一段摘要\n  - 第二段要点\n  - 第三段结论")
        XCTAssertEqual(CopyAppendHelper.joinSegments(base: "   ", incoming: "首段文本"), "首段文本")

        // 2. 支持从文本、文件路径与含 OCR 图片提取可追加内容
        let fileItem = ClipItem(type: .file, filePaths: ["/tmp/a.txt", "/tmp/b.txt"], contentHash: "file:ab")
        XCTAssertEqual(CopyAppendHelper.extractAppendableText(from: fileItem), "/tmp/a.txt\n/tmp/b.txt")
        let plainImg = ClipItem(type: .image, imageFileName: "x.png", contentHash: "img:x")
        XCTAssertNil(CopyAppendHelper.extractAppendableText(from: plainImg))

        // 3. 验证全局默认快捷键为 ⌃⌥C，且支持自然语言即时开关
        XCTAssertEqual(HotKeyShortcut.defaultCopyAppendShortcut.compactDisplayString, "⌃⌥C")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-append-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let engine = AdaptiveIntelligenceEngine(customDirectoryURL: tempDir)
        XCTAssertTrue(engine.copyAppendEnabled)
        _ = engine.adoptUserSuggestion("关闭续接复制", in: .shared)
        XCTAssertFalse(engine.copyAppendEnabled)
        _ = engine.adoptUserSuggestion("开启追加复制", in: .shared)
        XCTAssertTrue(engine.copyAppendEnabled)
    }

    #if !ICLIP_EDITION_FLOW
    // MARK: - 24. JWT 本地零上传 Base64URL 解码与 exp 过期诊断测试

    func testJWTOfflineBase64URLDecodeAndExpirationCheck() throws {
        // Header: {"alg":"HS256","typ":"JWT"}
        // Payload: {"sub":"u_42","role":"admin","exp":1893456000} (2030-01-01)
        let headerB64 = Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let payloadB64 = Data(#"{"sub":"u_42","role":"admin","exp":1893456000}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "Bearer \(headerB64).\(payloadB64).fake_signature_1234567890"

        let validRef = Date(timeIntervalSince1970: 1_700_000_000)
        let decodedValid = try XCTUnwrap(SemanticEngine.decodeJWTInspection(token, referenceDate: validRef))
        XCTAssertTrue(decodedValid.contains("（有效）"))
        XCTAssertTrue(decodedValid.contains("\"u_42\""))

        let expiredRef = Date(timeIntervalSince1970: 2_000_000_000)
        let decodedExpired = try XCTUnwrap(SemanticEngine.decodeJWTInspection(token, referenceDate: expiredRef))
        XCTAssertTrue(decodedExpired.contains("（已过期）"))

        // 验证 SemanticEngine.analyze 同时保留首位「脱敏粘贴」安全动作与「解码 JWT」动作
        let clip = ClipItem(type: .text, text: token, contentHash: "text:jwt")
        let snap = SemanticEngine.analyze(clip)
        XCTAssertEqual(snap.primaryKind, .sensitiveSecret)
        XCTAssertEqual(snap.actions.first?.id, "redact-secrets")
        XCTAssertTrue(snap.actions.contains(where: { $0.id == "jwt-decode" }))
    }
    #endif

    // MARK: - 25. 自然情景时间窗（今天/昨天/1h/7d/收藏）与 `!排除词` 零歧义组合检索测试

    func testEpisodicTimeScopeAndNegationTokenSearch() {
        let cal = Calendar.current
        let todayNoon = cal.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        let thirtyMinsAgo = todayNoon.addingTimeInterval(-1_800)
        let yesterdayAfternoon = todayNoon.addingTimeInterval(-86_400)
        let tenDaysAgo = todayNoon.addingTimeInterval(-10 * 86_400)

        let recentWeChatImg = ClipItem(
            type: .image,
            imageFileName: "qr.png",
            contentHash: "img:qr",
            sourceAppName: "微信",
            createdAt: thirtyMinsAgo,
            isPinned: true,
            customAlias: "公司收款码"
        )
        let yesterdayCurl = ClipItem(
            type: .text,
            text: "curl -X POST https://api.example.com/v1?utm_source=test",
            contentHash: "text:curl",
            sourceAppName: "Terminal",
            createdAt: yesterdayAfternoon
        )
        let oldNote = ClipItem(
            type: .text,
            text: "十天前的历史会议备忘",
            contentHash: "text:old",
            sourceAppName: "备忘录",
            createdAt: tenDaysAgo
        )

        // 1. 情景时间窗 × 来源应用 × 类型自由组合检索
        XCTAssertTrue(recentWeChatImg.matches(query: "今天 微信 图片", now: todayNoon))
        XCTAssertTrue(recentWeChatImg.matches(query: "1h gsskm", now: todayNoon)) // 1小时内 + 公司收款码拼音首字母
        XCTAssertTrue(recentWeChatImg.matches(query: "收藏 收款", now: todayNoon))
        XCTAssertFalse(yesterdayCurl.matches(query: "今天", now: todayNoon))
        XCTAssertTrue(yesterdayCurl.matches(query: "昨天 curl", now: todayNoon))
        XCTAssertTrue(yesterdayCurl.matches(query: "本周 terminal", now: todayNoon))
        XCTAssertFalse(oldNote.matches(query: "本周", now: todayNoon))

        // 2. `!排除词` 精准反向过滤，且绝不误伤命令行 `-X` 参数检索
        XCTAssertTrue(yesterdayCurl.matches(query: "curl -X", now: todayNoon))
        XCTAssertFalse(yesterdayCurl.matches(query: "curl !utm_source", now: todayNoon))
        XCTAssertTrue(recentWeChatImg.matches(query: "今天 !terminal", now: todayNoon))
    }

    // MARK: - 26. 目标窗口情境记忆（Target App Affinity）与第一性相关度检索引擎测试

    @MainActor
    func testSmartSearchRankerAliasPriorityAndTargetAppAffinity() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-smartrank-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let engine = AdaptiveIntelligenceEngine(customDirectoryURL: tempDir)

        let now = Date()
        // 刚刚复制的无关长文（偶然提到「税号」二字，时间最新）
        let noisyArticle = ClipItem(
            type: .text,
            text: String(repeating: "这是一段普通的行业新闻摘要，文末顺便提到了请核对企业税号是否变更。", count: 15),
            contentHash: "text:noisy-article",
            sourceAppName: "Safari",
            createdAt: now
        )
        // 三天前收藏并设置备注别名的真正税号条目
        let pinnedTaxID = ClipItem(
            type: .text,
            text: "91310000MA1K88888X",
            contentHash: "text:real-tax",
            sourceAppName: "飞书",
            createdAt: now.addingTimeInterval(-3 * 86_400),
            isPinned: true,
            customAlias: "总部税号"
        )

        // 1. 搜「税号」或备注拼音首字母「zbsh」时，精准备注收藏必须排在无关新长文之前（#1）
        let byKeyword = SmartSearchRanker.rankSearchResults([noisyArticle, pinnedTaxID], query: "税号", targetApp: nil, engine: engine)
        XCTAssertEqual(byKeyword.map(\.id), [pinnedTaxID.id, noisyArticle.id])

        let byAliasPinyin = SmartSearchRanker.rankSearchResults([noisyArticle, pinnedTaxID], query: "zbsh", targetApp: nil, engine: engine)
        XCTAssertEqual(byAliasPinyin.map(\.id), [pinnedTaxID.id, noisyArticle.id])

        // 2. 纯时间筛选词（如「今天」）严守时间倒序铁律，绝不乱排
        let secondRecent = ClipItem(type: .text, text: "今天较早记录", contentHash: "text:t2", createdAt: now.addingTimeInterval(-600))
        let pureTimeRanked = SmartSearchRanker.rankSearchResults([noisyArticle, secondRecent], query: "今天", targetApp: "微信", engine: engine)
        XCTAssertEqual(pureTimeRanked.map(\.id), [noisyArticle.id, secondRecent.id])

        // 3. 目标窗口情境分流：在「微信」搜地址置顶收货地址，在「Terminal」搜地址置顶服务器地址
        let officeAddr = ClipItem(
            type: .text,
            text: "地址：上海市浦东新区张江高科园区 88 号（收件人王经理）",
            contentHash: "text:addr-wx",
            createdAt: now.addingTimeInterval(-3600),
            isPinned: true
        )
        let serverAddr = ClipItem(
            type: .text,
            text: "地址：10.24.0.88:5432（生产只读库）",
            contentHash: "text:addr-term",
            createdAt: now.addingTimeInterval(-1800),
            isPinned: true
        )

        engine.recordPasteToTargetApp(contentHash: officeAddr.contentHash, targetApp: "微信")
        engine.recordPasteToTargetApp(contentHash: officeAddr.contentHash, targetApp: "微信")
        engine.recordPasteToTargetApp(contentHash: serverAddr.contentHash, targetApp: "Terminal")
        engine.recordPasteToTargetApp(contentHash: serverAddr.contentHash, targetApp: "Terminal")
        engine.recordPasteToTargetApp(contentHash: serverAddr.contentHash, targetApp: "Terminal")

        let inWeChat = SmartSearchRanker.rankSearchResults([serverAddr, officeAddr], query: "地址", targetApp: "微信", engine: engine)
        XCTAssertEqual(inWeChat.first?.id, officeAddr.id)

        let inTerminal = SmartSearchRanker.rankSearchResults([officeAddr, serverAddr], query: "地址", targetApp: "Terminal", engine: engine)
        XCTAssertEqual(inTerminal.first?.id, serverAddr.id)

        // 4. 收藏夹无搜索情境置顶与紧凑微标签（✦ 微信常用 / ✦ Chrome常用）
        let pinnedForWeChat = SmartSearchRanker.rankPinnedItemsForContext([pinnedTaxID, serverAddr, officeAddr], targetApp: "微信", engine: engine)
        XCTAssertEqual(pinnedForWeChat.first?.id, officeAddr.id)
        XCTAssertEqual(engine.preferredTargetAppBadge(for: officeAddr.contentHash, activeTargetApp: "微信"), "✦ 微信常用")
        XCTAssertNil(engine.preferredTargetAppBadge(for: officeAddr.contentHash, activeTargetApp: "Terminal"))

        // 未建立习惯的目标应用完全保持原始收藏顺序
        let pinnedForSafari = SmartSearchRanker.rankPinnedItemsForContext([pinnedTaxID, serverAddr, officeAddr], targetApp: "Safari", engine: engine)
        XCTAssertEqual(pinnedForSafari.map(\.id), [pinnedTaxID.id, serverAddr.id, officeAddr.id])

        // 5. 自然语言调教一键关闭情境智能排序后立即恢复原始时间序
        _ = engine.adoptUserSuggestion("关闭智能排序", in: .shared)
        XCTAssertFalse(engine.smartContextRankingEnabled)
        let rawOrder = SmartSearchRanker.rankSearchResults([noisyArticle, pinnedTaxID], query: "税号", targetApp: "微信", engine: engine)
        XCTAssertEqual(rawOrder.map(\.id), [noisyArticle.id, pinnedTaxID.id])
    }

    // MARK: - 27. 全角色零手机「二维码直解（QR Code Instant Decode）」与离线实况文本贯通测试

    @MainActor
    func testOfflineQRCodeInstantDecodeSparkPriorityAndCrossRoleOCRSearch() throws {
        // 1. 使用 CoreImage 在内存合成一张带安静区边框的真实二维码 PNG，验证 Apple Vision 离线精准解出原始链接
        let expectedURL = "https://github.com/fanaruto/iClip"
        let qrFilter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        qrFilter.setValue(Data(expectedURL.utf8), forKey: "inputMessage")
        qrFilter.setValue("M", forKey: "inputCorrectionLevel")
        let ciRaw = try XCTUnwrap(qrFilter.outputImage)
        let scaled = ciRaw.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let ciCtx = CIContext()
        let qrCG = try XCTUnwrap(ciCtx.createCGImage(scaled, from: scaled.extent))
        let rep = NSBitmapImageRep(cgImage: qrCG)
        let qrPNG = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        let decodedPayload = VisionOCRService.detectBarcodesFast(in: qrPNG)
        XCTAssertEqual(decodedPayload, expectedURL)

        // 2. 验证含二维码与实况文本的图片在双角色（Dev & Flow）中均支持 @qr / 二维码 / 图内中英与拼音首字母秒搜
        let qrShot = ClipItem(
            type: .image,
            imageFileName: "login-qr.png",
            ocrText: "扫码登录企业控制台",
            ocrChecked: true,
            qrCodePayload: expectedURL,
            contentHash: "img:qr-login",
            sourceAppName: "Google Chrome"
        )
        XCTAssertTrue(qrShot.matches(query: "二维码"))
        XCTAssertTrue(qrShot.matches(query: "@qr github"))
        XCTAssertTrue(qrShot.matches(query: "smdl")) // 扫码登录 拼音首字母（Dev 版同步解锁）
        XCTAssertTrue(qrShot.subtitleInfo.hasPrefix("二维码："))

        // 3. 验证 QuickLook 自动生成「高清原图 + 二维码内容 + 实况文本」三页签
        let qlTabs = QuickLookTabBuilder.buildTabs(for: qrShot, store: .shared)
        XCTAssertEqual(qlTabs.map(\.id), ["image", "qrcode", "ocr"])
        XCTAssertEqual(qlTabs[1].textValue, expectedURL)

        // 4. 验证微星标对二维码截图最高优推荐「提取二维码链接」，且支持自然语言调教开启二维码自动提取与截图优先提字
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-qr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let engine = AdaptiveIntelligenceEngine(customDirectoryURL: tempDir)

        let spark = try XCTUnwrap(engine.evaluateSparkCandidate(for: qrShot, reuseCount: 1, minimalMode: false))
        XCTAssertEqual(spark.actionID, "img-qrcode")
        XCTAssertEqual(spark.shortTitle, "提取二维码链接")

        _ = engine.adoptUserSuggestion("复制二维码自动提取，普通截图优先提取文字", in: .shared)
        XCTAssertTrue(engine.enabledAutoRules.contains(.extractQRCode))

        let textShot = ClipItem(type: .image, imageFileName: "err.png", ocrText: "Fatal error: Index out of range", ocrChecked: true, contentHash: "img:err")
        let textSpark = try XCTUnwrap(engine.evaluateSparkCandidate(for: textShot, reuseCount: 1, minimalMode: false))
        XCTAssertEqual(textSpark.actionID, "img-ocr")
    }

    // MARK: - 28. 内建 Pure Paste：富文本脏样式无损嗅探、电子表格分列保护与免打扰应用豁免测试

    @MainActor
    func testRichTextFormattingDetectionSpreadsheetGuardAndAutoPurePaste() throws {
        // 1. 识别网页 HTML / IDE RTF 富文本，但严格保护 Excel/Numbers (.tabularText) 与 TSV 二维表格
        XCTAssertTrue(RichTextPasteboardHelper.hasStrippableRichFormatting(
            types: [.string, .html],
            plainText: "这是一段来自网页带大字号红底的文字"
        ))
        XCTAssertTrue(RichTextPasteboardHelper.hasStrippableRichFormatting(
            types: [.string, .rtf],
            plainText: "let status = 200"
        ))
        XCTAssertFalse(RichTextPasteboardHelper.hasStrippableRichFormatting(
            types: [.string],
            plainText: "干净纯文本"
        ))
        XCTAssertFalse(RichTextPasteboardHelper.hasStrippableRichFormatting(
            types: [.string, .html, .tabularText],
            plainText: "姓名\t金额\n张三\t1200"
        ))
        XCTAssertFalse(RichTextPasteboardHelper.hasStrippableRichFormatting(
            types: [.string, .html],
            plainText: "季度\t营收\t利润\nQ1\t500\t120"
        ))

        // 2. 微星标在普通富文本复制时提供「净化为纯文本」，连续使用 2 次后解锁自动契约晋升
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-purepaste-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let engine = AdaptiveIntelligenceEngine(customDirectoryURL: tempDir)

        let styledNote = ClipItem(type: .text, text: "明天下午三点产品评审", contentHash: "text:styled", sourceAppName: "Google Chrome")
        XCTAssertNil(engine.evaluateSparkCandidate(for: styledNote, reuseCount: 1, minimalMode: false, hasRichFormatting: false))

        let firstSpark = try XCTUnwrap(engine.evaluateSparkCandidate(for: styledNote, reuseCount: 1, minimalMode: false, hasRichFormatting: true))
        XCTAssertEqual(firstSpark.actionID, "strip-rich-style")
        XCTAssertNil(firstSpark.promotableRule)

        engine.recordActionUsed(actionID: "strip-rich-style", sourceApp: "Google Chrome")
        engine.recordActionUsed(actionID: "strip-rich-style", sourceApp: "Google Chrome")
        let promotedSpark = try XCTUnwrap(engine.evaluateSparkCandidate(for: styledNote, reuseCount: 2, minimalMode: false, hasRichFormatting: true))
        XCTAssertEqual(promotedSpark.promotableRule, .stripRichTextFormatting)

        // 3. 自然语言开启「自动纯文本」后生效，且对设为免打扰的来源应用（如飞书）自动豁免保留原富文本
        _ = engine.adoptUserSuggestion("开启自动纯文本，在飞书里不要弹提示", in: .shared)
        XCTAssertTrue(engine.enabledAutoRules.contains(.stripRichTextFormatting))
        XCTAssertTrue(engine.shouldAutoStripRichFormatting(hasRichFormatting: true, sourceApp: "Google Chrome"))
        XCTAssertFalse(engine.shouldAutoStripRichFormatting(hasRichFormatting: true, sourceApp: "飞书"))
    }

    // MARK: - 29. 一行闪念速记（`> 备注 :: 正文`）零歧义解析与双角色动态模板（`{{date}} {{weekday}}`）测试

    func testQuickCaptureParserAndCrossRoleSnippetTemplateEngine() throws {
        // 1. 闪念速记与「备注 :: 正文」一步收藏拆解
        let c1 = try XCTUnwrap(QuickCaptureParser.parse(from: "> 下午4点找财务领发票"))
        XCTAssertNil(c1.customAlias)
        XCTAssertEqual(c1.bodyText, "下午4点找财务领发票")
        XCTAssertFalse(c1.defaultPin)

        let c2 = try XCTUnwrap(QuickCaptureParser.parse(from: "> 总部税号 :: 91310000MA1K88888X"))
        XCTAssertEqual(c2.customAlias, "总部税号")
        XCTAssertEqual(c2.bodyText, "91310000MA1K88888X")
        XCTAssertTrue(c2.defaultPin)

        let c3 = try XCTUnwrap(QuickCaptureParser.parse(from: "@新建 客服话术：：您好 {{clip}}，今日（{{date}} {{weekday}}）已为您寄出"))
        XCTAssertEqual(c3.customAlias, "客服话术")
        XCTAssertTrue(c3.defaultPin)

        // 2. 边界防误伤：区号手机号、代码 >= 符号与既有 @pin/@json 筛选词绝不误判为速记指令
        XCTAssertNil(QuickCaptureParser.parse(from: "+8613800138000"))
        XCTAssertNil(QuickCaptureParser.parse(from: "a >= b"))
        XCTAssertNil(QuickCaptureParser.parse(from: ">= 100"))
        XCTAssertNil(QuickCaptureParser.parse(from: "@pin"))
        XCTAssertNil(QuickCaptureParser.parse(from: "@json"))

        // 3. 双角色全量动态模板插值（含 {{date}}、{{weekday}}、{{clip}} 与 {{clip_redacted}}）
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 11
        comps.day = 23
        comps.hour = 9
        comps.minute = 30
        comps.second = 0
        let fixedMonday = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: comps))

        XCTAssertTrue(SnippetTemplateEngine.containsPlaceholders(c3.bodyText))
        let rendered = SnippetTemplateEngine.render(
            template: c3.bodyText,
            latestContextText: "王先生",
            referenceDate: fixedMonday
        )
        XCTAssertEqual(rendered, "您好 王先生，今日（2026-11-23 星期一）已为您寄出")
    }

    // MARK: - 30. 键鼠防冲突守卫（`PointerSelectionGuard`）、`⌥1~⌥6` 类目直达与历史资产原子自愈测试

    func testPointerSelectionGuardOptionTabsAndHistorySelfHealing() throws {
        // 1. 静止鼠标与微抖动绝不抢走面板唤起/键盘导航焦点；真实移动 >= 3.5pt 立即解锁接管
        var guardState = PointerSelectionGuard()
        XCTAssertFalse(guardState.isLocked)
        XCTAssertTrue(guardState.allowHoverSelection(currentMouseLocation: CGPoint(x: 300, y: 500), uptime: 1.0))

        guardState.lock(at: CGPoint(x: 300, y: 500), uptime: 10.0)
        XCTAssertTrue(guardState.isLocked)
        // 面板滑入或列表滚动经过静止光标（0 位移）与桌面光学微抖动（< 3.5pt）：严格抑制悬停抢焦点
        XCTAssertFalse(guardState.allowHoverSelection(currentMouseLocation: CGPoint(x: 300, y: 500), uptime: 10.25))
        XCTAssertFalse(guardState.allowHoverSelection(currentMouseLocation: CGPoint(x: 302, y: 501), uptime: 10.30))
        XCTAssertTrue(guardState.isLocked)

        // 用户真实移动鼠标（位移 5pt >= 3.5pt）：立即解锁放行
        XCTAssertTrue(guardState.allowHoverSelection(currentMouseLocation: CGPoint(x: 305, y: 500), uptime: 10.35))
        XCTAssertFalse(guardState.isLocked)

        // 鼠标物理点击直接解锁
        guardState.lock(at: CGPoint(x: 100, y: 100), uptime: 20.0)
        guardState.unlock()
        XCTAssertFalse(guardState.isLocked)

        // 2. ⌥1 ~ ⌥6 虚拟键码精确映射（特别验证 macOS kVK_ANSI_5=23 与 kVK_ANSI_6=22 顺序）
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(18), .all)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(19), .pinned)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(20), .text)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(21), .link)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(23), .image)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(22), .file)
        XCTAssertNil(ClipFilterTab.fromOptionKeyCode(26))

        // 3. 主 history.json 断电损坏时从 history.backup.json 零损自愈，并隔离损坏现场
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-selfheal-\(UUID().uuidString)", isDirectory: true)
        let imagesDir = tempDir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("history.json")
        let backupURL = tempDir.appendingPathComponent("history.backup.json")
        let corruptURL = tempDir.appendingPathComponent("history.corrupt.json")

        let pinnedItem = ClipItem(
            type: .text,
            text: "ssh prod-gateway",
            contentHash: "text:ssh",
            isPinned: true,
            customAlias: "生产网关"
        )
        let imageItem = ClipItem(
            type: .image,
            imageFileName: "referenced.png",
            contentHash: "img:ref"
        )
        HistoryPersistenceHelper.writeSnapshot([pinnedItem, imageItem], primaryURL: primaryURL, backupURL: backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        // 模拟异常截断损坏主文件
        try Data("{broken_json_eof".utf8).write(to: primaryURL)
        let healOutcome = HistoryPersistenceHelper.loadSnapshot(
            primaryURL: primaryURL,
            backupURL: backupURL,
            corruptURL: corruptURL
        )
        guard case .recoveredFromBackup(let recovered) = healOutcome else {
            return XCTFail("应当从原子备份无损自愈，实际结果：\(healOutcome)")
        }
        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(recovered.first?.customAlias, "生产网关")
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
        let healedReload = HistoryPersistenceHelper.loadSnapshot(
            primaryURL: primaryURL,
            backupURL: backupURL,
            corruptURL: corruptURL
        )
        XCTAssertEqual(healedReload, .loadedPrimary(recovered))

        // 4. 孤儿图片精准清理：保护活跃引用图片与 60s 内新写入图片，仅清理陈旧无主图片
        let now = Date()
        let refFile = imagesDir.appendingPathComponent("referenced.png")
        let freshUnrefFile = imagesDir.appendingPathComponent("inflight.png")
        let staleOrphanFile = imagesDir.appendingPathComponent("orphan.png")

        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: refFile)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: freshUnrefFile)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: staleOrphanFile)

        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: refFile.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10)], ofItemAtPath: freshUnrefFile.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-180)], ofItemAtPath: staleOrphanFile.path)

        let pruned = HistoryPersistenceHelper.pruneOrphanedImages(
            in: imagesDir,
            referencedFileNames: ["referenced.png"],
            minimumAgeSeconds: 60,
            now: now
        )
        XCTAssertEqual(pruned, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: refFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshUnrefFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleOrphanFile.path))
    }

    // MARK: - 31. 社媒分享口令剥壳提链（保护业务参数与配对括号）及终端 `路径:行列号` 访达解析测试

    @MainActor
    func testShareBlurbLinkExtractionAndLocalPathLineColResolution() throws {
        // 1. 小红书 / B站口令剥壳：自动在中文全角标点处截断，剥离追踪参数，严格保留分集 p=2 与小红书 xsec_token
        let xhsShare = "67 发布了一篇小红书笔记，快来看吧！😆 https://www.xiaohongshu.com/explore/66a1b2c3?xsec_token=KeepMe123&xhsshare=CopyLink&appuid=9988，复制本条信息，打开【小红书】App查看精彩内容！"
        XCTAssertEqual(
            URLTrackingCleaner.extractCleanShareURL(from: xhsShare),
            "https://www.xiaohongshu.com/explore/66a1b2c3?xsec_token=KeepMe123"
        )

        let biliShare = "【乔布斯产品演讲】 https://www.bilibili.com/video/BV1xx411c7mD/?p=2&spm_id_from=333.999&vd_source=abcdef123!"
        XCTAssertEqual(
            URLTrackingCleaner.extractCleanShareURL(from: biliShare),
            "https://www.bilibili.com/video/BV1xx411c7mD/?p=2"
        )

        // 2. 括号配对智能识别：剥除外层包裹括号，完整保留 Wikipedia 词条内部配对括号
        let wikiNote = "详见词条 (https://en.wikipedia.org/wiki/Swift_(programming_language))."
        XCTAssertEqual(
            URLTrackingCleaner.extractCleanShareURL(from: wikiNote),
            "https://en.wikipedia.org/wiki/Swift_(programming_language)"
        )

        // 3. 防误伤门控：Markdown 链接、JSON 字段与 cURL 命令绝不误触发分享口令剥壳
        XCTAssertNil(URLTrackingCleaner.extractCleanShareURL(from: "[iClip 官网](https://github.com/fanaruto/iClip)"))
        XCTAssertNil(URLTrackingCleaner.extractCleanShareURL(from: #"{"endpoint": "https://api.example.com/v1"}"#))
        XCTAssertNil(URLTrackingCleaner.extractCleanShareURL(from: "curl -s https://api.example.com/health"))

        // 4. 网盘链接 + 提取码混合文案：提取码与纯净链接双动作并存，且自动提链契约绝不误吞提取码消息
        let panShare = "通过网盘分享的文件：方案.pdf 链接：https://pan.baidu.com/s/1AbCdEf?utm_source=wechat 提取码：8829"
        let flowActions = MeetingAndEphemeralEngine.analyze(panShare)
        XCTAssertEqual(flowActions.map(\.id), ["otp-extract-code", "extract-share-url"])
        XCTAssertEqual(flowActions.last?.resultText, "https://pan.baidu.com/s/1AbCdEf")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-sharelink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let engine = AdaptiveIntelligenceEngine(customDirectoryURL: tempDir)
        _ = engine.adoptUserSuggestion("开启分享口令自动提取链接", in: .shared)
        XCTAssertTrue(engine.enabledAutoRules.contains(.extractCleanShareLink))
        XCTAssertEqual(
            engine.applyLearnedAutoTextRuleIfEnabled(rawText: biliShare, isLink: false)?.text,
            "https://www.bilibili.com/video/BV1xx411c7mD/?p=2"
        )
        // 含提取码/验证码的网盘消息不自动覆写，防止丢失提取码
        XCTAssertNil(engine.applyLearnedAutoTextRuleIfEnabled(rawText: panShare, isLink: false))

        // 5. 终端 / 编译器 `路径:行:列` 与 `file://...#L行号` 本地真实文件解析（支撑 ⌘O 访达高亮定位）
        let realFile = tempDir.appendingPathComponent("SampleSource.swift")
        try Data("struct Sample {}".utf8).write(to: realFile)

        let compilerDiag = "\(realFile.path):128:14"
        XCTAssertEqual(URLTrackingCleaner.resolveExistingLocalFileURL(from: compilerDiag)?.path, realFile.path)

        let fileURIWithAnchor = "file://\(realFile.path)#L10-L25"
        XCTAssertEqual(URLTrackingCleaner.resolveExistingLocalFileURL(from: fileURIWithAnchor)?.path, realFile.path)
    }

    // MARK: - 32. 原位剪贴差异对比引擎（`ClipboardDiffEngine` 行级 LCS、上下文折叠与 JSON 语义对齐）测试

    @MainActor
    func testClipboardDiffEngineContextCollapseAndJSONAlignment() throws {
        // 1. 多行配置修改：长公共前缀自动折叠，改动行严格按 `- 旧行` → `+ 新行` 呈现
        let oldConfig = (1...10).map { "line_\($0) = ok" }.joined(separator: "\n") + "\nport = 8080\nhost = localhost"
        let newConfig = (1...10).map { "line_\($0) = ok" }.joined(separator: "\n") + "\nport = 9090\nhost = localhost"

        let diff = try XCTUnwrap(ClipboardDiffEngine.computeDiff(older: oldConfig, newer: newConfig, contextLines: 2))
        XCTAssertEqual(diff.addedCount, 1)
        XCTAssertEqual(diff.removedCount, 1)
        XCTAssertFalse(diff.isJSONNormalized)
        XCTAssertEqual(diff.rows.first, .collapsedContext(hiddenLineCount: 8))
        XCTAssertTrue(diff.unifiedPatchText.contains("- port = 8080\n+ port = 9090"))

        // 2. 乱序与压缩 JSON 智能对齐：键值完全相同时精准给出「语义一致」，有字段变化时仅高亮真实差异行
        let jsonCompact = #"{"user":{"role":"guest","id":101},"code":0}"#
        let jsonReorderedPretty = "{\n  \"code\": 0,\n  \"user\": {\n    \"id\": 101,\n    \"role\": \"guest\"\n  }\n}"
        let semanticSame = try XCTUnwrap(ClipboardDiffEngine.computeDiff(older: jsonCompact, newer: jsonReorderedPretty))
        XCTAssertTrue(semanticSame.isJSONNormalized)
        XCTAssertFalse(semanticSame.hasChanges)
        XCTAssertEqual(semanticSame.tabBadgeTitle, "对比 #1 (语义一致)")

        let jsonUpdated = #"{"code":0,"user":{"id":101,"role":"admin"}}"#
        let jsonDiff = try XCTUnwrap(ClipboardDiffEngine.computeDiff(older: jsonCompact, newer: jsonUpdated))
        XCTAssertTrue(jsonDiff.isJSONNormalized)
        XCTAssertEqual(jsonDiff.addedCount, 1)
        XCTAssertEqual(jsonDiff.removedCount, 1)
        XCTAssertTrue(jsonDiff.unifiedPatchText.contains("-     \"role\" : \"guest\""))
        XCTAssertTrue(jsonDiff.unifiedPatchText.contains("+     \"role\" : \"admin\""))

        // 3. Space 与 ⌥Space 默认页签路由：普通文本按 Space 仍默认看原文，按 ⌥Space 直达对比页
        let plainItem = ClipItem(type: .text, text: oldConfig, contentHash: "text:cfg")
        let mockTabs = [
            QuickLookTabItem(id: "raw", title: "原始文本", payload: .text(oldConfig), toast: "", supportsSaveBack: true),
            QuickLookTabItem(id: QuickLookTabItem.diffLatestTabID, title: diff.tabBadgeTitle, payload: .text(diff.unifiedPatchText), toast: "", supportsSaveBack: false, diffResult: diff)
        ]
        XCTAssertEqual(QuickLookTabBuilder.defaultTabIndex(for: plainItem, tabs: mockTabs, preferDiff: false), 0)
        XCTAssertEqual(QuickLookTabBuilder.defaultTabIndex(for: plainItem, tabs: mockTabs, preferDiff: true), 1)
    }

    // MARK: - 33. 剪贴板金额免重敲续算（`* 13%` / `/ (1 + 6%)`）与百分号/取模消歧及手机号防误伤测试

    func testContextualClipboardMathPercentageAndPhoneNumberGuard() throws {
        // 1. 刚复制带货币符/千分位金额后，直接敲 `* 13%` 免重敲算出税额与会计大写
        let vat = try XCTUnwrap(InstantMathEvaluator.evaluate("* 13%", latestClipboardText: "¥12,800.00"))
        XCTAssertEqual(vat.plainValue, "1664")
        XCTAssertEqual(vat.formattedThousands, "1,664")
        XCTAssertEqual(vat.rmbUppercase, "壹仟陆佰陆拾肆元整")
        XCTAssertTrue(vat.isExplicitOrContextual)

        // 2. 括号内百分比与二元取模智能消歧：`1060 / (1 + 6%) = 1000`，同时 `17 % 5 = 2` 严格保留
        let taxExcl = try XCTUnwrap(InstantMathEvaluator.evaluate("/ (1 + 6%)", latestClipboardText: "1060元"))
        XCTAssertEqual(taxExcl.plainValue, "1000")

        let modulo = try XCTUnwrap(InstantMathEvaluator.evaluate("17 % 5"))
        XCTAssertEqual(modulo.plainValue, "2")

        // 3. 中文「万 / 亿」与货币符号直算
        let annual = try XCTUnwrap(InstantMathEvaluator.evaluate("3.5万 * 12"))
        XCTAssertEqual(annual.plainValue, "420000")
        XCTAssertEqual(annual.formattedThousands, "420,000")

        // 4. 防误伤门控：首条剪贴是 11 位手机号时绝不误当金额续算；本地路径 `/Users/...` 与 `+86...` 绝不误触发算式
        XCTAssertNil(InstantMathEvaluator.evaluate("* 2", latestClipboardText: "13800138000"))
        XCTAssertNil(InstantMathEvaluator.evaluate("/Users/fanaruto/Desktop", latestClipboardText: "12800"))
        XCTAssertNil(InstantMathEvaluator.evaluate("+8613800138000", latestClipboardText: "500"))
    }

    // MARK: - 34. 百分号编码中文 URL 可读展示/拼音检索与拖拽即成文件（SVG/JSON/MD/可读截图名）测试

    func testPercentEncodedChineseURLSearchAndDragFileMaterialization() throws {
        // 1. 浏览器复制的百分号编码中文 URL：卡片直显可读中文、支持中文与拼音首字母盲搜，且不篡改底层原始 URL
        let encodedWiki = "https://zh.wikipedia.org/wiki/%E7%AC%AC%E4%B8%80%E6%80%A7%E5%8E%9F%E7%90%86"
        let linkItem = ClipItem(type: .link, text: encodedWiki, contentHash: "link:wiki")
        XCTAssertEqual(linkItem.primaryTitle, "https://zh.wikipedia.org/wiki/第一性原理")
        XCTAssertEqual(linkItem.text, encodedWiki)
        XCTAssertTrue(linkItem.matches(query: "第一性原理"))
        XCTAssertTrue(linkItem.matches(query: "dyxyl"))

        // 2. 文本与代码拖拽类型智能推断（SVG / JSON / Markdown / CSV / Shell）与可读命名
        let svgText = #"<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><circle cx="12" cy="12" r="10"/></svg>"#
        let svgSpec = DragFileExportHelper.inferTextArtifactSpec(for: svgText)
        XCTAssertEqual(svgSpec.ext, "svg")

        let jsonItem = ClipItem(
            type: .text,
            text: #"{"status":"ok","items":[1,2,3]}"#,
            contentHash: "text:json",
            customAlias: "订单接口示例"
        )
        let tempExportDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-dragexport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempExportDir) }

        let jsonExported = try XCTUnwrap(DragFileExportHelper.materializeExportFile(for: jsonItem, exportDirectory: tempExportDir))
        XCTAssertEqual(jsonExported.url.lastPathComponent, "订单接口示例.json")
        XCTAssertEqual(try String(contentsOf: jsonExported.url, encoding: .utf8), jsonItem.text)

        let mdItem = ClipItem(
            type: .text,
            text: "# 产品周会纪要\n\n- 完成性能优化\n- 发布新版本",
            contentHash: "text:md"
        )
        let mdExported = try XCTUnwrap(DragFileExportHelper.materializeExportFile(for: mdItem, exportDirectory: tempExportDir))
        XCTAssertEqual(mdExported.url.lastPathComponent, "产品周会纪要.md")

        // 3. 截图拖出告别乱码 UUID，优先采用用户备注名建立零拷贝导出文件
        let rawImgURL = tempExportDir.appendingPathComponent("97c87fcd-4a7e-4150-ba16-5d9852cf7b3.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: rawImgURL)
        let imgItem = ClipItem(
            type: .image,
            imageFileName: rawImgURL.lastPathComponent,
            contentHash: "img:lic",
            customAlias: "深圳公司营业执照"
        )
        let imgExported = try XCTUnwrap(DragFileExportHelper.materializeExportFile(
            for: imgItem,
            sourceImageURL: rawImgURL,
            exportDirectory: tempExportDir
        ))
        XCTAssertEqual(imgExported.url.lastPathComponent, "深圳公司营业执照.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imgExported.url.path))
    }

    // MARK: - 35. 跨语言应用别名与模态同义词盲搜（`vscode`/`wechat`/`浏览器`/`终端`/`截图`）及备注智能归类测试

    func testCrossLanguageAppSynonymSearchAndPinCategoryInference() throws {
        // 1. macOS 应用进程名与人类直觉搜索词双向映射（Code ↔ vscode、微信 ↔ wechat、iTerm2 ↔ 终端、Chrome ↔ 浏览器）
        let vscodeSnippet = ClipItem(type: .text, text: "const api = '/v1/users'", contentHash: "text:vsc", sourceAppName: "Code")
        XCTAssertTrue(vscodeSnippet.matches(query: "vscode"))
        XCTAssertTrue(vscodeSnippet.matches(query: "ide api"))

        let wechatAddr = ClipItem(type: .text, text: "南山区科技园 18 号", contentHash: "text:wx", sourceAppName: "微信")
        XCTAssertTrue(wechatAddr.matches(query: "wechat 科技园"))
        XCTAssertTrue(wechatAddr.matches(query: "聊天 南山"))

        let ghosttyCmd = ClipItem(type: .text, text: "ssh root@10.0.0.8", contentHash: "text:ssh", sourceAppName: "Ghostty")
        XCTAssertTrue(ghosttyCmd.matches(query: "终端 ssh"))
        XCTAssertTrue(ghosttyCmd.matches(query: "shell 10.0.0.8"))

        let chromeQuote = ClipItem(type: .text, text: "Stay hungry, stay foolish", contentHash: "text:quote", sourceAppName: "Google Chrome")
        XCTAssertTrue(chromeQuote.matches(query: "浏览器 hungry"))

        let shotItem = ClipItem(type: .image, imageFileName: "a.png", ocrText: "增值税电子普通发票", contentHash: "img:inv")
        XCTAssertTrue(shotItem.matches(query: "截图 发票"))
        XCTAssertTrue(shotItem.matches(query: "img 电子"))

        // 2. 备注命名自动推断收藏分组（开票财务 / 地址名片 / 常用话术 / 合同模板，普通备注保持 nil 不乱打标）
        XCTAssertEqual(PinCategory.infer(alias: "深圳总部开票税号", text: "91440300MA5F88888X"), .invoice)
        XCTAssertEqual(PinCategory.infer(alias: "公司前台收货地址", text: "深圳市南山区..."), .contact)
        XCTAssertEqual(PinCategory.infer(alias: "售后安抚客服话术", text: "非常抱歉给您带来不便"), .reply)
        XCTAssertEqual(PinCategory.infer(alias: "日报通知", text: "今日日期 {{date}}"), .template)
        XCTAssertNil(PinCategory.infer(alias: "生产跳板机命令", text: "ssh jump-prod"))
    }

    // MARK: - 36. IDE/终端语法高亮剪贴零误扰抑制、原子临时件自洁与数字顺位键码映射

    @MainActor
    func testIDECodeRichCopySparkSuppressionAndDigitKeyCodeMapping() throws {
        // 1. IDE 与终端默认附带 HTML/RTF 时不误触发「去样式」微星标，而浏览器富文本照常提供微星标
        let htmlTypes: [NSPasteboard.PasteboardType] = [.string, .html]
        XCTAssertFalse(RichTextPasteboardHelper.shouldOfferRichStripSpark(
            types: htmlTypes,
            plainText: "let answer = 42",
            sourceApp: "Antigravity"
        ))
        XCTAssertFalse(RichTextPasteboardHelper.shouldOfferRichStripSpark(
            types: htmlTypes + [NSPasteboard.PasteboardType("vscode-editor-data")],
            plainText: "function hello() {}",
            sourceApp: "UnknownForkIDE"
        ))
        XCTAssertFalse(RichTextPasteboardHelper.shouldOfferRichStripSpark(
            types: htmlTypes,
            plainText: "git status -s",
            sourceApp: "Ghostty"
        ))
        XCTAssertTrue(RichTextPasteboardHelper.shouldOfferRichStripSpark(
            types: htmlTypes,
            plainText: "这是一段来自网页博客带背景底色的文章段落",
            sourceApp: "Google Chrome"
        ))

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-ide-spark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let engine = AdaptiveIntelligenceEngine(customDirectoryURL: tempDir)

        let idePlainItem = ClipItem(type: .text, text: "普通对话或代码片段", contentHash: "text:ide1", sourceAppName: "Cursor")
        XCTAssertNil(engine.evaluateSparkCandidate(for: idePlainItem, reuseCount: 1, minimalMode: false, hasRichFormatting: true))

        let browserRichItem = ClipItem(type: .text, text: "网页花哨样式文本", contentHash: "text:web1", sourceAppName: "Safari")
        let webSpark = engine.evaluateSparkCandidate(for: browserRichItem, reuseCount: 1, minimalMode: false, hasRichFormatting: true)
        XCTAssertEqual(webSpark?.actionID, "strip-rich-style")

        // 2. Foundation 原子写入残留 .sb-* 临时文件过期清理（保护新文件与正常 history.json）
        let historyFile = tempDir.appendingPathComponent("history.json")
        let staleTemp = tempDir.appendingPathComponent("history.json.sb-c149ea9b-Kw9zqw")
        try Data("[]".utf8).write(to: historyFile)
        try Data("stale".utf8).write(to: staleTemp)
        let removed = HistoryPersistenceHelper.pruneStaleAtomicTempFiles(
            in: tempDir,
            minimumAgeSeconds: 300,
            now: Date().addingTimeInterval(600)
        )
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTemp.path))

        // 3. 硬件数字键 1...9 精确映射（兼容 ⌘1~9 / ⌥⌘1~9 / ⇧⌘1~9）
        XCTAssertEqual(ClipFilterTab.digitFromKeyCode(18), 1)
        XCTAssertEqual(ClipFilterTab.digitFromKeyCode(23), 5)
        XCTAssertEqual(ClipFilterTab.digitFromKeyCode(25), 9)
        XCTAssertNil(ClipFilterTab.digitFromKeyCode(29))
    }

    // MARK: - 37. 全局快捷键多层级冲突检测与硬性拒绝设定保护

    func testHotKeyConflictDetectionAndHardBlocking() {
        let own = HotKeyShortcut.defaultShortcut // ⌥ V
        let others: [(shortcut: HotKeyShortcut, label: String)] = [
            (.defaultQueueShortcut, "顺序出队热键"),
            (.defaultCopyAppendShortcut, "跨处续接复制")
        ]

        // 1. 无修饰键或仅 Shift 搭配普通字符必须硬拦截（F1~F12 功能键除外）
        let bareV = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: 0)
        XCTAssertNotNil(HotKeyConflictValidator.staticConflictReason(for: bareV, role: .mainToggle, existingOwnShortcut: own, otherBindings: others))

        let shiftOnlyA = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(shiftKey))
        XCTAssertNotNil(HotKeyConflictValidator.staticConflictReason(for: shiftOnlyA, role: .mainToggle, existingOwnShortcut: own, otherBindings: others))

        let shiftF6 = HotKeyShortcut(keyCode: UInt32(kVK_F6), carbonModifiers: UInt32(shiftKey))
        XCTAssertNil(HotKeyConflictValidator.staticConflictReason(for: shiftF6, role: .mainToggle, existingOwnShortcut: own, otherBindings: others))

        // 2. macOS 系统核心基础快捷键硬拦截（⌘C / ⌘V / ⌘Space / ⌃Space / ⇧⌘4 / ⌘Q）
        let cmdC = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey))
        XCTAssertTrue(HotKeyConflictValidator.staticConflictReason(for: cmdC, role: .mainToggle, existingOwnShortcut: own, otherBindings: others)?.contains("复制") == true)

        let cmdSpace = HotKeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey))
        XCTAssertTrue(HotKeyConflictValidator.staticConflictReason(for: cmdSpace, role: .mainToggle, existingOwnShortcut: own, otherBindings: others)?.contains("Spotlight") == true)

        let ctrlSpace = HotKeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey))
        XCTAssertNotNil(HotKeyConflictValidator.staticConflictReason(for: ctrlSpace, role: .mainToggle, existingOwnShortcut: own, otherBindings: others))

        let shiftCmd4 = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey | shiftKey))
        XCTAssertNotNil(HotKeyConflictValidator.staticConflictReason(for: shiftCmd4, role: .mainToggle, existingOwnShortcut: own, otherBindings: others))

        // 3. 应用内部其他全局槽位与面板内置快捷键冲突硬拦截（⌃⌥C / ⌃⌥V / ⌘P / ⌥1 / ⌥Space）
        XCTAssertTrue(HotKeyConflictValidator.staticConflictReason(for: .defaultCopyAppendShortcut, role: .mainToggle, existingOwnShortcut: own, otherBindings: others)?.contains("跨处续接复制") == true)
        XCTAssertTrue(HotKeyConflictValidator.staticConflictReason(for: .defaultQueueShortcut, role: .mainToggle, existingOwnShortcut: own, otherBindings: others)?.contains("顺序出队") == true)

        let cmdP = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(cmdKey))
        XCTAssertNotNil(HotKeyConflictValidator.staticConflictReason(for: cmdP, role: .mainToggle, existingOwnShortcut: own, otherBindings: others))

        let opt1 = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: UInt32(optionKey))
        XCTAssertNotNil(HotKeyConflictValidator.staticConflictReason(for: opt1, role: .mainToggle, existingOwnShortcut: own, otherBindings: others))

        // 4. 当前自身原快捷键（⌥V）与无冲突自定义组合键（⇧⌘V / ⌃⌥X / ⌥Z）正常放行
        XCTAssertNil(HotKeyConflictValidator.staticConflictReason(for: own, role: .mainToggle, existingOwnShortcut: own, otherBindings: others))

        let shiftCmdV = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey))
        XCTAssertNil(HotKeyConflictValidator.staticConflictReason(for: shiftCmdV, role: .mainToggle, existingOwnShortcut: own, otherBindings: others))

        let optZ = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Z), carbonModifiers: UInt32(optionKey))
        XCTAssertNil(HotKeyConflictValidator.staticConflictReason(for: optZ, role: .mainToggle, existingOwnShortcut: own, otherBindings: others))
    }

    // MARK: - 38. 单键双击（⌘ / ⌥ / ⌃ / ⇧ / Fn）零误触状态机、JSON 兼容与冲突拦截测试

    func testSingleModifierDoubleTapStateMachineAndConflictGuard() throws {
        var machine = ModifierDoubleTapStateMachine(maxHoldDuration: 0.30, maxTapGap: 0.34)

        // 1. 干净双击左 Command (keyCode 55) -> 第一次松开返回 firstTapCompleted，第二次松开返回 doubleTapTriggered
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 55, flags: .command, uptime: 10.00), .none)
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 55, flags: [], uptime: 10.08), .firstTapCompleted(.command))
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 55, flags: .command, uptime: 10.20), .none)
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 55, flags: [], uptime: 10.28), .doubleTapTriggered(.command))

        // 2. 期间夹杂普通按键（如连按 ⌘C -> ⌘V 或 ⌘C×2 微星标）必须 100% 静默作废，绝不误弹面板
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 55, flags: .command, uptime: 20.00), .none)
        machine.markInterferingEvent() // 按下了 C
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 55, flags: [], uptime: 20.09), .none)
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 55, flags: .command, uptime: 20.18), .none)
        machine.markInterferingEvent() // 按下了 V
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 55, flags: [], uptime: 20.26), .none)

        // 3. 长按超过 maxHoldDuration (0.30s) 或左右不同物理键混按不误触发
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 58, flags: .option, uptime: 30.00), .none)
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 58, flags: [], uptime: 30.45), .none) // 长按作废

        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 55, flags: .command, uptime: 40.00), .none)
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 55, flags: [], uptime: 40.08), .firstTapCompleted(.command))
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 54, flags: .command, uptime: 40.18), .none) // 右 Command (54) != 左 Command (55)
        XCTAssertEqual(machine.handleFlagsChanged(keyCode: 54, flags: [], uptime: 40.25), .firstTapCompleted(.command))

        // 4. 旧版无 doubleTapModifier 字段的持久化 JSON 无损解码兼容 + 双击单键槽位查重硬拦截
        let legacyJSON = Data(#"{"keyCode":9,"carbonModifiers":2048}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(HotKeyShortcut.self, from: legacyJSON)
        XCTAssertEqual(decodedLegacy, .defaultShortcut)
        XCTAssertFalse(decodedLegacy.isDoubleTap)

        let doubleCtrl = HotKeyShortcut.doubleTap(.control)
        XCTAssertEqual(doubleCtrl.displayString, "双击 ⌃")
        XCTAssertEqual(doubleCtrl.compactDisplayString, "⌃⌃")
        let conflictWithQueue = HotKeyConflictValidator.staticConflictReason(
            for: doubleCtrl,
            role: .mainToggle,
            existingOwnShortcut: .defaultShortcut,
            otherBindings: [(doubleCtrl, "顺序出队热键")]
        )
        XCTAssertTrue(conflictWithQueue?.contains("顺序出队热键") == true)
    }

    // MARK: - 39. 液态玻璃四角无毛边出血容器点击穿透与连续圆角遮罩校验

    @MainActor
    func testLiquidGlassBleedRootHitTestAndCornerMask() {
        let bleed: CGFloat = 36
        let cardFrame = NSRect(x: bleed, y: bleed, width: 420, height: 560)
        let windowBounds = NSRect(x: 0, y: 0, width: 492, height: 632)
        let bleedRoot = LiquidGlassBleedRootView(frame: windowBounds, cardFrame: cardFrame)
        let cardChild = NSView(frame: cardFrame)
        bleedRoot.addSubview(cardChild)

        // 出血边距区域内点击必须 100% 穿透返回 nil，卡片内部正常命中
        XCTAssertNil(bleedRoot.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertNil(bleedRoot.hitTest(NSPoint(x: 485, y: 625)))
        XCTAssertNil(bleedRoot.hitTest(NSPoint(x: 35, y: 300)))
        XCTAssertEqual(bleedRoot.hitTest(NSPoint(x: 200, y: 300)), cardChild)

        // 连续圆角遮罩四角外缘必须为全透明（Alpha = 0），中心必须不透明（Alpha = 1）
        let mask = LiquidGlassSurfaceHost.continuousCornerMaskImage(size: NSSize(width: 120, height: 120), radius: 26)
        guard let rep = mask.representations.first as? NSBitmapImageRep else {
            XCTFail("应生成高清位图遮罩表示")
            return
        }
        XCTAssertEqual(rep.colorAt(x: 1, y: 1)?.alphaComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(rep.colorAt(x: rep.pixelsWide - 2, y: rep.pixelsHigh - 2)?.alphaComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0, 1, accuracy: 0.001)
    }
}
