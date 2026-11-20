import Foundation
import AppKit
import CryptoKit
import ApplicationServices

/// 剪贴板核心管理与持久化服务
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipItem] = []
    @Published var isPaused: Bool = false
    @Published var autoPasteEnabled: Bool {
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled") }
    }
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
    private var toastWorkItem: DispatchWorkItem?

    private let appSupportURL: URL
    private let historyFileURL: URL
    private let imagesDirectoryURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.appSupportURL = base.appendingPathComponent("QingJian", isDirectory: true)
        self.historyFileURL = appSupportURL.appendingPathComponent("history.json")
        self.imagesDirectoryURL = appSupportURL.appendingPathComponent("images", isDirectory: true)

        self.autoPasteEnabled = UserDefaults.standard.object(forKey: "autoPasteEnabled") as? Bool ?? true
        let savedMax = UserDefaults.standard.integer(forKey: "maxHistoryCount")
        self.maxHistoryCount = savedMax > 0 ? savedMax : 200
        self.lastChangeCount = pasteboard.changeCount

        thumbnailCache.countLimit = 120
        previewCache.countLimit = 24

        ensureDirectories()
        loadHistory()
        startMonitoring()
    }

    // MARK: - 目录与持久化

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

    private func saveHistory() {
        let snapshot = self.items
        let targetURL = self.historyFileURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: targetURL, options: .atomic)
            }
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

    // MARK: - 剪贴板监听

    func startMonitoring() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboard()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
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
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        if types.contains(concealedType) || types.contains(transientType) {
            return
        }

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // 1. 优先检测文件 URL（避免将访达复制的文件误判为文件名文本或图标图片）
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !fileURLs.isEmpty {
            let paths = fileURLs.map { $0.path }
            let hash = sha256(paths.joined(separator: "\n"))
            let item = ClipItem(
                type: .file,
                filePaths: paths,
                contentHash: "file:\(hash)",
                sourceAppName: sourceApp
            )
            insertOrPromote(item)
            return
        }

        // 2. 检测图片（PNG / TIFF）
        if let image = readImageFromPasteboard() {
            if let pngData = pngData(from: image) {
                let hash = sha256(pngData)
                let contentHash = "img:\(hash)"
                if let existingIndex = items.firstIndex(where: { $0.contentHash == contentHash }) {
                    var existing = items.remove(at: existingIndex)
                    existing.createdAt = Date()
                    existing.sourceAppName = sourceApp ?? existing.sourceAppName
                    items.insert(existing, at: 0)
                    items = sortItems(items)
                    saveHistory()
                    return
                }

                let fileName = "\(UUID().uuidString).png"
                let fileURL = imagesDirectoryURL.appendingPathComponent(fileName)
                do {
                    try pngData.write(to: fileURL, options: .atomic)
                    let pixelSize = pixelDimensions(of: image)
                    let item = ClipItem(
                        type: .image,
                        imageFileName: fileName,
                        imageWidth: pixelSize.width,
                        imageHeight: pixelSize.height,
                        contentHash: contentHash,
                        sourceAppName: sourceApp
                    )
                    insertOrPromote(item)
                    return
                } catch {
                    return
                }
            }
        }

        // 3. 检测文本与链接
        if let text = pasteboard.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let isLink = isValidWebURL(trimmed)
            let hash = sha256(text)
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

    /// 复制记录到系统剪贴板，并在允许时自动粘贴
    func copyAndOptionallyPaste(
        _ item: ClipItem,
        plainTextOnly: Bool = false,
        shouldAutoPaste: Bool = true,
        onBeforePaste: (() -> Void)? = nil
    ) {
        writeToPasteboard(item, plainTextOnly: plainTextOnly)

        // 更新记录时间戳并置前
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].createdAt = Date()
            items = sortItems(items)
            saveHistory()
        }

        onBeforePaste?()

        if shouldAutoPaste && autoPasteEnabled && hasAccessibilityPermission() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                Self.simulateCommandV()
            }
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
            if let url = imageURL(for: item), let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
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

    // MARK: - 图片与文件辅助

    func imageURL(for item: ClipItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return imagesDirectoryURL.appendingPathComponent(name)
    }

    func thumbnailImage(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFileName else { return nil }
        let cacheKey = name as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }
        guard let url = imageURL(for: item),
              let original = NSImage(contentsOf: url) else {
            return nil
        }

        let thumb = downscale(image: original, maxSide: 360)
        thumbnailCache.setObject(thumb, forKey: cacheKey)
        return thumb
    }

    func previewImage(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFileName else { return nil }
        let cacheKey = name as NSString
        if let cached = previewCache.object(forKey: cacheKey) {
            return cached
        }
        guard let url = imageURL(for: item),
              let original = NSImage(contentsOf: url) else {
            return nil
        }

        let preview = downscale(image: original, maxSide: 760)
        previewCache.setObject(preview, forKey: cacheKey)
        return preview
    }

    func fileIcon(for item: ClipItem) -> NSImage {
        if let first = item.filePaths?.first {
            return NSWorkspace.shared.icon(forFile: first)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private func deleteImageFileIfNeeded(for item: ClipItem) {
        if let name = item.imageFileName {
            thumbnailCache.removeObject(forKey: name as NSString)
            previewCache.removeObject(forKey: name as NSString)
            let url = imagesDirectoryURL.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func readImageFromPasteboard() -> NSImage? {
        if let data = pasteboard.data(forType: .png), let img = NSImage(data: data) {
            return img
        }
        if let data = pasteboard.data(forType: .tiff), let img = NSImage(data: data) {
            return img
        }
        return nil
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func pixelDimensions(of image: NSImage) -> (width: Int, height: Int) {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return (Int(image.size.width), Int(image.size.height))
    }

    private func downscale(image: NSImage, maxSide: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let ratio = min(maxSide / size.width, maxSide / size.height, 1.0)
        let targetSize = NSSize(width: max(1, size.width * ratio), height: max(1, size.height * ratio))
        let result = NSImage(size: targetSize)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
        result.unlockFocus()
        return result
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

    private func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    private func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 辅助功能与自动粘贴

    func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
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
