import AppKit
import SwiftUI

/// 拖拽途中轻按 `⌥`（Option）原地召唤的「光标旁磁吸微落点（Cursor Drop Pod）」：
/// - 彻底替代反直觉的“跨全屏往顶部刘海/状态栏拖拽”，实现零远距离鼠标移动；
/// - 平时 100% 隐形且零轮询开销，仅当系统级外部拖拽进行中（NSPasteboard.drag 变更）且点按 ⌥ 键时在光标尖旁浮现；
/// - 智能感知拖入内容：普通文本/文件提供「存入剪贴板」单槽；图片自动提供「存入剪贴板 | 套圆角样机」双槽，松手即处理。
@MainActor
final class CursorDropPodController {
    static let shared = CursorDropPodController()

    enum DropSlot: Equatable {
        case none
        case copyStandard
        case copyMockup
    }

    enum DisplayState: Equatable {
        case ready(dualImageMode: Bool, activeSlot: DropSlot)
        case succeeded(title: String)
    }

    @MainActor
    fileprivate final class ViewModel: ObservableObject {
        @Published var state: DisplayState = .ready(dualImageMode: false, activeSlot: .none)
    }

    private var panel: NSPanel?
    private var bleedRootRef: LiquidGlassBleedRootView?
    private var glassRoot: NSView?
    private var dropReceiver: DropPodReceiverNSView?
    private var hostingView: NSHostingView<CursorDropPodView>?
    private let viewModel = ViewModel()

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragChangeCountAtMouseDown: Int = 0
    private var wasOptionPressed: Bool = false
    private var hideWorkItem: DispatchWorkItem?
    private var didCompleteDropInCurrentDrag: Bool = false

    var isMainPanelVisibleProvider: (() -> Bool)?

    private let singlePodSize = NSSize(width: 186, height: 46)
    private let dualPodSize = NSSize(width: 276, height: 46)

    nonisolated private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "heif", "gif", "bmp", "tiff", "tif"
    ]

    private init() {
        self.dragChangeCountAtMouseDown = dragPasteboard.changeCount
    }

    func startMonitoring() {
        guard globalFlagsMonitor == nil else { return }
        dragChangeCountAtMouseDown = dragPasteboard.changeCount

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleMouseEvent(event)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    func stopMonitoring() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m); globalFlagsMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
        dismissImmediately()
    }

    func dismissImmediately() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    // MARK: - 零功耗按需事件判定

    private func handleMouseEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            dragChangeCountAtMouseDown = dragPasteboard.changeCount
            didCompleteDropInCurrentDrag = false
        } else if event.type == .leftMouseUp {
            wasOptionPressed = false
            if panel?.isVisible == true {
                // 预留 140ms 让 AppKit 先完成 performDragOperation 回调再收起窗口
                scheduleFadeOut(after: didCompleteDropInCurrentDrag ? 0.58 : 0.14)
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let optionNow = flags == .option
        defer { wasOptionPressed = optionNow }

        // 第一道超轻量短路：未按住鼠标左键时 0 开销立即返回，日常打字绝无丝毫损耗
        guard (NSEvent.pressedMouseButtons & 1) != 0 else { return }
        guard optionNow && !wasOptionPressed else { return }

        let store = ClipboardStore.shared
        guard AdaptiveIntelligenceEngine.shared.cursorDropPodEnabled, !store.minimalModeEnabled else { return }
        guard !(isMainPanelVisibleProvider?() ?? false) else { return }
        guard !store.isInternalDragActive else { return }

        // 内核级拖拽会话校验：仅当系统拖拽剪贴板确实在本次按下左键后产生了新拖拽载荷时才召唤
        guard dragPasteboard.changeCount != dragChangeCountAtMouseDown,
              ClipboardStore.canAcceptDrag(from: dragPasteboard) else {
            return
        }

        if panel?.isVisible == true {
            scheduleFadeOut(after: 0.02)
        } else {
            let isImageDrag = Self.containsImageDragPayload(in: dragPasteboard)
            summonNearCursor(dualImageMode: isImageDrag)
        }
    }

    nonisolated static func containsImageDragPayload(in pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        let directImageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("com.compuserve.gif")
        ]
        if directImageTypes.contains(where: { types.contains($0) }) {
            return true
        }
        if types.contains(.fileURL),
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.count == 1 {
            let ext = urls[0].pathExtension.lowercased()
            return imageExtensions.contains(ext)
        }
        return false
    }

    // MARK: - 原生液态玻璃微落点窗口展现

    private func summonNearCursor(dualImageMode: Bool) {
        let size = dualImageMode ? dualPodSize : singlePodSize
        ensurePanel(size: size)
        guard let panel, let dropReceiver else { return }
        panel.sharingType = (ClipboardStore.shared.screenSharePrivacyEnabled && !ProcessInfo.processInfo.arguments.contains("--demo")) ? .none : .readOnly

        hideWorkItem?.cancel()
        didCompleteDropInCurrentDrag = false
        dropReceiver.dualImageMode = dualImageMode
        viewModel.state = .ready(dualImageMode: dualImageMode, activeSlot: .none)
        resizeIfNeeded(to: size)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        // 紧贴当前光标下方偏右 10pt，手指微移几毫米即可滑入对应功能槽
        var originX = mouse.x - 36
        originX = max(visible.minX + 10, min(originX, visible.maxX - size.width - 10))
        var originY = mouse.y - size.height - 10
        if originY < visible.minY + 10 {
            originY = min(visible.maxY - size.height - 10, mouse.y + 14)
        }

        panel.setFrameOrigin(NSPoint(x: originX, y: originY - 4))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        TactileFeedbackEngine.shared.performNavigationStepHaptic()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(NSPoint(x: originX, y: originY))
        }
    }

    private func resizeIfNeeded(to size: NSSize) {
        guard let panel, panel.frame.size != size else { return }
        panel.setContentSize(size)
        let rect = NSRect(origin: .zero, size: size)
        bleedRootRef?.frame = rect
        bleedRootRef?.cardFrame = rect
        glassRoot?.frame = rect
        dropReceiver?.frame = rect
        hostingView?.frame = rect
        if #available(macOS 26.0, *), let glass = glassRoot as? NSGlassEffectView {
            glass.cornerRadius = size.height / 2
        } else if let effect = glassRoot as? NSVisualEffectView {
            effect.maskImage = LiquidGlassSurfaceHost.continuousCornerMaskImage(size: size, radius: size.height / 2)
            effect.layer?.cornerRadius = size.height / 2
        }
        panel.invalidateShadow()
    }

    private func ensurePanel(size: NSSize) {
        guard panel == nil else { return }
        let rect = NSRect(origin: .zero, size: size)
        let p = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.sharingType = (ClipboardStore.shared.screenSharePrivacyEnabled && !ProcessInfo.processInfo.arguments.contains("--demo")) ? .none : .readOnly

        let swiftUIView = CursorDropPodView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.sizingOptions = []
        hosting.frame = rect
        hosting.autoresizingMask = [.width, .height]

        let receiver = DropPodReceiverNSView(frame: rect)
        receiver.autoresizingMask = [.width, .height]
        receiver.addSubview(hosting)

        receiver.onActiveSlotChanged = { [weak self] dualMode, slot in
            guard let self else { return }
            let prevSlot: DropSlot
            if case .ready(_, let s) = self.viewModel.state { prevSlot = s } else { prevSlot = .none }
            if prevSlot != slot && slot != .none {
                TactileFeedbackEngine.shared.performNavigationStepHaptic()
            }
            withAnimation(.easeOut(duration: 0.12)) {
                self.viewModel.state = .ready(dualImageMode: dualMode, activeSlot: slot)
            }
        }

        receiver.onPerformDrop = { [weak self] pb, slot in
            guard let self else { return false }
            return self.executeDrop(from: pb, slot: slot)
        }

        let bleedRoot = LiquidGlassBleedRootView(frame: rect, cardFrame: rect)
        bleedRoot.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: rect)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = size.height / 2
            glass.style = .regular
            glass.tintColor = nil
            glass.contentView = receiver
            bleedRoot.addSubview(glass)
            p.contentView = bleedRoot
            self.glassRoot = glass
        } else {
            let effect = NSVisualEffectView(frame: rect)
            effect.autoresizingMask = [.width, .height]
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = LiquidGlassSurfaceHost.continuousCornerMaskImage(size: size, radius: size.height / 2)
            effect.wantsLayer = true
            effect.layer?.cornerCurve = .continuous
            effect.layer?.cornerRadius = size.height / 2
            effect.layer?.masksToBounds = true
            effect.addSubview(receiver)
            bleedRoot.addSubview(effect)
            p.contentView = bleedRoot
            self.glassRoot = effect
        }

        self.bleedRootRef = bleedRoot
        self.hostingView = hosting
        self.dropReceiver = receiver
        self.panel = p
    }

    private func executeDrop(from pasteboard: NSPasteboard, slot: DropSlot) -> Bool {
        let store = ClipboardStore.shared
        let ok = store.importAndCopy(from: pasteboard, sourceLabel: "光标微落点")
        guard ok else { return false }

        didCompleteDropInCurrentDrag = true
        if slot == .copyMockup, store.lastImportedDragPNGData != nil {
            AdaptiveIntelligenceEngine.shared.recordActionUsed(actionID: "img-mockup", categoryKey: "image", sourceApp: "光标微落点")
            TactileFeedbackEngine.shared.perform(.magicTransform)
            store.convertLastImportedDragImageToMockup()
            withAnimation(.easeOut(duration: 0.14)) {
                viewModel.state = .succeeded(title: "已生成样机 · 直接 ⌘V")
            }
        } else {
            TactileFeedbackEngine.shared.perform(.pasteCommit)
            withAnimation(.easeOut(duration: 0.14)) {
                viewModel.state = .succeeded(title: "已存入剪贴板 · 可 ⌘V")
            }
        }

        scheduleFadeOut(after: 0.62)
        return true
    }

    private func scheduleFadeOut(after seconds: Double) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().alphaValue = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.panel?.orderOut(nil)
                }
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// 底层 AppKit 拖放目标接收容器：实时根据光标水平落点切分「存入剪贴板」与「套圆角样机」双热区
private final class DropPodReceiverNSView: NSView {
    var dualImageMode: Bool = false
    var onActiveSlotChanged: ((Bool, CursorDropPodController.DropSlot) -> Void)?
    var onPerformDrop: ((NSPasteboard, CursorDropPodController.DropSlot) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ClipboardStore.supportedDragTypes)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func resolveSlot(for sender: NSDraggingInfo) -> CursorDropPodController.DropSlot {
        guard dualImageMode else { return .copyStandard }
        let localPt = convert(sender.draggingLocation, from: nil)
        return (localPt.x >= bounds.width * 0.52) ? .copyMockup : .copyStandard
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else {
            return []
        }
        let slot = resolveSlot(for: sender)
        let dual = dualImageMode
        Task { @MainActor [weak self] in
            self?.onActiveSlotChanged?(dual, slot)
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard) else {
            return []
        }
        let slot = resolveSlot(for: sender)
        let dual = dualImageMode
        Task { @MainActor [weak self] in
            self?.onActiveSlotChanged?(dual, slot)
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        let dual = dualImageMode
        Task { @MainActor [weak self] in
            self?.onActiveSlotChanged?(dual, .none)
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource == nil && ClipboardStore.canAcceptDrag(from: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let slot = resolveSlot(for: sender)
        return MainActor.assumeIsolated {
            onPerformDrop?(sender.draggingPasteboard, slot) ?? false
        }
    }
}

private struct CursorDropPodView: View {
    @ObservedObject var viewModel: CursorDropPodController.ViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(colorScheme == .dark ? Color.black.opacity(0.48) : Color.white.opacity(0.70))

            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.10),
                    lineWidth: 0.7
                )

            switch viewModel.state {
            case .ready(let dualImageMode, let activeSlot):
                if dualImageMode {
                    HStack(spacing: 4) {
                        slotPill(
                            symbol: "tray.and.arrow.down.fill",
                            title: "存入剪贴板",
                            isActive: activeSlot == .copyStandard
                        )

                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 0.8, height: 20)

                        slotPill(
                            symbol: "sparkles.rectangle.stack",
                            title: "套圆角样机",
                            isActive: activeSlot == .copyMockup
                        )
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                } else {
                    slotPill(
                        symbol: "tray.and.arrow.down.fill",
                        title: activeSlot == .copyStandard ? "松手立即复制" : "松手存入 iClip",
                        isActive: activeSlot == .copyStandard
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                }

            case .succeeded(let title):
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.green)
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func slotPill(symbol: String, title: String, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : Color.accentColor)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule()
                .fill(isActive ? Color.accentColor : Color.clear)
        )
    }
}
