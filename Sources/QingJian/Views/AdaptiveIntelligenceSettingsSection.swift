import SwiftUI

/// 搜索框即时四则速算与人民币会计大写直出卡片（零阻塞递归解析，按 ↵ 贴数值 / 按 ⇧↵ 贴大写）
struct InstantMathCardView: View {
    let math: InstantMathResult
    let onCommitPlain: () -> Void
    let onCommitRMB: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "function")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("= \(math.formattedThousands)")
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if math.formattedThousands != math.plainValue {
                        Text("(\(math.plainValue))")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if let rmb = math.rmbUppercase {
                    Text(rmb)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let rmb = math.rmbUppercase, !rmb.isEmpty, let onCommitRMB {
                Button(action: onCommitRMB) {
                    Text("大写 ⇧↵")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                }
                .buttonStyle(.plain)
            }

            Button(action: onCommitPlain) {
                Text("键入 ↵")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.accentColor.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.65)
        )
    }
}

/// 搜索框 `@pw` / `@密码` / `@genkey` 硬件级随机强密码直出卡片（↵ 无痕键入并 45s 擦除 / ⇧↵ 加密收藏入库）
struct SecurePasswordCardView: View {
    let candidate: SecurePasswordGenerator.Candidate
    let onCommitEphemeral: () -> Void
    let onCommitPinToVault: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.secretValue)
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(candidate.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onCommitPinToVault) {
                Text("收藏 ⇧↵")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.13)))
            }
            .buttonStyle(.plain)

            Button(action: onCommitEphemeral) {
                Text("无痕键入 ↵")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.accentColor.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.65)
        )
    }
}

/// 搜索框 `@安全` / `@体检` / `@shield` 零信任安全盾牌实时体检卡片（可视化呈现全库加密与活跃防线，一键清零未收藏风险）
struct SecurityAuditCardView: View {
    let report: SecurityPostureAudit.Report
    let onSweepRisks: () -> Void

    var body: some View {
        let isClean = (report.unpinnedRiskCount == 0)
        let tint: Color = isClean ? .green : .orange

        HStack(spacing: 10) {
            Image(systemName: isClean ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.15)))

            VStack(alignment: .leading, spacing: 2) {
                Text(report.headlineText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(report.postureSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isClean {
                Text("护盾全开")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
            } else {
                Button(action: onSweepRisks) {
                    Text("一键清零 (\(report.unpinnedRiskCount))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(Capsule().fill(Color.orange))
                }
                .buttonStyle(.plain)
                .help("连根清除未收藏的敏感凭据、即焚残留、隐藏控制符投毒与钓鱼风险链接（收藏项永久豁免）")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(tint.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(tint.opacity(0.26), lineWidth: 0.65)
        )
    }
}

/// 搜索框 `@锁` / `@解锁` 零知识端到端密文信封卡片（Mac/Win 互通加锁外发，离线口令无痕解锁不落盘）
struct SecretCapsuleCardView: View {
    let state: SecretCapsuleMessenger.CommandState
    let onCommitPrimary: () -> Void
    let onCommitPinDecrypted: (() -> Void)?

    var body: some View {
        let (symbol, tint, title, subtitle, primaryLabel): (String, Color, String, String, String?) = {
            switch state {
            case .lockReady(_, let src, let isInline):
                let preview = src.replacingOccurrences(of: "\n", with: " ")
                let veiled = SensitiveCredentialVeil.veiledPreview(for: preview)
                let srcDesc = isInline ? "内联正文" : "首条剪贴"
                return (
                    "lock.doc.fill",
                    .accentColor,
                    "端到端加密（\(srcDesc)）：\(veiled)",
                    "SHA256-CTR + HMAC 防篡改信封 · Mac/Win 互通 · 明文不入库",
                    "发送密文 ↵"
                )
            case .lockAwaitingInput(let hint):
                return ("lock.fill", .secondary, "零知识口令密文信封", hint, nil)
            case .unlockDecrypted(let plain):
                let single = plain.replacingOccurrences(of: "\n", with: " ")
                return (
                    "lock.open.fill",
                    .green,
                    single,
                    "✓ HMAC 校验通过 · 无痕键入不落盘 · 30s 自动擦除剪贴板",
                    "无痕键入 ↵"
                )
            case .unlockPending(let hasTarget, let attempted):
                if !hasTarget {
                    return ("envelope.badge.shield.half.filled", .secondary, "未在剪贴历史中发现 ICLPMSG1 密文信封", "先在微信/飞书复制对方发来的密文，再输入 @解锁 口令", nil)
                }
                return (
                    "key.horizontal.fill",
                    attempted ? .orange : .accentColor,
                    attempted ? "等待正确口令解锁密文信封…" : "检测到端到端加密信封 · 请输入解锁口令",
                    "离线零联网解密 · 口令匹配即刻显影（明文绝不写入磁盘）",
                    nil
                )
            }
        }()

        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.15)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let onPin = onCommitPinDecrypted {
                Button(action: onPin) {
                    Text("收藏 ⇧↵")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(tint.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }

            if let primaryLabel {
                Button(action: onCommitPrimary) {
                    Text(primaryLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(Capsule().fill(tint))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(tint.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 0.65)
        )
    }
}

/// 顶栏「始终在前（Always on Top · ⌘P）」32×32 原生玻璃图钉圆钮（锁死外框尺寸，零布局抖动）
struct AlwaysOnTopPinButton: View {
    @ObservedObject var store: ClipboardStore
    let glassPalette: LiquidGlassPalette
    @State private var isHovered: Bool = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                store.toggleAlwaysOnTop()
            }
        } label: {
            Image(systemName: store.alwaysOnTop ? "pin.fill" : "pin")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(store.alwaysOnTop ? Color.white : Color.secondary)
                .rotationEffect(.degrees(store.alwaysOnTop ? -18 : 0))
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(store.alwaysOnTop ? Color.accentColor : glassPalette.controlCapsuleFill)
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            glassPalette.controlCapsuleStroke.opacity(store.alwaysOnTop ? 0.3 : 0.85),
                            lineWidth: 0.65
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(store.alwaysOnTop ? "取消窗口始终在前" : "开启窗口始终在前")
        .help(store.alwaysOnTop ? "窗口已固定始终在前（点击或按 ⌘P 取消）" : "窗口始终在前：切窗口与连续粘贴不收起（⌘P）")
    }
}

/// 搜索框快捷指令 `@建议 ` / `@调教 ` / `@learn ` 即时对话式采纳横幅
struct QuickSuggestionCommandBanner: View {
    let rawQuery: String
    let onSubmit: (String) -> Void

    static func extractPayload(from searchText: String) -> String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        let prefixes = ["@建议", "@调教", "@learn", "@反馈"]
        for p in prefixes {
            if trimmed.lowercased().hasPrefix(p) {
                let body = String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                return body
            }
        }
        return nil
    }

    var body: some View {
        let payload = Self.extractPayload(from: rawQuery) ?? ""

        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))

            VStack(alignment: .leading, spacing: 1.5) {
                Text(payload.isEmpty ? "一句话调教 iClip（支持即时改偏好或提需求）" : "调教指令：\(payload)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(payload.isEmpty ? "例：@建议 微信里别弹提示 · @建议 复制链接自动净链 · @建议 PDF自动愈合断行" : "按 ↵ 回车或点击右侧按钮立即采纳生效")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if !payload.isEmpty {
                Button {
                    onSubmit(payload)
                } label: {
                    Text("立即采纳 ↵")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.65)
        )
    }
}

/// 搜索框快捷速记、闪念待办与模板创建横幅（输入 `[] 事项` / `- 事项` / `> 内容` 或 `> 备注 :: 正文` 即时入库）
struct QuickCaptureCommandBanner: View {
    let intent: QuickCaptureIntent
    let onCommitDefault: () -> Void
    let onCommitForcePin: () -> Void

    var body: some View {
        let isTodo = intent.defaultTodo
        let accent: Color = isTodo ? Color.accentColor : (intent.defaultPin ? Color.orange : Color.accentColor)
        let iconName = isTodo
            ? "checkmark.circle.fill"
            : (intent.defaultPin ? "star.circle.fill" : "square.and.pencil")

        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(accent.opacity(0.14)))

            VStack(alignment: .leading, spacing: 1.5) {
                if intent.isEmptyBody {
                    Text(isTodo ? "一行闪念待办直存（保留当前剪贴板）" : "一行闪念速记与常用模板直存")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(isTodo ? "例：[] 下午核对报表 · - 给客户回电话 · todo: 财务 :: 审合同" : "例：> 下午4点领发票 · > 税号 :: 913100... · 支持 {{date}} {{weekday}} {{clip}}")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 5) {
                        if let alias = intent.customAlias {
                            Text("备注：\(alias)")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(isTodo ? Color.accentColor : Color.orange)
                                .lineLimit(1)
                            Text("·")
                                .foregroundStyle(.secondary)
                        }
                        Text(intent.bodyText)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Text(
                        isTodo
                            ? "按 ↵ 加入待办（不冲掉当前剪贴板） · 按 ⇧↵ 加入并复制"
                            : (intent.defaultPin ? "按 ↵ 直接存入收藏夹并复制到剪贴板" : "按 ↵ 存入剪贴板与历史 · 按 ⇧↵ 直接收藏")
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if !intent.isEmptyBody {
                if isTodo {
                    Button(action: onCommitForcePin) {
                        Text("并复制 ⇧↵")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    }
                    .buttonStyle(.plain)

                    Button(action: onCommitDefault) {
                        Text("加待办 ↵")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                } else {
                    if !intent.defaultPin {
                        Button(action: onCommitForcePin) {
                            Text("收藏 ⇧↵")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: onCommitDefault) {
                        Text(intent.defaultPin ? "收藏 ↵" : "存入 ↵")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .background(Capsule().fill(intent.defaultPin ? Color.orange : Color.accentColor))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((intent.defaultPin ? Color.orange : Color.accentColor).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((intent.defaultPin ? Color.orange : Color.accentColor).opacity(0.24), lineWidth: 0.65)
        )
    }
}

/// 设置页「OneMind 主动智能」精简模块（内化本地持久记忆、情境排序与拟态节奏，越用越顺手）
struct AdaptiveIntelligenceSettingsSection: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var engine = AdaptiveIntelligenceEngine.shared

    var body: some View {
        let summary = engine.oneMindMemorySummary

        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    Text("OneMind 主动心智内核")
                        .font(.system(size: 13, weight: .semibold))
                    Text("本地加密留存")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    Spacer()
                    if summary.totalInteractions > 0 {
                        Button("重置记忆") {
                            engine.resetLearnedWeights()
                            store.showToast("已重置 OneMind 习惯记忆")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 6) {
                    oneMindStatTile(value: "\(summary.totalInteractions)", label: "习惯留存")
                    oneMindStatTile(value: "\(summary.rememberedAppCount)", label: "熟悉应用")
                    oneMindStatTile(value: "\(summary.completedNudgeCount)", label: "推进待办")
                    oneMindStatTile(value: "\(summary.adaptiveNudgeMinutes)m", label: "拟态节奏")
                }

                if summary.voiceTodoCount > 0 || summary.autoRuleCount > 0 {
                    Text("已记住 \(summary.autoRuleCount) 条自动契约 · \(summary.voiceTodoCount) 次语音录入待办，全本机离线留存")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            Divider().opacity(0.35)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("复制时显示光标角「灵动微星标」")
                        .font(.system(size: 13.5, weight: .medium))
                    Text("复制账单、断行 PDF 或二维码时轻浮一键转换，再按一次 ⌘C 零离手触发")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $engine.sparkEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider().opacity(0.35)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("拖拽途中按 ⌥ 呼出「微落点」")
                        .font(.system(size: 13.5, weight: .medium))
                    Text("拖起网页图片或文本时轻按 ⌥，在光标旁原地松手即存或套样机")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $engine.cursorDropPodEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider().opacity(0.35)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("复制链接自动剥离追踪参数")
                        .font(.system(size: 13.5, weight: .medium))
                    Text("自动移除 utm_source、spm、fbclid 等营销尾巴")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $store.autoCleanTrackingURL)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider().opacity(0.35)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("粘贴敏感凭据时自动脱敏守护")
                        .font(.system(size: 13.5, weight: .medium))
                    Text("双击或回车默认贴掩码，按 ⌥↵ 才贴原始明文")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $store.autoRedactOnPaste)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if !engine.mutedSourceApps.isEmpty {
                Divider().opacity(0.35)

                VStack(alignment: .leading, spacing: 5) {
                    Text("微星标免打扰应用")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(engine.mutedSourceApps, id: \.self) { app in
                                HStack(spacing: 4) {
                                    Text(app)
                                        .font(.system(size: 11, weight: .medium))
                                    Button {
                                        engine.setSourceAppMuted(app, muted: false)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                            }
                        }
                    }
                }
            }

            if !engine.enabledAutoRules.isEmpty {
                Divider().opacity(0.35)

                VStack(alignment: .leading, spacing: 7) {
                    Text("已开启的自动处理规则")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    ForEach(LearnedAutoRuleKind.allCases.filter { engine.enabledAutoRules.contains($0) }) { rule in
                        HStack {
                            Text(rule.title)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary.opacity(0.88))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { engine.enabledAutoRules.contains(rule) },
                                set: { newVal in
                                    engine.setAutoRule(rule, enabled: newVal)
                                    if rule == .cleanTrackingURL {
                                        store.autoCleanTrackingURL = newVal
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                        }
                    }
                }
            }
        }
    }

    private func oneMindStatTile(value: String, label: String) -> some View {
        VStack(spacing: 1.5) {
            Text(value)
                .font(.system(size: 12.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}
