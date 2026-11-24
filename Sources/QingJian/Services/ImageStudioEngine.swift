import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

/// 设计师、客服工单、自媒体创作者专属：剪贴板图片硬件加速瞬时瘦身与苹果风圆角样机加壳引擎
enum ImageStudioEngine {

    struct ProcessedImageResult {
        let data: Data
        let utType: NSPasteboard.PasteboardType
        let byteCount: Int
    }

    enum ImageDimensionInspection: Equatable {
        case safe
        case unreadableOrCorrupt
        case exceededLimits
    }

    /// 零像素分配前置校验图像宽高，精准区分「文件损坏/头部不可读」与「尺寸超限压缩炸弹（CWE-409）」
    static func inspectImageDimensions(
        _ source: CGImageSource,
        maxSingleEdge: Int = 16_384,
        maxTotalPixels: Int64 = 67_108_864
    ) -> ImageDimensionInspection {
        guard CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let wNum = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let hNum = props[kCGImagePropertyPixelHeight] as? NSNumber else {
            return .unreadableOrCorrupt
        }
        let w = wNum.int64Value
        let h = hNum.int64Value
        guard w > 0, h > 0 else {
            return .unreadableOrCorrupt
        }
        guard w <= Int64(maxSingleEdge), h <= Int64(maxSingleEdge) else {
            return .exceededLimits
        }
        let (total, overflow) = w.multipliedReportingOverflow(by: h)
        if overflow || total > maxTotalPixels {
            return .exceededLimits
        }
        return .safe
    }

    /// 零像素分配前置校验图像宽高，阻断恶意压缩炸弹（Decompression Bomb / CWE-409）耗尽进程内存
    static func hasSafeImageDimensions(
        _ source: CGImageSource,
        maxSingleEdge: Int = 16_384,
        maxTotalPixels: Int64 = 67_108_864
    ) -> Bool {
        inspectImageDimensions(
            source,
            maxSingleEdge: maxSingleEdge,
            maxTotalPixels: maxTotalPixels
        ) == .safe
    }

    static func hasSafeImageDimensions(
        in data: Data,
        maxSingleEdge: Int = 16_384,
        maxTotalPixels: Int64 = 67_108_864
    ) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return hasSafeImageDimensions(source, maxSingleEdge: maxSingleEdge, maxTotalPixels: maxTotalPixels)
    }

    /// 将本地 PNG 截图转换为高画质轻量 JPEG（自动垫白底防止透明通道变黑底，体积通常缩减 80%~92%）
    static func compressToLightweightJPEG(at imageURL: URL, quality: CGFloat = 0.78, maxEdge: Int = 2560) -> ProcessedImageResult? {
        autoreleasepool {
            guard let imgData = LocalVaultCrypto.readDecryptedImageData(at: imageURL),
                  let source = CGImageSourceCreateWithData(imgData as CFData, nil),
                  hasSafeImageDimensions(source) else {
                return nil
            }
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge
            ]
            guard let srcCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
                return nil
            }

            let width = srcCG.width
            let height = srcCG.height
            guard width > 0, height > 0 else { return nil }

            // 在不透明纯白画布上合成，彻底避免带透明阴影的 macOS 窗口截图转 JPEG 后边缘变纯黑的经典 Bug
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                return nil
            }

            ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            ctx.draw(srcCG, in: CGRect(x: 0, y: 0, width: width, height: height))

            guard let flattenedCG = ctx.makeImage() else { return nil }

            let outData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                outData as CFMutableData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }

            let props: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: quality
            ]
            CGImageDestinationAddImage(dest, flattenedCG, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }

            let finalData = outData as Data
            return ProcessedImageResult(
                data: finalData,
                utType: NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                byteCount: finalData.count
            )
        }
    }

    /// 为裸截图一键生成苹果风柔光渐变衬底 + 连续圆角 + 立体柔和投影样机图（CleanShot 级质感）
    static func renderAppleMockupFrame(at imageURL: URL, maxSourceEdge: Int = 2200) -> ProcessedImageResult? {
        autoreleasepool {
            guard let imgData = LocalVaultCrypto.readDecryptedImageData(at: imageURL),
                  let source = CGImageSourceCreateWithData(imgData as CFData, nil) else {
                return nil
            }
            return renderAppleMockupFrame(fromSource: source, maxSourceEdge: maxSourceEdge)
        }
    }

    /// 从内存图像字节流零磁盘 I/O 直接渲染苹果风圆角柔和阴影样机图
    static func renderAppleMockupFrame(from imageData: Data, maxSourceEdge: Int = 2200) -> ProcessedImageResult? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                return nil
            }
            return renderAppleMockupFrame(fromSource: source, maxSourceEdge: maxSourceEdge)
        }
    }

    private static func renderAppleMockupFrame(fromSource source: CGImageSource, maxSourceEdge: Int) -> ProcessedImageResult? {
        autoreleasepool {
            guard hasSafeImageDimensions(source) else { return nil }
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSourceEdge
            ]
            guard let srcCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
                return nil
            }

            let imgW = CGFloat(srcCG.width)
            let imgH = CGFloat(srcCG.height)
            guard imgW > 0, imgH > 0 else { return nil }

            let pad = round(min(max(min(imgW, imgH) * 0.10, 40), 96))
            let canvasW = Int(imgW + pad * 2)
            let canvasH = Int(imgH + pad * 2)
            let innerRadius = min(max(round(min(imgW, imgH) * 0.028), 12), 24)

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: canvasW,
                height: canvasH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }

            let fullRect = CGRect(x: 0, y: 0, width: CGFloat(canvasW), height: CGFloat(canvasH))

            // 1. 绘制克制高级的苹果冰雾渐变衬底（左上柔光银蓝 -> 右下淡雅雾灰）
            let gradColors = [
                CGColor(srgbRed: 0.93, green: 0.95, blue: 0.99, alpha: 1.0),
                CGColor(srgbRed: 0.86, green: 0.90, blue: 0.96, alpha: 1.0)
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0.0, 1.0]) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: CGFloat(canvasH)),
                    end: CGPoint(x: CGFloat(canvasW), y: 0),
                    options: []
                )
            } else {
                ctx.setFillColor(CGColor(srgbRed: 0.92, green: 0.94, blue: 0.98, alpha: 1.0))
                ctx.fill(fullRect)
            }

            let targetRect = CGRect(x: pad, y: pad, width: imgW, height: imgH)
            let roundedPath = CGPath(roundedRect: targetRect, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)

            // 2. 绘制具有真实偏移与柔和扩散的立体投影
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -round(pad * 0.22)),
                blur: round(pad * 0.65),
                color: CGColor(srgbRed: 0.06, green: 0.10, blue: 0.18, alpha: 0.26)
            )
            ctx.addPath(roundedPath)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()

            // 3. 裁剪圆角并绘制高清截图主体
            ctx.saveGState()
            ctx.addPath(roundedPath)
            ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(srcCG, in: targetRect)
            ctx.restoreGState()

            // 4. 叠加 1px 细腻玻璃高光内描边
            ctx.saveGState()
            ctx.addPath(roundedPath)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55))
            ctx.setLineWidth(1.0)
            ctx.strokePath()
            ctx.restoreGState()

            guard let outCG = ctx.makeImage() else { return nil }
            let outData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                outData as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(dest, outCG, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }

            let finalData = outData as Data
            return ProcessedImageResult(
                data: finalData,
                utType: .png,
                byteCount: finalData.count
            )
        }
    }

    // MARK: - 离线 Vision 坐标级「截图隐私一键智能打码」（自动定位二维码 / 密钥 / 身份证 / 银行卡 / 手机 / 邮箱 / 密码值）

    private static let imageInlineSecretRegexes: [(regex: NSRegularExpression, valueGroup: Int)] = [
        (try! NSRegularExpression(pattern: #"\b(?:sk-or-v1-[A-Za-z0-9_-]{24,}|sk-(?:proj-|ant-|live_|test_)?[A-Za-z0-9_-]{16,}|tskey-(?:auth|api|client|webhook)-[A-Za-z0-9_-]{16,}|vcp_[A-Za-z0-9]{24,}|cfut_[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{24,}|glpat-[A-Za-z0-9_-]{16,}|hf_[A-Za-z0-9]{24,}|gsk_[A-Za-z0-9]{24,}|pplx-[A-Za-z0-9]{24,}|ntn_[A-Za-z0-9]{24,}|secret_[A-Za-z0-9]{24,}|sbp_[A-Za-z0-9]{24,}|lin_api_[A-Za-z0-9]{20,}|dapi[0-9a-f]{32}|re_[A-Za-z0-9_]{20,}|npm_[A-Za-z0-9]{24,}|pypi-[A-Za-z0-9_-]{32,}|AIzaSy[A-Za-z0-9_-]{28,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|LTAI[A-Za-z0-9]{12,24}|xox[baprs]-[A-Za-z0-9-]{16,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})\b"#), 0),
        (try! NSRegularExpression(pattern: #"(?i)\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss|amqp|amqps)://(?:[^/\s:@]*:)([^@\s/]{4,})@"#), 1),
        (try! NSRegularExpression(pattern: #"(?<![0-9A-Za-z])[1-8]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[0-9Xx](?![0-9A-Za-z])"#), 0),
        (try! NSRegularExpression(pattern: #"(?<![0-9A-Za-z])(?:62\d{14,17}|4\d{15}|5[1-5]\d{14}|3[47]\d{13})(?![0-9A-Za-z])"#), 0),
        (try! NSRegularExpression(pattern: #"(?<![0-9])1[3-9]\d{9}(?![0-9])"#), 0),
        (try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#), 0),
        (try! NSRegularExpression(pattern: #"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3})\b"#), 0),
        (try! NSRegularExpression(pattern: #"(?i)(?:密码|口令|提取码|验证码|password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|[a-z0-9_]+_token|signing[_-]?key|master[_-]?key|encryption[_-]?key|accountkey)\s*[:=：]\s*([^\s,，;；'"]{6,})"#), 1)
    ]

    /// 离线扫描截图中的敏感文字与二维码包围盒，生成物理不可逆的圆角晶格马赛克打码图（原图局部文字保持 100% 锐利）
    static func redactSensitiveRegions(
        at imageURL: URL,
        maxEdge: Int = 2560
    ) -> (result: ProcessedImageResult, redactedCount: Int)? {
        guard let imgData = LocalVaultCrypto.readDecryptedImageData(at: imageURL) else {
            return nil
        }
        return redactSensitiveRegions(in: imgData, maxEdge: maxEdge)
    }

    static func redactSensitiveRegions(
        in imageData: Data,
        maxEdge: Int = 2560
    ) -> (result: ProcessedImageResult, redactedCount: Int)? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  hasSafeImageDimensions(source) else {
                return nil
            }
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge
            ]
            guard let srcCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
                return nil
            }

            let width = srcCG.width
            let height = srcCG.height
            guard width > 0, height > 0 else { return nil }

            let barcodeReq = VNDetectBarcodesRequest()
            barcodeReq.symbologies = [.qr, .aztec, .dataMatrix, .pdf417]
            let textReq = VNRecognizeTextRequest()
            textReq.recognitionLevel = .accurate
            textReq.usesLanguageCorrection = true
            textReq.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(cgImage: srcCG, options: [:])
            try? handler.perform([barcodeReq, textReq])

            var normBoxes: [CGRect] = []
            if let barcodes = barcodeReq.results {
                for b in barcodes {
                    normBoxes.append(b.boundingBox)
                }
            }

            if let textObsList = textReq.results {
                for obs in textObsList {
                    guard let top = obs.topCandidates(1).first else { continue }
                    let str = top.string
                    let fullNSRange = NSRange(str.startIndex..<str.endIndex, in: str)
                    var matchedSubBox = false

                    for (rx, grp) in imageInlineSecretRegexes {
                        for m in rx.matches(in: str, range: fullNSRange) {
                            let targetNS = (grp < m.numberOfRanges && m.range(at: grp).location != NSNotFound)
                                ? m.range(at: grp)
                                : m.range
                            if let swiftRange = Range(targetNS, in: str) {
                                let tokenStr = String(str[swiftRange])
                                // 对 18 位身份证与银行卡做校验位过滤，杜绝误打码普通单号
                                if tokenStr.count == 18, tokenStr.first?.isNumber == true,
                                   !SensitiveCredentialVeil.isValidChineseIDCard18(tokenStr) {
                                    continue
                                }
                                if (15...19).contains(tokenStr.count), tokenStr.allSatisfy(\.isNumber),
                                   !SensitiveCredentialVeil.isValidBankCardLuhn(tokenStr) {
                                    continue
                                }
                                if let subBox = try? top.boundingBox(for: swiftRange)?.boundingBox {
                                    normBoxes.append(subBox)
                                } else {
                                    normBoxes.append(obs.boundingBox)
                                }
                                matchedSubBox = true
                            }
                        }
                    }

                    if !matchedSubBox && SensitiveCredentialVeil.classify(str) != nil {
                        normBoxes.append(obs.boundingBox)
                    }
                }
            }

            guard !normBoxes.isEmpty else {
                return (ProcessedImageResult(data: imageData, utType: .png, byteCount: imageData.count), 0)
            }

            return renderMosaicBoxes(normBoxes, onto: srcCG)
        }
    }

    /// 在给定 CGImage 的指定归一化矩形列表（左下角原点）上合成物理不可逆圆角晶格马赛克（公开供单测验证像素擦除）
    static func renderMosaicBoxes(
        _ normalizedBoxes: [CGRect],
        onto srcCG: CGImage
    ) -> (result: ProcessedImageResult, redactedCount: Int)? {
        let width = srcCG.width
        let height = srcCG.height
        guard width > 0, height > 0, !normalizedBoxes.isEmpty else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)

        // 1. 生成物理降采样晶格马赛克源纹理（彻底销毁局部高频文字像素）
        let blockSize = max(8, min(width, height) / 38)
        let smallW = max(1, width / blockSize)
        let smallH = max(1, height / blockSize)
        guard let smallCtx = CGContext(
            data: nil,
            width: smallW,
            height: smallH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        smallCtx.interpolationQuality = .medium
        smallCtx.draw(srcCG, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let mosaicCG = smallCtx.makeImage() else { return nil }

        // 2. 在高清主画布上仅对命中的圆角隐私框裁剪覆盖晶格马赛克
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(srcCG, in: fullRect)

        let wF = CGFloat(width)
        let hF = CGFloat(height)
        for nb in normalizedBoxes {
            let rawRect = CGRect(
                x: nb.minX * wF - 5.0,
                y: nb.minY * hF - 3.5,
                width: nb.width * wF + 10.0,
                height: nb.height * hF + 7.0
            ).intersection(fullRect)
            guard rawRect.width >= 2, rawRect.height >= 2 else { continue }

            let radius = min(8.0, min(rawRect.width, rawRect.height) * 0.32)
            let path = CGPath(roundedRect: rawRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.interpolationQuality = .none
            ctx.draw(mosaicCG, in: fullRect)
            ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.15, blue: 0.22, alpha: 0.14))
            ctx.fill(rawRect)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.42))
            ctx.setLineWidth(1.0)
            ctx.strokePath()
            ctx.restoreGState()
        }

        guard let finalCG = ctx.makeImage() else { return nil }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, finalCG, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let pngBytes = outData as Data
        return (
            ProcessedImageResult(data: pngBytes, utType: .png, byteCount: pngBytes.count),
            normalizedBoxes.count
        )
    }

    // MARK: - 照片与本地图片一键剥离 GPS 经纬度与拍摄设备 EXIF 隐私元数据

    private static let supportedPhotoFileExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "webp", "tif", "tiff"
    ]

    /// 微秒级只读检查图片文件头是否携带 GPS 定位坐标或拍摄设备/作者 EXIF 元数据（0 像素解码开销）
    static func fileContainsPrivacyMetadata(at fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        guard supportedPhotoFileExtensions.contains(ext),
              FileManager.default.fileExists(atPath: fileURL.path),
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [AnyHashable: Any], !gps.isEmpty {
            return true
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if exif[kCGImagePropertyExifDateTimeOriginal] != nil
                || exif[kCGImagePropertyExifLensSerialNumber] != nil
                || exif[kCGImagePropertyExifBodySerialNumber] != nil
                || exif[kCGImagePropertyExifUserComment] != nil {
                return true
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if tiff[kCGImagePropertyTIFFMake] != nil
                || tiff[kCGImagePropertyTIFFModel] != nil
                || tiff[kCGImagePropertyTIFFArtist] != nil {
                return true
            }
        }
        return false
    }

    /// 将含 GPS/EXIF 的本地照片文件或加密缓存截图重编码为 100% 零隐私元数据的纯净图像
    static func stripPrivacyMetadata(at imageURL: URL, isEncryptedVaultImage: Bool = false) -> ProcessedImageResult? {
        autoreleasepool {
            let sourceOpt: CGImageSource? = {
                if isEncryptedVaultImage {
                    guard let data = LocalVaultCrypto.readDecryptedImageData(at: imageURL) else { return nil }
                    return CGImageSourceCreateWithData(data as CFData, nil)
                }
                return CGImageSourceCreateWithURL(imageURL as CFURL, nil)
            }()
            guard let source = sourceOpt, hasSafeImageDimensions(source) else { return nil }

            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
            ]
            guard let srcCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
                return nil
            }

            // 重新绘制到全新 sRGB 位图上下文，物理斩断一切原始 CGImage 附属 EXIF/GPS/IPTC/XMP 字典引用
            let w = srcCG.width
            let h = srcCG.height
            guard w > 0, h > 0 else { return nil }
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(srcCG, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let cleanCG = ctx.makeImage() else { return nil }

            let outData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                outData as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(dest, cleanCG, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }

            let bytes = outData as Data
            return ProcessedImageResult(data: bytes, utType: .png, byteCount: bytes.count)
        }
    }
}
