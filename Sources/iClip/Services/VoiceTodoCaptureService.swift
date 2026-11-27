@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// 长按语音转写文本拆解器与实时响度标准化（纯值无状态逻辑，直接供单元测试覆盖）
enum VoiceTodoParser {
    private static let leadingFillerPrefixes = [
        "帮我记一下", "请帮我记一下", "帮我记录", "请记录",
        "记一个待办", "加一个待办", "添加一个待办",
        "添加待办", "新增待办", "新建待办", "记一下待办",
        "提醒我一下", "提醒我", "别忘了", "记得", "记一下", "待办事项", "待办"
    ]

    private static let trimChars = CharacterSet(charactersIn: "：:，,、。.;；!！?？ ")

    /// 将语音转写原文清洗前缀并拆分为 0~N 条干净独立待办（过滤过短口癖噪声，保持出现顺序去重）
    static func extractTodoItems(from rawTranscript: String) -> [String] {
        var cleaned = rawTranscript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: trimChars.union(.whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return [] }

        // 剥离口语前导引导词
        var strippedPrefix = true
        while strippedPrefix {
            strippedPrefix = false
            for prefix in leadingFillerPrefixes where cleaned.hasPrefix(prefix) {
                let candidate = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: trimChars.union(.whitespacesAndNewlines))
                if !candidate.isEmpty {
                    cleaned = candidate
                    strippedPrefix = true
                    break
                }
            }
        }

        // 先按显式换行与分号切分，再对自然多任务口语连接词切分
        var coarseChunks = cleaned
            .components(separatedBy: CharacterSet(charactersIn: "\n；;"))
            .map { $0.trimmingCharacters(in: trimChars.union(.whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }

        let naturalConnectors = ["，还有", ",还有", "还有就是", "还有", "，另外", ",另外", "另外", "，然后", ",然后", "然后", "，顺便", ",顺便", "顺便"]
        for connector in naturalConnectors {
            coarseChunks = splitChunks(coarseChunks, by: connector, minSegmentLength: 3)
        }

        var result: [String] = []
        var seen = Set<String>()
        for chunk in coarseChunks {
            let body = chunk.trimmingCharacters(in: trimChars.union(.whitespacesAndNewlines))
            guard body.count >= 2 else { continue }
            // 再剥一遍单条残留的“还有/待办”前导
            var finalItem = body
            for p in ["待办", "提醒我", "还有"] where finalItem.hasPrefix(p) && finalItem.count > p.count + 2 {
                finalItem = String(finalItem.dropFirst(p.count)).trimmingCharacters(in: trimChars.union(.whitespacesAndNewlines))
            }
            guard finalItem.count >= 2, !seen.contains(finalItem) else { continue }
            seen.insert(finalItem)
            result.append(finalItem)
        }
        return result
    }

    private static func splitChunks(_ chunks: [String], by connector: String, minSegmentLength: Int) -> [String] {
        var out: [String] = []
        for chunk in chunks {
            let parts = chunk.components(separatedBy: connector)
            if parts.count <= 1 {
                out.append(chunk)
                continue
            }
            var buffer = ""
            for (idx, rawPart) in parts.enumerated() {
                let trimmed = rawPart.trimmingCharacters(in: trimChars.union(.whitespacesAndNewlines))
                if idx == 0 {
                    buffer = trimmed
                    continue
                }
                if buffer.count >= minSegmentLength && trimmed.count >= minSegmentLength {
                    out.append(buffer)
                    buffer = trimmed
                } else if !trimmed.isEmpty {
                    buffer = buffer.isEmpty ? trimmed : "\(buffer)\(connector)\(trimmed)"
                }
            }
            if !buffer.isEmpty {
                out.append(buffer)
            }
        }
        return out
    }

    /// 将 PCM RMS 振幅按对数分贝区间 (-50dB ... -8dB) 映射至 0.0 ... 1.0，使小声清晰可见、大声不削波
    static func computeNormalizedAudioLevel(rms: Float) -> Double {
        guard rms.isFinite && rms > 1e-6 else { return 0.0 }
        let db = 20.0 * Double(log10(rms))
        let minDb = -50.0
        let maxDb = -8.0
        return min(max((db - minDb) / (maxDb - minDb), 0.0), 1.0)
    }

    /// 在实时 AudioRealtime 线程计算缓冲 RMS（纯 nonisolated 无锁计算）
    nonisolated static func computeRMS(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        let samples = channelData[0]
        var sumSq: Float = 0
        for i in 0..<frameLength {
            let s = samples[i]
            sumSq += s * s
        }
        return sqrtf(sumSq / Float(frameLength))
    }
}

/// 长按悬浮精灵本地实时中文语音转写引擎（原生 Apple Speech + AVAudioEngine，零联网/优先离线端侧识别）
@MainActor
final class VoiceTodoCaptureService {
    static let shared = VoiceTodoCaptureService()

    enum CommitResult {
        case committed(items: [String], rawTranscript: String)
        case empty
        case failed(String)
    }

    var onAudioLevelChanged: ((Double) -> Void)?
    var onPartialTranscriptChanged: ((String) -> Void)?
    var onPermissionDenied: ((String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    /// macOS 26/27 原生 SpeechAnalyzer + SpeechTranscriber 流式端侧转写会话（类型擦除保持 macOS 14 兼容）
    private var modernAnalyzerSession: AnyObject?

    private var latestTranscript: String = ""
    private var isListening: Bool = false
    private var sessionToken: UUID = UUID()
    private var lastLevelNotifyUptime: TimeInterval = 0
    private var pendingCommitContinuation: CheckedContinuation<String, Never>?
    private var pendingCommitWorkItem: DispatchWorkItem?

    private init() {}

    func beginListening() async -> Bool {
        if isListening { return true }
        let currentSession = UUID()
        sessionToken = currentSession
        latestTranscript = ""

        // 1. 校验麦克风授权
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .denied, .restricted:
            onPermissionDenied?("需要开启麦克风权限，才能长按精灵语音记入待办")
            return false
        case .notDetermined:
            let granted = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    cont.resume(returning: ok)
                }
            }
            guard sessionToken == currentSession, granted else {
                if !granted {
                    onPermissionDenied?("您已拒绝麦克风权限，可在系统设置开启后使用语音待办")
                }
                return false
            }
        case .authorized:
            break
        @unknown default:
            return false
        }

        // 2. 校验语音识别授权
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .denied, .restricted:
            onPermissionDenied?("需要开启语音识别权限，才能将您的语音转为待办文本")
            return false
        case .notDetermined:
            let auth = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }
            guard sessionToken == currentSession, auth == .authorized else {
                if auth != .authorized {
                    onPermissionDenied?("语音识别未授权，可在系统设置隐私与安全性中允许")
                }
                return false
            }
        case .authorized:
            break
        @unknown default:
            return false
        }

        // 3. 启动音频引擎（macOS 26/27 优先原生 SpeechAnalyzer + SpeechTranscriber，本地模型未预装时零延迟回退 SFSpeechRecognizer）
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            onPermissionDenied?("未检测到可用麦克风输入设备")
            return false
        }

        // 注意：installTap 闭包在实时 CoreAudio 线程触发，保持 nonisolated 仅向主线程异步派发 UI 电平
        let levelHandler: @Sendable (Double) -> Void = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, self.isListening, self.sessionToken == currentSession else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastLevelNotifyUptime >= 0.016 else { return }
                self.lastLevelNotifyUptime = now
                self.onAudioLevelChanged?(level)
            }
        }

        if #available(macOS 26.0, *) {
            if let modernSession = await ModernSpeechAnalyzerSession.startIfInstalled(
                preferredLocale: Locale(identifier: "zh-CN"),
                inputFormat: format,
                onPartialTranscript: { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionToken == currentSession else { return }
                        guard !text.isEmpty else { return }
                        self.latestTranscript = text
                        if self.isListening {
                            self.onPartialTranscriptChanged?(text)
                        }
                    }
                }
            ) {
                guard sessionToken == currentSession else {
                    await modernSession.cancel()
                    return false
                }
                isListening = true
                self.audioEngine = engine
                self.modernAnalyzerSession = modernSession

                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    modernSession.appendAudioBuffer(buffer)
                    let rms = VoiceTodoParser.computeRMS(from: buffer)
                    let level = VoiceTodoParser.computeNormalizedAudioLevel(rms: rms)
                    levelHandler(level)
                }

                do {
                    engine.prepare()
                    try engine.start()
                    return true
                } catch {
                    await modernSession.cancel()
                    tearDownSession()
                    onPermissionDenied?("无法启动麦克风采集：\(error.localizedDescription)")
                    return false
                }
            }
        }

        // 回退经典端侧 SFSpeechRecognizer 引擎
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            onPermissionDenied?("当前系统语音识别服务暂不可用，请稍后重试")
            return false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        isListening = true
        self.speechRecognizer = recognizer
        self.audioEngine = engine
        self.recognitionRequest = request

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [request] buffer, _ in
            request.append(buffer)
            let rms = VoiceTodoParser.computeRMS(from: buffer)
            let level = VoiceTodoParser.computeNormalizedAudioLevel(rms: rms)
            levelHandler(level)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            tearDownSession()
            onPermissionDenied?("无法启动麦克风采集：\(error.localizedDescription)")
            return false
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errMsg = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.sessionToken == currentSession else { return }
                if let text, !text.isEmpty {
                    self.latestTranscript = text
                    if self.isListening {
                        self.onPartialTranscriptChanged?(text)
                    }
                }
                if isFinal || errMsg != nil {
                    if let cont = self.pendingCommitContinuation {
                        self.completePendingCommit(continuation: cont)
                    } else if let errMsg, self.isListening && self.latestTranscript.isEmpty {
                        _ = errMsg
                    }
                }
            }
        }

        return true
    }

    /// 结束录制并等待最多 0.45s 的末帧收尾识别，然后拆解返回待办列表（支持 macOS 26/27 端侧模型辅助提炼）
    func finishListeningAndCommit() async -> CommitResult {
        if #available(macOS 26.0, *), let modernSession = modernAnalyzerSession as? ModernSpeechAnalyzerSession {
            isListening = false
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            let finalized = await modernSession.finishAndCollect(timeoutSeconds: 0.45)
            if !finalized.isEmpty {
                latestTranscript = finalized
            }
            let raw = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            tearDownSession()
            return await buildCommitResult(from: raw)
        }

        guard isListening else {
            let trimmed = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            return await buildCommitResult(from: trimmed)
        }

        isListening = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()

        let rawTranscript: String = await withCheckedContinuation { cont in
            self.pendingCommitContinuation = cont
            let timeout = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let pending = self.pendingCommitContinuation else { return }
                    self.completePendingCommit(continuation: pending)
                }
            }
            self.pendingCommitWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: timeout)
        }

        return await buildCommitResult(from: rawTranscript)
    }

    private func buildCommitResult(from raw: String) async -> CommitResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if let aiRefined = await OnDeviceIntelligenceService.refineVoiceTodoItems(from: trimmed),
           !aiRefined.isEmpty {
            return .committed(items: aiRefined, rawTranscript: trimmed)
        }
        let items = VoiceTodoParser.extractTodoItems(from: trimmed)
        return items.isEmpty ? .empty : .committed(items: items, rawTranscript: trimmed)
    }

    func cancelListening() {
        sessionToken = UUID()
        if let pending = pendingCommitContinuation {
            pendingCommitContinuation = nil
            pendingCommitWorkItem?.cancel()
            pendingCommitWorkItem = nil
            pending.resume(returning: "")
        }
        if #available(macOS 26.0, *), let modernSession = modernAnalyzerSession as? ModernSpeechAnalyzerSession {
            modernAnalyzerSession = nil
            Task {
                await modernSession.cancel()
            }
        }
        tearDownSession()
    }

    private func completePendingCommit(continuation: CheckedContinuation<String, Never>) {
        pendingCommitContinuation = nil
        pendingCommitWorkItem?.cancel()
        pendingCommitWorkItem = nil

        let raw = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        tearDownSession()
        continuation.resume(returning: raw)
    }

    private func tearDownSession() {
        isListening = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        speechRecognizer = nil
        modernAnalyzerSession = nil
        onAudioLevelChanged?(0)
    }
}

/// macOS 26/27 原生 SpeechAnalyzer + SpeechTranscriber 端侧实时流式转写会话
/// 仅在目标语言离线语音资产已就绪时启用，零下载阻塞；音频采样率通过 AVAudioConverter 自动对齐最佳分析格式。
@available(macOS 26.0, *)
private final class ModernSpeechAnalyzerSession: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let targetFormat: AVAudioFormat
    private let converterLock = NSLock()
    private var converter: AVAudioConverter?
    private let transcriptLock = NSLock()
    private var latestText: String = ""
    private var resultsTask: Task<Void, Never>?

    private init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputContinuation = inputContinuation
        self.targetFormat = targetFormat
        if inputFormat != targetFormat {
            self.converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
    }

    static func startIfInstalled(
        preferredLocale: Locale,
        inputFormat: AVAudioFormat,
        onPartialTranscript: @escaping @Sendable (String) -> Void
    ) async -> ModernSpeechAnalyzerSession? {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) else {
            return nil
        }
        let installed = await SpeechTranscriber.installedLocales
        let supportedLang = supported.language.languageCode?.identifier.lowercased()
        let isLocallyInstalled = installed.contains { loc in
            loc.identifier.caseInsensitiveCompare(supported.identifier) == .orderedSame
                || (supportedLang != nil && loc.language.languageCode?.identifier.lowercased() == supportedLang)
        }
        guard isLocallyInstalled else { return nil }

        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: inputFormat
        ) ?? inputFormat

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let session = ModernSpeechAnalyzerSession(
            analyzer: analyzer,
            transcriber: transcriber,
            inputContinuation: continuation,
            inputFormat: inputFormat,
            targetFormat: targetFormat
        )

        session.resultsTask = Task { [weak session] in
            do {
                for try await result in transcriber.results {
                    let fragment = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !fragment.isEmpty else { continue }
                    session?.updateLatestTranscript(fragment)
                    onPartialTranscript(fragment)
                }
            } catch {
                // 正常取消或流关闭时静默收尾
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)
            return session
        } catch {
            continuation.finish()
            session.resultsTask?.cancel()
            await analyzer.cancelAndFinishNow()
            return nil
        }
    }

    func appendAudioBuffer(_ sourceBuffer: AVAudioPCMBuffer) {
        guard let prepared = prepareBufferForAnalyzer(sourceBuffer) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: prepared))
    }

    func finishAndCollect(timeoutSeconds: Double) async -> String {
        inputContinuation.finish()
        let clamped = max(0.15, timeoutSeconds)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await self.analyzer.finalizeAndFinishThroughEndOfInput()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
            }
            _ = await group.next()
            group.cancelAll()
        }
        resultsTask?.cancel()
        return readLatestTranscript()
    }

    func cancel() async {
        inputContinuation.finish()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }

    private func updateLatestTranscript(_ text: String) {
        transcriptLock.lock()
        latestText = text
        transcriptLock.unlock()
    }

    private func readLatestTranscript() -> String {
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        return latestText
    }

    private func prepareBufferForAnalyzer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        converterLock.lock()
        defer { converterLock.unlock() }

        guard let converter else {
            // 格式完全一致时做独立深拷贝，避免 CoreAudio 复写底层环形缓冲区
            guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
                return nil
            }
            copy.frameLength = source.frameLength
            if let srcChannels = source.floatChannelData, let dstChannels = copy.floatChannelData {
                let channelCount = Int(source.format.channelCount)
                let byteCount = Int(source.frameLength) * MemoryLayout<Float>.size
                for ch in 0..<channelCount {
                    memcpy(dstChannels[ch], srcChannels[ch], byteCount)
                }
                return copy
            }
            return nil
        }

        let ratio = targetFormat.sampleRate / max(1.0, source.format.sampleRate)
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var didSupply = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, outStatus in
            if didSupply {
                outStatus.pointee = .noDataNow
                return nil
            }
            didSupply = true
            outStatus.pointee = .haveData
            return source
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
