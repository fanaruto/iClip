import Foundation
import CoreGraphics

/// 键鼠焦点防冲突守卫：
/// 当面板唤起滑入、方向键滚动、切换类目或输入检索词时锁定当前全局屏幕光标锚点；
/// 在鼠标发生真实物理位移（>= movementThreshold）前抑制静止光标触发的幽灵悬停抢焦点与误弹大图预览。
struct PointerSelectionGuard {
    private(set) var lockedMouseLocation: CGPoint? = nil
    private(set) var lockedAtUptime: TimeInterval = -100
    var movementThreshold: CGFloat = 3.5
    var minHoldDuration: TimeInterval = 0.04

    var isLocked: Bool {
        lockedMouseLocation != nil
    }

    /// 在面板唤起或键盘导航瞬间锁定当前全局光标坐标
    mutating func lock(at mouseLocation: CGPoint, uptime: TimeInterval) {
        lockedMouseLocation = mouseLocation
        lockedAtUptime = uptime
    }

    /// 鼠标真实点击卡片时立即解除锁定
    mutating func unlock() {
        lockedMouseLocation = nil
    }

    /// 判断当前全局光标位置是否允许触发悬停选中（发生真实物理移动后自动解锁放行）
    mutating func allowHoverSelection(currentMouseLocation: CGPoint, uptime: TimeInterval) -> Bool {
        guard let anchor = lockedMouseLocation else {
            return true
        }
        guard (uptime - lockedAtUptime) >= minHoldDuration else {
            return false
        }
        let dx = currentMouseLocation.x - anchor.x
        let dy = currentMouseLocation.y - anchor.y
        if hypot(dx, dy) >= movementThreshold {
            lockedMouseLocation = nil
            return true
        }
        return false
    }
}

/// 高速扫卡操作浮岛防频闪驻留门控（代际单调递增，快速经过不挂载重型操作钮，停驻 >= 42ms 后丝滑揭示）
struct HoverActionsDwellGate: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var isHovering: Bool = false

    mutating func beginHover() -> UInt64 {
        generation &+= 1
        isHovering = true
        return generation
    }

    func shouldReveal(for token: UInt64) -> Bool {
        isHovering && generation == token
    }

    mutating func endHover() {
        generation &+= 1
        isHovering = false
    }
}

/// O(1) 选区隔离总线：跨卡切换严格只回调失选行（false）与新选行（true），彻底消除整窗重算雪崩
@MainActor
final class PanelSelectionStore {
    private(set) var selectedIndex: Int = 0
    private var indexListeners: [Int: [UUID: (Bool) -> Void]] = [:]
    private var rangeListeners: [UUID: (range: ClosedRange<Int>, handler: (Bool) -> Void)] = [:]
    var onSelectionDidChange: ((_ oldIndex: Int, _ newIndex: Int) -> Void)?

    var activeIndexListenerCount: Int {
        indexListeners.values.reduce(0) { $0 + $1.count }
    }

    var activeRangeListenerCount: Int {
        rangeListeners.count
    }

    func setSelectedIndex(_ newIndex: Int) {
        guard newIndex != selectedIndex else { return }
        let oldIndex = selectedIndex
        selectedIndex = newIndex

        if let oldHandlers = indexListeners[oldIndex]?.values {
            for handler in Array(oldHandlers) {
                handler(false)
            }
        }
        if let newHandlers = indexListeners[newIndex]?.values {
            for handler in Array(newHandlers) {
                handler(true)
            }
        }
        if !rangeListeners.isEmpty {
            for entry in Array(rangeListeners.values) {
                let hadOld = oldIndex >= 0 && entry.range.contains(oldIndex)
                let hasNew = newIndex >= 0 && entry.range.contains(newIndex)
                if hadOld != hasNew {
                    entry.handler(hasNew)
                }
            }
        }
        onSelectionDidChange?(oldIndex, newIndex)
    }

    @discardableResult
    func registerIndexListener(for index: Int, handler: @escaping (Bool) -> Void) -> UUID {
        let token = UUID()
        indexListeners[index, default: [:]][token] = handler
        return token
    }

    func unregisterIndexListener(token: UUID, for index: Int) {
        guard var bucket = indexListeners[index] else { return }
        bucket.removeValue(forKey: token)
        if bucket.isEmpty {
            indexListeners.removeValue(forKey: index)
        } else {
            indexListeners[index] = bucket
        }
    }

    @discardableResult
    func registerRangeListener(for range: ClosedRange<Int>, handler: @escaping (Bool) -> Void) -> UUID {
        let token = UUID()
        rangeListeners[token] = (range: range, handler: handler)
        return token
    }

    func unregisterRangeListener(token: UUID) {
        rangeListeners.removeValue(forKey: token)
    }
}

/// 剪贴板混合列表（普通单行卡片 + 3 列图片网格）的二维方向键导航方向
enum PanelNavigationDirection {
    case up
    case down
    case left
    case right
}

/// 混合列表（单行卡片与 3 列图片网格混排）的二维键盘导航算法
enum GridNavigationHelper {
    /// 将过滤后的条目按视觉呈现拆分为二维行阵（每行保存原始 filteredItems 索引）
    /// - Parameters:
    ///   - isImageAt: 判断指定索引条目是否为图片
    ///   - count: 过滤后总条目数
    ///   - imageColumns: 图片网格列数（默认 3 列）
    static func buildVisualRows(count: Int, imageColumns: Int = 3, isImageAt: (Int) -> Bool) -> [[Int]] {
        guard count > 0 else { return [] }
        let cols = max(1, imageColumns)
        var rows: [[Int]] = []
        var imageChunk: [Int] = []
        imageChunk.reserveCapacity(cols)

        for idx in 0..<count {
            if isImageAt(idx) {
                imageChunk.append(idx)
                if imageChunk.count == cols {
                    rows.append(imageChunk)
                    imageChunk.removeAll(keepingCapacity: true)
                }
            } else {
                if !imageChunk.isEmpty {
                    rows.append(imageChunk)
                    imageChunk.removeAll(keepingCapacity: true)
                }
                rows.append([idx])
            }
        }
        if !imageChunk.isEmpty {
            rows.append(imageChunk)
        }
        return rows
    }

    /// 计算二维方向键移动后的目标索引
    /// - Parameters:
    ///   - currentIndex: 当前选中索引
    ///   - direction: 方向（上/下/左/右）
    ///   - visualRows: 由 `buildVisualRows` 生成的视觉行阵
    ///   - preferredColumn: 记忆的视觉列号（跨过单行卡片或短尾行时保持列对齐）
    /// - Returns: (新选中索引, 更新后的记忆列号)
    static func nextIndex(
        from currentIndex: Int,
        direction: PanelNavigationDirection,
        visualRows: [[Int]],
        preferredColumn: Int?
    ) -> (index: Int, preferredColumn: Int?) {
        let totalCount = visualRows.reduce(0) { $0 + $1.count }
        guard totalCount > 0 else { return (-1, nil) }

        if currentIndex < 0 {
            switch direction {
            case .up:
                let lastRow = visualRows[visualRows.count - 1]
                return (lastRow.first ?? 0, lastRow.count > 1 ? 0 : nil)
            case .down, .left, .right:
                let firstRow = visualRows[0]
                return (firstRow.first ?? 0, firstRow.count > 1 ? 0 : nil)
            }
        }

        let safeCurrent = min(max(currentIndex, 0), totalCount - 1)

        switch direction {
        case .left:
            let next = (safeCurrent - 1 + totalCount) % totalCount
            let nextCol = locate(next, in: visualRows)?.col
            return (next, nextCol)

        case .right:
            let next = (safeCurrent + 1) % totalCount
            let nextCol = locate(next, in: visualRows)?.col
            return (next, nextCol)

        case .up, .down:
            guard let pos = locate(safeCurrent, in: visualRows) else {
                return (safeCurrent, preferredColumn)
            }
            let rowCount = visualRows.count
            let targetRowIndex = direction == .up
                ? (pos.row - 1 + rowCount) % rowCount
                : (pos.row + 1) % rowCount

            let targetRow = visualRows[targetRowIndex]
            let currentRowIsGrid = visualRows[pos.row].count > 1
            let activePreferredCol = preferredColumn ?? (currentRowIsGrid ? pos.col : 0)
            let clampedCol = min(max(activePreferredCol, 0), targetRow.count - 1)

            // 停留在单列行时保留之前的列记忆；落到多列网格行时维持/更新列记忆
            let nextPreferredCol: Int? = (targetRow.count > 1 || currentRowIsGrid) ? activePreferredCol : nil
            return (targetRow[clampedCol], nextPreferredCol)
        }
    }

    private static func locate(_ index: Int, in visualRows: [[Int]]) -> (row: Int, col: Int)? {
        for (r, row) in visualRows.enumerated() {
            if let c = row.firstIndex(of: index) {
                return (r, c)
            }
        }
        return nil
    }
}

/// 自适应等高流式图片墙布局引擎：
/// - 根据每张图片的真实宽高比与当前面板内容宽度动态排布，竖图一行可排 4~6+ 张、宽屏横图占更多横向比重；
/// - 面板拉宽时自动增多每行张数并严格对齐左右边距，末行未满保持自然纵横比靠左排列。
enum AdaptiveImageWallLayout {
    static func aspectRatio(width: Int?, height: Int?) -> CGFloat {
        guard let w = width, let h = height, w > 0, h > 0 else { return 1.0 }
        let raw = CGFloat(w) / CGFloat(h)
        return min(max(raw, 0.52), 2.35)
    }

    static func buildRows<Item>(
        entries: [(index: Int, item: Item)],
        containerWidth: CGFloat,
        targetRowHeight: CGFloat = 104,
        minRowHeight: CGFloat = 78,
        maxRowHeight: CGFloat = 148,
        spacing: CGFloat = 8,
        dimensionsOf: (Item) -> (width: Int?, height: Int?)
    ) -> [[(index: Int, item: Item, width: CGFloat, height: CGFloat)]] {
        guard !entries.isEmpty else { return [] }
        let safeWidth = max(220, containerWidth)

        var rows: [[(index: Int, item: Item, width: CGFloat, height: CGFloat)]] = []
        var buffer: [(index: Int, item: Item, ratio: CGFloat)] = []
        var ratioSum: CGFloat = 0

        func flushFullRow(_ items: [(index: Int, item: Item, ratio: CGFloat)], sum: CGFloat) {
            guard !items.isEmpty else { return }
            let totalSpacing = spacing * CGFloat(max(0, items.count - 1))
            let available = max(80, safeWidth - totalSpacing)
            let rawHeight = available / max(0.25, sum)
            let clampedHeight = min(max(rawHeight, minRowHeight), maxRowHeight)

            var remainingWidth = available
            var placed: [(index: Int, item: Item, width: CGFloat, height: CGFloat)] = []
            placed.reserveCapacity(items.count)
            for (i, entry) in items.enumerated() {
                let w: CGFloat
                if i == items.count - 1 {
                    w = max(40, remainingWidth)
                } else {
                    let ideal = floor(available * (entry.ratio / max(0.001, sum)))
                    w = max(40, ideal)
                    remainingWidth -= w
                }
                placed.append((index: entry.index, item: entry.item, width: w, height: clampedHeight))
            }
            rows.append(placed)
        }

        for entry in entries {
            let dims = dimensionsOf(entry.item)
            let ratio = aspectRatio(width: dims.width, height: dims.height)
            let candidateRatioSum = ratioSum + ratio
            let nextCount = buffer.count + 1
            let totalSpacing = spacing * CGFloat(max(0, nextCount - 1))
            let predictedWidth = candidateRatioSum * targetRowHeight + totalSpacing

            buffer.append((index: entry.index, item: entry.item, ratio: ratio))
            ratioSum = candidateRatioSum

            if predictedWidth >= safeWidth * 0.94 || buffer.count >= 8 {
                flushFullRow(buffer, sum: ratioSum)
                buffer.removeAll(keepingCapacity: true)
                ratioSum = 0
            }
        }

        if !buffer.isEmpty {
            if buffer.count >= 2 {
                // 2 张及以上图片始终按宽高比权重 100% 铺满当前容器宽度，消除右侧大块留白
                flushFullRow(buffer, sum: ratioSum)
            } else if let solo = buffer.first {
                // 单张孤图严格按真实宽高比计算尺寸（保证 100% 保留完整纵横形态、不裁切顶部/底部文字）
                let dynamicMaxSoloH: CGFloat = min(244, max(168, floor(safeWidth * 0.42)))
                let naturalFullH = safeWidth / max(0.35, solo.ratio)
                let soloHeight = min(dynamicMaxSoloH, max(108, round(naturalFullH)))
                let soloWidth = min(safeWidth, max(88, floor(soloHeight * solo.ratio)))
                rows.append([(index: solo.index, item: solo.item, width: soloWidth, height: soloHeight)])
            }
        }

        return rows
    }
}
