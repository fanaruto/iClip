import AppKit
import SwiftUI

/// 顶部菜单栏 Logo「黑洞奇点吞噬」引力场控制器
///
/// 当用户拖拽任意外部文字、链接、图片或文件移向屏幕顶部菜单栏 iClip 图标时：
/// 1. 自动在顶部 Logo 处唤醒深邃的「黑洞事件视界」与多层旋转吸积盘流光；
/// 2. 拖拽进入视界时引力场扩张加速、粒子向奇点坠落，并触发触控板引力对齐震感；
/// 3. 松手瞬间上演螺旋坍缩吞噬 + 引力冲击波扩散动效，直接完成剪贴板复制与历史收录。
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
    private var hostingView: NSHostingView<BlackHoleVortexView>?
    private var dropView: BlackHoleDropReceiverView?
    private var dismissWorkItem: DispatchWorkItem?
    private let portalSize = NSSize(width: 148, height: 148)

    private(set) var phase: Phase = .hidden
    var onPhaseChanged: ((Phase) -> Void)?
    var onPerformDrop: ((NSPasteboard) -> Bool)?

    private init() {}

    /// 当外部拖拽靠近顶部菜单栏 Logo 引力圈时唤醒黑洞
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
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().alphaValue = 1
            }
        }
    }

    /// 拖拽直接进入顶部 Logo 或黑洞视界核心：锁定高能吸积状态
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

    /// 拖拽离开黑洞视界但仍在引力圈内，或彻底移出
    func disengageToApproachingOrDismiss(mouseLocation: NSPoint, anchorRect: NSRect?) {
        guard phase != .devouring, phase != .hidden else { return }
        if let anchorRect {
            let center = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
            let dist = hypot(mouseLocation.x - center.x, mouseLocation.y - center.y)
            if dist < 128 {
                setPhase(.approaching)
                return
            }
        }
        dismiss()
    }

    /// 松手触发奇点吞噬坍缩动效
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
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().alphaValue = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.panel?.orderOut(nil)
                    self?.setPhase(.hidden)
                }
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: work)
    }

    /// 平滑收起黑洞引力场
    func dismiss() {
        guard phase != .hidden, phase != .devouring else { return }
        dismissWorkItem?.cancel()
        setPhase(.hidden)
        guard let panel, panel.isVisible else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        hostingView?.rootView = BlackHoleVortexView(phase: newPhase)
        onPhaseChanged?(newPhase)
    }

    private func positionPanel(around anchorRect: NSRect) {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame

        var originX = anchorRect.midX - portalSize.width / 2
        originX = max(frame.minX + 8, min(originX, frame.maxX - portalSize.width - 8))
        // 紧贴顶部菜单栏图标正下方展开黑洞视界，同时向上覆盖菜单栏图标热区
        let originY = min(frame.maxY - portalSize.height - 2, anchorRect.minY - portalSize.height + 26)
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

        let root = BlackHoleVortexView(phase: .approaching)
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

/// 承载黑洞视界拖放捕获的 AppKit 视图
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

/// 黑洞事件视界、旋转吸积盘与奇点吞噬动效视图
private struct BlackHoleVortexView: View {
    let phase: BlackHolePortalController.Phase

    @State private var spinAngle: Double = 0
    @State private var innerSpinAngle: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var shockwaveScale: CGFloat = 0.25
    @State private var shockwaveOpacity: Double = 0.0
    @State private var devouredCheckOpacity: Double = 0.0

    private var isEngaged: Bool { phase == .engaged }
    private var isDevouring: Bool { phase == .devouring }

    var body: some View {
        ZStack {
            // 1. 外围深空引力场暗晕（把背景柔和压暗，衬托黑洞视界）
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.black.opacity(isEngaged ? 0.92 : 0.78),
                            Color(red: 0.07, green: 0.05, blue: 0.16).opacity(isEngaged ? 0.68 : 0.45),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 68
                    )
                )
                .frame(width: 136, height: 136)
                .scaleEffect(isDevouring ? 0.15 : (isEngaged ? 1.08 : 0.88))

            // 2. 外层吸积盘螺旋流光（紫罗兰 -> 电光蓝 -> 亮青）
            Circle()
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.42, green: 0.22, blue: 0.98).opacity(0.15),
                            Color(red: 0.20, green: 0.62, blue: 1.0).opacity(0.92),
                            Color(red: 0.55, green: 0.92, blue: 1.0).opacity(0.98),
                            Color(red: 0.62, green: 0.28, blue: 0.98).opacity(0.85),
                            Color(red: 0.42, green: 0.22, blue: 0.98).opacity(0.15)
                        ]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: isEngaged ? 9 : 6, lineCap: .round)
                )
                .frame(width: 86, height: 86)
                .blur(radius: 1.8)
                .rotationEffect(.degrees(spinAngle))
                .scaleEffect(isDevouring ? 0.05 : (isEngaged ? 1.06 * pulseScale : 0.86))

            // 3. 吸入粒子星环（反向旋转交错产生引力漩涡感）
            ForEach(0..<6, id: \.self) { idx in
                Circle()
                    .fill(idx.isMultiple(of: 2) ? Color.cyan : Color.white)
                    .frame(width: isEngaged ? 4.5 : 3.2, height: isEngaged ? 4.5 : 3.2)
                    .shadow(color: Color.cyan, radius: 4)
                    .offset(y: isDevouring ? -2 : (isEngaged ? -34 : -42))
                    .rotationEffect(.degrees(Double(idx) * 60 + innerSpinAngle))
                    .opacity(isDevouring ? 0.0 : (isEngaged ? 0.95 : 0.65))
            }

            // 4. 内层光子环（Photon Ring：紧贴黑洞边缘的高亮折射白环）
            Circle()
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.95),
                            Color.cyan.opacity(0.75),
                            Color.purple.opacity(0.85),
                            Color.white.opacity(0.95)
                        ]),
                        center: .center
                    ),
                    lineWidth: isEngaged ? 2.6 : 1.8
                )
                .frame(width: 52, height: 52)
                .shadow(color: Color.cyan.opacity(0.8), radius: isEngaged ? 8 : 4)
                .rotationEffect(.degrees(-innerSpinAngle))
                .scaleEffect(isDevouring ? 0.02 : (isEngaged ? 0.96 : 0.84))

            // 5. 中心黑洞事件视界（Event Horizon：绝对纯黑奇点）
            Circle()
                .fill(Color.black)
                .frame(width: 46, height: 46)
                .shadow(color: Color.black, radius: 10)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(isEngaged ? 0.35 : 0.18), lineWidth: 0.8)
                )
                .scaleEffect(isDevouring ? 0.01 : (isEngaged ? 1.04 : 0.85))

            // 6. 奇点中心引力图标 / 吞噬完成星芒
            if isDevouring {
                Circle()
                    .strokeBorder(Color.cyan.opacity(shockwaveOpacity), lineWidth: 3)
                    .frame(width: 110, height: 110)
                    .scaleEffect(shockwaveScale)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.green, Color.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.cyan.opacity(0.8), radius: 10)
                    .opacity(devouredCheckOpacity)
                    .scaleEffect(devouredCheckOpacity > 0 ? 1.05 : 0.4)
            } else {
                Image(systemName: isEngaged ? "hurricane" : "tornado")
                    .font(.system(size: isEngaged ? 19 : 16, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color.cyan.opacity(0.9)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .rotationEffect(.degrees(spinAngle * 1.4))
                    .scaleEffect(isEngaged ? 1.12 : 0.92)
            }

            // 7. 底部引力提示微标
            if !isDevouring {
                VStack {
                    Spacer()
                    Text(isEngaged ? "松手吞噬复制" : "黑洞引力捕获")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.76))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.cyan.opacity(isEngaged ? 0.75 : 0.4), lineWidth: 0.8)
                                )
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 4, y: 2)
                        .padding(.bottom, 6)
                }
            }
        }
        .frame(width: 148, height: 148)
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: phase)
        .onAppear {
            startContinuousSpin()
            if phase == .devouring {
                runDevourCollapseAnimation()
            }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .devouring {
                runDevourCollapseAnimation()
            }
        }
    }

    private func startContinuousSpin() {
        withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
            spinAngle = 360
        }
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            innerSpinAngle = 360
        }
        withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
            pulseScale = 1.07
        }
    }

    private func runDevourCollapseAnimation() {
        shockwaveScale = 0.25
        shockwaveOpacity = 0.95
        devouredCheckOpacity = 0.0

        withAnimation(.easeOut(duration: 0.32)) {
            shockwaveScale = 1.18
            shockwaveOpacity = 0.0
        }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.68).delay(0.10)) {
            devouredCheckOpacity = 1.0
        }
    }
}
