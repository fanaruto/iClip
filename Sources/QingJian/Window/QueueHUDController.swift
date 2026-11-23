#if ICLIP_EDITION_FLOW
import AppKit
import SwiftUI

/// 免开面板顺序出队时的苹果原生无焦点灵动胶囊提示窗（不抢焦点、鼠标穿透、原生毛玻璃/液态玻璃）
@MainActor
final class QueueHUDController {
    static let shared = QueueHUDController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<QueueHUDPillView>?
    private var dismissWorkItem: DispatchWorkItem?
    private let hudSize = NSSize(width: 316, height: 48)

    private init() {}

    func show(symbol: String, title: String, subtitle: String?, tint: Color = .accentColor) {
        ensurePanel()
        guard let panel, let hostingView else { return }

        dismissWorkItem?.cancel()
        hostingView.rootView = QueueHUDPillView(symbol: symbol, title: title, subtitle: subtitle, tint: tint)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        var originX = mouse.x - hudSize.width / 2
        originX = max(visible.minX + 12, min(originX, visible.maxX - hudSize.width - 12))
        var originY = mouse.y + 22
        if originY + hudSize.height > visible.maxY - 12 {
            originY = mouse.y - hudSize.height - 22
        }

        panel.setFrameOrigin(NSPoint(x: originX, y: originY - 6))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(NSPoint(x: originX, y: originY))
        }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().alphaValue = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                    self?.panel?.orderOut(nil)
                }
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35, execute: work)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let rect = NSRect(origin: .zero, size: hudSize)
        let p = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false

        let root = QueueHUDPillView(symbol: "checkmark.circle.fill", title: "", subtitle: nil, tint: .accentColor)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = rect
        hosting.autoresizingMask = [.width, .height]

        let bleedRoot = LiquidGlassBleedRootView(frame: rect, cardFrame: rect)
        bleedRoot.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: rect)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = hudSize.height / 2
            glass.style = .regular
            glass.tintColor = nil
            glass.contentView = hosting
            bleedRoot.addSubview(glass)
            p.contentView = bleedRoot
        } else {
            let effect = NSVisualEffectView(frame: rect)
            effect.autoresizingMask = [.width, .height]
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = LiquidGlassSurfaceHost.continuousCornerMaskImage(size: hudSize, radius: hudSize.height / 2)
            effect.wantsLayer = true
            effect.layer?.cornerCurve = .continuous
            effect.layer?.cornerRadius = hudSize.height / 2
            effect.layer?.masksToBounds = true
            effect.addSubview(hosting)
            bleedRoot.addSubview(effect)
            p.contentView = bleedRoot
        }

        self.hostingView = hosting
        self.panel = p
    }
}

private struct QueueHUDPillView: View {
    let symbol: String
    let title: String
    let subtitle: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
