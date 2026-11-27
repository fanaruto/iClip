import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - 1. macOS 26 Tahoe 官方液态玻璃与原生控件适配层

enum TahoeUI {
    static let brandCobalt = Color(red: 0.118, green: 0.369, blue: 1.0)
    static let brandMint = Color(red: 0.08, green: 0.64, blue: 0.46)
    static let brandIndigo = Color(red: 0.33, green: 0.34, blue: 0.92)
}

struct TahoeGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

extension View {
    /// macOS 26 Tahoe 原生 Liquid Glass 卡片材质（macOS 14-15 自动回退为同心连续圆角毛玻璃）
    @ViewBuilder
    func tahoeGlassCard(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if let tint {
                let subtleTint = tint.opacity(0.16)
                if interactive {
                    self.glassEffect(.regular.tint(subtleTint).interactive(), in: shape)
                } else {
                    self.glassEffect(.regular.tint(subtleTint), in: shape)
                }
            } else {
                if interactive {
                    self.glassEffect(.regular.interactive(), in: shape)
                } else {
                    self.glassEffect(.regular, in: shape)
                }
            }
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            self
                .background(
                    shape.fill(.regularMaterial)
                        .overlay(
                            shape.fill((tint ?? Color.clear).opacity(tint == nil ? 0 : 0.09))
                        )
                )
                .overlay(
                    shape.strokeBorder(
                        (tint ?? Color.primary).opacity(tint == nil ? 0.10 : 0.28),
                        lineWidth: 0.8
                    )
                )
        }
    }

    /// macOS 26 Tahoe 原生胶囊按钮（`.glassProminent` / `.glass`），macOS 14-15 优雅回退
    @ViewBuilder
    func tahoeActionButtonStyle(prominent: Bool) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }

    /// macOS 26 Tahoe 原生柔边滚动渐变（消除硬切线）
    @ViewBuilder
    func tahoeSoftScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

// MARK: - 2. 独立设置窗口导航分区与权限焦点枚举

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case appearance
    case shortcuts
    case intelligence
    case privacy
    case permissionsAndAbout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "外观与手感"
        case .shortcuts: return "快捷键与手势"
        case .intelligence: return "智能与效率"
        case .privacy: return "隐私与搬家"
        case .permissionsAndAbout: return "权限与关于"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: return "液态玻璃浓度、卡片皮肤、悬浮精灵与点击手感"
        case .shortcuts: return "全局热键零冲突录制与高频键盘流速查"
        case .intelligence: return "OneMind 主动心智、极简纯净模式与口令短语"
        case .privacy: return "本机加密护盾、忽略应用、保留上限与数据迁入"
        case .permissionsAndAbout: return "系统权限自检、新手引导重温与软件更新"
        }
    }

    var symbolName: String {
        switch self {
        case .appearance: return "paintbrush.fill"
        case .shortcuts: return "command"
        case .intelligence: return "sparkles"
        case .privacy: return "lock.shield.fill"
        case .permissionsAndAbout: return "checkmark.shield.fill"
        }
    }

    var badgeGradient: [Color] {
        switch self {
        case .appearance: return [Color(red: 0.14, green: 0.45, blue: 1.0), Color(red: 0.06, green: 0.30, blue: 0.90)]
        case .shortcuts: return [Color(red: 0.36, green: 0.36, blue: 0.95), Color(red: 0.25, green: 0.24, blue: 0.80)]
        case .intelligence: return [Color(red: 0.62, green: 0.32, blue: 0.94), Color(red: 0.45, green: 0.20, blue: 0.82)]
        case .privacy: return [Color(red: 0.12, green: 0.70, blue: 0.48), Color(red: 0.06, green: 0.54, blue: 0.38)]
        case .permissionsAndAbout: return [Color(red: 0.12, green: 0.58, blue: 0.78), Color(red: 0.06, green: 0.43, blue: 0.66)]
        }
    }
}

enum PermissionFocusKind: String, Equatable, CaseIterable {
    case accessibility
    case fullDiskAccess
    case screenRecording
}

// MARK: - 3. 全局零冲突自检模型（纯函数，全覆盖单测）

struct HotKeyConflictHealthReport: Equatable {
    let isHealthy: Bool
    let issues: [String]

    static func evaluate(
        main: HotKeyShortcut,
        screenshot: HotKeyShortcut,
        copyAppend: HotKeyShortcut,
        copyAppendEnabled: Bool
    ) -> HotKeyConflictHealthReport {
        var issues: [String] = []

        if main == screenshot {
            issues.append("「全局呼出」与「区域截图」绑定了相同快捷键（\(main.displayString)），请调整其中一个。")
        }
        if copyAppendEnabled && main == copyAppend {
            issues.append("「全局呼出」与「跨处续接复制」绑定了相同快捷键（\(main.displayString)）。")
        }
        if copyAppendEnabled && screenshot == copyAppend {
            issues.append("「区域截图」与「跨处续接复制」绑定了相同快捷键（\(screenshot.displayString)）。")
        }

        var mainOthers: [(HotKeyShortcut, String)] = [(screenshot, "区域/窗口截图")]
        if copyAppendEnabled {
            mainOthers.append((copyAppend, "跨处续接复制"))
        }
        if let reason = HotKeyConflictValidator.staticConflictReason(
            for: main,
            role: .mainToggle,
            existingOwnShortcut: HotKeyShortcut(keyCode: 0xFFFF, carbonModifiers: 0),
            otherBindings: mainOthers
        ), !issues.contains(reason) {
            issues.append("主呼出热键：\(reason)")
        }

        var shotOthers: [(HotKeyShortcut, String)] = [(main, "全局呼出快捷键")]
        if copyAppendEnabled {
            shotOthers.append((copyAppend, "跨处续接复制"))
        }
        if let reason = HotKeyConflictValidator.staticConflictReason(
            for: screenshot,
            role: .screenshot,
            existingOwnShortcut: HotKeyShortcut(keyCode: 0xFFFF, carbonModifiers: 0),
            otherBindings: shotOthers
        ), !issues.contains(reason) {
            issues.append("截图热键：\(reason)")
        }

        return HotKeyConflictHealthReport(isHealthy: issues.isEmpty, issues: issues)
    }
}

struct FeatureConflictAdvisory: Identifiable, Equatable {
    enum Severity: Equatable {
        case info
        case warning
    }

    enum ActionKind: Equatable {
        case disableMinimalMode
        case enableSpriteOrb
        case openPermissionCenter
    }

    let id: String
    let severity: Severity
    let title: String
    let detail: String
    let actionTitle: String?
    let actionKind: ActionKind?

    static func evaluate(
        minimalModeEnabled: Bool,
        sparkEnabled: Bool,
        financeAssistantEnabled: Bool,
        spriteOrbEnabled: Bool,
        spriteOrbProactiveNudgeEnabled: Bool,
        isAccessibilityGranted: Bool,
        isFullDiskAccessGranted: Bool,
        isScreenRecordingGranted: Bool
    ) -> [FeatureConflictAdvisory] {
        var list: [FeatureConflictAdvisory] = []

        if minimalModeEnabled && (sparkEnabled || financeAssistantEnabled || spriteOrbProactiveNudgeEnabled) {
            list.append(
                FeatureConflictAdvisory(
                    id: "minimal-mode-shadows-intelligence",
                    severity: .info,
                    title: "当前处于「极简纯净模式（⌘E）」",
                    detail: "智能微星标、主动拟态推进、财务票据助手与待办页签已自动休眠，避免功能互扰；退出极简模式后将按原配置立即恢复。",
                    actionTitle: "退出极简模式",
                    actionKind: .disableMinimalMode
                )
            )
        }

        if !minimalModeEnabled && spriteOrbProactiveNudgeEnabled && !spriteOrbEnabled {
            list.append(
                FeatureConflictAdvisory(
                    id: "proactive-nudge-needs-orb",
                    severity: .warning,
                    title: "「主动拟态推进」当前处于休眠态",
                    detail: "主动推进提醒依托桌面悬浮精灵小球轻触呈现；你已关闭悬浮精灵小球，开启后该功能即可自动生效。",
                    actionTitle: "开启悬浮精灵",
                    actionKind: .enableSpriteOrb
                )
            )
        }

        var missingItems: [String] = []
        if !isAccessibilityGranted { missingItems.append("辅助功能（一键粘贴）") }
        if !isFullDiskAccessGranted { missingItems.append("完全磁盘访问（聊天原图）") }
        if !isScreenRecordingGranted { missingItems.append("屏幕录制（⌥A 截图）") }

        if !missingItems.isEmpty {
            list.append(
                FeatureConflictAdvisory(
                    id: "missing-system-permissions",
                    severity: .warning,
                    title: "有 \(missingItems.count) 项系统权限未授权，部分能力受限",
                    detail: "待授权：\(missingItems.joined(separator: "、"))。前往独立权限中心一键补齐即可恢复完整体验。",
                    actionTitle: "前往权限中心",
                    actionKind: .openPermissionCenter
                )
            )
        }

        return list
    }
}

/// 零信任隐私护盾「总开关 ↔ 6 项子开关」严格状态机（纯函数，全覆盖单测）：
/// - 只要任意一项子开关开启，总开关即保持开启（`activeCount > 0`）；
/// - 只有把底下全部 6 项隐私子开关都关闭时，总开关才联动关闭（`activeCount == 0`）；
/// - 主动拨动总开关时，一键全开或全关全部 6 项隐私子开关。
struct PrivacyShieldToggleState: Equatable {
    var screenSharePrivacy: Bool
    var maskSensitivePreviews: Bool
    var autoRedactOnPaste: Bool
    var autoClearConcealedPasteboard: Bool
    var autoExpireUnpinnedSecrets: Bool
    var autoCleanTrackingURL: Bool

    static let totalCount: Int = 6

    var activeCount: Int {
        [
            screenSharePrivacy,
            maskSensitivePreviews,
            autoRedactOnPaste,
            autoClearConcealedPasteboard,
            autoExpireUnpinnedSecrets,
            autoCleanTrackingURL
        ].filter { $0 }.count
    }

    /// 只要存在任一子开关开启，总开关保持开启；仅在全部关闭（0/6）时联动关闭总开关
    var isMasterOn: Bool {
        activeCount > 0
    }

    var isFullyProtected: Bool {
        activeCount == Self.totalCount
    }

    var isPartiallyProtected: Bool {
        activeCount > 0 && activeCount < Self.totalCount
    }

    var badgeText: String {
        if isFullyProtected {
            return "全面守护（6/6）"
        } else if isPartiallyProtected {
            return "自定义守护（\(activeCount)/6）"
        } else {
            return "护盾已关闭（0/6）"
        }
    }

    var statusDescription: String {
        if isFullyProtected {
            return "已全面开启投屏隐身、圆点防肩窥、粘贴自动脱敏、密码擦除、24h 销毁与净链保护"
        } else if isPartiallyProtected {
            return "当前已开启 \(activeCount)/6 项隐私护盾；可按需微调下方细项，仅全部关闭时总开关才联动关闭"
        } else {
            return "全部 6 项隐私护盾均已关闭，打开总开关或任一细项即可恢复守护"
        }
    }

    static func all(_ enabled: Bool) -> PrivacyShieldToggleState {
        PrivacyShieldToggleState(
            screenSharePrivacy: enabled,
            maskSensitivePreviews: enabled,
            autoRedactOnPaste: enabled,
            autoClearConcealedPasteboard: enabled,
            autoExpireUnpinnedSecrets: enabled,
            autoCleanTrackingURL: enabled
        )
    }

    @MainActor
    static func from(store: ClipboardStore) -> PrivacyShieldToggleState {
        PrivacyShieldToggleState(
            screenSharePrivacy: store.screenSharePrivacyEnabled,
            maskSensitivePreviews: store.maskSensitivePreviews,
            autoRedactOnPaste: store.autoRedactOnPaste,
            autoClearConcealedPasteboard: store.autoClearConcealedPasteboard,
            autoExpireUnpinnedSecrets: store.autoExpireUnpinnedSecrets,
            autoCleanTrackingURL: store.autoCleanTrackingURL
        )
    }

    @MainActor
    func apply(to store: ClipboardStore) {
        store.screenSharePrivacyEnabled = screenSharePrivacy
        store.maskSensitivePreviews = maskSensitivePreviews
        store.autoRedactOnPaste = autoRedactOnPaste
        store.autoClearConcealedPasteboard = autoClearConcealedPasteboard
        store.autoExpireUnpinnedSecrets = autoExpireUnpinnedSecrets
        store.autoCleanTrackingURL = autoCleanTrackingURL
    }
}

// MARK: - 4. 跨窗口共享热键录制协调器（设置窗 & 入门引导窗通用，零抢焦冲突）

@MainActor
final class HotKeyRecorderCoordinator: ObservableObject {
    static let shared = HotKeyRecorderCoordinator()

    @Published private(set) var recordingSlot: HotKeySlotRole? = nil
    @Published var conflictWarning: String? = nil
    @Published var recordingHint: String? = nil

    var isRecording: Bool {
        recordingSlot != nil
    }

    private weak var boundStore: ClipboardStore?
    private var localMonitor: Any?
    private var tapMachine = ModifierDoubleTapStateMachine(maxHoldDuration: 0.35, maxTapGap: 0.48)

    private init() {}

    func isRecording(slot: HotKeySlotRole) -> Bool {
        recordingSlot == slot
    }

    enum RecordingOutcome: Equatable {
        case updated(HotKeyShortcut)
        case rejected(String)
    }

    func startRecording(slot: HotKeySlotRole, store: ClipboardStore? = nil) {
        let targetStore = store ?? .shared
        if recordingSlot == slot {
            stopRecording()
            return
        }
        stopRecording()

        boundStore = targetStore
        recordingSlot = slot
        conflictWarning = nil
        recordingHint = nil
        tapMachine.reset()
        HotKeyManager.shared.suspendForRecording()

        guard NSClassFromString("XCTestCase") == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handleEvent(event)
        }
    }

    func stopRecording() {
        let wasRecording = (recordingSlot != nil) || (localMonitor != nil)
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        tapMachine.reset()
        recordingSlot = nil
        conflictWarning = nil
        recordingHint = nil
        if wasRecording {
            HotKeyManager.shared.resumeAfterRecording()
        }
    }

    /// 供本地事件监听与单元测试直接驱动录制事件
    @discardableResult
    func handleEvent(_ event: NSEvent) -> NSEvent? {
        guard let role = recordingSlot else { return event }
        let store = boundStore ?? .shared

        if event.type == .flagsChanged {
            let outcome = tapMachine.handleFlagsChanged(
                keyCode: event.keyCode,
                flags: event.modifierFlags,
                uptime: ProcessInfo.processInfo.systemUptime
            )
            switch outcome {
            case .none:
                return nil
            case .firstTapCompleted(let kind):
                conflictWarning = nil
                recordingHint = "再按一次 \(kind.symbol) 设为「双击 \(kind.symbol)」，或按下组合键"
                return nil
            case .doubleTapTriggered(let kind):
                recordingHint = nil
                _ = commitCandidate(
                    .doubleTap(kind),
                    for: role,
                    in: store,
                    copyAppendEnabled: AdaptiveIntelligenceEngine.shared.copyAppendEnabled && !store.minimalModeEnabled
                )
                return nil
            }
        }

        tapMachine.markInterferingEvent()
        recordingHint = nil

        // ESC (53) 安全取消录制并立即恢复原有全局热键
        if event.keyCode == 53 {
            stopRecording()
            return nil
        }

        // 单独按下修饰键 keyDown 忽略
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if modifierKeyCodes.contains(event.keyCode) {
            return nil
        }

        let carbonMods = HotKeyShortcut.carbonModifiers(from: event.modifierFlags)
        let candidate = HotKeyShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods)
        _ = commitCandidate(
            candidate,
            for: role,
            in: store,
            copyAppendEnabled: AdaptiveIntelligenceEngine.shared.copyAppendEnabled && !store.minimalModeEnabled
        )
        return nil
    }

    /// 校验候选快捷键并写入目标槽位（返回精确结果供 UI 与单测断言）
    @discardableResult
    func commitCandidate(
        _ candidate: HotKeyShortcut,
        for role: HotKeySlotRole,
        in store: ClipboardStore,
        copyAppendEnabled: Bool
    ) -> RecordingOutcome {
        if let reason = HotKeyManager.shared.validateAndProbeShortcut(
            candidate,
            for: role,
            copyAppendEnabled: copyAppendEnabled
        ) {
            if NSClassFromString("XCTestCase") == nil {
                NSSound.beep()
            }
            conflictWarning = reason
            store.showToast(reason, duration: 3.0)
            return .rejected(reason)
        }

        switch role {
        case .screenshot:
            store.screenshotHotKeyShortcut = candidate
            store.showToast("截图快捷键已更新为 \(candidate.displayString)")
        default:
            store.hotKeyShortcut = candidate
            store.showToast("全局呼出快捷键已更新为 \(candidate.displayString)")
        }

        TactileFeedbackEngine.shared.perform(.tabSwitch)
        stopRecording()
        return .updated(candidate)
    }
}

// MARK: - 5. 跨窗口共享文件面板辅助（忽略应用 / 加密导出 / 竞品搬家）

@MainActor
enum ClipboardSettingsDialogHelper {
    static func pickAppToIgnore(store: ClipboardStore, suppressPanelAutoHide: ((Bool) -> Void)? = nil) {
        suppressPanelAutoHide?(true)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择要忽略剪贴记录的应用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        let response = panel.runModal()
        suppressPanelAutoHide?(false)

        guard response == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        store.addIgnoredApp(bundleIdentifier: bundleID, displayName: name)
    }

    static func exportPinnedArchive(store: ClipboardStore, suppressPanelAutoHide: ((Bool) -> Void)? = nil) {
        guard store.pinnedItemCount > 0 else {
            store.showToast("暂无已收藏的记录可导出")
            return
        }

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let defaultName = "iClip-收藏资产-\(df.string(from: Date())).iclip"

        suppressPanelAutoHide?(true)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出 iClip 收藏与模板归档"
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true
        if let iclipType = UTType(filenameExtension: "iclip", conformingTo: .json) {
            panel.allowedContentTypes = [iclipType]
        }

        let passField = ArchivePassphraseUIHelper.attachExportPassphraseAccessory(
            to: panel,
            sensitivePinnedCount: store.pinnedSensitiveItemCount
        )

        let response = panel.runModal()
        suppressPanelAutoHide?(false)

        guard response == .OK, var targetURL = panel.url else { return }
        if targetURL.pathExtension.isEmpty {
            targetURL = targetURL.appendingPathExtension("iclip")
        }
        let pw = passField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let count = try store.exportPinnedArchive(to: targetURL, passphrase: pw.isEmpty ? nil : pw)
            store.showToast(
                pw.isEmpty
                    ? "已导出 \(count) 条收藏至 \(targetURL.lastPathComponent)"
                    : "已口令加密导出 \(count) 条收藏（Mac/Win 互通）"
            )
        } catch {
            store.showToast(error.localizedDescription)
        }
    }

    static func importArchiveOrCompetitorFile(
        store: ClipboardStore,
        suppressPanelAutoHide: ((Bool) -> Void)? = nil,
        onFeedback: ((String) -> Void)? = nil
    ) {
        suppressPanelAutoHide?(true)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "导入 .iclip 或 Paste / Maccy / Raycast / Alfred / Clipy / Ditto / CSV 数据"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        var allowed: [UTType] = [.json, .commaSeparatedText, .tabSeparatedText, .plainText, .xml, .propertyList, .data]
        for ext in ["md", "markdown", "alfredsnippets", "alfredsnippet", "clipy", "dto"] {
            if let ut = UTType(filenameExtension: ext), !allowed.contains(ut) {
                allowed.append(ut)
            }
        }
        if let iclipType = UTType(filenameExtension: "iclip") {
            allowed.insert(iclipType, at: 0)
        }
        panel.allowedContentTypes = allowed

        let response = panel.runModal()
        suppressPanelAutoHide?(false)

        guard response == .OK, let sourceURL = panel.url else { return }
        do {
            let summary: ArchiveImportSummary
            do {
                summary = try store.importPinnedArchive(from: sourceURL, passphrase: nil)
            } catch ArchiveBackupError.passphraseRequiredOrIncorrect {
                suppressPanelAutoHide?(true)
                let entered = ArchivePassphraseUIHelper.promptImportPassphrase(for: sourceURL.lastPathComponent)
                suppressPanelAutoHide?(false)
                guard let pw = entered else { return }
                summary = try store.importPinnedArchive(from: sourceURL, passphrase: pw)
            }
            let catSuffix = summary.categoryBreakdown.map { "（\($0)）" } ?? ""
            let feedback = "✓ 已从\(summary.sourceFormatLabel)导入 \(summary.importedNewCount) 条\(catSuffix)"
            onFeedback?(feedback)
            if summary.importedNewCount > 0 && summary.updatedExistingCount > 0 {
                store.showToast("已从\(summary.sourceFormatLabel)迁入 \(summary.importedNewCount) 条\(catSuffix)，更新 \(summary.updatedExistingCount) 条")
            } else if summary.importedNewCount > 0 {
                store.showToast("已从\(summary.sourceFormatLabel)迁入 \(summary.importedNewCount) 条\(catSuffix)")
            } else if summary.updatedExistingCount > 0 {
                store.showToast("已合并更新 \(summary.updatedExistingCount) 条既有收藏")
            } else {
                store.showToast("\(summary.sourceFormatLabel)内 \(summary.totalInBundle) 条记录均已在本地存在")
            }
        } catch {
            store.showToast(error.localizedDescription)
        }
    }

    static func importFromLocalMaccy(
        store: ClipboardStore,
        onFeedback: ((String) -> Void)? = nil
    ) {
        Task.detached(priority: .userInitiated) {
            let parsed = UniversalCompetitorImporter.readLocalMaccyDatabaseCandidates()
            await MainActor.run {
                guard let parsed else {
                    store.showToast("开启完全磁盘访问或导出 Maccy 文件后即可一键导入", duration: 2.8)
                    return
                }
                let summary = store.mergeExternalCompetitorEntries(parsed.entries, formatLabel: parsed.formatName)
                let breakdown = summary.categoryBreakdown.map { "（\($0)）" } ?? ""
                let msg = "✓ 已从 Maccy 导入 \(summary.importedNewCount) 条新记录\(breakdown)"
                onFeedback?(msg)
                store.showToast(msg)
                TactileFeedbackEngine.shared.perform(.favoriteOn)
            }
        }
    }
}

// MARK: - 6. 全局独立窗口生命周期与零冲突仲裁中心

@MainActor
final class AppWindowCoordinator: ObservableObject {
    static let shared = AppWindowCoordinator()

    enum StandaloneWindowKind: Hashable {
        case permission
        case settings
        case onboarding
    }

    /// 当用户在当前会话主动点击「稍后再说」跳过独立权限弹窗时，避免反复弹框打扰
    @Published var hasDeferredPermissionGateThisSession: Bool = false
    /// 外观设置「皮肤 / 模糊浓度」调校时的真实剪贴板面板并排预览态
    @Published var isAppearanceLivePreviewActive: Bool = false

    /// 活跃独立窗口登记表（弱引用防止内存泄漏）
    private var registeredWindows: [StandaloneWindowKind: () -> NSWindow?] = [:]

    /// 由 AppDelegate / FloatingPanelController 注入的跨模块联动回调
    var onOpenMainPanel: ((_ tab: ClipFilterTab?, _ createTemplate: Bool) -> Void)?
    var onHideNonPinnedMainPanel: (() -> Void)?
    var onSuspendMainPanelKeyboardCapture: (() -> Void)?
    var onStandaloneWindowVisibilityChanged: ((_ anyVisible: Bool) -> Void)?
    var onShowAppearanceLivePreview: ((_ anchorFrame: NSRect) -> Void)?
    var onHideAppearanceLivePreview: (() -> Void)?

    private init() {}

    func registerWindowProvider(for kind: StandaloneWindowKind, provider: @escaping () -> NSWindow?) {
        registeredWindows[kind] = provider
    }

    /// 任一独立窗口（权限弹窗 / 独立设置 / 独立新手引导）当前是否可见
    var isAnyStandaloneWindowVisible: Bool {
        visibleStandaloneWindows.isEmpty == false
    }

    /// 任一独立窗口当前是否为 Key / Main 窗口，或正在录制热键（用于 FloatingPanelController 立即让出键盘拦截）
    var isAnyStandaloneWindowKeyOrActive: Bool {
        if HotKeyRecorderCoordinator.shared.isRecording {
            return true
        }
        return visibleStandaloneWindows.contains(where: { $0.isKeyWindow || $0.isMainWindow })
    }

    var visibleStandaloneWindows: [NSWindow] {
        registeredWindows.values.compactMap { $0() }.filter { $0.isVisible }
    }

    /// 判断屏幕坐标是否落在任一独立窗口内部（防止主面板外部点击监听误关或误抢焦）
    func standaloneWindowContains(screenPoint: NSPoint) -> Bool {
        visibleStandaloneWindows.contains { $0.frame.insetBy(dx: -6, dy: -6).contains(screenPoint) }
    }

    /// 纯函数：判断主悬浮面板的非激活 CGEventTap 是否必须向独立窗口/热键录制让路
    static func shouldMainPanelYieldKeyboardCapture(
        hasActiveStandaloneWindow: Bool,
        isRecordingSharedHotKey: Bool
    ) -> Bool {
        hasActiveStandaloneWindow || isRecordingSharedHotKey
    }

    /// 纯函数：根据独立窗口是否可见与用户是否置顶，计算主面板的目标窗口层级（防止置顶主面板遮挡独立设置/权限/引导窗，同时确保独立窗口绝不遮挡 macOS 系统设置）
    static func mainPanelLevel(alwaysOnTop: Bool, hasVisibleStandaloneWindow: Bool) -> NSWindow.Level {
        if hasVisibleStandaloneWindow {
            return .normal
        }
        return alwaysOnTop ? .statusBar : .floating
    }

    /// 任意独立窗口显隐变化时通知主悬浮面板同步层级与焦点让路
    func notifyStandaloneVisibilityChanged() {
        let anyVisible = isAnyStandaloneWindowVisible
        if anyVisible {
            onSuspendMainPanelKeyboardCapture?()
        }
        onStandaloneWindowVisibilityChanged?(anyVisible)
    }

    // MARK: - 统一调度入口

    func presentPermissionSetup(
        store: ClipboardStore? = nil,
        highlight: PermissionFocusKind? = nil,
        continueToOnboardingOnComplete: Bool = false
    ) {
        let targetStore = store ?? .shared
        HotKeyRecorderCoordinator.shared.stopRecording()
        onHideNonPinnedMainPanel?()
        onSuspendMainPanelKeyboardCapture?()
        PermissionSetupWindowController.shared.show(
            store: targetStore,
            highlight: highlight,
            continueToOnboardingOnComplete: continueToOnboardingOnComplete
        )
    }

    func presentSettings(
        section: SettingsSection = .appearance,
        store: ClipboardStore? = nil,
        checkUpdates: Bool = false
    ) {
        let targetStore = store ?? .shared
        onHideNonPinnedMainPanel?()
        onSuspendMainPanelKeyboardCapture?()
        SettingsWindowController.shared.show(
            store: targetStore,
            section: section,
            checkUpdates: checkUpdates
        )
    }

    func presentOnboarding(
        store: ClipboardStore? = nil,
        forceRestart: Bool = false
    ) {
        let targetStore = store ?? .shared
        HotKeyRecorderCoordinator.shared.stopRecording()
        onHideNonPinnedMainPanel?()
        onSuspendMainPanelKeyboardCapture?()
        OnboardingWindowController.shared.show(
            store: targetStore,
            forceRestart: forceRestart
        )
    }

    func openMainPanelFromStandalone(tab: ClipFilterTab? = nil, createTemplate: Bool = false) {
        HotKeyRecorderCoordinator.shared.stopRecording()
        onOpenMainPanel?(tab, createTemplate)
    }

    func showAppearanceLivePreview(besideSettingsWindow window: NSWindow? = nil) {
        let targetWin = window ?? registeredWindows[.settings]?()
        guard let frame = targetWin?.frame else { return }
        isAppearanceLivePreviewActive = true
        onShowAppearanceLivePreview?(frame)
    }

    func hideAppearanceLivePreview() {
        guard isAppearanceLivePreviewActive else { return }
        isAppearanceLivePreviewActive = false
        onHideAppearanceLivePreview?()
    }

    func dismissAllStandaloneWindows() {
        HotKeyRecorderCoordinator.shared.stopRecording()
        hideAppearanceLivePreview()
        PermissionSetupWindowController.shared.close()
        SettingsWindowController.shared.close()
        OnboardingWindowController.shared.close()
    }
}
