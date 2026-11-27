import AppKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// macOS 27 原生运行时能力快照与硬件自适应中心（兼容 macOS 14+ 启动，在 macOS 26/27 自动激活全部原生特性）
enum MacOS27Capabilities {
    struct Snapshot: Equatable, Sendable {
        let osVersionText: String
        let isMacOS26OrNewer: Bool
        let isMacOS27OrNewer: Bool
        let interactiveLiquidGlassEnabled: Bool
        let expandedStatusItemSessionEnabled: Bool
        let concentricGeometryEnabled: Bool
        let screenshotKitPipelineEnabled: Bool
        let speechAnalyzerSupported: Bool
        let multiTouchDisplayDetected: Bool
        let onDeviceIntelligenceState: OnDeviceIntelligenceService.AvailabilityState

        var activeFeatureLabels: [String] {
            var labels: [String] = []
            if interactiveLiquidGlassEnabled {
                labels.append("交互式液态玻璃")
            } else if isMacOS26OrNewer {
                labels.append("原生液态玻璃")
            }
            if expandedStatusItemSessionEnabled {
                labels.append("原生菜单栏会话")
            }
            if concentricGeometryEnabled {
                labels.append("同心圆角与柔边滚动")
            }
            if screenshotKitPipelineEnabled {
                labels.append("SCScreenshotKit 抓帧")
            }
            if speechAnalyzerSupported {
                labels.append("SpeechAnalyzer 语音")
            }
            if onDeviceIntelligenceState == .available {
                labels.append("Apple 智能端侧模型")
            }
            if multiTouchDisplayDetected {
                labels.append("多点触控自适配")
            }
            return labels
        }
    }

    static var isMacOS26OrNewer: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    static var isMacOS27OrNewer: Bool {
        if #available(macOS 27.0, *) {
            return true
        }
        return false
    }

    static var osVersionText: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.patchVersion > 0 {
            return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    /// 探测目标显示器是否支持 macOS 27 原生多点触控交互
    @MainActor
    static func supportsMultiTouchDisplay(on screen: NSScreen? = nil) -> Bool {
        if #available(macOS 27.0, *) {
            let target = screen ?? NSScreen.main ?? NSScreen.screens.first
            guard let target else { return false }
            return target.touchCapabilities.contains(.multiTouch)
        }
        return false
    }

    /// 触控屏设备自适应扩大点按冗余边距（非触控 Mac 保持 0pt 经典桌面紧凑密度）
    @MainActor
    static func adaptiveTouchHitPadding(on screen: NSScreen? = nil) -> CGFloat {
        supportsMultiTouchDisplay(on: screen) ? 4.0 : 0.0
    }

    /// 统一提取显示器 CGDirectDisplayID（macOS 26+ 走官方 NSScreen.cgDirectDisplayID，旧系统回退 NSScreenNumber）
    @MainActor
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        if #available(macOS 26.0, *) {
            return screen.cgDirectDisplayID
        }
        guard let screenNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNum.uint32Value)
    }

    /// 采集当前系统的 macOS 27 能力快照（供设置窗诊断面板与单元测试校验）
    @MainActor
    static func currentSnapshot(screen: NSScreen? = nil) -> Snapshot {
        let v26 = isMacOS26OrNewer
        let v27 = isMacOS27OrNewer
        return Snapshot(
            osVersionText: osVersionText,
            isMacOS26OrNewer: v26,
            isMacOS27OrNewer: v27,
            interactiveLiquidGlassEnabled: v27,
            expandedStatusItemSessionEnabled: v27,
            concentricGeometryEnabled: v26,
            screenshotKitPipelineEnabled: v26,
            speechAnalyzerSupported: v26,
            multiTouchDisplayDetected: supportsMultiTouchDisplay(on: screen),
            onDeviceIntelligenceState: OnDeviceIntelligenceService.availabilityState
        )
    }
}

/// macOS 26/27 端侧 Apple Intelligence（FoundationModels）桥接服务
/// 严格纯端侧零联网运行；不支持或未开启 Apple Intelligence 的设备零开销自动回退本地确定性引擎。
enum OnDeviceIntelligenceService {
    enum AvailabilityState: Equatable, Sendable {
        case available
        case deviceNotEligible
        case notEnabled
        case modelNotReady
        case unsupportedOS
        case otherUnavailable

        var localizedDescription: String {
            switch self {
            case .available:
                return "已就绪（端侧模型可用）"
            case .deviceNotEligible:
                return "当前机型未开放端侧基础模型（已自动回退本地确定性引擎）"
            case .notEnabled:
                return "未在系统设置中开启 Apple 智能（已自动回退本地引擎）"
            case .modelNotReady:
                return "端侧基础模型准备中（暂用本地引擎）"
            case .unsupportedOS:
                return "需要 macOS 26 及以上系统"
            case .otherUnavailable:
                return "端侧模型暂不可用（已自动回退本地引擎）"
            }
        }
    }

    static var availabilityState: AvailabilityState {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .deviceNotEligible
                case .appleIntelligenceNotEnabled:
                    return .notEnabled
                case .modelNotReady:
                    return .modelNotReady
                @unknown default:
                    return .otherUnavailable
                }
            }
        }
        #endif
        return .unsupportedOS
    }

    static var isAvailable: Bool {
        availabilityState == .available
    }

    /// 解析模型输出的多行待办清单（纯函数，过滤 Markdown 序号、空行与过长噪音，便于单元测试）
    static func parseModelTodoLines(_ rawOutput: String, maxItems: Int = 6) -> [String] {
        var results: [String] = []
        var seen = Set<String>()
        let lines = rawOutput
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)

        for rawLine in lines {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            // 剥离常见项目符号或编号前缀（- / * / • / 1. / 1、 / [ ]）
            let patterns = [
                #"^[-*•·]+\s*"#,
                #"^\[\s?[xX]?\s?\]\s*"#,
                #"^\d+[\.、\)）]\s*"#
            ]
            for pattern in patterns {
                if let range = line.range(of: pattern, options: .regularExpression) {
                    line.removeSubrange(range)
                    line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "。；;，,！!\"'“”"))
            guard line.count >= 2, line.count <= 80 else { continue }
            let dedupKey = line.lowercased()
            guard !seen.contains(dedupKey) else { continue }
            seen.insert(dedupKey)
            results.append(line)
            if results.count >= maxItems { break }
        }
        return results
    }

    /// 端侧语言模型辅助提炼口语语音待办（不可用或超时自动返回 nil，由调用方无缝回退 VoiceTodoParser）
    static func refineVoiceTodoItems(
        from rawTranscript: String,
        timeoutSeconds: Double = 1.15
    ) async -> [String]? {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6, isAvailable else { return nil }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let prompt = """
            将下面这段中文口语语音整理为精简、可执行的待办事项清单。
            规则：每行仅输出 1 条待办，不要编号、不要解释、不要多余标点，保留原始时间/对象信息，最多 6 条。
            原文：\(trimmed)
            """
            guard let responseText = await runPromptWithTimeout(
                instructions: "你是精简高效的中文待办提炼助手，只输出逐行待办事项，禁止废话和客套。",
                prompt: prompt,
                timeoutSeconds: timeoutSeconds
            ) else {
                return nil
            }
            let items = parseModelTodoLines(responseText)
            return items.isEmpty ? nil : items
        }
        #endif
        return nil
    }

    /// 端侧长文本一句话摘要（仅在 Apple Intelligence 端侧模型可用且文本足够长时启用）
    static func summarizeTextIfAvailable(
        _ text: String,
        timeoutSeconds: Double = 2.4
    ) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 160, isAvailable else { return nil }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let clipped = String(trimmed.prefix(2400))
            let prompt = "请用不超过 60 字的简体中文提炼以下剪贴板内容的核心要点，直接输出结论：\n\n\(clipped)"
            guard let result = await runPromptWithTimeout(
                instructions: "你是端侧剪贴板摘要助手，使用简洁准确的简体中文直接输出核心要点。",
                prompt: prompt,
                timeoutSeconds: timeoutSeconds
            ) else {
                return nil
            }
            let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func runPromptWithTimeout(
        instructions: String,
        prompt: String,
        timeoutSeconds: Double
    ) async -> String? {
        let clampedTimeout = max(0.3, timeoutSeconds)
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: prompt)
                    return response.content
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(clampedTimeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    #endif
}
