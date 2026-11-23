import Foundation
import AppKit
import Combine
import ImageIO
import CryptoKit
import ApplicationServices
import ServiceManagement

/// 隐私忽略来源应用条目
struct IgnoredAppEntry: Identifiable, Codable, Equatable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }

    static let defaults: [IgnoredAppEntry] = [
        IgnoredAppEntry(bundleIdentifier: "com.apple.keychainaccess", displayName: "钥匙串访问"),
        IgnoredAppEntry(bundleIdentifier: "com.apple.Passwords", displayName: "密码"),
        IgnoredAppEntry(bundleIdentifier: "com.1password.1password", displayName: "1Password"),
        IgnoredAppEntry(bundleIdentifier: "com.bitwarden.desktop", displayName: "Bitwarden")
    ]

    /// 仅返回当前这台 Mac 实际已安装的默认隐私保护应用，绝不展示本机不存在的工具
    static func installedDefaults() -> [IgnoredAppEntry] {
        defaults.filter { ClipboardStore.isAppAvailableOnSystem(bundleIdentifier: $0.bundleIdentifier) }
    }
}

/// 面板官方材质样式（精简为液态玻璃与毛玻璃两种）
enum PanelSurfaceStyle: String, CaseIterable, Identifiable {
    case liquidGlass
    case frosted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass: return "液态玻璃"
        case .frosted: return "毛玻璃"
        }
    }
}

/// 苹果官方 Liquid Glass 蒙版风格（对应系统外观中的透明 / 着色两档）
enum LiquidGlassAppearance: String, CaseIterable, Identifiable {
    case clear
    case tinted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear: return "透明"
        case .tinted: return "着色"
        }
    }
}

#if !ICLIP_EDITION_FLOW
/// NSCache 包装盒：缓存单条记录的语义识别快照
private final class SemanticSnapshotBox {
    let snapshot: SemanticSnapshot
    init(_ snapshot: SemanticSnapshot) {
        self.snapshot = snapshot
    }
}
#endif

#if ICLIP_EDITION_FLOW
/// 多选摘录合并拼接格式
enum MergeJoinStyle: String, CaseIterable, Identifiable {
    case paragraphs
    case numberedList
    case singleLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paragraphs: return "段落合并"
        case .numberedList: return "编号清单"
        case .singleLine: return "单行汇总"
        }
    }
}
#endif

#if ICLIP_EDITION_FLOW
private final class FinanceActionsBox {
    let actions: [FinanceQuickAction]
    init(_ actions: [FinanceQuickAction]) {
        self.actions = actions
    }
}
#endif

/// 跨处选段「续接复制（Copy-Append）」纯函数文本衔接器
enum CopyAppendHelper {
    static func joinSegments(base: String, incoming: String) -> String {
        let normalizedBase = base
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let normalizedIncoming = incoming
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if normalizedBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return incoming
        }
        if normalizedIncoming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return base
        }

        var cleanBase = normalizedBase
        while cleanBase.hasSuffix("\n") {
            cleanBase.removeLast()
        }
        var cleanIncoming = normalizedIncoming
        while cleanIncoming.hasPrefix("\n") {
            cleanIncoming.removeFirst()
        }
        return "\(cleanBase)\n\(cleanIncoming)"
    }

    static func extractAppendableText(from item: ClipItem) -> String? {
        if let t = item.text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return t
        }
        if let paths = item.filePaths, !paths.isEmpty {
            return paths.joined(separator: "\n")
        }
        if let qr = item.qrCodePayload, !qr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return qr
        }
        if let ocr = item.ocrText, !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ocr
        }
        return nil
    }
}

/// 剪贴板历史持久化自愈结果
enum HistoryLoadOutcome: Equatable {
    case emptyFreshInstall
    case loadedPrimary([ClipItem])
    case recoveredFromBackup([ClipItem])
    case corruptedUnrecoverable

    var items: [ClipItem] {
        switch self {
        case .loadedPrimary(let list), .recoveredFromBackup(let list):
            return list
        case .emptyFreshInstall, .corruptedUnrecoverable:
            return []
        }
    }
}

/// 剪贴板历史双模原子持久化与无主孤儿图片自洁辅助器
enum HistoryPersistenceHelper {
    /// 原子写入主快照，并在快照非空（或用户主动删除清空）时同步原子刷新备份快照
    static func writeSnapshot(
        _ items: [ClipItem],
        primaryURL: URL,
        backupURL: URL,
        allowEmptyBackup: Bool = false
    ) {
        guard let plainData = try? JSONEncoder().encode(items),
              let sealedData = LocalVaultCrypto.sealSnapshotData(plainData) else {
            return
        }
        do {
            try LocalVaultCrypto.writeProtectedFile(sealedData, to: primaryURL)
            if !items.isEmpty || allowEmptyBackup {
                try? LocalVaultCrypto.writeProtectedFile(sealedData, to: backupURL)
            }
        } catch {
            // 磁盘异常时不触碰既有 backupURL，保护最近一份完好快照
        }
    }

    /// 加载剪贴板历史：原生支持 `ICLPENC1` 钥匙串 AES-256-GCM 密文，兼容旧明文无缝静默升级，损坏时从备份无损自愈
    static func loadSnapshot(
        primaryURL: URL,
        backupURL: URL,
        corruptURL: URL
    ) -> HistoryLoadOutcome {
        let fm = FileManager.default
        let primaryExists = fm.fileExists(atPath: primaryURL.path)
        let backupExists = fm.fileExists(atPath: backupURL.path)

        if primaryExists {
            if let raw = try? Data(contentsOf: primaryURL),
               let opened = LocalVaultCrypto.openSnapshotData(raw),
               let decoded = try? JSONDecoder().decode([ClipItem].self, from: opened.plainData) {
                if opened.wasLegacyPlaintext || (!decoded.isEmpty && !backupExists) {
                    writeSnapshot(decoded, primaryURL: primaryURL, backupURL: backupURL, allowEmptyBackup: true)
                }
                return .loadedPrimary(decoded)
            }
            try? fm.removeItem(at: corruptURL)
            try? fm.moveItem(at: primaryURL, to: corruptURL)
        }

        if backupExists,
           let backupRaw = try? Data(contentsOf: backupURL),
           let openedBackup = LocalVaultCrypto.openSnapshotData(backupRaw),
           let recovered = try? JSONDecoder().decode([ClipItem].self, from: openedBackup.plainData) {
            writeSnapshot(recovered, primaryURL: primaryURL, backupURL: backupURL, allowEmptyBackup: true)
            return .recoveredFromBackup(recovered)
        }

        return primaryExists ? .corruptedUnrecoverable : .emptyFreshInstall
    }

    /// 扫描 images 目录并安全清理无任何历史记录引用的陈旧孤儿图片（保护 minimumAgeSeconds 内的新写入图片）
    @discardableResult
    static func pruneOrphanedImages(
        in imagesDirectoryURL: URL,
        referencedFileNames: Set<String>,
        minimumAgeSeconds: TimeInterval = 60,
        now: Date = Date()
    ) -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: imagesDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "webp", "heic"]
        var removedCount = 0
        for fileURL in urls {
            let ext = fileURL.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            let name = fileURL.lastPathComponent
            guard !referencedFileNames.contains(name) else { continue }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey])
            guard values?.isRegularFile == true else { continue }
            if let modified = values?.contentModificationDate ?? values?.creationDate,
               now.timeIntervalSince(modified) < minimumAgeSeconds {
                continue
            }
            if (try? fm.removeItem(at: fileURL)) != nil {
                removedCount += 1
            }
        }
        return removedCount
    }

    /// 清理应用数据根目录在异常断电/热重启时偶发残留的 Foundation 原子写入临时文件（如 history.json.sb-*）
    @discardableResult
    static func pruneStaleAtomicTempFiles(
        in appSupportDirectoryURL: URL,
        minimumAgeSeconds: TimeInterval = 300,
        now: Date = Date()
    ) -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: appSupportDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: []
        ) else {
            return 0
        }
        var removed = 0
        for url in urls {
            let name = url.lastPathComponent
            guard name.contains(".sb-") else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            if let modified = values?.contentModificationDate,
               now.timeIntervalSince(modified) < minimumAgeSeconds {
                continue
            }
            if (try? fm.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}

/// 剪贴板核心管理与持久化服务（支持极客开发版 / 心流办公版编译期隔离与跨版本无损存储）
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var isAccessibilityGranted: Bool = false
    @Published var isPaused: Bool = false {
        didSet {
            if !isPaused {
                pauseResumeWorkItem?.cancel()
                pauseResumeWorkItem = nil
                pauseAutoResumeAt = nil
            }
        }
    }
    /// 定时无痕暂停的自动恢复时间点（nil 表示未开启倒计时或处于手动持续暂停）
    @Published private(set) var pauseAutoResumeAt: Date? = nil
    private var pauseResumeWorkItem: DispatchWorkItem? = nil

    /// 用户选择的目标角色版本（决定专属 OTA 更新轨道与跨角色热切换）
    @Published private(set) var targetRoleEdition: AppRoleEdition
    /// 是否已完成首次角色版本确认引导
    @Published var hasConfirmedRoleEdition: Bool {
        didSet { UserDefaults.standard.set(hasConfirmedRoleEdition, forKey: "hasConfirmedRoleEdition") }
    }
    /// 极简纯净模式（基础功能版）：开启后隐藏全部行业进阶栏与徽标，并静默停止后台 OCR/语义扫描
    @Published var minimalModeEnabled: Bool {
        didSet { UserDefaults.standard.set(minimalModeEnabled, forKey: "minimalModeEnabled") }
    }
    /// 窗口「始终在前（Always on Top）」：开启后悬浮面板固定置顶，切窗口或连续粘贴均不自动收起（⌘P）
    @Published var alwaysOnTop: Bool {
        didSet { UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop") }
    }

    @Published var surfaceStyle: PanelSurfaceStyle {
        didSet { UserDefaults.standard.set(surfaceStyle.rawValue, forKey: "panelSurfaceStyle") }
    }
    @Published var liquidGlassAppearance: LiquidGlassAppearance {
        didSet { UserDefaults.standard.set(liquidGlassAppearance.rawValue, forKey: "liquidGlassAppearance") }
    }
    /// 液态玻璃背景模糊浓度（0.0 清透透镜 ~ 1.0 浓厚柔焦，联动调整卡片衬底对比度）
    @Published var liquidGlassMaskOpacity: Double {
        didSet {
            let derived: LiquidGlassAppearance = (liquidGlassMaskOpacity < 0.35) ? .clear : .tinted
            if liquidGlassAppearance != derived {
                liquidGlassAppearance = derived
            }
            scheduleSaveAppearanceDefaults()
        }
    }
    @Published var borderlessPanel: Bool {
        didSet { UserDefaults.standard.set(borderlessPanel, forKey: "borderlessPanel") }
    }
    @Published var autoPasteEnabled: Bool {
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled") }
    }
    /// 交互微音效开关（关闭后静默无声，但仍保留细腻触控板震动）
    @Published var soundEffectsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEffectsEnabled, forKey: TactileFeedbackEngine.soundEnabledDefaultsKey)
            if soundEffectsEnabled {
                TactileFeedbackEngine.shared.perform(.favoriteOn)
            } else {
                TactileFeedbackEngine.shared.performNavigationStepHaptic()
            }
        }
    }
    /// 一次性验证码（OTP）粘贴后 30 秒自动无痕销毁（极简模式或已固定条目不生效）
    @Published var autoExpireOTP: Bool {
        didSet { UserDefaults.standard.set(autoExpireOTP, forKey: "autoExpireOTP") }
    }
    /// 投屏与录屏隐身护盾（开启后 Zoom/腾讯会议/飞书共享屏幕及录屏画面中自动隐藏 iClip 面板，本机屏幕正常可见）
    @Published var screenSharePrivacyEnabled: Bool {
        didSet { UserDefaults.standard.set(screenSharePrivacyEnabled, forKey: "screenSharePrivacyEnabled") }
    }
    /// 列表敏感凭据防肩窥遮罩（开启后未选中/未悬停的 API Key、私钥、Token 默认圆点雾化，选中即刻原位显影）
    @Published var maskSensitivePreviews: Bool {
        didSet { UserDefaults.standard.set(maskSensitivePreviews, forKey: "maskSensitivePreviews") }
    }
    /// 密码剪贴板残留自动擦除（检测到 1Password / 系统密码等复制密码后，60 秒未变动自动清空系统剪贴板残留明文）
    @Published var autoClearConcealedPasteboard: Bool {
        didSet { UserDefaults.standard.set(autoClearConcealedPasteboard, forKey: "autoClearConcealedPasteboard") }
    }
    /// 未收藏敏感凭据 24 小时自动无痕销毁（收藏记录与未完成待办永久保护）
    @Published var autoExpireUnpinnedSecrets: Bool {
        didSet {
            UserDefaults.standard.set(autoExpireUnpinnedSecrets, forKey: "autoExpireUnpinnedSecrets")
            if autoExpireUnpinnedSecrets {
                _ = purgeExpiredUnpinnedSecrets()
            }
        }
    }
    @Published private(set) var launchAtLoginEnabled: Bool = false
    @Published var hotKeyShortcut: HotKeyShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(hotKeyShortcut) {
                UserDefaults.standard.set(data, forKey: "hotKeyShortcut")
            }
            _ = HotKeyManager.shared.updateShortcut(hotKeyShortcut)
        }
    }

    #if !ICLIP_EDITION_FLOW
    /// [极客开发版] 复制含营销追踪尾巴的链接时自动净链
    @Published var autoCleanTrackingURL: Bool {
        didSet { UserDefaults.standard.set(autoCleanTrackingURL, forKey: "autoCleanTrackingURL") }
    }
    /// [极客开发版] 粘贴含敏感凭据条目时默认自动掩码脱敏守护（按 ⌥↵ 才贴明文）
    @Published var autoRedactOnPaste: Bool {
        didSet { UserDefaults.standard.set(autoRedactOnPaste, forKey: "autoRedactOnPaste") }
    }
    #endif

    #if ICLIP_EDITION_FLOW
    /// [心流办公版] FIFO 顺序粘贴队列采集开关
    @Published var isQueueModeActive: Bool = false
    /// [心流办公版] 待顺序吐出的记录 ID 队列
    @Published private(set) var pasteQueueIDs: [UUID] = []
    /// [心流办公版] 待合并粘贴的有序勾选记录 ID 列表
    @Published private(set) var selectedMergeIDs: [UUID] = []
    /// [心流办公版] 免开面板直接按 FIFO 吐出队列下一项的全局快捷键（默认 ⌃⌥V）
    @Published var queuePopShortcut: HotKeyShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(queuePopShortcut) {
                UserDefaults.standard.set(data, forKey: "queuePopShortcut")
            }
            _ = HotKeyManager.shared.updateQueueShortcut(queuePopShortcut)
        }
    }
    /// [心流办公版] 顺序出队键入后是否自动按下 Tab 跳到下一个表单输入框
    @Published var queueAutoTabEnabled: Bool {
        didSet { UserDefaults.standard.set(queueAutoTabEnabled, forKey: "queueAutoTabEnabled") }
    }
    #endif

    @Published private(set) var ignoredApps: [IgnoredAppEntry] = []
    private var ignoredBundleIDSet: Set<String> = []
    @Published var maxHistoryCount: Int {
        didSet {
            UserDefaults.standard.set(maxHistoryCount, forKey: "maxHistoryCount")
            trimHistoryIfNeeded()
        }
    }
    @Published var toastMessage: String? = nil
    /// 当前外部目标窗口应用名（即唤起面板或钉住面板即将粘贴的目标应用，供情境心智引擎学习与置顶）
    @Published var activeTargetAppName: String? = nil
    /// 是否存在处于 8 秒保护窗口内可按 ⌘Z 恢复的最近一次删除/清空快照
    @Published private(set) var canUndoLastDeletion: Bool = false
    /// 在外部浏览器直接打开链接后通知悬浮窗丝滑收起（不抢回原应用焦点）
    var onAfterOpenExternalURL: (() -> Void)? = nil

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private var isPollingFastMode: Bool = true
    private var lastActivityUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var ignoreNextChangeCount: Int?

    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let previewCache = NSCache<NSString, NSImage>()
    private let fileIconCache = NSCache<NSString, NSImage>()
    #if !ICLIP_EDITION_FLOW
    private let semanticCache = NSCache<NSString, SemanticSnapshotBox>()
    #else
    private let financeCache = NSCache<NSString, FinanceActionsBox>()
    #endif
    private var inFlightThumbnails = Set<String>()
    private var inFlightPreviews = Set<String>()

    private var toastWorkItem: DispatchWorkItem?
    private var saveWorkItem: DispatchWorkItem?
    private var appearanceSaveWorkItem: DispatchWorkItem?
    private var cacheTrimWorkItem: DispatchWorkItem?
    private var pendingOTPExpirationTasks: [UUID: DispatchWorkItem] = [:]
    private var concealedScrubWorkItem: DispatchWorkItem? = nil
    private var sourceAppDeleteStreaks: [String: (name: String, count: Int, lastAt: TimeInterval)] = [:]
    private var undoRemovedItems: [ClipItem] = []
    private var undoPurgeWorkItem: DispatchWorkItem?
    private var copyAppendTargetID: UUID? = nil
    private var copyAppendSegmentCount: Int = 1
    private var pendingCopyAppendBaseText: String? = nil
    private var pendingCopyAppendDeadlineUptime: TimeInterval = -100
    private var adaptiveCancellable: AnyCancellable?
    private let diskQueue = DispatchQueue(label: "com.qingjian.clipboard.disk", qos: .utility)

    private let appSupportURL: URL
    private let historyFileURL: URL
    private let historyBackupFileURL: URL
    private let historyCorruptFileURL: URL
    private let imagesDirectoryURL: URL

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.appSupportURL = base.appendingPathComponent("QingJian", isDirectory: true)
        self.historyFileURL = appSupportURL.appendingPathComponent("history.json")
        self.historyBackupFileURL = appSupportURL.appendingPathComponent("history.backup.json")
        self.historyCorruptFileURL = appSupportURL.appendingPathComponent("history.corrupt.json")
        self.imagesDirectoryURL = appSupportURL.appendingPathComponent("images", isDirectory: true)

        let installed = AppRoleEdition.installed
        let lastLaunchedEdition = UserDefaults.standard.string(forKey: "lastLaunchedBundleEdition")
        if lastLaunchedEdition != installed.rawValue {
            // 检测到客户端角色二进制发生切换（OTA 完成或手动覆盖安装），自动将目标角色与当前新二进制对齐
            self.targetRoleEdition = installed
            UserDefaults.standard.set(installed.rawValue, forKey: "targetRoleEdition")
            UserDefaults.standard.set(installed.rawValue, forKey: "lastLaunchedBundleEdition")
        } else if let savedRole = UserDefaults.standard.string(forKey: "targetRoleEdition"),
                  let parsedRole = AppRoleEdition(rawValue: savedRole) {
            self.targetRoleEdition = parsedRole
        } else {
            self.targetRoleEdition = installed
        }
        self.hasConfirmedRoleEdition = UserDefaults.standard.bool(forKey: "hasConfirmedRoleEdition")
        self.minimalModeEnabled = UserDefaults.standard.bool(forKey: "minimalModeEnabled")
        self.alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")

        self.autoPasteEnabled = true
        self.soundEffectsEnabled = UserDefaults.standard.object(forKey: TactileFeedbackEngine.soundEnabledDefaultsKey) as? Bool ?? true
        self.autoExpireOTP = UserDefaults.standard.object(forKey: "autoExpireOTP") as? Bool ?? true
        self.screenSharePrivacyEnabled = UserDefaults.standard.object(forKey: "screenSharePrivacyEnabled") as? Bool ?? true
        self.maskSensitivePreviews = UserDefaults.standard.object(forKey: "maskSensitivePreviews") as? Bool ?? true
        self.autoClearConcealedPasteboard = UserDefaults.standard.object(forKey: "autoClearConcealedPasteboard") as? Bool ?? true
        self.autoExpireUnpinnedSecrets = UserDefaults.standard.object(forKey: "autoExpireUnpinnedSecrets") as? Bool ?? true
        // 统一既定视觉风格：默认固定原生液态玻璃与纯净无分割线布局，仅暴露单一「背景模糊浓度」调节
        self.surfaceStyle = .liquidGlass
        let savedMask = UserDefaults.standard.object(forKey: "liquidGlassMaskOpacity") as? Double
        let clampedBlur = min(max(savedMask ?? 0.45, 0.0), 1.0)
        self.liquidGlassMaskOpacity = clampedBlur
        self.liquidGlassAppearance = (clampedBlur < 0.35) ? .clear : .tinted
        self.borderlessPanel = true

        if let shortcutData = UserDefaults.standard.data(forKey: "hotKeyShortcut"),
           let decodedShortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: shortcutData) {
            self.hotKeyShortcut = decodedShortcut
        } else {
            self.hotKeyShortcut = .defaultShortcut
        }

        #if !ICLIP_EDITION_FLOW
        self.autoCleanTrackingURL = UserDefaults.standard.object(forKey: "autoCleanTrackingURL") as? Bool ?? false
        self.autoRedactOnPaste = UserDefaults.standard.object(forKey: "autoRedactOnPaste") as? Bool ?? false
        self.semanticCache.countLimit = 256
        #endif

        #if ICLIP_EDITION_FLOW
        if let qShortcutData = UserDefaults.standard.data(forKey: "queuePopShortcut"),
           let decodedQShortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: qShortcutData) {
            self.queuePopShortcut = decodedQShortcut
        } else {
            self.queuePopShortcut = .defaultQueueShortcut
        }
        self.queueAutoTabEnabled = UserDefaults.standard.object(forKey: "queueAutoTabEnabled") as? Bool ?? false
        self.financeCache.countLimit = 256
        #endif

        let savedMax = UserDefaults.standard.integer(forKey: "maxHistoryCount")
        self.maxHistoryCount = savedMax > 0 ? savedMax : 200
        self.lastChangeCount = pasteboard.changeCount
        self.isAccessibilityGranted = AXIsProcessTrusted()
        self.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)

        if let ignoredData = UserDefaults.standard.data(forKey: "ignoredApps"),
           let decodedIgnored = try? JSONDecoder().decode([IgnoredAppEntry].self, from: ignoredData) {
            let filtered = decodedIgnored.filter { Self.isAppAvailableOnSystem(bundleIdentifier: $0.bundleIdentifier) }
            self.ignoredApps = filtered
            if filtered.count != decodedIgnored.count,
               let cleanData = try? JSONEncoder().encode(filtered) {
                UserDefaults.standard.set(cleanData, forKey: "ignoredApps")
            }
        } else {
            self.ignoredApps = IgnoredAppEntry.installedDefaults()
        }
        self.ignoredBundleIDSet = Set(self.ignoredApps.map(\.bundleIdentifier))

        thumbnailCache.countLimit = 80
        thumbnailCache.totalCostLimit = 24 * 1024 * 1024
        previewCache.countLimit = 12
        previewCache.totalCostLimit = 36 * 1024 * 1024
        fileIconCache.countLimit = 128

        adaptiveCancellable = AdaptiveIntelligenceEngine.shared.$revision
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                #if !ICLIP_EDITION_FLOW
                self.semanticCache.removeAllObjects()
                #else
                self.financeCache.removeAllObjects()
                #endif
            }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibilityStatus()
                self?.bumpPollingActivity()
            }
        }

        // 屏幕休眠期间完全卸载定时器实现 0.00% CPU 零唤醒；唤醒后立即恢复监听
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timer?.invalidate()
                self?.timer = nil
            }
        }
        wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bumpPollingActivity()
                self.checkPasteboard()
            }
        }

        ensureDirectories()
        loadHistory()
        archiveExpiredCompletedTodos()
        startMonitoring()
        scheduleOrphanedImageCleanup()
        if !minimalModeEnabled {
            scheduleLegacyOCRBackfill()
        }
    }

    func toggleMinimalMode() {
        minimalModeEnabled.toggle()
        if minimalModeEnabled {
            ActionSparkController.shared.dismissImmediately()
        }
        TactileFeedbackEngine.shared.perform(.tabSwitch)
        showToast(minimalModeEnabled ? "已开启极简纯净模式（基础功能版）" : "已恢复「\(AppRoleEdition.installed.title)」进阶功能")
    }

    /// 切换窗口「始终在前（Always on Top）」（⌘P）
    func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        TactileFeedbackEngine.shared.perform(alwaysOnTop ? .favoriteOn : .favoriteOff)
        showToast(alwaysOnTop ? "已钉住窗口：始终在前（⌘P 取消）" : "已取消窗口始终在前")
    }

    /// 读取「始终在前」模式下用户手动拖动摆放的专属桌面工位坐标
    var savedPinnedPanelOrigin: NSPoint? {
        guard UserDefaults.standard.object(forKey: "pinnedPanelOriginX") != nil,
              UserDefaults.standard.object(forKey: "pinnedPanelOriginY") != nil else {
            return nil
        }
        let x = UserDefaults.standard.double(forKey: "pinnedPanelOriginX")
        let y = UserDefaults.standard.double(forKey: "pinnedPanelOriginY")
        return NSPoint(x: x, y: y)
    }

    func savePinnedPanelOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: "pinnedPanelOriginX")
        UserDefaults.standard.set(Double(origin.y), forKey: "pinnedPanelOriginY")
    }

    /// 执行来自光标角「灵动微星标（Action Spark）」的一键动作（转换结果写入剪贴板，供用户随时 ⌘V 粘贴）
    func executeSparkCandidate(_ candidate: AdaptiveSparkCandidate) {
        switch candidate.payload {
        case .replaceClipboardText(let text, let htmlTable, _):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if let htmlTable {
                pasteboard.setString(text, forType: .tabularText)
                pasteboard.setString(htmlTable, forType: .html)
            }
            let forceSecret = (candidate.actionID == "img-totp-code")
            let scrubSec: TimeInterval = forceSecret ? 30.0 : 45.0
            commitOutboundPasteboardGuard(for: text, forceProtected: forceSecret, isPinnedSource: false, scrubDelay: scrubSec)
            TactileFeedbackEngine.shared.perform(.magicTransform)

        case .compressImage(let itemID):
            if let target = items.first(where: { $0.id == itemID }) {
                TactileFeedbackEngine.shared.perform(.magicTransform)
                pasteCompressedJPEG(for: target, shouldAutoPaste: false, onBeforePaste: nil)
            }

        case .mockupImage(let itemID):
            if let target = items.first(where: { $0.id == itemID }) {
                TactileFeedbackEngine.shared.perform(.magicTransform)
                pasteAppleMockupImage(for: target, shouldAutoPaste: false, onBeforePaste: nil)
            }

        case .extractImageOCR(let itemID):
            if let target = items.first(where: { $0.id == itemID }) {
                TactileFeedbackEngine.shared.perform(.magicTransform)
                pasteExtractedOCRText(for: target, shouldAutoPaste: false, onBeforePaste: nil)
            }

        case .pinFrequentItem(let itemID):
            if let target = items.first(where: { $0.id == itemID }), !target.isPinned {
                togglePin(target)
            }

        case .markAsTodo(let itemID):
            if let target = items.first(where: { $0.id == itemID }), !target.isTodo {
                toggleTodo(target)
            }

        case .splitChecklistIntoTodos(let itemID):
            if let target = items.first(where: { $0.id == itemID }) {
                _ = splitChecklistIntoTodos(from: target)
            }
        }
    }

    // MARK: - 角色选择与差异化 OTA 通道联动

    func selectRoleEdition(_ edition: AppRoleEdition) {
        targetRoleEdition = edition
        hasConfirmedRoleEdition = true
        UserDefaults.standard.set(edition.rawValue, forKey: "targetRoleEdition")

        if edition != AppRoleEdition.installed {
            showToast("已选「\(edition.title)」，正在获取专属 OTA 包...")
            UpdateManager.shared.checkForUpdates(targetEdition: edition, silent: false)
        } else {
            showToast("当前正运行「\(edition.title)」")
            UpdateManager.shared.checkForUpdates(targetEdition: edition, silent: true)
        }
    }

    // MARK: - 目录与防抖串行持久化

    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupportURL.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imagesDirectoryURL.path)
        let localOTA = appSupportURL.appendingPathComponent("LocalOTA", isDirectory: true)
        if fm.fileExists(atPath: localOTA.path) {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: localOTA.path)
        }
    }

    // MARK: - 定时无痕隐私护盾（默认 15 分钟到点自动恢复，彻底解决「暂停后忘开」痛点）

    func pauseCapture(forMinutes minutes: Int? = 15) {
        pauseResumeWorkItem?.cancel()
        pauseResumeWorkItem = nil
        lastChangeCount = pasteboard.changeCount

        if let mins = minutes, mins > 0 {
            let clamped = min(max(mins, 1), 480)
            let resumeDate = Date().addingTimeInterval(TimeInterval(clamped * 60))
            isPaused = true
            pauseAutoResumeAt = resumeDate
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isPaused else { return }
                self.resumeCapture(silent: true)
            }
            pauseResumeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(clamped * 60), execute: work)
        } else {
            pauseAutoResumeAt = nil
            isPaused = true
        }
    }

    func resumeCapture(silent: Bool = false) {
        pauseResumeWorkItem?.cancel()
        pauseResumeWorkItem = nil
        pauseAutoResumeAt = nil
        lastChangeCount = pasteboard.changeCount
        if isPaused {
            isPaused = false
        }
        if !silent {
            showToast("已恢复记录剪贴板")
        }
    }

    func toggleTimedPause(defaultMinutes: Int = 15) {
        if isPaused {
            resumeCapture(silent: false)
        } else {
            pauseCapture(forMinutes: defaultMinutes)
            showToast("已开启 \(defaultMinutes) 分钟无痕暂停（到点自动恢复）")
        }
    }

    var pauseStatusSummary: String {
        guard isPaused else { return "开启无痕暂停（默认 15 分钟自动恢复）" }
        if let deadline = pauseAutoResumeAt {
            let remainSec = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
            if remainSec > 0 {
                let remainMin = max(1, Int(ceil(Double(remainSec) / 60.0)))
                return "无痕暂停中（约 \(remainMin) 分钟后自动恢复 · 点击立即恢复）"
            }
        }
        return "已持续暂停记录（点击恢复）"
    }

    private func loadHistory() {
        let outcome = HistoryPersistenceHelper.loadSnapshot(
            primaryURL: historyFileURL,
            backupURL: historyBackupFileURL,
            corruptURL: historyCorruptFileURL
        )
        self.items = sortItems(outcome.items)
        _ = purgeExpiredUnpinnedSecrets()
        if case .recoveredFromBackup(let recovered) = outcome, !recovered.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showToast("已从原子备份自动恢复 \(recovered.count) 条历史记录", duration: 3.0)
            }
        }
    }

    /// 清理超过指定存活窗口（默认 24 小时）的未收藏、非待办高敏凭据（API Key / 私钥 / 连接密码 / 身份证 / 银行卡 / 含敏截图）
    @discardableResult
    func purgeExpiredUnpinnedSecrets(now: Date = Date(), maxAgeSeconds: TimeInterval = 86_400) -> Int {
        guard autoExpireUnpinnedSecrets, !minimalModeEnabled else { return 0 }
        var kept: [ClipItem] = []
        kept.reserveCapacity(items.count)
        var purged: [ClipItem] = []

        for item in items {
            let isProtected = item.isPinned || item.isPendingTodo
            if !isProtected,
               item.detectedSensitiveKind != nil,
               now.timeIntervalSince(item.createdAt) >= maxAgeSeconds {
                purged.append(item)
            } else {
                kept.append(item)
            }
        }

        guard !purged.isEmpty else { return 0 }
        items = kept
        let activeHashes = Set(items.map(\.contentHash))
        let deadHashes = Set(purged.map(\.contentHash)).subtracting(activeHashes)
        AdaptiveIntelligenceEngine.shared.forgetContentHashes(deadHashes)
        for dead in purged {
            pendingOTPExpirationTasks[dead.id]?.cancel()
            pendingOTPExpirationTasks.removeValue(forKey: dead.id)
            evictItemMemoryCaches(for: dead)
            DragFileExportHelper.purgeExportedFiles(for: dead)
            deleteImageFileIfNeeded(for: dead)
        }
        saveHistory()
        return purged.count
    }

    private static func isUnpinnedSecurityOrPoisonRisk(_ item: ClipItem) -> Bool {
        if item.isPinned || item.isPendingTodo { return false }
        if item.detectedSensitiveKind != nil || item.isBurnAfterPaste || item.detectedLinkRisk != nil {
            return true
        }
        if case .pastejackingOrBidi = item.detectedPoisonThreat {
            return true
        }
        return false
    }

    /// 当前历史库中未收藏、非待办的高敏凭据、投毒风险与粘贴即焚项总数（支撑 `@敏感` 与 `@体检`）
    var unpinnedSensitiveCount: Int {
        items.reduce(0) { acc, item in
            Self.isUnpinnedSecurityOrPoisonRisk(item) ? (acc + 1) : acc
        }
    }

    var securityPostureReport: SecurityPostureAudit.Report {
        SecurityPostureAudit.Report(
            totalEncryptedItems: items.count,
            pinnedProtectedSecrets: pinnedSensitiveItemCount,
            unpinnedRiskCount: unpinnedSensitiveCount,
            screenStealthEnabled: screenSharePrivacyEnabled,
            shoulderSurfVeilEnabled: maskSensitivePreviews
        )
    }

    /// 一键无痕清扫所有未收藏、非待办的敏感凭据、隐藏控制符投毒、钓鱼风险与粘贴即焚残留（收藏项永久豁免）
    @discardableResult
    func sweepAllUnpinnedSensitiveItems() -> Int {
        var kept: [ClipItem] = []
        var removed: [ClipItem] = []
        let currentPBString = pasteboard.string(forType: .string)

        for item in items {
            if Self.isUnpinnedSecurityOrPoisonRisk(item) {
                removed.append(item)
            } else {
                kept.append(item)
            }
        }
        guard !removed.isEmpty else { return 0 }

        items = kept
        let activeHashes = Set(items.map(\.contentHash))
        let deadHashes = Set(removed.map(\.contentHash)).subtracting(activeHashes)
        AdaptiveIntelligenceEngine.shared.forgetContentHashes(deadHashes)
        var shouldScrubPasteboard = false
        for dead in removed {
            pendingOTPExpirationTasks[dead.id]?.cancel()
            pendingOTPExpirationTasks.removeValue(forKey: dead.id)
            evictItemMemoryCaches(for: dead)
            DragFileExportHelper.purgeExportedFiles(for: dead)
            if let cur = currentPBString, let raw = dead.text, cur == raw {
                shouldScrubPasteboard = true
            }
            deleteImageFileIfNeeded(for: dead)
        }
        if shouldScrubPasteboard {
            pasteboard.clearContents()
            ignoreNextChangeCount = pasteboard.changeCount
            lastChangeCount = pasteboard.changeCount
        }
        saveHistory()
        TactileFeedbackEngine.shared.perform(.magicTransform)
        showToast("已无痕清扫 \(removed.count) 条未收藏敏感记录")
        return removed.count
    }

    /// 启动 5 秒后在后台低优串行队列静默加密存量明文图片并清理无主孤儿图片
    private func scheduleOrphanedImageCleanup() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self else { return }
            _ = self.purgeExpiredUnpinnedSecrets()
            let referenced = Set((self.items + self.undoRemovedItems).compactMap(\.imageFileName))
            let imagesDir = self.imagesDirectoryURL
            let rootDir = self.appSupportURL
            self.diskQueue.async {
                _ = LocalVaultCrypto.upgradePlainImagesInDirectoryIfNeeded(imagesDir)
                _ = HistoryPersistenceHelper.pruneOrphanedImages(
                    in: imagesDir,
                    referencedFileNames: referenced,
                    minimumAgeSeconds: 60
                )
                _ = HistoryPersistenceHelper.pruneStaleAtomicTempFiles(
                    in: rootDir,
                    minimumAgeSeconds: 300
                )
            }
        }
    }

    private func scheduleSaveAppearanceDefaults() {
        appearanceSaveWorkItem?.cancel()
        let value = liquidGlassMaskOpacity
        let work = DispatchWorkItem {
            UserDefaults.standard.set(value, forKey: "liquidGlassMaskOpacity")
        }
        appearanceSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func saveHistory(immediate: Bool = false, allowEmptyBackup: Bool = false) {
        saveWorkItem?.cancel()
        let snapshot = self.items
        let targetURL = self.historyFileURL
        let backupURL = self.historyBackupFileURL

        let work = DispatchWorkItem { [diskQueue] in
            diskQueue.async {
                HistoryPersistenceHelper.writeSnapshot(
                    snapshot,
                    primaryURL: targetURL,
                    backupURL: backupURL,
                    allowEmptyBackup: allowEmptyBackup
                )
            }
        }

        if immediate {
            work.perform()
        } else {
            saveWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func sortItems(_ list: [ClipItem]) -> [ClipItem] {
        list.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
    }

    // MARK: - 自适应双档低功耗剪贴板监听（活跃 0.45s 极速嗅探 / 静默 1.2s 内核合并省电）

    func startMonitoring(fastMode: Bool = true) {
        timer?.invalidate()
        isPollingFastMode = fastMode
        let interval: TimeInterval = fastMode ? 0.45 : 1.20
        let tolerance: TimeInterval = fastMode ? 0.12 : 0.50
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboard()
            }
        }
        t.tolerance = tolerance
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func bumpPollingActivity() {
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        if timer == nil || !isPollingFastMode {
            startMonitoring(fastMode: true)
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        DragFileExportHelper.wipeAllExports()
        saveHistory(immediate: true)
    }

    func onPanelShown(visibleItems: [ClipItem]) {
        cacheTrimWorkItem?.cancel()
        cacheTrimWorkItem = nil
        archiveExpiredCompletedTodos()
        bumpPollingActivity()
        refreshAccessibilityStatus()
        thumbnailCache.countLimit = 80
        thumbnailCache.totalCostLimit = 24 * 1024 * 1024
        prewarmThumbnails(for: visibleItems, limit: 18)
        prewarmPreviewImages(for: visibleItems, limit: 6)
        #if !ICLIP_EDITION_FLOW
        if !minimalModeEnabled {
            for item in visibleItems.prefix(24) where item.type == .text || item.type == .link {
                _ = semanticSnapshot(for: item)
            }
        }
        #endif
    }

    func onPanelHidden() {
        cacheTrimWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewCache.removeAllObjects()
            // 后台常驻期自动收缩缩略图缓存预算至 6 MB，呼出面板时毫秒级预热恢复
            self.thumbnailCache.countLimit = 16
            self.thumbnailCache.totalCostLimit = 6 * 1024 * 1024
        }
        cacheTrimWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)
    }

    private func checkPasteboard() {
        if isPaused, let deadline = pauseAutoResumeAt, Date() >= deadline {
            resumeCapture(silent: true)
        }
        guard !isPaused else {
            lastChangeCount = pasteboard.changeCount
            return
        }

        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else {
            // 连续 30 秒无剪贴板变更时自动退避至低功耗巡航档
            if isPollingFastMode && (ProcessInfo.processInfo.systemUptime - lastActivityUptime) > 30.0 {
                startMonitoring(fastMode: false)
            }
            return
        }
        lastChangeCount = currentCount
        bumpPollingActivity()

        if let ignored = ignoreNextChangeCount, ignored == currentCount {
            ignoreNextChangeCount = nil
            return
        }

        let types = pasteboard.types ?? []
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontBundleID = frontApp?.bundleIdentifier
        let sourcePB = PasteboardPrivacyStandards.extractSourceBundleID(from: pasteboard)

        switch PasteboardPrivacyStandards.inspect(
            types: types,
            sourceBundleIDFromPasteboard: sourcePB,
            frontmostBundleID: frontBundleID
        ) {
        case .rejectConcealedSecret:
            pendingCopyAppendDeadlineUptime = -100
            pendingCopyAppendBaseText = nil
            scheduleConcealedPasteboardScrubIfNeeded(capturedChangeCount: currentCount)
            return
        case .rejectTransientAutomation:
            return
        case .allowCapture:
            break
        }

        if let bundleID = frontBundleID, ignoredBundleIDSet.contains(bundleID) {
            return
        }
        if let pbBid = sourcePB, ignoredBundleIDSet.contains(pbBid) {
            return
        }
        let sourceApp = frontApp?.localizedName
        let effectiveBundleID = sourcePB ?? frontBundleID

        // 1. 文件 URL
        if types.contains(.fileURL),
           let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
               .urlReadingFileURLsOnly: true
           ]) as? [URL], !fileURLs.isEmpty {
            let paths = fileURLs.map { $0.path }
            let hash = Self.sha256(paths.joined(separator: "\n"))
            let contentHash = "file:\(hash)"
            let item = ClipItem(
                type: .file,
                filePaths: paths,
                contentHash: contentHash,
                sourceAppName: sourceApp,
                sourceAppBundleID: effectiveBundleID
            )
            let copyOutcome = ActionSparkController.shared.handleIncomingCopy(contentHash: contentHash, in: self)
            if copyOutcome == .triggerCandidate { return }
            insertOrPromote(item)
            if copyOutcome == .restoreOriginal || copyOutcome == .suppressReoffer { return }
            let reuseCount = AdaptiveIntelligenceEngine.shared.recordContentActivity(contentHash: contentHash)
            if let latest = items.first(where: { $0.contentHash == contentHash }) {
                ActionSparkController.shared.presentIfAppropriate(for: latest, reuseCount: reuseCount, in: self)
            }
            return
        }

        // 2. 图片
        if types.contains(.png) || types.contains(.tiff) {
            let rawPNG = pasteboard.data(forType: .png)
            let rawTIFF = (rawPNG == nil) ? pasteboard.data(forType: .tiff) : nil
            if rawPNG != nil || rawTIFF != nil {
                let imagesDir = self.imagesDirectoryURL
                let isMinimal = self.minimalModeEnabled
                Task.detached(priority: .utility) { [weak self] in
                    let finalPNG: Data?
                    if let rawPNG {
                        finalPNG = rawPNG
                    } else if let rawTIFF, let bitmap = NSBitmapImageRep(data: rawTIFF) {
                        finalPNG = bitmap.representation(using: .png, properties: [:])
                    } else {
                        finalPNG = nil
                    }
                    guard let pngData = finalPNG else { return }

                    let hash = Self.sha256(pngData)
                    let contentHash = "img:\(hash)"
                    let dims = Self.pixelDimensions(from: pngData)

                    let alreadyExists = await MainActor.run { [weak self] () -> Bool in
                        guard let self else { return true }
                        if let existingIndex = self.items.firstIndex(where: { $0.contentHash == contentHash }) {
                            let copyOutcome = ActionSparkController.shared.handleIncomingCopy(contentHash: contentHash, in: self)
                            if copyOutcome == .triggerCandidate {
                                return true
                            }
                            var existing = self.items.remove(at: existingIndex)
                            existing.createdAt = Date()
                            existing.sourceAppName = sourceApp ?? existing.sourceAppName
                            #if ICLIP_EDITION_FLOW
                            if self.isQueueModeActive && !self.pasteQueueIDs.contains(existing.id) {
                                self.pasteQueueIDs.append(existing.id)
                            }
                            #endif
                            self.items.insert(existing, at: 0)
                            self.items = self.sortItems(self.items)
                            self.saveHistory()
                            if copyOutcome == .restoreOriginal || copyOutcome == .suppressReoffer {
                                return true
                            }
                            let reuseCount = AdaptiveIntelligenceEngine.shared.recordContentActivity(contentHash: contentHash)
                            ActionSparkController.shared.presentIfAppropriate(for: existing, reuseCount: reuseCount, in: self)
                            return true
                        }
                        return false
                    }
                    if alreadyExists { return }

                    let detectedQR = isMinimal ? nil : VisionOCRService.detectBarcodesFast(in: pngData)
                    let fileName = "\(UUID().uuidString).png"
                    let fileURL = imagesDir.appendingPathComponent(fileName)
                    do {
                        try LocalVaultCrypto.writeEncryptedImage(pngData, to: fileURL)
                    } catch {
                        return
                    }

                    let thumb = Self.decodeImage(at: fileURL, maxPixelSize: 360)

                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if let thumb {
                            self.thumbnailCache.setObject(thumb, forKey: fileName as NSString, cost: Self.estimatedCost(of: thumb))
                        }
                        let item = ClipItem(
                            type: .image,
                            imageFileName: fileName,
                            imageWidth: dims.width,
                            imageHeight: dims.height,
                            qrCodePayload: detectedQR,
                            contentHash: contentHash,
                            sourceAppName: sourceApp,
                            sourceAppBundleID: effectiveBundleID
                        )
                        self.insertOrPromote(item)
                        let reuseCount = AdaptiveIntelligenceEngine.shared.recordContentActivity(contentHash: contentHash)
                        if !self.minimalModeEnabled,
                           let qr = detectedQR, !qr.isEmpty,
                           AdaptiveIntelligenceEngine.shared.enabledAutoRules.contains(.extractQRCode) {
                            self.pasteboard.clearContents()
                            self.pasteboard.setString(qr, forType: .string)
                            if Self.isValidWebURL(qr) && SensitiveCredentialVeil.classify(qr) == nil {
                                self.pasteboard.setString(qr, forType: .URL)
                            }
                            let isSensQR = SensitiveCredentialVeil.classify(qr) != nil
                            if isSensQR {
                                PasteboardPrivacyStandards.applyLocalOnlyConcealedProtection(to: self.pasteboard)
                            }
                            let written = self.pasteboard.changeCount
                            self.ignoreNextChangeCount = written
                            self.lastChangeCount = written
                            if isSensQR {
                                self.scheduleConcealedPasteboardScrubIfNeeded(capturedChangeCount: written, delaySeconds: 45.0)
                            }
                            self.showToast(LearnedAutoRuleKind.extractQRCode.shortToast)
                        } else if !self.minimalModeEnabled,
                                  AdaptiveIntelligenceEngine.shared.enabledAutoRules.contains(.compressLargeImage),
                                  pngData.count > 1_500_000 {
                            self.pasteCompressedJPEG(for: item, shouldAutoPaste: false, onBeforePaste: nil)
                        } else {
                            ActionSparkController.shared.presentIfAppropriate(for: item, reuseCount: reuseCount, in: self)
                        }
                        if !self.minimalModeEnabled {
                            self.scheduleBackgroundOCR(forItemID: item.id, fileURL: fileURL)
                        }
                    }
                }
                return
            }
        }

        // 3. 文本与链接
        if let rawText = pasteboard.string(forType: .string) {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // 命中 ⌃⌥C「跨处续接复制」捕获窗口：自动换行拼接并原地更新顶部记录，弹出光标旁轻胶囊
            if ProcessInfo.processInfo.systemUptime <= pendingCopyAppendDeadlineUptime {
                pendingCopyAppendDeadlineUptime = -100
                let base = pendingCopyAppendBaseText ?? ""
                pendingCopyAppendBaseText = nil
                commitAppendedSegment(incomingText: rawText, explicitBase: base, sourceApp: sourceApp, showGlobalNotice: true)
                return
            }

            copyAppendTargetID = nil
            copyAppendSegmentCount = 1

            let hasRichFormatting = RichTextPasteboardHelper.hasStrippableRichFormatting(types: types, plainText: rawText)
            let hasSparkRichFormatting = RichTextPasteboardHelper.shouldOfferRichStripSpark(
                types: types,
                plainText: rawText,
                sourceApp: sourceApp
            )
            var text = rawText
            let isLink = isValidWebURL(trimmed)
            var didAutoApplyRule = false

            if !minimalModeEnabled,
               let autoApplied = AdaptiveIntelligenceEngine.shared.applyLearnedAutoTextRuleIfEnabled(rawText: text, isLink: isLink) {
                text = autoApplied.text
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                commitOutboundPasteboardGuard(for: text, forceProtected: false, isPinnedSource: false)
                didAutoApplyRule = true
                showToast(autoApplied.rule.shortToast)
            } else if !minimalModeEnabled,
                      AdaptiveIntelligenceEngine.shared.shouldAutoStripRichFormatting(hasRichFormatting: hasRichFormatting, sourceApp: sourceApp) {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                commitOutboundPasteboardGuard(for: text, forceProtected: false, isPinnedSource: false)
                didAutoApplyRule = true
                showToast(LearnedAutoRuleKind.stripRichTextFormatting.shortToast)
            }
            #if !ICLIP_EDITION_FLOW
            if !didAutoApplyRule && !minimalModeEnabled && isLink && autoCleanTrackingURL,
               let cleaned = SemanticEngine.cleanTrackingURL(trimmed) {
                text = cleaned
                pasteboard.clearContents()
                pasteboard.setString(cleaned, forType: .string)
                commitOutboundPasteboardGuard(for: cleaned, forceProtected: false, isPinnedSource: false)
                didAutoApplyRule = true
            }
            #endif

            let finalIsLink = isValidWebURL(text.trimmingCharacters(in: .whitespacesAndNewlines))
            let hash = Self.sha256(text)
            let contentHash = "\(finalIsLink ? "link" : "text"):\(hash)"
            if !didAutoApplyRule {
                let copyOutcome = ActionSparkController.shared.handleIncomingCopy(contentHash: contentHash, in: self)
                if copyOutcome == .triggerCandidate {
                    return
                }
                if copyOutcome == .restoreOriginal || copyOutcome == .suppressReoffer {
                    let restoredItem = ClipItem(
                        type: finalIsLink ? .link : .text,
                        text: text,
                        contentHash: contentHash,
                        sourceAppName: sourceApp,
                        sourceAppBundleID: effectiveBundleID
                    )
                    insertOrPromote(restoredItem)
                    return
                }
            }
            let item = ClipItem(
                type: finalIsLink ? .link : .text,
                text: text,
                contentHash: contentHash,
                sourceAppName: sourceApp,
                sourceAppBundleID: effectiveBundleID
            )
            insertOrPromote(item)
            copyAppendTargetID = items.first(where: { $0.contentHash == contentHash })?.id
            let reuseCount = AdaptiveIntelligenceEngine.shared.recordContentActivity(contentHash: contentHash)
            if !didAutoApplyRule, let latest = items.first(where: { $0.contentHash == contentHash }) {
                ActionSparkController.shared.presentIfAppropriate(
                    for: latest,
                    reuseCount: reuseCount,
                    hasRichFormatting: hasSparkRichFormatting,
                    in: self
                )
            }
        }
    }

    // MARK: - 拖拽内容直达剪贴板复制与收录

    /// 记录最近一次从 iClip 面板内部向外发起拖拽的时间戳（防止内部拖出误触发自身拖入遮罩与顶部黑洞）
    private var lastInternalDragUptime: TimeInterval = -100

    var isInternalDragActive: Bool {
        (ProcessInfo.processInfo.systemUptime - lastInternalDragUptime) < 3.0
    }

    func markInternalDragEnded() {
        lastInternalDragUptime = -100
    }

    /// 将 iClip 面板内的条目（文本 / 链接 / 图片 / 文件）包装为原生 NSItemProvider，支持直接拖出至任意外部应用
    func makeDragItemProvider(for item: ClipItem) -> NSItemProvider {
        lastInternalDragUptime = ProcessInfo.processInfo.systemUptime
        if item.isBurnAfterPaste {
            scheduleBurnAfterPasteIfNeeded(for: item, delaySeconds: 5.0)
        }

        switch item.type {
        case .image:
            if let fileName = item.imageFileName {
                let url = imagesDirectoryURL.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: url.path) {
                    let exportURL = DragFileExportHelper.materializeExportFile(for: item, sourceImageURL: url)?.url ?? url
                    if let provider = NSItemProvider(contentsOf: exportURL) {
                        provider.suggestedName = exportURL.lastPathComponent
                        return provider
                    }
                }
            }
            if let nsImage = cachedThumbnail(for: item), let tiff = nsImage.tiffRepresentation {
                let provider = NSItemProvider()
                provider.suggestedName = DragFileExportHelper.suggestedFileName(for: item, ext: "png")
                provider.registerDataRepresentation(forTypeIdentifier: "public.tiff", visibility: .all) { completion in
                    completion(tiff, nil)
                    return nil
                }
                return provider
            }
            return NSItemProvider(object: (item.primaryTitle) as NSString)

        case .file:
            if let firstPath = item.filePaths?.first {
                let fileURL = URL(fileURLWithPath: firstPath)
                if FileManager.default.fileExists(atPath: firstPath),
                   let provider = NSItemProvider(contentsOf: fileURL) {
                    provider.suggestedName = fileURL.lastPathComponent
                    return provider
                }
                return NSItemProvider(object: (fileURL as NSURL))
            }
            return NSItemProvider(object: (item.primaryTitle) as NSString)

        case .link:
            let raw = (item.text ?? item.primaryTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: raw) {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider(object: raw as NSString)

        case .text:
            let raw = item.text ?? item.primaryTitle
            // 按住 ⌥ 拖拽任意文本卡片时，强制物化为带语义扩展名的真实文件（直投微信/飞书/网页上传框/桌面）
            if NSEvent.modifierFlags.contains(.option),
               let exported = DragFileExportHelper.materializeExportFile(for: item),
               let fileProvider = NSItemProvider(contentsOf: exported.url) {
                fileProvider.suggestedName = exported.url.lastPathComponent
                return fileProvider
            }

            let provider = NSItemProvider(object: raw as NSString)
            let spec = DragFileExportHelper.inferTextArtifactSpec(for: raw)
            provider.suggestedName = DragFileExportHelper.suggestedFileName(
                for: item,
                ext: spec.ext,
                fallbackStem: spec.fallbackStem
            )
            // 对 SVG / JSON / HTML / CSV / 脚本 / Markdown 同时附带标准文件表示（粘贴即焚高机密卡片禁止静默落盘临时文件）
            if !item.isBurnAfterPaste && spec.utType != .utf8PlainText && spec.utType != .plainText {
                let itemSnapshot = item
                provider.registerFileRepresentation(
                    forTypeIdentifier: spec.utType.identifier,
                    fileOptions: [],
                    visibility: .all
                ) { completion in
                    if let exported = DragFileExportHelper.materializeExportFile(for: itemSnapshot) {
                        completion(exported.url, false, nil)
                    } else {
                        completion(nil, false, nil)
                    }
                    return nil
                }
            }
            return provider
        }
    }

    /// 最近一次通过拖放成功导入的预览图与标准 PNG 数据（供光标微落点样机渲染零磁盘竞态直接复用）
    private(set) var lastImportedDragPreviewCGImage: CGImage?
    private(set) var lastImportedDragPNGData: Data?

    private static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let jpegPasteboardType = NSPasteboard.PasteboardType("public.jpeg")
    private static let webpPasteboardType = NSPasteboard.PasteboardType("org.webmproject.webp")
    private static let heicPasteboardType = NSPasteboard.PasteboardType("public.heic")
    private static let gifPasteboardType = NSPasteboard.PasteboardType("com.compuserve.gif")

    /// 支持拖放到 iClip 面板或菜单栏图标的原生剪贴板类型（含微信 Qt / Electron 等跨平台格式）
    nonisolated static let supportedDragTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        .png,
        .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("org.webmproject.webp"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        .URL,
        .string
    ]

    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "heif", "tiff", "tif", "gif", "bmp"
    ]

    private static let nonImageDocumentExtensions: Set<String> = [
        "pdf", "psd", "ai", "eps", "svg", "zip", "rar", "7z", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "mp4", "mov"
    ]

    /// 判断拖放内容是否可被 iClip 接收并复制
    nonisolated static func canAcceptDrag(from draggingPasteboard: NSPasteboard) -> Bool {
        guard let types = draggingPasteboard.types else { return false }
        return supportedDragTypes.contains(where: { types.contains($0) })
    }

    /// 接收拖拽到面板或菜单栏图标的内容：写入系统剪贴板（立即生效 ⌘V）并收录至历史列表
    @discardableResult
    func importAndCopy(from draggingPasteboard: NSPasteboard, sourceLabel: String = "拖拽复制") -> Bool {
        lastImportedDragPreviewCGImage = nil
        lastImportedDragPNGData = nil
        let types = draggingPasteboard.types ?? []

        // 1. 优先读取内存直接图像流（网页图片 / 截图 / 跨平台直接图像字节，零磁盘权限依赖）
        let inMemoryImageTypes: [NSPasteboard.PasteboardType] = [
            .png, Self.jpegPasteboardType, Self.webpPasteboardType, Self.heicPasteboardType, Self.gifPasteboardType, .tiff
        ]
        if inMemoryImageTypes.contains(where: { types.contains($0) }) {
            let rawData = inMemoryImageTypes.lazy.compactMap { draggingPasteboard.data(forType: $0) }.first { !$0.isEmpty }
            if let rawData, let normalized = Self.normalizeImageForClipboard(from: rawData) {
                commitNormalizedImageToPasteboard(normalized, sourceApp: sourceLabel, toastTitle: "已复制图片到剪贴板")
                return true
            }
        }

        // 2. 本地文件 URL / NSFilenamesPboardType（重点兼容 Mac 微信 Qt `file://localhost/.../Containers/com.tencent.xinWeChat/...`）
        let droppedNSURLs = Self.extractDroppedFileNSURLs(from: draggingPasteboard)
        if !droppedNSURLs.isEmpty {
            if droppedNSURLs.count == 1 {
                let singleNSURL = droppedNSURLs[0]
                let cleanPath = singleNSURL.path ?? (singleNSURL as URL).path
                let ext = (cleanPath as NSString).pathExtension.lowercased()
                let mightBeImage = Self.supportedImageExtensions.contains(ext) || (ext.isEmpty && !cleanPath.isEmpty)

                if mightBeImage || !Self.nonImageDocumentExtensions.contains(ext) {
                    switch Self.readScopedFileData(from: singleNSURL) {
                    case .success(let fileData):
                        if Self.supportedImageExtensions.contains(ext) || Self.looksLikeRasterImage(fileData),
                           let normalized = Self.normalizeImageForClipboard(from: fileData) {
                            let fileName = (cleanPath as NSString).lastPathComponent
                            commitNormalizedImageToPasteboard(
                                normalized,
                                sourceApp: sourceLabel,
                                toastTitle: "已复制图片到剪贴板：\(fileName)"
                            )
                            return true
                        }
                    case .permissionDenied:
                        handleContainerPermissionBlocked(path: cleanPath)
                        return false
                    case .failed:
                        break
                    }
                }
            }

            // 普通文件或多文件拖入：规范化为干净本地路径 URL（去除 Qt `file://localhost/` 主机头），并校验剪贴板实际写入结果
            let cleanURLs: [NSURL] = droppedNSURLs.compactMap { nsURL in
                guard let p = nsURL.path, !p.isEmpty else { return nil }
                return URL(fileURLWithPath: p) as NSURL
            }
            guard !cleanURLs.isEmpty else { return false }

            // 若单文件位于其他 App 受保护沙盒容器且无读取权限，防止 writeObjects 失败把系统剪贴板清空成空数组
            if let firstPath = cleanURLs[0].path,
               firstPath.contains("/Library/Containers/"),
               !FileManager.default.isReadableFile(atPath: firstPath) {
                let scoped = droppedNSURLs[0].startAccessingSecurityScopedResource()
                let readable = FileManager.default.isReadableFile(atPath: firstPath)
                if scoped { droppedNSURLs[0].stopAccessingSecurityScopedResource() }
                if !readable {
                    handleContainerPermissionBlocked(path: firstPath)
                    return false
                }
            }

            let tempCheckPB = NSPasteboard.withUniqueName()
            let canWrite = tempCheckPB.writeObjects(cleanURLs)
            tempCheckPB.releaseGlobally()
            guard canWrite else {
                if let firstPath = cleanURLs[0].path {
                    handleContainerPermissionBlocked(path: firstPath)
                } else {
                    showToast("无法读取拖入的文件")
                }
                return false
            }

            pasteboard.clearContents()
            pasteboard.writeObjects(cleanURLs)
            ignoreNextChangeCount = pasteboard.changeCount
            lastChangeCount = pasteboard.changeCount

            let paths = cleanURLs.compactMap { $0.path }
            let hash = Self.sha256(paths.joined(separator: "\n"))
            let item = ClipItem(
                type: .file,
                filePaths: paths,
                contentHash: "file:\(hash)",
                sourceAppName: sourceLabel
            )
            insertOrPromote(item)
            if paths.count == 1 {
                showToast("已复制到剪贴板：\((paths[0] as NSString).lastPathComponent)")
            } else {
                showToast("已复制 \(paths.count) 个文件到剪贴板")
            }
            return true
        }

        // 3. 网页链接（浏览器地址栏 / 超链接直接拖入）
        if types.contains(.URL),
           let urlString = draggingPasteboard.string(forType: .URL)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !urlString.isEmpty {
            var finalLink = urlString
            #if !ICLIP_EDITION_FLOW
            if !minimalModeEnabled && autoCleanTrackingURL, let cleaned = SemanticEngine.cleanTrackingURL(urlString) {
                finalLink = cleaned
            }
            #endif
            pasteboard.clearContents()
            pasteboard.setString(finalLink, forType: .string)
            if SensitiveCredentialVeil.classify(finalLink) == nil {
                pasteboard.setString(finalLink, forType: .URL)
            }
            commitOutboundPasteboardGuard(for: finalLink, forceProtected: false, isPinnedSource: false)

            let hash = Self.sha256(finalLink)
            let item = ClipItem(
                type: .link,
                text: finalLink,
                contentHash: "link:\(hash)",
                sourceAppName: sourceLabel
            )
            insertOrPromote(item)
            showToast("已复制链接到剪贴板")
            return true
        }

        // 4. 文本与选中文字片段
        if let rawText = draggingPasteboard.string(forType: .string) {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }

            var finalText = rawText
            let isLink = isValidWebURL(trimmed)
            #if !ICLIP_EDITION_FLOW
            if !minimalModeEnabled && isLink && autoCleanTrackingURL, let cleaned = SemanticEngine.cleanTrackingURL(trimmed) {
                finalText = cleaned
            }
            #endif

            pasteboard.clearContents()
            pasteboard.setString(finalText, forType: .string)
            if isLink && SensitiveCredentialVeil.classify(finalText) == nil {
                pasteboard.setString(finalText, forType: .URL)
            }
            commitOutboundPasteboardGuard(for: finalText, forceProtected: false, isPinnedSource: false)

            let hash = Self.sha256(finalText)
            let item = ClipItem(
                type: isLink ? .link : .text,
                text: finalText,
                contentHash: "\(isLink ? "link" : "text"):\(hash)",
                sourceAppName: sourceLabel
            )
            insertOrPromote(item)
            showToast(isLink ? "已复制链接到剪贴板" : "已复制文本到剪贴板")
            return true
        }

        return false
    }

    private struct NormalizedClipboardImage {
        let pngData: Data
        let tiffData: Data
        let cgImage: CGImage?
    }

    private enum ScopedFileReadResult {
        case success(Data)
        case permissionDenied
        case failed
    }

    /// 提取拖放剪贴板中的本地文件 NSURL（保留原始 NSURL Security-Scope 上下文，并兼容 Qt/Electron 的 NSFilenamesPboardType）
    private static func extractDroppedFileNSURLs(from pasteboard: NSPasteboard) -> [NSURL] {
        if let nsURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [NSURL], !nsURLs.isEmpty {
            return nsURLs
        }
        if let rawPaths = pasteboard.propertyList(forType: legacyFilenamesType) as? [String], !rawPaths.isEmpty {
            return rawPaths.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) as NSURL }
        }
        return []
    }

    /// 安全读取拖入文件字节（自动管理 Security-Scoped 访问，区分容器 TCC 权限拦截与普通错误）
    private static func readScopedFileData(from nsURL: NSURL) -> ScopedFileReadResult {
        let accessed = nsURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                nsURL.stopAccessingSecurityScopedResource()
            }
        }

        let primaryURL = nsURL as URL
        do {
            let data = try Data(contentsOf: primaryURL, options: [.mappedIfSafe])
            if !data.isEmpty { return .success(data) }
        } catch let err as NSError {
            if isPermissionDeniedError(err) {
                return .permissionDenied
            }
        }

        if let path = nsURL.path, !path.isEmpty {
            let fallbackURL = URL(fileURLWithPath: path)
            do {
                let data = try Data(contentsOf: fallbackURL, options: [.mappedIfSafe])
                if !data.isEmpty { return .success(data) }
            } catch let err as NSError {
                if isPermissionDeniedError(err) {
                    return .permissionDenied
                }
            }
        }

        return .failed
    }

    private static func isPermissionDeniedError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDeniedError(underlying)
        }
        return false
    }

    /// 通过文件头魔数嗅探无后缀缓存图片（如微信表情/缓存图 JPEG、PNG、GIF、WebP、BMP、HEIC）
    private static func looksLikeRasterImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        // PNG: 89 50 4E 47
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return true }
        // JPEG: FF D8 FF
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return true }
        // GIF: GIF87a / GIF89a
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 { return true }
        // WebP: RIFF....WEBP
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
           b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return true }
        // BMP: BM
        if b[0] == 0x42 && b[1] == 0x4D { return true }
        // HEIC/HEIF/AVIF: ....ftyp
        if b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 { return true }
        return false
    }

    /// 将任意图片数据（JPG/WebP/HEIC/PNG/TIFF/GIF）标准化解码为通用 PNG + TIFF 双格式字节流
    private static func normalizeImageForClipboard(from rawData: Data) -> NormalizedClipboardImage? {
        guard let source = CGImageSourceCreateWithData(rawData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            guard let nsImage = NSImage(data: rawData),
                  let tiff = nsImage.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                return nil
            }
            return NormalizedClipboardImage(pngData: png, tiffData: tiff, cgImage: rep.cgImage)
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]),
              let tiffData = rep.tiffRepresentation else {
            return nil
        }
        return NormalizedClipboardImage(pngData: pngData, tiffData: tiffData, cgImage: cgImage)
    }

    /// 写入纯正的 PNG + TIFF 双格式到系统剪贴板（不夹带受保护的私有容器 fileURL，确保任何目标应用 ⌘V 100% 粘出原图）
    private func commitNormalizedImageToPasteboard(
        _ normalized: NormalizedClipboardImage,
        sourceApp: String,
        toastTitle: String
    ) {
        lastImportedDragPreviewCGImage = normalized.cgImage
        lastImportedDragPNGData = normalized.pngData
        pasteboard.clearContents()
        pasteboard.setData(normalized.pngData, forType: .png)
        pasteboard.setData(normalized.tiffData, forType: .tiff)
        ignoreNextChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount

        ingestDroppedImageData(
            rawPNG: normalized.pngData,
            rawTIFF: normalized.tiffData,
            sourceApp: sourceApp
        )
        showToast(toastTitle)
    }

    /// 将刚通过拖放导入的内存图像字节零竞态渲染为苹果风圆角柔和阴影样机图，并写入系统剪贴板
    func convertLastImportedDragImageToMockup() {
        guard let pngData = lastImportedDragPNGData else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let result = ImageStudioEngine.renderAppleMockupFrame(from: pngData) else { return }
            let tiffData = NSImage(data: result.data)?.tiffRepresentation
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pasteboard.clearContents()
                self.pasteboard.setData(result.data, forType: .png)
                if let tiffData {
                    self.pasteboard.setData(tiffData, forType: .tiff)
                }
                self.ignoreNextChangeCount = self.pasteboard.changeCount
                self.lastChangeCount = self.pasteboard.changeCount
                self.showToast("已生成圆角阴影样机图到剪贴板")
            }
        }
    }

    /// 当 macOS TCC 拦截跨沙盒容器（如微信 `~/Library/Containers/com.tencent.xinWeChat`）文件读取时：
    /// 绝不清空原剪贴板、绝不写入损坏记录，并清晰指引用户授权
    private func handleContainerPermissionBlocked(path: String) {
        let isWeChat = path.contains("com.tencent.xinWeChat")
        if isWeChat {
            showToast("微信沙盒受系统保护，请在「隐私与安全性 › 完全磁盘访问权限」开启 iClip")
        } else {
            showToast("应用沙盒受系统保护，请在「隐私与安全性 › 完全磁盘访问权限」开启 iClip")
        }
    }

    private func ingestDroppedImageData(rawPNG: Data?, rawTIFF: Data?, sourceApp: String) {
        let imagesDir = self.imagesDirectoryURL
        let isMinimal = self.minimalModeEnabled
        Task.detached(priority: .utility) { [weak self] in
            let finalPNG: Data?
            if let rawPNG {
                finalPNG = rawPNG
            } else if let rawTIFF, let bitmap = NSBitmapImageRep(data: rawTIFF) {
                finalPNG = bitmap.representation(using: .png, properties: [:])
            } else {
                finalPNG = nil
            }
            guard let pngData = finalPNG else { return }

            let hash = Self.sha256(pngData)
            let contentHash = "img:\(hash)"
            let dims = Self.pixelDimensions(from: pngData)

            let alreadyExists = await MainActor.run { [weak self] () -> Bool in
                guard let self else { return true }
                if let existingIndex = self.items.firstIndex(where: { $0.contentHash == contentHash }) {
                    var existing = self.items.remove(at: existingIndex)
                    existing.createdAt = Date()
                    existing.sourceAppName = sourceApp
                    #if ICLIP_EDITION_FLOW
                    if !self.minimalModeEnabled && self.isQueueModeActive && !self.pasteQueueIDs.contains(existing.id) {
                        self.pasteQueueIDs.append(existing.id)
                    }
                    #endif
                    self.items.insert(existing, at: 0)
                    self.items = self.sortItems(self.items)
                    self.saveHistory()
                    return true
                }
                return false
            }
            if alreadyExists { return }

            let detectedQR = isMinimal ? nil : VisionOCRService.detectBarcodesFast(in: pngData)
            let fileName = "\(UUID().uuidString).png"
            let fileURL = imagesDir.appendingPathComponent(fileName)
            do {
                try LocalVaultCrypto.writeEncryptedImage(pngData, to: fileURL)
            } catch {
                return
            }

            let thumb = Self.decodeImage(at: fileURL, maxPixelSize: 360)

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let thumb {
                    self.thumbnailCache.setObject(thumb, forKey: fileName as NSString, cost: Self.estimatedCost(of: thumb))
                }
                let item = ClipItem(
                    type: .image,
                    imageFileName: fileName,
                    imageWidth: dims.width,
                    imageHeight: dims.height,
                    qrCodePayload: detectedQR,
                    contentHash: contentHash,
                    sourceAppName: sourceApp
                )
                self.insertOrPromote(item)
                if !self.minimalModeEnabled {
                    self.scheduleBackgroundOCR(forItemID: item.id, fileURL: fileURL)
                }
            }
        }
    }

    private func insertOrPromote(_ newItem: ClipItem) {
        let finalID: UUID
        if let existingIndex = items.firstIndex(where: { $0.contentHash == newItem.contentHash }) {
            var existing = items.remove(at: existingIndex)
            existing.createdAt = Date()
            if let app = newItem.sourceAppName {
                existing.sourceAppName = app
            }
            finalID = existing.id
            items.insert(existing, at: 0)
        } else {
            finalID = newItem.id
            items.insert(newItem, at: 0)
        }

        #if ICLIP_EDITION_FLOW
        if !minimalModeEnabled && isQueueModeActive && !pasteQueueIDs.contains(finalID) {
            pasteQueueIDs.append(finalID)
        }
        #else
        _ = finalID
        #endif

        items = sortItems(items)
        trimHistoryIfNeeded()
        saveHistory()
    }

    private func trimHistoryIfNeeded() {
        let protectedItems = items.filter { $0.isPinned || $0.isPendingTodo }
        var unprotected = items.filter { !$0.isPinned && !$0.isPendingTodo }
        if unprotected.count > maxHistoryCount {
            let removed = unprotected[maxHistoryCount...]
            for item in removed {
                deleteImageFileIfNeeded(for: item)
            }
            unprotected = Array(unprotected.prefix(maxHistoryCount))
            items = sortItems(protectedItems + unprotected)
            saveHistory()
        }
    }

    // MARK: - 用户粘贴与删除操作

    func copyAndOptionallyPaste(
        _ item: ClipItem,
        plainTextOnly: Bool = false,
        shouldAutoPaste: Bool = true,
        forceRawSecret: Bool = false,
        onBeforePaste: (() -> Void)? = nil
    ) {
        if !minimalModeEnabled && !plainTextOnly && !forceRawSecret,
           let rawTemplate = item.text,
           SnippetTemplateEngine.containsPlaceholders(rawTemplate) {
            let context = latestNonTemplateText(excluding: item.id)
            let rendered = SnippetTemplateEngine.render(template: rawTemplate, latestContextText: context)
            pasteCustomString(
                rendered,
                sourceItem: item,
                toast: "已展开动态模板并键入",
                shouldAutoPaste: shouldAutoPaste,
                onBeforePaste: onBeforePaste
            )
            return
        }

        #if !ICLIP_EDITION_FLOW
        if !minimalModeEnabled && autoRedactOnPaste && !forceRawSecret {
            let snap = semanticSnapshot(for: item)
            if let secAction = snap.actions.first(where: { $0.isSecurityAction }) {
                applyTransformAction(secAction, for: item, shouldAutoPaste: shouldAutoPaste, onBeforePaste: onBeforePaste)
                return
            }
        }
        #endif

        // 终端粘贴劫持（Pastejacking / Trojan Bidi）实时主动防御：目标窗口为终端且剪贴含高危隐藏控制符时自动剥离
        if !minimalModeEnabled && !forceRawSecret,
           let raw = item.text,
           case .pastejackingOrBidi = item.detectedPoisonThreat,
           ClipboardPoisonGuard.isTerminalApp(activeTargetAppName) {
            let safeCmd = ClipboardPoisonGuard.sanitize(raw)
            if safeCmd != raw && !safeCmd.isEmpty {
                pasteCustomString(
                    safeCmd,
                    sourceItem: item,
                    toast: "已拦截隐藏终端劫持控制符并安全键入",
                    shouldAutoPaste: shouldAutoPaste,
                    onBeforePaste: onBeforePaste
                )
                return
            }
        }

        writeToPasteboard(item, plainTextOnly: plainTextOnly)
        if shouldAutoPaste {
            AdaptiveIntelligenceEngine.shared.recordContentActivity(contentHash: item.contentHash)
            recordTargetAppPasteIfAppropriate(for: item)
            TactileFeedbackEngine.shared.perform(.pasteCommit)
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].createdAt = Date()
                items = sortItems(items)
                saveHistory()
            }
        } else {
            // 原地单击复制：仅写入剪贴板并给细腻触感反馈，绝不跳动卡片行序（确保紧接着的第 2 下双击精准落在同一卡片）
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
        }

        onBeforePaste?()
        if shouldAutoPaste {
            scheduleOTPAutoExpireIfNeeded(for: item)
            scheduleBurnAfterPasteIfNeeded(for: item)
        }

        refreshAccessibilityStatus()
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
        } else if shouldAutoPaste {
            showToast(plainTextOnly ? "已复制纯文本" : "已复制到剪贴板")
        } else if plainTextOnly {
            showToast("已复制纯文本")
        }
    }

    /// 解析链接条目的安全可访问网页 URL（严格锁定 http/https 白名单，拦截一切非网页危险伪协议）
    func resolvedBrowserURL(for item: ClipItem) -> URL? {
        let raw = (item.text ?? item.primaryTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        return OutboundLinkSafety.validatedBrowserURL(from: raw)
    }

    /// 点击链接卡片左侧徽标或悬停打开按钮：对同形异义钓鱼伪装域名执行主动拦截，安全网页正常打开
    func openLinkInBrowser(_ item: ClipItem) {
        if item.detectedLinkRisk == .homographPhishing {
            showToast("已拦截同形异义伪装钓鱼域名，请核对真实地址", duration: 3.6)
            return
        }
        guard let url = resolvedBrowserURL(for: item) else {
            showToast("无效的链接地址")
            return
        }
        TactileFeedbackEngine.shared.perform(.openLink)
        onAfterOpenExternalURL?()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config) { [weak self] _, error in
            if error != nil {
                Task { @MainActor in
                    _ = NSWorkspace.shared.open(url)
                    self?.showToast("已在浏览器请求打开链接")
                }
            }
        }
    }

    /// 全键盘 ⌘O 直达打开：链接在默认浏览器打开，文件与本地原图直接在访达中高亮定位
    @discardableResult
    func openItemExternally(_ item: ClipItem) -> Bool {
        switch item.type {
        case .link:
            guard resolvedBrowserURL(for: item) != nil else {
                showToast("无效的链接地址")
                return false
            }
            openLinkInBrowser(item)
            return true

        case .file:
            guard let paths = item.filePaths, !paths.isEmpty else { return false }
            let urls = paths.map { URL(fileURLWithPath: $0) }
            TactileFeedbackEngine.shared.perform(.openLink)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            onAfterOpenExternalURL?()
            return true

        case .image:
            guard let url = imageURL(for: item) else { return false }
            let previewURL = DragFileExportHelper.materializeExportFile(for: item, sourceImageURL: url)?.url ?? url
            TactileFeedbackEngine.shared.perform(.openLink)
            NSWorkspace.shared.activateFileViewerSelecting([previewURL])
            onAfterOpenExternalURL?()
            return true

        case .text:
            let trimmed = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isValidWebURL(trimmed) {
                openLinkInBrowser(item)
                return true
            }
            // 支持混排分享口令 / 群聊消息内嵌网页链接直接按 ⌘O 在浏览器打开（严格通过协议白名单与同形异义钓鱼拦截）
            if let embeddedURLString = URLTrackingCleaner.extractFirstCleanedWebURL(from: trimmed),
               let embeddedURL = OutboundLinkSafety.validatedBrowserURL(from: embeddedURLString) {
                if FileAndLinkSecurityGuard.inspectLinkRisk(embeddedURLString) == .homographPhishing {
                    showToast("已拦截同形异义伪装钓鱼域名，请核对真实地址", duration: 3.6)
                    return false
                }
                TactileFeedbackEngine.shared.perform(.openLink)
                NSWorkspace.shared.open(embeddedURL)
                onAfterOpenExternalURL?()
                return true
            }
            // 支持终端 / IDE 复制的本地路径（含 ~/...、file:// 与 File.swift:128:14 行列号后缀）按 ⌘O 直接访达高亮定位
            if let localFileURL = URLTrackingCleaner.resolveExistingLocalFileURL(from: trimmed) {
                TactileFeedbackEngine.shared.perform(.openLink)
                NSWorkspace.shared.activateFileViewerSelecting([localFileURL])
                onAfterOpenExternalURL?()
                return true
            }
            showToast("当前条目不含网页链接或存在的本地路径")
            return false
        }
    }

    /// 面板内按 ⌥⌘C（对齐 Finder 拷贝路径直觉）：文件与图片复制本地路径，链接与文本复制纯文本
    func copyPlainPathOrText(_ item: ClipItem) {
        if item.type == .image, let url = imageURL(for: item) {
            let exportPath = (DragFileExportHelper.materializeExportFile(for: item, sourceImageURL: url)?.url ?? url).path
            pasteboard.clearContents()
            pasteboard.setString(exportPath, forType: .string)
            ignoreNextChangeCount = pasteboard.changeCount
            lastChangeCount = pasteboard.changeCount
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
            showToast("已复制图片可读本地路径")
            return
        }
        copyAndOptionallyPaste(item, plainTextOnly: true, shouldAutoPaste: false, onBeforePaste: nil)
    }

    /// 针对一次性验证码条目在粘贴后启动 30 秒无痕清理倒计时（极简模式或已固定记录绝不误删）
    func scheduleOTPAutoExpireIfNeeded(for item: ClipItem, delaySeconds: TimeInterval = 30.0) {
        guard !minimalModeEnabled,
              autoExpireOTP,
              !item.isPinned,
              item.type == .text,
              let raw = item.text,
              MeetingAndEphemeralEngine.isOTPMessage(raw) else {
            return
        }

        let targetID = item.id
        pendingOTPExpirationTasks[targetID]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingOTPExpirationTasks.removeValue(forKey: targetID)
            guard !self.minimalModeEnabled,
                  self.autoExpireOTP,
                  let current = self.items.first(where: { $0.id == targetID }),
                  !current.isPinned else {
                return
            }
            self.delete(current, userInitiated: false)
        }
        pendingOTPExpirationTasks[targetID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: work)
    }

    /// 检测到密码管理器写入 `Concealed` 机密后，60 秒若剪贴板未更新则静默擦除系统剪贴板残留明文
    private func scheduleConcealedPasteboardScrubIfNeeded(capturedChangeCount: Int, delaySeconds: TimeInterval = 60.0) {
        concealedScrubWorkItem?.cancel()
        guard autoClearConcealedPasteboard else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.autoClearConcealedPasteboard else { return }
            if self.pasteboard.changeCount == capturedChangeCount {
                self.pasteboard.clearContents()
                self.ignoreNextChangeCount = self.pasteboard.changeCount
                self.lastChangeCount = self.pasteboard.changeCount
            }
        }
        concealedScrubWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: work)
    }

    /// 切换单条记录的「粘贴即焚」（⌘B）：开启后下次粘贴进目标窗口 5 秒即连同系统剪贴板一起无痕销毁
    func toggleBurnAfterPaste(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let nextState = !items[idx].isBurnAfterPaste
        items[idx].isBurnAfterPaste = nextState
        if nextState && items[idx].isPinned {
            items[idx].isPinned = false
        }
        saveHistory()
        TactileFeedbackEngine.shared.perform(nextState ? .favoriteOn : .favoriteOff)
        showToast(nextState ? "已设为「粘贴即焚」· 粘贴 5 秒后无痕自毁" : "已取消粘贴即焚")
    }

    private func scheduleBurnAfterPasteIfNeeded(for item: ClipItem, delaySeconds: TimeInterval = 5.0) {
        guard item.isBurnAfterPaste else { return }
        let targetID = item.id
        let expectedChangeCount = pasteboard.changeCount
        pendingOTPExpirationTasks[targetID]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  let current = self.items.first(where: { $0.id == targetID }),
                  current.isBurnAfterPaste else {
                return
            }
            self.pendingOTPExpirationTasks.removeValue(forKey: targetID)
            if self.pasteboard.changeCount == expectedChangeCount {
                self.pasteboard.clearContents()
                self.ignoreNextChangeCount = self.pasteboard.changeCount
                self.lastChangeCount = self.pasteboard.changeCount
            }
            self.delete(current, userInitiated: false)
        }
        pendingOTPExpirationTasks[targetID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: work)
    }

    /// 一键将指定记录的来源应用加入隐私忽略黑名单（支持 Bundle ID 精确匹配或运行中应用反查）
    @discardableResult
    func ignoreSourceApp(of item: ClipItem) -> Bool {
        if let bid = item.sourceAppBundleID, !bid.isEmpty {
            let name = item.sourceAppName ?? bid
            addIgnoredApp(bundleIdentifier: bid, displayName: name)
            showToast("已忽略来自「\(name)」的后续复制记录")
            return true
        }
        if let appName = item.sourceAppName,
           let matched = NSWorkspace.shared.runningApplications.first(where: {
               $0.localizedName == appName && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier
           }),
           let bid = matched.bundleIdentifier {
            addIgnoredApp(bundleIdentifier: bid, displayName: appName)
            showToast("已忽略来自「\(appName)」的后续复制记录")
            return true
        }
        return false
    }

    private func recordTargetAppPasteIfAppropriate(for item: ClipItem) {
        guard !minimalModeEnabled else { return }
        AdaptiveIntelligenceEngine.shared.recordPasteToTargetApp(
            contentHash: item.contentHash,
            targetApp: activeTargetAppName
        )
    }

    private func writeToPasteboard(_ item: ClipItem, plainTextOnly: Bool) {
        pasteboard.clearContents()

        switch item.type {
        case .text:
            if let text = item.text {
                pasteboard.setString(text, forType: .string)
            }
        case .link:
            if let text = item.text {
                pasteboard.setString(text, forType: .string)
                if !plainTextOnly {
                    pasteboard.setString(text, forType: .URL)
                }
            }
        case .image:
            if plainTextOnly, let url = imageURL(for: item) {
                let exportPath = (DragFileExportHelper.materializeExportFile(for: item, sourceImageURL: url)?.url ?? url).path
                pasteboard.setString(exportPath, forType: .string)
            } else if let url = imageURL(for: item), let pngData = LocalVaultCrypto.readDecryptedImageData(at: url) {
                pasteboard.setData(pngData, forType: .png)
            }
        case .file:
            if let paths = item.filePaths, !paths.isEmpty {
                if plainTextOnly {
                    pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
                } else {
                    let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
                    pasteboard.writeObjects(urls)
                }
            }
        }

        if item.detectedSensitiveKind != nil || item.isBurnAfterPaste {
            PasteboardPrivacyStandards.applyLocalOnlyConcealedProtection(to: pasteboard)
        }

        ignoreNextChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount

        if !item.isPinned && !item.isBurnAfterPaste && item.detectedSensitiveKind != nil {
            scheduleConcealedPasteboardScrubIfNeeded(capturedChangeCount: pasteboard.changeCount, delaySeconds: 45.0)
        }
    }

    /// 统一出口剪贴板隐私门卫：任何二级写回通道（续接拼接、多选合并、模板展开、转换输出、二维码提取）只要含敏感凭据，一律注入 `LocalOnly` 阻断 Handoff 云广播并挂载超时清擦
    private func commitOutboundPasteboardGuard(
        for text: String,
        forceProtected: Bool = false,
        isPinnedSource: Bool = false,
        scrubDelay: TimeInterval = 45.0
    ) {
        let isSens = forceProtected || SensitiveCredentialVeil.classify(text) != nil
        if isSens {
            PasteboardPrivacyStandards.applyLocalOnlyConcealedProtection(to: pasteboard)
        }
        let written = pasteboard.changeCount
        ignoreNextChangeCount = written
        lastChangeCount = written
        if isSens && !isPinnedSource {
            scheduleConcealedPasteboardScrubIfNeeded(capturedChangeCount: written, delaySeconds: scrubDelay)
        }
    }

    func togglePin(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isPinned.toggle()
        let pinned = items[idx].isPinned
        if pinned {
            pendingOTPExpirationTasks[item.id]?.cancel()
            pendingOTPExpirationTasks.removeValue(forKey: item.id)
            if items[idx].pinCategory == nil {
                items[idx].pinCategory = PinCategory.infer(alias: items[idx].customAlias, text: items[idx].text)
            }
        } else {
            items[idx].pinCategory = nil
        }
        items = sortItems(items)
        saveHistory()
        TactileFeedbackEngine.shared.perform(pinned ? .favoriteOn : .favoriteOff)
        showToast(pinned ? "已收藏" : "已取消收藏")
    }

    func delete(_ item: ClipItem, userInitiated: Bool = true) {
        pendingOTPExpirationTasks[item.id]?.cancel()
        pendingOTPExpirationTasks.removeValue(forKey: item.id)
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: idx)
        evictItemMemoryCaches(for: removed)
        #if ICLIP_EDITION_FLOW
        pasteQueueIDs.removeAll { $0 == removed.id }
        selectedMergeIDs.removeAll { $0 == removed.id }
        #endif
        saveHistory(allowEmptyBackup: true)

        // 「所删即所净」：若当前系统剪贴板正好停留在该被删敏感/即焚内容上，同步清空系统剪贴板残留
        if let curPB = pasteboard.string(forType: .string),
           let raw = removed.text,
           curPB == raw,
           (removed.detectedSensitiveKind != nil || removed.isBurnAfterPaste || removed.detectedPoisonThreat != nil) {
            pasteboard.clearContents()
            ignoreNextChangeCount = pasteboard.changeCount
            lastChangeCount = pasteboard.changeCount
        }

        // 立即清理可能存在的拖拽明文导出副本
        DragFileExportHelper.purgeExportedFiles(for: removed)

        if userInitiated {
            TactileFeedbackEngine.shared.perform(.deleteItem)
            if removed.isBurnAfterPaste {
                // 粘贴即焚机密手动删除时立即物理擦除，不进入 8s 内存撤销缓冲
                if !items.contains(where: { $0.contentHash == removed.contentHash }) {
                    AdaptiveIntelligenceEngine.shared.forgetContentHashes([removed.contentHash])
                }
                deleteImageFileIfNeeded(for: removed)
                showToast("已彻底销毁即焚记录", duration: 2.8)
                return
            }
            stageDeletionUndoBuffer([removed])
            if let bid = removed.sourceAppBundleID,
               let appName = removed.sourceAppName,
               !ignoredBundleIDSet.contains(bid) {
                let now = ProcessInfo.processInfo.systemUptime
                let prev = sourceAppDeleteStreaks[bid]
                let newCount = (prev != nil && (now - prev!.lastAt) < 180.0) ? (prev!.count + 1) : 1
                sourceAppDeleteStreaks[bid] = (appName, newCount, now)
                if newCount == 3 {
                    showToast("已连续清理「\(appName)」记录，右键卡片可一键永久忽略该应用", duration: 4.0)
                    return
                }
            }
            showToast("已删除 · 按 ⌘Z 撤销", duration: 3.4)
        } else {
            if !items.contains(where: { $0.contentHash == removed.contentHash }) {
                AdaptiveIntelligenceEngine.shared.forgetContentHashes([removed.contentHash])
            }
            deleteImageFileIfNeeded(for: removed)
        }
    }

    func clearUnpinned() {
        let toRemove = items.filter { !$0.isPinned && !$0.isPendingTodo }
        guard !toRemove.isEmpty else { return }
        for item in toRemove {
            evictItemMemoryCaches(for: item)
        }
        DragFileExportHelper.wipeAllExports()
        #if ICLIP_EDITION_FLOW
        let removedIDs = Set(toRemove.map(\.id))
        pasteQueueIDs.removeAll { removedIDs.contains($0) }
        selectedMergeIDs.removeAll { removedIDs.contains($0) }
        #endif
        items = items.filter { $0.isPinned || $0.isPendingTodo }
        saveHistory(allowEmptyBackup: true)
        TactileFeedbackEngine.shared.perform(.deleteItem)
        stageDeletionUndoBuffer(toRemove)
        showToast("已清空 \(toRemove.count) 条 · 按 ⌘Z 撤销", duration: 4.2)
    }

    /// 暂存被删条目并延迟 8 秒物理清理图片，支持手滑后按 ⌘Z 或点击胶囊零损原位恢复
    private func stageDeletionUndoBuffer(_ newlyRemoved: [ClipItem]) {
        flushPendingUndoImages()
        undoRemovedItems = newlyRemoved
        canUndoLastDeletion = true

        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingUndoImages()
        }
        undoPurgeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)
    }

    private func flushPendingUndoImages() {
        undoPurgeWorkItem?.cancel()
        undoPurgeWorkItem = nil
        guard !undoRemovedItems.isEmpty else {
            canUndoLastDeletion = false
            return
        }
        let activeHashes = Set(items.map(\.contentHash))
        let deadHashes = Set(undoRemovedItems.map(\.contentHash)).subtracting(activeHashes)
        AdaptiveIntelligenceEngine.shared.forgetContentHashes(deadHashes)
        for item in undoRemovedItems where !activeHashes.contains(item.contentHash) {
            deleteImageFileIfNeeded(for: item)
        }
        undoRemovedItems.removeAll()
        canUndoLastDeletion = false
    }

    /// 撤销最近一次删除或清空操作（⌘Z）
    @discardableResult
    func undoLastDeletion() -> Bool {
        guard canUndoLastDeletion, !undoRemovedItems.isEmpty else { return false }
        undoPurgeWorkItem?.cancel()
        undoPurgeWorkItem = nil

        let existingIDs = Set(items.map(\.id))
        let toRestore = undoRemovedItems.filter { !existingIDs.contains($0.id) }
        undoRemovedItems.removeAll()
        canUndoLastDeletion = false
        guard !toRestore.isEmpty else { return false }

        items = sortItems(items + toRestore)
        saveHistory()
        TactileFeedbackEngine.shared.perform(.favoriteOn)
        showToast("已恢复 \(toRestore.count) 条记录")
        return true
    }

    /// 将即时速算结果写入系统剪贴板并按需键入外部目标窗口
    func pasteInstantValue(
        _ valueText: String,
        toast: String,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        pasteboard.clearContents()
        pasteboard.setString(valueText, forType: .string)
        ignoreNextChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount

        let hash = Self.sha256(valueText)
        let item = ClipItem(
            type: .text,
            text: valueText,
            contentHash: "text:\(hash)",
            sourceAppName: "iClip 速算"
        )
        insertOrPromote(item)

        TactileFeedbackEngine.shared.perform(.pasteCommit)
        onBeforePaste?()
        refreshAccessibilityStatus()
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
            showToast(toast)
        } else {
            showToast("\(toast)（已复制）")
        }
    }

    /// 将 `@pw` / `@genkey` 或离线 2FA 动态码无痕键入目标输入框（不写入历史列表、阻断 Handoff 云同步、到期自动清擦剪贴板）
    func pasteEphemeralSecret(
        _ secretValue: String,
        toast: String,
        scrubDelaySeconds: TimeInterval = 45.0,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        SecurePasswordGenerator.bumpGenerationSalt()
        pasteboard.clearContents()
        pasteboard.setString(secretValue, forType: .string)
        PasteboardPrivacyStandards.applyLocalOnlyConcealedProtection(to: pasteboard)
        let writtenCount = pasteboard.changeCount
        ignoreNextChangeCount = writtenCount
        lastChangeCount = writtenCount
        scheduleConcealedPasteboardScrubIfNeeded(capturedChangeCount: writtenCount, delaySeconds: scrubDelaySeconds)

        TactileFeedbackEngine.shared.perform(.pasteCommit)
        onBeforePaste?()
        refreshAccessibilityStatus()
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
            showToast(toast)
        } else {
            showToast("\(toast)（已复制）")
        }
    }

    var latestPlainTextForCapsuleLock: String? {
        items.first(where: { item in
            guard let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }
            return !SecretCapsuleMessenger.containsCapsule(t)
        })?.text
    }

    func latestCapsuleText(prioritizing selectedItem: ClipItem? = nil) -> String? {
        if let sel = selectedItem, let t = sel.text, SecretCapsuleMessenger.containsCapsule(t) {
            return t
        }
        return items.first(where: { SecretCapsuleMessenger.containsCapsule($0.text) })?.text
    }

    /// 将端到端加锁后的 `ICLPMSG1:` 密文信封直接键入外部聊天/邮件窗口（明文绝不写入历史库）
    func pasteLockedCapsuleEnvelope(
        plainText: String,
        passphrase: String,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        guard let envelope = SecretCapsuleMessenger.sealCapsule(plainText: plainText, passphrase: passphrase) else {
            showToast("加密失败：请检查口令与正文")
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(envelope, forType: .string)
        let written = pasteboard.changeCount
        ignoreNextChangeCount = written
        lastChangeCount = written

        TactileFeedbackEngine.shared.perform(.magicTransform)
        onBeforePaste?()
        refreshAccessibilityStatus()
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
            showToast("已生成端到端加密信封并键入（对方输入口令即可解锁）")
        } else {
            showToast("已复制端到端加密信封到剪贴板")
        }
    }

    // MARK: - 收藏话术与模板离线归档迁移（.iclip）

    var pinnedItemCount: Int {
        items.filter(\.isPinned).count
    }

    var pinnedSensitiveItemCount: Int {
        items.filter { $0.isPinned && $0.detectedSensitiveKind != nil }.count
    }

    func exportPinnedArchive(to destinationURL: URL, passphrase: String? = nil) throws -> Int {
        let data = try ArchiveBackupService.exportPinnedArchiveData(
            from: items,
            imagesDirectoryURL: imagesDirectoryURL,
            passphrase: passphrase
        )
        try data.write(to: destinationURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        return pinnedItemCount
    }

    func importPinnedArchive(from sourceURL: URL, passphrase: String? = nil) throws -> ArchiveImportSummary {
        let data = try Data(contentsOf: sourceURL)
        let (merged, summary) = try ArchiveBackupService.mergeArchiveData(
            data,
            into: items,
            imagesDirectoryURL: imagesDirectoryURL,
            passphrase: passphrase,
            fileExtensionHint: sourceURL.pathExtension
        )
        self.items = sortItems(merged)
        saveHistory(immediate: true)
        return summary
    }

    func showToast(_ message: String, duration: TimeInterval = 1.6) {
        toastWorkItem?.cancel()
        toastMessage = message
        let work = DispatchWorkItem { [weak self] in
            self?.toastMessage = nil
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - 极客开发版专属能力（微秒级语义总线 + 密钥脱敏 + 动态模板）

    #if !ICLIP_EDITION_FLOW
    func semanticSnapshot(for item: ClipItem) -> SemanticSnapshot {
        guard !minimalModeEnabled, (item.type == .text || item.type == .link) else { return .empty }
        let isExternalAI = SensitiveCredentialVeil.isExternalAIOrChatApp(activeTargetAppName)
        let cacheKey = "\(item.contentHash)|\(item.sourceAppName ?? "")|\(isExternalAI ? "ext" : "std")" as NSString
        if let cached = semanticCache.object(forKey: cacheKey) {
            return cached.snapshot
        }
        let analyzed = SemanticEngine.analyze(item)
        var baseActions = analyzed.actions
        var resolvedKind = analyzed.primaryKind

        // 剪贴板投毒（Bidi / ANSI 控制符）与网页零宽幽灵字符净化胶囊
        if let raw = item.text, let threat = item.detectedPoisonThreat {
            let cleanText = ClipboardPoisonGuard.sanitize(raw)
            if cleanText != raw && !cleanText.isEmpty {
                let (title, isHighRisk): (String, Bool) = {
                    switch threat {
                    case .pastejackingOrBidi:
                        return ("净化隐藏控制符", true)
                    case .zeroWidthGhost(let n):
                        return ("清除 \(n) 个零宽字符", false)
                    }
                }()
                baseActions.insert(
                    TransformAction(
                        id: "sanitize-invisible-poison",
                        title: title,
                        symbolName: isHighRisk ? "exclamationmark.shield.fill" : "sparkles",
                        isSecurityAction: isHighRisk,
                        resultText: cleanText,
                        toastText: isHighRisk ? "已彻底剥离隐藏控制符与双向伪装符" : "已清除隐藏零宽幽灵字符"
                    ),
                    at: 0
                )
            }
        }

        // 兜底身份证/银行卡等高敏凭据的通用脱敏胶囊
        if let raw = item.text, item.detectedSensitiveKind != nil,
           !baseActions.contains(where: { $0.id.hasPrefix("redact-") }) {
            let redacted = SensitiveCredentialVeil.redactForExternalSharing(raw)
            if redacted != raw {
                if resolvedKind == nil { resolvedKind = .sensitiveSecret }
                baseActions.insert(
                    TransformAction(
                        id: "redact-secrets",
                        title: isExternalAI ? "防泄密脱敏" : "脱敏粘贴",
                        symbolName: "lock.shield",
                        isSecurityAction: true,
                        resultText: redacted,
                        toastText: "已自动掩码敏感凭据与隐私后键入"
                    ),
                    at: 0
                )
            }
        }

        var rankedActions = AdaptiveIntelligenceEngine.shared.rankActions(
            baseActions,
            idOf: \.id,
            sourceApp: item.sourceAppName
        )

        // 外发 AI 助手 / 公域聊天软件防泄密护航：自动将安全脱敏胶囊提升为 #1 首选动作（⇧↵ 一键脱敏直发）
        if isExternalAI, let secIdx = rankedActions.firstIndex(where: { $0.isSecurityAction || $0.id.hasPrefix("redact-") }) {
            let sec = rankedActions.remove(at: secIdx)
            let upgraded = TransformAction(
                id: sec.id,
                title: sec.id == "redact-secrets" ? "防泄密脱敏" : sec.title,
                symbolName: sec.symbolName,
                isSecurityAction: true,
                resultText: sec.resultText,
                toastText: sec.toastText
            )
            rankedActions.insert(upgraded, at: 0)
        }

        let personalized = SemanticSnapshot(
            primaryKind: resolvedKind,
            parsedColorRGBA: analyzed.parsedColorRGBA,
            actions: rankedActions
        )
        if let raw = item.text, let totp = TOTPAuthenticator.evaluate(uri: raw) {
            var liveActions = personalized.actions
            let totpChip = TransformAction(
                id: "totp-live-code",
                title: "动态码 \(totp.formattedCode) · \(totp.remainingSeconds)s",
                symbolName: "key.viewfinder",
                isSecurityAction: false,
                resultText: totp.code,
                toastText: "已算出 2FA 动态码 \(totp.formattedCode) 并无痕键入"
            )
            if isExternalAI, !liveActions.isEmpty, liveActions[0].isSecurityAction {
                liveActions.insert(totpChip, at: 1)
            } else {
                liveActions.insert(totpChip, at: 0)
            }
            return SemanticSnapshot(
                primaryKind: resolvedKind ?? .ephemeralOTP,
                parsedColorRGBA: analyzed.parsedColorRGBA,
                actions: liveActions
            )
        }
        semanticCache.setObject(SemanticSnapshotBox(personalized), forKey: cacheKey)
        return personalized
    }

    func applyTransformAction(
        _ action: TransformAction,
        for item: ClipItem,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        AdaptiveIntelligenceEngine.shared.recordActionUsed(
            actionID: action.id,
            sourceApp: item.sourceAppName
        )
        if action.id == "todo-split-checklist" {
            _ = splitChecklistIntoTodos(from: item)
            return
        }
        if action.id == "totp-live-code", let raw = item.text, let fresh = TOTPAuthenticator.evaluate(uri: raw) {
            pasteEphemeralSecret(
                fresh.code,
                toast: "已键入 2FA 动态码 \(fresh.formattedCode)（剩 \(fresh.remainingSeconds)s · 30s 后擦除）",
                scrubDelaySeconds: 30.0,
                shouldAutoPaste: shouldAutoPaste,
                onBeforePaste: onBeforePaste
            )
            return
        }
        let htmlPayload = (action.id == "tbl-md-to-excel") ? TableBridgeEngine.toHTMLTable(fromTSV: action.resultText) : nil
        pasteCustomString(
            action.resultText,
            htmlTable: htmlPayload,
            sourceItem: item,
            toast: action.toastText,
            shouldAutoPaste: shouldAutoPaste,
            onBeforePaste: onBeforePaste
        )
    }

    func addPinnedTemplate(_ content: String) {
        captureQuickNote(body: content, alias: nil, pin: true)
    }
    #endif

    // MARK: - 双角色共享：一行闪念速记、动态模板求值、自定义串键入与备注别名

    func latestNonTemplateText(excluding itemID: UUID) -> String? {
        for candidate in items where candidate.id != itemID {
            if let t = candidate.text, !SnippetTemplateEngine.containsPlaceholders(t) {
                return t
            }
            if let paths = candidate.filePaths, !paths.isEmpty {
                return paths.joined(separator: "\n")
            }
        }
        return nil
    }

    /// 将用户在搜索框输入的速记或模板一步写入系统剪贴板并收录（支持同时绑定备注别名与直接收藏）
    @discardableResult
    func captureQuickNote(body: String, alias: String?, pin: Bool) -> Bool {
        let rawTrimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmed.isEmpty else { return false }
        let expandedSecret = SecurePasswordGenerator.expandQuickCaptureBodyIfApplicable(rawTrimmed)
        let trimmed = expandedSecret ?? rawTrimmed

        let cleanAlias: String? = {
            guard let a = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { return nil }
            return a
        }()
        let isTemplate = expandedSecret == nil && SnippetTemplateEngine.containsPlaceholders(trimmed)
        let isLink = !isTemplate && expandedSecret == nil && isValidWebURL(trimmed)
        let prefix = isTemplate ? "tpl" : (isLink ? "link" : "text")
        let contentHash = "\(prefix):\(Self.sha256(trimmed))"

        let newID = UUID()
        let clipboardValue = isTemplate
            ? SnippetTemplateEngine.render(template: trimmed, latestContextText: latestNonTemplateText(excluding: newID))
            : trimmed

        pasteboard.clearContents()
        pasteboard.setString(clipboardValue, forType: .string)
        if isLink {
            pasteboard.setString(clipboardValue, forType: .URL)
        }
        if expandedSecret != nil || SensitiveCredentialVeil.classify(clipboardValue) != nil {
            PasteboardPrivacyStandards.applyLocalOnlyConcealedProtection(to: pasteboard)
        }
        let writtenCount = pasteboard.changeCount
        ignoreNextChangeCount = writtenCount
        lastChangeCount = writtenCount
        if !pin && (expandedSecret != nil || SensitiveCredentialVeil.classify(clipboardValue) != nil) {
            scheduleConcealedPasteboardScrubIfNeeded(capturedChangeCount: writtenCount, delaySeconds: 45.0)
        }

        let inferredCategory = pin ? PinCategory.infer(alias: cleanAlias, text: trimmed) : nil
        let newItem = ClipItem(
            id: newID,
            type: isLink ? .link : .text,
            text: trimmed,
            contentHash: contentHash,
            sourceAppName: isTemplate ? "iClip 模板" : "iClip 速记",
            isPinned: pin,
            pinCategory: inferredCategory,
            customAlias: cleanAlias
        )
        insertOrPromote(newItem)
        if let idx = items.firstIndex(where: { $0.contentHash == contentHash }) {
            if pin {
                items[idx].isPinned = true
                if items[idx].pinCategory == nil {
                    items[idx].pinCategory = inferredCategory
                }
            }
            if let cleanAlias {
                items[idx].customAlias = cleanAlias
            }
            items = sortItems(items)
            saveHistory()
        }

        TactileFeedbackEngine.shared.perform(pin ? .favoriteOn : .pasteCommit)
        if pin {
            if let cleanAlias {
                showToast("已收藏「\(cleanAlias)」并复制到剪贴板")
            } else {
                showToast(isTemplate ? "已保存并收藏动态模板" : "已存入收藏并复制到剪贴板")
            }
        } else {
            showToast("已存入剪贴板与历史顶部")
        }
        return true
    }

    // MARK: - 轻量直觉待办清单（复制即收件 · 用完即勾销 · 24h 自动新陈代谢）

    var pendingTodoCount: Int {
        items.reduce(0) { $0 + ($1.isPendingTodo ? 1 : 0) }
    }

    var completedTodoCount: Int {
        items.reduce(0) { $0 + ($1.isTodoCompleted ? 1 : 0) }
    }

    /// 纯函数：将所有待办按「未完成 `- [ ]` → 已完成 `- [x]`」渲染为干净的 Markdown 任务清单，方便贴入周报/飞书
    nonisolated static func formatTodosAsMarkdownChecklist(from sourceItems: [ClipItem]) -> String? {
        let todos = sourceItems.filter(\.isTodo)
        guard !todos.isEmpty else { return nil }
        let ordered = todos.sorted { lhs, rhs in
            if lhs.isTodoCompleted != rhs.isTodoCompleted {
                return !lhs.isTodoCompleted
            }
            if lhs.isTodoCompleted {
                return (lhs.todoCompletedAt ?? lhs.createdAt) > (rhs.todoCompletedAt ?? rhs.createdAt)
            }
            return lhs.createdAt > rhs.createdAt
        }
        let lines: [String] = ordered.map { item in
            let prefix = item.isTodoCompleted ? "- [x] " : "- [ ] "
            let alias = item.customAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawFlat = item.rawContentPreview
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let alias, !alias.isEmpty {
                if item.type == .link || (item.type == .text && alias != rawFlat && rawFlat.count <= 100) {
                    return "\(prefix)\(alias) — \(rawFlat)"
                }
                return "\(prefix)\(alias)"
            }
            return "\(prefix)\(rawFlat)"
        }
        return lines.joined(separator: "\n")
    }

    /// 一键将当前待办清单复制为标准 Markdown 任务列表（静默防自吞，不污染剪贴历史顶部）
    @discardableResult
    func copyTodosAsMarkdownChecklist() -> Int {
        guard let md = Self.formatTodosAsMarkdownChecklist(from: items) else { return 0 }
        let total = items.reduce(0) { $0 + ($1.isTodo ? 1 : 0) }
        let hasSensitiveTodo = items.contains { $0.isTodo && ($0.detectedSensitiveKind != nil || $0.isBurnAfterPaste) }
        pasteboard.clearContents()
        pasteboard.setString(md, forType: .string)
        commitOutboundPasteboardGuard(for: md, forceProtected: hasSensitiveTodo, isPinnedSource: false)
        TactileFeedbackEngine.shared.perform(.pasteCommit)
        showToast("✓ 已复制 \(total) 条 Markdown 待办清单")
        return total
    }

    /// 搜索框闪念直存待办：默认不覆盖系统剪贴板，避免冲掉用户手头正在粘贴的代码或资料
    @discardableResult
    func captureQuickTodo(body: String, alias: String?, copyToClipboard: Bool = false) -> Bool {
        let rawTrimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedBody = TodoChecklistExtractor.cleanLeadingCheckboxIfPresent(rawTrimmed)
        guard !cleanedBody.isEmpty else { return false }

        let cleanAlias: String? = {
            guard let a = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { return nil }
            return a
        }()
        let isLink = isValidWebURL(cleanedBody)
        let prefix = isLink ? "link" : "text"
        let contentHash = "\(prefix):\(Self.sha256(cleanedBody))"

        if copyToClipboard {
            pasteboard.clearContents()
            pasteboard.setString(cleanedBody, forType: .string)
            if isLink {
                pasteboard.setString(cleanedBody, forType: .URL)
            }
            ignoreNextChangeCount = pasteboard.changeCount
            lastChangeCount = pasteboard.changeCount
        }

        if let existingIdx = items.firstIndex(where: { $0.contentHash == contentHash }) {
            items[existingIdx].createdAt = Date()
            items[existingIdx].isTodo = true
            items[existingIdx].todoCompletedAt = nil
            if let cleanAlias {
                items[existingIdx].customAlias = cleanAlias
            }
            items = sortItems(items)
            saveHistory()
        } else {
            let newItem = ClipItem(
                type: isLink ? .link : .text,
                text: cleanedBody,
                contentHash: contentHash,
                sourceAppName: "iClip 待办",
                isTodoItem: true,
                todoCompletedAt: nil
            )
            var finalItem = newItem
            finalItem.customAlias = cleanAlias
            items.insert(finalItem, at: 0)
            items = sortItems(items)
            trimHistoryIfNeeded()
            saveHistory()
        }

        TactileFeedbackEngine.shared.perform(.favoriteOn)
        showToast(copyToClipboard ? "✓ 已加入待办并复制到剪贴板" : "✓ 已加入待办（⌥2 查看）")
        return true
    }

    /// ⌘T 核心循环：普通记录 → 未完成待办 → 已完成待办 → 恢复未完成
    func toggleTodo(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        pendingOTPExpirationTasks[item.id]?.cancel()
        pendingOTPExpirationTasks.removeValue(forKey: item.id)

        if !items[idx].isTodo {
            items[idx].isTodo = true
            items[idx].todoCompletedAt = nil
            saveHistory()
            TactileFeedbackEngine.shared.perform(.favoriteOn)
            showToast("已加入待办 · 按 ⌥2 查看")
        } else if items[idx].todoCompletedAt == nil {
            items[idx].todoCompletedAt = Date()
            saveHistory()
            TactileFeedbackEngine.shared.perform(.pasteCommit)
            showToast("✓ 已完成待办 · 24h 后自动归档")
        } else {
            items[idx].todoCompletedAt = nil
            saveHistory()
            TactileFeedbackEngine.shared.perform(.favoriteOn)
            showToast("已恢复为未完成待办")
        }
    }

    /// 点击待办卡片左侧圆环勾选框：直接切换未完成 / 已完成
    func toggleTodoCompletion(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if !items[idx].isTodo {
            items[idx].isTodo = true
            items[idx].todoCompletedAt = nil
            saveHistory()
            TactileFeedbackEngine.shared.perform(.favoriteOn)
            return
        }
        if items[idx].todoCompletedAt == nil {
            items[idx].todoCompletedAt = Date()
            saveHistory()
            TactileFeedbackEngine.shared.perform(.pasteCommit)
        } else {
            items[idx].todoCompletedAt = nil
            saveHistory()
            TactileFeedbackEngine.shared.perform(.favoriteOn)
        }
    }

    /// 粘贴待办并顺手标记已完成（⌘↵）
    func markTodoCompletedSilently(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }), items[idx].isPendingTodo else { return }
        items[idx].todoCompletedAt = Date()
        saveHistory()
    }

    /// 从待办清单移出（保留原剪贴历史不误删）
    func removeFromTodo(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }), items[idx].isTodo else { return }
        items[idx].isTodo = false
        items[idx].todoCompletedAt = nil
        saveHistory()
        TactileFeedbackEngine.shared.perform(.favoriteOff)
        showToast("已移出待办清单")
    }

    /// 一键归档所有已完成的待办（退回普通历史列表）
    @discardableResult
    func archiveCompletedTodos() -> Int {
        var count = 0
        for idx in items.indices where items[idx].isTodoCompleted {
            items[idx].isTodo = false
            items[idx].todoCompletedAt = nil
            count += 1
        }
        guard count > 0 else { return 0 }
        saveHistory()
        TactileFeedbackEngine.shared.perform(.tabSwitch)
        showToast("已归档 \(count) 条已完成待办")
        return count
    }

    /// 自动新陈代谢：完成满 24 小时的待办静默退回普通历史记录，保持清单清爽不积灰
    @discardableResult
    func archiveExpiredCompletedTodos(now: Date = Date(), maxCompletedAge: TimeInterval = 86_400) -> Int {
        var archived = 0
        for idx in items.indices {
            if items[idx].isTodo,
               let doneAt = items[idx].todoCompletedAt,
               now.timeIntervalSince(doneAt) >= maxCompletedAge {
                items[idx].isTodo = false
                items[idx].todoCompletedAt = nil
                archived += 1
            }
        }
        if archived > 0 {
            saveHistory()
        }
        return archived
    }

    /// 将多行清单剪贴记录一键拆解为多条独立可勾选的待办事项
    @discardableResult
    func splitChecklistIntoTodos(from item: ClipItem) -> Int {
        guard let raw = item.text else { return 0 }
        let extracted = TodoChecklistExtractor.extractChecklistItems(from: raw)
        guard extracted.count >= 2 else { return 0 }

        let baseDate = Date()
        var createdCount = 0
        // 逆序插入并错开微秒时间戳，使原清单第 1 行排在待办顶部第 1 条
        for (revOffset, line) in extracted.reversed().enumerated() {
            let isLink = isValidWebURL(line)
            let prefix = isLink ? "link" : "text"
            let hash = "\(prefix):\(Self.sha256(line))"
            let itemDate = baseDate.addingTimeInterval(Double(revOffset) * 0.001)

            if let existingIdx = items.firstIndex(where: { $0.contentHash == hash }) {
                items[existingIdx].createdAt = itemDate
                items[existingIdx].isTodo = true
                items[existingIdx].todoCompletedAt = nil
            } else {
                let todoItem = ClipItem(
                    type: isLink ? .link : .text,
                    text: line,
                    contentHash: hash,
                    sourceAppName: item.sourceAppName ?? "清单拆解",
                    createdAt: itemDate,
                    isTodoItem: true,
                    todoCompletedAt: nil
                )
                items.insert(todoItem, at: 0)
            }
            createdCount += 1
        }

        items = sortItems(items)
        trimHistoryIfNeeded()
        #if !ICLIP_EDITION_FLOW
        semanticCache.removeAllObjects()
        #else
        financeCache.removeAllObjects()
        #endif
        saveHistory()
        TactileFeedbackEngine.shared.perform(.magicTransform)
        showToast("✓ 已拆解为 \(createdCount) 条待办（按 ⌥2 查看）")
        return createdCount
    }

    func pasteCustomString(
        _ text: String,
        htmlTable: String? = nil,
        sourceItem: ClipItem,
        toast: String,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let htmlTable {
            pasteboard.setString(text, forType: .tabularText)
            pasteboard.setString(htmlTable, forType: .html)
        }
        commitOutboundPasteboardGuard(
            for: text,
            forceProtected: sourceItem.isBurnAfterPaste,
            isPinnedSource: sourceItem.isPinned
        )

        if shouldAutoPaste {
            recordTargetAppPasteIfAppropriate(for: sourceItem)
        }
        if let idx = items.firstIndex(where: { $0.id == sourceItem.id }) {
            items[idx].createdAt = Date()
            items = sortItems(items)
            saveHistory()
        }

        TactileFeedbackEngine.shared.perform(.magicTransform)
        onBeforePaste?()
        scheduleOTPAutoExpireIfNeeded(for: sourceItem)

        refreshAccessibilityStatus()
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
            showToast(toast)
        } else {
            showToast("\(toast)（已复制）")
        }
    }

    func setCustomAlias(_ alias: String?, for item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAlias = (trimmed?.isEmpty == false)
        items[idx].customAlias = hasAlias ? trimmed : nil

        var autoPinnedNow = false
        if hasAlias {
            if !items[idx].isPinned && !items[idx].isTodo {
                items[idx].isPinned = true
                autoPinnedNow = true
                pendingOTPExpirationTasks[item.id]?.cancel()
                pendingOTPExpirationTasks.removeValue(forKey: item.id)
                TactileFeedbackEngine.shared.perform(.favoriteOn)
            }
            if items[idx].isPinned && items[idx].pinCategory == nil {
                items[idx].pinCategory = PinCategory.infer(alias: trimmed, text: items[idx].text)
            }
        }
        saveHistory()
        if autoPinnedNow {
            showToast("已保存备注并自动收藏保护")
        } else {
            showToast(hasAlias ? (items[idx].isTodo ? "已更新待办说明" : "已更新备注标题") : "已清除备注标题")
        }
    }

    /// 纯函数：生成原位微调后的新 ClipItem（保留原 UUID、收藏、分组、待办状态与备注名，自动重算类型与哈希）
    nonisolated static func updatedItem(from existing: ClipItem, withNewText newText: String) -> ClipItem? {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch existing.type {
        case .text, .link:
            let finalIsLink = Self.isValidWebURL(trimmed)
            let newType: ClipContentType = finalIsLink ? .link : .text
            let newHash = "\(finalIsLink ? "link" : "text"):\(Self.sha256(newText))"
            return ClipItem(
                id: existing.id,
                type: newType,
                text: newText,
                contentHash: newHash,
                sourceAppName: existing.sourceAppName,
                createdAt: existing.createdAt,
                isPinned: existing.isPinned,
                pinCategory: existing.pinCategory,
                customAlias: existing.customAlias,
                isTodoItem: existing.isTodoItem,
                todoCompletedAt: existing.todoCompletedAt
            )

        case .image:
            var copy = existing
            copy.ocrText = newText
            copy.ocrChecked = true
            return copy

        case .file:
            return nil
        }
    }

    /// 原位更新剪贴条目正文或实况文本（完整保留原 UUID、收藏状态、场景分类与备注别名）
    @discardableResult
    func updateItemText(_ newText: String, for item: ClipItem) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return false }
        guard let updated = Self.updatedItem(from: items[idx], withNewText: newText) else {
            showToast("内容不能为空")
            return false
        }
        items[idx] = updated
        saveHistory()
        showToast(updated.type == .image ? "已更新图片实况文本" : "已原地保存微调内容")
        return true
    }

    /// 跨处选段按 ⌃⌥C 触发全局「续接复制」：自动发送纯净 ⌘C 并将新选段换行衔接至当前剪贴板末尾
    func triggerGlobalCopyAppend() {
        refreshAccessibilityStatus()
        if isAccessibilityGranted {
            let currentClip = pasteboard.string(forType: .string)
                ?? items.first(where: { $0.type == .text || $0.type == .link })?.text
                ?? ""
            pendingCopyAppendBaseText = currentClip
            pendingCopyAppendDeadlineUptime = ProcessInfo.processInfo.systemUptime + 0.75
            let changeCountBefore = pasteboard.changeCount
            Self.simulateCommandC()

            // 85ms 极速收割剪贴板，不等常规轮询；若 220ms 后选区无变化则给出轻提示
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.085) { [weak self] in
                self?.checkPasteboard()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self else { return }
                self.checkPasteboard()
                if ProcessInfo.processInfo.systemUptime <= self.pendingCopyAppendDeadlineUptime,
                   self.pasteboard.changeCount == changeCountBefore {
                    self.pendingCopyAppendDeadlineUptime = -100
                    self.pendingCopyAppendBaseText = nil
                    ActionSparkController.shared.presentTransientNotice(
                        symbolName: "selection.pin.in.out",
                        message: "请先选中要续接的文字再按 ⌃⌥C",
                        duration: 1.2,
                        in: self
                    )
                }
            }
            return
        }

        // 零辅助权限兜底：直接将最近复制的两条文本历史合并为同一剪贴板载荷
        let recentTexts = items.filter { $0.type == .text || $0.type == .link }.prefix(2)
        guard recentTexts.count == 2,
              let newest = recentTexts.first,
              let older = recentTexts.last,
              let tNew = newest.text,
              let tOld = older.text else {
            ActionSparkController.shared.presentTransientNotice(
                symbolName: "hand.raised",
                message: "授权辅助功能后可跨处选字直按 ⌃⌥C 续接",
                duration: 1.5,
                in: self
            )
            return
        }
        copyAppendTargetID = older.id
        copyAppendSegmentCount = 1
        items.removeAll { $0.id == newest.id }
        commitAppendedSegment(incomingText: tNew, explicitBase: tOld, sourceApp: newest.sourceAppName, showGlobalNotice: true)
    }

    /// 在主面板内将指定卡片（⇧⌘C）追加至当前系统剪贴板末尾
    func appendItemToCurrentClipboard(_ item: ClipItem) {
        guard let incoming = CopyAppendHelper.extractAppendableText(from: item) else {
            showToast("该图片暂无可追加的文本内容")
            return
        }
        let currentBase = pasteboard.string(forType: .string) ?? ""
        commitAppendedSegment(incomingText: incoming, explicitBase: currentBase, sourceApp: item.sourceAppName, showGlobalNotice: false)
    }

    private func commitAppendedSegment(
        incomingText: String,
        explicitBase: String,
        sourceApp: String?,
        showGlobalNotice: Bool
    ) {
        let combined = CopyAppendHelper.joinSegments(base: explicitBase, incoming: incomingText)
        let isFirstSegment = explicitBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        copyAppendSegmentCount = isFirstSegment ? 1 : (copyAppendSegmentCount + 1)

        pasteboard.clearContents()
        pasteboard.setString(combined, forType: .string)
        commitOutboundPasteboardGuard(for: combined, forceProtected: false, isPinnedSource: false)

        let finalIsLink = isValidWebURL(combined.trimmingCharacters(in: .whitespacesAndNewlines))
        let newType: ClipContentType = finalIsLink ? .link : .text
        let newHash = "\(finalIsLink ? "link" : "text"):\(Self.sha256(combined))"

        if let targetID = copyAppendTargetID,
           let idx = items.firstIndex(where: { $0.id == targetID }),
           !items[idx].isPinned {
            let existing = items[idx]
            items[idx] = ClipItem(
                id: existing.id,
                type: newType,
                text: combined,
                contentHash: newHash,
                sourceAppName: sourceApp ?? existing.sourceAppName,
                createdAt: Date(),
                isPinned: false,
                pinCategory: existing.pinCategory,
                customAlias: existing.customAlias
            )
            items = sortItems(items)
            saveHistory()
        } else {
            let mergedItem = ClipItem(
                type: newType,
                text: combined,
                contentHash: newHash,
                sourceAppName: sourceApp
            )
            insertOrPromote(mergedItem)
            copyAppendTargetID = items.first(where: { $0.contentHash == newHash })?.id
        }

        TactileFeedbackEngine.shared.perform(.queueToggle(added: true))
        let msg = copyAppendSegmentCount > 1
            ? "已续接第 \(copyAppendSegmentCount) 段 · 直接 ⌘V"
            : "已存入首段 · 再选按 ⌃⌥C 续接"
        if showGlobalNotice {
            ActionSparkController.shared.presentTransientNotice(
                symbolName: "plus.rectangle.on.rectangle.fill",
                message: msg,
                duration: 1.25,
                in: self
            )
        } else {
            showToast(copyAppendSegmentCount > 1 ? "已追加至当前剪贴板（共 \(copyAppendSegmentCount) 段）" : "已写入当前剪贴板")
        }
    }

    // MARK: - 心流办公版专属能力（顺序队列 + 离线实况识图 + 多选合并 + 场景分组）

    #if ICLIP_EDITION_FLOW
    func financeActions(for item: ClipItem) -> [FinanceQuickAction] {
        guard !minimalModeEnabled, item.type == .text, let raw = item.text else { return [] }
        let isExternalAI = SensitiveCredentialVeil.isExternalAIOrChatApp(activeTargetAppName)
        let cacheKey = "\(item.contentHash)|\(item.sourceAppName ?? "")|\(isExternalAI ? "ext" : "std")" as NSString
        if let cached = financeCache.object(forKey: cacheKey) {
            return cached.actions
        }
        var analyzed = MeetingAndEphemeralEngine.analyze(raw)
        if analyzed.isEmpty {
            analyzed = ComplianceCodeEngine.analyze(raw)
        }
        if analyzed.isEmpty {
            analyzed = TableBridgeEngine.analyze(raw)
        }
        if analyzed.isEmpty {
            analyzed = FinanceNumberEngine.analyze(raw)
        }
        if analyzed.isEmpty {
            analyzed = DocumentTypographyEngine.analyze(raw)
        }
        if item.detectedSensitiveKind != nil {
            if let envExample = EnvTemplateSanitizer.generateExampleTemplate(from: raw) {
                analyzed.insert(
                    FinanceQuickAction(
                        id: "env-to-example",
                        title: "生成 .env.example",
                        symbolName: "doc.badge.gearshape",
                        resultText: envExample,
                        toastText: "已生成安全的 .env.example 净模板"
                    ),
                    at: 0
                )
            }
            let redacted = SensitiveCredentialVeil.redactForExternalSharing(raw)
            if redacted != raw {
                analyzed.insert(
                    FinanceQuickAction(
                        id: "redact-secrets",
                        title: isExternalAI ? "防泄密脱敏" : "脱敏粘贴",
                        symbolName: "lock.shield",
                        resultText: redacted,
                        toastText: "已自动掩码密钥与敏感隐私"
                    ),
                    at: 0
                )
            }
        }
        if let threat = item.detectedPoisonThreat {
            let cleanText = ClipboardPoisonGuard.sanitize(raw)
            if cleanText != raw && !cleanText.isEmpty {
                let title: String = {
                    switch threat {
                    case .pastejackingOrBidi: return "净化隐藏控制符"
                    case .zeroWidthGhost(let n): return "清除 \(n) 个零宽字符"
                    }
                }()
                analyzed.insert(
                    FinanceQuickAction(
                        id: "sanitize-invisible-poison",
                        title: title,
                        symbolName: "exclamationmark.shield.fill",
                        resultText: cleanText,
                        toastText: "已清除隐藏控制符与零宽幽灵字符"
                    ),
                    at: 0
                )
            }
        }
        if !item.isTodo {
            let checklist = TodoChecklistExtractor.extractChecklistItems(from: raw)
            if checklist.count >= 2 {
                analyzed.insert(
                    FinanceQuickAction(
                        id: "todo-split-checklist",
                        title: "拆为 \(checklist.count) 条待办",
                        symbolName: "checklist",
                        resultText: raw,
                        toastText: "已拆解为 \(checklist.count) 条待办"
                    ),
                    at: 0
                )
            }
        }
        var ranked = AdaptiveIntelligenceEngine.shared.rankActions(
            analyzed,
            idOf: \.id,
            sourceApp: item.sourceAppName
        )
        if isExternalAI, let secIdx = ranked.firstIndex(where: { $0.id == "redact-secrets" }) {
            let sec = ranked.remove(at: secIdx)
            ranked.insert(sec, at: 0)
        }
        if let totp = TOTPAuthenticator.evaluate(uri: raw) {
            let totpAction = FinanceQuickAction(
                id: "totp-live-code",
                title: "动态码 \(totp.formattedCode) · \(totp.remainingSeconds)s",
                symbolName: "key.viewfinder",
                resultText: totp.code,
                toastText: "已算出 2FA 动态码 \(totp.formattedCode)"
            )
            if isExternalAI, !ranked.isEmpty, ranked[0].id == "redact-secrets" {
                ranked.insert(totpAction, at: 1)
            } else {
                ranked.insert(totpAction, at: 0)
            }
            return ranked
        }
        financeCache.setObject(FinanceActionsBox(ranked), forKey: cacheKey)
        return ranked
    }

    func applyFinanceAction(
        _ action: FinanceQuickAction,
        for item: ClipItem,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        AdaptiveIntelligenceEngine.shared.recordActionUsed(
            actionID: action.id,
            sourceApp: item.sourceAppName
        )
        if action.id == "todo-split-checklist" {
            _ = splitChecklistIntoTodos(from: item)
            return
        }
        if action.id == "totp-live-code", let raw = item.text, let fresh = TOTPAuthenticator.evaluate(uri: raw) {
            pasteEphemeralSecret(
                fresh.code,
                toast: "已键入 2FA 动态码 \(fresh.formattedCode)（剩 \(fresh.remainingSeconds)s · 30s 后擦除）",
                scrubDelaySeconds: 30.0,
                shouldAutoPaste: shouldAutoPaste,
                onBeforePaste: onBeforePaste
            )
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(action.resultText, forType: .string)
        if action.id == "tbl-md-to-excel", let html = TableBridgeEngine.toHTMLTable(fromTSV: action.resultText) {
            pasteboard.setString(action.resultText, forType: .tabularText)
            pasteboard.setString(html, forType: .html)
        }
        commitOutboundPasteboardGuard(
            for: action.resultText,
            forceProtected: item.isBurnAfterPaste,
            isPinnedSource: item.isPinned
        )

        if shouldAutoPaste {
            recordTargetAppPasteIfAppropriate(for: item)
        }
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].createdAt = Date()
            items = sortItems(items)
            saveHistory()
        }

        TactileFeedbackEngine.shared.perform(.magicTransform)
        onBeforePaste?()
        scheduleOTPAutoExpireIfNeeded(for: item)
        refreshAccessibilityStatus()
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
            showToast(action.toastText)
        } else {
            showToast("\(action.toastText)（已复制）")
        }
    }

    func setPinCategory(_ category: PinCategory?, for item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isPinned = true
        items[idx].pinCategory = category
        items = sortItems(items)
        saveHistory()
        if let category {
            showToast("已归入「\(category.title)」收藏槽")
        } else {
            showToast("已设为普通收藏")
        }
    }

    func queuePosition(for item: ClipItem) -> Int? {
        guard let idx = pasteQueueIDs.firstIndex(of: item.id) else { return nil }
        return idx + 1
    }

    var nextQueuedItem: ClipItem? {
        for id in pasteQueueIDs {
            if let found = items.first(where: { $0.id == id }) {
                return found
            }
        }
        return nil
    }

    func toggleQueueMembership(_ item: ClipItem) {
        if let idx = pasteQueueIDs.firstIndex(of: item.id) {
            pasteQueueIDs.remove(at: idx)
            TactileFeedbackEngine.shared.perform(.queueToggle(added: false))
            showToast("已移出顺序队列")
        } else {
            pasteQueueIDs.append(item.id)
            TactileFeedbackEngine.shared.perform(.queueToggle(added: true))
            showToast("已加入顺序队列 #\(pasteQueueIDs.count)")
        }
    }

    func clearPasteQueue() {
        pasteQueueIDs.removeAll()
        showToast("已清空顺序粘贴队列")
    }

    func dequeueAndPasteNext(showGlobalHUD: Bool = false, onBeforePaste: (() -> Void)? = nil) {
        while let firstID = pasteQueueIDs.first {
            pasteQueueIDs.removeFirst()
            if let target = items.first(where: { $0.id == firstID }) {
                let remaining = pasteQueueIDs.count
                let nextVeiled = nextQueuedItem?.displayTitle(minimalMode: minimalModeEnabled, veilActive: true)

                if !minimalModeEnabled,
                   let raw = target.text,
                   case .pastejackingOrBidi = target.detectedPoisonThreat,
                   ClipboardPoisonGuard.isTerminalApp(activeTargetAppName) {
                    let safeCmd = ClipboardPoisonGuard.sanitize(raw)
                    if safeCmd != raw && !safeCmd.isEmpty {
                        pasteboard.clearContents()
                        pasteboard.setString(safeCmd, forType: .string)
                        commitOutboundPasteboardGuard(
                            for: safeCmd,
                            forceProtected: target.detectedSensitiveKind != nil || target.isBurnAfterPaste,
                            isPinnedSource: target.isPinned
                        )
                    } else {
                        writeToPasteboard(target, plainTextOnly: false)
                    }
                } else {
                    writeToPasteboard(target, plainTextOnly: false)
                }

                recordTargetAppPasteIfAppropriate(for: target)
                onBeforePaste?()
                scheduleOTPAutoExpireIfNeeded(for: target)
                scheduleBurnAfterPasteIfNeeded(for: target)
                refreshAccessibilityStatus()
                let sendTabAfter = queueAutoTabEnabled
                if autoPasteEnabled && isAccessibilityGranted {
                    Self.schedulePasteWhenTargetReady(autoTabAfter: sendTabAfter)
                }

                if showGlobalHUD {
                    let veiledTarget = target.displayTitle(minimalMode: minimalModeEnabled, veilActive: true)
                    let shortTitle = veiledTarget.count > 18
                        ? String(veiledTarget.prefix(18)) + "…"
                        : veiledTarget
                    let sub: String
                    if let nextVeiled {
                        let cleanNext = nextVeiled.count > 16 ? String(nextVeiled.prefix(16)) + "…" : nextVeiled
                        sub = "下一项：\(cleanNext)（剩 \(remaining) 项）"
                    } else {
                        sub = "队列已全部键入完毕"
                    }
                    QueueHUDController.shared.show(
                        symbol: "checkmark.circle.fill",
                        title: "已键入：\(shortTitle)",
                        subtitle: sub,
                        tint: .green
                    )
                } else {
                    showToast(remaining > 0 ? "已键入队首 · 剩余 \(remaining) 项" : "顺序队列已全部键入完毕")
                }
                return
            }
        }
        if showGlobalHUD {
            QueueHUDController.shared.show(
                symbol: "list.number",
                title: "顺序粘贴队列为空",
                subtitle: "打开 iClip 开启队列后连续 ⌘C 即可按序采集",
                tint: .orange
            )
        } else {
            showToast("顺序队列当前为空")
        }
    }

    func mergeSelectionRank(for item: ClipItem) -> Int? {
        guard let idx = selectedMergeIDs.firstIndex(of: item.id) else { return nil }
        return idx + 1
    }

    func toggleMergeSelection(_ item: ClipItem) {
        if let idx = selectedMergeIDs.firstIndex(of: item.id) {
            selectedMergeIDs.remove(at: idx)
            TactileFeedbackEngine.shared.perform(.queueToggle(added: false))
        } else {
            selectedMergeIDs.append(item.id)
            TactileFeedbackEngine.shared.perform(.queueToggle(added: true))
        }
    }

    func ensureMergeSelected(_ item: ClipItem) {
        if !selectedMergeIDs.contains(item.id) {
            selectedMergeIDs.append(item.id)
        }
    }

    func clearMergeSelection() {
        selectedMergeIDs.removeAll()
    }

    func mergeAndPasteSelected(
        style: MergeJoinStyle = .paragraphs,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        let sourceItems = selectedMergeIDs.compactMap { id in items.first(where: { $0.id == id }) }
        let anySourceSensitive = sourceItems.contains { $0.detectedSensitiveKind != nil || $0.isBurnAfterPaste }
        let segments: [String] = sourceItems.compactMap { item in
            switch item.type {
            case .text, .link:
                let t = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            case .image:
                let ocr = (item.ocrText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return ocr.isEmpty ? nil : ocr
            case .file:
                let paths = (item.filePaths ?? []).joined(separator: "\n")
                return paths.isEmpty ? nil : paths
            }
        }

        guard !segments.isEmpty else {
            showToast("所选记录不含可合并文本")
            return
        }

        let merged: String
        switch style {
        case .paragraphs:
            merged = segments.joined(separator: "\n\n")
        case .numberedList:
            merged = segments.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        case .singleLine:
            let flat = segments.map { $0.replacingOccurrences(of: "\n", with: " ") }
            merged = flat.joined(separator: "；")
        }

        let count = segments.count
        selectedMergeIDs.removeAll()
        pasteboard.clearContents()
        pasteboard.setString(merged, forType: .string)
        commitOutboundPasteboardGuard(for: merged, forceProtected: anySourceSensitive, isPinnedSource: false)

        onBeforePaste?()
        refreshAccessibilityStatus()
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
            showToast("已按「\(style.title)」合并 \(count) 条并键入")
        } else {
            showToast("已合并 \(count) 条到剪贴板")
        }
    }
    #endif

    // MARK: - 双角色共享：离线二维码直解与实况文本识别（Apple Vision）

    func scheduleBackgroundOCR(forItemID itemID: UUID, fileURL: URL) {
        Task.detached(priority: .utility) { [weak self] in
            let recognized = await VisionOCRService.recognizeText(at: fileURL)
            await MainActor.run { [weak self] in
                guard let self,
                      let idx = self.items.firstIndex(where: { $0.id == itemID }) else {
                    return
                }
                self.items[idx].ocrChecked = true
                if let recognized, !recognized.isEmpty {
                    self.items[idx].ocrText = recognized
                }
                self.saveHistory()
            }
        }
    }

    private func scheduleLegacyOCRBackfill(limit: Int = 20) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            let pending: [(UUID, URL)] = self.items
                .filter { $0.type == .image && $0.ocrChecked != true && $0.ocrText == nil }
                .prefix(limit)
                .compactMap { item in
                    guard let url = self.imageURL(for: item),
                          FileManager.default.fileExists(atPath: url.path) else {
                        return nil
                    }
                    return (item.id, url)
                }

            guard !pending.isEmpty else { return }
            Task.detached(priority: .background) { [weak self] in
                for (id, url) in pending {
                    let qrFound: String? = {
                        guard let raw = LocalVaultCrypto.readDecryptedImageData(at: url) else { return nil }
                        return VisionOCRService.detectBarcodesFast(in: raw)
                    }()
                    let recognized = await VisionOCRService.recognizeText(at: url)
                    await MainActor.run { [weak self] in
                        guard let self,
                              let idx = self.items.firstIndex(where: { $0.id == id }) else {
                            return
                        }
                        self.items[idx].ocrChecked = true
                        if let qrFound, !qrFound.isEmpty, self.items[idx].qrCodePayload == nil {
                            self.items[idx].qrCodePayload = qrFound
                        }
                        if let recognized, !recognized.isEmpty {
                            self.items[idx].ocrText = recognized
                        }
                        self.saveHistory()
                    }
                    try? await Task.sleep(nanoseconds: 180_000_000)
                }
            }
        }
    }

    /// 提取图片中的二维码载荷或离线实况文本并键入（含二维码时优先提取二维码链接/码值）
    func pasteExtractedOCRText(
        for item: ClipItem,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        if let existingQR = item.qrCodePayload?.trimmingCharacters(in: .whitespacesAndNewlines), !existingQR.isEmpty {
            if shouldAutoPaste {
                AdaptiveIntelligenceEngine.shared.recordActionUsed(actionID: "img-qrcode", categoryKey: "qrcode", sourceApp: item.sourceAppName)
                recordTargetAppPasteIfAppropriate(for: item)
            }
            commitPlainStringPaste(existingQR, isQRCode: true, shouldAutoPaste: shouldAutoPaste, onBeforePaste: onBeforePaste)
            return
        }

        if shouldAutoPaste {
            AdaptiveIntelligenceEngine.shared.recordActionUsed(actionID: "img-ocr", categoryKey: "image", sourceApp: item.sourceAppName)
            recordTargetAppPasteIfAppropriate(for: item)
        }
        if let existingOCR = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !existingOCR.isEmpty {
            commitPlainStringPaste(existingOCR, isQRCode: false, shouldAutoPaste: shouldAutoPaste, onBeforePaste: onBeforePaste)
            return
        }

        guard let url = imageURL(for: item) else {
            showToast("未找到原始图片文件")
            return
        }

        showToast("正在离线识别图中二维码与文字...")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let detectedQR: String? = await Task.detached(priority: .userInitiated) {
                guard let data = LocalVaultCrypto.readDecryptedImageData(at: url) else { return nil }
                return VisionOCRService.detectBarcodesFast(in: data)
            }.value

            if let qr = detectedQR, !qr.isEmpty {
                if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[idx].qrCodePayload = qr
                    self.saveHistory()
                }
                self.commitPlainStringPaste(qr, isQRCode: true, shouldAutoPaste: shouldAutoPaste, onBeforePaste: onBeforePaste)
                return
            }

            guard let recognized = await VisionOCRService.recognizeText(at: url),
                  !recognized.isEmpty else {
                self.showToast("未在图片中检测到二维码或文字")
                return
            }
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[idx].ocrChecked = true
                self.items[idx].ocrText = recognized
                self.saveHistory()
            }
            self.commitPlainStringPaste(recognized, isQRCode: false, shouldAutoPaste: shouldAutoPaste, onBeforePaste: onBeforePaste)
        }
    }

    func openImageQRCodeURLIfAvailable(_ item: ClipItem) {
        guard let qr = item.qrCodePayload?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = OutboundLinkSafety.validatedBrowserURL(from: qr) else {
            return
        }
        if FileAndLinkSecurityGuard.inspectLinkRisk(qr) == .homographPhishing {
            showToast("已拦截二维码中的同形异义伪装钓鱼域名", duration: 3.6)
            return
        }
        TactileFeedbackEngine.shared.perform(.openLink)
        NSWorkspace.shared.open(url)
        onAfterOpenExternalURL?()
    }

    private func commitPlainStringPaste(_ text: String, isQRCode: Bool, shouldAutoPaste: Bool, onBeforePaste: (() -> Void)?) {
        let isExternalAI = SensitiveCredentialVeil.isExternalAIOrChatApp(activeTargetAppName)
        // 若图中二维码是 2FA TOTP 绑定码且目标窗口不是外部 AI/聊天工具，直接离线现算当前 6 位动态码无痕键入（绝不将根密钥贴入网页登录框）
        if isQRCode && !isExternalAI, let totp = TOTPAuthenticator.evaluate(uri: text) {
            pasteEphemeralSecret(
                totp.code,
                toast: "已从二维码算出 2FA 动态码 \(totp.formattedCode)（剩 \(totp.remainingSeconds)s · 30s 后擦除）",
                scrubDelaySeconds: 30.0,
                shouldAutoPaste: shouldAutoPaste,
                onBeforePaste: onBeforePaste
            )
            return
        }

        let shouldAutoRedactForAI = isExternalAI && SensitiveCredentialVeil.classify(text) != nil
        let finalOut = shouldAutoRedactForAI ? SensitiveCredentialVeil.redactForExternalSharing(text) : text
        let didRedact = (finalOut != text)

        pasteboard.clearContents()
        pasteboard.setString(finalOut, forType: .string)
        if isQRCode && !didRedact && Self.isValidWebURL(finalOut) && SensitiveCredentialVeil.classify(finalOut) == nil {
            pasteboard.setString(finalOut, forType: .URL)
        }
        commitOutboundPasteboardGuard(for: finalOut, forceProtected: false, isPinnedSource: false)

        onBeforePaste?()
        refreshAccessibilityStatus()
        let noun = didRedact ? "脱敏后图中内容" : (isQRCode ? "图中二维码内容" : "图中文字")
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
            showToast("已提取\(noun)并键入")
        } else {
            showToast("已提取\(noun)到剪贴板")
        }
    }

    // MARK: - 零阻塞图片与文件图标缓存

    /// 后台硬件压缩截图为轻量 JPEG 并键入（解决工单/后台 2MB 上传限制，自动垫白底防透明变黑）
    func pasteCompressedJPEG(
        for item: ClipItem,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        if shouldAutoPaste {
            AdaptiveIntelligenceEngine.shared.recordActionUsed(actionID: "img-compress", categoryKey: "image", sourceApp: item.sourceAppName)
        }
        guard let url = imageURL(for: item),
              let origSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) else {
            showToast("未找到原始截图文件")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let result = ImageStudioEngine.compressToLightweightJPEG(at: url) else {
                await MainActor.run { [weak self] in self?.showToast("图片瘦身转换失败") }
                return
            }
            let savedRatio = origSize > 0 ? max(0, Int(round((1.0 - Double(result.byteCount) / Double(origSize)) * 100))) : 0
            let kb = max(1, result.byteCount / 1024)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pasteboard.clearContents()
                self.pasteboard.setData(result.data, forType: result.utType)
                if let nsImg = NSImage(data: result.data), let tiff = nsImg.tiffRepresentation {
                    self.pasteboard.setData(tiff, forType: .tiff)
                }
                self.ignoreNextChangeCount = self.pasteboard.changeCount
                self.lastChangeCount = self.pasteboard.changeCount

                onBeforePaste?()
                self.refreshAccessibilityStatus()
                let msg = savedRatio > 5 ? "已瘦身 \(savedRatio)%（\(kb) KB）" : "已转为轻量 JPEG（\(kb) KB）"
                if shouldAutoPaste && self.autoPasteEnabled && self.isAccessibilityGranted {
                    Self.schedulePasteWhenTargetReady()
                    self.showToast("\(msg)并键入")
                } else {
                    self.showToast("\(msg)到剪贴板")
                }
            }
        }
    }

    /// 后台硬件渲染苹果风柔光圆角阴影样机衬底并键入
    func pasteAppleMockupImage(
        for item: ClipItem,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        if shouldAutoPaste {
            AdaptiveIntelligenceEngine.shared.recordActionUsed(actionID: "img-mockup", categoryKey: "image", sourceApp: item.sourceAppName)
        }
        guard let url = imageURL(for: item) else {
            showToast("未找到原始截图文件")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let result = ImageStudioEngine.renderAppleMockupFrame(at: url) else {
                await MainActor.run { [weak self] in self?.showToast("样机衬底生成失败") }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pasteboard.clearContents()
                self.pasteboard.setData(result.data, forType: .png)
                self.ignoreNextChangeCount = self.pasteboard.changeCount
                self.lastChangeCount = self.pasteboard.changeCount

                onBeforePaste?()
                self.refreshAccessibilityStatus()
                if shouldAutoPaste && self.autoPasteEnabled && self.isAccessibilityGranted {
                    Self.schedulePasteWhenTargetReady()
                    self.showToast("已生成圆角阴影样机图并键入")
                } else {
                    self.showToast("已生成圆角阴影样机图到剪贴板")
                }
            }
        }
    }

    /// 离线 Vision 坐标级智能隐私打码（自动遮盖截图中的二维码、身份证、银行卡、手机号、邮箱与密钥后键入）
    func pastePrivacyRedactedImage(
        for item: ClipItem,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        if shouldAutoPaste {
            AdaptiveIntelligenceEngine.shared.recordActionUsed(actionID: "img-privacy-mosaic", categoryKey: "security", sourceApp: item.sourceAppName)
        }
        guard let url = imageURL(for: item) else {
            showToast("未找到原始截图文件")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let outcome = ImageStudioEngine.redactSensitiveRegions(at: url) else {
                await MainActor.run { [weak self] in self?.showToast("截图隐私扫描失败") }
                return
            }
            if outcome.redactedCount == 0 {
                await MainActor.run { [weak self] in self?.showToast("未在截图中检出敏感号码、密钥或二维码") }
                return
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pasteboard.clearContents()
                self.pasteboard.setData(outcome.result.data, forType: .png)
                self.ignoreNextChangeCount = self.pasteboard.changeCount
                self.lastChangeCount = self.pasteboard.changeCount

                TactileFeedbackEngine.shared.perform(.magicTransform)
                onBeforePaste?()
                self.refreshAccessibilityStatus()
                if shouldAutoPaste && self.autoPasteEnabled && self.isAccessibilityGranted {
                    Self.schedulePasteWhenTargetReady()
                    self.showToast("已智能打码 \(outcome.redactedCount) 处隐私并键入")
                } else {
                    self.showToast("已智能打码 \(outcome.redactedCount) 处隐私到剪贴板")
                }
            }
        }
    }

    /// 一键抹除照片文件（`.file`）或缓存图片（`.image`）中的 GPS 经纬度与拍摄设备 EXIF 元数据后粘贴
    func pasteMetadataStrippedImage(
        for item: ClipItem,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        let targetInfo: (url: URL, encrypted: Bool)? = {
            if item.type == .image, let u = imageURL(for: item) {
                return (u, true)
            }
            if item.type == .file, let first = item.filePaths?.first {
                return (URL(fileURLWithPath: first), false)
            }
            return nil
        }()
        guard let info = targetInfo else {
            showToast("未找到可处理的图片文件")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let clean = ImageStudioEngine.stripPrivacyMetadata(at: info.url, isEncryptedVaultImage: info.encrypted) else {
                await MainActor.run { [weak self] in self?.showToast("抹除图片隐私元数据失败") }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pasteboard.clearContents()
                self.pasteboard.setData(clean.data, forType: .png)
                self.ignoreNextChangeCount = self.pasteboard.changeCount
                self.lastChangeCount = self.pasteboard.changeCount

                TactileFeedbackEngine.shared.perform(.magicTransform)
                onBeforePaste?()
                self.refreshAccessibilityStatus()
                if shouldAutoPaste && self.autoPasteEnabled && self.isAccessibilityGranted {
                    Self.schedulePasteWhenTargetReady()
                    self.showToast("已抹除 GPS 定位与 EXIF 元数据并键入")
                } else {
                    self.showToast("已复制无定位/无 EXIF 纯净图像")
                }
            }
        }
    }

    func imageURL(for item: ClipItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return imagesDirectoryURL.appendingPathComponent(name)
    }

    func cachedThumbnail(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFileName else { return nil }
        return thumbnailCache.object(forKey: name as NSString)
    }

    func loadThumbnail(for item: ClipItem) async -> NSImage? {
        guard let name = item.imageFileName, let url = imageURL(for: item) else { return nil }
        let cacheKey = name as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decodeImage(at: url, maxPixelSize: 360)
        }.value
        if let decoded {
            thumbnailCache.setObject(decoded, forKey: cacheKey, cost: Self.estimatedCost(of: decoded))
        }
        return decoded
    }

    func prewarmThumbnails(for items: [ClipItem], limit: Int = 18) {
        let targets: [(String, URL)] = items
            .lazy
            .filter { $0.type == .image }
            .prefix(limit)
            .compactMap { item in
                guard let name = item.imageFileName,
                      thumbnailCache.object(forKey: name as NSString) == nil,
                      !inFlightThumbnails.contains(name),
                      let url = imageURL(for: item) else {
                    return nil
                }
                return (name, url)
            }

        guard !targets.isEmpty else { return }
        for (name, _) in targets {
            inFlightThumbnails.insert(name)
        }

        Task.detached(priority: .utility) { [weak self] in
            var results: [(String, NSImage)] = []
            for (name, url) in targets {
                if let img = Self.decodeImage(at: url, maxPixelSize: 360) {
                    results.append((name, img))
                }
            }
            let decodedResults = results
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (name, _) in targets {
                    self.inFlightThumbnails.remove(name)
                }
                for (name, img) in decodedResults {
                    self.thumbnailCache.setObject(img, forKey: name as NSString, cost: Self.estimatedCost(of: img))
                }
            }
        }
    }

    func cachedPreviewImage(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFileName else { return nil }
        return previewCache.object(forKey: name as NSString)
    }

    func loadPreviewImage(for item: ClipItem) async -> NSImage? {
        guard let name = item.imageFileName, let url = imageURL(for: item) else { return nil }
        let cacheKey = name as NSString
        if let cached = previewCache.object(forKey: cacheKey) {
            return cached
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decodeImage(at: url, maxPixelSize: 1080)
        }.value
        if let decoded {
            previewCache.setObject(decoded, forKey: cacheKey, cost: Self.estimatedCost(of: decoded))
        }
        return decoded
    }

    func prewarmPreviewImages(for items: [ClipItem], limit: Int = 6) {
        let targets: [(String, URL)] = items
            .lazy
            .filter { $0.type == .image }
            .prefix(limit)
            .compactMap { item in
                guard let name = item.imageFileName,
                      previewCache.object(forKey: name as NSString) == nil,
                      !inFlightPreviews.contains(name),
                      let url = imageURL(for: item) else {
                    return nil
                }
                return (name, url)
            }

        guard !targets.isEmpty else { return }
        for (name, _) in targets {
            inFlightPreviews.insert(name)
        }

        Task.detached(priority: .utility) { [weak self] in
            var results: [(String, NSImage)] = []
            for (name, url) in targets {
                if let img = Self.decodeImage(at: url, maxPixelSize: 1080) {
                    results.append((name, img))
                }
            }
            let decodedResults = results
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (name, _) in targets {
                    self.inFlightPreviews.remove(name)
                }
                for (name, img) in decodedResults {
                    self.previewCache.setObject(img, forKey: name as NSString, cost: Self.estimatedCost(of: img))
                }
            }
        }
    }

    nonisolated static func decodeImage(at url: URL, maxPixelSize: Int) -> NSImage? {
        guard let imgData = LocalVaultCrypto.readDecryptedImageData(at: url),
              let source = CGImageSourceCreateWithData(imgData as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }

    nonisolated private static func pixelDimensions(from data: Data) -> (width: Int?, height: Int?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        let w = props[kCGImagePropertyPixelWidth] as? Int
        let h = props[kCGImagePropertyPixelHeight] as? Int
        return (w, h)
    }

    nonisolated private static func estimatedCost(of image: NSImage) -> Int {
        let pixels = max(1, Int(image.size.width) * Int(image.size.height))
        return pixels * 4
    }

    func fileIcon(for item: ClipItem) -> NSImage {
        guard let first = item.filePaths?.first else {
            return NSWorkspace.shared.icon(for: .data)
        }
        let cacheKey = first as NSString
        if let cached = fileIconCache.object(forKey: cacheKey) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: first)
        fileIconCache.setObject(icon, forKey: cacheKey)
        return icon
    }

    private func evictItemMemoryCaches(for item: ClipItem) {
        let appPart = item.sourceAppName ?? ""
        let stdKey = "\(item.contentHash)|\(appPart)|std" as NSString
        let extKey = "\(item.contentHash)|\(appPart)|ext" as NSString
        #if !ICLIP_EDITION_FLOW
        semanticCache.removeObject(forKey: stdKey)
        semanticCache.removeObject(forKey: extKey)
        #else
        financeCache.removeObject(forKey: stdKey)
        financeCache.removeObject(forKey: extKey)
        #endif
    }

    private func deleteImageFileIfNeeded(for item: ClipItem) {
        if let name = item.imageFileName {
            thumbnailCache.removeObject(forKey: name as NSString)
            previewCache.removeObject(forKey: name as NSString)
            let url = imagesDirectoryURL.appendingPathComponent(name)
            diskQueue.async {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    nonisolated static func isValidWebURL(_ string: String) -> Bool {
        guard !string.contains("\n"), !string.contains("\r"), !string.contains(" ") else { return false }
        let candidate = URL(string: string)
            ?? string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        guard let url = candidate,
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host?.lowercased(),
              (host.contains(".") || host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0") else {
            return false
        }
        return true
    }

    private func isValidWebURL(_ string: String) -> Bool {
        Self.isValidWebURL(string)
    }

    nonisolated private static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 辅助功能与开机自启

    func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityGranted {
            isAccessibilityGranted = trusted
        }
        let loginEnabled = (SMAppService.mainApp.status == .enabled)
        if loginEnabled != launchAtLoginEnabled {
            launchAtLoginEnabled = loginEnabled
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            let actual = (SMAppService.mainApp.status == .enabled)
            launchAtLoginEnabled = actual
            if enabled && SMAppService.mainApp.status == .requiresApproval {
                showToast("请在系统设置 → 登录项中允许 iClip")
                SMAppService.openSystemSettingsLoginItems()
            } else {
                showToast(actual ? "已开启开机自启" : "已关闭开机自启")
            }
        } catch {
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
            showToast("开机自启设置失败：请将 iClip 放入应用程序文件夹")
        }
    }

    // MARK: - 隐私忽略来源应用白名单

    /// 判断目标应用在当前这台电脑上是否真实存在（已安装或正在运行）
    nonisolated static func isAppAvailableOnSystem(bundleIdentifier: String) -> Bool {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) != nil {
            return true
        }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == trimmed }
    }

    /// 自动剔除本机未安装/已卸载的应用条目，确保设置列表只呈现电脑上真实存在的工具
    func pruneUnavailableIgnoredApps() {
        let filtered = ignoredApps.filter { Self.isAppAvailableOnSystem(bundleIdentifier: $0.bundleIdentifier) }
        guard filtered != ignoredApps else { return }
        ignoredApps = filtered
        ignoredBundleIDSet = Set(filtered.map(\.bundleIdentifier))
        persistIgnoredApps()
    }

    func addIgnoredApp(bundleIdentifier: String, displayName: String) {
        let trimmedID = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !ignoredBundleIDSet.contains(trimmedID) else { return }
        let entry = IgnoredAppEntry(bundleIdentifier: trimmedID, displayName: displayName.isEmpty ? trimmedID : displayName)
        ignoredApps.append(entry)
        ignoredBundleIDSet.insert(trimmedID)
        persistIgnoredApps()
        showToast("已忽略来自「\(entry.displayName)」的剪贴内容")
    }

    func removeIgnoredApp(bundleIdentifier: String) {
        ignoredApps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        ignoredBundleIDSet.remove(bundleIdentifier)
        persistIgnoredApps()
    }

    func runningCandidateAppsForIgnore() -> [IgnoredAppEntry] {
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var result: [IgnoredAppEntry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bid = app.bundleIdentifier,
                  bid != ownID,
                  !ignoredBundleIDSet.contains(bid),
                  !seen.contains(bid) else {
                continue
            }
            seen.insert(bid)
            result.append(IgnoredAppEntry(bundleIdentifier: bid, displayName: app.localizedName ?? bid))
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func appIcon(forBundleID bundleID: String) -> NSImage? {
        let cacheKey = "app:\(bundleID)" as NSString
        if let cached = fileIconCache.object(forKey: cacheKey) {
            return cached
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            fileIconCache.setObject(icon, forKey: cacheKey)
            return icon
        }
        if let runningIcon = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.icon {
            fileIconCache.setObject(runningIcon, forKey: cacheKey)
            return runningIcon
        }
        return nil
    }

    private func persistIgnoredApps() {
        if let data = try? JSONEncoder().encode(ignoredApps) {
            UserDefaults.standard.set(data, forKey: "ignoredApps")
        }
    }

    private static func schedulePasteWhenTargetReady(attempt: Int = 0, autoTabAfter: Bool = false) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontPID != nil && frontPID != ownPID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) {
                simulateCommandV()
                if autoTabAfter {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
                        simulateTabKey()
                    }
                }
            }
            return
        }
        if attempt >= 10 {
            simulateCommandV()
            if autoTabAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
                    simulateTabKey()
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            schedulePasteWhenTargetReady(attempt: attempt + 1, autoTabAfter: autoTabAfter)
        }
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func simulateCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// 使用 .privateState 隔离物理按住的 ⌃⌥ 修饰键，向当前前台应用发送纯净 ⌘C
    private static func simulateCommandC() {
        let source = CGEventSource(stateID: .privateState)
        let cKeyCode: CGKeyCode = 8
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func simulateTabKey() {
        let source = CGEventSource(stateID: .hidSystemState)
        let tabKeyCode: CGKeyCode = 48
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: tabKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: tabKeyCode, keyDown: false) else {
            return
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
