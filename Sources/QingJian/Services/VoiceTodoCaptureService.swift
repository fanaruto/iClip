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

    private var latestTranscript: String = ""
    private var isListening: Bool = false
    private var sessionToken: UUID = UUID()
    private var lastLevelNotifyUptime: TimeInterval = 0
    private var pendingCommitContinuation: CheckedContinuation<CommitResult, Never>?
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

        // 3. 初始化中文识别器与音频引擎（优先端侧识别降低延迟）
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            onPermissionDenied?("当前系统语音识别服务暂不可用，请稍后重试")
            return false
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            onPermissionDenied?("未检测到可用麦克风输入设备")
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

    /// 结束录制并等待最多 0.45s 的末帧收尾识别，然后拆解返回待办列表
    func finishListeningAndCommit() async -> CommitResult {
        guard isListening else {
            let trimmed = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .empty }
            let items = VoiceTodoParser.extractTodoItems(from: trimmed)
            return items.isEmpty ? .empty : .committed(items: items, rawTranscript: trimmed)
        }

        isListening = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()

        return await withCheckedContinuation { cont in
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
    }

    func cancelListening() {
        sessionToken = UUID()
        if let pending = pendingCommitContinuation {
            pendingCommitContinuation = nil
            pendingCommitWorkItem?.cancel()
            pendingCommitWorkItem = nil
            pending.resume(returning: .empty)
        }
        tearDownSession()
    }

    private func completePendingCommit(continuation: CheckedContinuation<CommitResult, Never>) {
        pendingCommitContinuation = nil
        pendingCommitWorkItem?.cancel()
        pendingCommitWorkItem = nil

        let raw = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        tearDownSession()

        guard !raw.isEmpty else {
            continuation.resume(returning: .empty)
            return
        }
        let items = VoiceTodoParser.extractTodoItems(from: raw)
        if items.isEmpty {
            continuation.resume(returning: .empty)
        } else {
            continuation.resume(returning: .committed(items: items, rawTranscript: raw))
        }
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
        onAudioLevelChanged?(0)
    }
}
