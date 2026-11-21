import AppKit
import Combine

/// 应用生命周期与菜单栏管理
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: FloatingPanelController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 纯菜单栏常驻模式，不在程序坞显示图标
        NSApp.setActivationPolicy(.accessory)

        // 初始化剪贴板服务与悬浮窗
        _ = ClipboardStore.shared
        panelController = FloatingPanelController()

        setupStatusItem()
        setupGlobalHotKey()

        // 首次启动后轻柔弹出一次面板，方便用户立刻上手（演示模式由面板自行编排）
        if !ProcessInfo.processInfo.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showFromStatusItem()
            }
        }

        // 后台静默检查一次 GitHub Releases 更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            UpdateManager.shared.checkForUpdates(silent: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
        ClipboardStore.shared.stopMonitoring()
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        if let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "iClip") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
            button.image?.isTemplate = true
        } else {
            button.title = "iClip"
        }

        button.toolTip = "iClip（\(ClipboardStore.shared.hotKeyShortcut.compactDisplayString) 鼠标旁呼出）"
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        ClipboardStore.shared.$hotKeyShortcut
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] shortcut in
                self?.statusItem.button?.toolTip = "iClip（\(shortcut.compactDisplayString) 鼠标旁呼出）"
            }
            .store(in: &cancellables)
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

        let shortcutText = ClipboardStore.shared.hotKeyShortcut.compactDisplayString
        let openItem = NSMenuItem(title: "打开 iClip（\(shortcutText)）", action: #selector(menuOpenPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let store = ClipboardStore.shared
        let pauseTitle = store.isPaused ? "恢复剪贴板记录" : "暂停剪贴板记录"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(menuTogglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "清空未固定历史", action: #selector(menuClearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let updateItem = NSMenuItem(title: "检查 GitHub 更新...", action: #selector(menuCheckUpdate), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

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

    @objc private func menuTogglePause() {
        ClipboardStore.shared.isPaused.toggle()
    }

    @objc private func menuClearHistory() {
        ClipboardStore.shared.clearUnpinned()
    }

    @objc private func menuCheckUpdate() {
        showFromStatusItem()
        UpdateManager.shared.checkForUpdates(silent: false)
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
    }
}
