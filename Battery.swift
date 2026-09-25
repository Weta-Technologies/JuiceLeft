import AppKit
import IOKit.ps
import ServiceManagement

/// One look at the battery. `percent`, `onAC`, `charging`, `full` and macOS's own time estimate come from
/// IOPowerSources (the same numbers as the menu bar's battery); everything else is the gas gauge's own figures
/// from the AppleSmartBattery registry entry. No root needed.
struct Reading: Equatable {
    var at: Date
    var percent: Int
    var onAC: Bool
    var charging: Bool
    var full: Bool
    var lowPowerMode = false
    var osMinutesLeft: Int?         // macOS's time to empty (on battery) or to full (charging); nil = it doesn't know
    var maxCapacity: Double?        // Apple's own health figure: a percent on Apple Silicon (what System Settings shows), mAh on Intel
    var rawCurrent: Double?         // mAh in the cells now
    var rawMax: Double?             // mAh a full charge holds today (varies with temperature and load)
    var cellCapacity: Double?       // mAh the cells can hold, the gauge's Qmax
    var designCapacity: Double?     // mAh a full charge held when new
    var cycles: Int?
    var designCycles: Int?
    var volts: Double?
    var amps: Double?               // + charging, − discharging
    var celsius: Double?
    var adapterWatts: Int?
    var adapterName: String?
    var systemWatts: Double?        // what the whole Mac is drawing, on power or on battery
    var failed = false              // the gas gauge reports a permanent failure

    /// The level the forecast works from: fractional, from the raw capacities, so it moves between whole percents.
    var level: Double {
        if let rawCurrent, let rawMax, rawMax > 0 { return rawCurrent / rawMax * 100 }
        return Double(percent)
    }
    /// Watts flowing into (+) or out of (−) the battery.
    var batteryWatts: Double? {
        guard let volts, let amps else { return nil }
        return volts * amps
    }
    /// The gas gauge's live rate in % of a full charge per hour: − draining, + charging.
    var ratePerHour: Double? {
        guard let amps, let rawMax, rawMax > 0 else { return nil }
        return amps * 1000 / rawMax * 100
    }
    /// Apple's health figure, the one System Settings › Battery shows: MaxCapacity is already a percent on Apple
    /// Silicon; on Intel it is mAh, so it is set against the design capacity. Never the raw full-charge ratio, which
    /// swings with temperature and load and reads several percent low on a healthy battery.
    var health: Double? {
        if let maxCapacity {
            if maxCapacity <= 100 { return maxCapacity }
            if let designCapacity, designCapacity > 0 { return maxCapacity / designCapacity * 100 }
        }
        guard let cellCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return min(cellCapacity / designCapacity * 100, 100)
    }
    var condition: String { failed || (health ?? 100) < 80 ? "Service recommended" : "Normal" }
}

/// Where readings come from: the Mac's battery, or a fake curve under --simulate.
protocol BatterySource: AnyObject {
    /// Called on every power event and every periodic sample. `nil` = no battery in this Mac.
    var onReading: ((Reading?) -> Void)? { get set }
    /// How far apart its samples come; a hole of several of these in the readings means the Mac slept.
    var interval: TimeInterval { get }
    func start()
    func refresh()
}

/// The real battery: IOPowerSources notifications (plug, unplug, every percent) plus a light 30 s sample so the
/// forecast sees the raw capacity move between whole percents. One registry read per sample, nothing in between.
final class LiveBattery: BatterySource {
    var onReading: ((Reading?) -> Void)?
    let interval: TimeInterval = 30
    private var source: CFRunLoopSource?
    private var timer: Timer?

    func start() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<LiveBattery>.fromOpaque(context).takeUnretainedValue().refresh()
        }, me)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 5   // let macOS coalesce it with other wake-ups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() { onReading?(Self.read()) }

    static func read(at now: Date = Date()) -> Reading? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let info = sources.lazy
                .compactMap({ IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any] })
                .first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }),
              let current = info[kIOPSCurrentCapacityKey] as? Int,
              let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
        else { return nil }
        var r = Reading(at: now, percent: current * 100 / max,
                        onAC: info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                        charging: info[kIOPSIsChargingKey] as? Bool ?? false,
                        full: info[kIOPSIsChargedKey] as? Bool ?? false)
        r.lowPowerMode = (info["LPM Active"] as? Int ?? 0) == 1
        let minutes = info[r.charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? -1
        r.osMinutesLeft = minutes > 0 ? minutes : nil

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return r }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = props?.takeRetainedValue() as? [String: Any] else { return r }
        // Signed values (current, when discharging) arrive as the unsigned 64-bit bit pattern; int64Value puts the sign back.
        let num = { (key: String) -> Double? in (p[key] as? NSNumber).map { Double($0.int64Value) } }
        r.maxCapacity = num("MaxCapacity")
        r.rawCurrent = num("AppleRawCurrentCapacity")
        r.rawMax = num("AppleRawMaxCapacity")
        r.designCapacity = num("DesignCapacity")
        if let data = p["BatteryData"] as? [String: Any], let qmax = data["Qmax"] as? [NSNumber], !qmax.isEmpty {
            r.cellCapacity = qmax.map(\.doubleValue).reduce(0, +) / Double(qmax.count)
        }
        r.cycles = p["CycleCount"] as? Int
        r.designCycles = p["DesignCycleCount9C"] as? Int
        r.volts = num("Voltage").map { $0 / 1000 }
        r.amps = (num("Amperage") ?? num("InstantAmperage")).map { $0 / 1000 }
        r.celsius = num("Temperature").map { $0 / 100 }
        r.failed = (p["PermanentFailureStatus"] as? Int ?? 0) != 0
        if r.onAC, let adapter = p["AdapterDetails"] as? [String: Any], let watts = adapter["Watts"] as? Int, watts > 0 {
            r.adapterWatts = watts
            r.adapterName = (adapter["Name"] as? String)?.trimmingCharacters(in: .whitespaces)
        }
        if let telemetry = p["PowerTelemetryData"] as? [String: Any], let mw = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, mw > 0 {
            r.systemWatts = mw / 1000
        }
        return r
    }
}

enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message, or nil on success.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Short, locale-aware strings for the menu bar, the panel and notifications.
enum Format {
    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "2 h 10 m", "2 h", "45 min".
    static func duration(_ minutes: Int) -> String {
        let m = max(minutes, 0)
        guard m >= 60 else { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) m"
    }

    /// VoiceOver-friendly: "2 hours 10 minutes".
    static func spokenDuration(_ minutes: Int) -> String {
        let m = max(minutes, 0), h = m / 60
        let hours = h == 0 ? "" : h == 1 ? "1 hour " : "\(h) hours "
        return hours + (m % 60 == 1 ? "1 minute" : "\(m % 60) minutes")
    }

    /// The menu bar's compact form: "2:10" from an hour up, "45m" under it.
    static func compact(_ minutes: Int) -> String {
        let m = max(minutes, 0)
        return m >= 60 ? String(format: "%d:%02d", m / 60, m % 60) : "\(m)m"
    }

    /// The menu bar's spelled-out form, to the nearest five minutes: "2 Hours 10 Min Remaining", "1 Hour Remaining",
    /// "45 Min Remaining", "Less Than 5 Min Remaining"; charging, "… Until Full".
    static func words(_ minutes: Int, charging: Bool) -> String {
        let suffix = charging ? "Until Full" : "Remaining"
        guard minutes >= 5 else { return "Less Than 5 Min \(suffix)" }
        let m = max(rounded5(minutes), 5)
        var parts: [String] = []
        if m >= 60 { parts.append(m / 60 == 1 ? "1 Hour" : "\(m / 60) Hours") }
        if m % 60 > 0 { parts.append("\(m % 60) Min") }
        return (parts + [suffix]).joined(separator: " ")
    }

    static func rounded5(_ minutes: Int) -> Int { Int((Double(max(minutes, 0)) / 5).rounded()) * 5 }

    static func watts(_ w: Double) -> String { String(format: abs(w) < 10 ? "%.1f W" : "%.0f W", abs(w)) }
}
