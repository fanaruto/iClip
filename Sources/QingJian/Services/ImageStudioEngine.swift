import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 设计师、客服工单、自媒体创作者专属：剪贴板图片硬件加速瞬时瘦身与苹果风圆角样机加壳引擎
enum ImageStudioEngine {

    struct ProcessedImageResult {
        let data: Data
        let utType: NSPasteboard.PasteboardType
        let byteCount: Int
    }

    /// 将本地 PNG 截图转换为高画质轻量 JPEG（自动垫白底防止透明通道变黑底，体积通常缩减 80%~92%）
    static func compressToLightweightJPEG(at imageURL: URL, quality: CGFloat = 0.78, maxEdge: Int = 2560) -> ProcessedImageResult? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
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
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
                return nil
            }
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
}
