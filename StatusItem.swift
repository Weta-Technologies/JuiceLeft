import AppKit
import Combine
import SwiftUI

/// The menu-bar item: the glyph plus, by choice, the time to flat or the percent. A click (or right-click / ⌃-click)
/// opens the panel, which closes on Esc, on a click anywhere else, or on another click on the item. Press and hold
/// turns the monitor on or off without opening anything: the glyph changes and the trackpad taps back.
@MainActor final class StatusItemController {
    enum Gesture: Equatable { case panel, toggle }
    static let holdDelay: TimeInterval = 0.35

    /// The click decision, kept pure so --selftest can check it: right- or ⌃-click opens the panel; a left press opens
    /// it too if the button comes up before the hold delay, otherwise it is a hold, which toggles the monitor.
    nonisolated static func gesture(_ type: NSEvent.EventType, control: Bool, releasedInTime: () -> Bool) -> Gesture {
        if type == .rightMouseDown || control { return .panel }
        return releasedInTime() ? .panel : .toggle
    }

    private let monitor: Monitor
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let host: NSHostingController<AnyView>
    private var sinks: [AnyCancellable] = []
    private var monitors: [Any] = []
    private var shown: (text: String?, red: CGFloat)?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

    init(monitor: Monitor) {
        self.monitor = monitor
        host = NSHostingController(rootView: Self.panel(monitor, visible: false))
        host.sizingOptions = .preferredContentSize   // the popover follows the SwiftUI content as it expands
        popover.contentViewController = host
        popover.behavior = .applicationDefined      // closed by the monitors below; .transient races with the item click

        item.autosaveName = "Item-0"   // what MenuBarExtra uses, so menu-bar organisers keep recognising the item
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.imagePosition = .imageLeading
        button.setAccessibilityHelp("Click for battery details. Press and hold to turn monitoring on or off.")
        monitor.icon.$image.sink { image in MainActor.assumeIsolated { button.image = image } }.store(in: &sinks)
        // The text follows the reading, the forecast, the display setting and the red pulse.
        monitor.objectWillChange.merge(with: monitor.icon.objectWillChange).receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.refreshText() } }.store(in: &sinks)

        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let swallow = MainActor.assumeIsolated { self?.sawLocal(event) ?? false }
            return swallow ? nil : event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        monitors = [local, global].compactMap { $0 }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        refreshText()
    }

    private func refreshText() {
        guard let button = item.button else { return }
        let text = monitor.menuText, red = monitor.icon.frame.red
        if shown?.text != text || shown?.red != red {
            shown = (text, red)
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if red > 0 { attributes[.foregroundColor] = NSColor.systemRed.withAlphaComponent(red) }
            button.attributedTitle = NSAttributedString(string: text.map { " " + $0 } ?? "", attributes: attributes)
            button.imagePosition = text == nil ? .imageOnly : .imageLeading
        }
        let spoken = monitor.spoken
        if button.accessibilityLabel() != spoken {
            button.setAccessibilityLabel(spoken)
            button.toolTip = spoken.replacingOccurrences(of: "JuiceLeft: ", with: "") + " Click for details; press and hold to turn monitoring \(monitor.s.armed ? "off" : "on")."
        }
    }

    /// Esc closes the popover (and is swallowed); a click in any window but the popover's or the item's closes it.
    private func sawLocal(_ event: NSEvent) -> Bool {
        guard popover.isShown else { return false }
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return false }
            close()
            return true
        }
        if ![host.view.window, item.button?.window].contains(where: { $0 === event.window }) { close() }
        return false
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if popover.isShown { return close() }
        let gesture = Self.gesture(event.type, control: event.modifierFlags.contains(.control)) {
            // Peek (no dequeue) so the button's own tracking still sees the mouse-up.
            NSApp.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: Self.holdDelay), inMode: .eventTracking, dequeue: false) != nil
        }
        switch gesture {
        case .panel: open()
        case .toggle:   // the moment the hold registers: the glyph changes and the trackpad taps back
            monitor.toggleArmed()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    private static func panel(_ monitor: Monitor, visible: Bool) -> AnyView {
        AnyView(Panel(monitor: monitor).environment(\.panelVisible, visible))
    }

    private func open() {
        guard let button = item.button, !popover.isShown else { return }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        host.rootView = Self.panel(monitor, visible: true)
        host.view.layoutSubtreeIfNeeded()
        popover.contentSize = host.view.fittingSize
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        host.view.window?.makeKey()
        monitor.energy.start()   // the top-apps list only samples while the panel is open
    }

    private func close() {
        guard popover.isShown else { return }
        popover.close()
        monitor.energy.stop()
        host.rootView = Self.panel(monitor, visible: false)
    }
}
