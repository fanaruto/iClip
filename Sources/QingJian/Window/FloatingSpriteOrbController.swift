import AppKit
import Combine
import SwiftUI

/// 悬浮精灵吸附的屏幕边缘方向
enum SpriteOrbEdgeSide: String, Equatable {
    case left
    case right
}

/// 悬浮精灵根据复制内容或智能建议实时映射的心情光色
enum SpriteOrbMoodAccent: Equatable {
    case cobalt
    case emerald
    case amber

    var swiftUIColor: Color {
        switch self {
        case .cobalt:
            return Color(red: 0.118, green: 0.369, blue: 1.0) // #1E5EFF 电光蓝
        case .emerald:
            return Color(red: 0.063, green: 0.725, blue: 0.506) // #10B981 翡翠绿
        case .amber:
            return Color(red: 0.961, green: 0.620, blue: 0.043) // #F59E0B 琥珀金
        }
    }

    var secondaryColor: Color {
        switch self {
        case .cobalt:
            return Color(red: 0.22, green: 0.74, blue: 0.97)
        case .emerald:
            return Color(red: 0.20, green: 0.86, blue: 0.70)
        case .amber:
            return Color(red: 0.99, green: 0.78, blue: 0.28)
        }
    }
}

/// 风格 2「精密点阵表冠」中心 5×5 LED 语义点阵字模
enum SpriteOrbMatrixGlyph: Equatable {
    case none
    case todo
    case link
    case clean
    case image
    case panelOpen
    case done

    var bitmask25: [Int]? {
        switch self {
        case .none:
            return nil
        case .todo:
            return [
                0, 1, 1, 1, 0,
                1, 0, 0, 0, 1,
                1, 0, 1, 0, 1,
                1, 0, 0, 0, 1,
                0, 1, 1, 1, 0
            ]
        case .link:
            return [
                0, 0, 1, 1, 1,
                0, 1, 0, 0, 1,
                0, 0, 1, 0, 0,
                1, 0, 0, 1, 0,
                1, 1, 1, 0, 0
            ]
        case .clean:
            return [
                0, 0, 1, 0, 0,
                0, 1, 1, 1, 0,
                1, 1, 1, 1, 1,
                0, 1, 1, 1, 0,
                0, 0, 1, 0, 0
            ]
        case .image:
            return [
                1, 1, 1, 1, 1,
                1, 1, 0, 0, 1,
                1, 0, 1, 0, 1,
                1, 0, 0, 1, 1,
                1, 1, 1, 1, 1
            ]
        case .panelOpen:
            return [
                1, 1, 1, 1, 1,
                0, 0, 0, 0, 0,
                1, 1, 1, 1, 1,
                0, 0, 0, 0, 0,
                1, 1, 1, 0, 0
            ]
        case .done:
            return [
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 1,
                1, 0, 0, 1, 0,
                0, 1, 1, 0, 0,
                0, 0, 0, 0, 0
            ]
        }
    }
}

/// 悬浮精灵纯几何定位、手势阈值与多窗非对称零溢出停靠算法
enum SpriteOrbPhysicsGeometry {
    static let panelDimension: CGFloat = 140
    static let orbVisualRadius: CGFloat = 25
    static let hitTestRadius: CGFloat = 31
    static let dragThreshold: CGFloat = 5.0
    static let edgeVisualMargin: CGFloat = 13.0

    /// 判定指针移动距离是否属于「单击启动剪贴板」而非「拖拽换位」
    static func isClickGesture(dragDistance: CGFloat) -> Bool {
        dragDistance <= dragThreshold
    }

    /// 根据当前停靠模式计算球体静息中心在 140×140 SwiftUI 舞台（左上原点，Y 向下）内的锚点
    /// - 靠屏边时向屏幕内侧留足 102pt 舞台，既让实球距屏边保持 13pt，又容纳磁吸、波纹与流光粒子且绝不溢出屏幕
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

    /// 由 140×140 含动态粒子舞台的面板外框推导出核心 50×50 实球体的屏幕坐标
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

    /// 反推使球心精确位于目标屏幕点时，140×140 面板对应的窗口原点
    static func panelOrigin(forOrbCenter orbCenter: NSPoint, dockedSide: SpriteOrbEdgeSide?) -> NSPoint {
        let anchor = anchorInPanel(for: dockedSide)
        return NSPoint(
            x: orbCenter.x - anchor.x,
            y: orbCenter.y - (panelDimension - anchor.y)
        )
    }

    /// 首次启动时的默认初始位置：贴靠主屏右侧中下区（视觉不遮挡工作区正文）
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

    /// 计算单击精灵时主剪贴板面板的就近绽放坐标（避让精灵本体的同时完整收敛在可用屏幕内）
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

    /// 计算智能提醒卡片（Action Spark）紧贴精灵旁侧的安全坐标
    static func sparkAnchorOrigin(
        forOrbCoreFrame orbRect: NSRect,
        sparkSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let placeOnLeft = orbRect.midX >= visibleFrame.midX
        let rawX = placeOnLeft
            ? (orbRect.minX - sparkSize.width - 12)
            : (orbRect.maxX + 12)
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

// MARK: - 120Hz 连续二阶弹簧与粒子物理引擎（纯值类型可测试核心）

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
}

struct SpriteOrbPhysicsInput: Equatable {
    var isHoveredOnCore: Bool = false
    var isPressed: Bool = false
    var isDragging: Bool = false
    var isDragTargeted: Bool = false
    var isClipboardPanelOpen: Bool = false
    var smartSuggestionActive: Bool = false
    /// 指针相对于精灵静态锚点的坐标偏移（Y 向下，Canvas 坐标系）；超出视距外时可传 nil
    var pointerOffsetFromAnchor: CGPoint? = nil
    /// 拖拽过程瞬时速度（pt/s，Y 向下）
    var dragStepVelocity: CGVector = .zero
}

struct SpriteOrbPhysicsState: Equatable {
    var time: Double = 0

    // 二阶位置弹簧与速度（相对静态 anchor 的偏移，Y 向下）
    var offsetX: Double = 0
    var offsetY: Double = 0
    var vx: Double = 0
    var vy: Double = 0

    // 光标磁吸与表面张力平滑通道
    var hoverBlend: Double = 0
    var pressBlend: Double = 0
    var tensionPull: Double = 0
    var tensionAngle: Double = 0

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

    var hasActiveEffects: Bool {
        !inflowParticles.isEmpty
            || !pendingInflowImpacts.isEmpty
            || !sparks.isEmpty
            || !ripples.isEmpty
            || abs(scaleImpulse) > 0.003
            || abs(scaleVel) > 0.015
            || capillaryAmp > 0.01
            || vortexBlend > 0.01
            || abs(vx) > 2.0
            || abs(vy) > 2.0
    }

    func activeAccent(smartSuggestionActive: Bool) -> SpriteOrbMoodAccent {
        if smartSuggestionActive {
            return smartSuggestionAccent
        }
        if captureMoodRemaining > 0 {
            return captureAccent
        }
        return .cobalt
    }

    mutating func step(dt rawDt: Double, input: SpriteOrbPhysicsInput) {
        let dt = min(max(rawDt, 0.0005), 0.04)
        time += dt

        if captureMoodRemaining > 0 {
            captureMoodRemaining = max(0, captureMoodRemaining - dt)
        }

        // 1. 远场光标磁吸（< 142pt 轻盈探身）与表面张力形变（< 130pt）
        var targetX = 0.0
        var targetY = sin(time * 1.95) * 3.2

        var mouseDist = 999.0
        var hasPointer = false
        var mdx = 0.0
        var mdy = 0.0
        if let ptr = input.pointerOffsetFromAnchor, !input.isDragging {
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

        let pressTarget: Double = input.isPressed ? 1.0 : 0.0
        pressBlend += (pressTarget - pressBlend) * (1.0 - exp(-22.0 * dt))

        let tensionTarget: Double = (!input.isDragging && hasPointer && mouseDist < 130.0)
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

        // 5. 待触发的粒子撞击回弹计时
        for idx in pendingInflowImpacts.indices.reversed() {
            pendingInflowImpacts[idx].delay -= dt
            if pendingInflowImpacts[idx].delay <= 0 {
                let impactAccent = pendingInflowImpacts[idx].accent
                pendingInflowImpacts.remove(at: idx)
                scaleImpulse = 0.30
                capillaryAmp = 0.95
                vortexBlend = 1.0
                ripples.append(
                    SpriteRippleWave(
                        offsetX: offsetX,
                        offsetY: offsetY,
                        radius: 22.0,
                        maxRadius: 84.0,
                        alpha: 0.92,
                        accent: impactAccent
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
            ripples[idx].radius += (targetR - ripples[idx].radius) * (1.0 - exp(-5.5 * dt))
            ripples[idx].alpha -= dt * 1.15
            if ripples[idx].alpha <= 0.02 {
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
                maxRadius: 72.0,
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

    /// 触发复制内容弧线粒子流入：12 颗微粒分波沿二阶贝塞尔弧吸入球心，0.22s 后触发弹性回弹与波纹
    mutating func triggerCopyInflow(incomingAngle: Double, accent: SpriteOrbMoodAccent) {
        captureAccent = accent
        captureMoodRemaining = 3.8
        for i in 0..<12 {
            let spread = (Double(i) / 11.0 - 0.5) * 0.95
            let ang = incomingAngle + spread
            let dist = 54.0 + Double((i * 7) % 13)
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
        pendingInflowImpacts.append(SpritePendingInflowImpact(delay: 0.22, accent: accent))
    }

    /// 触发采纳智能建议庆贺：翡翠绿扩纹 + 12 颗受重力落体火花 + Q 弹回响
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
                maxRadius: 88.0,
                alpha: 0.85,
                accent: .emerald
            )
        )
        for i in 0..<12 {
            let ang = (Double(i) / 12.0) * .pi * 2.0 + Double((i % 3)) * 0.14
            let spd = 24.0 + Double((i * 11) % 34)
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

/// 非 `@Published` 实时仿真引擎：由 `TimelineView` 独占步进并在 `Canvas` 直接读取，零视图树 diff
@MainActor
final class SpriteOrbSimulationEngine {
    var state = SpriteOrbPhysicsState()
    var input = SpriteOrbPhysicsInput()
    var lastFrameUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    func advance(to now: TimeInterval) {
        let dt = now - lastFrameUptime
        lastFrameUptime = now
        if dt > 0 {
            state.step(dt: dt, input: input)
        }
    }
}

/// 驱动低频切换信号与偏好样式的轻量状态模型（绝不承载每帧 120Hz 坐标！）
@MainActor
final class SpriteOrbViewModel: ObservableObject {
    @Published var style: SpriteOrbStyle = .prismDew
    @Published var dockMode: SpriteOrbDockMode = .edgeSnap
    @Published var dockedSide: SpriteOrbEdgeSide? = .right

    @Published var isIdleResting: Bool = false
    @Published var isDragTargeted: Bool = false
    @Published var isClipboardPanelOpen: Bool = false
    @Published var smartSuggestionActive: Bool = false
    @Published var isHighFrequencyActive: Bool = false
    @Published var activeMatrixGlyph: SpriteOrbMatrixGlyph = .none
}

/// 原生 120Hz 悬浮精灵控制器：全天候非抢焦常驻，串联点击呼出、近场磁吸、拖拽吸边与智能提醒联动
@MainActor
final class FloatingSpriteOrbController {
    static let shared = FloatingSpriteOrbController()

    private static let posXDefaultsKey = "spriteOrbPosXRatio"
    private static let posYDefaultsKey = "spriteOrbPosYRatio"

    var onToggleClipboardPanel: ((NSRect) -> Void)?
    var onOpenTodoList: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let viewModel = SpriteOrbViewModel()
    private let simulation = SpriteOrbSimulationEngine()

    private var panel: UnifiedActiveFloatingPanel?
    private var hostingView: NSHostingView<SpriteOrbRootView>?
    private var interactiveView: SpriteOrbInteractiveView?
    private weak var boundStore: ClipboardStore?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var isStarted: Bool = false

    private var idleRestWorkItem: DispatchWorkItem?
    private var highFreqCooldownWorkItem: DispatchWorkItem?
    private var smartMatrixResetWorkItem: DispatchWorkItem?

    private init() {}

    /// 若精灵可见，返回当前真实核心球体（含弹簧漂移后位置）的屏幕坐标，供主面板与提醒卡精准贴旁
    var visibleOrbCoreScreenFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        let base = SpriteOrbPhysicsGeometry.orbCoreFrame(
            fromPanelFrame: panel.frame,
            dockedSide: viewModel.dockedSide
        )
        return NSRect(
            x: base.minX + simulation.state.offsetX,
            y: base.minY - simulation.state.offsetY,
            width: base.width,
            height: base.height
        )
    }

    /// 供主面板外部点击豁免判断（包含微光晕扩边），避免收起面板同时误触发二次呼出
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
                self.viewModel.style = style
                self.simulation.state.triggerStyleSwitch()
                self.activateHighFrequencyWindow(duration: 0.9)
                self.bumpInteractionWakefulness()
            }
            .store(in: &cancellables)

        store.$spriteOrbDockMode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                guard let self else { return }
                self.viewModel.dockMode = mode
                self.reanchorCurrentPosition(animated: true)
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

        installCursorNearFieldMonitors()
        updatePanelVisibility()
    }

    func stop() {
        idleRestWorkItem?.cancel()
        idleRestWorkItem = nil
        highFreqCooldownWorkItem?.cancel()
        highFreqCooldownWorkItem = nil
        smartMatrixResetWorkItem?.cancel()
        smartMatrixResetWorkItem = nil
        cancellables.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        panel?.orderOut(nil)
        isStarted = false
    }

    func setClipboardPanelVisible(_ visible: Bool) {
        viewModel.isClipboardPanelOpen = visible
        simulation.input.isClipboardPanelOpen = visible
        refreshActiveMatrixGlyph()
        if visible {
            wakeFromIdle()
        } else {
            scheduleIdleRestIfEligible()
        }
    }

    /// 监听新剪贴板内容流入：从屏内方向喷射 12 颗二阶贝塞尔流光粒子吸入球心，并按内容点亮语义色
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

        // 流光颗粒默认从屏内方向朝停靠球体优雅飞入（左停靠从右侧 0 rad 飞入；右停靠从左侧 π rad 飞入）
        let incomingAngle: Double = {
            switch viewModel.dockedSide {
            case .left:
                return 0.0
            case .right:
                return .pi
            case nil:
                return -.pi * 0.72
            }
        }()
        simulation.state.triggerCopyInflow(incomingAngle: incomingAngle, accent: accent)
        if !viewModel.smartSuggestionActive && !viewModel.isClipboardPanelOpen {
            viewModel.activeMatrixGlyph = tempGlyph
            smartMatrixResetWorkItem?.cancel()
            let reset = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refreshActiveMatrixGlyph()
                }
            }
            smartMatrixResetWorkItem = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.35, execute: reset)
        }
        activateHighFrequencyWindow(duration: 1.4)
        bumpInteractionWakefulness()
    }

    /// 由 ActionSparkController 同步当前智能提醒卡片显隐，点亮精灵呼应光环与 5×5 点阵图标
    func setSmartSuggestionState(active: Bool, categoryKey: String?, actionID: String? = nil) {
        guard isStarted else { return }
        smartMatrixResetWorkItem?.cancel()
        smartMatrixResetWorkItem = nil
        viewModel.smartSuggestionActive = active
        simulation.input.smartSuggestionActive = active

        if active {
            switch categoryKey {
            case "todo_capture":
                simulation.state.smartSuggestionAccent = .amber
            case "frequent_reuse", "security":
                simulation.state.smartSuggestionAccent = .emerald
            default:
                simulation.state.smartSuggestionAccent = .cobalt
            }
            if categoryKey == "todo_capture" {
                viewModel.activeMatrixGlyph = .todo
            } else if actionID?.contains("url") == true || actionID?.contains("link") == true || actionID?.contains("qr") == true {
                viewModel.activeMatrixGlyph = .link
            } else if categoryKey == "image" {
                viewModel.activeMatrixGlyph = .image
            } else {
                viewModel.activeMatrixGlyph = .clean
            }
            wakeFromIdle()
        } else {
            refreshActiveMatrixGlyph()
            scheduleIdleRestIfEligible()
        }
    }

    /// 当用户采纳提醒动作后触发 12 颗翡翠火花 + 扩纹 + 5×5 对勾
    func triggerSuggestionAcceptedPulse() {
        guard isStarted else { return }
        smartMatrixResetWorkItem?.cancel()
        viewModel.smartSuggestionActive = false
        simulation.input.smartSuggestionActive = false
        simulation.state.triggerAcceptedCelebration()
        viewModel.activeMatrixGlyph = .done

        let reset = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshActiveMatrixGlyph()
            }
        }
        smartMatrixResetWorkItem = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: reset)

        activateHighFrequencyWindow(duration: 1.25)
        bumpInteractionWakefulness()
    }

    /// 当用户主动关闭智能提醒卡片时给予轻柔收拢反馈
    func triggerSuggestionDismissedPulse() {
        guard isStarted else { return }
        viewModel.smartSuggestionActive = false
        simulation.input.smartSuggestionActive = false
        simulation.state.triggerDismissShrink()
        refreshActiveMatrixGlyph()
        activateHighFrequencyWindow(duration: 0.65)
        scheduleIdleRestIfEligible()
    }

    // MARK: - 全局近场光标零轮询监听

    private func installCursorNearFieldMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNearFieldCursorPosition()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateNearFieldCursorPosition()
            return event
        }
    }

    private func updateNearFieldCursorPosition() {
        guard let panel, panel.isVisible, boundStore?.spriteOrbEnabled == true else { return }
        let mouseScreen = NSEvent.mouseLocation
        let panelFrame = panel.frame
        let anchor = SpriteOrbPhysicsGeometry.anchorInPanel(for: viewModel.dockedSide)

        // 转入 SwiftUI Canvas 局部坐标（Y 向下）并求与静态锚点相对位移
        let canvasX = mouseScreen.x - panelFrame.minX
        let canvasY = panelFrame.height - (mouseScreen.y - panelFrame.minY)
        let dx = canvasX - anchor.x
        let dy = canvasY - anchor.y
        let dist = hypot(dx, dy)

        if dist < 260.0 {
            simulation.input.pointerOffsetFromAnchor = CGPoint(x: dx, y: dy)
        } else {
            simulation.input.pointerOffsetFromAnchor = nil
        }

        let inHighFreqZone = dist < 165.0
        if inHighFreqZone != viewModel.isHighFrequencyActive {
            if inHighFreqZone {
                highFreqCooldownWorkItem?.cancel()
                viewModel.isHighFrequencyActive = true
            } else if !simulation.state.hasActiveEffects {
                viewModel.isHighFrequencyActive = false
            }
        }
        if dist < 110.0 {
            wakeFromIdle()
        } else if !simulation.input.isDragging && !simulation.input.isHoveredOnCore {
            scheduleIdleRestIfEligible()
        }
    }

    private func refreshActiveMatrixGlyph() {
        if viewModel.isClipboardPanelOpen {
            viewModel.activeMatrixGlyph = .panelOpen
        } else if !viewModel.smartSuggestionActive {
            viewModel.activeMatrixGlyph = .none
        }
    }

    // MARK: - 窗口装配与显隐调度

    private func syncPreferences(from store: ClipboardStore) {
        viewModel.style = store.spriteOrbStyle
        viewModel.dockMode = store.spriteOrbDockMode
        panel?.sharingType = store.screenSharePrivacyEnabled ? .none : .readOnly
    }

    private func updatePanelVisibility() {
        guard let store = boundStore else { return }
        if !store.spriteOrbEnabled || ProcessInfo.processInfo.arguments.contains("--demo") {
            idleRestWorkItem?.cancel()
            panel?.orderOut(nil)
            return
        }
        ensurePanel()
        guard let panel else { return }
        if !panel.isVisible {
            restoreSavedOriginOnLaunch()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.enforceUnifiedActiveAppearance()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.enforceUnifiedActiveAppearance()
        }
        scheduleIdleRestIfEligible()
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

        let interactive = SpriteOrbInteractiveView(frame: rect)
        interactive.autoresizingMask = [.width, .height]

        let rootView = SpriteOrbRootView(model: viewModel, simulation: simulation)
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        hosting.frame = rect
        hosting.autoresizingMask = [.width, .height]
        interactive.addSubview(hosting)

        // 提供动态渲染圆心给 hitTest，保证外周光晕完全穿透不误拦底层窗口事件
        interactive.liveOrbCenterProvider = { [weak self] in
            guard let self else {
                return CGPoint(x: side * 0.5, y: side * 0.5)
            }
            let anchor = SpriteOrbPhysicsGeometry.anchorInPanel(for: self.viewModel.dockedSide)
            let cx = anchor.x + self.simulation.state.offsetX
            // AppKit Y 向上
            let cy = side - (anchor.y + self.simulation.state.offsetY)
            return CGPoint(x: cx, y: cy)
        }
        interactive.onHoverStateChanged = { [weak self] hovering in
            self?.handleCoreHoverChanged(hovering)
        }
        interactive.onPressChanged = { [weak self] pressed in
            self?.handlePressChanged(pressed)
        }
        interactive.onDragMoved = { [weak self] newOrigin, velocity in
            self?.handleDragMoved(to: newOrigin, velocity: velocity)
        }
        interactive.onPointerReleased = { [weak self] didDrag, finalOrigin in
            self?.handlePointerReleased(didDrag: didDrag, finalOrigin: finalOrigin)
        }
        interactive.onDragTargetedChanged = { [weak self] targeted in
            self?.handleExternalDragTargeted(targeted)
        }
        interactive.onPerformExternalDrop = { [weak self] pb in
            self?.handleExternalDrop(pasteboard: pb) ?? false
        }
        interactive.onBuildContextMenu = { [weak self] in
            self?.buildContextMenu() ?? NSMenu()
        }

        p.contentView = interactive
        self.interactiveView = interactive
        self.hostingView = hosting
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
                dockMode: viewModel.dockMode
            )
            panel.setFrameOrigin(resolved.origin)
            viewModel.dockedSide = resolved.dockedSide
        } else {
            let screen = NSScreen.main ?? screens[0]
            let initial = SpriteOrbPhysicsGeometry.defaultInitialOrigin(
                panelSize: size,
                visibleFrame: screen.visibleFrame
            )
            panel.setFrameOrigin(initial)
            viewModel.dockedSide = (viewModel.dockMode == .edgeSnap) ? .right : nil
        }
    }

    private func reanchorCurrentPosition(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        let oldSide = viewModel.dockedSide
        let oldCenter = SpriteOrbPhysicsGeometry.orbCoreFrame(fromPanelFrame: panel.frame, dockedSide: oldSide)
        let screen = targetScreenForOrigin(panel.frame.origin)

        // 先根据当前真实球心所在屏幕侧计算新目标停靠位
        let candidateOrigin = SpriteOrbPhysicsGeometry.panelOrigin(
            forOrbCenter: NSPoint(x: oldCenter.midX, y: oldCenter.midY),
            dockedSide: nil
        )
        let resolved = SpriteOrbPhysicsGeometry.resolvedRestingOrigin(
            currentOrigin: candidateOrigin,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame,
            dockMode: viewModel.dockMode
        )

        if oldSide != resolved.dockedSide {
            // 先平移窗口原点使新 dockedSide 锚下的球体画面保持原地零跳变，再执行吸附补间
            let compensated = SpriteOrbPhysicsGeometry.panelOrigin(
                forOrbCenter: NSPoint(x: oldCenter.midX, y: oldCenter.midY),
                dockedSide: resolved.dockedSide
            )
            viewModel.dockedSide = resolved.dockedSide
            panel.setFrameOrigin(compensated)
        } else {
            viewModel.dockedSide = resolved.dockedSide
        }

        saveNormalizedOrigin(resolved.origin, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame)
        movePanel(panel, to: resolved.origin, animated: animated)
        bumpInteractionWakefulness()
    }

    private func movePanel(_ panel: NSPanel, to origin: NSPoint, animated: Bool) {
        guard animated else {
            panel.setFrameOrigin(origin)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().setFrameOrigin(origin)
        }
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

    // MARK: - 交互事件协调

    private func handleCoreHoverChanged(_ hovering: Bool) {
        simulation.input.isHoveredOnCore = hovering
        if hovering {
            viewModel.isHighFrequencyActive = true
            wakeFromIdle()
        } else if !simulation.input.isDragging {
            scheduleIdleRestIfEligible()
        }
    }

    private func handlePressChanged(_ pressed: Bool) {
        simulation.input.isPressed = pressed
        if pressed {
            activateHighFrequencyWindow(duration: 0.5)
            wakeFromIdle()
        }
    }

    private func handleDragMoved(to newOrigin: NSPoint, velocity: CGVector) {
        guard let panel else { return }
        simulation.input.isDragging = true
        // AppKit velocity.dy 向上 -> 转为 Canvas 向下速度
        simulation.input.dragStepVelocity = CGVector(dx: velocity.dx, dy: -velocity.dy)
        panel.setFrameOrigin(newOrigin)
        viewModel.isHighFrequencyActive = true
        wakeFromIdle()
    }

    private func handlePointerReleased(didDrag: Bool, finalOrigin: NSPoint) {
        guard let panel else { return }
        simulation.input.isPressed = false
        simulation.input.isDragging = false
        simulation.input.dragStepVelocity = .zero

        if !didDrag {
            TactileFeedbackEngine.shared.perform(.tabSwitch)
            let willOpen = !viewModel.isClipboardPanelOpen
            simulation.state.triggerClick(
                panelOpening: willOpen,
                accent: simulation.state.activeAccent(smartSuggestionActive: viewModel.smartSuggestionActive)
            )
            if let orbCore = visibleOrbCoreScreenFrame {
                onToggleClipboardPanel?(orbCore)
            }
            activateHighFrequencyWindow(duration: 0.9)
            bumpInteractionWakefulness()
            return
        }

        let oldSide = viewModel.dockedSide
        let oldCenter = SpriteOrbPhysicsGeometry.orbCoreFrame(fromPanelFrame: NSRect(origin: finalOrigin, size: panel.frame.size), dockedSide: oldSide)
        let screen = targetScreenForOrigin(finalOrigin)

        let pseudoCenterOrigin = SpriteOrbPhysicsGeometry.panelOrigin(
            forOrbCenter: NSPoint(x: oldCenter.midX, y: oldCenter.midY),
            dockedSide: nil
        )
        let resolved = SpriteOrbPhysicsGeometry.resolvedRestingOrigin(
            currentOrigin: pseudoCenterOrigin,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame,
            dockMode: viewModel.dockMode
        )

        if oldSide != resolved.dockedSide {
            let compensated = SpriteOrbPhysicsGeometry.panelOrigin(
                forOrbCenter: NSPoint(x: oldCenter.midX, y: oldCenter.midY),
                dockedSide: resolved.dockedSide
            )
            viewModel.dockedSide = resolved.dockedSide
            panel.setFrameOrigin(compensated)
        } else {
            viewModel.dockedSide = resolved.dockedSide
        }

        saveNormalizedOrigin(resolved.origin, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame)
        TactileFeedbackEngine.shared.performNavigationStepHaptic()
        simulation.state.triggerDockBounce()
        movePanel(panel, to: resolved.origin, animated: true)
        activateHighFrequencyWindow(duration: 1.0)
        bumpInteractionWakefulness()
    }

    private func handleExternalDragTargeted(_ targeted: Bool) {
        if targeted && !viewModel.isDragTargeted {
            TactileFeedbackEngine.shared.performNavigationStepHaptic()
        }
        viewModel.isDragTargeted = targeted
        simulation.input.isDragTargeted = targeted
        if targeted {
            viewModel.isHighFrequencyActive = true
            wakeFromIdle()
        } else {
            scheduleIdleRestIfEligible()
        }
    }

    private func handleExternalDrop(pasteboard: NSPasteboard) -> Bool {
        viewModel.isDragTargeted = false
        simulation.input.isDragTargeted = false
        let ok = ClipboardStore.shared.importAndCopy(from: pasteboard, sourceLabel: "悬浮精灵")
        if ok {
            TactileFeedbackEngine.shared.perform(.magicTransform)
            simulation.state.triggerAcceptedCelebration()
            activateHighFrequencyWindow(duration: 1.25)
            bumpInteractionWakefulness()
        }
        return ok
    }

    // MARK: - 右键快捷菜单

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "iClip 悬浮精灵", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let toggleTitle = viewModel.isClipboardPanelOpen ? "收起剪贴板面板" : "打开 iClip 剪贴板"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(contextTogglePanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let todoItem = NSMenuItem(title: "打开待办清单", action: #selector(contextOpenTodos), keyEquivalent: "")
        todoItem.target = self
        menu.addItem(todoItem)

        menu.addItem(.separator())

        let currentStyle = boundStore?.spriteOrbStyle ?? viewModel.style
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

        let currentDock = boundStore?.spriteOrbDockMode ?? viewModel.dockMode
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

    // MARK: - 空闲柔隐与 60Hz/120Hz 窗口控制

    private func wakeFromIdle() {
        idleRestWorkItem?.cancel()
        idleRestWorkItem = nil
        if viewModel.isIdleResting {
            withAnimation(.easeOut(duration: 0.18)) {
                viewModel.isIdleResting = false
            }
        }
    }

    private func bumpInteractionWakefulness() {
        wakeFromIdle()
        scheduleIdleRestIfEligible()
    }

    private func scheduleIdleRestIfEligible() {
        idleRestWorkItem?.cancel()
        idleRestWorkItem = nil
        guard viewModel.dockMode == .edgeSnap,
              !simulation.input.isHoveredOnCore,
              !simulation.input.isPressed,
              !simulation.input.isDragging,
              !viewModel.isDragTargeted,
              !viewModel.isClipboardPanelOpen,
              !viewModel.smartSuggestionActive else {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.viewModel.dockMode == .edgeSnap,
                      !self.simulation.input.isHoveredOnCore,
                      !self.simulation.input.isPressed,
                      !self.simulation.input.isDragging,
                      !self.viewModel.isDragTargeted,
                      !self.viewModel.isClipboardPanelOpen,
                      !self.viewModel.smartSuggestionActive else {
                    return
                }
                withAnimation(.easeInOut(duration: 0.45)) {
                    self.viewModel.isIdleResting = true
                }
            }
        }
        idleRestWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
    }

    private func activateHighFrequencyWindow(duration: TimeInterval) {
        highFreqCooldownWorkItem?.cancel()
        viewModel.isHighFrequencyActive = true
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.simulation.state.hasActiveEffects
                    && self.simulation.input.pointerOffsetFromAnchor == nil
                    && !self.viewModel.smartSuggestionActive {
                    self.viewModel.isHighFrequencyActive = false
                }
            }
        }
        highFreqCooldownWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

// MARK: - 交互层：动态球心命中与透明周边穿透

private final class SpriteOrbInteractiveView: NSView {
    var liveOrbCenterProvider: (() -> CGPoint)?
    var onHoverStateChanged: ((Bool) -> Void)?
    var onPressChanged: ((Bool) -> Void)?
    var onDragMoved: ((NSPoint, CGVector) -> Void)?
    var onPointerReleased: ((Bool, NSPoint) -> Void)?
    var onDragTargetedChanged: ((Bool) -> Void)?
    var onPerformExternalDrop: ((NSPasteboard) -> Bool)?
    var onBuildContextMenu: (() -> NSMenu)?

    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownScreenPoint: NSPoint = .zero
    private var panelOriginOnMouseDown: NSPoint = .zero
    private var lastDragScreenPoint: NSPoint = .zero
    private var lastDragTime: TimeInterval = 0
    private var didExceedDragThreshold: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ClipboardStore.supportedDragTypes)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        // 纯视觉画布子视图无需截获事件，统一由宿主视图处理按压、拖拽、右键与外部拖入
        return self
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

    override func mouseEntered(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let center = liveOrbCenterProvider?() ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let inside = hypot(pt.x - center.x, pt.y - center.y) <= SpriteOrbPhysicsGeometry.hitTestRadius
        onHoverStateChanged?(inside)
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let center = liveOrbCenterProvider?() ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let inside = hypot(pt.x - center.x, pt.y - center.y) <= SpriteOrbPhysicsGeometry.hitTestRadius
        onHoverStateChanged?(inside)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverStateChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        mouseDownScreenPoint = NSEvent.mouseLocation
        lastDragScreenPoint = mouseDownScreenPoint
        lastDragTime = ProcessInfo.processInfo.systemUptime
        panelOriginOnMouseDown = window.frame.origin
        didExceedDragThreshold = false
        onPressChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard window != nil else { return }
        let currentScreen = NSEvent.mouseLocation
        let totalDx = currentScreen.x - mouseDownScreenPoint.x
        let totalDy = currentScreen.y - mouseDownScreenPoint.y
        let totalDist = hypot(totalDx, totalDy)

        if !SpriteOrbPhysicsGeometry.isClickGesture(dragDistance: totalDist) {
            didExceedDragThreshold = true
        }
        guard didExceedDragThreshold else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let stepDt = max(0.008, now - lastDragTime)
        let stepDx = currentScreen.x - lastDragScreenPoint.x
        let stepDy = currentScreen.y - lastDragScreenPoint.y
        lastDragScreenPoint = currentScreen
        lastDragTime = now

        let nextOrigin = NSPoint(
            x: panelOriginOnMouseDown.x + totalDx,
            y: panelOriginOnMouseDown.y + totalDy
        )
        // 计算 pt/s 速度矢量，上限 900pt/s 对应适度的弹性拉长
        let vx = min(max(stepDx / stepDt, -900), 900)
        let vy = min(max(stepDy / stepDt, -900), 900)
        onDragMoved?(nextOrigin, CGVector(dx: vx, dy: vy))
    }

    override func mouseUp(with event: NSEvent) {
        let finalOrigin = window?.frame.origin ?? panelOriginOnMouseDown
        let movedBeyondClick = didExceedDragThreshold
        didExceedDragThreshold = false
        onPointerReleased?(movedBeyondClick, finalOrigin)
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
}

// MARK: - 60Hz / 120Hz 原生矢量画布与 4 套风格像素级复刻

private struct SpriteOrbRootView: View {
    @ObservedObject var model: SpriteOrbViewModel
    let simulation: SpriteOrbSimulationEngine
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let interval = (model.isHighFrequencyActive || model.isDragTargeted || model.smartSuggestionActive)
            ? (1.0 / 120.0)
            : (1.0 / 60.0)
        TimelineView(.animation(minimumInterval: interval)) { _ in
            SpriteOrbCanvasView(model: model, simulation: simulation, colorScheme: colorScheme)
        }
        .frame(
            width: SpriteOrbPhysicsGeometry.panelDimension,
            height: SpriteOrbPhysicsGeometry.panelDimension
        )
        .opacity(model.isIdleResting ? 0.86 : 1.0)
    }
}

private struct SpriteOrbCanvasView: View {
    @ObservedObject var model: SpriteOrbViewModel
    let simulation: SpriteOrbSimulationEngine
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { ctx, _ in
            let now = ProcessInfo.processInfo.systemUptime
            simulation.advance(to: now)
            let state = simulation.state
            let isDark = (colorScheme == .dark)

            let baseAnchor = SpriteOrbPhysicsGeometry.anchorInPanel(for: model.dockedSide)
            let idleShiftX: CGFloat = {
                guard model.isIdleResting, model.dockMode == .edgeSnap, let side = model.dockedSide else {
                    return 0
                }
                return side == .right ? 2.5 : -2.5
            }()
            let anchorX = baseAnchor.x + idleShiftX
            let anchorY = baseAnchor.y
            let orbCenter = CGPoint(x: anchorX + state.offsetX, y: anchorY + state.offsetY)

            let accent = state.activeAccent(smartSuggestionActive: model.smartSuggestionActive)
            let accentColor = accent.swiftUIColor

            // 1. 二阶贝塞尔弧线流光粒子流入（从屏内侧飞向当前动态球心）
            for p in state.inflowParticles where p.progress >= 0 && p.progress < 1 {
                let t = p.progress
                let u = 1.0 - t
                let sx = anchorX + p.startOffsetX
                let sy = anchorY + p.startOffsetY
                let cx = anchorX + p.ctrlOffsetX
                let cy = anchorY + p.ctrlOffsetY
                let px = u * u * sx + 2.0 * u * t * cx + t * t * orbCenter.x
                let py = u * u * sy + 2.0 * u * t * cy + t * t * orbCenter.y
                let r = p.size * (0.6 + 0.5 * u)
                let alpha = min(1.0, t * 4.0) * (0.35 + 0.65 * u)
                let pColor = p.isWhite ? Color.white : p.accent.swiftUIColor
                ctx.fill(
                    Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                    with: .color(pColor.opacity(alpha))
                )
            }

            // 2. 采纳成功火花
            for sp in state.sparks {
                let sx = anchorX + sp.offsetX
                let sy = anchorY + sp.offsetY
                let r = 2.2 * sp.life
                let sColor = sp.isWhite ? Color.white : SpriteOrbMoodAccent.emerald.swiftUIColor
                ctx.fill(
                    Path(ellipseIn: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)),
                    with: .color(sColor.opacity(sp.life))
                )
            }

            // 3. 扩散波纹
            for rp in state.ripples {
                let rx = anchorX + rp.offsetX
                let ry = anchorY + rp.offsetY
                let rect = CGRect(x: rx - rp.radius, y: ry - rp.radius, width: rp.radius * 2, height: rp.radius * 2)
                ctx.stroke(
                    Path(ellipseIn: rect),
                    with: .color(rp.accent.swiftUIColor.opacity(max(0, rp.alpha * 0.55))),
                    lineWidth: 1.5
                )
            }

            // 4. 外部拖入磁吸热点虚线环
            if model.isDragTargeted {
                let hotR: CGFloat = 41
                let hotRect = CGRect(x: orbCenter.x - hotR, y: orbCenter.y - hotR, width: hotR * 2, height: hotR * 2)
                ctx.stroke(
                    Path(ellipseIn: hotRect),
                    with: .color(SpriteOrbMoodAccent.emerald.swiftUIColor.opacity(0.92)),
                    style: StrokeStyle(lineWidth: 1.6, dash: [4, 4], dashPhase: -CGFloat(state.time * 24))
                )
            }

            // 5. 剪贴板展开态 / 智能建议待命呼应弧环
            let breathWave = state.breathWave
            let dragScaleBoost: Double = model.isDragTargeted ? 0.14 : 0.0
            var scaleDouble = 1.0 + breathWave * 0.08 + state.scaleImpulse
            scaleDouble += dragScaleBoost + state.hoverBlend * 0.05 - state.pressBlend * 0.09
            let breathScale = CGFloat(scaleDouble)
            if model.isClipboardPanelOpen {
                let openR = 29.0 * breathScale
                let openRect = CGRect(x: orbCenter.x - openR, y: orbCenter.y - openR, width: openR * 2, height: openR * 2)
                ctx.stroke(
                    Path(ellipseIn: openRect),
                    with: .color(SpriteOrbMoodAccent.cobalt.swiftUIColor.opacity(isDark ? 0.72 : 0.56)),
                    lineWidth: 1.4
                )
            } else if model.smartSuggestionActive {
                let ringPulse = 0.45 + 0.45 * sin(state.time * 4.2)
                let ringR = 28.5 * breathScale + CGFloat(ringPulse) * 2.0
                let ringRect = CGRect(x: orbCenter.x - ringR, y: orbCenter.y - ringR, width: ringR * 2, height: ringR * 2)
                ctx.stroke(
                    Path(ellipseIn: ringRect),
                    with: .color(accentColor.opacity(0.30 + 0.28 * ringPulse)),
                    lineWidth: 1.4
                )
            }

            // 6. 球体主变换：速度矢量果冻拉伸（风格 2 保持工业刚性） + 呼吸缩放
            let speed = hypot(state.vx, state.vy)
            let stretchAmt = CGFloat(min(0.22, speed / 1500.0))
            let velAngle = atan2(state.vy, state.vx)

            ctx.drawLayer { orbCtx in
                orbCtx.translateBy(x: orbCenter.x, y: orbCenter.y)
                if stretchAmt > 0.008 && model.style != .matrixCrown {
                    orbCtx.rotate(by: .radians(velAngle))
                    orbCtx.scaleBy(x: 1.0 + stretchAmt, y: 1.0 - stretchAmt * 0.55)
                    orbCtx.rotate(by: .radians(-velAngle))
                }
                orbCtx.scaleBy(x: breathScale, y: breathScale)

                switch model.style {
                case .prismDew:
                    drawPrismDew(ctx: &orbCtx, state: state, breathWave: breathWave, isDark: isDark, accent: accentColor)
                case .matrixCrown:
                    drawMatrixCrown(ctx: &orbCtx, state: state, breathWave: breathWave, isDark: isDark, accent: accentColor, glyph: model.activeMatrixGlyph)
                case .organicJade:
                    drawOrganicJade(ctx: &orbCtx, state: state, breathWave: breathWave, isDark: isDark, accent: accentColor, panelOrSmart: model.isClipboardPanelOpen || model.smartSuggestionActive)
                case .auroraRibbon:
                    drawAuroraRibbon(ctx: &orbCtx, state: state, breathWave: breathWave, isDark: isDark, accent: accent)
                }
            }
        }
    }

    // MARK: - 闭合二次中点样条（复刻原型 drawClosedSpline）

    private func closedSplinePath(through pts: [CGPoint]) -> Path {
        var path = Path()
        let n = pts.count
        guard n >= 3 else { return path }
        let firstMid = CGPoint(x: (pts[n - 1].x + pts[0].x) * 0.5, y: (pts[n - 1].y + pts[0].y) * 0.5)
        path.move(to: firstMid)
        for i in 0..<n {
            let next = pts[(i + 1) % n]
            let mid = CGPoint(x: (pts[i].x + next.x) * 0.5, y: (pts[i].y + next.y) * 0.5)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.closeSubpath()
        return path
    }

    // MARK: - 风格 1：光学色散露珠 (28 点张力凸起 + 毛细波纹 + Leica 3 层 RGB 色散)

    private func drawPrismDew(
        ctx: inout GraphicsContext,
        state: SpriteOrbPhysicsState,
        breathWave: Double,
        isDark: Bool,
        accent: Color
    ) {
        let baseR = 25.0
        let count = 28
        var pts: [CGPoint] = []
        pts.reserveCapacity(count)

        for i in 0..<count {
            let a = (Double(i) / Double(count)) * .pi * 2.0
            var da = a - state.tensionAngle
            while da > .pi { da -= .pi * 2.0 }
            while da < -.pi { da += .pi * 2.0 }
            let pull = max(0.0, cos(da))
            let bulge = pow(pull, 3.0) * state.tensionPull * 5.2
            let capRipple = sin(a * 5.0 + state.time * 14.0) * state.capillaryAmp * 1.8
            let r = baseR + bulge + capRipple
            pts.append(CGPoint(x: cos(a) * r, y: sin(a) * r))
        }

        let spline = closedSplinePath(through: pts)

        // 透镜聚焦底影
        ctx.drawLayer { shadowCtx in
            shadowCtx.addFilter(
                .shadow(
                    color: isDark ? Color.black.opacity(0.55) : Color(red: 0.059, green: 0.090, blue: 0.165).opacity(0.18),
                    radius: 8 + breathWave * 1.8,
                    x: 0,
                    y: 5 + breathWave * 1.2
                )
            )
            shadowCtx.fill(
                spline,
                with: .color(isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.42))
            )
        }

        // 折射主体、流动焦散水光纹、弯月镜面高光与底部反光弧
        ctx.drawLayer { bodyCtx in
            bodyCtx.clip(to: spline)

            let lensGrad = isDark
                ? Gradient(stops: [
                    .init(color: Color.white.opacity(0.22), location: 0.0),
                    .init(color: Color(red: 0.58, green: 0.77, blue: 1.0).opacity(0.08), location: 0.55),
                    .init(color: Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.35), location: 1.0)
                ])
                : Gradient(stops: [
                    .init(color: Color.white.opacity(0.92), location: 0.0),
                    .init(color: Color(red: 0.88, green: 0.95, blue: 1.0).opacity(0.38), location: 0.65),
                    .init(color: Color(red: 0.73, green: 0.90, blue: 0.99).opacity(0.56), location: 1.0)
                ])
            bodyCtx.fill(
                Path(CGRect(x: -36, y: -36, width: 72, height: 72)),
                with: .radialGradient(lensGrad, center: CGPoint(x: -8, y: -9), startRadius: 2, endRadius: 30)
            )

            // 内部流动双层焦散水光纹
            let c1x = cos(state.time * 1.2) * 8.0
            let c1y = sin(state.time * 1.5) * 6.0
            bodyCtx.fill(
                Path(CGRect(x: -34, y: -34, width: 68, height: 68)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: accent.opacity(0.40), location: 0.0),
                        .init(color: Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.18), location: 0.6),
                        .init(color: Color.white.opacity(0.0), location: 1.0)
                    ]),
                    center: CGPoint(x: c1x, y: c1y),
                    startRadius: 1,
                    endRadius: 17
                )
            )

            // 顶部斜置弯月高光（-0.38 rad）
            let specCenter = CGPoint(x: -6, y: -11)
            let rawSpec = Path(ellipseIn: CGRect(x: -13, y: -5.5, width: 26, height: 11))
            let specTransform = CGAffineTransform(translationX: specCenter.x, y: specCenter.y).rotated(by: -0.38)
            bodyCtx.fill(
                rawSpec.applying(specTransform),
                with: .color(isDark ? Color.white.opacity(0.34) : Color.white.opacity(0.92))
            )

            // 底部柔和反光弧
            var bottomArc = Path()
            bottomArc.addArc(center: .zero, radius: 21, startAngle: .radians(0.45), endAngle: .radians(2.2), clockwise: false)
            bodyCtx.stroke(
                bottomArc,
                with: .color(accent.opacity(0.33)),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
            )
        }

        // Leica 棱镜 RGB 错位极细色散边界
        let rims: [(dx: CGFloat, dy: CGFloat, color: Color)] = [
            (-0.9, -0.6, Color(red: 0.024, green: 0.714, blue: 0.831).opacity(0.52)),
            (0.9, 0.6, Color(red: 0.957, green: 0.247, blue: 0.369).opacity(0.40)),
            (0.0, 0.0, isDark ? Color.white.opacity(0.55) : Color.white.opacity(0.96))
        ]
        for rim in rims {
            ctx.drawLayer { rimCtx in
                rimCtx.translateBy(x: rim.dx, y: rim.dy)
                rimCtx.stroke(spline, with: .color(rim.color), lineWidth: 1.0)
            }
        }
    }

    // MARK: - 风格 2：精密点阵表冠 (24 齿旋转刻度 + 追光信号指标点 + 5×5 OLED 像素窗)

    private func drawMatrixCrown(
        ctx: inout GraphicsContext,
        state: SpriteOrbPhysicsState,
        breathWave: Double,
        isDark: Bool,
        accent: Color,
        glyph: SpriteOrbMatrixGlyph
    ) {
        let rDial: CGFloat = 25.0
        let dialCircle = Path(ellipseIn: CGRect(x: -rDial, y: -rDial, width: rDial * 2, height: rDial * 2))

        // 金属表壳落影
        ctx.drawLayer { shadowCtx in
            shadowCtx.addFilter(
                .shadow(
                    color: isDark ? Color.black.opacity(0.62) : Color(red: 0.059, green: 0.090, blue: 0.165).opacity(0.22),
                    radius: 8 + breathWave * 1.6,
                    x: 0,
                    y: 5 + breathWave * 1.0
                )
            )
            shadowCtx.fill(
                dialCircle,
                with: .color(isDark ? Color(red: 0.090, green: 0.102, blue: 0.129) : Color(red: 0.957, green: 0.965, blue: 0.976))
            )
        }

        // 外盘金属线性渐变与细框
        let metalGrad = isDark
            ? Gradient(colors: [Color(red: 0.165, green: 0.188, blue: 0.235), Color(red: 0.078, green: 0.090, blue: 0.114)])
            : Gradient(colors: [.white, Color(red: 0.863, green: 0.886, blue: 0.925)])
        ctx.fill(
            dialCircle,
            with: .linearGradient(metalGrad, startPoint: CGPoint(x: -rDial, y: -rDial), endPoint: CGPoint(x: rDial, y: rDial))
        )
        ctx.stroke(
            dialCircle,
            with: .color(isDark ? Color.white.opacity(0.16) : Color(red: 0.773, green: 0.808, blue: 0.859)),
            lineWidth: 1.1
        )

        // 旋转 24 齿精密刻度 + 追光指标圆点
        ctx.drawLayer { crownCtx in
            crownCtx.rotate(by: .radians(state.crownAngle))
            for i in 0..<24 {
                let ang = (Double(i) / 24.0) * .pi * 2.0
                let isMajor = (i % 6 == 0)
                let r1 = isMajor ? 20.5 : 21.8
                let r2 = 23.6
                var tick = Path()
                tick.move(to: CGPoint(x: cos(ang) * r1, y: sin(ang) * r1))
                tick.addLine(to: CGPoint(x: cos(ang) * r2, y: sin(ang) * r2))
                crownCtx.stroke(
                    tick,
                    with: .color(isDark ? Color.white.opacity(0.22) : Color(red: 0.059, green: 0.090, blue: 0.165).opacity(0.24)),
                    lineWidth: isMajor ? 1.2 : 0.8
                )
            }
            // 正对 0° 方向追随鼠标的高对比指示圆点
            crownCtx.fill(
                Path(ellipseIn: CGRect(x: 21.2 - 2.3, y: -2.3, width: 4.6, height: 4.6)),
                with: .color(accent)
            )
        }

        // 中心深墨微凹 OLED 视窗
        let oledCircle = Path(ellipseIn: CGRect(x: -15.5, y: -15.5, width: 31, height: 31))
        ctx.fill(oledCircle, with: .color(isDark ? Color(red: 0.039, green: 0.047, blue: 0.063) : Color(red: 0.067, green: 0.094, blue: 0.153)))
        ctx.stroke(
            oledCircle,
            with: .color(isDark ? Color.white.opacity(0.10) : Color(red: 0.059, green: 0.090, blue: 0.165).opacity(0.18)),
            lineWidth: 0.8
        )

        // 5×5 LED 精密像素点阵
        let pat = glyph.bitmask25
        let step = 4.0
        for row in 0..<5 {
            for col in 0..<5 {
                let dx = Double(col - 2) * step
                let dy = Double(row - 2) * step
                let distFromCenter = hypot(Double(col - 2), Double(row - 2))
                let idx = row * 5 + col
                if let pat {
                    let lit = (pat[idx] == 1)
                    let r = lit ? (1.28 + sin(state.time * 4.0 - distFromCenter) * 0.16) : 0.75
                    let dotColor = lit ? accent : Color.white.opacity(0.12)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: dx - r, y: dy - r, width: r * 2, height: r * 2)),
                        with: .color(dotColor)
                    )
                } else {
                    let wave = sin(state.time * 2.5 - distFromCenter * 1.1)
                    let lum = max(0.14, 0.42 + wave * 0.42)
                    let r = 1.0 + max(0.0, wave) * 0.45
                    let dotColor = (col == 2 && row == 2) ? accent : Color(red: 0.973, green: 0.980, blue: 0.988).opacity(lum)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: dx - r, y: dy - r, width: r * 2, height: r * 2)),
                        with: .color(dotColor)
                    )
                }
            }
        }
    }

    // MARK: - 风格 3：活体有机软玉 (22 点卵石慢蠕自呼吸 + 羊脂白玉/墨青玉 + 内蕴柔雾)

    private func drawOrganicJade(
        ctx: inout GraphicsContext,
        state: SpriteOrbPhysicsState,
        breathWave: Double,
        isDark: Bool,
        accent: Color,
        panelOrSmart: Bool
    ) {
        let count = 22
        let baseR = 24.5
        var pts: [CGPoint] = []
        pts.reserveCapacity(count)

        for i in 0..<count {
            let a = (Double(i) / Double(count)) * .pi * 2.0
            let organic =
                sin(2.0 * a + state.time * 1.25) * 1.7 +
                cos(3.0 * a - state.time * 0.95) * 1.25 +
                sin(4.0 * a + state.time * 0.7) * 0.6
            var da = a - state.tensionAngle
            while da > .pi { da -= .pi * 2.0 }
            while da < -.pi { da += .pi * 2.0 }
            let lean = max(0.0, cos(da)) * state.tensionPull * 4.2
            let cap = sin(a * 3.0 + state.time * 10.0) * state.capillaryAmp * 1.5
            let r = baseR + organic + lean + cap
            pts.append(CGPoint(x: cos(a) * r, y: sin(a) * r))
        }

        let jadePath = closedSplinePath(through: pts)

        // 温润陶瓷柔影
        ctx.drawLayer { shadowCtx in
            shadowCtx.addFilter(
                .shadow(
                    color: isDark ? Color.black.opacity(0.56) : Color(red: 0.059, green: 0.090, blue: 0.165).opacity(0.16),
                    radius: 9 + breathWave * 2.0,
                    x: 0,
                    y: 4.5 + breathWave * 1.2
                )
            )
            shadowCtx.fill(
                jadePath,
                with: .color(isDark ? Color(red: 0.090, green: 0.125, blue: 0.133) : Color(red: 0.973, green: 0.976, blue: 0.961))
            )
        }

        // 羊脂玉 / 墨青玉主体 + 内蕴呼吸柔雾 + 哑光月牙
        ctx.drawLayer { jadeCtx in
            jadeCtx.clip(to: jadePath)

            let bgColors: [Color] = isDark
                ? [Color(red: 0.165, green: 0.212, blue: 0.224), Color(red: 0.067, green: 0.090, blue: 0.098)]
                : [.white, Color(red: 0.902, green: 0.929, blue: 0.910)]
            jadeCtx.fill(
                Path(CGRect(x: -38, y: -38, width: 76, height: 76)),
                with: .radialGradient(Gradient(colors: bgColors), center: CGPoint(x: -8, y: -8), startRadius: 2, endRadius: 30)
            )

            let jx = cos(state.time * 0.9) * 6.0
            let jy = sin(state.time * 1.1) * 5.0
            let mistColor: Color = panelOrSmart
                ? accent
                : (isDark ? Color(red: 0.204, green: 0.827, blue: 0.600) : SpriteOrbMoodAccent.emerald.swiftUIColor)
            jadeCtx.fill(
                Path(CGRect(x: -38, y: -38, width: 76, height: 76)),
                with: .radialGradient(
                    Gradient(colors: [mistColor.opacity(isDark ? 0.44 : 0.28), mistColor.opacity(0.0)]),
                    center: CGPoint(x: jx, y: jy),
                    startRadius: 1,
                    endRadius: 20
                )
            )

            // 柔哑陶瓷月牙光斑（-0.35 rad）
            let specPath = Path(ellipseIn: CGRect(x: -11, y: -4.2, width: 22, height: 8.4))
                .applying(CGAffineTransform(translationX: -6, y: -12).rotated(by: -0.35))
            jadeCtx.fill(
                specPath,
                with: .color(isDark ? Color.white.opacity(0.16) : Color.white.opacity(0.88))
            )
        }

        ctx.stroke(
            jadePath,
            with: .color(isDark ? Color.white.opacity(0.18) : Color.white.opacity(0.92)),
            lineWidth: 1.05
        )
    }

    // MARK: - 风格 4：无框极光丝灵 (去边界 4 层 3D 李萨如光绸 + 半透光纱 + 6 颗星核微粒簇)

    private func drawAuroraRibbon(
        ctx: inout GraphicsContext,
        state: SpriteOrbPhysicsState,
        breathWave: Double,
        isDark: Bool,
        accent: SpriteOrbMoodAccent
    ) {
        let accentColor = accent.swiftUIColor
        let pal: [Color] = isDark
            ? [
                accentColor,
                Color(red: 0.220, green: 0.741, blue: 0.973),
                Color(red: 0.506, green: 0.549, blue: 0.973),
                Color(red: 0.204, green: 0.827, blue: 0.600)
            ]
            : [
                accentColor,
                Color(red: 0.008, green: 0.518, blue: 0.780),
                Color(red: 0.310, green: 0.275, blue: 0.898),
                Color(red: 0.055, green: 0.647, blue: 0.914)
            ]

        // 极微底层柔晕，彻底无外框
        let auraR = 32.0 + breathWave * 4.0
        ctx.fill(
            Path(ellipseIn: CGRect(x: -34, y: -34, width: 68, height: 68)),
            with: .radialGradient(
                Gradient(colors: [accentColor.opacity(isDark ? 0.20 : 0.13), accentColor.opacity(0.0)]),
                center: .zero,
                startRadius: 2,
                endRadius: auraR
            )
        )

        let amp = (19.0 + breathWave * 3.8 + state.hoverBlend * 3.5) * (1.0 - state.vortexBlend * 0.25)
        let speedBoost = 1.0 + state.hoverBlend * 0.7 + state.vortexBlend * 1.4
        let speedT = state.time * 1.35 * speedBoost

        for rIdx in 0..<4 {
            let dir = (rIdx % 2 == 0) ? 0.42 : -0.34
            let rot = Double(rIdx) * 0.78 + speedT * dir
            let tiltY = 0.46 + 0.16 * sin(speedT * 0.9 + Double(rIdx))

            ctx.drawLayer { rCtx in
                rCtx.rotate(by: .radians(rot))
                var rPath = Path()
                let steps = 42
                for s in 0...steps {
                    let th = (Double(s) / Double(steps)) * .pi * 2.0
                    let wave = sin(th * 2.0 + speedT * 1.8 + Double(rIdx)) * 3.2
                    let x = cos(th) * (amp + wave)
                    let y = sin(th) * (amp * tiltY + wave * 0.5)
                    let pt = CGPoint(x: x, y: y)
                    if s == 0 {
                        rPath.move(to: pt)
                    } else {
                        rPath.addLine(to: pt)
                    }
                }
                rPath.closeSubpath()

                let strokeOpacity = (isDark ? 0.68 : 0.72) + Double(rIdx) * 0.06
                rCtx.stroke(
                    rPath,
                    with: .color(pal[rIdx].opacity(strokeOpacity)),
                    lineWidth: rIdx == 0 ? 2.4 : 1.75
                )
                rCtx.fill(
                    rPath,
                    with: .color(pal[rIdx].opacity(isDark ? 0.08 : 0.06))
                )
            }
        }

        // 中央 6 颗错速星核微粒簇
        for d in 0..<6 {
            let ang = state.time * (1.2 + Double(d) * 0.25) + Double(d) * 1.05
            let dist = 5.0 + sin(state.time * 2.2 + Double(d)) * 3.5
            let px = cos(ang) * dist
            let py = sin(ang) * dist
            let color = (d % 2 == 0) ? Color.white : accentColor
            ctx.fill(
                Path(ellipseIn: CGRect(x: px - 1.35, y: py - 1.35, width: 2.7, height: 2.7)),
                with: .color(color.opacity(0.85))
            )
        }
    }
}
