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
        AppInstallHelper.clearSelfQuarantineIfWritable()

        _ = ClipboardStore.shared
        panelController = FloatingPanelController()
        panelController.statusItemScreenRectProvider = { [weak self] in
            self?.statusItemScreenRect()
        }

        setupStatusItem()
        setupGlobalHotKey()
        CursorDropPodController.shared.startMonitoring()

        if !ProcessInfo.processInfo.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showFromStatusItem()
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
        HotKeyManager.shared.unregister()
        CursorDropPodController.shared.stopMonitoring()
        SystemQuickLookController.shared.dismissAndPurge(appSupportURL: ClipboardStore.shared.appSupportURL)
        ClipboardStore.shared.stopMonitoring()
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
        statusItem.button?.toolTip = "iClip（\(hk) 光标旁呼出）"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleFromStatusItem()
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu(for: sender)
        } else {
            toggleFromStatusItem()
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

    private func showContextMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()

        let versionHeader = NSMenuItem(title: "iClip v\(AppRoleEdition.currentVersionString)", action: nil, keyEquivalent: "")
        versionHeader.isEnabled = false
        menu.addItem(versionHeader)

        let shortcutText = ClipboardStore.shared.hotKeyShortcut.compactDisplayString
        let openItem = NSMenuItem(title: "打开 iClip（\(shortcutText)）", action: #selector(menuOpenPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let checkUpdateItem = NSMenuItem(title: "偏好设置与检查更新...", action: #selector(menuOpenRoleSettings), keyEquivalent: ",")
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)

        let onboardingItem = NSMenuItem(title: "查看新手与新功能引导...", action: #selector(menuShowOnboardingHighlights), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        let store = ClipboardStore.shared
        if !store.minimalModeEnabled {
            let pendingCount = store.pendingTodoCount
            let todoMenuTitle = pendingCount > 0 ? "打开待办清单（\(pendingCount) 项未完成）" : "打开待办清单（⌥2）"
            let openTodoItem = NSMenuItem(title: todoMenuTitle, action: #selector(menuOpenTodoList), keyEquivalent: "")
            openTodoItem.target = self
            menu.addItem(openTodoItem)

            let pinTodoItem = NSMenuItem(title: "钉住待办悬浮板（始终在前）", action: #selector(menuPinTodoBoard), keyEquivalent: "")
            pinTodoItem.state = (store.alwaysOnTop && panelController.nav.selectedTab == .todo) ? .on : .off
            pinTodoItem.target = self
            menu.addItem(pinTodoItem)
        }

        let alwaysOnTopItem = NSMenuItem(
            title: "窗口始终在前",
            action: #selector(menuToggleAlwaysOnTop),
            keyEquivalent: "p"
        )
        alwaysOnTopItem.state = store.alwaysOnTop ? .on : .off
        alwaysOnTopItem.target = self
        menu.addItem(alwaysOnTopItem)

        let minimalItem = NSMenuItem(
            title: "极简纯净模式（基础功能版）",
            action: #selector(menuToggleMinimalMode),
            keyEquivalent: ""
        )
        minimalItem.state = store.minimalModeEnabled ? .on : .off
        minimalItem.target = self
        menu.addItem(minimalItem)

        if store.isPaused {
            let resumeItem = NSMenuItem(title: "立即恢复剪贴板记录", action: #selector(menuResumeCapture), keyEquivalent: "")
            resumeItem.target = self
            menu.addItem(resumeItem)
        } else {
            let pause15Item = NSMenuItem(title: "无痕暂停 15 分钟（自动恢复）", action: #selector(menuPause15Minutes), keyEquivalent: "")
            pause15Item.target = self
            menu.addItem(pause15Item)

            let pause60Item = NSMenuItem(title: "无痕暂停 60 分钟（自动恢复）", action: #selector(menuPause60Minutes), keyEquivalent: "")
            pause60Item.target = self
            menu.addItem(pause60Item)

            let pauseIndefItem = NSMenuItem(title: "持续暂停剪贴板记录", action: #selector(menuTogglePause), keyEquivalent: "")
            pauseIndefItem.target = self
            menu.addItem(pauseIndefItem)
        }

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "清空未收藏历史", action: #selector(menuClearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

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

    @objc private func menuOpenRoleSettings() {
        showFromStatusItem()
        panelController.nav.showSettings = true
        UpdateManager.shared.checkForUpdates(silent: false)
    }

    @objc private func menuShowOnboardingHighlights() {
        panelController.nav.showSettings = false
        showFromStatusItem()
        InteractivePlaygroundController.shared.showHighlights()
    }

    @objc private func menuToggleAlwaysOnTop() {
        ClipboardStore.shared.toggleAlwaysOnTop()
    }

    @objc private func menuToggleMinimalMode() {
        ClipboardStore.shared.toggleMinimalMode()
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
