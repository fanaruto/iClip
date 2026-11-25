import AppKit
import Combine
import Metal
import QuartzCore
import SwiftUI

/// 悬浮精灵吸附的屏幕边缘方向
enum SpriteOrbEdgeSide: String, Equatable {
    case left
    case right
}

/// 悬浮精灵根据复制内容、语音或拟态建议实时映射的心情光色
enum SpriteOrbMoodAccent: Equatable {
    case cobalt
    case emerald
    case amber
    case coral

    var rgbTuple: (Float, Float, Float) {
        switch self {
        case .cobalt:
            return (0.118, 0.369, 1.0) // #1E5EFF 电光蓝
        case .emerald:
            return (0.063, 0.725, 0.506) // #10B981 翡翠绿
        case .amber:
            return (0.961, 0.620, 0.043) // #F59E0B 琥珀金
        case .coral:
            return (0.957, 0.247, 0.369) // #F43F5E 珊瑚红
        }
    }
}

/// 风格 2「精密点阵表冠」中心 5×5 LED 语义点阵字模与态模式
enum SpriteOrbMatrixGlyph: Equatable {
    case none
    case todo
    case link
    case clean
    case image
    case panelOpen
    case done
    case voiceEqualizer
    case biomimeticBlink

    var bitmask25: UInt32? {
        let bits: [Int]
        switch self {
        case .none, .voiceEqualizer, .biomimeticBlink:
            return nil
        case .todo:
            bits = [
                0, 1, 1, 1, 0,
                1, 0, 0, 0, 1,
                1, 0, 1, 0, 1,
                1, 0, 0, 0, 1,
                0, 1, 1, 1, 0
            ]
        case .link:
            bits = [
                0, 0, 1, 1, 1,
                0, 1, 0, 0, 1,
                0, 0, 1, 0, 0,
                1, 0, 0, 1, 0,
                1, 1, 1, 0, 0
            ]
        case .clean:
            bits = [
                0, 0, 1, 0, 0,
                0, 1, 1, 1, 0,
                1, 1, 1, 1, 1,
                0, 1, 1, 1, 0,
                0, 0, 1, 0, 0
            ]
        case .image:
            bits = [
                1, 1, 1, 1, 1,
                1, 1, 0, 0, 1,
                1, 0, 1, 0, 1,
                1, 0, 0, 1, 1,
                1, 1, 1, 1, 1
            ]
        case .panelOpen:
            bits = [
                1, 1, 1, 1, 1,
                0, 0, 0, 0, 0,
                1, 1, 1, 1, 1,
                0, 0, 0, 0, 0,
                1, 1, 1, 0, 0
            ]
        case .done:
            bits = [
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 1,
                1, 0, 0, 1, 0,
                0, 1, 1, 0, 0,
                0, 0, 0, 0, 0
            ]
        }
        var packed: UInt32 = 1 << 25
        for (idx, bit) in bits.enumerated() where bit == 1 {
            packed |= (1 << UInt32(idx))
        }
        return packed
    }

    var packedShaderMask: UInt32 {
        switch self {
        case .none:
            return 0
        case .voiceEqualizer:
            return 1 << 26
        case .biomimeticBlink:
            return 1 << 27
        default:
            return bitmask25 ?? 0
        }
    }
}

// MARK: - 主动智能拟态待办推进策略大脑（纯值类型可单元测试）

struct ProactiveTodoNudgeCandidate: Equatable {
    let itemID: UUID
    let todoText: String
    let pendingCount: Int
    let headline: String
    let personaLine: String
    let isUrgent: Bool
}

enum ProactiveTodoNudgePlanner {
    private static let urgencyKeywords = [
        "下班前", "今晚前", "中午前", "点前", "今天", "马上",
        "尽快", "紧急", "截止", "deadline", "ASAP"
    ]

    /// 基于截止词紧迫度、积压时长、OneMind 黄金时段与冷却防打扰策略选出一条拟态待办推进建议
    static func selectNudgeCandidate(
        from items: [ClipItem],
        now: Date,
        lastGlobalNudgeAt: Date?,
        snoozedUntil: [UUID: Date],
        minimumGlobalInterval: TimeInterval = 18 * 60,
        minimumItemAge: TimeInterval = 25 * 60,
        preferredHours: Set<Int> = [],
        forceImmediate: Bool = false
    ) -> ProactiveTodoNudgeCandidate? {
        let pending = items.filter(\.isPendingTodo)
        guard !pending.isEmpty else { return nil }

        if !forceImmediate, let last = lastGlobalNudgeAt, now.timeIntervalSince(last) < minimumGlobalInterval {
            return nil
        }

        let eligible = pending.filter { item in
            if let snoozeDate = snoozedUntil[item.id], snoozeDate > now {
                return false
            }
            return true
        }
        guard !eligible.isEmpty else { return nil }

        let hour = Calendar.current.component(.hour, from: now)
        let isPreferredHour = preferredHours.contains(hour)

        struct Scored {
            let item: ClipItem
            let score: Double
            let isUrgent: Bool
            let ageSeconds: TimeInterval
            let displayBody: String
        }

        let scored: [Scored] = eligible.compactMap { item in
            let age = max(0, now.timeIntervalSince(item.createdAt))
            let bodySource = (item.customAlias?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? (item.customAlias ?? item.rawContentPreview)
                : item.rawContentPreview
            let cleanBody = bodySource
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanBody.isEmpty else { return nil }

            let lower = cleanBody.lowercased()
            let urgent = urgencyKeywords.contains(where: { lower.contains($0.lowercased()) })
            if !forceImmediate {
                let baseAge = isPreferredHour ? min(minimumItemAge, 12 * 60) : minimumItemAge
                let requiredAge = urgent ? min(minimumItemAge, 8 * 60) : baseAge
                if age < requiredAge {
                    return nil
                }
            }

            var pts = min(72.0, age / 3600.0) * 10.0
            if urgent { pts += 1000.0 }
            if isPreferredHour { pts += 15.0 }
            if item.isPinned { pts += 5.0 }
            return Scored(item: item, score: pts, isUrgent: urgent, ageSeconds: age, displayBody: cleanBody)
        }

        guard let top = scored.sorted(by: { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.createdAt < rhs.item.createdAt
        }).first else {
            return nil
        }

        let headline: String
        let personaLine: String
        if top.isUrgent {
            headline = "临近时间节点"
            personaLine = "这项快到点啦，先推进一下？"
        } else if isPreferredHour {
            headline = "OneMind 黄金节奏"
            personaLine = "你常在这个时段推进待办，顺手处理这条？"
        } else if hour >= 17 && hour <= 20 {
            headline = "今日待办收个尾"
            personaLine = "快到收尾时间，还有 \(pending.count) 项待办，先处理这条？"
        } else if top.ageSeconds >= 3600 {
            headline = "搁置超过 1 小时"
            personaLine = "这条已等了挺久，要不要先勾选推进？"
        } else {
            headline = "轻碰你一下 · 余 \(pending.count) 项待办"
            personaLine = "手头闲下来时，顺手把这条推进掉？"
        }

        return ProactiveTodoNudgeCandidate(
            itemID: top.item.id,
            todoText: top.displayBody,
            pendingCount: pending.count,
            headline: headline,
            personaLine: personaLine,
            isUrgent: top.isUrgent
        )
    }
}

// MARK: - 零冲突三态手势仲裁器（单击剪贴板 / 拖动换位 / 原地长按语音记待办）

enum SpriteOrbArbiterAction: Equatable {
    case none
    case enteredDragging
    case triggerClick
    case endDragging
    case startedVoice
    case voiceCancelStateChanged(Bool)
    case commitVoice
    case cancelVoice
}

struct SpriteOrbGestureArbiter: Equatable {
    enum Phase: Equatable {
        case idle
        case pressing(startScreenPoint: CGPoint, startUptime: TimeInterval)
        case dragging
        case voiceRecording(startScreenPoint: CGPoint, isCancelling: Bool)
    }

    static let dragThreshold: CGFloat = 5.0
    static let longPressDelay: TimeInterval = 0.36
    static let chargeRevealDelay: TimeInterval = 0.12
    static let voiceCancelSlideDistance: CGFloat = 52.0

    private(set) var phase: Phase = .idle

    var isPressingOrRecording: Bool {
        switch phase {
        case .pressing, .voiceRecording:
            return true
        case .idle, .dragging:
            return false
        }
    }

    mutating func pointerDown(atScreenPoint point: CGPoint, uptime: TimeInterval) {
        phase = .pressing(startScreenPoint: point, startUptime: uptime)
    }

    mutating func pointerMoved(toScreenPoint point: CGPoint) -> SpriteOrbArbiterAction {
        switch phase {
        case .pressing(let start, _):
            let dist = hypot(point.x - start.x, point.y - start.y)
            if dist > Self.dragThreshold {
                phase = .dragging
                return .enteredDragging
            }
            return .none

        case .voiceRecording(let start, let prevCancel):
            let dist = hypot(point.x - start.x, point.y - start.y)
            let nowCancel = dist > Self.voiceCancelSlideDistance
            if nowCancel != prevCancel {
                phase = .voiceRecording(startScreenPoint: start, isCancelling: nowCancel)
                return .voiceCancelStateChanged(nowCancel)
            }
            return .none

        case .idle, .dragging:
            return .none
        }
    }

    mutating func checkLongPressActivation(atUptime uptime: TimeInterval) -> (activated: Bool, chargeProgress: Double) {
        guard case .pressing(let startPt, let startUptime) = phase else {
            return (false, 0.0)
        }
        let elapsed = max(0, uptime - startUptime)
        if elapsed >= Self.longPressDelay {
            phase = .voiceRecording(startScreenPoint: startPt, isCancelling: false)
            return (true, 1.0)
        }
        if elapsed >= Self.chargeRevealDelay {
            let span = max(0.01, Self.longPressDelay - Self.chargeRevealDelay)
            let p = min(max((elapsed - Self.chargeRevealDelay) / span, 0.0), 1.0)
            return (false, p)
        }
        return (false, 0.0)
    }

    mutating func pointerUp(atScreenPoint point: CGPoint, uptime: TimeInterval) -> SpriteOrbArbiterAction {
        _ = uptime
        switch phase {
        case .idle:
            return .none

        case .pressing(let start, _):
            let dist = hypot(point.x - start.x, point.y - start.y)
            phase = .idle
            return (dist <= Self.dragThreshold) ? .triggerClick : .endDragging

        case .dragging:
            phase = .idle
            return .endDragging

        case .voiceRecording(let start, _):
            let dist = hypot(point.x - start.x, point.y - start.y)
            phase = .idle
            return (dist > Self.voiceCancelSlideDistance) ? .cancelVoice : .commitVoice
        }
    }

    mutating func reset() {
        phase = .idle
    }
}

// MARK: - 悬浮精灵纯几何定位、手势阈值与非对称零溢出停靠算法

enum SpriteOrbPhysicsGeometry {
    static let panelDimension: CGFloat = 176
    static let orbVisualRadius: CGFloat = 25
    static let hitTestRadius: CGFloat = 31
    static let dragThreshold: CGFloat = SpriteOrbGestureArbiter.dragThreshold
    static let edgeVisualMargin: CGFloat = 13.0

    /// 判定指针移动距离是否属于「单击启动剪贴板」而非「拖拽换位」
    static func isClickGesture(dragDistance: CGFloat) -> Bool {
        dragDistance <= dragThreshold
    }

    /// 根据当前停靠模式计算球体静息中心在 176×176 舞台（左上原点，Y 向下）内的锚点
    static func anchorInPanel(for dockedSide: SpriteOrbEdgeSide?) -> CGPoint {
        let midY = panelDimension * 0.5
        let edgeCenterOffset = orbVisualRadius + edgeVisualMargin // 38pt
        switch dockedSide {
        case .left:
            return CGPoint(x: edgeCenterOffset, y: midY)
        case .right:
            return CGPoint(x: panelDimension - edgeCenterOffset, y: midY)
        case nil:
            return CGPoint(x: panelDimension * 0.5, y: midY)
        }
    }

    /// 由 176×176 舞台外框推导出核心 50×50 实球体的屏幕坐标
    static func orbCoreFrame(fromPanelFrame panelFrame: NSRect, dockedSide: SpriteOrbEdgeSide? = nil) -> NSRect {
        let anchor = anchorInPanel(for: dockedSide)
        let centerX = panelFrame.minX + anchor.x
        let centerY = panelFrame.maxY - anchor.y
        let side = orbVisualRadius * 2
        return NSRect(
            x: centerX - orbVisualRadius,
            y: centerY - orbVisualRadius,
            width: side,
            height: side
        )
    }

    /// 反推使球心精确位于目标屏幕点时，176×176 面板对应的窗口原点
    static func panelOrigin(forOrbCenter orbCenter: NSPoint, dockedSide: SpriteOrbEdgeSide?) -> NSPoint {
        let anchor = anchorInPanel(for: dockedSide)
        return NSPoint(
            x: orbCenter.x - anchor.x,
            y: orbCenter.y - (panelDimension - anchor.y)
        )
    }

    /// 首次启动时的默认初始位置：贴靠主屏右侧中下区
    static func defaultInitialOrigin(panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        let x = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        let rawY = visibleFrame.minY + visibleFrame.height * 0.34
        let minY = visibleFrame.minY + 10
        let maxY = max(minY, visibleFrame.maxY - panelSize.height - 10)
        let clampedY = min(max(rawY, minY), maxY)
        return NSPoint(x: x, y: clampedY)
    }

    /// 拖拽松手或屏幕参数变化后计算最终静止原点与吸附边向
    static func resolvedRestingOrigin(
        currentOrigin: NSPoint,
        panelSize: NSSize,
        visibleFrame: NSRect,
        dockMode: SpriteOrbDockMode
    ) -> (origin: NSPoint, dockedSide: SpriteOrbEdgeSide?) {
        let minY = visibleFrame.minY + 10
        let maxY = max(minY, visibleFrame.maxY - panelSize.height - 10)
        let clampedY = min(max(currentOrigin.y, minY), maxY)

        switch dockMode {
        case .edgeSnap:
            let midX = currentOrigin.x + panelSize.width * 0.5
            let snapRight = midX >= visibleFrame.midX
            let snapX = snapRight
                ? max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
                : visibleFrame.minX
            return (NSPoint(x: snapX, y: clampedY), snapRight ? .right : .left)

        case .freeFloat:
            let minX = visibleFrame.minX + 4
            let maxX = max(minX, visibleFrame.maxX - panelSize.width - 4)
            let clampedX = min(max(currentOrigin.x, minX), maxX)
            return (NSPoint(x: clampedX, y: clampedY), nil)
        }
    }

    /// 将持久化归一化比例还原为目标屏幕的窗口原点
    static func origin(
        fromRatios ratioX: CGFloat,
        ratioY: CGFloat,
        panelSize: NSSize,
        visibleFrame: NSRect,
        dockMode: SpriteOrbDockMode
    ) -> (origin: NSPoint, dockedSide: SpriteOrbEdgeSide?) {
        let usableWidth = max(1, visibleFrame.width - panelSize.width)
        let usableHeight = max(1, visibleFrame.height - panelSize.height)
        let raw = NSPoint(
            x: visibleFrame.minX + min(max(ratioX, 0), 1) * usableWidth,
            y: visibleFrame.minY + min(max(ratioY, 0), 1) * usableHeight
        )
        return resolvedRestingOrigin(
            currentOrigin: raw,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            dockMode: dockMode
        )
    }

    /// 将当前屏幕窗口原点映射回与分辨率无关的归一化比例（0...1）
    static func normalizedRatios(
        forOrigin origin: NSPoint,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> (x: CGFloat, y: CGFloat) {
        let usableWidth = max(1, visibleFrame.width - panelSize.width)
        let usableHeight = max(1, visibleFrame.height - panelSize.height)
        let rx = min(max((origin.x - visibleFrame.minX) / usableWidth, 0), 1)
        let ry = min(max((origin.y - visibleFrame.minY) / usableHeight, 0), 1)
        return (rx, ry)
    }

    /// 计算单击精灵时主剪贴板面板的就近绽放坐标
    static func panelAnchorOrigin(
        forOrbCoreFrame orbRect: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect,
        shadowBleed: CGFloat
    ) -> (origin: NSPoint, entryDelta: NSPoint) {
        let placeOnLeft = orbRect.midX >= visibleFrame.midX
        let rawLeft = placeOnLeft
            ? (orbRect.minX - panelSize.width - 14)
            : (orbRect.maxX + 14)
        let minLeft = visibleFrame.minX + 10
        let maxLeft = max(minLeft, visibleFrame.maxX - panelSize.width - 10)
        let cardLeft = min(max(rawLeft, minLeft), maxLeft)

        let rawBottom = orbRect.midY - panelSize.height * 0.5
        let minBottom = visibleFrame.minY + 10
        let maxBottom = max(minBottom, visibleFrame.maxY - panelSize.height - 10)
        let cardBottom = min(max(rawBottom, minBottom), maxBottom)

        return (
            NSPoint(x: cardLeft - shadowBleed, y: cardBottom - shadowBleed),
            NSPoint(x: placeOnLeft ? 10 : -10, y: 0)
        )
    }

    /// 计算智能伴生卡片紧贴精灵旁侧的安全坐标（预留 22pt 声波环净空）
    static func sparkAnchorOrigin(
        forOrbCoreFrame orbRect: NSRect,
        sparkSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let placeOnLeft = orbRect.midX >= visibleFrame.midX
        let rawX = placeOnLeft
            ? (orbRect.minX - sparkSize.width - 22)
            : (orbRect.maxX + 22)
        let minX = visibleFrame.minX + 10
        let maxX = max(minX, visibleFrame.maxX - sparkSize.width - 10)
        let x = min(max(rawX, minX), maxX)

        let rawY = orbRect.midY - sparkSize.height * 0.5
        let minY = visibleFrame.minY + 10
        let maxY = max(minY, visibleFrame.maxY - sparkSize.height - 10)
        let y = min(max(rawY, minY), maxY)
        return NSPoint(x: x, y: y)
    }
}

// MARK: - 120Hz 连续二阶弹簧与粒子物理引擎（纯值类型可单元测试核心）

struct SpriteInflowParticle: Equatable {
    var startOffsetX: Double
    var startOffsetY: Double
    var ctrlOffsetX: Double
    var ctrlOffsetY: Double
    var progress: Double
    var size: Double
    var accent: SpriteOrbMoodAccent
    var isWhite: Bool
}

struct SpriteSparkParticle: Equatable {
    var offsetX: Double
    var offsetY: Double
    var vx: Double
    var vy: Double
    var life: Double
    var isWhite: Bool
}

struct SpriteRippleWave: Equatable {
    var offsetX: Double
    var offsetY: Double
    var radius: Double
    var maxRadius: Double
    var alpha: Double
    var accent: SpriteOrbMoodAccent
}

struct SpritePendingInflowImpact: Equatable {
    var delay: Double
    var accent: SpriteOrbMoodAccent
    var isNudgeBeat: Bool = false
}

struct SpriteOrbPhysicsInput: Equatable {
    var isHoveredOnCore: Bool = false
    var isPressed: Bool = false
    var isDragging: Bool = false
    var isDragTargeted: Bool = false
    var isClipboardPanelOpen: Bool = false
    var smartSuggestionActive: Bool = false
    var proactiveNudgeActive: Bool = false
    var voiceActive: Bool = false
    var voiceCancelSlide: Bool = false
    var audioLevel: Double = 0.0
    var chargeProgress: Double = 0.0
    var nudgePeekOffsetX: Double = 0.0
    var pointerOffsetFromAnchor: CGPoint? = nil
    var dragStepVelocity: CGVector = .zero
}

struct SpriteOrbPhysicsState: Equatable {
    var time: Double = 0

    // 二阶位置弹簧与速度（相对静态 anchor 偏移，Y 向下）
    var offsetX: Double = 0
    var offsetY: Double = 0
    var vx: Double = 0
    var vy: Double = 0

    // 光标磁吸、张力、语音与取消滑态平滑通道
    var hoverBlend: Double = 0
    var pressBlend: Double = 0
    var tensionPull: Double = 0
    var tensionAngle: Double = 0
    var voiceActiveBlend: Double = 0
    var cancelSlideBlend: Double = 0
    var smoothedAudioLevel: Double = 0
    var idleRestBlend: Double = 0

    // 二阶缩放脉冲弹簧 + 毛细水波 + 极光漩涡 + 表冠追指角
    var scaleImpulse: Double = 0
    var scaleVel: Double = 0
    var capillaryAmp: Double = 0
    var vortexBlend: Double = 0
    var crownAngle: Double = -0.35

    // 心情光色与持续脉冲状态
    var captureAccent: SpriteOrbMoodAccent = .cobalt
    var captureMoodRemaining: Double = 0
    var smartSuggestionAccent: SpriteOrbMoodAccent = .emerald

    // 特效粒子池
    var inflowParticles: [SpriteInflowParticle] = []
    var pendingInflowImpacts: [SpritePendingInflowImpact] = []
    var sparks: [SpriteSparkParticle] = []
    var ripples: [SpriteRippleWave] = []

    var breathWave: Double {
        sin(time * 2.05)
    }

    var breathScale: Double {
        var s = 1.0 + breathWave * 0.08 + scaleImpulse + hoverBlend * 0.05 - pressBlend * 0.09
        if smoothedAudioLevel > 0.01 {
            s += smoothedAudioLevel * 0.07
        }
        return s
    }

    var hasActiveEffects: Bool {
        !inflowParticles.isEmpty
            || !pendingInflowImpacts.isEmpty
            || !sparks.isEmpty
            || !ripples.isEmpty
            || abs(scaleImpulse) > 0.003
            || abs(scaleVel) > 0.015
            || capillaryAmp > 0.01
            || vortexBlend > 0.01
            || voiceActiveBlend > 0.02
            || abs(vx) > 1.8
            || abs(vy) > 1.8
    }

    func activeAccent(smartSuggestionActive: Bool, proactiveNudgeActive: Bool) -> SpriteOrbMoodAccent {
        if proactiveNudgeActive {
            return .amber
        }
        if smartSuggestionActive {
            return smartSuggestionAccent
        }
        if captureMoodRemaining > 0 {
            return captureAccent
        }
        return .cobalt
    }

    mutating func step(dt rawDt: Double, input: SpriteOrbPhysicsInput, idleRestingTarget: Bool = false) {
        let dt = min(max(rawDt, 0.0005), 0.04)
        time += dt

        if captureMoodRemaining > 0 {
            captureMoodRemaining = max(0, captureMoodRemaining - dt)
        }

        // 平滑录音态、划出取消态、音频响度与静息透明度
        let voiceTarget = input.voiceActive ? 1.0 : 0.0
        voiceActiveBlend += (voiceTarget - voiceActiveBlend) * (1.0 - exp(-15.0 * dt))
        let cancelTarget = (input.voiceActive && input.voiceCancelSlide) ? 1.0 : 0.0
        cancelSlideBlend += (cancelTarget - cancelSlideBlend) * (1.0 - exp(-14.0 * dt))
        let audioTarget = input.voiceActive ? min(max(input.audioLevel, 0.0), 1.0) : 0.0
        let audioRate = (audioTarget > smoothedAudioLevel) ? 26.0 : 12.0
        smoothedAudioLevel += (audioTarget - smoothedAudioLevel) * (1.0 - exp(-audioRate * dt))
        let restTarget = idleRestingTarget ? 1.0 : 0.0
        idleRestBlend += (restTarget - idleRestBlend) * (1.0 - exp(-5.0 * dt))

        // 1. 远场光标磁吸（< 142pt 轻盈探身）与表面张力形变（< 130pt）
        var targetX = input.proactiveNudgeActive ? input.nudgePeekOffsetX : 0.0
        var targetY = sin(time * 1.95) * 3.2

        var mouseDist = 999.0
        var hasPointer = false
        var mdx = 0.0
        var mdy = 0.0
        if let ptr = input.pointerOffsetFromAnchor, !input.isDragging && !input.voiceActive {
            hasPointer = true
            mdx = Double(ptr.x)
            mdy = Double(ptr.y)
            mouseDist = hypot(mdx, mdy)
            if mouseDist < 142.0 && mouseDist > 1.0 {
                let pull = pow(1.0 - mouseDist / 142.0, 1.35) * 12.0
                targetX += (mdx / mouseDist) * pull
                targetY += (mdy / mouseDist) * pull
            }
        }

        let hoverTarget: Double = (!input.isDragging && (input.isHoveredOnCore || (hasPointer && mouseDist < 60.0))) ? 1.0 : 0.0
        hoverBlend += (hoverTarget - hoverBlend) * (1.0 - exp(-11.0 * dt))

        let pressTarget: Double = (input.isPressed && !input.voiceActive) ? 1.0 : 0.0
        pressBlend += (pressTarget - pressBlend) * (1.0 - exp(-22.0 * dt))

        let tensionTarget: Double = (!input.isDragging && !input.voiceActive && hasPointer && mouseDist < 130.0)
            ? pow(1.0 - mouseDist / 130.0, 1.2)
            : 0.0
        tensionPull += (tensionTarget - tensionPull) * (1.0 - exp(-14.0 * dt))
        if hasPointer && mouseDist > 1.0 {
            let relX = mdx - offsetX
            let relY = mdy - offsetY
            if hypot(relX, relY) > 0.5 {
                tensionAngle = atan2(relY, relX)
            }
        }

        // 2. 二阶弹簧位置积分（k = 185, d = 15.5）
        if !input.isDragging {
            let k = 185.0
            let d = 15.5
            vx += ((targetX - offsetX) * k - vx * d) * dt
            vy += ((targetY - offsetY) * k - vy * d) * dt
            offsetX += vx * dt
            offsetY += vy * dt
        } else {
            offsetX += (0.0 - offsetX) * (1.0 - exp(-18.0 * dt))
            offsetY += (0.0 - offsetY) * (1.0 - exp(-18.0 * dt))
            vx = Double(input.dragStepVelocity.dx) * 0.45
            vy = Double(input.dragStepVelocity.dy) * 0.45
        }

        // 3. 缩放 импульс二阶弹簧 + 毛细波纹 + 极光漩涡衰变（k = 240, d = 16）
        scaleVel += ((-scaleImpulse) * 240.0 - scaleVel * 16.0) * dt
        scaleImpulse += scaleVel * dt
        capillaryAmp = max(0, capillaryAmp - dt * 1.45)
        vortexBlend = max(0, vortexBlend - dt * 1.8)

        // 4. 风格 2 表冠棘轮追向光标最短弧插值
        if hasPointer && mouseDist < 260.0 {
            let targetCrown = atan2(mdy - offsetY, mdx - offsetX)
            var diff = targetCrown - crownAngle
            while diff > .pi { diff -= .pi * 2.0 }
            while diff < -.pi { diff += .pi * 2.0 }
            crownAngle += diff * (1.0 - exp(-12.0 * dt))
        } else {
            crownAngle += sin(time * 0.8) * 0.12 * dt
        }

        // 5. 待触发延迟脉冲（复制吸收撞击 / 拟态心跳二连搏）
        for idx in pendingInflowImpacts.indices.reversed() {
            pendingInflowImpacts[idx].delay -= dt
            if pendingInflowImpacts[idx].delay <= 0 {
                let impact = pendingInflowImpacts[idx]
                pendingInflowImpacts.remove(at: idx)
                if impact.isNudgeBeat {
                    scaleImpulse = 0.20
                    capillaryAmp = 0.65
                } else {
                    scaleImpulse = 0.30
                    capillaryAmp = 0.95
                    vortexBlend = 1.0
                }
                ripples.append(
                    SpriteRippleWave(
                        offsetX: offsetX,
                        offsetY: offsetY,
                        radius: 22.0,
                        maxRadius: impact.isNudgeBeat ? 44.0 : 46.0,
                        alpha: impact.isNudgeBeat ? 0.72 : 0.92,
                        accent: impact.accent
                    )
                )
            }
        }

        // 6. 二阶贝塞尔吸收粒子更新
        for idx in inflowParticles.indices.reversed() {
            inflowParticles[idx].progress += dt * 3.1
            if inflowParticles[idx].progress >= 1.0 {
                inflowParticles.remove(at: idx)
            }
        }

        // 7. 重力火花更新
        for idx in sparks.indices.reversed() {
            sparks[idx].offsetX += sparks[idx].vx * dt
            sparks[idx].offsetY += sparks[idx].vy * dt
            sparks[idx].vy += 36.0 * dt
            sparks[idx].life -= dt * 1.65
            if sparks[idx].life <= 0 {
                sparks.remove(at: idx)
            }
        }

        // 8. 扩散波纹更新
        for idx in ripples.indices.reversed() {
            let targetR = ripples[idx].maxRadius
            ripples[idx].radius += (targetR - ripples[idx].radius) * (1.0 - exp(-5.8 * dt))
            ripples[idx].alpha -= dt * 1.45
            if ripples[idx].alpha <= 0.02 || (targetR - ripples[idx].radius) < 0.35 && ripples[idx].alpha < 0.08 {
                ripples.remove(at: idx)
            }
        }
    }

    // MARK: - 交互脉冲触发入口

    mutating func triggerClick(panelOpening: Bool, accent: SpriteOrbMoodAccent = .cobalt) {
        scaleImpulse = panelOpening ? 0.28 : -0.14
        capillaryAmp = 0.72
        ripples.append(
            SpriteRippleWave(
                offsetX: offsetX,
                offsetY: offsetY,
                radius: 22.0,
                maxRadius: 42.0,
                alpha: 0.68,
                accent: accent
            )
        )
    }

    mutating func triggerStyleSwitch() {
        scaleImpulse = 0.22
        capillaryAmp = 0.70
    }

    mutating func triggerDockBounce() {
        scaleImpulse = 0.22
        capillaryAmp = 0.85
    }

    mutating func triggerDismissShrink() {
        scaleImpulse = -0.14
    }

    mutating func triggerVoiceWakePulse() {
        scaleImpulse = 0.24
        capillaryAmp = 0.80
        captureAccent = .emerald
        captureMoodRemaining = 1.5
        ripples.append(
            SpriteRippleWave(
                offsetX: offsetX,
                offsetY: offsetY,
                radius: 23.0,
                maxRadius: 44.0,
                alpha: 0.78,
                accent: .emerald
            )
        )
    }

    /// 触发拟态待办推进提醒的“心脏二连轻搏（lub-dub）”
    mutating func triggerProactiveNudgePeek(accent: SpriteOrbMoodAccent = .amber) {
        scaleImpulse = 0.24
        capillaryAmp = 0.60
        captureAccent = accent
        captureMoodRemaining = 4.5
        ripples.append(
            SpriteRippleWave(
                offsetX: offsetX,
                offsetY: offsetY,
                radius: 22.0,
                maxRadius: 40.0,
                alpha: 0.70,
                accent: accent
            )
        )
        pendingInflowImpacts.append(SpritePendingInflowImpact(delay: 0.19, accent: accent, isNudgeBeat: true))
    }

    mutating func triggerCopyInflow(incomingAngle: Double, accent: SpriteOrbMoodAccent) {
        captureAccent = accent
        captureMoodRemaining = 3.8
        for i in 0..<12 {
            let spread = (Double(i) / 11.0 - 0.5) * 0.95
            let ang = incomingAngle + spread
            let dist = 36.0 + Double((i * 7) % 10)
            let sx = offsetX + cos(ang) * dist
            let sy = offsetY + sin(ang) * dist
            let arcSide = (i % 2 == 0 ? 1.0 : -1.0)
            let cx = offsetX + cos(ang + arcSide * 0.46) * (dist * 0.54)
            let cy = offsetY + sin(ang + arcSide * 0.46) * (dist * 0.54)
            inflowParticles.append(
                SpriteInflowParticle(
                    startOffsetX: sx,
                    startOffsetY: sy,
                    ctrlOffsetX: cx,
                    ctrlOffsetY: cy,
                    progress: -Double(i) * 0.032,
                    size: 1.7 + Double(i % 3) * 0.7,
                    accent: accent,
                    isWhite: (i % 3 == 0)
                )
            )
        }
        pendingInflowImpacts.append(SpritePendingInflowImpact(delay: 0.22, accent: accent, isNudgeBeat: false))
    }

    mutating func triggerAcceptedCelebration() {
        scaleImpulse = 0.28
        capillaryAmp = 0.85
        captureAccent = .emerald
        captureMoodRemaining = 1.6
        ripples.append(
            SpriteRippleWave(
                offsetX: offsetX,
                offsetY: offsetY,
                radius: 22.0,
                maxRadius: 48.0,
                alpha: 0.85,
                accent: .emerald
            )
        )
        for i in 0..<12 {
            let ang = (Double(i) / 12.0) * .pi * 2.0 + Double((i % 3)) * 0.14
            let spd = 16.0 + Double((i * 9) % 20)
            sparks.append(
                SpriteSparkParticle(
                    offsetX: offsetX + cos(ang) * 14.0,
                    offsetY: offsetY + sin(ang) * 14.0,
                    vx: cos(ang) * spd,
                    vy: sin(ang) * spd - 10.0,
                    life: 1.0,
                    isWhite: (i % 2 != 0)
                )
            )
        }
    }
}

// MARK: - 对齐的 Metal 着色器 Uniform 结构体

private struct SpriteOrbMetalUniforms {
    var dims: SIMD4<Float> = .zero
    var motion: SIMD4<Float> = .zero
    var states: SIMD4<Float> = .zero
    var stretch: SIMD4<Float> = .zero
    var accentRGB: SIMD4<Float> = .zero
    var voiceAndNudge: SIMD4<Float> = .zero
    var flags: SIMD4<UInt32> = .zero
    var extra: SIMD4<Float> = .zero
    var ripple0: SIMD4<Float> = .zero
    var ripple1: SIMD4<Float> = .zero
    var ripple2: SIMD4<Float> = .zero
}

// MARK: - 全 GPU Metal 视图 + 交互宿主（NSView.displayLink 120Hz 原生 VSync）

@MainActor
private final class SpriteOrbMetalView: NSView {
    var liveOrbCenterProvider: (() -> CGPoint)?
    var onDisplayLinkTick: ((_ deltaSeconds: Double, _ displayLink: CADisplayLink) -> Void)?
    var onPointerDown: ((NSPoint) -> Void)?
    var onPointerMovedOrDragged: ((NSPoint, CGVector) -> Void)?
    var onPointerUp: ((NSPoint) -> Void)?
    var onCoreHoverChanged: ((Bool) -> Void)?
    var onDragTargetedChanged: ((Bool) -> Void)?
    var onPerformExternalDrop: ((NSPasteboard) -> Bool)?
    var onBuildContextMenu: (() -> NSMenu)?

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var displayLink: CADisplayLink?
    private var lastTickUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var particleStaging = [SIMD4<Float>](repeating: .zero, count: SpriteOrbMetalShader.particleCapacity)

    private var trackingAreaRef: NSTrackingArea?
    private var lastDragScreenPoint: NSPoint = .zero
    private var lastDragTime: TimeInterval = 0
    private var isCoreHoveredLocal: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(ClipboardStore.supportedDragTypes)
        configureMetalPipeline()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let center = liveOrbCenterProvider?() ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let dist = hypot(point.x - center.x, point.y - center.y)
        guard dist <= SpriteOrbPhysicsGeometry.hitTestRadius else {
            return nil
        }
        return self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableGeometry()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func startDisplayLink() {
        if displayLink == nil {
            let dl = displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
            dl.add(to: .main, forMode: .common)
            displayLink = dl
        }
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        displayLink?.isPaused = false
    }

    func pauseDisplayLink() {
        displayLink?.isPaused = true
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func setProMotionHighRate(_ highRate: Bool) {
        guard let dl = displayLink else { return }
        if highRate {
            dl.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        } else {
            dl.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 45)
        }
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTickUptime
        lastTickUptime = now
        onDisplayLinkTick?(dt, link)
    }

    func renderFrame(uniforms: SpriteOrbMetalUniforms, particles: [SIMD4<Float>]) {
        guard let metalLayer = layer as? CAMetalLayer,
              let pipelineState,
              let commandQueue else { return }

        if metalLayer.drawableSize.width < 1 || metalLayer.drawableSize.height < 1 {
            updateDrawableGeometry()
        }
        guard let drawable = metalLayer.nextDrawable() else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(pipelineState)

        var u = uniforms
        encoder.setFragmentBytes(&u, length: MemoryLayout<SpriteOrbMetalUniforms>.stride, index: 0)

        let count = min(particles.count, SpriteOrbMetalShader.particleCapacity)
        for i in 0..<SpriteOrbMetalShader.particleCapacity {
            particleStaging[i] = (i < count) ? particles[i] : .zero
        }
        particleStaging.withUnsafeBytes { rawBuf in
            if let base = rawBuf.baseAddress {
                encoder.setFragmentBytes(base, length: SpriteOrbMetalShader.particleCapacity * MemoryLayout<SIMD4<Float>>.stride, index: 1)
            }
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    private func configureMetalPipeline() {
        guard let metalLayer = layer as? CAMetalLayer,
              let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            return
        }
        device = dev
        commandQueue = queue

        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = false
        metalLayer.displaySyncEnabled = true

        do {
            let lib = try dev.makeLibrary(source: SpriteOrbMetalShader.source, options: nil)
            guard let vFunc = lib.makeFunction(name: "spriteOrbVertex"),
                  let fFunc = lib.makeFunction(name: "spriteOrbFragment") else {
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vFunc
            desc.fragmentFunction = fFunc
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = false
            pipelineState = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            pipelineState = nil
        }

        updateDrawableGeometry()
    }

    private func updateDrawableGeometry() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        let side = max(1, bounds.width)
        metalLayer.drawableSize = CGSize(width: side * scale, height: max(1, bounds.height) * scale)
    }

    // MARK: - 指针、拖拽、右键与外部拖放

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if isCoreHoveredLocal {
            isCoreHoveredLocal = false
            onCoreHoverChanged?(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = NSEvent.mouseLocation
        lastDragScreenPoint = pt
        lastDragTime = ProcessInfo.processInfo.systemUptime
        onPointerDown?(pt)
    }

    override func mouseDragged(with event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let pt = NSEvent.mouseLocation
        let stepDt = max(0.008, now - lastDragTime)
        let stepDx = pt.x - lastDragScreenPoint.x
        let stepDy = pt.y - lastDragScreenPoint.y
        lastDragScreenPoint = pt
        lastDragTime = now

        let vx = min(max(stepDx / stepDt, -900), 900)
        let vy = min(max(stepDy / stepDt, -900), 900)
        onPointerMovedOrDragged?(pt, CGVector(dx: vx, dy: vy))
    }

    override func mouseUp(with event: NSEvent) {
        onPointerUp?(NSEvent.mouseLocation)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = onBuildContextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else {
            return []
        }
        onDragTargetedChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else {
            return []
        }
        onDragTargetedChanged?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargetedChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource == nil && ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerformExternalDrop?(sender.draggingPasteboard) ?? false
    }

    private func updateHover(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let center = liveOrbCenterProvider?() ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let inside = hypot(pt.x - center.x, pt.y - center.y) <= SpriteOrbPhysicsGeometry.hitTestRadius
        if inside != isCoreHoveredLocal {
            isCoreHoveredLocal = inside
            onCoreHoverChanged?(inside)
        }
    }
}

// MARK: - 悬浮精灵总控制器（Metal 120Hz DisplayLink + 语音待办 + 主动拟态推进）

@MainActor
final class FloatingSpriteOrbController {
    static let shared = FloatingSpriteOrbController()

    private static let posXDefaultsKey = "spriteOrbPosXRatio"
    private static let posYDefaultsKey = "spriteOrbPosYRatio"

    var onToggleClipboardPanel: ((NSRect) -> Void)?
    var onOpenTodoList: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private var panel: UnifiedActiveFloatingPanel?
    private var metalView: SpriteOrbMetalView?
    private weak var boundStore: ClipboardStore?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var isStarted: Bool = false

    // 实时状态（全部驻留纯内存，DisplayLink 直读零 SwiftUI Diff）
    private var currentStyle: SpriteOrbStyle = .prismDew
    private var currentDockMode: SpriteOrbDockMode = .edgeSnap
    private var dockedSide: SpriteOrbEdgeSide? = .right
    private var physicsState = SpriteOrbPhysicsState()
    private var physicsInput = SpriteOrbPhysicsInput()
    private var arbiter = SpriteOrbGestureArbiter()

    private var dragPanelStartOrigin: NSPoint = .zero
    private var dragPointerStartScreen: NSPoint = .zero
    private var dragTotalDx: CGFloat = 0
    private var dragTotalDy: CGFloat = 0
    private var lastDragMoveUptime: TimeInterval = 0

    // 可打断的 120Hz 窗口临界阻尼吸边弹簧
    private var windowSnapTarget: NSPoint?
    private var windowSnapPos: NSPoint = .zero
    private var windowSnapVel: CGVector = .zero

    // 状态与表情控制
    private var activeGlyph: SpriteOrbMatrixGlyph = .none
    private var glyphResetWorkItem: DispatchWorkItem?
    private var isIdleResting: Bool = false
    private var lastActivityUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    // 主动智能拟态推进调度
    private var nudgeCheckTimer: Timer?
    private var lastGlobalNudgeAt: Date?
    private var snoozedTodosUntil: [UUID: Date] = [:]
    private var activeProactiveNudge: ProactiveTodoNudgeCandidate?

    // 语音监听控制
    private var voiceSessionID: UUID = UUID()
    private var latestPartialTranscript: String = ""
    private var particleStagingBuffer: [SIMD4<Float>] = Array(repeating: .zero, count: SpriteOrbMetalShader.particleCapacity)
    private var visibilityEpoch: UInt64 = 0

    private init() {}

    /// 返回当前真实物理球体屏幕坐标（供主面板与伴生卡片贴旁）
    var visibleOrbCoreScreenFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        let base = SpriteOrbPhysicsGeometry.orbCoreFrame(fromPanelFrame: panel.frame, dockedSide: dockedSide)
        return NSRect(
            x: base.minX + physicsState.offsetX,
            y: base.minY - physicsState.offsetY,
            width: base.width,
            height: base.height
        )
    }

    var visibleHitScreenFrame: NSRect? {
        guard let core = visibleOrbCoreScreenFrame else { return nil }
        return core.insetBy(dx: -6, dy: -6)
    }

    func start(store: ClipboardStore) {
        boundStore = store
        guard !isStarted else {
            syncPreferences(from: store)
            updatePanelVisibility()
            return
        }
        isStarted = true
        syncPreferences(from: store)

        store.$spriteOrbEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePanelVisibility()
            }
            .store(in: &cancellables)

        store.$spriteOrbStyle
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] style in
                guard let self else { return }
                self.currentStyle = style
                self.physicsState.triggerStyleSwitch()
                self.physicsState.triggerClick(panelOpening: true)
                self.markInteractionActive()
            }
            .store(in: &cancellables)

        store.$spriteOrbDockMode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                guard let self else { return }
                self.currentDockMode = mode
                self.physicsState.triggerDockBounce()
                self.reanchorCurrentPosition(animated: true)
                TactileFeedbackEngine.shared.performNavigationStepHaptic()
            }
            .store(in: &cancellables)

        store.$spriteOrbProactiveNudgeEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    if let panel = self.panel, panel.isVisible {
                        self.physicsState.triggerProactiveNudgePeek(accent: .amber)
                        self.scheduleTemporaryGlyph(.biomimeticBlink, duration: 1.6)
                        self.markInteractionActive()
                        TactileFeedbackEngine.shared.performNavigationStepHaptic()
                    }
                } else {
                    if self.activeProactiveNudge != nil {
                        self.clearActiveProactiveNudge(shrink: true)
                        ActionSparkController.shared.dismiss()
                    }
                }
            }
            .store(in: &cancellables)

        store.$screenSharePrivacyEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.panel?.sharingType = enabled ? .none : .readOnly
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reanchorCurrentPosition(animated: false)
            }
        }

        // 绑定语音服务实时回调与伴生卡片动作回调
        bindVoiceAndSparkCallbacks(store: store)
        startProactiveNudgeTimer()
        updatePanelVisibility()
    }

    func stop() {
        nudgeCheckTimer?.invalidate()
        nudgeCheckTimer = nil
        glyphResetWorkItem?.cancel()
        glyphResetWorkItem = nil
        cancellables.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        VoiceTodoCaptureService.shared.cancelListening()
        metalView?.stopDisplayLink()
        panel?.orderOut(nil)
        isStarted = false
    }

    func setClipboardPanelVisible(_ visible: Bool) {
        physicsInput.isClipboardPanelOpen = visible
        if visible, activeProactiveNudge != nil {
            activeProactiveNudge = nil
            physicsInput.proactiveNudgeActive = false
        }
        refreshActiveMatrixGlyph()
        if visible {
            markInteractionActive()
        }
    }

    /// 新剪贴板捕获时向球心发射 12 颗贝塞尔流光粒子
    func notifyClipboardCaptured(itemType: ClipContentType, previewText: String?) {
        guard isStarted, boundStore?.spriteOrbEnabled == true else { return }
        let accent: SpriteOrbMoodAccent
        let tempGlyph: SpriteOrbMatrixGlyph
        if let text = previewText, TodoChecklistExtractor.hasActionableSingleTodoIntent(text) {
            accent = .amber
            tempGlyph = .todo
        } else {
            switch itemType {
            case .text:
                accent = .cobalt
                tempGlyph = .clean
            case .link:
                accent = .emerald
                tempGlyph = .link
            case .image, .file:
                accent = .cobalt
                tempGlyph = .image
            }
        }

        let incomingAngle: Double = {
            switch dockedSide {
            case .left: return 0.0
            case .right: return .pi
            case nil: return -.pi * 0.72
            }
        }()
        physicsState.triggerCopyInflow(incomingAngle: incomingAngle, accent: accent)
        if !physicsInput.smartSuggestionActive && !physicsInput.isClipboardPanelOpen && !physicsInput.voiceActive {
            scheduleTemporaryGlyph(tempGlyph, duration: 1.35)
        }
        markInteractionActive()
    }

    /// 同步 ActionSpark 智能提醒卡片状态（传递 categoryKey 与 actionID）
    func setSmartSuggestionState(active: Bool, categoryKey: String?, actionID: String? = nil) {
        guard isStarted else { return }
        if active && categoryKey == "proactive_nudge" {
            physicsInput.proactiveNudgeActive = true
            physicsInput.smartSuggestionActive = false
            activeGlyph = .biomimeticBlink
            markInteractionActive()
            return
        }

        if !active {
            activeProactiveNudge = nil
            physicsInput.proactiveNudgeActive = false
        }
        physicsInput.smartSuggestionActive = active
        if active {
            switch categoryKey {
            case "todo_capture":
                physicsState.smartSuggestionAccent = .amber
                activeGlyph = .todo
            case "frequent_reuse", "security":
                physicsState.smartSuggestionAccent = .emerald
                activeGlyph = .clean
            default:
                physicsState.smartSuggestionAccent = .cobalt
                if actionID?.contains("url") == true || actionID?.contains("link") == true || actionID?.contains("qr") == true {
                    activeGlyph = .link
                } else if categoryKey == "image" {
                    activeGlyph = .image
                } else {
                    activeGlyph = .clean
                }
            }
            markInteractionActive()
        } else {
            refreshActiveMatrixGlyph()
        }
    }

    func triggerSuggestionAcceptedPulse() {
        guard isStarted else { return }
        activeProactiveNudge = nil
        physicsInput.proactiveNudgeActive = false
        physicsInput.smartSuggestionActive = false
        physicsState.triggerAcceptedCelebration()
        scheduleTemporaryGlyph(.done, duration: 1.0)
        markInteractionActive()
    }

    func triggerSuggestionDismissedPulse() {
        guard isStarted else { return }
        activeProactiveNudge = nil
        physicsInput.proactiveNudgeActive = false
        physicsInput.smartSuggestionActive = false
        physicsState.triggerDismissShrink()
        refreshActiveMatrixGlyph()
    }

    /// 支持主动拟态待办推进：自动巡检或右键菜单「测试拟态待办推进提醒」
    func evaluateAndTriggerProactiveNudgeIfNeeded(forceImmediate: Bool) {
        guard isStarted,
              let store = boundStore,
              store.spriteOrbEnabled,
              !store.minimalModeEnabled,
              !ProcessInfo.processInfo.arguments.contains("--demo"),
              let panel, panel.isVisible else {
            return
        }
        if !forceImmediate {
            guard store.spriteOrbProactiveNudgeEnabled else { return }
            guard !physicsInput.isClipboardPanelOpen,
                  !physicsInput.smartSuggestionActive,
                  !physicsInput.voiceActive,
                  activeProactiveNudge == nil,
                  !ActionSparkController.shared.isOfferingInteractiveCard else {
                return
            }
        }

        let now = Date()
        let oneMind = OneMindKernel.shared
        let mergedSnoozes = oneMind.activeSnoozedTodosMap(now: now).merging(snoozedTodosUntil) { persisted, local in
            max(persisted, local)
        }
        guard let candidate = ProactiveTodoNudgePlanner.selectNudgeCandidate(
            from: store.items,
            now: now,
            lastGlobalNudgeAt: lastGlobalNudgeAt,
            snoozedUntil: mergedSnoozes,
            minimumGlobalInterval: oneMind.recommendedProactiveNudgeInterval(),
            preferredHours: oneMind.preferredNudgeHourSet(),
            forceImmediate: forceImmediate
        ) else {
            if forceImmediate {
                ActionSparkController.shared.presentTransientNotice(
                    symbolName: "mic.fill",
                    message: "暂无待推进待办 · 长按精灵说话记一条",
                    duration: 2.2,
                    in: store
                )
            }
            return
        }

        presentProactiveNudge(candidate, now: now, in: store)
    }

    // MARK: - 绑定与调度

    private func bindVoiceAndSparkCallbacks(store: ClipboardStore) {
        let voice = VoiceTodoCaptureService.shared
        voice.onAudioLevelChanged = { [weak self] level in
            guard let self, self.physicsInput.voiceActive else { return }
            self.physicsInput.audioLevel = level
            let transcript = self.latestPartialTranscript.isEmpty ? "正在聆听，请说待办事项…" : self.latestPartialTranscript
            ActionSparkController.shared.updateVoiceListeningState(
                transcript: transcript,
                isCancelling: self.physicsInput.voiceCancelSlide,
                audioLevel: level
            )
        }
        voice.onPartialTranscriptChanged = { [weak self] text in
            guard let self, self.physicsInput.voiceActive else { return }
            self.latestPartialTranscript = text
            ActionSparkController.shared.updateVoiceListeningState(
                transcript: text,
                isCancelling: self.physicsInput.voiceCancelSlide,
                audioLevel: self.physicsInput.audioLevel
            )
        }
        voice.onPermissionDenied = { [weak self] message in
            guard let self else { return }
            self.arbiter.reset()
            self.physicsInput.voiceActive = false
            self.physicsInput.voiceCancelSlide = false
            self.physicsInput.audioLevel = 0
            self.physicsInput.chargeProgress = 0
            self.refreshActiveMatrixGlyph()
            ActionSparkController.shared.presentVoicePermissionNeeded(message: message, in: store)
        }

        ActionSparkController.shared.onOpenTodoListRequested = { [weak self] in
            self?.onOpenTodoList?()
        }
        ActionSparkController.shared.onProactiveTodoCompleted = { [weak self, weak store] itemID in
            guard let self, let store else { return }
            if let item = store.items.first(where: { $0.id == itemID && $0.isPendingTodo }) {
                store.toggleTodoCompletion(item)
            }
            OneMindKernel.shared.recordTodoNudgeCompleted(itemID: itemID)
            self.snoozedTodosUntil.removeValue(forKey: itemID)
            self.activeProactiveNudge = nil
            self.physicsInput.proactiveNudgeActive = false
            self.physicsState.triggerAcceptedCelebration()
            self.scheduleTemporaryGlyph(.done, duration: 1.0)
            self.markInteractionActive()
        }
        ActionSparkController.shared.onProactiveTodoSnoozed = { [weak self] itemID in
            guard let self else { return }
            let until = Date().addingTimeInterval(30 * 60)
            self.snoozedTodosUntil[itemID] = until
            OneMindKernel.shared.recordTodoNudgeSnoozed(itemID: itemID, until: until)
            self.clearActiveProactiveNudge(shrink: true)
        }
        ActionSparkController.shared.onProactiveTodoDismissed = { [weak self] _ in
            guard let self else { return }
            OneMindKernel.shared.recordTodoNudgeDismissed()
            self.clearActiveProactiveNudge(shrink: false)
        }
    }

    private func startProactiveNudgeTimer() {
        nudgeCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 90.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateAndTriggerProactiveNudgeIfNeeded(forceImmediate: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        nudgeCheckTimer = timer
    }

    private func presentProactiveNudge(_ candidate: ProactiveTodoNudgeCandidate, now: Date, in store: ClipboardStore) {
        lastGlobalNudgeAt = now
        activeProactiveNudge = candidate
        physicsInput.proactiveNudgeActive = true
        physicsInput.nudgePeekOffsetX = {
            switch dockedSide {
            case .left: return 9.0
            case .right: return -9.0
            case nil: return 0.0
            }
        }()
        activeGlyph = .biomimeticBlink
        physicsState.triggerProactiveNudgePeek(accent: candidate.isUrgent ? .amber : .emerald)
        markInteractionActive()
        ActionSparkController.shared.presentProactiveTodoNudge(candidate: candidate, in: store)
    }

    private func clearActiveProactiveNudge(shrink: Bool) {
        activeProactiveNudge = nil
        physicsInput.proactiveNudgeActive = false
        if shrink {
            physicsState.triggerDismissShrink()
        }
        refreshActiveMatrixGlyph()
    }

    // MARK: - VSync 120Hz DisplayLink 主循环

    private func stepAndRenderFrame(dt: Double) {
        guard let panel, panel.isVisible, let metalView else { return }
        let nowUptime = ProcessInfo.processInfo.systemUptime

        // 1. 轮询检查长按蓄力与 0.36s 语音激活门槛（无需单独定时器，VSync 帧级精确唤醒）
        if case .pressing = arbiter.phase {
            let (activated, charge) = arbiter.checkLongPressActivation(atUptime: nowUptime)
            physicsInput.chargeProgress = charge
            if activated {
                physicsInput.chargeProgress = 0
                beginLongPressVoiceCapture()
            }
        } else {
            physicsInput.chargeProgress = 0
        }

        // 2. 推进可打断的 120Hz 临界阻尼窗口吸边弹簧（k = 320, d = 32）
        if let snapTarget = windowSnapTarget {
            let safeDt = min(max(dt, 0.0005), 0.03)
            let k = 320.0
            let d = 32.0
            let dx = Double(snapTarget.x - windowSnapPos.x)
            let dy = Double(snapTarget.y - windowSnapPos.y)
            let ax = dx * k - Double(windowSnapVel.dx) * d
            let ay = dy * k - Double(windowSnapVel.dy) * d
            windowSnapVel.dx += CGFloat(ax * safeDt)
            windowSnapVel.dy += CGFloat(ay * safeDt)
            windowSnapPos.x += windowSnapVel.dx * CGFloat(safeDt)
            windowSnapPos.y += windowSnapVel.dy * CGFloat(safeDt)
            panel.setFrameOrigin(windowSnapPos)

            if hypot(dx, dy) < 0.3 && hypot(Double(windowSnapVel.dx), Double(windowSnapVel.dy)) < 5.0 {
                panel.setFrameOrigin(snapTarget)
                windowSnapPos = snapTarget
                windowSnapVel = .zero
                windowSnapTarget = nil
            }
        }

        // 3. 在 VSync 回调中直接 O(1) 读取鼠标坐标计算近场偏移，零全局监听器与 Task 分配
        let panelFrame = panel.frame
        let baseAnchor = SpriteOrbPhysicsGeometry.anchorInPanel(for: dockedSide)
        let mouseScreen = NSEvent.mouseLocation
        let canvasX = mouseScreen.x - panelFrame.minX
        let canvasY = panelFrame.height - (mouseScreen.y - panelFrame.minY)
        let pdx = canvasX - baseAnchor.x
        let pdy = canvasY - baseAnchor.y
        let pointerDist = hypot(pdx, pdy)
        let nearField = pointerDist < 170.0
        physicsInput.pointerOffsetFromAnchor = (pointerDist < 260.0) ? CGPoint(x: pdx, y: pdy) : nil

        // 4. 空闲柔隐与自适应 ProMotion 帧率判定
        let busy = arbiter.isPressingOrRecording
            || physicsInput.isDragging
            || physicsInput.isHoveredOnCore
            || physicsInput.isDragTargeted
            || physicsInput.isClipboardPanelOpen
            || physicsInput.smartSuggestionActive
            || physicsInput.proactiveNudgeActive
            || physicsInput.voiceActive
            || pointerDist < 110.0
            || windowSnapTarget != nil

        if busy {
            lastActivityUptime = nowUptime
            isIdleResting = false
        } else if currentDockMode == .edgeSnap && (nowUptime - lastActivityUptime) > 2.8 {
            isIdleResting = true
        } else {
            isIdleResting = false
        }

        let highFreq = nearField
            || busy
            || physicsState.hasActiveEffects
            || physicsInput.chargeProgress > 0.001
        metalView.setProMotionHighRate(highFreq)

        // 5. 推进物理弹簧与粒子状态
        physicsState.step(dt: dt, input: physicsInput, idleRestingTarget: isIdleResting)

        // 拖拽松手后瞬时速度仅采样一帧防残留
        if !physicsInput.isDragging {
            physicsInput.dragStepVelocity = .zero
        }

        // 6. 组装 16 字节对齐 GPU Uniform 并单 Pass 绘制
        let idleShiftX: CGFloat = {
            guard currentDockMode == .edgeSnap, let side = dockedSide else { return 0 }
            return (side == .right ? 2.5 : -2.5) * CGFloat(physicsState.idleRestBlend)
        }()
        let anchorX = Float(baseAnchor.x + idleShiftX)
        let anchorY = Float(baseAnchor.y)
        let orbCenterX = anchorX + Float(physicsState.offsetX)
        let orbCenterY = anchorY + Float(physicsState.offsetY)

        let speed = hypot(physicsState.vx, physicsState.vy)
        let stretchAmt = Float(min(0.22, speed / 1500.0))
        let velAngle = Float(atan2(physicsState.vy, physicsState.vx))
        let overallOpacity = Float(1.0 - physicsState.idleRestBlend * 0.14)

        let activeAccent = physicsState.activeAccent(
            smartSuggestionActive: physicsInput.smartSuggestionActive,
            proactiveNudgeActive: physicsInput.proactiveNudgeActive
        )
        let rgb = activeAccent.rgbTuple

        let styleIdx: UInt32 = {
            switch currentStyle {
            case .prismDew: return 0
            case .matrixCrown: return 1
            case .organicJade: return 2
            case .auroraRibbon: return 3
            }
        }()
        let isDark: UInt32 = (metalView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) ? 1 : 0

        var stateBits: UInt32 = 0
        if physicsInput.isClipboardPanelOpen { stateBits |= 1 << 0 }
        if physicsInput.isDragTargeted { stateBits |= 1 << 1 }
        if physicsInput.smartSuggestionActive { stateBits |= 1 << 2 }
        if physicsInput.proactiveNudgeActive { stateBits |= 1 << 3 }

        // 填充最多 3 条波纹 + 24 颗粒子（0..<12 inflow, 12..<24 sparks）
        var r0 = SIMD4<Float>.zero
        var r1 = SIMD4<Float>.zero
        var r2 = SIMD4<Float>.zero
        for (i, rp) in physicsState.ripples.prefix(3).enumerated() {
            let packedA = (rp.accent == .emerald) ? -Float(rp.alpha) : Float(rp.alpha)
            let v = SIMD4<Float>(anchorX + Float(rp.offsetX), anchorY + Float(rp.offsetY), Float(rp.radius), packedA)
            if i == 0 { r0 = v }
            else if i == 1 { r1 = v }
            else { r2 = v }
        }

        for i in 0..<SpriteOrbMetalShader.particleCapacity {
            particleStagingBuffer[i] = .zero
        }
        for (idx, p) in physicsState.inflowParticles.prefix(12).enumerated() {
            if p.progress >= 0 && p.progress < 1 {
                let t = p.progress
                let u = 1.0 - t
                let sx = Double(anchorX) + p.startOffsetX
                let sy = Double(anchorY) + p.startOffsetY
                let cx = Double(anchorX) + p.ctrlOffsetX
                let cy = Double(anchorY) + p.ctrlOffsetY
                let px = u * u * sx + 2.0 * u * t * cx + t * t * Double(orbCenterX)
                let py = u * u * sy + 2.0 * u * t * cy + t * t * Double(orbCenterY)
                let r = p.size * (0.6 + 0.5 * u)
                let a = min(1.0, t * 4.0) * (0.35 + 0.65 * u)
                let wVal = p.isWhite ? -Float(a) : Float(a)
                particleStagingBuffer[idx] = SIMD4<Float>(Float(px), Float(py), Float(r), wVal)
            }
        }
        for (idx, sp) in physicsState.sparks.prefix(12).enumerated() {
            let px = anchorX + Float(sp.offsetX)
            let py = anchorY + Float(sp.offsetY)
            let r = Float(2.2 * sp.life)
            let wVal = sp.isWhite ? -Float(sp.life) : Float(sp.life)
            particleStagingBuffer[12 + idx] = SIMD4<Float>(px, py, r, wVal)
        }

        let uniforms = SpriteOrbMetalUniforms(
            dims: SIMD4<Float>(Float(SpriteOrbPhysicsGeometry.panelDimension), orbCenterX, orbCenterY, Float(physicsState.breathScale)),
            motion: SIMD4<Float>(Float(physicsState.time), Float(physicsState.tensionPull), Float(physicsState.tensionAngle), Float(physicsState.capillaryAmp)),
            states: SIMD4<Float>(Float(physicsState.hoverBlend), Float(physicsState.pressBlend), Float(physicsState.vortexBlend), Float(physicsState.crownAngle)),
            stretch: SIMD4<Float>(velAngle, stretchAmt, overallOpacity, 0),
            accentRGB: SIMD4<Float>(rgb.0, rgb.1, rgb.2, 1.0),
            voiceAndNudge: SIMD4<Float>(Float(physicsState.smoothedAudioLevel), Float(physicsState.voiceActiveBlend), Float(physicsState.cancelSlideBlend), Float(physicsInput.chargeProgress)),
            flags: SIMD4<UInt32>(styleIdx, isDark, activeGlyph.packedShaderMask, stateBits),
            extra: SIMD4<Float>(Float(physicsState.breathWave), physicsInput.proactiveNudgeActive ? 1.0 : 0.0, 0, 0),
            ripple0: r0,
            ripple1: r1,
            ripple2: r2
        )

        metalView.renderFrame(uniforms: uniforms, particles: particleStagingBuffer)
    }

    // MARK: - 长按语音键入待办闭环

    private func beginLongPressVoiceCapture() {
        guard let store = boundStore else { return }
        if physicsInput.isClipboardPanelOpen {
            // 如果主面板正开着，先触发收起防止遮挡语音卡片
            if let orbCore = visibleOrbCoreScreenFrame {
                onToggleClipboardPanel?(orbCore)
            }
        }
        activeProactiveNudge = nil
        physicsInput.proactiveNudgeActive = false
        physicsInput.smartSuggestionActive = false
        physicsInput.voiceActive = true
        physicsInput.voiceCancelSlide = false
        physicsInput.audioLevel = 0.05
        latestPartialTranscript = ""
        activeGlyph = .voiceEqualizer
        physicsState.triggerVoiceWakePulse()
        TactileFeedbackEngine.shared.perform(.forceTouchPop)
        markInteractionActive()

        ActionSparkController.shared.presentVoiceListening(
            transcript: "正在准备麦克风…",
            isCancelling: false,
            audioLevel: 0.05,
            in: store
        )

        let session = UUID()
        voiceSessionID = session
        Task { @MainActor [weak self] in
            let ok = await VoiceTodoCaptureService.shared.beginListening()
            guard let self, self.voiceSessionID == session else {
                if ok {
                    VoiceTodoCaptureService.shared.cancelListening()
                }
                return
            }
            if ok {
                let text = self.latestPartialTranscript.isEmpty ? "请说出待办事项（松手保存）" : self.latestPartialTranscript
                ActionSparkController.shared.updateVoiceListeningState(
                    transcript: text,
                    isCancelling: self.physicsInput.voiceCancelSlide,
                    audioLevel: self.physicsInput.audioLevel
                )
            }
        }
    }

    private func finishAndCommitVoiceCapture() {
        guard let store = boundStore else { return }
        voiceSessionID = UUID()
        physicsInput.voiceActive = false
        physicsInput.voiceCancelSlide = false
        physicsInput.audioLevel = 0
        refreshActiveMatrixGlyph()
        markInteractionActive()

        Task { @MainActor [weak self] in
            let result = await VoiceTodoCaptureService.shared.finishListeningAndCommit()
            guard let self else { return }
            switch result {
            case .committed(let todoItems, _):
                var insertedCount = 0
                for body in todoItems {
                    if store.captureQuickTodo(body: body, alias: nil, copyToClipboard: false) {
                        insertedCount += 1
                    }
                }
                if insertedCount > 0 {
                    OneMindKernel.shared.recordVoiceTodoCaptured(count: insertedCount)
                    TactileFeedbackEngine.shared.perform(.magicTransform)
                    self.physicsState.triggerAcceptedCelebration()
                    self.scheduleTemporaryGlyph(.done, duration: 1.2)
                    ActionSparkController.shared.presentVoiceCommitted(
                        count: insertedCount,
                        summary: todoItems[0],
                        in: store
                    )
                } else {
                    ActionSparkController.shared.dismiss()
                }

            case .empty:
                self.physicsState.triggerDismissShrink()
                ActionSparkController.shared.presentTransientNotice(
                    symbolName: "waveform",
                    message: "未识别到清晰语音待办",
                    duration: 1.4,
                    in: store
                )

            case .failed(let msg):
                self.physicsState.triggerDismissShrink()
                ActionSparkController.shared.presentTransientNotice(
                    symbolName: "exclamationmark.triangle",
                    message: msg,
                    duration: 1.8,
                    in: store
                )
            }
        }
    }

    private func cancelVoiceCapture() {
        voiceSessionID = UUID()
        VoiceTodoCaptureService.shared.cancelListening()
        physicsInput.voiceActive = false
        physicsInput.voiceCancelSlide = false
        physicsInput.audioLevel = 0
        physicsState.triggerDismissShrink()
        refreshActiveMatrixGlyph()
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
        ActionSparkController.shared.dismiss()
    }

    // MARK: - 指针手势交互响应

    private func handlePointerDown(at screenPt: NSPoint) {
        guard let panel else { return }
        windowSnapTarget = nil
        windowSnapVel = .zero
        dragPanelStartOrigin = panel.frame.origin
        dragPointerStartScreen = screenPt
        dragTotalDx = 0
        dragTotalDy = 0

        physicsInput.isPressed = true
        arbiter.pointerDown(atScreenPoint: screenPt, uptime: ProcessInfo.processInfo.systemUptime)
        markInteractionActive()
    }

    private func handlePointerMovedOrDragged(at screenPt: NSPoint, stepVelocity: CGVector) {
        guard let panel else { return }
        let action = arbiter.pointerMoved(toScreenPoint: screenPt)

        switch action {
        case .enteredDragging:
            physicsInput.chargeProgress = 0
            physicsInput.isDragging = true
            dragTotalDx = screenPt.x - dragPointerStartScreen.x
            dragTotalDy = screenPt.y - dragPointerStartScreen.y
            let nextOrigin = NSPoint(x: dragPanelStartOrigin.x + dragTotalDx, y: dragPanelStartOrigin.y + dragTotalDy)
            panel.setFrameOrigin(nextOrigin)
            windowSnapPos = nextOrigin
            physicsInput.dragStepVelocity = CGVector(dx: stepVelocity.dx, dy: -stepVelocity.dy)

        case .voiceCancelStateChanged(let cancelling):
            physicsInput.voiceCancelSlide = cancelling
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
            let text = latestPartialTranscript.isEmpty ? "正在聆听，请说待办事项…" : latestPartialTranscript
            ActionSparkController.shared.updateVoiceListeningState(
                transcript: text,
                isCancelling: cancelling,
                audioLevel: physicsInput.audioLevel
            )

        case .none, .triggerClick, .endDragging, .startedVoice, .commitVoice, .cancelVoice:
            if case .dragging = arbiter.phase {
                dragTotalDx = screenPt.x - dragPointerStartScreen.x
                dragTotalDy = screenPt.y - dragPointerStartScreen.y
                let nextOrigin = NSPoint(x: dragPanelStartOrigin.x + dragTotalDx, y: dragPanelStartOrigin.y + dragTotalDy)
                panel.setFrameOrigin(nextOrigin)
                windowSnapPos = nextOrigin
                lastDragMoveUptime = ProcessInfo.processInfo.systemUptime
                physicsInput.dragStepVelocity = CGVector(dx: stepVelocity.dx, dy: -stepVelocity.dy)
                windowSnapVel = CGVector(dx: stepVelocity.dx * 0.45, dy: stepVelocity.dy * 0.45)
            }
        }
        markInteractionActive()
    }

    private func handlePointerUp(at screenPt: NSPoint) {
        guard let panel else { return }
        physicsInput.isPressed = false
        physicsInput.chargeProgress = 0
        physicsInput.isDragging = false
        let action = arbiter.pointerUp(atScreenPoint: screenPt, uptime: ProcessInfo.processInfo.systemUptime)

        switch action {
        case .triggerClick:
            TactileFeedbackEngine.shared.perform(.tabSwitch)
            let willOpen = !physicsInput.isClipboardPanelOpen
            physicsState.triggerClick(
                panelOpening: willOpen,
                accent: physicsState.activeAccent(
                    smartSuggestionActive: physicsInput.smartSuggestionActive,
                    proactiveNudgeActive: physicsInput.proactiveNudgeActive
                )
            )
            if let orbCore = visibleOrbCoreScreenFrame {
                onToggleClipboardPanel?(orbCore)
            }
            markInteractionActive()

        case .endDragging:
            let finalOrigin = panel.frame.origin
            let oldSide = dockedSide
            let oldCenter = SpriteOrbPhysicsGeometry.orbCoreFrame(
                fromPanelFrame: NSRect(origin: finalOrigin, size: panel.frame.size),
                dockedSide: oldSide
            )
            let screen = targetScreenForOrigin(finalOrigin)
            let pseudoOrigin = SpriteOrbPhysicsGeometry.panelOrigin(
                forOrbCenter: NSPoint(x: oldCenter.midX, y: oldCenter.midY),
                dockedSide: nil
            )
            let resolved = SpriteOrbPhysicsGeometry.resolvedRestingOrigin(
                currentOrigin: pseudoOrigin,
                panelSize: panel.frame.size,
                visibleFrame: screen.visibleFrame,
                dockMode: currentDockMode
            )

            if oldSide != resolved.dockedSide {
                let compensated = SpriteOrbPhysicsGeometry.panelOrigin(
                    forOrbCenter: NSPoint(x: oldCenter.midX, y: oldCenter.midY),
                    dockedSide: resolved.dockedSide
                )
                dockedSide = resolved.dockedSide
                panel.setFrameOrigin(compensated)
                windowSnapPos = compensated
            } else {
                dockedSide = resolved.dockedSide
                windowSnapPos = finalOrigin
            }

            saveNormalizedOrigin(resolved.origin, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame)
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
            physicsState.triggerDockBounce()
            if ProcessInfo.processInfo.systemUptime - lastDragMoveUptime > 0.08 {
                windowSnapVel = .zero
            }
            windowSnapTarget = resolved.origin
            markInteractionActive()

        case .commitVoice:
            finishAndCommitVoiceCapture()

        case .cancelVoice:
            cancelVoiceCapture()

        case .none, .enteredDragging, .startedVoice, .voiceCancelStateChanged:
            break
        }
        physicsInput.dragStepVelocity = .zero
    }

    // MARK: - 窗口装配与显隐管理

    private func syncPreferences(from store: ClipboardStore) {
        currentStyle = store.spriteOrbStyle
        currentDockMode = store.spriteOrbDockMode
        panel?.sharingType = store.screenSharePrivacyEnabled ? .none : .readOnly
    }

    private func updatePanelVisibility() {
        guard let store = boundStore else { return }
        if !store.spriteOrbEnabled || ProcessInfo.processInfo.arguments.contains("--demo") {
            visibilityEpoch &+= 1
            let hideEpoch = visibilityEpoch
            ActionSparkController.shared.dismiss()
            guard let panel, panel.isVisible else {
                metalView?.pauseDisplayLink()
                panel?.orderOut(nil)
                return
            }
            physicsState.scaleImpulse = -0.35
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.visibilityEpoch == hideEpoch else { return }
                    self.metalView?.pauseDisplayLink()
                    self.panel?.orderOut(nil)
                }
            })
            return
        }

        visibilityEpoch &+= 1
        ensurePanel()
        guard let panel else { return }
        let wasVisible = panel.isVisible
        if !wasVisible {
            restoreSavedOriginOnLaunch()
            panel.alphaValue = 0
            physicsState.scaleImpulse = -0.45
            physicsState.triggerClick(panelOpening: true)
            panel.orderFrontRegardless()
            panel.enforceUnifiedActiveAppearance()
            metalView?.startDisplayLink()
            markInteractionActive()
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().alphaValue = 1.0
            }
        } else {
            panel.alphaValue = 1.0
            panel.enforceUnifiedActiveAppearance()
            metalView?.startDisplayLink()
            markInteractionActive()
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let side = SpriteOrbPhysicsGeometry.panelDimension
        let rect = NSRect(origin: .zero, size: NSSize(width: side, height: side))

        let p = UnifiedActiveFloatingPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.sharingType = (boundStore?.screenSharePrivacyEnabled ?? true) ? .none : .readOnly

        let mView = SpriteOrbMetalView(frame: rect)
        mView.autoresizingMask = [.width, .height]

        mView.liveOrbCenterProvider = { [weak self] in
            guard let self else {
                return CGPoint(x: side * 0.5, y: side * 0.5)
            }
            let anchor = SpriteOrbPhysicsGeometry.anchorInPanel(for: self.dockedSide)
            let cx = anchor.x + self.physicsState.offsetX
            let cy = side - (anchor.y + self.physicsState.offsetY)
            return CGPoint(x: cx, y: cy)
        }
        mView.onDisplayLinkTick = { [weak self] dt, _ in
            self?.stepAndRenderFrame(dt: dt)
        }
        mView.onCoreHoverChanged = { [weak self] hovering in
            self?.physicsInput.isHoveredOnCore = hovering
            if hovering {
                self?.markInteractionActive()
            }
        }
        mView.onPointerDown = { [weak self] screenPt in
            self?.handlePointerDown(at: screenPt)
        }
        mView.onPointerMovedOrDragged = { [weak self] screenPt, stepVel in
            self?.handlePointerMovedOrDragged(at: screenPt, stepVelocity: stepVel)
        }
        mView.onPointerUp = { [weak self] screenPt in
            self?.handlePointerUp(at: screenPt)
        }
        mView.onDragTargetedChanged = { [weak self] targeted in
            if targeted && self?.physicsInput.isDragTargeted != true {
                TactileFeedbackEngine.shared.performNavigationStepHaptic()
            }
            self?.physicsInput.isDragTargeted = targeted
            if targeted {
                self?.markInteractionActive()
            }
        }
        mView.onPerformExternalDrop = { [weak self] pb in
            guard let self else { return false }
            self.physicsInput.isDragTargeted = false
            let ok = ClipboardStore.shared.importAndCopy(from: pb, sourceLabel: "悬浮精灵")
            if ok {
                TactileFeedbackEngine.shared.perform(.magicTransform)
                self.physicsState.triggerAcceptedCelebration()
                self.scheduleTemporaryGlyph(.done, duration: 1.0)
                self.markInteractionActive()
            }
            return ok
        }
        mView.onBuildContextMenu = { [weak self] in
            self?.buildContextMenu() ?? NSMenu()
        }

        p.contentView = mView
        self.metalView = mView
        self.panel = p
    }

    private func restoreSavedOriginOnLaunch() {
        guard let panel else { return }
        let size = panel.frame.size
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let defaults = UserDefaults.standard
        if let ratioX = defaults.object(forKey: Self.posXDefaultsKey) as? Double,
           let ratioY = defaults.object(forKey: Self.posYDefaultsKey) as? Double {
            let screen = targetScreenForOrigin(panel.frame.origin)
            let resolved = SpriteOrbPhysicsGeometry.origin(
                fromRatios: CGFloat(ratioX),
                ratioY: CGFloat(ratioY),
                panelSize: size,
                visibleFrame: screen.visibleFrame,
                dockMode: currentDockMode
            )
            panel.setFrameOrigin(resolved.origin)
            windowSnapPos = resolved.origin
            dockedSide = resolved.dockedSide
        } else {
            let screen = NSScreen.main ?? screens[0]
            let initial = SpriteOrbPhysicsGeometry.defaultInitialOrigin(
                panelSize: size,
                visibleFrame: screen.visibleFrame
            )
            panel.setFrameOrigin(initial)
            windowSnapPos = initial
            dockedSide = (currentDockMode == .edgeSnap) ? .right : nil
        }
    }

    private func reanchorCurrentPosition(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        let oldSide = dockedSide
        let oldCenter = SpriteOrbPhysicsGeometry.orbCoreFrame(fromPanelFrame: panel.frame, dockedSide: oldSide)
        let screen = targetScreenForOrigin(panel.frame.origin)

        let candidateOrigin = SpriteOrbPhysicsGeometry.panelOrigin(
            forOrbCenter: NSPoint(x: oldCenter.midX, y: oldCenter.midY),
            dockedSide: nil
        )
        let resolved = SpriteOrbPhysicsGeometry.resolvedRestingOrigin(
            currentOrigin: candidateOrigin,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame,
            dockMode: currentDockMode
        )

        if oldSide != resolved.dockedSide {
            let compensated = SpriteOrbPhysicsGeometry.panelOrigin(
                forOrbCenter: NSPoint(x: oldCenter.midX, y: oldCenter.midY),
                dockedSide: resolved.dockedSide
            )
            dockedSide = resolved.dockedSide
            panel.setFrameOrigin(compensated)
            windowSnapPos = compensated
        } else {
            dockedSide = resolved.dockedSide
            windowSnapPos = panel.frame.origin
        }

        saveNormalizedOrigin(resolved.origin, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame)
        if animated {
            windowSnapTarget = resolved.origin
        } else {
            windowSnapTarget = nil
            panel.setFrameOrigin(resolved.origin)
            windowSnapPos = resolved.origin
        }
        markInteractionActive()
    }

    private func targetScreenForOrigin(_ origin: NSPoint) -> NSScreen {
        let screens = NSScreen.screens
        let side = SpriteOrbPhysicsGeometry.panelDimension
        let center = NSPoint(x: origin.x + side * 0.5, y: origin.y + side * 0.5)
        if let matched = screens.first(where: { $0.frame.contains(center) }) {
            return matched
        }
        let mouse = NSEvent.mouseLocation
        if let mouseScreen = screens.first(where: { $0.frame.contains(mouse) }) {
            return mouseScreen
        }
        return NSScreen.main ?? screens[0]
    }

    private func saveNormalizedOrigin(_ origin: NSPoint, panelSize: NSSize, visibleFrame: NSRect) {
        let ratios = SpriteOrbPhysicsGeometry.normalizedRatios(
            forOrigin: origin,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        UserDefaults.standard.set(Double(ratios.x), forKey: Self.posXDefaultsKey)
        UserDefaults.standard.set(Double(ratios.y), forKey: Self.posYDefaultsKey)
    }

    // MARK: - 右键快捷菜单与体验动作

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "iClip 悬浮精灵 · 长按语音记待办", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let oneMind = OneMindKernel.shared.oneMindMemorySummary
        let oneMindTitle = oneMind.totalInteractions > 0
            ? "OneMind 记忆 · 已留存 \(oneMind.totalInteractions) 次习惯"
            : "OneMind 记忆 · 自动学习中"
        let oneMindItem = NSMenuItem(title: oneMindTitle, action: nil, keyEquivalent: "")
        oneMindItem.isEnabled = false
        menu.addItem(oneMindItem)

        let toggleTitle = physicsInput.isClipboardPanelOpen ? "收起剪贴板面板" : "打开 iClip 剪贴板"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(contextTogglePanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let todoItem = NSMenuItem(title: "打开待办清单", action: #selector(contextOpenTodos), keyEquivalent: "")
        todoItem.target = self
        menu.addItem(todoItem)

        let testNudgeItem = NSMenuItem(title: "测试拟态待办推进提醒", action: #selector(contextTestProactiveNudge), keyEquivalent: "")
        testNudgeItem.target = self
        menu.addItem(testNudgeItem)

        menu.addItem(.separator())

        let currentStyle = boundStore?.spriteOrbStyle ?? self.currentStyle
        for (idx, style) in SpriteOrbStyle.allCases.enumerated() {
            let item = NSMenuItem(
                title: "\(idx + 1) · \(style.title)",
                action: #selector(contextSelectStyle(_:)),
                keyEquivalent: ""
            )
            item.representedObject = style.rawValue
            item.state = (style == currentStyle) ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let currentDock = boundStore?.spriteOrbDockMode ?? self.currentDockMode
        for mode in SpriteOrbDockMode.allCases {
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(contextSelectDockMode(_:)),
                keyEquivalent: ""
            )
            item.representedObject = mode.rawValue
            item.state = (mode == currentDock) ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "偏好设置...", action: #selector(contextOpenSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let hideItem = NSMenuItem(title: "隐藏悬浮精灵", action: #selector(contextHideOrb), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        return menu
    }

    @objc private func contextTogglePanel() {
        if let orbCore = visibleOrbCoreScreenFrame {
            onToggleClipboardPanel?(orbCore)
        }
    }

    @objc private func contextOpenTodos() {
        onOpenTodoList?()
    }

    @objc private func contextTestProactiveNudge() {
        evaluateAndTriggerProactiveNudgeIfNeeded(forceImmediate: true)
    }

    @objc private func contextSelectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = SpriteOrbStyle(rawValue: raw),
              let store = boundStore else { return }
        store.spriteOrbStyle = style
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    @objc private func contextSelectDockMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = SpriteOrbDockMode(rawValue: raw),
              let store = boundStore else { return }
        store.spriteOrbDockMode = mode
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
    }

    @objc private func contextOpenSettings() {
        onOpenSettings?()
    }

    @objc private func contextHideOrb() {
        boundStore?.spriteOrbEnabled = false
    }

    // MARK: - 活跃标记与矩阵表情复位

    private func markInteractionActive() {
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        isIdleResting = false
    }

    private func scheduleTemporaryGlyph(_ glyph: SpriteOrbMatrixGlyph, duration: TimeInterval) {
        glyphResetWorkItem?.cancel()
        activeGlyph = glyph
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshActiveMatrixGlyph()
            }
        }
        glyphResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func refreshActiveMatrixGlyph() {
        if physicsInput.voiceActive {
            activeGlyph = .voiceEqualizer
        } else if physicsInput.proactiveNudgeActive {
            activeGlyph = .biomimeticBlink
        } else if physicsInput.isClipboardPanelOpen {
            activeGlyph = .panelOpen
        } else if !physicsInput.smartSuggestionActive {
            activeGlyph = .none
        }
    }
}
