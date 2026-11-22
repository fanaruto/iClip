import SwiftUI
import AppKit

/// 苹果原生风格「核心亮点速览（Feature Highlights）」控制器
///
/// 摒弃繁琐的打卡任务与假数据注入：
/// - 绝不向用户剪贴板塞入示例垃圾卡片；
/// - 仅在首次打开（或设置页主动查看）时以通透居中浮层突出 3 个最核心重点能力，按 ↵ / ESC 或点击「开始使用」即刻进入纯净主界面。
@MainActor
final class InteractivePlaygroundController: ObservableObject {
    static let shared = InteractivePlaygroundController()

    private let seenHighlightsKey = "hasSeenCoreHighlightsV3"
    private let legacySampleHashesKey = "playgroundSampleContentHashes"

    @Published var isActive: Bool = false

    private init() {
        let seen = UserDefaults.standard.bool(forKey: seenHighlightsKey)
        if !seen && !ProcessInfo.processInfo.arguments.contains("--demo") && !ProcessInfo.processInfo.arguments.contains("--analyze-bloat") {
            isActive = true
        }
    }

    func showHighlights() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
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
                .fill(Color.black.opacity(colorScheme == .dark ? 0.52 : 0.24))
                .onTapGesture {
                    controller.dismiss(in: store)
                }

            VStack(alignment: .leading, spacing: 18) {
                // 顶部极简标题
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 iClip")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("只记重点，开箱即用")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }

                // 仅突出 3 个最高频王牌能力
                VStack(alignment: .leading, spacing: 14) {
                    highlightRow(
                        symbol: "arrow.up.and.down.and.sparkles",
                        gradient: [.cyan, .blue],
                        title: "双向自由拖拽",
                        detail: "外部图文文件拖入即复制；面板内按住卡片直接拖进微信与文档。"
                    )

                    highlightRow(
                        symbol: "sparkles.rectangle.stack",
                        gradient: [.purple, .pink, .orange],
                        title: "官方级液态玻璃",
                        detail: "原生 26pt 连续 R 角与光学透镜折射，深浅双外观下文字始终锐利清晰。"
                    )

                    highlightRow(
                        symbol: "command",
                        gradient: [.green, .teal],
                        title: "全键盘瞬时流转",
                        detail: "按 ⇥ 切换类目，↑↓←→ 选图，⇧↵ 一键完成密钥脱敏或财务大写。"
                    )
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
                                .fill(Color.accentColor)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(22)
            .frame(width: 356)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(glassPalette.groupStroke, lineWidth: 0.9)
                    )
                    .shadow(color: Color.black.opacity(0.28), radius: 22, y: 10)
            )
        }
    }

    private func highlightRow(symbol: String, gradient: [Color], title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
