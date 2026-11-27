import AppKit
import SwiftUI

/// 长按拖拽排序纯算法求解器（脱离 AppKit 依赖，100% 单元测试覆盖）
enum ClipReorderSwapSolver {
    struct RowSlot: Equatable {
        let itemID: UUID
        let minY: CGFloat
        let height: CGFloat
        let isLockedBottom: Bool

        var midY: CGFloat { minY + height * 0.5 }
    }

    /// 根据当前被拖起卡片的视觉中心 Y 与相邻可排序行槽位，计算是否应平滑换位（带 18% 防抖死区且严禁越过底部锁定区）
    static func resolveSwapTarget(
        draggedID: UUID,
        dragOffsetY: CGFloat,
        slots: [RowSlot]
    ) -> (targetID: UUID, anchorCompensationY: CGFloat)? {
        guard let currentIndex = slots.firstIndex(where: { $0.itemID == draggedID }) else {
            return nil
        }
        let current = slots[currentIndex]
        guard !current.isLockedBottom else { return nil }

        let draggedMidY = current.midY + dragOffsetY

        // 向下拖动：跨越下一张可排序卡片中线 + 18% 迟滞死区
        if dragOffsetY > 0, currentIndex + 1 < slots.count {
            let next = slots[currentIndex + 1]
            guard !next.isLockedBottom else { return nil }
            let threshold = next.midY + min(12, next.height * 0.14)
            if draggedMidY > threshold {
                let step = max(24, next.minY - current.minY)
                return (next.itemID, step)
            }
        }

        // 向上拖动：跨越上一张可排序卡片中线 - 18% 迟滞死区
        if dragOffsetY < 0, currentIndex - 1 >= 0 {
            let prev = slots[currentIndex - 1]
            guard !prev.isLockedBottom else { return nil }
            let threshold = prev.midY - min(12, prev.height * 0.14)
            if draggedMidY < threshold {
                let step = max(24, current.minY - prev.minY)
                return (prev.itemID, -step)
            }
        }

        return nil
    }

    /// 将拖拽纵向偏移安全夹紧在可排序内容区域内，绝不覆盖底部固定区与已完成待办区
    static func clampOffsetY(
        rawOffsetY: CGFloat,
        draggedID: UUID,
        slots: [RowSlot]
    ) -> CGFloat {
        guard let idx = slots.firstIndex(where: { $0.itemID == draggedID }) else {
            return rawOffsetY
        }
        let movable = slots.filter { !$0.isLockedBottom }
        guard let first = movable.first, let last = movable.last else {
            return 0
        }
        let current = slots[idx]
        let minAllowed = (first.minY - current.minY) - 10
        let maxAllowed = (last.minY - current.minY) + 10
        return min(max(rawOffsetY, minAllowed), maxAllowed)
    }
}

/// 120Hz 丝滑长按拖动排序协调器：
/// - 轻点 / 双击 → 正常粘贴或复制（零影响）；
/// - 立即拖出 → 正常 `.onDrag` 拖拽到微信 / Cursor / 访达（零影响）；
/// - 重按 Force Touch → 正常预览 / 大爆炸（自动取消待定长按，零冲突）；
/// - 原地长按 0.24s → 触感微震浮起卡片，原生本地鼠标事件追踪 120Hz 顺滑换位，底部已完成待办与底栏纹丝不动。
@MainActor
final class ClipReorderCoordinator: ObservableObject {
    @Published private(set) var draggedItemID: UUID? = nil
    @Published private(set) var dragOffsetY: CGFloat = 0
    @Published private(set) var isLifted: Bool = false

    var isReordering: Bool { draggedItemID != nil }

    /// 刚结束长按排序的短时防误点粘贴时间戳（防止松手瞬间触发 onTapGesture 误粘贴）
    private var suppressedTapItemID: UUID? = nil
    private var suppressedTapUntil: TimeInterval = 0

    /// 可见行局部几何缓存（仅按 ID 记录 minY / height / 是否属于底部锁定区）
    private var rowFrameCache: [UUID: (minY: CGFloat, height: CGFloat, isLockedBottom: Bool)] = [:]
    private var orderedVisibleIDs: [UUID] = []

    /// 挂起的长按识别器（原地按住 >= 0.24s 且位移 < 7pt 自动进入排序模式）
    private var armWorkItem: DispatchWorkItem?
    private var armedItemID: UUID? = nil
    private var armedStartScreenPoint: NSPoint = .zero
    private var preDragMonitor: Any?

    /// 活跃排序态的 120Hz 鼠标事件监听器与光标锚点
    private var activeDragMonitor: Any?
    private var anchorMouseScreenY: CGFloat = 0
    private var onSwapItems: ((_ draggedID: UUID, _ targetID: UUID) -> Void)?
    private var onCommitOrder: (() -> Void)?

    func updateRowGeometry(itemID: UUID, minY: CGFloat, height: CGFloat, isLockedBottom: Bool) {
        rowFrameCache[itemID] = (minY, height, isLockedBottom)
    }

    func syncVisibleOrder(_ ids: [UUID]) {
        orderedVisibleIDs = ids
        if rowFrameCache.count > max(80, ids.count * 2) {
            let active = Set(ids)
            rowFrameCache = rowFrameCache.filter { active.contains($0.key) }
        }
    }

    /// 消费刚完成排序的防误粘贴保护
    func consumeTapSuppressionIfNeeded(for itemID: UUID) -> Bool {
        guard suppressedTapItemID == itemID else { return false }
        suppressedTapItemID = nil
        return ProcessInfo.processInfo.systemUptime <= suppressedTapUntil
    }

    /// 外部手势（如 Force Touch 重按、滚轮滚动、隐藏面板）触发时立即安全取消挂起或进行中的排序
    func cancelAll() {
        cancelPendingArm()
        finishActiveReorder(commit: false)
    }

    /// 卡片按下鼠标左键时预备长按检测（不阻断立即拖出外部 `.onDrag` 或普通单击）
    func beginPotentialLongPress(
        itemID: UUID,
        isLockedBottom: Bool,
        isAllowed: Bool,
        onSwap: @escaping (_ draggedID: UUID, _ targetID: UUID) -> Void,
        onCommit: @escaping () -> Void
    ) {
        guard isAllowed, !isLockedBottom, !isReordering else { return }
        cancelPendingArm()

        let startPt = NSEvent.mouseLocation
        armedItemID = itemID
        armedStartScreenPoint = startPt
        onSwapItems = onSwap
        onCommitOrder = onCommit

        preDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            guard let self, self.armedItemID == itemID else { return event }
            if event.type == .leftMouseUp || event.type == .rightMouseDown {
                self.cancelPendingArm()
                return event
            }
            if event.type == .leftMouseDragged {
                let nowPt = NSEvent.mouseLocation
                let dist = hypot(nowPt.x - self.armedStartScreenPoint.x, nowPt.y - self.armedStartScreenPoint.y)
                // 用户立刻拖走（位移 > 7pt）：说明意图是向外部应用拖出内容，静默让路给 `.onDrag`
                if dist > 7.0 {
                    self.cancelPendingArm()
                }
            }
            return event
        }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.armedItemID == itemID else { return }
                let nowPt = NSEvent.mouseLocation
                let dist = hypot(nowPt.x - self.armedStartScreenPoint.x, nowPt.y - self.armedStartScreenPoint.y)
                guard dist <= 7.0, (NSEvent.pressedMouseButtons & 1) != 0 else {
                    self.cancelPendingArm()
                    return
                }
                self.activateReorderMode(for: itemID, currentScreenPoint: nowPt)
            }
        }
        armWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func cancelPendingArm() {
        armWorkItem?.cancel()
        armWorkItem = nil
        armedItemID = nil
        if let m = preDragMonitor {
            NSEvent.removeMonitor(m)
            preDragMonitor = nil
        }
    }

    private func activateReorderMode(for itemID: UUID, currentScreenPoint: NSPoint) {
        cancelPendingArm()

        anchorMouseScreenY = currentScreenPoint.y
        draggedItemID = itemID
        dragOffsetY = 0
        withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
            isLifted = true
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        TactileFeedbackEngine.shared.perform(.tabSwitch)

        activeDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self, self.isReordering else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.finishActiveReorder(commit: false)
                    return nil
                }
                return event
            }
            if event.type == .leftMouseUp {
                self.finishActiveReorder(commit: true)
                return nil
            }
            if event.type == .leftMouseDragged {
                self.handleActiveMouseDrag(screenPoint: NSEvent.mouseLocation)
                // 吞掉事件防止 AppKit 启动外部 .onDrag 会话冲突
                return nil
            }
            return event
        }
    }

    private func handleActiveMouseDrag(screenPoint: NSPoint) {
        guard let draggedID = draggedItemID else { return }
        // macOS 屏幕坐标系 Y 向上递增，SwiftUI 列表 Y 向下递增
        let rawDeltaY = anchorMouseScreenY - screenPoint.y
        let slots = currentSlots()
        let clampedY = ClipReorderSwapSolver.clampOffsetY(
            rawOffsetY: rawDeltaY,
            draggedID: draggedID,
            slots: slots
        )
        dragOffsetY = clampedY

        if let swap = ClipReorderSwapSolver.resolveSwapTarget(
            draggedID: draggedID,
            dragOffsetY: clampedY,
            slots: slots
        ) {
            anchorMouseScreenY -= swap.anchorCompensationY
            dragOffsetY = ClipReorderSwapSolver.clampOffsetY(
                rawOffsetY: anchorMouseScreenY - screenPoint.y,
                draggedID: draggedID,
                slots: slots
            )
            onSwapItems?(draggedID, swap.targetID)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func currentSlots() -> [ClipReorderSwapSolver.RowSlot] {
        orderedVisibleIDs.compactMap { id in
            guard let frame = rowFrameCache[id] else { return nil }
            return ClipReorderSwapSolver.RowSlot(
                itemID: id,
                minY: frame.minY,
                height: frame.height,
                isLockedBottom: frame.isLockedBottom
            )
        }
    }

    private func finishActiveReorder(commit: Bool) {
        if let m = activeDragMonitor {
            NSEvent.removeMonitor(m)
            activeDragMonitor = nil
        }
        guard let finishedID = draggedItemID else { return }
        suppressedTapItemID = finishedID
        suppressedTapUntil = ProcessInfo.processInfo.systemUptime + 0.25

        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
            dragOffsetY = 0
            isLifted = false
            draggedItemID = nil
        }

        if commit {
            onCommitOrder?()
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        onSwapItems = nil
        onCommitOrder = nil
    }
}

/// 轻量化行坐标与长按左键监听探针（零 GeometryReader 布局开销、完全透传鼠标事件）
struct ReorderLongPressMouseProbe: NSViewRepresentable {
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onMouseDown = onMouseDown
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onMouseDown = onMouseDown
    }

    final class ProbeView: NSView {
        var onMouseDown: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    guard let self, let win = self.window, event.window === win else { return event }
                    let localPt = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(localPt) {
                        self.onMouseDown?()
                    }
                    return event
                }
            } else if window == nil, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // 100% 鼠标透传，绝不阻断卡片内任何按钮、链接、复选框或 .onDrag
            nil
        }

        deinit {
            if let m = monitor {
                NSEvent.removeMonitor(m)
            }
        }
    }
}
