import AppKit
import Combine

/// 应用生命周期与菜单栏管理（感知当前编译角色并驱动对应全局快捷键通道）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: FloatingPanelController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        DiagnosticLogService.shared.installAndScanOnLaunch()
        AppInstallHelper.clearSelfQuarantineIfWritable()

        _ = ClipboardStore.shared
        panelController = FloatingPanelController()
        panelController.statusItemScreenRectProvider = { [weak self] in
            self?.statusItemScreenRect()
        }

        wireWindowCoordinator()
        setupStatusItem()
        setupGlobalHotKey()
        CursorDropPodController.shared.startMonitoring()

        let orb = FloatingSpriteOrbController.shared
        orb.onToggleClipboardPanel = { [weak self] orbRect in
            self?.panelController.toggle(anchorRect: orbRect, anchorPlacement: .sideOfOrb)
        }
        orb.onOpenTodoList = { [weak self] in
            self?.menuOpenTodoList()
        }
        orb.onOpenSettings = { [weak self] in
            self?.menuOpenStandaloneSettings()
        }
        ActionSparkController.shared.spriteOrbAnchorFrameProvider = {
            FloatingSpriteOrbController.shared.visibleOrbCoreScreenFrame
        }
        ActionSparkController.shared.onSuggestionVisibilityChanged = { active, categoryKey, actionID in
            FloatingSpriteOrbController.shared.setSmartSuggestionState(active: active, categoryKey: categoryKey, actionID: actionID)
        }
        ActionSparkController.shared.onSuggestionAccepted = { _ in
            FloatingSpriteOrbController.shared.triggerSuggestionAcceptedPulse()
        }
        ActionSparkController.shared.onSuggestionDismissed = {
            FloatingSpriteOrbController.shared.triggerSuggestionDismissedPulse()
        }
        orb.start(store: ClipboardStore.shared)

        if !ProcessInfo.processInfo.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                guard let self else { return }
                let store = ClipboardStore.shared
                store.refreshAllPermissionStatuses()
                if store.isPermissionGateActive {
                    AppWindowCoordinator.shared.presentPermissionSetup(
                        store: store,
                        continueToOnboardingOnComplete: !InteractivePlaygroundController.shared.hasCompletedOnboarding
                    )
                } else if !InteractivePlaygroundController.shared.hasCompletedOnboarding {
                    AppWindowCoordinator.shared.presentOnboarding(store: store, forceRestart: false)
                } else {
                    self.showFromStatusItem()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                AppInstallHelper.promptMoveToApplicationsIfNeeded()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            UpdateManager.shared.checkForUpdates(silent: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppWindowCoordinator.shared.dismissAllStandaloneWindows()
        HotKeyManager.shared.unregister()
        ScreenshotOverlayController.shared.dismissImmediately()
        FloatingSpriteOrbController.shared.stop()
        CursorDropPodController.shared.stopMonitoring()
        BigBangStageController.shared.dismissImmediatelyAndPurge()
        SystemQuickLookController.shared.dismissAndPurge(appSupportURL: ClipboardStore.shared.appSupportURL)
        ClipboardStore.shared.stopMonitoring()
    }

    // MARK: - 独立窗口协调与原生主菜单（确保 ⌘, / ⌘W / ⌘C / ⌘V / ⌘Q 在独立窗完美响应）

    private func wireWindowCoordinator() {
        let coordinator = AppWindowCoordinator.shared
        coordinator.onOpenMainPanel = { [weak self] tab, createTemplate in
            guard let self else { return }
            self.panelController.nav.showSettings = false
            if let tab {
                if tab == .todo && ClipboardStore.shared.minimalModeEnabled {
                    ClipboardStore.shared.minimalModeEnabled = false
                }
                self.panelController.nav.selectedTab = tab
            }
            if createTemplate {
                if ClipboardStore.shared.minimalModeEnabled {
                    ClipboardStore.shared.minimalModeEnabled = false
                }
                self.panelController.nav.selectedTab = .pinned
                self.panelController.nav.isCreatingTemplate = true
            }
            self.showFromStatusItem()
        }
        coordinator.onHideNonPinnedMainPanel = { [weak self] in
            guard let self, !ClipboardStore.shared.alwaysOnTop else { return }
            self.panelController.hide(restoreFocus: false)
        }
        coordinator.onSuspendMainPanelKeyboardCapture = { [weak self] in
            self?.panelController.yieldKeyboardFocusForStandaloneWindow()
        }
        coordinator.onStandaloneWindowVisibilityChanged = { [weak self] anyVisible in
            self?.panelController.syncLevelForStandaloneWindows(hasVisibleStandaloneWindow: anyVisible)
        }
        coordinator.onShowAppearanceLivePreview = { [weak self] anchorFrame in
            self?.panelController.showLiveAppearancePreview(beside: anchorFrame)
        }
        coordinator.onHideAppearanceLivePreview = { [weak self] in
            self?.panelController.hideLiveAppearancePreviewIfNeeded()
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "iClip")
        let settingsItem = NSMenuItem(title: "偏好设置…", action: #selector(menuOpenStandaloneSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        let permissionsItem = NSMenuItem(title: "权限授权中心…", action: #selector(menuOpenPermissionSetup), keyEquivalent: "")
        permissionsItem.target = self
        appMenu.addItem(permissionsItem)
        let onboardingItem = NSMenuItem(title: "新手入门引导…", action: #selector(menuShowOnboardingHighlights), keyEquivalent: "")
        onboardingItem.target = self
        appMenu.addItem(onboardingItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 iClip", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        let logoImage = BrandLogo.menuBarTemplateImage(pointSize: 17)
        button.image = logoImage
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading

        updateStatusTooltip()
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        ClipboardStore.shared.$hotKeyShortcut
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusTooltip()
            }
            .store(in: &cancellables)
    }

    private func updateStatusTooltip() {
        let hk = ClipboardStore.shared.hotKeyShortcut.compactDisplayString
        statusItem.button?.toolTip = "iClip（左键设置 · 右键简约菜单 · \(hk) 呼出面板）"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            menuOpenStandaloneSettings()
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu(for: sender)
        } else {
            // 左键单击状态栏直接打开独立苹果风偏好设置（已在前台时轻点收起）
            if SettingsWindowController.shared.isVisibleAndKey {
                SettingsWindowController.shared.close()
            } else {
                menuOpenStandaloneSettings()
            }
        }
    }

    private func toggleFromStatusItem() {
        panelController.toggle(anchorRect: statusItemScreenRect())
    }

    private func showFromStatusItem() {
        panelController.show(anchorRect: statusItemScreenRect())
    }

    private func statusItemScreenRect() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// 简约果味右键菜单（仅保留最高频核心项，其余设置均收归左键直开的独立偏好设置窗）
    private func showContextMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()
        let store = ClipboardStore.shared
        store.refreshAllPermissionStatuses()

        let shortcutText = store.hotKeyShortcut.compactDisplayString
        let openItem = NSMenuItem(title: "打开剪贴板（\(shortcutText)）", action: #selector(menuOpenPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let shotText = store.screenshotHotKeyShortcut.compactDisplayString
        let screenshotItem = NSMenuItem(title: "区域 / 窗口截图（\(shotText)）", action: #selector(menuTriggerScreenshot), keyEquivalent: "")
        screenshotItem.target = self
        menu.addItem(screenshotItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "偏好设置…", action: #selector(menuOpenStandaloneSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if store.isPaused {
            let resumeItem = NSMenuItem(title: "恢复剪贴板记录", action: #selector(menuResumeCapture), keyEquivalent: "")
            resumeItem.target = self
            menu.addItem(resumeItem)
        } else {
            let pauseRoot = NSMenuItem(title: "无痕暂停记录", action: nil, keyEquivalent: "")
            let pauseSubmenu = NSMenu()

            let pause15 = NSMenuItem(title: "暂停 15 分钟（推荐 · 自动恢复）", action: #selector(menuPause15Minutes), keyEquivalent: "")
            pause15.target = self
            pauseSubmenu.addItem(pause15)

            let pause60 = NSMenuItem(title: "暂停 60 分钟（自动恢复）", action: #selector(menuPause60Minutes), keyEquivalent: "")
            pause60.target = self
            pauseSubmenu.addItem(pause60)

            pauseSubmenu.addItem(.separator())

            let pauseForever = NSMenuItem(title: "持续暂停（直到手动恢复）", action: #selector(menuTogglePause), keyEquivalent: "")
            pauseForever.target = self
            pauseSubmenu.addItem(pauseForever)

            pauseRoot.submenu = pauseSubmenu
            menu.addItem(pauseRoot)
        }

        let pendingPermissions = (store.isAccessibilityGranted ? 0 : 1)
            + (store.isFullDiskAccessGranted ? 0 : 1)
            + (store.isScreenRecordingGranted ? 0 : 1)
        if pendingPermissions > 0 {
            let permissionItem = NSMenuItem(title: "权限授权中心（待开启 \(pendingPermissions) 项）…", action: #selector(menuOpenPermissionSetup), keyEquivalent: "")
            permissionItem.target = self
            menu.addItem(permissionItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 iClip", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenPanel() {
        showFromStatusItem()
    }

    @objc private func menuTriggerScreenshot() {
        ScreenshotOverlayController.shared.startCapture(store: ClipboardStore.shared)
    }

    @objc private func menuOpenTodoList() {
        let store = ClipboardStore.shared
        if store.minimalModeEnabled {
            store.minimalModeEnabled = false
        }
        panelController.nav.selectedTab = .todo
        showFromStatusItem()
    }

    @objc private func menuPinTodoBoard() {
        let store = ClipboardStore.shared
        if store.minimalModeEnabled {
            store.minimalModeEnabled = false
        }
        if !store.alwaysOnTop {
            store.alwaysOnTop = true
        }
        panelController.nav.selectedTab = .todo
        showFromStatusItem()
        store.showToast("已钉住待办悬浮板（⌘P 可取消置顶）")
    }

    @objc private func menuOpenStandaloneSettings() {
        AppWindowCoordinator.shared.presentSettings(
            section: .appearance,
            store: ClipboardStore.shared,
            checkUpdates: false
        )
    }

    @objc private func menuOpenPermissionSetup() {
        AppWindowCoordinator.shared.presentPermissionSetup(
            store: ClipboardStore.shared,
            highlight: nil,
            continueToOnboardingOnComplete: false
        )
    }

    @objc private func menuOpenRoleSettings() {
        AppWindowCoordinator.shared.presentSettings(
            section: .permissionsAndAbout,
            store: ClipboardStore.shared,
            checkUpdates: true
        )
    }

    @objc private func menuShowOnboardingHighlights() {
        AppWindowCoordinator.shared.presentOnboarding(
            store: ClipboardStore.shared,
            forceRestart: false
        )
    }

    @objc private func menuToggleAlwaysOnTop() {
        ClipboardStore.shared.toggleAlwaysOnTop()
    }

    @objc private func menuToggleMinimalMode() {
        ClipboardStore.shared.toggleMinimalMode()
    }

    @objc private func menuToggleSpriteOrb() {
        ClipboardStore.shared.spriteOrbEnabled.toggle()
    }

    @objc private func menuResumeCapture() {
        ClipboardStore.shared.resumeCapture()
    }

    @objc private func menuPause15Minutes() {
        ClipboardStore.shared.pauseCapture(forMinutes: 15)
        ClipboardStore.shared.showToast("已开启 15 分钟无痕暂停（到点自动恢复）")
    }

    @objc private func menuPause60Minutes() {
        ClipboardStore.shared.pauseCapture(forMinutes: 60)
        ClipboardStore.shared.showToast("已开启 60 分钟无痕暂停（到点自动恢复）")
    }

    @objc private func menuTogglePause() {
        ClipboardStore.shared.pauseCapture(forMinutes: nil)
    }

    @objc private func menuClearHistory() {
        ClipboardStore.shared.clearUnpinned()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - 全局快捷键

    private func setupGlobalHotKey() {
        HotKeyManager.shared.registerToggleHotKey(shortcut: ClipboardStore.shared.hotKeyShortcut) { [weak self] in
            Task { @MainActor [weak self] in
                self?.panelController.toggle(anchorRect: nil, isFromGlobalHotKey: true)
            }
        }
        HotKeyManager.shared.registerScreenshotHotKey(shortcut: ClipboardStore.shared.screenshotHotKeyShortcut) {
            Task { @MainActor in
                ScreenshotOverlayController.shared.startCapture(store: ClipboardStore.shared)
            }
        }
        HotKeyManager.shared.registerCopyAppendHotKey { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      !ClipboardStore.shared.minimalModeEnabled,
                      AdaptiveIntelligenceEngine.shared.copyAppendEnabled else { return }
                if self.panelController.isVisible {
                    self.panelController.appendSelectedCardToClipboard()
                } else {
                    ClipboardStore.shared.triggerGlobalCopyAppend()
                }
            }
        }
    }
}
