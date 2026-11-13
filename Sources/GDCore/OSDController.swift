import SwiftUI
import AppKit

public struct OSDContentView: View {
    public let symbol: String
    public let title: String
    public let value: Double
    public let detail: String?

    public var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule()
                            .fill(.white.opacity(0.92))
                            .frame(width: max(3, geometry.size.width * value))
                    }
                }
                .frame(height: 5)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Lightweight on-screen display used for brightness, contrast and volume feedback.
@MainActor
public final class OSDController {
    public static let shared = OSDController()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    /// Counts calls to `show`, so a fade-out that finishes after a newer
    /// `show` does not hide what that one just put on screen.
    private var generation = 0

    private init() {}

    public func show(symbol: String, title: String, value: Double, detail: String? = nil) {
        let clamped = max(0, min(1, value))
        let content = OSDContentView(symbol: symbol, title: title, value: clamped, detail: detail)

        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 74),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            self.panel = panel
        }

        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: content)
        panel.setContentSize(NSSize(width: 260, height: detail == nil ? 74 : 88))
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideWorkItem?.cancel()
        generation += 1
        let shown = generation
        let item = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    guard OSDController.shared.generation == shown else { return }
                    panel.orderOut(nil)
                }
            })
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + SettingsStore.shared.state.general.osdDuration,
                                      execute: item)
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + 90)
        panel.setFrameOrigin(origin)
    }
}
