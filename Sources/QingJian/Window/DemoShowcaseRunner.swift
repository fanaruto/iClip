import AppKit
import SwiftUI

/// 实机演示舞台状态（仅在传 --demo 启动参数时实例化，平时运行零内存与零开销）
@MainActor
private final class DemoStageModel: ObservableObject {
    @Published var cursorPosition: CGPoint = CGPoint(x: 340, y: 270)
    @Published var clickPulseScale: CGFloat = 0.01
    @Published var clickPulseOpacity: Double = 0.0
    @Published var keyBadge: String? = nil
    @Published var caption: String = "iClip · 1.2 MB 原生 macOS 剪贴板"
    @Published var typedLine: String = ""
    @Published var highlightInserted: Bool = false
}

/// 电影级 16:10 实机演示舞台与运镜编排器
@MainActor
final class DemoShowcaseRunner {
    private weak var panelController: FloatingPanelController?
    private let store: ClipboardStore
    private let nav: PanelNavigationModel
    private let stageModel = DemoStageModel()

    private var stageWindow: NSWindow?
    private var overlayWindow: NSWindow?
    private var maskTimer: Timer?

    private let stageSize = CGSize(width: 1040, height: 650)

    init(panelController: FloatingPanelController, store: ClipboardStore, nav: PanelNavigationModel) {
        self.panelController = panelController
        self.store = store
        self.nav = nav
    }

    func start() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let stageOrigin = NSPoint(
            x: round(visible.midX - stageSize.width / 2),
            y: round(visible.midY - stageSize.height / 2)
        )
        let stageFrame = NSRect(origin: stageOrigin, size: stageSize)

        // 把精确录制坐标（CG 坐标系，原点在主屏左上角）打印到 stdout 供录屏脚本 100% 对齐
        let screenHeight = screen.frame.height
        let cgY = round(screenHeight - stageFrame.maxY)
        print("DEMO_STAGE_RECT=\(Int(stageFrame.minX)),\(Int(cgY)),\(Int(stageSize.width)),\(Int(stageSize.height))")
        fflush(stdout)

        // 将系统真实光标移出录制区域并隐藏，确保画面中只有唯一一颗 60fps 丝滑运镜指针
        CGWarpMouseCursorPosition(CGPoint(x: 30, y: 30))
        CGDisplayHideCursor(CGMainDisplayID())

        // 1. 底层高颜值极光壁纸 + 左侧极简文档窗口（置于真实 iClip 液态玻璃面板正下方一层）
        let bg = NSWindow(contentRect: stageFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        bg.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        bg.isOpaque = true
        bg.backgroundColor = .clear
        bg.hasShadow = false
        bg.contentView = NSHostingView(rootView: DemoBackgroundStageView(model: stageModel))
        bg.orderFront(nil)
        self.stageWindow = bg

        // 2. 顶层透明光标与胶囊字幕层（浮于真实 iClip 液态玻璃面板之上，不吃点击）
        let ov = NSWindow(contentRect: stageFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        ov.level = .popUpMenu
        ov.isOpaque = false
        ov.backgroundColor = .clear
        ov.hasShadow = false
        ov.ignoresMouseEvents = true
        ov.contentView = NSHostingView(rootView: DemoCursorOverlayView(model: stageModel))
        ov.orderFront(nil)
        self.overlayWindow = ov

        // 真实 iClip 面板紧贴左侧文档光标旁弹出（右侧黄金构图位置）
        // stage 内坐标系（左上为原点）：面板位于 x = 540, y = 45, width = 420, height = 560
        let panelLeftInStage: CGFloat = 540
        let panelTopInStage: CGFloat = 45
        let panelOrigin = NSPoint(
            x: stageFrame.minX + panelLeftInStage,
            y: stageFrame.maxY - panelTopInStage - 560
        )

        // 预设清晰通透的液态玻璃初始状态
        store.surfaceStyle = .liquidGlass
        store.liquidGlassAppearance = .tinted
        store.liquidGlassMaskOpacity = 0.24
        store.borderlessPanel = true

        // 初始光标停在左侧文档写作输入处
        stageModel.cursorPosition = CGPoint(x: 420, y: 268)

        // === 镜头 1（0.8s）：按下 Option+V，iClip 从鼠标右侧丝滑呼出 ===
        schedule(at: 0.75) { [weak self] in
            guard let self else { return }
            self.showKeyBadge("⌥ V")
            self.stageModel.caption = "⌥ V · 鼠标光标旁直觉唤醒"
            self.panelController?.showForDemo(origin: panelOrigin, entryDelta: NSPoint(x: -14, y: 6))
        }

        // === 镜头 2（2.2s ~ 5.5s）：光标顺滑扫过 3 列图片相册网格，触发原厂大屏速览 ===
        let imgRowY = panelTopInStage + 225
        schedule(at: 2.1) { [weak self] in
            guard let self else { return }
            self.stageModel.caption = "3 列相册网格 · Space / 重按系统大屏预览"
            self.moveCursor(to: CGPoint(x: panelLeftInStage + 78, y: imgRowY), duration: 0.42)
        }
        schedule(at: 2.45) { [weak self] in
            self?.nav.demoPreviewIndex = 1
        }

        schedule(at: 3.45) { [weak self] in
            guard let self else { return }
            self.moveCursor(to: CGPoint(x: panelLeftInStage + 210, y: imgRowY), duration: 0.34)
        }
        schedule(at: 3.72) { [weak self] in
            self?.nav.demoPreviewIndex = 2
        }

        schedule(at: 4.70) { [weak self] in
            guard let self else { return }
            self.moveCursor(to: CGPoint(x: panelLeftInStage + 342, y: imgRowY), duration: 0.34)
        }
        schedule(at: 4.95) { [weak self] in
            self?.nav.demoPreviewIndex = 3
        }

        // === 镜头 3（5.95s ~ 8.9s）：点击设置，实时无级调节苹果原生 Liquid Glass 蒙版 ===
        schedule(at: 5.95) { [weak self] in
            guard let self else { return }
            self.nav.demoPreviewIndex = nil
            self.moveCursor(to: CGPoint(x: panelLeftInStage + 390, y: panelTopInStage + 30), duration: 0.38)
        }
        schedule(at: 6.38) { [weak self] in
            guard let self else { return }
            self.triggerClickPulse()
            self.nav.showSettings = true
            self.stageModel.caption = "苹果原生 Liquid Glass · 透明 / 着色与蒙版无级调节"
        }

        // 切至「透明」并实时平滑抓着滑块圆点拖动蒙版浓度 24% -> 2% -> 50%
        let sliderMinX = panelLeftInStage + 32
        let sliderMaxX = panelLeftInStage + 388
        let sliderY = panelTopInStage + 206

        schedule(at: 6.85) { [weak self] in
            guard let self else { return }
            self.moveCursor(to: CGPoint(x: panelLeftInStage + 312, y: panelTopInStage + 146), duration: 0.30)
        }
        schedule(at: 7.18) { [weak self] in
            guard let self else { return }
            self.triggerClickPulse()
            self.store.liquidGlassAppearance = .clear
            self.moveCursor(to: CGPoint(x: sliderMinX + (sliderMaxX - sliderMinX) * 0.24, y: sliderY), duration: 0.22)
        }
        schedule(at: 7.42) { [weak self] in
            guard let self else { return }
            self.animateMaskOpacity(
                from: 0.24,
                to: 0.02,
                duration: 0.55,
                sliderTrack: (minX: sliderMinX, maxX: sliderMaxX, y: sliderY)
            )
        }
        schedule(at: 8.05) { [weak self] in
            guard let self else { return }
            self.store.liquidGlassAppearance = .tinted
            self.animateMaskOpacity(
                from: 0.02,
                to: 0.50,
                duration: 0.72,
                sliderTrack: (minX: sliderMinX, maxX: sliderMaxX, y: sliderY)
            )
        }

        // === 镜头 4（9.0s ~ 11.4s）：返回列表 -> 双击卡片 -> 面板丝滑收起、内容直接键入光标处 ===
        schedule(at: 8.95) { [weak self] in
            guard let self else { return }
            self.moveCursor(to: CGPoint(x: panelLeftInStage + 36, y: panelTopInStage + 30), duration: 0.32)
        }
        schedule(at: 9.30) { [weak self] in
            guard let self else { return }
            self.triggerClickPulse()
            self.nav.showSettings = false
            self.nav.selectedIndex = 0
        }
        schedule(at: 9.75) { [weak self] in
            guard let self else { return }
            self.stageModel.caption = "双击卡片 · 直接键入光标所在区域"
            self.moveCursor(to: CGPoint(x: panelLeftInStage + 195, y: panelTopInStage + 142), duration: 0.34)
        }
        schedule(at: 10.15) { [weak self] in
            guard let self else { return }
            self.showKeyBadge("双击键入")
            self.triggerClickPulse()
        }
        schedule(at: 10.30) { [weak self] in
            guard let self else { return }
            self.triggerClickPulse()
            self.panelController?.hideForDemo()
        }
        schedule(at: 10.52) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                self.stageModel.typedLine = "https://github.com/fanaruto/iClip"
                self.stageModel.highlightInserted = true
            }
            self.moveCursor(to: CGPoint(x: 425, y: 292), duration: 0.35)
        }
        schedule(at: 11.2) { [weak self] in
            withAnimation(.easeOut(duration: 0.35)) {
                self?.stageModel.highlightInserted = false
            }
        }
    }

    private func schedule(at delay: Double, block: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            block()
        }
    }

    private func moveCursor(to point: CGPoint, duration: Double) {
        withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: duration)) {
            stageModel.cursorPosition = point
        }
    }

    private func triggerClickPulse() {
        stageModel.clickPulseScale = 0.2
        stageModel.clickPulseOpacity = 0.85
        withAnimation(.easeOut(duration: 0.32)) {
            stageModel.clickPulseScale = 1.65
            stageModel.clickPulseOpacity = 0.0
        }
    }

    private func showKeyBadge(_ text: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
            stageModel.keyBadge = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) {
                if self?.stageModel.keyBadge == text {
                    self?.stageModel.keyBadge = nil
                }
            }
        }
    }

    private func animateMaskOpacity(
        from start: Double,
        to end: Double,
        duration: Double,
        sliderTrack: (minX: CGFloat, maxX: CGFloat, y: CGFloat)? = nil
    ) {
        maskTimer?.invalidate()
        let startTime = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(max(elapsed / duration, 0), 1)
            let eased = progress < 0.5
                ? 2 * progress * progress
                : 1 - pow(-2 * progress + 2, 2) / 2
            let current = start + (end - start) * eased
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.store.liquidGlassMaskOpacity = current
                if let track = sliderTrack {
                    let x = track.minX + (track.maxX - track.minX) * CGFloat(current)
                    self.stageModel.cursorPosition = CGPoint(x: x, y: track.y)
                }
            }
            if progress >= 1 {
                t.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        maskTimer = timer
    }
}

/// 底层高颜值极光壁纸 + 左侧真实感写作便签
private struct DemoBackgroundStageView: View {
    @ObservedObject var model: DemoStageModel
    @State private var caretVisible: Bool = true

    var body: some View {
        ZStack(alignment: .leading) {
            // 高质感 macOS 极光渐变壁纸（凸显苹果原生 Liquid Glass 物理光学折射）
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.11, blue: 0.22),
                        Color(red: 0.14, green: 0.22, blue: 0.42),
                        Color(red: 0.11, green: 0.16, blue: 0.28)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color(red: 0.25, green: 0.62, blue: 0.98).opacity(0.45))
                    .frame(width: 520, height: 520)
                    .blur(radius: 90)
                    .offset(x: 240, y: -120)

                Circle()
                    .fill(Color(red: 0.95, green: 0.42, blue: 0.56).opacity(0.36))
                    .frame(width: 440, height: 440)
                    .blur(radius: 85)
                    .offset(x: 320, y: 170)

                Circle()
                    .fill(Color(red: 0.22, green: 0.85, blue: 0.72).opacity(0.28))
                    .frame(width: 420, height: 420)
                    .blur(radius: 90)
                    .offset(x: -180, y: 140)
            }

            // 左侧极简 macOS 便签窗口（展示真实输入与双击键入闭环）
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.26)).frame(width: 11, height: 11)
                    Spacer()
                    Text("发布记录.md")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer()
                    Color.clear.frame(width: 45, height: 1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(Color.white.opacity(0.05))

                VStack(alignment: .leading, spacing: 14) {
                    Text("# iClip v1.7 发布笔记")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))

                    Text("做了一个 1.2 MB 的原生 macOS 剪贴板，支持 Liquid Glass 液态玻璃、图片 3 列悬停放大与 GitHub 一键 OTA 更新。")
                        .font(.system(size: 13.5))
                        .lineSpacing(5)
                        .foregroundStyle(.white.opacity(0.72))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("开源地址：")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))

                        HStack(spacing: 2) {
                            if !model.typedLine.isEmpty {
                                Text(model.typedLine)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(Color(red: 0.48, green: 0.80, blue: 1.0))
                                    .padding(.horizontal, model.highlightInserted ? 6 : 0)
                                    .padding(.vertical, model.highlightInserted ? 2 : 0)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.accentColor.opacity(model.highlightInserted ? 0.28 : 0))
                                    )
                                    .transition(.opacity.combined(with: .move(edge: .leading)))
                            }
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.accentColor)
                                .frame(width: 2, height: 17)
                                .opacity(caretVisible ? 1 : 0.15)
                        }
                        .frame(minHeight: 24, alignment: .leading)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.black.opacity(0.24))
                    )

                    Spacer()
                }
                .padding(20)
            }
            .frame(width: 440, height: 470)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.18).opacity(0.84))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 28, y: 14)
            .padding(.leading, 56)
        }
        .frame(width: 1040, height: 650)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { _ in
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        caretVisible.toggle()
                    }
                }
            }
        }
    }
}

/// 顶层透明覆盖视图：丝滑苹果光标、点击波纹、快捷键徽章与极简字幕
private struct DemoCursorOverlayView: View {
    @ObservedObject var model: DemoStageModel

    var body: some View {
        ZStack {
            // 底部极简毛玻璃字幕胶囊（按键徽章独立居中浮在字幕上方，过渡绝不重叠）
            VStack(spacing: 8) {
                Spacer()
                if let badge = model.keyBadge {
                    Text(badge)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4.5)
                        .background(
                            Capsule()
                                .fill(Color.accentColor)
                                .shadow(color: Color.accentColor.opacity(0.4), radius: 8, y: 2)
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Text(model.caption)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7.5)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.56))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6))
                    )
                    .padding(.bottom, 16)
            }
            .animation(.easeOut(duration: 0.2), value: model.keyBadge)

            // 点击微涟漪
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: 26, height: 26)
                .scaleEffect(model.clickPulseScale)
                .opacity(model.clickPulseOpacity)
                .position(model.cursorPosition)

            // 精致苹果箭头指针
            ApplePointerShape()
                .fill(Color.black)
                .overlay(
                    ApplePointerShape()
                        .stroke(Color.white, lineWidth: 1.5)
                )
                .frame(width: 17, height: 22)
                .shadow(color: Color.black.opacity(0.45), radius: 3, y: 1.5)
                .position(x: model.cursorPosition.x + 6, y: model.cursorPosition.y + 9)
        }
        .frame(width: 1040, height: 650)
        .allowsHitTesting(false)
    }
}

/// 经典 macOS 指针矢量轮廓
private struct ApplePointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: rect.height * 0.86))
        p.addLine(to: CGPoint(x: rect.width * 0.28, y: rect.height * 0.66))
        p.addLine(to: CGPoint(x: rect.width * 0.48, y: rect.height))
        p.addLine(to: CGPoint(x: rect.width * 0.64, y: rect.height * 0.92))
        p.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.58))
        p.addLine(to: CGPoint(x: rect.width * 0.82, y: rect.height * 0.56))
        p.closeSubpath()
        return p
    }
}
