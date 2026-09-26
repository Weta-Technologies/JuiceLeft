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
    var smartLowPower = true     // Low Power Mode by itself at 30 % (or under an hour left), back on the charger
    var brightnessCap = false    // keep the screen at or below `brightnessCapLevel` on battery
    var brightnessCapLevel = 0.5
    var heatGuard = true         // a nudge when the pack runs hot
    var light = true             // drive the MagSafe charging light
    var lightBehaviour = MagSafeLight.Behaviour.blinkThenSteady
    var lightGreenAtLimit = true // green when full or held at the charge limit
    var lightFastWhenLow = true  // fast orange blink while charging from at or below the alert level

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
        s.brightnessCapLevel = max(0.2, min(0.8, s.brightnessCapLevel))
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
    var savings = Savings()        // what brightness and Low Power cost on this Mac
    var days: [DayLog] = []        // one line a day: cycles and health, for the coach

    init(points: [Point] = [], learner: Learner = Learner(), savings: Savings = Savings(), days: [DayLog] = []) {
        self.points = points
        self.learner = learner
        self.savings = savings
        self.days = days
    }

    /// Fields added in later versions are optional on the way in, so an older file keeps its learner.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decodeIfPresent([Point].self, forKey: .points) ?? []
        learner = try c.decodeIfPresent(Learner.self, forKey: .learner) ?? Learner()
        savings = try c.decodeIfPresent(Savings.self, forKey: .savings) ?? Savings()
        days = try c.decodeIfPresent([DayLog].self, forKey: .days) ?? []
    }

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
    @Published private(set) var saving: SaverSnapshot?          // Save Battery is on: what to put back
    @Published private(set) var tips: [Tip] = []                // what is costing power right now (while the panel is open)
    @Published private(set) var heat = HeatGuard()
    @Published var heatNote: String?                            // the once-per-episode nudge, dismissable
    @Published private(set) var chargeLimit: ChargeLimit.State?
    @Published private(set) var travelFull: Date?               // "Full for travel" is on since then
    @Published private(set) var smartApplied = false            // Smart Low Power has the mode
    @Published private(set) var helperReady = PowerMode.helperReady
    @Published private(set) var helperUpdating = false          // the installed helper is taking this build's signed files (no prompt)
    @Published var setupLater = false                           // "Later" on the setup card, for this launch
    @Published private(set) var aiStatus = AppleIntelligence.status
    @Published private(set) var aiNudgeDismissed: Bool          // "Not now" on the Apple Intelligence line, remembered
    /// The helper is there but from another version: a signed update, or the setup card.
    var helperStale: Bool { !helperReady && PowerMode.helperInstalled }
    var interactive = true                                      // false = never raise the helper's admin prompt (harness, selftest, --simulate)
    let icon = MenuIcon()
    let light = LightController()
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
    let hardware: Hardware
    private var careWindow: (start: Date, level: Double, brightnessSum: Double, samples: Int, lowPower: Int)?
    private var smartPrevious: PowerMode.Mode?
    private var smartUserChanged = false
    private var cappedFrom: Float?
    private var travelPrevious: Int?
    static let careWindowLength: TimeInterval = 5 * 60
    static let travelMax: TimeInterval = 24 * 3600

    init(source: BatterySource, defaults: UserDefaults = .standard, historyURL: URL = History.url, hardware: Hardware = RealHardware()) {
        self.source = source
        self.defaults = defaults
        self.historyURL = historyURL
        self.hardware = hardware
        s = Settings.load(defaults)
        aiNudgeDismissed = defaults.bool(forKey: "aiNudgeDismissed")
        history = History.load(from: historyURL)
        saving = defaults.data(forKey: SaverSnapshot.key).flatMap { try? JSONDecoder().decode(SaverSnapshot.self, from: $0) }
        if let travel = defaults.object(forKey: "travelFull") as? [String: Any] {
            travelFull = travel["since"] as? Date
            travelPrevious = travel["previous"] as? Int
        }
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
        light.refresh = { [weak self] in self?.evaluate() }
        light.log = { [weak self] line in self?.log?(line) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.persist(force: true)
                if self.s.replaceSystemIcon { SystemBattery.restore(from: self.defaults) }
                self.light.handBack(onAC: self.reading?.onAC ?? false, charging: self.reading?.charging ?? false)
            }
        }
    }

    /// --shots: sample state for the panel — no readings, no observers, nothing on the Mac touched.
    init(shots s: Settings, reading r: Reading, forecast: Forecast?, phase: Alerts.Phase = .clear, history: History = History(), helperReady: Bool = true,
         aiStatus: AppleIntelligence.Status = .available, welcome: Bool = false, tips: [Tip] = [], ranking: Ranking = Ranking(),
         chargeLimit: ChargeLimit.State? = nil, power: PowerMode.State = PowerMode.State(), defaults: UserDefaults, source: BatterySource) {
        self.source = source
        self.defaults = defaults
        historyURL = FileManager.default.temporaryDirectory.appendingPathComponent("juiceleft-shots-history.json")
        hardware = FakeHardware()
        self.s = s
        aiNudgeDismissed = false
        self.history = history
        reading = r
        self.forecast = forecast
        self.phase = phase
        self.helperReady = helperReady
        self.aiStatus = aiStatus
        self.welcome = welcome
        self.tips = tips
        self.chargeLimit = chargeLimit
        self.power = power
        if let forecast { _ = steady.update(forecast.minutes) }
        energy.show(sample: ranking)
        insight.update(facts, ai: false)
        let parts = Self.menuParts(s.menuBar, percent: r.percent, onAC: r.onAC, full: r.full, charging: r.charging, minutes: forecast?.minutes)
        icon.show(MenuIcon.Frame(level: r.percent, plugged: r.onAC, armed: s.armed, percent: parts.percent, trailing: parts.trailing), phase: phase)
    }

    func start() {
        if interactive, helperStale {   // an app update changed the helper: the installed one takes the signed files itself
            helperUpdating = true
            HelperUpdate.request(ready: { PowerMode.helperReady }) { [weak self] _ in
                guard let self else { return }
                self.helperUpdating = false
                self.helperReady = PowerMode.helperReady
                self.evaluate()
            }
        }
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

    func dismissAINudge() {
        aiNudgeDismissed = true
        defaults.set(true, forKey: "aiNudgeDismissed")
    }

    /// The one administrator prompt (password or Touch ID): the setup card, a Set up… button, or Reinstall helper.
    func setUpHelper() {
        note = nil
        switch PowerMode.installHelper() {
        case .done: helperReady = true
        case .cancelled: break
        case .failed(let why): note = "The helper didn't install: \(why)"
        }
        evaluate()
    }

    // MARK: Save Battery

    /// What one click would gain right now, from this Mac's own numbers where it has them.
    var saveBatteryGain: (minutes: Int, estimated: Bool)? {
        guard let r = reading, !r.onAC, let f = forecast, f.kind == .flat, saving == nil else { return nil }
        var parts: [Saving] = []
        if let b = hardware.brightness(), Double(b) > Tips.dimTo { parts.append(history.savings.brightness(from: Double(b), to: Tips.dimTo, rate: f.ratePerHour)) }
        if let k = hardware.keyboard(), k.brightness > 0 { parts.append(Savings.keyboard()) }
        if !r.lowPowerMode { parts.append(history.savings.lowPower(rate: f.ratePerHour)) }
        let all = Savings.combined(parts)
        return (all.minutes(level: r.level, ratePerHour: f.ratePerHour), !all.learned)
    }

    /// One click: Low Power Mode, the screen down to 40 % (never up), the keyboard light off — remembering each.
    func saveBattery() {
        guard saving == nil, let r = reading, !r.onAC else { return }
        var snap = SaverSnapshot(at: r.at)
        if let b = hardware.brightness() {
            snap.brightness = b
            if Double(b) > Tips.dimTo { hardware.setBrightness(Float(Tips.dimTo)) }
        }
        if let k = hardware.keyboard() {
            snap.keyboard = k
            if k.brightness > 0 || k.auto { hardware.setKeyboard(.init(brightness: 0, auto: false)) }
        }
        if !r.lowPowerMode, requestPowerMode(.low, onBattery: true, reason: "Save Battery") {
            snap.batteryMode = (power.battery ?? .automatic).rawValue
        }
        saving = snap
        defaults.set(try? JSONEncoder().encode(snap), forKey: SaverSnapshot.key)
        log?("save battery: \(snap)")
        evaluate()
    }

    /// Everything back exactly as it was.
    func undoSaveBattery() {
        guard let snap = saving else { return }
        if let b = snap.brightness { hardware.setBrightness(b) }
        if let k = snap.keyboard { hardware.setKeyboard(k) }
        if let mode = snap.batteryMode.flatMap(PowerMode.Mode.init(rawValue:)) { _ = requestPowerMode(mode, onBattery: true, reason: "undo") }
        saving = nil
        defaults.removeObject(forKey: SaverSnapshot.key)
        log?("save battery undone")
        evaluate()
    }

    /// A one-click fix from a tip.
    func apply(_ tip: Tip) {
        switch tip.fix {
        case .dim(let to): if let b = hardware.brightness(), Double(b) > to { hardware.setBrightness(Float(to)) }
        case .keyboardOff: hardware.setKeyboard(.init(brightness: 0, auto: false))
        case .lowPower: _ = requestPowerMode(.low, onBattery: true, reason: "tip")
        case .quit(let name): if let app = energy.ranking.apps.first(where: { $0.name == name }) { energy.quit(app) }
        case .unplugUSB: break
        }
        refreshTips()
    }

    /// Sets the battery-side mode through the helper; without the helper it says so (never a prompt) and leaves the mode.
    @discardableResult
    private func requestPowerMode(_ mode: PowerMode.Mode, onBattery: Bool, reason: String) -> Bool {
        guard PowerMode.helperReady else {
            if interactive { note = "Low Power needs the one-time setup — click Set up." }
            log?("\(reason): helper not set up, mode left alone")
            return false
        }
        if let why = PowerMode.set(mode, onBattery: onBattery) { note = why; return false }
        log?("\(reason): power mode → \(PowerMode.request(mode, onBattery: onBattery))")
        for delay in [1.0, 3.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { self.refreshPower() } } }
        return true
    }

    // MARK: Charge limit

    func refreshChargeLimit() {
        guard ChargeLimit.supported else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let state = ChargeLimit.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { if state != self.chargeLimit { self.chargeLimit = state } } }
        }
    }

    func setChargeLimit(_ limit: Int) {
        note = ChargeLimit.set(limit)
        if note == nil { chargeLimit = chargeLimit.map { State(enabled: limit < 100, limit: limit, available: $0.available) } }
        log?("charge limit → \(limit)")
        refreshChargeLimit()
    }
    private typealias State = ChargeLimit.State

    /// One tap: let it fill to 100 % once; the limit comes back after the next unplug, or after a day plugged in.
    func fullForTravel() {
        guard let current = chargeLimit, current.enabled else { return }
        if let why = ChargeLimit.fullNow() { note = why; return }
        travelPrevious = current.limit
        travelFull = reading?.at ?? Date()
        defaults.set(["since": travelFull!, "previous": current.limit], forKey: "travelFull")
        log?("full for travel from \(current.limit)%")
    }

    func cancelFullForTravel() { endTravel() }

    private func endTravel() {
        guard travelFull != nil else { return }
        if let previous = travelPrevious { note = ChargeLimit.set(previous) }
        travelFull = nil
        travelPrevious = nil
        defaults.removeObject(forKey: "travelFull")
        refreshChargeLimit()
    }

    // MARK: Care

    var careFacts: CareFacts {
        var f = CareFacts()
        guard let r = reading else { return f }
        f.onAC = r.onAC; f.percent = r.percent; f.level = r.level; f.lowPower = r.lowPowerMode
        f.ratePerHour = forecast?.kind == .flat ? forecast?.ratePerHour : nil
        f.batteryWatts = r.batteryWatts.map { -$0 }
        f.brightness = hardware.brightness().map(Double.init)
        f.keyboardOn = (hardware.keyboard()?.brightness ?? 0) > 0
        f.ambient = hardware.ambientLight()
        f.topApp = energy.ranking.apps.first.map { ($0.name, $0.cpuPercent, $0.share) }
        f.usbDevices = hardware.usbDevices().map { ($0.name, $0.milliamps) }
        return f
    }

    func refreshTips() {
        guard panelIsOpen else { return }
        let fresh = Tips.detect(careFacts, savings: history.savings)
        if fresh != tips { tips = fresh }
    }

    /// The five-minute windows that teach `Savings` what brightness and Low Power cost here.
    private func learnCare(_ r: Reading) {
        guard !r.onAC, let b = hardware.brightness() else { careWindow = nil; return }
        guard var w = careWindow else { careWindow = (r.at, r.level, Double(b), 1, r.lowPowerMode ? 1 : 0); return }
        w.brightnessSum += Double(b); w.samples += 1; w.lowPower += r.lowPowerMode ? 1 : 0
        if r.at.timeIntervalSince(w.start) >= Self.careWindowLength {
            let hours = r.at.timeIntervalSince(w.start) / 3600
            history.savings.learn(rate: (w.level - r.level) / hours, brightness: w.brightnessSum / Double(w.samples), lowPower: w.lowPower * 2 > w.samples)
            careWindow = (r.at, r.level, Double(b), 1, r.lowPowerMode ? 1 : 0)
        } else {
            careWindow = w
        }
    }

    // MARK: Energy modes

    /// The status item found (or lost) room in the menu bar.
    func setSqueezed(_ squeezed: Bool) {
        guard squeezed != self.squeezed else { return }
        self.squeezed = squeezed
        evaluate()
    }

    /// The mode for the power source in use right now.
    var activeMode: PowerMode.Mode? { reading?.onAC == true ? power.adapter : power.battery }

    /// The battery-side mode as the system reports it live (Low Power Mode active), else as last read from pmset.
    private var batteryModeNow: PowerMode.Mode? {
        guard let r = reading else { return nil }
        if r.lowPowerMode { return .low }
        return power.battery == .low ? .automatic : power.battery ?? .automatic
    }

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
        if !helperUpdating { helperReady = PowerMode.helperReady }
        aiStatus = AppleIntelligence.status   // turned on since launch? the nudge goes, and the sentence gets its phrasing
        insight.retryAI(ai: s.insight)
        refreshPower()
        refreshChargeLimit()
        refreshTips()
        energy.start()
        let timer = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { self.refreshPower() } }
        RunLoop.main.add(timer, forMode: .common)
        powerTimer = timer
    }

    func panelClosed() {
        panelIsOpen = false
        tips = []
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

    /// Sets the mode for the source in use through the helper (set up once from the panel; never a prompt here).
    func setPowerMode(_ mode: PowerMode.Mode) {
        guard mode != activeMode, let r = reading else { return }
        note = nil
        guard PowerMode.helperReady else { note = "Energy modes need the one-time setup — click Set up."; return }
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
            careWindow = nil
            if r.onAC != previous.onAC { plugEdge(r) }
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
        care(r)
        light.update(enabled: s.light, onAC: r.onAC, charging: r.charging && !r.full, percent: r.percent, alertAt: s.alertAt,
                     behaviour: s.lightBehaviour, greenAtLimit: s.lightGreenAtLimit, fastWhenLow: s.lightFastWhenLow, now: r.at)
        insight.update(facts, ai: s.insight)
    }

    private func notify(id: String, title: String, body: String) {
        log?("notification “\(title)” \(body)")
        Notifier.post(id: id, title: title, body: body)
    }

    /// The charger went in or out: everything automatic steps back.
    private func plugEdge(_ r: Reading) {
        light.plugChanged(onAC: r.onAC, at: r.at)
        if r.onAC {
            if saving != nil { undoSaveBattery() }
            if smartApplied { _ = requestPowerMode(smartPrevious ?? .automatic, onBattery: true, reason: "smart low power, charger in"); smartApplied = false }
            smartUserChanged = false
            if let from = cappedFrom { hardware.setBrightness(from); cappedFrom = nil }
        } else {
            endTravel()   // the trip's full charge has happened; the limit comes back
            if let since = travelFull, r.at.timeIntervalSince(since) > Self.travelMax { endTravel() }
        }
    }

    /// The automatic helpers, every reading: heat, Smart Low Power, the brightness cap, learning, the coach's log.
    private func care(_ r: Reading) {
        if let t = r.celsius, s.heatGuard {
            if heat.step(celsius: t, charging: r.onAC && r.charging) {
                let line = String(format: "Battery at %.0f °C. ", t) + HeatGuard.advice(charging: r.onAC)
                heatNote = line
                if s.notify { notify(id: "heat", title: "Battery running hot", body: line) }
                log?("hot: \(line)")
            } else if !heat.hot, heatNote != nil { heatNote = nil }
        }
        if let since = travelFull, r.onAC, r.at.timeIntervalSince(since) > Self.travelMax { endTravel() }
        // Smart Low Power: engage low, put the old mode back on the charger, and stand down if the user moved it.
        if smartApplied, !r.onAC, !r.lowPowerMode, power.battery != .low { smartApplied = false; smartUserChanged = true; log?("smart low power: user changed the mode") }
        switch SmartLowPower.decide(enabled: s.smartLowPower && s.armed, onAC: r.onAC, percent: r.percent, minutesLeft: forecast?.kind == .flat ? forecast?.minutes : nil,
                                    mode: batteryModeNow, applied: smartApplied, previous: smartPrevious, userChanged: smartUserChanged) {
        case .engage:   // automatic, so never a password prompt: without the helper the tip offers Low Power instead
            guard PowerMode.helperReady else { break }
            smartPrevious = batteryModeNow
            if requestPowerMode(.low, onBattery: true, reason: "smart low power") { smartApplied = true }
        case .restore(let mode):
            _ = requestPowerMode(mode, onBattery: true, reason: "smart low power, charger in")
            smartApplied = false
        case .none: break
        }
        // The brightness cap: down to the cap on battery, never up; back on the charger.
        if let b = hardware.brightness(), let target = BrightnessCap.target(enabled: s.brightnessCap, onAC: r.onAC, brightness: b, cap: s.brightnessCapLevel) {
            if cappedFrom == nil { cappedFrom = b }
            hardware.setBrightness(target)
            log?("brightness capped to \(target)")
        }
        learnCare(r)
        if let c = r.cycles { history.days = HealthCoach.logged(history.days, cycles: c, health: r.health, now: r.at) }
        refreshTips()
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
        return forecast.map { "Flat around \(Format.clock($0.at))" } ?? "Estimating time to flat…"
    }

    /// The panel header's second line.
    var detail: String {
        guard let r = reading else { return "JuiceLeft needs a Mac with a battery" }
        var parts = ["\(r.percent)%"]
        if let f = forecast {
            parts.append(f.kind == .flat ? "\(Format.duration(f.minutes)) left" : "\(Format.duration(f.minutes)) to full")
        } else if !r.onAC, let os = r.osMinutesLeft {
            parts.append("macOS says \(Format.duration(os))")
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
                      topApps: energy.ranking.apps.prefix(2).map(\.name))
    }
}

/// What Save Battery changed, so Undo (or the charger) can put it back exactly. Persisted, so a relaunch can still undo.
struct SaverSnapshot: Codable, Equatable {
    var at: Date
    var brightness: Float?
    var keyboard: KeyboardLight.Level?
    var batteryMode: Int?          // the mode Low Power replaced, if Save Battery changed it
    static let key = "saver"
}
