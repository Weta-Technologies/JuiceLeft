import AppKit

/// Everything the panel edits, persisted as one blob. Loading merges the stored JSON over the defaults, so a field
/// added in a later version keeps everyone's other settings.
struct Settings: Codable, Equatable {
    enum MenuBar: String, Codable, CaseIterable { case icon, percent, compact, words }   // 1.0's "time" no longer decodes: those installs get the new default
    var armed = true
    var warnAt = 20              // %: the menu-bar item flashes red
    var alertAt = 10             // %: the tone
    var tone = Tone.chimeName
    var volume = 1.0
    var repeatMinutes = 5        // 0 = once
    var notify = true            // macOS notifications at the warning and alert levels
    var unplugReminder = false   // charging care: a nudge at 80 %
    var fullNotice = false
    var plugNotices = false      // charger connected / disconnected
    var menuBar = MenuBar.words     // "84% [battery] 2 Hours 10 Min Remaining"
    var replaceSystemIcon = true // hide Apple's battery item while JuiceLeft runs
    var insight = true           // the plain-English line (Apple Intelligence phrases it when available)

    static let key = "settings"

    static func load(_ defaults: UserDefaults) -> Settings {
        guard let stored = defaults.data(forKey: key),
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any],
              var saved = try? JSONSerialization.jsonObject(with: stored) as? [String: Any] else { return Settings() }
        // A choice this version no longer offers falls back to the default, without costing the other settings.
        if let style = saved["menuBar"] as? String, !MenuBar.allCases.contains(where: { $0.rawValue == style }) { saved["menuBar"] = nil }
        guard let merged = try? JSONSerialization.data(withJSONObject: base.merging(saved) { $1 }),
              let settings = try? JSONDecoder().decode(Settings.self, from: merged)
        else { return Settings() }
        return settings.normalized
    }

    /// The tone level can never be above the flash level.
    var normalized: Settings {
        var s = self
        s.warnAt = max(5, min(50, s.warnAt))
        s.alertAt = max(1, min(s.warnAt, s.alertAt))
        s.volume = max(0, min(1, s.volume))
        return s
    }
}

/// What JuiceLeft remembers between launches: the learner, and a per-minute curve of the last three days for the
/// chart. ~/Library/Application Support/JuiceLeft/history.json, a few hundred KB at most, written every five minutes.
struct History: Codable, Equatable {
    struct Point: Codable, Equatable {
        var t: Date
        var l: Double      // level, %
        var w: Double?     // battery watts: − draining, + charging
        var c: Bool        // on the charger
    }
    var points: [Point] = []
    var learner = Learner()

    static let keep: TimeInterval = 3 * 24 * 3600
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("JuiceLeft/history.json")

    static func load(from url: URL) -> History {
        (try? JSONDecoder().decode(History.self, from: Data(contentsOf: url))) ?? History()
    }

    func save(to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("JuiceLeft: couldn't save history: \(error.localizedDescription)")
        }
    }
}

/// The one place readings turn into a forecast, an alert phase, a menu-bar item and notifications.
@MainActor final class Monitor: ObservableObject {
    @Published var s: Settings {
        didSet {
            let n = s.normalized
            if n != s { s = n; return }
            guard s != oldValue else { return }
            defaults.set(try? JSONEncoder().encode(s), forKey: Settings.key)
            if !s.armed { tone.stop() }
            if s.replaceSystemIcon != oldValue.replaceSystemIcon {
                if s.replaceSystemIcon {
                    let moved = SystemBattery.takePosition(remembering: defaults)
                    SystemBattery.hide(remembering: defaults)
                    if moved { onReposition?() }
                } else {
                    SystemBattery.restore(from: defaults, forget: true)
                }
            }
            evaluate()
        }
    }
    @Published private(set) var reading: Reading?
    @Published private(set) var forecast: Forecast?
    @Published private(set) var phase = Alerts.Phase.clear
    @Published private(set) var history: History
    @Published private(set) var snoozedUntil: Date?
    @Published private(set) var notificationsAllowed: Bool?   // nil = not decided / not available
    @Published var note: String?                                // an error worth a line in the panel
    @Published private(set) var power = PowerMode.State()      // energy modes per source
    @Published private(set) var powerBusy = false               // a change is on its way through the helper
    @Published private(set) var welcome = false                 // first run: say what happened to Apple's icon
    let icon = MenuIcon()
    let tone = Tone()
    let energy = EnergyMeter()
    let insight = Insight()
    var log: ((String) -> Void)?                                // --simulate prints what happens
    var onReposition: (() -> Void)?                             // the status item re-reads its saved place

    static let snooze: TimeInterval = 30 * 60
    static let unplugAt = 80

    private let source: BatterySource
    let defaults: UserDefaults
    private let historyURL: URL
    private var samples: [Sample] = []                          // this discharge (or charge) so far
    private var alerts = Alerts.State()
    private var remindedUnplug = false, noticedFull = false
    private var savedAt = Date.distantPast
    private var powerTimer: Timer?
    private var steady = Steady()                               // the menu bar's spelled-out minutes
    private(set) var squeezed = false                           // macOS had no room for the item: fall back to the compact form

    init(source: BatterySource, defaults: UserDefaults = .standard, historyURL: URL = History.url) {
        self.source = source
        self.defaults = defaults
        self.historyURL = historyURL
        s = Settings.load(defaults)
        history = History.load(from: historyURL)
        // Asked-for default: start at login — but only for an installed copy, never a build tree or a test run.
        if !defaults.bool(forKey: "loginItemOffered"), Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
            defaults.set(true, forKey: "loginItemOffered")
            note = LoginItem.set(true)
        }
        // A straight swap: Apple's battery item goes while JuiceLeft runs and comes back when it quits, and JuiceLeft's
        // item takes its place in the bar (this runs before the status item is made, which is when the place is read).
        if s.replaceSystemIcon {
            SystemBattery.takePosition(remembering: defaults)   // before the hide: Control Center drops the position of a hidden item
            SystemBattery.hide(remembering: defaults)
            if !defaults.bool(forKey: "welcomed") { defaults.set(true, forKey: "welcomed"); welcome = true }
        }
        source.onReading = { [weak self] reading in MainActor.assumeIsolated { self?.ingest(reading) } }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persist(force: true)
                if let self, self.s.replaceSystemIcon { SystemBattery.restore(from: self.defaults) }
            }
        }
    }

    func start() {
        Notifier.setUp { [weak self] allowed in
            MainActor.assumeIsolated {
                self?.notificationsAllowed = allowed
                self?.log?("notifications \(allowed.map { $0 ? "allowed" : "denied" } ?? "not decided")")
            }
        }
        source.start()
    }

    // MARK: User actions

    /// The menu-bar tap (and the panel's main switch).
    func toggleArmed() { s.armed.toggle() }

    func snooze() {
        alerts.snoozedUntil = (reading?.at ?? Date()).addingTimeInterval(Self.snooze)
        tone.stop()
        evaluate()
    }

    func resume() {
        alerts.snoozedUntil = nil
        evaluate()
    }

    func testTone() { tone.play(s.tone, volume: s.volume) }

    func dismissWelcome() { welcome = false }

    // MARK: Energy modes

    /// The status item found (or lost) room in the menu bar.
    func setSqueezed(_ squeezed: Bool) {
        guard squeezed != self.squeezed else { return }
        self.squeezed = squeezed
        evaluate()
    }

    /// The mode for the power source in use right now.
    var activeMode: PowerMode.Mode? { reading?.onAC == true ? power.adapter : power.battery }

    private(set) var panelIsOpen = false

    /// The hover card's two lines: the time in words, then the clock time, the percent and the state; red when low.
    var hoverLines: (title: String, detail: String, warning: Bool) {
        guard let r = reading else { return ("No battery", "JuiceLeft needs a Mac with a battery", false) }
        let title: String
        if r.onAC {
            title = r.full ? "Fully Charged" : r.charging ? steady.shown.map { Format.words($0, charging: true) } ?? "Estimating…" : "On Power, Not Charging"
        } else {
            title = steady.shown.map { Format.words($0, charging: false) } ?? "Estimating…"
        }
        var parts: [String] = []
        if let f = forecast { parts.append(f.kind == .flat ? "Flat around \(Format.clock(f.at))" : "Full around \(Format.clock(f.at))") }
        parts.append("\(r.percent)%")
        if r.onAC, let w = r.adapterWatts { parts.append("\(w) W charger") }
        switch phase {
        case .alert: parts.append("At or below \(s.alertAt)%: sounding")
        case .warning: parts.append("At or below \(s.warnAt)%: flashing")
        case .clear: parts.append(s.armed ? "Alerts on" : "Alerts off")
        }
        return (title, parts.joined(separator: " · "), phase != .clear)
    }

    /// While the panel is open the modes are re-read once a minute, so a change made in System Settings shows here.
    func panelOpened() {
        panelIsOpen = true
        refreshPower()
        energy.start()
        let timer = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { self.refreshPower() } }
        RunLoop.main.add(timer, forMode: .common)
        powerTimer = timer
    }

    func panelClosed() {
        panelIsOpen = false
        energy.stop()
        powerTimer?.invalidate()
        powerTimer = nil
    }

    func refreshPower() {
        DispatchQueue.global(qos: .userInitiated).async {
            let state = PowerMode.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { if state != self.power { self.power = state } } }
        }
    }

    /// Sets the mode for the source in use, installing the root helper (one admin prompt) the first time.
    func setPowerMode(_ mode: PowerMode.Mode) {
        guard mode != activeMode, let r = reading else { return }
        note = nil
        if !PowerMode.helperReady, let why = PowerMode.installHelper() { note = "Energy modes need the helper: \(why)"; return }
        if let why = PowerMode.set(mode, onBattery: !r.onAC) { note = why; return }
        powerBusy = true
        log?("power mode → \(PowerMode.request(mode, onBattery: !r.onAC))")
        for delay in [0.7, 2.0, 4.5] {   // the helper runs on the file write; confirm from pmset itself
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    self.refreshPower()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        MainActor.assumeIsolated { if self.activeMode == mode || delay == 4.5 { self.powerBusy = false } }
                    }
                }
            }
        }
    }

    func setLoginItem(_ on: Bool) {
        note = LoginItem.set(on)
        objectWillChange.send()
    }

    // MARK: Readings

    func ingest(_ r: Reading?) {
        guard let r else {
            reading = nil
            forecast = nil
            icon.show(MenuIcon.Frame(level: 0, plugged: false, armed: s.armed, missing: true), phase: .clear)
            return
        }
        let previous = reading
        reading = r
        let slept = previous.map { r.at.timeIntervalSince($0.at) > 3 * source.interval } ?? false   // a hole in the readings: the Mac slept
        if let previous, r.onAC != previous.onAC || slept {
            if !previous.onAC, !slept { history.learner.endDischarge(now: r.at, level: previous.level) } else { history.learner.abandon() }
            samples = []
            steady.reset()
            remindedUnplug = false
            noticedFull = false
            if !slept, r.onAC != previous.onAC { plugChanged(r) }
        }
        samples.append(Sample(at: r.at, level: r.level, ratePerHour: r.ratePerHour))
        samples.removeAll { r.at.timeIntervalSince($0.at) > 2 * Learner.window }
        if history.points.last.map({ r.at.timeIntervalSince($0.t) >= 60 }) ?? true {
            history.points.append(History.Point(t: r.at, l: r.level, w: r.batteryWatts, c: r.onAC))
            history.points.removeAll { r.at.timeIntervalSince($0.t) > History.keep }
        }
        evaluate()
        persist(force: previous.map { $0.onAC != r.onAC } ?? false)
        log?("\(r.percent)% \(r.onAC ? "on power" : "on battery") → \(forecast.map { "\($0.kind) in \(Format.duration($0.minutes))" } ?? "no forecast")")
    }

    /// The forecast and the alert rules, from the latest reading (also re-run after a settings change).
    private func evaluate() {
        guard let r = reading else { return }
        if r.onAC {
            forecast = r.charging && !r.full ? Learner.chargeForecast(samples, level: r.level, now: r.at, osMinutes: r.osMinutesLeft) : nil
        } else {
            forecast = history.learner.step(samples, now: r.at)
        }

        let out = Alerts.step(alerts, armed: s.armed, onAC: r.onAC, percent: r.percent, warnAt: s.warnAt, alertAt: s.alertAt,
                              repeatMinutes: s.repeatMinutes, now: r.at)
        alerts = out.state
        if out.phase != phase { phase = out.phase; log?("phase \(out.phase)") }
        if alerts.snoozedUntil != snoozedUntil { snoozedUntil = alerts.snoozedUntil }
        if out.playTone { tone.play(s.tone, volume: s.volume); log?("tone \(s.tone) at \(r.percent)%") }
        if r.onAC { tone.stop() }
        if s.notify {
            if out.enteredWarning, !out.enteredAlert { notify(id: "warning", title: "Battery at \(r.percent)%", body: forecastLine) }
            if out.enteredAlert { notify(id: "alert", title: "Battery low: \(r.percent)%", body: "Plug in soon. " + forecastLine) }
        }
        if s.unplugReminder, r.onAC, r.charging, r.percent >= Self.unplugAt, !remindedUnplug {
            remindedUnplug = true
            notify(id: "unplug", title: "Battery at \(r.percent)%", body: "Unplugging now is kinder to the battery than sitting at 100%.")
        }
        if s.fullNotice, r.full, !noticedFull {
            noticedFull = true
            notify(id: "full", title: "Fully charged", body: "You can unplug.")
        }
        let minutes = forecast.map { steady.update($0.minutes) }
        let parts = Self.menuParts(squeezed && s.menuBar == .words ? .compact : s.menuBar, percent: r.percent, onAC: r.onAC, full: r.full,
                                   charging: r.charging, minutes: minutes)
        icon.show(MenuIcon.Frame(level: r.percent, plugged: r.onAC, armed: s.armed, percent: parts.percent, trailing: parts.trailing), phase: phase)
        insight.update(facts, ai: s.insight)
    }

    private func notify(id: String, title: String, body: String) {
        log?("notification “\(title)” \(body)")
        Notifier.post(id: id, title: title, body: body)
    }

    private func plugChanged(_ r: Reading) {
        log?(r.onAC ? "charger connected" : "unplugged")
        if powerTimer != nil { refreshPower() }
        guard s.plugNotices else { return }
        if r.onAC {
            notify(id: "plug", title: "Charger connected", body: [r.adapterName, r.adapterWatts.map { "\($0) W" }].compactMap { $0 }.joined(separator: " · "))
        } else {
            notify(id: "plug", title: "On battery: \(r.percent)%", body: forecastLine)
        }
    }

    private func persist(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(savedAt) >= 5 * 60 else { return }
        savedAt = now
        history.save(to: historyURL)
    }

    // MARK: Words

    var forecastLine: String {
        guard let f = forecast else { return "Still working out the time to flat." }
        return f.kind == .flat ? "Flat around \(Format.clock(f.at)) (\(Format.duration(f.minutes)))." : "Full around \(Format.clock(f.at))."
    }

    /// The panel header's first line.
    var headline: String {
        guard let r = reading else { return "No battery found" }
        if r.onAC {
            if r.full { return "Fully charged" }
            if r.charging { return forecast.map { "Full around \(Format.clock($0.at))" } ?? "Charging" }
            return "On power, not charging"
        }
        return forecast.map { "Flat around \(Format.clock($0.at))" } ?? "Working out the time to flat…"
    }

    /// The panel header's second line.
    var detail: String {
        guard let r = reading else { return "JuiceLeft needs a Mac with a battery" }
        var parts = ["\(r.percent)%"]
        if let f = forecast {
            parts.append(f.kind == .flat ? "\(Format.duration(f.minutes)) left" : "\(Format.duration(f.minutes)) to full")
        } else if !r.onAC, let os = r.osMinutesLeft {
            parts.append("macOS guesses \(Format.duration(os))")
        }
        if r.onAC, let w = r.adapterWatts { parts.append("\(w) W charger") }
        else if let w = r.batteryWatts, w < 0 { parts.append(Format.watts(w)) }
        if r.lowPowerMode { parts.append("Low Power Mode") }
        return parts.joined(separator: " · ")
    }

    /// The text either side of the glyph, per the display setting: Apple's "84%" in front, and after it the time —
    /// spelled out ("2 Hours 10 Min Remaining", "45 Min Until Full"), or compact ("2:10", "Full 45m"); "Estimating…"
    /// (or "…") until there is a forecast; nothing at all when the battery is full. Pure, so --selftest can check it.
    nonisolated static func menuParts(_ style: Settings.MenuBar, percent: Int, onAC: Bool, full: Bool, charging: Bool, minutes: Int?)
        -> (percent: String?, trailing: String?) {
        let pct = "\(percent)%"
        switch style {
        case .icon: return (nil, nil)
        case .percent: return (pct, nil)
        case .compact, .words:
            if onAC && (full || !charging) { return (pct, nil) }
            guard let minutes else { return (pct, style == .words ? "Estimating…" : "…") }
            let time = style == .words ? Format.words(minutes, charging: onAC) : onAC ? "Full \(Format.compact(minutes))" : Format.compact(minutes)
            return (pct, time)
        }
    }

    /// What VoiceOver reads for the menu-bar item: the whole story.
    var spoken: String {
        guard let r = reading else { return "JuiceLeft: no battery" }
        var s = "JuiceLeft: \(r.percent) percent"
        if let f = forecast {
            s += f.kind == .flat ? ", flat around \(Format.clock(f.at)), \(Format.spokenDuration(f.minutes)) left" : ", full around \(Format.clock(f.at))"
        } else if r.full { s += ", fully charged" } else if r.onAC { s += ", on power" } else { s += ", working out the time to flat" }
        s += self.s.armed ? ". Alerts on." : ". Alerts off."
        return s
    }

    var facts: Insight.Facts {
        Insight.Facts(percent: reading?.percent ?? 0, onAC: reading?.onAC ?? false, charging: reading?.charging ?? false,
                      full: reading?.full ?? false, minutesLeft: forecast?.minutes, ratePerHour: forecast?.ratePerHour,
                      typicalRate: reading.map { history.learner.prior(at: $0.at) } ?? nil,
                      topApps: energy.apps.prefix(2).map(\.name))
    }
}
