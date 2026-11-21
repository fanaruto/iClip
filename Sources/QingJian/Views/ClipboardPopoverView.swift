import SwiftUI
import AppKit

/// 键盘导航与出场动效控制桥接器
@MainActor
final class PanelNavigationModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var selectedTab: ClipFilterTab = .all
    @Published var selectedIndex: Int = 0
    @Published var focusTrigger: UUID = UUID()
    @Published var showSettings: Bool = false
    @Published var isPresented: Bool = false
    @Published var presentationEpoch: Int = 0

    func resetOnOpen() {
        searchText = ""
        selectedIndex = 0
        showSettings = false
        presentationEpoch &+= 1
        focusTrigger = UUID()
    }
}

/// 主面板视图（iOS 风格毛玻璃卡片容器）
struct ClipboardPopoverView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var nav: PanelNavigationModel
    @ObservedObject private var updater = UpdateManager.shared
    let onDismiss: () -> Void
    let onQuit: () -> Void

    @Namespace private var tabNamespace
    @FocusState private var isSearchFocused: Bool
    @State private var hoveredImageItem: ClipItem? = nil
    @State private var hoveredImageInUpperHalf: Bool = true

    /// 列表行模型：连续图片自动聚合成 3 列网格，非图片保持单行精致卡片
    private enum DisplayRow: Identifiable {
        case standard(index: Int, item: ClipItem)
        case imageGrid(entries: [(index: Int, item: ClipItem)])

        var id: String {
            switch self {
            case .standard(_, let item):
                return "row-\(item.id.uuidString)"
            case .imageGrid(let entries):
                return "grid-\(entries.first?.item.id.uuidString ?? "empty")"
            }
        }
    }

    var filteredItems: [ClipItem] {
        store.items.filter { item in
            let tabMatches: Bool
            switch nav.selectedTab {
            case .all: tabMatches = true
            case .pinned: tabMatches = item.isPinned
            case .text: tabMatches = item.type == .text
            case .link: tabMatches = item.type == .link
            case .image: tabMatches = item.type == .image
            case .file: tabMatches = item.type == .file
            }
            return tabMatches && item.matches(query: nav.searchText)
        }
    }

    private var displayRows: [DisplayRow] {
        var rows: [DisplayRow] = []
        var imageBuffer: [(index: Int, item: ClipItem)] = []

        for (index, item) in filteredItems.enumerated() {
            if item.type == .image {
                imageBuffer.append((index: index, item: item))
            } else {
                if !imageBuffer.isEmpty {
                    rows.append(.imageGrid(entries: imageBuffer))
                    imageBuffer.removeAll()
                }
                rows.append(.standard(index: index, item: item))
            }
        }

        if !imageBuffer.isEmpty {
            rows.append(.imageGrid(entries: imageBuffer))
        }

        return rows
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                if nav.showSettings {
                    settingsView
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    filterBar
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)

                    Divider()
                        .opacity(0.35)

                    contentList
                        .transition(.opacity)

                    Divider()
                        .opacity(0.35)

                    footerBar
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
            }

            // iOS 灵动胶囊轻提示
            if let message = store.toastMessage {
                toastPill(message)
                    .padding(.bottom, 46)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 420, height: 560)
        .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(nav.isPresented ? 0.42 : 0.05),
                            Color.white.opacity(0.14),
                            Color.white.opacity(0.06)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color.black.opacity(nav.isPresented ? 0.28 : 0.0),
            radius: nav.isPresented ? 22 : 4,
            y: nav.isPresented ? 12 : 0
        )
        // 顶部 3D 透视瀑布弹性滑落
        .scaleEffect(nav.isPresented ? 1.0 : 0.92, anchor: .top)
        .rotation3DEffect(
            .degrees(nav.isPresented ? 0 : -11),
            axis: (x: 1, y: 0, z: 0),
            anchor: .top,
            perspective: 0.55
        )
        .offset(y: nav.isPresented ? 0 : -34)
        .opacity(nav.isPresented ? 1 : 0)
        .blur(radius: nav.isPresented ? 0 : 3.5)
        .padding(24)
        .frame(width: 468, height: 608)
        .animation(
            nav.isPresented
                ? .spring(response: 0.42, dampingFraction: 0.78)
                : .spring(response: 0.2, dampingFraction: 0.92),
            value: nav.isPresented
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: nav.showSettings)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: store.toastMessage)
        .onChange(of: nav.focusTrigger) { _, _ in
            hoveredImageItem = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
        .onChange(of: nav.searchText) { _, _ in
            nav.selectedIndex = 0
            hoveredImageItem = nil
        }
        .onChange(of: nav.selectedTab) { _, _ in
            nav.selectedIndex = 0
            hoveredImageItem = nil
        }
        .onChange(of: nav.showSettings) { _, showing in
            hoveredImageItem = nil
            if showing {
                store.refreshAccessibilityStatus()
            }
        }
    }

    // MARK: - 顶部胶囊搜索栏

    private var headerBar: some View {
        HStack(spacing: 8) {
            if nav.showSettings {
                Button {
                    nav.showSettings = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("轻剪设置")
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))

                Spacer()

                Color.clear.frame(width: 60, height: 1)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("搜索剪贴历史...", text: $nav.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, design: .rounded))
                        .focused($isSearchFocused)

                    if !nav.searchText.isEmpty {
                        Button {
                            nav.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.07))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
                )

                // 暂停/恢复监听按钮
                Button {
                    store.isPaused.toggle()
                    store.showToast(store.isPaused ? "已暂停记录剪贴板" : "已恢复记录剪贴板")
                } label: {
                    Image(systemName: store.isPaused ? "pause.circle.fill" : "record.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(store.isPaused ? Color.orange : Color.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(store.isPaused ? "点击恢复记录" : "暂停记录剪贴板")

                // 设置按钮（有 GitHub 新版本时右上角展示蓝点提示）
                Button {
                    store.refreshAccessibilityStatus()
                    nav.showSettings = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.primary.opacity(0.06)))

                        if updater.hasUpdateAvailable {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
                                .offset(x: -1, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(updater.hasUpdateAvailable ? "发现新版本，点击进入设置更新" : "偏好设置")
            }
        }
    }

    // MARK: - iOS 滑动胶囊分类条

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(ClipFilterTab.allCases) { tab in
                let isSelected = nav.selectedTab == tab
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        nav.selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5.5)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                                    .shadow(color: Color.black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "activeTabPill", in: tabNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.06))
        )
    }

    // MARK: - 剪贴记录列表

    private let imageGridColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 9),
        count: 3
    )

    private var contentList: some View {
        GeometryReader { listGeo in
            ZStack(alignment: hoveredImageInUpperHalf ? .bottom : .top) {
                if filteredItems.isEmpty {
                    emptyStateView
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 10) {
                                ForEach(Array(displayRows.enumerated()), id: \.element.id) { rowIndex, row in
                                    switch row {
                                    case .standard(let index, let item):
                                        ClipCardView(
                                            item: item,
                                            index: index,
                                            isSelected: index == nav.selectedIndex,
                                            onSelect: {
                                                nav.selectedIndex = index
                                            },
                                            onCopy: { plainTextOnly in
                                                store.copyAndOptionallyPaste(
                                                    item,
                                                    plainTextOnly: plainTextOnly,
                                                    shouldAutoPaste: true,
                                                    onBeforePaste: onDismiss
                                                )
                                            },
                                            onTogglePin: {
                                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                    store.togglePin(item)
                                                }
                                            },
                                            onDelete: {
                                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                                    store.delete(item)
                                                    clampSelection()
                                                }
                                            }
                                        )
                                        .cascadeAppear(
                                            isPresented: nav.isPresented,
                                            delay: Double(min(rowIndex, 8)) * 0.028
                                        )
                                        .id(item.id)

                                    case .imageGrid(let entries):
                                        LazyVGrid(columns: imageGridColumns, spacing: 9) {
                                            ForEach(Array(entries.enumerated()), id: \.element.item.id) { colIndex, entry in
                                                ClipImageGridTile(
                                                    item: entry.item,
                                                    index: entry.index,
                                                    isSelected: entry.index == nav.selectedIndex,
                                                    onSelect: {
                                                        nav.selectedIndex = entry.index
                                                    },
                                                    onCopy: {
                                                        hoveredImageItem = nil
                                                        store.copyAndOptionallyPaste(
                                                            entry.item,
                                                            plainTextOnly: false,
                                                            shouldAutoPaste: true,
                                                            onBeforePaste: onDismiss
                                                        )
                                                    },
                                                    onTogglePin: {
                                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                            store.togglePin(entry.item)
                                                        }
                                                    },
                                                    onDelete: {
                                                        if hoveredImageItem?.id == entry.item.id {
                                                            hoveredImageItem = nil
                                                        }
                                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                                            store.delete(entry.item)
                                                            clampSelection()
                                                        }
                                                    },
                                                    onHoverChange: { hovering, midY in
                                                        if hovering {
                                                            hoveredImageInUpperHalf = midY < (listGeo.size.height * 0.5)
                                                            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                                                                hoveredImageItem = entry.item
                                                            }
                                                        } else if hoveredImageItem?.id == entry.item.id {
                                                            withAnimation(.easeOut(duration: 0.14)) {
                                                                hoveredImageItem = nil
                                                            }
                                                        }
                                                    }
                                                )
                                                .cascadeAppear(
                                                    isPresented: nav.isPresented,
                                                    delay: Double(min(rowIndex, 7)) * 0.028 + Double(min(colIndex, 8)) * 0.02
                                                )
                                                .id(entry.item.id)
                                            }
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                        .onChange(of: nav.selectedIndex) { _, newIndex in
                            guard newIndex >= 0, newIndex < filteredItems.count else { return }
                            withAnimation(.easeOut(duration: 0.14)) {
                                proxy.scrollTo(filteredItems[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }

                // 悬停图片时智能避让的高清大图预览浮层
                if let previewItem = hoveredImageItem {
                    ImageHoverPreviewOverlay(item: previewItem)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        .zIndex(50)
                }
            }
            .coordinateSpace(name: "clipListArea")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 64, height: 64)
                Image(systemName: nav.searchText.isEmpty ? "clipboard" : "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text(nav.searchText.isEmpty ? "暂无剪贴记录" : "未找到匹配的内容")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.8))
            Text(nav.searchText.isEmpty ? "复制文本、链接、图片或文件后将自动出现在这里" : "试试更换关键词或切换上方分类")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部状态栏

    private var footerBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.isPaused ? Color.orange : Color.green)
                    .frame(width: 6.5, height: 6.5)
                Text("\(filteredItems.count) 条记录")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                keyHint("↵", "粘贴")
                keyHint("↑↓", "选择")
                keyHint("ESC", "关闭")
            }

            if !store.items.filter({ !$0.isPinned }).isEmpty {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        store.clearUnpinned()
                        nav.selectedIndex = 0
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("清空未固定记录")
            }
        }
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - iOS 风格设置页

    private var settingsView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                // 行为分组
                settingsGroup(title: "粘贴行为") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("选中后自动粘贴")
                                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                            Text("点击或按回车后自动向当前应用发送 ⌘V")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $store.autoPasteEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.4)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("辅助功能权限")
                                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                            Text(store.isAccessibilityGranted ? "已授权，支持一键直接粘贴" : "未授权，当前仅复制到剪贴板")
                                .font(.system(size: 11.5))
                                .foregroundStyle(store.isAccessibilityGranted ? .green : .orange)
                        }
                        Spacer()
                        if store.isAccessibilityGranted {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 17))
                        } else {
                            Button {
                                store.refreshAccessibilityStatus()
                                if store.isAccessibilityGranted {
                                    store.showToast("已检测到辅助功能授权")
                                } else {
                                    store.showToast("仍未生效：若已勾选旧版，请减号移除后重勾")
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(Color.primary.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .help("立即重新检测权限状态")

                            Button("前往开启") {
                                store.requestAccessibilityPermission()
                                store.openAccessibilitySettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }

                // 软件更新分组（GitHub Releases OTA）
                settingsGroup(title: "软件更新（GitHub OTA）") {
                    updateSectionContent
                }

                // 存储分组
                settingsGroup(title: "存储上限") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("保留最近未固定记录数（固定记录不受限制）")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $store.maxHistoryCount) {
                            Text("50 条").tag(50)
                            Text("100 条").tag(100)
                            Text("200 条").tag(200)
                            Text("500 条").tag(500)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                // 快捷键说明
                settingsGroup(title: "快捷键一览") {
                    shortcutRow("全局呼出 / 隐藏", "⌥ V")
                    Divider().opacity(0.35)
                    shortcutRow("复制并粘贴选中项", "↵ 回车")
                    Divider().opacity(0.35)
                    shortcutRow("快速粘贴前 9 条", "⌘ 1 ~ 9")
                    Divider().opacity(0.35)
                    shortcutRow("删除当前选中项", "⌘ ⌫")
                }

                // 底部操作
                HStack(spacing: 10) {
                    Button {
                        store.clearUnpinned()
                        nav.showSettings = false
                    } label: {
                        Text("清空未固定历史")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.14)))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onQuit()
                    } label: {
                        Text("退出轻剪")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.14)))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
            )
        }
    }

    private func shortcutRow(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, design: .rounded))
            Spacer()
            Text(shortcut)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
    }

    @ViewBuilder
    private var updateSectionContent: some View {
        switch updater.state {
        case .idle:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前版本 v\(updater.currentVersion)")
                        .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    Text("直接从 GitHub Releases 下载新包并自动重启更新")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("检查更新") {
                    updater.checkForUpdates(silent: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在从 GitHub 检查新版本...")
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
            }

        case .upToDate(let latest):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已是最新版本（v\(updater.currentVersion)）")
                        .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    Text("GitHub 最新版本 v\(latest)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("重新检查") {
                    updater.checkForUpdates(silent: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .available(let info):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("发现新版本 v\(info.version)")
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                        Text("当前 v\(updater.currentVersion) · 包体约 \(Self.formatBytes(info.assetSize))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("立即 OTA 更新") {
                        updater.startOTAUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if !info.notes.isEmpty {
                    Text(info.notes)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
            }

        case .downloading(let progress, let info):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("正在下载 v\(info.version)...")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("取消") {
                        updater.cancelDownload()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

        case .installing(let info):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在安装 v\(info.version) 并自动重启...")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }

        case .failed(let message):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("更新检查未完成")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("重试") {
                    updater.checkForUpdates(silent: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        }
        return "\(max(1, bytes / 1024)) KB"
    }

    // MARK: - 轻提示胶囊

    private func toastPill(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.78))
                    .shadow(color: Color.black.opacity(0.2), radius: 8, y: 3)
            )
    }

    // MARK: - 键盘控制辅助

    func moveSelection(delta: Int) {
        let count = filteredItems.count
        guard count > 0 else { return }
        nav.selectedIndex = (nav.selectedIndex + delta + count) % count
    }

    func pasteSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        store.copyAndOptionallyPaste(item, plainTextOnly: false, shouldAutoPaste: true, onBeforePaste: onDismiss)
    }

    func pasteItem(at index: Int) {
        guard index >= 0, index < filteredItems.count else { return }
        let item = filteredItems[index]
        store.copyAndOptionallyPaste(item, plainTextOnly: false, shouldAutoPaste: true, onBeforePaste: onDismiss)
    }

    func deleteSelected() {
        guard nav.selectedIndex >= 0, nav.selectedIndex < filteredItems.count else { return }
        let item = filteredItems[nav.selectedIndex]
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            store.delete(item)
            clampSelection()
        }
    }

    private func clampSelection() {
        let count = filteredItems.count
        if count == 0 {
            nav.selectedIndex = 0
        } else if nav.selectedIndex >= count {
            nav.selectedIndex = count - 1
        }
    }
}

/// 卡片瀑布错峰浮现动效修饰器
private struct CascadeAppearModifier: ViewModifier {
    let isPresented: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .offset(y: isPresented ? 0 : -16)
            .scaleEffect(isPresented ? 1 : 0.94, anchor: .top)
            .animation(
                isPresented
                    ? .spring(response: 0.36, dampingFraction: 0.78).delay(delay)
                    : .easeOut(duration: 0.12),
                value: isPresented
            )
    }
}

private extension View {
    func cascadeAppear(isPresented: Bool, delay: Double) -> some View {
        modifier(CascadeAppearModifier(isPresented: isPresented, delay: delay))
    }
}

/// 系统级原生毛玻璃背景封装
struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
