import SwiftUI
import AppKit

/// 首次打开「30 秒互动游乐场（Interactive Playground）」控制器
///
/// 遵循乔布斯式“Show, Don't Tell”直觉引导：
/// 1. 首次启动（或用户在设置页点击重玩）时，自动预置 3 张自带魔法的体验卡片（实况海报图 + 敏感密钥/财务账单 + 效率金句）；
/// 2. 顶部展示紧凑的 3 步闯关胶囊条：
///    - Step 1：按 `⇥ Tab` 左/右切换一次类目，或按方向键浏览
///    - Step 2：按 `⇧↵`（或点卡片底部胶囊）体验一次瞬时智变 / 脱敏 / 账单求和
///    - Step 3：按住任意卡片向外拖出，或拖向屏幕顶部 New Siri 虹吸球
/// 3. 30 秒内完成全部 3 步或随时点「完成并清理示例」，可一键移除演练卡片，不污染用户真实剪贴板历史。
@MainActor
final class InteractivePlaygroundController: ObservableObject {
    static let shared = InteractivePlaygroundController()

    private let completedKey = "hasCompletedInteractivePlaygroundV2"
    private let sampleHashesKey = "playgroundSampleContentHashes"

    @Published var isActive: Bool = false
    @Published var step1TabSwitched: Bool = false
    @Published var step2MagicTriggered: Bool = false
    @Published var step3DragExperienced: Bool = false
    @Published var justFinishedAll: Bool = false

    var completedCount: Int {
        (step1TabSwitched ? 1 : 0) + (step2MagicTriggered ? 1 : 0) + (step3DragExperienced ? 1 : 0)
    }

    private init() {
        let alreadyDone = UserDefaults.standard.bool(forKey: completedKey)
        if !alreadyDone && !ProcessInfo.processInfo.arguments.contains("--demo") {
            isActive = true
        }
    }

    /// 启动或重玩 30 秒互动游乐场，注入 3 张可实操的魔法示例卡片
    func startOrReplay(in store: ClipboardStore) {
        step1TabSwitched = false
        step2MagicTriggered = false
        step3DragExperienced = false
        justFinishedAll = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            isActive = true
        }
        UserDefaults.standard.set(false, forKey: completedKey)
        seedPlaygroundCardsIfNeeded(in: store)
    }

    /// 首次启动若处于激活态且尚未注入示例卡，自动注入
    func ensureSeededOnFirstLaunch(in store: ClipboardStore) {
        guard isActive else { return }
        let savedHashes = UserDefaults.standard.stringArray(forKey: sampleHashesKey) ?? []
        if savedHashes.isEmpty || store.items.isEmpty {
            seedPlaygroundCardsIfNeeded(in: store)
        }
    }

    func recordTabOrArrowNavigation() {
        guard isActive, !step1TabSwitched else { return }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
            step1TabSwitched = true
        }
        checkCompletion()
    }

    func recordMagicOrCopyAction() {
        guard isActive, !step2MagicTriggered else { return }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
            step2MagicTriggered = true
        }
        checkCompletion()
    }

    func recordDragAction() {
        guard isActive, !step3DragExperienced else { return }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
            step3DragExperienced = true
        }
        checkCompletion()
    }

    private func checkCompletion() {
        if step1TabSwitched && step2MagicTriggered && step3DragExperienced && !justFinishedAll {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                justFinishedAll = true
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    /// 结束游乐场并可选清理预置的示例卡片
    func finish(in store: ClipboardStore, removeSampleCards: Bool) {
        if removeSampleCards {
            let hashes = Set(UserDefaults.standard.stringArray(forKey: sampleHashesKey) ?? [])
            if !hashes.isEmpty {
                for item in store.items where hashes.contains(item.contentHash) {
                    store.delete(item)
                }
            }
            UserDefaults.standard.removeObject(forKey: sampleHashesKey)
        }
        UserDefaults.standard.set(true, forKey: completedKey)
        withAnimation(.easeOut(duration: 0.2)) {
            isActive = false
            justFinishedAll = false
        }
        if removeSampleCards {
            store.showToast("已完成游乐场并清理示例卡片")
        } else {
            store.showToast("已开启 iClip 完整体验")
        }
    }

    // MARK: - 生成 3 张自带魔法的互动示例卡片

    private func seedPlaygroundCardsIfNeeded(in store: ClipboardStore) {
        var createdHashes: [String] = []

        // 卡片 3（排第 3）：双向拖拽与 Markdown 表格破壁示例
        let tableSample = """
        | 快捷键 | 核心魔法 | 适用场景 |
        | --- | --- | --- |
        | ⇥ Tab | 秒切 6 大类目 | 全键盘极速检索 |
        | ⇧ ↵ | 智能脱敏 / 财务大写 | 喂 AI / 贴报销单 |
        | 拖拽到顶部 | New Siri 虹吸球吞噬 | 免开面板随手收集 |
        """
        if let h = injectTextSample(tableSample, source: "游乐场示例 · 试着拖向顶部 Siri 球", in: store) {
            createdHashes.append(h)
        }

        // 卡片 2（排第 2）：角色专属魔法卡（Dev 版为 AI 密钥+JSON 脱敏；Flow 版为多行账单求和+人民币大写）
        #if ICLIP_EDITION_FLOW
        let magicSample = """
        差旅机票报销 1,280.00 元
        酒店住宿发票 640.50 元
        市内交通补贴 79.50 元
        """
        let magicSource = "游乐场示例 · 按 ⇧↵ 一键求和/转大写"
        #else
        let magicSample = """
        OPENAI_API_KEY="sk-proj-9876543210abcdefghijklmnop"
        DB_HOST="192.168.1.108:5432"
        """
        let magicSource = "游乐场示例 · 按 ⇧↵ 一键脱敏喂给 AI"
        #endif
        if let h = injectTextSample(magicSample, source: magicSource, in: store) {
            createdHashes.append(h)
        }

        // 卡片 1（排第 1）：高颜值 Apple Intelligence 渐变示例图（支持方向键选图、悬停放大、向外拖出）
        if let imgHash = injectSamplePosterImage(in: store) {
            createdHashes.append(imgHash)
        }

        UserDefaults.standard.set(createdHashes, forKey: sampleHashesKey)
    }

    private func injectTextSample(_ text: String, source: String, in store: ClipboardStore) -> String? {
        let dragPB = NSPasteboard.withUniqueName()
        defer { dragPB.releaseGlobally() }
        dragPB.clearContents()
        dragPB.setString(text, forType: .string)
        _ = store.importAndCopy(from: dragPB, sourceLabel: source)
        return store.items.first?.contentHash
    }

    private func injectSamplePosterImage(in store: ClipboardStore) -> String? {
        let size = NSSize(width: 640, height: 420)
        let image = NSImage(size: size, flipped: false) { rect in
            let gradient = NSGradient(colors: [
                NSColor(srgbRed: 0.10, green: 0.12, blue: 0.28, alpha: 1.0),
                NSColor(srgbRed: 0.24, green: 0.14, blue: 0.46, alpha: 1.0),
                NSColor(srgbRed: 0.12, green: 0.42, blue: 0.68, alpha: 1.0)
            ])
            gradient?.draw(in: rect, angle: 35)

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 28, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.86)
            ]
            NSString(string: "iClip · 30 秒互动游乐场").draw(at: NSPoint(x: 42, y: 245), withAttributes: titleAttrs)
            NSString(string: "1. 按 Tab / 方向键自由冲浪   2. 按 ⇧↵ 触发智能魔法").draw(at: NSPoint(x: 42, y: 185), withAttributes: subAttrs)
            NSString(string: "3. 按住这张图直接拖到微信/桌面，或拖向顶部 Siri 彩球").draw(at: NSPoint(x: 42, y: 145), withAttributes: subAttrs)
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let dragPB = NSPasteboard.withUniqueName()
        defer { dragPB.releaseGlobally() }
        dragPB.clearContents()
        dragPB.setData(png, forType: .png)
        _ = store.importAndCopy(from: dragPB, sourceLabel: "游乐场示例图 · 可直接向外拖出")
        return "img:"
    }
}

/// 顶部「30 秒互动游乐场」闯关引导卡片
struct InteractivePlaygroundBanner: View {
    @ObservedObject var playground: InteractivePlaygroundController
    @ObservedObject var store: ClipboardStore
    let glassPalette: LiquidGlassPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text(playground.justFinishedAll ? "恭喜通关！你已掌握 iClip 全部核心魔法" : "30 秒互动游乐场（亲手试一下下面 3 个动作）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(playground.completedCount)/3")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))

                Button {
                    playground.finish(in: store, removeSampleCards: true)
                } label: {
                    Text(playground.justFinishedAll ? "完成并清理示例" : "跳过")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(playground.justFinishedAll ? Color.white : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(playground.justFinishedAll ? Color.accentColor : Color.primary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                stepPill(
                    done: playground.step1TabSwitched,
                    icon: "arrow.left.arrow.right.square",
                    title: "① 按 ⇥ 切类目"
                )
                stepPill(
                    done: playground.step2MagicTriggered,
                    icon: "wand.and.stars",
                    title: "② 按 ⇧↵ 试魔法"
                )
                stepPill(
                    done: playground.step3DragExperienced,
                    icon: "hand.draw",
                    title: "③ 拖出或拖上顶部"
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(glassPalette.groupFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(0.55),
                            Color.purple.opacity(0.45),
                            glassPalette.groupStroke
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        )
    }

    private func stepPill(done: Bool, icon: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(done ? Color.green : Color.accentColor)
            Text(title)
                .font(.system(size: 10.5, weight: done ? .semibold : .medium))
                .foregroundStyle(done ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(done ? Color.green.opacity(0.14) : glassPalette.nestedCardFill)
        )
    }
}
