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
        guard totalCount > 0 else { return (0, nil) }

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
