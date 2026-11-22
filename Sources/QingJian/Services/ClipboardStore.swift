import Foundation
import AppKit
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
        IgnoredAppEntry(bundleIdentifier: "com.1password.1password", displayName: "1Password"),
        IgnoredAppEntry(bundleIdentifier: "com.bitwarden.desktop", displayName: "Bitwarden")
    ]
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

/// 剪贴板核心管理与持久化服务（支持极客开发版 / 心流办公版编译期隔离与跨版本无损存储）
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var isAccessibilityGranted: Bool = false
    @Published var isPaused: Bool = false

    /// 用户选择的目标角色版本（决定专属 OTA 更新轨道与跨角色热切换）
    @Published private(set) var targetRoleEdition: AppRoleEdition
    /// 是否已完成首次角色版本确认引导
    @Published var hasConfirmedRoleEdition: Bool {
        didSet { UserDefaults.standard.set(hasConfirmedRoleEdition, forKey: "hasConfirmedRoleEdition") }
    }

    @Published var surfaceStyle: PanelSurfaceStyle {
        didSet { UserDefaults.standard.set(surfaceStyle.rawValue, forKey: "panelSurfaceStyle") }
    }
    @Published var liquidGlassAppearance: LiquidGlassAppearance {
        didSet { UserDefaults.standard.set(liquidGlassAppearance.rawValue, forKey: "liquidGlassAppearance") }
    }
    @Published var liquidGlassMaskOpacity: Double {
        didSet { scheduleSaveAppearanceDefaults() }
    }
    @Published var borderlessPanel: Bool {
        didSet { UserDefaults.standard.set(borderlessPanel, forKey: "borderlessPanel") }
    }
    @Published var autoPasteEnabled: Bool {
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled") }
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

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private var ignoreNextChangeCount: Int?

    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let previewCache = NSCache<NSString, NSImage>()
    private let fileIconCache = NSCache<NSString, NSImage>()
    #if !ICLIP_EDITION_FLOW
    private let semanticCache = NSCache<NSString, SemanticSnapshotBox>()
    #endif
    private var inFlightThumbnails = Set<String>()
    private var inFlightPreviews = Set<String>()

    private var toastWorkItem: DispatchWorkItem?
    private var saveWorkItem: DispatchWorkItem?
    private var appearanceSaveWorkItem: DispatchWorkItem?
    private var cacheTrimWorkItem: DispatchWorkItem?
    private let diskQueue = DispatchQueue(label: "com.qingjian.clipboard.disk", qos: .utility)

    private let appSupportURL: URL
    private let historyFileURL: URL
    private let imagesDirectoryURL: URL

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.appSupportURL = base.appendingPathComponent("QingJian", isDirectory: true)
        self.historyFileURL = appSupportURL.appendingPathComponent("history.json")
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

        self.autoPasteEnabled = UserDefaults.standard.object(forKey: "autoPasteEnabled") as? Bool ?? true
        let savedStyle = UserDefaults.standard.string(forKey: "panelSurfaceStyle") ?? PanelSurfaceStyle.liquidGlass.rawValue
        if savedStyle == "clearGlass" {
            self.surfaceStyle = .liquidGlass
            self.liquidGlassAppearance = .clear
        } else {
            self.surfaceStyle = PanelSurfaceStyle(rawValue: savedStyle) ?? .liquidGlass
            let savedGlassMode = UserDefaults.standard.string(forKey: "liquidGlassAppearance") ?? LiquidGlassAppearance.tinted.rawValue
            self.liquidGlassAppearance = LiquidGlassAppearance(rawValue: savedGlassMode) ?? .tinted
        }
        let savedMask = UserDefaults.standard.object(forKey: "liquidGlassMaskOpacity") as? Double
        self.liquidGlassMaskOpacity = min(max(savedMask ?? 0.25, 0.0), 1.0)
        self.borderlessPanel = UserDefaults.standard.object(forKey: "borderlessPanel") as? Bool ?? true

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
        #endif

        let savedMax = UserDefaults.standard.integer(forKey: "maxHistoryCount")
        self.maxHistoryCount = savedMax > 0 ? savedMax : 200
        self.lastChangeCount = pasteboard.changeCount
        self.isAccessibilityGranted = AXIsProcessTrusted()
        self.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)

        if let ignoredData = UserDefaults.standard.data(forKey: "ignoredApps"),
           let decodedIgnored = try? JSONDecoder().decode([IgnoredAppEntry].self, from: ignoredData) {
            self.ignoredApps = decodedIgnored
        } else {
            self.ignoredApps = IgnoredAppEntry.defaults
        }
        self.ignoredBundleIDSet = Set(self.ignoredApps.map(\.bundleIdentifier))

        thumbnailCache.countLimit = 80
        thumbnailCache.totalCostLimit = 24 * 1024 * 1024
        previewCache.countLimit = 12
        previewCache.totalCostLimit = 36 * 1024 * 1024
        fileIconCache.countLimit = 128

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibilityStatus()
            }
        }

        ensureDirectories()
        loadHistory()
        startMonitoring()
        #if ICLIP_EDITION_FLOW
        scheduleLegacyOCRBackfill()
        #endif
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
        try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
    }

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: historyFileURL)
            let decoded = try JSONDecoder().decode([ClipItem].self, from: data)
            self.items = sortItems(decoded)
        } catch {
            self.items = []
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

    private func saveHistory(immediate: Bool = false) {
        saveWorkItem?.cancel()
        let snapshot = self.items
        let targetURL = self.historyFileURL

        let work = DispatchWorkItem { [diskQueue] in
            diskQueue.async {
                if let data = try? JSONEncoder().encode(snapshot) {
                    try? data.write(to: targetURL, options: .atomic)
                }
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
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    // MARK: - 低功耗剪贴板监听

    func startMonitoring() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboard()
            }
        }
        t.tolerance = 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        saveHistory(immediate: true)
    }

    func onPanelShown(visibleItems: [ClipItem]) {
        cacheTrimWorkItem?.cancel()
        cacheTrimWorkItem = nil
        refreshAccessibilityStatus()
        prewarmThumbnails(for: visibleItems, limit: 18)
        prewarmPreviewImages(for: visibleItems, limit: 6)
        #if !ICLIP_EDITION_FLOW
        for item in visibleItems.prefix(24) where item.type == .text || item.type == .link {
            _ = semanticSnapshot(for: item)
        }
        #endif
    }

    func onPanelHidden() {
        cacheTrimWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.previewCache.removeAllObjects()
        }
        cacheTrimWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)
    }

    private func checkPasteboard() {
        guard !isPaused else {
            lastChangeCount = pasteboard.changeCount
            return
        }

        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if let ignored = ignoreNextChangeCount, ignored == currentCount {
            ignoreNextChangeCount = nil
            return
        }

        let types = pasteboard.types ?? []
        if types.contains(Self.concealedType) || types.contains(Self.transientType) {
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        if let bundleID = frontApp?.bundleIdentifier, ignoredBundleIDSet.contains(bundleID) {
            return
        }
        let sourceApp = frontApp?.localizedName

        // 1. 文件 URL
        if types.contains(.fileURL),
           let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
               .urlReadingFileURLsOnly: true
           ]) as? [URL], !fileURLs.isEmpty {
            let paths = fileURLs.map { $0.path }
            let hash = Self.sha256(paths.joined(separator: "\n"))
            let item = ClipItem(
                type: .file,
                filePaths: paths,
                contentHash: "file:\(hash)",
                sourceAppName: sourceApp
            )
            insertOrPromote(item)
            return
        }

        // 2. 图片
        if types.contains(.png) || types.contains(.tiff) {
            let rawPNG = pasteboard.data(forType: .png)
            let rawTIFF = (rawPNG == nil) ? pasteboard.data(forType: .tiff) : nil
            if rawPNG != nil || rawTIFF != nil {
                let imagesDir = self.imagesDirectoryURL
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
                            existing.sourceAppName = sourceApp ?? existing.sourceAppName
                            #if ICLIP_EDITION_FLOW
                            if self.isQueueModeActive && !self.pasteQueueIDs.contains(existing.id) {
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

                    let fileName = "\(UUID().uuidString).png"
                    let fileURL = imagesDir.appendingPathComponent(fileName)
                    do {
                        try pngData.write(to: fileURL, options: .atomic)
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
                            contentHash: contentHash,
                            sourceAppName: sourceApp
                        )
                        self.insertOrPromote(item)
                        #if ICLIP_EDITION_FLOW
                        self.scheduleBackgroundOCR(forItemID: item.id, fileURL: fileURL)
                        #endif
                    }
                }
                return
            }
        }

        // 3. 文本与链接
        if let rawText = pasteboard.string(forType: .string) {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            var text = rawText
            let isLink = isValidWebURL(trimmed)
            #if !ICLIP_EDITION_FLOW
            if isLink && autoCleanTrackingURL, let cleaned = SemanticEngine.cleanTrackingURL(trimmed) {
                text = cleaned
                pasteboard.clearContents()
                pasteboard.setString(cleaned, forType: .string)
                ignoreNextChangeCount = pasteboard.changeCount
                lastChangeCount = pasteboard.changeCount
            }
            #endif

            let hash = Self.sha256(text)
            let item = ClipItem(
                type: isLink ? .link : .text,
                text: text,
                contentHash: "\(isLink ? "link" : "text"):\(hash)",
                sourceAppName: sourceApp
            )
            insertOrPromote(item)
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
        if isQueueModeActive && !pasteQueueIDs.contains(finalID) {
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
        let pinned = items.filter { $0.isPinned }
        var unpinned = items.filter { !$0.isPinned }
        if unpinned.count > maxHistoryCount {
            let removed = unpinned[maxHistoryCount...]
            for item in removed {
                deleteImageFileIfNeeded(for: item)
            }
            unpinned = Array(unpinned.prefix(maxHistoryCount))
            items = sortItems(pinned + unpinned)
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
        #if !ICLIP_EDITION_FLOW
        if !forceRawSecret,
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

        if autoRedactOnPaste && !forceRawSecret {
            let snap = semanticSnapshot(for: item)
            if let secAction = snap.actions.first(where: { $0.isSecurityAction }) {
                applyTransformAction(secAction, for: item, shouldAutoPaste: shouldAutoPaste, onBeforePaste: onBeforePaste)
                return
            }
        }
        #else
        _ = forceRawSecret
        #endif

        writeToPasteboard(item, plainTextOnly: plainTextOnly)

        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].createdAt = Date()
            items = sortItems(items)
            saveHistory()
        }

        onBeforePaste?()

        refreshAccessibilityStatus()
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
        } else {
            showToast(plainTextOnly ? "已复制纯文本" : "已复制到剪贴板")
        }
    }

    private func writeToPasteboard(_ item: ClipItem, plainTextOnly: Bool) {
        pasteboard.clearContents()

        switch item.type {
        case .text, .link:
            if let text = item.text {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let url = imageURL(for: item), let pngData = try? Data(contentsOf: url) {
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

        ignoreNextChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
    }

    func togglePin(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isPinned.toggle()
        let pinned = items[idx].isPinned
        if !pinned {
            items[idx].pinCategory = nil
        }
        items = sortItems(items)
        saveHistory()
        showToast(pinned ? "已固定到顶部" : "已取消固定")
    }

    func delete(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: idx)
        #if ICLIP_EDITION_FLOW
        pasteQueueIDs.removeAll { $0 == removed.id }
        selectedMergeIDs.removeAll { $0 == removed.id }
        #endif
        deleteImageFileIfNeeded(for: removed)
        saveHistory()
    }

    func clearUnpinned() {
        let toRemove = items.filter { !$0.isPinned }
        #if ICLIP_EDITION_FLOW
        let removedIDs = Set(toRemove.map(\.id))
        pasteQueueIDs.removeAll { removedIDs.contains($0) }
        selectedMergeIDs.removeAll { removedIDs.contains($0) }
        #endif
        for item in toRemove {
            deleteImageFileIfNeeded(for: item)
        }
        items = items.filter { $0.isPinned }
        saveHistory()
        showToast("已清空未固定记录")
    }

    func showToast(_ message: String) {
        toastWorkItem?.cancel()
        toastMessage = message
        let work = DispatchWorkItem { [weak self] in
            self?.toastMessage = nil
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    // MARK: - 极客开发版专属能力（微秒级语义总线 + 密钥脱敏 + 动态模板）

    #if !ICLIP_EDITION_FLOW
    func semanticSnapshot(for item: ClipItem) -> SemanticSnapshot {
        guard item.type == .text || item.type == .link else { return .empty }
        let key = item.contentHash as NSString
        if let cached = semanticCache.object(forKey: key) {
            return cached.snapshot
        }
        let analyzed = SemanticEngine.analyze(item)
        semanticCache.setObject(SemanticSnapshotBox(analyzed), forKey: key)
        return analyzed
    }

    func applyTransformAction(
        _ action: TransformAction,
        for item: ClipItem,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        pasteCustomString(action.resultText, sourceItem: item, toast: action.toastText, shouldAutoPaste: shouldAutoPaste, onBeforePaste: onBeforePaste)
    }

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

    func addPinnedTemplate(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let hash = Self.sha256(trimmed)
        let newItem = ClipItem(
            type: .text,
            text: trimmed,
            contentHash: "tpl:\(hash)",
            sourceAppName: "iClip 模板",
            isPinned: true
        )
        insertOrPromote(newItem)
        if let idx = items.firstIndex(where: { $0.contentHash == newItem.contentHash }) {
            items[idx].isPinned = true
            items = sortItems(items)
            saveHistory()
        }
        showToast("已保存并固定动态模板")
    }

    func pasteCustomString(
        _ text: String,
        sourceItem: ClipItem,
        toast: String,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ignoreNextChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount

        if let idx = items.firstIndex(where: { $0.id == sourceItem.id }) {
            items[idx].createdAt = Date()
            items = sortItems(items)
            saveHistory()
        }

        onBeforePaste?()

        refreshAccessibilityStatus()
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
            showToast(toast)
        } else {
            showToast("\(toast)（已复制）")
        }
    }
    #endif

    // MARK: - 心流办公版专属能力（顺序队列 + 离线实况识图 + 多选合并 + 场景分组）

    #if ICLIP_EDITION_FLOW
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

    func setCustomAlias(_ alias: String?, for item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        items[idx].customAlias = (trimmed?.isEmpty == false) ? trimmed : nil
        saveHistory()
        showToast(items[idx].customAlias != nil ? "已更新备注标题" : "已清除备注标题")
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
            showToast("已移出顺序队列")
        } else {
            pasteQueueIDs.append(item.id)
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
                let nextPreview = nextQueuedItem?.primaryTitle
                writeToPasteboard(target, plainTextOnly: false)
                onBeforePaste?()
                refreshAccessibilityStatus()
                let sendTabAfter = queueAutoTabEnabled
                if autoPasteEnabled && isAccessibilityGranted {
                    Self.schedulePasteWhenTargetReady(autoTabAfter: sendTabAfter)
                }

                if showGlobalHUD {
                    let shortTitle = target.primaryTitle.count > 18
                        ? String(target.primaryTitle.prefix(18)) + "…"
                        : target.primaryTitle
                    let sub: String
                    if let nextPreview {
                        let cleanNext = nextPreview.count > 16 ? String(nextPreview.prefix(16)) + "…" : nextPreview
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
        } else {
            selectedMergeIDs.append(item.id)
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
        let segments: [String] = selectedMergeIDs.compactMap { id in
            guard let item = items.first(where: { $0.id == id }) else { return nil }
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
        ignoreNextChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount

        onBeforePaste?()
        refreshAccessibilityStatus()
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
            showToast("已按「\(style.title)」合并 \(count) 条并键入")
        } else {
            showToast("已合并 \(count) 条到剪贴板")
        }
    }

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
                    let recognized = await VisionOCRService.recognizeText(at: url)
                    await MainActor.run { [weak self] in
                        guard let self,
                              let idx = self.items.firstIndex(where: { $0.id == id }) else {
                            return
                        }
                        self.items[idx].ocrChecked = true
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

    func pasteExtractedOCRText(
        for item: ClipItem,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        if let existingOCR = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !existingOCR.isEmpty {
            commitPlainStringPaste(existingOCR, shouldAutoPaste: shouldAutoPaste, onBeforePaste: onBeforePaste)
            return
        }

        guard let url = imageURL(for: item) else {
            showToast("未找到原始图片文件")
            return
        }

        showToast("正在使用系统实况文本识别...")
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let recognized = await VisionOCRService.recognizeText(at: url),
                  !recognized.isEmpty else {
                self.showToast("未在图片中检测到可识别文字")
                return
            }
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[idx].ocrChecked = true
                self.items[idx].ocrText = recognized
                self.saveHistory()
            }
            self.commitPlainStringPaste(recognized, shouldAutoPaste: shouldAutoPaste, onBeforePaste: onBeforePaste)
        }
    }

    private func commitPlainStringPaste(_ text: String, shouldAutoPaste: Bool, onBeforePaste: (() -> Void)?) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ignoreNextChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount

        onBeforePaste?()
        refreshAccessibilityStatus()
        if shouldAutoPaste && autoPasteEnabled && isAccessibilityGranted {
            Self.schedulePasteWhenTargetReady()
            showToast("已提取图中文字并键入")
        } else {
            showToast("已提取图中文字到剪贴板")
        }
    }
    #endif

    // MARK: - 零阻塞图片与文件图标缓存

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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
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

    private func isValidWebURL(_ string: String) -> Bool {
        guard !string.contains("\n"), !string.contains(" ") else { return false }
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, host.contains(".") else {
            return false
        }
        return true
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
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        fileIconCache.setObject(icon, forKey: cacheKey)
        return icon
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
