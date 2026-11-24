import Foundation
import AppKit
import CryptoKit

/// 单条可跨机迁移的收藏知识资产快照（自包含文本、链接、动态模板、分组槽、备注名及内嵌图片数据）
struct ArchivedClipEntry: Codable, Equatable {
    let type: ClipContentType
    let text: String?
    let imageWidth: Int?
    let imageHeight: Int?
    let ocrText: String?
    let embeddedPNGBase64: String?
    let filePaths: [String]?
    let contentHash: String
    let sourceAppName: String?
    let createdAt: Date
    let pinCategory: PinCategory?
    let customAlias: String?
    let isTodoItem: Bool?

    init(
        type: ClipContentType,
        text: String?,
        imageWidth: Int?,
        imageHeight: Int?,
        ocrText: String?,
        embeddedPNGBase64: String?,
        filePaths: [String]?,
        contentHash: String,
        sourceAppName: String?,
        createdAt: Date,
        pinCategory: PinCategory?,
        customAlias: String?,
        isTodoItem: Bool? = nil
    ) {
        self.type = type
        self.text = text
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.ocrText = ocrText
        self.embeddedPNGBase64 = embeddedPNGBase64
        self.filePaths = filePaths
        self.contentHash = contentHash
        self.sourceAppName = sourceAppName
        self.createdAt = createdAt
        self.pinCategory = pinCategory
        self.customAlias = customAlias
        self.isTodoItem = isTodoItem
    }
}

/// `.iclip` 收藏资产归档包根结构（双角色 100% 互通）
struct PinnedArchiveBundle: Codable, Equatable {
    static let formatIdentifier = "com.qingjian.iclip.archive"
    static let currentSchemaVersion = 1

    let format: String
    let schemaVersion: Int
    let appVersion: String
    let exportedEdition: String
    let exportedAt: Date
    let entries: [ArchivedClipEntry]
}

/// 归档导入结果统计（兼容原生 `.iclip` 与 Raycast / Maccy / Paste / CSV 跨软件搬家）
struct ArchiveImportSummary: Equatable {
    let importedNewCount: Int
    let updatedExistingCount: Int
    let totalInBundle: Int
    let sourceFormatLabel: String

    init(
        importedNewCount: Int,
        updatedExistingCount: Int,
        totalInBundle: Int,
        sourceFormatLabel: String = "iClip 归档"
    ) {
        self.importedNewCount = importedNewCount
        self.updatedExistingCount = updatedExistingCount
        self.totalInBundle = totalInBundle
        self.sourceFormatLabel = sourceFormatLabel
    }
}

/// 归档导入导出错误类型
enum ArchiveBackupError: LocalizedError, Equatable {
    case noPinnedItems
    case archiveTooLarge
    case invalidArchiveFormat
    case unsupportedSchemaVersion(Int)
    case passphraseRequiredOrIncorrect

    var errorDescription: String? {
        switch self {
        case .noPinnedItems:
            return "当前暂无已收藏的记录，请先点击卡片收藏常用话术或模板"
        case .archiveTooLarge:
            return "归档文件体积超过 64 MB 安全上限，已拒绝加载以保护内存稳定"
        case .invalidArchiveFormat:
            return "无法解析该文件，请选择有效的 .iclip 归档或 Raycast / Maccy / CSV 常用语文件"
        case .unsupportedSchemaVersion(let ver):
            return "该归档包版本 (v\(ver)) 高于当前客户端，请先检查更新升级 iClip"
        case .passphraseRequiredOrIncorrect:
            return "加密归档口令不正确或已取消解锁"
        }
    }
}

/// 置顶收藏话术 / 模板 / 常用图片自包含离线归档与无损合并引擎
enum ArchiveBackupService {
    /// 单张内嵌图片体积上限（12 MB），防止异常超大文件撑爆归档包
    private static let maxEmbeddedImageBytes = 12 * 1024 * 1024
    /// 外部导入文件总体积硬上限（64 MB）与单包最大条目数（5,000 条），防御恶意 JSON 内存炸弹
    static let maxArchiveInputBytes = 64 * 1024 * 1024
    private static let maxArchiveEntryCount = 5_000

    /// 将当前历史列表中的所有 `isPinned == true` 记录打包编码为 `.iclip` Data
    static func exportPinnedArchiveData(
        from items: [ClipItem],
        imagesDirectoryURL: URL,
        appVersion: String = AppRoleEdition.currentVersionString,
        editionKey: String = AppRoleEdition.installed.rawValue
    ) throws -> Data {
        let pinnedItems = items.filter { $0.isPinned }
        guard !pinnedItems.isEmpty else {
            throw ArchiveBackupError.noPinnedItems
        }

        let entries: [ArchivedClipEntry] = pinnedItems.map { item in
            var base64PNG: String? = nil
            if item.type == .image, let fileName = item.imageFileName {
                let safeName = (fileName as NSString).lastPathComponent
                if !safeName.isEmpty && safeName != "." && safeName != ".." && safeName == fileName {
                    let imgURL = imagesDirectoryURL.appendingPathComponent(safeName)
                    if let imgData = LocalVaultCrypto.readDecryptedImageData(at: imgURL),
                       imgData.count <= maxEmbeddedImageBytes {
                        base64PNG = imgData.base64EncodedString()
                    }
                }
            }
            return ArchivedClipEntry(
                type: item.type,
                text: item.text,
                imageWidth: item.imageWidth,
                imageHeight: item.imageHeight,
                ocrText: item.ocrText,
                embeddedPNGBase64: base64PNG,
                filePaths: item.filePaths,
                contentHash: item.contentHash,
                sourceAppName: item.sourceAppName,
                createdAt: item.createdAt,
                pinCategory: item.pinCategory,
                customAlias: item.customAlias,
                isTodoItem: item.isTodoItem
            )
        }

        let bundle = PinnedArchiveBundle(
            format: PinnedArchiveBundle.formatIdentifier,
            schemaVersion: PinnedArchiveBundle.currentSchemaVersion,
            appVersion: appVersion,
            exportedEdition: editionKey,
            exportedAt: Date(),
            entries: entries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    /// 导出带可选口令加密（AES-256-GCM）的 `.iclip` 收藏包
    static func exportPinnedArchiveData(
        from items: [ClipItem],
        imagesDirectoryURL: URL,
        passphrase: String?,
        appVersion: String = AppRoleEdition.currentVersionString,
        editionKey: String = AppRoleEdition.installed.rawValue
    ) throws -> Data {
        let plain = try exportPinnedArchiveData(
            from: items,
            imagesDirectoryURL: imagesDirectoryURL,
            appVersion: appVersion,
            editionKey: editionKey
        )
        guard let pw = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines), !pw.isEmpty else {
            return plain
        }
        guard let encrypted = LocalVaultCrypto.sealArchiveWithPassphrase(plain, passphrase: pw) else {
            throw ArchiveBackupError.invalidArchiveFormat
        }
        return encrypted
    }

    /// 解码 `.iclip`（含口令加密版）或外部竞品常用语文件（Raycast / Maccy / Paste / CSV），执行非破坏性去重合并
    static func mergeArchiveData(
        _ data: Data,
        into existingItems: [ClipItem],
        imagesDirectoryURL: URL,
        passphrase: String? = nil,
        fileExtensionHint: String? = nil
    ) throws -> (mergedItems: [ClipItem], summary: ArchiveImportSummary) {
        guard data.count <= maxArchiveInputBytes else {
            throw ArchiveBackupError.archiveTooLarge
        }
        let effectiveData: Data
        if LocalVaultCrypto.isEncryptedArchive(data) {
            guard let pw = passphrase, !pw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let opened = LocalVaultCrypto.openEncryptedArchive(data, passphrase: pw) else {
                throw ArchiveBackupError.passphraseRequiredOrIncorrect
            }
            guard opened.count <= maxArchiveInputBytes else {
                throw ArchiveBackupError.archiveTooLarge
            }
            effectiveData = opened
        } else {
            effectiveData = data
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let bundle: PinnedArchiveBundle
        if let decodedBundle = try? decoder.decode(PinnedArchiveBundle.self, from: effectiveData),
           decodedBundle.format == PinnedArchiveBundle.formatIdentifier {
            bundle = decodedBundle
        } else if let external = UniversalCompetitorImporter.parseExternalData(effectiveData, fileExtensionHint: fileExtensionHint) {
            return mergeExternalCompetitorCandidates(
                external.entries,
                formatLabel: external.formatName,
                into: existingItems
            )
        } else if let probe = try? decoder.decode(PinnedArchiveBundle.self, from: effectiveData),
                  probe.format != PinnedArchiveBundle.formatIdentifier {
            throw ArchiveBackupError.invalidArchiveFormat
        } else {
            throw ArchiveBackupError.invalidArchiveFormat
        }

        guard bundle.schemaVersion <= PinnedArchiveBundle.currentSchemaVersion else {
            throw ArchiveBackupError.unsupportedSchemaVersion(bundle.schemaVersion)
        }

        try? FileManager.default.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)

        var working = existingItems
        var importedNew = 0
        var updatedExisting = 0

        for entry in bundle.entries.prefix(maxArchiveEntryCount) {
            if let existingIdx = working.firstIndex(where: { $0.contentHash == entry.contentHash }) {
                var current = working[existingIdx]
                var didChange = false

                if !current.isPinned {
                    current.isPinned = true
                    didChange = true
                }
                if entry.isTodoItem == true && !current.isTodo {
                    current.isTodo = true
                    didChange = true
                }
                if current.pinCategory == nil, let cat = entry.pinCategory {
                    current.pinCategory = cat
                    didChange = true
                }
                if (current.customAlias?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                   let alias = entry.customAlias, !alias.isEmpty {
                    current.customAlias = alias
                    didChange = true
                }
                if (current.ocrText?.isEmpty ?? true), let ocr = entry.ocrText, !ocr.isEmpty {
                    current.ocrText = ocr
                    current.ocrChecked = true
                    didChange = true
                }
                // 若本地图片文件缺失但归档内有内嵌 PNG，校验体积上限与图像魔数后安全修复落盘
                if current.type == .image,
                   let base64 = entry.embeddedPNGBase64,
                   base64.utf8.count <= (maxEmbeddedImageBytes * 4 / 3 + 64),
                   let pngData = Data(base64Encoded: base64),
                   pngData.count <= maxEmbeddedImageBytes,
                   isValidRasterImageHeader(pngData) {
                    let missingLocalFile: Bool = {
                        guard let name = current.imageFileName else { return true }
                        return !FileManager.default.fileExists(atPath: imagesDirectoryURL.appendingPathComponent(name).path)
                    }()
                    if missingLocalFile {
                        let restoredName = "\(UUID().uuidString).png"
                        let targetURL = imagesDirectoryURL.appendingPathComponent(restoredName)
                        if (try? LocalVaultCrypto.writeEncryptedImage(pngData, to: targetURL)) != nil {
                            current.imageFileName = restoredName
                            didChange = true
                        }
                    }
                }

                if didChange {
                    working[existingIdx] = current
                    updatedExisting += 1
                }
            } else {
                var savedImageName: String? = nil
                if entry.type == .image {
                    guard let base64 = entry.embeddedPNGBase64,
                          base64.utf8.count <= (maxEmbeddedImageBytes * 4 / 3 + 64),
                          let pngData = Data(base64Encoded: base64),
                          pngData.count <= maxEmbeddedImageBytes,
                          isValidRasterImageHeader(pngData) else {
                        // 无可用合法内嵌图片数据或超限的图片记录跳过，防止内存炸弹与坏死空图
                        continue
                    }
                    let fileName = "\(UUID().uuidString).png"
                    let fileURL = imagesDirectoryURL.appendingPathComponent(fileName)
                    do {
                        try LocalVaultCrypto.writeEncryptedImage(pngData, to: fileURL)
                        savedImageName = fileName
                    } catch {
                        continue
                    }
                }

                if entry.type == .file {
                    if let paths = entry.filePaths {
                        let hasTraversal = paths.contains { $0.contains("..") }
                        if hasTraversal || FileAndLinkSecurityGuard.classifyFilePaths(paths) != nil {
                            // 拒绝跨机归档注入含 `..` 路径穿越或指向私钥/凭据的敏感本地路径
                            continue
                        }
                    }
                }

                let sanitizedEntryText: String? = entry.text.map { rawText in
                    if case .pastejackingOrBidi = ClipboardPoisonGuard.inspect(rawText) {
                        let clean = ClipboardPoisonGuard.sanitize(rawText)
                        return clean.isEmpty ? rawText : clean
                    }
                    return rawText
                }
                let sanitizedEntryAlias: String? = entry.customAlias.map { rawAlias in
                    if case .pastejackingOrBidi = ClipboardPoisonGuard.inspect(rawAlias) {
                        return ClipboardPoisonGuard.sanitize(rawAlias)
                    }
                    return rawAlias
                }
                let sanitizedEntryOCR: String? = entry.ocrText.map { rawOCR in
                    if case .pastejackingOrBidi = ClipboardPoisonGuard.inspect(rawOCR) {
                        let clean = ClipboardPoisonGuard.sanitize(rawOCR)
                        return clean.isEmpty ? rawOCR : clean
                    }
                    return rawOCR
                }
                let effectiveHash: String = {
                    if let cleanText = sanitizedEntryText, cleanText != entry.text {
                        let digest = SHA256.hash(data: Data(cleanText.utf8)).map { String(format: "%02x", $0) }.joined()
                        return "\(entry.type == .link ? "link" : "text"):\(digest)"
                    }
                    return entry.contentHash
                }()

                let restored = ClipItem(
                    type: entry.type,
                    text: sanitizedEntryText,
                    imageFileName: savedImageName,
                    imageWidth: entry.imageWidth,
                    imageHeight: entry.imageHeight,
                    ocrText: sanitizedEntryOCR,
                    ocrChecked: (sanitizedEntryOCR != nil) ? true : nil,
                    filePaths: entry.filePaths,
                    contentHash: effectiveHash,
                    sourceAppName: entry.sourceAppName,
                    createdAt: entry.createdAt,
                    isPinned: true,
                    pinCategory: entry.pinCategory,
                    customAlias: sanitizedEntryAlias,
                    isTodoItem: entry.isTodoItem
                )
                working.append(restored)
                importedNew += 1
            }
        }

        let summary = ArchiveImportSummary(
            importedNewCount: importedNew,
            updatedExistingCount: updatedExisting,
            totalInBundle: bundle.entries.count,
            sourceFormatLabel: "iClip 归档"
        )
        return (working, summary)
    }

    private static func mergeExternalCompetitorCandidates(
        _ candidates: [UniversalCompetitorImporter.ExternalCandidate],
        formatLabel: String,
        into existingItems: [ClipItem]
    ) -> (mergedItems: [ClipItem], summary: ArchiveImportSummary) {
        var working = existingItems
        var importedNew = 0
        var updatedExisting = 0

        for cand in candidates {
            let safeBody: String = {
                if case .pastejackingOrBidi = ClipboardPoisonGuard.inspect(cand.text) {
                    let clean = ClipboardPoisonGuard.sanitize(cand.text)
                    return clean.isEmpty ? cand.text : clean
                }
                return cand.text
            }()
            let safeAlias: String? = cand.alias.map { rawAlias in
                if case .pastejackingOrBidi = ClipboardPoisonGuard.inspect(rawAlias) {
                    return ClipboardPoisonGuard.sanitize(rawAlias)
                }
                return rawAlias
            }
            let trimmed = safeBody.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let isLink = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
            let hash = SHA256.hash(data: Data(safeBody.utf8)).map { String(format: "%02x", $0) }.joined()
            let contentHash = "\(isLink ? "link" : "text"):\(hash)"
            let inferredCat = PinCategory.infer(alias: safeAlias, text: safeBody)

            if let idx = working.firstIndex(where: { $0.contentHash == contentHash }) {
                var cur = working[idx]
                var changed = false
                if !cur.isPinned {
                    cur.isPinned = true
                    changed = true
                }
                if (cur.customAlias?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                   let alias = safeAlias, !alias.isEmpty {
                    cur.customAlias = alias
                    changed = true
                }
                if cur.pinCategory == nil, let cat = inferredCat {
                    cur.pinCategory = cat
                    changed = true
                }
                if changed {
                    working[idx] = cur
                    updatedExisting += 1
                }
            } else {
                let newItem = ClipItem(
                    type: isLink ? .link : .text,
                    text: safeBody,
                    contentHash: contentHash,
                    sourceAppName: cand.sourceLabel,
                    createdAt: cand.createdAt ?? Date(),
                    isPinned: true,
                    pinCategory: inferredCat,
                    customAlias: safeAlias
                )
                working.append(newItem)
                importedNew += 1
            }
        }

        let summary = ArchiveImportSummary(
            importedNewCount: importedNew,
            updatedExistingCount: updatedExisting,
            totalInBundle: candidates.count,
            sourceFormatLabel: formatLabel
        )
        return (working, summary)
    }

    static func isValidRasterImageHeader(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return true } // PNG
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return true } // JPEG
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 { return true } // GIF
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return true } // WebP
        return false
    }
}

/// 跨角色共享的 `.iclip` 保存面板加密口令附件与加密归档解锁提示组件（零冗余模态弹窗）
@MainActor
enum ArchivePassphraseUIHelper {
    static func attachExportPassphraseAccessory(
        to savePanel: NSSavePanel,
        sensitivePinnedCount: Int
    ) -> NSSecureTextField {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: sensitivePinnedCount > 0 ? 64 : 42))
        let label = NSTextField(labelWithString: "加密口令（可选 · Mac/Win 互通）：")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.frame = NSRect(x: 12, y: sensitivePinnedCount > 0 ? 32 : 11, width: 196, height: 18)

        let field = NSSecureTextField(frame: NSRect(x: 210, y: sensitivePinnedCount > 0 ? 29 : 8, width: 158, height: 24))
        field.placeholderString = "留空则不设口令"
        field.font = .systemFont(ofSize: 12)

        container.addSubview(label)
        container.addSubview(field)

        if sensitivePinnedCount > 0 {
            let warn = NSTextField(labelWithString: "⚠ 检测到 \(sensitivePinnedCount) 条收藏含敏感凭据，建议输入口令加密导出")
            warn.font = .systemFont(ofSize: 11)
            warn.textColor = .systemOrange
            warn.frame = NSRect(x: 12, y: 6, width: 356, height: 16)
            container.addSubview(warn)
        }

        savePanel.accessoryView = container
        return field
    }

    static func promptImportPassphrase(for fileName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "解锁加密归档「\(fileName)」"
        alert.informativeText = "该 .iclip 归档受口令加密保护（兼容 macOS 与 Windows），请输入导出时设置的口令："
        alert.alertStyle = .informational
        alert.addButton(withTitle: "解锁并导入")
        alert.addButton(withTitle: "取消")

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "输入归档加密口令"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return nil }
        let pw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return pw.isEmpty ? nil : pw
    }
}
