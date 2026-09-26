import AppKit
import IOKit

/// The MagSafe charging light. The hardware drives every pattern (no software blinking, no cost), through the SMC
/// key ACLC, which only root may write: the app leaves a one-line request for the helper, which runs juiceleft-led.
/// Rules, all pure: while charging through MagSafe, a slow orange blink for the first ten seconds and then steady
/// orange (or blink throughout, or Apple's own behaviour); a fast blink while charging from at or below the alert
/// level; green when full or held at the charge limit. Never driven with the lid closed (SleepLess owns it then),
/// re-asserted two seconds after the lid opens, handed back — the right colour first, then 0 — on quit, when
/// switched off, and when the charger isn't MagSafe.
enum MagSafeLight {
    enum Colour: Int, Codable, CaseIterable {
        case macOS = 0, off = 1, green = 3, orange = 4, flash = 5, slowBlink = 6, fastBlink = 7
        var name: String {
            switch self {
            case .macOS: return "macOS's choice"
            case .off: return "off"
            case .green: return "green"
            case .orange: return "orange"
            case .flash: return "flashing"
            case .slowBlink: return "slow orange blink"
            case .fastBlink: return "fast orange blink"
            }
        }
    }

    enum Behaviour: String, Codable, CaseIterable {
        case blinkThenSteady, blink, apple
        var name: String {
            switch self {
            case .blinkThenSteady: return "Blink, then steady"
            case .blink: return "Blink"
            case .apple: return "Apple's default"
            }
        }
    }

    struct Inputs: Equatable {
        var enabled = true
        var onMagSafe = false
        var charging = false
        var percent = 100
        var alertAt = 10
        var secondsSincePlug: TimeInterval = 0
        var lidClosed = false
        var behaviour = Behaviour.blinkThenSteady
        var greenAtLimit = true
        var fastWhenLow = true
    }

    static let blinkFor: TimeInterval = 10
    static let reassertAfter: TimeInterval = 2

    /// What the light should show; nil = leave it to macOS (hand back if we were holding it).
    static func desired(_ i: Inputs) -> Colour? {
        guard i.enabled, i.onMagSafe, !i.lidClosed else { return nil }
        if i.charging {
            if i.fastWhenLow, i.percent <= i.alertAt { return .fastBlink }
            switch i.behaviour {
            case .apple: return nil
            case .blink: return .slowBlink
            case .blinkThenSteady: return i.secondsSincePlug < blinkFor ? .slowBlink : .orange
            }
        }
        return i.greenAtLimit ? .green : nil   // on the charger and not charging: full, or held at the charge limit
    }

    /// The helper's request line: a colour, or the hand-back — the colour macOS expects (orange charging, green
    /// otherwise), then 0, because 0 alone leaves the last colour latched. On battery the light is dark anyway.
    static func request(_ colour: Colour?, onAC: Bool, charging: Bool) -> String {
        if let colour { return "\(colour.rawValue)" }
        guard onAC else { return "0" }
        return charging ? "4 0" : "3 0"
    }
}

/// The MagSafe port in the registry: whether this Mac has one, and whether power is coming through it.
enum MagSafePort {
    private static let entry: UInt64? = {
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let description = IORegistryEntryCreateCFProperty(service, "PortDescription" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  description.hasPrefix("Port-MagSafe") else { continue }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            return id
        }
        return nil
    }()

    static var exists: Bool { entry != nil }

    /// Power is coming in through MagSafe right now.
    static var active: Bool {
        guard let entry else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(entry))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "ConnectionActive" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }
}

/// The lid, from IOPMrootDomain, with a change callback that costs nothing between changes.
final class Lid {
    private static let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    private var port: IONotificationPortRef?
    private var iterator: io_object_t = 0
    var changed: ((Bool) -> Void)?
    private(set) var closed = Lid.read()

    static func read() -> Bool {
        IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }

    init() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        if IOServiceAddInterestNotification(port, Self.root, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            let lid = Unmanaged<Lid>.fromOpaque(context).takeUnretainedValue()
            let now = Lid.read()
            guard now != lid.closed else { return }
            lid.closed = now
            lid.changed?(now)
        }, me, &iterator) == KERN_SUCCESS {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        }
    }
}

/// Holds the light at what the rules ask for, writing a request only when that changes (and once more, two
/// seconds after the lid opens, since SleepLess hands the light back on its own way out).
@MainActor final class LightController: ObservableObject {
    /// The port, the helper and the request file, as closures: FakeMac stands in for them and the real light is never touched.
    static var portExists: () -> Bool = { MagSafePort.exists }
    static var portActive: () -> Bool = { MagSafePort.active }
    static var isReady: () -> Bool = {
        PowerMode.helperReady && FileManager.default.contentsEqual(atPath: toolPath, andPath: bundledTool) && FileManager.default.isWritableFile(atPath: requestPath)
    }
    static var send: (String) throws -> Void = { line in
        try (line + "\n").write(toFile: requestPath, atomically: false, encoding: .utf8)   // rewritten in place: the folder is root's
    }

    @Published private(set) var onMagSafe = LightController.portActive()
    @Published private(set) var holding: MagSafeLight.Colour?      // what we last asked for; nil = macOS has it
    @Published private(set) var needsSetup = false                  // the helper isn't installed or isn't this version
    let available = LightController.portExists()
    var refresh: (() -> Void)?                                      // the monitor re-evaluates (timers, lid)
    var log: ((String) -> Void)?
    private let lid = Lid()
    private var pluggedAt: Date?
    private var blinkTimer: Timer?
    private var reassertTimer: Timer?
    private var force = false
    private var lastInputs: MagSafeLight.Inputs?
    static let requestPath = "/Library/Application Support/JuiceLeft/led"
    static let toolPath = "/Library/PrivilegedHelperTools/io.github.cyborgfingers.juiceleft.led"
    static var bundledTool: String { Bundle.main.path(forResource: "juiceleft-led", ofType: nil) ?? "" }

    /// The tool is installed, is this build's, and the request file is ours to write (the script is checked by PowerMode).
    static var ready: Bool { isReady() }

    var lidClosed: Bool { lid.closed }

    init() {
        lid.changed = { [weak self] closed in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log?("lid \(closed ? "closed" : "opened")")
                self.reassertTimer?.invalidate()
                if closed { self.refresh?(); return }
                let timer = Timer(timeInterval: MagSafeLight.reassertAfter, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.force = true; self?.refresh?() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.reassertTimer = timer
            }
        }
    }

    /// The charger went in or out.
    func plugChanged(onAC: Bool, at now: Date) {
        onMagSafe = onAC && Self.portActive()
        pluggedAt = onAC ? now : nil
        blinkTimer?.invalidate()
        guard onAC else { return }
        let timer = Timer(timeInterval: MagSafeLight.blinkFor + 0.2, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.refresh?() } }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    /// Every evaluation: work out the colour and write only if it moved (or the lid just opened).
    func update(enabled: Bool, onAC: Bool, charging: Bool, percent: Int, alertAt: Int, behaviour: MagSafeLight.Behaviour,
                greenAtLimit: Bool, fastWhenLow: Bool, now: Date) {
        guard available else { return }
        if pluggedAt == nil, onAC { pluggedAt = now.addingTimeInterval(-MagSafeLight.blinkFor); onMagSafe = Self.portActive() }   // already plugged in at launch: no blink
        let inputs = MagSafeLight.Inputs(enabled: enabled, onMagSafe: onMagSafe, charging: charging, percent: percent, alertAt: alertAt,
                                         secondsSincePlug: pluggedAt.map { now.timeIntervalSince($0) } ?? 0, lidClosed: lid.closed,
                                         behaviour: behaviour, greenAtLimit: greenAtLimit, fastWhenLow: fastWhenLow)
        lastInputs = inputs
        let wanted = MagSafeLight.desired(inputs)
        if lid.closed { return }                                    // SleepLess has the light while the lid is shut
        guard wanted != holding || force else { return }
        force = false
        guard wanted != nil || holding != nil else { return }       // never held it, nothing to hand back
        write(MagSafeLight.request(wanted, onAC: onAC, charging: charging), holding: wanted)
    }

    /// Quit, or the feature switched off: the colour macOS expects, then 0.
    func handBack(onAC: Bool, charging: Bool) {
        guard holding != nil else { return }
        write(MagSafeLight.request(nil, onAC: onAC, charging: charging), holding: nil)
    }

    private func write(_ line: String, holding: MagSafeLight.Colour?) {
        guard Self.ready else {
            if !needsSetup { needsSetup = true; log?("light: helper needs setting up") }
            return
        }
        do {
            try Self.send(line)
            self.holding = holding
            needsSetup = false
            log?("light → \(line)")
        } catch {
            needsSetup = true
        }
    }
}
