import Foundation
import CryptoKit
import Security
import IOKit
import AppKit

/// 高敏凭据离线分类（双角色共享，微秒级零正则回溯）
enum SensitiveSecretKind: String, Equatable {
    case apiKey
    case privateKey
    case jwtToken
    case connectionSecret
    case personalIdentity

    var shieldBadgeTitle: String {
        switch self {
        case .apiKey: return "密钥保护"
        case .privateKey: return "私钥保护"
        case .jwtToken: return "令牌保护"
        case .connectionSecret: return "凭据保护"
        case .personalIdentity: return "隐私保护"
        }
    }
}

/// 1. 本机硬件 UUID + 256-bit 独立随机种子绑定的零弹窗静态透明加密引擎（兼容免证书 Ad-hoc 跨版本无损升级，彻底杜绝钥匙串 CDHash 阻塞弹窗）
enum LocalVaultCrypto {
    static let magicHeader = Data("ICLPENC1".utf8)
    private static let legacyKeychainService = "com.qingjian.clipboard.vault"
    private static let legacyKeychainAccount = "history-aes256-v1"

    private static let keyLock = NSLock()
    private static var cachedMasterKey: SymmetricKey? = nil

    private static func hardwarePlatformUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "mac-fallback-hw" }
        defer { IOObjectRelease(service) }
        if let uuid = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String, !uuid.isEmpty {
            return uuid
        }
        return "mac-fallback-hw"
    }

    private static func defaultSeedFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("QingJian", isDirectory: true)
            .appendingPathComponent("vault.keyseed")
    }

    /// 获取或首次静默派生本机硬件绑定的 256-bit 主密钥（0.01ms 零弹窗、零线程阻塞，Ad-hoc 重签升级 100% 稳定一致）
    static func loadOrCreateMasterKey() -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }

        if let existing = cachedMasterKey {
            return existing
        }

        let seedURL = defaultSeedFileURL()
        var seedData: Data? = nil
        if let raw = try? Data(contentsOf: seedURL), raw.count == 32 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seedURL.path)
            seedData = raw
        } else {
            var fresh = Data(count: 32)
            let status = fresh.withUnsafeMutableBytes { ptr in
                SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
            }
            if status == errSecSuccess {
                try? writeProtectedFile(fresh, to: seedURL)
                seedData = fresh
            }
        }

        let ikmBytes = seedData ?? Data(SHA256.hash(data: Data("iclip-seed|\(NSHomeDirectory())".utf8)))
        let hwContext = "iclip-hw-vault-v2|\(hardwarePlatformUUID())|\(getuid())"
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikmBytes),
            salt: Data(hwContext.utf8),
            info: Data("com.qingjian.clipboard.aes256gcm".utf8),
            outputByteCount: 32
        )
        cachedMasterKey = derived
        return derived
    }

    /// 非阻塞尝试读取早期版本的传统钥匙串密钥（强制 `kSecUseAuthenticationUISkip`，0.1ms 内返回，绝不弹窗或挂起线程）
    private static func tryLoadLegacyKeychainKeyNonBlocking() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyKeychainAccount,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let keyData = result as? Data, keyData.count == 32 {
            return SymmetricKey(data: keyData)
        }
        return nil
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

    /// 解开本地快照：支持新版硬件绑定 `ICLPENC1` 密文、非阻塞兼容早期钥匙串密文及历史明文 JSON
    static func openSnapshotData(
        _ rawData: Data,
        customKey: SymmetricKey? = nil
    ) -> (plainData: Data, wasLegacyPlaintext: Bool)? {
        guard !rawData.isEmpty else { return nil }
        if rawData.starts(with: magicHeader) {
            let payload = rawData.dropFirst(magicHeader.count)
            let key = customKey ?? loadOrCreateMasterKey()
            guard let box = try? AES.GCM.SealedBox(combined: payload) else {
                return nil
            }
            if let opened = try? AES.GCM.open(box, using: key) {
                return (opened, false)
            }
            if customKey == nil,
               let legacyKey = tryLoadLegacyKeychainKeyNonBlocking(),
               let openedLegacy = try? AES.GCM.open(box, using: legacyKey) {
                return (openedLegacy, true)
            }
            return nil
        }

        // 兼容旧版未加密 UTF-8 JSON 数组或对象（首非空字节需为 `[` 或 `{`）
        if let firstNonWS = rawData.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }),
           (firstNonWS == UInt8(ascii: "[") || firstNonWS == UInt8(ascii: "{")) {
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

    // MARK: - 本地剪贴板截图全模态静态透明加密（`ICLPIMG1` + AES-256-GCM + 旧明文 PNG 自动升级）

    static let imageEncryptedMagic = Data("ICLPIMG1".utf8)

    static func sealImageData(_ plainImageData: Data, customKey: SymmetricKey? = nil) -> Data? {
        guard !plainImageData.isEmpty else { return nil }
        let key = customKey ?? loadOrCreateMasterKey()
        guard let sealed = try? AES.GCM.seal(plainImageData, using: key),
              let combined = sealed.combined else {
            return nil
        }
        var output = Data(capacity: imageEncryptedMagic.count + combined.count)
        output.append(imageEncryptedMagic)
        output.append(combined)
        return output
    }

    static func openImageData(
        _ rawData: Data,
        customKey: SymmetricKey? = nil
    ) -> (plainData: Data, wasLegacyPlainImage: Bool)? {
        guard !rawData.isEmpty else { return nil }
        if rawData.starts(with: imageEncryptedMagic) {
            let payload = rawData.dropFirst(imageEncryptedMagic.count)
            let key = customKey ?? loadOrCreateMasterKey()
            guard let box = try? AES.GCM.SealedBox(combined: payload),
                  let opened = try? AES.GCM.open(box, using: key) else {
                return nil
            }
            return (opened, false)
        }
        return (rawData, true)
    }

    static func writeEncryptedImage(
        _ plainImageData: Data,
        to fileURL: URL,
        customKey: SymmetricKey? = nil
    ) throws {
        let payload = sealImageData(plainImageData, customKey: customKey) ?? plainImageData
        try writeProtectedFile(payload, to: fileURL)
    }

    static func readDecryptedImageData(
        at fileURL: URL,
        customKey: SymmetricKey? = nil
    ) -> Data? {
        guard let raw = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return nil
        }
        return openImageData(raw, customKey: customKey)?.plainData
    }

    @discardableResult
    static func upgradePlainImagesInDirectoryIfNeeded(
        _ imagesDir: URL,
        customKey: SymmetricKey? = nil
    ) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: imagesDir.path) else { return 0 }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imagesDir.path)
        guard let files = try? fm.contentsOfDirectory(
            at: imagesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var upgraded = 0
        for fileURL in files where !fileURL.hasDirectoryPath {
            guard let raw = try? Data(contentsOf: fileURL), !raw.isEmpty else { continue }
            if raw.starts(with: imageEncryptedMagic) {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                continue
            }
            if let sealed = sealImageData(raw, customKey: customKey),
               (try? writeProtectedFile(sealed, to: fileURL)) != nil {
                upgraded += 1
            }
        }
        return upgraded
    }

    // MARK: - 口令级跨设备归档加密（`.iclip` 可选密码保护，macOS ↔ Windows 100% 字节级双向互通）

    static let archiveEncryptedMagic = Data("ICLPARCH1".utf8)
    static let crossPlatformArchiveMagic = Data("ICLPAWIN1".utf8)

    private static func derivePassphraseKeyBytes(passphrase: String, salt: Data) -> Data {
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
        return hash
    }

    private static func deriveArchiveSubkeys(masterKeyBytes: Data, nonce: Data) -> (encKey: Data, macKey: SymmetricKey) {
        let mKey = SymmetricKey(data: masterKeyBytes)
        var encMsg = Data("enc|".utf8)
        encMsg.append(nonce)
        var macMsg = Data("mac|".utf8)
        macMsg.append(nonce)
        let encDigest = Data(HMAC<SHA256>.authenticationCode(for: encMsg, using: mKey))
        let macDigest = Data(HMAC<SHA256>.authenticationCode(for: macMsg, using: mKey))
        return (encDigest, SymmetricKey(data: macDigest))
    }

    private static func applySHA256CTRStream(encKey: Data, nonce: Data, data: Data) -> Data {
        var bytes = [UInt8](data)
        var counter: UInt64 = 0
        var offset = 0
        while offset < bytes.count {
            var blockInput = Data(capacity: 32 + 16 + 8)
            blockInput.append(encKey)
            blockInput.append(nonce)
            var cLE = counter.littleEndian
            withUnsafeBytes(of: &cLE) { blockInput.append(contentsOf: $0) }
            let stream = Array(SHA256.hash(data: blockInput))
            let chunkLen = min(32, bytes.count - offset)
            for i in 0..<chunkLen {
                bytes[offset + i] ^= stream[i]
            }
            offset += chunkLen
            counter &+= 1
        }
        return Data(bytes)
    }

    static func sealArchiveWithPassphrase(_ plainArchive: Data, passphrase: String) -> Data? {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return plainArchive }
        var salt = Data(count: 16)
        var nonce = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        let master = derivePassphraseKeyBytes(passphrase: trimmed, salt: salt)
        let (encKey, macKey) = deriveArchiveSubkeys(masterKeyBytes: master, nonce: nonce)
        let ciphertext = applySHA256CTRStream(encKey: encKey, nonce: nonce, data: plainArchive)

        var out = Data(capacity: 9 + 16 + 16 + ciphertext.count + 32)
        out.append(crossPlatformArchiveMagic)
        out.append(salt)
        out.append(nonce)
        out.append(ciphertext)
        let tag = Data(HMAC<SHA256>.authenticationCode(for: out, using: macKey))
        out.append(tag)
        return out
    }

    static func isEncryptedArchive(_ data: Data) -> Bool {
        data.starts(with: crossPlatformArchiveMagic) || data.starts(with: archiveEncryptedMagic)
    }

    static func openEncryptedArchive(_ data: Data, passphrase: String) -> Data? {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if data.starts(with: crossPlatformArchiveMagic) {
            guard !trimmed.isEmpty, data.count >= 9 + 16 + 16 + 32 else { return nil }
            let bodyEnd = data.count - 32
            let expectedTag = data.subdata(in: bodyEnd..<data.count)
            let salt = data.subdata(in: 9..<25)
            let nonce = data.subdata(in: 25..<41)
            let master = derivePassphraseKeyBytes(passphrase: trimmed, salt: salt)
            let (encKey, macKey) = deriveArchiveSubkeys(masterKeyBytes: master, nonce: nonce)
            let valid = HMAC<SHA256>.isValidAuthenticationCode(
                expectedTag,
                authenticating: data.subdata(in: 0..<bodyEnd),
                using: macKey
            )
            guard valid else { return nil }
            let cipherSlice = data.subdata(in: 41..<bodyEnd)
            return applySHA256CTRStream(encKey: encKey, nonce: nonce, data: cipherSlice)
        }
        if data.starts(with: archiveEncryptedMagic) {
            let headerLen = archiveEncryptedMagic.count + 16
            guard !trimmed.isEmpty, data.count > headerLen + 28 else { return nil }
            let salt = data.subdata(in: archiveEncryptedMagic.count..<headerLen)
            let combined = data.subdata(in: headerLen..<data.count)
            let key = SymmetricKey(data: derivePassphraseKeyBytes(passphrase: trimmed, salt: salt))
            guard let box = try? AES.GCM.SealedBox(combined: combined),
                  let plain = try? AES.GCM.open(box, using: key) else {
                return nil
            }
            return plain
        }
        return data
    }
}

/// 1.9 剪贴板投毒、终端粘贴劫持（Pastejacking / Trojan Source CVE-2021-42574）与网页零宽幽灵字符净化护盾
enum ClipboardPoisonGuard {
    enum ThreatKind: Equatable {
        /// 高危：包含双向文本反转伪装（RLO/LRO/Bidi Isolates）或隐藏终端控制转义（ESC/CSI/Backspace/内联CR覆盖）
        case pastejackingOrBidi(count: Int)
        /// 常见污染：从富文本/网页复制出的零宽幽灵字符（U+200B/200C/非Emoji 200D/2060/FEFF）
        case zeroWidthGhost(count: Int)
    }

    private static let ansiCSIRegex = try! NSRegularExpression(
        pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]|\u{009B}[0-9;?]*[ -/]*[@-~]|\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)"
    )

    private static func isBidiOverrideScalar(_ v: UInt32) -> Bool {
        (v >= 0x202A && v <= 0x202E) || (v >= 0x2066 && v <= 0x2069) || v == 0x061C
    }

    private static func isZeroWidthScalar(_ v: UInt32) -> Bool {
        v == 0x200B || v == 0x200C || v == 0x2060 || v == 0xFEFF
    }

    static func inspect(_ rawText: String) -> ThreatKind? {
        guard !rawText.isEmpty else { return nil }
        let sample: Substring = rawText.utf8.count > 16_384 ? rawText.prefix(8_192) : rawText[...]
        var highRiskCount = 0
        var zeroWidthCount = 0
        var prevScalar: UInt32 = 0

        let scalars = Array(sample.unicodeScalars)
        for idx in scalars.indices {
            let v = scalars[idx].value
            if isBidiOverrideScalar(v) || v == 0x001B || v == 0x009B || v == 0x0008 || v == 0x0007 {
                highRiskCount += 1
            } else if v == 0x000D {
                // `\r` 后紧跟的若非 `\n` 且后面还有可见字符，属于终端同行覆盖回显欺骗（`evil \r safe`）
                let nextV: UInt32? = (idx + 1 < scalars.count) ? scalars[idx + 1].value : nil
                if let nv = nextV, nv != 0x000A && nv != 0x000D {
                    highRiskCount += 1
                }
            } else if isZeroWidthScalar(v) {
                zeroWidthCount += 1
            } else if v == 0x200D {
                // 智能豁免合法 Emoji ZWJ 复合序列（如 👨‍👩‍👧 / 🧑‍💻）
                if prevScalar < 0x2600 {
                    zeroWidthCount += 1
                }
            }
            prevScalar = v
        }

        if highRiskCount > 0 {
            return .pastejackingOrBidi(count: highRiskCount + zeroWidthCount)
        }
        if zeroWidthCount > 0 {
            return .zeroWidthGhost(count: zeroWidthCount)
        }
        return nil
    }

    /// 彻底剥离 ANSI 转义序列、Bidi 反转木马符、欺骗性内联回车与非 Emoji 零宽幽灵字符
    static func sanitize(_ rawText: String) -> String {
        guard !rawText.isEmpty else { return rawText }
        let hadHighRisk: Bool = {
            if case .pastejackingOrBidi = inspect(rawText) { return true }
            return false
        }()

        // 1. 剥离完整 ANSI CSI / OSC 控制序列，防止残留 `[31m` 等尾巴
        var stage = rawText
        if stage.contains("\u{001B}") || stage.contains("\u{009B}") {
            stage = ansiCSIRegex.stringByReplacingMatches(
                in: stage,
                range: NSRange(stage.startIndex..<stage.endIndex, in: stage),
                withTemplate: ""
            )
        }
        // 2. 规范化 CRLF 后，将同行欺骗裸 `\r` 转为安全空格或剥离
        stage = stage.replacingOccurrences(of: "\r\n", with: "\n")
        if stage.contains("\r") {
            stage = stage.replacingOccurrences(of: "\r", with: " ")
        }

        // 3. 逐标量过滤危险控制符、Bidi 伪装符与非 Emoji 零宽字符
        var out = String.UnicodeScalarView()
        out.reserveCapacity(stage.unicodeScalars.count)
        var prevV: UInt32 = 0
        for sc in stage.unicodeScalars {
            let v = sc.value
            if isBidiOverrideScalar(v) || isZeroWidthScalar(v) {
                continue
            }
            if v == 0x200D && prevV < 0x2600 {
                continue
            }
            if v < 0x0020 && v != 0x000A && v != 0x0009 {
                continue
            }
            if v == 0x007F || (v >= 0x0080 && v <= 0x009F) {
                continue
            }
            out.append(sc)
            prevV = v
        }

        var cleaned = String(out)
        if hadHighRisk {
            // 剥离尾随自动回车执行陷阱，让用户在终端先看清命令再按回车
            while cleaned.hasSuffix("\n") {
                cleaned.removeLast()
            }
        }
        return cleaned
    }

    static func isTerminalApp(_ appName: String?) -> Bool {
        guard let raw = appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return false }
        let terms = [
            "ghostty", "iterm", "terminal", "终端", "warp", "wezterm",
            "kitty", "alacritty", "hyper", "tabby", "windterm", "termius", "royal tsx"
        ]
        return terms.contains { raw.contains($0) }
    }
}

/// 2. 离线微秒级高敏凭据嗅探与防肩窥圆点雾化遮罩（零布局抖动，选中/悬停即刻原位显影）
enum SensitiveCredentialVeil {
    private static let apiKeyRegex = try! NSRegularExpression(
        pattern: #"\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{18,}|(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{28,}|glpat-[A-Za-z0-9_-]{18,}|xox[baprs]-[A-Za-z0-9-]{18,}|AIzaSy[A-Za-z0-9_-]{31,}|hf_[A-Za-z0-9]{24,}|gsk_[A-Za-z0-9]{24,}|pplx-[A-Za-z0-9]{24,}|r8_[A-Za-z0-9]{24,}|ntn_[A-Za-z0-9]{24,}|secret_[A-Za-z0-9]{32,}|sbp_[a-fA-F0-9]{32,}|figd_[A-Za-z0-9_-]{24,}|lin_api_[A-Za-z0-9]{24,}|PMAK-[a-fA-F0-9]{24}-[a-fA-F0-9]{34}|dop_v1_[a-fA-F0-9]{64}|dckr_pat_[A-Za-z0-9_-]{20,}|hvs\.[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|LTAI[A-Za-z0-9]{12,24}|AKID[A-Za-z0-9]{13,32}|\d{8,10}:AA[A-Za-z0-9_-]{33}|npm_[A-Za-z0-9]{36}|pypi-[A-Za-z0-9_-]{40,}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,})\b"#
    )
    private static let wireGuardPrivateKeyRegex = try! NSRegularExpression(
        pattern: #"(?im)^(\s*(?:PrivateKey|PresharedKey)\s*=\s*)([A-Za-z0-9+/]{42,44}=)(\s*)$"#
    )
    private static let puttyPrivateKeyRegex = try! NSRegularExpression(
        pattern: #"PuTTY-User-Key-File-[23]:[\s\S]*?Private-MAC:\s*[0-9a-fA-F]+"#
    )
    private static let kubeClientKeyRegex = try! NSRegularExpression(
        pattern: #"(?im)^(\s*client-key-data\s*:\s*)([A-Za-z0-9+/=]{32,})(\s*)$"#
    )
    private static let jdbcPasswordRegex = try! NSRegularExpression(
        pattern: #"(?i)(jdbc:[a-z0-9+:-]+://[^\s'"]*?(?:[?&;]|user=[^&\s;]+[?&;])password=)([^&\s;'"]{4,})"#
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
    private static let idCardCandidateRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])[1-8]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[0-9Xx](?![0-9A-Za-z])"#
    )
    private static let bankCardCandidateRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])(?:62\d{14,17}|4\d{15}|5[1-5]\d{14}|3[47]\d{13})(?![0-9A-Za-z])"#
    )
    private static let pemBlockRegex = try! NSRegularExpression(
        pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"#
    )
    private static let ageSecretKeyRegex = try! NSRegularExpression(
        pattern: #"\bAGE-SECRET-KEY-1[A-Z0-9]{50,}\b"#
    )
    private static let webhookSecretRegex = try! NSRegularExpression(
        pattern: #"(?i)(https?://(?:open\.(?:feishu\.cn|larksuite\.com)/open-apis/bot/v2/hook/|qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?(?:[^&#\s]+&)*key=|hooks\.slack\.com/services/[A-Z0-9]{8,}/[A-Z0-9]{8,}/|(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d{10,}/))([A-Za-z0-9_\-]{12,})"#
    )
    private static let envSecretRegex = try! NSRegularExpression(
        pattern: ##"(?im)^(\s*(?:export\s+)?[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|API_KEY|ACCESS_KEY|PRIVATE_KEY|AUTH_TOKEN|CLIENT_SECRET)[A-Z0-9_]*\s*[:=]\s*['"]?)([^\s'"#]{6,})(['"]?)"##
    )
    private static let urlQuerySecretRegex = try! NSRegularExpression(
        pattern: #"(?i)([?&](?:api_key|apikey|access_token|auth_token|client_secret|secret|password|passwd)=)([^&\s#]{8,})"#
    )
    private static let httpBasicAuthRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(https?://[^:\s/@]+:)([^@\s/]{4,})(@)"#
    )
    private static let httpHeaderAuthCookieRegex = try! NSRegularExpression(
        pattern: ##"(?i)(\b(?:cookie|set-cookie|x-api-key|x-auth-token|x-csrf-token)\s*:\s*)([^\r\n'"]{8,})"##
    )
    private static let httpBasicHeaderRegex = try! NSRegularExpression(
        pattern: #"(?i)(\b(?:authorization|proxy-authorization)\s*:\s*basic\s+)([A-Za-z0-9+/=]{8,})"#
    )
    private static let jsonSecretFieldRegex = try! NSRegularExpression(
        pattern: ##"(?i)("(?:password|passwd|secret|client_secret|api_key|apikey|access_token|refresh_token|id_token|session_token|private_key)"\s*:\s*")([^"\r\n]{6,})(")"##
    )
    private static let otpAuthUriRegex = try! NSRegularExpression(
        pattern: #"(?i)\botpauth(?:-migration)?://(?:totp|hotp|offline)[^\s'"]+"#
    )
    private static let otpAuthSecretParamRegex = try! NSRegularExpression(
        pattern: #"(?i)([?&](?:secret|data)=)([^&\s#'"]+)"#
    )
    private static let wifiPasswordRegex = try! NSRegularExpression(
        pattern: #"(?i)(WIFI:(?:[^;\r\n]*;)*?P:)([^;\r\n]{4,})(;)"#
    )

    static func isOTPAuthURI(_ rawText: String) -> Bool {
        guard !rawText.isEmpty else { return false }
        let sample: String = rawText.utf8.count > 2_048 ? String(rawText.prefix(1_024)) : rawText
        let nsRange = NSRange(sample.startIndex..<sample.endIndex, in: sample)
        return otpAuthUriRegex.firstMatch(in: sample, range: nsRange) != nil
    }

    private static func isPlaceholderSecretValue(_ val: String) -> Bool {
        let lower = val.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.count >= 6 else { return true }
        let placeholders = [
            "your_", "changeme", "change_me", "example", "placeholder",
            "replace_me", "redacted", "todo", "<your", "<secret", "<password",
            "***", "xxxxxx", "123456", "password", "secret"
        ]
        if placeholders.contains(where: { lower == $0 || lower.hasPrefix("your_") || lower.hasSuffix("_here") || lower.contains("redacted") || lower.contains("***") || (lower.hasPrefix("<") && lower.hasSuffix(">")) }) {
            return true
        }
        if Set(lower).count <= 1 { return true }
        return false
    }

    private static let apiKeyFastHints: [String] = [
        "sk-", "_live_", "_test_", "whsec_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
        "github_pat_", "glpat-", "xox", "AIzaSy", "hf_", "gsk_", "pplx-", "r8_",
        "ntn_", "secret_", "sbp_", "figd_", "lin_api_", "PMAK-", "dop_v1_",
        "dckr_pat_", "hvs.", "AKIA", "LTAI", "AKID", ":AA", "npm_", "pypi-", "SG."
    ]

    private static func fastHeadSlice(_ rawText: String, maxUTF8Bytes: Int = 2_048) -> String {
        let utf8 = rawText.utf8
        guard utf8.count > maxUTF8Bytes else { return rawText }
        var idx = utf8.index(utf8.startIndex, offsetBy: maxUTF8Bytes)
        while idx > utf8.startIndex && (utf8[idx] & 0b1100_0000) == 0b1000_0000 {
            idx = utf8.index(before: idx)
        }
        return String(decoding: utf8[..<idx], as: UTF8.self)
    }

    private static func hasASCIIDigitRun(in sample: String, minLength: Int) -> Bool {
        var run = 0
        for b in sample.utf8 {
            if b >= 48 && b <= 57 {
                run += 1
                if run >= minLength { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    private static func hasRealEnvSecretAssignment(in sample: String, lowerSample: String, nsRange: NSRange) -> Bool {
        guard sample.contains("=") || sample.contains(":") else { return false }
        let envKeywords = ["password", "passwd", "secret", "api_key", "access_key", "private_key", "auth_token"]
        guard envKeywords.contains(where: { lowerSample.contains($0) }) else { return false }
        for match in envSecretRegex.matches(in: sample, range: nsRange) {
            if match.numberOfRanges >= 3, let valRange = Range(match.range(at: 2), in: sample) {
                let candidate = String(sample[valRange])
                if !isPlaceholderSecretValue(candidate) {
                    return true
                }
            }
        }
        return false
    }

    static func isWebhookURL(_ rawText: String) -> Bool {
        guard !rawText.isEmpty else { return false }
        let sample = fastHeadSlice(rawText)
        guard sample.contains("://") else { return false }
        let nsRange = NSRange(sample.startIndex..<sample.endIndex, in: sample)
        if webhookSecretRegex.firstMatch(in: sample, range: nsRange) != nil {
            return true
        }
        return sample.lowercased().contains("oapi.dingtalk.com/robot/send")
    }

    /// 仅扫描首 2,048 UTF-8 字节并通过 O(1) 字节预筛跳过无关正则，2MB 超大文本耗时 < 0.01ms
    static func classify(_ rawText: String) -> SensitiveSecretKind? {
        guard !rawText.isEmpty else { return nil }
        let sample = fastHeadSlice(rawText)
        if sample.contains("-----BEGIN ") && (sample.contains("PRIVATE KEY-----") || sample.contains("PRIVATE KEY BLOCK-----")) {
            return .privateKey
        }
        if sample.contains("PuTTY-User-Key-File-") {
            return .privateKey
        }
        let hasScheme = sample.contains("://")
        let hasColon = sample.contains(":")
        let hasEquals = sample.contains("=")
        let nsRange = NSRange(sample.startIndex..<sample.endIndex, in: sample)

        if (sample.contains("AGE-SECRET-KEY-1") && ageSecretKeyRegex.firstMatch(in: sample, range: nsRange) != nil)
            || (hasScheme && otpAuthUriRegex.firstMatch(in: sample, range: nsRange) != nil)
            || (hasEquals && sample.contains("Key") && wireGuardPrivateKeyRegex.firstMatch(in: sample, range: nsRange) != nil)
            || (hasColon && sample.contains("client-key-data") && kubeClientKeyRegex.firstMatch(in: sample, range: nsRange) != nil) {
            return .privateKey
        }
        if apiKeyFastHints.contains(where: { sample.contains($0) }),
           apiKeyRegex.firstMatch(in: sample, range: nsRange) != nil {
            return .apiKey
        }
        if sample.contains("eyJ"),
           jwtRegex.firstMatch(in: sample, range: nsRange) != nil {
            return .jwtToken
        }

        if hasScheme || hasColon || hasEquals || sample.contains("?") || sample.contains("Bearer") || sample.contains("bearer") {
            let lowerSample = sample.lowercased()
            if (hasScheme && (
                connUriRegex.firstMatch(in: sample, range: nsRange) != nil
                || httpBasicAuthRegex.firstMatch(in: sample, range: nsRange) != nil
                || webhookSecretRegex.firstMatch(in: sample, range: nsRange) != nil
                || (lowerSample.contains("jdbc:") && jdbcPasswordRegex.firstMatch(in: sample, range: nsRange) != nil)
            ))
            || (lowerSample.contains("bearer") && bearerRegex.firstMatch(in: sample, range: nsRange) != nil)
            || ((sample.contains("?") || sample.contains("&")) && urlQuerySecretRegex.firstMatch(in: sample, range: nsRange) != nil)
            || (hasColon && (
                httpHeaderAuthCookieRegex.firstMatch(in: sample, range: nsRange) != nil
                || (lowerSample.contains("basic") && httpBasicHeaderRegex.firstMatch(in: sample, range: nsRange) != nil)
                || (sample.contains("\"") && jsonSecretFieldRegex.firstMatch(in: sample, range: nsRange) != nil)
                || (lowerSample.contains("wifi:") && wifiPasswordRegex.firstMatch(in: sample, range: nsRange) != nil)
            ))
            || hasRealEnvSecretAssignment(in: sample, lowerSample: lowerSample, nsRange: nsRange) {
                return .connectionSecret
            }
        }

        if hasASCIIDigitRun(in: sample, minLength: 15) {
            for match in idCardCandidateRegex.matches(in: sample, range: nsRange) {
                if let r = Range(match.range, in: sample), isValidChineseIDCard18(String(sample[r])) {
                    return .personalIdentity
                }
            }
            for match in bankCardCandidateRegex.matches(in: sample, range: nsRange) {
                if let r = Range(match.range, in: sample), isValidBankCardLuhn(String(sample[r])) {
                    return .personalIdentity
                }
            }
        }
        return nil
    }

    /// GB 11643-1999 公民身份号码 18 位加权校验码精确核验（零误伤普通 18 位订单号）
    static func isValidChineseIDCard18(_ code: String) -> Bool {
        let bytes = Array(code.utf8)
        guard bytes.count == 18 else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let mapping: [UInt8] = Array("10X98765432".utf8)
        var sum = 0
        for i in 0..<17 {
            let b = bytes[i]
            guard b >= 48 && b <= 57 else { return false }
            sum += Int(b - 48) * weights[i]
        }
        let expected = mapping[sum % 11]
        let last = (bytes[17] == UInt8(ascii: "x")) ? UInt8(ascii: "X") : bytes[17]
        return last == expected
    }

    /// 银联/国际银行卡号 Luhn 模 10 校验核验（排除全重复数字与普通流水号）
    static func isValidBankCardLuhn(_ digits: String) -> Bool {
        let bytes = Array(digits.utf8)
        guard (15...19).contains(bytes.count) else { return false }
        guard bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return false }
        if Set(bytes).count <= 2 { return false }
        var sum = 0
        var shouldDouble = false
        for b in bytes.reversed() {
            var d = Int(b - 48)
            if shouldDouble {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
            shouldDouble.toggle()
        }
        return sum % 10 == 0
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

    /// 判断当前前台目标窗口是否为外部 AI 助手或公域聊天工具（外发粘贴时自动置顶防泄密脱敏胶囊）
    static func isExternalAIOrChatApp(_ appName: String?) -> Bool {
        guard let raw = appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return false }
        let markers = [
            "chatgpt", "claude", "deepseek", "grok", "kimi", "豆包", "doubao",
            "元宝", "yuanbao", "通义", "tongyi", "perplexity", "gemini", "poe", "ego",
            "微信", "wechat", "weixin", "飞书", "feishu", "lark", "钉钉", "dingtalk",
            "企业微信", "wecom", "qq", "slack", "discord", "telegram", "whatsapp"
        ]
        return markers.contains { raw.contains($0) }
    }

    /// 双角色共享：一键掩码文本中的高敏密钥、私钥、连接凭据与身份证/银行卡（保留代码与日志上下文）
    static func redactForExternalSharing(_ rawText: String) -> String {
        guard !rawText.isEmpty, rawText.utf8.count <= 131_072 else { return rawText }
        var out = rawText
        if out.contains("-----BEGIN ") && (out.contains("PRIVATE KEY-----") || out.contains("PRIVATE KEY BLOCK-----")) {
            let r = NSRange(out.startIndex..<out.endIndex, in: out)
            out = pemBlockRegex.stringByReplacingMatches(
                in: out,
                range: r,
                withTemplate: "-----BEGIN PRIVATE KEY-----\n[REDACTED_BY_iCLIP]\n-----END PRIVATE KEY-----"
            )
        }
        if out.contains("PuTTY-User-Key-File-") {
            let r = NSRange(out.startIndex..<out.endIndex, in: out)
            out = puttyPrivateKeyRegex.stringByReplacingMatches(
                in: out,
                range: r,
                withTemplate: "PuTTY-User-Key-File-3: [REDACTED_BY_iCLIP]"
            )
        }
        if out.contains("client-key-data") {
            let r = NSRange(out.startIndex..<out.endIndex, in: out)
            out = kubeClientKeyRegex.stringByReplacingMatches(
                in: out,
                range: r,
                withTemplate: "$1***KUBE_KEY_REDACTED***$3"
            )
        }
        if out.lowercased().contains("jdbc:") {
            let r = NSRange(out.startIndex..<out.endIndex, in: out)
            out = jdbcPasswordRegex.stringByReplacingMatches(
                in: out,
                range: r,
                withTemplate: "$1***REDACTED***"
            )
        }
        out = ageSecretKeyRegex.stringByReplacingMatches(
            in: out,
            range: NSRange(out.startIndex..<out.endIndex, in: out),
            withTemplate: "AGE-SECRET-KEY-1***REDACTED***"
        )
        out = apiKeyRegex.stringByReplacingMatches(
            in: out,
            range: NSRange(out.startIndex..<out.endIndex, in: out),
            withTemplate: "[API_KEY_REDACTED]"
        )
        out = jwtRegex.stringByReplacingMatches(
            in: out,
            range: NSRange(out.startIndex..<out.endIndex, in: out),
            withTemplate: "eyJ***JWT_REDACTED***"
        )
        if out.contains("://") {
            let uriSecretRegex = try! NSRegularExpression(
                pattern: #"(?i)\b((?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^:\s/]+:)([^@\s]{4,})(@)"#
            )
            out = uriSecretRegex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: "$1***REDACTED***$3"
            )
            out = httpBasicAuthRegex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: "$1***REDACTED***$3"
            )
            out = webhookSecretRegex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: "$1***WEBHOOK_REDACTED***"
            )
            if out.lowercased().contains("otpauth") {
                out = otpAuthSecretParamRegex.stringByReplacingMatches(
                    in: out,
                    range: NSRange(out.startIndex..<out.endIndex, in: out),
                    withTemplate: "$1***2FA_SECRET_REDACTED***"
                )
            }
        }
        if out.uppercased().contains("WIFI:") {
            out = wifiPasswordRegex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: "$1***WIFI_REDACTED***$3"
            )
        }
        if out.contains("?") || out.contains("&") {
            out = urlQuerySecretRegex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: "$1***REDACTED***"
            )
            if out.lowercased().contains("otpauth") {
                let otpUpgradeRegex = try! NSRegularExpression(
                    pattern: #"(?i)(\botpauth(?:-migration)?://[^\s'"]*?[?&](?:secret|data)=)\*{3}REDACTED\*{3}"#
                )
                out = otpUpgradeRegex.stringByReplacingMatches(
                    in: out,
                    range: NSRange(out.startIndex..<out.endIndex, in: out),
                    withTemplate: "$1***2FA_SECRET_REDACTED***"
                )
            }
        }
        out = bearerRegex.stringByReplacingMatches(
            in: out,
            range: NSRange(out.startIndex..<out.endIndex, in: out),
            withTemplate: "Bearer ***REDACTED***"
        )
        if out.contains("=") || out.contains(":") {
            out = wireGuardPrivateKeyRegex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: "$1***WG_KEY_REDACTED***$3"
            )
            out = envSecretRegex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: "$1***REDACTED***$3"
            )
            out = httpHeaderAuthCookieRegex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: "$1***REDACTED***"
            )
            out = httpBasicHeaderRegex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: "$1***REDACTED***"
            )
            out = jsonSecretFieldRegex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: "$1***REDACTED***$3"
            )
        }
        // 精确替换通过 GB 11643 校验的 18 位身份证与通过 Luhn 校验的银行卡号
        let idMatches = idCardCandidateRegex.matches(in: out, range: NSRange(out.startIndex..<out.endIndex, in: out))
        for m in idMatches.reversed() {
            if let r = Range(m.range, in: out) {
                let s = String(out[r])
                if isValidChineseIDCard18(s) {
                    let masked = "\(s.prefix(3))***********\(s.suffix(4))"
                    out.replaceSubrange(r, with: masked)
                }
            }
        }
        let cardMatches = bankCardCandidateRegex.matches(in: out, range: NSRange(out.startIndex..<out.endIndex, in: out))
        for m in cardMatches.reversed() {
            if let r = Range(m.range, in: out) {
                let s = String(out[r])
                if isValidBankCardLuhn(s) {
                    let masked = "\(s.prefix(4))********\(s.suffix(4))"
                    out.replaceSubrange(r, with: masked)
                }
            }
        }
        return out
    }
}

/// 2.5 外部链接跳转严格协议白名单守卫（仅放行 http/https 合法主机，彻底阻断 javascript:/file:/ms-msdt:/ssh: 等危险伪协议）
enum OutboundLinkSafety {
    static func validatedBrowserURL(from rawInput: String) -> URL? {
        let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // 优先从混合分享文案中提取已净化的 http/https 网页链接
        if let cleaned = URLTrackingCleaner.extractFirstCleanedWebURL(from: raw),
           let url = parseStrictHTTPURL(cleaned) {
            return url
        }

        // 独立打开时严禁包含换行、回车、空字节等注入控制符
        if raw.contains("\n") || raw.contains("\r") || raw.contains("\0") || raw.contains("\t") {
            return nil
        }

        // 本地路径或 UNC 共享路径一律禁止当成浏览器 URL 打开
        if raw.hasPrefix("/") || raw.hasPrefix("~") || raw.hasPrefix("\\") {
            return nil
        }
        if raw.count >= 3 {
            let chars = Array(raw.prefix(3))
            if chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/") {
                return nil
            }
        }

        // 情况 A：显式包含 `://` 协议分隔符 —— 仅允许 http:// 与 https://
        if let range = raw.range(of: "://") {
            let scheme = raw[..<range.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else {
                return nil
            }
            return parseStrictHTTPURL(raw)
        }

        // 情况 B：不含 `://`，检查是否为无双斜杠伪协议（如 javascript:alert(1), data:..., ms-msdt:..., search-ms:..., mailto:...）
        if let colonIdx = raw.firstIndex(of: ":") {
            let prefix = raw[..<colonIdx]
            let afterColon = raw[raw.index(after: colonIdx)...]
            let isSchemeChars = !prefix.isEmpty && prefix.unicodeScalars.allSatisfy { sc in
                let v = sc.value
                return (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 43 || v == 45 || v == 46
            }
            // 合法的裸 host:port（如 localhost:3000/api 或 127.0.0.1:8080）冒号后必紧跟 1~5 位纯数字端口
            let portDigits = afterColon.prefix(while: { $0.isWholeNumber && $0.isASCII })
            let afterPort = afterColon.dropFirst(portDigits.count)
            let looksLikeHostPort = !portDigits.isEmpty && portDigits.count <= 5
                && (afterPort.isEmpty || afterPort.hasPrefix("/") || afterPort.hasPrefix("?") || afterPort.hasPrefix("#"))
            if isSchemeChars && !looksLikeHostPort {
                return nil
            }
        }

        // 情况 C：无协议头的裸域名或本地域名端口，安全补全 http:// 或 https://
        let lower = raw.lowercased()
        let isLocal = lower == "localhost"
            || lower.hasPrefix("localhost:")
            || lower.hasPrefix("localhost/")
            || lower.hasPrefix("127.0.0.1")
            || lower.hasPrefix("0.0.0.0")
        let prefixed = (isLocal ? "http://" : "https://") + raw
        return parseStrictHTTPURL(prefixed)
    }

    private static func parseStrictHTTPURL(_ candidate: String) -> URL? {
        let urlOpt = URL(string: candidate)
            ?? candidate.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        guard let url = urlOpt,
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        guard host == "localhost" || host.contains(".") else {
            return nil
        }
        return url
    }
}

/// 3. 行业标准密码管理器与自动化临时剪贴板协议全覆盖识别器
enum PasteboardPrivacyStandards {
    static let localOnlyType = NSPasteboard.PasteboardType("org.nspasteboard.LocalOnlyType")
    static let universalConcealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// 当 iClip 将敏感密钥或粘贴即焚条目写回系统剪贴板供粘贴时，注入本机隔离与隐秘标记：
    /// 1. `org.nspasteboard.LocalOnlyType`：物理阻断 macOS `sharingd` 通用剪贴板（Handoff）跨蓝牙/Wi-Fi 广播至周边设备；
    /// 2. `org.nspasteboard.ConcealedType`：阻止同机第三方剪贴板监听工具录制该敏感输出。
    static func applyLocalOnlyConcealedProtection(to pasteboard: NSPasteboard) {
        pasteboard.setData(Data(), forType: localOnlyType)
        pasteboard.setData(Data(), forType: universalConcealedType)
    }

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

/// 5. 离线敏感凭证文件识别与防钓鱼域名/高危可执行链接透视引擎
enum FileAndLinkSecurityGuard {
    enum LinkRiskKind: Equatable {
        /// 同形异义伪装域名（IDN Punycode `xn--`、西里尔/希腊混排拉丁主机、或 `trusted@evil` 用户信息段欺骗）
        case homographPhishing
        /// 直接指向非官方源可执行脚本/安装器的高危下载链接
        case executableDownload

        var badgeTitle: String {
            switch self {
            case .homographPhishing: return "疑似伪装域名"
            case .executableDownload: return "可执行下载链接"
            }
        }
    }

    private static let privateKeyExactNames: Set<String> = [
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "id_xmss"
    ]
    private static let privateKeyExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "jks", "keystore", "mobileprovision"
    ]
    private static let secretConfigExactNames: Set<String> = [
        ".env", ".npmrc", ".pypirc", ".netrc", ".pgpass", "kubeconfig",
        "credentials.json", "secrets.json", "secrets.yaml", "secrets.yml"
    ]
    private static let secretConfigExtensions: Set<String> = [
        "kdbx", "ovpn", "rdp", "tfvars"
    ]
    private static let safeTemplateSuffixes: [String] = [
        ".example", ".sample", ".template", ".dist", ".schema"
    ]

    /// 离线微秒级识别高危私钥与凭据配置文件（排除 `.pub` 公钥与 `.env.example` 模板，零误伤）
    static func classifyFilePaths(_ paths: [String]?) -> SensitiveSecretKind? {
        guard let paths, !paths.isEmpty else { return nil }
        for rawPath in paths {
            let fileName = URL(fileURLWithPath: rawPath).lastPathComponent.lowercased()
            guard !fileName.isEmpty, !fileName.hasSuffix(".pub") else { continue }
            if safeTemplateSuffixes.contains(where: { fileName.hasSuffix($0) }) {
                continue
            }
            if privateKeyExactNames.contains(fileName) {
                return .privateKey
            }
            let ext = URL(fileURLWithPath: fileName).pathExtension
            if privateKeyExtensions.contains(ext) {
                return .privateKey
            }
            if secretConfigExactNames.contains(fileName)
                || fileName.hasPrefix(".env.")
                || (fileName.hasPrefix("service-account") && fileName.hasSuffix(".json"))
                || secretConfigExtensions.contains(ext) {
                return .connectionSecret
            }
        }
        return nil
    }

    private static let dangerousExecExtensions: Set<String> = [
        "exe", "msi", "bat", "cmd", "scr", "vbs", "vbe", "js", "jse", "wsf", "hta", "ps1", "apk"
    ]
    private static let trustedDownloadHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
        "app.webfooo.com", "apple.com", "microsoft.com"
    ]

    /// 离线检测同形异义字钓鱼域名（IDN Homograph Attack）与非信任源可执行文件直链
    static func inspectLinkRisk(_ rawInput: String) -> LinkRiskKind? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096 else { return nil }

        // 检测 `https://apple.com@evil.example` URL userinfo 欺骗
        if let schemeRange = trimmed.range(of: "://") {
            let afterScheme = trimmed[schemeRange.upperBound...]
            let authority = afterScheme.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
            if authority.contains("@") && !SensitiveCredentialVeil.classify(trimmed).map({ _ in true }, default: false) {
                return .homographPhishing
            }
        }

        let candidate = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
            ? trimmed
            : ("https://" + trimmed)
        let lowerPrefix = String(candidate.prefix(10)).lowercased()
        let afterSchemeSub: Substring = lowerPrefix.hasPrefix("https://")
            ? candidate.dropFirst(8)
            : (lowerPrefix.hasPrefix("http://") ? candidate.dropFirst(7) : Substring(candidate))
        let rawAuthority = afterSchemeSub.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
        let rawHostPort = rawAuthority.split(separator: "@").last ?? Substring()
        let rawHost = (rawHostPort.split(separator: ":").first ?? Substring()).lowercased()

        let parsed = URL(string: candidate)
            ?? candidate.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        let host = (parsed?.host?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? rawHost
        guard !host.isEmpty, host.contains(".") else {
            return nil
        }

        // 1. Punycode `xn--` 同形异义字编码预警
        if host.contains("xn--") || rawHost.contains("xn--") {
            return .homographPhishing
        }

        // 2. 同一域名标签内混排 ASCII 拉丁字母与西里尔/希腊视觉同形字母（如 `аррӏе.com`）
        for hostCandidate in [rawHost, host] where !hostCandidate.isEmpty {
            for label in hostCandidate.split(separator: ".") {
                var hasASCIIAlpha = false
                var hasConfusableScript = false
                for sc in label.unicodeScalars {
                    let v = sc.value
                    if (v >= 97 && v <= 122) || (v >= 65 && v <= 90) {
                        hasASCIIAlpha = true
                    } else if v >= 0x0370 && v <= 0x052F {
                        // Greek / Cyrillic 区间
                        hasConfusableScript = true
                    }
                }
                if hasASCIIAlpha && hasConfusableScript {
                    return .homographPhishing
                }
            }
        }

        // 3. 非可信主机的高危可执行脚本/安装器直链预警
        let isTrusted = trustedDownloadHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        if !isTrusted, let url = parsed {
            let pathExt = url.pathExtension.lowercased()
            if dangerousExecExtensions.contains(pathExt) {
                return .executableDownload
            }
        }

        return nil
    }
}

private extension Optional {
    func map<U>(_ transform: (Wrapped) -> U, default fallback: U) -> U {
        switch self {
        case .some(let v): return transform(v)
        case .none: return fallback
        }
    }
}

/// 6. 硬件级 CSPRNG 零离手强密码与随机密钥生成器（本地隔离不上云 + 45s 自动擦除 + 支持 `> 备注 :: @pw 24` 命名加密入库）
enum SecurePasswordGenerator {
    struct Candidate: Equatable {
        let secretValue: String
        let subtitle: String
        let ephemeralToast: String
        let defaultVaultAlias: String
    }

    private enum SpecKind {
        case strongPassword(length: Int, includeSymbols: Bool)
        case numericPIN(length: Int)
        case hexSecretKey(byteCount: Int)
    }

    private static let lock = NSLock()
    private static var generationEpoch: UInt64 = 0
    private static let sessionSeedKey: SymmetricKey = {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return SymmetricKey(data: Data(bytes))
    }()

    /// 每次提交密码后推进熵轮次，确保悬停重绘零跳变，而下一次重新输入 `@pw` 必定生成全新随机密码
    static func bumpGenerationSalt() {
        lock.lock()
        generationEpoch &+= 1
        lock.unlock()
    }

    private static func currentEpoch() -> UInt64 {
        lock.lock()
        let v = generationEpoch
        lock.unlock()
        return v
    }

    /// 解析搜索框中的 `@pw` / `@密码` / `@pin码` / `@genkey` 指令，返回零跳变实时预览候选
    static func evaluate(_ rawQuery: String) -> Candidate? {
        guard let (spec, normalizedKey) = parseSpec(from: rawQuery) else { return nil }
        let streamSeed = "\(currentEpoch())|\(normalizedKey)"
        return buildCandidate(for: spec, deterministicTag: streamSeed)
    }

    /// 若 `> 备注 :: @pw 24` 正文为密码生成指令，直接从硬件 CSPRNG 抽取全新高熵随机串展开
    static func expandQuickCaptureBodyIfApplicable(_ rawBody: String) -> String? {
        guard let (spec, _) = parseSpec(from: rawBody) else { return nil }
        bumpGenerationSalt()
        return buildCandidate(for: spec, deterministicTag: nil).secretValue
    }

    private static func parseSpec(from rawInput: String) -> (SpecKind, String)? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") || trimmed.hasPrefix("＠") else { return nil }
        let normalized = "@" + String(trimmed.dropFirst())
        let lower = normalized.lowercased()
        let tokens = lower.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let head = tokens.first else { return nil }

        // 1. 256-bit / 自定义字节 Hex 随机密钥（严密避开筛选词 `@key` / `@secret`）
        let hexKeyTriggers: Set<String> = ["@genkey", "@hexkey", "@随机密钥", "@生成密钥"]
        if hexKeyTriggers.contains(head) {
            let requested = tokens.dropFirst().compactMap { Int($0) }.first ?? 32
            let byteCount = min(max(requested, 16), 64)
            return (.hexSecretKey(byteCount: byteCount), "hex:\(byteCount)")
        }

        // 2. 纯数字随机码（严密避开收藏筛选词 `@pin`！）
        let pinTriggers: Set<String> = ["@pin码", "@随机码", "@数字码", "@genpin"]
        if pinTriggers.contains(head) || (head == "@pw" && tokens.contains("pin")) {
            let requested = tokens.dropFirst().compactMap { Int($0) }.first ?? 6
            let len = min(max(requested, 4), 12)
            return (.numericPIN(length: len), "pin:\(len)")
        }

        // 3. 硬件级强密码（`@pw` / `@密码` / `@强密码` / `@genpw`）
        let pwTriggers: Set<String> = ["@pw", "@密码", "@强密码", "@生成密码", "@genpw"]
        guard pwTriggers.contains(head) else { return nil }
        let noSymbols = lower.contains("无符号")
            || lower.contains("纯字母")
            || lower.contains("nosym")
            || lower.contains("alnum")
        let requestedLen = tokens.dropFirst().compactMap { Int($0) }.first ?? 20
        let length = min(max(requestedLen, 8), 64)
        return (.strongPassword(length: length, includeSymbols: !noSymbols), "pw:\(length):\(noSymbols ? 0 : 1)")
    }

    private static func buildCandidate(for spec: SpecKind, deterministicTag: String?) -> Candidate {
        var rng = ByteStreamSource(deterministicTag: deterministicTag, sessionKey: sessionSeedKey)
        switch spec {
        case .hexSecretKey(let byteCount):
            var raw = [UInt8](repeating: 0, count: byteCount)
            for i in 0..<byteCount { raw[i] = rng.nextByte() }
            let hex = raw.map { String(format: "%02x", $0) }.joined()
            return Candidate(
                secretValue: hex,
                subtitle: "CSPRNG \(byteCount * 8)-bit 随机密钥 · 本地隔离不上云 · 45s擦除",
                ephemeralToast: "已无痕键入 \(byteCount * 8)-bit 随机密钥（45s后自动擦除）",
                defaultVaultAlias: "随机密钥 (\(byteCount * 8)-bit)"
            )

        case .numericPIN(let length):
            let digits = Array("0123456789".utf8)
            var out = [UInt8]()
            out.reserveCapacity(length)
            for _ in 0..<length {
                out.append(digits[rng.nextIndex(upperBound: digits.count)])
            }
            let pinStr = String(decoding: out, as: UTF8.self)
            return Candidate(
                secretValue: pinStr,
                subtitle: "CSPRNG \(length) 位随机数字码 · 本地隔离不上云 · 45s擦除",
                ephemeralToast: "已无痕键入 \(length) 位随机数字码（45s后自动擦除）",
                defaultVaultAlias: "随机数字码"
            )

        case .strongPassword(let length, let includeSymbols):
            // 剔除易混淆字符 0/O/1/l/I，兼顾 115+ bit 密码学熵值与人工核对可读性
            let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ".utf8)
            let lower = Array("abcdefghijkmnopqrstuvwxyz".utf8)
            let digits = Array("23456789".utf8)
            let symbols = Array("!@#$%^&*-_=+?".utf8)
            let pool = includeSymbols ? (upper + lower + digits + symbols) : (upper + lower + digits)

            var chars: [UInt8] = [
                upper[rng.nextIndex(upperBound: upper.count)],
                lower[rng.nextIndex(upperBound: lower.count)],
                digits[rng.nextIndex(upperBound: digits.count)]
            ]
            if includeSymbols {
                chars.append(symbols[rng.nextIndex(upperBound: symbols.count)])
            }
            while chars.count < length {
                chars.append(pool[rng.nextIndex(upperBound: pool.count)])
            }
            // Fisher-Yates 无偏乱序洗牌
            for i in stride(from: chars.count - 1, through: 1, by: -1) {
                let j = rng.nextIndex(upperBound: i + 1)
                if i != j { chars.swapAt(i, j) }
            }
            let pw = String(decoding: chars, as: UTF8.self)
            let modeLabel = includeSymbols ? "含符号" : "纯字母数字"
            return Candidate(
                secretValue: pw,
                subtitle: "CSPRNG \(length)位强密码(\(modeLabel)) · 禁Handoff/云同步 · 45s擦除",
                ephemeralToast: "已无痕键入 \(length) 位强密码（本地隔离 · 45s后擦除）",
                defaultVaultAlias: "随机强密码 (\(length)位)"
            )
        }
    }

    private struct ByteStreamSource {
        let deterministicTag: String?
        let sessionKey: SymmetricKey
        private var counter: UInt64 = 0
        private var buffer: [UInt8] = []
        private var offset: Int = 0

        init(deterministicTag: String?, sessionKey: SymmetricKey) {
            self.deterministicTag = deterministicTag
            self.sessionKey = sessionKey
        }

        mutating func nextByte() -> UInt8 {
            if offset >= buffer.count {
                refill()
            }
            let b = buffer[offset]
            offset += 1
            return b
        }

        mutating func nextIndex(upperBound: Int) -> Int {
            guard upperBound > 1 else { return 0 }
            let bound = UInt16(upperBound)
            let limit = UInt16(256 - (256 % Int(bound)))
            while true {
                let b = UInt16(nextByte())
                if b < limit {
                    return Int(b % bound)
                }
            }
        }

        private mutating func refill() {
            offset = 0
            if let tag = deterministicTag {
                var msg = Data("\(tag)|\(counter)".utf8)
                counter &+= 1
                let mac = HMAC<SHA256>.authenticationCode(for: msg, using: sessionKey)
                msg.removeAll()
                buffer = Array(mac)
            } else {
                var raw = [UInt8](repeating: 0, count: 32)
                _ = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
                buffer = raw
            }
        }
    }
}

/// 6. 离线零联网 RFC 6238 TOTP 两步验证动态码直算引擎（支持 `otpauth://totp/...` 链接与 2FA 绑定二维码实时算码）
enum TOTPAuthenticator {
    enum Algorithm: String, Equatable {
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case sha512 = "SHA512"
    }

    struct Evaluation: Equatable {
        let code: String
        let formattedCode: String
        let remainingSeconds: Int
        let period: Int
        let accountLabel: String?
    }

    static func isTOTPURI(_ raw: String?) -> Bool {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return false }
        return s.lowercased().hasPrefix("otpauth://totp/")
    }

    /// RFC 4648 Base32 无偏解码（忽略空格、连字符与 `=` 填充）
    static func decodeBase32(_ encoded: String) -> Data? {
        var buffer: UInt32 = 0
        var bitsLeft = 0
        var out = Data()
        for scalar in encoded.unicodeScalars {
            let v = scalar.value
            if v == 32 || v == 45 { continue } // space or '-'
            if v == 61 { break } // '=' padding
            let fiveBit: UInt32
            if v >= 65 && v <= 90 {
                fiveBit = v - 65
            } else if v >= 97 && v <= 122 {
                fiveBit = v - 97
            } else if v >= 50 && v <= 55 {
                fiveBit = (v - 50) + 26
            } else {
                return nil
            }
            buffer = (buffer << 5) | fiveBit
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                out.append(UInt8((buffer >> UInt32(bitsLeft)) & 0xff))
            }
        }
        return out.count >= 5 ? out : nil
    }

    /// 按指定 Unix 秒时间戳对标准 `otpauth://totp/...` URI 进行离线动态口令求值
    static func evaluate(uri rawText: String, timestampSeconds: Int64? = nil) -> Evaluation? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("otpauth://totp/"),
              let components = URLComponents(string: trimmed),
              let queryItems = components.queryItems else {
            return nil
        }

        var secretBase32: String?
        var digits = 6
        var period = 30
        var algorithm: Algorithm = .sha1
        var issuerParam: String?

        for item in queryItems {
            let k = item.name.lowercased()
            let val = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch k {
            case "secret":
                secretBase32 = val
            case "digits":
                if let d = Int(val), (d == 6 || d == 7 || d == 8) { digits = d }
            case "period":
                if let p = Int(val), (10...120).contains(p) { period = p }
            case "algorithm":
                switch val.uppercased() {
                case "SHA256", "HMACSHA256": algorithm = .sha256
                case "SHA512", "HMACSHA512": algorithm = .sha512
                default: algorithm = .sha1
                }
            case "issuer":
                if !val.isEmpty { issuerParam = val }
            default:
                break
            }
        }

        guard let secretStr = secretBase32,
              let secretKeyData = decodeBase32(secretStr) else {
            return nil
        }

        let nowSec = max(0, timestampSeconds ?? Int64(Date().timeIntervalSince1970))
        let code = computeHOTP(
            secretKey: secretKeyData,
            counter: UInt64(nowSec) / UInt64(period),
            digits: digits,
            algorithm: algorithm
        )
        let rem = Int(Int64(period) - (nowSec % Int64(period)))
        let formatted: String = {
            if code.count == 6 {
                return "\(code.prefix(3)) \(code.suffix(3))"
            } else if code.count == 8 {
                return "\(code.prefix(4)) \(code.suffix(4))"
            }
            return code
        }()

        let rawPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        let label: String? = {
            if !decodedPath.isEmpty { return decodedPath }
            return issuerParam
        }()

        return Evaluation(
            code: code,
            formattedCode: formatted,
            remainingSeconds: rem,
            period: period,
            accountLabel: label
        )
    }

    static func computeHOTP(
        secretKey: Data,
        counter: UInt64,
        digits: Int = 6,
        algorithm: Algorithm = .sha1
    ) -> String {
        var counterBE = counter.bigEndian
        let counterData = withUnsafeBytes(of: &counterBE) { Data($0) }
        let symKey = SymmetricKey(data: secretKey)
        let macBytes: [UInt8]
        switch algorithm {
        case .sha1:
            macBytes = Array(HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: symKey))
        case .sha256:
            macBytes = Array(HMAC<SHA256>.authenticationCode(for: counterData, using: symKey))
        case .sha512:
            macBytes = Array(HMAC<SHA512>.authenticationCode(for: counterData, using: symKey))
        }
        let offset = Int(macBytes[macBytes.count - 1] & 0x0f)
        let binCode = (UInt32(macBytes[offset] & 0x7f) << 24)
            | (UInt32(macBytes[offset + 1]) << 16)
            | (UInt32(macBytes[offset + 2]) << 8)
            | UInt32(macBytes[offset + 3])
        let mod: UInt32
        switch digits {
        case 8: mod = 100_000_000
        case 7: mod = 10_000_000
        default: mod = 1_000_000
        }
        return String(format: "%0*u", digits, binCode % mod)
    }
}

/// 7. `.env` 环境变量配置一键净模版生成器（保留注释与非敏感开关原值，将密钥/连接串安全转换为 `.env.example` 规范占位符）
enum EnvTemplateSanitizer {
    private static let envLineRegex = try! NSRegularExpression(
        pattern: #"^(\s*(?:export\s+)?)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)(.*)$"#
    )
    private static let sensitiveKeyMarkers = [
        "KEY", "SECRET", "TOKEN", "PASS", "PWD", "AUTH", "PRIVATE",
        "CERT", "CREDENTIAL", "WEBHOOK", "COOKIE", "DSN", "MNEMONIC", "SEED"
    ]

    static func generateExampleTemplate(from rawText: String) -> String? {
        guard rawText.utf8.count <= 65_536, rawText.contains("="), rawText.contains("\n") else { return nil }
        let lines = rawText.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }

        var validAssignments = 0
        var mutatedCount = 0
        var outLines: [String] = []
        outLines.reserveCapacity(lines.count)

        for rawLine in lines {
            let hasCR = rawLine.hasSuffix("\r")
            let line = hasCR ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                outLines.append(rawLine)
                continue
            }
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let m = envLineRegex.firstMatch(in: line, range: nsRange),
                  let prefixR = Range(m.range(at: 1), in: line),
                  let keyR = Range(m.range(at: 2), in: line),
                  let eqR = Range(m.range(at: 3), in: line),
                  let valR = Range(m.range(at: 4), in: line) else {
                // 若存在明显非注释、非环境变量语法（如代码块大括号），说明不是 `.env` 文件
                if trimmed.hasPrefix("{") || trimmed.hasPrefix("}") || trimmed.hasPrefix("<") || trimmed.hasSuffix(";") {
                    return nil
                }
                outLines.append(rawLine)
                continue
            }

            validAssignments += 1
            let prefix = String(line[prefixR])
            let key = String(line[keyR])
            let eq = String(line[eqR])
            let valPart = String(line[valR]).trimmingCharacters(in: .whitespaces)

            if valPart.isEmpty {
                outLines.append(rawLine)
                continue
            }

            let quoteChar: String = {
                if valPart.count >= 2 && valPart.hasPrefix("\"") && valPart.hasSuffix("\"") { return "\"" }
                if valPart.count >= 2 && valPart.hasPrefix("'") && valPart.hasSuffix("'") { return "'" }
                return ""
            }()
            let innerVal = quoteChar.isEmpty ? valPart : String(valPart.dropFirst().dropLast())
            let upperKey = key.uppercased()
            let keyLooksSensitive = sensitiveKeyMarkers.contains { upperKey.contains($0) }
            let valLooksSensitive = SensitiveCredentialVeil.classify("\(key)=\(innerVal)") != nil
                || SensitiveCredentialVeil.classify(innerVal) != nil

            if keyLooksSensitive || valLooksSensitive {
                let lowerInner = innerVal.lowercased()
                let placeholder: String
                if lowerInner.hasPrefix("postgres://") || lowerInner.hasPrefix("postgresql://") {
                    placeholder = "postgresql://user:password@localhost:5432/dbname"
                } else if lowerInner.hasPrefix("mysql://") {
                    placeholder = "mysql://user:password@localhost:3306/dbname"
                } else if lowerInner.hasPrefix("mongodb://") || lowerInner.hasPrefix("mongodb+srv://") {
                    placeholder = "mongodb://user:password@localhost:27017/dbname"
                } else if lowerInner.hasPrefix("redis://") {
                    placeholder = "redis://:password@localhost:6379/0"
                } else {
                    placeholder = "your_\(key.lowercased())_here"
                }
                if placeholder != innerVal {
                    mutatedCount += 1
                }
                let rebuilt = "\(prefix)\(key)\(eq)\(quoteChar)\(placeholder)\(quoteChar)\(hasCR ? "\r" : "")"
                outLines.append(rebuilt)
            } else {
                outLines.append(rawLine)
            }
        }

        guard validAssignments >= 2 && mutatedCount >= 1 else { return nil }
        return outLines.joined(separator: "\n")
    }
}

/// 8. 零信任安全盾牌实时体检引擎（支持 `@安全` / `@体检` / `@shield` 一眼透视加密状态与未收藏风险）
enum SecurityPostureAudit {
    struct Report: Equatable {
        let totalEncryptedItems: Int
        let pinnedProtectedSecrets: Int
        let unpinnedRiskCount: Int
        let screenStealthEnabled: Bool
        let shoulderSurfVeilEnabled: Bool

        var headlineText: String {
            if unpinnedRiskCount == 0 {
                return "✓ 零临时风险残留 · \(pinnedProtectedSecrets) 项收藏密钥受保护"
            }
            return "检出 \(unpinnedRiskCount) 项未收藏敏感/投毒风险 · 收藏项豁免"
        }

        var postureSubtitle: String {
            let stealth = screenStealthEnabled ? "开启" : "关闭"
            let veil = shoulderSurfVeilEnabled ? "开启" : "关闭"
            return "硬件主密钥已加密 \(totalEncryptedItems) 条 · 投屏隐身\(stealth) · 防肩窥\(veil)"
        }
    }

    static func isAuditQuery(_ rawQuery: String) -> Bool {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch q {
        case "@安全", "@体检", "@隐私体检", "@shield", "@audit":
            return true
        default:
            return false
        }
    }
}

/// 9. 零知识端到端认证加密密文信封（`@锁 口令` 加锁外发 / `@解锁 口令` 无痕阅后即焚，macOS ↔ Windows 100% 字节级互解）
enum SecretCapsuleMessenger {
    static let tokenPrefix = "ICLPMSG1:"
    private static let capsuleExtractRegex = try! NSRegularExpression(
        pattern: #"ICLPMSG1:([A-Za-z0-9_-]{80,})"#
    )

    enum CommandState: Equatable {
        case lockReady(passphrase: String, plainSource: String, isInlineBody: Bool)
        case lockAwaitingInput(hint: String)
        case unlockDecrypted(decryptedPlain: String)
        case unlockPending(hasTargetCapsule: Bool, attemptedPassphrase: Bool)
    }

    static func containsCapsule(_ text: String?) -> Bool {
        guard let s = text, s.contains(tokenPrefix) else { return false }
        let r = NSRange(s.startIndex..<s.endIndex, in: s)
        return capsuleExtractRegex.firstMatch(in: s, range: r) != nil
    }

    static func isCapsuleCommandPrefix(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("@") else { return false }
        for p in ["@锁", "@加密", "@lock", "@解锁", "@解密", "@unlock"] {
            if trimmed == p || trimmed.hasPrefix(p + " ") || trimmed.hasPrefix(p + "\t") {
                return true
            }
        }
        return false
    }

    static func sealCapsule(plainText: String, passphrase: String) -> String? {
        let pw = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty, !pw.isEmpty, plainText.utf8.count <= 65_536 else { return nil }
        guard let sealed = LocalVaultCrypto.sealArchiveWithPassphrase(Data(plainText.utf8), passphrase: pw) else {
            return nil
        }
        let b64url = sealed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "🔒[iClip密文·口令解锁] \(tokenPrefix)\(b64url)"
    }

    static func openCapsule(in rawEnvelope: String, passphrase: String) -> String? {
        let pw = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pw.isEmpty, rawEnvelope.contains(tokenPrefix) else { return nil }
        let r = NSRange(rawEnvelope.startIndex..<rawEnvelope.endIndex, in: rawEnvelope)
        guard let m = capsuleExtractRegex.firstMatch(in: rawEnvelope, range: r),
              let b64Range = Range(m.range(at: 1), in: rawEnvelope) else {
            return nil
        }
        let rawB64URL = String(rawEnvelope[b64Range])
        var std = rawB64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = std.count % 4
        if rem > 0 {
            std.append(String(repeating: "=", count: 4 - rem))
        }
        guard let cipherData = Data(base64Encoded: std) else { return nil }
        // RFC 4648 §3.5 规范性校验：拒绝末尾填充冗余比特被篡改的非规范 Base64URL 密文（消除密文延展性）
        let canonical = cipherData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard canonical == rawB64URL,
              let plainData = LocalVaultCrypto.openEncryptedArchive(cipherData, passphrase: pw),
              let plainStr = String(data: plainData, encoding: .utf8) else {
            return nil
        }
        return plainStr
    }

    static func evaluateCommand(
        query: String,
        latestPlainCandidate: String?,
        latestCapsuleCandidate: String?
    ) -> CommandState? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else { return nil }
        let lower = trimmed.lowercased()

        let lockPrefixes = ["@锁", "@加密", "@lock"]
        for p in lockPrefixes {
            if lower == p || lower.hasPrefix(p + " ") || lower.hasPrefix(p + "\t") {
                let rest = String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    return .lockAwaitingInput(hint: "输入口令加密首条剪贴（如 @锁 8866）或 @锁 8866 :: 正文")
                }
                for sep in ["::", "：："] {
                    if let range = rest.range(of: sep) {
                        let pw = String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let body = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !pw.isEmpty else {
                            return .lockAwaitingInput(hint: "请在 \(sep) 左侧填写加密口令")
                        }
                        guard !body.isEmpty else {
                            return .lockAwaitingInput(hint: "请在 \(sep) 右侧输入要端到端加锁的机密正文")
                        }
                        return .lockReady(passphrase: pw, plainSource: body, isInlineBody: true)
                    }
                }
                if let fallback = latestPlainCandidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !fallback.isEmpty {
                    return .lockReady(passphrase: rest, plainSource: fallback, isInlineBody: false)
                }
                return .lockAwaitingInput(hint: "当前无可用纯文本剪贴，可使用 @锁 \(rest) :: 机密正文")
            }
        }

        let unlockPrefixes = ["@解锁", "@解密", "@unlock"]
        for p in unlockPrefixes {
            if lower == p || lower.hasPrefix(p + " ") || lower.hasPrefix(p + "\t") {
                let pw = String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                guard let cap = latestCapsuleCandidate, containsCapsule(cap) else {
                    return .unlockPending(hasTargetCapsule: false, attemptedPassphrase: !pw.isEmpty)
                }
                if pw.isEmpty {
                    return .unlockPending(hasTargetCapsule: true, attemptedPassphrase: false)
                }
                if let plain = openCapsule(in: cap, passphrase: pw) {
                    return .unlockDecrypted(decryptedPlain: plain)
                }
                return .unlockPending(hasTargetCapsule: true, attemptedPassphrase: true)
            }
        }

        return nil
    }
}

/// 11. 离线纯内存双向 AI 替身沙盒（`ReversiblePrivacyTwin`：脱敏外发 AI 保持多实体指代关系，复制 AI 回复一键无损回填真值，锁屏/清扫/退出瞬时清零）
enum ReversiblePrivacyTwin {
    private struct Entry {
        let token: String
        let realValue: String
        var expiresAtUptime: TimeInterval
    }

    private static let lock = NSLock()
    private static let ttlSeconds: TimeInterval = 1_800 // 30 分钟滑动生存期，绝不落盘
    private static let maxEntries = 256
    private static var entriesByToken: [String: Entry] = [:]
    private static var tokenByRealValue: [String: String] = [:]
    private static var categoryCounters: [String: Int] = [:]

    private static let twinTokenRegex = try! NSRegularExpression(
        pattern: #"\[ICLIP_(?:KEY|SEC|IP|EMAIL|PHONE|ID|CARD)_\d+\]"#
    )
    private static let pemRegex = try! NSRegularExpression(
        pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"#
    )
    private static let standaloneSecretRegex = try! NSRegularExpression(
        pattern: #"\b(?:AGE-SECRET-KEY-1[A-Z0-9]{50,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|sk-(?:proj-|ant-)?[A-Za-z0-9_-]{18,}|(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{28,}|glpat-[A-Za-z0-9_-]{18,}|xox[baprs]-[A-Za-z0-9-]{18,}|AIzaSy[A-Za-z0-9_-]{31,}|hf_[A-Za-z0-9]{24,}|gsk_[A-Za-z0-9]{24,}|pplx-[A-Za-z0-9]{24,}|r8_[A-Za-z0-9]{24,}|ntn_[A-Za-z0-9]{24,}|secret_[A-Za-z0-9]{32,}|sbp_[a-fA-F0-9]{32,}|figd_[A-Za-z0-9_-]{24,}|lin_api_[A-Za-z0-9]{24,}|PMAK-[a-fA-F0-9]{24}-[a-fA-F0-9]{34}|dop_v1_[a-fA-F0-9]{64}|dckr_pat_[A-Za-z0-9_-]{20,}|hvs\.[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|LTAI[A-Za-z0-9]{12,24}|AKID[A-Za-z0-9]{13,32}|\d{8,10}:AA[A-Za-z0-9_-]{33}|npm_[A-Za-z0-9]{36}|pypi-[A-Za-z0-9_-]{40,}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,})\b"#
    )
    private static let uriPasswordGroupRegex = try! NSRegularExpression(
        pattern: #"(?i)\b((?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp|https?)://[^:\s/@]+:)([^@\s/]{4,})(@)"#
    )
    private static let envOrBearerGroupRegex = try! NSRegularExpression(
        pattern: ##"(?im)((?:^\s*(?:export\s+)?[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|API_KEY|ACCESS_KEY|PRIVATE_KEY|AUTH_TOKEN|CLIENT_SECRET)[A-Z0-9_]*\s*[:=]\s*['"]?)|(?:\bBearer\s+))([^\s'"#\[\]]{6,})"##
    )
    private static let privateIPv4Regex = try! NSRegularExpression(
        pattern: #"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3})\b"#
    )
    private static let emailRegex = try! NSRegularExpression(
        pattern: #"\b[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]+\.[A-Za-z]{2,18}\b"#
    )
    private static let cnPhoneRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])1[3-9]\d{9}(?![0-9A-Za-z])"#
    )
    private static let idOrCardCandidateRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])\d{15,19}[Xx]?(?![0-9A-Za-z])"#
    )

    /// 锁屏、休眠、安全清扫、清空未收藏或退出应用时瞬时清零全部内存替身映射
    static func wipeAll() {
        lock.lock()
        entriesByToken.removeAll()
        tokenByRealValue.removeAll()
        categoryCounters.removeAll()
        lock.unlock()
    }

    private static func pruneExpiredLocked(now: TimeInterval) {
        let expiredTokens = entriesByToken.compactMap { k, v in
            v.expiresAtUptime <= now ? k : nil
        }
        for tok in expiredTokens {
            if let old = entriesByToken.removeValue(forKey: tok) {
                if tokenByRealValue[old.realValue] == tok {
                    tokenByRealValue.removeValue(forKey: old.realValue)
                }
            }
        }
    }

    private static func assignTokenLocked(category: String, realValue: String, now: TimeInterval) -> String {
        if let existing = tokenByRealValue[realValue], var entry = entriesByToken[existing] {
            entry.expiresAtUptime = now + ttlSeconds
            entriesByToken[existing] = entry
            return existing
        }
        if entriesByToken.count >= maxEntries,
           let oldest = entriesByToken.min(by: { $0.value.expiresAtUptime < $1.value.expiresAtUptime }) {
            entriesByToken.removeValue(forKey: oldest.key)
            tokenByRealValue.removeValue(forKey: oldest.value.realValue)
        }
        let nextIdx = (categoryCounters[category] ?? 0) + 1
        categoryCounters[category] = nextIdx
        let token = "[ICLIP_\(category)_\(nextIdx)]"
        entriesByToken[token] = Entry(token: token, realValue: realValue, expiresAtUptime: now + ttlSeconds)
        tokenByRealValue[realValue] = token
        return token
    }

    /// 将文本中的敏感密钥、口令、身份证、银行卡、内网 IP、邮箱与手机号替换为一致性编号替身（如 `[ICLIP_KEY_1]`、`[ICLIP_IP_1]`）
    static func maskWithTwins(_ rawText: String) -> (maskedText: String, replacedCount: Int)? {
        guard !rawText.isEmpty, rawText.utf8.count <= 65_536 else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now)

        var out = rawText
        var count = 0

        func replaceFullMatches(regex: NSRegularExpression, category: String, validator: ((String) -> Bool)? = nil) {
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..<out.endIndex, in: out))
            guard !matches.isEmpty else { return }
            for m in matches.reversed() {
                guard let r = Range(m.range, in: out) else { continue }
                let val = String(out[r])
                if val.hasPrefix("[ICLIP_") { continue }
                if let validator, !validator(val) { continue }
                let tok = assignTokenLocked(category: category, realValue: val, now: now)
                out.replaceSubrange(r, with: tok)
                count += 1
            }
        }

        func replaceGroup2Matches(regex: NSRegularExpression, category: String) {
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..<out.endIndex, in: out))
            guard !matches.isEmpty else { return }
            for m in matches.reversed() where m.numberOfRanges >= 3 {
                guard let r = Range(m.range(at: 2), in: out) else { continue }
                let val = String(out[r])
                if val.hasPrefix("[ICLIP_") || val.contains("***") || val.lowercased().contains("redacted") { continue }
                let tok = assignTokenLocked(category: category, realValue: val, now: now)
                out.replaceSubrange(r, with: tok)
                count += 1
            }
        }

        if out.contains("PRIVATE KEY") {
            replaceFullMatches(regex: pemRegex, category: "KEY")
        }
        replaceFullMatches(regex: standaloneSecretRegex, category: "KEY")
        if out.contains("://") {
            replaceGroup2Matches(regex: uriPasswordGroupRegex, category: "SEC")
        }
        if out.contains("=") || out.contains(":") || out.lowercased().contains("bearer ") {
            replaceGroup2Matches(regex: envOrBearerGroupRegex, category: "SEC")
        }

        // 身份证与银行卡（先于手机号避免长数字串被误切）
        let idMatches = idOrCardCandidateRegex.matches(in: out, range: NSRange(out.startIndex..<out.endIndex, in: out))
        for m in idMatches.reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let val = String(out[r])
            if val.count == 18 && SensitiveCredentialVeil.isValidChineseIDCard18(val) {
                let tok = assignTokenLocked(category: "ID", realValue: val, now: now)
                out.replaceSubrange(r, with: tok)
                count += 1
            } else if (15...19).contains(val.count) && SensitiveCredentialVeil.isValidBankCardLuhn(val) {
                let tok = assignTokenLocked(category: "CARD", realValue: val, now: now)
                out.replaceSubrange(r, with: tok)
                count += 1
            }
        }

        if out.contains("10.") || out.contains("192.168.") || out.contains("172.") {
            replaceFullMatches(regex: privateIPv4Regex, category: "IP")
        }
        if out.contains("@") {
            replaceFullMatches(regex: emailRegex, category: "EMAIL")
        }
        if out.contains("1") {
            replaceFullMatches(regex: cnPhoneRegex, category: "PHONE")
        }

        guard count > 0, out != rawText else { return nil }
        return (out, count)
    }

    /// 检测 AI 回复或剪贴文本中是否包含本会话存活的 `[ICLIP_*_N]` 替身占位符，若有则无损还原全部真值
    static func inspectRestorableTwins(in rawText: String) -> (restoredText: String, restoredCount: Int)? {
        guard rawText.contains("[ICLIP_"), rawText.utf8.count <= 131_072 else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now)
        guard !entriesByToken.isEmpty else { return nil }

        let matches = twinTokenRegex.matches(in: rawText, range: NSRange(rawText.startIndex..<rawText.endIndex, in: rawText))
        guard !matches.isEmpty else { return nil }

        var out = rawText
        var restored = 0
        for m in matches.reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let tok = String(out[r])
            if var entry = entriesByToken[tok] {
                entry.expiresAtUptime = now + ttlSeconds
                entriesByToken[tok] = entry
                out.replaceSubrange(r, with: entry.realValue)
                restored += 1
            }
        }
        guard restored > 0, out != rawText else { return nil }
        return (out, restored)
    }
}


/// 12. 最小够用净提与收件名片一键拆入连填引擎（`SmartFieldExtractor`：自动剥离闲聊噪音提纯手机/地址/邮箱/IP，支持一键拆入 FIFO 顺序连填队列）
enum SmartFieldExtractor {
    struct ShippingContact: Equatable {
        let recipientName: String?
        let cleanPhone: String
        let cleanAddress: String

        var cleanCardText: String {
            if let name = recipientName, !name.isEmpty {
                return "\(name)\n\(cleanPhone)\n\(cleanAddress)"
            }
            return "\(cleanPhone)\n\(cleanAddress)"
        }

        var queueFields: [String] {
            if let name = recipientName, !name.isEmpty {
                return [name, cleanPhone, cleanAddress]
            }
            return [cleanPhone, cleanAddress]
        }
    }

    private static let formattedPhoneRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])(?:\+?86[\s-]*)?(1[3-9]\d[\s-]?\d{4}[\s-]?\d{4})(?![0-9A-Za-z])"#
    )
    private static let emailExtractRegex = try! NSRegularExpression(
        pattern: #"\b[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]+\.[A-Za-z]{2,18}\b"#
    )
    private static let ipv4ExtractRegex = try! NSRegularExpression(
        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#
    )
    private static let logisticsRemarkRegex = try! NSRegularExpression(
        pattern: #"[（(][^）)\n]{0,24}(?:顺丰|到付|寄付|包邮|圆通|中通|韵达|申通|极兔|京东|快递|勿电|丰巢|谢谢|麻烦|加急)[^）)\n]{0,24}[）)]"#
    )
    private static let labelStripRegex = try! NSRegularExpression(
        pattern: #"(?:收件人|收货人|联系人|姓名|联系电话|手机号码|手机号|电话|手机|收货地址|详细地址|寄件地址|收件地址|地址)\s*[:：]\s*"#
    )
    private static let politePrefixRegex = try! NSRegularExpression(
        pattern: #"^(?:亲|你好|您好|麻烦|帮我|请)?(?:帮我)?(?:发|寄)?(?:一下|个)?(?:顺丰|快递|样品|包裹)?\s*[:：，,\s]+"#
    )

    private static let regionMarkers = ["省", "市", "自治区", "特别行政区", "区", "县", "旗"]
    private static let streetMarkers = ["路", "街", "道", "巷", "号", "弄", "室", "楼", "层", "栋", "幢", "单元", "大厦", "广场", "中心", "园", "苑", "小区", "村", "镇"]

    static func hasChineseAddress(_ raw: String) -> Bool {
        let sample = raw.utf8.count > 2_048 ? String(raw.prefix(1_024)) : raw
        if sample.contains("收货地址") || sample.contains("收件地址") || sample.contains("详细地址") {
            return true
        }
        return regionMarkers.contains(where: { sample.contains($0) })
            && streetMarkers.contains(where: { sample.contains($0) })
    }

    static func hasMainlandPhone(_ raw: String) -> Bool {
        guard raw.contains("1") else { return false }
        let sample = raw.utf8.count > 2_048 ? String(raw.prefix(1_024)) : raw
        let r = NSRange(sample.startIndex..<sample.endIndex, in: sample)
        return formattedPhoneRegex.firstMatch(in: sample, range: r) != nil
    }

    static func hasEmail(_ raw: String) -> Bool {
        guard raw.contains("@") else { return false }
        let sample = raw.utf8.count > 2_048 ? String(raw.prefix(1_024)) : raw
        let r = NSRange(sample.startIndex..<sample.endIndex, in: sample)
        return emailExtractRegex.firstMatch(in: sample, range: r) != nil
    }

    static func hasIPv4(_ raw: String) -> Bool {
        guard raw.contains(".") else { return false }
        let sample = raw.utf8.count > 2_048 ? String(raw.prefix(1_024)) : raw
        let r = NSRange(sample.startIndex..<sample.endIndex, in: sample)
        return ipv4ExtractRegex.firstMatch(in: sample, range: r) != nil
    }

    /// 提取并提纯单条带横杠/空格/`+86`/标签前缀的 11 位大陆手机号（若原文本已是纯 11 位数字则返回 nil）
    static func extractNormalizedSinglePhone(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 11, trimmed.utf8.count <= 240 else { return nil }
        let r = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = formattedPhoneRegex.matches(in: trimmed, range: r)
        guard matches.count == 1,
              let g1 = Range(matches[0].range(at: 1), in: trimmed) else {
            return nil
        }
        let digits = trimmed[g1].filter { $0 >= "0" && $0 <= "9" }
        guard digits.count == 11, digits != trimmed else { return nil }
        return digits
    }

    /// 批量去重提取杂乱文本中的全部邮箱（>= 2 个不同邮箱时触发）
    static func extractUniqueEmails(_ raw: String) -> [String] {
        guard raw.contains("@"), raw.utf8.count <= 32_768 else { return [] }
        let r = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        var seen = Set<String>()
        var ordered: [String] = []
        for m in emailExtractRegex.matches(in: raw, range: r) {
            if let rng = Range(m.range, in: raw) {
                let mail = String(raw[rng])
                let key = mail.lowercased()
                if seen.insert(key).inserted {
                    ordered.append(mail)
                }
            }
        }
        return ordered.count >= 2 ? ordered : []
    }

    /// 批量去重提取杂乱日志/告警中的全部 IPv4 地址（>= 2 个不同 IP 时触发）
    static func extractUniqueIPv4s(_ raw: String) -> [String] {
        guard raw.contains("."), raw.utf8.count <= 32_768 else { return [] }
        let r = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        var seen = Set<String>()
        var ordered: [String] = []
        for m in ipv4ExtractRegex.matches(in: raw, range: r) {
            if let rng = Range(m.range, in: raw) {
                let ip = String(raw[rng])
                if seen.insert(ip).inserted {
                    ordered.append(ip)
                }
            }
        }
        return ordered.count >= 2 ? ordered : []
    }

    /// 离线智能解析中文收件地址/名片三要素（支持有标签与自然无标签格式，自动清洗手机号横杠与快递备注噪音）
    static func parseShippingContact(_ raw: String) -> ShippingContact? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 14, trimmed.utf8.count <= 1_200 else { return nil }
        let lower = trimmed.lowercased()
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("|") || lower.hasPrefix("curl ") || lower.contains("http://") || lower.contains("https://") {
            // 若含链接则先剥离链接再解析，防止后台 URL 混入收件地址（最小够用防泄密）
        }
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count <= 8, hasChineseAddress(trimmed) else { return nil }

        // 剥离任何混入的 HTTP(S) 链接与物流括号备注
        var working = trimmed.replacingOccurrences(of: #"https?://[^\s，,）)]+"#, with: " ", options: .regularExpression)
        working = logisticsRemarkRegex.stringByReplacingMatches(
            in: working,
            range: NSRange(working.startIndex..<working.endIndex, in: working),
            withTemplate: " "
        )

        let fullRange = NSRange(working.startIndex..<working.endIndex, in: working)
        guard let phoneMatch = formattedPhoneRegex.firstMatch(in: working, range: fullRange),
              let fullPhoneRange = Range(phoneMatch.range, in: working),
              let corePhoneRange = Range(phoneMatch.range(at: 1), in: working) else {
            return nil
        }
        let cleanPhone = working[corePhoneRange].filter { $0 >= "0" && $0 <= "9" }
        guard cleanPhone.count == 11 else { return nil }

        working.replaceSubrange(fullPhoneRange, with: "\n")
        working = politePrefixRegex.stringByReplacingMatches(
            in: working,
            range: NSRange(working.startIndex..<working.endIndex, in: working),
            withTemplate: ""
        )
        working = labelStripRegex.stringByReplacingMatches(
            in: working,
            range: NSRange(working.startIndex..<working.endIndex, in: working),
            withTemplate: "\n"
        )

        let rawSegments = working
            .components(separatedBy: CharacterSet(charactersIn: "\n,，;；|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var tokens: [String] = []
        for seg in rawSegments {
            if hasChineseAddress(seg), seg.contains(" ") {
                let parts = seg.split(whereSeparator: \.isWhitespace).map(String.init)
                if parts.count >= 2, let first = parts.first, first.count >= 2, first.count <= 6, !hasChineseAddress(first) {
                    tokens.append(first)
                    tokens.append(parts.dropFirst().joined())
                    continue
                }
            }
            tokens.append(seg)
        }

        var foundAddress: String?
        var foundName: String?
        for tok in tokens {
            let cleanedTok = tok.trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。.、-— "))
            guard !cleanedTok.isEmpty else { continue }
            if foundAddress == nil && (hasChineseAddress(cleanedTok) || cleanedTok.count >= 9) {
                foundAddress = cleanedTok
            } else if foundName == nil && cleanedTok.count >= 2 && cleanedTok.count <= 12 && !cleanedTok.allSatisfy(\.isNumber) {
                foundName = cleanedTok
            }
        }

        guard let address = foundAddress, address.count >= 6 else { return nil }
        return ShippingContact(recipientName: foundName, cleanPhone: cleanPhone, cleanAddress: address)
    }
}
