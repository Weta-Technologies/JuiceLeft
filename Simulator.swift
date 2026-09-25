import Foundation

/// `--simulate [hold]`: a fake battery that drains 1 % a second from 26 %, so the warning flash at 20 %, the tone at
/// 10 % and the charger-connected reset can all be watched without draining anything. Each real second is two
/// simulated minutes, so the forecast sees a 30 %/h discharge. `hold` parks it at 15 % (flashing) for CPU
/// measurements. Runs with its own settings domain and history file, never the real ones.
final class Simulator: BatterySource {
    var onReading: ((Reading?) -> Void)?
    static let minutesPerTick = 2.0
    let interval: TimeInterval = minutesPerTick * 60   // in simulated time
    static let rawMax = 5895.0
    private let hold: Bool
    private var percent = 26.0
    private var onAC = false
    private var clock = Date()
    private var timer: Timer?

    init(hold: Bool) { self.hold = hold }

    func start() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() { onReading?(reading()) }

    private func tick() {
        clock = clock.addingTimeInterval(Self.minutesPerTick * 60)
        if onAC {
            percent = min(100, percent + 2)
        } else if !(hold && percent <= 15) {
            percent -= 1
            if percent <= 4 { onAC = true }
        }
        refresh()
    }

    private func reading() -> Reading {
        let drain = -(30.0 / 100) * Self.rawMax / 1000   // amps for a 30 %/h drain
        var r = Reading(at: clock, percent: Int(percent), onAC: onAC, charging: onAC && percent < 100, full: onAC && percent >= 100)
        r.osMinutesLeft = onAC ? Int((100 - percent) / 60 * 60) : Int(percent * 2 * 1.3)   // macOS's "guess", a bit pessimistic
        r.maxCapacity = 100
        r.rawCurrent = percent / 100 * Self.rawMax
        r.rawMax = Self.rawMax
        r.cellCapacity = 6460
        r.designCapacity = 6249
        r.cycles = 132
        r.designCycles = 1000
        r.volts = 11.9 + percent / 100 * 1.1
        r.amps = onAC ? 2.4 : drain
        r.celsius = onAC ? min(31.2 + (percent - 4) * 0.25, 38) : 31.2   // warms up on the charger, past the 35 °C nudge
        r.systemWatts = onAC ? 18.3 : 21.1
        if onAC { r.adapterWatts = 68; r.adapterName = "70W USB-C Power Adapter" }
        return r
    }
}
