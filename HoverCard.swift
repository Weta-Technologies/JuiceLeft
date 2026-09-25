import AppKit
import SwiftUI

/// The card that appears under the menu-bar item after the pointer rests on it for a moment: the time left in words,
/// then the clock time, the percent and the state. A borderless, non-activating panel that never takes focus, fades
/// in and out (not under Reduce Motion), follows the live reading while it is up, and costs nothing when it isn't:
/// the only timer is the 0.4 s hover delay. It stands in for the plain tooltip; VoiceOver keeps its own label.
@MainActor final class HoverCard {
    static let delay: TimeInterval = 0.4
    static let fade: TimeInterval = 0.15

    private let monitor: Monitor
    private let button: NSStatusBarButton
    private let tracker = Tracker()
    private var panel: NSPanel?
    private var timer: Timer?
    private var showing = false

    private var inside = false
    private var monitors: [Any] = []

    init(monitor: Monitor, button: NSStatusBarButton) {
        self.monitor = monitor
        self.button = button
        // A tracking area, and — since the status bar's window doesn't deliver enter/exit on its own — pointer moves
        // watched against the item's frame. Both funnel into one entered/exited pair; nothing runs while the pointer is still.
        button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: tracker, userInfo: nil))
        tracker.entered = { [weak self] in self?.crossed(true) }
        tracker.exited = { [weak self] in self?.crossed(false) }
        button.window?.acceptsMouseMovedEvents = true
        let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.moved() }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }
        monitors = [local, global].compactMap { $0 }
    }

    private func moved() {
        guard let window = button.window else { return }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let now = frame.contains(NSEvent.mouseLocation)
        if now != inside { crossed(now) }
    }

    private func crossed(_ entered: Bool) {
        guard entered != inside else { return }
        inside = entered
        if entered { armed() } else { hide() }
    }

    /// The pointer arrived: show after the delay, unless it leaves first.
    private func armed() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.show() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A click or hold is taking over, or the pointer left.
    func hide() {
        timer?.invalidate()
        timer = nil
        guard showing, let panel else { return }
        showing = false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fade
                panel.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { if !self.showing { panel.orderOut(nil) } } })
        }
    }

    private func show() {
        guard !showing, !monitor.panelIsOpen, let window = button.window else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let itemFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = itemFrame.midX - size.width / 2
        if let screen = window.screen ?? NSScreen.main {
            x = max(screen.visibleFrame.minX + 8, min(x, screen.visibleFrame.maxX - size.width - 8))
        }
        panel.setFrame(NSRect(x: x, y: itemFrame.minY - size.height - 6, width: size.width, height: size.height), display: true)
        showing = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fade
                panel.animator().alphaValue = 1
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HoverCardView(monitor: monitor))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    /// The tracking area's owner: AppKit calls these by selector.
    private final class Tracker: NSObject {
        var entered: (() -> Void)?
        var exited: (() -> Void)?
        @objc func mouseEntered(with event: NSEvent) { entered?() }
        @objc func mouseExited(with event: NSEvent) { exited?() }
    }
}

struct HoverCardView: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let (title, detail, warning) = monitor.hoverLines
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(detail).font(.caption).lineLimit(1)
                .foregroundStyle(warning ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0.12)))
        .padding(4)   // room for the shadow inside the transparent window
    }
}
