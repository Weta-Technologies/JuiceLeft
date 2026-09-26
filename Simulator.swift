import Foundation

/// `--simulate [hold]`: a fake battery that drains 1 % a second from 26 %, so the warning flash at 20 %, the tone at
/// 10 % and the charger-connected reset can all be watched without draining anything. Each real second is two
/// simulated minutes, so the forecast sees a 30 %/h discharge. `hold` parks it at 15 % (flashing) for CPU
/// measurements. Runs with its own settings domain and history file, never the real ones, on a FakeMac.
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

/// What JuiceLeft can change on the Mac besides the screen and keyboard (FakeHardware has those) — energy modes and
/// the charging light through the installed helper, Apple's charge limit, the menu-bar battery item's preferences —
/// as stand-ins that only remember what they were asked. --simulate, --selftest and --e2e run on one, so none of them
/// can reach the real helper, limit or menu bar; the battery readings stay real (or simulated).
final class FakeMac {
    var prefs: [String: Any] = [SystemBattery.applePositionKey: NSNumber(value: 178)]   // the battery item's preferences
    var power = PowerMode.State(battery: .automatic, adapter: .automatic, highPowerSupported: true)
    var powerRequests: [String] = []
    var helperReady = true
    var helperInstalled = false        // never "installed but stale", so nothing asks the real helper to update itself
    var installOutcome = Admin.Outcome.done
    var installs = 0
    var limit: ChargeLimit.State? = ChargeLimit.State(enabled: false, limit: 100, available: ChargeLimit.steps)   // nil: can't limit
    var limitSets: [Int] = []
    var topUps = 0
    var magSafe: Bool?                 // nil: no MagSafe port; else whether power is coming in through it
    var lightReady = true
    var lightLines: [String] = []

    @MainActor func install() {
        SystemBattery.read = { key, _ in self.prefs[key] }
        SystemBattery.write = { key, value, _ in self.prefs[key] = value }
        PowerMode.ready = { self.helperReady }
        PowerMode.installed = { self.helperInstalled }
        PowerMode.reader = { self.power }
        PowerMode.writer = { line in
            self.powerRequests.append(line)
            let parts = line.split(separator: " ")   // what the helper does with "b|c 0|1|2"
            if parts.count == 2, let mode = Int(parts[1]).flatMap(PowerMode.Mode.init(rawValue:)) {
                if parts[0] == "b" { self.power.battery = mode } else { self.power.adapter = mode }
            }
            return nil
        }
        PowerMode.installer = {
            self.installs += 1
            if self.installOutcome == .done { self.helperReady = true; self.lightReady = true }
            return self.installOutcome
        }
        ChargeLimit.isSupported = { self.limit != nil }
        ChargeLimit.reader = { self.limit }
        ChargeLimit.writer = { value in
            self.limitSets.append(value)
            self.limit = ChargeLimit.State(enabled: value < 100, limit: value, available: ChargeLimit.steps)
            return nil
        }
        ChargeLimit.topUp = { self.topUps += 1; return nil }
        LightController.portExists = { self.magSafe != nil }
        LightController.portActive = { self.magSafe == true }
        LightController.isReady = { self.lightReady }
        LightController.send = { self.lightLines.append($0) }
    }
}
