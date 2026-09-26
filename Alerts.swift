import AppKit
import UserNotifications

/// The low-battery alert logic, pure so --selftest can walk it down a discharge.
enum Alerts {
    static let hysteresis = 2   // % the level must climb back above a threshold before that alert can fire again

    enum Phase: Equatable { case clear, warning, alert }

    struct State: Equatable {
        var warned = false        // latched at or below the warning level
        var alerted = false       // latched at or below the alert level
        var lastToneAt: Date?
        var snoozedUntil: Date?
    }

    struct Outcome: Equatable {
        var state: State
        var phase: Phase          // what the menu bar shows
        var playTone = false
        var enteredWarning = false
        var enteredAlert = false
    }

    /// Charger in or alerts off: everything clears and re-arms. On battery, each level latches on the way down and
    /// only releases `hysteresis` above it, so a 10 ↔ 11 % bounce can't sound the tone twice. The tone plays once on
    /// entering the alert level, again every `repeatMinutes` (0 = once) while still there, and again when a snooze
    /// runs out; a snooze silences the flash too.
    static func step(_ state: State, armed: Bool, onAC: Bool, percent: Int, warnAt: Int, alertAt: Int, repeatMinutes: Int, now: Date) -> Outcome {
        guard armed, !onAC else { return Outcome(state: State(), phase: .clear) }
        var s = state
        if percent <= warnAt { s.warned = true } else if percent >= warnAt + hysteresis { s.warned = false }
        if percent <= alertAt { s.alerted = true } else if percent >= alertAt + hysteresis { s.alerted = false; s.lastToneAt = nil }
        let enteredWarning = s.warned && !state.warned, enteredAlert = s.alerted && !state.alerted
        if let until = s.snoozedUntil {
            if now < until { return Outcome(state: s, phase: .clear) }
            s.snoozedUntil = nil
            s.lastToneAt = nil
        }
        var play = false
        if s.alerted {
            let due = s.lastToneAt.map { repeatMinutes > 0 && now.timeIntervalSince($0) >= Double(repeatMinutes) * 60 } ?? true
            if due { play = true; s.lastToneAt = now }
        }
        return Outcome(state: s, phase: s.alerted ? .alert : s.warned ? .warning : .clear, playTone: play,
                       enteredWarning: enteredWarning, enteredAlert: enteredAlert)
    }
}

/// The alert sound: JuiceLeft's own chime, or one of macOS's alert sounds. Goes through the normal output at the
/// system volume, scaled by the app's own level.
@MainActor final class Tone {
    nonisolated static let chimeName = "Chime"
    nonisolated static let names = [chimeName, "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    private var playing: NSSound?
    var recorder: ((String, Double) -> Void)?   // --e2e: what would have played, and nothing sounds

    func play(_ name: String, volume: Double) {
        if let recorder { return recorder(name, volume) }
        playing?.stop()
        let sound = name == Self.chimeName ? NSSound(data: Self.chime) : NSSound(named: NSSound.Name(name))
        sound?.volume = Float(max(0, min(1, volume)))
        sound?.play()
        playing = sound
    }

    func stop() { playing?.stop() }

    /// A bell-like "ding-ding-dong" (G5, E5, C5) played twice, rendered once to a WAV in memory.
    static let chime: Data = wav(notes: [(784.0, 0.0), (659.3, 0.3), (523.3, 0.6), (784.0, 1.5), (659.3, 1.8), (523.3, 2.1)], length: 3.3)

    static func wav(notes: [(hz: Double, start: Double)], length: Double, rate: Double = 44_100) -> Data {
        let count = Int(rate * length)
        var samples = [Float](repeating: 0, count: count)
        for note in notes {
            let from = Int(note.start * rate)
            for i in from..<count {
                let t = Double(i - from) / rate
                let envelope = min(t / 0.008, 1) * exp(-t / 0.4)           // 8 ms attack, ~0.4 s ring
                let wave = sin(2 * .pi * note.hz * t) + 0.35 * sin(4 * .pi * note.hz * t) + 0.12 * sin(6 * .pi * note.hz * t)
                samples[i] += Float(envelope * wave * 0.3)
            }
        }
        var data = Data(capacity: 44 + count * 2)
        let le32 = { (v: UInt32) in withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let le16 = { (v: UInt16) in withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + count * 2)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1); le32(UInt32(rate)); le32(UInt32(rate) * 2); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(UInt32(count * 2))
        for s in samples { le16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return data
    }
}

/// macOS notifications. Only touched from inside an app bundle (the framework aborts otherwise), and everything is
/// optional: if the user says no, the flash and the tone still work.
enum Notifier {
    private static var usable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// The notification centre, behind two closures: --e2e records what would be asked and posted, and asks nothing.
    static var authorize: (@escaping (Bool?) -> Void) -> Void = { report in
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            center.getNotificationSettings { settings in
                let allowed: Bool? = settings.authorizationStatus == .notDetermined ? nil : settings.authorizationStatus != .denied
                DispatchQueue.main.async { report(allowed) }
            }
        }
    }
    static var deliver: (_ id: String, _ title: String, _ body: String) -> Void = { id, title, body in
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { NSLog("JuiceLeft: notification failed: \(error.localizedDescription)") }
        }
    }

    /// Asks once, then reports whether notifications are allowed (nil = unknown / not usable).
    static func setUp(_ report: @escaping (Bool?) -> Void) {
        guard usable else { return report(nil) }
        authorize(report)
    }

    static func post(id: String, title: String, body: String) {
        guard usable else { return }
        deliver(id, title, body)
    }
}
