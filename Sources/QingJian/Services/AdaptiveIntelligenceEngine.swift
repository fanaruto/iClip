import Foundation
import AppKit

/// 可由用户习惯自动晋升或通过建议直接开启的「复制即自动处理」契约规则
enum LearnedAutoRuleKind: String, CaseIterable, Codable, Identifiable {
    case cleanTrackingURL
    case healPDFLineBreaks
    case applyPanguSpacing
    case extractPureOTP
    case cleanMeetingTranscript
    case compressLargeImage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanTrackingURL: return "复制链接自动剥离追踪尾巴"
        case .healPDFLineBreaks: return "复制 PDF 段落自动愈合断行"
        case .applyPanguSpacing: return "复制中英混排自动加盘古空格"
        case .extractPureOTP: return "复制验证码短信直接提取纯数字"
        case .cleanMeetingTranscript: return "复制会议纪要自动剥离时间轴"
        case .compressLargeImage: return "复制超大截图（>1.5MB）自动轻量优化"
        }
    }

    var shortToast: String {
        switch self {
        case .cleanTrackingURL: return "智能契约：已自动净链去追踪"
        case .healPDFLineBreaks: return "智能契约：已自动愈合 PDF 断行"
        case .applyPanguSpacing: return "智能契约：已自动优化中英间距"
        case .extractPureOTP: return "智能契约：已自动提取纯验证码"
        case .cleanMeetingTranscript: return "智能契约：已自动剥离会议时间轴"
        case .compressLargeImage: return "智能契约：已自动轻量优化大图"
        }
    }

    /// 关联的手动动作 ID（当用户连续 3 次手动执行该动作时，主动提议晋升为全自动契约）
    static func fromActionID(_ actionID: String) -> LearnedAutoRuleKind? {
        switch actionID {
        case "clean-url": return .cleanTrackingURL
        case "doc-pdf-heal": return .healPDFLineBreaks
        case "doc-pangu-space": return .applyPanguSpacing
        case "otp-extract-code": return .extractPureOTP
        case "meet-plain-body", "meet-speaker-notes": return .cleanMeetingTranscript
        case "img-compress": return .compressLargeImage
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
        case extractImageOCR(itemID: UUID)
        case pinFrequentItem(itemID: UUID)
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
    var actionWeights: [String: Double] = [:]
    var appActionWeights: [String: [String: Double]] = [:]
    var actionAcceptCounts: [String: Int] = [:]
    var categoryDismissStreaks: [String: Int] = [:]
    var enabledAutoRules: Set<LearnedAutoRuleKind> = []
    var declinedAutoRules: Set<LearnedAutoRuleKind> = []
    var mutedSourceApps: [String] = []
    var recentReuseCounts: [String: Int] = [:]
    var recentReuseOrder: [String] = []
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

    @Published private(set) var enabledAutoRules: Set<LearnedAutoRuleKind> = []
    @Published private(set) var mutedSourceApps: [String] = []
    @Published private(set) var suggestions: [UserSuggestionRecord] = []
    @Published private(set) var totalLearnedInteractions: Int = 0
    /// 递增版本号：用于通知外部缓存（如语义动作排序缓存）按需失效刷新
    @Published private(set) var revision: Int = 0

    private var state: AdaptiveBrainState
    private let brainFileURL: URL
    private let suggestionsFileURL: URL
    private var saveWorkItem: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "com.qingjian.adaptive.io", qos: .utility)

    init(customDirectoryURL: URL? = nil) {
        let baseDir: URL
        if let customDirectoryURL {
            baseDir = customDirectoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            baseDir = appSupport.appendingPathComponent("QingJian", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.brainFileURL = baseDir.appendingPathComponent("adaptive_intelligence.json")
        self.suggestionsFileURL = baseDir.appendingPathComponent("user_suggestions.json")

        let loaded: AdaptiveBrainState
        if let data = try? Data(contentsOf: brainFileURL),
           let decoded = try? JSONDecoder().decode(AdaptiveBrainState.self, from: data) {
            loaded = decoded
        } else {
            loaded = AdaptiveBrainState()
        }
        self.state = loaded
        self.sparkEnabled = loaded.sparkEnabled
        self.sparkDurationSeconds = loaded.sparkDurationSeconds
        self.doubleCopySparkEnabled = loaded.doubleCopySparkEnabled ?? true
        self.copyAppendEnabled = loaded.copyAppendEnabled ?? true
        self.cursorDropPodEnabled = loaded.cursorDropPodEnabled ?? true
        self.enabledAutoRules = loaded.enabledAutoRules
        self.mutedSourceApps = loaded.mutedSourceApps
        self.totalLearnedInteractions = loaded.totalLearnedInteractions

        if let sugData = try? Data(contentsOf: suggestionsFileURL),
           let decodedSug = try? JSONDecoder().decode([UserSuggestionRecord].self, from: sugData) {
            self.suggestions = decodedSug
        } else {
            self.suggestions = []
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

    // MARK: - 4. 光标角「灵动微星标（Action Spark）」候选评估

    func evaluateSparkCandidate(
        for item: ClipItem,
        reuseCount: Int,
        minimalMode: Bool
    ) -> AdaptiveSparkCandidate? {
        guard sparkEnabled, !minimalMode else { return nil }
        guard !isSourceAppMuted(item.sourceAppName) else { return nil }

        switch item.type {
        case .image:
            let cat = "image"
            guard !isCategoryCoolingDown(cat) else { return nil }

            struct ImgOption {
                let id: String
                let symbol: String
                let title: String
                let payload: AdaptiveSparkCandidate.Payload
            }

            var options: [ImgOption] = [
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
                )
            ]
            #if ICLIP_EDITION_FLOW
            options.append(
                ImgOption(
                    id: "img-ocr",
                    symbol: "text.viewfinder",
                    title: "提取图中文字",
                    payload: .extractImageOCR(itemID: item.id)
                )
            )
            #endif

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
        #if !ICLIP_EDITION_FLOW
        let snap = SemanticEngine.analyze(item)
        let ranked = rankActions(snap.actions, idOf: \.id, sourceApp: item.sourceAppName)
        guard let top = ranked.first else { return nil }
        let cat = Self.categoryKey(forActionID: top.id)
        guard !isCategoryCoolingDown(cat) else { return nil }

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
        #else
        if item.type == .link, let raw = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           let cleaned = URLTrackingCleaner.cleanTrackingURL(raw), cleaned != raw {
            let cat = "url_tracking"
            guard !isCategoryCoolingDown(cat) else { return nil }
            let promo = promotableRuleIfEligible(forActionID: "clean-url")
            return AdaptiveSparkCandidate(
                actionID: "clean-url",
                categoryKey: cat,
                sourceApp: item.sourceAppName,
                symbolName: "sparkles",
                shortTitle: "剥离追踪参数",
                badgeHint: isHabitPreferred(actionID: "clean-url", sourceApp: item.sourceAppName) ? "习惯首选" : nil,
                promotableRule: promo,
                payload: .replaceClipboardText(text: cleaned, htmlTable: nil, toast: "已净化追踪链接")
            )
        }

        guard let raw = item.text else { return nil }
        var actions = MeetingAndEphemeralEngine.analyze(raw)
        if actions.isEmpty { actions = ComplianceCodeEngine.analyze(raw) }
        if actions.isEmpty { actions = TableBridgeEngine.analyze(raw) }
        if actions.isEmpty { actions = FinanceNumberEngine.analyze(raw) }
        if actions.isEmpty { actions = DocumentTypographyEngine.analyze(raw) }

        let ranked = rankActions(actions, idOf: \.id, sourceApp: item.sourceAppName)
        guard let top = ranked.first else { return nil }
        let cat = Self.categoryKey(forActionID: top.id)
        guard !isCategoryCoolingDown(cat) else { return nil }

        let html = (top.id == "tbl-md-to-excel") ? TableBridgeEngine.toHTMLTable(fromTSV: top.resultText) : nil
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
            payload: .replaceClipboardText(text: top.resultText, htmlTable: html, toast: top.toastText)
        )
        #endif
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
        let urlKeys = ["净链", "追踪参数", "追踪尾巴", "utm", "干净链接"]
        if Self.containsAny(lower, urlKeys) {
            let neg = Self.isClauseNegated(matching: urlKeys, in: clauses)
            setAutoRule(.cleanTrackingURL, enabled: !neg)
            #if !ICLIP_EDITION_FLOW
            store.autoCleanTrackingURL = !neg
            #endif
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

        // E. 动作默认顺位偏好调教（如“截图优先套样机”、“JSON 优先压缩单行”、“金额默认转大写”）
        let mockupKeys = ["样机", "圆角阴影", "加壳"]
        if Self.containsAny(lower, mockupKeys) && !Self.isClauseNegated(matching: mockupKeys, in: clauses) {
            boostPreferredAction("img-mockup", competingIDs: ["img-compress", "img-ocr"])
            adoptedEffects.append("已将「套圆角样机」设为截图首选动作")
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
            #if !ICLIP_EDITION_FLOW
            if Self.containsAny(lower, ["自动", "默认"]) {
                store.autoRedactOnPaste = true
            }
            #endif
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
        if actionID.hasPrefix("redact-") { return "security" }
        if actionID.hasPrefix("img-") { return "image" }
        if actionID.hasPrefix("meet-") { return "meeting" }
        if actionID.hasPrefix("otp-") { return "otp" }
        if actionID.hasPrefix("comp-") { return "compliance" }
        if actionID == "clean-url" { return "url_tracking" }
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
        let work = DispatchWorkItem { [ioQueue] in
            ioQueue.async {
                if let data = try? JSONEncoder().encode(snapshot) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func saveSuggestions() {
        let snapshot = self.suggestions
        let url = self.suggestionsFileURL
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

/// 双版本共享的轻量 URL 追踪参数剥离工具（保障 Dev 与 Flow 版本都能执行自动净链契约）
enum URLTrackingCleaner {
    private static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "spm", "spm_id_from", "vd_source", "from_spmid", "share_source", "share_medium",
        "fbclid", "gclid", "dclid", "msclkid", "twclid", "igshid", "igsh",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "yclid", "wickedid"
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
}
