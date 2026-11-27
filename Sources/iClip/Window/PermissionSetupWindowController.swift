import AppKit
import SwiftUI
import Combine

/// 独立新人系统权限授权中心（macOS 26 Tahoe Setup Assistant 风格，彻底告别挤在 420×560 面板内的阻塞遮罩）
@MainActor
final class PermissionSetupWindowController: NSObject, NSWindowDelegate {
    static let shared = PermissionSetupWindowController()

    private var window: NSWindow?
    private let state = PermissionSetupViewModel()
    private var activeAppObserver: NSObjectProtocol?

    private override init() {
        super.init()
        AppWindowCoordinator.shared.registerWindowProvider(for: .permission) { [weak self] in
            self?.window
        }
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func show(
        store: ClipboardStore? = nil,
        highlight: PermissionFocusKind? = nil,
        continueToOnboardingOnComplete: Bool = false
    ) {
        let store = store ?? .shared
        guard NSClassFromString("XCTestCase") == nil else { return }

        state.highlightedPermission = highlight
        state.continueToOnboardingOnComplete = continueToOnboardingOnComplete
        store.refreshAllPermissionStatuses()

        if let existing = window {
            bringToFront(existing)
            return
        }

        let contentSize = NSSize(width: 556, height: 636)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "iClip 系统权限授权中心"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        // 使用 .normal 层级，避免点击「前往开启」跳转到「系统设置」时反向盖住系统设置界面
        win.level = .normal
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.minSize = NSSize(width: 510, height: 560)
        win.backgroundColor = .windowBackgroundColor
        win.delegate = self

        let rootView = PermissionSetupWindowView(
            store: store,
            viewModel: state,
            onContinueAfterGranted: { [weak self] in
                guard let self else { return }
                let shouldOpenOnboarding = self.state.continueToOnboardingOnComplete
                    || !InteractivePlaygroundController.shared.hasCompletedOnboarding
                self.close()
                if shouldOpenOnboarding {
                    AppWindowCoordinator.shared.presentOnboarding(store: store, forceRestart: false)
                } else {
                    AppWindowCoordinator.shared.openMainPanelFromStandalone()
                }
            },
            onDeferForSession: { [weak self] in
                AppWindowCoordinator.shared.hasDeferredPermissionGateThisSession = true
                self?.close()
                if !InteractivePlaygroundController.shared.hasCompletedOnboarding {
                    AppWindowCoordinator.shared.presentOnboarding(store: store, forceRestart: false)
                } else {
                    store.showToast("稍后可随时从菜单栏「权限授权中心」补齐权限", duration: 3.0)
                }
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]
        win.contentView = hosting

        centerOnActiveScreen(win, size: contentSize)
        self.window = win
        installActiveObserver(store: store)
        bringToFront(win)
    }

    func close() {
        removeActiveObserver()
        if let win = window, win.isVisible {
            win.orderOut(nil)
        }
        AppWindowCoordinator.shared.notifyStandaloneVisibilityChanged()
    }

    func windowWillClose(_ notification: Notification) {
        removeActiveObserver()
        AppWindowCoordinator.shared.notifyStandaloneVisibilityChanged()
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
            y: round(visible.midY - size.height * 0.5 + 18)
        )
        win.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func installActiveObserver(store: ClipboardStore) {
        removeActiveObserver()
        activeAppObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak store] _ in
            Task { @MainActor in
                store?.refreshAllPermissionStatuses()
            }
        }
    }

    private func removeActiveObserver() {
        if let obs = activeAppObserver {
            NotificationCenter.default.removeObserver(obs)
            activeAppObserver = nil
        }
    }
}

@MainActor
final class PermissionSetupViewModel: ObservableObject {
    @Published var highlightedPermission: PermissionFocusKind? = nil
    @Published var continueToOnboardingOnComplete: Bool = false
}

// MARK: - 独立权限授权中心 SwiftUI 视图（macOS 26 Liquid Glass）

struct PermissionSetupWindowView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: PermissionSetupViewModel
    let onContinueAfterGranted: () -> Void
    let onDeferForSession: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showTroubleshooter: Bool = false
    @State private var copiedCommand: Bool = false
    @State private var previousGrantedCount: Int = -1

    private var grantedCount: Int {
        (store.isAccessibilityGranted ? 1 : 0)
            + (store.isFullDiskAccessGranted ? 1 : 0)
            + (store.isScreenRecordingGranted ? 1 : 0)
    }

    private var allGranted: Bool {
        grantedCount == 3
    }

    private var progressFraction: Double {
        Double(grantedCount) / 3.0
    }

    var body: some View {
        ZStack {
            windowBackdrop

            VStack(spacing: 0) {
                heroHeader
                    .padding(.horizontal, 26)
                    .padding(.top, 30)
                    .padding(.bottom, 16)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 12) {
                        accessibilityCard
                        fullDiskAccessCard
                        screenRecordingCard
                        troubleshooterCard
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 6)
                }
                .tahoeSoftScrollEdges()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().opacity(0.28)

                footerBar
                    .padding(.horizontal, 26)
                    .padding(.vertical, 15)
            }
        }
        .frame(minWidth: 510, minHeight: 560)
        .onAppear {
            store.refreshAllPermissionStatuses()
            previousGrantedCount = grantedCount
            if store.isStaleSignaturePermissionRisk || store.isRunningOutsideApplications {
                showTroubleshooter = true
            }
        }
        .onChange(of: grantedCount) { oldVal, newVal in
            if previousGrantedCount >= 0 && newVal > oldVal {
                TactileFeedbackEngine.shared.perform(newVal == 3 ? .pasteCommit : .tabSwitch)
            }
            previousGrantedCount = newVal
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            store.refreshAllPermissionStatuses()
        }
    }

    private var windowBackdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    (allGranted ? TahoeUI.brandMint : TahoeUI.brandCobalt).opacity(colorScheme == .dark ? 0.15 : 0.07),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - 顶部苹果风 Hero 区

    private var heroHeader: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                BrandAppIconBadge(size: 54)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(allGranted ? "全部 3 项系统权限已就绪" : "为 iClip 开启系统权限")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.primary)
                        Image(systemName: allGranted ? "checkmark.shield.fill" : "lock.shield.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(allGranted ? Color.green : TahoeUI.brandCobalt)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: grantedCount)
                    }
                    Text("所有剪贴板记录、识别与加密均在本机离线完成，零联网上传；一次授权后更新版本可自动沿用。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)
            }

            // 进度胶囊条
            VStack(spacing: 8) {
                HStack {
                    Text(allGranted ? "已完成全部核心授权，现在可以畅享完整体验" : "完成下方 3 项授权即可解锁一键直贴、聊天原图与原生截屏")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(allGranted ? Color.green : .secondary)
                    Spacer()
                    Text("\(grantedCount) / 3")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(allGranted ? Color.green : TahoeUI.brandCobalt)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: allGranted
                                        ? [Color.green, TahoeUI.brandMint]
                                        : [TahoeUI.brandCobalt, Color(red: 0.25, green: 0.56, blue: 1.0)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(12, proxy.size.width * progressFraction))
                            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: grantedCount)
                    }
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .tahoeGlassCard(cornerRadius: 14, tint: allGranted ? .green : nil)
        }
    }

    // MARK: - 3 项核心权限卡片

    private var accessibilityCard: some View {
        permissionCardShell(
            index: 1,
            symbol: "cursorarrow.click.2",
            iconTint: TahoeUI.brandCobalt,
            title: "辅助功能（Accessibility）",
            benefit: "允许单击 / 回车直接贴入当前光标框，并驱动零失焦键盘流与全局热键。",
            granted: store.isAccessibilityGranted,
            isHighlighted: viewModel.highlightedPermission == .accessibility,
            actionTitle: "前往开启"
        ) {
            store.requestAccessibilityPermission()
            store.openAccessibilitySettings()
        } extraContent: {
            EmptyView()
        }
    }

    private var fullDiskAccessCard: some View {
        permissionCardShell(
            index: 2,
            symbol: "internaldrive.fill",
            iconTint: TahoeUI.brandIndigo,
            title: "完全磁盘访问（Full Disk Access）",
            benefit: "允许高清直显微信 / 飞书等聊天工具沙盒原图，并读取受保护目录文件。",
            granted: store.isFullDiskAccessGranted,
            isHighlighted: viewModel.highlightedPermission == .fullDiskAccess,
            actionTitle: "打开设置"
        ) {
            store.openFullDiskAccessSettings()
        } extraContent: {
            if !store.isFullDiskAccessGranted {
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 22, height: 22)
                        Text("按住此图标，直接拖入系统设置的「完全磁盘访问」列表")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TahoeUI.brandCobalt)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "hand.draw.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(TahoeUI.brandCobalt)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(TahoeUI.brandCobalt.opacity(colorScheme == .dark ? 0.16 : 0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                TahoeUI.brandCobalt.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                    )
                    .onDrag {
                        NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                    }

                    Button("访达定位") {
                        store.revealAppInFinder()
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
    }

    private var screenRecordingCard: some View {
        permissionCardShell(
            index: 3,
            symbol: "camera.viewfinder",
            iconTint: TahoeUI.brandMint,
            title: "屏幕录制（Screen Recording）",
            benefit: "驱动原生 ScreenCaptureKit 区域 / 窗口截图（\(store.screenshotHotKeyShortcut.displayString)）与像素取色。",
            granted: store.isScreenRecordingGranted,
            isHighlighted: viewModel.highlightedPermission == .screenRecording,
            actionTitle: "前往开启"
        ) {
            store.requestScreenRecordingPermission()
            store.openScreenRecordingSettings()
        } extraContent: {
            EmptyView()
        }
    }

    private func permissionCardShell<Extra: View>(
        index: Int,
        symbol: String,
        iconTint: Color,
        title: String,
        benefit: String,
        granted: Bool,
        isHighlighted: Bool,
        actionTitle: String,
        onAction: @escaping () -> Void,
        @ViewBuilder extraContent: () -> Extra
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill((granted ? Color.green : iconTint).opacity(colorScheme == .dark ? 0.24 : 0.14))
                        .frame(width: 38, height: 38)
                    Image(systemName: granted ? "checkmark.circle.fill" : symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(granted ? Color.green : iconTint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .symbolEffect(.bounce, value: granted)

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 6) {
                        Text("\(index). \(title)")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(granted ? "已就绪" : "待开启")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(granted ? Color.green : Color.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill((granted ? Color.green : Color.orange).opacity(0.14))
                            )
                    }
                    Text(benefit)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if !granted {
                    Button(actionTitle, action: onAction)
                        .tahoeActionButtonStyle(prominent: true)
                        .controlSize(.regular)
                }
            }

            extraContent()
        }
        .padding(14)
        .tahoeGlassCard(
            cornerRadius: 16,
            tint: granted ? .green : (isHighlighted ? TahoeUI.brandCobalt : nil)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    granted
                        ? Color.green.opacity(0.38)
                        : (isHighlighted ? TahoeUI.brandCobalt.opacity(0.68) : Color.clear),
                    lineWidth: isHighlighted ? 1.5 : 1.0
                )
        )
    }

    // MARK: - 折叠式疑难排查区（仅在检测到风险时默认展开）

    private var troubleshooterCard: some View {
        let hasWarning = store.isStaleSignaturePermissionRisk || store.isRunningOutsideApplications
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                    showTroubleshooter.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: hasWarning ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(hasWarning ? Color.orange : .secondary)
                    Text(hasWarning ? "检测到旧签名或非 /Applications 运行路径 · 点击排查修复" : "勾选后仍显示「待开启」？展开旧版签名冲突排查")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hasWarning ? Color.orange : .secondary)
                    Spacer()
                    Image(systemName: showTroubleshooter ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showTroubleshooter {
                Divider().opacity(0.35)

                VStack(alignment: .leading, spacing: 4) {
                    Text("当前签名：\(store.signingIdentityInfo.displayLabel)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("运行路径：\(store.signingIdentityInfo.bundlePath)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(store.isRunningOutsideApplications ? Color.orange : .secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Text(
                    store.isRunningOutsideApplications
                        ? "当前未从 /Applications/iClip.app 启动，同名多副本容易导致勾选错旧条目。建议移入应用程序目录后运行一键重置。"
                        : "若系统设置里已勾上同名 iClip 但仍未生效，通常是旧签名残留导致；点击下方「清理旧授权残留」后再重新勾选并重启即可。"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        store.resetStaleTCCPermissions()
                    } label: {
                        Label(store.isResettingTCCPermissions ? "清理中..." : "清理旧授权残留", systemImage: "arrow.uturn.backward.circle.fill")
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)
                    .disabled(store.isResettingTCCPermissions)

                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(store.oneClickPermissionFixCommand, forType: .string)
                        copiedCommand = true
                        store.showToast("已复制一键终端修复命令，在终端粘贴回车即可", duration: 3.4)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            copiedCommand = false
                        }
                    } label: {
                        Label(copiedCommand ? "已复制终端命令" : "复制一键修复命令", systemImage: copiedCommand ? "checkmark" : "terminal.fill")
                    }
                    .tahoeActionButtonStyle(prominent: false)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .tahoeGlassCard(cornerRadius: 14, tint: hasWarning ? .orange : nil)
    }

    // MARK: - 底部操作栏

    private var footerBar: some View {
        TahoeGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    store.refreshAllPermissionStatuses()
                    TactileFeedbackEngine.shared.perform(.tabSwitch)
                    if allGranted {
                        store.showToast("全部 3 项系统权限已就绪")
                    } else {
                        store.showToast("已刷新状态：当前 \(grantedCount)/3 项已就绪", duration: 2.2)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("立即复检")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if !allGranted {
                    Button {
                        store.relaunchApplication()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("重启生效")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Spacer()

                if allGranted {
                    Button(action: onContinueAfterGranted) {
                        HStack(spacing: 6) {
                            Text(
                                (viewModel.continueToOnboardingOnComplete || !InteractivePlaygroundController.shared.hasCompletedOnboarding)
                                    ? "继续入门引导"
                                    : "开始使用 iClip"
                            )
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .padding(.horizontal, 6)
                    }
                    .tahoeActionButtonStyle(prominent: true)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("稍后再说", action: onDeferForSession)
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            }
        }
    }
}
