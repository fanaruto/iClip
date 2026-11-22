import AppKit
import SwiftUI

/// 顶部菜单栏 Logo「Apple Intelligence New Siri 流体虹吸球」引力场控制器
///
/// 采用 Apple New Siri / Apple Intelligence 标志性的多色流体丝带（Cyan / Indigo / Magenta / Coral）
/// 与 macOS 26 Liquid Glass 光学球体设计：
/// 1. 靠近顶部菜单栏 Logo 时，无文字干扰的 New Siri 液态虹彩球从菜单栏下方丝滑绽放；
/// 2. 拖拽进入球体时，四色极光色带加速向中心视界内卷汇聚、高光呼吸增强，伴随触控板清脆对齐震感；
/// 3. 松手瞬间，流体色带向心坍缩成一道纯净的虹彩奇点闪光并向上收归入菜单栏图标，完成复制与入库。
@MainActor
final class BlackHolePortalController {
    static let shared = BlackHolePortalController()

    enum Phase: Equatable {
        case hidden
        case approaching
        case engaged
        case devouring
    }

    private var panel: NSPanel?
    private var hostingView: NSHostingView<SiriLiquidOrbView>?
    private var dropView: BlackHoleDropReceiverView?
    private var dismissWorkItem: DispatchWorkItem?
    private let portalSize = NSSize(width: 132, height: 132)

    private(set) var phase: Phase = .hidden
    var onPhaseChanged: ((Phase) -> Void)?
    var onPerformDrop: ((NSPasteboard) -> Bool)?

    private init() {}

    /// 当外部拖拽靠近顶部菜单栏 Logo 引力圈时唤醒 New Siri 流体球
    func showApproaching(anchorRect: NSRect) {
        guard phase != .devouring else { return }
        dismissWorkItem?.cancel()
        ensurePanel()
        guard let panel else { return }

        positionPanel(around: anchorRect)
        if phase == .hidden {
            setPhase(.approaching)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().alphaValue = 1
            }
        }
    }

    /// 拖拽直接进入顶部 Logo 或流体球：锁定高能向心虹吸状态
    func engage(anchorRect: NSRect?) {
        guard phase != .devouring else { return }
        dismissWorkItem?.cancel()
        ensurePanel()
        guard let panel else { return }

        if let anchorRect {
            positionPanel(around: anchorRect)
        }
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        if phase != .engaged {
            setPhase(.engaged)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// 拖拽离开球体核心但仍在引力圈内，或彻底移出
    func disengageToApproachingOrDismiss(mouseLocation: NSPoint, anchorRect: NSRect?) {
        guard phase != .devouring, phase != .hidden else { return }
        if let anchorRect {
            let center = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
            let dist = hypot(mouseLocation.x - center.x, mouseLocation.y - center.y)
            if dist < 125 {
                setPhase(.approaching)
                return
            }
        }
        dismiss()
    }

    /// 松手触发向心虹吸坍缩动效
    func triggerDevour() {
        dismissWorkItem?.cancel()
        ensurePanel()
        guard panel != nil else { return }

        setPhase(.devouring)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.20
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().alphaValue = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                    self?.panel?.orderOut(nil)
                    self?.setPhase(.hidden)
                }
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: work)
    }

    /// 平滑收起
    func dismiss() {
        guard phase != .hidden, phase != .devouring else { return }
        dismissWorkItem?.cancel()
        setPhase(.hidden)
        guard let panel, panel.isVisible else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .hidden else { return }
                self.panel?.orderOut(nil)
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: work)
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        hostingView?.rootView = SiriLiquidOrbView(phase: newPhase)
        onPhaseChanged?(newPhase)
    }

    private func positionPanel(around anchorRect: NSRect) {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame

        var originX = anchorRect.midX - portalSize.width / 2
        originX = max(frame.minX + 8, min(originX, frame.maxX - portalSize.width - 8))
        let originY = min(frame.maxY - portalSize.height - 2, anchorRect.minY - portalSize.height + 24)
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let rect = NSRect(origin: .zero, size: portalSize)
        let p = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar + 2
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false

        let root = SiriLiquidOrbView(phase: .approaching)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = rect
        hosting.autoresizingMask = [.width, .height]

        let receiver = BlackHoleDropReceiverView(frame: rect)
        receiver.autoresizingMask = [.width, .height]
        receiver.addSubview(hosting)
        receiver.onDragEntered = { [weak self] in
            self?.engage(anchorRect: nil)
        }
        receiver.onDragExited = { [weak self] in
            self?.disengageToApproachingOrDismiss(mouseLocation: NSEvent.mouseLocation, anchorRect: nil)
        }
        receiver.onPerformDrop = { [weak self] pasteboard in
            guard let self else { return false }
            let ok = self.onPerformDrop?(pasteboard) ?? false
            if ok {
                self.triggerDevour()
            } else {
                self.dismiss()
            }
            return ok
        }

        p.contentView = receiver
        self.hostingView = hosting
        self.dropView = receiver
        self.panel = p
    }
}

/// 承载拖放捕获的 AppKit 视图
private final class BlackHoleDropReceiverView: NSView {
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onPerformDrop: ((NSPasteboard) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ClipboardStore.supportedDragTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(ClipboardStore.supportedDragTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              !ClipboardStore.shared.isInternalDragActive,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else { return [] }
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              !ClipboardStore.shared.isInternalDragActive,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource == nil &&
        !ClipboardStore.shared.isInternalDragActive &&
        ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerformDrop?(sender.draggingPasteboard) ?? false
    }
}

/// Apple Intelligence New Siri 风格：多层流体极光丝带 + 液态玻璃球面折射 + 向心虹吸坍缩
private struct SiriLiquidOrbView: View {
    let phase: BlackHolePortalController.Phase

    @State private var devourCollapse: CGFloat = 1.0
    @State private var devourFlashScale: CGFloat = 0.2
    @State private var devourFlashOpacity: Double = 0.0
    @State private var devourOffsetY: CGFloat = 0

    private var isEngaged: Bool { phase == .engaged }
    private var isDevouring: Bool { phase == .devouring }

    // Apple Intelligence 官方标志性四色极光色板
    private let siriCyan = Color(red: 0.22, green: 0.78, blue: 1.00)
    private let siriIndigo = Color(red: 0.42, green: 0.34, blue: 0.98)
    private let siriMagenta = Color(red: 1.00, green: 0.22, blue: 0.56)
    private let siriCoral = Color(red: 1.00, green: 0.56, blue: 0.24)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed = isEngaged ? 2.4 : 1.15
            let angle1 = t * 68 * speed
            let angle2 = -t * 54 * speed
            let angle3 = t * 82 * speed
            let breathe = 1.0 + 0.045 * sin(t * (isEngaged ? 6.5 : 3.2))

            ZStack {
                // 1. 外围 Apple Intelligence 柔和环境虹彩呼吸光晕（Siri Aura）
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                siriCyan.opacity(0.55),
                                siriIndigo.opacity(0.60),
                                siriMagenta.opacity(0.58),
                                siriCoral.opacity(0.50),
                                siriCyan.opacity(0.55)
                            ]),
                            center: .center
                        )
                    )
                    .frame(width: isEngaged ? 96 : 82, height: isEngaged ? 96 : 82)
                    .rotationEffect(.degrees(angle1))
                    .blur(radius: isEngaged ? 16 : 13)
                    .opacity(isDevouring ? 0.0 : (isEngaged ? 0.92 : 0.68))

                // 2. 液态玻璃球体基底（深邃半透明暗晶 + 多层交织流体极光瓣）
                ZStack {
                    // 深空暗晶底（衬托极光丝带的通透发光感，同时形成中心引力深渊）
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.03, green: 0.03, blue: 0.07).opacity(0.95),
                                    Color(red: 0.06, green: 0.05, blue: 0.14).opacity(0.88)
                                ],
                                center: .center,
                                startRadius: 2,
                                endRadius: 36
                            )
                        )

                    // 流体丝带层 A（青蓝 -> 靛紫 偏心变形柔光瓣）
                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [siriCyan.opacity(0.95), siriIndigo.opacity(0.85), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58, height: 40)
                        .offset(x: isEngaged ? 4 : 8, y: isEngaged ? -4 : -7)
                        .rotationEffect(.degrees(angle1))
                        .blur(radius: 7)
                        .blendMode(.plusLighter)

                    // 流体丝带层 B（洋红 -> 暖橙 反向交织柔光瓣）
                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [siriMagenta.opacity(0.92), siriCoral.opacity(0.82), .clear],
                                startPoint: .bottomTrailing,
                                endPoint: .topLeading
                            )
                        )
                        .frame(width: 56, height: 38)
                        .offset(x: isEngaged ? -4 : -8, y: isEngaged ? 4 : 7)
                        .rotationEffect(.degrees(angle2))
                        .blur(radius: 7)
                        .blendMode(.plusLighter)

                    // 流体丝带层 C（Siri 标志性高光白芯流带，悬停锁定时向球心收束提亮）
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(isEngaged ? 0.92 : 0.65),
                                    siriCyan.opacity(0.70),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 1,
                                endRadius: 24
                            )
                        )
                        .frame(width: isEngaged ? 42 : 48, height: isEngaged ? 26 : 32)
                        .rotationEffect(.degrees(angle3))
                        .blur(radius: 4.5)
                        .blendMode(.plusLighter)

                    // 中心深邃视界引力核（悬停时产生向内坍缩的深邃黑洞透镜感）
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.black.opacity(isEngaged ? 0.88 : 0.72),
                                    Color.black.opacity(0.25),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 1,
                                endRadius: isEngaged ? 20 : 16
                            )
                        )
                        .frame(width: 40, height: 40)

                    // 液态玻璃球面顶部高光反射（Apple 玻璃球体标志性弧面反光）
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.42),
                                    Color.white.opacity(0.06),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .padding(1.5)
                }
                .frame(width: isEngaged ? 74 : 64, height: isEngaged ? 74 : 64)
                .clipShape(Circle())
                // 3. 球体边缘 Liquid Glass 四色流光折射环
                .overlay(
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    Color.white.opacity(0.95),
                                    siriCyan.opacity(0.90),
                                    siriMagenta.opacity(0.92),
                                    siriCoral.opacity(0.88),
                                    siriIndigo.opacity(0.90),
                                    Color.white.opacity(0.95)
                                ]),
                                center: .center
                            ),
                            lineWidth: isEngaged ? 2.2 : 1.5
                        )
                        .rotationEffect(.degrees(angle1 * 0.8))
                )
                .scaleEffect(breathe * devourCollapse)
                .offset(y: devourOffsetY)

                // 4. 松手吞噬瞬间：向心坍缩后的虹彩奇点星芒脉冲
                if isDevouring {
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                gradient: Gradient(colors: [siriCyan, siriMagenta, siriCoral, siriIndigo, siriCyan]),
                                center: .center
                            ),
                            lineWidth: 2.5
                        )
                        .frame(width: 76, height: 76)
                        .blur(radius: 1.5)
                        .scaleEffect(devourFlashScale)
                        .opacity(devourFlashOpacity)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white, siriCyan.opacity(0.8), .clear],
                                center: .center,
                                startRadius: 1,
                                endRadius: 22
                            )
                        )
                        .frame(width: 44, height: 44)
                        .scaleEffect(devourFlashScale * 0.85)
                        .opacity(devourFlashOpacity)
                        .blendMode(.plusLighter)
                }
            }
        }
        .frame(width: 132, height: 132)
        .animation(.spring(response: 0.28, dampingFraction: 0.76), value: phase)
        .onAppear {
            if phase == .devouring {
                runDevourCollapse()
            }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .devouring {
                runDevourCollapse()
            } else {
                devourCollapse = 1.0
                devourOffsetY = 0
            }
        }
    }

    private func runDevourCollapse() {
        devourCollapse = 1.08
        devourOffsetY = 0
        devourFlashScale = 0.35
        devourFlashOpacity = 1.0

        // 球体极速向心坍缩并向上吸入菜单栏 Logo
        withAnimation(.easeIn(duration: 0.24)) {
            devourCollapse = 0.02
            devourOffsetY = -28
        }
        // 坍缩同时荡开一圈柔和的 Apple Intelligence 四色虹彩涟漪
        withAnimation(.easeOut(duration: 0.32)) {
            devourFlashScale = 1.22
            devourFlashOpacity = 0.0
        }
    }
}
