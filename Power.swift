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

    /// One admin prompt. Returns an error message, or nil on success.
    static func installHelper() -> String? {
        let quote = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "do shell script \"/bin/sh \" & quoted form of \"\(quote(bundledPath))\" & \" install \" & quoted form of \"\(quote(NSUserName()))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { return error[NSAppleScript.errorMessage] as? String ?? "Helper install failed." }
        return helperReady ? nil : "Helper install didn't complete."
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
