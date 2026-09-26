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
        let hog = Tip(id: "app", text: "Safari is working hard: 62% of a core", gain: 25, estimated: true, fix: .quit(app: "Safari"))
        let lowPower = Tip(id: "lowpower", text: "Under 30% with Low Power off", gain: 22, estimated: true, fix: .lowPower)
        let states: [(name: String, monitor: Monitor, expanded: [String])] = [
            ("setup", Monitor(shots: Settings(), reading: reading(percent: 84, onAC: false, at: now), forecast: nil, helperReady: false, aiStatus: .notEnabled,
                              welcome: true, defaults: defaults, source: source), []),
            ("battery", make(84, false, flat, .clear, [dim, hog], Settings()), []),
            ("charging", make(62, true, full, .clear, [], Settings()), ["stretchExpanded", "chargingExpanded"]),
            ("warning", make(18, false, low, .warning, [lowPower], Settings()), ["alertsExpanded"]),
            ("history", make(84, false, flat, .clear, [], shortcut), ["historyExpanded", "devicesExpanded"]),
            ("update", make(84, false, flat, .clear, [dim], Settings()), ["healthExpanded"]),   // last: the sample update card stays offered
        ]
        for state in states {
            if state.name == "update" { Updater.shared.offerSample() }
            defaults.set(state.name != "setup", forKey: "tapHintSeen")
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

    /// Three days, a point a minute like the real curve: each day sleeps seven hours (a gap), charges from 30 % to
    /// full over the morning, sits full on the charger, then drains through the afternoon and evening — to 30 % on
    /// the earlier days, to 84 % today. Three weeks of daily log for the coach.
    private static func history(now: Date) -> History {
        var h = History()
        let day = 24 * 60
        for i in 0..<(3 * day) {
            let k = i % day, d = 2 - i / day   // minute of that day, and 0 = today
            guard k >= 420 else { continue }   // asleep until 07:00
            let t = now.addingTimeInterval(Double(i - 3 * day + 1) * 60)
            let level: Double, charging: Bool
            if k < 600 { level = 30 + Double(k - 420) / 180 * 70; charging = true }
            else if k < 960 { level = 100; charging = true }
            else { level = 100 - Double(k - 960) / 480 * (d == 0 ? 16 : 70); charging = false }
            h.points.append(History.Point(t: t, l: level, w: charging ? (level < 100 ? 30 : 0) : -17, c: charging))
        }
        h.days = (0..<21).map { DayLog(day: now.addingTimeInterval(Double($0 - 20) * 86400), cycles: 112 + $0, health: 96.4 - Double($0) * 0.02) }
        h.learner.discharges = 3
        h.learner.relativeError = 0.08
        return h
    }

    private static let devices = [AccessoryBattery.Device(id: "trackpad", name: "Magic Trackpad", percent: 12, kind: .trackpad),
                                  AccessoryBattery.Device(id: "mouse", name: "Magic Mouse", percent: 47, kind: .mouse),
                                  AccessoryBattery.Device(id: "keyboard", name: "Magic Keyboard", percent: 88, kind: .keyboard)]

    private static let ranking = Ranking(
        apps: [AppEnergy(id: "/Applications/Safari.app", name: "Safari", bundle: "/Applications/Safari.app", cpuPercent: 62, share: 0.34),
               AppEnergy(id: "/System/Applications/Music.app", name: "Music", bundle: "/System/Applications/Music.app", cpuPercent: 21, share: 0.12),
               AppEnergy(id: "/System/Applications/Mail.app", name: "Mail", bundle: "/System/Applications/Mail.app", cpuPercent: 11, share: 0.06),
               AppEnergy(id: "/System/Applications/Utilities/Terminal.app", name: "Terminal", bundle: "/System/Applications/Utilities/Terminal.app", cpuPercent: 5, share: 0.03)],
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
