import SwiftUI
import AppKit

/// 首次使用时的无模态原生双角色选择引导卡（也支持在设置页直接调用切换 OTA 轨道）
struct RoleOnboardingBanner: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var updater: UpdateManager
    let onOpenSettings: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let installed = AppRoleEdition.installed

    private var glassPalette: LiquidGlassPalette {
        LiquidGlassPalette(colorScheme: colorScheme, surfaceStyle: store.surfaceStyle, appearance: store.liquidGlassAppearance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("选择你的剪贴板角色版本")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        store.hasConfirmedRoleEdition = true
                        store.minimalModeEnabled = true
                        store.showToast("已开启极简纯净模式（基础功能版）")
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 10))
                        Text("使用极简基础版")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.green)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                ForEach(AppRoleEdition.allCases) { edition in
                    roleOptionTile(edition)
                }
            }

            if store.targetRoleEdition != installed {
                pendingEditionSwitchFooter
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(glassPalette.groupFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(glassPalette.groupStroke, lineWidth: 0.75)
        )
    }

    private func roleOptionTile(_ edition: AppRoleEdition) -> some View {
        let isSelected = (store.targetRoleEdition == edition)
        let isInstalled = (installed == edition)

        return Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                store.selectRoleEdition(edition)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: edition.symbolName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(isSelected ? edition.accentTint : .secondary)

                    Text(edition.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if isInstalled {
                        Text("已装")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.green.opacity(0.14)))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(edition.shortHighlights, id: \.self) { line in
                        Text("· \(line)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? edition.accentTint.opacity(0.14) : glassPalette.nestedCardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? edition.accentTint.opacity(0.75) : glassPalette.groupStroke.opacity(0.7), lineWidth: isSelected ? 1.2 : 0.6)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var pendingEditionSwitchFooter: some View {
        HStack(spacing: 8) {
            switch updater.state {
            case .checking:
                ProgressView()
                    .controlSize(.small)
                Text("正在查询「\(store.targetRoleEdition.title)」专属 OTA 包...")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()

            case .available(let info) where info.isEditionSwitch:
                Text("已就绪：\(info.assetName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("立即 OTA 切换重启") {
                    updater.startOTAUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            case .downloading(let progress, _):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()

            case .installing:
                ProgressView()
                    .controlSize(.small)
                Text("正在替换应用并自动重启...")
                    .font(.system(size: 11, weight: .medium))
                Spacer()

            case .failed(let msg):
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer()
                Button("前往设置") {
                    onOpenSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            default:
                Text("需要通过 OTA 拉取「\(store.targetRoleEdition.title)」安装包")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("检查并切换") {
                    updater.checkForUpdates(targetEdition: store.targetRoleEdition, silent: false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
}

/// 设置页「使用角色与差异化 OTA 更新」完整控制视图
struct RoleAndOTASettingsSection: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var updater: UpdateManager
    @Environment(\.colorScheme) private var colorScheme

    private let installed = AppRoleEdition.installed

    private var glassPalette: LiquidGlassPalette {
        LiquidGlassPalette(colorScheme: colorScheme, surfaceStyle: store.surfaceStyle, appearance: store.liquidGlassAppearance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 极简纯净模式（基础功能版）一键总开关
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(store.minimalModeEnabled ? Color.green : .secondary)
                        Text("极简纯净模式（⌘E）")
                            .font(.system(size: 13.5, weight: .medium))
                    }
                    Text("隐藏行业增强动作与智能浮标，仅保留纯粹复制粘贴")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $store.minimalModeEnabled.animation(.spring(response: 0.24, dampingFraction: 0.86)))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if !store.minimalModeEnabled {
                Divider().opacity(0.35)

                HStack(spacing: 8) {
                    ForEach(AppRoleEdition.allCases) { edition in
                        let isSelected = (store.targetRoleEdition == edition)
                        let isInstalled = (installed == edition)

                        Button {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                                store.selectRoleEdition(edition)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    Image(systemName: edition.symbolName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(isSelected ? edition.accentTint : .secondary)

                                    Text(edition.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(.primary)

                                    Spacer(minLength: 0)

                                    if isInstalled {
                                        Text("当前")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(Color.green)
                                            .padding(.horizontal, 5.5)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(Color.green.opacity(0.14)))
                                    }
                                }

                                Text(edition.subtitle)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(isSelected ? edition.accentTint.opacity(0.14) : glassPalette.nestedCardFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(isSelected ? edition.accentTint.opacity(0.8) : glassPalette.groupStroke.opacity(0.7), lineWidth: isSelected ? 1.2 : 0.6)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().opacity(0.35)

            otaStatusFooter
        }
    }

    @ViewBuilder
    private var otaStatusFooter: some View {
        let switching = (store.targetRoleEdition != installed)

        switch updater.state {
        case .idle:
            HStack {
                Text(switching
                     ? "待切换至「\(store.targetRoleEdition.title)」"
                     : "\(installed.title) · v\(updater.currentVersion)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(switching ? .primary : .secondary)
                Spacer()
                Button(switching ? "立即切换版本" : "检查更新") {
                    updater.checkForUpdates(targetEdition: store.targetRoleEdition, silent: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在连接 GitHub Releases 检索「\(store.targetRoleEdition.title)」安装包...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }

        case .upToDate(let latest, let ed):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ed.title) 已是最新（v\(updater.currentVersion)）")
                        .font(.system(size: 13, weight: .medium))
                    Text("GitHub 最新版本 v\(latest) · \(ed.expectedAssetName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("重新检查") {
                    updater.checkForUpdates(targetEdition: store.targetRoleEdition, silent: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .available(let info):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.isEditionSwitch
                             ? "可切换至「\(info.edition.title)」v\(info.version)"
                             : "发现「\(info.edition.title)」新版本 v\(info.version)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("\(info.assetName) · 约 \(Self.formatBytes(info.assetSize)) · 保留辅助功能权限与历史")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(info.isEditionSwitch ? "立即 OTA 切换" : "立即 OTA 更新") {
                        updater.startOTAUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if !info.notes.isEmpty && !info.isEditionSwitch {
                    Text(info.notes)
                        .font(.system(size: 11))
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
                    Text("正在下载 \(info.assetName)...")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("取消") {
                        updater.cancelDownload()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

        case .installing(let info):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在切换安装「\(info.edition.title)」v\(info.version) 并自动重启...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }

        case .failed(let message):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("角色包或更新获取未完成")
                        .font(.system(size: 12.5, weight: .medium))
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("重试") {
                    updater.checkForUpdates(targetEdition: store.targetRoleEdition, silent: false)
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
}
