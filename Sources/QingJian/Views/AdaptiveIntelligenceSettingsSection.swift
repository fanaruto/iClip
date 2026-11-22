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

/// 设置页「自适应心智引擎与建议采纳中心」模块
struct AdaptiveIntelligenceSettingsSection: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var engine = AdaptiveIntelligenceEngine.shared

    @State private var suggestionDraft: String = ""
    @State private var latestFeedbackMessage: String? = nil
    @State private var latestAdoptedImmediately: Bool = true
    @State private var showAutoRulesDetail: Bool = false

    private let quickPresets: [String] = [
        "复制链接自动剥离追踪尾巴",
        "复制 PDF 自动愈合断行",
        "在微信里不要弹微星标提示",
        "截图优先套圆角样机"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. 心智进化概览
            HStack(spacing: 9) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor.opacity(0.13)))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("越用越懂你的本地心智")
                            .font(.system(size: 13.5, weight: .semibold))
                        if engine.totalLearnedInteractions > 0 {
                            Text("已习得 \(engine.totalLearnedInteractions) 次偏好")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                    Text("自动记忆你在不同应用下的常用动作并动态置顶；搜索框输入 @建议 可随时调教")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Divider().opacity(0.35)

            // 2. 自然语言建议输入框（直接采纳用户建议）
            VStack(alignment: .leading, spacing: 7) {
                Text("告诉 iClip 你的建议或偏好")
                    .font(.system(size: 12.5, weight: .medium))

                HStack(spacing: 6) {
                    TextField("例如：在微信里免打扰 / 金额优先转大写 / 新功能建议...", text: $suggestionDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6.5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .onSubmit {
                            submitSuggestion()
                        }

                    Button {
                        submitSuggestion()
                    } label: {
                        Text("采纳")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6.5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(suggestionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.35) : Color.accentColor)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(suggestionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // 快捷灵感标签
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(quickPresets, id: \.self) { preset in
                            Button {
                                suggestionDraft = preset
                                submitSuggestion()
                            } label: {
                                Text(preset)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(Capsule().fill(Color.primary.opacity(0.055)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let msg = latestFeedbackMessage {
                    HStack(spacing: 5) {
                        Image(systemName: latestAdoptedImmediately ? "checkmark.seal.fill" : "sparkles")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(latestAdoptedImmediately ? Color.green : Color.accentColor)
                        Text(msg)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.top, 2)
                }
            }

            Divider().opacity(0.35)

            // 3. 光标角「灵动微星标（Action Spark）」开关与停留时长
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("复制时显示光标角「灵动微星标」")
                        .font(.system(size: 13.5, weight: .medium))
                    Text("复制截图、账单、断行 PDF 或 JSON 时在光标右下角轻浮一键转换，不理睬自动习得退避")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $engine.sparkEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if engine.sparkEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("微星标浮现时再按一次 ⌘C 零离手触发")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("手指无需移向鼠标：按第 2 次 ⌘C 直接完成智变，按第 3 次 ⌘C 无损还原原文")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $engine.doubleCopySparkEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }

                HStack {
                    Text("微星标停留时长")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Text(String(format: "%.1f 秒", engine.sparkDurationSeconds))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Slider(value: $engine.sparkDurationSeconds, in: 1.2...3.8, step: 0.2)
                        .controlSize(.small)
                        .frame(width: 110)
                }
            }

            Divider().opacity(0.35)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("拖拽途中按 ⌥ 召唤「光标旁微落点」")
                        .font(.system(size: 13.5, weight: .medium))
                    Text("拖起网页图片、文件或文本时轻按一下 ⌥，在光标尖旁原地松手即存或套样机")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $engine.cursorDropPodEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if !engine.mutedSourceApps.isEmpty {
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

            Divider().opacity(0.35)

            // 4. 复制即自动处理契约折叠区
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        showAutoRulesDetail.toggle()
                    }
                } label: {
                    HStack {
                        Text("已习得的全自动处理契约（\(engine.enabledAutoRules.count)/\(LearnedAutoRuleKind.allCases.count)）")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: showAutoRulesDetail ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAutoRulesDetail || !engine.enabledAutoRules.isEmpty {
                    ForEach(LearnedAutoRuleKind.allCases) { rule in
                        if showAutoRulesDetail || engine.enabledAutoRules.contains(rule) {
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

                if engine.totalLearnedInteractions > 0 {
                    HStack {
                        Spacer()
                        Button("重置自动习得的排序偏好") {
                            engine.resetLearnedWeights()
                            store.showToast("已重置习惯排序权重")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func submitSuggestion() {
        let outcome = engine.adoptUserSuggestion(suggestionDraft, in: store)
        guard !outcome.record.rawText.isEmpty else { return }
        suggestionDraft = ""
        withAnimation(.easeOut(duration: 0.16)) {
            latestAdoptedImmediately = outcome.adoptedImmediately
            latestFeedbackMessage = outcome.message
        }
        store.showToast(outcome.message)
    }
}
