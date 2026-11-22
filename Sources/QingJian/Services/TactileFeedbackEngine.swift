import AppKit
import Foundation

/// 原生微声学与多级 Force Touch 触控板震动反馈引擎
///
/// 设计原则：
/// 1. 零外部音频资源依赖：启动后在内存中以 48kHz / 16-bit 立体声物理建模合成毫秒级温润微音效（总内存 < 120KB）；
/// 2. 高频耐听不聒噪：所有音色均经正弦柔化包络与低通平滑，时长控制在 14ms ~ 85ms，连续操作百次依然丝滑舒适；
/// 3. 差异化触控板震动编排：针对悬停刻度、切类目、复制确认、摘星收藏、棘轮入队、智变重塑、阻尼删除与液态吞噬提供截然不同的震感节奏；
/// 4. 严格尊重用户在设置页中的「交互音效」开关（关闭音效时仍保留细腻触控板物理震动）。
@MainActor
final class TactileFeedbackEngine {
    static let shared = TactileFeedbackEngine()

    enum Event {
        case hoverTick
        case tabSwitch
        case pasteCommit
        case openLink
        case favoriteOn
        case favoriteOff
        case queueToggle(added: Bool)
        case magicTransform
        case deleteItem
        case portalEngage
        case portalDevour
    }

    private enum SoundID: CaseIterable {
        case hoverTick
        case tabSwitch
        case pasteCommit
        case openLink
        case favoriteOn
        case favoriteOff
        case queueIn
        case queueOut
        case magicTransform
        case deleteItem
        case portalEngage
        case portalDevour
    }

    private var soundBank: [SoundID: NSSound] = [:]
    private var isBankPrepared = false
    private var lastHoverFeedbackTime: CFTimeInterval = 0
    private var lastNavHapticTime: CFTimeInterval = 0

    static let soundEnabledDefaultsKey = "QingJian.soundEffectsEnabled"

    var isSoundEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.soundEnabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.soundEnabledDefaultsKey)
    }

    private init() {}

    // MARK: - 公开触发入口

    func perform(_ event: Event) {
        let now = CACurrentMediaTime()

        switch event {
        case .hoverTick:
            // 65ms 防抖节流：快速划过一排按钮时像拨动机械表冠一样清脆有序，绝不连片炸响
            guard now - lastHoverFeedbackTime > 0.065 else { return }
            lastHoverFeedbackTime = now
            haptic(.alignment)
            playSound(.hoverTick, volume: 0.14)

        case .tabSwitch:
            haptic(.alignment)
            playSound(.tabSwitch, volume: 0.24)

        case .pasteCommit:
            haptic(.generic)
            playSound(.pasteCommit, volume: 0.28)

        case .openLink:
            // 清脆跃迁发射震感：先轻触对焦，32ms 后向上弹射确认
            haptic(.alignment)
            scheduleHaptic(.levelChange, after: 0.032)
            playSound(.openLink, volume: 0.28)

        case .favoriteOn:
            // 双段渐强摘星震感：先轻触对齐，42ms 后星芒锁定
            haptic(.alignment)
            scheduleHaptic(.levelChange, after: 0.042)
            playSound(.favoriteOn, volume: 0.30)

        case .favoriteOff:
            haptic(.alignment)
            playSound(.favoriteOff, volume: 0.22)

        case .queueToggle(let added):
            if added {
                haptic(.levelChange)
                playSound(.queueIn, volume: 0.26)
            } else {
                haptic(.alignment)
                playSound(.queueOut, volume: 0.20)
            }

        case .magicTransform:
            // 双段灵动重塑震感
            haptic(.alignment)
            scheduleHaptic(.generic, after: 0.036)
            playSound(.magicTransform, volume: 0.28)

        case .deleteItem:
            // 先沉后轻的物理落底阻尼震感
            haptic(.levelChange)
            scheduleHaptic(.alignment, after: 0.048)
            playSound(.deleteItem, volume: 0.26)

        case .portalEngage:
            haptic(.alignment)
            playSound(.portalEngage, volume: 0.20)

        case .portalDevour:
            // 三段式液态虹吸归位脉冲
            haptic(.alignment)
            scheduleHaptic(.levelChange, after: 0.055)
            scheduleHaptic(.generic, after: 0.125)
            playSound(.portalDevour, volume: 0.32)
        }
    }

    /// 键盘方向键高频选行/选图专用：仅提供极轻的触控板微刻度阻尼，不发声打扰心流
    func performNavigationStepHaptic() {
        let now = CACurrentMediaTime()
        guard now - lastNavHapticTime > 0.035 else { return }
        lastNavHapticTime = now
        haptic(.alignment)
    }

    // MARK: - Force Touch 触控板震动调度

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    private func scheduleHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }

    // MARK: - 低延迟内存声学回放

    private func playSound(_ id: SoundID, volume: Float) {
        guard isSoundEnabled else { return }
        ensureSoundBank()
        guard let proto = soundBank[id],
              let instance = proto.copy() as? NSSound else { return }
        instance.volume = volume
        instance.play()
    }

    private func ensureSoundBank() {
        guard !isBankPrepared else { return }
        isBankPrepared = true

        // 1. 悬停微刻度：15ms 丝绒高阻尼短触（1480Hz -> 1820Hz 极轻泛音）
        soundBank[.hoverTick] = Self.makeSound(duration: 0.015) { t, _ in
            let env = exp(-t * 260.0) * sin(min(1.0, t / 0.002) * .pi * 0.5)
            let freq = 1480.0 + 340.0 * (t / 0.015)
            return sin(2.0 * .pi * freq * t) * env * 0.45
        }

        // 2. 切类目滑块：24ms 温润胡桃木轻叩（540Hz 基频 + 二次谐波）
        soundBank[.tabSwitch] = Self.makeSound(duration: 0.024) { t, _ in
            let attack = min(1.0, t / 0.0018)
            let env = attack * exp(-t * 155.0)
            let f0 = 540.0
            return (sin(2.0 * .pi * f0 * t) * 0.72 + sin(2.0 * .pi * f0 * 1.98 * t) * 0.28) * env * 0.65
        }

        // 3. 复制/键入确认：52ms 纯五度晶莹双音（C6 -> G6 玻璃钟琴）
        soundBank[.pasteCommit] = Self.makeSound(duration: 0.052) { t, _ in
            let note1 = t < 0.040 ? sin(2.0 * .pi * 1046.5 * t) * exp(-t * 95.0) * min(1.0, t / 0.002) : 0.0
            let t2 = max(0.0, t - 0.016)
            let note2 = t >= 0.016 ? sin(2.0 * .pi * 1568.0 * t2) * exp(-t2 * 85.0) * min(1.0, t2 / 0.002) : 0.0
            return (note1 * 0.52 + note2 * 0.62) * 0.65
        }

        // 3b. 链接跃迁直达：60ms 清透上扬滑音 + 高八度泛音（G5 -> D6 -> G6 轻盈发射感）
        soundBank[.openLink] = Self.makeSound(duration: 0.060) { t, _ in
            let p = t / 0.060
            let sweep = 2.0 * .pi * (784.0 * t + 392.0 * p * t)
            let env1 = min(1.0, t / 0.002) * exp(-t * 62.0)
            let dt = max(0.0, t - 0.020)
            let chime = t >= 0.020 ? sin(2.0 * .pi * 1568.0 * dt) * min(1.0, dt / 0.002) * exp(-dt * 78.0) : 0.0
            return (sin(sweep) * env1 * 0.52 + chime * 0.58) * 0.66
        }

        // 4. 点亮收藏星标：78ms 水晶大三和弦微琶音（E6 -> G#6 -> B6 轻盈绽放）
        soundBank[.favoriteOn] = Self.makeSound(duration: 0.078) { t, _ in
            var s = 0.0
            let notes: [(Double, Double, Double)] = [
                (0.000, 1318.5, 0.46),
                (0.018, 1661.2, 0.48),
                (0.036, 1975.5, 0.58)
            ]
            for (onset, freq, amp) in notes where t >= onset {
                let dt = t - onset
                let env = min(1.0, dt / 0.002) * exp(-dt * 72.0)
                s += (sin(2.0 * .pi * freq * dt) + 0.22 * sin(2.0 * .pi * freq * 2.0 * dt)) * env * amp
            }
            return s * 0.55
        }

        // 5. 取消收藏：40ms 柔和下行收拢（B5 -> E5）
        soundBank[.favoriteOff] = Self.makeSound(duration: 0.040) { t, _ in
            let p = t / 0.040
            let phase = 2.0 * .pi * (987.7 * t - 210.0 * p * t)
            let env = min(1.0, t / 0.0025) * exp(-t * 95.0)
            return sin(phase) * env * 0.55
        }

        // 6. 棘轮入队 / 合并勾选：34ms 磁吸锁扣咔哒（760Hz -> 1140Hz）
        soundBank[.queueIn] = Self.makeSound(duration: 0.034) { t, _ in
            let n1 = sin(2.0 * .pi * 760.0 * t) * exp(-t * 140.0) * min(1.0, t / 0.0015)
            let dt = max(0.0, t - 0.012)
            let n2 = t >= 0.012 ? sin(2.0 * .pi * 1140.0 * dt) * exp(-dt * 125.0) * min(1.0, dt / 0.0015) : 0.0
            return (n1 * 0.55 + n2 * 0.65) * 0.65
        }

        // 7. 移出队列 / 取消勾选：30ms 柔和解扣
        soundBank[.queueOut] = Self.makeSound(duration: 0.030) { t, _ in
            let env = min(1.0, t / 0.002) * exp(-t * 135.0)
            return sin(2.0 * .pi * (920.0 - 260.0 * (t / 0.030)) * t) * env * 0.55
        }

        // 8. 智变 / 财务 / OCR 转换：70ms 棱镜泛音流转
        soundBank[.magicTransform] = Self.makeSound(duration: 0.070) { t, _ in
            let notes: [(Double, Double)] = [(0.0, 880.0), (0.015, 1174.7), (0.030, 1760.0)]
            var acc = 0.0
            for (onset, f) in notes where t >= onset {
                let dt = t - onset
                acc += sin(2.0 * .pi * f * dt) * min(1.0, dt / 0.0025) * exp(-dt * 75.0) * 0.45
            }
            return acc * 0.65
        }

        // 9. 删除记录：56ms 低频柔焦落桶阻尼音（260Hz -> 92Hz 温润下潜，零刺耳高频）
        soundBank[.deleteItem] = Self.makeSound(duration: 0.056) { t, _ in
            let p = t / 0.056
            let instPhase = 2.0 * .pi * (260.0 * t - 84.0 * p * t)
            let env = min(1.0, t / 0.0025) * exp(-t * 68.0)
            let softAir = sin(t * 9800.0) * sin(t * 3100.0) * exp(-t * 190.0) * 0.14
            return (sin(instPhase) * 0.78 + softAir) * env * 0.72
        }

        // 10. 液态水滴锁定：36ms 深水共鸣微鸣
        soundBank[.portalEngage] = Self.makeSound(duration: 0.036) { t, _ in
            let env = min(1.0, t / 0.004) * exp(-t * 88.0)
            return (sin(2.0 * .pi * 620.0 * t) * 0.6 + sin(2.0 * .pi * 930.0 * t) * 0.4) * env * 0.55
        }

        // 11. 液态水滴吞噬归位：85ms 水珠向上虹吸“啵”声包络（310Hz -> 1080Hz 指数滑音）
        soundBank[.portalDevour] = Self.makeSound(duration: 0.085) { t, _ in
            let p = t / 0.085
            let sweepPhase = 2.0 * .pi * (310.0 * t + 385.0 * p * p * t)
            let bellEnv = sin(min(1.0, p * 1.15) * .pi) * exp(-t * 24.0)
            return (sin(sweepPhase) * 0.75 + sin(sweepPhase * 1.5) * 0.25) * bellEnv * 0.68
        }
    }

    // MARK: - 48kHz 16-bit Stereo WAV 内存生成器

    private static func makeSound(duration: Double, sampleAt: (Double, Double) -> Double) -> NSSound? {
        let sampleRate = 48_000
        let frameCount = max(1, Int(duration * Double(sampleRate)))
        let channels = 2
        let bytesPerSample = 2
        let dataByteCount = frameCount * channels * bytesPerSample

        var data = Data(capacity: 44 + dataByteCount)

        func appendASCII(_ s: String) {
            data.append(contentsOf: s.utf8)
        }
        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataByteCount))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * channels * bytesPerSample))
        appendUInt16(UInt16(channels * bytesPerSample))
        appendUInt16(UInt16(bytesPerSample * 8))
        appendASCII("data")
        appendUInt32(UInt32(dataByteCount))

        var pcm = [Int16](repeating: 0, count: frameCount * channels)
        for i in 0..<frameCount {
            let t = Double(i) / Double(sampleRate)
            let raw = max(-0.98, min(0.98, sampleAt(t, duration)))
            let s16 = Int16(raw * Double(Int16.max))
            pcm[i * 2] = s16
            pcm[i * 2 + 1] = s16
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }

        return NSSound(data: data)
    }
}
