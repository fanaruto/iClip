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
}
