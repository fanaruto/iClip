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

/// 剪贴板核心管理与持久化服务（低功耗轮询 + 后台异步图片编码 + 严格内存上限缓存）
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var isAccessibilityGranted: Bool = false
    @Published var isPaused: Bool = false
    @Published var surfaceStyle: PanelSurfaceStyle {
        didSet { UserDefaults.standard.set(surfaceStyle.rawValue, forKey: "panelSurfaceStyle") }
    }
    @Published var liquidGlassAppearance: LiquidGlassAppearance {
        didSet { UserDefaults.standard.set(liquidGlassAppearance.rawValue, forKey: "liquidGlassAppearance") }
    }
    /// 液态玻璃原生蒙版浓度（0.0 ~ 1.0），拖动时防抖落盘零 I/O 卡顿
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

    // 精确内存上限的图像与图标缓存，杜绝长期运行内存膨胀
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let previewCache = NSCache<NSString, NSImage>()
    private let fileIconCache = NSCache<NSString, NSImage>()
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

        self.autoPasteEnabled = UserDefaults.standard.object(forKey: "autoPasteEnabled") as? Bool ?? true
        let savedStyle = UserDefaults.standard.string(forKey: "panelSurfaceStyle") ?? PanelSurfaceStyle.liquidGlass.rawValue
        if savedStyle == "clearGlass" {
            // 兼容旧版通透液态配置：无缝迁移到液态玻璃 + 透明档位
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

        // 缩略图上限 24 MB / 80 张；高清预览上限 36 MB / 12 张；文件图标上限 128 个
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

    /// 防抖持久化滑块值，保证 120Hz 拖动液态蒙版零磁盘阻塞
    private func scheduleSaveAppearanceDefaults() {
        appearanceSaveWorkItem?.cancel()
        let value = liquidGlassMaskOpacity
        let work = DispatchWorkItem {
            UserDefaults.standard.set(value, forKey: "liquidGlassMaskOpacity")
        }
        appearanceSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// 0.25s 防抖合并 + 串行后台队列落盘，避免连续操作重复编码 JSON 与并发写盘
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
        // 0.6s 周期 + 0.25s 容差，允许 macOS 内核自动合并 CPU 唤醒，待机近乎 0 功耗
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

    /// 面板打开时取消缓存回收，后台预热首屏缩略图与少量高清图
    func onPanelShown(visibleItems: [ClipItem]) {
        cacheTrimWorkItem?.cancel()
        cacheTrimWorkItem = nil
        refreshAccessibilityStatus()
        prewarmThumbnails(for: visibleItems, limit: 18)
        prewarmPreviewImages(for: visibleItems, limit: 6)
    }

    /// 面板隐藏 8 秒后释放高占用的高清预览图缓存，让后台常驻内存保持在极低水平
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

        // 跳过常见的密码管理器临时敏感内容标记
        let types = pasteboard.types ?? []
        if types.contains(Self.concealedType) || types.contains(Self.transientType) {
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        if let bundleID = frontApp?.bundleIdentifier, ignoredBundleIDSet.contains(bundleID) {
            return
        }
        let sourceApp = frontApp?.localizedName

        // 1. 优先检测文件 URL（避免将访达复制的文件误判为文件名文本或图标图片）
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

        // 2. 检测图片：主线程只取原始字节，转码、哈希、落盘与缩略图解码全部放后台，彻底告别主线程掉帧
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

                    // 后台顺手预生成一张小缩略图，待会儿打开面板直接内存秒出
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
                    }
                }
                return
            }
        }

        // 3. 检测文本与链接
        if let text = pasteboard.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let isLink = isValidWebURL(trimmed)
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
        if let existingIndex = items.firstIndex(where: { $0.contentHash == newItem.contentHash }) {
            var existing = items.remove(at: existingIndex)
            existing.createdAt = Date()
            if let app = newItem.sourceAppName {
                existing.sourceAppName = app
            }
            items.insert(existing, at: 0)
        } else {
            items.insert(newItem, at: 0)
        }

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

    // MARK: - 用户操作

    /// 复制记录到系统剪贴板，并在允许时极速键入光标处
    func copyAndOptionallyPaste(
        _ item: ClipItem,
        plainTextOnly: Bool = false,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
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
            // 直接写入原始 PNG Data，避免 NSImage 解码成巨型未压缩 TIFF 造成粘贴卡顿
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
        items = sortItems(items)
        saveHistory()
        showToast(pinned ? "已固定到顶部" : "已取消固定")
    }

    func delete(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: idx)
        deleteImageFileIfNeeded(for: removed)
        saveHistory()
    }

    func clearUnpinned() {
        let toRemove = items.filter { !$0.isPinned }
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

    // MARK: - 零阻塞图片与文件图标缓存

    func imageURL(for item: ClipItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return imagesDirectoryURL.appendingPathComponent(name)
    }

    /// 零 I/O 读取内存缩略图缓存（供 SwiftUI body 直接渲染，绝不阻塞滚动）
    func cachedThumbnail(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFileName else { return nil }
        return thumbnailCache.object(forKey: name as NSString)
    }

    /// 后台异步解码缩略图并写入带内存上限的缓存
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

    /// 后台预热首屏缩略图，打开面板即刻满帧呈现
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

    /// 零 I/O 读取已预解码的高清预览图缓存，保证悬停首帧 120Hz 不掉帧
    func cachedPreviewImage(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFileName else { return nil }
        return previewCache.object(forKey: name as NSString)
    }

    /// 后台线程预解码高清原比例预览图（ImageIO 硬件加速 + 立即解压缩）
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

    /// 面板打开时在后台预热前排图片的高清缓存，悬停即可瞬时满帧放大
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

    /// 零解码直接读取图片像素尺寸元数据
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

    /// 带缓存的本地文件图标查询，消除滚动时的重复 LaunchServices IPC
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

    // MARK: - 辅助功能与极速自动粘贴

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

    // MARK: - 开机自启（SMAppService）

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

    // MARK: - 隐私忽略来源应用白名单（O(1) 哈希过滤）

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

    /// 面板收起后尽快检测原应用恢复前台焦点，立即触发 ⌘V，消除固定长延迟
    private static func schedulePasteWhenTargetReady(attempt: Int = 0) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontPID != nil && frontPID != ownPID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) {
                simulateCommandV()
            }
            return
        }
        if attempt >= 10 {
            simulateCommandV()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            schedulePasteWhenTargetReady(attempt: attempt + 1)
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
        // 键盘 V 的虚拟键码为 9
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
}
