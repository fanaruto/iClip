import AppKit
import Combine

/// 应用生命周期与菜单栏管理（感知当前编译角色并驱动对应全局快捷键通道）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: FloatingPanelController!
    private var statusDropView: StatusItemDropTargetView?
    private var statusFeedbackWorkItem: DispatchWorkItem?
    private var globalDragMonitor: Any?
    private var localDragMonitor: Any?
    private var lastObservedDragChangeCount: Int = -1
    private var isCurrentDragSessionEligible: Bool = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        _ = ClipboardStore.shared
        panelController = FloatingPanelController()

        setupStatusItem()
        setupGlobalHotKey()

        if !ProcessInfo.processInfo.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showFromStatusItem()
            }
        }

        // 启动后按用户绑定的目标角色检查对应通道的 GitHub Releases 更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let target = ClipboardStore.shared.targetRoleEdition
            UpdateManager.shared.checkForUpdates(targetEdition: target, silent: target == AppRoleEdition.installed)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = globalDragMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localDragMonitor {
            NSEvent.removeMonitor(monitor)
        }
        HotKeyManager.shared.unregister()
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

        let symbol = AppRoleEdition.installed == .developer ? "doc.on.clipboard" : "list.clipboard"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "iClip") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
        } else {
            button.title = "iClip"
        }

        updateStatusTooltip()
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        installStatusItemDropTarget(on: button)

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

    @objc private func menuOpenRoleSettings() {
        showFromStatusItem()
        panelController.nav.showSettings = true
        UpdateManager.shared.checkForUpdates(targetEdition: ClipboardStore.shared.targetRoleEdition, silent: false)
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

    // MARK: - 菜单栏图标拖放复制与黑洞奇点吞噬

    private func installStatusItemDropTarget(on button: NSStatusBarButton) {
        let dropView = StatusItemDropTargetView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.onHighlightChanged = { [weak self, weak button] highlighted in
            guard let self else { return }
            button?.highlight(highlighted)
            let anchor = self.statusItemScreenRect()
            if highlighted {
                BlackHolePortalController.shared.engage(anchorRect: anchor)
            } else {
                BlackHolePortalController.shared.disengageToApproachingOrDismiss(
                    mouseLocation: NSEvent.mouseLocation,
                    anchorRect: anchor
                )
            }
        }
        dropView.onPerformDrop = { [weak self] pasteboard in
            guard let self else { return false }
            let ok = ClipboardStore.shared.importAndCopy(from: pasteboard, sourceLabel: "黑洞吞噬")
            if ok {
                BlackHolePortalController.shared.triggerDevour()
                self.flashStatusItemCopiedFeedback()
            } else {
                BlackHolePortalController.shared.dismiss()
            }
            return ok
        }
        dropView.onLeftClick = { [weak self] in
            self?.toggleFromStatusItem()
        }
        dropView.onRightClick = { [weak self, weak button] in
            guard let self, let button else { return }
            self.showContextMenu(for: button)
        }
        button.addSubview(dropView)
        self.statusDropView = dropView

        // 绑定黑洞视界本体拖放与菜单栏图标状态联动
        BlackHolePortalController.shared.onPerformDrop = { [weak self] pasteboard in
            guard let self else { return false }
            let ok = ClipboardStore.shared.importAndCopy(from: pasteboard, sourceLabel: "黑洞吞噬")
            if ok {
                self.flashStatusItemCopiedFeedback()
            }
            return ok
        }
        BlackHolePortalController.shared.onPhaseChanged = { [weak self] phase in
            self?.syncStatusItemIcon(forBlackHolePhase: phase)
        }

        installGlobalDragProximityMonitor()
    }

    /// 监听全局拖拽移向屏幕顶部菜单栏 Logo：靠近引力半径时自动唤醒黑洞视界
    private func installGlobalDragProximityMonitor() {
        let dragPasteboard = NSPasteboard(name: .drag)
        lastObservedDragChangeCount = dragPasteboard.changeCount

        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleGlobalDragEvent(event)
            }
        }
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleGlobalDragEvent(event)
            return event
        }
    }

    private func handleGlobalDragEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            ClipboardStore.shared.markInternalDragEnded()
            if BlackHolePortalController.shared.phase != .devouring {
                BlackHolePortalController.shared.dismiss()
            }
            return
        }

        guard !ClipboardStore.shared.isInternalDragActive else { return }

        let dragPB = NSPasteboard(name: .drag)
        let currentCount = dragPB.changeCount
        if currentCount != lastObservedDragChangeCount {
            lastObservedDragChangeCount = currentCount
            isCurrentDragSessionEligible = ClipboardStore.canAcceptDrag(from: dragPB)
        }
        guard isCurrentDragSessionEligible, let anchor = statusItemScreenRect() else { return }

        let mouse = NSEvent.mouseLocation
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        let distance = hypot(mouse.x - center.x, mouse.y - center.y)

        if distance < 125 {
            BlackHolePortalController.shared.showApproaching(anchorRect: anchor)
        } else if distance > 165, BlackHolePortalController.shared.phase == .approaching {
            BlackHolePortalController.shared.dismiss()
        }
    }

    private func syncStatusItemIcon(forBlackHolePhase phase: BlackHolePortalController.Phase) {
        guard let button = statusItem.button, statusFeedbackWorkItem == nil else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbol: String
        switch phase {
        case .approaching, .engaged:
            symbol = "hurricane"
        case .devouring:
            symbol = "checkmark.circle.fill"
        case .hidden:
            symbol = AppRoleEdition.installed == .developer ? "doc.on.clipboard" : "list.clipboard"
        }
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: "iClip") {
            button.image = icon.withSymbolConfiguration(config)
            button.image?.isTemplate = true
        }
    }

    private func flashStatusItemCopiedFeedback() {
        guard let button = statusItem.button else { return }
        statusFeedbackWorkItem?.cancel()

        let normalSymbol = AppRoleEdition.installed == .developer ? "doc.on.clipboard" : "list.clipboard"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let checkImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已复制到剪贴板") {
            button.image = checkImage.withSymbolConfiguration(config)
            button.image?.isTemplate = true
        }

        let work = DispatchWorkItem { [weak self, weak button] in
            Task { @MainActor [weak self, weak button] in
                self?.statusFeedbackWorkItem = nil
                guard let button else { return }
                if let icon = NSImage(systemSymbolName: normalSymbol, accessibilityDescription: "iClip") {
                    button.image = icon.withSymbolConfiguration(config)
                    button.image?.isTemplate = true
                }
            }
        }
        statusFeedbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }
}

/// 覆盖在菜单栏图标上的轻量拖放接收视图：支持直接拖拽文字/图片/链接/文件到菜单栏图标触发黑洞吞噬复制，同时无损转发左右键点击
private final class StatusItemDropTargetView: NSView {
    var onHighlightChanged: ((Bool) -> Void)?
    var onPerformDrop: ((NSPasteboard) -> Bool)?
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ClipboardStore.supportedDragTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(ClipboardStore.supportedDragTypes)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?()
        } else {
            onLeftClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              !ClipboardStore.shared.isInternalDragActive,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else { return [] }
        onHighlightChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              !ClipboardStore.shared.isInternalDragActive,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHighlightChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onHighlightChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource == nil &&
        !ClipboardStore.shared.isInternalDragActive &&
        ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHighlightChanged?(false)
        return onPerformDrop?(sender.draggingPasteboard) ?? false
    }
}
