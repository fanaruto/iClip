import AppKit
import SwiftUI
import Combine

/// 独立苹果原厂 Setup Assistant 风格入门引导窗口（易上手、可交互沙盒零污染历史、全链路零冲突）
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    enum Step: Int, CaseIterable, Identifiable {
        case welcomeAndReadiness = 0
        case hotKeyMuscleMemory = 1
        case clickPasteFeel = 2
        case interactiveSandbox = 3
        case migrateAndFinish = 4

        var id: Int { rawValue }

        var shortTitle: String {
            switch self {
            case .welcomeAndReadiness: return "欢迎"
            case .hotKeyMuscleMemory: return "唤醒手势"
            case .clickPasteFeel: return "键入手感"
            case .interactiveSandbox: return "互动沙盒"
            case .migrateAndFinish: return "搬家启程"
            }
        }

        var symbolName: String {
            switch self {
            case .welcomeAndReadiness: return "sparkles"
            case .hotKeyMuscleMemory: return "command"
            case .clickPasteFeel: return "hand.tap.fill"
            case .interactiveSandbox: return "wand.and.stars"
            case .migrateAndFinish: return "checkmark.seal.fill"
            }
        }
    }

    private var window: NSWindow?
    let state = OnboardingWindowViewModel()

    private override init() {
        super.init()
        AppWindowCoordinator.shared.registerWindowProvider(for: .onboarding) { [weak self] in
            self?.window
        }
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// 当用户停留在「唤醒手势」试按步骤时，由全局热键回调消费本次试按并给出物理弹跳反馈（绝不把主面板叠盖到引导窗上方）
    func consumeHotKeyTrialIfNeeded() -> Bool {
        guard isVisible, state.currentStep == .hotKeyMuscleMemory, !HotKeyRecorderCoordinator.shared.isRecording else {
            return false
        }
        return state.triggerTrialSuccess()
    }

    func show(store: ClipboardStore? = nil, forceRestart: Bool = false) {
        let store = store ?? .shared
        guard NSClassFromString("XCTestCase") == nil else { return }

        store.refreshAllPermissionStatuses()
        if forceRestart {
            state.resetForFreshRun()
        } else if state.currentStep == .migrateAndFinish {
            state.currentStep = .welcomeAndReadiness
        }

        if let existing = window {
            bringToFront(existing)
            state.syncMonitorsForCurrentStep()
            return
        }

        let contentSize = NSSize(width: 710, height: 560)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "欢迎使用 iClip"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.level = .normal
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.minSize = NSSize(width: 660, height: 520)
        win.backgroundColor = .windowBackgroundColor
        win.delegate = self

        let rootView = StandaloneOnboardingView(
            store: store,
            viewModel: state,
            onFinish: { [weak self] openMainPanel in
                self?.state.stopMonitors()
                HotKeyRecorderCoordinator.shared.stopRecording()
                InteractivePlaygroundController.shared.markOnboardingCompleted(in: store)
                self?.close()
                if openMainPanel {
                    AppWindowCoordinator.shared.openMainPanelFromStandalone()
                }
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]
        win.contentView = hosting

        centerOnActiveScreen(win, size: contentSize)
        self.window = win
        bringToFront(win)
        state.syncMonitorsForCurrentStep()
    }

    func close() {
        state.stopMonitors()
        HotKeyRecorderCoordinator.shared.stopRecording()
        if let win = window, win.isVisible {
            win.orderOut(nil)
        }
        AppWindowCoordinator.shared.notifyStandaloneVisibilityChanged()
    }

    func windowWillClose(_ notification: Notification) {
        state.stopMonitors()
        HotKeyRecorderCoordinator.shared.stopRecording()
        InteractivePlaygroundController.shared.markOnboardingCompleted(in: ClipboardStore.shared)
        AppWindowCoordinator.shared.notifyStandaloneVisibilityChanged()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ClipboardStore.shared.refreshAllPermissionStatuses()
        state.syncMonitorsForCurrentStep()
        AppWindowCoordinator.shared.notifyStandaloneVisibilityChanged()
    }

    private func bringToFront(_ win: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        AppWindowCoordinator.shared.notifyStandaloneVisibilityChanged()
    }

    private func centerOnActiveScreen(_ win: NSWindow, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            win.center()
            return
        }
        let origin = NSPoint(
            x: round(visible.midX - size.width * 0.5),
            y: round(visible.midY - size.height * 0.5 + 16)
        )
        win.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

// MARK: - 引导视图状态机（含大爆炸互动沙盒纯内存状态）

@MainActor
final class OnboardingWindowViewModel: ObservableObject {
    enum SandboxTab: String, CaseIterable, Identifiable {
        case bigBang = "大爆炸与二次拆分"
        case todoAndShield = "待办与敏感护盾"
        case screenshotAndMinimal = "原生截屏与极简模式"

        var id: String { rawValue }
    }

    @Published var currentStep: OnboardingWindowController.Step = .welcomeAndReadiness {
        didSet {
            if currentStep != .hotKeyMuscleMemory {
                HotKeyRecorderCoordinator.shared.stopRecording()
            }
            syncMonitorsForCurrentStep()
        }
    }

    @Published var didHitTrialHotKey: Bool = false
    @Published var isTrialModifierDown: Bool = false
    @Published var showInlineHotKeyCustom: Bool = false
    @Published var lastImportFeedback: String? = nil

    // 沙盒 Tab 状态（完全纯内存，0 写入 ClipboardStore）
    @Published var sandboxTab: SandboxTab = .bigBang
    @Published var sandboxTokens: [BigBangTextToken] = []
    @Published var sandboxSelectedTokenIDs: Set<Int> = []
    @Published var sandboxUndoStack: [[BigBangTextToken]] = []
    @Published var sandboxBurstEpoch: Int = 0
    @Published var sandboxTodoChecked: Bool = false
    @Published var sandboxSecretRedacted: Bool = true
    @Published var sandboxMinimalPreview: Bool = false

    private var sandboxNextTokenID: Int = 1000
    private var flagsMonitor: Any?

    static let sandboxSampleSentence = "打开 https://app.webfooo.com/iClip 查看 984×1,264 截图"

    init() {
        resetSandboxBigBang()
    }

    func resetForFreshRun() {
        currentStep = .welcomeAndReadiness
        didHitTrialHotKey = false
        isTrialModifierDown = false
        showInlineHotKeyCustom = false
        lastImportFeedback = nil
        resetSandboxBigBang()
    }

    func resetSandboxBigBang() {
        let initial = BigBangTokenizer.tokenize(Self.sandboxSampleSentence, granularity: .smart)
            .filter { !$0.isLineBreak }
        sandboxTokens = initial
        sandboxNextTokenID = (initial.map(\.id).max() ?? 0) + 10
        sandboxSelectedTokenIDs = []
        sandboxUndoStack = []
        sandboxBurstEpoch = 0
    }

    func toggleSandboxTokenSelection(_ tokenID: Int) {
        if sandboxSelectedTokenIDs.contains(tokenID) {
            sandboxSelectedTokenIDs.remove(tokenID)
        } else {
            sandboxSelectedTokenIDs.insert(tokenID)
        }
        TactileFeedbackEngine.shared.perform(.tabSwitch)
    }

    @discardableResult
    func explodeSandboxToken(_ token: BigBangTextToken) -> Bool {
        guard let idx = sandboxTokens.firstIndex(where: { $0.id == token.id }) else { return false }
        sandboxBurstEpoch += 1
        guard let children = BigBangTokenizer.subdivideToken(
            token,
            nextID: &sandboxNextTokenID,
            burstGeneration: sandboxBurstEpoch
        ) else {
            return false
        }
        sandboxUndoStack.append(sandboxTokens)
        let wasSelected = sandboxSelectedTokenIDs.remove(token.id) != nil
        withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
            sandboxTokens.replaceSubrange(idx...idx, with: children)
            if wasSelected {
                for child in children {
                    sandboxSelectedTokenIDs.insert(child.id)
                }
            }
        }
        TactileFeedbackEngine.shared.perform(.onboardingKeyHit)
        return true
    }

    func undoSandboxExplosion() {
        guard let previous = sandboxUndoStack.popLast() else { return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            sandboxTokens = previous
            let validIDs = Set(previous.map(\.id))
            sandboxSelectedTokenIDs = sandboxSelectedTokenIDs.intersection(validIDs)
        }
        TactileFeedbackEngine.shared.perform(.tabSwitch)
    }

    var sandboxSelectedPreviewText: String {
        let picked = sandboxTokens.filter { sandboxSelectedTokenIDs.contains($0.id) }
        guard !picked.isEmpty else { return "" }
        return picked.map(\.text).joined(separator: " ")
    }

    func triggerTrialSuccess() -> Bool {
        guard !didHitTrialHotKey else { return true }
        didHitTrialHotKey = true
        TactileFeedbackEngine.shared.perform(.onboardingKeyHit)
        return true
    }

    func syncMonitorsForCurrentStep() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        if currentStep == .hotKeyMuscleMemory {
            startMonitorsIfNeeded()
        } else {
            stopMonitors()
        }
    }

    private func startMonitorsIfNeeded() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, self.currentStep == .hotKeyMuscleMemory else { return event }
            if HotKeyRecorderCoordinator.shared.isRecording {
                return event
            }
            if event.type == .flagsChanged {
                let pressed = ClipboardStore.shared.hotKeyShortcut.matchesTrialModifierPressed(in: event.modifierFlags)
                if self.isTrialModifierDown != pressed {
                    withAnimation(.interpolatingSpring(mass: 0.55, stiffness: 420, damping: 24)) {
                        self.isTrialModifierDown = pressed
                    }
                }
            } else if event.type == .keyDown,
                      ClipboardStore.shared.hotKeyShortcut.matchesLocalKeyDown(
                          keyCode: event.keyCode,
                          flags: event.modifierFlags
                      ) {
                _ = self.triggerTrialSuccess()
                return nil
            }
            return event
        }
    }

    func stopMonitors() {
        isTrialModifierDown = false
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
    }
}

// MARK: - 独立入门引导 SwiftUI 视图（macOS 26 Tahoe 果味美学）

struct StandaloneOnboardingView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: OnboardingWindowViewModel
    @ObservedObject private var recorder = HotKeyRecorderCoordinator.shared
    let onFinish: (_ openMainPanel: Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var installedCompetitors: [UniversalCompetitorImporter.InstalledCompetitorApp] = []

    private var grantedPermissionCount: Int {
        (store.isAccessibilityGranted ? 1 : 0)
            + (store.isFullDiskAccessGranted ? 1 : 0)
            + (store.isScreenRecordingGranted ? 1 : 0)
    }

    var body: some View {
        ZStack {
            windowBackdrop

            VStack(spacing: 0) {
                topStepperBar
                    .padding(.horizontal, 26)
                    .padding(.top, 26)
                    .padding(.bottom, 12)

                Divider().opacity(0.28)

                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        switch viewModel.currentStep {
                        case .welcomeAndReadiness:
                            step1WelcomeView
                        case .hotKeyMuscleMemory:
                            step2HotKeyTrialView
                        case .clickPasteFeel:
                            step3ClickPasteFeelView
                        case .interactiveSandbox:
                            step4InteractiveSandboxView
                        case .migrateAndFinish:
                            step5MigrateAndFinishView
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(viewModel.currentStep)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 16)),
                        removal: .opacity.combined(with: .offset(x: -16))
                    ))
                }
                .tahoeSoftScrollEdges()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().opacity(0.28)

                bottomNavigationBar
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
            }
        }
        .frame(minWidth: 660, minHeight: 520)
        .onAppear {
            store.refreshAllPermissionStatuses()
            installedCompetitors = UniversalCompetitorImporter.detectInstalledCompetitorApps()
        }
    }

    private var windowBackdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [
                    TahoeUI.brandCobalt.opacity(colorScheme == .dark ? 0.16 : 0.08),
                    Color.clear
                ],
                center: .top,
                startRadius: 20,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - 顶部 5 步可跳转进度胶囊

    private var topStepperBar: some View {
        TahoeGlassContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(OnboardingWindowController.Step.allCases) { step in
                    let isActive = (step == viewModel.currentStep)
                    let isPassed = (step.rawValue < viewModel.currentStep.rawValue)
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                            viewModel.currentStep = step
                        }
                        TactileFeedbackEngine.shared.perform(.tabSwitch)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isPassed ? "checkmark.circle.fill" : step.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(
                                    isActive
                                        ? .white
                                        : (isPassed ? Color.green : .secondary)
                                )
                            Text(step.shortTitle)
                                .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(isActive ? .white : .primary.opacity(0.82))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(
                                isActive
                                    ? TahoeUI.brandCobalt
                                    : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Step 1: 欢迎与系统就绪检查

    private var step1WelcomeView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                BrandAppIconBadge(size: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 iClip")
                        .font(.system(size: 24, weight: .bold))
                    Text("macOS 原生液态玻璃剪贴板 · 零失焦秒贴、大爆炸精准选词、原生截屏与本地零信任护盾。")
                        .font(.system(size: 12.8))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                welcomePillarCard(
                    symbol: "bolt.horizontal.fill",
                    tint: TahoeUI.brandCobalt,
                    title: "零失焦直贴与大爆炸",
                    detail: "唤醒不打断当前打字框；空格预览原图，双击词块原位二次拆分。"
                )
                welcomePillarCard(
                    symbol: "lock.shield.fill",
                    tint: TahoeUI.brandMint,
                    title: "零信任本地加密护盾",
                    detail: "全库硬件加密零上传，投屏自动隐身，敏感凭据默认防肩窥遮罩。"
                )
                welcomePillarCard(
                    symbol: "camera.viewfinder",
                    tint: TahoeUI.brandIndigo,
                    title: "原生截屏与剪贴即待办",
                    detail: "\(store.screenshotHotKeyShortcut.displayString) 自动吸附窗口截屏并秒提文字，⌘T 顺手化作桌面待办。"
                )
            }

            // 权限就绪联动卡（直达独立权限弹窗，彻底无冲突）
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((grantedPermissionCount == 3 ? Color.green : Color.orange).opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: grantedPermissionCount == 3 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(grantedPermissionCount == 3 ? Color.green : Color.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(grantedPermissionCount == 3 ? "系统权限已全部就绪（3/3）" : "系统权限待补齐（当前 \(grantedPermissionCount)/3 项已就绪）")
                        .font(.system(size: 13, weight: .semibold))
                    Text(
                        grantedPermissionCount == 3
                            ? "一键直贴、微信/飞书高清原图与原生截屏均已解锁。"
                            : "可在独立权限中心一次开启辅助功能、完全磁盘访问与屏幕录制，不会打断当前引导进度。"
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if grantedPermissionCount < 3 {
                    Button("打开权限中心") {
                        AppWindowCoordinator.shared.presentPermissionSetup(
                            store: store,
                            continueToOnboardingOnComplete: true
                        )
                    }
                    .tahoeActionButtonStyle(prominent: true)
                    .controlSize(.small)
                }
            }
            .padding(14)
            .tahoeGlassCard(cornerRadius: 16, tint: grantedPermissionCount == 3 ? .green : .orange)
        }
    }

    private func welcomePillarCard(symbol: String, tint: Color, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.24 : 0.13))
                    .frame(width: 34, height: 34)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tahoeGlassCard(cornerRadius: 16)
    }

    // MARK: - Step 2: 物理键帽试按与专属唤醒手势

    private var step2HotKeyTrialView: some View {
        let caps = store.hotKeyShortcut.onboardingKeycaps
        let hit = viewModel.didHitTrialHotKey
        let modDown = viewModel.isTrialModifierDown || hit

        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("亲手试按一次，建立肌肉记忆")
                    .font(.system(size: 21, weight: .bold))
                Text("现在按下「\(store.hotKeyShortcut.displayString)」，感受键盘微震反馈；不习惯也可以下方直接录制专属手势。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            // 苹果物理键帽舞台
            VStack(spacing: 14) {
                HStack(spacing: 16) {
                    if !caps.leftSymbol.isEmpty {
                        physicalKeycap(
                            symbol: caps.leftSymbol,
                            label: caps.leftLabel,
                            pressed: modDown,
                            succeeded: hit
                        )
                        Image(systemName: caps.isDoubleTap ? "arrow.right" : "plus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    physicalKeycap(
                        symbol: caps.rightSymbol,
                        label: caps.rightLabel,
                        pressed: hit,
                        succeeded: hit
                    )
                }

                HStack(spacing: 6) {
                    Image(systemName: hit ? "checkmark.circle.fill" : "hand.point.up.left.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(hit ? Color.green : TahoeUI.brandCobalt)
                        .symbolEffect(.bounce, value: hit)
                    Text(hit ? "太顺手了！已记住你的唤醒手势「\(store.hotKeyShortcut.displayString)」" : "请直接按下键盘上的 \(store.hotKeyShortcut.displayString)（按住修饰键时键帽会实时下沉）")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(hit ? Color.green : .primary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal, 18)
            .tahoeGlassCard(cornerRadius: 18, tint: hit ? .green : TahoeUI.brandCobalt)

            // 内联自定义手势录制（走共享 HotKeyRecorderCoordinator，自动 5 层零冲突拦截）
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("想换回你原本顺手的唤醒手势？")
                            .font(.system(size: 13.5, weight: .semibold))
                        if let warning = recorder.conflictWarning {
                            Text(warning)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.red)
                        } else if let hint = recorder.recordingHint {
                            Text(hint)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(TahoeUI.brandCobalt)
                        } else {
                            Text("支持 ⇧⌘V 等组合键，或双击 ⌘ / ⌥ / ⌃ / ⇧ 单键，系统自动拦截冲突键位。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    let isRec = recorder.isRecording(slot: .mainToggle)
                    Button {
                        if isRec {
                            recorder.stopRecording()
                        } else {
                            viewModel.didHitTrialHotKey = false
                            recorder.startRecording(slot: .mainToggle, store: store)
                        }
                    } label: {
                        Text(isRec ? "等待按键（ESC 取消）" : "录制新热键 · \(store.hotKeyShortcut.displayString)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .tahoeActionButtonStyle(prominent: isRec)
                    .controlSize(.regular)
                }
            }
            .padding(14)
            .tahoeGlassCard(cornerRadius: 15)
        }
    }

    private func physicalKeycap(symbol: String, label: String, pressed: Bool, succeeded: Bool) -> some View {
        VStack(spacing: 4) {
            Text(symbol)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(succeeded ? .white : (pressed ? TahoeUI.brandCobalt : .primary))
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(succeeded ? .white.opacity(0.9) : .secondary)
        }
        .frame(width: 96, height: 82)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    succeeded
                        ? AnyShapeStyle(LinearGradient(colors: [Color.green, TahoeUI.brandMint], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    succeeded
                        ? Color.green.opacity(0.6)
                        : (pressed ? TahoeUI.brandCobalt : Color.primary.opacity(0.14)),
                    lineWidth: pressed ? 1.8 : 1.0
                )
        )
        .shadow(
            color: Color.black.opacity(pressed ? 0.08 : 0.16),
            radius: pressed ? 2 : 8,
            y: pressed ? 1 : 5
        )
        .offset(y: pressed ? 3 : 0)
        .scaleEffect(pressed ? 0.97 : 1.0)
        .animation(.interpolatingSpring(mass: 0.55, stiffness: 420, damping: 24), value: pressed)
    }

    // MARK: - Step 3: 单击 vs 双击键入手感

    private var step3ClickPasteFeelView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择最顺手的卡片键入手感")
                    .font(.system(size: 21, weight: .bold))
                Text("无论选哪一种，iClip 都已自动配好整套无冲突副手势，后续随时可在独立设置中切换。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                clickModeChoiceCard(
                    mode: .singleClick,
                    badge: "极速流 · 推荐",
                    headline: "单击直接粘贴",
                    bullets: [
                        "单击卡片：直接贴入目标光标",
                        "⌥ + 单击：仅复制到剪贴板不关闭",
                        "⇧ + 单击：去格式贴为纯文本",
                        "Space / 重按：全图预览与大爆炸"
                    ]
                )

                clickModeChoiceCard(
                    mode: .doubleClick,
                    badge: "稳健防误触",
                    headline: "双击直接粘贴",
                    bullets: [
                        "双击卡片：直接贴入目标光标",
                        "单击卡片：选中并静默复制",
                        "⇧ + 双击：去格式贴为纯文本",
                        "Space / 重按：全图预览与大爆炸"
                    ]
                )
            }

            HStack(spacing: 10) {
                Image(systemName: "keyboard.fill")
                    .foregroundStyle(TahoeUI.brandCobalt)
                Text("全键盘同样畅快：↑ / ↓ 选卡，↵ 直接键入，⌘1~9 瞬贴前 9 条，ESC 优雅收起。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tahoeGlassCard(cornerRadius: 13)
        }
    }

    private func clickModeChoiceCard(
        mode: CardClickPasteMode,
        badge: String,
        headline: String,
        bullets: [String]
    ) -> some View {
        let selected = (store.cardClickPasteMode == mode)
        return Button {
            store.cardClickPasteMode = mode
            TactileFeedbackEngine.shared.perform(.tabSwitch)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(selected ? .white : TahoeUI.brandCobalt)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(selected ? TahoeUI.brandCobalt : TahoeUI.brandCobalt.opacity(0.14)))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(selected ? TahoeUI.brandCobalt : .secondary.opacity(0.45))
                        .symbolEffect(.bounce, value: selected)
                }

                Text(headline)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(selected ? TahoeUI.brandCobalt : Color.secondary.opacity(0.45))
                                .frame(width: 4.5, height: 4.5)
                                .padding(.top, 5)
                            Text(bullet)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tahoeGlassCard(cornerRadius: 16, tint: selected ? TahoeUI.brandCobalt : nil, interactive: true)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? TahoeUI.brandCobalt : Color.clear, lineWidth: 1.6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 4: 零污染互动沙盒（边玩边学会核心绝技）

    private var step4InteractiveSandboxView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("动手试一试核心能力（沙盒演练）")
                        .font(.system(size: 21, weight: .bold))
                    Text("以下演示完全在内存中运行，绝不污染你的真实剪贴板历史。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker("沙盒体验项目", selection: $viewModel.sandboxTab) {
                ForEach(OnboardingWindowViewModel.SandboxTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch viewModel.sandboxTab {
                case .bigBang:
                    sandboxBigBangStage
                case .todoAndShield:
                    sandboxTodoAndShieldStage
                case .screenshotAndMinimal:
                    sandboxScreenshotAndMinimalStage
                }
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.85), value: viewModel.sandboxTab)
        }
    }

    private var sandboxBigBangStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("单击点选词块 · 双击任意复合词块（如网址或分辨率）体验原位二次爆炸", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TahoeUI.brandCobalt)
                Spacer()
                if !viewModel.sandboxUndoStack.isEmpty {
                    Button("撤销拆分") {
                        viewModel.undoSandboxExplosion()
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)
                }
                Button("重置") {
                    viewModel.resetSandboxBigBang()
                }
                .tahoeActionButtonStyle(prominent: false)
                .controlSize(.small)
            }

            SandboxFlowLayout(spacing: 8) {
                ForEach(viewModel.sandboxTokens) { token in
                    let isSelected = viewModel.sandboxSelectedTokenIDs.contains(token.id)
                    let canSplit = BigBangTokenizer.canSubdivide(token.text)
                    Text(token.text)
                        .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6.5)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    isSelected
                                        ? TahoeUI.brandCobalt
                                        : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isSelected
                                        ? TahoeUI.brandCobalt
                                        : (canSplit ? TahoeUI.brandCobalt.opacity(0.24) : Color.clear),
                                    lineWidth: 1
                                )
                        )
                        .onTapGesture(count: 2) {
                            _ = viewModel.explodeSandboxToken(token)
                        }
                        .onTapGesture(count: 1) {
                            viewModel.toggleSandboxTokenSelection(token.id)
                        }
                        .help(canSplit ? "单击选中，双击原位二次爆炸拆分" : "单击选中")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .tahoeGlassCard(cornerRadius: 16)

            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                Text(
                    viewModel.sandboxSelectedPreviewText.isEmpty
                        ? "点选上方任意词块，这里会实时拼接你打算提取的内容（真实面板中按 Space 即可对任意文本或图片呼出大爆炸）"
                        : "已精准提取：\(viewModel.sandboxSelectedPreviewText)"
                )
                .font(.system(size: 12, weight: viewModel.sandboxSelectedPreviewText.isEmpty ? .regular : .semibold))
                .foregroundStyle(viewModel.sandboxSelectedPreviewText.isEmpty ? .secondary : TahoeUI.brandCobalt)
                .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .tahoeGlassCard(cornerRadius: 12)

            HStack(spacing: 10) {
                sandboxHintChip(key: "双击 / X", detail: "原位继续拆细词块")
                sandboxHintChip(key: "⌘ Z", detail: "逐级无损撤销拆分")
                sandboxHintChip(key: "Space", detail: "面板内预览大图取词")
            }
        }
    }

    private func sandboxHintChip(key: String, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(TahoeUI.brandCobalt)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(TahoeUI.brandCobalt.opacity(0.12)))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tahoeGlassCard(cornerRadius: 11)
    }

    private var sandboxTodoAndShieldStage: some View {
        VStack(spacing: 12) {
            // 剪贴即待办演示卡
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        viewModel.sandboxTodoChecked.toggle()
                    }
                    TactileFeedbackEngine.shared.perform(.tabSwitch)
                } label: {
                    Image(systemName: viewModel.sandboxTodoChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(viewModel.sandboxTodoChecked ? Color.green : TahoeUI.brandCobalt)
                        .symbolEffect(.bounce, value: viewModel.sandboxTodoChecked)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text("周四 15:00 前把新版发布包同步到测试群")
                        .font(.system(size: 13.5, weight: .medium))
                        .strikethrough(viewModel.sandboxTodoChecked, color: .secondary)
                        .foregroundStyle(viewModel.sandboxTodoChecked ? .secondary : .primary)
                    Text("真实面板中选中任意剪贴按 ⌘T 即可秒转待办，按 ⌘↵ 一边粘贴一边勾选完成")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(viewModel.sandboxTodoChecked ? "已完成" : "待办中")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(viewModel.sandboxTodoChecked ? Color.green : TahoeUI.brandCobalt)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((viewModel.sandboxTodoChecked ? Color.green : TahoeUI.brandCobalt).opacity(0.14)))
            }
            .padding(14)
            .tahoeGlassCard(cornerRadius: 15)

            // 敏感凭据护盾演示卡
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: viewModel.sandboxSecretRedacted ? "lock.shield.fill" : "eye.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(viewModel.sandboxSecretRedacted ? Color.green : Color.orange)
                        .contentTransition(.symbolEffect(.replace))
                }

                VStack(alignment: .leading, spacing: 2.5) {
                    Text(
                        viewModel.sandboxSecretRedacted
                            ? "API_KEY=sk-live-••••••••••••7d2c（已防肩窥脱敏）"
                            : "API_KEY=sk-live-9f8a4c21e0ab7d2c（原始明文）"
                    )
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    Text("复制密钥 / 手机号 / Token 时默认圆点防肩窥；粘贴给 AI 时自动替身脱敏，按 ⌥↵ 可随时贴出原文明文。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(viewModel.sandboxSecretRedacted ? "模拟 ⌥↵ 看明文" : "恢复护盾遮罩") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        viewModel.sandboxSecretRedacted.toggle()
                    }
                    TactileFeedbackEngine.shared.perform(.tabSwitch)
                }
                .tahoeActionButtonStyle(prominent: false)
                .controlSize(.small)
            }
            .padding(14)
            .tahoeGlassCard(cornerRadius: 15, tint: viewModel.sandboxSecretRedacted ? .green : .orange)
        }
    }

    private var sandboxScreenshotAndMinimalStage: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TahoeUI.brandMint)
                    Text("原生截屏（\(store.screenshotHotKeyShortcut.displayString)）")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                }
                Text("基于 ScreenCaptureKit 零闪烁抓帧：自动吸附任意桌面窗口、支持标注与一键 AI 隐私打码、直接大爆炸提取图中文字，按住 ⌘ 松手瞬间复制进历史。")
                    .font(.system(size: 11.8))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !store.isScreenRecordingGranted {
                    Button("前往开启屏幕录制权限") {
                        AppWindowCoordinator.shared.presentPermissionSetup(
                            store: store,
                            highlight: .screenRecording,
                            continueToOnboardingOnComplete: true
                        )
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)
                } else {
                    Label("屏幕录制权限已就绪，随时按 \(store.screenshotHotKeyShortcut.displayString) 体验", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .tahoeGlassCard(cornerRadius: 16)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.green)
                    Text("极简纯净模式（⌘E）")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Toggle("", isOn: $viewModel.sandboxMinimalPreview)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                Text(
                    viewModel.sandboxMinimalPreview
                        ? "已切换模拟极简态：隐藏待办、微星标与财务助手，仅保留纯粹、极速的复制与粘贴历史。"
                        : "喜欢返璞归真？随时按 ⌘E 一键收起全部智能辅助，还原最轻盈的纯剪贴板体验，零功能打扰。"
                )
                .font(.system(size: 11.8))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(viewModel.sandboxMinimalPreview ? "模拟预览：极简纯净态" : "模拟预览：完整智能态")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(viewModel.sandboxMinimalPreview ? Color.green : TahoeUI.brandCobalt)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill((viewModel.sandboxMinimalPreview ? Color.green : TahoeUI.brandCobalt).opacity(0.14)))
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .tahoeGlassCard(cornerRadius: 16, tint: viewModel.sandboxMinimalPreview ? .green : nil)
        }
    }

    // MARK: - Step 5: 跨工具一键搬家 & 启程偏好

    private var step5MigrateAndFinishView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("一切就绪，准备启程")
                    .font(.system(size: 21, weight: .bold))
                Text("如你之前用过其他剪贴板工具，可直接一键迁入并自动分类；也可按需微调开机常驻偏好。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            // 竞品无缝搬家卡
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TahoeUI.brandCobalt)
                    Text("从其他剪贴板无缝迁入（可选）")
                        .font(.system(size: 14, weight: .semibold))
                }

                let names = installedCompetitors.map(\.name)
                Text(
                    names.isEmpty
                        ? "兼容 .iclip、Paste、Maccy、Raycast、Alfred (.alfredsnippets)、Clipy、CopyQ、Ditto 及 CSV / JSON / Markdown，导入后自动归入链接、待办、文件与收藏。"
                        : "检测到本机已安装：\(names.joined(separator: " / "))。导入后将自动归入链接、待办、文件与收藏对应分组。"
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if installedCompetitors.contains(where: { $0.id == "maccy" && $0.supportsDirectLocalRead }) {
                        Button {
                            ClipboardSettingsDialogHelper.importFromLocalMaccy(store: store) { msg in
                                viewModel.lastImportFeedback = msg
                            }
                        } label: {
                            Label("一键直读 Maccy", systemImage: "bolt.fill")
                        }
                        .tahoeActionButtonStyle(prominent: true)
                        .controlSize(.regular)
                    }

                    Button {
                        ClipboardSettingsDialogHelper.importArchiveOrCompetitorFile(
                            store: store,
                            onFeedback: { msg in
                                viewModel.lastImportFeedback = msg
                            }
                        )
                    } label: {
                        Label("选择导出文件导入...", systemImage: "folder.badge.plus")
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.regular)
                }

                if let feedback = viewModel.lastImportFeedback {
                    Text(feedback)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
            .padding(16)
            .tahoeGlassCard(cornerRadius: 16)

            // 常用启程开关
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开机自动启动")
                            .font(.system(size: 13.5, weight: .medium))
                        Text("登录 macOS 后自动在顶部菜单栏轻盈待命")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.launchAtLoginEnabled },
                        set: { store.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().opacity(0.3).padding(.horizontal, 16)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示桌面悬浮精灵小球")
                            .font(.system(size: 13.5, weight: .medium))
                        Text("贴边悬浮的液态光球，轻点呼出剪贴板或待办，随时可在菜单栏开关")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $store.spriteOrbEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .tahoeGlassCard(cornerRadius: 16)
        }
    }

    // MARK: - 底部翻页控制栏

    private var bottomNavigationBar: some View {
        TahoeGlassContainer(spacing: 10) {
            HStack {
                if viewModel.currentStep != .welcomeAndReadiness {
                    Button {
                        if let prev = OnboardingWindowController.Step(rawValue: viewModel.currentStep.rawValue - 1) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                viewModel.currentStep = prev
                            }
                            TactileFeedbackEngine.shared.perform(.tabSwitch)
                        }
                    } label: {
                        Label("上一步", systemImage: "chevron.left")
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.large)
                } else {
                    Button("跳过引导") {
                        onFinish(true)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if let next = OnboardingWindowController.Step(rawValue: viewModel.currentStep.rawValue + 1) {
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                            viewModel.currentStep = next
                        }
                        TactileFeedbackEngine.shared.perform(.tabSwitch)
                    } label: {
                        HStack(spacing: 5) {
                            Text("下一步：\(next.shortTitle)")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 4)
                    }
                    .tahoeActionButtonStyle(prominent: true)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        TactileFeedbackEngine.shared.perform(.pasteCommit)
                        onFinish(true)
                    } label: {
                        HStack(spacing: 6) {
                            Text("开始使用 iClip")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                    }
                    .tahoeActionButtonStyle(prominent: true)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// 沙盒专用轻盈流式布局（不依赖外部视图私有类型，零耦合）
private struct SandboxFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 560
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
