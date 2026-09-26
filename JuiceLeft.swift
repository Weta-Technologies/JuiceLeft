import SwiftUI

// JuiceLeft — a battery monitor for the menu bar: a self-calibrating forecast of when the Mac will go flat, a red
// pulse at the warning level, a tone at the alert level, the apps using the most power, and battery health.
// The menu-bar item lives in StatusItem.swift, the panel in Panel.swift / PanelSections.swift, the model in
// Forecast.swift, the alert rules in Alerts.swift and the glue in Monitor.swift.

@main struct JuiceLeftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--selftest") { selfTest() }
        if let i = CommandLine.arguments.firstIndex(of: "--shots"), i + 1 < CommandLine.arguments.count { Shots.run(dir: CommandLine.arguments[i + 1]) }
    }

    var body: some Scene {
        SwiftUI.Settings { EmptyView() }   // no windows of its own; the status item owns the panel
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var monitor: Monitor?
    var statusItem: StatusItemController?
    var quitIntercept: (() -> Bool)?   // --e2e: Quit is watched, not obeyed

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Updater.shared.testRun { return Updater.shared.start() }   // --update-test: only the updater, on a copy of the app
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--e2e"), i + 1 < args.count { E2E.run(dir: args[i + 1], delegate: self) }   // every function, on fakes
        let simulate = args.contains("--simulate")
        if simulate { FakeMac().install() }   // the helper, the charge limit and the battery item are stand-ins: nothing real changes
        let source: BatterySource = simulate ? Simulator(hold: args.contains("hold")) : LiveBattery()
        let defaults = simulate ? UserDefaults(suiteName: "io.github.cyborgfingers.juiceleft.simulate")! : .standard
        let historyURL = simulate ? FileManager.default.temporaryDirectory.appendingPathComponent("juiceleft-simulate-history.json") : History.url
        let monitor = Monitor(source: source, defaults: defaults, historyURL: historyURL, hardware: simulate ? FakeHardware() : RealHardware())
        if simulate {
            monitor.interactive = false
            monitor.log = { line in print("SIM \(line)"); fflush(stdout) }
            if let i = args.firstIndex(of: "--volume"), i + 1 < args.count, let volume = Double(args[i + 1]) { monitor.s.volume = volume }
        }
        self.monitor = monitor
        statusItem = StatusItemController(monitor: monitor)
        monitor.start()
        if !simulate { Updater.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { quitIntercept?() == true ? .terminateCancel : .terminateNow }

    /// The user's own shortcuts and scripts drive JuiceLeft through its `juiceleft://` scheme; only the whitelisted actions run.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { if let action = URLAction.parse(url) { monitor?.handle(action) } }
    }
}

// MARK: - Self-test

/// `JuiceLeft.app/Contents/MacOS/JuiceLeft --selftest`: the pure parts (forecast model and its learning, alert rules,
/// gesture, settings migration, app grouping) plus the OS hooks (battery read, sound, glyph drawing).
@MainActor private func selfTest() -> Never {
    func check(_ ok: Bool, _ what: String) { if !ok { fatalError("FAIL: \(what)") } }   // fatalError keeps its message under -O
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
    check(Learner.chargeForecast([], level: 50, now: at(0)) == nil, "charging: nothing to go on, no forecast (never macOS's hour-plus figure)")
    var up: [Sample] = []
    for i in 0...10 { up.append(Sample(at: at(Double(i)), level: 50 + 20 * Double(i) / 60, ratePerHour: 20)) }
    check(near(Double(Learner.chargeForecast(up, level: up.last!.level, now: at(10))?.minutes ?? 0), Learner.chargeHours(from: up.last!.level, to: 100, rate: 20) * 60, 0.02), "charging from the curve, through the taper")

    // The trace of a 70 W charger into a pack held to 80 %: 43–48 W in (57–63 %/h on the gauge) from 70.5 % at plug-in,
    // 75 % five minutes on, 80 % ten minutes on. Before: "1 Hour 10 Min Until Full" (macOS's figure, aimed at 100 %).
    var trace: [Sample] = []
    for i in 0...20 { trace.append(Sample(at: at(Double(i) * 0.5), level: 70.5 + Double(i) * 0.5, ratePerHour: [57, 63, 59, 61][i % 4])) }
    let first = Learner.chargeForecast(Array(trace.prefix(2)), level: trace[1].level, now: trace[1].at, target: 80)
    check((8...15).contains(first?.minutes ?? 0) && first?.target == 80, "71 % with 43–48 W in and an 80 % limit: 8–15 min to the limit, got \(String(describing: first?.minutes))")
    check(Format.words(first!.minutes, charging: true, goal: first!.goalText) == "10 Min Until 80%", "worded as \(Format.words(first!.minutes, charging: true, goal: first!.goalText))")
    check(Monitor.menuParts(.words, percent: 71, onAC: true, full: false, charging: true, minutes: first!.minutes, goal: first!.goalText).trailing == "10 Min Until 80%"
          && Monitor.menuParts(.compact, percent: 71, onAC: true, full: false, charging: true, minutes: 18, goal: "80%").trailing == "18m", "the words aim at the limit; compact is the time alone")
    let later = Learner.chargeForecast(Array(trace.prefix(11)), level: trace[10].level, now: trace[10].at, target: 80)
    check((3...7).contains(later?.minutes ?? 0), "five minutes in, at 75.5 %: \(String(describing: later?.minutes)) min to go")
    check(Learner.chargeForecast(trace, level: 80.5, now: trace.last!.at, target: 80) == nil, "at the limit: no countdown")
    // Above 80 % the gauge's own current is already tapered: a 60 %/h charger seen from 84 % on is still on course
    // for the 60 %/h time to full, not a second taper's.
    var tapering = [Sample(at: at(0), level: 84, ratePerHour: 60 * Learner.taper(at: 84))]
    for i in 1...40 {
        let l = tapering[i - 1].level + 60 * Learner.taper(at: tapering[i - 1].level) * 0.5 / 60
        tapering.append(Sample(at: at(Double(i) * 0.5), level: l, ratePerHour: 60 * Learner.taper(at: l)))
    }
    let late = Learner.chargeForecast(tapering, level: tapering.last!.level, now: tapering.last!.at)
    let lateWant = Learner.chargeHours(from: tapering.last!.level, to: 100, rate: 60) * 60
    check(near(Double(late?.minutes ?? 0), lateWant, 0.05) && near(late?.ratePerHour ?? 0, 60 * Learner.taper(at: tapering.last!.level), 0.05),
          "above 80 %: \(String(describing: late?.minutes)) min to full against \(Int(lateWant)), measured \(String(describing: late?.ratePerHour)) %/h")
    check(Learner.chargeForecast([Sample(at: at(0), level: 71, ratePerHour: nil)], level: 71, now: at(0), target: 80) == nil, "a sample without a measured rate is no measurement")
    let toFull = Learner.chargeForecast(Array(trace.prefix(2)), level: trace[1].level, now: trace[1].at)
    let straight = (100 - trace[1].level) / (toFull?.ratePerHour ?? 1) * 60
    check(toFull?.target == 100 && Double(toFull?.minutes ?? 0) > straight * 1.4 && Double(toFull?.minutes ?? 0) < straight * 2.2,
          "no limit: the taper makes 100 % \(String(describing: toFull?.minutes)) min away against \(Int(straight)) straight")
    check(Format.words(toFull!.minutes, charging: true, goal: toFull!.goalText).hasSuffix("Until Full"), "no limit: Until Full")
    check(near(Learner.chargeHours(from: 40, to: 80, rate: 60), 40.0 / 60, 0.001) && near(Learner.chargeHours(from: 71, to: 80, rate: 60), 9.0 / 60, 0.001), "below 80 % nothing slows the charge")
    check(near(Learner.chargeHours(from: 80, to: 100, rate: 60), log(5) / (60 * 0.04), 0.001) && near(Learner.chargeHours(from: 90, to: 100, rate: 60), log(0.6 / 0.2) / (60 * 0.04), 0.001), "the taper's integral")
    check(Monitor.fullNotice(full: false, onAC: true, charging: false, percent: 80, limit: 80) == "Held at 80%", "held at the limit: the header's line")

    // On battery, a learned habit mustn't drag a fresh discharge: 8 %/h typical, 24 %/h measured → the forecast leans on the measurement.
    var habit = Learner()
    for _ in 0..<3 { habit.global.learn(8) }
    var fresh24: [Sample] = []
    for i in 0...2 { fresh24.append(Sample(at: at(Double(i) * 0.5), level: 60 - 24 * Double(i) * 0.5 / 60, ratePerHour: -24)) }
    let early = habit.step(fresh24, now: at(1))
    check(near(early?.ratePerHour ?? 0, 24, 0.25) && early?.learned == true, "a minute into a discharge the measured 24 %/h outweighs a typical 8 %/h: \(String(describing: early?.ratePerHour))")

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
    defaults.set(#"{"warnAt":25,"alertAt":30,"bogus":1,"menuBar":"time"}"#.data(using: .utf8), forKey: Settings.key)
    let loaded = Settings.load(defaults)
    defaults.removePersistentDomain(forName: suite)
    check(loaded.warnAt == 25 && loaded.alertAt == 25 && loaded.tone == Tone.chimeName && loaded.menuBar == .words && loaded.replaceSystemIcon, "settings merge + clamp: \(loaded)")

    // Apps: helpers fold into the app; only real user apps get a Quit button.
    let helper = "/Applications/Example Browser.app/Contents/Frameworks/Example Browser Framework.framework/Versions/1/Helpers/Example Browser Helper (GPU).app/Contents/MacOS/Example Browser Helper (GPU)"
    check(EnergyMeter.app(for: helper).name == "Example Browser" && EnergyMeter.app(for: helper).bundle == "/Applications/Example Browser.app", "helper → app")
    check(EnergyMeter.app(for: "/usr/bin/python3").name == "python3" && EnergyMeter.app(for: "/usr/bin/python3").bundle == nil, "bare executable")
    let before: EnergyMeter.Snapshot = [1: (1.0, helper), 2: (5.0, "/Applications/Example Browser.app/Contents/MacOS/Example Browser"), 3: (0.0, "/usr/bin/python3"), 4: (2.0, "/bin/zsh")]
    let after: EnergyMeter.Snapshot = [1: (3.0, helper), 2: (6.0, "/Applications/Example Browser.app/Contents/MacOS/Example Browser"), 3: (0.5, "/usr/bin/python3"), 5: (9.0, "/bin/zsh")]
    let userApps: Set<String> = ["/Applications/Example Browser.app"]
    let ranked = EnergyMeter.rank(before: before, after: after, seconds: 3, apps: userApps)
    check(ranked.apps.map(\.name) == ["Example Browser"] && near(ranked.apps[0].cpuPercent, 100, 0.01) && near(ranked.apps[0].share, 3 / 3.5, 0.01), "ranking: apps only, share of the total: \(ranked)")
    check(ranked.background.map(\.name) == ["python3"] && near(ranked.backgroundShare, 0.5 / 3.5, 0.01), "ranking: the rest rolls up: \(ranked)")
    let idle: EnergyMeter.Snapshot = [2: (5.02, "/Applications/Example Browser.app/Contents/MacOS/Example Browser"), 3: (9.0, "/usr/bin/python3")]
    let quiet = EnergyMeter.rank(before: before, after: idle, seconds: 3, apps: userApps)
    check(quiet.apps.isEmpty && near(quiet.backgroundShare, 1, 0.01), "ranking: an app below 1% of a core is not listed")
    check(!EnergyMeter.rank(before: before, after: idle, seconds: 3, apps: userApps, pinned: ["/Applications/Example Browser.app"]).apps.isEmpty, "ranking: a quitting app stays pinned")
    check(EnergyMeter.rank(before: before, after: before, seconds: 3, apps: userApps) == Ranking(), "ranking: nothing used, nothing listed")
    check(EnergyMeter.isUserApp(bundle: "/Applications/SleepLess.app", bundleID: "io.github.cyborgfingers.sleepless", policy: .accessory), "a menu-bar app counts as the user's")
    check(!EnergyMeter.isUserApp(bundle: "/System/Library/CoreServices/SystemAgent.app", bundleID: "com.apple.systemagent", policy: .accessory), "a system agent is background")
    check(EnergyMeter.mayQuit(bundle: "/Applications/Example Browser.app", bundleID: "com.example.browser", policy: .regular, isSelf: false), "a user app may quit")
    check(!EnergyMeter.mayQuit(bundle: "/System/Library/CoreServices/SystemApp.app", bundleID: "com.apple.loginwindow", policy: .regular, isSelf: false), "not a system app")
    check(!EnergyMeter.mayQuit(bundle: "/System/Library/CoreServices/ControlCenter.app", bundleID: "com.apple.controlcenter", policy: .accessory, isSelf: false), "not Control Center")
    check(!EnergyMeter.mayQuit(bundle: "/Applications/JuiceLeft.app", bundleID: "io.github.cyborgfingers.juiceleft", policy: .accessory, isSelf: true), "not itself")
    check(!EnergyMeter.mayQuit(bundle: nil, bundleID: nil, policy: .regular, isSelf: false), "not a bare process")
    check(!EnergyMeter.mayQuit(bundle: "/Library/Foo.app", bundleID: "x", policy: .prohibited, isSelf: false), "not a background process")

    // Apple Intelligence guard: the model may only use numbers it was given. The first-launch nudge: only on a Mac
    // that could run it but has it off, and never again once dismissed.
    check(AppleIntelligence.offersNudge(status: .notEnabled, dismissed: false) && !AppleIntelligence.offersNudge(status: .notEnabled, dismissed: true), "nudge when off, not once dismissed")
    for status in [AppleIntelligence.Status.available, .notEligible, .notReady, .unsupported] {
        check(!AppleIntelligence.offersNudge(status: status, dismissed: false), "no nudge when \(status)")
    }
    check(AppleIntelligence.keepsNumbers("Flat in 2 h 50 min, at 34%.", facts: "Battery 34%. Flat in 2 h 50 min."), "numbers kept")
    check(!AppleIntelligence.keepsNumbers("About 3 hours left.", facts: "Battery 34%. Flat in 2 h 50 min."), "invented number caught")
    let facts = Insight.Facts(percent: 34, onAC: false, charging: false, full: false, minutesLeft: 170, ratePerHour: 12, typicalRate: 9, topApps: ["Example Browser"])
    check(Insight.template(facts).contains("faster") && Insight.template(facts).contains("Example Browser"), "template: \(Insight.template(facts))")
    check(Insight.signature(facts, ai: true) != Insight.signature(facts, ai: false), "the wording switch alone is worth new words, both ways")

    // The menu bar's words and text parts, per display style.
    check(Format.words(130, charging: false) == "2 Hours 10 Min Remaining" && Format.words(120, charging: false) == "2 Hours Remaining", "words: hours")
    check(Format.words(60, charging: false) == "1 Hour Remaining" && Format.words(66, charging: false) == "1 Hour 5 Min Remaining", "words: singular hour")
    check(Format.words(47, charging: false) == "45 Min Remaining" && Format.words(3, charging: false) == "Less Than 5 Min Remaining", "words: minutes, rounding to 5")
    check(Format.words(80, charging: true) == "1 Hour 20 Min Until Full" && Format.words(45, charging: true) == "45 Min Until Full", "words: charging")
    let parts = { (style: Settings.MenuBar, onAC: Bool, full: Bool, charging: Bool, m: Int?) in
        Monitor.menuParts(style, percent: 84, onAC: onAC, full: full, charging: charging, minutes: m) }
    check(parts(.words, false, false, false, 130) == ("84%", "2 Hours 10 Min Remaining"), "words: the default")
    check(parts(.compact, false, false, false, 130) == ("84%", "2:10") && parts(.compact, true, false, true, 45) == ("84%", "45m"), "compact: the time alone, charging too")
    check(parts(.words, false, false, false, nil) == ("84%", "Estimating…") && parts(.compact, false, false, false, nil) == ("84%", "…"), "estimating")
    check(parts(.words, true, true, false, nil) == ("84%", nil) && parts(.words, true, false, false, 30) == ("84%", nil), "full / on power, not charging: no time")
    check(parts(.percent, false, false, false, 130) == ("84%", nil) && parts(.icon, false, false, false, 130) == (nil, nil), "percent, icon")
    var steady = Steady()
    check(steady.update(133) == 135 && steady.update(129) == 135 && steady.update(129) == 130, "steady: a new value must come twice")
    check(steady.update(112) == 110, "steady: a ten-minute jump shows at once")
    check(steady.update(107) == 110 && steady.update(104) == 105, "steady: settles once the new value has come twice")

    // Energy modes: pmset's output parses, and only the exact request lines are ever written.
    let custom = "Battery Power:\n lowpowermode         0\n powermode            1\nAC Power:\n powermode            2\n"
    let power = PowerMode.parse(custom: custom, capabilities: " sleep\n lowpowermode\n highpowermode\n")
    check(power.battery == .low && power.adapter == .high && power.highPowerSupported, "pmset parse: \(power)")
    check(!PowerMode.parse(custom: "", capabilities: " lowpowermode\n").highPowerSupported && PowerMode.parse(custom: "", capabilities: "").battery == nil, "no high power, no modes")
    check(PowerMode.request(.low, onBattery: true) == "b 1" && PowerMode.request(.high, onBattery: false) == "c 2" && PowerMode.request(.automatic, onBattery: true) == "b 0", "helper requests")

    // Care: what a change saves, from the defaults and then from this Mac's own windows.
    let cold = Savings()
    let dim = cold.brightness(from: 0.85, to: 0.4, rate: 12)
    check(!dim.learned && dim.fraction > 0.2 && dim.fraction <= CareDefaults.estimateCap, "default dimming saving is a cautious quarter-to-third: \(dim.fraction)")
    check(near(cold.lowPower(rate: 12).fraction, CareDefaults.lowPowerSaving, 0.001) && !cold.lowPower(rate: 12).learned, "default Low Power saving")
    check(Saving(fraction: 0.2, learned: false).minutes(level: 50, ratePerHour: 10) == 75, "20 % less drain on 5 hours = 75 minutes")
    check(near(Savings.combined([Saving(fraction: 0.3, learned: true), Saving(fraction: 0.2, learned: false)]).fraction, 0.44, 0.001), "savings compound")
    check(near(Savings.combined([.estimated(0.3), .estimated(0.3), .estimated(0.3)]).fraction, CareDefaults.estimateCombinedCap, 0.001), "a pile of guesses is capped")
    check(Saving.estimated(0.9).fraction == CareDefaults.estimateCap && Savings.quitting(cpuPercent: 300, batteryWatts: 5).fraction == CareDefaults.estimateCap, "a single guess is capped")
    check(Tip.gainText(134, estimated: true) == "~+2 h 15 m" && Tip.gainText(134, estimated: false) == "+2 h 15 m" && Tip.gainText(9, estimated: true) == "~+10 min"
          && Tip.gainText(3, estimated: true) == nil && Tip.gainText(62, estimated: true) == "~+1 h" && Format.duration(120) == "2 h", "gain wording")
    var warm = Savings()
    for i in 0..<48 {   // a Mac whose drain is 5 + 12·b^1.6 − 3·lowPower, brightness sweeping 0.2…1.0
        let b = 0.2 + Double(i % 9) / 10, lp = i % 3 == 0
        warm.learn(rate: 5 + 12 * pow(b, 1.6) - (lp ? 3 : 0) + noise(0.3), brightness: b, lowPower: lp)
    }
    check(warm.trustsBrightness && warm.trustsLowPower, "learned after 48 windows: \(warm.weights ?? [])")
    let learnedDim = warm.brightness(from: 0.85, to: 0.4, rate: 5 + 12 * pow(0.85, 1.6))
    check(learnedDim.learned && near(learnedDim.fraction, 12 * (pow(0.85, 1.6) - pow(0.4, 1.6)) / (5 + 12 * pow(0.85, 1.6)), 0.15), "learned dimming saving: \(learnedDim.fraction)")
    check(warm.lowPower(rate: 12).learned && near(warm.lowPower(rate: 12).fraction, 3 / 12, 0.2), "learned Low Power saving: \(warm.lowPower(rate: 12).fraction)")
    var careFacts = CareFacts(onAC: false, percent: 25, level: 25, ratePerHour: 12, batteryWatts: 8, brightness: 0.85, keyboardOn: true, ambient: 300, lowPower: false,
                          topApp: ("Example Browser", 80, 0.5), usbDevices: [("Portable SSD", 900)])
    let found = Tips.detect(careFacts, savings: cold)
    check(found.count == 2 && found.allSatisfy { $0.gain >= 0 } && found[0].gain >= found[1].gain, "two tips, biggest saving first: \(found.map { $0.id })")
    check(Set(Tips.detect(careFacts, savings: cold).map { $0.id }).isSubset(of: ["brightness", "keyboard", "lowpower", "app", "usb"]), "tip ids")
    careFacts.onAC = true
    check(Tips.detect(careFacts, savings: cold).isEmpty, "no tips on the charger")
    careFacts.onAC = false; careFacts.brightness = 0.3; careFacts.keyboardOn = false; careFacts.percent = 60; careFacts.topApp = nil; careFacts.usbDevices = []
    check(Tips.detect(careFacts, savings: cold).isEmpty, "nothing to tip when nothing is wasteful")
    careFacts.usbDevices = [("Mouse", 100)]
    check(Tips.detect(careFacts, savings: cold).isEmpty, "a 100 mA device isn't worth a tip")
    var guardState = HeatGuard()
    check(!guardState.step(celsius: 34, charging: true) && !guardState.hot, "34 °C charging: fine")
    check(guardState.step(celsius: 35, charging: true) && guardState.hot, "35 °C charging: hot, one nudge")
    check(!guardState.step(celsius: 34, charging: true) && guardState.hot, "34 °C: still hot (hysteresis)")
    check(!guardState.step(celsius: 33, charging: true) && !guardState.hot, "33 °C: cleared")
    check(!guardState.step(celsius: 38, charging: false) && guardState.step(celsius: 40, charging: false), "on battery it takes 40 °C")
    var points: [History.Point] = []
    for m in 0..<120 { points.append(History.Point(t: at(Double(m)), l: m < 90 ? 100 : 60, w: nil, c: m < 90)) }
    check(near(HealthCoach.timeAtHighCharge(points, now: at(120)) ?? 0, 0.75, 0.01), "three quarters of the time at 95 %+")
    check(HealthCoach.timeAtHighCharge(Array(points.prefix(10)), now: at(10)) == nil, "the coach waits for data")
    let days = (0..<28).map { DayLog(day: at(Double($0) * 1440), cycles: 100 + $0 / 2, health: 100 - Double($0) * 0.05) }
    check(near(HealthCoach.cyclesPerWeek(days) ?? 0, 3.5, 0.15), "cycles per week: \(HealthCoach.cyclesPerWeek(days) ?? -1)")
    check(near(HealthCoach.healthTrendPerMonth(days) ?? 0, -1.5, 0.05), "health trend per month: \(HealthCoach.healthTrendPerMonth(days) ?? 0)")
    check(HealthCoach.healthTrendPerMonth(Array(days.prefix(10))) == nil && HealthCoach.cyclesPerWeek(Array(days.prefix(3))) == nil, "trends need weeks")
    let logged = HealthCoach.logged(HealthCoach.logged([], cycles: 1, health: 100, now: at(0)), cycles: 2, health: 100, now: at(10))
    check(logged.count == 1 && HealthCoach.logged(logged, cycles: 2, health: 100, now: at(1500)).count == 2, "one line a day")
    check(SmartLowPower.decide(enabled: true, onAC: false, percent: 30, minutesLeft: 120, mode: .automatic, applied: false, previous: nil, userChanged: false) == .engage, "smart: engages at 30 %")
    check(SmartLowPower.decide(enabled: true, onAC: false, percent: 50, minutesLeft: 50, mode: .automatic, applied: false, previous: nil, userChanged: false) == .engage, "smart: engages under an hour")
    check(SmartLowPower.decide(enabled: true, onAC: false, percent: 50, minutesLeft: 120, mode: .automatic, applied: false, previous: nil, userChanged: false) == .none, "smart: waits")
    check(SmartLowPower.decide(enabled: true, onAC: false, percent: 20, minutesLeft: 30, mode: .low, applied: false, previous: nil, userChanged: false) == .none, "smart: already low")
    check(SmartLowPower.decide(enabled: true, onAC: false, percent: 20, minutesLeft: 30, mode: .automatic, applied: false, previous: nil, userChanged: true) == .none, "smart: respects the user")
    check(SmartLowPower.decide(enabled: true, onAC: true, percent: 40, minutesLeft: nil, mode: .low, applied: true, previous: .high, userChanged: false) == .restore(.high), "smart: restores on the charger")
    check(SmartLowPower.decide(enabled: false, onAC: false, percent: 10, minutesLeft: 10, mode: .automatic, applied: false, previous: nil, userChanged: false) == .none, "smart: off")
    check(BrightnessCap.target(enabled: true, onAC: false, brightness: 0.8, cap: 0.5) == 0.5 && BrightnessCap.target(enabled: true, onAC: false, brightness: 0.3, cap: 0.5) == nil
          && BrightnessCap.target(enabled: true, onAC: true, brightness: 0.9, cap: 0.5) == nil && BrightnessCap.target(enabled: false, onAC: false, brightness: 0.9, cap: 0.5) == nil, "brightness cap only turns down, only on battery")
    check(USBPower.parse(["USB Product Name": "Portable SSD", "bMaxPower": 250]) == USBPower.Device(name: "Portable SSD", milliamps: 500), "USB bMaxPower is in 2 mA units")
    check(USBPower.parse(["USB Product Name": "Ambient Light Sensor", "idVendor": 0x05ac]) == nil && USBPower.parse(["USB Product Name": "Hub", "Built-In": true]) == nil, "Apple's built-ins are skipped")
    check(ChargeLimit.steps == [80, 85, 90, 95, 100] && ChargeLimit.recommended == 80, "charge limit steps")

    // Save Battery on a fake Mac: dims, kills the keyboard light, remembers; Undo and the charger put it all back.
    let careSuite = "io.github.cyborgfingers.juiceleft.selftest.care"
    let careDefaults = UserDefaults(suiteName: careSuite)!
    careDefaults.removePersistentDomain(forName: careSuite)
    careDefaults.set(#"{"replaceSystemIcon":false,"smartLowPower":false}"#.data(using: .utf8), forKey: Settings.key)
    let fake = FakeHardware()
    let mac = FakeMac()   // and a fake helper, limit and battery item: the real energy mode is never asked for
    mac.install()
    Notifier.deliver = { _, _, _ in }   // the heat nudge below posts nothing real
    final class Still: BatterySource { var onReading: ((Reading?) -> Void)?; let interval: TimeInterval = 30; func start() {}; func refresh() {} }
    let careURL = FileManager.default.temporaryDirectory.appendingPathComponent("juiceleft-selftest-care.json")
    let monitor = Monitor(source: Still(), defaults: careDefaults, historyURL: careURL, hardware: fake)
    monitor.interactive = false
    var careReading = Reading(at: at(0), percent: 60, onAC: false, charging: false, full: false)
    careReading.rawCurrent = 3537; careReading.rawMax = 5895; careReading.amps = -0.7; careReading.volts = 12; careReading.celsius = 30
    for m in 0...8 { careReading.at = at(Double(m) * 0.5); careReading.rawCurrent = 3537 - Double(m) * 6; monitor.ingest(careReading) }
    check(monitor.forecast?.kind == .flat && (monitor.saveBatteryGain?.minutes ?? 0) > 0, "Save Battery shows a gain before the click: \(String(describing: monitor.saveBatteryGain))")
    monitor.saveBattery()
    check(monitor.saving != nil && fake.level == 0.4 && fake.keys == .init(brightness: 0, auto: false), "Save Battery dimmed to 40 % and turned the keyboard light off: \(fake.log)")
    check(mac.powerRequests == ["b 1"], "Save Battery asked the (fake) helper for Low Power on battery: \(mac.powerRequests)")
    check(monitor.saveBatteryGain == nil, "no gain offered while saving")
    monitor.undoSaveBattery()
    check(monitor.saving == nil && fake.level == 0.85 && fake.keys == .init(brightness: 0.5, auto: true), "Undo put brightness and keyboard back: \(fake.log)")
    check(mac.powerRequests == ["b 1", "b 0"], "Undo put the energy mode back: \(mac.powerRequests)")
    monitor.saveBattery()
    careReading.at = at(5); careReading.onAC = true; careReading.charging = true
    monitor.ingest(careReading)
    check(monitor.saving == nil && fake.level == 0.85, "the charger undoes Save Battery by itself")
    fake.level = 0.9
    monitor.s.brightnessCap = true
    careReading.at = at(6); careReading.onAC = false; careReading.charging = false
    monitor.ingest(careReading)
    check(fake.level == 0.5, "brightness cap turns 90 % down to 50 % on battery")
    careReading.at = at(7); careReading.onAC = true
    monitor.ingest(careReading)
    check(fake.level == 0.9, "and puts it back on the charger")
    careReading.at = at(8); careReading.celsius = 36; careReading.charging = true
    monitor.ingest(careReading)
    check(monitor.heat.hot && monitor.heatNote?.contains("36 °C") == true, "heat guard nudges at 36 °C charging: \(monitor.heatNote ?? "")")
    careDefaults.removePersistentDomain(forName: careSuite)
    try? FileManager.default.removeItem(at: careURL)

    // The charging light's rules and request lines.
    var li = MagSafeLight.Inputs(onMagSafe: true, charging: true, percent: 50, secondsSincePlug: 3)
    check(MagSafeLight.desired(li) == .slowBlink, "light: slow blink right after plugging in")
    li.secondsSincePlug = 12
    check(MagSafeLight.desired(li) == .orange, "light: steady orange after ten seconds")
    li.behaviour = .blink
    check(MagSafeLight.desired(li) == .slowBlink, "light: blink throughout")
    li.behaviour = .apple
    check(MagSafeLight.desired(li) == nil, "light: Apple's default leaves it alone")
    li.percent = 8
    check(MagSafeLight.desired(li) == .fastBlink, "light: fast blink at or below the alert level, whatever the behaviour")
    li.fastWhenLow = false
    check(MagSafeLight.desired(li) == nil, "light: fast blink can be turned off")
    li = MagSafeLight.Inputs(onMagSafe: true, charging: false, percent: 80)
    check(MagSafeLight.desired(li) == .green, "light: green when held at the limit or full")
    li.greenAtLimit = false
    check(MagSafeLight.desired(li) == nil, "light: green can be turned off")
    li = MagSafeLight.Inputs(onMagSafe: true, charging: true, percent: 50, secondsSincePlug: 30, lidClosed: true)
    check(MagSafeLight.desired(li) == nil, "light: never driven with the lid closed")
    li.lidClosed = false; li.onMagSafe = false
    check(MagSafeLight.desired(li) == nil, "light: not through USB-C")
    li.onMagSafe = true; li.enabled = false
    check(MagSafeLight.desired(li) == nil, "light: switched off")
    check(MagSafeLight.request(.slowBlink, onAC: true, charging: true) == "6" && MagSafeLight.request(nil, onAC: true, charging: true) == "4 0"
          && MagSafeLight.request(nil, onAC: true, charging: false) == "3 0" && MagSafeLight.request(nil, onAC: false, charging: false) == "0", "light: request lines, hand-back writes the colour first")

    // Click decision: quick press or right/⌃-click = panel, held past the deadline = toggle monitoring.
    check(StatusItemController.gesture(.leftMouseDown, control: false) { true } == .panel, "quick press opens the panel")
    check(StatusItemController.gesture(.leftMouseDown, control: false) { false } == .toggle, "hold toggles")
    check(StatusItemController.gesture(.rightMouseDown, control: false) { true } == .panel, "right-click opens the panel")
    check(StatusItemController.gesture(.leftMouseDown, control: true) { false } == .panel, "control-click opens the panel")

    // OS hooks: the battery reads, the chime decodes, every glyph state draws.
    let reading = LiveBattery.read()
    check(reading != nil, "battery read")
    check(NSSound(data: Tone.chime) != nil, "chime decodes")
    for frame in [MenuIcon.Frame(level: 100, percent: "100%"), MenuIcon.Frame(level: 15, plugged: true, percent: "15%", trailing: "45 Min Until Full"),
                  MenuIcon.Frame(level: 50, armed: false, percent: "50%", trailing: "2 Hours 10 Min Remaining"),
                  MenuIcon.Frame(level: 8, percent: "8%", trailing: "12m", red: 0.6), MenuIcon.Frame(level: 0, missing: true), MenuIcon.Frame(level: 60)] {
        check(MenuIcon.draw(frame).tiffRepresentation != nil && MenuIcon.glyph(frame, side: 44).tiffRepresentation != nil, "item draws \(frame)")
    }
    check(MenuIcon.draw(MenuIcon.Frame(level: 60)).size.width == MenuIcon.glyphWidth, "icon-only item is just the glyph")
    check(MenuIcon.draw(MenuIcon.Frame(level: 60, percent: "60%")).size.width > MenuIcon.glyphWidth + 20, "percent makes room for the text")
    check(MenuIcon.draw(MenuIcon.Frame(level: 60, percent: "60%", trailing: "2 Hours 10 Min Remaining")).size.width > MenuIcon.glyphWidth + 120, "the words make room after the glyph")

    // Menu-bar power draw: an opt-in "· −12 W" after the trailing text; the icon-only style keeps the battery alone.
    check(Format.signedWatts(-12.4) == "−12 W" && Format.signedWatts(45.0) == "+45 W", "signed watts")
    check(parts(.words, false, false, false, 130) == ("84%", "2 Hours 10 Min Remaining"), "watts off: unchanged")
    check(Monitor.menuParts(.words, percent: 84, onAC: false, full: false, charging: false, minutes: 130, wattsText: "−12 W") == ("84%", "2 Hours 10 Min Remaining · −12 W"), "watts appended to the words")
    check(Monitor.menuParts(.percent, percent: 84, onAC: false, full: false, charging: false, minutes: nil, wattsText: "−12 W") == ("84%", "−12 W"), "watts stands alone with percent")
    check(Monitor.menuParts(.compact, percent: 84, onAC: true, full: false, charging: false, minutes: 45, wattsText: "+45 W") == ("84%", "+45 W"), "watts on power, not charging")
    check(Monitor.menuParts(.icon, percent: 84, onAC: false, full: false, charging: false, minutes: 130, wattsText: "−12 W") == (nil, nil), "icon stays alone, watts and all")

    // Charging insight: a weak charger is worth a quiet word; a 30 W-and-up adapter isn't.
    check(ChargerAdvice.slowLine(onAC: true, charging: true, watts: 20) == "Charging slowly — 20 W charger", "weak charger flagged")
    check(ChargerAdvice.slowLine(onAC: true, charging: true, watts: 30) == nil && ChargerAdvice.slowLine(onAC: true, charging: true, watts: 96) == nil, "a strong charger isn't")
    check(ChargerAdvice.slowLine(onAC: true, charging: false, watts: 20) == nil && ChargerAdvice.slowLine(onAC: false, charging: false, watts: 20) == nil && ChargerAdvice.slowLine(onAC: true, charging: true, watts: nil) == nil, "no charger, no word")

    // History summary: the level then and now, and the average drain over the on-battery time in the window.
    var hist: [History.Point] = []
    for m in 0..<180 { hist.append(History.Point(t: at(Double(m)), l: m < 60 ? 100 : 100 - Double(m - 60) / 120 * 16, w: nil, c: m < 60)) }
    let sum = History.summary(hist, since: at(0))
    check(sum?.from == 100 && sum?.to == 84 && near(sum?.drainPerHour ?? 0, 8, 0.05), "history summary: \(String(describing: sum))")
    check(History.summary([], since: at(0)) == nil && History.summary([History.Point(t: at(0), l: 50, w: nil, c: false)], since: at(0)) == nil, "summary needs two points")

    // The chart's time labels: start, middle and Now over a day; a weekday at each noon inside three days.
    let dayTicks = LevelChart.ticks(now: t0, hours: 24)
    check(dayTicks.count == 3 && dayTicks[0].fraction == 0 && dayTicks[1].fraction == 0.5 && dayTicks[2] == (1, "Now") && !dayTicks[0].text.isEmpty, "a day's ticks: \(dayTicks)")
    let dayNames = LevelChart.ticks(now: t0, hours: 72)
    check((2...3).contains(dayNames.count) && dayNames.allSatisfy { $0.fraction > 0 && $0.fraction < 1 && !$0.text.isEmpty }
          && zip(dayNames, dayNames.dropFirst()).allSatisfy { $0.fraction < $1.fraction }, "three days' ticks: \(dayNames)")

    // Accessory batteries: a Bluetooth mouse parses; a wired or level-less entry doesn't; the name gives the kind.
    check(AccessoryBattery.parse(["BatteryPercent": 55, "Product": "Wireless Mouse", "Transport": "Bluetooth", "DeviceAddress": "aa:bb"]) == AccessoryBattery.Device(id: "aa:bb", name: "Wireless Mouse", percent: 55, kind: .mouse), "mouse parses")
    check(AccessoryBattery.parse(["BatteryPercent": 80, "Product": "Wireless Keyboard", "Transport": "USB"]) == nil, "wired accessory skipped")
    check(AccessoryBattery.parse(["Product": "Wireless Trackpad", "Transport": "Bluetooth"]) == nil && AccessoryBattery.parse(["BatteryPercent": 0, "Product": "Wireless Mouse"]) == nil, "no level, no device")
    check(AccessoryBattery.kind(for: "Office Trackpad") == .trackpad && AccessoryBattery.kind(for: "Office Keyboard") == .keyboard && AccessoryBattery.kind(for: "Desk Display") == .other, "kinds")

    // The low-accessory latch fires once, clears with hysteresis, and forgets a device that goes away.
    let mouse = { (p: Int) in AccessoryBattery.Device(id: "m", name: "Wireless Mouse", percent: p, kind: .mouse) }
    var da = DeviceAlerts()
    check(da.due([mouse(20)], level: 15).isEmpty, "20% at a 15% level: quiet")
    check(da.due([mouse(15)], level: 15).map(\.id) == ["m"] && da.due([mouse(14)], level: 15).isEmpty, "15%: one warning, no repeat")
    check(da.due([mouse(20)], level: 15).isEmpty && da.due([mouse(15)], level: 15).map(\.id) == ["m"], "recovered past hysteresis, then low again: warns again")
    _ = da.due([], level: 15)
    check(da.alerted.isEmpty, "a device that goes away is forgotten")

    // The URL scheme: only the whitelisted actions, only with a valid single parameter; everything else is nil.
    check(URLAction.parse(URL(string: "juiceleft://savebattery?on=1")!) == .saveBattery(true) && URLAction.parse(URL(string: "juiceleft://savebattery?on=off")!) == .saveBattery(false), "savebattery on/off")
    check(URLAction.parse(URL(string: "juiceleft://mode?set=low")!) == .setMode(.low) && URLAction.parse(URL(string: "juiceleft://mode?set=auto")!) == .setMode(.automatic) && URLAction.parse(URL(string: "juiceleft://mode?set=high")!) == .setMode(.high), "mode set")
    check(URLAction.parse(URL(string: "juiceleft://topup")!) == .topUp && URLAction.parse(URL(string: "juiceleft://snooze")!) == .snooze && URLAction.parse(URL(string: "juiceleft://monitoring?on=0")!) == .setArmed(false), "topup, snooze, monitoring")
    check(URLAction.parse(URL(string: "juiceleft://savebattery?on=maybe")!) == nil && URLAction.parse(URL(string: "juiceleft://mode?set=turbo")!) == nil, "bad values rejected")
    check(URLAction.parse(URL(string: "juiceleft://savebattery?on=1&and=delete")!) == nil && URLAction.parse(URL(string: "juiceleft://topup?x=1")!) == nil, "extra parameters rejected")
    check(URLAction.parse(URL(string: "juiceleft://wipe?all=1")!) == nil && URLAction.parse(URL(string: "https://evil.example/mode?set=low")!) == nil && URLAction.parse(URL(string: "juiceleft://?on=1")!) == nil, "unknown host, wrong scheme, no host")

    // The global shortcut: the label in the menu bar's order, Carbon's flags, and only combinations that can't steal plain typing.
    check(HotKey.Spec.label(modifiers: [.command, .shift, .option, .control], key: "J") == "⌃⌥⇧⌘J" && HotKey.Spec.label(modifiers: [], key: "F5") == "F5", "shortcut label")
    check(HotKey.Spec.valid(keyCode: 38, modifiers: [.control, .option]) && HotKey.Spec.valid(keyCode: 96, modifiers: []), "⌃⌥J and F5 are shortcuts")
    check(!HotKey.Spec.valid(keyCode: 38, modifiers: .shift) && !HotKey.Spec.valid(keyCode: 38, modifiers: []), "⇧J and J alone are typing, not shortcuts")
    let ctrlOpt = NSEvent.ModifierFlags([.control, .option]).rawValue
    check(HotKey.Spec(keyCode: 38, key: "J", modifiers: ctrlOpt).carbonModifiers == 0x1000 | 0x0800, "carbon flags: controlKey | optionKey")
    check(Settings.load(UserDefaults(suiteName: "io.github.cyborgfingers.juiceleft.selftest.none")!).hotKey == nil, "no shortcut by default")

    // The full notice: full — or held at the charge limit; never while charging through it (a top-up), never on battery.
    check(Monitor.fullNotice(full: true, onAC: true, charging: false, percent: 100, limit: nil) == "Fully charged", "full, no limit")
    check(Monitor.fullNotice(full: false, onAC: true, charging: false, percent: 80, limit: 80) == "Held at 80%", "held at the limit")
    check(Monitor.fullNotice(full: true, onAC: true, charging: false, percent: 80, limit: 80) == "Held at 80%", "macOS calls a held battery charged: still 'held'")
    check(Monitor.fullNotice(full: false, onAC: true, charging: true, percent: 85, limit: 80) == nil && Monitor.fullNotice(full: false, onAC: true, charging: false, percent: 60, limit: 80) == nil, "charging through the limit, or under it: nothing")
    check(Monitor.fullNotice(full: false, onAC: false, charging: false, percent: 80, limit: 80) == nil && Monitor.fullNotice(full: false, onAC: true, charging: false, percent: 90, limit: 100) == nil, "on battery, or no limit: nothing")

    // A 1.2.1 settings blob decodes unchanged; the new fields take their defaults; a newer blob keeps (and clamps) its values.
    let suite13 = "io.github.cyborgfingers.juiceleft.selftest13"
    let d13 = UserDefaults(suiteName: suite13)!
    let blob121 = #"{"armed":false,"warnAt":25,"alertAt":7,"tone":"Glass","volume":0.5,"repeatMinutes":2,"notify":false,"unplugReminder":true,"fullNotice":true,"plugNotices":true,"menuBar":"compact","replaceSystemIcon":false,"insight":false,"smartLowPower":false,"brightnessCap":true,"brightnessCapLevel":0.6,"heatGuard":false,"light":false,"lightBehaviour":"blink","lightGreenAtLimit":false,"lightFastWhenLow":false}"#
    var want121 = Settings()
    want121.armed = false; want121.warnAt = 25; want121.alertAt = 7; want121.tone = "Glass"; want121.volume = 0.5; want121.repeatMinutes = 2; want121.notify = false
    want121.unplugReminder = true; want121.fullNotice = true; want121.plugNotices = true; want121.menuBar = .compact; want121.replaceSystemIcon = false; want121.insight = false
    want121.smartLowPower = false; want121.brightnessCap = true; want121.brightnessCapLevel = 0.6; want121.heatGuard = false; want121.light = false
    want121.lightBehaviour = .blink; want121.lightGreenAtLimit = false; want121.lightFastWhenLow = false
    d13.set(blob121.data(using: .utf8), forKey: Settings.key)
    let old = Settings.load(d13)
    check(old == want121, "a 1.2.1 blob decodes unchanged, new fields at their defaults: \(old)")
    check(!old.menuBarWatts && !old.deviceAlert && old.deviceAlertAt == 15 && old.hotKey == nil, "new fields default on an older blob: \(old)")
    d13.set(#"{"menuBarWatts":true,"deviceAlert":true,"deviceAlertAt":999,"hotKey":{"keyCode":38,"key":"J","modifiers":\#(ctrlOpt)}}"#.data(using: .utf8), forKey: Settings.key)
    let new = Settings.load(d13)
    check(new.menuBarWatts && new.deviceAlert && new.deviceAlertAt == 50 && new.hotKey == HotKey.Spec(keyCode: 38, key: "J", modifiers: ctrlOpt), "new fields kept and clamped: \(new)")
    d13.set(#"{"warnAt":25,"hotKey":"nope"}"#.data(using: .utf8), forKey: Settings.key)
    let odd = Settings.load(d13)
    check(odd.warnAt == 25 && odd.hotKey == nil, "a malformed shortcut is dropped without costing the other settings: \(odd)")
    d13.set(#"{"hotKey":{"keyCode":38,"key":"J","modifiers":\#(NSEvent.ModifierFlags.shift.rawValue)}}"#.data(using: .utf8), forKey: Settings.key)
    check(Settings.load(d13).hotKey == nil, "a shortcut that would steal typing is dropped")
    d13.removePersistentDomain(forName: suite13)

    // The notch rule: squeeze the moment a neighbour sits in the camera gap; the words come back only when they would still clear it.
    let notch = CGRect(x: 663, y: 0, width: 185, height: 37), me = CGRect(x: 1300, y: 0, width: 200, height: 37)
    let item = { (x: CGFloat) in CGRect(x: x, y: 0, width: 36, height: 37) }
    let decide = { (squeezed: Bool, items: [CGRect]) in StatusItemController.notchDecision(squeezed: squeezed, items: items, notch: notch, wordsWidth: 200, compactWidth: 80) }
    check(decide(false, [me, item(766)]) == true, "a neighbour under the notch: squeeze")
    check(decide(false, [me, item(900)]) == nil && decide(false, [me]) == nil, "everyone clear: the words stay")
    check(decide(true, [me, item(900)]) == nil, "900 − 120 < 848 + 8: stay compact")
    check(decide(true, [me, item(980)]) == false, "980 − 120 ≥ 856: the words fit again")
    check(decide(false, [me, item(860)]) == nil, "and after that expansion nothing is under the notch: no flap")
    check(decide(true, [me, item(766)]) == nil && decide(true, []) == false, "still hidden: stay compact; an empty bar: expand")

    // Which windows are menu-bar items: the live layout of a 1512 × 982 screen with a 33 pt bar (CG bounds, top-left origin).
    let frame = { (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, n: Int) in
        StatusItemController.itemFrame(bounds: CGRect(x: x, y: y, width: w, height: h), layer: 25, number: n, own: 7,
                                       screen: CGRect(x: 0, y: 0, width: 1512, height: 982), barHeight: 33) }
    check(frame(755, 27, 370, 548, 1) == nil && frame(1133, 28, 370, 836, 2) == nil, "hidden panels at the status level start lower and stand taller: not items")
    check(frame(0, 982, 0, 0, 3) == nil, "a zero-size window is nothing")
    check(frame(766, 0, 36, 33, 4) == CGRect(x: 766, y: 949, width: 36, height: 33) && frame(902, 0, 34, 33, 5) != nil, "item windows at the top, bar-high: counted")
    check(frame(1322, 0, 42, 33, 7) == nil && frame(1322, 0, 42, 33, 8) != nil, "our own item, by window number, is left out")
    let parkedX: [CGFloat] = [-9502, -9470, -9432, -9386, -9346, -9308, -9261, -9223, -4207, -4175, -4137, -4099]   // hidden on purpose, always there
    let parked = parkedX.enumerated().map { frame($1, 0, $0 < 8 ? 5016 : 5001, 33, 100 + $0) }
    check(parked.allSatisfy { $0 == nil }, "items parked far off screen say nothing about room: not counted")
    let layout = ([frame(755, 27, 370, 548, 1), frame(1133, 28, 370, 836, 2), frame(0, 982, 0, 0, 3), frame(902, 0, 34, 33, 5), frame(936, 0, 34, 33, 6)] + parked).compactMap { $0 }
    check(layout.count == 2 && StatusItemController.notchDecision(squeezed: false, items: layout, notch: notch, wordsWidth: 200, compactWidth: 80) == nil,
          "that layout, twelve parked items and all, nothing in the gap: the words stay")
    check(StatusItemController.notchDecision(squeezed: false, items: layout + [frame(766, 0, 36, 33, 4)!], notch: notch, wordsWidth: 200, compactWidth: 80) == true, "an item window at 766: squeeze")

    // The keyboard backlight: a level captured while macOS had it suppressed (0, auto on) never writes that 0 back.
    check(KeyboardLight.writes(KeyboardLight.Level(brightness: 0, auto: true)) == (nil, true), "suppressed: only auto comes back")
    check(KeyboardLight.writes(KeyboardLight.Level(brightness: 0.5, auto: true)) == (0.5, true) && KeyboardLight.writes(KeyboardLight.Level(brightness: 0, auto: false)) == (0, false), "a real level, or off, is written as is")
    let keys = FakeHardware()
    keys.keys = KeyboardLight.Level(brightness: 0.3, auto: false)
    keys.setKeyboard(KeyboardLight.Level(brightness: 0, auto: true))
    check(keys.keys == KeyboardLight.Level(brightness: 0.3, auto: true), "on the fake hardware the restore leaves the brightness alone: \(keys.keys)")

    Updater.selfTest()   // versions, the release feed, signatures, the swap script on a fake bundle

    let r = reading!
    print("MagSafe port: \(MagSafePort.exists ? "present" : "none"), power through it now: \(MagSafePort.active), lid closed: \(Lid.read())")
    print("Accessories with a battery: \(AccessoryBattery.read().map { "\($0.name) \($0.percent)%" }.joined(separator: ", ").ifEmpty("none"))")
    print("PASS: alert rules, forecast + learning (priors \(String(format: "%.1f", morning.rate))/\(String(format: "%.1f", evening.rate)) → \(String(format: "%.1f", evening2.rate)) %/h, miss \(String(format: "%.0f", (learner.relativeError ?? 0) * 100))%), settings, apps, gesture, glyphs, updater; battery \(r.percent)% \(r.onAC ? "on power" : "on battery"), health \(r.health.map { String(format: "%.0f%%", $0) } ?? "?"), \(r.cycles ?? 0) cycles; Apple Intelligence \(AppleIntelligence.status)")
    exit(0)
}
