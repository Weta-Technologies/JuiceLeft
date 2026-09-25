import AppKit

/// Apple's own battery item in the menu bar. JuiceLeft stands in for it: on launch it is hidden (the way System
/// Settings › Control Center hides it — the per-host `Battery` value in Control Center's preferences, which Control
/// Center picks up live), and on quit whatever was there before is put back, so nobody is ever left without a
/// battery indicator. The value found before the first hide is remembered, so a user who already had it hidden gets
/// exactly that back.
enum SystemBattery {
    static let domain = "com.apple.controlcenter" as CFString
    static let key = "Battery" as CFString
    static let hidden = 24           // Control Center's "don't show in the menu bar"
    static let originalKey = "systemBatteryOriginal"   // in JuiceLeft's defaults: the value before the first hide

    /// Control Center's current value: nil = never set (shown).
    static var current: Int? {
        (CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? NSNumber)?.intValue
    }

    static var isHidden: Bool { current == hidden }

    static func hide(remembering defaults: UserDefaults) {
        if defaults.object(forKey: originalKey) == nil {
            defaults.set(current ?? -1, forKey: originalKey)   // -1 = the key was absent (the usual case)
        }
        if !isHidden { set(hidden) }
    }

    /// Puts back what was there before JuiceLeft's first hide: nothing, an explicit value, or — if the user had it
    /// hidden themselves — leaves it hidden. `forget` drops the memory, for when the user turns the replacement off.
    static func restore(from defaults: UserDefaults, forget: Bool = false) {
        defer { if forget { defaults.removeObject(forKey: originalKey); defaults.removeObject(forKey: positionedKey) } }
        restorePosition(from: defaults)
        guard let original = defaults.object(forKey: originalKey) as? Int, original != hidden, isHidden else { return }
        set(original == -1 ? nil : original)
    }

    private static func set(_ value: Int?) {
        CFPreferencesSetValue(key, value.map { NSNumber(value: $0) }, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    // MARK: The place in the menu bar

    static let applePositionKey = "NSStatusItem Preferred Position Battery"   // in Control Center's (per-user) domain
    static let ourPositionKey = "NSStatusItem Preferred Position Item-0"      // in JuiceLeft's: read when the status item is made
    static let rememberedPositionKey = "appleBatteryPosition"
    static let positionedKey = "positioned"                                     // the swap has placed the item; ⌘-drags are the user's from then on

    /// Where Apple's item sits: its distance from the right edge of the menu bar.
    static var applePosition: Double? {
        (CFPreferencesCopyAppValue(applePositionKey as CFString, domain) as? NSNumber)?.doubleValue
    }

    /// Puts JuiceLeft's item where Apple's battery item is — once per swap, before the status item exists (or before
    /// it is re-made). Returns true when a position was taken.
    @discardableResult
    static func takePosition(remembering defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: positionedKey), let position = applePosition else { return false }
        defaults.set(position, forKey: ourPositionKey)
        defaults.set(position, forKey: rememberedPositionKey)
        defaults.set(true, forKey: positionedKey)
        return true
    }

    /// Apple's item keeps its own position preference while hidden; should it ever be gone, the remembered one goes back.
    static func restorePosition(from defaults: UserDefaults) {
        guard applePosition == nil, let remembered = defaults.object(forKey: rememberedPositionKey) as? Double else { return }
        CFPreferencesSetAppValue(applePositionKey as CFString, NSNumber(value: remembered), domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// System Settings › Control Center, the manual way back.
    static func openControlCenterSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
    }

    static func openBatterySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
    }
}

/// Apple's own Charge Limit (macOS 26.4+, Apple silicon): the setting behind System Settings › Battery › Charging.
/// Reached through PowerUI's smart-charge client in-process — the same client Apple's UI uses — with no root, no
/// helper and no SMC keys (which newer firmware has removed). The firmware holds the limit and even drains a
/// battery above it down to it. 100 means no limit; below 80 is refused by the system, so those steps aren't offered.
/// `temporarilyDisableMCL:` is Apple's "charge to full now": it lets the battery fill once and is cleared by JuiceLeft
/// at the next unplug (or after a day).
enum ChargeLimit {
    struct State: Equatable {
        var enabled: Bool
        var limit: Int             // 80…100; 100 = no limit
        var available: [Int]
    }

    static let steps = [80, 85, 90, 95, 100]
    static let recommended = 80

    private typealias InitName = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
    private typealias BoolNoArg = @convention(c) (AnyObject, Selector) -> Bool
    private typealias U8Err = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt8
    private typealias U64Err = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt64
    private typealias ObjErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?
    private typealias BoolErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool
    private typealias SetU8Err = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?) -> Bool

    private static let client: NSObject? = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4),
              dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else { return nil }
        let client = cls.init()
        if let (sel, f) = imp(client, "initWithClientName:", InitName.self) { _ = f(client, sel, "JuiceLeft") }
        return client
    }()

    private static func imp<T>(_ object: NSObject, _ name: String, _ type: T.Type) -> (Selector, T)? {
        let sel = NSSelectorFromString(name)
        guard let m = class_getInstanceMethod(Swift.type(of: object), sel) else { return nil }
        return (sel, unsafeBitCast(method_getImplementation(m), to: type))
    }

    /// macOS 26.4+, the framework loads, and the system says this Mac can limit its charge.
    static let supported: Bool = {
        guard let client, let (sel, f) = imp(client, "isMCLSupported", BoolNoArg.self) else { return false }
        return f(client, sel)
    }()

    static func read() -> State? {
        guard supported, let client,
              let (sEnabled, enabled) = imp(client, "isMCLCurrentlyEnabled:", U64Err.self),
              let (sLimit, limit) = imp(client, "getMCLLimitWithError:", U8Err.self) else { return nil }
        var e1: NSError?, e2: NSError?
        let on = enabled(client, sEnabled, &e1) != 0, value = Int(limit(client, sLimit, &e2))
        guard e1 == nil, e2 == nil else { return nil }
        var available = steps
        if let (sAvail, avail) = imp(client, "availableChargeLimitsWithError:", ObjErr.self) {
            var e3: NSError?
            if let list = avail(client, sAvail, &e3) as? [NSNumber], !list.isEmpty { available = list.map(\.intValue) }
        }
        return State(enabled: on, limit: on ? value : 100, available: available)
    }

    /// Sets the limit; 100 turns limiting off. Returns an error message, or nil.
    static func set(_ limit: Int) -> String? {
        guard supported, let client,
              let (sSet, setLimit) = imp(client, "setMCLLimit:error:", SetU8Err.self),
              let (sOn, enable) = imp(client, "enableMCL:", BoolErr.self),
              let (sOff, disable) = imp(client, "disableMCL:", BoolErr.self) else { return "Charge limit isn't available on this Mac." }
        guard limit >= 80, limit <= 100 else { return "macOS only allows limits from 80% to 100%." }
        var error: NSError?
        if limit >= 100 {
            _ = setLimit(client, sSet, 100, &error)
            guard disable(client, sOff, &error) else { return error?.localizedDescription ?? "macOS didn't turn the limit off." }
            return nil
        }
        guard setLimit(client, sSet, UInt8(limit), &error) else { return error?.localizedDescription ?? "macOS didn't accept \(limit)%." }
        guard enable(client, sOn, &error) else { return error?.localizedDescription ?? "macOS didn't turn the limit on." }
        return nil
    }

    /// Apple's "charge to full now": one full charge, the limit untouched.
    static func fullNow() -> String? {
        guard supported, let client, let (sel, f) = imp(client, "temporarilyDisableMCL:", BoolErr.self) else { return "Charge limit isn't available on this Mac." }
        var error: NSError?
        return f(client, sel, &error) ? nil : error?.localizedDescription ?? "macOS didn't allow a full charge right now."
    }
}

/// Energy modes — Low Power, Automatic, High Power — the same `pmset powermode` System Settings › Battery sets, per
/// power source. Reading is free (`pmset -g custom`); setting needs root, so it goes through juiceleft-helper.sh: a
/// root launchd job installed once with an admin prompt that applies a one-line request file (`b 1` = battery, low
/// power; `c 2` = adapter, high power) and lets nothing else through to pmset.
enum PowerMode {
    enum Mode: Int, CaseIterable, Identifiable {
        case automatic = 0, low = 1, high = 2
        var id: Int { rawValue }
        var name: String { switch self { case .low: return "Low Power"; case .automatic: return "Automatic"; case .high: return "High Power" } }
    }

    struct State: Equatable {
        var battery: Mode?
        var adapter: Mode?
        var highPowerSupported = false
    }

    private static let requestPath = "/Library/Application Support/JuiceLeft/powermode"
    private static let installedPath = "/Library/PrivilegedHelperTools/io.github.cyborgfingers.juiceleft.power.sh"
    private static var bundledPath: String { Bundle.main.path(forResource: "juiceleft-helper", ofType: "sh") ?? "" }

    /// Pure: `pmset -g custom` and `pmset -g cap` output → the modes per source.
    static func parse(custom: String, capabilities: String) -> State {
        var state = State(highPowerSupported: capabilities.contains("highpowermode"))
        var section = ""
        for line in custom.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") { section = trimmed; continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0] == "powermode", let value = Int(parts[1]), let mode = Mode(rawValue: value) else { continue }
            if section.hasPrefix("Battery") { state.battery = mode } else if section.hasPrefix("AC") { state.adapter = mode }
        }
        return state
    }

    static func read() -> State {
        parse(custom: run(["-g", "custom"]), capabilities: run(["-g", "cap"]))
    }

    private static func run(_ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: The helper

    /// Installed, the same version as this build, and the request file is ours to write.
    static var helperReady: Bool {
        FileManager.default.contentsEqual(atPath: installedPath, andPath: bundledPath)
            && FileManager.default.isWritableFile(atPath: requestPath)
    }

    /// Some version of the helper is installed (so a signed self-update is possible when it isn't this one).
    static var helperInstalled: Bool { FileManager.default.fileExists(atPath: installedPath) }

    /// The one admin prompt (password or Touch ID): installs everything JuiceLeft ever needs as root.
    static func installHelper() -> Admin.Outcome {
        let outcome = Admin.run(bundledPath, ["install", NSUserName()], prompt: "JuiceLeft needs to install its helper for energy modes and the charging light. This is the only time it will ask.")
        return outcome == .done && !helperReady ? .failed("The helper didn't install.") : outcome
    }

    /// The request line the helper accepts: exactly "b 0" … "c 2".
    static func request(_ mode: Mode, onBattery: Bool) -> String { "\(onBattery ? "b" : "c") \(mode.rawValue)" }

    /// Asks the helper to set `mode` for the active source. Returns an error message, or nil.
    static func set(_ mode: Mode, onBattery: Bool) -> String? {
        // atomically: false — the helper's folder is root-owned, so our file is rewritten in place.
        do { try (request(mode, onBattery: onBattery) + "\n").write(toFile: requestPath, atomically: false, encoding: .utf8) }
        catch { return "Couldn't hand the request to the helper: \(error.localizedDescription)" }
        return nil
    }
}
