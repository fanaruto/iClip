#if !ICLIP_EDITION_FLOW
import Foundation
import AppKit

/// 剪贴板文本语义分类标签
enum SemanticKind: String, Equatable {
    case dynamicTemplate
    case sensitiveSecret
    case ephemeralOTP
    case meetingTranscript
    case dirtyURL
    case curlCommand
    case colorCode
    case json
    case dataTable
    case financeAmount
    case pdfTypography
    case timestamp
    case multilineList
    case base64
    case identifierCase

    var badgeTitle: String {
        switch self {
        case .dynamicTemplate: return "动态模板"
        case .sensitiveSecret: return "含敏感凭据"
        case .ephemeralOTP: return "验证码"
        case .meetingTranscript: return "会议逐字稿"
        case .dirtyURL: return "含追踪参数"
        case .curlCommand: return "cURL 请求"
        case .colorCode: return "颜色色值"
        case .json: return "JSON"
        case .dataTable: return "二维表格"
        case .financeAmount: return "金额账单"
        case .pdfTypography: return "PDF/排版"
        case .timestamp: return "时间戳"
        case .multilineList: return "多行数据列"
        case .base64: return "Base64"
        case .identifierCase: return "标识符"
        }
    }

    var symbolName: String {
        switch self {
        case .dynamicTemplate: return "wand.and.stars"
        case .sensitiveSecret: return "lock.shield.fill"
        case .ephemeralOTP: return "key.horizontal.fill"
        case .meetingTranscript: return "waveform.and.mic"
        case .dirtyURL: return "sparkles"
        case .curlCommand: return "terminal.fill"
        case .colorCode: return "paintpalette.fill"
        case .json: return "curlybraces"
        case .dataTable: return "tablecells.fill"
        case .financeAmount: return "yensign.circle.fill"
        case .pdfTypography: return "text.redaction"
        case .timestamp: return "clock.badge.checkmark"
        case .multilineList: return "list.bullet.rectangle"
        case .base64: return "lock.open.rotation"
        case .identifierCase: return "textformat.abc"
        }
    }

    var tintColor: NSColor {
        switch self {
        case .dynamicTemplate: return .systemIndigo
        case .sensitiveSecret: return .systemOrange
        case .ephemeralOTP: return .systemMint
        case .meetingTranscript: return .systemIndigo
        case .dirtyURL: return .systemTeal
        case .curlCommand: return .systemGreen
        case .colorCode: return .systemPink
        case .json: return .systemPurple
        case .dataTable: return .systemGreen
        case .financeAmount: return .systemBrown
        case .pdfTypography: return .systemTeal
        case .timestamp: return .systemCyan
        case .multilineList: return .systemMint
        case .base64: return .systemIndigo
        case .identifierCase: return .systemBlue
        }
    }

    /// 支持在搜索框用 @otp / @meet / @tpl / @rmb / @json / @secret / @color / @url / @curl / @list / @time / @b64 / @id 快速过滤
    static func fromSearchToken(_ token: String) -> SemanticKind? {
        switch token.lowercased() {
        case "@tpl", "@snippet", "@模板": return .dynamicTemplate
        case "@otp", "@code", "@验证码": return .ephemeralOTP
        case "@meet", "@meeting", "@srt", "@会议", "@纪要": return .meetingTranscript
        case "@rmb", "@money", "@sum", "@金额", "@大写": return .financeAmount
        case "@pdf", "@typo", "@排版", "@断行": return .pdfTypography
        case "@secret", "@key", "@env", "@jwt", "@脱敏", "@密钥": return .sensitiveSecret
        case "@url", "@clean", "@净链": return .dirtyURL
        case "@curl", "@http": return .curlCommand
        case "@color", "@hex", "@rgb", "@颜色": return .colorCode
        case "@json": return .json
        case "@table", "@excel", "@csv", "@tsv", "@表格": return .dataTable
        case "@time", "@ts", "@时间": return .timestamp
        case "@list", "@sql", "@in", "@列表": return .multilineList
        case "@base64", "@b64": return .base64
        case "@id", "@case", "@驼峰": return .identifierCase
        default: return nil
        }
    }
}

/// 单项可执行瞬时变换动作（支持惰性求值闭包，避免超大文本在列表嗅探阶段产生冗余内存拷贝）
struct TransformAction: Identifiable, Equatable {
    let id: String
    let title: String
    let symbolName: String
    let isSecurityAction: Bool
    private let eagerText: String?
    private let lazyBuilder: (@Sendable () -> String)?
    let toastText: String

    init(
        id: String,
        title: String,
        symbolName: String,
        isSecurityAction: Bool,
        resultText: String,
        toastText: String
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.isSecurityAction = isSecurityAction
        self.eagerText = resultText
        self.lazyBuilder = nil
        self.toastText = toastText
    }

    init(
        id: String,
        title: String,
        symbolName: String,
        isSecurityAction: Bool,
        toastText: String,
        lazyResult: @escaping @Sendable () -> String
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.isSecurityAction = isSecurityAction
        self.eagerText = nil
        self.lazyBuilder = lazyResult
        self.toastText = toastText
    }

    var resultText: String {
        if let eagerText { return eagerText }
        return lazyBuilder?() ?? ""
    }

    static func == (lhs: TransformAction, rhs: TransformAction) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.isSecurityAction == rhs.isSecurityAction
    }
}

/// 单条记录的语义分析快照（轻量缓存，避免滚动重复计算）
struct SemanticSnapshot: Equatable {
    let primaryKind: SemanticKind?
    let parsedColorRGBA: (r: Double, g: Double, b: Double, a: Double)?
    let actions: [TransformAction]

    static let empty = SemanticSnapshot(primaryKind: nil, parsedColorRGBA: nil, actions: [])

    static func == (lhs: SemanticSnapshot, rhs: SemanticSnapshot) -> Bool {
        lhs.primaryKind == rhs.primaryKind && lhs.actions == rhs.actions
    }
}

/// 纯本地微秒级语义识别、格式转换与 AI 安全脱敏引擎
enum SemanticEngine {
    /// 最大嗅探字符数上限（8KB 头部足够覆盖所有请求头、配置块与日志首屏，保障 1MB+ 负载 < 0.3ms）
    private static let maxInspectUTF16Count = 8_192

    /// 预编译安全脱敏正则规则（附带 O(1) 前置子串门控，未包含特征前缀时直接跳过正则引擎）
    private static let secretPatterns: [(name: String, fastHints: [String], regex: NSRegularExpression, replacement: String)] = {
        let specs: [(String, [String], String, String)] = [
            // OpenAI / Anthropic / DeepSeek 等 sk- 密钥
            ("API Key", ["sk-"], #"sk-[A-Za-z0-9_\-]{18,}"#, "sk-***REDACTED***"),
            // Stripe Live / Webhook 密钥
            ("Stripe Key", ["sk_live_", "rk_live_", "whsec_"], #"(?:sk_live|rk_live|whsec)_[A-Za-z0-9]{16,}"#, "stripe_***REDACTED***"),
            // GitHub Personal / Fine-grained / OAuth Token
            ("GitHub Token", ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"], #"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{30,}"#, "gh_***REDACTED***"),
            // AWS Access Key ID
            ("AWS Key", ["AKIA"], #"AKIA[0-9A-Z]{16}"#, "AKIA***REDACTED***"),
            // Slack Token
            ("Slack Token", ["xox"], #"xox[baprs]-[A-Za-z0-9\-]{16,}"#, "xox-***REDACTED***"),
            // Google API Key
            ("Google Key", ["AIza"], #"AIza[0-9A-Za-z\-_]{35}"#, "AIza***REDACTED***"),
            // JWT Token (eyJ...)
            ("JWT", ["eyJ"], #"eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, "eyJ***JWT_REDACTED***"),
            // Authorization Bearer Token
            ("Bearer", ["Bearer", "bearer", "BEARER"], #"(?i)(Bearer\s+)[A-Za-z0-9\-._~+/]{20,}=*"#, "$1***REDACTED***"),
            // 数据库连接串中的密码 scheme://user:password@host
            ("URI Password", ["://"], #"([a-zA-Z][a-zA-Z0-9+.\-]*://[^:\s/@]+:)([^@\s]+)(@)"#, "$1***REDACTED***$3"),
            // .env / YAML / 配置文件敏感键值对（保留键名，掩码真实密钥值）
            ("Env Secret", ["=", ":"], ##"(?im)^(\s*(?:export\s+)?[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|API_KEY|ACCESS_KEY|PRIVATE_KEY|AUTH_TOKEN|CLIENT_SECRET)[A-Z0-9_]*\s*[:=]\s*['"]?)([^\s'"#]{6,})(['"]?)"##, "$1***REDACTED***$3"),
            // cURL / HTTP 请求头中的 Cookie / Set-Cookie / X-API-Key / X-Auth-Token / Basic Auth
            ("HTTP Cookie/Key", [":"], ##"(?i)(\b(?:cookie|set-cookie|x-api-key|x-auth-token|x-csrf-token)\s*:\s*)([^\r\n'"]{8,})"##, "$1***REDACTED***"),
            ("HTTP Basic Auth", ["Basic", "basic", "BASIC"], #"(?i)(\b(?:authorization|proxy-authorization)\s*:\s*basic\s+)([A-Za-z0-9+/=]{8,})"#, "$1***REDACTED***"),
            // JSON 载荷中的敏感口令与 Token 键值
            ("JSON Secret", ["\":", "\" :"], ##"(?i)("(?:password|passwd|secret|client_secret|api_key|apikey|access_token|refresh_token|id_token|session_token|private_key)"\s*:\s*")([^"\r\n]{6,})(")"##, "$1***REDACTED***$3"),
            // 企业群机器人 Webhook（飞书 / Lark / 企微 / Slack / Discord）、Age 私钥、otpauth 2FA 与 Wi-Fi 密码
            ("Webhook Secret", ["://"], #"(?i)(https?://(?:open\.(?:feishu\.cn|larksuite\.com)/open-apis/bot/v2/hook/|qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?(?:[^&#\s]+&)*key=|hooks\.slack\.com/services/[A-Z0-9]{8,}/[A-Z0-9]{8,}/|(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d{10,}/))([A-Za-z0-9_\-]{12,})"#, "$1***WEBHOOK_REDACTED***"),
            ("Age Secret Key", ["AGE-SECRET-KEY-1"], #"\bAGE-SECRET-KEY-1[A-Z0-9]{50,}\b"#, "AGE-SECRET-KEY-1***REDACTED***"),
            ("OTPAuth Secret", ["otpauth", "OTPAUTH"], #"(?i)([?&](?:secret|data)=)([^&\s#'"]+)"#, "$1***2FA_SECRET_REDACTED***"),
            ("WiFi Password", ["WIFI:", "wifi:"], #"(?i)(WIFI:(?:[^;\r\n]*;)*?P:)([^;\r\n]{4,})(;)"#, "$1***WIFI_REDACTED***$3")
        ]
        return specs.compactMap { name, hints, pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (name, hints, regex, replacement)
        }
    }()

    private static let hexColorRegex = try! NSRegularExpression(pattern: #"^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"#)
    private static let privateIPv4Regex = try! NSRegularExpression(
        pattern: #"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3})\b"#
    )
    private static let emailRegex = try! NSRegularExpression(
        pattern: #"\b([A-Za-z0-9._%+\-])([A-Za-z0-9._%+\-]*)(@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})\b"#
    )
    private static let cnPhoneRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)(1[3-9]\d)\d{4}(\d{4})(?!\d)"#
    )
    private static let rgbColorRegex = try! NSRegularExpression(
        pattern: #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})(?:\s*,\s*([0-9]*\.?[0-9]+))?\s*\)$"#,
        options: [.caseInsensitive]
    )

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: - 主入口：生成语义快照

    static func analyze(_ item: ClipItem) -> SemanticSnapshot {
        guard item.type == .text || item.type == .link,
              let raw = item.text, !raw.isEmpty else {
            return .empty
        }

        let inspectSlice: String = raw.utf8.count > 12_288 ? String(raw.prefix(6_000)) : raw

        let trimmed = inspectSlice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        var actions: [TransformAction] = []
        var primaryKind: SemanticKind? = nil
        var parsedColor: (r: Double, g: Double, b: Double, a: Double)? = nil

        // 0. 动态模板 Snippet 识别（支持 {{clip}} / {{clip_redacted}} / {{date}} / {{uuid}} 等实时求值）
        if SnippetTemplateEngine.containsPlaceholders(inspectSlice) {
            primaryKind = .dynamicTemplate
        }

        // 0.5 一次性短信/邮件验证码（OTP）极速提取（排在首位，按 ⇧↵ 直接贴纯数字验证码）
        if primaryKind == nil,
           raw.utf8.count <= 400,
           let otp = MeetingAndEphemeralEngine.extractVerificationCode(from: trimmed),
           otp != trimmed {
            primaryKind = .ephemeralOTP
            actions.append(TransformAction(
                id: "otp-extract-code",
                title: "验证码 \(otp)",
                symbolName: "key.horizontal.fill",
                isSecurityAction: false,
                resultText: otp,
                toastText: "已提取纯验证码 \(otp) 并键入"
            ))
        }

        // 1. 最高优：敏感凭据检测与一键 AI 脱敏（超大文本采用惰性求值，嗅探阶段 0 额外内存拷贝）
        let hasSecret = containsSensitiveSecret(in: inspectSlice)
        let hasPII = containsPIIOrPrivateIP(in: inspectSlice)
        let isLargePayload = raw.utf8.count > 16_384
        if hasSecret {
            if primaryKind != .ephemeralOTP { primaryKind = .sensitiveSecret }
            if isLargePayload {
                actions.append(TransformAction(
                    id: "redact-secrets",
                    title: "脱敏粘贴",
                    symbolName: "lock.shield",
                    isSecurityAction: true,
                    toastText: "已安全掩码敏感凭据并键入",
                    lazyResult: { redactSecrets(in: raw) }
                ))
                if hasPII {
                    actions.append(TransformAction(
                        id: "redact-deep",
                        title: "深度脱敏(含IP/隐私)",
                        symbolName: "eye.slash.fill",
                        isSecurityAction: true,
                        toastText: "已完成密钥 + 内网IP/邮箱/手机全量脱敏",
                        lazyResult: { redactPIIAndPrivateIP(in: redactSecrets(in: raw)) }
                    ))
                }
            } else {
                let redacted = redactSecrets(in: raw)
                if redacted != raw {
                    actions.append(TransformAction(
                        id: "redact-secrets",
                        title: "脱敏粘贴",
                        symbolName: "lock.shield",
                        isSecurityAction: true,
                        resultText: redacted,
                        toastText: "已安全掩码敏感凭据并键入"
                    ))
                }
                if let twin = ReversiblePrivacyTwin.maskWithTwins(raw) {
                    actions.append(TransformAction(
                        id: "redact-reversible-twin",
                        title: "AI 替身脱敏",
                        symbolName: "person.2.badge.key.fill",
                        isSecurityAction: true,
                        resultText: twin.maskedText,
                        toastText: "已生成 \(twin.replacedCount) 处可逆替身（复制 AI 回复可一键还原真值）"
                    ))
                }
                if hasPII {
                    let deepRedacted = redactPIIAndPrivateIP(in: redacted)
                    if deepRedacted != redacted {
                        actions.append(TransformAction(
                            id: "redact-deep",
                            title: "深度脱敏(含IP/隐私)",
                            symbolName: "eye.slash.fill",
                            isSecurityAction: true,
                            resultText: deepRedacted,
                            toastText: "已完成密钥 + 内网IP/邮箱/手机全量脱敏"
                        ))
                    }
                }
                if let jwtInfo = decodeJWTInspectionWithStatus(trimmed) {
                    let chipTitle: String
                    if let valid = jwtInfo.isUnexpired {
                        chipTitle = valid ? "解码 JWT · 有效" : "解码 JWT · 已过期"
                    } else {
                        chipTitle = "解码 JWT"
                    }
                    actions.append(TransformAction(
                        id: "jwt-decode",
                        title: chipTitle,
                        symbolName: "person.text.rectangle",
                        isSecurityAction: false,
                        resultText: jwtInfo.decodedText,
                        toastText: "已离线解码 JWT 载荷并键入"
                    ))
                }
                if let envExample = EnvTemplateSanitizer.generateExampleTemplate(from: raw) {
                    actions.append(TransformAction(
                        id: "env-to-example",
                        title: "生成 .env.example",
                        symbolName: "doc.badge.gearshape",
                        isSecurityAction: true,
                        resultText: envExample,
                        toastText: "已生成安全的 .env.example 净模板并键入"
                    ))
                }
            }
        } else if hasPII && trimmed.count >= 11 {
            if primaryKind != .ephemeralOTP { primaryKind = .sensitiveSecret }
            if isLargePayload {
                actions.append(TransformAction(
                    id: "redact-pii",
                    title: "隐私掩码(IP/邮箱/号)",
                    symbolName: "eye.slash",
                    isSecurityAction: true,
                    toastText: "已掩码内网 IP / 邮箱 / 手机号并键入",
                    lazyResult: { redactPIIAndPrivateIP(in: raw) }
                ))
            } else {
                let deepRedacted = redactPIIAndPrivateIP(in: raw)
                if deepRedacted != raw {
                    actions.append(TransformAction(
                        id: "redact-pii",
                        title: "隐私掩码(IP/邮箱/号)",
                        symbolName: "eye.slash",
                        isSecurityAction: true,
                        resultText: deepRedacted,
                        toastText: "已掩码内网 IP / 邮箱 / 手机号并键入"
                    ))
                    if let twin = ReversiblePrivacyTwin.maskWithTwins(raw) {
                        actions.append(TransformAction(
                            id: "redact-reversible-twin",
                            title: "AI 替身脱敏",
                            symbolName: "person.2.badge.key.fill",
                            isSecurityAction: true,
                            resultText: twin.maskedText,
                            toastText: "已生成 \(twin.replacedCount) 处可逆替身（复制 AI 回复可一键还原真值）"
                        ))
                    }
                }
            }
        }

        // 2. cURL 命令识别与安全复现瘦身 / 提取 URL / 转 JS fetch()
        if trimmed.lowercased().hasPrefix("curl ") || trimmed.lowercased().hasPrefix("curl\t") {
            if primaryKind == nil { primaryKind = .curlCommand }
            if let sanitizedCurl = CurlAndJSONCSanitizer.sanitizeCurlForReproduction(raw) {
                let isSec = sanitizedCurl.redactedSecrets > 0
                actions.append(TransformAction(
                    id: isSec ? "curl-safe-repro" : "curl-slim-clean",
                    title: isSec ? "安全复现 cURL" : "精简纯净 cURL",
                    symbolName: isSec ? "checkmark.shield" : "sparkles",
                    isSecurityAction: isSec,
                    resultText: sanitizedCurl.cleanedCurl,
                    toastText: isSec
                        ? "已脱敏 \(sanitizedCurl.redactedSecrets) 处凭据并剥除 \(sanitizedCurl.removedNoiseHeaders) 个浏览器噪音头"
                        : "已剥除 \(sanitizedCurl.removedNoiseHeaders) 个浏览器指纹噪音头"
                ))
            }
            if let extractedURL = extractURLFromCurl(raw) {
                actions.append(TransformAction(
                    id: "curl-url",
                    title: "提取 URL",
                    symbolName: "link",
                    isSecurityAction: false,
                    resultText: extractedURL,
                    toastText: "已提取 cURL 中的请求地址"
                ))
            }
            if let fetchCode = convertCurlToFetch(raw) {
                actions.append(TransformAction(
                    id: "curl-fetch",
                    title: "转 fetch()",
                    symbolName: "chevron.left.forwardslash.chevron.right",
                    isSecurityAction: false,
                    resultText: fetchCode,
                    toastText: "已将 cURL 转换为 JS fetch 代码"
                ))
            }
        }

        // 3. 链接鉴权剥离净享、追踪参数净链检测与社媒分享口令剥壳提链
        if trimmed.count < 4096, !trimmed.contains("\n"), let publicURL = URLTrackingCleaner.sanitizeURLForPublicShare(trimmed) {
            if primaryKind == nil { primaryKind = .sensitiveSecret }
            actions.insert(TransformAction(
                id: "sanitize-auth-url",
                title: "去鉴权净链",
                symbolName: "link.badge.plus",
                isSecurityAction: true,
                resultText: publicURL,
                toastText: "已剥离 URL 鉴权令牌与追踪尾巴，可安全外发"
            ), at: 0)
        } else if trimmed.count < 4096, !trimmed.contains("\n"), let cleaned = cleanTrackingURL(trimmed) {
            if primaryKind == nil { primaryKind = .dirtyURL }
            actions.append(TransformAction(
                id: "clean-url",
                title: "净链粘贴",
                symbolName: "sparkles",
                isSecurityAction: false,
                resultText: cleaned,
                toastText: "已剥离追踪参数并键入纯净链接"
            ))
        } else if item.type == .text, let shareURL = URLTrackingCleaner.extractCleanShareURL(from: inspectSlice) {
            if primaryKind == nil { primaryKind = .dirtyURL }
            actions.append(TransformAction(
                id: "extract-share-url",
                title: "提取纯净链接",
                symbolName: "link",
                isSecurityAction: false,
                resultText: shareURL,
                toastText: "已剥除口令废话与追踪尾巴，键入纯净链接"
            ))
        }

        // 3. 颜色色值解析（HEX / RGB）
        if trimmed.count <= 48, let rgba = parseColor(trimmed) {
            if primaryKind == nil { primaryKind = .colorCode }
            parsedColor = rgba
            let hex = formatHex(rgba)
            let rgb = formatRGB(rgba)
            let swiftColor = formatSwiftUIColor(rgba)
            if hex.caseInsensitiveCompare(trimmed) != .orderedSame {
                actions.append(TransformAction(
                    id: "color-hex",
                    title: hex,
                    symbolName: "number",
                    isSecurityAction: false,
                    resultText: hex,
                    toastText: "已转换色值为 \(hex)"
                ))
            }
            if rgb.caseInsensitiveCompare(trimmed) != .orderedSame {
                actions.append(TransformAction(
                    id: "color-rgb",
                    title: "转 RGB",
                    symbolName: "eyedropper",
                    isSecurityAction: false,
                    resultText: rgb,
                    toastText: "已转换为 \(rgb)"
                ))
            }
            actions.append(TransformAction(
                id: "color-swiftui",
                title: "SwiftUI",
                symbolName: "swift",
                isSecurityAction: false,
                resultText: swiftColor,
                toastText: "已转换为 SwiftUI Color"
            ))
        }

        // 4. JSON 检测与格式化 / 压缩（仅在尺寸适中时解析）
        if raw.utf8.count <= 65_536,
           ((trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))),
           let data = trimmed.data(using: .utf8),
           let jsonObj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if primaryKind == nil { primaryKind = .json }
            let isMultiline = trimmed.contains("\n")
            if !isMultiline,
               let prettyData = try? JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let prettyStr = String(data: prettyData, encoding: .utf8) {
                actions.append(TransformAction(
                    id: "json-pretty",
                    title: "格式化 JSON",
                    symbolName: "curlybraces",
                    isSecurityAction: false,
                    resultText: prettyStr,
                    toastText: "已美化 JSON 并键入"
                ))
            } else if let compactData = try? JSONSerialization.data(withJSONObject: jsonObj, options: [.sortedKeys, .withoutEscapingSlashes]),
                      let compactStr = String(data: compactData, encoding: .utf8) {
                actions.append(TransformAction(
                    id: "json-minify",
                    title: "压缩单行",
                    symbolName: "arrow.right.and.line.vertical.and.arrow.left",
                    isSecurityAction: false,
                    resultText: compactStr,
                    toastText: "已压缩为单行 JSON"
                ))
                if let prettyData = try? JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                   let prettyStr = String(data: prettyData, encoding: .utf8),
                   prettyStr != trimmed {
                    actions.append(TransformAction(
                        id: "json-pretty",
                        title: "重排缩进",
                        symbolName: "curlybraces",
                        isSecurityAction: false,
                        resultText: prettyStr,
                        toastText: "已规范化 JSON 缩进"
                    ))
                }
            }
        } else if raw.utf8.count <= 65_536,
                  let strictJSON = CurlAndJSONCSanitizer.cleanJSONCToStrictJSON(raw) {
            if primaryKind == nil { primaryKind = .json }
            actions.append(TransformAction(
                id: "jsonc-clean-strict",
                title: "净化为标准 JSON",
                symbolName: "curlybraces.square",
                isSecurityAction: false,
                resultText: strictJSON,
                toastText: "已剥除注释与尾随逗号，转为标准合法 JSON"
            ))
        }

        // 4.5 乱码转义安全解码（Unicode \uXXXX / URL %XX / HTML 实体）与多行列表稳定去重
        if raw.utf8.count <= 32_768,
           !actions.contains(where: { $0.id == "json-pretty" || $0.id == "json-minify" || $0.id == "jsonc-clean-strict" }),
           let decoded = UniversalEscapeDecoder.decodeIfApplicable(raw) {
            actions.append(TransformAction(
                id: "decode-escaped-text",
                title: decoded.chipTitle,
                symbolName: "character.bubble",
                isSecurityAction: false,
                resultText: decoded.decodedText,
                toastText: decoded.toastText
            ))
        }
        if raw.utf8.count <= 65_536,
           let dedup = UniversalEscapeDecoder.deduplicateListLines(raw) {
            actions.append(TransformAction(
                id: "dedup-list-lines",
                title: "去重净列(剩\(dedup.remainingCount)行)",
                symbolName: "line.3.horizontal.decrease.circle",
                isSecurityAction: false,
                resultText: dedup.cleanedText,
                toastText: "已按原序剔除 \(dedup.removedCount) 行重复项，保留 \(dedup.remainingCount) 行"
            ))
        }
        if !trimmed.contains("\n"), trimmed.utf8.count <= 512 {
            if let cronDesc = CronAndPathHelper.explainCronExpression(trimmed) {
                actions.append(TransformAction(
                    id: "cron-explain",
                    title: "Cron：\(cronDesc.shortSummary)",
                    symbolName: "calendar.badge.clock",
                    isSecurityAction: false,
                    resultText: cronDesc.annotatedComment,
                    toastText: "已复制 Cron 注释：\(cronDesc.shortSummary)"
                ))
            } else if let pathAct = CronAndPathHelper.analyzePathAction(trimmed) {
                actions.append(TransformAction(
                    id: pathAct.id,
                    title: pathAct.title,
                    symbolName: "folder.badge.gearshape",
                    isSecurityAction: false,
                    resultText: pathAct.resultText,
                    toastText: pathAct.toastText
                ))
            }
        }

        // 5. Unix 时间戳检测（秒级 10 位 / 毫秒级 13 位）
        if (trimmed.count == 10 || trimmed.count == 13),
           trimmed.allSatisfy(\.isNumber),
           let rawVal = Double(trimmed) {
            let seconds = (trimmed.count == 13) ? (rawVal / 1000.0) : rawVal
            // 2001-09-09 ~ 2100-01-01 合理区间
            if seconds >= 1_000_000_000 && seconds <= 4_102_444_800 {
                if primaryKind == nil { primaryKind = .timestamp }
                let date = Date(timeIntervalSince1970: seconds)
                let formatted = isoFormatter.string(from: date)
                let iso8601 = ISO8601DateFormatter().string(from: date)
                actions.append(TransformAction(
                    id: "ts-local",
                    title: formatted,
                    symbolName: "clock",
                    isSecurityAction: false,
                    resultText: formatted,
                    toastText: "已转换时间戳为 \(formatted)"
                ))
                actions.append(TransformAction(
                    id: "ts-iso",
                    title: "ISO8601",
                    symbolName: "globe",
                    isSecurityAction: false,
                    resultText: iso8601,
                    toastText: "已转换为 ISO8601 时间"
                ))
            }
        }

        // 5.2 法务与出纳国标号码校验（身份证 GB11643 / 税号 GB32100 / 银行卡 Luhn）
        if primaryKind == nil && !trimmed.contains("\n") && trimmed.count >= 15 && trimmed.count <= 32 {
            let compActions = ComplianceCodeEngine.analyze(raw)
            if !compActions.isEmpty {
                primaryKind = .financeAmount
                for ca in compActions {
                    actions.append(TransformAction(
                        id: ca.id,
                        title: ca.title,
                        symbolName: ca.symbolName,
                        isSecurityAction: ca.id.contains("mask"),
                        resultText: ca.resultText,
                        toastText: ca.toastText
                    ))
                }
            }
        }

        // 5.3 会议逐字稿 / SRT 字幕时间轴剥离与发言人纪要合并
        if primaryKind == nil && raw.utf8.count <= 65_536 && raw.contains("\n") {
            let meetActions = MeetingAndEphemeralEngine.analyze(raw)
            if !meetActions.isEmpty {
                primaryKind = .meetingTranscript
                for ma in meetActions {
                    actions.append(TransformAction(
                        id: ma.id,
                        title: ma.title,
                        symbolName: ma.symbolName,
                        isSecurityAction: false,
                        resultText: ma.resultText,
                        toastText: ma.toastText
                    ))
                }
            }
        }

        // 5.5 二维数据表格协议破壁（Markdown 表格 ↔ Excel TSV / CSV / JSON 数组）
        if primaryKind == nil && raw.utf8.count <= 65_536 && raw.contains("\n") {
            let tblActions = TableBridgeEngine.analyze(raw)
            if !tblActions.isEmpty {
                primaryKind = .dataTable
                for ta in tblActions {
                    actions.append(TransformAction(
                        id: ta.id,
                        title: ta.title,
                        symbolName: ta.symbolName,
                        isSecurityAction: false,
                        resultText: ta.resultText,
                        toastText: ta.toastText
                    ))
                }
            }
        }

        // 6. 财务金额大写与多行明细账单自动求和（仅在未命中 Unix 时间戳时执行）
        if primaryKind == nil && raw.utf8.count <= 16_384 {
            let finActions = FinanceNumberEngine.analyze(raw)
            if !finActions.isEmpty {
                primaryKind = .financeAmount
                for fa in finActions {
                    actions.append(TransformAction(
                        id: fa.id,
                        title: fa.title,
                        symbolName: fa.symbolName,
                        isSecurityAction: false,
                        resultText: fa.resultText,
                        toastText: fa.toastText
                    ))
                }
            }
        }

        // 7. Base64 可读文本解码检测
        if primaryKind == nil,
           trimmed.count >= 12, trimmed.count <= 4096,
           trimmed.count % 4 == 0,
           !trimmed.contains(" "), !trimmed.contains("\n"),
           trimmed.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil,
           let decodedData = Data(base64Encoded: trimmed),
           let decodedStr = String(data: decodedData, encoding: .utf8) {
            let cleanDecoded = decodedStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanDecoded.count >= 3, isMostlyPrintableText(cleanDecoded) {
                primaryKind = .base64
                actions.append(TransformAction(
                    id: "base64-decode",
                    title: "Base64 解码",
                    symbolName: "lock.open",
                    isSecurityAction: false,
                    resultText: decodedStr,
                    toastText: "已解码 Base64 文本并键入"
                ))
            }
        }

        // 8. PDF 跨行断句愈合与中英间距美化 vs 多行数据列转换（SQL IN / JSON 数组）
        if raw.utf8.count <= 32_768 && primaryKind == nil {
            let docActions = DocumentTypographyEngine.analyze(raw)
            if DocumentTypographyEngine.looksLikeBrokenPDFParagraphs(raw), !docActions.isEmpty {
                primaryKind = .pdfTypography
                for da in docActions {
                    actions.append(TransformAction(
                        id: da.id,
                        title: da.title,
                        symbolName: da.symbolName,
                        isSecurityAction: false,
                        resultText: da.resultText,
                        toastText: da.toastText
                    ))
                }
            }
        }

        if raw.utf8.count <= 32_768 && trimmed.contains("\n") && primaryKind != .json && primaryKind != .curlCommand && primaryKind != .pdfTypography {
            if !item.isTodo {
                let checklist = TodoChecklistExtractor.extractChecklistItems(from: raw)
                if checklist.count >= 2 {
                    actions.append(TransformAction(
                        id: "todo-split-checklist",
                        title: "拆为 \(checklist.count) 条待办",
                        symbolName: "checklist",
                        isSecurityAction: false,
                        resultText: raw,
                        toastText: "已拆解为 \(checklist.count) 条待办"
                    ))
                }
            }
            let rawLines = raw.components(separatedBy: .newlines)
            let cleanItems = rawLines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // 判断是否为整齐的 ID / 词条数据列（2~500 行，每行 ≤ 64 字符且不含典型句子标点与代码花括号分号）
            let looksLikeColumn = cleanItems.count >= 2 && cleanItems.count <= 500 && cleanItems.allSatisfy { line in
                line.count <= 64 && !line.contains("{") && !line.contains("}") && !line.hasSuffix(";")
                    && !line.contains("。") && !line.contains("，")
            }

            if looksLikeColumn {
                if primaryKind == nil { primaryKind = .multilineList }
                let sqlIn = buildSQLInClause(cleanItems)
                actions.append(TransformAction(
                    id: "list-sql-in",
                    title: "SQL IN (...)",
                    symbolName: "cylinder.split.1x2",
                    isSecurityAction: false,
                    resultText: sqlIn,
                    toastText: "已将 \(cleanItems.count) 行转换为 SQL IN 子句"
                ))
                if let jsonData = try? JSONSerialization.data(withJSONObject: cleanItems, options: [.withoutEscapingSlashes]),
                   let jsonArr = String(data: jsonData, encoding: .utf8) {
                    actions.append(TransformAction(
                        id: "list-json-arr",
                        title: "JSON 数组",
                        symbolName: "curlybraces.square",
                        isSecurityAction: false,
                        resultText: jsonArr,
                        toastText: "已转换为 JSON 数组"
                    ))
                }
                actions.append(TransformAction(
                    id: "list-csv",
                    title: "逗号单行",
                    symbolName: "line.3.horizontal.decrease",
                    isSecurityAction: false,
                    resultText: cleanItems.joined(separator: ", "),
                    toastText: "已合并为逗号分隔单行"
                ))
            } else if let dedented = stripCommonLeadingIndent(raw) {
                actions.append(TransformAction(
                    id: "code-dedent",
                    title: "去除公共缩进",
                    symbolName: "decrease.indent",
                    isSecurityAction: false,
                    resultText: dedented,
                    toastText: "已对齐并清除多余前导缩进"
                ))
            }
        }

        // 8. 编程标识符命名风格互转（snake_case / camelCase / kebab-case）
        if primaryKind == nil,
           trimmed.count >= 4, trimmed.count <= 80,
           !trimmed.contains(" "), !trimmed.contains("\n"), !trimmed.contains("/"), !trimmed.contains(".") {
            let words = splitIdentifierWords(trimmed)
            if words.count >= 2 {
                primaryKind = .identifierCase
                let camel = toCamelCase(words)
                let snake = words.map { $0.lowercased() }.joined(separator: "_")
                let upperSnake = words.map { $0.uppercased() }.joined(separator: "_")
                if camel != trimmed {
                    actions.append(TransformAction(
                        id: "case-camel",
                        title: camel,
                        symbolName: "textformat",
                        isSecurityAction: false,
                        resultText: camel,
                        toastText: "已转为驼峰 \(camel)"
                    ))
                }
                if snake != trimmed {
                    actions.append(TransformAction(
                        id: "case-snake",
                        title: snake,
                        symbolName: "minus",
                        isSecurityAction: false,
                        resultText: snake,
                        toastText: "已转为下划线 \(snake)"
                    ))
                }
                if upperSnake != trimmed && actions.count < 3 {
                    actions.append(TransformAction(
                        id: "case-const",
                        title: "UPPER_CASE",
                        symbolName: "textformat.size.larger",
                        isSecurityAction: false,
                        resultText: upperSnake,
                        toastText: "已转为常量命名"
                    ))
                }
            }
        }

        // 9. 最小够用结构化净提：中文收件名片提纯、带分隔符手机号清洗及多邮箱/多 IP 去重提取
        if !isLargePayload && primaryKind != .ephemeralOTP && primaryKind != .json && primaryKind != .curlCommand {
            if let shipping = SmartFieldExtractor.parseShippingContact(raw) {
                actions.append(TransformAction(
                    id: "contact-clean-card",
                    title: "净提收件卡",
                    symbolName: "shippingbox",
                    isSecurityAction: false,
                    resultText: shipping.cleanCardText,
                    toastText: "已剥离闲聊噪音提纯标准收件信息"
                ))
                actions.append(TransformAction(
                    id: "extract-clean-phone",
                    title: "纯手机号 \(shipping.cleanPhone)",
                    symbolName: "phone.fill",
                    isSecurityAction: false,
                    resultText: shipping.cleanPhone,
                    toastText: "已提取 11 位纯数字手机号 \(shipping.cleanPhone)"
                ))
            } else {
                if let cleanPhone = SmartFieldExtractor.extractNormalizedSinglePhone(raw),
                   !MeetingAndEphemeralEngine.isOTPMessage(raw) {
                    actions.append(TransformAction(
                        id: "extract-clean-phone",
                        title: "纯手机号 \(cleanPhone)",
                        symbolName: "phone.fill",
                        isSecurityAction: false,
                        resultText: cleanPhone,
                        toastText: "已清洗分隔符并提取纯手机号 \(cleanPhone)"
                    ))
                }
                let uniqueEmails = SmartFieldExtractor.extractUniqueEmails(raw)
                if uniqueEmails.count >= 2 {
                    actions.append(TransformAction(
                        id: "extract-unique-emails",
                        title: "提取 \(uniqueEmails.count) 个邮箱",
                        symbolName: "envelope.fill",
                        isSecurityAction: false,
                        resultText: uniqueEmails.joined(separator: "\n"),
                        toastText: "已去重净提 \(uniqueEmails.count) 个邮箱地址"
                    ))
                }
                let uniqueIPs = SmartFieldExtractor.extractUniqueIPv4s(raw)
                if uniqueIPs.count >= 2 {
                    actions.append(TransformAction(
                        id: "extract-unique-ips",
                        title: "提取 \(uniqueIPs.count) 个 IP",
                        symbolName: "network",
                        isSecurityAction: false,
                        resultText: uniqueIPs.joined(separator: "\n"),
                        toastText: "已去重净提 \(uniqueIPs.count) 个 IPv4 地址"
                    ))
                }
            }
        }

        // 单行中英混排粘连排版美化兜底
        if primaryKind == nil && !trimmed.contains("\n") && raw.utf8.count <= 8_192 {
            let docActions = DocumentTypographyEngine.analyze(raw)
            if !docActions.isEmpty {
                primaryKind = .pdfTypography
                for da in docActions {
                    actions.append(TransformAction(
                        id: da.id,
                        title: da.title,
                        symbolName: da.symbolName,
                        isSecurityAction: false,
                        resultText: da.resultText,
                        toastText: da.toastText
                    ))
                }
            }
        }

        return SemanticSnapshot(
            primaryKind: primaryKind,
            parsedColorRGBA: parsedColor,
            actions: Array(actions.prefix(3))
        )
    }

    // MARK: - 具体转换与脱敏实现

    static func containsSensitiveSecret(in text: String) -> Bool {
        if SensitiveCredentialVeil.classify(text) != nil {
            return true
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for item in secretPatterns {
            guard item.fastHints.contains(where: { text.contains($0) }) else { continue }
            if item.regex.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    static func redactSecrets(in text: String) -> String {
        var result = text
        if result.contains("-----BEGIN ") && (result.contains("PRIVATE KEY-----") || result.contains("PRIVATE KEY BLOCK-----")),
           let pemRegex = try? NSRegularExpression(
               pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"#
           ) {
            let fullRange = NSRange(result.startIndex..<result.endIndex, in: result)
            result = pemRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: fullRange,
                withTemplate: "-----BEGIN PRIVATE KEY-----\n[REDACTED_BY_iCLIP]\n-----END PRIVATE KEY-----"
            )
        }
        for item in secretPatterns {
            let fullRange = NSRange(result.startIndex..<result.endIndex, in: result)
            result = item.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: fullRange,
                withTemplate: item.replacement
            )
        }
        result = SensitiveCredentialVeil.redactForExternalSharing(result)
        return result
    }

    static func containsPIIOrPrivateIP(in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if text.contains("@"), emailRegex.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if (text.contains("10.") || text.contains("192.168.") || text.contains("172.")),
           privateIPv4Regex.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if text.contains("1"), cnPhoneRegex.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        return false
    }

    static func redactPIIAndPrivateIP(in text: String) -> String {
        var result = text
        var range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = privateIPv4Regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "*.*.*.*")
        range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = emailRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1***$3")
        range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = cnPhoneRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1****$2")
        return result
    }

    /// 剥离营销追踪参数；若原链接不含追踪参数则返回 nil（复用双版本统一 URLTrackingCleaner）
    static func cleanTrackingURL(_ raw: String) -> String? {
        URLTrackingCleaner.cleanTrackingURL(raw)
    }

    // MARK: - JWT 离线零上传解码审查（支持裸 eyJ... 与 Bearer eyJ...，自动解析 exp/iat 时间戳）

    static func decodeJWTInspection(_ input: String, referenceDate: Date = Date()) -> String? {
        decodeJWTInspectionWithStatus(input, referenceDate: referenceDate)?.decodedText
    }

    static func decodeJWTInspectionWithStatus(
        _ input: String,
        referenceDate: Date = Date()
    ) -> (decodedText: String, isUnexpired: Bool?)? {
        var candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.lowercased().hasPrefix("bearer ") {
            candidate = String(candidate.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        guard candidate.count >= 24,
              candidate.count <= 8_192,
              !candidate.contains(" "),
              !candidate.contains("\n") else {
            return nil
        }

        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].hasPrefix("eyJ"),
              parts[1].hasPrefix("ey") else {
            return nil
        }

        guard let headerData = decodeBase64URL(String(parts[0])),
              let payloadData = decodeBase64URL(String(parts[1])),
              let headerObj = try? JSONSerialization.jsonObject(with: headerData),
              let payloadObj = try? JSONSerialization.jsonObject(with: payloadData),
              let headerPretty = try? JSONSerialization.data(withJSONObject: headerObj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let payloadPretty = try? JSONSerialization.data(withJSONObject: payloadObj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let headerStr = String(data: headerPretty, encoding: .utf8),
              let payloadStr = String(data: payloadPretty, encoding: .utf8) else {
            return nil
        }

        var summaryLines: [String] = []
        var unexpiredFlag: Bool? = nil
        if let dict = payloadObj as? [String: Any] {
            if let expVal = numericEpochSeconds(from: dict["exp"]) {
                let expDate = Date(timeIntervalSince1970: expVal)
                let isValid = expDate > referenceDate
                unexpiredFlag = isValid
                let status = isValid ? "有效" : "已过期"
                summaryLines.append("// 过期时间 (exp): \(isoFormatter.string(from: expDate))（\(status)）")
            }
            if let iatVal = numericEpochSeconds(from: dict["iat"]) {
                let iatDate = Date(timeIntervalSince1970: iatVal)
                summaryLines.append("// 签发时间 (iat): \(isoFormatter.string(from: iatDate))")
            }
        }

        var blocks: [String] = []
        if !summaryLines.isEmpty {
            blocks.append(summaryLines.joined(separator: "\n"))
        }
        blocks.append("// Header\n\(headerStr)")
        blocks.append("// Payload\n\(payloadStr)")
        return (blocks.joined(separator: "\n\n"), unexpiredFlag)
    }

    private static func decodeBase64URL(_ segment: String) -> Data? {
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func numericEpochSeconds(from raw: Any?) -> TimeInterval? {
        if let d = raw as? Double { return d > 10_000_000_000 ? d / 1000.0 : d }
        if let i = raw as? Int { return Double(i) > 10_000_000_000 ? Double(i) / 1000.0 : Double(i) }
        if let n = raw as? NSNumber {
            let d = n.doubleValue
            return d > 10_000_000_000 ? d / 1000.0 : d
        }
        return nil
    }

    // MARK: - 颜色解析与格式化

    private static func parseColor(_ input: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
        if let match = hexColorRegex.firstMatch(in: input, options: [], range: nsRange),
           let hexRange = Range(match.range(at: 1), in: input) {
            let hex = String(input[hexRange])
            var value: UInt64 = 0
            guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
            switch hex.count {
            case 3:
                let r = Double((value >> 8) & 0xF) / 15.0
                let g = Double((value >> 4) & 0xF) / 15.0
                let b = Double(value & 0xF) / 15.0
                return (r, g, b, 1.0)
            case 6:
                let r = Double((value >> 16) & 0xFF) / 255.0
                let g = Double((value >> 8) & 0xFF) / 255.0
                let b = Double(value & 0xFF) / 255.0
                return (r, g, b, 1.0)
            case 8:
                let r = Double((value >> 24) & 0xFF) / 255.0
                let g = Double((value >> 16) & 0xFF) / 255.0
                let b = Double((value >> 8) & 0xFF) / 255.0
                let a = Double(value & 0xFF) / 255.0
                return (r, g, b, a)
            default:
                return nil
            }
        }

        if let match = rgbColorRegex.firstMatch(in: input, options: [], range: nsRange),
           let rR = Range(match.range(at: 1), in: input),
           let gR = Range(match.range(at: 2), in: input),
           let bR = Range(match.range(at: 3), in: input),
           let rInt = Int(input[rR]), let gInt = Int(input[gR]), let bInt = Int(input[bR]),
           (0...255).contains(rInt), (0...255).contains(gInt), (0...255).contains(bInt) {
            var alpha = 1.0
            if match.range(at: 4).location != NSNotFound,
               let aR = Range(match.range(at: 4), in: input),
               let parsedA = Double(input[aR]) {
                alpha = min(max(parsedA, 0.0), 1.0)
            }
            return (Double(rInt) / 255.0, Double(gInt) / 255.0, Double(bInt) / 255.0, alpha)
        }
        return nil
    }

    private static func formatHex(_ c: (r: Double, g: Double, b: Double, a: Double)) -> String {
        let r = Int(round(c.r * 255))
        let g = Int(round(c.g * 255))
        let b = Int(round(c.b * 255))
        if c.a < 0.995 {
            let a = Int(round(c.a * 255))
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func formatRGB(_ c: (r: Double, g: Double, b: Double, a: Double)) -> String {
        let r = Int(round(c.r * 255))
        let g = Int(round(c.g * 255))
        let b = Int(round(c.b * 255))
        if c.a < 0.995 {
            return String(format: "rgba(%d, %d, %d, %.2f)", r, g, b, c.a)
        }
        return "rgb(\(r), \(g), \(b))"
    }

    private static func formatSwiftUIColor(_ c: (r: Double, g: Double, b: Double, a: Double)) -> String {
        if c.a < 0.995 {
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f, opacity: %.2f)", c.r, c.g, c.b, c.a)
        }
        return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", c.r, c.g, c.b)
    }

    // MARK: - 辅助工具

    private static func isMostlyPrintableText(_ s: String) -> Bool {
        var printable = 0
        var total = 0
        for scalar in s.unicodeScalars {
            total += 1
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F) {
                printable += 1
            }
        }
        return total > 0 && Double(printable) / Double(total) > 0.92
    }

    private static func splitIdentifierWords(_ input: String) -> [String] {
        guard input.range(of: #"^[A-Za-z][A-Za-z0-9_\-]*$"#, options: .regularExpression) != nil else {
            return []
        }
        if input.contains("_") {
            return input.split(separator: "_").map(String.init).filter { !$0.isEmpty }
        }
        if input.contains("-") {
            return input.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        }
        // camelCase / PascalCase 拆分
        var words: [String] = []
        var current = ""
        for ch in input {
            if ch.isUppercase && !current.isEmpty && current.last?.isLowercase == true {
                words.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.count >= 2 ? words : []
    }

    private static func toCamelCase(_ words: [String]) -> String {
        guard let first = words.first else { return "" }
        let rest = words.dropFirst().map { word -> String in
            let lower = word.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return ([first.lowercased()] + rest).joined()
    }

    // MARK: - cURL 解析、SQL IN 构造与代码缩进清洗

    private static func extractURLFromCurl(_ curl: String) -> String? {
        let pattern = #"https?://[^\s'"\\]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: curl, options: [], range: NSRange(curl.startIndex..<curl.endIndex, in: curl)),
              let range = Range(match.range, in: curl) else {
            return nil
        }
        return String(curl[range])
    }

    private static func convertCurlToFetch(_ curl: String) -> String? {
        let unfolded = curl.replacingOccurrences(of: "\\\n", with: " ").replacingOccurrences(of: "\\\r\n", with: " ")
        guard let url = extractURLFromCurl(unfolded) else { return nil }

        var method: String? = nil
        if let mRegex = try? NSRegularExpression(pattern: #"(?:-X|--request)\s+['"]?([A-Z]+)['"]?"#),
           let m = mRegex.firstMatch(in: unfolded, options: [], range: NSRange(unfolded.startIndex..<unfolded.endIndex, in: unfolded)),
           let r = Range(m.range(at: 1), in: unfolded) {
            method = String(unfolded[r])
        }

        var headers: [(String, String)] = []
        if let hRegex = try? NSRegularExpression(pattern: #"(?:-H|--header)\s+(['"])(.*?)\1"#) {
            let matches = hRegex.matches(in: unfolded, options: [], range: NSRange(unfolded.startIndex..<unfolded.endIndex, in: unfolded))
            for match in matches {
                if let r = Range(match.range(at: 2), in: unfolded) {
                    let rawHeader = String(unfolded[r])
                    let parts = rawHeader.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let k = parts[0].trimmingCharacters(in: .whitespaces)
                        let v = parts[1].trimmingCharacters(in: .whitespaces)
                        headers.append((k, v))
                    }
                }
            }
        }

        var bodyData: String? = nil
        if let dRegex = try? NSRegularExpression(pattern: #"(?:--data-raw|--data-binary|--data|-d)\s+(['"])([\s\S]*?)\1"#),
           let m = dRegex.firstMatch(in: unfolded, options: [], range: NSRange(unfolded.startIndex..<unfolded.endIndex, in: unfolded)),
           let r = Range(m.range(at: 2), in: unfolded) {
            bodyData = String(unfolded[r])
        }

        let finalMethod = method ?? (bodyData != nil ? "POST" : "GET")
        var lines: [String] = []
        lines.append("const response = await fetch(\"\(url)\", {")
        lines.append("  method: \"\(finalMethod)\",")
        if !headers.isEmpty {
            lines.append("  headers: {")
            for (k, v) in headers {
                let escapedV = v.replacingOccurrences(of: "\"", with: "\\\"")
                lines.append("    \"\(k)\": \"\(escapedV)\",")
            }
            lines.append("  },")
        }
        if let bodyData {
            let escapedBody = bodyData.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
            lines.append("  body: `\(escapedBody)`")
        }
        lines.append("});")
        return lines.joined(separator: "\n")
    }

    private static func buildSQLInClause(_ items: [String]) -> String {
        let allNumeric = items.allSatisfy { Int64($0) != nil }
        if allNumeric {
            return "(\(items.joined(separator: ", ")))"
        }
        let quoted = items.map { item -> String in
            let escaped = item.replacingOccurrences(of: "'", with: "''")
            return "'\(escaped)'"
        }
        return "(\(quoted.joined(separator: ", ")))"
    }

    private static func stripCommonLeadingIndent(_ raw: String) -> String? {
        let lines = raw.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonEmpty.count >= 2 else { return nil }

        let minIndent = nonEmpty.map { line -> Int in
            var count = 0
            for ch in line {
                if ch == " " { count += 1 }
                else if ch == "\t" { count += 4 }
                else { break }
            }
            return count
        }.min() ?? 0

        guard minIndent >= 4 else { return nil }
        let stripped = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
            var removed = 0
            var idx = line.startIndex
            while idx < line.endIndex && removed < minIndent {
                let ch = line[idx]
                if ch == " " {
                    removed += 1
                    idx = line.index(after: idx)
                } else if ch == "\t" {
                    removed += 4
                    idx = line.index(after: idx)
                } else {
                    break
                }
            }
            return String(line[idx...])
        }.joined(separator: "\n")

        return stripped != raw ? stripped : nil
    }

    // MARK: - 1MB 超长负载性能基准自检（--bench-semantic）

    static func runMicroBenchmark() -> String {
        let oneMBLog = "ERROR [2026-11-22] Authorization: Bearer sk-proj-1234567890abcdefghijklmnop client=192.168.1.88 "
            + String(repeating: "stacktrace_frame_line_padding_0123456789abcdef ", count: 22_000)
        let largeItem = ClipItem(type: .text, text: oneMBLog, contentHash: "bench:1mb")
        let jsonItem = ClipItem(type: .text, text: #"{"user":"alice","id":1024,"roles":["admin","dev"]}"#, contentHash: "bench:json")
        let dirtyURLItem = ClipItem(type: .link, text: "https://webfooo.com/post/1?utm_source=x&spm=101.202&id=7", contentHash: "bench:url")

        let iterations = 100
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = analyze(largeItem)
        }
        let avg1MBMs = ((CFAbsoluteTimeGetCurrent() - start) / Double(iterations)) * 1000.0

        let startSmall = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = analyze(jsonItem)
            _ = analyze(dirtyURLItem)
        }
        let avgSmallMs = ((CFAbsoluteTimeGetCurrent() - startSmall) / Double(iterations * 2)) * 1000.0

        return String(format: "1MB 超长日志嗅探平均耗时: %.3f ms (目标 < 0.300 ms) | 常规 JSON/URL 平均耗时: %.4f ms", avg1MBMs, avgSmallMs)
    }
}
#endif
