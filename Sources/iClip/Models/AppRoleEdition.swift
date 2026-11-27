import Foundation
import SwiftUI

/// iClip 统一主线版本信息（One iClip：废除开发版/办公版割裂，保留单一纯粹主线）
enum AppRoleEdition: String, Codable, CaseIterable, Identifiable {
    case unified = "unified"

    var id: String { rawValue }

    /// 当前客户端版本号字符串
    static var currentVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "3.0.0"
    }

    /// 当前运行客户端固定为唯一统一主线
    static var installed: AppRoleEdition { .unified }

    var title: String { "iClip" }

    var fullTitle: String { "iClip" }

    var expectedAssetName: String { "iClip-macOS.zip" }
}
