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
        case .pinned: return "pin.fill"
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

    /// 原始内容摘要预览
    var rawContentPreview: String {
        switch type {
        case .text, .link:
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// 辅助信息（字数、域名、实况文本摘要、文件目录等）
    var subtitleInfo: String {
        if let alias = customAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            let preview = rawContentPreview.replacingOccurrences(of: "\n", with: " ")
            return preview.count > 28 ? String(preview.prefix(28)) + "…" : preview
        }
        switch type {
        case .text:
            let count = text?.count ?? 0
            return "\(count) 字"
        case .link:
            if let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: raw),
               let host = url.host, !host.isEmpty {
                return host
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

    /// 搜索匹配判断
    func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true }
        if let text = text, text.lowercased().contains(q) {
            return true
        }
        if let alias = customAlias, alias.lowercased().contains(q) {
            return true
        }
        if let cat = pinCategory, cat.title.lowercased().contains(q) {
            return true
        }
        #if ICLIP_EDITION_FLOW
        if let ocr = ocrText, ocr.lowercased().contains(q) {
            return true
        }
        #endif
        if let paths = filePaths {
            for path in paths where path.lowercased().contains(q) {
                return true
            }
        }
        if let app = sourceAppName, app.lowercased().contains(q) {
            return true
        }
        if type.displayName.contains(q) {
            return true
        }
        return false
    }
}
