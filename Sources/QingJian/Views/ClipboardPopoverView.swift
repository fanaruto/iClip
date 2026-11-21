import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// 列表行模型：连续图片自动聚合成 3 列网格，非图片保持单行精致卡片
enum ClipDisplayRow: Identifiable {
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

/// 键盘导航、筛选缓存与出场动效控制桥接器（仅在数据/搜索/分类变动时重算列表，悬停与方向键零开销）
@MainActor
final class PanelNavigationModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var selectedTab: ClipFilterTab = .all
    @Published var selectedIndex: Int = 0
    @Published var focusTrigger: UUID = UUID()
    @Published var showSettings: Bool = false
    @Published var isPresented: Bool = false
    @Published var presentationEpoch: Int = 0
    @Published var scrollRequestEpoch: Int = 0
    @Published var isRecordingHotKey: Bool = false
    @Published var demoPreviewIndex: Int? = nil
    var suppressAutoHide: Bool = false

    private(set) var cachedFilteredItems: [ClipItem] = []
    private(set) var cachedDisplayRows: [ClipDisplayRow] = []
    private var cancellables = Set<AnyCancellable>()

    init(store: ClipboardStore? = nil) {
        let resolvedStore = store ?? .shared
        rebuildCache(items: resolvedStore.items, tab: selectedTab, query: searchText)

        Publishers.CombineLatest3(resolvedStore.$items, $selectedTab, $searchText)
            .sink { [weak self] items, tab, query in
                self?.rebuildCache(items: items, tab: tab, query: query)
            }
            .store(in: &cancellables)
    }

    private func rebuildCache(items: [ClipItem], tab: ClipFilterTab, query: String) {
        let filtered = items.filter { item in
            let tabMatches: Bool
            switch tab {
            case .all: tabMatches = true
            case .pinned: tabMatches = item.isPinned
            case .text: tabMatches = item.type == .text
            case .link: tabMatches = item.type == .link
            case .image: tabMatches = item.type == .image
            case .file: tabMatches = item.type == .file
            }
            return tabMatches && item.matches(query: query)
        }

        var rows: [ClipDisplayRow] = []
        rows.reserveCapacity(filtered.count)
        var imageBuffer: [(index: Int, item: ClipItem)] = []

        for (index, item) in filtered.enumerated() {
            if item.type == .image {
                imageBuffer.append((index: index, item: item))
            } else {
                if !imageBuffer.isEmpty {
                    rows.append(.imageGrid(entries: imageBuffer))
                    imageBuffer.removeAll(keepingCapacity: true)
                }
                rows.append(.standard(index: index, item: item))
            }
        }
        if !imageBuffer.isEmpty {
            rows.append(.imageGrid(entries: imageBuffer))
        }

        self.cachedFilteredItems = filtered
        self.cachedDisplayRows = rows
    }

    func resetOnOpen() {
        searchText = ""
        selectedIndex = 0
        showSettings = false
        isRecordingHotKey = false
        suppressAutoHide = false
        presentationEpoch &+= 1
        focusTrigger = UUID()
    }
}

/// 主面板视图（苹果原生毛玻璃 / 液态玻璃内容层）
struct ClipboardPopoverView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var nav: PanelNavigationModel
    @ObservedObject private var updater = UpdateManager.shared
    let onDismiss: () -> Void
    let onQuit: () -> Void

    @Namespace private var tabNamespace
    @FocusState private var isSearchFocused: Bool
    @State private var previewItem: ClipItem? = nil
    @State private var previewTileRect: CGRect = .zero
    @State private var isPreviewVisible: Bool = false
    @State private var hoveredTileItemID: UUID? = nil
    @State private var previewHideWorkItem: DispatchWorkItem? = nil

    var filteredItems: [ClipItem] {
        nav.cachedFilteredItems
    }

    private var displayRows: [ClipDisplayRow] {
        nav.cachedDisplayRows
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

                    if !store.borderlessPanel {
                        Divider()
                            .opacity(0.28)
                    }

                    contentList
                        .transition(.opacity)

                    if !store.borderlessPanel {
                        Divider()
                            .opacity(0.28)
                    }

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
        .overlay {
            if !store.borderlessPanel {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        // 纯净原图放大预览浮层
        .overlay {
            ImageHoverPreviewLayer(
                item: previewItem,
                tileRect: previewTileRect,
                isVisible: isPreviewVisible,
                panelSize: CGSize(width: 420, height: 560)
            )
        }
        .coordinateSpace(name: "panelRoot")
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: nav.showSettings)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: store.toastMessage)
        .onChange(of: nav.isPresented) { _, presented in
            if presented {
                store.onPanelShown(visibleItems: filteredItems)
            } else {
                dismissImagePreview(clearItem: true)
                store.onPanelHidden()
            }
        }
        .onChange(of: nav.focusTrigger) { _, _ in
            dismissImagePreview(clearItem: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
        .onChange(of: nav.searchText) { _, _ in
            nav.selectedIndex = 0
            dismissImagePreview(clearItem: true)
        }
        .onChange(of: nav.selectedTab) { _, _ in
            nav.selectedIndex = 0
            dismissImagePreview(clearItem: true)
        }
        .onChange(of: nav.demoPreviewIndex) { _, targetIdx in
            if let idx = targetIdx, idx >= 0, idx < filteredItems.count {
                let item = filteredItems[idx]
                nav.selectedIndex = idx
                // 估算第 1 行 3 列图片格在面板内的真实位置触发原生纯净原图放大浮层
                let col = max(0, min(2, idx - 1))
                let tileRect = CGRect(x: 14 + CGFloat(col) * 134, y: 196, width: 124, height: 98)
                handleImageHover(item: item, hovering: true, tileRect: tileRect)
            } else {
                dismissImagePreview(clearItem: true)
            }
        }
        .onChange(of: nav.showSettings) { _, showing in
            dismissImagePreview(clearItem: true)
            if showing {
                store.refreshAccessibilityStatus()
            } else if nav.isRecordingHotKey {
                nav.isRecordingHotKey = false
                HotKeyManager.shared.resumeAfterRecording()
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
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 13.5, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text("iClip 设置")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Color.clear.frame(width: 48, height: 1)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("搜索剪贴历史...", text: $nav.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
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
                .overlay {
                    if !store.borderlessPanel {
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
                    }
                }

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
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
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
        Group {
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
                                        surfaceStyle: store.surfaceStyle,
                                        borderlessPanel: store.borderlessPanel,
                                        onSelect: {
                                            nav.selectedIndex = index
                                        },
                                        onPaste: { plainTextOnly in
                                            store.copyAndOptionallyPaste(
                                                item,
                                                plainTextOnly: plainTextOnly,
                                                shouldAutoPaste: true,
                                                onBeforePaste: onDismiss
                                            )
                                        },
                                        onCopyOnly: { plainTextOnly in
                                            store.copyAndOptionallyPaste(
                                                item,
                                                plainTextOnly: plainTextOnly,
                                                shouldAutoPaste: false,
                                                onBeforePaste: nil
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
                                                onPaste: {
                                                    dismissImagePreview(clearItem: true)
                                                    store.copyAndOptionallyPaste(
                                                        entry.item,
                                                        plainTextOnly: false,
                                                        shouldAutoPaste: true,
                                                        onBeforePaste: onDismiss
                                                    )
                                                },
                                                onCopyOnly: {
                                                    store.copyAndOptionallyPaste(
                                                        entry.item,
                                                        plainTextOnly: false,
                                                        shouldAutoPaste: false,
                                                        onBeforePaste: nil
                                                    )
                                                },
                                                onTogglePin: {
                                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                        store.togglePin(entry.item)
                                                    }
                                                },
                                                onDelete: {
                                                    if previewItem?.id == entry.item.id {
                                                        dismissImagePreview(clearItem: true)
                                                    }
                                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                                        store.delete(entry.item)
                                                        clampSelection()
                                                    }
                                                },
                                                onHoverChange: { hovering, tileRect in
                                                    handleImageHover(item: entry.item, hovering: hovering, tileRect: tileRect)
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
                    .onChange(of: nav.scrollRequestEpoch) { _, _ in
                        let idx = nav.selectedIndex
                        guard idx >= 0, idx < filteredItems.count else { return }
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo(filteredItems[idx].id, anchor: .center)
                        }
                    }
                }
            }
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
                .font(.system(size: 14, weight: .medium))
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
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                keyHint("双击/↵", "键入")
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
                .font(.system(size: 10, weight: .semibold))
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
                // 外观材质分组（苹果官方液态玻璃 / 毛玻璃，支持官方透明/着色档位与蒙版浓度无级调节）
                settingsGroup(title: "外观与边缘材质") {
                    HStack {
                        Text("窗口材质")
                            .font(.system(size: 13.5, weight: .medium))
                        Spacer()
                        Picker("", selection: $store.surfaceStyle) {
                            ForEach(PanelSurfaceStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 176)
                    }

                    if store.surfaceStyle == .liquidGlass {
                        Divider().opacity(0.35)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("液态风格")
                                    .font(.system(size: 13.5, weight: .medium))
                                Text("对应系统 Liquid Glass 透明 / 着色官方样式")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $store.liquidGlassAppearance) {
                                ForEach(LiquidGlassAppearance.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 128)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("液态蒙版浓度")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(Int(round(store.liquidGlassMaskOpacity * 100)))%")
                                    .font(.system(size: 12, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $store.liquidGlassMaskOpacity, in: 0.0...1.0)
                                .controlSize(.small)
                        }
                    }

                    Divider().opacity(0.35)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("纯净无边框")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("去除外框与卡片描边，只保留纯粹玻璃质感")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $store.borderlessPanel)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                // 通用与快捷键分组（开机自启 + 自定义全局快捷键）
                settingsGroup(title: "通用与快捷键") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自动启动")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("登录 macOS 后自动在菜单栏常驻运行")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLogin($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }

                    Divider().opacity(0.35)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("全局呼出快捷键")
                                .font(.system(size: 13.5, weight: .medium))
                            Text(nav.isRecordingHotKey ? "请直接按下新组合键，按 ESC 取消" : "点击右侧按键录制自定义组合键")
                                .font(.system(size: 11.5))
                                .foregroundStyle(nav.isRecordingHotKey ? Color.accentColor : .secondary)
                        }
                        Spacer()

                        Button {
                            if nav.isRecordingHotKey {
                                nav.isRecordingHotKey = false
                                HotKeyManager.shared.resumeAfterRecording()
                            } else {
                                HotKeyManager.shared.suspendForRecording()
                                nav.isRecordingHotKey = true
                            }
                        } label: {
                            Text(nav.isRecordingHotKey ? "等待按键..." : store.hotKeyShortcut.displayString)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(nav.isRecordingHotKey ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(nav.isRecordingHotKey ? Color.accentColor : Color.primary.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)

                        if store.hotKeyShortcut != .defaultShortcut && !nav.isRecordingHotKey {
                            Button {
                                store.hotKeyShortcut = .defaultShortcut
                                store.showToast("已恢复默认快捷键 ⌥ V")
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.primary.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .help("恢复默认 ⌥ V")
                        }
                    }
                }

                // 行为分组
                settingsGroup(title: "粘贴行为") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("双击直接键入光标处")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("双击卡片或按回车后自动键入当前应用光标所在位置")
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
                                .font(.system(size: 13.5, weight: .medium))
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

                // 隐私忽略应用白名单分组
                settingsGroup(title: "隐私忽略应用") {
                    Text("来自以下应用的复制内容将被自动忽略，不会记录到历史")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    if store.ignoredApps.isEmpty {
                        Text("暂未设置忽略应用")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary.opacity(0.8))
                            .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(store.ignoredApps) { app in
                                HStack(spacing: 8) {
                                    if let icon = store.appIcon(forBundleID: app.bundleIdentifier) {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 18, height: 18)
                                    } else {
                                        Image(systemName: "app.dashed")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18, height: 18)
                                    }

                                    Text(app.displayName)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)

                                    Spacer()

                                    Button {
                                        withAnimation(.easeOut(duration: 0.16)) {
                                            store.removeIgnoredApp(bundleIdentifier: app.bundleIdentifier)
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary.opacity(0.75))
                                    }
                                    .buttonStyle(.plain)
                                    .help("移出忽略名单")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Menu {
                            let candidates = store.runningCandidateAppsForIgnore()
                            if candidates.isEmpty {
                                Text("暂无可添加的运行中应用")
                            } else {
                                ForEach(candidates) { candidate in
                                    Button(candidate.displayName) {
                                        store.addIgnoredApp(
                                            bundleIdentifier: candidate.bundleIdentifier,
                                            displayName: candidate.displayName
                                        )
                                    }
                                }
                            }
                        } label: {
                            Label("添加运行中应用", systemImage: "plus.circle")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        Spacer()

                        Button("选择应用...") {
                            pickAppToIgnore()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                settingsGroup(title: "快捷键与交互") {
                    shortcutRow("鼠标旁呼出 / 隐藏", store.hotKeyShortcut.displayString)
                    Divider().opacity(0.35)
                    shortcutRow("直接键入光标所在区域", "双击 / ↵")
                    Divider().opacity(0.35)
                    shortcutRow("快速键入前 9 条", "⌘ 1 ~ 9")
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
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    Button {
                        onQuit()
                    } label: {
                        Text("退出 iClip")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.10)))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        }
    }

    private func shortcutRow(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Text(shortcut)
                .font(.system(size: 11.5, weight: .semibold))
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
                        .font(.system(size: 13.5, weight: .medium))
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
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }

        case .upToDate(let latest):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已是最新版本（v\(updater.currentVersion)）")
                        .font(.system(size: 13.5, weight: .medium))
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
                            .font(.system(size: 13.5, weight: .semibold))
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
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11.5, weight: .semibold))
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
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }

        case .failed(let message):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("更新检查未完成")
                        .font(.system(size: 13, weight: .medium))
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
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.78))
                    .shadow(color: Color.black.opacity(0.2), radius: 8, y: 3)
            )
    }

    // MARK: - 图片悬停纯净原图预览控制

    private func handleImageHover(item: ClipItem, hovering: Bool, tileRect: CGRect) {
        if hovering {
            previewHideWorkItem?.cancel()
            previewHideWorkItem = nil
            hoveredTileItemID = item.id

            let wasVisible = isPreviewVisible
            let isSameItem = previewItem?.id == item.id

            if !wasVisible {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    previewItem = item
                    previewTileRect = tileRect
                }
                let targetID = item.id
                // 下一帧再触发绽放动画，确保首次悬停也能完整演绎从缩略图边缘生长的弹簧动效
                DispatchQueue.main.async {
                    guard hoveredTileItemID == targetID else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.08)) {
                        isPreviewVisible = true
                    }
                }
            } else if isSameItem {
                // 列表滚动时实时贴合当前缩略图位置，不滞后
                previewTileRect = tileRect
            } else {
                // 跨图片网格滑动时连续平移与形变，无闪退重绘
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.1)) {
                    previewItem = item
                    previewTileRect = tileRect
                }
            }
        } else if hoveredTileItemID == item.id || previewItem?.id == item.id {
            if hoveredTileItemID == item.id {
                hoveredTileItemID = nil
            }
            previewHideWorkItem?.cancel()
            let itemID = item.id
            let work = DispatchWorkItem {
                guard hoveredTileItemID == nil, previewItem?.id == itemID else { return }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.94)) {
                    isPreviewVisible = false
                }
            }
            previewHideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
        }
    }

    private func dismissImagePreview(clearItem: Bool) {
        previewHideWorkItem?.cancel()
        previewHideWorkItem = nil
        hoveredTileItemID = nil
        if clearItem {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPreviewVisible = false
                previewItem = nil
            }
        } else {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.94)) {
                isPreviewVisible = false
            }
        }
    }

    // MARK: - 键盘控制辅助

    func moveSelection(delta: Int) {
        let count = filteredItems.count
        guard count > 0 else { return }
        dismissImagePreview(clearItem: false)
        nav.selectedIndex = (nav.selectedIndex + delta + count) % count
        nav.scrollRequestEpoch &+= 1
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

    private func pickAppToIgnore() {
        nav.suppressAutoHide = true
        let panel = NSOpenPanel()
        panel.title = "选择要忽略剪贴记录的应用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        let response = panel.runModal()
        nav.suppressAutoHide = false

        guard response == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        store.addIgnoredApp(bundleIdentifier: bundleID, displayName: name)
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
