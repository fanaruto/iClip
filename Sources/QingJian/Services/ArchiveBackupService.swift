import Foundation
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
    case invalidArchiveFormat
    case unsupportedSchemaVersion(Int)
    case passphraseRequiredOrIncorrect

    var errorDescription: String? {
        switch self {
        case .noPinnedItems:
            return "当前暂无已收藏的记录，请先点击卡片收藏常用话术或模板"
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
                let imgURL = imagesDirectoryURL.appendingPathComponent(fileName)
                if let imgData = LocalVaultCrypto.readDecryptedImageData(at: imgURL),
                   imgData.count <= maxEmbeddedImageBytes {
                    base64PNG = imgData.base64EncodedString()
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
        let effectiveData: Data
        if LocalVaultCrypto.isEncryptedArchive(data) {
            guard let pw = passphrase, !pw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let opened = LocalVaultCrypto.openEncryptedArchive(data, passphrase: pw) else {
                throw ArchiveBackupError.passphraseRequiredOrIncorrect
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

        for entry in bundle.entries {
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
                // 若本地图片文件缺失但归档内有内嵌 PNG，自动修复落盘
                if current.type == .image,
                   let base64 = entry.embeddedPNGBase64,
                   let pngData = Data(base64Encoded: base64) {
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
                          let pngData = Data(base64Encoded: base64) else {
                        // 无可用内嵌数据的跨机图片记录跳过，避免生成坏死空图卡片
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

                let restored = ClipItem(
                    type: entry.type,
                    text: entry.text,
                    imageFileName: savedImageName,
                    imageWidth: entry.imageWidth,
                    imageHeight: entry.imageHeight,
                    ocrText: entry.ocrText,
                    ocrChecked: (entry.ocrText != nil) ? true : nil,
                    filePaths: entry.filePaths,
                    contentHash: entry.contentHash,
                    sourceAppName: entry.sourceAppName,
                    createdAt: entry.createdAt,
                    isPinned: true,
                    pinCategory: entry.pinCategory,
                    customAlias: entry.customAlias,
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
            let trimmed = cand.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let isLink = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
            let hash = SHA256.hash(data: Data(cand.text.utf8)).map { String(format: "%02x", $0) }.joined()
            let contentHash = "\(isLink ? "link" : "text"):\(hash)"
            let inferredCat = PinCategory.infer(alias: cand.alias, text: cand.text)

            if let idx = working.firstIndex(where: { $0.contentHash == contentHash }) {
                var cur = working[idx]
                var changed = false
                if !cur.isPinned {
                    cur.isPinned = true
                    changed = true
                }
                if (cur.customAlias?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                   let alias = cand.alias, !alias.isEmpty {
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
                    text: cand.text,
                    contentHash: contentHash,
                    sourceAppName: cand.sourceLabel,
                    createdAt: cand.createdAt ?? Date(),
                    isPinned: true,
                    pinCategory: inferredCat,
                    customAlias: cand.alias
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
}
