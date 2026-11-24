import SwiftUI
import AppKit

/// 新手与新功能引导条目模型（双端同源核心能力速览）
struct HighlightFeatureItem: Identifiable, Equatable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
}

/// 苹果原生风格「核心亮点速览（Feature Highlights）」控制器
///
/// 摒弃繁琐打卡与假数据注入：
/// - 绝不向用户剪贴板塞入示例垃圾卡片；
/// - 首次打开或升至 v2.7 新版时以通透居中浮层呈现 4 项最高频王牌能力，按 ↵ / Space / Esc 或点击「开始使用」即刻进入纯净主界面；
/// - 支持随时从设置页「帮助」或菜单栏右键重新唤出。
@MainActor
final class InteractivePlaygroundController: ObservableObject {
    static let shared = InteractivePlaygroundController()

    static let coreHighlights: [HighlightFeatureItem] = [
        HighlightFeatureItem(
            id: "zero-blur-paste",
            symbol: "bolt.horizontal.fill",
            tint: Color(red: 0.12, green: 0.37, blue: 1.0),
            title: "唤醒零失焦直贴",
            detail: "在搜索框或弹层内呼出不丢原焦点，按 ↵ 瞬间顺手键入当前位置。"
        ),
        HighlightFeatureItem(
            id: "zero-trust-shield",
            symbol: "lock.shield.fill",
            tint: Color(red: 0.08, green: 0.62, blue: 0.45),
            title: "零信任隐私护盾",
            detail: "全库硬件加密与投屏自动隐身，密钥默认圆点遮罩，⇧↵ 一键 AI 替身脱敏。"
        ),
        HighlightFeatureItem(
            id: "todo-clean-text",
            symbol: "checklist.checked",
            tint: Color(red: 0.22, green: 0.48, blue: 0.96),
            title: "剪贴即待办与净文",
            detail: "⌘T 一键转待办；AI 回复一键褪去 Markdown 符号，表格直粘 Excel 分列。"
        ),
        HighlightFeatureItem(
            id: "drag-and-minimal",
            symbol: "leaf.fill",
            tint: Color(red: 0.16, green: 0.56, blue: 0.52),
            title: "自由拖拽与极简开关",
            detail: "图文双向自由拖入拖出，Tab 秒切分类，按 ⌘E 随时切回极简纯净模式。"
        )
    ]

    private let seenHighlightsKey = "hasSeenCoreHighlightsV4_v27"
    private let legacySampleHashesKey = "playgroundSampleContentHashes"

    @Published var isActive: Bool = false

    private init() {
        let seen = UserDefaults.standard.bool(forKey: seenHighlightsKey)
        if !seen && !ProcessInfo.processInfo.arguments.contains("--demo") && !ProcessInfo.processInfo.arguments.contains("--analyze-bloat") {
            isActive = true
        }
    }

    func showHighlights() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            isActive = true
        }
    }

    func dismiss(in store: ClipboardStore? = nil) {
        if let store {
            cleanupLegacySamplesIfAny(in: store)
        }
        UserDefaults.standard.set(true, forKey: seenHighlightsKey)
        withAnimation(.easeOut(duration: 0.18)) {
            isActive = false
        }
    }

    /// 自动清理旧版本可能残留的游乐场示例卡片，保持用户剪贴板绝对纯净
    func cleanupLegacySamplesIfAny(in store: ClipboardStore) {
        let hashes = Set(UserDefaults.standard.stringArray(forKey: legacySampleHashesKey) ?? [])
        for item in store.items {
            if hashes.contains(item.contentHash) || (item.sourceAppName?.hasPrefix("游乐场示例") == true) {
                store.delete(item)
            }
        }
        UserDefaults.standard.removeObject(forKey: legacySampleHashesKey)
    }
}

/// 苹果官方「新功能亮点（What's New）」同款极简液态玻璃重点浮层
struct CoreHighlightsOverlay: View {
    @ObservedObject var controller: InteractivePlaygroundController
    let store: ClipboardStore
    let glassPalette: LiquidGlassPalette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.54 : 0.24))
                .onTapGesture {
                    controller.dismiss(in: store)
                }

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("欢迎使用 iClip 2.7")
                            .font(.system(size: 19.5, weight: .bold))
                            .foregroundStyle(.primary)
                        Text("轻如无物，一呼即贴 · 按 ↵ 立即开始")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    BrandAppIconBadge(size: 32)
                }

                VStack(alignment: .leading, spacing: 12.5) {
                    ForEach(InteractivePlaygroundController.coreHighlights) { item in
                        highlightRow(item)
                    }
                }

                Button {
                    controller.dismiss(in: store)
                } label: {
                    Text("开始使用")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.12, green: 0.37, blue: 1.0))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(22)
            .frame(width: 364)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.18), radius: 22, y: 10)
            )
        }
    }

    private func highlightRow(_ item: HighlightFeatureItem) -> some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(item.tint.opacity(colorScheme == .dark ? 0.22 : 0.13))
                    .frame(width: 32, height: 32)
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(item.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(item.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
