import Foundation
import AppKit
import Darwin

/// 崩溃现场信号安全写入缓冲（仅在 POSIX 信号处理器中使用，绝不执行 Swift 堆分配或 Objective-C 消息发送）
private nonisolated(unsafe) var gCrashLogPathBuffer: [CChar] = []
private nonisolated(unsafe) var gCrashHeaderBuffer: [CChar] = []

private func iClipFatalSignalHandler(_ sig: Int32) {
    if !gCrashLogPathBuffer.isEmpty {
        let fd = Darwin.open(&gCrashLogPathBuffer, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd >= 0 {
            if !gCrashHeaderBuffer.isEmpty {
                _ = Darwin.write(fd, &gCrashHeaderBuffer, max(0, gCrashHeaderBuffer.count - 1))
            }
            var sigLine: [CChar] = Array("signal=\(sig)\nstack:\n".utf8CString)
            _ = Darwin.write(fd, &sigLine, max(0, sigLine.count - 1))
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
            let count = frames.withUnsafeMutableBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return 0 }
                return Darwin.backtrace(base, Int32(buf.count))
            }
            if count > 0 {
                frames.withUnsafeMutableBufferPointer { buf in
                    if let base = buf.baseAddress {
                        Darwin.backtrace_symbols_fd(base, count, fd)
                    }
                }
            }
            Darwin.close(fd)
        }
    }
    Darwin.signal(sig, SIG_DFL)
    Darwin.raise(sig)
}

/// 单条脱敏崩溃记录摘要（零用户剪贴板内容，专供本地自检队列与自动优化迭代消费）
struct DiagnosticCrashEntry: Codable, Identifiable, Equatable {
    let id: String
    let sourceFile: String
    let captureTime: String
    let exceptionType: String
    let signal: String
    let faultingQueue: String
    let topFrames: [String]
}

/// 供每小时 / 30 分钟自省迭代自动化消费的结构化崩溃反馈队列
struct DiagnosticSelfHealQueue: Codable, Equatable {
    let updatedAt: String
    let appVersion: String
    let osVersion: String
    let recentCrashes: [DiagnosticCrashEntry]
}

/// 零隐私泄露本地日志与崩溃自诊断反馈服务：
/// 1. 启动挂载 POSIX 致命信号与未捕获异常记录器（`0700` 目录 + `0600` 文件，零剪贴板明文）；
/// 2. 启动自动扫描本地 `crash_last.log` 与最近 7 天 macOS `DiagnosticReports/QingJian-*.ips`，写入结构化自愈队列 `crash_feedback_queue.json` 供定时自省任务自动定位并修复；
/// 3. 提供一键「前往官网 Bug 反馈」与「复制脱敏诊断摘要」，让用户零门槛反馈问题。
@MainActor
final class DiagnosticLogService: ObservableObject {
    static let shared = DiagnosticLogService()

    /// 官网统一意见与 Bug 反馈直达地址
    static let officialBugFeedbackURL = URL(string: "https://app.webfooo.com/iClip#community")!

    @Published private(set) var recentCrashes: [DiagnosticCrashEntry] = []
    @Published private(set) var lastScanDate: Date? = nil

    var recentCrashCount: Int { recentCrashes.count }
    var latestCrash: DiagnosticCrashEntry? { recentCrashes.first }

    let logsDirectoryURL: URL
    let runtimeLogURL: URL
    let crashLastLogURL: URL
    let selfHealQueueURL: URL

    private let maxRuntimeLogBytes: Int = 192 * 1024
    private var handlersInstalled: Bool = false
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private init() {
        let baseDir = AppStoragePaths.appSupportDirectory()
        let logsDir = baseDir.appendingPathComponent("Logs", isDirectory: true)
        self.logsDirectoryURL = logsDir
        self.runtimeLogURL = logsDir.appendingPathComponent("runtime.log")
        self.crashLastLogURL = logsDir.appendingPathComponent("crash_last.log")
        self.selfHealQueueURL = logsDir.appendingPathComponent("crash_feedback_queue.json")
        ensureLogsDirectory()
    }

    /// 供单元测试隔离目录构造
    init(customLogsDirectory: URL) {
        self.logsDirectoryURL = customLogsDirectory
        self.runtimeLogURL = customLogsDirectory.appendingPathComponent("runtime.log")
        self.crashLastLogURL = customLogsDirectory.appendingPathComponent("crash_last.log")
        self.selfHealQueueURL = customLogsDirectory.appendingPathComponent("crash_feedback_queue.json")
        ensureLogsDirectory()
    }

    private func ensureLogsDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logsDirectoryURL.path) {
            try? fm.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsDirectoryURL.path)
        }
    }

    /// 启动时挂载 POSIX 崩溃捕捉器与未捕获 NSException 记录器，并后台扫描最近崩溃日志写入自愈队列
    func installAndScanOnLaunch() {
        installCrashHandlersIfNeeded()
        recordEvent(category: "lifecycle", message: "iClip v\(AppRoleEdition.currentVersionString) launched")
        scanRecentCrashes()
    }

    private func installCrashHandlersIfNeeded() {
        guard !handlersInstalled, NSClassFromString("XCTestCase") == nil else { return }
        handlersInstalled = true

        gCrashLogPathBuffer = Array(crashLastLogURL.path.utf8CString)
        let header = "version=\(AppRoleEdition.currentVersionString)\nos=\(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        gCrashHeaderBuffer = Array(header.utf8CString)

        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]
        for sig in signals {
            Darwin.signal(sig, iClipFatalSignalHandler)
        }

        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "unknown"
            let stack = exception.callStackSymbols.prefix(32).joined(separator: "\n")
            let payload = "exception=\(name)\nreason=\(reason)\nstack:\n\(stack)\n"
            if !gCrashLogPathBuffer.isEmpty {
                let fd = Darwin.open(&gCrashLogPathBuffer, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
                if fd >= 0 {
                    var bytes = Array(payload.utf8)
                    _ = Darwin.write(fd, &bytes, bytes.count)
                    Darwin.close(fd)
                }
            }
        }
    }

    /// 写入轻量脱敏运行事件日志（自动剔除潜在敏感凭据并滚动截断体积）
    func recordEvent(category: String, message: String) {
        let scrubbed = Self.sanitizeDiagnosticText(message)
        let line = "[\(isoFormatter.string(from: Date()))] [\(category)] \(scrubbed)\n"
        guard let data = line.data(using: .utf8) else { return }

        ensureLogsDirectory()
        let fm = FileManager.default
        if fm.fileExists(atPath: runtimeLogURL.path),
           let attrs = try? fm.attributesOfItem(atPath: runtimeLogURL.path),
           let fileSize = attrs[.size] as? Int,
           fileSize > maxRuntimeLogBytes,
           let existing = try? Data(contentsOf: runtimeLogURL) {
            let keepTail = existing.suffix(maxRuntimeLogBytes / 2)
            try? keepTail.write(to: runtimeLogURL, options: .atomic)
        }

        if let handle = try? FileHandle(forWritingTo: runtimeLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: runtimeLogURL, options: .atomic)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeLogURL.path)
    }

    /// 扫描本地最近 7 天 macOS DiagnosticReports 与内部 crash_last.log，同步落盘供自动迭代引擎消费
    func scanRecentCrashes(reportsDirectory: URL? = nil, maxAgeDays: Int = 7) {
        let diagDir = reportsDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-Double(max(1, maxAgeDays)) * 86400.0)
        var parsed: [DiagnosticCrashEntry] = []

        if let files = try? FileManager.default.contentsOfDirectory(
            at: diagDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let matching = files
                .filter { url in
                    let name = url.lastPathComponent
                    guard (name.hasPrefix("QingJian") || name.hasPrefix("iClip")) && name.hasSuffix(".ips") else {
                        return false
                    }
                    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return mtime >= cutoff
                }
                .sorted { lhs, rhs in
                    let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lDate > rDate
                }

            for url in matching.prefix(8) {
                if let text = try? String(contentsOf: url, encoding: .utf8),
                   let entry = Self.parseAppleIPSReport(text, fileName: url.lastPathComponent) {
                    parsed.append(entry)
                }
            }
        }

        if FileManager.default.fileExists(atPath: crashLastLogURL.path),
           let text = try? String(contentsOf: crashLastLogURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: crashLastLogURL.path)[.modificationDate] as? Date) ?? Date()
            if mtime >= cutoff {
                let topLines = text
                    .split(separator: "\n")
                    .prefix(8)
                    .map { Self.sanitizeDiagnosticText(String($0)) }
                let entry = DiagnosticCrashEntry(
                    id: "local-crash-\(Int(mtime.timeIntervalSince1970))",
                    sourceFile: crashLastLogURL.lastPathComponent,
                    captureTime: isoFormatter.string(from: mtime),
                    exceptionType: "LOCAL_FATAL",
                    signal: topLines.first(where: { $0.hasPrefix("signal=") || $0.hasPrefix("exception=") }) ?? "UNKNOWN",
                    faultingQueue: "in-process",
                    topFrames: Array(topLines)
                )
                parsed.append(entry)
            }
        }

        recentCrashes = parsed
        lastScanDate = Date()
        persistSelfHealQueue(entries: parsed)
    }

    private func persistSelfHealQueue(entries: [DiagnosticCrashEntry]) {
        ensureLogsDirectory()
        let queue = DiagnosticSelfHealQueue(
            updatedAt: isoFormatter.string(from: Date()),
            appVersion: AppRoleEdition.currentVersionString,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            recentCrashes: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(queue) {
            try? data.write(to: selfHealQueueURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: selfHealQueueURL.path)
        }
    }

    /// 纯函数解析 Apple `.ips` JSON 崩溃日志（仅提取崩溃时间、异常类型、队列与栈帧，零用户数据）
    nonisolated static func parseAppleIPSReport(_ rawText: String, fileName: String) -> DiagnosticCrashEntry? {
        let lines = rawText.split(separator: "\n", omittingEmptySubsequences: false)
        let bodyString: String
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("{") && lines.count > 1 {
            bodyString = lines.dropFirst().joined(separator: "\n")
        } else {
            bodyString = rawText
        }
        guard let bodyData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }

        let captureTime = (json["captureTime"] as? String) ?? "unknown"
        let exc = json["exception"] as? [String: Any]
        let excType = (exc?["type"] as? String) ?? "UNKNOWN"
        let signal = (exc?["signal"] as? String) ?? "UNKNOWN"

        let usedImages = (json["usedImages"] as? [[String: Any]]) ?? []
        let faultingThreadIdx = (json["faultingThread"] as? Int) ?? 0
        let threads = (json["threads"] as? [[String: Any]]) ?? []

        var queueName = "unknown"
        var topFrames: [String] = []
        if faultingThreadIdx >= 0 && faultingThreadIdx < threads.count {
            let thread = threads[faultingThreadIdx]
            queueName = (thread["queue"] as? String) ?? (thread["name"] as? String) ?? "thread-\(faultingThreadIdx)"
            let frames = (thread["frames"] as? [[String: Any]]) ?? []
            for frame in frames.prefix(12) {
                let imgIdx = (frame["imageIndex"] as? Int) ?? -1
                let imgName = (imgIdx >= 0 && imgIdx < usedImages.count)
                    ? ((usedImages[imgIdx]["name"] as? String) ?? "?")
                    : "?"
                let sym = (frame["symbol"] as? String) ?? "offset+\((frame["imageOffset"] as? Int) ?? 0)"
                topFrames.append("[\(imgName)] \(sym)")
            }
        }

        return DiagnosticCrashEntry(
            id: fileName,
            sourceFile: fileName,
            captureTime: captureTime,
            exceptionType: excType,
            signal: signal,
            faultingQueue: queueName,
            topFrames: topFrames
        )
    }

    /// 脱敏清洗任意诊断文本，防止敏感凭据意外进入日志
    nonisolated static func sanitizeDiagnosticText(_ raw: String) -> String {
        let singleLine = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if SensitiveCredentialVeil.classify(singleLine) != nil {
            return String(SensitiveCredentialVeil.redactForExternalSharing(singleLine).prefix(600))
        }
        return String(singleLine.prefix(600))
    }

    /// 生成可直接贴入官网 Bug 反馈表单的脱敏诊断摘要（零剪贴板内容）
    func buildSanitizedDiagnosticSummary(store: ClipboardStore) -> String {
        var lines: [String] = [
            "【iClip 脱敏运行诊断摘要】",
            "- 应用版本：iClip v\(AppRoleEdition.currentVersionString)",
            "- 系统环境：macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "- 签名状态：\(store.signingIdentityInfo.displayLabel)",
            "- 权限状态：辅助功能=\(store.isAccessibilityGranted ? "已授" : "未授") / 完全磁盘=\(store.isFullDiskAccessGranted ? "已授" : "未授") / 屏幕录制=\(store.isScreenRecordingGranted ? "已授" : "未授")",
            "- 模式状态：极简=\(store.minimalModeEnabled ? "开" : "关") / 精灵小球=\(store.spriteOrbEnabled ? "开" : "关") / 卡片皮肤=\(store.cardSkin.title)",
            "- 近期异常日志数：\(recentCrashes.count)"
        ]
        if let latest = recentCrashes.first {
            lines.append("- 最近异常：\(latest.captureTime) | \(latest.exceptionType) (\(latest.signal)) | queue=\(latest.faultingQueue)")
            if !latest.topFrames.isEmpty {
                lines.append("- 顶部栈帧：\(latest.topFrames.prefix(4).joined(separator: " -> "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    func openOfficialBugFeedbackPage() {
        NSWorkspace.shared.open(Self.officialBugFeedbackURL)
    }

    func copySanitizedDiagnosticSummary(store: ClipboardStore) {
        let report = buildSanitizedDiagnosticSummary(store: store)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
        store.showToast("已复制脱敏诊断摘要，可直接粘贴到官网 Bug 反馈页", duration: 3.2)
    }

    func revealLogsInFinder() {
        ensureLogsDirectory()
        if FileManager.default.fileExists(atPath: selfHealQueueURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([selfHealQueueURL])
        } else {
            NSWorkspace.shared.open(logsDirectoryURL)
        }
    }
}
