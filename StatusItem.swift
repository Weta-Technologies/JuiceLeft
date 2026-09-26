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
    private var openedAt = Date.distantPast
    private var hover: HoverCard?

    init(monitor: Monitor) {
        self.monitor = monitor
        host = NSHostingController(rootView: Self.panel(monitor, visible: false))
        host.sizingOptions = .preferredContentSize   // the popover follows the SwiftUI content as it expands
        popover.contentViewController = host
        popover.behavior = .applicationDefined      // closed by the monitors below; .transient races with the item click

        item.autosaveName = "Item-0"   // what MenuBarExtra uses, so menu-bar organisers keep recognising the item
        monitor.onReposition = { [weak self] in   // the swap wrote a new saved place: re-read it
            guard let self else { return }
            self.item.autosaveName = nil
            self.item.autosaveName = "Item-0"
        }
        monitor.onOpenPanel = { [weak self] in   // the global shortcut: open, or close if it is up
            guard let self else { return }
            if self.popover.isShown { self.close() } else { self.open() }
        }
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.imagePosition = .imageOnly   // the text is part of the image, laid out exactly like Apple's item
        button.setAccessibilityHelp("Click for battery details. Press and hold to turn monitoring on or off.")
        hover = HoverCard(monitor: monitor, button: button)   // the card under the item stands in for a tooltip
        monitor.icon.$image.sink { [weak self] image in
            MainActor.assumeIsolated {
                button.image = image
                self?.scheduleRoomCheck()
            }
        }.store(in: &sinks)
        // ponytail: best effort — when the menu bar runs out of room macOS drops the item off screen; the compact form
        // is tried then, and the full one again every few minutes. Untested for want of a crowded enough bar.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { if (note.object as? NSWindow) === self?.item.button?.window { self?.scheduleRoomCheck() } }
        }
        // Neighbours come and go with apps, and the notch with the screen: the room check runs again then, debounced.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRoomCheck() } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRoomCheck() }
        }
        monitor.objectWillChange.receive(on: DispatchQueue.main)
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
        // Activation lands a moment after it is asked for; the panel takes key status then, so Esc and the keyboard work.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.host.view.window?.makeKeyAndOrderFront(nil)
            }
        }
        refreshText()
    }

    // MARK: Room in the menu bar

    private var roomRetry: Timer?
    private var roomDebounce: Timer?
    nonisolated static let notchMargin: CGFloat = 8

    /// The notch rule, pure for --selftest. `items` are every status item's frame on the menu-bar screen (ours too),
    /// `notch` the gap between that screen's top-left and top-right areas, the widths ours in each form. Squeeze the
    /// moment any item sits in the gap (macOS hides it there); go back to the words only once the leftmost item, moved
    /// left by the width the words add, would still clear the gap by a margin. The two can never both hold for one
    /// layout, so nothing flaps. nil = leave it as it is.
    nonisolated static func notchDecision(squeezed: Bool, items: [CGRect], notch: CGRect, wordsWidth: CGFloat, compactWidth: CGFloat,
                                          margin: CGFloat = notchMargin) -> Bool? {
        let hidden = items.contains { $0.maxX > notch.minX && $0.minX < notch.maxX }
        if !squeezed { return hidden ? true : nil }
        if hidden { return nil }
        guard let leftmost = items.map(\.minX).min() else { return false }
        return leftmost - max(wordsWidth - compactWidth, 0) >= notch.maxX + margin ? false : nil
    }

    /// The camera notch on a screen, in that screen's coordinates; nil where there is none.
    nonisolated static func notch(of screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX else { return nil }
        return CGRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height)
    }

    /// Every status item's frame in the menu bar of `screen` (the first screen, where the menu bar is), ours included:
    /// window bounds and level only — no names, no permission. CG's top-left origin flipped into the screen's own.
    private static func statusItemFrames(on screen: NSScreen) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let level = Int(CGWindowLevelForKey(.statusWindow)), band = screen.frame.maxY - 40
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == level, let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict), b.width > 0, b.height > 0, b.height < 60 else { return nil }
            let rect = CGRect(x: b.minX, y: screen.frame.height - b.maxY, width: b.width, height: b.height)
            return rect.maxY > band && screen.frame.intersects(rect) ? rect : nil
        }
    }

    private func scheduleRoomCheck() {
        roomDebounce?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.checkRoom() } }
        RunLoop.main.add(t, forMode: .common)
        roomDebounce = t
    }

    /// Pushed off the screen (or given no width) = squeezed out; the compact form goes up in its place. Occlusion is
    /// deliberately not a signal: a menu-bar organiser's overlay covers the item without hiding it. On a screen with a
    /// camera notch the notch rule decides both ways — a neighbour hidden in the gap squeezes the words, and they come
    /// back only when they would fit; elsewhere the full form is tried again every few minutes.
    private func checkRoom() {
        guard let window = item.button?.window, let screen = NSScreen.main, let bar = NSScreen.screens.first else { return }
        let onScreen = screen.frame.intersects(window.frame) && window.frame.width > 1
        let notch = Self.notch(of: bar)
        if !onScreen {
            guard !monitor.squeezed else { return }
            monitor.setSqueezed(true)
            if notch == nil {
                let retry = Timer(timeInterval: 5 * 60, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.monitor.setSqueezed(false) } }
                RunLoop.main.add(retry, forMode: .common)
                roomRetry = retry
            }
            return
        }
        guard let notch, monitor.interactive, monitor.s.menuBar == .words else { return }
        let widths = monitor.itemWidths
        if let decision = Self.notchDecision(squeezed: monitor.squeezed, items: Self.statusItemFrames(on: bar), notch: notch,
                                             wordsWidth: widths.words, compactWidth: widths.compact) {
            monitor.setSqueezed(decision)
        }
    }

    /// VoiceOver always gets the whole story, whatever the menu bar shows.
    private func refreshText() {
        guard let button = item.button else { return }
        let spoken = monitor.spoken
        if button.accessibilityLabel() != spoken { button.setAccessibilityLabel(spoken) }
    }

    /// Esc closes the popover (and is swallowed); a click in any window but the popover's or the item's closes it.
    private func sawLocal(_ event: NSEvent) -> Bool {
        guard popover.isShown else { return false }
        if event.type == .keyDown {
            guard event.keyCode == 53, !HotKey.recording else { return false }   // Esc while recording a shortcut cancels that instead
            close()
            return true
        }
        if ![host.view.window, item.button?.window].contains(where: { $0 === event.window }) { close() }
        return false
    }

    @objc private func clicked() {
        hover?.hide()
        if popover.isShown {
            guard Date().timeIntervalSince(openedAt) > 0.5 else { return }   // the same press bouncing back, not a second click
            return close()
        }
        // No mouse event behind the action (VoiceOver's press, for one): that is a request for the panel.
        guard let event = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown].contains(event.type) else { return open() }
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
        // Activate outright: on macOS 14+ the plain activate() is cooperative and can be refused while another app is
        // frontmost, which left the popover without key status, so Esc and the keyboard went to that app.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        host.view.window?.makeKeyAndOrderFront(nil)
        openedAt = Date()
        monitor.panelOpened()   // top apps and energy modes only refresh while the panel is open
    }

    private func close() {
        guard popover.isShown else { return }
        popover.close()
        monitor.panelClosed()
        host.rootView = Self.panel(monitor, visible: false)
    }
}
