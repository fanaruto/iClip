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

        // 启动后按用户绑定的目标角色检查对应通道的 GitHub Releases 更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let target = ClipboardStore.shared.targetRoleEdition
            UpdateManager.shared.checkForUpdates(targetEdition: target, silent: target == AppRoleEdition.installed)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
        CursorDropPodController.shared.stopMonitoring()
        ClipboardStore.shared.stopMonitoring()
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        #if ICLIP_EDITION_FLOW
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        #else
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        #endif
        guard let button = statusItem.button else { return }

        let logoImage = BrandLogo.menuBarTemplateImage(pointSize: 17)
        button.image = logoImage
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading

        updateStatusTooltip()
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        #if ICLIP_EDITION_FLOW
        Publishers.CombineLatest(ClipboardStore.shared.$pasteQueueIDs, ClipboardStore.shared.$minimalModeEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] queueIDs, minimal in
                guard let btn = self?.statusItem.button else { return }
                btn.title = (minimal || queueIDs.isEmpty) ? "" : " \(queueIDs.count)"
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(ClipboardStore.shared.$hotKeyShortcut, ClipboardStore.shared.$queuePopShortcut)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateStatusTooltip()
            }
            .store(in: &cancellables)
        #else
        ClipboardStore.shared.$hotKeyShortcut
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusTooltip()
            }
            .store(in: &cancellables)
        #endif
    }

    private func updateStatusTooltip() {
        let editionName = AppRoleEdition.installed.title
        let hk = ClipboardStore.shared.hotKeyShortcut.compactDisplayString
        #if ICLIP_EDITION_FLOW
        let qk = ClipboardStore.shared.queuePopShortcut.compactDisplayString
        statusItem.button?.toolTip = "iClip · \(editionName)（\(hk) 呼出 · \(qk) 顺序出队）"
        #else
        statusItem.button?.toolTip = "iClip · \(editionName)（\(hk) 鼠标旁呼出）"
        #endif
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
        let installed = AppRoleEdition.installed

        let roleHeader = NSMenuItem(title: "当前角色：\(installed.title)", action: nil, keyEquivalent: "")
        roleHeader.isEnabled = false
        menu.addItem(roleHeader)

        let shortcutText = ClipboardStore.shared.hotKeyShortcut.compactDisplayString
        let openItem = NSMenuItem(title: "打开 iClip（\(shortcutText)）", action: #selector(menuOpenPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let switchRoleItem = NSMenuItem(title: "切换角色版本 / OTA 更新...", action: #selector(menuOpenRoleSettings), keyEquivalent: "")
        switchRoleItem.target = self
        menu.addItem(switchRoleItem)

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

        let pauseTitle = store.isPaused ? "恢复剪贴板记录" : "暂停剪贴板记录"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(menuTogglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

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
        UpdateManager.shared.checkForUpdates(targetEdition: ClipboardStore.shared.targetRoleEdition, silent: false)
    }

    @objc private func menuToggleAlwaysOnTop() {
        ClipboardStore.shared.toggleAlwaysOnTop()
    }

    @objc private func menuToggleMinimalMode() {
        ClipboardStore.shared.toggleMinimalMode()
    }

    @objc private func menuTogglePause() {
        ClipboardStore.shared.isPaused.toggle()
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
                self?.panelController.toggle(anchorRect: nil)
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
        #if ICLIP_EDITION_FLOW
        HotKeyManager.shared.registerQueuePopHotKey(shortcut: ClipboardStore.shared.queuePopShortcut) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !ClipboardStore.shared.minimalModeEnabled else { return }
                if self.panelController.isVisible {
                    self.panelController.hide(restoreFocus: true)
                }
                ClipboardStore.shared.dequeueAndPasteNext(showGlobalHUD: true)
            }
        }
        #endif
    }
}
