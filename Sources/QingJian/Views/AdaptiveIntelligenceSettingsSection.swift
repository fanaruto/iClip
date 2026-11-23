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

/// 设置页「智能辅助」精简模块（内化情境排序、双击 ⌘C 触发与黄金驻留时长，仅保留核心可感知开关）
struct AdaptiveIntelligenceSettingsSection: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var engine = AdaptiveIntelligenceEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
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

            #if ICLIP_EDITION_FLOW
            Divider().opacity(0.35)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("顺序出队后自动按 Tab 跳格")
                        .font(.system(size: 13.5, weight: .medium))
                    Text("连续按 \(store.queuePopShortcut.compactDisplayString) 填表时自动跳往下一个输入框")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $store.queueAutoTabEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            #else
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
            #endif

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
                                    #if !ICLIP_EDITION_FLOW
                                    if rule == .cleanTrackingURL {
                                        store.autoCleanTrackingURL = newVal
                                    }
                                    #endif
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
}
