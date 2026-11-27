import SwiftUI
import AppKit

/// 新手与新功能引导条目模型（供设置页「查看核心亮点」复盘）
struct HighlightFeatureItem: Identifiable, Equatable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
}

/// 首次上手直觉三步流与核心亮点控制器：
/// 1. 肌肉记忆初体验：先让用户亲手试按一次预设 `⌥V`（实时键帽物理下沉与声学触感反馈）；
/// 2. 直觉手势抉择：选择继续使用 `⌥V`，或切换为自己习惯的呼出手势（组合键 / 双击单键）；
/// 3. 顺势无缝搬家：若用户选择设为自己的习惯手势，顺势引导从其习惯的剪贴板工具（Maccy / Paste / Raycast / Alfred / CopyQ / Ditto 等）一键导入并自动归入对应类目。
@MainActor
final class InteractivePlaygroundController: ObservableObject {
    static let shared = InteractivePlaygroundController()

    enum OnboardingPhase: Equatable {
        /// 第 1 步：亲手试按预设 `⌥V`
        case tryDefaultHotKey
        /// 第 2 步：选择沿用 `⌥V` 还是自定义习惯手势
        case chooseGestureHabit
        /// 第 3 步（可选）：原位录制专属手势 + 顺势从原剪贴板工具分类导入
        case customizeAndImport
        /// 第 4 步：选择默认卡片键入方式（单击 vs 双击，零冲突配套）
        case chooseClickMode
        /// 第 5 步：辅助功能 + 完全磁盘访问可拖入式权限引导
        case permissionsSetup
        /// 从菜单栏或设置页主动查看核心功能亮点
        case featureHighlights
    }

    static let coreHighlights: [HighlightFeatureItem] = [
        HighlightFeatureItem(
            id: "zero-blur-paste",
            symbol: "bolt.horizontal.fill",
            tint: Color(red: 0.12, green: 0.37, blue: 1.0),
            title: "唤醒零失焦直贴与大爆炸选字",
            detail: "不打断当前输入框，支持 Space 全图预览原图、原位大爆炸选字与文本炸词。"
        ),
        HighlightFeatureItem(
            id: "zero-trust-shield",
            symbol: "lock.shield.fill",
            tint: Color(red: 0.08, green: 0.62, blue: 0.45),
            title: "零信任隐私护盾",
            detail: "全库硬件加密与投屏自动隐身，密钥默认圆点遮罩，⇧↵ 一键 AI 替身脱敏。"
        ),
        HighlightFeatureItem(
            id: "todo-clean-text",
            symbol: "checklist.checked",
            tint: Color(red: 0.22, green: 0.48, blue: 0.96),
            title: "剪贴即待办与全能直算",
            detail: "⌘T 转待办；搜索框秒算含税、日薪与 AA 分摊；微信与飞书图片高清直显。"
        ),
        HighlightFeatureItem(
            id: "drag-and-minimal",
            symbol: "hand.tap.fill",
            tint: Color(red: 0.16, green: 0.56, blue: 0.52),
            title: "双皮肤质感与极简开关",
            detail: "默认原生苹果轻盈卡片，支持设置页丝滑切换立体光影皮肤，按 ⌘E 秒切极简纯净模式。"
        )
    ]

    private let seenOnboardingKey = "hasCompletedIntuitiveOnboarding_v30"
    private let legacySampleHashesKey = "playgroundSampleContentHashes"

    @Published var isActive: Bool = false
    @Published var phase: OnboardingPhase = .tryDefaultHotKey
    @Published var didHitTrialHotKey: Bool = false
    @Published var isOptionModifierDown: Bool = false
    @Published var lastImportFeedback: String? = nil
    @Published private(set) var cameFromCustomizeStep: Bool = false

    private var flagsMonitor: Any?

    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: seenOnboardingKey)
    }

    func markOnboardingCompleted(in store: ClipboardStore? = nil) {
        stopModifierTracking()
        cameFromCustomizeStep = false
        if let store {
            cleanupLegacySamplesIfAny(in: store)
        }
        UserDefaults.standard.set(true, forKey: seenOnboardingKey)
        if isActive {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.90)) {
                isActive = false
            }
        }
    }

    private init() {
        let ud = UserDefaults.standard
        let completed = ud.bool(forKey: seenOnboardingKey)
        let isReturningUser = ud.bool(forKey: "hasSeenPlaygroundOnboarding_v27")
            || ud.bool(forKey: "hasSeenCoreHighlights_v27")
            || ud.bool(forKey: "hasConfirmedRoleEdition")
            || ud.data(forKey: "hotKeyShortcut") != nil
            || ud.string(forKey: "cardClickPasteMode") != nil
        if isReturningUser && !completed {
            ud.set(true, forKey: seenOnboardingKey)
        }
    }

    /// 当处于第 1 步试按阶段时，拦截全局快捷键 `⌥V` 触发键帽物理触底反馈并丝滑推进第 2 步
    func consumeHotKeyTrialIfNeeded() -> Bool {
        guard isActive, phase == .tryDefaultHotKey else { return false }
        guard !didHitTrialHotKey else { return true }
        didHitTrialHotKey = true
        TactileFeedbackEngine.shared.perform(.onboardingKeyHit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            guard let self, self.isActive, self.phase == .tryDefaultHotKey else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                self.phase = .chooseGestureHabit
            }
            self.stopModifierTracking()
        }
        return true
    }

    func advanceFromTrialManually() {
        TactileFeedbackEngine.shared.perform(.tabSwitch)
        stopModifierTracking()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            phase = .chooseGestureHabit
        }
    }

    func advanceFromGestureChoice() {
        TactileFeedbackEngine.shared.perform(.tabSwitch)
        stopModifierTracking()
        cameFromCustomizeStep = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            phase = .chooseClickMode
        }
    }

    func enterCustomizeAndImport() {
        TactileFeedbackEngine.shared.perform(.tabSwitch)
        stopModifierTracking()
        lastImportFeedback = nil
        cameFromCustomizeStep = true
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            phase = .customizeAndImport
        }
    }

    func advanceFromCustomizeToClickMode() {
        TactileFeedbackEngine.shared.perform(.tabSwitch)
        stopModifierTracking()
        cameFromCustomizeStep = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            phase = .chooseClickMode
        }
    }

    func completeClickModeSelection(in store: ClipboardStore) {
        store.refreshAccessibilityStatus()
        store.refreshFullDiskAccessStatus()
        if store.isAccessibilityGranted && store.isFullDiskAccessGranted {
            TactileFeedbackEngine.shared.perform(.pasteCommit)
            dismiss(in: store)
            return
        }
        TactileFeedbackEngine.shared.perform(.tabSwitch)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            phase = .permissionsSetup
        }
    }

    func showPermissionGuidance() {
        didHitTrialHotKey = false
        lastImportFeedback = nil
        stopModifierTracking()
        if NSClassFromString("XCTestCase") == nil {
            AppWindowCoordinator.shared.presentPermissionSetup(store: ClipboardStore.shared)
            return
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            phase = .permissionsSetup
            isActive = true
        }
    }

    /// 供设置页或菜单栏右键主动唤出引导（提供重温快捷键体验与核心亮点入口）
    func showHighlights() {
        didHitTrialHotKey = false
        lastImportFeedback = nil
        let completed = UserDefaults.standard.bool(forKey: seenOnboardingKey)
        phase = completed ? .featureHighlights : .tryDefaultHotKey
        if phase == .tryDefaultHotKey {
            startModifierTrackingIfNeeded()
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            isActive = true
        }
    }

    func restartInteractiveSetup() {
        didHitTrialHotKey = false
        lastImportFeedback = nil
        cameFromCustomizeStep = false
        startModifierTrackingIfNeeded()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
            phase = .tryDefaultHotKey
            isActive = true
        }
    }

    func dismiss(in store: ClipboardStore? = nil) {
        stopModifierTracking()
        cameFromCustomizeStep = false
        if let store {
            cleanupLegacySamplesIfAny(in: store)
        }
        UserDefaults.standard.set(true, forKey: seenOnboardingKey)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.90)) {
            isActive = false
        }
    }

    func cleanupLegacySamplesIfAny(in store: ClipboardStore) {
        let hashes = Set(UserDefaults.standard.stringArray(forKey: legacySampleHashesKey) ?? [])
        for item in store.items {
            if hashes.contains(item.contentHash) || (item.sourceAppName?.hasPrefix("游乐场示例") == true) {
                store.delete(item)
            }
        }
        UserDefaults.standard.removeObject(forKey: legacySampleHashesKey)
    }

    /// 接收来自本地监听器或非激活 CGEventTap 转发的修饰键状态，实时驱动键帽物理下沉动画
    func updateModifierFlags(_ flags: NSEvent.ModifierFlags) {
        guard isActive, phase == .tryDefaultHotKey else { return }
        let modPressed = ClipboardStore.shared.hotKeyShortcut.matchesTrialModifierPressed(in: flags)
        if isOptionModifierDown != modPressed {
            withAnimation(.interpolatingSpring(mass: 0.55, stiffness: 420, damping: 24)) {
                isOptionModifierDown = modPressed
            }
        }
    }

    private func startModifierTrackingIfNeeded() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.updateModifierFlags(event.modifierFlags)
            } else if event.type == .keyDown,
                      self.phase == .tryDefaultHotKey,
                      ClipboardStore.shared.hotKeyShortcut.matchesLocalKeyDown(
                          keyCode: event.keyCode,
                          flags: event.modifierFlags
                      ) {
                _ = self.consumeHotKeyTrialIfNeeded()
                return nil
            }
            return event
        }
    }

    private func stopModifierTracking() {
        isOptionModifierDown = false
        if let m = flagsMonitor {
            NSEvent.removeMonitor(m)
            flagsMonitor = nil
        }
    }
}

/// 苹果原厂 Setup Assistant 级物理直觉引导与跨软件搬家浮层
struct CoreHighlightsOverlay: View {
    @ObservedObject var controller: InteractivePlaygroundController
    @ObservedObject var store: ClipboardStore
    var onStartHotKeyRecording: (() -> Void)? = nil
    var onStopHotKeyRecording: (() -> Void)? = nil
    var isRecordingHotKey: Bool = false
    var hotKeyConflictWarning: String? = nil
    var hotKeyRecordingHint: String? = nil
    var onOpenFileImportPanel: (() -> Void)? = nil
    let glassPalette: LiquidGlassPalette

    @Environment(\.colorScheme) private var colorScheme
    @State private var installedCompetitors: [UniversalCompetitorImporter.InstalledCompetitorApp] = []

    private var brandCobalt: Color { Color(red: 0.118, green: 0.369, blue: 1.0) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.58 : 0.26))
                .onTapGesture {
                    if controller.phase == .featureHighlights {
                        controller.dismiss(in: store)
                    }
                }

            VStack(alignment: .leading, spacing: 16) {
                switch controller.phase {
                case .tryDefaultHotKey:
                    step1TryHotKeyView
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))

                case .chooseGestureHabit:
                    step2ChooseHabitView
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))

                case .customizeAndImport:
                    step3CustomizeAndImportView
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))

                case .chooseClickMode:
                    step4ChooseClickModeView
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))

                case .permissionsSetup:
                    step5PermissionsSetupView
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.96))
                        ))

                case .featureHighlights:
                    featureHighlightsView
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .padding(20)
            .frame(width: controller.phase == .chooseClickMode || controller.phase == .permissionsSetup ? 388 : 372)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.45), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.20), radius: 26, y: 12)
            )
        }
        .onAppear {
            installedCompetitors = UniversalCompetitorImporter.detectInstalledCompetitorApps()
            if controller.phase == .permissionsSetup {
                store.refreshAccessibilityStatus()
                store.refreshFullDiskAccessStatus()
            }
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            if controller.isActive && controller.phase == .permissionsSetup {
                store.refreshAccessibilityStatus()
                store.refreshFullDiskAccessStatus()
            }
        }
        .onDisappear {
            if isRecordingHotKey {
                onStopHotKeyRecording?()
            }
        }
    }

    // MARK: - Step 1：先试按一次预设 ⌥V

    private var step1TryHotKeyView: some View {
        let caps = store.hotKeyShortcut.onboardingKeycaps
        let isDefaultHotKey = (store.hotKeyShortcut == .defaultShortcut)
        let promptText: String = {
            if caps.isDoubleTap {
                return controller.isOptionModifierDown
                    ? "轻按已感知，迅速松手再按第 2 下！"
                    : "现在直接在键盘上连续轻按两次 \(caps.leftSymbol)"
            }
            if caps.leftSymbol.isEmpty {
                return "现在直接在键盘上按一下 \(caps.rightSymbol) 键"
            }
            return controller.isOptionModifierDown
                ? "已按住修饰键，再按一下 \(caps.rightSymbol)！"
                : "现在直接在键盘上按一次 \(store.hotKeyShortcut.compactDisplayString)"
        }()

        return VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("先试试呼出它的手感")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("按下\(isDefaultHotKey ? "预设" : "当前")的 \(store.hotKeyShortcut.compactDisplayString)，随时在光标旁零失焦唤出")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                BrandAppIconBadge(size: 32)
            }

            // 物理行程动态键帽舞台（兼容组合键、双击单键与单功能键）
            HStack(spacing: 12) {
                if caps.leftSymbol.isEmpty {
                    physicalKeycap(
                        symbol: caps.rightSymbol,
                        label: caps.rightLabel,
                        isPressed: controller.didHitTrialHotKey,
                        isSuccess: controller.didHitTrialHotKey
                    )
                } else {
                    physicalKeycap(
                        symbol: caps.leftSymbol,
                        label: caps.leftLabel,
                        isPressed: controller.isOptionModifierDown || controller.didHitTrialHotKey,
                        isSuccess: controller.didHitTrialHotKey
                    )

                    Text(caps.isDoubleTap ? "→" : "+")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.65))

                    physicalKeycap(
                        symbol: caps.rightSymbol,
                        label: caps.rightLabel,
                        isPressed: controller.didHitTrialHotKey,
                        isSuccess: controller.didHitTrialHotKey
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        controller.didHitTrialHotKey
                            ? Color.green.opacity(colorScheme == .dark ? 0.16 : 0.10)
                            : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        controller.didHitTrialHotKey
                            ? Color.green.opacity(0.55)
                            : (controller.isOptionModifierDown ? brandCobalt.opacity(0.45) : Color.primary.opacity(0.08)),
                        lineWidth: 1.0
                    )
            )

            HStack {
                if controller.didHitTrialHotKey {
                    Label("手感已激活，正在进入下一步...", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.green)
                } else {
                    Text(promptText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(controller.isOptionModifierDown ? brandCobalt : .secondary)
                }
                Spacer()
                Button("跳过试按 →") {
                    controller.advanceFromTrialManually()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func physicalKeycap(symbol: String, label: String, isPressed: Bool, isSuccess: Bool) -> some View {
        VStack(spacing: 3) {
            Text(symbol)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .foregroundStyle(isSuccess ? Color.green : (isPressed ? brandCobalt : .primary))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSuccess ? Color.green.opacity(0.9) : .secondary)
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 82)
        .frame(height: 64)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color(white: isPressed ? 0.20 : 0.24)
                        : Color.white
                )
                .shadow(
                    color: Color.black.opacity(isPressed ? 0.06 : 0.16),
                    radius: isPressed ? 1.5 : 4,
                    y: isPressed ? 1 : 4
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    isSuccess
                        ? Color.green.opacity(0.7)
                        : (isPressed ? brandCobalt.opacity(0.65) : Color.primary.opacity(0.14)),
                    lineWidth: isPressed ? 1.4 : 0.9
                )
        )
        .offset(y: isPressed ? 2.5 : 0)
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(.interpolatingSpring(mass: 0.55, stiffness: 440, damping: 24), value: isPressed)
    }

    // MARK: - Step 2：选择继续用 ⌥V 还是设为自己的习惯手势

    private var step2ChooseHabitView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("喜欢 \(store.hotKeyShortcut.compactDisplayString) 这个呼出手势吗？")
                        .font(.system(size: 18.5, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("呼出时不会打断你正在输入的文本框，按 ↵ 即可顺手贴入。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("上一步") {
                    controller.restartInteractiveSetup()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 9) {
                Button {
                    controller.advanceFromGestureChoice()
                } label: {
                    HStack(spacing: 11) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.22))
                                .frame(width: 34, height: 34)
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("很顺手，继续使用 \(store.hotKeyShortcut.compactDisplayString)")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("推荐 · 单手大拇指与食指自然落位，零冲突")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.84))
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(brandCobalt)
                            .shadow(color: brandCobalt.opacity(0.32), radius: 8, y: 3)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    controller.enterCustomizeAndImport()
                    onStartHotKeyRecording?()
                } label: {
                    HStack(spacing: 11) {
                        ZStack {
                            Circle()
                                .fill(brandCobalt.opacity(0.12))
                                .frame(width: 34, height: 34)
                            Image(systemName: "command.square.fill")
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(brandCobalt)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("设为我习惯的呼出手势")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text("支持 ⇧⌘V 等组合键，或双击 ⌘ / ⌥ / ⌃ 单键，并可导入旧数据")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.8)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Step 3：录制习惯手势 + 顺势从常用剪贴板导入并匹配对应类目

    private var step3CustomizeAndImportView: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("定制手势与旧剪贴板搬家")
                    .font(.system(size: 17.5, weight: .bold))
                Spacer()
                Button("上一步") {
                    if isRecordingHotKey {
                        onStopHotKeyRecording?()
                    }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        controller.phase = .chooseGestureHabit
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }

            // 1. 专属快捷键原位录制卡
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("呼出手势")
                            .font(.system(size: 12.5, weight: .semibold))
                        if let conflict = hotKeyConflictWarning {
                            Text(conflict)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        } else if let hint = hotKeyRecordingHint {
                            Text(hint)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(brandCobalt)
                        } else {
                            Text(isRecordingHotKey ? "请直接按下组合键，或连按两次 ⌘/⌥/⌃/⇧" : "已就绪 · 点击右侧胶囊可重新录制")
                                .font(.system(size: 11))
                                .foregroundStyle(isRecordingHotKey ? brandCobalt : .secondary)
                        }
                    }
                    Spacer()
                    Button {
                        if isRecordingHotKey {
                            onStopHotKeyRecording?()
                        } else {
                            onStartHotKeyRecording?()
                        }
                    } label: {
                        Text(isRecordingHotKey ? "等待按键..." : store.hotKeyShortcut.displayString)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(isRecordingHotKey ? .white : brandCobalt)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5.5)
                            .background(
                                Capsule()
                                    .fill(isRecordingHotKey ? brandCobalt : brandCobalt.opacity(0.13))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isRecordingHotKey ? brandCobalt.opacity(0.6) : Color.primary.opacity(0.09), lineWidth: 0.9)
            )

            // 2. 顺势提醒：从习惯的剪贴板应用导入数据并自动归入对应类目
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(brandCobalt)
                    Text("有正在用的剪贴板？一键搬入并自动分类")
                        .font(.system(size: 12.5, weight: .semibold))
                }

                let detectedNames = installedCompetitors.map(\.name)
                Text(
                    detectedNames.isEmpty
                        ? "兼容 Paste、Maccy、Raycast、Alfred (.alfredsnippets)、Clipy、CopyQ、Ditto 及 CSV/JSON/Markdown，自动归入链接、待办、文件与收藏类目。"
                        : "已识别本机 \(detectedNames.joined(separator: " / ")) · 导入内容将自动匹配至链接、待办、文件与收藏对应分组。"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if installedCompetitors.contains(where: { $0.id == "maccy" && $0.supportsDirectLocalRead }) {
                        Button {
                            if isRecordingHotKey { onStopHotKeyRecording?() }
                            importFromLocalMaccy()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10))
                                Text("一键直读 Maccy")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(brandCobalt)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(brandCobalt.opacity(0.13))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        if isRecordingHotKey { onStopHotKeyRecording?() }
                        onOpenFileImportPanel?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("选择剪贴板导出文件导入...")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let feedback = controller.lastImportFeedback {
                    Text(feedback)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.green)
                        .lineLimit(2)
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )

            Button {
                if isRecordingHotKey {
                    onStopHotKeyRecording?()
                }
                controller.advanceFromCustomizeToClickMode()
            } label: {
                Text("下一步：选择键入方式")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9.5)
                    .background(Capsule().fill(brandCobalt))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    // MARK: - Step 4：选择默认键入方式（单击 vs 双击，零冲突配套手势）

    private var step4ChooseClickModeView: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("选择最顺手的卡片键入方式")
                        .font(.system(size: 17.5, weight: .bold))
                    Text("已自动配好整套无冲突副手势，随时可在设置中切换。")
                        .font(.system(size: 11.2))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("上一步") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        controller.phase = controller.cameFromCustomizeStep ? .customizeAndImport : .chooseGestureHabit
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                clickModeOptionCard(
                    mode: .singleClick,
                    badge: "极速高效",
                    headline: "单击直接粘贴",
                    bullets: [
                        "单击卡片：直接粘贴上屏",
                        "按住 ⌥ 单击：仅复制不关闭",
                        "Space / 重按：大爆炸与预览"
                    ]
                )

                clickModeOptionCard(
                    mode: .doubleClick,
                    badge: "稳健防误触",
                    headline: "双击直接粘贴",
                    bullets: [
                        "双击卡片：直接粘贴上屏",
                        "单击卡片：选中并静默复制",
                        "Space / 重按：大爆炸与预览"
                    ]
                )
            }

            Button {
                controller.completeClickModeSelection(in: store)
            } label: {
                Text("下一步")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9.5)
                    .background(Capsule().fill(brandCobalt))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private func clickModeOptionCard(
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
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(badge)
                        .font(.system(size: 9.8, weight: .semibold))
                        .foregroundStyle(selected ? .white : brandCobalt)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(selected ? brandCobalt : brandCobalt.opacity(0.14)))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? brandCobalt : .secondary.opacity(0.45))
                }

                Text(headline)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(bullets, id: \.self) { line in
                        Text("· \(line)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? brandCobalt.opacity(colorScheme == .dark ? 0.16 : 0.08) : Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? brandCobalt : Color.primary.opacity(0.10), lineWidth: selected ? 1.5 : 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 5：到位的系统权限授权引导（可拖入实体徽章 + 更新自动复用）

    private var step5PermissionsSetupView: some View {
        let allGranted = store.isAccessibilityGranted && store.isFullDiskAccessGranted
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("开启系统权限，获取更完整体验")
                    .font(.system(size: 17.5, weight: .bold))
                Text("一次授权，后续版本更新自动复用，无需重新配置。")
                    .font(.system(size: 11.2))
                    .foregroundStyle(.secondary)
            }

            // 1. 辅助功能权限
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("辅助功能")
                            .font(.system(size: 13, weight: .semibold))
                        permissionStatusPill(granted: store.isAccessibilityGranted, grantedLabel: "已就绪", pendingLabel: "待开启")
                    }
                    Text("开启后可从\(store.cardClickPasteMode == .singleClick ? "单击" : "双击")或 ↵ 直接贴入当前光标框")
                        .font(.system(size: 10.8))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !store.isAccessibilityGranted {
                    Button("前往开启") {
                        store.requestAccessibilityPermission()
                        store.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(store.isAccessibilityGranted ? Color.green.opacity(0.42) : Color.primary.opacity(0.08), lineWidth: 0.85)
            )

            // 2. 完全磁盘访问（支持直接拖入系统设置列表，获取更完整的跨应用与本地资源体验）
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("完全磁盘访问")
                        .font(.system(size: 13, weight: .semibold))
                    permissionStatusPill(granted: store.isFullDiskAccessGranted, grantedLabel: "已就绪", pendingLabel: "推荐开启")
                    Spacer()
                    if !store.isFullDiskAccessGranted {
                        Button("打开系统设置") {
                            store.openFullDiskAccessSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                Text(
                    store.isFullDiskAccessGranted
                        ? "已获取完整访问权限，可顺畅读取跨应用缓存图片与本地资源。"
                        : "macOS 不会自动将应用加入此列表：按住下方图标直接拖入「完全磁盘访问权限」列表，或点列表左下角 + 号选取应用程序中的 iClip。"
                )
                .font(.system(size: 10.8))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if !store.isFullDiskAccessGranted {
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(nsImage: NSApp.applicationIconImage)
                                .resizable()
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("iClip.app")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text("按住我，直接拖进右侧权限列表")
                                    .font(.system(size: 10))
                                    .foregroundStyle(brandCobalt)
                            }
                            Spacer()
                            Image(systemName: "hand.draw.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(brandCobalt)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(brandCobalt.opacity(colorScheme == .dark ? 0.14 : 0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(brandCobalt.opacity(0.65), style: StrokeStyle(lineWidth: 1.1, dash: [4, 3]))
                        )
                        .onDrag {
                            NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                        }

                        Button("访达定位") {
                            store.revealAppInFinder()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                    }
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(store.isFullDiskAccessGranted ? Color.green.opacity(0.42) : Color.primary.opacity(0.08), lineWidth: 0.85)
            )

            HStack(spacing: 8) {
                Button {
                    controller.dismiss(in: store)
                } label: {
                    Text("暂不开启，先使用")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)

                Button {
                    TactileFeedbackEngine.shared.perform(.pasteCommit)
                    controller.dismiss(in: store)
                } label: {
                    Text(allGranted ? "权限全部就绪，开始使用" : "完成设置，开始使用")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(allGranted ? Color.green : brandCobalt))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
    }

    private func permissionStatusPill(granted: Bool, grantedLabel: String, pendingLabel: String) -> some View {
        Text(granted ? grantedLabel : pendingLabel)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(granted ? Color.green : brandCobalt)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill((granted ? Color.green : brandCobalt).opacity(0.14))
            )
    }

    private func importFromLocalMaccy() {
        Task.detached(priority: .userInitiated) {
            let parsed = UniversalCompetitorImporter.readLocalMaccyDatabaseCandidates()
            await MainActor.run {
                guard let parsed else {
                    store.showToast("开启完全磁盘访问或导出 Maccy 文件后即可一键导入", duration: 2.8)
                    return
                }
                let summary = store.mergeExternalCompetitorEntries(parsed.entries, formatLabel: parsed.formatName)
                let breakdown = summary.categoryBreakdown.map { "（\($0)）" } ?? ""
                let msg = "✓ 已从 Maccy 导入 \(summary.importedNewCount) 条新记录\(breakdown)"
                controller.lastImportFeedback = msg
                TactileFeedbackEngine.shared.perform(.favoriteOn)
            }
        }
    }

    // MARK: - 核心亮点复盘视图（从设置页/菜单栏打开时呈现，附「手势、键入方式与权限引导」入口）

    private var featureHighlightsView: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("iClip 核心体验亮点")
                        .font(.system(size: 18.5, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("轻如无物，物理直觉 · 按 ↵ 继续使用")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                BrandAppIconBadge(size: 30)
            }

            VStack(alignment: .leading, spacing: 11.5) {
                ForEach(InteractivePlaygroundController.coreHighlights) { item in
                    HStack(alignment: .top, spacing: 11) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(item.tint.opacity(colorScheme == .dark ? 0.22 : 0.13))
                                .frame(width: 31, height: 31)
                            Image(systemName: item.symbol)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(item.tint)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12.8, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(item.detail)
                                .font(.system(size: 11.2))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    controller.restartInteractiveSetup()
                } label: {
                    Text("重温手势、键入与权限")
                        .font(.system(size: 12.2, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8.5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Button {
                    controller.dismiss(in: store)
                } label: {
                    Text("继续使用")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8.5)
                        .background(Capsule().fill(brandCobalt))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
    }
}

/// 面板右下角极轻量拖拽缩放角标（纯视觉提示，不拦截点击/拖动）
struct PanelCornerResizeGripIndicator: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 9, y: 2))
            path.addLine(to: CGPoint(x: 2, y: 9))
            path.move(to: CGPoint(x: 9, y: 6))
            path.addLine(to: CGPoint(x: 6, y: 9))
        }
        .stroke(Color.secondary.opacity(0.32), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        .frame(width: 11, height: 11)
    }
}

/// 强制系统权限门禁遮罩：未开启全部 3 项核心权限前阻止进入主功能，内置签名一致性与同名旧应用冲突自检与一键清理工具
struct MandatoryPermissionGateView: View {
    @ObservedObject var store: ClipboardStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var copiedCommand: Bool = false

    private var brandCobalt: Color { Color(red: 0.118, green: 0.369, blue: 1.0) }

    private var grantedCount: Int {
        (store.isAccessibilityGranted ? 1 : 0)
            + (store.isFullDiskAccessGranted ? 1 : 0)
            + (store.isScreenRecordingGranted ? 1 : 0)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Color.black.opacity(colorScheme == .dark ? 0.36 : 0.14)
                )
                .contentShape(Rectangle())
                .onTapGesture { }

            VStack(spacing: 0) {
                // 顶部标题与当前权限进度（固定顶部，不随内容滚动）
                HStack(alignment: .center, spacing: 10) {
                    BrandAppIconBadge(size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开启全部 3 项核心权限后方可使用")
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(.primary)
                        Text("未授权将导致自动粘贴失灵、聊天原图白屏或全局截屏无法抓取画面。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Text("\(grantedCount)/3")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(grantedCount == 3 ? Color.green : brandCobalt))
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {

                    // 1. 辅助功能
                    permissionCardRow(
                        index: "1",
                        title: "辅助功能（Accessibility）",
                        subtitle: "允许卡片单击/回车直接上屏粘贴与全局热键捕获。",
                        granted: store.isAccessibilityGranted,
                        actionTitle: "前往开启"
                    ) {
                        store.requestAccessibilityPermission()
                        store.openAccessibilitySettings()
                    }

                    // 2. 完全磁盘访问（支持直接拖入系统设置列表）
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            stepBadge("2", granted: store.isFullDiskAccessGranted)
                            VStack(alignment: .leading, spacing: 1.5) {
                                HStack(spacing: 6) {
                                    Text("完全磁盘访问权限")
                                        .font(.system(size: 12.8, weight: .semibold))
                                    statusTag(store.isFullDiskAccessGranted)
                                }
                                Text("用于读取微信/飞书等应用沙盒原图与 Finder 保护目录内容。")
                                    .font(.system(size: 10.6))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            if !store.isFullDiskAccessGranted {
                                Button("打开设置") {
                                    store.openFullDiskAccessSettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }

                        if !store.isFullDiskAccessGranted {
                            HStack(spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(nsImage: NSApp.applicationIconImage)
                                        .resizable()
                                        .frame(width: 22, height: 22)
                                    Text("拖住此图标扔进右侧列表")
                                        .font(.system(size: 10.2, weight: .medium))
                                        .foregroundStyle(brandCobalt)
                                    Spacer(minLength: 0)
                                    Image(systemName: "hand.draw.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(brandCobalt)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(brandCobalt.opacity(colorScheme == .dark ? 0.14 : 0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(brandCobalt.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                )
                                .onDrag {
                                    NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                                }

                                Button("访达定位") {
                                    store.revealAppInFinder()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.primary.opacity(0.08))
                                )
                            }
                        }
                    }
                    .padding(10)
                    .background(cardBackground(granted: store.isFullDiskAccessGranted))
                    .overlay(cardStroke(granted: store.isFullDiskAccessGranted))

                    // 3. 屏幕录制
                    permissionCardRow(
                        index: "3",
                        title: "屏幕录制（Screen Recording）",
                        subtitle: "用于 ScreenCaptureKit 零闪烁高精度截屏与取色。",
                        granted: store.isScreenRecordingGranted,
                        actionTitle: "前往开启"
                    ) {
                        store.requestScreenRecordingPermission()
                        store.openScreenRecordingSettings()
                    }

                    // 同名旧应用 / 换签名 TCC 冲突自检与一键处理区
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: (store.isStaleSignaturePermissionRisk || store.isRunningOutsideApplications) ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle((store.isStaleSignaturePermissionRisk || store.isRunningOutsideApplications) ? Color.orange : brandCobalt)
                            Text("同名旧版本权限冲突排查与一键修复")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("当前签名：\(store.signingIdentityInfo.displayLabel)")
                                .font(.system(size: 10.3, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("运行路径：\(store.signingIdentityInfo.bundlePath)")
                                .font(.system(size: 10.3, design: .monospaced))
                                .foregroundStyle(store.isRunningOutsideApplications ? Color.orange : .secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }

                        Text(
                            store.isRunningOutsideApplications
                                ? "检测到当前未从 /Applications/iClip.app 启动，同名多副本极易导致系统设置勾错了旧应用！请先删除副本或运行一键修复命令。"
                                : "若系统设置里已看到同名 iClip 且已勾选但仍显示「待开启」，说明是旧签名（如 Ad-hoc）残留或存在多个副本。点下方清理旧授权残留后重新勾选并重启即可。"
                        )
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 7) {
                            Button {
                                store.resetStaleTCCPermissions()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.uturn.backward.circle.fill")
                                    Text(store.isResettingTCCPermissions ? "清理中..." : "清理旧授权残留")
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.orange))
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isResettingTCCPermissions)

                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(store.oneClickPermissionFixCommand, forType: .string)
                                copiedCommand = true
                                store.showToast("已复制一键终端修复命令，在终端粘贴回车即可", duration: 3.6)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    copiedCommand = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: copiedCommand ? "checkmark" : "terminal.fill")
                                    Text(copiedCommand ? "已复制命令" : "复制一键终端命令")
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(brandCobalt)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(brandCobalt.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                        }

                        Text("说明：受 macOS 系统安全机制限制，命令行不能静默强行打勾隐私权限；一键命令会自动清除旧签名残留、注册唯一路径并直达系统设置，固定证书签名后升级无需反复重授。")
                            .font(.system(size: 9.8))
                            .foregroundStyle(.secondary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.orange.opacity(colorScheme == .dark ? 0.11 : 0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.85)
                    )

                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 底部固定操作栏（无论窗口拉高或标准高度均贴底对齐）
                HStack(spacing: 8) {
                    Button {
                        store.refreshAllPermissionStatuses()
                        TactileFeedbackEngine.shared.perform(.tabSwitch)
                        if store.areAllRequiredPermissionsGranted {
                            store.showToast("全部权限已就绪")
                        } else {
                            store.showToast("已刷新检测：当前 \(grantedCount)/3 项已就绪", duration: 2.2)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                            Text("立即复检")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8.5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.relaunchApplication()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("重启生效")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8.5)
                        .background(Capsule().fill(brandCobalt))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            store.refreshAllPermissionStatuses()
        }
        .onReceive(Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()) { _ in
            store.refreshAllPermissionStatuses()
        }
    }

    private func permissionCardRow(
        index: String,
        title: String,
        subtitle: String,
        granted: Bool,
        actionTitle: String,
        onAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            stepBadge(index, granted: granted)
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.8, weight: .semibold))
                    statusTag(granted)
                }
                Text(subtitle)
                    .font(.system(size: 10.6))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !granted {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(cardBackground(granted: granted))
        .overlay(cardStroke(granted: granted))
    }

    private func stepBadge(_ index: String, granted: Bool) -> some View {
        ZStack {
            Circle()
                .fill(granted ? Color.green : brandCobalt.opacity(0.16))
                .frame(width: 22, height: 22)
            if granted {
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text(index)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(brandCobalt)
            }
        }
    }

    private func statusTag(_ granted: Bool) -> some View {
        Text(granted ? "已就绪" : "必需 · 待开启")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(granted ? Color.green : Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill((granted ? Color.green : Color.orange).opacity(0.14)))
    }

    private func cardBackground(granted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.065 : 0.04))
    }

    private func cardStroke(granted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(granted ? Color.green.opacity(0.45) : Color.primary.opacity(0.09), lineWidth: 0.85)
    }
}
