import Foundation
import Vision
import ImageIO
import CoreGraphics

private final class WordBoxCacheEntry {
    let fullText: String
    let boxes: [BigBangImageWordBox]
    init(fullText: String, boxes: [BigBangImageWordBox]) {
        self.fullText = fullText
        self.boxes = boxes
    }
}

private final class WordBoxCancelFlag: @unchecked Sendable {
    var cancelled = false
}

/// 基于 Apple Vision 框架的纯本地离线实况文本、原位词框（Big Bang）与二维码直解服务（零网络上传）
/// 采用串行后台队列 + ImageIO 硬件降采样 + NSCache 去重，杜绝连续 5K 截图造成的内存峰值与 CPU 抖动
enum VisionOCRService {
    private static let ocrQueue = DispatchQueue(label: "com.qingjian.clipboard.ocr", qos: .utility)
    private static let wordBoxQueue = DispatchQueue(label: "com.qingjian.clipboard.ocr.wordbox", qos: .userInitiated)
    private static let stateLock = NSLock()
    private static var inFlightPaths = Set<String>()
    private static var pendingWordBoxWaiters: [String: [(CheckedContinuation<(fullText: String, boxes: [BigBangImageWordBox])?, Never>, WordBoxCancelFlag)]] = [:]
    private static let wordBoxCache: NSCache<NSString, WordBoxCacheEntry> = {
        let c = NSCache<NSString, WordBoxCacheEntry>()
        c.countLimit = 24
        return c
    }()
    private static let maxOCREdgePixelSize = 2048
    private static let maxBarcodeEdgePixelSize = 1280

    /// 毫秒级内存二维码/条码极速嗅探（~3ms，供截图入库瞬间立即驱动光标角微星标直解链接/文本）
    static func detectBarcodesFast(in imageData: Data) -> String? {
        autoreleasepool {
            guard !imageData.isEmpty,
                  let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  ImageStudioEngine.hasSafeImageDimensions(source) else {
                return nil
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxBarcodeEdgePixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            return detectBarcodesFast(in: cgImage)
        }
    }

    /// 从 CGImage 直接离线提取二维码/常用条码载荷（去重保序）
    static func detectBarcodesFast(in cgImage: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .aztec, .dataMatrix, .pdf417, .code128]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        var seen = Set<String>()
        var payloads: [String] = []
        for obs in observations {
            guard let rawVal = obs.payloadStringValue?.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawVal.isEmpty else {
                continue
            }
            let safeVal: String
            if case .pastejackingOrBidi = ClipboardPoisonGuard.inspect(rawVal) {
                let cleaned = ClipboardPoisonGuard.sanitize(rawVal)
                safeVal = cleaned.isEmpty ? rawVal : cleaned
            } else {
                safeVal = rawVal
            }
            guard !seen.contains(safeVal) else { continue }
            seen.insert(safeVal)
            payloads.append(safeVal)
        }
        return payloads.isEmpty ? nil : payloads.joined(separator: "\n")
    }

    /// 从本地图片 URL 异步提取中英混排文字（同一文件并发请求自动防重）
    static func recognizeText(at imageURL: URL) async -> String? {
        let pathKey = imageURL.path
        let shouldProceed: Bool = {
            stateLock.lock()
            defer { stateLock.unlock() }
            if inFlightPaths.contains(pathKey) { return false }
            inFlightPaths.insert(pathKey)
            return true
        }()
        guard shouldProceed else { return nil }

        return await withCheckedContinuation { continuation in
            ocrQueue.async {
                defer {
                    stateLock.lock()
                    inFlightPaths.remove(pathKey)
                    stateLock.unlock()
                }
                let text = performSyncRecognition(at: imageURL)
                continuation.resume(returning: text)
            }
        }
    }

    private static func performSyncRecognition(at url: URL) -> String? {
        autoreleasepool {
            guard let imgData = LocalVaultCrypto.readDecryptedImageData(at: url),
                  let source = CGImageSourceCreateWithData(imgData as CFData, nil),
                  ImageStudioEngine.hasSafeImageDimensions(source) else {
                return nil
            }
            // 使用 ImageIO 硬件降采样至最大 2048px 长边，5K 截图峰值内存直降 75%，文字识别精度不受损
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxOCREdgePixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            return recognize(cgImage: cgImage)
        }
    }

    private static func recognize(cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        let lines = observations.compactMap { observation -> String? in
            let candidate = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text = candidate, !text.isEmpty else { return nil }
            return text
        }

        let joinedRaw = lines.joined(separator: "\n").replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joinedRaw.isEmpty else { return nil }
        if case .pastejackingOrBidi = ClipboardPoisonGuard.inspect(joinedRaw) {
            let cleaned = ClipboardPoisonGuard.sanitize(joinedRaw)
            return cleaned.isEmpty ? joinedRaw : cleaned
        }
        return joinedRaw
    }

    // MARK: - 原位大爆炸（Big Bang）精确词框识别与缓存

    private static func wordBoxCacheKey(for url: URL, granularity: BigBangGranularity) -> NSString {
        "\(url.path)|\(granularity.rawValue)" as NSString
    }

    /// 零等待读取已完成识别的原位词框缓存（供全图大屏 Preview 无闪烁切换）
    static func cachedWordBoxes(
        at imageURL: URL,
        granularity: BigBangGranularity = .word
    ) -> (fullText: String, boxes: [BigBangImageWordBox])? {
        guard let entry = wordBoxCache.object(forKey: wordBoxCacheKey(for: imageURL, granularity: granularity)) else {
            return nil
        }
        return (entry.fullText, entry.boxes)
    }

    /// 清空原位 OCR 词框缓存（锁屏、切换保险库等场景）
    static func clearWordBoxCache() {
        wordBoxCache.removeAllObjects()
    }

    /// 按图片路径精确失效原位 OCR 词框缓存（条目删除/替换时同步抹除敏感识别残余）
    static func evictWordBoxCache(for imageURL: URL) {
        for g in BigBangGranularity.allCases {
            wordBoxCache.removeObject(forKey: wordBoxCacheKey(for: imageURL, granularity: g))
        }
    }

    /// 异步提取图片内每处文字的精确原位词框（已转为左上角原点 `[0, 1]` SwiftUI 归一化坐标）
    static func recognizeWordBoxes(
        at imageURL: URL,
        granularity: BigBangGranularity = .word
    ) async -> (fullText: String, boxes: [BigBangImageWordBox])? {
        let keyString = "\(imageURL.path)|\(granularity.rawValue)"
        let key = keyString as NSString
        if let cached = wordBoxCache.object(forKey: key) {
            return (cached.fullText, cached.boxes)
        }

        let cancelFlag = WordBoxCancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldEnqueue: Bool = {
                    stateLock.lock()
                    defer { stateLock.unlock() }
                    if let cached = wordBoxCache.object(forKey: keyString as NSString) {
                        continuation.resume(returning: (cached.fullText, cached.boxes))
                        return false
                    }
                    let first = pendingWordBoxWaiters[keyString] == nil
                    pendingWordBoxWaiters[keyString, default: []].append((continuation, cancelFlag))
                    return first
                }()
                guard shouldEnqueue else { return }

                wordBoxQueue.async {
                    let hasActiveWaiter: Bool = {
                        stateLock.lock()
                        defer { stateLock.unlock() }
                        let waiters = pendingWordBoxWaiters[keyString] ?? []
                        return waiters.contains { !$0.1.cancelled }
                    }()

                    let computed: (fullText: String, boxes: [BigBangImageWordBox])?
                    if hasActiveWaiter {
                        let nsKey = keyString as NSString
                        if let cached = wordBoxCache.object(forKey: nsKey) {
                            computed = (cached.fullText, cached.boxes)
                        } else if let res = performSyncWordBoxRecognition(at: imageURL, granularity: granularity) {
                            wordBoxCache.setObject(WordBoxCacheEntry(fullText: res.fullText, boxes: res.boxes), forKey: nsKey)
                            computed = res
                        } else {
                            // 无文字纯图同步写入空负缓存，避免上下翻阅重复重算 Vision
                            wordBoxCache.setObject(WordBoxCacheEntry(fullText: "", boxes: []), forKey: nsKey)
                            computed = ("", [])
                        }
                    } else {
                        computed = nil
                    }

                    let waitersToResume: [CheckedContinuation<(fullText: String, boxes: [BigBangImageWordBox])?, Never>] = {
                        stateLock.lock()
                        defer { stateLock.unlock() }
                        let list = pendingWordBoxWaiters.removeValue(forKey: keyString) ?? []
                        return list.map { $0.0 }
                    }()
                    for w in waitersToResume {
                        w.resume(returning: computed)
                    }
                }
            }
        } onCancel: {
            stateLock.lock()
            cancelFlag.cancelled = true
            stateLock.unlock()
        }
    }

    private static func performSyncWordBoxRecognition(
        at url: URL,
        granularity: BigBangGranularity
    ) -> (fullText: String, boxes: [BigBangImageWordBox])? {
        autoreleasepool {
            guard let imgData = LocalVaultCrypto.readDecryptedImageData(at: url),
                  let source = CGImageSourceCreateWithData(imgData as CFData, nil),
                  ImageStudioEngine.hasSafeImageDimensions(source) else {
                return nil
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxOCREdgePixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            return recognizeWordBoxes(in: cgImage, granularity: granularity)
        }
    }

    private static func recognizeWordBoxes(
        in cgImage: CGImage,
        granularity: BigBangGranularity
    ) -> (fullText: String, boxes: [BigBangImageWordBox])? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        func clamp01(_ v: CGFloat) -> CGFloat {
            max(0.0, min(1.0, v))
        }

        var lineTexts: [String] = []
        var boxes: [BigBangImageWordBox] = []
        var nextBoxID = 0

        for (lineIdx, observation) in observations.enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let rawLine = candidate.string.replacingOccurrences(of: "\0", with: "")
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            let cleanLine: String
            if case .pastejackingOrBidi = ClipboardPoisonGuard.inspect(trimmedLine) {
                let c = ClipboardPoisonGuard.sanitize(trimmedLine)
                cleanLine = c.isEmpty ? trimmedLine : c
            } else {
                cleanLine = trimmedLine
            }
            lineTexts.append(cleanLine)

            let tokenRanges = BigBangTokenizer.tokenizeWithRanges(rawLine, granularity: granularity)
            let totalUTF16 = max(1, (rawLine as NSString).length)
            let obsBox = observation.boundingBox

            for (rawPiece, range) in tokenRanges {
                let pieceClean: String
                if case .pastejackingOrBidi = ClipboardPoisonGuard.inspect(rawPiece) {
                    let c = ClipboardPoisonGuard.sanitize(rawPiece)
                    pieceClean = c.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    pieceClean = rawPiece.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !pieceClean.isEmpty else { continue }

                let normRect: CGRect
                if let rectObs = try? candidate.boundingBox(for: range)?.boundingBox,
                   rectObs.width > 0.001, rectObs.height > 0.001 {
                    let nx = clamp01(rectObs.minX)
                    let ny = clamp01(1.0 - rectObs.maxY)
                    let nw = min(1.0 - nx, max(0.006, rectObs.width))
                    let nh = min(1.0 - ny, max(0.006, rectObs.height))
                    normRect = CGRect(x: nx, y: ny, width: nw, height: nh)
                } else {
                    let ns = NSRange(range, in: rawLine)
                    let startRatio = CGFloat(ns.location) / CGFloat(totalUTF16)
                    let endRatio = CGFloat(ns.location + ns.length) / CGFloat(totalUTF16)
                    let nx = clamp01(obsBox.minX + startRatio * obsBox.width)
                    let ny = clamp01(1.0 - obsBox.maxY)
                    let nw = min(1.0 - nx, max(0.006, (endRatio - startRatio) * obsBox.width))
                    let nh = min(1.0 - ny, max(0.006, obsBox.height))
                    normRect = CGRect(x: nx, y: ny, width: nw, height: nh)
                }

                boxes.append(
                    BigBangImageWordBox(
                        id: nextBoxID,
                        text: pieceClean,
                        normalizedRect: normRect,
                        lineIndex: lineIdx,
                        granularity: granularity
                    )
                )
                nextBoxID += 1
            }
        }

        let fullText = lineTexts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty || !boxes.isEmpty else { return nil }
        return (fullText, boxes)
    }
}
