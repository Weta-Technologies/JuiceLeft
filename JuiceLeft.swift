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
        let monitor = Monitor(source: source, defaults: defaults, historyURL: historyURL, hardware: simulate ? FakeHardware() : RealHardware())
        if simulate {
            monitor.interactive = false
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
    defaults.set(#"{"warnAt":25,"alertAt":30,"bogus":1,"menuBar":"time"}"#.data(using: .utf8), forKey: Settings.key)
    let loaded = Settings.load(defaults)
    defaults.removePersistentDomain(forName: suite)
    check(loaded.warnAt == 25 && loaded.alertAt == 25 && loaded.tone == Tone.chimeName && loaded.menuBar == .words && loaded.replaceSystemIcon, "settings merge + clamp: \(loaded)")

    // Apps: helpers fold into the app; only real user apps get a Quit button.
    let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"
    check(EnergyMeter.app(for: chrome).name == "Google Chrome" && EnergyMeter.app(for: chrome).bundle == "/Applications/Google Chrome.app", "helper → app")
    check(EnergyMeter.app(for: "/usr/bin/python3").name == "python3" && EnergyMeter.app(for: "/usr/bin/python3").bundle == nil, "bare executable")
    let before: EnergyMeter.Snapshot = [1: (1.0, chrome), 2: (5.0, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), 3: (0.0, "/usr/bin/python3"), 4: (2.0, "/bin/zsh")]
    let after: EnergyMeter.Snapshot = [1: (3.0, chrome), 2: (6.0, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), 3: (0.5, "/usr/bin/python3"), 5: (9.0, "/bin/zsh")]
    let userApps: Set<String> = ["/Applications/Google Chrome.app"]
    let ranked = EnergyMeter.rank(before: before, after: after, seconds: 3, apps: userApps)
    check(ranked.apps.map(\.name) == ["Google Chrome"] && near(ranked.apps[0].cpuPercent, 100, 0.01) && near(ranked.apps[0].share, 3 / 3.5, 0.01), "ranking: apps only, share of the total: \(ranked)")
    check(ranked.background.map(\.name) == ["python3"] && near(ranked.backgroundShare, 0.5 / 3.5, 0.01), "ranking: the rest rolls up: \(ranked)")
    let idle: EnergyMeter.Snapshot = [2: (5.02, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), 3: (9.0, "/usr/bin/python3")]
    let quiet = EnergyMeter.rank(before: before, after: idle, seconds: 3, apps: userApps)
    check(quiet.apps.isEmpty && near(quiet.backgroundShare, 1, 0.01), "ranking: an app below 1% of a core is not listed")
    check(!EnergyMeter.rank(before: before, after: idle, seconds: 3, apps: userApps, pinned: ["/Applications/Google Chrome.app"]).apps.isEmpty, "ranking: a quitting app stays pinned")
    check(EnergyMeter.rank(before: before, after: before, seconds: 3, apps: userApps) == Ranking(), "ranking: nothing used, nothing listed")
    check(EnergyMeter.isUserApp(bundle: "/Applications/SleepLess.app", bundleID: "io.github.cyborgfingers.sleepless", policy: .accessory), "a menu-bar app counts as the user's")
    check(!EnergyMeter.isUserApp(bundle: "/System/Library/CoreServices/Spotlight.app", bundleID: "com.apple.Spotlight", policy: .accessory), "Spotlight is background")
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

    // The menu bar's words and text parts, per display style.
    check(Format.words(130, charging: false) == "2 Hours 10 Min Remaining" && Format.words(120, charging: false) == "2 Hours Remaining", "words: hours")
    check(Format.words(60, charging: false) == "1 Hour Remaining" && Format.words(66, charging: false) == "1 Hour 5 Min Remaining", "words: singular hour")
    check(Format.words(47, charging: false) == "45 Min Remaining" && Format.words(3, charging: false) == "Less Than 5 Min Remaining", "words: minutes, rounding to 5")
    check(Format.words(80, charging: true) == "1 Hour 20 Min Until Full" && Format.words(45, charging: true) == "45 Min Until Full", "words: charging")
    let parts = { (style: Settings.MenuBar, onAC: Bool, full: Bool, charging: Bool, m: Int?) in
        Monitor.menuParts(style, percent: 84, onAC: onAC, full: full, charging: charging, minutes: m) }
    check(parts(.words, false, false, false, 130) == ("84%", "2 Hours 10 Min Remaining"), "words: the default")
    check(parts(.compact, false, false, false, 130) == ("84%", "2:10") && parts(.compact, true, false, true, 45) == ("84%", "Full 45m"), "compact")
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
                          topApp: ("Chrome", 80, 0.5), usbDevices: [("Portable SSD", 900)])
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
    check(monitor.saveBatteryGain == nil, "no gain offered while saving")
    monitor.undoSaveBattery()
    check(monitor.saving == nil && fake.level == 0.85 && fake.keys == .init(brightness: 0.5, auto: true), "Undo put brightness and keyboard back: \(fake.log)")
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

    let r = reading!
    print("MagSafe port: \(MagSafePort.exists ? "present" : "none"), power through it now: \(MagSafePort.active), lid closed: \(Lid.read())")
    print("PASS: alert rules, forecast + learning (priors \(String(format: "%.1f", morning.rate))/\(String(format: "%.1f", evening.rate)) → \(String(format: "%.1f", evening2.rate)) %/h, miss \(String(format: "%.0f", (learner.relativeError ?? 0) * 100))%), settings, apps, gesture, glyphs; battery \(r.percent)% \(r.onAC ? "on power" : "on battery"), health \(r.health.map { String(format: "%.0f%%", $0) } ?? "?"), \(r.cycles ?? 0) cycles; Apple Intelligence \(AppleIntelligence.available ? "available" : "not available")")
    exit(0)
}
