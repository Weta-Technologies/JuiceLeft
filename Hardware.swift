import AppKit
import IOKit

/// The bits of the Mac that Save Battery, the brightness cap and the tips touch or read. Behind a protocol so the
/// screenshot harness and --simulate never dim a real screen.
protocol Hardware: AnyObject {
    func brightness() -> Float?
    func setBrightness(_ value: Float)
    func keyboard() -> KeyboardLight.Level?
    func setKeyboard(_ level: KeyboardLight.Level)
    func ambientLight() -> Double?
    func usbDevices() -> [USBPower.Device]
}

final class RealHardware: Hardware {
    func brightness() -> Float? { Brightness.get() }
    func setBrightness(_ value: Float) { Brightness.set(value) }
    func keyboard() -> KeyboardLight.Level? { KeyboardLight.get() }
    func setKeyboard(_ level: KeyboardLight.Level) { KeyboardLight.set(level) }
    func ambientLight() -> Double? { AmbientLight.level() }
    func usbDevices() -> [USBPower.Device] { USBPower.external() }
}

/// What the harness and --simulate use: a screen at 85 %, keyboard light on, a lit room, one hungry USB device.
final class FakeHardware: Hardware {
    var level: Float = 0.85
    var keys = KeyboardLight.Level(brightness: 0.5, auto: true)
    var lux = 320.0
    var devices = [USBPower.Device(name: "Portable SSD", milliamps: 900)]
    var log: [String] = []
    func brightness() -> Float? { level }
    func setBrightness(_ value: Float) { level = value; log.append("brightness \(value)") }
    func keyboard() -> KeyboardLight.Level? { keys }
    func setKeyboard(_ level: KeyboardLight.Level) {   // the same rule as the real backlight: a suppressed 0 is never written
        let write = KeyboardLight.writes(level)
        keys = KeyboardLight.Level(brightness: write.brightness ?? keys.brightness, auto: write.auto)
        log.append("keyboard \(write.brightness.map { "\($0)" } ?? "kept") auto \(write.auto)")
    }
    func ambientLight() -> Double? { lux }
    func usbDevices() -> [USBPower.Device] { devices }
}

// Built-in screen brightness via private DisplayServices (what the brightness keys use).
enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn = dlsym(lib, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
    private static let setFn = dlsym(lib, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }

    private static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static func get() -> Float? {
        var value: Float = 0
        guard let getFn, getFn(display, &value) == 0 else { return nil }
        return value
    }

    static func set(_ value: Float) {
        guard let setFn, setFn(display, value) == 0 else { return NSLog("JuiceLeft: brightness set failed") }
    }
}

// Built-in keyboard backlight via private CoreBrightness (what the keyboard-brightness keys use).
enum KeyboardLight {
    struct Level: Codable, Equatable {
        var brightness: Float
        var auto: Bool   // ambient-light adjustment
    }

    private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }()
    private static let keyboard: UInt64? = (client?.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?
        .takeRetainedValue() as? [NSNumber])?.first?.uint64Value

    private static func method<F>(_ name: String, _ type: F.Type) -> (NSObject, Selector, UInt64, F)? {
        let selector = NSSelectorFromString(name)
        guard let client, let keyboard, let m = class_getInstanceMethod(Swift.type(of: client), selector) else { return nil }
        return (client, selector, keyboard, unsafeBitCast(method_getImplementation(m), to: F.self))
    }

    static func get() -> Level? {
        guard let (c, s, k, brightness) = method("brightnessForKeyboard:", (@convention(c) (AnyObject, Selector, UInt64) -> Float).self),
              let (_, s2, _, isAuto) = method("isAutoBrightnessEnabledForKeyboard:", (@convention(c) (AnyObject, Selector, UInt64) -> Bool).self)
        else { return nil }
        return Level(brightness: brightness(c, s, k), auto: isAuto(c, s2, k))
    }

    /// What putting a level back writes: the brightness — unless the level was captured while macOS had the backlight
    /// suppressed (0 with auto on): writing that 0 would become the user's preference and leave the keyboard dark, so
    /// only auto comes back and macOS picks the brightness itself. Pure, for --selftest.
    static func writes(_ level: Level) -> (brightness: Float?, auto: Bool) {
        (level.auto && level.brightness == 0 ? nil : level.brightness, level.auto)
    }

    static func set(_ level: Level) {
        guard let (c, s, k, setBrightness) = method("setBrightness:forKeyboard:", (@convention(c) (AnyObject, Selector, Float, UInt64) -> Bool).self),
              let (_, s2, _, enableAuto) = method("enableAutoBrightness:forKeyboard:", (@convention(c) (AnyObject, Selector, Bool, UInt64) -> Void).self)
        else { return NSLog("JuiceLeft: keyboard backlight unavailable") }
        let write = writes(level)
        if !write.auto { enableAuto(c, s2, false, k) }   // off first, so ambient light can't pull it back up
        if let brightness = write.brightness, !setBrightness(c, s, brightness, k) { NSLog("JuiceLeft: keyboard backlight set failed") }
        if write.auto { enableAuto(c, s2, true, k) }
    }
}

/// The ambient light sensor, through the HID event system (an Apple-vendor usage on Apple silicon). Roughly lux:
/// a lit room reads a couple of hundred. Nil on Macs without the sensor.
enum AmbientLight {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias IntValue = @convention(c) (AnyObject, Int32) -> Int64
    private static let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func sym<T>(_ name: String, _ type: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: type) } }
    private static let eventType: Int64 = 12                  // kIOHIDEventTypeAmbientLightSensor
    private static let levelField: Int32 = 12 << 16           // kIOHIDEventFieldAmbientLightSensorLevel

    /// The event-system client must outlive the service it handed out — releasing it while the service is still in
    /// use crashes IOKit on a background queue later — so both are kept for the life of the app.
    private static let handles: (client: AnyObject, service: AnyObject)? = {
        guard let create = sym("IOHIDEventSystemClientCreate", Create.self), let match = sym("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let services = sym("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        match(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 4] as CFDictionary)
        guard let service = (services(client)?.takeRetainedValue() as? [AnyObject])?.first else { return nil }
        return (client, service)
    }()

    static func level() -> Double? {
        guard let service = handles?.service, let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEvent.self), let value = sym("IOHIDEventGetIntegerValue", IntValue.self),
              let event = copyEvent(service, eventType, 0, 0)?.takeRetainedValue() else { return nil }
        return Double(value(event, levelField))
    }
}

/// External USB devices and what they draw from the bus, for the tips. Apple's own built-in devices are skipped.
enum USBPower {
    struct Device: Equatable { var name: String; var milliamps: Int }

    /// Pure: one registry entry's properties → a device, or nil for the Mac's own built-in parts (matched by the names they report over USB) and the unnamed.
    static func parse(_ p: [String: Any]) -> Device? {
        guard let name = (p["USB Product Name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if (p["Built-In"] as? Bool) == true { return nil }
        if (p["idVendor"] as? Int) == 0x05ac, ["Ambient Light Sensor", "Apple T2", "Touch Bar", "FaceTime", "Headset", "Keyboard Backlight"].contains(where: name.contains) { return nil }
        let mA = (p["UsbPowerSinkAllocation"] as? Int) ?? (p["kUSBBusCurrentAllocation"] as? Int) ?? ((p["bMaxPower"] as? Int).map { $0 * 2 }) ?? 0
        return Device(name: name, milliamps: mA)
    }

    static func external() -> [Device] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [Device] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let p = props?.takeRetainedValue() as? [String: Any], let device = parse(p) else { continue }
            devices.append(device)
        }
        return devices.sorted { $0.milliamps > $1.milliamps }
    }
}
