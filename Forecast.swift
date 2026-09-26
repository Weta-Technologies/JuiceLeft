import Foundation

/// One point on the battery curve.
struct Sample: Codable, Equatable {
    var at: Date
    var level: Double          // % of a full charge, fractional
    var ratePerHour: Double?   // the gas gauge's live rate at that moment: − draining, + charging
}

/// When the battery will be flat (or full).
struct Forecast: Equatable {
    enum Kind: Equatable { case flat, full }
    var kind: Kind
    var minutes: Int
    var at: Date
    var ratePerHour: Double     // the rate it rests on, %/h, always positive
    var learned = false         // a learned prior took part
    var target = 100            // charging: the level it aims at — Apple's charge limit when one is set, else 100

    /// "Full", or "80%" when a charge limit is the goal — the word every "… Until Full" and "Full around …" uses.
    var goalText: String { target < 100 ? "\(target)%" : "Full" }
}

/// Keeps the menu bar's spelled-out time from flip-flopping: the shown value (rounded to five minutes) only moves when
/// the new one differs by ten minutes or more, or has come up twice in a row.
struct Steady: Equatable {
    private(set) var shown: Int?
    private var pending: Int?

    mutating func update(_ minutes: Int) -> Int {
        let new = Format.rounded5(minutes)
        guard let current = shown else { shown = new; return new }
        if abs(new - current) >= 10 || new == pending { shown = new; pending = nil; return new }
        pending = new == current ? nil : new
        return current
    }

    mutating func reset() { shown = nil; pending = nil }
}

/// The three opinions of the drain rate the forecast blends.
enum RateSource: Int, Codable, CaseIterable { case live, trend, prior }

/// The self-calibrating discharge model: a pure value, Codable so it carries on between launches.
///
/// Three opinions of the drain rate are blended: `live`, the gas gauge's current smoothed over the last 5 min;
/// `trend`, a straight line fitted to the last 20 min of the level curve; and `prior`, what this user typically
/// drains at this time of day (six 4-hour slots, weekdays and weekends apart). Each opinion is weighted by the
/// inverse of its recent error: every 5 min a check is filed, and 20 min later the rate each opinion predicted is
/// scored against what the level really did. The same verdict teaches the prior, and a bias term soaks up any
/// consistent lean. Arrival accuracy is scored when a discharge ends: every forecast made during it predicted when
/// the level it ended at would arrive, and the typical miss (as a share of the horizon) is what the panel shows.
struct Learner: Codable, Equatable {
    struct Bucket: Codable, Equatable { var rate = 0.0; var n = 0 }   // typical drain, %/h (positive), observations
    struct Check: Codable, Equatable { var at: Date; var level: Double; var rates: [Double?]; var blended: Double? }
    struct Made: Codable, Equatable { var at: Date; var level: Double; var rate: Double }

    var buckets = [Bucket](repeating: Bucket(), count: 12)
    var global = Bucket()
    var errors = [3.0, 3.0, 9.0]         // EW mean |miss| per opinion (live, trend, prior), %/h: a typical rate starts as the least trusted
    var bias = 0.0                       // EW mean of (actual − blended), signed %/h
    var relativeError: Double?           // EW mean of |forecast − actual arrival| / actual, per discharge
    var discharges = 0                   // how many discharges have scored the accuracy
    var pending: [Check] = []
    var made: [Made] = []

    static let window: TimeInterval = 20 * 60        // the trend line fits this much of the curve
    static let minSpan: TimeInterval = 3 * 60        // and needs this much (and 3 samples) before it has an opinion
    static let minSamples = 3
    static let tau: TimeInterval = 5 * 60            // the live current's smoothing time constant
    static let checkEvery: TimeInterval = 5 * 60     // a check (and a forecast on record) every 5 min
    static let checkAfter: TimeInterval = 20 * 60    // scored 20 min later
    static let settleAfter: TimeInterval = 5 * 60    // or at plug-in, if at least this old
    static let judgeAfter: TimeInterval = 15 * 60    // a forecast's arrival is only judged over 15 min or more
    static let minBucketN = 3                        // observations before a slot's prior is trusted over the global one
    static let errorAlpha = 0.2, biasAlpha = 0.1, bucketAlpha = 0.25, accuracyAlpha = 0.3
    static let noise = 0.5                           // %/h added to every error, so no opinion ever takes the whole blend
    static let biasCap = 0.25                        // the bias never moves the rate by more than a quarter
    static let maxHours = 48.0
    static let keep = 96                             // pending / made entries kept (8 hours at one per 5 min)

    // MARK: Opinions

    static func slot(_ date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date) / 4 + (calendar.isDateInWeekend(date) ? 6 : 0)
    }

    /// The typical drain for this moment, if enough has been seen: this slot's, else the overall one.
    func prior(at date: Date, calendar: Calendar = .current) -> Double? {
        let slot = buckets[Self.slot(date, calendar: calendar)]
        if slot.n >= Self.minBucketN { return slot.rate }
        return global.n >= Self.minBucketN ? global.rate : nil
    }

    /// Live and trend, signed (− draining), from this discharge's samples (oldest first).
    static func liveAndTrend(_ samples: [Sample], now: Date) -> (live: Double?, trend: Double?) {
        let recent = samples.filter { now.timeIntervalSince($0.at) <= window }
        var wsum = 0.0, rsum = 0.0
        for s in recent {
            guard let r = s.ratePerHour else { continue }
            let w = exp(-now.timeIntervalSince(s.at) / tau)
            wsum += w
            rsum += w * r
        }
        let live = wsum > 0 ? rsum / wsum : nil
        guard recent.count >= minSamples, let first = recent.first, now.timeIntervalSince(first.at) >= minSpan else { return (live, nil) }
        let n = Double(recent.count)
        let t = recent.map { $0.at.timeIntervalSince(now) / 3600 }, y = recent.map(\.level)
        let mt = t.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for i in recent.indices {
            sxy += (t[i] - mt) * (y[i] - my)
            sxx += (t[i] - mt) * (t[i] - mt)
        }
        return (live, sxx > 0 ? sxy / sxx : nil)
    }

    /// Inverse-error weighted mean of the opinions that exist, plus the bias. Signed.
    func blend(_ opinions: [Double?]) -> Double? {
        var wsum = 0.0, rsum = 0.0
        for (i, opinion) in opinions.enumerated() {
            guard let opinion else { continue }
            let w = 1 / (errors[i] + Self.noise)
            wsum += w
            rsum += w * opinion
        }
        guard wsum > 0 else { return nil }
        let rate = rsum / wsum
        return rate + max(-Self.biasCap * abs(rate), min(Self.biasCap * abs(rate), bias))
    }

    // MARK: A discharge, step by step

    /// One step of a discharge: `samples` is the whole discharge so far, its last entry taken at `now`. Returns the
    /// forecast, files and scores checks, and keeps the forecast on record for the arrival score.
    mutating func step(_ samples: [Sample], now: Date, calendar: Calendar = .current) -> Forecast? {
        guard let last = samples.last else { return nil }
        settle(now: now, level: last.level, olderThan: Self.checkAfter, calendar: calendar)
        let (live, trend) = Self.liveAndTrend(samples, now: now)
        let prior = prior(at: now, calendar: calendar)
        let opinions: [Double?] = [live, trend, prior.map { -$0 }]
        let blended = blend(opinions)
        if pending.last.map({ now.timeIntervalSince($0.at) >= Self.checkEvery }) ?? true {
            pending.append(Check(at: now, level: last.level, rates: opinions, blended: blended))
            pending = pending.suffix(Self.keep)
        }
        guard let rate = blended, rate < 0 else { return nil }
        let hours = min(last.level / -rate, Self.maxHours)
        if made.last.map({ now.timeIntervalSince($0.at) >= Self.checkEvery }) ?? true {
            made.append(Made(at: now, level: last.level, rate: -rate))
            made = made.suffix(Self.keep)
        }
        return Forecast(kind: .flat, minutes: Int((hours * 60).rounded()), at: now.addingTimeInterval(hours * 3600),
                        ratePerHour: -rate, learned: prior != nil)
    }

    /// The charger went in (or the curve was interrupted by sleep): score the forecasts made against the level actually
    /// reached, settle what checks can be settled, and start clean.
    mutating func endDischarge(now: Date, level: Double, calendar: Calendar = .current) {
        var misses: [Double] = []
        for m in made where m.level > level {
            let actual = now.timeIntervalSince(m.at) / 60
            guard actual >= Self.judgeAfter / 60 else { continue }
            let predicted = (m.level - level) / m.rate * 60
            misses.append(abs(predicted - actual) / actual)
        }
        if !misses.isEmpty {
            let miss = misses.reduce(0, +) / Double(misses.count)
            relativeError = relativeError.map { (1 - Self.accuracyAlpha) * $0 + Self.accuracyAlpha * miss } ?? miss
            discharges += 1
        }
        settle(now: now, level: level, olderThan: Self.settleAfter, calendar: calendar)
        pending = []
        made = []
    }

    /// The Mac slept mid-discharge: the curve on either side can't be compared, so nothing is scored.
    mutating func abandon() {
        pending = []
        made = []
    }

    /// Scores every check at least `olderThan` old against the level now, and teaches the prior with the verdict.
    private mutating func settle(now: Date, level: Double, olderThan: TimeInterval, calendar: Calendar) {
        for check in pending where now.timeIntervalSince(check.at) >= olderThan {
            let hours = now.timeIntervalSince(check.at) / 3600
            let actual = (level - check.level) / hours
            for (i, predicted) in check.rates.enumerated() {
                guard let predicted else { continue }
                errors[i] = (1 - Self.errorAlpha) * errors[i] + Self.errorAlpha * abs(predicted - actual)
            }
            if let blended = check.blended { bias = (1 - Self.biasAlpha) * bias + Self.biasAlpha * (actual - blended) }
            guard actual < 0 else { continue }
            let slot = Self.slot(check.at, calendar: calendar)
            buckets[slot].learn(-actual)
            global.learn(-actual)
        }
        pending.removeAll { now.timeIntervalSince($0.at) >= olderThan }
    }

    /// How far out a forecast for `minutes` from now typically lands, once two discharges have scored it.
    func typicalMiss(for minutes: Int) -> Int? {
        guard discharges >= 2, let relativeError else { return nil }
        return max(5, Int((relativeError * Double(minutes) / 5).rounded()) * 5)
    }

    // MARK: Charging

    static let taperFrom = 80.0                      // above this the charger tapers…
    static let taperFloor = 0.2                      // …to a fifth of the rate at 100 %, falling linearly
    static let chargeTau: TimeInterval = 60          // the measured charge rate settles within about a minute of plug-in

    /// Time to the level the Mac will stop at: Apple's charge limit when one is set (`target` < 100), else 100 %. The
    /// rate is measured — the gas gauge's charge current over the pack's capacity (watts over watt-hours), smoothed over
    /// the last minute — from the first sample after plug-in, with the level curve's own trend blended in once it has
    /// one. macOS's figure isn't used: it averages the slow first minutes into an hour-plus estimate and always aims at
    /// 100 %. Above 80 % the charger tapers, modelled as the rate falling linearly to a fifth of itself at 100 % (that
    /// stretch takes about twice what a straight line would); below 80 % nothing slows it. nil until there is a
    /// measurement, and nil at or past the target.
    static func chargeForecast(_ samples: [Sample], level: Double, now: Date, target: Int = 100) -> Forecast? {
        let goal = Double(min(max(target, 1), 100))
        guard level < goal else { return nil }
        var wsum = 0.0, rsum = 0.0
        for s in samples where now.timeIntervalSince(s.at) <= window {
            guard let r = s.ratePerHour, r > 0 else { continue }
            let w = exp(-now.timeIntervalSince(s.at) / chargeTau)
            wsum += w
            rsum += w * r
        }
        guard wsum > 0 else { return nil }
        var rate = rsum / wsum
        if let trend = liveAndTrend(samples, now: now).trend, trend > 0 { rate = (2 * rate + trend) / 3 }
        let hours = min(chargeHours(from: level, to: goal, rate: rate), maxHours)
        return Forecast(kind: .full, minutes: Int((hours * 60).rounded()), at: now.addingTimeInterval(hours * 3600), ratePerHour: rate, target: Int(goal))
    }

    /// Hours from one level up to another at `rate` %/h: straight up to 80 %, then through the taper, where the rate
    /// is rate · (1 − k·(level − 80)) with k = 0.8 / 20 — integrated exactly, so 80 → 100 takes ln 5 / (0.04 · rate).
    static func chargeHours(from a: Double, to b: Double, rate: Double) -> Double {
        guard rate > 0, b > a else { return 0 }
        let straight = max(0, min(b, taperFrom) - a) / rate
        let lo = max(a, taperFrom), hi = max(b, taperFrom)
        guard hi > lo else { return straight }
        let k = (1 - taperFloor) / (100 - taperFrom)
        return straight + log((1 - k * (lo - taperFrom)) / (1 - k * (hi - taperFrom))) / (rate * k)
    }
}

extension Learner.Bucket {
    mutating func learn(_ observed: Double) {
        rate = n == 0 ? observed : (1 - Learner.bucketAlpha) * rate + Learner.bucketAlpha * observed
        n += 1
    }
}
