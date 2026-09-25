import Foundation

// The pure side of stretching the battery: what a change would save, what is costing power right now, when the
// pack is running hot, what the charging habits look like, and the two automatic helpers' decisions. Nothing in
// here touches the Mac; Monitor acts on these answers. Every piece is checked by --selftest.

/// Research-based starting points, used (and labelled "estimated") until the Mac's own numbers take over.
/// The display is the dominant drain on Apple silicon — roughly 7.5 h at full brightness against 20 h at the
/// lowest step, and its power climbs steeply above half — and Low Power Mode trims sustained draw by 18–24 %.
enum CareDefaults {
    static let displayOverBase = 1.0       // display draw at 100 % brightness, as a multiple of everything else (the cautious end)
    static let displayExponent = 1.6       // draw ∝ brightness^1.6: steep at the top, cheap at the bottom
    static let lowPowerSaving = 0.15       // under the measured 18–24 %
    static let keyboardSaving = 0.02       // the backlight is a couple of percent of a typical drain
    static let wattsPerBusyCore = 2.0      // an app pinning one core costs about this
    static let estimateCap = 0.3           // no single default claim beyond this share of the drain…
    static let estimateCombinedCap = 0.4   // …nor all of them together
}

/// How much of the drain a change would remove, as a fraction (0…1) of the current rate, and whether that comes
/// from this Mac's own measurements or the defaults. Defaults are capped, so a guess can never promise the moon.
struct Saving: Equatable {
    var fraction: Double
    var learned: Bool
    var isNothing: Bool { fraction <= 0.005 }

    static func estimated(_ fraction: Double) -> Saving { Saving(fraction: max(0, min(fraction, CareDefaults.estimateCap)), learned: false) }

    /// Minutes gained on the current forecast: the level lasts longer at the reduced rate.
    func minutes(level: Double, ratePerHour: Double) -> Int {
        guard ratePerHour > 0, fraction > 0, fraction < 1 else { return 0 }
        let now = level / ratePerHour * 60, after = level / (ratePerHour * (1 - fraction)) * 60
        return Int((after - now).rounded())
    }
}

/// What this Mac's drain has to do with its brightness and Low Power Mode: a small online ridge regression,
/// rate = w0 + w1·brightness^1.6 + w2·lowPower, fed one observation per five-minute window on battery. It only
/// speaks for itself once it has seen enough — two dozen windows, real spread in brightness, both Low Power
/// states — and a coefficient with the wrong sign is ignored in favour of the defaults.
struct Savings: Codable, Equatable {
    var n = 0
    var xtx = [Double](repeating: 0, count: 9)     // 3×3, row-major
    var xty = [Double](repeating: 0, count: 3)
    var brightnessSum = 0.0, brightnessSquares = 0.0
    var lowPowerOn = 0, lowPowerOff = 0

    static let ridge = 1.0
    static let minWindows = 24
    static let minBrightnessSpread = 0.01   // variance; ±10 % around the mean
    static let minEach = 4                  // Low Power windows of each kind

    /// One window: the measured drain (%/h, positive) at a mean brightness (0…1) with Low Power on or off.
    mutating func learn(rate: Double, brightness: Double, lowPower: Bool) {
        guard rate > 0, rate < 200 else { return }
        let x = [1.0, pow(max(brightness, 0), CareDefaults.displayExponent), lowPower ? 1.0 : 0.0]
        for i in 0..<3 {
            for j in 0..<3 { xtx[i * 3 + j] += x[i] * x[j] }
            xty[i] += x[i] * rate
        }
        n += 1
        brightnessSum += brightness
        brightnessSquares += brightness * brightness
        if lowPower { lowPowerOn += 1 } else { lowPowerOff += 1 }
    }

    /// The fitted coefficients (w0, w1, w2), or nil until there is anything to fit.
    var weights: [Double]? {
        guard n > 0 else { return nil }
        var a = xtx, b = xty
        for i in 0..<3 { a[i * 3 + i] += Self.ridge }
        // Gaussian elimination on the 3×3 system.
        for c in 0..<3 {
            var pivot = c
            for r in c + 1..<3 where abs(a[r * 3 + c]) > abs(a[pivot * 3 + c]) { pivot = r }
            if pivot != c { for k in 0..<3 { a.swapAt(c * 3 + k, pivot * 3 + k) }; b.swapAt(c, pivot) }
            guard abs(a[c * 3 + c]) > 1e-9 else { return nil }
            for r in 0..<3 where r != c {
                let f = a[r * 3 + c] / a[c * 3 + c]
                for k in 0..<3 { a[r * 3 + k] -= f * a[c * 3 + k] }
                b[r] -= f * b[c]
            }
        }
        return (0..<3).map { b[$0] / a[$0 * 3 + $0] }
    }

    private var brightnessVariance: Double { n > 1 ? brightnessSquares / Double(n) - pow(brightnessSum / Double(n), 2) : 0 }
    var trustsBrightness: Bool { n >= Self.minWindows && brightnessVariance >= Self.minBrightnessSpread && (weights?[1] ?? -1) > 0 }
    var trustsLowPower: Bool { n >= Self.minWindows && lowPowerOn >= Self.minEach && lowPowerOff >= Self.minEach && (weights?[2] ?? 1) < 0 }

    /// Dimming from `from` to `to` (0…1) at the current drain `rate` (%/h).
    func brightness(from: Double, to: Double, rate: Double) -> Saving {
        let e = CareDefaults.displayExponent
        guard from > to, rate > 0 else { return Saving(fraction: 0, learned: false) }
        if trustsBrightness, let w = weights {
            return Saving(fraction: min(w[1] * (pow(from, e) - pow(to, e)) / rate, 0.9), learned: true)
        }
        let d = CareDefaults.displayOverBase
        let total = { (b: Double) in 1 + d * pow(b, e) }
        return .estimated((total(from) - total(to)) / total(from))
    }

    func lowPower(rate: Double) -> Saving {
        if trustsLowPower, let w = weights, rate > 0 { return Saving(fraction: min(-w[2] / rate, 0.6), learned: true) }
        return .estimated(CareDefaults.lowPowerSaving)
    }

    static func keyboard() -> Saving { .estimated(CareDefaults.keyboardSaving) }

    /// Quitting an app: its processor time as watts against what the battery is delivering.
    static func quitting(cpuPercent: Double, batteryWatts: Double) -> Saving {
        guard batteryWatts > 0 else { return .estimated(0) }
        return .estimated(cpuPercent / 100 * CareDefaults.wattsPerBusyCore / batteryWatts)
    }

    /// Everything Save Battery does at once — savings compound, they don't add; a pile of guesses is capped too.
    static func combined(_ savings: [Saving]) -> Saving {
        let remaining = savings.reduce(1.0) { $0 * (1 - max(0, min($1.fraction, 0.95))) }
        let learned = savings.contains { $0.learned && !$0.isNothing }
        return Saving(fraction: learned ? 1 - remaining : min(1 - remaining, CareDefaults.estimateCombinedCap), learned: learned)
    }
}

/// What the tips see.
struct CareFacts: Equatable {
    var onAC = false
    var percent = 100
    var level = 100.0
    var ratePerHour: Double?         // positive drain
    var batteryWatts: Double?        // positive
    var brightness: Double?          // 0…1, built-in display
    var keyboardOn = false
    var ambient: Double?             // the light sensor's reading; ~200 and up is a lit room
    var lowPower = false
    var topApp: (name: String, cpuPercent: Double, share: Double)?
    var usbDevices: [(name: String, milliamps: Int)] = []

    static func == (a: CareFacts, b: CareFacts) -> Bool {
        a.onAC == b.onAC && a.percent == b.percent && a.brightness == b.brightness && a.keyboardOn == b.keyboardOn
            && a.lowPower == b.lowPower && a.topApp?.name == b.topApp?.name && a.usbDevices.map(\.name) == b.usbDevices.map(\.name)
    }
}

/// One thing that is costing power right now, with the click that fixes it.
struct Tip: Identifiable, Equatable {
    enum Fix: Equatable { case dim(to: Double), keyboardOff, lowPower, quit(app: String), unplugUSB }
    var id: String
    var text: String
    var gain: Int            // minutes, 0 = unknown
    var estimated: Bool      // from the defaults rather than this Mac's own numbers
    var fix: Fix

    /// "+2 h 10 m" when learned; "~+2 h" (to the quarter hour) when it is only an estimate.
    static func gainText(_ minutes: Int, estimated: Bool) -> String? {
        guard minutes >= 5 else { return nil }
        if !estimated { return "+" + Format.duration(Format.rounded5(minutes)) }
        guard minutes >= 15 else { return "~+\(Format.rounded5(minutes)) min" }   // under a quarter hour, to the nearest 5
        return "~+" + Format.duration(Int((Double(minutes) / 15).rounded()) * 15)
    }
}

enum Tips {
    static let dimTo = 0.4
    static let brightScreen = 0.7
    static let litRoom = 200.0
    static let lowPowerBelow = 30
    static let hogShare = 0.4, hogCore = 50.0
    static let usbNoticeable = 250   // mA
    static let shown = 2

    /// Only what is detected, the biggest saving first, at most `shown`.
    static func detect(_ f: CareFacts, savings: Savings) -> [Tip] {
        guard !f.onAC, let rate = f.ratePerHour, rate > 0 else { return [] }
        var tips: [Tip] = []
        let minutes = { (s: Saving) in s.minutes(level: f.level, ratePerHour: rate) }
        if let b = f.brightness, b >= brightScreen {
            let s = savings.brightness(from: b, to: dimTo, rate: rate)
            tips.append(Tip(id: "brightness", text: "Screen at \(Int((b * 100).rounded()))% — dim it to \(Int(dimTo * 100))%", gain: minutes(s), estimated: !s.learned, fix: .dim(to: dimTo)))
        }
        if f.keyboardOn, let ambient = f.ambient, ambient >= litRoom {
            let s = Savings.keyboard()
            tips.append(Tip(id: "keyboard", text: "Keyboard light on in a bright room — turn it off", gain: minutes(s), estimated: true, fix: .keyboardOff))
        }
        if !f.lowPower, f.percent <= lowPowerBelow {
            let s = savings.lowPower(rate: rate)
            tips.append(Tip(id: "lowpower", text: "Under \(lowPowerBelow)% with Low Power off — turn it on", gain: minutes(s), estimated: !s.learned, fix: .lowPower))
        }
        if let app = f.topApp, app.share >= hogShare, app.cpuPercent >= hogCore, let watts = f.batteryWatts {
            let s = Savings.quitting(cpuPercent: app.cpuPercent, batteryWatts: watts)
            tips.append(Tip(id: "app", text: "\(app.name) is working hard (\(Int(app.cpuPercent.rounded()))% of a core) — quit it", gain: minutes(s), estimated: true, fix: .quit(app: app.name)))
        }
        let hungry = f.usbDevices.filter { $0.milliamps >= usbNoticeable }
        if let first = hungry.first {
            tips.append(Tip(id: "usb", text: hungry.count == 1 ? "\(first.name) is drawing \(first.milliamps) mA — unplug it when you can"
                                                               : "\(hungry.count) USB devices are drawing power — unplug what you can", gain: 0, estimated: true, fix: .unplugUSB))
        }
        return Array(tips.sorted { $0.gain > $1.gain }.prefix(shown))
    }
}

/// Battery temperature: hot is 35 °C on the charger, 40 °C on battery, and it takes 2 °C of cooling to clear.
struct HeatGuard: Equatable {
    var hot = false
    static let chargingHot = 35.0, batteryHot = 40.0, release = 2.0

    /// Returns true on the moment it turns hot — the once-per-episode nudge.
    mutating func step(celsius: Double, charging: Bool) -> Bool {
        let threshold = charging ? Self.chargingHot : Self.batteryHot
        if !hot, celsius >= threshold { hot = true; return true }
        if hot, celsius <= threshold - Self.release { hot = false }
        return false
    }

    static func advice(charging: Bool) -> String {
        charging ? "Unplug for a while, or move it somewhere cooler — charging a hot battery ages it fastest."
                 : "Turn on Low Power Mode, close what is working hard, and give it some air."
    }
}

/// One line a day about the battery's life, for the health coach.
struct DayLog: Codable, Equatable {
    var day: Date
    var cycles: Int
    var health: Double?
}

enum HealthCoach {
    static let highCharge = 95.0
    static let trendWeeks = 3.0
    static let storageShare = 0.8

    /// The share of the last `hours` spent on the charger at 95 % or more.
    static func timeAtHighCharge(_ points: [History.Point], now: Date, hours: Double = 72) -> Double? {
        let recent = points.filter { now.timeIntervalSince($0.t) <= hours * 3600 }
        guard recent.count >= 30 else { return nil }
        return Double(recent.filter { $0.c && $0.l >= highCharge }.count) / Double(recent.count)
    }

    /// Cycles per week over the log, once it spans a week.
    static func cyclesPerWeek(_ log: [DayLog]) -> Double? {
        guard let first = log.first, let last = log.last, last.day.timeIntervalSince(first.day) >= 6 * 86400 else { return nil }
        return Double(last.cycles - first.cycles) / (last.day.timeIntervalSince(first.day) / (7 * 86400))
    }

    /// Health change per month from a straight line through the log, once it spans three weeks.
    static func healthTrendPerMonth(_ log: [DayLog]) -> Double? {
        let pts = log.compactMap { entry in entry.health.map { (x: entry.day.timeIntervalSince1970 / 86400, y: $0) } }
        guard let first = pts.first, let last = pts.last, last.x - first.x >= trendWeeks * 7, pts.count >= 10 else { return nil }
        let n = Double(pts.count), mx = pts.map(\.x).reduce(0, +) / n, my = pts.map(\.y).reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for p in pts { sxy += (p.x - mx) * (p.y - my); sxx += (p.x - mx) * (p.x - mx) }
        return sxx > 0 ? sxy / sxx * 30 : nil
    }

    /// Adds today's line (once a day) and keeps a year.
    static func logged(_ log: [DayLog], cycles: Int, health: Double?, now: Date, calendar: Calendar = .current) -> [DayLog] {
        if let last = log.last, calendar.isDate(last.day, inSameDayAs: now) { return log }
        return (log + [DayLog(day: now, cycles: cycles, health: health)]).suffix(366).map { $0 }
    }
}

/// Smart Low Power: on battery at or below the level (or under an hour left), switch the battery-side mode to
/// Low Power; put the old mode back on the charger; and never fight a change the user made by hand.
enum SmartLowPower {
    static let level = 30
    static let minutes = 60

    enum Action: Equatable { case none, engage, restore(PowerMode.Mode) }

    /// `applied` is the mode we set (nil = not engaged); `userChanged` is set when the mode moved without us.
    static func decide(enabled: Bool, onAC: Bool, percent: Int, minutesLeft: Int?, mode: PowerMode.Mode?, applied: Bool, previous: PowerMode.Mode?, userChanged: Bool) -> Action {
        guard enabled, let mode else { return .none }
        if onAC { return applied ? .restore(previous ?? .automatic) : .none }
        guard !applied, !userChanged, mode != .low else { return .none }
        let low = percent <= level || (minutesLeft.map { $0 < minutes } ?? false)
        return low ? .engage : .none
    }
}

/// The brightness cap on battery: only ever turns the screen down, to `cap` at most.
enum BrightnessCap {
    static func target(enabled: Bool, onAC: Bool, brightness: Float, cap: Double) -> Float? {
        guard enabled, !onAC, Double(brightness) > cap + 0.005 else { return nil }
        return Float(cap)
    }
}
