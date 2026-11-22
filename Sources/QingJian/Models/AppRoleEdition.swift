import Foundation
import SwiftUI

/// iClip 双角色专属版本定义（编译期二进制隔离 + 差异化 GitHub Releases OTA 轨道）
enum AppRoleEdition: String, Codable, CaseIterable, Identifiable {
    /// 面向程序员、运维、数据工程师与 AI 重度用户的语义转换与脱敏版
    case developer = "dev"
    /// 面向商务运营、财务、研究员与多任务办公人群的顺序队列与离线识图版
    case workflow = "flow"

    var id: String { rawValue }

    /// 当前正在运行的客户端二进制所属角色版本
    static var installed: AppRoleEdition {
        if let plistValue = Bundle.main.infoDictionary?["IClipEdition"] as? String,
           let parsed = AppRoleEdition(rawValue: plistValue) {
            return parsed
        }
        #if ICLIP_EDITION_FLOW
        return .workflow
        #else
        return .developer
        #endif
    }

    var title: String {
        switch self {
        case .developer: return "极客开发版"
        case .workflow: return "心流办公版"
        }
    }

    var fullTitle: String {
        switch self {
        case .developer: return "极客开发与 AI 版"
        case .workflow: return "商务与心流办公版"
        }
    }

    var subtitle: String {
        switch self {
        case .developer:
            return "AI 密钥脱敏 · JSON/cURL/SQL 瞬变 · @语义速筛 · 动态模板"
        case .workflow:
            return "FIFO 顺序连填表单 · 截图离线识字 · 多选合并 · 收藏分组"
        }
    }

    var shortHighlights: [String] {
        switch self {
        case .developer:
            return ["密钥自动掩码", "JSON/SQL/净链", "QuickLook 对照"]
        case .workflow:
            return ["⌃⌥V 连填表单", "截图实况识字", "多选合并摘录"]
        }
    }

    var symbolName: String {
        switch self {
        case .developer: return "terminal.fill"
        case .workflow: return "sparkles.rectangle.stack.fill"
        }
    }

    var accentTint: Color {
        switch self {
        case .developer: return .indigo
        case .workflow: return .blue
        }
    }

    /// 该角色在 GitHub Releases 中对应的独立安装包文件名
    var expectedAssetName: String {
        switch self {
        case .developer: return "iClip-Dev-macOS.zip"
        case .workflow: return "iClip-Flow-macOS.zip"
        }
    }
}
