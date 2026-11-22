import Foundation

/// 销售访谈 / 律所笔录 / 隐私高敏场景引擎：
/// 1. 飞书妙记 / 腾讯会议 / 通义听悟 / SRT 字幕时间轴剥离与同发言人自动合并；
/// 2. 中英文短信/邮件一次性验证码（OTP）精准提取（防银行尾号/有效分钟数误判）与阅后即焚判定。
enum MeetingAndEphemeralEngine {

    // MARK: - 预编译正则规则

    /// SRT / WebVTT 时间轴行：00:00:01,200 --> 00:00:04,500 或 00:01.200 --> 00:04.500
    private static let srtTimelineRegex = try! NSRegularExpression(
        pattern: #"^\s*\d{1,2}:\d{2}(?::\d{2})?[.,]\d{1,3}\s*-->\s*\d{1,2}:\d{2}(?::\d{2})?[.,]\d{1,3}.*$"#
    )

    /// 飞书妙记 / 腾讯会议 / 通义听悟独立说话人+时间行：
    /// 例如："张总监 00:12:35"、"说话人 1  12:05"、"Speaker A 01:02:03"、"李律师 (00:05:12)"
    private static let speakerHeaderLineRegex = try! NSRegularExpression(
        pattern: #"^\s*([^\d\[\]\n:：]{1,24}?(?:\s*\d{1,2})?)\s*[\(\[（【]?\b(\d{1,2}:\d{2}(?::\d{2})?)\b[\)\]）】]?\s*$"#
    )

    /// 纯时间戳独立行："[00:12:35]" 或 "00:12:35"
    private static let standaloneTimestampLineRegex = try! NSRegularExpression(
        pattern: #"^\s*[\(\[（【]?(\d{1,2}:\d{2}(?::\d{2})?)[\)\]）】]?\s*$"#
    )

    /// 单行内联时间戳+可选发言人前缀：
    /// 例如："[00:12:35] 王经理：先把报价单发过去" 或 "00:03:12 陈总: 同意这个方案" 或 "[01:23] 好的没问题"
    private static let inlineTimestampPrefixRegex = try! NSRegularExpression(
        pattern: #"^\s*[\(\[（【]?\b(\d{1,2}:\d{2}(?::\d{2})?)\b[\)\]）】]?\s*(?:([^\d\[\]\n:：]{1,20}?)\s*[:：]\s*)?(.+)$"#
    )

    /// 发言人前置 + 时间戳 + 冒号内联格式：
    /// 例如："王经理 00:12:35：先把报价单发过去"
    private static let speakerThenInlineTimeRegex = try! NSRegularExpression(
        pattern: #"^\s*([^\d\[\]\n:：]{1,20}?)\s+[\(\[（【]?\b(\d{1,2}:\d{2}(?::\d{2})?)\b[\)\]）】]?\s*[:：]\s*(.+)$"#
    )

    /// 排除技术与服务器日志特征，严防把运维 Debug 日志误判为会议逐字稿
    private static let serverLogExclusionRegex = try! NSRegularExpression(
        pattern: #"(?:\[(?:INFO|WARN|WARNING|ERROR|DEBUG|TRACE|FATAL)\]|Exception\b|Traceback\b|\bHTTP/\d\.\d\b|\b(?:GET|POST|PUT|DELETE)\s+/|\berrno\b|\bpid=\d+)"#,
        options: []
    )

    /// 验证码语义关键词（中英文）
    private static let otpContextKeywords: [String] = [
        "验证码", "校验码", "动态码", "安全码", "确认码", "登录码", "授权码", "提取码", "认证码",
        "verification code", "security code", "auth code", "authentication code",
        "login code", "confirmation code", "one-time password", "one-time code", "passcode", "otp"
    ]

    /// 验证码干扰项清洗正则（提前抹除尾号、金额、有效分钟/秒数、日期时间，防止误抓非验证码数字）
    private static let otpNoiseSanitizeRegexes: [NSRegularExpression] = [
        // 银行卡/手机尾号：尾号 8899 / 尾号为1234 / ending in 1234
        try! NSRegularExpression(pattern: #"(?:尾号(?:为|是)?|ending\s+in)\s*[0-9A-Za-z]{3,6}"#, options: [.caseInsensitive]),
        // 有效期时长：5分钟 / 10 mins / 300秒 / 60s / 24小时
        try! NSRegularExpression(pattern: #"\b\d{1,4}\s*(?:分钟|分|秒钟|秒|小时|min|mins|minute|minutes|sec|secs|second|seconds|hr|hrs|hours)\b"#, options: [.caseInsensitive]),
        // 金额：¥100.00 / 1280元 / RMB 500
        try! NSRegularExpression(pattern: #"(?:[¥￥$€£]\s*\d+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?\s*(?:元|圆|RMB|USD))"#, options: [.caseInsensitive]),
        // 日期与时间：2026-11-22 / 10:30:00
        try! NSRegularExpression(pattern: #"\b(?:\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?|\d{1,2}:\d{2}(?::\d{2})?)\b"#)
    ]

    /// 紧跟验证码关键词后的高优先级匹配（如：验证码为：839201 / code is 482910）
    private static let otpAfterKeywordRegex = try! NSRegularExpression(
        pattern: #"(?:验证码|校验码|动态码|安全码|确认码|登录码|授权码|提取码|认证码|(?:verification|security|auth|authentication|login|confirmation|one-time)\s+code|passcode|\botp\b)\s*(?:为|是|is)?\s*[:：]?\s*[\(\[【「『"']?([0-9]{4,8}|(?=[A-Z0-9]{4,8}\b)(?=[A-Z0-9]*\d)[A-Z0-9]{4,8})[\)\]】」』"']?"#,
        options: [.caseInsensitive]
    )

    /// 验证码在前、关键词在后的句式（如：918273 is your OpenAI security code / 839201（登录验证码））
    private static let otpBeforeKeywordRegex = try! NSRegularExpression(
        pattern: #"\b([0-9]{4,8}|(?=[A-Z0-9]{4,8}\b)(?=[A-Z0-9]*\d)[A-Z0-9]{4,8})\b[^\n]{0,28}?(?:验证码|校验码|动态码|安全码|确认码|(?:verification|security|auth|login|confirmation|one-time)\s+code|passcode|\botp\b)"#,
        options: [.caseInsensitive]
    )

    /// 兜底：清洗干扰数字后的独立 4~8 位纯数字验证码
    private static let fallbackDigitsRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])([0-9]{4,8})(?![0-9A-Za-z])"#
    )

    // MARK: - 统一分析入口（供 Flow 版与 Dev 版复用）

    static func analyze(_ rawText: String) -> [FinanceQuickAction] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1. 一次性验证码 / 提取码（OTP）提取（若网盘/会议口令同时内嵌分享链接，并列附带「提取纯净链接」胶囊）
        if let otp = extractVerificationCode(from: trimmed), otp != trimmed {
            var actions = [
                FinanceQuickAction(
                    id: "otp-extract-code",
                    title: "验证码 \(otp)",
                    symbolName: "key.horizontal.fill",
                    resultText: otp,
                    toastText: "已提取纯验证码 \(otp) 并键入"
                )
            ]
            if let shareURL = URLTrackingCleaner.extractCleanShareURL(from: trimmed) {
                actions.append(FinanceQuickAction(
                    id: "extract-share-url",
                    title: "提取纯净链接",
                    symbolName: "link",
                    resultText: shareURL,
                    toastText: "已剥除口令废话与追踪尾巴，键入纯净链接"
                ))
            }
            return actions
        }

        // 1.5 社媒分享口令 / 群聊混排文案一键剥壳提纯干净 URL
        if let shareURL = URLTrackingCleaner.extractCleanShareURL(from: trimmed) {
            return [
                FinanceQuickAction(
                    id: "extract-share-url",
                    title: "提取纯净链接",
                    symbolName: "link",
                    resultText: shareURL,
                    toastText: "已剥除口令废话与追踪尾巴，键入纯净链接"
                )
            ]
        }

        // 2. 会议逐字稿 / 字幕时间轴清洗
        if trimmed.contains("\n"), let cleaned = cleanMeetingTranscript(rawText) {
            var actions: [FinanceQuickAction] = [
                FinanceQuickAction(
                    id: "meet-plain-body",
                    title: "纯享正文(去时间轴)",
                    symbolName: "text.quote",
                    resultText: cleaned.plainBody,
                    toastText: "已剥离 \(cleaned.removedTimestampCount) 处会议时间轴"
                )
            ]
            if let speakerDialogue = cleaned.speakerMergedDialogue, speakerDialogue != cleaned.plainBody {
                actions.append(FinanceQuickAction(
                    id: "meet-speaker-notes",
                    title: "按发言人合并纪要",
                    symbolName: "person.2.wave.2.fill",
                    resultText: speakerDialogue,
                    toastText: "已合并同发言人段落并去除时间轴"
                ))
            }
            return actions
        }

        return []
    }

    // MARK: - 1. 一次性验证码（OTP）精准提取与判定

    /// 判断文本是否为含上下文语义的短信/邮件验证码消息（用于粘贴后阅后即焚判定）
    static func isOTPMessage(_ rawText: String) -> Bool {
        extractVerificationCode(from: rawText) != nil
    }

    /// 从短信/邮件正文中提取 4~8 位一次性验证码；普通数字、长文或纯号码返回 nil
    static func extractVerificationCode(from rawText: String) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6, trimmed.utf16.count <= 400 else { return nil }

        let lineCount = trimmed.components(separatedBy: .newlines).count
        guard lineCount <= 8 else { return nil }

        let lower = trimmed.lowercased()
        let hasKeyword = otpContextKeywords.contains { kw in
            if kw == "otp" {
                return lower.range(of: #"\botp\b"#, options: .regularExpression) != nil
            }
            return lower.contains(kw)
        }
        guard hasKeyword else { return nil }

        // 先抹除尾号、有效分钟数、金额与日期干扰项
        var sanitized = trimmed
        for regex in otpNoiseSanitizeRegexes {
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: " ")
        }

        let nsRange = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)

        // 优先 1：关键词在前的紧邻匹配
        if let m1 = otpAfterKeywordRegex.firstMatch(in: sanitized, options: [], range: nsRange),
           let r1 = Range(m1.range(at: 1), in: sanitized) {
            return String(sanitized[r1])
        }

        // 优先 2：验证码在前、关键词在后的句式
        if let m2 = otpBeforeKeywordRegex.firstMatch(in: sanitized, options: [], range: nsRange),
           let r2 = Range(m2.range(at: 1), in: sanitized) {
            return String(sanitized[r2])
        }

        // 优先 3：已确认含验证码语义词且抹除干扰项后，提取首个 4~8 位纯数字
        if let m3 = fallbackDigitsRegex.firstMatch(in: sanitized, options: [], range: nsRange),
           let r3 = Range(m3.range(at: 1), in: sanitized) {
            return String(sanitized[r3])
        }

        return nil
    }

    // MARK: - 2. 会议逐字稿 / 字幕时间轴剥离与发言人合并

    struct CleanedTranscriptResult: Equatable {
        let plainBody: String
        let speakerMergedDialogue: String?
        let removedTimestampCount: Int
    }

    static func cleanMeetingTranscript(_ rawText: String) -> CleanedTranscriptResult? {
        guard rawText.utf16.count <= 65_536, rawText.contains(":") else { return nil }

        // 排除服务器/开发运行日志
        let fullRange = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
        if serverLogExclusionRegex.firstMatch(in: rawText, options: [], range: fullRange) != nil {
            return nil
        }

        let rawLines = rawText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard rawLines.count >= 2 else { return nil }

        var timestampHits = 0
        var activeSpeaker: String? = nil
        var plainSegments: [String] = []
        var dialogueTurns: [(speaker: String?, text: String)] = []

        var i = 0
        while i < rawLines.count {
            let line = rawLines[i].trimmingCharacters(in: .whitespacesAndNewlines)

            // 空行与 WEBVTT 头部跳过
            if line.isEmpty || line.uppercased() == "WEBVTT" {
                i += 1
                continue
            }

            // SRT 序号行：当前行是纯数字且下一行是 SRT 箭头时间轴
            if line.allSatisfy(\.isNumber), i + 1 < rawLines.count {
                let nextLine = rawLines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                let nextRange = NSRange(nextLine.startIndex..<nextLine.endIndex, in: nextLine)
                if srtTimelineRegex.firstMatch(in: nextLine, options: [], range: nextRange) != nil {
                    timestampHits += 1
                    i += 2
                    continue
                }
            }

            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)

            // 1) SRT / VTT 箭头时间轴行
            if srtTimelineRegex.firstMatch(in: line, options: [], range: lineRange) != nil {
                timestampHits += 1
                i += 1
                continue
            }

            // 2) 纯独立时间戳行 "[00:12:35]"
            if standaloneTimestampLineRegex.firstMatch(in: line, options: [], range: lineRange) != nil {
                timestampHits += 1
                i += 1
                continue
            }

            // 3) 飞书妙记 / 腾讯会议 说话人 + 时间戳标题行："张总监 00:12:35"
            if let headerMatch = speakerHeaderLineRegex.firstMatch(in: line, options: [], range: lineRange),
               let speakerRange = Range(headerMatch.range(at: 1), in: line) {
                let speaker = line[speakerRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if !speaker.isEmpty {
                    activeSpeaker = speaker
                    timestampHits += 1
                    i += 1
                    continue
                }
            }

            // 4) "王经理 00:12:35：发言内容"
            if let spInline = speakerThenInlineTimeRegex.firstMatch(in: line, options: [], range: lineRange),
               let spRange = Range(spInline.range(at: 1), in: line),
               let contentRange = Range(spInline.range(at: 3), in: line) {
                let speaker = line[spRange].trimmingCharacters(in: .whitespacesAndNewlines)
                let content = line[contentRange].trimmingCharacters(in: .whitespacesAndNewlines)
                timestampHits += 1
                if !content.isEmpty {
                    plainSegments.append(content)
                    appendTurn(speaker: speaker.isEmpty ? activeSpeaker : speaker, text: content, into: &dialogueTurns)
                }
                i += 1
                continue
            }

            // 5) "[00:12:35] 王经理：发言内容" 或 "[00:12:35] 发言内容"
            if let inlineMatch = inlineTimestampPrefixRegex.firstMatch(in: line, options: [], range: lineRange),
               let contentRange = Range(inlineMatch.range(at: 3), in: line) {
                let inlineSpeaker: String? = {
                    guard inlineMatch.range(at: 2).location != NSNotFound,
                          let r = Range(inlineMatch.range(at: 2), in: line) else { return nil }
                    let s = line[r].trimmingCharacters(in: .whitespacesAndNewlines)
                    return s.isEmpty ? nil : s
                }()
                let content = line[contentRange].trimmingCharacters(in: .whitespacesAndNewlines)
                timestampHits += 1
                if let inlineSpeaker {
                    activeSpeaker = inlineSpeaker
                }
                if !content.isEmpty {
                    plainSegments.append(content)
                    appendTurn(speaker: inlineSpeaker ?? activeSpeaker, text: content, into: &dialogueTurns)
                }
                i += 1
                continue
            }

            // 普通正文行
            plainSegments.append(line)
            appendTurn(speaker: activeSpeaker, text: line, into: &dialogueTurns)
            i += 1
        }

        // 至少命中 2 处时间轴且提取出了有效正文，才认定为会议逐字稿/字幕
        guard timestampHits >= 2, !plainSegments.isEmpty else {
            return nil
        }

        let plainBody = joinNaturalSentences(plainSegments)

        let hasNamedSpeaker = dialogueTurns.contains { ($0.speaker?.isEmpty == false) }
        let speakerMerged: String?
        if hasNamedSpeaker {
            let formattedTurns = dialogueTurns.map { turn -> String in
                if let sp = turn.speaker, !sp.isEmpty {
                    return "\(sp)：\(turn.text)"
                }
                return turn.text
            }
            speakerMerged = formattedTurns.joined(separator: "\n")
        } else {
            speakerMerged = nil
        }

        return CleanedTranscriptResult(
            plainBody: plainBody,
            speakerMergedDialogue: speakerMerged,
            removedTimestampCount: timestampHits
        )
    }

    private static func appendTurn(speaker: String?, text: String, into turns: inout [(speaker: String?, text: String)]) {
        if let last = turns.last, last.speaker == speaker {
            let merged = joinTwoFragments(last.text, text)
            turns[turns.count - 1].text = merged
        } else {
            turns.append((speaker: speaker, text: text))
        }
    }

    private static func joinNaturalSentences(_ segments: [String]) -> String {
        guard var acc = segments.first else { return "" }
        for seg in segments.dropFirst() {
            acc = joinTwoFragments(acc, seg)
        }
        return acc
    }

    private static func joinTwoFragments(_ lhs: String, _ rhs: String) -> String {
        guard let lastChar = lhs.last, let firstChar = rhs.first else {
            return lhs + rhs
        }
        let terminalPunct: Set<Character> = ["。", "！", "？", "；", "，", "、", ".", "!", "?", ";", ","]
        let lhsIsASCII = lastChar.isASCII && (lastChar.isLetter || lastChar.isNumber || terminalPunct.contains(lastChar))
        let rhsIsASCII = firstChar.isASCII && (firstChar.isLetter || firstChar.isNumber)

        if terminalPunct.contains(lastChar) {
            if lhsIsASCII && rhsIsASCII {
                return "\(lhs) \(rhs)"
            }
            return "\(lhs)\(rhs)"
        }

        // 若前一句末尾没有标点：中文补全逗号或空格，英文补空格
        if lhsIsASCII || rhsIsASCII {
            return "\(lhs) \(rhs)"
        }
        return "\(lhs)，\(rhs)"
    }
}
