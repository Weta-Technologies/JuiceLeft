import Foundation
import IOKit

/// The batteries of the Bluetooth accessories paired with this Mac — a wireless mouse, keyboard or trackpad — read
/// straight from the IORegistry (the `AppleDeviceManagementHIDEventService` entries expose `BatteryPercent`). No
/// permission, no private Bluetooth APIs, nothing stored: read live for the panel and, if the user asks, to warn
/// when one runs low. AirPods and other audio devices don't publish a level here, so they aren't listed.
enum AccessoryBattery {
    enum Kind: String, Equatable { case mouse, keyboard, trackpad, other }

    struct Device: Identifiable, Equatable {
        var id: String        // the device address, or the name if it has none
        var name: String
        var percent: Int      // 0…100
        var kind: Kind
    }

    /// Pure: one registry entry's properties → a device, or nil when it carries no usable battery level. Only
    /// Bluetooth accessories (built-in keyboards and trackpads report over SPI/USB and are skipped).
    static func parse(_ p: [String: Any]) -> Device? {
        guard let percent = (p["BatteryPercent"] as? NSNumber)?.intValue, percent > 0, percent <= 100 else { return nil }
        let transport = (p["Transport"] as? String ?? p["DeviceTransport"] as? String ?? "")
        guard transport.isEmpty || transport.lowercased().contains("bluetooth") else { return nil }
        let name = ((p["Product"] as? String) ?? (p["Name"] as? String) ?? (p["BD_ADDR"] as? String))?
            .trimmingCharacters(in: .whitespaces)
        guard let name, !name.isEmpty else { return nil }
        let id = ((p["DeviceAddress"] as? String) ?? (p["BD_ADDR"] as? String) ?? name)
        return Device(id: id, name: name, percent: percent, kind: kind(for: name))
    }

    static func kind(for name: String) -> Kind {
        let n = name.lowercased()
        if n.contains("trackpad") { return .trackpad }
        if n.contains("mouse") { return .mouse }
        if n.contains("keyboard") { return .keyboard }
        return .other
    }

    /// The registry walk, as a closure: --e2e hands in made-up accessories instead.
    static var scan: () -> [Device] = { registry() }

    /// The connected accessories with a battery level, most-drained first.
    static func read() -> [Device] { scan() }

    private static func registry() -> [Device] {
        var found: [String: Device] = [:]
        for service in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(service), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let p = props?.takeRetainedValue() as? [String: Any], let device = parse(p) else { continue }
                found[device.id] = device   // one entry per device wins; the same device can appear under both services
            }
        }
        return found.values.sorted { $0.percent != $1.percent ? $0.percent < $1.percent : $0.name < $1.name }
    }
}

/// Which low accessories to warn about right now, once each until it recovers. Pure so --selftest can walk it.
struct DeviceAlerts: Equatable {
    var alerted: Set<String> = []   // device ids notified and still low
    static let hysteresis = 5       // % it must climb back above the level before it can warn again

    /// Mutates the latch and returns the devices that just crossed below `level` (and so should be notified now).
    mutating func due(_ devices: [AccessoryBattery.Device], level: Int) -> [AccessoryBattery.Device] {
        var fire: [AccessoryBattery.Device] = []
        for d in devices {
            if d.percent <= level, !alerted.contains(d.id) { alerted.insert(d.id); fire.append(d) }
            else if d.percent >= level + Self.hysteresis { alerted.remove(d.id) }
        }
        alerted.formIntersection(Set(devices.map(\.id)))   // forget devices that have gone away
        return fire
    }
}
