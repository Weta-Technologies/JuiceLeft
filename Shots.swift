import AppKit
import SwiftUI

/// `JuiceLeft --shots <dir>`: the panel in its main states and the hover card, light and dark, as PNGs — for the
/// README and polish passes. Sample state only: no status item, no readings, no timers, nothing on the Mac
/// touched, its own settings domain (removed afterwards); the process exits once the files are written.
@MainActor enum Shots {
    static func run(dir: String) -> Never {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: dir)
        try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // AppKit gives controls their accent colours only while the app is active: say it is, without activating it.
        if let m = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)) {
            method_setImplementation(m, imp_implementationWithBlock({ (_: AnyObject) -> Bool in true } as @convention(block) (AnyObject) -> Bool))
        }
        let suite = "io.github.cyborgfingers.juiceleft.shots.settings"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let now = Date(), source = NoSource()
        let flat = Forecast(kind: .flat, minutes: 190, at: now.addingTimeInterval(190 * 60), ratePerHour: 24, learned: true)
        let full = Forecast(kind: .full, minutes: 55, at: now.addingTimeInterval(55 * 60), ratePerHour: 40)
        let low = Forecast(kind: .flat, minutes: 40, at: now.addingTimeInterval(40 * 60), ratePerHour: 27, learned: true)
        let limit = ChargeLimit.State(enabled: true, limit: 80, available: ChargeLimit.steps)
        let power = PowerMode.State(battery: .automatic, adapter: .automatic, highPowerSupported: true)
        let make = { (percent: Int, onAC: Bool, forecast: Forecast?, phase: Alerts.Phase, tips: [Tip], settings: Settings) in
            Monitor(shots: settings, reading: reading(percent: percent, onAC: onAC, at: now), forecast: forecast, phase: phase, history: history(now: now),
                    tips: tips, ranking: ranking, chargeLimit: limit, power: power, devices: devices, defaults: defaults, source: source)
        }
        var shortcut = Settings()
        shortcut.hotKey = HotKey.Spec(keyCode: 38, key: "J", modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)
        let dim = Tip(id: "brightness", text: "Screen at 85%: dim to 40%", gain: 41, estimated: true, fix: .dim(to: 0.4))
        let hog = Tip(id: "app", text: "Web Browser is working hard: 62% of a core", gain: 25, estimated: true, fix: .quit(app: "Web Browser"))
        let lowPower = Tip(id: "lowpower", text: "Under 30% with Low Power off", gain: 22, estimated: true, fix: .lowPower)
        let states: [(name: String, monitor: Monitor, expanded: [String], hours: Int)] = [
            ("setup", Monitor(shots: Settings(), reading: reading(percent: 84, onAC: false, at: now), forecast: nil, helperReady: false, aiStatus: .notEnabled,
                              welcome: true, defaults: defaults, source: source), [], 24),
            ("battery", make(84, false, flat, .clear, [dim, hog], Settings()), [], 24),
            ("charging", make(62, true, full, .clear, [], Settings()), ["stretchExpanded", "chargingExpanded"], 24),
            ("warning", make(18, false, low, .warning, [lowPower], Settings()), ["alertsExpanded"], 24),
            ("history", make(84, false, flat, .clear, [], shortcut), ["historyExpanded", "devicesExpanded"], 24),
            ("history-12h", make(84, false, flat, .clear, [], shortcut), ["historyExpanded"], 12),
            ("history-3d", make(84, false, flat, .clear, [], shortcut), ["historyExpanded"], 72),
            ("update", make(84, false, flat, .clear, [dim], Settings()), ["healthExpanded"], 24),   // last: the sample update card stays offered
        ]
        for state in states {
            if state.name == "update" { Updater.shared.offerSample() }
            defaults.set(state.name != "setup", forKey: "tapHintSeen")
            defaults.set(state.hours, forKey: "historyHours")
            for key in ["alertsExpanded", "healthExpanded", "stretchExpanded", "chargingExpanded", "historyExpanded", "devicesExpanded"] { defaults.set(state.expanded.contains(key), forKey: key) }
            for dark in [false, true] {
                write(Panel(monitor: state.monitor).content.frame(width: 344), as: "\(state.name)-\(dark ? "dark" : "light")", dark: dark, to: out)
                if ["battery", "warning"].contains(state.name) { write(HoverCardView(monitor: state.monitor), as: "hover-\(state.name)-\(dark ? "dark" : "light")", dark: dark, to: out) }
            }
        }
        defaults.removePersistentDomain(forName: suite)
        print("Wrote \(states.count * 2 + 4) shots to \(out.path)")
        exit(0)
    }

    /// A battery source that never reports.
    private final class NoSource: BatterySource {
        var onReading: ((Reading?) -> Void)?
        let interval: TimeInterval = 60
        func start() {}
        func refresh() {}
    }

    private static func reading(percent: Int, onAC: Bool, at now: Date) -> Reading {
        var r = Reading(at: now, percent: percent, onAC: onAC, charging: onAC && percent < 100, full: onAC && percent >= 100)
        r.osMinutesLeft = onAC ? (100 - percent) * 2 : percent * 3
        r.maxCapacity = 96
        r.rawCurrent = Double(percent) / 100 * 5895
        r.rawMax = 5895
        r.cellCapacity = 6460
        r.designCapacity = 6249
        r.cycles = 132
        r.designCycles = 1000
        r.volts = 12.4
        r.amps = onAC ? 2.4 : -1.4
        r.celsius = 31.2
        r.systemWatts = onAC ? 18.3 : 17.4
        if onAC { r.adapterWatts = 70; r.adapterName = "70W USB-C Power Adapter" }
        return r
    }

    /// Three days, a point a minute like the real curve, by the clock: asleep 00:00–07:00 (a gap), charging from 30 %
    /// to full over the morning, full on the charger until four, then draining through the evening — to 30 % on the
    /// earlier days; today it comes off the charger and drains to 84 % at "now". Three weeks of daily log for the coach.
    private static func history(now: Date) -> History {
        var h = History()
        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        let drainFrom = max(now.addingTimeInterval(-8 * 3600), today.addingTimeInterval(10 * 3600))   // today's drain: the last eight hours, once up
        for i in stride(from: 3 * 24 * 60 - 1, through: 0, by: -1) {
            let t = now.addingTimeInterval(-Double(i) * 60)
            let day = calendar.startOfDay(for: t), minute = t.timeIntervalSince(day) / 60
            guard minute >= 7 * 60 else { continue }   // asleep until 07:00
            let level: Double, charging: Bool
            if day == today, t >= drainFrom, now.timeIntervalSince(drainFrom) > 60 {
                level = 100 - t.timeIntervalSince(drainFrom) / now.timeIntervalSince(drainFrom) * 16; charging = false
            } else if minute < 10 * 60 { level = 30 + (minute - 7 * 60) / 180 * 70; charging = true }
            else if minute < 16 * 60 { level = 100; charging = true }
            else { level = 100 - (minute - 16 * 60) / 480 * 70; charging = false }
            h.points.append(History.Point(t: t, l: level, w: charging ? (level < 100 ? 30 : 0) : -17, c: charging))
        }
        h.days = (0..<21).map { DayLog(day: now.addingTimeInterval(Double($0 - 20) * 86400), cycles: 112 + $0, health: 96.4 - Double($0) * 0.02) }
        h.learner.discharges = 3
        h.learner.relativeError = 0.08
        return h
    }

    private static func sample(_ name: String, symbol: String, from: (CGFloat, CGFloat, CGFloat), to: (CGFloat, CGFloat, CGFloat),
                               cpuPercent: Double, share: Double) -> AppEnergy {
        let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)) ?? NSImage()
        let white = symbolImage.copy() as! NSImage   // the symbol as a white shape
        white.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: white.size).fill(using: .sourceAtop)
        white.unlockFocus()
        let icon = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            NSGradient(starting: NSColor(red: from.0, green: from.1, blue: from.2, alpha: 1), ending: NSColor(red: to.0, green: to.1, blue: to.2, alpha: 1))?.draw(in: tile, angle: -90)
            white.draw(in: NSRect(x: (rect.width - white.size.width) / 2, y: (rect.height - white.size.height) / 2, width: white.size.width, height: white.size.height))
            return true
        }
        var app = AppEnergy(id: "/Applications/\(name).app", name: name, bundle: "/Applications/\(name).app", cpuPercent: cpuPercent, share: share)
        app.icon = icon
        return app
    }

    private static let devices = [AccessoryBattery.Device(id: "trackpad", name: "Trackpad", percent: 12, kind: .trackpad),
                                  AccessoryBattery.Device(id: "mouse", name: "Mouse", percent: 47, kind: .mouse),
                                  AccessoryBattery.Device(id: "keyboard", name: "Keyboard", percent: 88, kind: .keyboard)]

    /// Made-up apps, since a screenshot can't show anyone's real ones: each with an icon drawn here — a white symbol
    /// on a rounded gradient tile, the way app icons read at this size.
    private static let ranking = Ranking(
        apps: [sample("Web Browser", symbol: "globe", from: (0.20, 0.55, 1.0), to: (0.05, 0.35, 0.85), cpuPercent: 62, share: 0.34),
               sample("Video Call", symbol: "video.fill", from: (0.35, 0.80, 0.45), to: (0.10, 0.60, 0.30), cpuPercent: 21, share: 0.12),
               sample("Photo Editor", symbol: "photo.fill", from: (1.0, 0.60, 0.30), to: (0.90, 0.35, 0.40), cpuPercent: 11, share: 0.06),
               sample("Code Builder", symbol: "hammer.fill", from: (0.45, 0.45, 0.50), to: (0.25, 0.25, 0.30), cpuPercent: 5, share: 0.03)],
        background: [AppEnergy(id: "WindowServer", name: "WindowServer", bundle: nil, cpuPercent: 30, share: 0.16),
                     AppEnergy(id: "kernel_task", name: "kernel_task", bundle: nil, cpuPercent: 14, share: 0.08)],
        backgroundShare: 0.45)

    /// Ordered in but off every display, and key: AppKit then draws the controls in their active look.
    private final class ShotWindow: NSWindow { override var canBecomeKey: Bool { true } }

    /// The view at its natural size on the window background, in the light or dark appearance.
    private static func write<V: View>(_ view: V, as name: String, dark: Bool, to dir: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        let window = ShotWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: host.fittingSize),
                                styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill(); host.bounds.fill() }
        NSGraphicsContext.restoreGraphicsState()
        host.cacheDisplay(in: host.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}
