import AppKit
import Metal
import MetalKit
import QuartzCore

/// 顶部菜单栏「Apple Liquid Glass 灵动水滴 Siri + GPU 流体引力漏斗」控制器
///
/// 采用原生级双层物理光学架构（零静态渐变贴图）：
/// 1. 底层透镜：在 macOS 26+ 直接以官方 `NSGlassEffectView(.clear)` 作为水滴唯一根视图，
///    由 WindowServer 120Hz 实时对正后方桌面窗口、文字、图标进行硬件级凸透镜弯曲折射；
/// 2. 体积光场：内嵌 120Hz 原生 `MTKView` Metal 片元着色器（Premultiplied Luminescent Blending），
///    上半部为无缝衔接菜单栏的灵动岛曜石暗穹，赤道面为 5 层 3D 体积积分丝绸等离子彩虹声波与白炽核，
///    下半部完全透出真实桌面折射并叠加物理弯月面焦散（Meniscus Specular）与菲涅尔棱镜色散；
/// 3. 物理弹性形变：由 60/120Hz Display Timer 二阶弹簧微分方程驱动水滴从菜单栏表面张力隆起、磁力跟手与回缩；
/// 4. 图片空间扭曲吸入：松手瞬间启动全透明 Metal 流体引力场窗口，基于反向拉格朗日流线场（Inverse Funnel Advection）
///    与 RGB 三通道色散，将被拖入的真实图片拉丝、弯曲、色散分解并源源不断吸入水滴奇点。
@MainActor
final class BlackHolePortalController {
    static let shared = BlackHolePortalController()

    enum Phase: Equatable {
        case hidden
        case approaching
        case engaged
        case devouring
    }

    // MARK: - 水滴主透镜窗口与空间扭曲场窗口

    private var orbPanel: NSPanel?
    private var glassRootView: AnyObject?
    private var orbMetalView: MTKView?
    private var orbRenderer: SiriOrbMetalRenderer?
    private var dropReceiverView: BlackHoleDropReceiverView?

    private var warpPanel: NSPanel?
    private var warpMetalView: MTKView?
    private var warpRenderer: SpacetimeFunnelMetalRenderer?

    // MARK: - 二阶物理弹簧状态（120Hz 连续驱动水滴几何与磁力位移）

    private var physicsTimer: Timer?
    private var lastTickTime: CFTimeInterval = 0

    private var curWidth: CGFloat = 36
    private var curHeight: CGFloat = 12
    private var velWidth: CGFloat = 0
    private var velHeight: CGFloat = 0

    private var curOffsetX: CGFloat = 0
    private var curOffsetY: CGFloat = 0
    private var velOffsetX: CGFloat = 0
    private var velOffsetY: CGFloat = 0

    private var curEnergy: Float = 0.3
    private var curPulse: Float = 0.0

    private var anchorScreenRect: NSRect = .zero
    private var targetMousePoint: NSPoint = .zero
    private var cachedDragChangeCount: Int = -1
    private var cachedPayloadCGImage: CGImage?
    private var devourStartTimestamp: CFTimeInterval = 0

    private(set) var phase: Phase = .hidden
    var onPhaseChanged: ((Phase) -> Void)?
    var onPerformDrop: ((NSPasteboard) -> Bool)?

    private init() {}

    // MARK: - 外部交互状态机

    func showApproaching(anchorRect: NSRect, mouseLocation: NSPoint? = nil, dragPasteboard: NSPasteboard? = nil) {
        guard phase != .devouring else { return }
        self.anchorScreenRect = anchorRect
        if let mouseLocation {
            self.targetMousePoint = mouseLocation
        }
        if let pb = dragPasteboard {
            preloadDragTextureIfNeeded(from: pb)
        }

        ensureOrbPanel()
        guard let orbPanel else { return }

        if phase == .hidden {
            // 从菜单栏内部极扁液滴初始态生长垂落
            curWidth = 44
            curHeight = 14
            velWidth = 0
            velHeight = 0
            curOffsetX = 0
            curOffsetY = 8
            velOffsetX = 0
            velOffsetY = 0
            curEnergy = 0.35
            curPulse = 0.0

            setPhase(.approaching)
            applyOrbGeometryImmediate()
            orbPanel.alphaValue = 1
            orbMetalView?.isPaused = false
            orbPanel.orderFrontRegardless()
            startPhysicsLoop()
        }
    }

    func engage(anchorRect: NSRect?, mouseLocation: NSPoint? = nil, dragPasteboard: NSPasteboard? = nil) {
        guard phase != .devouring else { return }
        if let anchorRect {
            self.anchorScreenRect = anchorRect
        }
        if let mouseLocation {
            self.targetMousePoint = mouseLocation
        }
        if let pb = dragPasteboard {
            preloadDragTextureIfNeeded(from: pb)
        }

        ensureOrbPanel()
        guard let orbPanel else { return }

        if phase == .hidden {
            curWidth = 68
            curHeight = 28
            applyOrbGeometryImmediate()
        }
        if !orbPanel.isVisible {
            orbPanel.alphaValue = 1
            orbMetalView?.isPaused = false
            orbPanel.orderFrontRegardless()
        }
        if phase != .engaged {
            setPhase(.engaged)
            // 给一个微小的弹性冲量，像水珠被触碰轻颤一下
            velWidth += 95
            velHeight += 70
            TactileFeedbackEngine.shared.perform(.portalEngage)
        }
        startPhysicsLoop()
    }

    func disengageToApproachingOrDismiss(mouseLocation: NSPoint, anchorRect: NSRect?) {
        guard phase != .devouring, phase != .hidden else { return }
        if let anchorRect {
            self.anchorScreenRect = anchorRect
        }
        self.targetMousePoint = mouseLocation

        let center = NSPoint(x: anchorScreenRect.midX, y: anchorScreenRect.midY)
        let dist = hypot(mouseLocation.x - center.x, mouseLocation.y - center.y)
        if dist < 140 {
            setPhase(.approaching)
            return
        }
        dismiss()
    }

    /// 松手瞬间：启动 GPU 流体漏斗空间扭曲吸入真实图片 + 水滴等离子脉冲与回缩
    func triggerDevour(from pasteboard: NSPasteboard? = nil, dropScreenPoint: NSPoint? = nil) {
        ensureOrbPanel()
        if let importedCG = ClipboardStore.shared.lastImportedDragPreviewCGImage,
           let cardCG = PayloadSnapshotBuilder.renderRoundedCard(from: NSImage(cgImage: importedCG, size: NSSize(width: importedCG.width, height: importedCG.height)), pixelSize: 240) {
            cachedPayloadCGImage = cardCG
        } else if let pb = pasteboard,
                  let fresh = PayloadSnapshotBuilder.extractCGImage(from: pb, allowFileURLAccess: true) {
            cachedPayloadCGImage = fresh
        }

        devourStartTimestamp = CACurrentMediaTime()
        setPhase(.devouring)

        // 水滴先受吸入动量向下微鼓，再顺表面张力快速收归菜单栏
        velWidth += 140
        velHeight += 110
        velOffsetY -= 65
        curPulse = 1.0

        if let cgImg = cachedPayloadCGImage {
            launchWarpFunnelOverlay(
                image: cgImg,
                dropPoint: dropScreenPoint ?? NSEvent.mouseLocation
            )
        }

        TactileFeedbackEngine.shared.perform(.portalDevour)
        startPhysicsLoop()
    }

    func dismiss() {
        guard phase != .hidden, phase != .devouring else { return }
        setPhase(.hidden)
        startPhysicsLoop()
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        onPhaseChanged?(newPhase)
    }

    // MARK: - 120Hz 物理弹簧与生命周期驱动环

    private func startPhysicsLoop() {
        guard physicsTimer == nil else { return }
        lastTickTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepPhysics()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.physicsTimer = timer
    }

    private func stopPhysicsLoop() {
        physicsTimer?.invalidate()
        physicsTimer = nil
    }

    private func stepPhysics() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1.0 / 30.0, max(1.0 / 240.0, now - lastTickTime)))
        lastTickTime = now

        // 计算目标尺寸、磁力偏移与能量强度
        var targetW: CGFloat = 34
        var targetH: CGFloat = 8
        var targetOffX: CGFloat = 0
        var targetOffY: CGFloat = 10
        var targetEnergy: Float = 0.0
        var stiffness: CGFloat = 340
        var damping: CGFloat = 28

        let dx = targetMousePoint.x - anchorScreenRect.midX
        let dy = targetMousePoint.y - (anchorScreenRect.minY - 38)
        let dist = hypot(dx, dy)
        let proximity = max(0, min(1, 1.0 - dist / 155.0))

        switch phase {
        case .approaching:
            targetW = 98 + 18 * proximity
            targetH = 68 + 14 * proximity
            targetOffX = max(-9, min(9, dx * 0.075))
            targetOffY = max(-6, min(5, dy * 0.055))
            targetEnergy = Float(0.45 + 0.35 * proximity)
            stiffness = 320
            damping = 24

        case .engaged:
            targetW = 132
            targetH = 94
            targetOffX = max(-11, min(11, dx * 0.11))
            targetOffY = max(-8, min(6, dy * 0.08))
            targetEnergy = 1.0
            stiffness = 360
            damping = 25

        case .devouring:
            let elapsed = now - devourStartTimestamp
            let warpDuration: Double = cachedPayloadCGImage != nil ? 0.56 : 0.38
            let p = min(1.0, max(0.0, elapsed / warpDuration))

            // 同步驱动外部空间扭曲漏斗窗口
            if let warpRenderer, warpPanel?.isVisible == true {
                let orbCenterScreen = currentOrbSingularityScreenPoint()
                warpRenderer.update(progress: Float(p), orbScreenPoint: orbCenterScreen)
            }

            if p < 0.34 {
                // 前段张开吞噬漏斗，承接流光注入
                targetW = 138
                targetH = 98
                targetOffX = 0
                targetOffY = -2
                targetEnergy = 1.35
                curPulse = Float(sin((p / 0.34) * .pi)) * 1.15
                stiffness = 380
                damping = 26
            } else {
                // 后段顺着液体表面张力高速缩回顶部菜单栏图标内
                targetW = 28
                targetH = 6
                targetOffX = 0
                targetOffY = 14
                targetEnergy = 0.15
                curPulse = max(0, curPulse - Float(dt) * 4.5)
                stiffness = 460
                damping = 34
            }

            if p >= 1.0 {
                completeHideAndCleanup()
                return
            }

        case .hidden:
            targetW = 30
            targetH = 6
            targetOffX = 0
            targetOffY = 14
            targetEnergy = 0.0
            stiffness = 420
            damping = 34
        }

        // 二阶胡克阻尼弹簧积分
        springStep(pos: &curWidth, vel: &velWidth, target: targetW, stiffness: stiffness, damping: damping, dt: dt)
        springStep(pos: &curHeight, vel: &velHeight, target: targetH, stiffness: stiffness, damping: damping, dt: dt)
        springStep(pos: &curOffsetX, vel: &velOffsetX, target: targetOffX, stiffness: 280, damping: 24, dt: dt)
        springStep(pos: &curOffsetY, vel: &velOffsetY, target: targetOffY, stiffness: 280, damping: 24, dt: dt)

        curEnergy += (targetEnergy - curEnergy) * Float(min(1.0, dt * 10.0))
        if phase != .devouring {
            curPulse = max(0, curPulse - Float(dt) * 3.5)
        }

        applyOrbGeometryImmediate()

        // 同步着色器参数（含鼠标视差归一化向量）
        let normParallax = SIMD2<Float>(
            Float(max(-1, min(1, dx / 90.0))),
            Float(max(-1, min(1, dy / 90.0)))
        )
        orbRenderer?.updateUniforms(
            energy: curEnergy,
            pulse: curPulse,
            parallax: normParallax
        )

        if phase == .hidden, curHeight < 9.5, abs(velHeight) < 8 {
            completeHideAndCleanup()
        }
    }

    private func springStep(
        pos: inout CGFloat,
        vel: inout CGFloat,
        target: CGFloat,
        stiffness: CGFloat,
        damping: CGFloat,
        dt: CGFloat
    ) {
        let force = -stiffness * (pos - target) - damping * vel
        vel += force * dt
        pos += vel * dt
    }

    private func applyOrbGeometryImmediate() {
        guard let orbPanel, anchorScreenRect != .zero else { return }
        let w = max(24, curWidth)
        let h = max(6, curHeight)

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorScreenRect) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let sFrame = screen.frame

        var x = anchorScreenRect.midX - w * 0.5 + curOffsetX
        x = max(sFrame.minX + 6, min(x, sFrame.maxX - w - 6))
        // 水滴上沿紧贴菜单栏底沿（略嵌入 2pt 实现与菜单栏无缝融接）
        let topY = anchorScreenRect.minY + 2 + curOffsetY
        let y = topY - h

        let frame = NSRect(x: x, y: y, width: w, height: h)
        orbPanel.setFrame(frame, display: true)

        let radius = min(w, h) * 0.49
        if #available(macOS 26.0, *), let glassView = glassRootView as? NSGlassEffectView {
            glassView.cornerRadius = radius
        } else if let effectView = glassRootView as? NSVisualEffectView {
            effectView.layer?.cornerRadius = radius
        }

        // 收拢接近消失时平滑淡出，根除最后 1 帧闪烁
        if phase == .hidden || (phase == .devouring && h < 22) {
            orbPanel.alphaValue = max(0, min(1, (h - 6) / 16.0))
        } else {
            orbPanel.alphaValue = 1.0
        }
    }

    private func currentOrbSingularityScreenPoint() -> NSPoint {
        guard let orbPanel else {
            return NSPoint(x: anchorScreenRect.midX, y: anchorScreenRect.minY - 24)
        }
        // 奇点对准水滴中央虹彩等离子核心
        return NSPoint(
            x: orbPanel.frame.midX,
            y: orbPanel.frame.midY + orbPanel.frame.height * 0.04
        )
    }

    private func completeHideAndCleanup() {
        stopPhysicsLoop()
        orbMetalView?.isPaused = true
        orbPanel?.orderOut(nil)
        warpMetalView?.isPaused = true
        warpPanel?.orderOut(nil)
        cachedPayloadCGImage = nil
        cachedDragChangeCount = -1
        if phase != .hidden {
            setPhase(.hidden)
        }
    }

    private func preloadDragTextureIfNeeded(from pasteboard: NSPasteboard) {
        let count = pasteboard.changeCount
        guard count != cachedDragChangeCount || cachedPayloadCGImage == nil else { return }
        cachedDragChangeCount = count
        // 拖拽悬停阶段绝不提前读取本地 fileURL 磁盘路径，避免在未松手前触发跨容器 TCC 静默拦截
        if let cg = PayloadSnapshotBuilder.extractCGImage(from: pasteboard, allowFileURLAccess: false) {
            cachedPayloadCGImage = cg
        }
    }

    // MARK: - 构建原生 Liquid Glass + Metal 体积光场水滴窗口

    private func ensureOrbPanel() {
        guard orbPanel == nil else { return }
        let initRect = NSRect(x: 0, y: 0, width: 120, height: 86)
        let p = NSPanel(
            contentRect: initRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar + 2
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false

        let device = MTLCreateSystemDefaultDevice()
        let mtkView = MTKView(frame: initRect, device: device)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0)
        mtkView.preferredFramesPerSecond = 120
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.wantsLayer = true
        mtkView.layer?.isOpaque = false
        mtkView.layer?.backgroundColor = NSColor.clear.cgColor

        if let device, let renderer = SiriOrbMetalRenderer(device: device) {
            mtkView.delegate = renderer
            self.orbRenderer = renderer
        }

        let receiver = BlackHoleDropReceiverView(frame: initRect)
        receiver.autoresizingMask = [.width, .height]
        receiver.wantsLayer = true
        receiver.layer?.backgroundColor = NSColor.clear.cgColor
        receiver.addSubview(mtkView)

        receiver.onDragEntered = { [weak self] pb in
            self?.engage(anchorRect: nil, mouseLocation: NSEvent.mouseLocation, dragPasteboard: pb)
        }
        receiver.onDragUpdated = { [weak self] in
            self?.targetMousePoint = NSEvent.mouseLocation
        }
        receiver.onDragExited = { [weak self] in
            self?.disengageToApproachingOrDismiss(mouseLocation: NSEvent.mouseLocation, anchorRect: nil)
        }
        receiver.onPerformDrop = { [weak self] pb in
            guard let self else { return false }
            let ok = self.onPerformDrop?(pb) ?? false
            if ok {
                self.triggerDevour(from: pb, dropScreenPoint: NSEvent.mouseLocation)
            } else {
                self.dismiss()
            }
            return ok
        }

        if #available(macOS 26.0, *) {
            // 官方 NSGlassEffectView(.clear) 作为唯一根视图：100% 真实桌面折射、官方连续曲率、零四角毛边
            let glass = NSGlassEffectView(frame: initRect)
            glass.autoresizingMask = [.width, .height]
            glass.style = .clear
            glass.tintColor = nil
            glass.cornerRadius = 42
            glass.contentView = receiver
            p.hasShadow = false
            p.contentView = glass
            self.glassRootView = glass
        } else {
            let fallback = NSVisualEffectView(frame: initRect)
            fallback.autoresizingMask = [.width, .height]
            fallback.material = .hudWindow
            fallback.blendingMode = .behindWindow
            fallback.state = .active
            fallback.wantsLayer = true
            fallback.layer?.cornerCurve = .continuous
            fallback.layer?.cornerRadius = 42
            fallback.layer?.masksToBounds = true
            fallback.addSubview(receiver)
            p.hasShadow = true
            p.contentView = fallback
            self.glassRootView = fallback
        }

        self.orbMetalView = mtkView
        self.dropReceiverView = receiver
        self.orbPanel = p
    }

    // MARK: - 构建全透明 GPU 流体空间扭曲吸入窗口

    private func launchWarpFunnelOverlay(image: CGImage, dropPoint: NSPoint) {
        ensureWarpPanel()
        guard let warpPanel, let warpMetalView, let warpRenderer else { return }

        let orbPoint = currentOrbSingularityScreenPoint()
        // 覆盖奇点与松手位置之间的完整空间并留足扭曲余量
        let minX = min(orbPoint.x, dropPoint.x) - 150
        let maxX = max(orbPoint.x, dropPoint.x) + 150
        let minY = min(orbPoint.y, dropPoint.y) - 150
        let maxY = max(orbPoint.y, dropPoint.y) + 120
        let frame = NSRect(x: minX, y: minY, width: max(280, maxX - minX), height: max(240, maxY - minY))

        warpPanel.setFrame(frame, display: true)
        warpRenderer.configureSession(
            payload: image,
            panelFrame: frame,
            dropScreenPoint: dropPoint,
            orbScreenPoint: orbPoint
        )
        warpPanel.alphaValue = 1
        warpMetalView.isPaused = false
        // 置于水滴正上层或紧邻同层，让流束精准汇入水滴中心奇点
        warpPanel.orderFrontRegardless()
    }

    private func ensureWarpPanel() {
        guard warpPanel == nil else { return }
        let rect = NSRect(x: 0, y: 0, width: 320, height: 280)
        let p = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar + 3
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false

        let device = MTLCreateSystemDefaultDevice()
        let mtk = MTKView(frame: rect, device: device)
        mtk.autoresizingMask = [.width, .height]
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.clearColor = MTLClearColorMake(0, 0, 0, 0)
        mtk.preferredFramesPerSecond = 120
        mtk.isPaused = true
        mtk.enableSetNeedsDisplay = false
        mtk.wantsLayer = true
        mtk.layer?.isOpaque = false
        mtk.layer?.backgroundColor = NSColor.clear.cgColor

        if let device, let renderer = SpacetimeFunnelMetalRenderer(device: device) {
            mtk.delegate = renderer
            self.warpRenderer = renderer
        }

        p.contentView = mtk
        self.warpMetalView = mtk
        self.warpPanel = p
    }
}

// MARK: - 拖放接收视图

private final class BlackHoleDropReceiverView: NSView {
    var onDragEntered: ((NSPasteboard) -> Void)?
    var onDragUpdated: (() -> Void)?
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
        onDragEntered?(sender.draggingPasteboard)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              !ClipboardStore.shared.isInternalDragActive,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else { return [] }
        onDragUpdated?()
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

// MARK: - 拖拽内容纹理提取器（高清圆角图片 / 玻璃文字缩略卡）

@MainActor
private enum PayloadSnapshotBuilder {
    static func extractCGImage(from pasteboard: NSPasteboard, allowFileURLAccess: Bool) -> CGImage? {
        let types = pasteboard.types ?? []
        if types.contains(.png) || types.contains(.tiff) || types.contains(NSPasteboard.PasteboardType("public.jpeg")) {
            if let img = NSImage(pasteboard: pasteboard),
               let cg = renderRoundedCard(from: img, pixelSize: 240) {
                return cg
            }
        }

        if allowFileURLAccess,
           let nsURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] {
            for nsURL in nsURLs {
                let accessed = nsURL.startAccessingSecurityScopedResource()
                defer { if accessed { nsURL.stopAccessingSecurityScopedResource() } }
                let url = nsURL as URL
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "webp", "heic", "tiff", "gif", "bmp"].contains(ext),
                   let img = NSImage(contentsOf: url),
                   let cg = renderRoundedCard(from: img, pixelSize: 240) {
                    return cg
                }
            }
        }

        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return renderTextGlassCard(text: String(text.prefix(48)), pixelSize: 220)
        }

        return nil
    }

    static func renderRoundedCard(from image: NSImage, pixelSize: Int) -> CGImage? {
        let size = NSSize(width: pixelSize, height: pixelSize)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
        let radius = CGFloat(pixelSize) * 0.14
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.addClip()

        let src = image.size
        if src.width > 0 && src.height > 0 {
            let scale = max(rect.width / src.width, rect.height / src.height)
            let dw = src.width * scale
            let dh = src.height * scale
            let drawRect = NSRect(
                x: rect.midX - dw * 0.5,
                y: rect.midY - dh * 0.5,
                width: dw,
                height: dh
            )
            image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        NSColor.white.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 2.5
        path.stroke()

        return rep.cgImage
    }

    private static func renderTextGlassCard(text: String, pixelSize: Int) -> CGImage? {
        let w = pixelSize
        let h = Int(Double(pixelSize) * 0.68)
        let size = NSSize(width: w, height: h)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
        let path = NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28)
        let grad = NSGradient(
            starting: NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.28, alpha: 0.92),
            ending: NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.15, alpha: 0.95)
        )
        grad?.draw(in: path, angle: -45)

        NSColor.white.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 2.2
        path.stroke()

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96),
            .paragraphStyle: style
        ]
        (text as NSString).draw(in: rect.insetBy(dx: 20, dy: 24), withAttributes: attrs)
        return rep.cgImage
    }
}

// MARK: - Metal 着色器 1：Apple Liquid Glass 灵动岛黑核 + 3D 体积 Siri 丝绸波 + 弯月面棱镜色散

private struct OrbUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var energy: Float
    var pulse: Float
    var parallax: SIMD2<Float>
    var pad: Float = 0
}

private final class SiriOrbMetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let startTime: CFTimeInterval = CACurrentMediaTime()

    private var energy: Float = 0.5
    private var pulse: Float = 0.0
    private var parallax: SIMD2<Float> = .zero

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vfn = library.makeFunction(name: "orbFullscreenVertex"),
              let ffn = library.makeFunction(name: "siriLiquidMeniscusFragment") else {
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Premultiplied Luminescent Blending：既能用高 alpha 压暗顶部黑穹，又能用 0 alpha 在透明折射玻璃上叠加高光与色散！
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipelineState = pso
        super.init()
    }

    func updateUniforms(energy: Float, pulse: Float, parallax: SIMD2<Float>) {
        self.energy = energy
        self.pulse = pulse
        self.parallax = parallax
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let size = view.drawableSize
        var uniforms = OrbUniforms(
            resolution: SIMD2<Float>(Float(max(1, size.width)), Float(max(1, size.height))),
            time: Float(CACurrentMediaTime() - startTime),
            energy: energy,
            pulse: pulse,
            parallax: parallax
        )

        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct OrbUniforms {
        float2 resolution;
        float time;
        float energy;
        float pulse;
        float2 parallax;
        float pad;
    };

    vertex VertexOut orbFullscreenVertex(uint vid [[vertex_id]]) {
        float2 pos[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        VertexOut out;
        out.position = float4(pos[vid], 0.0, 1.0);
        // uv: (0,0) 顶部左角 -> (1,1) 底部右角
        out.uv = float2(pos[vid].x * 0.5 + 0.5, 0.5 - pos[vid].y * 0.5);
        return out;
    }

    // 柔和低频有机曲面场（摒弃细碎正弦线，采用宽阔丝滑的液态光瓣包络）
    float smoothLobe(float2 p, float2 center, float2 radii, float angle) {
        float c = cos(angle), s = sin(angle);
        float2 d = p - center;
        float2 rot = float2(d.x * c - d.y * s, d.x * s + d.y * c) / radii;
        return exp(-dot(rot, rot) * 1.65);
    }

    // 复刻 Apple 官方灵动岛 Liquid Glass Siri 光谱曲面（高饱和多层液态光翼 + 斜向丝绸白芯）
    void evalAppleSiriLiquidPrism(
        float2 p,
        float superR,
        float sphereZ,
        float t,
        float energy,
        float pulse,
        thread float3 &outColor,
        thread float &outMediumOpacity
    ) {
        float sp = 0.95 + energy * 0.75;
        // 球面赤道弧度自然上翘包裹（复刻官方图两端顺着球壁向上弯折的立体透镜感）
        float wrapY = p.y + (p.x * p.x) * 0.26 + 0.04;
        float2 wp = float2(p.x, wrapY);

        // 缓慢呼吸流动的相位
        float w1 = sin(t * sp * 1.15) * 0.10;
        float w2 = cos(t * sp * 0.92 + 1.1) * 0.11;
        float w3 = sin(t * sp * 1.34 + 2.4) * 0.09;

        // 1. 左上翼：清透翡翠青绿弧（#14E898）
        float lobeEmerald = smoothLobe(
            wp,
            float2(-0.36 + w1, -0.10 + w2 * 0.35),
            float2(0.48, 0.15),
            -0.18 + w1 * 0.5
        );

        // 2. 左下翼：炽烈琥珀暖橙红（#FF6B1A -> #FFB82E）
        float lobeAmber = smoothLobe(
            wp,
            float2(-0.26 + w2, 0.04 + w3 * 0.30),
            float2(0.46, 0.16),
            0.14 - w2 * 0.4
        );
        float lobeCoral = smoothLobe(
            wp,
            float2(-0.08 + w3, 0.10 + w1 * 0.25),
            float2(0.38, 0.14),
            0.08
        );

        // 3. 右中翼：高饱和霓虹樱粉洋红（#FF267E）
        float lobeMagenta = smoothLobe(
            wp,
            float2(0.18 - w1, 0.07 - w2 * 0.30),
            float2(0.46, 0.17),
            -0.16 + w3 * 0.4
        );

        // 4. 右侧深翼：电光紫罗兰与深钴蓝（#6A2BFF -> #1C64FF）
        float lobeViolet = smoothLobe(
            wp,
            float2(0.44 + w3 * 0.8, 0.02 + w1 * 0.30),
            float2(0.48, 0.18),
            -0.24
        );
        float lobeCobalt = smoothLobe(
            wp,
            float2(0.56 - w2 * 0.6, 0.10),
            float2(0.40, 0.16),
            -0.30
        );

        // 5. 正中央标志性斜向丝绸亮白等离子主光瓣（#FFFFFF，温润饱满不刺眼）
        float whiteTilt = -0.12 + 0.06 * sin(t * sp);
        float lobeWhite = smoothLobe(
            wp,
            float2(-0.06 + w1 * 0.6, -0.02 + w2 * 0.22),
            float2(0.44, 0.125 * (1.0 + pulse * 0.32)),
            whiteTilt
        );

        // 组合高纯度苹果官方光谱（避免加性混成死白，采用分层能量混合）
        float3 col = float3(0.0);
        col += float3(0.06, 0.95, 0.64) * lobeEmerald * 1.25;
        col += float3(1.00, 0.58, 0.08) * lobeAmber   * 1.42;
        col += float3(1.00, 0.26, 0.24) * lobeCoral   * 1.15;
        col += float3(1.00, 0.16, 0.56) * lobeMagenta * 1.25;
        col += float3(0.46, 0.22, 1.00) * lobeViolet  * 1.28;
        col += float3(0.12, 0.50, 1.00) * lobeCobalt  * 1.12;

        // 柔和胶片级色调压缩，确保色彩浓郁鲜活不泛白
        col = 1.0 - exp(-col * (1.15 + energy * 0.35 + pulse * 0.55));

        // 中心丝绸白芯柔和融入光谱中央
        float whiteMask = clamp(lobeWhite * (1.05 + energy * 0.22 + pulse * 0.45), 0.0, 1.0);
        col = mix(col, float3(0.99, 0.995, 1.0), whiteMask * 0.90);

        // 球面边缘柔化包络
        float edgeFade = smoothstep(1.02, 0.80, superR);
        col *= edgeFade * (0.72 + 0.28 * sphereZ);

        // 烟熏光学承托介质（保证即便背后是纯白窗口，腰部彩虹光带依然 100% 浓郁鲜明，而下半部透镜完全清透！）
        float totalEnergy = clamp(lobeEmerald + lobeAmber + lobeMagenta + lobeViolet + lobeWhite * 1.1, 0.0, 1.4);
        outMediumOpacity = clamp(totalEnergy * 0.68, 0.0, 0.88) * edgeFade;
        outColor = col;
    }

    fragment float4 siriLiquidMeniscusFragment(
        VertexOut in [[stage_in]],
        constant OrbUniforms &u [[buffer(0)]]
    ) {
        float2 p = in.uv * 2.0 - 1.0;
        float aspect = max(1.0, u.resolution.x / max(u.resolution.y, 1.0));

        // 精确胶囊距离场（与 NSGlassEffectView 连续圆角外壁在任意弹簧形变宽高比下 100% 像素级严丝合缝）
        float2 pa = float2(p.x * aspect, p.y);
        float halfSpan = max(0.0, aspect - 1.0);
        float2 cq = float2(max(abs(pa.x) - halfSpan, 0.0), abs(pa.y));
        float superR = length(cq);
        if (superR > 1.04) {
            return float4(0.0);
        }
        float sphereZ = sqrt(max(0.0, 1.0 - min(1.0, superR * superR)));
        p.x -= u.parallax.x * 0.035;

        // 1. 上半部：灵动岛深邃纯黑曜石穹顶（与菜单栏浑然一体，在腰部彩虹带正后方丝滑收束）
        float domeCurve = -0.06 + (p.x * p.x) * 0.24 - u.parallax.y * 0.025;
        float domeAlpha = (1.0 - smoothstep(domeCurve - 0.14, domeCurve + 0.20, p.y)) * 0.97;
        float3 obsidianRGB = float3(0.014, 0.015, 0.022);

        // 2. 腰部：Apple Liquid Glass Siri 丝绸光谱光翼（带细腻物理微色散）
        float3 colR, colG, colB;
        float medR, medG, medB;
        float2 disp = normalize(p + float2(0.0001, 0.0001)) * (0.006 + 0.010 * superR * superR);
        evalAppleSiriLiquidPrism(p + disp, superR, sphereZ, u.time, u.energy, u.pulse, colR, medR);
        evalAppleSiriLiquidPrism(p,        superR, sphereZ, u.time, u.energy, u.pulse, colG, medG);
        evalAppleSiriLiquidPrism(p - disp, superR, sphereZ, u.time, u.energy, u.pulse, colB, medB);

        float3 siriColor = float3(colR.r, colG.g, colB.b);
        float bandBackdropAlpha = max(medG, (medR + medB) * 0.48);

        // 3. 下半部透明凸透镜区的真实玻璃光学细节（完全保留底层 NSGlassEffectView 真实桌面折射！）
        // 极淡的光学玻璃体积深度感（仅 8% 烟熏冷灰，防止纯白背景晃眼并凸显白色玻璃弧边）
        float lowerLensTintAlpha = smoothstep(-0.05, 0.45, p.y) * (1.0 - smoothstep(0.92, 1.01, superR)) * 0.10;

        // 锐利晶莹的 3D 弯月面内壁菲涅尔高光环（Crisp Meniscus Specular Rim，复刻官方图底部与两侧亮边）
        float crispRim = exp(-pow((superR - 0.955) / 0.032, 2.0));
        float softInnerRim = exp(-pow((superR - 0.88) / 0.075, 2.0)) * 0.32;
        float lowerWeight = smoothstep(-0.35, 0.35, p.y);

        float3 leftSpectralRim  = float3(0.28, 0.90, 0.96) * clamp(-p.x * 1.2, 0.0, 1.0);
        float3 rightSpectralRim = float3(0.76, 0.52, 1.00) * clamp( p.x * 1.2, 0.0, 1.0);
        float bottomPool = pow(max(0.0, p.y), 1.8);

        float3 meniscusHighlight = (
            float3(0.96, 0.98, 1.00) * (0.38 + 0.62 * bottomPool) +
            (leftSpectralRim + rightSpectralRim) * 0.55
        ) * (crispRim * 0.78 + softInnerRim) * lowerWeight;

        // 顶部曜石穹顶微弱弧面冷反光
        float domeSpec = exp(-pow(length((p - float2(0.0, -0.68)) / float2(0.58, 0.20)), 2.0)) * 0.055;

        // 4. 精确 Premultiplied Alpha 物理合成：
        // 背景遮蔽 alpha 由上半黑穹、腰部烟熏承托层、下半极淡透镜冷调共同决定；
        // 光谱自发光与弯月面高光直接以光子能量叠加，绝不在白色背景上泛灰或过曝！
        float baseAlpha = clamp(max(max(domeAlpha, bandBackdropAlpha), lowerLensTintAlpha), 0.0, 0.98);
        float3 darkSubstrate = obsidianRGB * baseAlpha;

        float3 finalPremulRGB = darkSubstrate * (1.0 - clamp(bandBackdropAlpha * 0.55, 0.0, 1.0))
                              + siriColor * 0.92
                              + meniscusHighlight
                              + float3(domeSpec);

        // 外缘 1.5px 丝滑抗锯齿羽化
        float aa = 1.0 - smoothstep(0.985, 1.02, superR);
        return float4(finalPremulRGB * aa, clamp(baseAlpha + crispRim * lowerWeight * 0.35, 0.0, 0.98) * aa);
    }
    """
}

// MARK: - Metal 着色器 2：真实图片 GPU 相对论流体漏斗空间扭曲与色散吸入（Spacetime Funnel Advection）

private struct FunnelUniforms {
    var resolution: SIMD2<Float>
    var dropCenterUV: SIMD2<Float>
    var orbCenterUV: SIMD2<Float>
    var cardHalfSizeUV: SIMD2<Float>
    var progress: Float
    var pad: Float = 0
}

private final class SpacetimeFunnelMetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState

    private var payloadTexture: MTLTexture?
    private var panelFrame: NSRect = .zero
    private var dropScreenPoint: NSPoint = .zero
    private var orbScreenPoint: NSPoint = .zero
    private var progress: Float = 0

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vfn = library.makeFunction(name: "funnelFullscreenVertex"),
              let ffn = library.makeFunction(name: "spacetimeFunnelFragment") else {
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipelineState = pso

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToZero
        sampDesc.tAddressMode = .clampToZero
        guard let sampler = device.makeSamplerState(descriptor: sampDesc) else { return nil }
        self.samplerState = sampler

        super.init()
    }

    func configureSession(
        payload: CGImage,
        panelFrame: NSRect,
        dropScreenPoint: NSPoint,
        orbScreenPoint: NSPoint
    ) {
        self.panelFrame = panelFrame
        self.dropScreenPoint = dropScreenPoint
        self.orbScreenPoint = orbScreenPoint
        self.progress = 0

        let loader = MTKTextureLoader(device: device)
        self.payloadTexture = try? loader.newTexture(cgImage: payload, options: [
            .SRGB: false,
            .generateMipmaps: false
        ])
    }

    func update(progress: Float, orbScreenPoint: NSPoint) {
        self.progress = progress
        self.orbScreenPoint = orbScreenPoint
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let tex = payloadTexture,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let w = max(1, panelFrame.width)
        let h = max(1, panelFrame.height)

        // 转换到 UV 坐标系（左上角 0,0 -> 右下角 1,1）
        let dropUV = SIMD2<Float>(
            Float((dropScreenPoint.x - panelFrame.minX) / w),
            Float(1.0 - (dropScreenPoint.y - panelFrame.minY) / h)
        )
        let orbUV = SIMD2<Float>(
            Float((orbScreenPoint.x - panelFrame.minX) / w),
            Float(1.0 - (orbScreenPoint.y - panelFrame.minY) / h)
        )
        let aspect = Float(tex.height) / Float(max(1, tex.width))
        let cardW: CGFloat = 104
        let cardH: CGFloat = cardW * CGFloat(aspect)
        let halfSizeUV = SIMD2<Float>(Float((cardW * 0.5) / w), Float((cardH * 0.5) / h))

        let drawSize = view.drawableSize
        var uniforms = FunnelUniforms(
            resolution: SIMD2<Float>(Float(max(1, drawSize.width)), Float(max(1, drawSize.height))),
            dropCenterUV: dropUV,
            orbCenterUV: orbUV,
            cardHalfSizeUV: halfSizeUV,
            progress: progress
        )

        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(samplerState, index: 0)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<FunnelUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct FunnelUniforms {
        float2 resolution;
        float2 dropCenterUV;
        float2 orbCenterUV;
        float2 cardHalfSizeUV;
        float progress;
        float pad;
    };

    vertex VertexOut funnelFullscreenVertex(uint vid [[vertex_id]]) {
        float2 pos[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        VertexOut out;
        out.position = float4(pos[vid], 0.0, 1.0);
        out.uv = float2(pos[vid].x * 0.5 + 0.5, 0.5 - pos[vid].y * 0.5);
        return out;
    }

    // 反向求解拉格朗日引力流场：靠近奇点一侧率先拉长成流体细丝钻入水滴，尾端滞后收缩跟进
    float2 sampleFunnelSourceUV(
        float2 pixelPt,
        float2 orbPt,
        float2 centerPt,
        float2 cardHalfPx,
        float p,
        float swirlScale
    ) {
        float2 relOrb = pixelPt - orbPt;
        float r = length(relOrb);
        float safeR = max(r, 1.0);

        // 1. 螺旋角动量逆变换：越靠近水滴中心，时空旋转扭曲越剧烈
        float swirlStrength = pow(clamp(p * 1.35, 0.0, 1.0), 1.25);
        float twistAngle = swirlStrength * swirlScale * 3.6 * exp(-safeR / 88.0);
        float cs = cos(-twistAngle);
        float sn = sin(-twistAngle);
        float2 untwisted = orbPt + float2(
            relOrb.x * cs - relOrb.y * sn,
            relOrb.x * sn + relOrb.y * cs
        );

        // 2. 引力漏斗径向拉丝与横向收束（Spaghettification）
        float2 axis = orbPt - centerPt;
        float axisLen = length(axis);
        float2 dir = axisLen > 0.5 ? (axis / axisLen) : float2(0.0, -1.0);
        float2 perp = float2(-dir.y, dir.x);

        float2 fromCenter = untwisted - centerPt;
        float along = dot(fromCenter, dir);
        float across = dot(fromCenter, perp);

        // 越靠近奇点，横向漏斗截面越窄（像水滴被吸入细玻璃管），逆映射即放大横向采样跨度！
        float distToSingularity = length(untwisted - orbPt);
        float funnelPinch = 1.0 + swirlStrength * 5.2 * exp(-distToSingularity / 72.0);
        // 整体随吸入进度平滑收缩，同时沿引力方向产生流线拉伸
        float globalScale = max(0.10, 1.0 - pow(p, 1.65) * 0.92);
        float axialStretch = 1.0 + sin(min(1.0, p * 1.15) * 3.1415926) * 0.72;

        float srcAlong = along / (globalScale * axialStretch);
        float srcAcross = (across * funnelPinch) / globalScale;

        float2 localPx = dir * srcAlong + perp * srcAcross;
        return (localPx / max(cardHalfPx, float2(1.0))) * 0.5 + 0.5;
    }

    fragment float4 spacetimeFunnelFragment(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant FunnelUniforms &u [[buffer(0)]]
    ) {
        float p = clamp(u.progress, 0.0, 1.0);
        if (p >= 0.96) {
            return float4(0.0);
        }

        float2 res = u.resolution;
        float2 pixelPt = in.uv * res;
        float2 dropPt = u.dropCenterUV * res;
        float2 orbPt = u.orbCenterUV * res;
        float2 cardHalfPx = u.cardHalfSizeUV * res;

        // 质心沿优雅的引力弧线加速坠向水滴奇点
        float moveT = pow(p, 1.78);
        float2 axis = orbPt - dropPt;
        float2 perp = normalize(float2(-axis.y, axis.x) + float2(0.001, 0.0));
        float arcOffset = sin(p * 3.1415926) * 18.0 * (1.0 - moveT);
        float2 curCenter = mix(dropPt, orbPt, moveT) + perp * arcOffset;

        // RGB 三通道收敛为克制真实的光学玻璃微色散（0.976 / 1.000 / 1.024），画面主体清晰温润，仅流束边缘泛出棱镜光谱
        float2 uvR = sampleFunnelSourceUV(pixelPt, orbPt, curCenter, cardHalfPx, p, 0.976);
        float2 uvG = sampleFunnelSourceUV(pixelPt, orbPt, curCenter, cardHalfPx, p, 1.000);
        float2 uvB = sampleFunnelSourceUV(pixelPt, orbPt, curCenter, cardHalfPx, p, 1.024);

        float4 sR = tex.sample(samp, uvR);
        float4 sG = tex.sample(samp, uvG);
        float4 sB = tex.sample(samp, uvB);

        float outAlpha = max(sG.a, max(sR.a, sB.a) * 0.85);
        if (outAlpha <= 0.002) {
            return float4(0.0);
        }

        float3 rgb = float3(sR.r * sR.a, sG.g * sG.a, sB.b * sB.a);

        // 事件视界吸收核：流丝钻入水滴中心时平滑没入等离子体，绝不穿透出界
        float distOrb = length(pixelPt - orbPt);
        float horizonMask = smoothstep(4.0, 24.0, distOrb + (1.0 - p) * 16.0);
        float tailFade = 1.0 - smoothstep(0.76, 0.95, p);
        float finalMask = horizonMask * tailFade;

        // 靠近奇点咽喉处激发一道明亮的虹彩流光能量增亮
        float throatGlow = exp(-distOrb / 32.0) * sin(p * 3.1415926) * 0.55;
        rgb += float3(0.32, 0.86, 1.00) * throatGlow * outAlpha;

        return float4(rgb * finalMask, outAlpha * finalMask);
    }
    """
}
