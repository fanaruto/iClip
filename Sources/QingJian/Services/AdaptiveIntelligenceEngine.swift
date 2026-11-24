import Foundation
import AppKit

/// 可由用户习惯自动晋升或通过建议直接开启的「复制即自动处理」契约规则
enum LearnedAutoRuleKind: String, CaseIterable, Codable, Identifiable {
    case stripRichTextFormatting
    case extractCleanShareLink
    case cleanTrackingURL
    case healPDFLineBreaks
    case applyPanguSpacing
    case extractPureOTP
    case cleanMeetingTranscript
    case compressLargeImage
    case extractQRCode
    case sanitizeInvisibleChars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stripRichTextFormatting: return "复制富文本自动剥离脏样式（智能保护表格）"
        case .extractCleanShareLink: return "复制社媒分享口令自动剥壳提取纯净链接"
        case .cleanTrackingURL: return "复制链接自动剥离追踪尾巴"
        case .healPDFLineBreaks: return "复制 PDF 段落自动愈合断行"
        case .applyPanguSpacing: return "复制中英混排自动加盘古空格"
        case .extractPureOTP: return "复制验证码短信直接提取纯数字"
        case .cleanMeetingTranscript: return "复制会议纪要自动剥离时间轴"
        case .compressLargeImage: return "复制超大截图（>1.5MB）自动轻量优化"
        case .extractQRCode: return "复制二维码截图自动提取链接/内容"
        case .sanitizeInvisibleChars: return "复制文本自动清除零宽幽灵与隐藏控制符"
        }
    }

    var shortToast: String {
        switch self {
        case .stripRichTextFormatting: return "智能契约：已自动净化为纯文本"
        case .extractCleanShareLink: return "智能契约：已从分享口令提取纯净链接"
        case .cleanTrackingURL: return "智能契约：已自动净链去追踪"
        case .healPDFLineBreaks: return "智能契约：已自动愈合 PDF 断行"
        case .applyPanguSpacing: return "智能契约：已自动优化中英间距"
        case .extractPureOTP: return "智能契约：已自动提取纯验证码"
        case .cleanMeetingTranscript: return "智能契约：已自动剥离会议时间轴"
        case .compressLargeImage: return "智能契约：已自动轻量优化大图"
        case .extractQRCode: return "智能契约：已自动提取图中二维码"
        case .sanitizeInvisibleChars: return "智能契约：已自动清除隐形幽灵与控制符"
        }
    }

    /// 关联的手动动作 ID（当用户连续 3 次手动执行该动作时，主动提议晋升为全自动契约）
    static func fromActionID(_ actionID: String) -> LearnedAutoRuleKind? {
        switch actionID {
        case "strip-rich-style": return .stripRichTextFormatting
        case "extract-share-url": return .extractCleanShareLink
        case "clean-url": return .cleanTrackingURL
        case "doc-pdf-heal": return .healPDFLineBreaks
        case "doc-pangu-space": return .applyPanguSpacing
        case "otp-extract-code": return .extractPureOTP
        case "meet-plain-body", "meet-speaker-notes": return .cleanMeetingTranscript
        case "img-compress": return .compressLargeImage
        case "img-qrcode": return .extractQRCode
        case "sanitize-invisible-poison": return .sanitizeInvisibleChars
        default: return nil
        }
    }
}

/// 用户提交的自然语言调教建议记录（同时供 20 分钟自省进化循环读取落地）
struct UserSuggestionRecord: Identifiable, Codable, Equatable {
    enum Status: String, Codable, Equatable {
        case adoptedImmediately
        case queuedForEvolution
    }

    let id: UUID
    let createdAt: Date
    let rawText: String
    let status: Status
    let responseSummary: String
}

/// 提交建议后的即时处理结果
struct SuggestionAdoptionOutcome: Equatable {
    let adoptedImmediately: Bool
    let message: String
    let record: UserSuggestionRecord
}

/// 光标角「灵动微星标（Action Spark）」单次推荐动作载荷
struct AdaptiveSparkCandidate: Equatable {
    enum Payload: Equatable {
        case replaceClipboardText(text: String, htmlTable: String?, toast: String)
        case compressImage(itemID: UUID)
        case mockupImage(itemID: UUID)
        case privacyMosaicImage(itemID: UUID)
        case extractImageOCR(itemID: UUID)
        case pinFrequentItem(itemID: UUID)
        case markAsTodo(itemID: UUID)
        case splitChecklistIntoTodos(itemID: UUID)
    }

    let actionID: String
    let categoryKey: String
    let sourceApp: String?
    let symbolName: String
    let shortTitle: String
    let badgeHint: String?
    let promotableRule: LearnedAutoRuleKind?
    let payload: Payload
}

/// 持久化心智状态（纯本地轻量 JSON，< 32 KB，零网络上传）
private struct AdaptiveBrainState: Codable {
    var sparkEnabled: Bool = true
    var sparkDurationSeconds: Double = 2.0
    var doubleCopySparkEnabled: Bool? = true
    var copyAppendEnabled: Bool? = true
    var cursorDropPodEnabled: Bool? = true
    var smartContextRankingEnabled: Bool? = true
    var actionWeights: [String: Double] = [:]
    var appActionWeights: [String: [String: Double]] = [:]
    var actionAcceptCounts: [String: Int] = [:]
    var categoryDismissStreaks: [String: Int] = [:]
    var enabledAutoRules: Set<LearnedAutoRuleKind> = []
    var declinedAutoRules: Set<LearnedAutoRuleKind> = []
    var mutedSourceApps: [String] = []
    var recentReuseCounts: [String: Int] = [:]
    var recentReuseOrder: [String] = []
    var targetAppPasteCounts: [String: [String: Int]]? = [:]
    var targetAppDisplayNames: [String: String]? = [:]
    var totalLearnedInteractions: Int = 0
}

/// iClip 自适应心智引擎：
/// 1. 隐式学习「来源应用 × 内容类型 → 常用转换动作」亲和权重，动态置顶高频动作；
/// 2. 感知用户忽略与关闭反馈，对低需求提示自动退避静默，绝不死缠烂打；
/// 3. 连续 3 次重复同一操作时主动请示晋升为全自动契约；
/// 4. 解析并立即采纳用户的自然语言调教建议，将开放需求沉淀至自省进化队列。
@MainActor
final class AdaptiveIntelligenceEngine: ObservableObject {
    static let shared = AdaptiveIntelligenceEngine()

    @Published var sparkEnabled: Bool {
        didSet {
            guard state.sparkEnabled != sparkEnabled else { return }
            state.sparkEnabled = sparkEnabled
            scheduleSave()
        }
    }

    @Published var sparkDurationSeconds: Double {
        didSet {
            let clamped = min(max(sparkDurationSeconds, 1.0), 4.5)
            guard abs(state.sparkDurationSeconds - clamped) > 0.01 else { return }
            state.sparkDurationSeconds = clamped
            scheduleSave()
        }
    }

    /// 微星标浮现期间连按第 2 次 ⌘C 免鼠标零离手触发智变（按第 3 次 ⌘C 自动还原原文）
    @Published var doubleCopySparkEnabled: Bool {
        didSet {
            guard (state.doubleCopySparkEnabled ?? true) != doubleCopySparkEnabled else { return }
            state.doubleCopySparkEnabled = doubleCopySparkEnabled
            scheduleSave()
        }
    }

    /// 跨处选段按 ⌃⌥C 零切窗「续接复制（Copy-Append）」开关
    @Published var copyAppendEnabled: Bool {
        didSet {
            guard (state.copyAppendEnabled ?? true) != copyAppendEnabled else { return }
            state.copyAppendEnabled = copyAppendEnabled
            scheduleSave()
        }
    }

    @Published var cursorDropPodEnabled: Bool {
        didSet {
            guard (state.cursorDropPodEnabled ?? true) != cursorDropPodEnabled else { return }
            state.cursorDropPodEnabled = cursorDropPodEnabled
            scheduleSave()
        }
    }

    /// 情境感知搜索与收藏排序开关：自动记忆「哪条记录常贴入哪个目标窗口」并优化检索/收藏顺位
    @Published var smartContextRankingEnabled: Bool {
        didSet {
            guard (state.smartContextRankingEnabled ?? true) != smartContextRankingEnabled else { return }
            state.smartContextRankingEnabled = smartContextRankingEnabled
            revision &+= 1
            scheduleSave()
        }
    }

    @Published private(set) var enabledAutoRules: Set<LearnedAutoRuleKind> = []
    @Published private(set) var mutedSourceApps: [String] = []
    @Published private(set) var suggestions: [UserSuggestionRecord] = []
    @Published private(set) var totalLearnedInteractions: Int = 0
    /// 递增版本号：用于通知外部缓存（如语义动作排序缓存）按需失效刷新
    @Published private(set) var revision: Int = 0

    private final class PersistenceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false

        func close() {
            lock.lock()
            closed = true
            lock.unlock()
        }

        func performIfOpen(requireCustomDir: Bool, dirPath: String, _ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            if requireCustomDir {
                guard !closed, FileManager.default.fileExists(atPath: dirPath) else { return }
            }
            body()
        }
    }

    private var state: AdaptiveBrainState
    private let brainFileURL: URL
    private let suggestionsFileURL: URL
    private let isCustomDirectory: Bool
    private let persistenceGate = PersistenceGate()
    private var saveWorkItem: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "com.qingjian.adaptive.io", qos: .utility)

    deinit {
        saveWorkItem?.cancel()
        if isCustomDirectory {
            persistenceGate.close()
        }
    }

    init(customDirectoryURL: URL? = nil) {
        let baseDir: URL
        if let customDirectoryURL {
            baseDir = customDirectoryURL
            self.isCustomDirectory = true
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            baseDir = appSupport.appendingPathComponent("QingJian", isDirectory: true)
            self.isCustomDirectory = false
        }
        try? FileManager.default.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
        self.brainFileURL = baseDir.appendingPathComponent("adaptive_intelligence.json")
        self.suggestionsFileURL = baseDir.appendingPathComponent("user_suggestions.json")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: brainFileURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: suggestionsFileURL.path)

        let loaded: AdaptiveBrainState
        var needsEncryptBrainUpgrade = false
        if let rawData = try? Data(contentsOf: brainFileURL),
           let opened = LocalVaultCrypto.openSnapshotData(rawData),
           let decoded = try? JSONDecoder().decode(AdaptiveBrainState.self, from: opened.plainData) {
            loaded = decoded
            needsEncryptBrainUpgrade = opened.wasLegacyPlaintext
        } else {
            loaded = AdaptiveBrainState()
        }
        self.state = loaded
        self.sparkEnabled = loaded.sparkEnabled
        self.sparkDurationSeconds = loaded.sparkDurationSeconds
        self.doubleCopySparkEnabled = loaded.doubleCopySparkEnabled ?? true
        self.copyAppendEnabled = loaded.copyAppendEnabled ?? true
        self.cursorDropPodEnabled = loaded.cursorDropPodEnabled ?? true
        self.smartContextRankingEnabled = loaded.smartContextRankingEnabled ?? true
        self.enabledAutoRules = loaded.enabledAutoRules
        self.mutedSourceApps = loaded.mutedSourceApps
        self.totalLearnedInteractions = loaded.totalLearnedInteractions

        var needsEncryptSugUpgrade = false
        if let sugRaw = try? Data(contentsOf: suggestionsFileURL),
           let openedSug = LocalVaultCrypto.openSnapshotData(sugRaw) {
            let decoder = JSONDecoder()
            let isoDec = JSONDecoder()
            isoDec.dateDecodingStrategy = .iso8601
            if let decodedSug = (try? isoDec.decode([UserSuggestionRecord].self, from: openedSug.plainData))
                ?? (try? decoder.decode([UserSuggestionRecord].self, from: openedSug.plainData)) {
                self.suggestions = decodedSug
                needsEncryptSugUpgrade = openedSug.wasLegacyPlaintext
            } else {
                self.suggestions = []
            }
        } else {
            self.suggestions = []
        }

        if needsEncryptBrainUpgrade {
            scheduleSave()
        }
        if needsEncryptSugUpgrade {
            saveSuggestions()
        }
    }

    // MARK: - 1. 动作亲和度打分与自适应排序

    /// 计算某个动作在指定来源应用下的习惯加权得分
    func affinityBoost(for actionID: String, sourceApp: String?) -> Double {
        let globalScore = state.actionWeights[actionID] ?? 0
        let appScore: Double
        if let app = normalizedAppKey(sourceApp) {
            appScore = state.appActionWeights[app]?[actionID] ?? 0
        } else {
            appScore = 0
        }
        return globalScore + appScore * 1.6
    }

    /// 判断某动作是否已被用户习惯显著偏爱（用于在 UI 展示微小的星芒记忆提示）
    func isHabitPreferred(actionID: String, sourceApp: String?) -> Bool {
        affinityBoost(for: actionID, sourceApp: sourceApp) >= 4.0
    }

    /// 按用户历史习惯对动作列表进行稳定重排（得分相同时完全保留原有精选顺序）
    func rankActions<T>(_ actions: [T], idOf: (T) -> String, sourceApp: String?) -> [T] {
        guard actions.count > 1 else { return actions }
        let enumerated = Array(actions.enumerated())
        let hasNonZero = enumerated.contains { abs(affinityBoost(for: idOf($0.element), sourceApp: sourceApp)) > 0.01 }
        guard hasNonZero else { return actions }

        return enumerated.sorted { lhs, rhs in
            let s1 = affinityBoost(for: idOf(lhs.element), sourceApp: sourceApp)
            let s2 = affinityBoost(for: idOf(rhs.element), sourceApp: sourceApp)
            if abs(s1 - s2) > 0.05 {
                return s1 > s2
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 记录用户主动使用某项转换动作（无论是从面板卡片点击还是从光标微星标点击）
    func recordActionUsed(actionID: String, categoryKey: String? = nil, sourceApp: String?) {
        let currentGlobal = state.actionWeights[actionID] ?? 0
        state.actionWeights[actionID] = min(currentGlobal + 2.5, 80.0)

        if let app = normalizedAppKey(sourceApp) {
            var appDict = state.appActionWeights[app] ?? [:]
            appDict[actionID] = min((appDict[actionID] ?? 0) + 3.0, 60.0)
            state.appActionWeights[app] = appDict
        }

        state.actionAcceptCounts[actionID, default: 0] += 1
        let resolvedCategory = categoryKey ?? Self.categoryKey(forActionID: actionID)
        state.categoryDismissStreaks[resolvedCategory] = 0

        state.totalLearnedInteractions += 1
        totalLearnedInteractions = state.totalLearnedInteractions
        revision &+= 1
        scheduleSave()
    }

    /// 记录用户点击微星标右侧 `×` 主动关闭：快速降低权重并累加退避计数
    func recordSparkExplicitDismiss(actionID: String, categoryKey: String, sourceApp: String?) {
        let currentGlobal = state.actionWeights[actionID] ?? 0
        state.actionWeights[actionID] = max(currentGlobal - 3.5, -25.0)

        if let app = normalizedAppKey(sourceApp) {
            var appDict = state.appActionWeights[app] ?? [:]
            appDict[actionID] = max((appDict[actionID] ?? 0) - 4.0, -25.0)
            state.appActionWeights[app] = appDict
        }

        state.categoryDismissStreaks[categoryKey, default: 0] += 3
        state.totalLearnedInteractions += 1
        totalLearnedInteractions = state.totalLearnedInteractions
        revision &+= 1
        scheduleSave()
    }

    /// 记录微星标自然超时未点击：温和累加退避计数，连续 6 次不理睬则自动休眠该类提示
    func recordSparkPassiveTimeout(categoryKey: String) {
        state.categoryDismissStreaks[categoryKey, default: 0] += 1
        scheduleSave()
    }

    // MARK: - 2. 高频内容复用追踪（沉淀个人高粘性收藏）

    /// 记录某条剪贴内容被复制或再次唤起粘贴，返回累计复用次数
    @discardableResult
    func recordContentActivity(contentHash: String) -> Int {
        guard !contentHash.isEmpty else { return 1 }
        let nextCount = (state.recentReuseCounts[contentHash] ?? 0) + 1
        state.recentReuseCounts[contentHash] = nextCount
        state.recentReuseOrder.removeAll { $0 == contentHash }
        state.recentReuseOrder.append(contentHash)

        if state.recentReuseOrder.count > 300 {
            let overflow = state.recentReuseOrder.count - 300
            let evicted = state.recentReuseOrder.prefix(overflow)
            for key in evicted {
                state.recentReuseCounts.removeValue(forKey: key)
            }
            state.recentReuseOrder.removeFirst(overflow)
        }
        scheduleSave()
        return nextCount
    }

    func reuseCount(for contentHash: String) -> Int {
        state.recentReuseCounts[contentHash] ?? 0
    }

    /// 物理级不可追溯遗忘：当敏感条目或历史记录被销毁时，同步连根抹除行为记忆库中的 SHA-256 内容指纹
    func forgetContentHashes(_ hashes: Set<String>) {
        guard !hashes.isEmpty else { return }
        var mutated = false
        for h in hashes {
            if state.recentReuseCounts.removeValue(forKey: h) != nil {
                mutated = true
            }
        }
        let beforeOrderCount = state.recentReuseOrder.count
        state.recentReuseOrder.removeAll { hashes.contains($0) }
        if state.recentReuseOrder.count != beforeOrderCount {
            mutated = true
        }
        if var allApps = state.targetAppPasteCounts {
            for (appKey, var bucket) in allApps {
                var appChanged = false
                for h in hashes {
                    if bucket.removeValue(forKey: h) != nil {
                        appChanged = true
                        mutated = true
                    }
                }
                if appChanged {
                    if bucket.isEmpty {
                        allApps.removeValue(forKey: appKey)
                        state.targetAppDisplayNames?.removeValue(forKey: appKey)
                    } else {
                        allApps[appKey] = bucket
                    }
                }
            }
            state.targetAppPasteCounts = allApps
        }
        if mutated {
            revision &+= 1
            scheduleSave()
        }
    }

    /// 记录用户将某条内容实际粘贴进外部目标应用（如微信、飞书、Terminal、Cursor），构建个人目标场景记忆
    func recordPasteToTargetApp(contentHash: String, targetApp: String?) {
        guard !contentHash.isEmpty, let appKey = normalizedAppKey(targetApp) else { return }
        let cleanDisplay = Self.compactAppDisplayName(from: targetApp ?? appKey)

        var allApps = state.targetAppPasteCounts ?? [:]
        var appBucket = allApps[appKey] ?? [:]
        appBucket[contentHash] = min((appBucket[contentHash] ?? 0) + 1, 999)

        // 单目标应用最多保留 80 条高频哈希，防止长期运行 JSON 膨胀
        if appBucket.count > 80 {
            if let victim = appBucket.filter({ $0.key != contentHash }).min(by: { $0.value < $1.value })?.key {
                appBucket.removeValue(forKey: victim)
            }
        }
        allApps[appKey] = appBucket

        // 全局最多跟踪 32 个外部常用应用
        if allApps.count > 32 {
            if let leastUsedApp = allApps
                .filter({ $0.key != appKey })
                .min(by: { lhs, rhs in
                    lhs.value.values.reduce(0, +) < rhs.value.values.reduce(0, +)
                })?.key {
                allApps.removeValue(forKey: leastUsedApp)
                state.targetAppDisplayNames?.removeValue(forKey: leastUsedApp)
            }
        }
        state.targetAppPasteCounts = allApps

        var names = state.targetAppDisplayNames ?? [:]
        names[appKey] = cleanDisplay
        state.targetAppDisplayNames = names

        state.totalLearnedInteractions += 1
        totalLearnedInteractions = state.totalLearnedInteractions
        revision &+= 1
        scheduleSave()
    }

    /// 查询某条内容在指定目标应用中的历史主动粘贴次数
    func targetAppPasteCount(for contentHash: String, targetApp: String?) -> Int {
        guard !contentHash.isEmpty, let appKey = normalizedAppKey(targetApp) else { return 0 }
        return state.targetAppPasteCounts?[appKey]?[contentHash] ?? 0
    }

    /// 当当前外部目标应用下该条目已被主动粘贴 ≥ 2 次时，返回紧凑的情境记忆微标签（如「✦ 微信常用」）
    func preferredTargetAppBadge(for contentHash: String, activeTargetApp: String?) -> String? {
        guard smartContextRankingEnabled else { return nil }
        guard let appKey = normalizedAppKey(activeTargetApp) else { return nil }
        let count = state.targetAppPasteCounts?[appKey]?[contentHash] ?? 0
        guard count >= 2 else { return nil }
        let label = state.targetAppDisplayNames?[appKey] ?? Self.compactAppDisplayName(from: activeTargetApp ?? "")
        guard !label.isEmpty else { return nil }
        return "✦ \(label)常用"
    }

    private static func compactAppDisplayName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "google chrome" { return "Chrome" }
        if lower == "visual studio code" { return "VSCode" }
        if lower == "iterm2" { return "iTerm" }
        if trimmed.count > 8 {
            return String(trimmed.prefix(7)) + "…"
        }
        return trimmed
    }

    // MARK: - 3. 已采纳的「复制即自动处理」契约执行

    func setAutoRule(_ rule: LearnedAutoRuleKind, enabled: Bool) {
        if enabled {
            state.enabledAutoRules.insert(rule)
            state.declinedAutoRules.remove(rule)
        } else {
            state.enabledAutoRules.remove(rule)
        }
        enabledAutoRules = state.enabledAutoRules
        state.totalLearnedInteractions += 1
        totalLearnedInteractions = state.totalLearnedInteractions
        revision &+= 1
        scheduleSave()
    }

    func declineAutoRulePromotion(_ rule: LearnedAutoRuleKind) {
        state.declinedAutoRules.insert(rule)
        scheduleSave()
    }

    func isSourceAppMuted(_ appName: String?) -> Bool {
        guard let key = normalizedAppKey(appName) else { return false }
        return state.mutedSourceApps.contains { normalizedAppKey($0) == key }
    }

    func setSourceAppMuted(_ appName: String, muted: Bool) {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = trimmed.lowercased()
        state.mutedSourceApps.removeAll { $0.lowercased() == key }
        if muted {
            state.mutedSourceApps.append(trimmed)
        }
        mutedSourceApps = state.mutedSourceApps
        revision &+= 1
        scheduleSave()
    }

    /// 在剪贴板捕获新文本瞬间，检查是否有用户已授权开启的全自动契约规则可立即净化内容
    func applyLearnedAutoTextRuleIfEnabled(rawText: String, isLink: Bool) -> (text: String, rule: LearnedAutoRuleKind)? {
        guard !state.enabledAutoRules.isEmpty else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 32_768 else { return nil }

        if state.enabledAutoRules.contains(.sanitizeInvisibleChars),
           ClipboardPoisonGuard.inspect(rawText) != nil {
            let cleaned = ClipboardPoisonGuard.sanitize(rawText)
            if cleaned != rawText && !cleaned.isEmpty {
                return (cleaned, .sanitizeInvisibleChars)
            }
        }

        if isLink, state.enabledAutoRules.contains(.cleanTrackingURL) {
            if let cleaned = URLTrackingCleaner.cleanTrackingURL(trimmed), cleaned != trimmed {
                return (cleaned, .cleanTrackingURL)
            }
        }

        if !isLink {
            if state.enabledAutoRules.contains(.extractPureOTP),
               MeetingAndEphemeralEngine.isOTPMessage(rawText),
               let code = MeetingAndEphemeralEngine.extractVerificationCode(from: rawText),
               code != trimmed {
                return (code, .extractPureOTP)
            }

            // 分享口令自动剥壳提纯（若同时含提取码/会议密码则自动保留原文，绝不误吞密码）
            if state.enabledAutoRules.contains(.extractCleanShareLink),
               !MeetingAndEphemeralEngine.isOTPMessage(rawText),
               let shareURL = URLTrackingCleaner.extractCleanShareURL(from: rawText),
               shareURL != trimmed {
                return (shareURL, .extractCleanShareLink)
            }

            if state.enabledAutoRules.contains(.cleanMeetingTranscript),
               let cleaned = MeetingAndEphemeralEngine.cleanMeetingTranscript(rawText),
               cleaned.plainBody != trimmed {
                return (cleaned.plainBody, .cleanMeetingTranscript)
            }

            if state.enabledAutoRules.contains(.healPDFLineBreaks),
               DocumentTypographyEngine.looksLikeBrokenPDFParagraphs(rawText) {
                let healed = DocumentTypographyEngine.healPDFLineBreaks(rawText)
                if healed != rawText {
                    return (healed, .healPDFLineBreaks)
                }
            }

            if state.enabledAutoRules.contains(.applyPanguSpacing),
               DocumentTypographyEngine.containsUnspacedCJKAndLatin(rawText) {
                let spaced = DocumentTypographyEngine.applyPanguSpacing(rawText)
                if spaced != rawText {
                    return (spaced, .applyPanguSpacing)
                }
            }
        }

        return nil
    }

    /// 判断本次复制是否命中「自动剥离富文本样式」契约（对用户设为免打扰的来源应用自动豁免保留原样式）
    func shouldAutoStripRichFormatting(hasRichFormatting: Bool, sourceApp: String?) -> Bool {
        guard hasRichFormatting, state.enabledAutoRules.contains(.stripRichTextFormatting) else {
            return false
        }
        return !isSourceAppMuted(sourceApp)
    }

    // MARK: - 4. 光标角「灵动微星标（Action Spark）」候选评估

    func evaluateSparkCandidate(
        for item: ClipItem,
        reuseCount: Int,
        minimalMode: Bool,
        hasRichFormatting: Bool = false
    ) -> AdaptiveSparkCandidate? {
        guard sparkEnabled, !minimalMode else { return nil }
        guard !isSourceAppMuted(item.sourceAppName) else { return nil }

        switch item.type {
        case .image:
            if let qr = item.qrCodePayload?.trimmingCharacters(in: .whitespacesAndNewlines),
               !qr.isEmpty,
               !isCategoryCoolingDown("qrcode") {
                if let totp = TOTPAuthenticator.evaluate(uri: qr) {
                    return AdaptiveSparkCandidate(
                        actionID: "img-totp-code",
                        categoryKey: "qrcode",
                        sourceApp: item.sourceAppName,
                        symbolName: "key.viewfinder",
                        shortTitle: "动态码 \(totp.formattedCode)",
                        badgeHint: "2FA 直出",
                        promotableRule: nil,
                        payload: .replaceClipboardText(
                            text: totp.code,
                            htmlTable: nil,
                            toast: "已算出 2FA 动态码 \(totp.formattedCode)（30s后自动擦除）"
                        )
                    )
                }
                if let wifi = UniversalEscapeDecoder.parseWiFiQRCode(qr) {
                    let shortTitle = wifi.ssid.isEmpty ? "提取 Wi-Fi 密码" : "Wi-Fi 密码 · \(wifi.ssid)"
                    return AdaptiveSparkCandidate(
                        actionID: "img-wifi-password",
                        categoryKey: "qrcode",
                        sourceApp: item.sourceAppName,
                        symbolName: "wifi",
                        shortTitle: shortTitle,
                        badgeHint: "免扫直连",
                        promotableRule: nil,
                        payload: .replaceClipboardText(
                            text: wifi.password,
                            htmlTable: nil,
                            toast: "已提取纯 Wi-Fi 密码（30s后自动擦除）"
                        )
                    )
                }
                let isWeb = ClipboardStore.isValidWebURL(qr)
                let promo = promotableRuleIfEligible(forActionID: "img-qrcode")
                return AdaptiveSparkCandidate(
                    actionID: "img-qrcode",
                    categoryKey: "qrcode",
                    sourceApp: item.sourceAppName,
                    symbolName: "qrcode.viewfinder",
                    shortTitle: isWeb ? "提取二维码链接" : "提取二维码内容",
                    badgeHint: "扫码直解",
                    promotableRule: promo,
                    payload: .replaceClipboardText(
                        text: qr,
                        htmlTable: nil,
                        toast: isWeb ? "已提取图中二维码链接" : "已提取图中二维码内容"
                    )
                )
            }

            let cat = "image"
            let hasImageSecretsOrPII: Bool = {
                if item.detectedSensitiveKind != nil { return true }
                if let ocr = item.ocrText, !ocr.isEmpty {
                    return SmartFieldExtractor.hasMainlandPhone(ocr) || SmartFieldExtractor.hasEmail(ocr)
                }
                return false
            }()
            if hasImageSecretsOrPII, !isCategoryCoolingDown("security") {
                return AdaptiveSparkCandidate(
                    actionID: "img-privacy-mosaic",
                    categoryKey: "security",
                    sourceApp: item.sourceAppName,
                    symbolName: "eye.trianglebadge.exclamationmark",
                    shortTitle: "截图隐私打码",
                    badgeHint: "防泄密",
                    promotableRule: nil,
                    payload: .privacyMosaicImage(itemID: item.id)
                )
            }
            guard !isCategoryCoolingDown(cat) else { return nil }

            struct ImgOption {
                let id: String
                let symbol: String
                let title: String
                let payload: AdaptiveSparkCandidate.Payload
            }

            let options: [ImgOption] = [
                ImgOption(
                    id: "img-mockup",
                    symbol: "sparkles.rectangle.stack",
                    title: "套圆角样机",
                    payload: .mockupImage(itemID: item.id)
                ),
                ImgOption(
                    id: "img-compress",
                    symbol: "arrow.down.right.and.arrow.up.left",
                    title: "瘦身 JPEG",
                    payload: .compressImage(itemID: item.id)
                ),
                ImgOption(
                    id: "img-ocr",
                    symbol: "text.viewfinder",
                    title: "提取图中文字",
                    payload: .extractImageOCR(itemID: item.id)
                )
            ]

            let ranked = rankActions(options, idOf: \.id, sourceApp: item.sourceAppName)
            guard let top = ranked.first else { return nil }
            let promo = promotableRuleIfEligible(forActionID: top.id)
            let preferred = isHabitPreferred(actionID: top.id, sourceApp: item.sourceAppName)
            return AdaptiveSparkCandidate(
                actionID: top.id,
                categoryKey: cat,
                sourceApp: item.sourceAppName,
                symbolName: top.symbol,
                shortTitle: top.title,
                badgeHint: preferred ? "习惯首选" : nil,
                promotableRule: promo,
                payload: top.payload
            )

        case .text, .link:
            if let candidate = evaluateTextOrLinkCandidate(for: item) {
                return candidate
            }
            if hasRichFormatting,
               let plain = item.text, !plain.isEmpty,
               !isCategoryCoolingDown("rich_text") {
                let isCodeOrTerminal = RichTextPasteboardHelper.isCodeEditorOrTerminalCopy(
                    types: [],
                    sourceApp: item.sourceAppName
                )
                let preferred = isHabitPreferred(actionID: "strip-rich-style", sourceApp: item.sourceAppName)
                if !isCodeOrTerminal || preferred {
                    let promo = promotableRuleIfEligible(forActionID: "strip-rich-style")
                    return AdaptiveSparkCandidate(
                        actionID: "strip-rich-style",
                        categoryKey: "rich_text",
                        sourceApp: item.sourceAppName,
                        symbolName: "textformat",
                        shortTitle: "净化为纯文本",
                        badgeHint: preferred ? "习惯首选" : "去样式",
                        promotableRule: promo,
                        payload: .replaceClipboardText(
                            text: plain,
                            htmlTable: nil,
                            toast: "已剥离富文本样式，直接 ⌘V 粘贴纯文本"
                        )
                    )
                }
            }
            // 若无格式转换命中，但该未收藏条目已被反复复制 ≥ 3 次，主动提示沉淀进收藏夹
            if !item.isPinned && reuseCount >= 3 {
                let cat = "frequent_reuse"
                guard !isCategoryCoolingDown(cat) else { return nil }
                return AdaptiveSparkCandidate(
                    actionID: "habit-pin-frequent",
                    categoryKey: cat,
                    sourceApp: item.sourceAppName,
                    symbolName: "star.fill",
                    shortTitle: "已复用 \(reuseCount) 次 · 收藏",
                    badgeHint: "高频记忆",
                    promotableRule: nil,
                    payload: .pinFrequentItem(itemID: item.id)
                )
            }
            return nil

        case .file:
            if !item.isPinned && reuseCount >= 3 {
                let cat = "frequent_reuse"
                guard !isCategoryCoolingDown(cat) else { return nil }
                return AdaptiveSparkCandidate(
                    actionID: "habit-pin-frequent",
                    categoryKey: cat,
                    sourceApp: item.sourceAppName,
                    symbolName: "star.fill",
                    shortTitle: "已复用 \(reuseCount) 次 · 收藏",
                    badgeHint: "高频记忆",
                    promotableRule: nil,
                    payload: .pinFrequentItem(itemID: item.id)
                )
            }
            return nil
        }
    }

    private func evaluateTextOrLinkCandidate(for item: ClipItem) -> AdaptiveSparkCandidate? {
        // 当剪贴板包含本会话主动脱敏生成的 `[ICLIP_*_N]` 替身时，无视普通忽略冷却期直接弹出回填胶囊，确保 AI 提问→回填真值闭环永不断链
        if let raw = item.text,
           let restored = ReversiblePrivacyTwin.inspectRestorableTwins(in: raw) {
            return AdaptiveSparkCandidate(
                actionID: "restore-privacy-twin",
                categoryKey: "security",
                sourceApp: item.sourceAppName,
                symbolName: "arrow.uturn.backward.circle.fill",
                shortTitle: "还原 \(restored.restoredCount) 处真值",
                badgeHint: "替身回填",
                promotableRule: nil,
                payload: .replaceClipboardText(
                    text: restored.restoredText,
                    htmlTable: nil,
                    toast: "已无损还原 \(restored.restoredCount) 处脱敏真值（本机隔离 · 45s自动擦除）"
                )
            )
        }
        let snap = SemanticEngine.analyze(item)
        let sparkEligible = snap.actions.filter {
            $0.id != "query-to-json"
                && $0.id != "json-to-query"
                && $0.id != "kv-to-json"
                && $0.id != "list-strip-markers"
                && $0.id != "list-add-numbers"
        }
        let ranked = rankActions(sparkEligible, idOf: \.id, sourceApp: item.sourceAppName)
        if let top = ranked.first {
            let cat = Self.categoryKey(forActionID: top.id)
            guard !isCategoryCoolingDown(cat) else { return nil }
            if top.id == "todo-split-checklist" {
                return AdaptiveSparkCandidate(
                    actionID: top.id,
                    categoryKey: "todo_capture",
                    sourceApp: item.sourceAppName,
                    symbolName: "checklist",
                    shortTitle: top.title,
                    badgeHint: nil,
                    promotableRule: nil,
                    payload: .splitChecklistIntoTodos(itemID: item.id)
                )
            }

            let result = top.resultText
            guard !result.isEmpty else { return nil }
            let html = (top.id == "tbl-md-to-excel") ? TableBridgeEngine.toHTMLTable(fromTSV: result) : nil
            let promo = promotableRuleIfEligible(forActionID: top.id)
            let preferred = isHabitPreferred(actionID: top.id, sourceApp: item.sourceAppName)

            return AdaptiveSparkCandidate(
                actionID: top.id,
                categoryKey: cat,
                sourceApp: item.sourceAppName,
                symbolName: top.symbolName,
                shortTitle: top.title,
                badgeHint: preferred ? "习惯首选" : nil,
                promotableRule: promo,
                payload: .replaceClipboardText(text: result, htmlTable: html, toast: top.toastText)
            )
        }
        if item.type == .text, !item.isTodo, let raw = item.text,
           TodoChecklistExtractor.hasActionableSingleTodoIntent(raw),
           !isCategoryCoolingDown("todo_capture") {
            return AdaptiveSparkCandidate(
                actionID: "todo-mark-item",
                categoryKey: "todo_capture",
                sourceApp: item.sourceAppName,
                symbolName: "checkmark.circle",
                shortTitle: "设为待办",
                badgeHint: nil,
                promotableRule: nil,
                payload: .markAsTodo(itemID: item.id)
            )
        }
        return nil
    }

    private func isCategoryCoolingDown(_ categoryKey: String) -> Bool {
        (state.categoryDismissStreaks[categoryKey] ?? 0) >= 6
    }

    private func promotableRuleIfEligible(forActionID actionID: String) -> LearnedAutoRuleKind? {
        guard let rule = LearnedAutoRuleKind.fromActionID(actionID) else { return nil }
        guard !state.enabledAutoRules.contains(rule), !state.declinedAutoRules.contains(rule) else { return nil }
        let count = state.actionAcceptCounts[actionID] ?? 0
        return count >= 2 ? rule : nil
    }

    // MARK: - 5. 「听懂并采纳用户建议」本地自然语言调教引擎

    @discardableResult
    func adoptUserSuggestion(_ rawInput: String, in store: ClipboardStore) -> SuggestionAdoptionOutcome {
        let cleaned = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            let emptyRec = UserSuggestionRecord(
                id: UUID(),
                createdAt: Date(),
                rawText: "",
                status: .queuedForEvolution,
                responseSummary: "请输入具体的调教偏好或功能建议"
            )
            return SuggestionAdoptionOutcome(adoptedImmediately: false, message: emptyRec.responseSummary, record: emptyRec)
        }

        let lower = cleaned.lowercased()
        let clauses = Self.splitClauses(lower)
        var adoptedEffects: [String] = []

        // A. 窗口「始终在前 / 置顶」建议
        let aotKeys = ["始终在前", "窗口置顶", "面板置顶", "钉住", "常驻屏幕", "不自动关闭", "不自动收起"]
        if Self.containsAny(lower, aotKeys) {
            let neg: Bool
            if lower.contains("不自动关闭") || lower.contains("不自动收起") {
                neg = false
            } else {
                neg = Self.isClauseNegated(matching: aotKeys, in: clauses)
            }
            store.alwaysOnTop = !neg
            adoptedEffects.append(!neg ? "已开启窗口「始终在前（⌘P）」" : "已关闭窗口「始终在前」")
        }

        // B. 指定应用免打扰 / 静默微星标（如“在微信里不要弹提示”、“Cursor 免打扰”）
        if let appTarget = Self.extractAppTargetForMute(from: cleaned) {
            let restoreOnly = Self.containsAny(lower, ["恢复提示", "开启提示", "取消静音", "取消免打扰"])
            let shouldMute = !restoreOnly
            setSourceAppMuted(appTarget, muted: shouldMute)
            adoptedEffects.append(shouldMute ? "已在「\(appTarget)」中静默微星标提示" : "已恢复「\(appTarget)」的微星标提示")
        }

        // C. 微星标、连按 ⌘C×2 智变、续接复制与拖拽微落点开关调节
        let copyAppendKeys = ["续接复制", "追加复制", "累加复制", "连续追加"]
        if Self.containsAny(lower, copyAppendKeys) {
            let neg = Self.isClauseNegated(matching: copyAppendKeys, in: clauses)
            copyAppendEnabled = !neg
            adoptedEffects.append(!neg ? "已开启 ⌃⌥C 零切窗「续接复制」" : "已关闭 ⌃⌥C「续接复制」")
        }

        let doubleCopyKeys = ["双击复制", "连按复制", "二次复制", "两次复制", "双按复制"]
        if Self.containsAny(lower, doubleCopyKeys) {
            let neg = Self.isClauseNegated(matching: doubleCopyKeys, in: clauses)
            doubleCopySparkEnabled = !neg
            adoptedEffects.append(!neg ? "已开启微星标在屏时「再按 ⌘C 直接智变」" : "已关闭「连按两次 ⌘C 触发智变」（仅保留鼠标点击）")
        }

        let dropPodKeys = ["微落点", "拖拽落点", "光标落点", "拖拽胶囊"]
        if Self.containsAny(lower, dropPodKeys) {
            let neg = Self.isClauseNegated(matching: dropPodKeys, in: clauses)
            cursorDropPodEnabled = !neg
            adoptedEffects.append(!neg ? "已开启拖拽时按 ⌥ 召唤「光标旁微落点」" : "已关闭拖拽时的「光标旁微落点」")
        }

        let smartRankKeys = ["智能排序", "情境排序", "上下文排序", "习惯置顶", "常用置顶"]
        if Self.containsAny(lower, smartRankKeys) {
            let neg = Self.isClauseNegated(matching: smartRankKeys, in: clauses)
            smartContextRankingEnabled = !neg
            adoptedEffects.append(!neg ? "已开启目标应用情境智能检索与收藏置顶" : "已关闭情境智能排序（恢复纯时间排序）")
        }

        let sparkKeys = ["微星标", "光标提示", "悬浮胶囊", "星标提示"]
        if adoptedEffects.isEmpty && Self.containsAny(lower, sparkKeys) {
            let neg = Self.isClauseNegated(matching: sparkKeys, in: clauses)
            if Self.containsAny(lower, ["久一点", "慢一点", "延长", "太快", "来不及点"]) {
                sparkDurationSeconds = 3.2
                adoptedEffects.append("已将灵动微星标停留时间延长至 3.2 秒")
            } else if Self.containsAny(lower, ["快一点", "短一点", "缩短"]) {
                sparkDurationSeconds = 1.25
                adoptedEffects.append("已将灵动微星标停留时间缩短至 1.25 秒")
            } else if neg {
                sparkEnabled = false
                adoptedEffects.append("已关闭复制时的光标角灵动微星标")
            } else if Self.containsAny(lower, ["开启", "打开", "恢复"]) {
                sparkEnabled = true
                adoptedEffects.append("已开启光标角灵动微星标")
            }
        }

        // D. 复制即自动处理的 6 大个人进化契约
        let shareLinkKeys = ["分享口令", "分享文案", "口令链接", "提取链接", "提纯链接", "口令废话"]
        if Self.containsAny(lower, shareLinkKeys) {
            let neg = Self.isClauseNegated(matching: shareLinkKeys, in: clauses)
            setAutoRule(.extractCleanShareLink, enabled: !neg)
            adoptedEffects.append(!neg ? "已开启「复制分享口令自动提取纯净链接」" : "已关闭分享口令自动提取链接")
        }

        let urlKeys = ["净链", "追踪参数", "追踪尾巴", "utm", "干净链接"]
        if Self.containsAny(lower, urlKeys) {
            let neg = Self.isClauseNegated(matching: urlKeys, in: clauses)
            setAutoRule(.cleanTrackingURL, enabled: !neg)
            store.autoCleanTrackingURL = !neg
            adoptedEffects.append(!neg ? "已开启「复制链接自动剥离追踪尾巴」" : "已关闭自动净链")
        }

        let pdfKeys = ["pdf", "断行", "换行合并", "愈合段落"]
        if Self.containsAny(lower, pdfKeys) {
            let neg = Self.isClauseNegated(matching: pdfKeys, in: clauses)
            setAutoRule(.healPDFLineBreaks, enabled: !neg)
            adoptedEffects.append(!neg ? "已开启「复制 PDF 自动愈合断行」" : "已关闭 PDF 自动愈合断行")
        }

        let panguKeys = ["盘古", "中英空格", "中英文空格", "自动加空格", "中英间距"]
        if Self.containsAny(lower, panguKeys) {
            let neg = Self.isClauseNegated(matching: panguKeys, in: clauses)
            setAutoRule(.applyPanguSpacing, enabled: !neg)
            adoptedEffects.append(!neg ? "已开启「复制中英混排自动加空格」" : "已关闭自动中英空格")
        }

        let otpKeys = ["验证码", "otp"]
        if Self.containsAny(lower, otpKeys) && Self.containsAny(lower, ["自动提取", "纯数字", "直接提取", "自动", "不要", "关闭"]) {
            let neg = Self.isClauseNegated(matching: otpKeys, in: clauses)
            setAutoRule(.extractPureOTP, enabled: !neg)
            adoptedEffects.append(!neg ? "已开启「复制验证码短信直接提取纯数字」" : "已关闭验证码自动提取")
        }

        let meetKeys = ["会议", "时间轴", "时间戳剥离", "妙记"]
        if Self.containsAny(lower, meetKeys) {
            let neg = Self.isClauseNegated(matching: meetKeys, in: clauses)
            setAutoRule(.cleanMeetingTranscript, enabled: !neg)
            adoptedEffects.append(!neg ? "已开启「复制会议纪要自动剥离时间轴」" : "已关闭会议时间轴自动剥离")
        }

        let imgAutoKeys = ["大图", "自动瘦身", "自动压缩"]
        if Self.containsAny(lower, imgAutoKeys) && Self.containsAny(lower, ["截图", "图片", "jpeg", "jpg", "压缩", "瘦身"]) {
            let neg = Self.isClauseNegated(matching: imgAutoKeys, in: clauses)
            setAutoRule(.compressLargeImage, enabled: !neg)
            adoptedEffects.append(!neg ? "已开启「超大截图自动轻量优化」" : "已关闭大图自动优化")
        }

        let qrAutoKeys = ["二维码", "qrcode", "扫码"]
        if Self.containsAny(lower, qrAutoKeys) && Self.containsAny(lower, ["自动", "直接提取", "提取", "解析", "不要", "关闭"]) {
            let neg = Self.isClauseNegated(matching: qrAutoKeys, in: clauses)
            setAutoRule(.extractQRCode, enabled: !neg)
            adoptedEffects.append(!neg ? "已开启「复制二维码截图自动提取内容」" : "已关闭二维码自动提取")
        }

        let richStyleKeys = ["纯文本", "去格式", "去样式", "剥离样式", "剥离格式", "清除格式", "pure paste", "富文本"]
        if Self.containsAny(lower, richStyleKeys) {
            let neg = Self.isClauseNegated(matching: richStyleKeys, in: clauses)
            if neg && Self.containsAny(lower, ["提示", "不弹", "微星标"]) {
                state.categoryDismissStreaks["rich_text"] = 6
                scheduleSave()
                adoptedEffects.append("已静默富文本去样式微星标提示")
            } else {
                setAutoRule(.stripRichTextFormatting, enabled: !neg)
                adoptedEffects.append(!neg ? "已开启「复制富文本自动净化纯文本（保护表格）」" : "已关闭富文本自动去样式")
            }
        }

        // E. 动作默认顺位偏好调教（如“截图优先套样机”、“截图优先提取文字”、“JSON 优先压缩单行”、“金额默认转大写”）
        let mockupKeys = ["样机", "圆角阴影", "加壳"]
        let ocrPrefKeys = ["提取文字", "识图", "ocr", "图中文字"]
        if Self.containsAny(lower, mockupKeys) && !Self.isClauseNegated(matching: mockupKeys, in: clauses) {
            boostPreferredAction("img-mockup", competingIDs: ["img-compress", "img-ocr"])
            adoptedEffects.append("已将「套圆角样机」设为截图首选动作")
        } else if Self.containsAny(lower, ocrPrefKeys) && !Self.isClauseNegated(matching: ocrPrefKeys, in: clauses) {
            boostPreferredAction("img-ocr", competingIDs: ["img-mockup", "img-compress"])
            adoptedEffects.append("已将「提取图中文字」设为截图首选动作")
        } else if Self.containsAny(lower, ["瘦身", "压缩jpeg", "轻量jpeg"]) && adoptedEffects.isEmpty && !Self.isClauseNegated(matching: ["瘦身", "压缩jpeg", "轻量jpeg"], in: clauses) {
            boostPreferredAction("img-compress", competingIDs: ["img-mockup", "img-ocr"])
            adoptedEffects.append("已将「瘦身 JPEG」设为截图首选动作")
        }

        if Self.containsAny(lower, ["json"]) && !Self.isClauseNegated(matching: ["json"], in: clauses) {
            if Self.containsAny(lower, ["压缩", "单行", "minify"]) {
                boostPreferredAction("json-minify", competingIDs: ["json-pretty"])
                adoptedEffects.append("已将「压缩单行 JSON」置顶为首选动作")
            } else if Self.containsAny(lower, ["格式化", "美化", "缩进", "pretty"]) {
                boostPreferredAction("json-pretty", competingIDs: ["json-minify"])
                adoptedEffects.append("已将「美化格式化 JSON」置顶为首选动作")
            }
        }

        let rmbKeys = ["大写", "人民币", "会计"]
        if Self.containsAny(lower, rmbKeys) && !Self.isClauseNegated(matching: rmbKeys, in: clauses) {
            boostPreferredAction("fin-rmb-upper", competingIDs: ["fin-thousands", "fin-plain-num"])
            adoptedEffects.append("已将「转中文大写金额」置顶为财务首选动作")
        } else if Self.containsAny(lower, ["求和", "算账", "总计"]) && !Self.isClauseNegated(matching: ["求和", "算账", "总计"], in: clauses) {
            boostPreferredAction("bill-sum-only", competingIDs: ["bill-append-total"])
            adoptedEffects.append("已将「多行账单直接求和」置顶为首选动作")
        }

        let redactKeys = ["脱敏", "打码", "隐藏密钥", "掩码"]
        if Self.containsAny(lower, redactKeys) && !Self.isClauseNegated(matching: redactKeys, in: clauses) {
            boostPreferredAction("redact-secrets", competingIDs: ["redact-deep"])
            if Self.containsAny(lower, ["自动", "默认"]) {
                store.autoRedactOnPaste = true
            }
            adoptedEffects.append("已强化敏感密钥脱敏守护优先级")
        }

        let soundKeys = ["音效", "声音", "提示音"]
        if Self.containsAny(lower, soundKeys) {
            let neg = Self.isClauseNegated(matching: soundKeys, in: clauses)
            store.soundEffectsEnabled = !neg
            adoptedEffects.append(!neg ? "已开启交互微音效" : "已关闭交互微音效（仅保留触感震动）")
        }

        let minKeys = ["极简模式", "纯净模式", "基础模式"]
        if Self.containsAny(lower, minKeys) {
            let neg = Self.isClauseNegated(matching: minKeys, in: clauses)
            store.minimalModeEnabled = !neg
            adoptedEffects.append(!neg ? "已切换至极简纯净模式" : "已恢复完整进阶功能模式")
        }

        let shareShieldKeys = ["投屏", "录屏", "共享屏幕", "防录屏", "会议隐身"]
        if Self.containsAny(lower, shareShieldKeys) {
            let neg = Self.isClauseNegated(matching: shareShieldKeys, in: clauses)
            store.screenSharePrivacyEnabled = !neg
            adoptedEffects.append(!neg ? "已开启投屏与录屏光学隐身护盾" : "已关闭投屏隐身保护")
        }

        let veilKeys = ["防窥", "肩窥", "遮罩", "雾化", "隐藏敏感"]
        if Self.containsAny(lower, veilKeys) {
            let neg = Self.isClauseNegated(matching: veilKeys, in: clauses)
            store.maskSensitivePreviews = !neg
            adoptedEffects.append(!neg ? "已开启敏感凭据防肩窥圆点遮罩" : "已关闭列表敏感凭据遮罩")
        }

        let secretTTLKeys = ["敏感清理", "敏感自毁", "24小时清理", "24h自毁", "自动销毁敏感"]
        if Self.containsAny(lower, secretTTLKeys) {
            let neg = Self.isClauseNegated(matching: secretTTLKeys, in: clauses)
            store.autoExpireUnpinnedSecrets = !neg
            adoptedEffects.append(!neg ? "已开启未收藏敏感凭据 24h 自动销毁" : "已关闭未收藏敏感凭据自动销毁")
        }

        let ghostKeys = ["零宽", "隐藏字符", "幽灵字符", "控制符", "防投毒"]
        if Self.containsAny(lower, ghostKeys) {
            let neg = Self.isClauseNegated(matching: ghostKeys, in: clauses)
            setAutoRule(.sanitizeInvisibleChars, enabled: !neg)
            adoptedEffects.append(!neg ? "已开启自动清除零宽幽灵与隐藏控制符契约" : "已关闭自动清除隐藏字符契约")
        }

        let resumePauseKeys = ["恢复记录", "恢复监听", "开启记录", "取消暂停", "结束无痕"]
        let timedPauseKeys = ["无痕暂停", "暂停记录", "暂停监听", "无痕模式", "隐私暂停"]
        if Self.containsAny(lower, resumePauseKeys) {
            store.resumeCapture()
            adoptedEffects.append("已立即恢复剪贴板记录")
        } else if Self.containsAny(lower, timedPauseKeys) || (lower.hasPrefix("暂停") || lower.hasPrefix("无痕")) {
            let digits = lower.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first
            let mins = min(max(digits ?? 15, 1), 480)
            store.pauseCapture(forMinutes: mins)
            adoptedEffects.append("已开启 \(mins) 分钟无痕暂停（到点自动恢复记录）")
        }

        let status: UserSuggestionRecord.Status
        let summary: String
        if !adoptedEffects.isEmpty {
            status = .adoptedImmediately
            summary = "已采纳生效：" + adoptedEffects.joined(separator: "；")
            TactileFeedbackEngine.shared.perform(.magicTransform)
        } else {
            status = .queuedForEvolution
            summary = "已记入 iClip 进化建议单（#\(suggestions.count + 1)），后续自省迭代将针对性优化"
            TactileFeedbackEngine.shared.perform(.favoriteOn)
        }

        let record = UserSuggestionRecord(
            id: UUID(),
            createdAt: Date(),
            rawText: cleaned,
            status: status,
            responseSummary: summary
        )
        suggestions.insert(record, at: 0)
        if suggestions.count > 100 {
            suggestions = Array(suggestions.prefix(100))
        }
        saveSuggestions()
        return SuggestionAdoptionOutcome(
            adoptedImmediately: status == .adoptedImmediately,
            message: summary,
            record: record
        )
    }

    /// 重置所有自动习得的权重与退避状态（保留用户的历史建议记录）
    func resetLearnedWeights() {
        state.actionWeights.removeAll()
        state.appActionWeights.removeAll()
        state.actionAcceptCounts.removeAll()
        state.categoryDismissStreaks.removeAll()
        state.declinedAutoRules.removeAll()
        state.targetAppPasteCounts?.removeAll()
        state.targetAppDisplayNames?.removeAll()
        state.totalLearnedInteractions = 0
        totalLearnedInteractions = 0
        revision &+= 1
        scheduleSave()
    }

    private func boostPreferredAction(_ targetID: String, competingIDs: [String]) {
        let maxCompeting = competingIDs.compactMap { state.actionWeights[$0] }.max() ?? 0
        state.actionWeights[targetID] = max(state.actionWeights[targetID] ?? 0, maxCompeting + 15.0)
        state.categoryDismissStreaks[Self.categoryKey(forActionID: targetID)] = 0
        state.totalLearnedInteractions += 1
        totalLearnedInteractions = state.totalLearnedInteractions
        revision &+= 1
        scheduleSave()
    }

    // MARK: - 辅助分类与文本意图解析

    static func categoryKey(forActionID actionID: String) -> String {
        if actionID.hasPrefix("json-") { return "json" }
        if actionID.hasPrefix("fin-") { return "amount" }
        if actionID.hasPrefix("bill-") { return "bill" }
        if actionID.hasPrefix("doc-") { return "typography" }
        if actionID.hasPrefix("tbl-") { return "table" }
        if actionID.hasPrefix("redact-") || actionID == "restore-privacy-twin" || actionID == "img-privacy-mosaic" { return "security" }
        if actionID.hasPrefix("contact-") || actionID.hasPrefix("extract-unique-") || actionID == "extract-clean-phone" { return "extract_field" }
        if actionID == "strip-rich-style" { return "rich_text" }
        if actionID == "img-qrcode" { return "qrcode" }
        if actionID.hasPrefix("img-") { return "image" }
        if actionID.hasPrefix("meet-") { return "meeting" }
        if actionID.hasPrefix("otp-") { return "otp" }
        if actionID.hasPrefix("comp-") { return "compliance" }
        if actionID == "clean-url" { return "url_tracking" }
        if actionID == "extract-share-url" { return "share_url" }
        if actionID == "query-to-json" || actionID == "json-to-query" { return "url_query" }
        return actionID
    }

    private func normalizedAppKey(_ appName: String?) -> String? {
        guard let raw = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.lowercased()
    }

    private static func containsAny(_ hay: String, _ needles: [String]) -> Bool {
        needles.contains { hay.contains($0) }
    }

    private static func splitClauses(_ text: String) -> [String] {
        var normalized = text
        for conj in ["并且", "而且", "同时", "以及", "但是", "不过"] {
            normalized = normalized.replacingOccurrences(of: conj, with: "，")
        }
        let separators = CharacterSet(charactersIn: "，,；;。！!\n")
        return normalized
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isClauseNegated(matching keywords: [String], in clauses: [String]) -> Bool {
        let negWords = ["不要", "别", "关闭", "取消", "禁用", "停止", "不弹", "关掉", "不需要"]
        let matchedClauses = clauses.filter { clause in containsAny(clause, keywords) }
        guard !matchedClauses.isEmpty else { return false }
        return matchedClauses.contains { clause in containsAny(clause, negWords) }
    }

    private static func extractAppTargetForMute(from input: String) -> String? {
        let lower = input.lowercased()
        let hasMuteIntent = containsAny(lower, ["不弹", "不要弹", "别弹", "免打扰", "静音", "静默", "屏蔽", "不提示", "别提示", "恢复提示"])
        guard hasMuteIntent else { return nil }

        let knownApps: [(aliases: [String], canonical: String)] = [
            (["微信", "wechat"], "微信"),
            (["飞书", "lark", "feishu"], "飞书"),
            (["钉钉", "dingtalk"], "钉钉"),
            (["企业微信", "企微", "wecom"], "企业微信"),
            (["cursor"], "Cursor"),
            (["vscode", "vs code", "code"], "Code"),
            (["xcode"], "Xcode"),
            (["终端", "terminal", "iterm", "warp", "ghostty"], "终端"),
            (["safari"], "Safari"),
            (["chrome", "浏览器"], "Google Chrome"),
            (["arc"], "Arc"),
            (["figma"], "Figma"),
            (["notion"], "Notion"),
            (["obsidian"], "Obsidian")
        ]
        for entry in knownApps {
            if entry.aliases.contains(where: { lower.contains($0) }) {
                return entry.canonical
            }
        }

        // 支持「在 <App名> 里/中不要弹...」通用句式提取
        if let range1 = input.range(of: "在"),
           let range2 = input.range(of: "里", range: range1.upperBound..<input.endIndex) ?? input.range(of: "中", range: range1.upperBound..<input.endIndex) {
            let candidate = String(input[range1.upperBound..<range2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty && candidate.count <= 24 {
                return candidate
            }
        }
        return nil
    }

    // MARK: - 防抖异步持久化

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = self.state
        let url = self.brainFileURL
        let customDir = self.isCustomDirectory
        let gate = self.persistenceGate
        let parentPath = url.deletingLastPathComponent().path
        let work = DispatchWorkItem { [ioQueue] in
            ioQueue.async {
                gate.performIfOpen(requireCustomDir: customDir, dirPath: parentPath) {
                    if let data = try? JSONEncoder().encode(snapshot) {
                        let payload = LocalVaultCrypto.sealSnapshotData(data) ?? data
                        try? LocalVaultCrypto.writeProtectedFile(payload, to: url)
                    }
                }
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func saveSuggestions() {
        let snapshot = self.suggestions
        let url = self.suggestionsFileURL
        let customDir = self.isCustomDirectory
        let gate = self.persistenceGate
        let parentPath = url.deletingLastPathComponent().path
        ioQueue.async {
            gate.performIfOpen(requireCustomDir: customDir, dirPath: parentPath) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(snapshot) {
                    let payload = LocalVaultCrypto.sealSnapshotData(data) ?? data
                    try? LocalVaultCrypto.writeProtectedFile(payload, to: url)
                }
            }
        }
    }
}

/// 双版本共享的轻量 URL 追踪剥离、混排分享口令提纯与本地路径解析工具
enum URLTrackingCleaner {
    static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "spm", "spm_id_from", "vd_source", "from_spmid", "from_source", "share_source", "share_medium",
        "share_plat", "share_from", "share_tag", "share_session_id", "unique_k",
        "xhsshare", "xsec_source", "apptime", "appuid", "author_share",
        "tt_from", "u_code", "iid", "from_copylink",
        "fbclid", "gclid", "dclid", "msclkid", "twclid", "igshid", "igsh",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "yclid", "wickedid", "si"
    ]

    /// 公域外发时需彻底剥除的 URL 鉴权令牌与云对象存储预签名参数
    static let authAndSignatureParams: Set<String> = [
        "token", "access_token", "auth_token", "id_token", "refresh_token", "session_token", "jwt",
        "api_key", "apikey", "secret", "client_secret", "password", "passwd", "sig", "signature",
        "x-amz-signature", "x-amz-credential", "x-amz-security-token",
        "x-goog-signature", "x-goog-credential",
        "ossaccesskeyid", "q-signature", "q-ak"
    ]

    /// 预签名 URL 配套的过期与签名元数据参数（当命中上述鉴权参数时一并剥净）
    private static let companionPresignParams: Set<String> = [
        "expires", "x-amz-date", "x-amz-expires", "x-amz-algorithm", "x-amz-signedheaders",
        "x-goog-date", "x-goog-expires", "x-goog-algorithm", "x-goog-signedheaders",
        "q-key-time", "q-sign-time", "q-sign-algorithm", "q-header-list", "q-url-param-list",
        "sv", "se", "sp", "spr", "srt", "ss"
    ]

    static func cleanTrackingURL(_ raw: String) -> String? {
        guard var comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let items = comps.queryItems, !items.isEmpty else {
            return nil
        }
        let filtered = items.filter { item in
            let key = item.name.lowercased()
            return !trackingParams.contains(key) && !key.hasPrefix("utm_")
        }
        guard filtered.count < items.count else { return nil }
        comps.queryItems = filtered.isEmpty ? nil : filtered
        return comps.string
    }

    /// 外发公域链接安全净享：一键同时剥离 HTTP Basic Auth 账密、URL 鉴权/云预签名令牌参数与营销追踪尾巴，保留干净业务参数
    static func sanitizeURLForPublicShare(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 4_096,
              !trimmed.contains("\n"),
              !trimmed.contains("\r"),
              !trimmed.contains(" "),
              !SensitiveCredentialVeil.isWebhookURL(trimmed),
              var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = comps.host, !host.isEmpty else {
            return nil
        }

        let hasBasicAuth = !(comps.user ?? "").isEmpty || !(comps.password ?? "").isEmpty
        let queryItems = comps.queryItems ?? []
        let hasAuthQuery = queryItems.contains { item in
            let key = item.name.lowercased()
            let val = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return authAndSignatureParams.contains(key) && !val.isEmpty
        }

        guard hasBasicAuth || hasAuthQuery else { return nil }

        comps.user = nil
        comps.password = nil
        if !queryItems.isEmpty {
            let filtered = queryItems.filter { item in
                let key = item.name.lowercased()
                if authAndSignatureParams.contains(key) || companionPresignParams.contains(key) {
                    return false
                }
                if trackingParams.contains(key) || key.hasPrefix("utm_") {
                    return false
                }
                return true
            }
            comps.queryItems = filtered.isEmpty ? nil : filtered
        }

        guard let cleaned = comps.string, cleaned != trimmed else { return nil }
        return cleaned
    }

    /// 扫描混排文本中的合法 HTTP(S) 链接：自动在中日韩全角标点/空白处截断，并保留 URL 内部配对括号（如 Wikipedia 词条）
    static func extractAllWebURLs(from raw: String, limit: Int = 3) -> [String] {
        guard limit > 0 else { return [] }
        let inspect = raw.utf16.count > 8_192 ? String(raw.prefix(4_096)) : raw
        guard inspect.range(of: "http", options: .caseInsensitive) != nil else { return [] }

        let scalars = Array(inspect.unicodeScalars)
        let count = scalars.count
        var results: [String] = []
        var idx = 0

        while idx + 7 < count && results.count < limit {
            let s0 = scalars[idx].value
            if s0 == 0x68 || s0 == 0x48 { // 'h' or 'H'
                let prevIsAlphaNum: Bool
                if idx > 0 {
                    let pv = scalars[idx - 1].value
                    prevIsAlphaNum = (pv >= 0x30 && pv <= 0x39) || (pv >= 0x41 && pv <= 0x5A) || (pv >= 0x61 && pv <= 0x7A)
                } else {
                    prevIsAlphaNum = false
                }

                if !prevIsAlphaNum {
                    let prefix8 = String(String.UnicodeScalarView(scalars[idx..<min(idx + 8, count)])).lowercased()
                    let schemeLen: Int
                    if prefix8.hasPrefix("https://") {
                        schemeLen = 8
                    } else if prefix8.hasPrefix("http://") {
                        schemeLen = 7
                    } else {
                        schemeLen = 0
                    }

                    if schemeLen > 0 {
                        var end = idx + schemeLen
                        while end < count {
                            let v = scalars[end].value
                            // 允许拉丁扩展与希腊/西里尔同形异义字符进入主机候选（供防钓鱼引擎精准拦截），
                            // 遇到空白、控制符、中日韩文字、全角标点、零宽/Bidi 控制符或引号尖括号立即终止
                            let isConfusableIDNScalar = (v >= 0x00C0 && v <= 0x052F)
                            if v <= 0x20 || (v >= 0x7F && !isConfusableIDNScalar) { break }
                            if v == 0x22 || v == 0x27 || v == 0x3C || v == 0x3E || v == 0x60 || v == 0x5C || v == 0x7B || v == 0x7D || v == 0x7C || v == 0x5E {
                                break
                            }
                            end += 1
                        }

                        var candidate = String(String.UnicodeScalarView(scalars[idx..<end]))
                        candidate = trimUnmatchedTrailingPunctuation(candidate)
                        if isValidExtractedWebURL(candidate) {
                            results.append(candidate)
                        }
                        idx = end
                        continue
                    }
                }
            }
            idx += 1
        }
        return results
    }

    /// 提取文本中的首个网页链接并自动剥离追踪尾巴（供 ⌘O 浏览器直达使用）
    static func extractFirstCleanedWebURL(from raw: String) -> String? {
        guard let first = extractAllWebURLs(from: raw, limit: 1).first else { return nil }
        return cleanTrackingURL(first) ?? first
    }

    /// 识别社媒分享口令 / 群聊带链接短消息并剥壳提取唯一纯净 URL（严格排除代码块、cURL、Markdown 语法与多链接列表）
    static func extractCleanShareURL(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12, trimmed.utf16.count <= 800 else { return nil }
        if isValidExtractedWebURL(trimmed) { return nil }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("curl ") || lower.hasPrefix("curl\t") { return nil }
        if trimmed.contains("](") || trimmed.contains("=\"http") || trimmed.contains("='http") || trimmed.contains(": \"http") {
            return nil
        }

        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count <= 8 else { return nil }
        if let firstLine = lines.first?.trimmingCharacters(in: .whitespaces) {
            for codePrefix in ["import ", "func ", "let ", "var ", "const ", "def ", "class ", "struct ", "{", "SELECT ", "select "] {
                if firstLine.hasPrefix(codePrefix) { return nil }
            }
        }

        let urls = extractAllWebURLs(from: trimmed, limit: 2)
        guard urls.count == 1, let extracted = urls.first else { return nil }
        let cleaned = cleanTrackingURL(extracted) ?? extracted
        guard cleaned != trimmed else { return nil }
        return cleaned
    }

    /// 解析单行本地文件/目录路径候选（支持 ~/ 展开、file:// URI、首尾引号剥除，以及终端/IDE 的 `:行:列` 与 `#L行号` 后缀剥除）
    static func parseLocalPathCandidates(from raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 2, s.utf16.count <= 1_024, !s.contains("\n"), !s.contains("\r") else {
            return []
        }

        if (s.hasPrefix("\"") && s.hasSuffix("\"")) ||
           (s.hasPrefix("'") && s.hasSuffix("'")) ||
           (s.hasPrefix("`") && s.hasSuffix("`")) {
            s.removeFirst()
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespaces)
        }

        if s.lowercased().hasPrefix("file://") {
            let withoutAnchor = s.replacingOccurrences(of: #"#L\d+(?:-L?\d+)?$"#, with: "", options: .regularExpression)
            if let fileURL = URL(string: withoutAnchor),
               fileURL.isFileURL,
               (fileURL.host == nil || fileURL.host?.isEmpty == true || fileURL.host?.lowercased() == "localhost") {
                s = fileURL.path
            } else {
                return []
            }
        }

        guard s.hasPrefix("~/") || (s.hasPrefix("/") && !s.hasPrefix("//")) else {
            return []
        }

        let expanded = NSString(string: s).expandingTildeInPath
        var candidates: [String] = [expanded]

        let strippedAnchor = expanded.replacingOccurrences(
            of: #"#L\d+(?:-L?\d+)?$"#,
            with: "",
            options: .regularExpression
        )
        if strippedAnchor != expanded && !strippedAnchor.isEmpty {
            candidates.append(strippedAnchor)
        }

        let strippedLineCol = strippedAnchor.replacingOccurrences(
            of: #":\d+(?::\d+)?(?::)?$"#,
            with: "",
            options: .regularExpression
        )
        if strippedLineCol != strippedAnchor && !strippedLineCol.isEmpty {
            candidates.append(strippedLineCol)
        }

        return candidates
    }

    /// 解析并校验磁盘真实存在的本地文件或目录 URL（供面板 ⌘O 一键访达定位）
    static func resolveExistingLocalFileURL(from raw: String) -> URL? {
        let fm = FileManager.default
        for path in parseLocalPathCandidates(from: raw) {
            if fm.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func trimUnmatchedTrailingPunctuation(_ candidate: String) -> String {
        var result = candidate
        let openParens = result.filter { $0 == "(" }.count
        var closeParens = result.filter { $0 == ")" }.count
        let openBrackets = result.filter { $0 == "[" }.count
        var closeBrackets = result.filter { $0 == "]" }.count

        while let last = result.last {
            if last == "." || last == "," || last == ";" || last == ":" || last == "!" || last == "?" {
                result.removeLast()
            } else if last == ")" && closeParens > openParens {
                result.removeLast()
                closeParens -= 1
            } else if last == "]" && closeBrackets > openBrackets {
                result.removeLast()
                closeBrackets -= 1
            } else {
                break
            }
        }
        return result
    }

    private static func isValidExtractedWebURL(_ string: String) -> Bool {
        guard !string.contains(" "), !string.contains("\n") else { return false }
        if let comps = URLComponents(string: string),
           let scheme = comps.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           let host = comps.host, !host.isEmpty {
            return host.contains(".") || host == "localhost"
        }
        let lower = string.lowercased()
        let afterScheme: Substring
        if lower.hasPrefix("https://") {
            afterScheme = string.dropFirst(8)
        } else if lower.hasPrefix("http://") {
            afterScheme = string.dropFirst(7)
        } else {
            return false
        }
        let authority = afterScheme.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
        let hostPort = authority.split(separator: "@").last ?? Substring()
        let host = hostPort.split(separator: ":").first ?? Substring()
        guard !host.isEmpty else { return false }
        return host.contains(".") || host.lowercased() == "localhost"
    }
}

/// 富文本脏样式无损嗅探器：识别网页/文档夹带的 HTML/RTF 脏样式，严格保护电子表格分列结构，并自动过滤 IDE/终端等宽语法着色噪音
enum RichTextPasteboardHelper {
    private static let webArchiveType = NSPasteboard.PasteboardType("com.apple.webarchive")
    private static let vscodeEditorDataType = NSPasteboard.PasteboardType("vscode-editor-data")
    private static let sourceCodeType = NSPasteboard.PasteboardType("public.source-code")
    private static let richTextTypes: Set<NSPasteboard.PasteboardType> = [
        .html,
        .rtf,
        .rtfd,
        NSPasteboard.PasteboardType("com.apple.webarchive")
    ]

    private static let codeAndTerminalAppKeywords: [String] = [
        "antigravity", "cursor", "visual studio code", "vscode", "windsurf", "trae",
        "zed", "xcode", "intellij", "pycharm", "webstorm", "goland", "clion",
        "rustrover", "phpstorm", "rubymine", "rider", "datagrip", "android studio",
        "sublime text", "nova", "bbedit", "textmate", "coteditor",
        "terminal", "终端", "iterm", "ghostty", "warp", "kitty", "alacritty", "wezterm", "tabby", "hyper"
    ]

    static func hasStrippableRichFormatting(
        types: [NSPasteboard.PasteboardType],
        plainText: String
    ) -> Bool {
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if types.contains(.tabularText) || types.contains(.fileURL) {
            return false
        }
        if trimmed.contains("\t") && (trimmed.contains("\n") || trimmed.contains("\r")) {
            return false
        }
        return types.contains { richTextTypes.contains($0) }
    }

    /// 识别是否来自代码编辑器 / IDE / 终端的常规语法高亮复制（此类应用默认附带 HTML/RTF，不应主动弹「去样式」微星标打扰编码）
    static func isCodeEditorOrTerminalCopy(
        types: [NSPasteboard.PasteboardType],
        sourceApp: String?
    ) -> Bool {
        if types.contains(vscodeEditorDataType) || types.contains(sourceCodeType) {
            return true
        }
        guard let rawApp = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawApp.isEmpty else {
            return false
        }
        if rawApp == "code" || rawApp == "code - insiders" || rawApp == "vim" || rawApp == "nvim" || rawApp == "neovim" || rawApp == "emacs" {
            return true
        }
        return codeAndTerminalAppKeywords.contains { rawApp.contains($0) }
    }

    /// 判断本次复制是否值得主动弹出「净化富文本」微星标
    static func shouldOfferRichStripSpark(
        types: [NSPasteboard.PasteboardType],
        plainText: String,
        sourceApp: String?
    ) -> Bool {
        guard hasStrippableRichFormatting(types: types, plainText: plainText) else {
            return false
        }
        return !isCodeEditorOrTerminalCopy(types: types, sourceApp: sourceApp)
    }
}
