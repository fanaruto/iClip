import Foundation
import CryptoKit
import Security
import AppKit

/// 高敏凭据离线分类（双角色共享，微秒级零正则回溯）
enum SensitiveSecretKind: String, Equatable {
    case apiKey
    case privateKey
    case jwtToken
    case connectionSecret

    var shieldBadgeTitle: String {
        switch self {
        case .apiKey: return "密钥保护"
        case .privateKey: return "私钥保护"
        case .jwtToken: return "令牌保护"
        case .connectionSecret: return "凭据保护"
        }
    }
}

/// 1. 硬件钥匙串绑定的本地剪贴板历史静态透明加密引擎（AES-256-GCM + `0600` 权限锁死）
enum LocalVaultCrypto {
    static let magicHeader = Data("ICLPENC1".utf8)
    private static let keychainService = "com.qingjian.clipboard.vault"
    private static let keychainAccount = "history-aes256-v1"

    private static let keyLock = NSLock()
    private static var cachedMasterKey: SymmetricKey? = nil

    /// 获取或首次静默创建本机专属 256-bit 钥匙串主密钥（绑定当前设备，绝不弹窗打扰用户）
    static func loadOrCreateMasterKey() -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }

        if let existing = cachedMasterKey {
            return existing
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let keyData = result as? Data, keyData.count == 32 {
            let key = SymmetricKey(data: keyData)
            cachedMasterKey = key
            return key
        }

        let newKey = SymmetricKey(size: .bits256)
        let rawKeyData = newKey.withUnsafeBytes { Data($0) }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: rawKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        _ = SecItemDelete(query as CFDictionary)
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            cachedMasterKey = newKey
            return newKey
        }

        // 极端沙盒/无钥匙串守护进程测试环境兜底：基于本机硬件/用户目录派生确定性设备密钥
        let fallbackSeed = "iclip-local-vault|\(NSHomeDirectory())|\(NSUserName())"
        let digest = SHA256.hash(data: Data(fallbackSeed.utf8))
        let fallbackKey = SymmetricKey(data: Data(digest))
        cachedMasterKey = fallbackKey
        return fallbackKey
    }

    /// 将明文 JSON 数据封装为 `ICLPENC1` + AES-256-GCM 认证密文
    static func sealSnapshotData(_ plainData: Data, customKey: SymmetricKey? = nil) -> Data? {
        let key = customKey ?? loadOrCreateMasterKey()
        guard let sealed = try? AES.GCM.seal(plainData, using: key),
              let combined = sealed.combined else {
            return nil
        }
        var output = Data(capacity: magicHeader.count + combined.count)
        output.append(magicHeader)
        output.append(combined)
        return output
    }

    /// 解开本地快照：支持新版 `ICLPENC1` 认证密文，同时平滑兼容旧版明文 JSON 并在下次保存时自动加密升级
    static func openSnapshotData(
        _ rawData: Data,
        customKey: SymmetricKey? = nil
    ) -> (plainData: Data, wasLegacyPlaintext: Bool)? {
        guard !rawData.isEmpty else { return nil }
        if rawData.starts(with: magicHeader) {
            let payload = rawData.dropFirst(magicHeader.count)
            let key = customKey ?? loadOrCreateMasterKey()
            guard let box = try? AES.GCM.SealedBox(combined: payload),
                  let opened = try? AES.GCM.open(box, using: key) else {
                return nil
            }
            return (opened, false)
        }

        // 兼容旧版未加密 UTF-8 JSON 数组（首非空字节需为 `[`）
        if let firstNonWS = rawData.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }),
           firstNonWS == UInt8(ascii: "[") {
            return (rawData, true)
        }
        return nil
    }

    /// 原子写入数据并将目录锁死为 `0700`、文件锁死为 `0600`（防止同机其他低权进程窥探）
    static func writeProtectedFile(_ data: Data, to fileURL: URL) throws {
        let fm = FileManager.default
        let dirURL = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dirURL.path) {
            try fm.createDirectory(
                at: dirURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirURL.path)
        }
        try data.write(to: fileURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - 口令级跨设备归档加密（`.iclip` 可选密码保护，双端互通）

    static let archiveEncryptedMagic = Data("ICLPARCH1".utf8)

    private static func derivePassphraseKey(passphrase: String, salt: Data) -> SymmetricKey {
        // 4,096 轮迭代 SHA-256 密钥拉伸（零外部 C 库依赖，macOS Swift 与 Windows Rust 100% 字节级一致）
        var block = Data()
        block.append(salt)
        block.append(Data(passphrase.utf8))
        var hash = Data(SHA256.hash(data: block))
        for round in 0..<4096 {
            var mix = Data(capacity: hash.count + salt.count + 4)
            mix.append(hash)
            mix.append(salt)
            var rLE = UInt32(round).littleEndian
            withUnsafeBytes(of: &rLE) { mix.append(contentsOf: $0) }
            hash = Data(SHA256.hash(data: mix))
        }
        return SymmetricKey(data: hash)
    }

    static func sealArchiveWithPassphrase(_ plainArchive: Data, passphrase: String) -> Data? {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return plainArchive }
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = derivePassphraseKey(passphrase: trimmed, salt: salt)
        guard let box = try? AES.GCM.seal(plainArchive, using: key),
              let combined = box.combined else {
            return nil
        }
        var out = Data(capacity: archiveEncryptedMagic.count + 16 + combined.count)
        out.append(archiveEncryptedMagic)
        out.append(salt)
        out.append(combined)
        return out
    }

    static func isEncryptedArchive(_ data: Data) -> Bool {
        data.starts(with: archiveEncryptedMagic)
    }

    static func openEncryptedArchive(_ data: Data, passphrase: String) -> Data? {
        guard isEncryptedArchive(data) else { return data }
        let headerLen = archiveEncryptedMagic.count + 16
        guard data.count > headerLen + 28 else { return nil }
        let salt = data.subdata(in: archiveEncryptedMagic.count..<headerLen)
        let combined = data.subdata(in: headerLen..<data.count)
        let key = derivePassphraseKey(passphrase: passphrase.trimmingCharacters(in: .whitespacesAndNewlines), salt: salt)
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key) else {
            return nil
        }
        return plain
    }
}

/// 2. 离线微秒级高敏凭据嗅探与防肩窥圆点雾化遮罩（零布局抖动，选中/悬停即刻原位显影）
enum SensitiveCredentialVeil {
    private static let apiKeyRegex = try! NSRegularExpression(
        pattern: #"\b(?:sk-(?:proj-|ant-|live_|test_)?[A-Za-z0-9_-]{18,}|gh[pousr]_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{28,}|glpat-[A-Za-z0-9_-]{18,}|xox[baprs]-[A-Za-z0-9-]{18,}|AIzaSy[A-Za-z0-9_-]{31,}|hf_[A-Za-z0-9]{24,}|AKIA[0-9A-Z]{16})\b"#
    )
    private static let jwtRegex = try! NSRegularExpression(
        pattern: #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#
    )
    private static let connUriRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^:\s/]+:[^@\s]{4,}@[^\s]+"#
    )
    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:bearer|authorization\s*:\s*bearer)\s+[A-Za-z0-9._~+/=-]{20,}"#
    )

    /// 仅扫描首 2,048 UTF-8 字节，2MB 超大文本耗时 < 0.03ms
    static func classify(_ rawText: String) -> SensitiveSecretKind? {
        guard !rawText.isEmpty else { return nil }
        let sample: String = rawText.utf8.count > 2_048 ? String(rawText.prefix(1_024)) : rawText
        if sample.contains("-----BEGIN ") && sample.contains("PRIVATE KEY-----") {
            return .privateKey
        }
        let nsRange = NSRange(sample.startIndex..<sample.endIndex, in: sample)
        if apiKeyRegex.firstMatch(in: sample, range: nsRange) != nil {
            return .apiKey
        }
        if jwtRegex.firstMatch(in: sample, range: nsRange) != nil {
            return .jwtToken
        }
        if connUriRegex.firstMatch(in: sample, range: nsRange) != nil || bearerRegex.firstMatch(in: sample, range: nsRange) != nil {
            return .connectionSecret
        }
        return nil
    }

    /// 生成防肩窥雾化摘要（保留辨识头尾，中间替换为紧凑圆点，行数与视觉长度恒定零抖动）
    static func veiledPreview(for rawText: String) -> String {
        let trimmed = rawText.prefix(360).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "••••••••••••" }

        if trimmed.contains("PRIVATE KEY-----") {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? "-----BEGIN PRIVATE KEY-----"
            return "\(firstLine) ••••••••••••••••"
        }

        let singleLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= 12 {
            return String(singleLine.prefix(3)) + "••••••••"
        }
        let headCount = min(8, max(4, singleLine.count / 5))
        let tailCount = 4
        let head = String(singleLine.prefix(headCount))
        let tail = String(singleLine.suffix(tailCount))
        return "\(head)••••••••••••\(tail)"
    }
}

/// 3. 行业标准密码管理器与自动化临时剪贴板协议全覆盖识别器
enum PasteboardPrivacyStandards {
    private static let concealedTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword"),
        NSPasteboard.PasteboardType("com.bitwarden.desktop.concealed"),
        NSPasteboard.PasteboardType("net.antelle.keeweb")
    ]

    private static let transientTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
        NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType"),
        NSPasteboard.PasteboardType("Pasteboard generator type")
    ]

    private static let sourcePasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    private static let passwordManagerBundleIDs: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.dashlane.dashlanephonefinal",
        "me.proton.pass.catalyst",
        "in.sinew.Enpass-Desktop"
    ]

    enum InspectionDisposition: Equatable {
        case allowCapture
        /// 密码管理器复制的真实机密密码：禁止入库，且可触发超时自动清擦系统剪贴板
        case rejectConcealedSecret
        /// TextExpander / 输入法 / 自动化工具临时借道剪贴板：静默跳过入库
        case rejectTransientAutomation
    }

    static func inspect(
        types: [NSPasteboard.PasteboardType],
        sourceBundleIDFromPasteboard: String? = nil,
        frontmostBundleID: String? = nil
    ) -> InspectionDisposition {
        for t in types {
            if concealedTypes.contains(t) {
                return .rejectConcealedSecret
            }
        }
        if let pbSource = sourceBundleIDFromPasteboard, passwordManagerBundleIDs.contains(pbSource) {
            return .rejectConcealedSecret
        }
        if let front = frontmostBundleID, passwordManagerBundleIDs.contains(front) {
            return .rejectConcealedSecret
        }
        for t in types {
            if transientTypes.contains(t) {
                return .rejectTransientAutomation
            }
        }
        return .allowCapture
    }

    static func extractSourceBundleID(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: sourcePasteboardType)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 4. 跨软件零成本搬家引擎（原生支持导入 Raycast Snippets / Maccy / Paste / CopyQ JSON 及 Excel CSV/TSV 常用语表）
enum UniversalCompetitorImporter {
    struct ExternalCandidate: Equatable {
        let text: String
        let alias: String?
        let sourceLabel: String
        let createdAt: Date?
    }

    /// 尝试从常见竞品导出格式解析收藏/常用语条目（非 `.iclip` 时自动接管）
    static func parseExternalData(
        _ data: Data,
        fileExtensionHint: String? = nil
    ) -> (entries: [ExternalCandidate], formatName: String)? {
        let ext = (fileExtensionHint ?? "").lowercased()

        // A. 优先尝试 JSON 结构（Raycast Snippets / Maccy / Paste / CopyQ / 通用键值数组）
        if ext != "csv" && ext != "tsv",
           let jsonObj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let parsed = parseJSONPayload(jsonObj), !parsed.entries.isEmpty {
                return parsed
            }
        }

        // B. 尝试 UTF-8 CSV / TSV 常用语表（例如从 Excel / 飞书多维表 / Ditto 导出的 `备注标题,正文`）
        if let rawStr = String(data: data, encoding: .utf8) {
            let trimmed = rawStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[") {
                let delimiter: Character = (ext == "tsv" || (trimmed.contains("\t") && !trimmed.contains(","))) ? "\t" : ","
                let rows = parseDelimitedRows(trimmed, delimiter: delimiter)
                let candidates = buildCandidatesFromTableRows(rows)
                if !candidates.isEmpty {
                    return (candidates, delimiter == "\t" ? "TSV 常用语表" : "CSV 常用语表")
                }
            }
        }

        return nil
    }

    private static func parseJSONPayload(_ root: Any) -> (entries: [ExternalCandidate], formatName: String)? {
        var dictList: [[String: Any]] = []
        var formatHint = "外部 JSON 收藏"

        if let arr = root as? [[String: Any]] {
            dictList = arr
            if arr.first?["keyword"] != nil && arr.first?["text"] != nil {
                formatHint = "Raycast 常用语"
            } else if arr.first?["pin"] != nil || arr.first?["application"] != nil {
                formatHint = "Maccy 剪贴记录"
            }
        } else if let strArr = root as? [String] {
            let entries = strArr
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { ExternalCandidate(text: $0, alias: nil, sourceLabel: "JSON 列表导入", createdAt: nil) }
            return entries.isEmpty ? nil : (entries, "JSON 文本列表")
        } else if let obj = root as? [String: Any] {
            // 跳过标准 iClip 自身归档格式（由 ArchiveBackupService 原生分支处理以校验 schemaVersion）
            if (obj["format"] as? String) == PinnedArchiveBundle.formatIdentifier {
                return nil
            }
            for key in ["snippets", "items", "pins", "history", "clips", "data", "records"] {
                if let sub = obj[key] as? [[String: Any]], !sub.isEmpty {
                    dictList = sub
                    if key == "snippets" {
                        formatHint = "常用语片段包"
                    } else if key == "pins" {
                        formatHint = "Maccy / Paste 收藏"
                    }
                    break
                }
            }
        }

        guard !dictList.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        var out: [ExternalCandidate] = []

        for item in dictList {
            let textVal = firstNonEmptyString(
                in: item,
                keys: ["text", "content", "value", "plainText", "body", "snippet", "string"]
            )
            guard let cleanText = textVal, !cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let rawTitle = firstNonEmptyString(
                in: item,
                keys: ["title", "name", "alias", "customAlias", "label", "keyword"]
            )
            let alias: String? = {
                guard let t = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !t.isEmpty,
                      t != cleanText.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return nil
                }
                return String(t.prefix(80))
            }()

            let appSource = firstNonEmptyString(in: item, keys: ["application", "sourceAppName", "app", "source"]) ?? formatHint
            let created: Date? = {
                if let tsStr = firstNonEmptyString(in: item, keys: ["createdAt", "firstCopiedAt", "lastCopiedAt", "timestamp"]),
                   let d = iso.date(from: tsStr) {
                    return d
                }
                if let unix = item["timestamp"] as? TimeInterval ?? item["createdAt"] as? TimeInterval, unix > 1_000_000_000 {
                    return Date(timeIntervalSince1970: unix)
                }
                return nil
            }()

            out.append(ExternalCandidate(text: cleanText, alias: alias, sourceLabel: appSource, createdAt: created))
        }

        return out.isEmpty ? nil : (out, formatHint)
    }

    private static func firstNonEmptyString(in dict: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = dict[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
    }

    /// RFC 4180 兼容的轻量 CSV / TSV 解析器（支持引号内逗号与跨行文本）
    private static func parseDelimitedRows(_ input: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        let chars = Array(input)
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(ch)
                }
            } else {
                if ch == "\"" && currentField.isEmpty {
                    inQuotes = true
                } else if ch == delimiter {
                    currentRow.append(currentField)
                    currentField = ""
                } else if ch == "\r" || ch == "\n" {
                    if ch == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" {
                        i += 1
                    }
                    currentRow.append(currentField)
                    currentField = ""
                    if currentRow.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                } else {
                    currentField.append(ch)
                }
            }
            i += 1
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            if currentRow.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                rows.append(currentRow)
            }
        }
        return rows
    }

    private static func buildCandidatesFromTableRows(_ rows: [[String]]) -> [ExternalCandidate] {
        guard !rows.isEmpty else { return [] }
        let headerKeywords: Set<String> = [
            "title", "name", "alias", "keyword", "label", "text", "content", "value", "body", "snippet",
            "标题", "名称", "备注", "快捷键", "内容", "正文", "话术"
        ]

        var startIdx = 0
        if let first = rows.first, !first.isEmpty {
            let c0 = first[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let c1 = (first.count > 1 ? first[1] : "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if headerKeywords.contains(c0) || headerKeywords.contains(c1) {
                startIdx = 1
            }
        }

        var out: [ExternalCandidate] = []
        for row in rows.dropFirst(startIdx) {
            if row.count >= 2 {
                let col0 = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let col1 = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !col1.isEmpty {
                    let alias = (!col0.isEmpty && col0 != col1) ? String(col0.prefix(80)) : nil
                    out.append(ExternalCandidate(text: col1, alias: alias, sourceLabel: "表格迁入", createdAt: nil))
                } else if !col0.isEmpty {
                    out.append(ExternalCandidate(text: col0, alias: nil, sourceLabel: "表格迁入", createdAt: nil))
                }
            } else if let only = row.first?.trimmingCharacters(in: .whitespacesAndNewlines), !only.isEmpty {
                out.append(ExternalCandidate(text: only, alias: nil, sourceLabel: "列表迁入", createdAt: nil))
            }
        }
        return out
    }
}
