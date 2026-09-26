import Foundation

/// The `juiceleft://` URL scheme, for Shortcuts and scripts. A tight whitelist: the host names the command, and the
/// only accepted query is a single validated on/off or mode. Anything else — an unknown host, a stray parameter, a
/// bad value — parses to nil and does nothing. Pure, so --selftest can throw hostile input at it.
enum URLAction: Equatable {
    case saveBattery(Bool)               // juiceleft://savebattery?on=1  (on=0 = Undo)
    case setMode(PowerMode.Mode)         // juiceleft://mode?set=low|automatic|high
    case topUp                           // juiceleft://topup            (charge to full once)
    case setArmed(Bool)                  // juiceleft://monitoring?on=0
    case snooze                          // juiceleft://snooze

    static let scheme = "juiceleft"

    static func parse(_ url: URL) -> URLAction? {
        guard url.scheme?.lowercased() == scheme, let host = url.host?.lowercased() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func only(_ name: String) -> String? {   // exactly one query item, and it is `name`
            guard items.count == 1, let item = items.first, item.name.lowercased() == name else { return nil }
            return item.value
        }
        func bool(_ name: String) -> Bool? {
            switch only(name)?.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        }
        switch host {
        case "savebattery": return bool("on").map(URLAction.saveBattery)
        case "monitoring": return bool("on").map(URLAction.setArmed)
        case "mode":
            switch only("set")?.lowercased() {
            case "low": return .setMode(.low)
            case "automatic", "auto": return .setMode(.automatic)
            case "high": return .setMode(.high)
            default: return nil
            }
        case "topup": return items.isEmpty ? .topUp : nil
        case "snooze": return items.isEmpty ? .snooze : nil
        default: return nil
        }
    }
}
