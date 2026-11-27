import Foundation
import AppKit
import CryptoKit
import SwiftUI

/// 轻量级网页站点图标服务（双层零开销架构）：
/// - 第 1 层（零联网 / 零体积 / 秒出）：内置 30+ 高频站点的特征品牌色与极简缩写/符号；
/// - 第 2 层（按需懒加载 + 有界落盘缓存）：仅对公网 `http/https` 域名拉取 ≤ 64KB 图标并重采样至 32×32@2x，
///   磁盘上限 200 个域名 / ≤ 2 MB（LRU 自动淘汰），严格屏蔽内网/本地地址，极简模式下零网络请求。
@MainActor
final class FaviconCacheService {
    static let shared = FaviconCacheService()

    struct BrandBadge: Equatable {
        let label: String
        let tintHex: UInt32
        let symbolName: String?

        var tintColor: Color {
            let r = Double((tintHex >> 16) & 0xFF) / 255.0
            let g = Double((tintHex >> 8) & 0xFF) / 255.0
            let b = Double(tintHex & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b)
        }

        var isDarkBrandColor: Bool {
            let r = Double((tintHex >> 16) & 0xFF) / 255.0
            let g = Double((tintHex >> 8) & 0xFF) / 255.0
            let b = Double(tintHex & 0xFF) / 255.0
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return luminance < 0.24
        }

        func resolvedForegroundColor(colorScheme: ColorScheme, isSelectedCard: Bool) -> Color {
            if isSelectedCard {
                return .white
            }
            if colorScheme == .dark && isDarkBrandColor {
                return Color.white.opacity(0.94)
            }
            return tintColor
        }
    }

    private let memoryCache = NSCache<NSString, NSImage>()
    private var negativeCache: [String: Date] = [:]
    private var inFlightHosts: Set<String> = []
    private let diskQueue = DispatchQueue(label: "com.iclip.favicon.disk", qos: .utility)
    private let cacheDirectoryURL: URL
    private let urlSession: URLSession

    private nonisolated static let maxDiskFiles = 200
    private nonisolated static let maxDiskBytes: Int = 2 * 1024 * 1024
    private nonisolated static let maxResponseBytes = 64 * 1024
    private static let negativeTTL: TimeInterval = 24 * 3600

    private init() {
        self.cacheDirectoryURL = AppStoragePaths.appSupportDirectory()
            .appendingPathComponent("favicons", isDirectory: true)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 4.0
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 2
        self.urlSession = URLSession(configuration: config)

        memoryCache.countLimit = 120
    }

    // MARK: - 域名归一化与隐私安全守卫

    nonisolated static func normalizedPublicHost(from rawURLString: String?) -> (scheme: String, host: String)? {
        guard let raw = rawURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw)
                ?? raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host?.lowercased(),
              !host.isEmpty,
              isSafePublicHost(host) else {
            return nil
        }
        return (scheme, host)
    }

    nonisolated static func isSafePublicHost(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".internal"), !host.hasSuffix(".lan") else {
            return false
        }
        if host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "::1" {
            return false
        }
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ Int($0) != nil }), let a = Int(parts[0]), let b = Int(parts[1]) {
            if a == 10 || a == 127 || a == 0 { return false }
            if a == 192 && b == 168 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 169 && b == 254 { return false }
            if a == 100 && (64...127).contains(b) { return false }
        }
        return true
    }

    // MARK: - 第 1 层：零联网即时品牌识别

    nonisolated static func brandBadge(for urlString: String?) -> BrandBadge? {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let host = url.host?.lowercased() else {
            return nil
        }
        let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        let rules: [(suffix: String, label: String, hex: UInt32, symbol: String?)] = [
            ("github.com", "GH", 0x24292F, "chevron.left.forwardslash.chevron.right"),
            ("gist.github.com", "GH", 0x24292F, "chevron.left.forwardslash.chevron.right"),
            ("gitlab.com", "GL", 0xFC6D26, nil),
            ("bilibili.com", "B站", 0xFB7299, "play.tv"),
            ("b23.tv", "B站", 0xFB7299, "play.tv"),
            ("youtube.com", "YT", 0xFF0000, "play.rectangle.fill"),
            ("youtu.be", "YT", 0xFF0000, "play.rectangle.fill"),
            ("x.com", "X", 0x111111, nil),
            ("twitter.com", "X", 0x1D9BF0, nil),
            ("zhihu.com", "知", 0x0066FF, nil),
            ("xiaohongshu.com", "红", 0xFF2442, nil),
            ("xhslink.com", "红", 0xFF2442, nil),
            ("weixin.qq.com", "微", 0x07C160, "message.fill"),
            ("mp.weixin.qq.com", "公", 0x07C160, "doc.richtext"),
            ("feishu.cn", "飞", 0x00D6B9, nil),
            ("larksuite.com", "Lark", 0x00D6B9, nil),
            ("dingtalk.com", "钉", 0x0089FF, nil),
            ("notion.so", "N", 0x191919, nil),
            ("notion.site", "N", 0x191919, nil),
            ("figma.com", "Fig", 0xA259FF, nil),
            ("apple.com", "", 0x1D1D1F, "apple.logo"),
            ("developer.apple.com", "Dev", 0x0A84FF, "swift"),
            ("google.com", "G", 0x4285F4, nil),
            ("openai.com", "AI", 0x10A37F, "sparkle"),
            ("chatgpt.com", "GPT", 0x10A37F, "sparkle"),
            ("claude.ai", "AI", 0xD97757, "sparkle"),
            ("anthropic.com", "AI", 0xD97757, "sparkle"),
            ("stackoverflow.com", "SO", 0xF48024, nil),
            ("npmjs.com", "npm", 0xCB3837, nil),
            ("pypi.org", "Py", 0x3775A9, nil),
            ("taobao.com", "淘", 0xFF5000, nil),
            ("jd.com", "京", 0xE1251B, nil),
            ("aliyun.com", "云", 0xFF6A00, "cloud.fill"),
            ("cloudflare.com", "CF", 0xF38020, "cloud.fill"),
            ("vercel.com", "▲", 0x111111, nil),
            ("douyin.com", "抖", 0x161823, "music.note"),
            ("weibo.com", "微", 0xE6162D, nil),
            ("juejin.cn", "掘", 0x1E80FF, nil),
            ("v2ex.com", "V2", 0x333344, nil),
            ("reddit.com", "R", 0xFF4500, nil),
            ("medium.com", "M", 0x12100E, nil),
            ("webfooo.com", "W", 0x1E5EFF, nil)
        ]

        for rule in rules {
            if cleanHost == rule.suffix || cleanHost.hasSuffix("." + rule.suffix) {
                return BrandBadge(label: rule.label, tintHex: rule.hex, symbolName: rule.symbol)
            }
        }
        return nil
    }

    // MARK: - 第 2 层：按需内存 + 磁盘缓存与懒加载

    func cachedFavicon(for urlString: String?) -> NSImage? {
        guard let (_, host) = Self.normalizedPublicHost(from: urlString) else { return nil }
        return memoryCache.object(forKey: host as NSString)
    }

    func loadFaviconIfNeeded(for urlString: String?, minimalMode: Bool) async -> NSImage? {
        guard let (scheme, host) = Self.normalizedPublicHost(from: urlString) else { return nil }
        let cacheKey = host as NSString
        if let hit = memoryCache.object(forKey: cacheKey) {
            return hit
        }

        let diskURL = cacheFileURL(forHost: host)
        let diskTask = Task.detached(priority: .utility) { () -> NSImage? in
            guard let data = try? Data(contentsOf: diskURL), !data.isEmpty else { return nil }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: diskURL.path)
            return NSImage(data: data)
        }
        if let diskImage = await diskTask.value {
            memoryCache.setObject(diskImage, forKey: cacheKey)
            return diskImage
        }

        // 极简纯净模式下严禁发起任何网络请求
        guard !minimalMode else { return nil }
        if let failedAt = negativeCache[host], Date().timeIntervalSince(failedAt) < Self.negativeTTL {
            return nil
        }
        guard !inFlightHosts.contains(host) else { return nil }
        inFlightHosts.insert(host)
        defer { inFlightHosts.remove(host) }

        guard let iconURL = URL(string: "\(scheme)://\(host)/favicon.ico") else {
            negativeCache[host] = Date()
            return nil
        }

        do {
            var req = URLRequest(url: iconURL)
            req.timeoutInterval = 3.0
            req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty,
                  data.count <= Self.maxResponseBytes else {
                negativeCache[host] = Date()
                return nil
            }

            let resampleTask = Task.detached(priority: .utility) { () -> (image: NSImage, pngData: Data)? in
                Self.resampleFavicon(data: data, targetPixels: 64)
            }
            guard let processed = await resampleTask.value else {
                negativeCache[host] = Date()
                return nil
            }

            memoryCache.setObject(processed.image, forKey: cacheKey)
            let dir = cacheDirectoryURL
            let pngData = processed.pngData
            diskQueue.async {
                Self.persistAndPrune(pngData: pngData, to: diskURL, directory: dir)
            }
            return processed.image
        } catch {
            negativeCache[host] = Date()
            return nil
        }
    }

    private func cacheFileURL(forHost host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectoryURL.appendingPathComponent("\(digest.prefix(24)).png")
    }

    nonisolated private static func resampleFavicon(data: Data, targetPixels: Int) -> (image: NSImage, pngData: Data)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: targetPixels
              ] as CFDictionary) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: 24, height: 24))
        return (nsImage, png)
    }

    nonisolated private static func persistAndPrune(pngData: Data, to fileURL: URL, directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? pngData.write(to: fileURL, options: .atomic)

        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Entry {
            let url: URL
            let mtime: Date
            let size: Int
        }
        var entries: [Entry] = urls.compactMap { url in
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Entry(
                url: url,
                mtime: vals?.contentModificationDate ?? .distantPast,
                size: vals?.fileSize ?? 0
            )
        }
        var totalBytes = entries.reduce(0) { $0 + $1.size }
        if entries.count <= maxDiskFiles && totalBytes <= maxDiskBytes {
            return
        }
        entries.sort { $0.mtime < $1.mtime }
        var remaining = entries.count
        for entry in entries {
            if remaining <= maxDiskFiles && totalBytes <= maxDiskBytes { break }
            try? fm.removeItem(at: entry.url)
            remaining -= 1
            totalBytes -= entry.size
        }
    }
}
