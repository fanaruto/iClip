import AppKit
import SwiftUI
import Combine

/// 独立苹果系统设置风格偏好窗口（macOS 26 Tahoe NavigationSplitView + Grouped Form，从菜单栏直开，彻底脱离 420×560 窄面板）
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let state = SettingsWindowViewModel()

    private override init() {
        super.init()
        AppWindowCoordinator.shared.registerWindowProvider(for: .settings) { [weak self] in
            self?.window
        }
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    var isVisibleAndKey: Bool {
        (window?.isVisible ?? false) && (window?.isKeyWindow ?? false)
    }

    func show(
        store: ClipboardStore? = nil,
        section: SettingsSection = .appearance,
        checkUpdates: Bool = false
    ) {
        let store = store ?? .shared
        state.selectedSection = section
        guard NSClassFromString("XCTestCase") == nil else { return }

        store.refreshAllPermissionStatuses()
        store.pruneUnavailableIgnoredApps()

        if checkUpdates {
            UpdateManager.shared.checkForUpdates(silent: false)
        }

        if let existing = window {
            bringToFront(existing)
            return
        }

        let contentSize = NSSize(width: 792, height: 590)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "iClip 设置"
        win.toolbarStyle = .unified
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.level = .normal
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.minSize = NSSize(width: 688, height: 500)
        win.backgroundColor = .windowBackgroundColor
        win.delegate = self

        let rootView = StandaloneSettingsRootView(
            store: store,
            viewModel: state,
            onOpenPhraseCreator: {
                AppWindowCoordinator.shared.openMainPanelFromStandalone(tab: .pinned, createTemplate: true)
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]
        win.contentView = hosting

        centerOnActiveScreen(win, size: contentSize)
        self.window = win
        bringToFront(win)
    }

    func close() {
        HotKeyRecorderCoordinator.shared.stopRecording()
        AppWindowCoordinator.shared.hideAppearanceLivePreview()
        if let win = window, win.isVisible {
            win.orderOut(nil)
        }
        AppWindowCoordinator.shared.notifyStandaloneVisibilityChanged()
    }

    func windowWillClose(_ notification: Notification) {
        HotKeyRecorderCoordinator.shared.stopRecording()
        AppWindowCoordinator.shared.hideAppearanceLivePreview()
        AppWindowCoordinator.shared.notifyStandaloneVisibilityChanged()
    }

    func windowDidResignKey(_ notification: Notification) {
        if HotKeyRecorderCoordinator.shared.isRecording {
            HotKeyRecorderCoordinator.shared.stopRecording()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ClipboardStore.shared.refreshAllPermissionStatuses()
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
            y: round(visible.midY - size.height * 0.5 + 14)
        )
        win.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

@MainActor
final class SettingsWindowViewModel: ObservableObject {
    @Published var selectedSection: SettingsSection = .appearance
}

// MARK: - 独立设置窗口 SwiftUI 根视图

struct StandaloneSettingsRootView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: SettingsWindowViewModel
    @ObservedObject private var updater = UpdateManager.shared
    @ObservedObject private var recorder = HotKeyRecorderCoordinator.shared
    @ObservedObject private var engine = AdaptiveIntelligenceEngine.shared
    @ObservedObject private var oneMind = OneMindKernel.shared
    @ObservedObject private var coordinator = AppWindowCoordinator.shared
    @ObservedObject private var diagnostics = DiagnosticLogService.shared

    let onOpenPhraseCreator: () -> Void
    let onQuit: () -> Void

    @State private var showAdvancedPrivacy: Bool = false
    @State private var showClearHistoryConfirm: Bool = false

    private var pendingPermissionCount: Int {
        (store.isAccessibilityGranted ? 0 : 1)
            + (store.isFullDiskAccessGranted ? 0 : 1)
            + (store.isScreenRecordingGranted ? 0 : 1)
    }

    private var hotKeyHealth: HotKeyConflictHealthReport {
        HotKeyConflictHealthReport.evaluate(
            main: store.hotKeyShortcut,
            screenshot: store.screenshotHotKeyShortcut,
            copyAppend: .defaultCopyAppendShortcut,
            copyAppendEnabled: engine.copyAppendEnabled && !store.minimalModeEnabled
        )
    }

    private var featureAdvisories: [FeatureConflictAdvisory] {
        FeatureConflictAdvisory.evaluate(
            minimalModeEnabled: store.minimalModeEnabled,
            sparkEnabled: engine.sparkEnabled,
            financeAssistantEnabled: store.financeAssistantEnabled,
            spriteOrbEnabled: store.spriteOrbEnabled,
            spriteOrbProactiveNudgeEnabled: store.spriteOrbProactiveNudgeEnabled,
            isAccessibilityGranted: store.isAccessibilityGranted,
            isFullDiskAccessGranted: store.isFullDiskAccessGranted,
            isScreenRecordingGranted: store.isScreenRecordingGranted
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebarView
                .navigationSplitViewColumnWidth(min: 204, ideal: 218, max: 244)
        } detail: {
            detailContainer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: viewModel.selectedSection) { _, newSection in
            if newSection != .shortcuts && recorder.isRecording {
                recorder.stopRecording()
            }
            if newSection != .appearance {
                coordinator.hideAppearanceLivePreview()
            }
            if newSection == .permissionsAndAbout {
                store.refreshAllPermissionStatuses()
                diagnostics.scanRecentCrashes()
            } else if newSection == .privacy {
                store.pruneUnavailableIgnoredApps()
            }
        }
        .alert("确定清空全部未收藏历史？", isPresented: $showClearHistoryConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空未收藏历史", role: .destructive) {
                store.clearUnpinned()
            }
        } message: {
            Text("所有已收藏（置顶）记录和自定义口令短语都会完整保留。")
        }
    }

    // MARK: - 左侧原生苹果设置栏

    private var sidebarView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandAppIconBadge(size: 32)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("iClip")
                        .font(.system(size: 14, weight: .bold))
                    Text("v\(AppRoleEdition.currentVersionString)")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)

            List(SettingsSection.allCases, selection: $viewModel.selectedSection) { section in
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: section.badgeGradient,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 24, height: 24)
                        Image(systemName: section.symbolName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text(section.title)
                        .font(.system(size: 13, weight: .medium))

                    Spacer(minLength: 4)

                    sidebarBadge(for: section)
                }
                .padding(.vertical, 3)
                .tag(section)
            }
            .listStyle(.sidebar)
            .tahoeSoftScrollEdges()

            Divider().opacity(0.35)

            HStack(spacing: 8) {
                Button {
                    AppWindowCoordinator.shared.presentOnboarding(store: store, forceRestart: false)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text("入门引导")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    AppWindowCoordinator.shared.presentPermissionSetup(store: store)
                } label: {
                    let statusColor: Color = pendingPermissionCount > 0 ? .orange : .green
                    HStack(spacing: 4) {
                        Image(systemName: pendingPermissionCount > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(pendingPermissionCount > 0 ? "权限 \(3 - pendingPermissionCount)/3" : "权限正常")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(statusColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(statusColor.opacity(0.13))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(statusColor.opacity(0.32), lineWidth: 0.7)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func sidebarBadge(for section: SettingsSection) -> some View {
        switch section {
        case .permissionsAndAbout:
            if pendingPermissionCount > 0 {
                Text("\(pendingPermissionCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.orange))
            } else if updater.hasUpdateAvailable {
                Circle()
                    .fill(TahoeUI.brandCobalt)
                    .frame(width: 8, height: 8)
            }
        case .shortcuts:
            if !hotKeyHealth.isHealthy {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        case .intelligence:
            if store.minimalModeEnabled {
                Text("极简")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
            }
        default:
            EmptyView()
        }
    }

    // MARK: - 右侧详情容器

    private var detailContainer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedSection.title)
                        .font(.system(size: 20, weight: .bold))
                    Text(viewModel.selectedSection.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if viewModel.selectedSection == .appearance {
                    Button {
                        if coordinator.isAppearanceLivePreviewActive {
                            coordinator.hideAppearanceLivePreview()
                        } else {
                            coordinator.showAppearanceLivePreview()
                        }
                        TactileFeedbackEngine.shared.performNavigationStepHaptic()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: coordinator.isAppearanceLivePreviewActive ? "eye.fill" : "macwindow.on.rectangle")
                                .font(.system(size: 11, weight: .semibold))
                            Text(coordinator.isAppearanceLivePreviewActive ? "实时预览中 · 收起" : "预览真实面板")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(coordinator.isAppearanceLivePreviewActive ? .white : TahoeUI.brandCobalt)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                coordinator.isAppearanceLivePreviewActive
                                    ? TahoeUI.brandCobalt
                                    : TahoeUI.brandCobalt.opacity(0.12)
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .help("在设置窗旁实时展示真实的 iClip 剪贴板面板效果")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Group {
                switch viewModel.selectedSection {
                case .appearance:
                    appearancePane
                case .shortcuts:
                    shortcutsPane
                case .intelligence:
                    intelligencePane
                case .privacy:
                    privacyPane
                case .permissionsAndAbout:
                    permissionsAndAboutPane
                }
            }
            .tahoeSoftScrollEdges()
        }
    }

    // MARK: - 1. 外观与手感

    private var appearancePane: some View {
        Form {
            Section("液态玻璃与卡片质感") {
                LiquidGlassBlurStyleCard(blurConcentration: $store.liquidGlassMaskOpacity)
                    .padding(.vertical, 2)
                    .onChange(of: store.liquidGlassMaskOpacity) { _, _ in
                        coordinator.showAppearanceLivePreview()
                    }
                CardSkinStylePickerCard(cardSkin: $store.cardSkin)
                    .padding(.vertical, 2)
                    .onChange(of: store.cardSkin) { _, _ in
                        coordinator.showAppearanceLivePreview()
                    }
            }

            Section("悬浮精灵小球") {
                SpriteOrbSettingsCard(
                    enabled: $store.spriteOrbEnabled,
                    style: $store.spriteOrbStyle,
                    dockMode: $store.spriteOrbDockMode
                )
                .padding(.vertical, 2)
            }

            Section("操控手感与窗口行为") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("默认键入方式", selection: $store.cardClickPasteMode) {
                        Text("单击直接粘贴").tag(CardClickPasteMode.singleClick)
                        Text("双击直接粘贴").tag(CardClickPasteMode.doubleClick)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: store.cardClickPasteMode) { _, _ in
                        TactileFeedbackEngine.shared.performNavigationStepHaptic()
                    }

                    Text(store.cardClickPasteMode.companionGestureSummary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: Binding(
                    get: { store.alwaysOnTop },
                    set: { newVal in
                        if newVal != store.alwaysOnTop {
                            store.toggleAlwaysOnTop()
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("主面板始终在前（⌘P）")
                        Text("开启后切窗或连续粘贴不自动收起；打开独立设置或权限窗时自动避让绝不遮挡")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    let isDefaultSize = abs(store.panelWidth - 420) < 1 && abs(store.panelHeight - 560) < 1
                    VStack(alignment: .leading, spacing: 2) {
                        Text("主面板尺寸")
                        Text("当前 \(Int(store.panelWidth)) × \(Int(store.panelHeight)) px · 拖动边缘四向自由拉伸，双击边缘还原")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("恢复默认") {
                        TactileFeedbackEngine.shared.performNavigationStepHaptic()
                        store.resetPanelDimensions()
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)
                    .disabled(isDefaultSize)
                }

                Toggle(isOn: Binding(
                    get: { store.launchAtLoginEnabled },
                    set: { store.setLaunchAtLogin($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开机自动启动")
                        Text("登录 macOS 后自动在菜单栏轻盈常驻")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $store.soundEffectsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("交互微音效反馈")
                        Text("键入与转换时播放轻柔声学反馈（开启即刻试音）")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.soundEffectsEnabled) { _, on in
                    if on {
                        TactileFeedbackEngine.shared.perform(.pasteCommit)
                    } else {
                        TactileFeedbackEngine.shared.performNavigationStepHaptic()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 2. 快捷键与手势

    private var shortcutsPane: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: hotKeyHealth.isHealthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(hotKeyHealth.isHealthy ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hotKeyHealth.isHealthy ? "全部快捷键零冲突守护中" : "发现快捷键冲突项")
                            .font(.system(size: 13.5, weight: .semibold))
                        if hotKeyHealth.isHealthy {
                            Text("录制新热键自动通过 5 层检测：应用内互锁、系统核心键、系统快捷键与听写双击防重。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(hotKeyHealth.issues, id: \.self) { issue in
                                Text("· \(issue)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }

            Section("全局热键录制") {
                hotKeyRecorderRow(
                    title: "全局呼出主面板",
                    subtitle: "在光标旁零失焦呼出（支持组合键或双击 ⌘/⌥/⌃/⇧ 单键）",
                    slot: .mainToggle,
                    current: store.hotKeyShortcut,
                    defaultShortcut: .defaultShortcut,
                    onReset: {
                        recorder.stopRecording()
                        store.hotKeyShortcut = .defaultShortcut
                        store.showToast("已恢复默认全局呼出快捷键 ⌥ V")
                    }
                )

                hotKeyRecorderRow(
                    title: "区域 / 窗口原生截图",
                    subtitle: store.isScreenRecordingGranted
                        ? "自动吸附桌面窗口、自由框选、按住 ⌘ 松手秒复制与大爆炸取词"
                        : "需先在「权限授权中心」开启屏幕录制权限后方可使用",
                    slot: .screenshot,
                    current: store.screenshotHotKeyShortcut,
                    defaultShortcut: .defaultScreenshotShortcut,
                    onReset: {
                        recorder.stopRecording()
                        store.screenshotHotKeyShortcut = .defaultScreenshotShortcut
                        store.showToast("已恢复默认截图快捷键 ⌥ A")
                    }
                )

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("跨处选段续接复制（Copy-Append）")
                                .font(.system(size: 13, weight: .medium))
                            Text("内置固定")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                        Text(
                            (engine.copyAppendEnabled && !store.minimalModeEnabled)
                                ? "多次选中文字按此热键，自动换行拼接至当前剪贴板末尾"
                                : "当前已随极简模式或智能设置暂停"
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    keycapPill(HotKeyShortcut.defaultCopyAppendShortcut.displayString)
                }
            }

            Section("面板与大爆炸高频快捷键速查") {
                shortcutReferenceRow("直接键入光标所在区域", store.cardClickPasteMode == .singleClick ? "单击 / ↵" : "双击 / ↵")
                shortcutReferenceRow("仅复制到系统剪贴板", store.cardClickPasteMode == .singleClick ? "⌥ 单击 / ⌘ C" : "单击 / ⌘ C")
                shortcutReferenceRow("全图缩放 / 大爆炸选字（先用 ↓ 选卡）", "Space / ⌘ Y")
                shortcutReferenceRow("大爆炸内：原位二次拆分 / 撤销拆分", "双击词块 / X · ⌘ Z")
                shortcutReferenceRow("大爆炸内：纯图与原位选字切换", "O / B")
                shortcutReferenceRow("首选智能变换 / AI 替身脱敏键入", "⇧ ↵")
                shortcutReferenceRow("强制粘贴原始明文（跳过脱敏）", "⌥ ↵")
                shortcutReferenceRow("直达第 1~3 个语义变换", "⌃ 1 ~ 3")
                shortcutReferenceRow("左 / 右切换类目与按语义速筛", "⇧⇥ / ⇥ · @json @secret")
                shortcutReferenceRow("快速键入前 9 条与剪贴即待办", "⌘ 1 ~ 9 · ⌘ T")
                shortcutReferenceRow("置顶面板 / 切换极简纯净模式 / 打开设置", "⌘ P · ⌘ E · ⌘ ,")
            }
        }
        .formStyle(.grouped)
    }

    private func hotKeyRecorderRow(
        title: String,
        subtitle: String,
        slot: HotKeySlotRole,
        current: HotKeyShortcut,
        defaultShortcut: HotKeyShortcut,
        onReset: @escaping () -> Void
    ) -> some View {
        let isRecordingThis = recorder.isRecording(slot: slot)
        let hasConflict = isRecordingThis && recorder.conflictWarning != nil

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                if isRecordingThis, let warning = recorder.conflictWarning {
                    Text(warning)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.red)
                } else if isRecordingThis, let hint = recorder.recordingHint {
                    Text(hint)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(TahoeUI.brandCobalt)
                } else {
                    Text(isRecordingThis ? "请直接按下组合键，或连按两次 ⌘/⌥/⌃/⇧（ESC 取消）" : subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isRecordingThis ? TahoeUI.brandCobalt : .secondary)
                }
            }

            Spacer(minLength: 8)

            Button {
                if isRecordingThis {
                    recorder.stopRecording()
                } else {
                    recorder.startRecording(slot: slot, store: store)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: hasConflict ? "exclamationmark.circle.fill" : (isRecordingThis ? "record.circle.fill" : "keyboard"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isRecordingThis ? .white : TahoeUI.brandCobalt)
                    Text(hasConflict ? "冲突 · 请重按" : (isRecordingThis ? "等待按键..." : current.displayString))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(isRecordingThis ? .white : .primary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
                        hasConflict
                            ? Color.red
                            : (isRecordingThis ? TahoeUI.brandCobalt : TahoeUI.brandCobalt.opacity(0.11))
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
                        hasConflict
                            ? Color.red.opacity(0.8)
                            : (isRecordingThis ? TahoeUI.brandCobalt : TahoeUI.brandCobalt.opacity(0.36)),
                        lineWidth: 0.9
                    )
                )
            }
            .buttonStyle(.plain)
            .help("点击录制自定义热键（支持组合键与双击单键）")

            if current != defaultShortcut && !isRecordingThis {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                }
                .tahoeActionButtonStyle(prominent: false)
                .controlSize(.small)
                .help("恢复默认 \(defaultShortcut.displayString)")
            }
        }
        .padding(.vertical, 2)
    }

    private func shortcutReferenceRow(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            keycapPill(shortcut)
        }
    }

    private func keycapPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color.primary.opacity(0.055)))
    }

    // MARK: - 3. 智能与效率

    private var intelligencePane: some View {
        Form {
            if !featureAdvisories.isEmpty {
                Section("功能协同状态提示") {
                    ForEach(featureAdvisories) { advisory in
                        advisoryBannerRow(advisory)
                    }
                }
            }

            Section("OneMind 主动心智与扩展能力") {
                AdaptiveIntelligenceSettingsSection(
                    store: store,
                    onOpenPhraseCreator: onOpenPhraseCreator
                )
                .padding(.vertical, 4)
            }

            Section("桌面快捷手势与排序") {
                Toggle(
                    isOn: Binding(
                        get: { oneMind.cursorDropPodEnabled },
                        set: { oneMind.cursorDropPodEnabled = $0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("拖拽途中按 ⌥ 呼出「微落点」中转舱")
                        Text("拖拽图片、文字或文件时按住 Option 键，光标旁浮现即时收件舱")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Image(systemName: "hand.draw.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TahoeUI.brandCobalt)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("长按卡片可自由拖动排列顺序")
                            .font(.system(size: 13, weight: .medium))
                        Text("在主面板按住任意剪贴卡片约 0.25 秒浮起后上下拖动即可顺滑排序；直接拖出仍保持跨应用拖拽")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func advisoryBannerRow(_ advisory: FeatureConflictAdvisory) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: advisory.severity == .warning ? "exclamationmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(advisory.severity == .warning ? Color.orange : TahoeUI.brandCobalt)

            VStack(alignment: .leading, spacing: 2) {
                Text(advisory.title)
                    .font(.system(size: 12.8, weight: .semibold))
                Text(advisory.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let title = advisory.actionTitle, let actionKind = advisory.actionKind {
                Button(title) {
                    switch actionKind {
                    case .disableMinimalMode:
                        if store.minimalModeEnabled {
                            store.toggleMinimalMode()
                        }
                    case .enableSpriteOrb:
                        store.spriteOrbEnabled = true
                    case .openPermissionCenter:
                        AppWindowCoordinator.shared.presentPermissionSetup(store: store)
                    }
                }
                .tahoeActionButtonStyle(prominent: false)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 4. 隐私与搬家

    private var privacyPane: some View {
        let shieldState = PrivacyShieldToggleState.from(store: store)
        let badgeTint: Color = shieldState.isFullyProtected
            ? .green
            : (shieldState.isPartiallyProtected ? TahoeUI.brandCobalt : .secondary)
        let visibleIgnoredApps = store.ignoredApps.filter {
            ClipboardStore.isAppAvailableOnSystem(bundleIdentifier: $0.bundleIdentifier)
        }

        return Form {
            Section("零信任隐私护盾") {
                HStack(spacing: 10) {
                    Image(systemName: shieldState.isMasterOn ? "lock.shield.fill" : "shield.slash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(badgeTint)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本机 AES-256 透明加密 · 零联网")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(shieldState.statusDescription)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()

                    if shieldState.isPartiallyProtected {
                        Button("一键全开") {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                PrivacyShieldToggleState.all(true).apply(to: store)
                            }
                            TactileFeedbackEngine.shared.perform(.tabSwitch)
                        }
                        .tahoeActionButtonStyle(prominent: false)
                        .controlSize(.small)
                    }

                    Text(shieldState.badgeText)
                        .font(.system(size: 10.5, weight: .semibold))
                        .contentTransition(.numericText())
                        .foregroundStyle(badgeTint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(badgeTint.opacity(0.12)))
                }

                Toggle(isOn: Binding(
                    get: { shieldState.isMasterOn },
                    set: { newVal in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            PrivacyShieldToggleState.all(newVal).apply(to: store)
                        }
                        TactileFeedbackEngine.shared.perform(.tabSwitch)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("隐私安全护盾（总开关）")
                        Text("开启即全开 6 项核心隐私防护；向下微调细项时仅当 6 项全部关闭才联动关闭总开关")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                DisclosureGroup("展开 6 项细分护盾控制（已开启 \(shieldState.activeCount)/6）", isExpanded: $showAdvancedPrivacy) {
                    Toggle("投屏与录屏光学隐身", isOn: $store.screenSharePrivacyEnabled)
                    Toggle("敏感凭据防肩窥圆点遮罩", isOn: $store.maskSensitivePreviews)
                    Toggle("粘贴敏感凭据自动脱敏（⌥↵ 强制贴明文）", isOn: $store.autoRedactOnPaste)
                    Toggle("密码剪贴板 60 秒残留擦除", isOn: $store.autoClearConcealedPasteboard)
                    Toggle("未收藏敏感凭据 24 小时自动销毁", isOn: $store.autoExpireUnpinnedSecrets)
                    Toggle("复制链接自动剥离追踪尾巴", isOn: $store.autoCleanTrackingURL)
                }
            }

            Section("隐私忽略应用（仅显示本机已安装）") {
                if visibleIgnoredApps.isEmpty {
                    Text("当前未配置忽略应用；可添加密码管理器或隐私聊天应用，使其复制内容不被记录。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleIgnoredApps) { app in
                        HStack(spacing: 10) {
                            if let icon = store.appIcon(forBundleID: app.bundleIdentifier) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 20, height: 20)
                            }
                            Text(app.displayName)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    store.removeIgnoredApp(bundleIdentifier: app.bundleIdentifier)
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("移出忽略名单")
                        }
                    }
                }

                HStack {
                    Menu {
                        let candidates = store.runningCandidateAppsForIgnore()
                        if candidates.isEmpty {
                            Text("暂无可添加的运行中应用")
                        } else {
                            ForEach(candidates) { candidate in
                                Button(candidate.displayName) {
                                    store.addIgnoredApp(
                                        bundleIdentifier: candidate.bundleIdentifier,
                                        displayName: candidate.displayName
                                    )
                                }
                            }
                        }
                    } label: {
                        Label("添加运行中应用", systemImage: "plus.circle")
                    }
                    .fixedSize()

                    Spacer()

                    Button("从应用程序选择...") {
                        ClipboardSettingsDialogHelper.pickAppToIgnore(store: store)
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)
                }
            }

            Section("历史上限与跨工具无缝搬家") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("历史保留上限", selection: $store.maxHistoryCount) {
                        Text("50 条").tag(50)
                        Text("100 条").tag(100)
                        Text("200 条").tag(200)
                        Text("500 条").tag(500)
                    }
                    .pickerStyle(.segmented)
                    Text("已收藏与待办记录永久安全保存，不受历史上限清理影响。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("收藏归档与竞品导入")
                        Text("已收藏 \(store.pinnedItemCount) 条 · 支持 .iclip / Paste / Maccy / Raycast / Alfred / Ditto / CSV")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("导入...") {
                        ClipboardSettingsDialogHelper.importArchiveOrCompetitorFile(store: store)
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)

                    Button("导出 (.iclip)") {
                        ClipboardSettingsDialogHelper.exportPinnedArchive(store: store)
                    }
                    .tahoeActionButtonStyle(prominent: true)
                    .controlSize(.small)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("清空未收藏历史")
                        Text("一键清理普通历史记录，保留全部收藏与短语模板")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("清空历史...", role: .destructive) {
                        showClearHistoryConfirm = true
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 5. 权限与关于

    private var permissionsAndAboutPane: some View {
        Form {
            Section("系统权限状态（3 项核心能力）") {
                permissionStatusSummaryRow(
                    title: "辅助功能（一键直贴与全局热键）",
                    granted: store.isAccessibilityGranted,
                    focus: .accessibility
                )
                permissionStatusSummaryRow(
                    title: "完全磁盘访问（微信 / 飞书原图直显）",
                    granted: store.isFullDiskAccessGranted,
                    focus: .fullDiskAccess
                )
                permissionStatusSummaryRow(
                    title: "屏幕录制（⌥A 原生截图与取色）",
                    granted: store.isScreenRecordingGranted,
                    focus: .screenRecording
                )

                HStack {
                    Text(pendingPermissionCount == 0 ? "全部 3 项核心权限均已正常就绪" : "还有 \(pendingPermissionCount) 项权限待开启，可在独立向导中一键完成")
                        .font(.system(size: 12))
                        .foregroundStyle(pendingPermissionCount == 0 ? Color.green : Color.orange)
                    Spacer()
                    Button("打开独立权限中心...") {
                        AppWindowCoordinator.shared.presentPermissionSetup(store: store)
                    }
                    .tahoeActionButtonStyle(prominent: pendingPermissionCount > 0)
                    .controlSize(.small)
                }
            }

            Section("入门体验与上手引导") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("新手交互式引导与沙盒")
                        Text("随时重温物理键帽试按、大爆炸二次拆分沙盒与一键竞品搬家")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开入门引导...") {
                        AppWindowCoordinator.shared.presentOnboarding(store: store, forceRestart: true)
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)
                }
            }

            Section("问题诊断与官网 Bug 反馈") {
                HStack(spacing: 10) {
                    Image(systemName: diagnostics.recentCrashCount > 0 ? "exclamationmark.bubble.fill" : "checkmark.seal.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(diagnostics.recentCrashCount > 0 ? Color.orange : Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            diagnostics.recentCrashCount > 0
                                ? "近期检测到 \(diagnostics.recentCrashCount) 条异常退出日志（已入自动优化队列）"
                                : "本地运行稳定（近期 0 次异常退出）"
                        )
                        .font(.system(size: 13, weight: .semibold))
                        if let latest = diagnostics.latestCrash {
                            Text("最近记录：\(latest.captureTime) · \(latest.exceptionType)（\(latest.faultingQueue)），诊断仅含技术栈帧，零剪贴板内容。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else {
                            Text("已开启本机脱敏崩溃捕捉与每小时自愈诊断，遇到异常可一键跳转官网反馈。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        diagnostics.openOfficialBugFeedbackPage()
                    } label: {
                        Label("前往官网反馈 Bug", systemImage: "ladybug.fill")
                    }
                    .tahoeActionButtonStyle(prominent: true)
                    .controlSize(.small)

                    Button {
                        diagnostics.copySanitizedDiagnosticSummary(store: store)
                    } label: {
                        Label("复制脱敏诊断摘要", systemImage: "doc.on.doc")
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)

                    Spacer()

                    Button("查看日志目录") {
                        diagnostics.revealLogsInFinder()
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)
                }
            }

            Section("软件更新与运行环境") {
                RoleAndOTASettingsSection(store: store, updater: updater)
                    .padding(.vertical, 2)

                LabeledContent("签名身份") {
                    Text(store.signingIdentityInfo.displayLabel)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("安装路径") {
                    Text(store.signingIdentityInfo.bundlePath)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(store.isRunningOutsideApplications ? Color.orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("退出 iClip", role: .destructive, action: onQuit)
                        .tahoeActionButtonStyle(prominent: false)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func permissionStatusSummaryRow(
        title: String,
        granted: Bool,
        focus: PermissionFocusKind
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title)
                .font(.system(size: 13))
            Spacer()
            if granted {
                Text("已授权")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Button("去开启") {
                    AppWindowCoordinator.shared.presentPermissionSetup(store: store, highlight: focus)
                }
                .tahoeActionButtonStyle(prominent: false)
                .controlSize(.small)
            }
        }
    }
}
