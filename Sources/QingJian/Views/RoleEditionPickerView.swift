import SwiftUI
import AppKit

/// 设置页「版本与软件更新」精简状态条（One iClip 单一主线）
struct RoleAndOTASettingsSection: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var updater: UpdateManager

    var body: some View {
        otaStatusFooter
    }

    @ViewBuilder
    private var otaStatusFooter: some View {
        switch updater.state {
        case .idle:
            HStack {
                Text("iClip v\(updater.currentVersion)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
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
                Text("正在检查最新版本...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }

        case .upToDate(let latest, _):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前已是最新版本（v\(updater.currentVersion)）")
                        .font(.system(size: 13, weight: .medium))
                    Text("线上最新版本 v\(latest)")
                        .font(.system(size: 11))
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("\(info.assetName) · 约 \(Self.formatBytes(info.assetSize)) · 保留权限与全部历史")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("立即更新") {
                        updater.startOTAUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if !info.notes.isEmpty {
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
                Text("正在安装 iClip v\(info.version) 并自动重启...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }

        case .failed(let message):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("检查更新未完成")
                        .font(.system(size: 12.5, weight: .medium))
                    Text(message)
                        .font(.system(size: 11))
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
}
