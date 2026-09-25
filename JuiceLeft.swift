import SwiftUI

// JuiceLeft — a battery monitor for the menu bar: a self-calibrating forecast of when the Mac will go flat, a red
// pulse at the warning level, a tone at the alert level, the apps using the most power, and battery health.
// The menu-bar item lives in StatusItem.swift, the panel in Panel.swift / PanelSections.swift, the model in
// Forecast.swift, the alert rules in Alerts.swift and the glue in Monitor.swift.

@main struct JuiceLeftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--selftest") { selfTest() }
    }

    var body: some Scene {
        SwiftUI.Settings { EmptyView() }   // no windows of its own; the status item owns the panel
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let simulate = args.contains("--simulate")
        let source: BatterySource = simulate ? Simulator(hold: args.contains("hold")) : LiveBattery()
        let defaults = simulate ? UserDefaults(suiteName: "io.github.cyborgfingers.juiceleft.simulate")! : .standard
        let historyURL = simulate ? FileManager.default.temporaryDirectory.appendingPathComponent("juiceleft-simulate-history.json") : History.url
        let monitor = Monitor(source: source, defaults: defaults, historyURL: historyURL)
        if simulate {
            monitor.log = { line in print("SIM \(line)"); fflush(stdout) }
            if let i = args.firstIndex(of: "--volume"), i + 1 < args.count, let volume = Double(args[i + 1]) { monitor.s.volume = volume }
        }
        self.monitor = monitor
        statusItem = StatusItemController(monitor: monitor)
        monitor.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Self-test

/// `JuiceLeft.app/Contents/MacOS/JuiceLeft --selftest`: the pure parts (forecast model and its learning, alert rules,
/// gesture, settings migration, app grouping) plus the OS hooks (battery read, sound, glyph drawing).
@MainActor private func selfTest() -> Never {
    func check(_ ok: Bool, _ what: String) { precondition(ok, "FAIL: \(what)") }
    func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= abs(b) * tolerance }

    // Words.
    check(Format.compact(130) == "2:10" && Format.compact(45) == "45m" && Format.duration(130) == "2 h 10 m" && Format.duration(7) == "7 min", "formats")
    check(Format.spokenDuration(61) == "1 hour 1 minute", "spoken duration")

    // Alert rules, down a discharge and back.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let at = { (m: Double) in t0.addingTimeInterval(m * 60) }
    let run = { (s: Alerts.State, armed: Bool, ac: Bool, pct: Int, m: Double) in
        Alerts.step(s, armed: armed, onAC: ac, percent: pct, warnAt: 20, alertAt: 10, repeatMinutes: 5, now: at(m))
    }
    var o = run(Alerts.State(), false, false, 5, 0)
    check(o.phase == .clear && !o.playTone, "disarmed: nothing")
    o = run(Alerts.State(), true, false, 25, 0)
    check(o.phase == .clear && !o.enteredWarning, "25%: clear")
    o = run(o.state, true, false, 20, 1)
    check(o.phase == .warning && o.enteredWarning && !o.playTone, "20%: warning entered, no tone")
    o = run(o.state, true, false, 21, 2)
    check(o.phase == .warning && !o.enteredWarning, "21%: still warning (hysteresis)")
    o = run(o.state, true, false, 22, 3)
    check(o.phase == .clear, "22%: warning released")
    o = run(o.state, true, false, 10, 4)
    check(o.phase == .alert && o.enteredAlert && o.enteredWarning && o.playTone, "10%: alert entered, tone")
    o = run(o.state, true, false, 11, 5)
    check(o.phase == .alert && !o.playTone, "11%: no re-fire")
    o = run(o.state, true, false, 10, 6)
    check(o.phase == .alert && !o.playTone, "10% again, 2 min later: no repeat yet")
    o = run(o.state, true, false, 9, 9.5)
    check(o.playTone, "5 min later: repeat")
    o = run(o.state, true, false, 12, 10)
    check(o.phase == .warning && !o.playTone, "12%: alert released to warning")
    o = run(o.state, true, false, 10, 11)
    check(o.phase == .alert && o.playTone && o.enteredAlert, "back to 10%: tone again")
    var snoozed = o.state
    snoozed.snoozedUntil = at(41)
    o = run(snoozed, true, false, 9, 12)
    check(o.phase == .clear && !o.playTone, "snoozed: quiet")
    o = run(o.state, true, false, 9, 41)
    check(o.phase == .alert && o.playTone, "snooze over: tone, flash")
    o = run(o.state, true, true, 9, 42)
    check(o.phase == .clear && o.state == Alerts.State(), "charger in: clear and reset")
    check(Alerts.step(Alerts.State(), armed: true, onAC: false, percent: 10, warnAt: 20, alertAt: 10, repeatMinutes: 0, now: at(0)).playTone, "once: fires on entry")
    var once = Alerts.step(Alerts.State(), armed: true, onAC: false, percent: 10, warnAt: 20, alertAt: 10, repeatMinutes: 0, now: at(0)).state
    once = Alerts.step(once, armed: true, onAC: false, percent: 8, warnAt: 20, alertAt: 10, repeatMinutes: 0, now: at(30)).state
    check(once.lastToneAt == at(0), "once: never repeats")

    // The forecast model on a perfect line: 30 %/h from 80 %.
    var samples: [Sample] = []
    for i in 0...20 { samples.append(Sample(at: at(Double(i) * 0.5), level: 80 - 30 * Double(i) * 0.5 / 60, ratePerHour: -30)) }
    let (live, trend) = Learner.liveAndTrend(samples, now: at(10))
    check(near(live ?? 0, -30, 0.01) && near(trend ?? 0, -30, 0.01), "live and trend both read 30 %/h: \(String(describing: live)) \(String(describing: trend))")
    var fresh = Learner()
    let f = fresh.step(samples, now: at(10))
    check(f?.kind == .flat && near(Double(f?.minutes ?? 0), 75 * 2, 0.01), "75 % at 30 %/h → 150 min: \(String(describing: f?.minutes))")
    check(fresh.step([Sample(at: at(0), level: 50, ratePerHour: nil)], now: at(0)) == nil, "no opinion without data")
    check(Learner.chargeForecast([], level: 50, now: at(0), osMinutes: 42)?.minutes == 42, "charging uses macOS's estimate")
    var up: [Sample] = []
    for i in 0...10 { up.append(Sample(at: at(Double(i)), level: 50 + 20 * Double(i) / 60, ratePerHour: 20)) }
    check(near(Double(Learner.chargeForecast(up, level: up.last!.level, now: at(10), osMinutes: nil)?.minutes ?? 0), (50 - 20.0 / 6) / 20 * 60, 0.02), "charging from the curve")

    // Learning: a synthetic user who drains 12 %/h in the morning and 30 %/h in the evening, five weekdays.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    var seed: UInt64 = 42
    let noise = { (spread: Double) -> Double in   // deterministic ±spread
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return (Double(seed >> 11) / Double(1 << 53) * 2 - 1) * spread
    }
    /// One discharge: samples every 30 s, the level following `rate` (±5 %), the gauge reading it ±10 % times `gauge`.
    func discharge(_ learner: inout Learner, day: Int, hour: Int, hours: Double, from: Double, rate: Double, gauge: Double = 1) -> (first: Forecast?, last: Forecast?) {
        let start = cal.date(from: DateComponents(year: 2026, month: 3, day: 2 + day, hour: hour))!   // 2 March 2026 is a Monday
        var samples: [Sample] = [], level = from, first: Forecast?, last: Forecast?
        for i in 0...Int(hours * 120) {
            let now = start.addingTimeInterval(Double(i) * 30)
            if i > 0 { level -= rate * (1 + noise(0.05)) / 120 }
            samples.append(Sample(at: now, level: level, ratePerHour: -rate * gauge * (1 + noise(0.1))))
            samples.removeAll { now.timeIntervalSince($0.at) > 2 * Learner.window }
            last = learner.step(samples, now: now, calendar: cal)
            if i == 0 { first = last }
        }
        learner.endDischarge(now: start.addingTimeInterval(hours * 3600), level: level, calendar: cal)
        return (first, last)
    }
    var learner = Learner()
    check(learner.prior(at: at(0), calendar: cal) == nil, "no prior before learning")
    for day in 0..<5 {
        _ = discharge(&learner, day: day, hour: 8, hours: 3, from: 90, rate: 12)
        _ = discharge(&learner, day: day, hour: 17, hours: 2, from: 70, rate: 30)
    }
    let morning = learner.buckets[Learner.slot(cal.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 9))!, calendar: cal)]
    let evening = learner.buckets[Learner.slot(cal.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 18))!, calendar: cal)]
    check(near(morning.rate, 12, 0.15) && near(evening.rate, 30, 0.15), "priors converge: morning \(morning.rate) evening \(evening.rate)")
    check(learner.discharges == 10 && (learner.relativeError ?? 1) < 0.15, "arrival accuracy scored: \(learner.discharges) discharges, miss \(String(describing: learner.relativeError))")
    check((learner.typicalMiss(for: 120) ?? 0) >= 5, "typical miss is a number")
    // Day 6 (Monday): the very first sample of a morning already forecasts from the live gauge and the prior.
    let sixth = discharge(&learner, day: 7, hour: 8, hours: 3, from: 90, rate: 12)
    check(sixth.first?.learned == true && near(Double(sixth.first?.minutes ?? 0), 90 / 12 * 60, 0.15), "first-sample forecast within 15 %: \(String(describing: sixth.first?.minutes)) of 450")
    check(near(Double(sixth.last?.minutes ?? 0), (90 - 36) / 12 * 60, 0.1), "end-of-session forecast within 10 %: \(String(describing: sixth.last?.minutes)) of 270")
    // The pattern changes: evenings become 45 %/h. The prior follows within a week.
    for day in 7..<12 { _ = discharge(&learner, day: day, hour: 17, hours: 2, from: 70, rate: 45) }
    let evening2 = learner.buckets[Learner.slot(cal.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 18))!, calendar: cal)]
    check(evening2.rate > 40, "prior adapts to the new evening pace: \(evening2.rate)")
    // A gauge that reads 50 % high loses its say: the blend stays near the truth and the live error stands out.
    var skew: Forecast?
    for day in 14..<19 { skew = discharge(&learner, day: day, hour: 8, hours: 3, from: 90, rate: 12, gauge: 1.5).last }
    check(learner.errors[RateSource.live.rawValue] > 2 * learner.errors[RateSource.trend.rawValue], "live error stands out: \(learner.errors)")
    check(near(skew?.ratePerHour ?? 0, 12, 0.1), "blend within 10 % despite the skewed gauge: \(String(describing: skew?.ratePerHour))")
    var abandoned = learner
    _ = abandoned.step(samples, now: at(10), calendar: cal)
    abandoned.abandon()
    check(abandoned.pending.isEmpty && abandoned.made.isEmpty, "abandon clears the checks")
    let roundTrip = try? JSONDecoder().decode(Learner.self, from: JSONEncoder().encode(learner))
    check(roundTrip == learner, "learner survives a save")

    // Settings: a stored blob missing new keys keeps its own values, and the levels are kept sane.
    let suite = "io.github.cyborgfingers.juiceleft.selftest"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(#"{"warnAt":25,"alertAt":30,"bogus":1}"#.data(using: .utf8), forKey: Settings.key)
    let loaded = Settings.load(defaults)
    defaults.removePersistentDomain(forName: suite)
    check(loaded.warnAt == 25 && loaded.alertAt == 25 && loaded.tone == Tone.chimeName && loaded.menuBar == .time, "settings merge + clamp: \(loaded)")

    // Apps: helpers fold into the app; only real user apps get a Quit button.
    let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"
    check(EnergyMeter.app(for: chrome).name == "Google Chrome" && EnergyMeter.app(for: chrome).bundle == "/Applications/Google Chrome.app", "helper → app")
    check(EnergyMeter.app(for: "/usr/bin/python3").name == "python3" && EnergyMeter.app(for: "/usr/bin/python3").bundle == nil, "bare executable")
    let before: EnergyMeter.Snapshot = [1: (1.0, chrome), 2: (5.0, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), 3: (0.0, "/usr/bin/python3"), 4: (2.0, "/bin/zsh")]
    let after: EnergyMeter.Snapshot = [1: (3.0, chrome), 2: (6.0, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), 3: (0.5, "/usr/bin/python3"), 5: (9.0, "/bin/zsh")]
    let ranked = EnergyMeter.rank(before: before, after: after, seconds: 3)
    check(ranked.map(\.name) == ["Google Chrome", "python3"] && near(ranked[0].cpuPercent, 100, 0.01) && near(ranked[1].share, 0.5 / 3, 0.01), "ranking: \(ranked)")
    check(EnergyMeter.mayQuit(bundle: "/Applications/Safari.app", bundleID: "com.apple.Safari", policy: .regular, isSelf: false), "Safari may quit")
    check(!EnergyMeter.mayQuit(bundle: "/System/Library/CoreServices/Finder.app", bundleID: "com.apple.finder", policy: .regular, isSelf: false), "not Finder")
    check(!EnergyMeter.mayQuit(bundle: "/System/Library/CoreServices/ControlCenter.app", bundleID: "com.apple.controlcenter", policy: .accessory, isSelf: false), "not Control Center")
    check(!EnergyMeter.mayQuit(bundle: "/Applications/JuiceLeft.app", bundleID: "io.github.cyborgfingers.juiceleft", policy: .accessory, isSelf: true), "not itself")
    check(!EnergyMeter.mayQuit(bundle: nil, bundleID: nil, policy: .regular, isSelf: false), "not a bare process")
    check(!EnergyMeter.mayQuit(bundle: "/Library/Foo.app", bundleID: "x", policy: .prohibited, isSelf: false), "not a background process")

    // Apple Intelligence guard: the model may only use numbers it was given.
    check(AppleIntelligence.keepsNumbers("Flat in 2 h 50 min, at 34%.", facts: "Battery 34%. Flat in 2 h 50 min."), "numbers kept")
    check(!AppleIntelligence.keepsNumbers("About 3 hours left.", facts: "Battery 34%. Flat in 2 h 50 min."), "invented number caught")
    let facts = Insight.Facts(percent: 34, onAC: false, charging: false, full: false, minutesLeft: 170, ratePerHour: 12, typicalRate: 9, topApps: ["Chrome"])
    check(Insight.template(facts).contains("faster") && Insight.template(facts).contains("Chrome"), "template: \(Insight.template(facts))")

    // Click decision: quick press or right/⌃-click = panel, held past the deadline = toggle monitoring.
    check(StatusItemController.gesture(.leftMouseDown, control: false) { true } == .panel, "quick press opens the panel")
    check(StatusItemController.gesture(.leftMouseDown, control: false) { false } == .toggle, "hold toggles")
    check(StatusItemController.gesture(.rightMouseDown, control: false) { true } == .panel, "right-click opens the panel")
    check(StatusItemController.gesture(.leftMouseDown, control: true) { false } == .panel, "control-click opens the panel")

    // OS hooks: the battery reads, the chime decodes, every glyph state draws.
    let reading = LiveBattery.read()
    check(reading != nil, "battery read")
    check(NSSound(data: Tone.chime) != nil, "chime decodes")
    for frame in [MenuIcon.Frame(level: 100), MenuIcon.Frame(level: 15, plugged: true), MenuIcon.Frame(level: 50, armed: false),
                  MenuIcon.Frame(level: 8, red: 0.6), MenuIcon.Frame(level: 0, missing: true)] {
        check(MenuIcon.draw(frame).tiffRepresentation != nil && MenuIcon.draw(frame, side: 44).tiffRepresentation != nil, "glyph draws \(frame)")
    }

    let r = reading!
    print("PASS: alert rules, forecast + learning (priors \(String(format: "%.1f", morning.rate))/\(String(format: "%.1f", evening.rate)) → \(String(format: "%.1f", evening2.rate)) %/h, miss \(String(format: "%.0f", (learner.relativeError ?? 0) * 100))%), settings, apps, gesture, glyphs; battery \(r.percent)% \(r.onAC ? "on power" : "on battery"), health \(r.health.map { String(format: "%.0f%%", $0) } ?? "?"), \(r.cycles ?? 0) cycles; Apple Intelligence \(AppleIntelligence.available ? "available" : "not available")")
    exit(0)
}
