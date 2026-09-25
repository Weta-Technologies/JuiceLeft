import SwiftUI

/// The two levels, the tone, and what happens at each — behind a disclosure; the header line carries the state and,
/// while the item is flashing or sounding, the Snooze button.
struct AlertsCard: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("alertsExpanded") private var expanded = false
    private let repeats = [(0, "Once"), (2, "Every 2 min"), (5, "Every 5 min"), (10, "Every 10 min")]

    init(monitor: Monitor) {
        self.monitor = monitor
        _expanded = AppStorage(wrappedValue: false, "alertsExpanded", store: monitor.defaults)
    }

    private var animation: Animation? { reduceMotion ? nil : panelEase }

    private var subtitle: String {
        guard monitor.s.armed else { return "Off: nothing flashes or sounds" }
        if let until = monitor.snoozedUntil { return "Quiet until \(Format.clock(until))" }
        switch monitor.phase {
        case .alert: return "Sounding: at or below \(monitor.s.alertAt)%"
        case .warning: return "Flashing: at or below \(monitor.s.warnAt)%"
        case .clear: return "Flash red at \(monitor.s.warnAt)% · tone at \(monitor.s.alertAt)%"
        }
    }

    private var notificationNote: String {
        monitor.notificationsAllowed == false ? "Turned off for JuiceLeft in System Settings › Notifications" : "With the time to flat"
    }

    var body: some View {
        Card(title: "Low-battery alerts", subtitle: subtitle, symbol: "bell.badge.fill", tint: .red, lit: monitor.s.armed,
             expanded: $expanded, help: "The warning flash, the tone, and how they behave. Monitoring itself is the switch at the top.", trailing: {
            if monitor.snoozedUntil != nil {
                Button("Resume") { withAnimation(animation) { monitor.resume() } }.controlSize(.small)
                    .help("Bring the flash and the tone back now.")
            } else if monitor.phase != .clear {
                Button("Snooze") { withAnimation(animation) { monitor.snooze() } }.controlSize(.small)
                    .help("Quiet the flash and the tone for 30 minutes. They come back if the battery is still low.")
                    .accessibilityLabel("Snooze alerts for 30 minutes")
            }
        }) {
            Divider()
            LevelRow(title: "Flash red at", value: Binding(get: { monitor.s.warnAt }, set: { monitor.s.warnAt = $0 }), range: 5...50,
                     help: "On battery, at this level the menu-bar item starts pulsing red until you plug in.")
            LevelRow(title: "Play tone at", value: Binding(get: { monitor.s.alertAt }, set: { monitor.s.alertAt = $0 }), range: 1...monitor.s.warnAt,
                     help: "At this level the tone plays. It never re-fires on a one-percent bounce, and stops the moment the charger goes in.")
            HStack(spacing: 8) {
                Text("Tone").font(.callout).frame(width: 92, alignment: .leading)
                Picker("Tone", selection: $monitor.s.tone) {
                    ForEach(Tone.names, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("JuiceLeft's own chime, or one of macOS's alert sounds.")
                Button { monitor.testTone() } label: { Label("Test", systemImage: "play.fill") }
                    .help("Play the tone once now, at this volume.")
                    .accessibilityLabel("Test the tone")
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Volume").font(.callout).frame(width: 92, alignment: .leading)
                Image(systemName: "speaker.fill").foregroundStyle(.secondary).imageScale(.small).accessibilityHidden(true)
                Slider(value: $monitor.s.volume, in: 0...1) { Text("Volume") }.labelsHidden().controlSize(.small)
                    .help("How loud, within the system volume.")
                    .accessibilityValue("\(Int((monitor.s.volume * 100).rounded())) percent")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).imageScale(.small).accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                Text("Repeat").font(.callout).frame(width: 92, alignment: .leading)
                Picker("Repeat", selection: $monitor.s.repeatMinutes) {
                    ForEach(repeats, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().fixedSize()
                .help("Play the tone again this often while the battery stays at or below the tone level, until the charger goes in.")
                Spacer()
            }
            SwitchRow(title: "Notification", subtitle: notificationNote,
                      help: "Also post a macOS notification at each level, with the time to flat.",
                      isOn: $monitor.s.notify)
        }
        .animation(animation, value: monitor.phase)
    }
}

/// A slider for a percent level with its value beside it.
struct LevelRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let help: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.callout).frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1) { Text(title) }
                .labelsHidden().controlSize(.small)
                .accessibilityValue("\(value) percent")
            Text("\(value)%").font(.callout).monospacedDigit().frame(width: 38, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .help(help)
    }
}

/// The five apps using the most processor time right now, each with a Quit button.
struct EnergyCard: View {
    @ObservedObject var meter: EnergyMeter

    private var subtitle: String {
        if meter.apps.isEmpty { return meter.measuring ? "Measuring your apps…" : "Nothing busy right now" }
        return "Your apps by processor time, live"
    }

    var body: some View {
        Card(title: "Using the most power", subtitle: subtitle, symbol: "bolt.fill", tint: .orange, lit: !meter.apps.isEmpty,
             trailing: {
                 Button {
                     NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                        configuration: NSWorkspace.OpenConfiguration())
                 } label: { Image(systemName: "chart.bar.xaxis").foregroundStyle(.secondary) }
                     .buttonStyle(.plain)
                     .help("Open Activity Monitor for the full picture, including system processes.")
                     .accessibilityLabel("Open Activity Monitor")
             }) {
            if !meter.apps.isEmpty {
                Divider()
                VStack(spacing: 6) { ForEach(meter.apps) { AppRow(app: $0, meter: meter) } }
            }
        }
        .help("Processor time is the best per-app proxy for battery use that a Mac exposes without root. System processes such as WindowServer aren't listed; Activity Monitor has them.")
    }
}

struct AppRow: View {
    let app: AppEnergy
    @ObservedObject var meter: EnergyMeter
    @State private var hover = false
    @State private var confirmForce = false

    private var quitState: String? {   // nil = running normally
        guard let since = meter.quitting[app.id] else { return nil }
        return Date().timeIntervalSince(since) >= EnergyMeter.forceAfter ? "stuck" : "quitting"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: EnergyMeter.icon(for: app)).frame(width: 18, height: 18).accessibilityHidden(true)
            Text(app.name).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            switch quitState {
            case "quitting":
                ProgressView().controlSize(.small)
                Text("Quitting…").font(.caption).foregroundStyle(.secondary)
            case "stuck":
                if confirmForce {
                    Text("Unsaved work is lost").font(.caption).foregroundStyle(.secondary)
                    Button("Force Quit", role: .destructive) { meter.forceQuit(app); confirmForce = false }.controlSize(.small)
                    Button { confirmForce = false } label: { Image(systemName: "xmark") }.controlSize(.small)
                        .accessibilityLabel("Cancel")
                } else {
                    Text("Still running").font(.caption).foregroundStyle(.secondary)
                    Button("Force Quit") { confirmForce = true }.controlSize(.small)
                        .help("\(app.name) hasn't quit — it may be hung or waiting for you to save. Force-quitting can lose unsaved work.")
                }
            default:
                Capsule().fill(.quaternary).frame(width: 64, height: 5)
                    .overlay(alignment: .leading) { Capsule().fill(Brand.amber).frame(width: 64 * app.share) }
                    .accessibilityHidden(true)
                Text(String(format: "%.0f%%", app.cpuPercent)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                if meter.quittable(app) != nil {
                    Button { meter.quit(app) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(hover ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .help("Quit \(app.name)")
                    .accessibilityLabel("Quit \(app.name)")
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
        }
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.name), \(Int(app.cpuPercent)) percent of a processor core")
    }
}

/// Health, the live numbers, and the last twelve hours, behind a disclosure.
struct BatteryCard: View {
    @ObservedObject var monitor: Monitor
    @AppStorage("healthExpanded") private var expanded = false

    init(monitor: Monitor) {
        self.monitor = monitor
        _expanded = AppStorage(wrappedValue: false, "healthExpanded", store: monitor.defaults)
    }

    private var summary: String {
        guard let r = monitor.reading else { return "No battery" }
        var parts: [String] = []
        if let h = r.health { parts.append("Health \(Int(h.rounded()))%") }
        parts.append(r.condition)
        if let t = r.celsius { parts.append(String(format: "%.0f °C", t)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card(title: "Battery", subtitle: summary, symbol: "heart.text.square.fill", tint: .pink, lit: monitor.reading?.failed == false,
             expanded: $expanded, help: "Health, temperature, power, and the last twelve hours.", trailing: { EmptyView() }) {
            if let r = monitor.reading {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let h = r.health {
                        StatRow(label: "Maximum capacity", value: "\(Int(h.rounded()))%",
                                help: "Apple's own health figure, the same one System Settings › Battery shows.")
                    }
                    StatRow(label: "Condition", value: r.condition, help: "Normal unless the gas gauge reports a failure or Apple's capacity figure has fallen below 80%.")
                    if let c = r.cycles {
                        StatRow(label: "Cycle count", value: r.designCycles.map { "\(c) of \($0.formatted())" } ?? "\(c)",
                                help: "Full charge-discharge cycles so far, against the number the battery is designed for.")
                    }
                    if let q = r.cellCapacity, let d = r.designCapacity, d > 0 {
                        StatRow(label: "Cell capacity", value: "\(Int(q.rounded()).formatted()) mAh · \(Int((q / d * 100).rounded()))% of design",
                                help: "What the cells can hold, as the gas gauge has measured it (Qmax). A young battery often reads a little over its design figure.")
                    }
                    if let m = r.rawMax {
                        StatRow(label: "Usable full charge now", value: "\(Int(m.rounded()).formatted()) mAh",
                                help: "What a full charge can deliver right now. It moves with temperature and load, so it reads a few percent below the cell capacity most of the time — that is not wear.")
                    }
                    if let d = r.designCapacity { StatRow(label: "Design capacity", value: "\(Int(d.rounded()).formatted()) mAh", help: "What a full charge held when the battery was new.") }
                    if let t = r.celsius { StatRow(label: "Temperature", value: String(format: "%.1f °C", t), help: "The battery pack. Charging is slower when it is hot.") }
                    if let v = r.volts { StatRow(label: "Voltage", value: String(format: "%.2f V", v)) }
                    if r.onAC {
                        StatRow(label: "Charger", value: [r.adapterWatts.map { "\($0) W" }, r.adapterName].compactMap { $0 }.joined(separator: " · ").ifEmpty("Connected"),
                                help: "What the adapter can supply.")
                        if let w = r.batteryWatts, w > 0.05 { StatRow(label: "Into the battery", value: Format.watts(w)) }
                    } else if let w = r.batteryWatts, w < 0 {
                        StatRow(label: "From the battery", value: Format.watts(w), help: "What the Mac is drawing from the battery right now.")
                    }
                    if let w = r.systemWatts { StatRow(label: "Mac is using", value: Format.watts(w), help: "Total system power, from the power telemetry.") }
                    if let os = r.osMinutesLeft {
                        StatRow(label: r.charging ? "macOS says full in" : "macOS says flat in", value: Format.duration(os),
                                help: "macOS's own estimate, for comparison. It reacts to every change in load; JuiceLeft's blends the trend, the live draw and what it has learned about you.")
                    }
                }
                .padding(.leading, 2)
                Text("Last 12 hours").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                LevelChart(points: monitor.history.points, now: r.at, warnAt: monitor.s.warnAt, alertAt: monitor.s.alertAt)
                    .frame(height: 56)
                    .accessibilityLabel("Battery level over the last twelve hours")
            }
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// The level over the last twelve hours: the line, the flash level dashed, the tone level shaded. Gaps stay gaps.
struct LevelChart: View {
    let points: [History.Point]
    let now: Date
    let warnAt: Int
    let alertAt: Int
    static let hours = 12.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let from = now.addingTimeInterval(-Self.hours * 3600)
            let recent = points.filter { $0.t >= from }
            let x = { (t: Date) in CGFloat(t.timeIntervalSince(from) / (Self.hours * 3600)) * w }
            let y = { (l: Double) in h * CGFloat(1 - l / 100) }
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04))
                Rectangle().fill(Color.red.opacity(0.10)).frame(height: h * CGFloat(alertAt) / 100)
                Path { p in p.move(to: CGPoint(x: 0, y: y(Double(warnAt)))); p.addLine(to: CGPoint(x: w, y: y(Double(warnAt)))) }
                    .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach([false, true], id: \.self) { charging in
                    Path { p in
                        var previous: History.Point?
                        for point in recent where point.c == charging {
                            let at = CGPoint(x: x(point.t), y: y(point.l))
                            if let previous, point.t.timeIntervalSince(previous.t) < 5 * 60 { p.addLine(to: at) } else { p.move(to: at) }
                            previous = point
                        }
                    }
                    .stroke(charging ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                if recent.count < 2 {
                    Text("Not enough history yet").font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// Reminders that keep a battery healthier.
struct ChargingCard: View {
    @ObservedObject var monitor: Monitor
    @AppStorage("chargingExpanded") private var expanded = false

    init(monitor: Monitor) {
        self.monitor = monitor
        _expanded = AppStorage(wrappedValue: false, "chargingExpanded", store: monitor.defaults)
    }

    private var summary: String {
        var parts: [String] = []
        if monitor.s.unplugReminder { parts.append("Unplug at \(Monitor.unplugAt)%") }
        if monitor.s.fullNotice { parts.append("Full notice") }
        if monitor.s.plugNotices { parts.append("Plug in/out") }
        return parts.isEmpty ? "No reminders" : parts.joined(separator: " · ")
    }

    var body: some View {
        Card(title: "Charging care", subtitle: summary, symbol: "bolt.heart.fill", tint: .green,
             lit: monitor.s.unplugReminder || monitor.s.fullNotice || monitor.s.plugNotices,
             expanded: $expanded, help: "Notifications about charging.", trailing: { EmptyView() }) {
            Divider()
            SwitchRow(title: "Remind me to unplug at \(Monitor.unplugAt)%", subtitle: "Lithium batteries age slowest between 20 and 80%",
                      help: "A notification once per charge when the battery reaches \(Monitor.unplugAt)%.", isOn: $monitor.s.unplugReminder)
            SwitchRow(title: "Tell me when it's full", help: "A notification when the battery reports fully charged.", isOn: $monitor.s.fullNotice)
            SwitchRow(title: "Charger plugged in or out", subtitle: "Which charger, and the time to flat when unplugged",
                      help: "A notification on every plug and unplug.", isOn: $monitor.s.plugNotices)
        }
    }
}

/// The menu-bar display and the wording.
struct GeneralRows: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Menu bar").font(.callout)
                Spacer()
                Picker("Menu bar shows", selection: $monitor.s.menuBar) {
                    Text("Icon").tag(Settings.MenuBar.icon)
                    Text("Percent").tag(Settings.MenuBar.percent)
                    Text("Compact").tag(Settings.MenuBar.compact)
                    Text("Words").tag(Settings.MenuBar.words)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Icon: the battery alone. Percent: Apple's look, “84%” and the battery. Compact: adds the time after it, “2:10” (“Full 45m” charging). Words: “2 Hours 10 Min Remaining” (“45 Min Until Full” charging). The tooltip and VoiceOver always have the whole story.")
            }
            SwitchRow(title: "Replace the macOS battery icon", subtitle: "Apple's battery item is hidden while JuiceLeft runs and comes back when it quits",
                      help: "Off puts Apple's battery item back straight away and leaves it alone from then on. It lives in System Settings › Control Center › Battery.",
                      isOn: $monitor.s.replaceSystemIcon)
            if AppleIntelligence.available {
                SwitchRow(title: "Apple Intelligence wording", subtitle: "Phrases the summary line on this Mac; the numbers are always JuiceLeft's",
                          help: "Uses the on-device model to word the summary. Nothing leaves the Mac.", isOn: $monitor.s.insight)
            }
        }
    }
}
