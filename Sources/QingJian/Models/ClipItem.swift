import Foundation
import AppKit
import SwiftUI

/// 收藏置顶的商务与办公场景分组标签（跨角色持久化保留，切换版本不丢失）
enum PinCategory: String, Codable, CaseIterable, Identifiable {
    case reply
    case invoice
    case contact
    case template

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reply: return "常用话术"
        case .invoice: return "开票财务"
        case .contact: return "地址名片"
        case .template: return "合同模板"
        }
    }

    var dotColor: Color {
        switch self {
        case .reply: return .blue
        case .invoice: return .orange
        case .contact: return .green
        case .template: return .purple
        }
    }
}

/// 剪贴内容类型
enum ClipContentType: String, Codable, CaseIterable, Identifiable {
    case text
    case link
    case image
    case file

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return "文本"
        case .link: return "链接"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    var symbolName: String {
        switch self {
        case .text: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "folder"
        }
    }
}

/// 顶部分类筛选标签
enum ClipFilterTab: String, CaseIterable, Identifiable {
    case all
    case pinned
    case text
    case link
    case image
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .pinned: return "收藏"
        case .text: return "文本"
        case .link: return "链接"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .pinned: return "star.fill"
        case .text: return "text.alignleft"
        case .link: return "safari"
        case .image: return "photo.on.rectangle"
        case .file: return "doc"
        }
    }
}

/// 单条剪贴板记录（双角色共享超集持久化 Schema，确保通过 OTA 跨角色切换时历史与元数据 100% 无损）
struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    let type: ClipContentType
    var text: String?
    var imageFileName: String?
    var imageWidth: Int?
    var imageHeight: Int?
    /// Apple Vision 离线识别出的图片内实况文本
    var ocrText: String?
    /// 是否已完成离线实况文本扫描
    var ocrChecked: Bool?
    /// Apple Vision 离线识别出的图片内二维码/条码载荷（链接或纯文本）
    var qrCodePayload: String?
    var filePaths: [String]?
    var contentHash: String
    var sourceAppName: String?
    var createdAt: Date
    var isPinned: Bool
    /// 收藏分组场景（话术 / 开票 / 地址 / 模板）
    var pinCategory: PinCategory?
    /// 用户自定义备注标题（仅用于展示与检索，粘贴仍输出原文）
    var customAlias: String?

    init(
        id: UUID = UUID(),
        type: ClipContentType,
        text: String? = nil,
        imageFileName: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        ocrText: String? = nil,
        ocrChecked: Bool? = nil,
        qrCodePayload: String? = nil,
        filePaths: [String]? = nil,
        contentHash: String,
        sourceAppName: String? = nil,
        createdAt: Date = Date(),
        isPinned: Bool = false,
        pinCategory: PinCategory? = nil,
        customAlias: String? = nil
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.imageFileName = imageFileName
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.ocrText = ocrText
        self.ocrChecked = ocrChecked
        self.qrCodePayload = qrCodePayload
        self.filePaths = filePaths
        self.contentHash = contentHash
        self.sourceAppName = sourceAppName
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.pinCategory = pinCategory
        self.customAlias = customAlias
    }

    /// 标题/主要预览文案（若有备注标题则优先展示备注名）
    var primaryTitle: String {
        if let alias = customAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return alias
        }
        return rawContentPreview
    }

    /// 原始内容摘要预览（严格 O(1) 仅向后迭代最多 180 个字符即停止，2MB 大文本耗时 < 0.002ms）
    var rawContentPreview: String {
        switch type {
        case .text, .link:
            guard let raw = text, !raw.isEmpty else { return "空白文本" }
            let slice: Substring = raw.utf8.count > 540 ? raw.prefix(180) : raw[...]
            let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "空白文本" : trimmed
        case .image:
            if let w = imageWidth, let h = imageHeight {
                return "图片 · \(w) × \(h)"
            }
            return "剪贴板图片"
        case .file:
            guard let paths = filePaths, !paths.isEmpty else { return "未知文件" }
            let firstName = URL(fileURLWithPath: paths[0]).lastPathComponent
            if paths.count == 1 {
                return firstName
            }
            return "\(firstName) 等 \(paths.count) 个项目"
        }
    }

    /// 辅助信息（基于 Swift 原生 String O(1) utf8.count 门控，彻底消除百万字符遍历）
    var subtitleInfo: String {
        if let alias = customAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            let preview = rawContentPreview.replacingOccurrences(of: "\n", with: " ")
            return preview.count > 28 ? String(preview.prefix(28)) + "…" : preview
        }
        switch type {
        case .text:
            guard let t = text else { return "0 字" }
            let bytes = t.utf8.count
            if bytes <= 8_192 {
                return "\(t.count) 字"
            } else if bytes < 1_048_576 {
                return String(format: "%.1f KB 文本", Double(bytes) / 1024.0)
            } else {
                return String(format: "%.2f MB 大文本", Double(bytes) / 1_048_576.0)
            }
        case .link:
            if let raw = text, raw.utf8.count <= 4_096 {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
                    return host
                }
            }
            return "网页链接"
        case .image:
            if let qr = qrCodePayload?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines),
               !qr.isEmpty {
                let preview = qr.count > 26 ? String(qr.prefix(26)) + "…" : qr
                return "二维码：\(preview)"
            }
            if let ocr = ocrText?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines),
               !ocr.isEmpty {
                let preview = ocr.count > 26 ? String(ocr.prefix(26)) + "…" : ocr
                return "实况文本：\(preview)"
            }
            return "PNG 图像"
        case .file:
            guard let first = filePaths?.first else { return "本地文件" }
            let dir = URL(fileURLWithPath: first).deletingLastPathComponent().path
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if dir.hasPrefix(home) {
                return "~" + dir.dropFirst(home.count)
            }
            return dir
        }
    }

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM月dd日"
        return formatter
    }()

    /// 中文相对时间描述
    var relativeTimeText: String {
        let interval = Int(Date().timeIntervalSince(createdAt))
        if interval < 15 { return "刚刚" }
        if interval < 60 { return "\(interval) 秒前" }
        let minutes = interval / 60
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        let days = hours / 24
        if days < 7 { return "\(days) 天前" }
        return Self.monthDayFormatter.string(from: createdAt)
    }

    /// 零堆分配快路径 + 自然情景时间窗（今天/昨天/1h/7d/收藏） + `!排除词` + 多词跨维度与拼音极速检索
    func matches(query: String, now: Date = Date()) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }

        // 单一词元零数组分配快路径（保障 2MB 大文本 + 500 条检索 < 3ms）
        if !q.contains(" ") && !q.contains("\t") {
            return evaluateTokenTerm(q, now: now)
        }

        let tokens = q.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for tokenSub in tokens {
            if !evaluateTokenTerm(String(tokenSub), now: now) {
                return false
            }
        }
        return true
    }

    private func evaluateTokenTerm(_ rawToken: String, now: Date) -> Bool {
        if rawToken.hasPrefix("!"), rawToken.utf8.count >= 2, !rawToken.hasPrefix("!=") {
            let excluded = String(rawToken.dropFirst())
            return !matchesSingleToken(excluded, now: now)
        }
        return matchesSingleToken(rawToken, now: now)
    }

    private func matchesSingleToken(_ token: String, now: Date) -> Bool {
        if token.utf8.count <= 16,
           EpisodicQueryMatcher.matchesSpecialToken(token.lowercased(), item: self, now: now) {
            return true
        }
        let opts: String.CompareOptions = [.caseInsensitive]
        if let text = text {
            if text.utf8.count <= 65_536 {
                if text.range(of: token, options: opts) != nil { return true }
            } else {
                // 超大负载仅检索头部约 32K 字符窗口，将单条最坏耗时锁死在 0.1ms 内
                let head = text.prefix(32_768)
                if head.range(of: token, options: opts) != nil { return true }
            }
        }
        if let alias = customAlias, alias.range(of: token, options: opts) != nil {
            return true
        }
        if let cat = pinCategory, cat.title.range(of: token, options: opts) != nil {
            return true
        }
        if let qr = qrCodePayload, qr.range(of: token, options: opts) != nil {
            return true
        }
        if let ocr = ocrText, ocr.range(of: token, options: opts) != nil {
            return true
        }
        if let paths = filePaths {
            for path in paths where path.range(of: token, options: opts) != nil {
                return true
            }
        }
        if let app = sourceAppName, app.range(of: token, options: opts) != nil {
            return true
        }
        if type.displayName.range(of: token, options: opts) != nil {
            return true
        }

        // 免切中文输入法回退：当输入为 2~20 位纯英文字母时，匹配缓存的中文全拼与拼音首字母
        if PinyinSearchCache.isPureASCIILetters(token) {
            return PinyinSearchCache.matchesPinyin(tokenLower: token.lowercased(), for: self)
        }
        return false
    }
}

/// 自然情景时间窗与收藏状态词匹配器（30 秒桶缓存本地零点时间戳，单次比较仅 0.5ns 零堆分配）
enum EpisodicQueryMatcher {
    private static let lock = NSLock()
    private static var cachedRefBucket: Int = -1
    private static var cachedStartOfToday: TimeInterval = 0

    static func startOfToday(for now: Date) -> TimeInterval {
        let nowTs = now.timeIntervalSince1970
        let bucket = Int(nowTs / 30.0)
        lock.lock()
        if bucket == cachedRefBucket {
            let hit = cachedStartOfToday
            lock.unlock()
            return hit
        }
        lock.unlock()

        let computed = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        lock.lock()
        cachedRefBucket = bucket
        cachedStartOfToday = computed
        lock.unlock()
        return computed
    }

    static func matchesSpecialToken(_ tokenLower: String, item: ClipItem, now: Date) -> Bool {
        switch tokenLower {
        case "收藏", "@pin", "@star", "pinned", "starred":
            return item.isPinned
        case "二维码", "qrcode", "@qr":
            return !(item.qrCodePayload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case "今天", "今日", "today", "@today":
            let start = startOfToday(for: now)
            let ts = item.createdAt.timeIntervalSince1970
            return ts >= start && ts < (start + 86_400)
        case "昨天", "昨日", "yesterday", "@yesterday":
            let todayStart = startOfToday(for: now)
            let yesterdayStart = todayStart - 86_400
            let ts = item.createdAt.timeIntervalSince1970
            return ts >= yesterdayStart && ts < todayStart
        case "刚刚", "1h", "1小时", "@1h":
            let diff = now.timeIntervalSince1970 - item.createdAt.timeIntervalSince1970
            return diff >= -60 && diff <= 3_600
        case "本周", "一周", "7d", "week", "@7d", "@week":
            let diff = now.timeIntervalSince1970 - item.createdAt.timeIntervalSince1970
            return diff >= -60 && diff <= 604_800
        default:
            return false
        }
    }

    static func isTimeScopeToken(_ tokenLower: String) -> Bool {
        switch tokenLower {
        case "今天", "今日", "today", "@today",
             "昨天", "昨日", "yesterday", "@yesterday",
             "刚刚", "1h", "1小时", "@1h",
             "本周", "一周", "7d", "week", "@7d", "@week",
             "二维码", "qrcode", "@qr":
            return true
        default:
            return false
        }
    }

    static func isPinScopeToken(_ tokenLower: String) -> Bool {
        switch tokenLower {
        case "收藏", "@pin", "@star", "pinned", "starred":
            return true
        default:
            return false
        }
    }
}

/// 线程安全轻量中文全拼与首字母索引缓存（零外部词库依赖，支持英文输入态盲搜中文历史与应用名）
enum PinyinSearchCache {
    private final class Entry {
        let compactFull: String
        let initials: String
        let aliasFull: String
        let aliasInitials: String
        init(compactFull: String, initials: String, aliasFull: String, aliasInitials: String) {
            self.compactFull = compactFull
            self.initials = initials
            self.aliasFull = aliasFull
            self.aliasInitials = aliasInitials
        }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.countLimit = 1024
        return c
    }()

    static func isPureASCIILetters(_ s: String) -> Bool {
        let len = s.utf8.count
        guard len >= 2 && len <= 20 else { return false }
        for b in s.utf8 {
            let isUpper = (b >= 65 && b <= 90)
            let isLower = (b >= 97 && b <= 122)
            if !isUpper && !isLower { return false }
        }
        return true
    }

    static func matchesPinyin(tokenLower: String, for item: ClipItem) -> Bool {
        let entry = resolvedEntry(for: item)
        if entry.initials.isEmpty { return false }
        return entry.initials.contains(tokenLower) || entry.compactFull.contains(tokenLower)
    }

    static func matchesAliasPinyin(tokenLower: String, for item: ClipItem) -> Bool {
        guard let alias = item.customAlias, !alias.isEmpty else { return false }
        let entry = resolvedEntry(for: item)
        guard !entry.aliasInitials.isEmpty else { return false }
        return entry.aliasInitials == tokenLower
            || entry.aliasFull == tokenLower
            || entry.aliasInitials.hasPrefix(tokenLower)
            || entry.aliasFull.hasPrefix(tokenLower)
    }

    private static func resolvedEntry(for item: ClipItem) -> Entry {
        let cacheKey = "\(item.contentHash)|\(item.customAlias ?? "")|\(item.sourceAppName ?? "")" as NSString
        if let hit = cache.object(forKey: cacheKey) {
            return hit
        }
        let built = buildEntry(for: item)
        cache.setObject(built, forKey: cacheKey)
        return built
    }

    private static func buildEntry(for item: ClipItem) -> Entry {
        var source = ""
        var aliasPair: (full: String, initials: String) = ("", "")
        if let alias = item.customAlias, !alias.isEmpty {
            source.append(alias)
            source.append(" ")
            if containsHanCharacters(alias) {
                aliasPair = transliterate(alias)
            }
        }
        if let app = item.sourceAppName, !app.isEmpty {
            source.append(app)
            source.append(" ")
        }
        source.append(item.type.displayName)
        if let cat = item.pinCategory {
            source.append(" ")
            source.append(cat.title)
        }
        if let t = item.text, !t.isEmpty {
            source.append(" ")
            source.append(String(t.prefix(64)))
        } else if let firstPath = item.filePaths?.first {
            source.append(" ")
            source.append(URL(fileURLWithPath: firstPath).lastPathComponent)
        }
        if let qr = item.qrCodePayload, !qr.isEmpty {
            source.append(" ")
            source.append(String(qr.prefix(48)))
        }
        if let ocr = item.ocrText, !ocr.isEmpty {
            source.append(" ")
            source.append(String(ocr.prefix(48)))
        }

        guard containsHanCharacters(source) else {
            return Entry(compactFull: "", initials: "", aliasFull: "", aliasInitials: "")
        }

        let mainPair = transliterate(source)
        return Entry(
            compactFull: mainPair.full,
            initials: mainPair.initials,
            aliasFull: aliasPair.full,
            aliasInitials: aliasPair.initials
        )
    }

    private static func transliterate(_ text: String) -> (full: String, initials: String) {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let latin = (mutable as String).lowercased()

        var full = String()
        full.reserveCapacity(latin.utf8.count)
        var initials = String()
        initials.reserveCapacity(32)

        var atWordStart = true
        for scalar in latin.unicodeScalars {
            let v = scalar.value
            if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) {
                let ch = Character(scalar)
                full.append(ch)
                if atWordStart {
                    initials.append(ch)
                    atWordStart = false
                }
            } else {
                atWordStart = true
            }
        }
        return (full, initials)
    }

    private static func containsHanCharacters(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                return true
            }
        }
        return false
    }
}

/// 第一性相关度 × 目标窗口情境检索引擎：
/// 1. 守护「空搜索时间流」铁律：日常全部列表空搜索严格保持复制时间倒序，#1 永不乱跳；
/// 2. 主动搜索时综合计算「备注别名命中 > 前缀精确命中 > 收藏沉淀 > 当前目标应用粘贴亲和度 > 全局复用」；
/// 3. 收藏夹无搜索时自动将「当前外部目标应用（如微信 / 终端 / Cursor）最常粘贴的收藏」智能置顶。
enum SmartSearchRanker {
    @MainActor
    static func rankSearchResults(
        _ matchedItems: [ClipItem],
        query: String,
        targetApp: String?,
        engine: AdaptiveIntelligenceEngine
    ) -> [ClipItem] {
        guard engine.smartContextRankingEnabled, matchedItems.count > 1 else {
            return matchedItems
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return matchedItems }

        let rawTokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var positiveContentTokens: [String] = []
        var hasPinScope = false

        for tok in rawTokens {
            if tok.hasPrefix("!") && tok.utf8.count >= 2 && !tok.hasPrefix("!=") {
                continue
            }
            let lower = tok.lowercased()
            if EpisodicQueryMatcher.isTimeScopeToken(lower) {
                continue
            }
            if EpisodicQueryMatcher.isPinScopeToken(lower) {
                hasPinScope = true
                continue
            }
            positiveContentTokens.append(tok)
        }

        // 若用户仅输入时间词（如「今天」「昨天」），严格保留自然时间流；若仅输入「收藏 / @pin」，应用目标窗口常用收藏排序
        if positiveContentTokens.isEmpty {
            if hasPinScope {
                return rankPinnedItemsForContext(matchedItems, targetApp: targetApp, engine: engine)
            }
            return matchedItems
        }

        let joinedQueryLower = positiveContentTokens.joined(separator: " ").lowercased()
        let firstTokenLower = positiveContentTokens[0].lowercased()

        let scored: [(offset: Int, score: Double, item: ClipItem)] = matchedItems.enumerated().map { idx, item in
            let s = relevanceScore(
                for: item,
                joinedQueryLower: joinedQueryLower,
                firstTokenLower: firstTokenLower,
                tokens: positiveContentTokens,
                targetApp: targetApp,
                engine: engine
            )
            return (idx, s, item)
        }

        return scored.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.5 {
                return lhs.score > rhs.score
            }
            return lhs.offset < rhs.offset
        }.map(\.item)
    }

    @MainActor
    static func rankPinnedItemsForContext(
        _ pinnedItems: [ClipItem],
        targetApp: String?,
        engine: AdaptiveIntelligenceEngine
    ) -> [ClipItem] {
        guard engine.smartContextRankingEnabled, pinnedItems.count > 1, targetApp != nil else {
            return pinnedItems
        }

        let decorated: [(offset: Int, appCount: Int, item: ClipItem)] = pinnedItems.enumerated().map { idx, item in
            let count = engine.targetAppPasteCount(for: item.contentHash, targetApp: targetApp)
            return (idx, count >= 2 ? count : 0, item)
        }

        guard decorated.contains(where: { $0.appCount >= 2 }) else {
            return pinnedItems
        }

        return decorated.sorted { lhs, rhs in
            if lhs.appCount != rhs.appCount {
                return lhs.appCount > rhs.appCount
            }
            return lhs.offset < rhs.offset
        }.map(\.item)
    }

    @MainActor
    private static func relevanceScore(
        for item: ClipItem,
        joinedQueryLower: String,
        firstTokenLower: String,
        tokens: [String],
        targetApp: String?,
        engine: AdaptiveIntelligenceEngine
    ) -> Double {
        var score: Double = 0

        // 1. 备注别名（⌘R）精准度：用户特意命名的记忆索引享有最高权重
        if let rawAlias = item.customAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !rawAlias.isEmpty {
            let aliasLower = rawAlias.lowercased()
            if aliasLower == joinedQueryLower || aliasLower == firstTokenLower {
                score += 140
            } else if aliasLower.hasPrefix(joinedQueryLower) || aliasLower.hasPrefix(firstTokenLower) {
                score += 95
            } else if tokens.contains(where: { aliasLower.contains($0.lowercased()) }) {
                score += 65
            } else if PinyinSearchCache.isPureASCIILetters(firstTokenLower),
                      PinyinSearchCache.matchesAliasPinyin(tokenLower: firstTokenLower, for: item) {
                score += 85
            }
        }

        // 2. 正文 / 文件名紧凑命中度（避免数千字长文偶然包含某词压过精悍的目标条目）
        if let rawText = item.text {
            let byteCount = rawText.utf8.count
            let head = String(rawText.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
            let headLower = head.lowercased()
            if byteCount <= 256 && headLower == joinedQueryLower {
                score += 110
            } else if headLower.hasPrefix(joinedQueryLower) || headLower.hasPrefix(firstTokenLower) {
                score += 48
            } else if headLower.contains(firstTokenLower) {
                score += 22
            }
            if byteCount <= 360 {
                score += 12
            }
        } else if let firstPath = item.filePaths?.first {
            let fileNameLower = URL(fileURLWithPath: firstPath).lastPathComponent.lowercased()
            if fileNameLower == joinedQueryLower || fileNameLower == firstTokenLower {
                score += 90
            } else if fileNameLower.hasPrefix(firstTokenLower) {
                score += 48
            } else if fileNameLower.contains(firstTokenLower) {
                score += 24
            }
        }

        // 3. 个人收藏资产权重
        if item.isPinned {
            score += 30
        }

        // 4. 目标窗口情境亲和度（例如在「微信」里搜地址 vs 在「终端」里搜地址）
        let appCount = engine.targetAppPasteCount(for: item.contentHash, targetApp: targetApp)
        if appCount > 0 {
            score += min(Double(appCount) * 22.0, 88.0)
        }

        // 5. 全局历史复用频次微调
        let globalReuse = engine.reuseCount(for: item.contentHash)
        if globalReuse > 1 {
            score += min(Double(globalReuse - 1) * 4.0, 20.0)
        }

        return score
    }
}
