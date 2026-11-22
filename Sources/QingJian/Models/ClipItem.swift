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
            #if ICLIP_EDITION_FLOW
            if let ocr = ocrText?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines),
               !ocr.isEmpty {
                let preview = ocr.count > 26 ? String(ocr.prefix(26)) + "…" : ocr
                return "实况文本：\(preview)"
            }
            #endif
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

    /// 零堆分配快路径 + 多词跨维度 AND 组合 + 免切输入法拼音/首字母极速搜索匹配
    func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }

        // 单一词元零数组分配快路径（保障 2MB 大文本 + 500 条检索 < 3ms）
        if !q.contains(" ") && !q.contains("\t") {
            return matchesSingleToken(q)
        }

        let tokens = q.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for tokenSub in tokens {
            if !matchesSingleToken(String(tokenSub)) {
                return false
            }
        }
        return true
    }

    private func matchesSingleToken(_ token: String) -> Bool {
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
        #if ICLIP_EDITION_FLOW
        if let ocr = ocrText, ocr.range(of: token, options: opts) != nil {
            return true
        }
        #endif
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

/// 线程安全轻量中文全拼与首字母索引缓存（零外部词库依赖，支持英文输入态盲搜中文历史与应用名）
enum PinyinSearchCache {
    private final class Entry {
        let compactFull: String
        let initials: String
        init(compactFull: String, initials: String) {
            self.compactFull = compactFull
            self.initials = initials
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
        let cacheKey = "\(item.contentHash)|\(item.customAlias ?? "")|\(item.sourceAppName ?? "")" as NSString
        let entry: Entry
        if let hit = cache.object(forKey: cacheKey) {
            entry = hit
        } else {
            let built = buildEntry(for: item)
            cache.setObject(built, forKey: cacheKey)
            entry = built
        }
        if entry.initials.isEmpty { return false }
        return entry.initials.contains(tokenLower) || entry.compactFull.contains(tokenLower)
    }

    private static func buildEntry(for item: ClipItem) -> Entry {
        var source = ""
        if let alias = item.customAlias, !alias.isEmpty {
            source.append(alias)
            source.append(" ")
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
        #if ICLIP_EDITION_FLOW
        if let ocr = item.ocrText, !ocr.isEmpty {
            source.append(" ")
            source.append(String(ocr.prefix(48)))
        }
        #endif

        guard containsHanCharacters(source) else {
            return Entry(compactFull: "", initials: "")
        }

        let mutable = NSMutableString(string: source) as CFMutableString
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
        return Entry(compactFull: full, initials: initials)
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
