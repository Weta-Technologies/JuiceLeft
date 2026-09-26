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
    @State private var showBackground = false

    private var ranking: Ranking { meter.ranking }
    private var measured: Bool { !ranking.apps.isEmpty || ranking.backgroundShare > 0 }

    private var subtitle: String {
        if !measured { return meter.measuring ? "Measuring your apps…" : "Nothing is using much power" }
        return ranking.apps.isEmpty ? "None of your apps is using much power" : "Your apps, by share of processor time"
    }

    var body: some View {
        Card(title: "Using the most power", subtitle: subtitle, symbol: "bolt.fill", tint: .orange, lit: !ranking.apps.isEmpty,
             trailing: {
                 Button {
                     NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                        configuration: NSWorkspace.OpenConfiguration())
                 } label: { Image(systemName: "chart.bar.xaxis").foregroundStyle(.secondary) }
                     .buttonStyle(.plain)
                     .help("Open Activity Monitor for the full picture, including system processes.")
                     .accessibilityLabel("Open Activity Monitor")
             }) {
            if measured {
                Divider()
                VStack(spacing: 6) {
                    ForEach(ranking.apps) { AppRow(app: $0, top: ranking.apps.first?.share ?? 1, meter: meter) }
                    if ranking.apps.count < EnergyMeter.count, !ranking.apps.isEmpty {
                        Text("Nothing else is using much power.").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
                    }
                    if ranking.backgroundShare > 0 { backgroundRow }
                }
            }
        }
        .help("Measured from processor time, the best per-app proxy for battery use a Mac exposes without root. Shares are of everything measured, so they add up to 100.")
    }

    /// Everything that isn't one of the user's apps, rolled into one quiet line, with the top few behind a disclosure.
    private var backgroundRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(panelEase) { showBackground.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                    Text("System & background").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text("\(Int((ranking.backgroundShare * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showBackground ? 90 : 0)).frame(width: 14)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("macOS's own processes and background helpers — nothing here can be quit from JuiceLeft.")
            .accessibilityLabel("System and background, \(Int((ranking.backgroundShare * 100).rounded())) percent")
            .accessibilityValue(showBackground ? "expanded" : "collapsed")
            if showBackground {
                ForEach(ranking.background) { item in
                    HStack(spacing: 8) {
                        Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text("\(Int((item.share * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                        Color.clear.frame(width: 14, height: 1)
                    }
                    .padding(.leading, 26)
                    .accessibilityElement(children: .combine)
                }
                if ranking.background.isEmpty {
                    Text("Nothing of note.").font(.caption).foregroundStyle(.tertiary).padding(.leading, 26)
                }
            }
        }
    }
}

struct AppRow: View {
    let app: AppEnergy
    let top: Double          // the top app's share, so the bars are proportional to the numbers
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
                    .overlay(alignment: .leading) { Capsule().fill(Brand.amber).frame(width: 64 * min(app.share / max(top, 0.001), 1)) }
                    .accessibilityHidden(true)
                Text("\(Int((app.share * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                    .help(String(format: "%.0f%% of one processor core over the last few seconds.", app.cpuPercent))
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
        .accessibilityLabel("\(app.name), \(Int((app.share * 100).rounded())) percent of the power in use")
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
             expanded: $expanded, help: "Health, temperature, power, and how the battery is being treated.", trailing: { EmptyView() }) {
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
                    if let t = r.celsius {
                        StatRow(label: "Temperature", value: String(format: "%.1f °C", t) + (monitor.heat.hot ? " · hot" : ""),
                                help: monitor.heat.hot ? HeatGuard.advice(charging: r.onAC) : "The battery pack. Heat ages a battery faster than anything else; JuiceLeft nudges you at 35 °C on the charger, 40 °C on battery.")
                            .foregroundStyle(monitor.heat.hot ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                    }
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
                HealthCoachRows(monitor: monitor)
            }
        }
    }
}

/// How the battery is being treated, and the one habit that helps most.
struct HealthCoachRows: View {
    @ObservedObject var monitor: Monitor

    private var high: Double? { monitor.reading.flatMap { HealthCoach.timeAtHighCharge(monitor.history.points, now: $0.at) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Health coach").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            StatRow(label: "Time at 95 %+, last 3 days", value: high.map { "\(Int(($0 * 100).rounded()))% of the time" } ?? "Needs a day of data",
                    help: "Sitting full on the charger is the habit that ages a lithium battery fastest. Under a quarter is easy on it.")
            StatRow(label: "Cycles per week", value: HealthCoach.cyclesPerWeek(monitor.history.days).map { String(format: "%.1f", $0) } ?? "Needs a week of data",
                    help: "Full charge–discharge cycles, from JuiceLeft's daily log. The battery is designed for 1,000.")
            StatRow(label: "Health trend", value: HealthCoach.healthTrendPerMonth(monitor.history.days).map { String(format: "%+.1f%% a month", $0) } ?? "Needs a few weeks of data",
                    help: "A straight line through the daily health figures, once there are three weeks of them.")
            if let high, high >= HealthCoach.storageShare {
                Text("Leaving it for a while? A battery stored at around 50 % keeps best.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ChargeLimit.supported, let limit = monitor.chargeLimit, !limit.enabled || limit.limit > ChargeLimit.recommended {
                HStack(spacing: 8) {
                    Text("An 80 % limit is the kindest everyday setting.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Set 80%") { monitor.setChargeLimit(ChargeLimit.recommended) }.controlSize(.small)
                        .help("macOS's own Charge Limit, the one in System Settings › Battery. It still tops up to 100 % now and then to keep the gauge honest.")
                }
            }
        }
    }
}

/// Stretch the battery: the two automatic helpers, the charge limit and the heat guard.
struct StretchCard: View {
    @ObservedObject var monitor: Monitor
    @AppStorage("stretchExpanded") private var expanded = false

    init(monitor: Monitor) {
        self.monitor = monitor
        _expanded = AppStorage(wrappedValue: false, "stretchExpanded", store: monitor.defaults)
    }

    private var summary: String {
        var parts: [String] = []
        if monitor.s.smartLowPower { parts.append("Smart Low Power") }
        if monitor.s.brightnessCap { parts.append("Screen ≤ \(Int((monitor.s.brightnessCapLevel * 100).rounded()))%") }
        if let limit = monitor.chargeLimit, limit.enabled { parts.append("Charge to \(limit.limit)%") }
        if monitor.travelFull != nil { parts.append("Full for travel") }
        return parts.isEmpty ? "Nothing automatic" : parts.joined(separator: " · ")
    }

    var body: some View {
        Card(title: "Stretch the battery", subtitle: summary, symbol: "leaf.fill", tint: .green,
             lit: monitor.s.smartLowPower || monitor.s.brightnessCap || (monitor.chargeLimit?.enabled ?? false),
             expanded: $expanded, help: "Things JuiceLeft can do by itself to make a charge last, and to make the battery last.", trailing: { EmptyView() }) {
            Divider()
            SwitchRow(title: "Smart Low Power", subtitle: monitor.helperReady ? "Low Power Mode by itself at \(SmartLowPower.level)% or under an hour left; the old mode is back on the charger"
                                                                             : "At \(SmartLowPower.level)% or under an hour left, once JuiceLeft's helper is set up",
                      help: "Uses the energy-mode helper (set up once, with your password or Touch ID). Change the mode by hand and JuiceLeft stands back until the next charge.",
                      isOn: $monitor.s.smartLowPower)
            SwitchRow(title: "Keep the screen at or below", subtitle: "On battery, and never turned up",
                      help: "Turns the built-in screen down to the cap whenever it is brighter on battery, and puts it back on the charger.",
                      isOn: $monitor.s.brightnessCap)
            if monitor.s.brightnessCap {
                HStack(spacing: 8) {
                    Text("Cap").font(.callout).frame(width: 92, alignment: .leading)
                    Slider(value: $monitor.s.brightnessCapLevel, in: 0.2...0.8, step: 0.05) { Text("Cap") }.labelsHidden().controlSize(.small)
                        .accessibilityValue("\(Int((monitor.s.brightnessCapLevel * 100).rounded())) percent")
                    Text("\(Int((monitor.s.brightnessCapLevel * 100).rounded()))%").font(.callout).monospacedDigit().frame(width: 38, alignment: .trailing)
                }
            }
            if ChargeLimit.supported {
                ChargeLimitRows(monitor: monitor)
            } else if #available(macOS 26.4, *) {
                HStack {
                    Text("Charge limit").font(.callout)
                    Spacer()
                    Button("Open Battery Settings…") { SystemBattery.openBatterySettings() }.controlSize(.small)
                        .help("macOS didn't offer its Charge Limit to JuiceLeft on this Mac; System Settings › Battery has it.")
                }
            }
            SwitchRow(title: "Heat guard", subtitle: "A nudge at 35 °C on the charger or 40 °C on battery",
                      help: "Shows what to do when the battery pack runs hot — heat ages it faster than anything. A notification too, when notifications are on.",
                      isOn: $monitor.s.heatGuard)
        }
    }
}

/// macOS's own Charge Limit, and one tap to fill up for a trip.
struct ChargeLimitRows: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Charge limit").font(.callout)
                    Text(monitor.chargeLimit.map { $0.enabled ? "Stops charging at \($0.limit)%; 80% is kindest for everyday use" : "Off: charges to 100%; 80% is kindest for everyday use" } ?? "Reading…")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Picker("Charge limit", selection: Binding(get: { monitor.chargeLimit?.limit ?? 100 }, set: { monitor.setChargeLimit($0) })) {
                    ForEach(monitor.chargeLimit?.available ?? ChargeLimit.steps, id: \.self) { Text($0 == 100 ? "Off" : "\($0)%").tag($0) }
                }
                .labelsHidden().fixedSize()
                .disabled(monitor.chargeLimit == nil)
                .help("macOS's own Charge Limit (System Settings › Battery). The firmware holds it, and still tops up to 100 % occasionally so the gauge stays accurate. macOS allows 80 % to 100 %.")
            }
            if let limit = monitor.chargeLimit, limit.enabled {
                HStack(spacing: 8) {
                    if let since = monitor.travelFull {
                        Label("Charging to full once (since \(Format.clock(since)))", systemImage: "airplane").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { monitor.cancelFullForTravel() }.controlSize(.small)
                            .help("Put the \(monitor.chargeLimit?.limit ?? 80)% limit back now.")
                    } else {
                        Text("Going somewhere?").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Full for travel") { monitor.fullForTravel() }.controlSize(.small)
                            .help("Let it charge to 100 % this once. The limit comes back by itself after the next unplug, or after a day on the charger.")
                    }
                }
            }
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// The level over a chosen window: the line, the flash level dashed, the tone level shaded. Gaps (the Mac asleep)
/// stay gaps at any range, since a real gap is always more than a few minutes without a sample.
struct LevelChart: View {
    let points: [History.Point]
    let now: Date
    var hours = 12.0
    let warnAt: Int
    let alertAt: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let from = now.addingTimeInterval(-hours * 3600)
            let recent = points.filter { $0.t >= from }
            let x = { (t: Date) in CGFloat(t.timeIntervalSince(from) / (hours * 3600)) * w }
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

/// The level over the last 12 hours, day or three days, with what the window comes to in one line.
struct HistoryCard: View {
    @ObservedObject var monitor: Monitor
    @AppStorage("historyExpanded") private var expanded = false
    @AppStorage("historyHours") private var hours = 24
    private let ranges = [(12, "12 hours"), (24, "24 hours"), (72, "3 days")]

    init(monitor: Monitor) {
        self.monitor = monitor
        _expanded = AppStorage(wrappedValue: false, "historyExpanded", store: monitor.defaults)
        _hours = AppStorage(wrappedValue: 24, "historyHours", store: monitor.defaults)
    }

    private var summary: History.Summary? {
        monitor.reading.flatMap { History.summary(monitor.history.points, since: $0.at.addingTimeInterval(-Double(hours) * 3600)) }
    }

    private var subtitle: String {
        guard let s = summary else { return "Battery level over time" }
        var parts = ["\(s.from)% → \(s.to)%"]
        if let d = s.drainPerHour { parts.append(String(format: "about %.0f%%/h on battery", d)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card(title: "History", subtitle: subtitle, symbol: "chart.xyaxis.line", tint: .blue, lit: monitor.history.points.count >= 2,
             expanded: $expanded, help: "The battery level over the window you pick, kept on this Mac for three days. Blue is on battery, green is charging; a gap is the Mac asleep.",
             trailing: { EmptyView() }) {
            Divider()
            Picker("Range", selection: $hours) {
                ForEach(ranges, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .help("How far back the chart looks.")
            if let r = monitor.reading {
                LevelChart(points: monitor.history.points, now: r.at, hours: Double(hours), warnAt: monitor.s.warnAt, alertAt: monitor.s.alertAt)
                    .frame(height: 72)
                    .accessibilityLabel("Battery level over the last \(ranges.first { $0.0 == hours }?.1 ?? "day"): \(subtitle)")
            }
            HStack(spacing: 12) {
                legend(Color.accentColor, "On battery")
                legend(.green, "Charging")
                legend(.orange, "Flash level")
                Spacer()
            }
            .font(.caption2).foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) { Capsule().fill(color).frame(width: 10, height: 3); Text(text) }
    }
}

/// The batteries of the Bluetooth accessories paired with this Mac, and an optional word when one runs low. The
/// card only appears while something with a battery is connected.
struct DevicesCard: View {
    @ObservedObject var monitor: Monitor
    @AppStorage("devicesExpanded") private var expanded = false

    init(monitor: Monitor) {
        self.monitor = monitor
        _expanded = AppStorage(wrappedValue: false, "devicesExpanded", store: monitor.defaults)
    }

    private var subtitle: String {
        guard let lowest = monitor.devices.first else { return "No accessories with a battery" }
        if monitor.devices.count == 1 { return "\(lowest.name) · \(lowest.percent)%" }
        return "\(lowest.name) \(lowest.percent)% · \(monitor.devices.count - 1) more"
    }

    var body: some View {
        if !monitor.devices.isEmpty {
            Card(title: "Your devices", subtitle: subtitle, symbol: "keyboard", tint: .indigo, lit: true, expanded: $expanded,
                 help: "The batteries of the Bluetooth mice, keyboards and trackpads connected to this Mac — read from macOS, nothing installed or stored.",
                 trailing: { EmptyView() }) {
                Divider()
                VStack(spacing: 6) {
                    ForEach(monitor.devices) { DeviceRow(device: $0, lowAt: monitor.s.deviceAlertAt) }
                }
                SwitchRow(title: "Tell me when one gets low", subtitle: "A notification at \(monitor.s.deviceAlertAt)%, once per charge",
                          help: "Checks the accessories every ten minutes while this is on. Off, JuiceLeft only reads them while the panel is open.",
                          isOn: $monitor.s.deviceAlert)
                if monitor.s.deviceAlert {
                    LevelRow(title: "Low at", value: Binding(get: { monitor.s.deviceAlertAt }, set: { monitor.s.deviceAlertAt = $0 }), range: 5...50,
                             help: "The level an accessory has to reach before JuiceLeft says so.")
                }
            }
        }
    }

    /// A symbol that exists on this macOS for the kind of device; never a blank.
    static func symbol(_ kind: AccessoryBattery.Kind) -> String {
        let preferred: String
        switch kind {
        case .mouse: preferred = "computermouse.fill"
        case .keyboard: preferred = "keyboard"
        case .trackpad: preferred = "rectangle.and.hand.point.up.left.fill"
        case .other: preferred = "dot.radiowaves.left.and.right"
        }
        return NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : "dot.radiowaves.left.and.right"
    }
}

/// One accessory: its kind, name, a bar and the percent — red at the alert level, orange under a third.
struct DeviceRow: View {
    let device: AccessoryBattery.Device
    let lowAt: Int
    private static let lowish = 30

    private var color: Color { device.percent <= lowAt ? .red : device.percent <= Self.lowish ? .orange : .green }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: DevicesCard.symbol(device.kind)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text(device.name).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Capsule().fill(.quaternary).frame(width: 64, height: 5)
                .overlay(alignment: .leading) { Capsule().fill(color).frame(width: 64 * CGFloat(device.percent) / 100) }
                .accessibilityHidden(true)
            Text("\(device.percent)%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.name), \(device.percent) percent")
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
        if let slow = monitor.chargerAdvice { return slow }   // a weak charger is the one thing worth saying first
        var parts: [String] = []
        if monitor.s.unplugReminder { parts.append("Unplug at \(Monitor.unplugAt)%") }
        if monitor.s.fullNotice { parts.append("Full notice") }
        if monitor.s.plugNotices { parts.append("Plug in/out") }
        if monitor.light.available, monitor.s.light { parts.append("MagSafe light") }
        return parts.isEmpty ? "No reminders" : parts.joined(separator: " · ")
    }

    var body: some View {
        Card(title: "Charging care", subtitle: summary, symbol: "bolt.heart.fill", tint: .green,
             lit: monitor.s.unplugReminder || monitor.s.fullNotice || monitor.s.plugNotices,
             expanded: $expanded, help: "Notifications about charging.", trailing: { EmptyView() }) {
            Divider()
            SwitchRow(title: "Remind me to unplug at \(Monitor.unplugAt)%", subtitle: "Lithium batteries age slowest between 20 and 80%",
                      help: "A notification once per charge when the battery reaches \(Monitor.unplugAt)%.", isOn: $monitor.s.unplugReminder)
            SwitchRow(title: "Tell me when it's full", subtitle: ChargeLimit.supported ? "Or held at the charge limit" : nil,
                      help: ChargeLimit.supported ? "A notification when the battery reports fully charged — or, with a charge limit on, when it stops there (“Held at 80%”)."
                                                  : "A notification when the battery reports fully charged.",
                      isOn: $monitor.s.fullNotice)
            SwitchRow(title: "Charger plugged in or out", subtitle: "Which charger, and the time to flat when unplugged",
                      help: "A notification on every plug and unplug.", isOn: $monitor.s.plugNotices)
            if monitor.light.available { LightRows(monitor: monitor, light: monitor.light) }
        }
    }
}

/// The menu-bar display and the wording.
struct GeneralRows: View {
    @ObservedObject var monitor: Monitor

    private var menuBarExample: String {
        switch monitor.s.menuBar {
        case .icon: return "the battery alone"
        case .percent: return "84% and the battery, Apple's look"
        case .compact: return "84% · battery · 2:10"
        case .words: return "84% · battery · 2 Hours 10 Min Remaining"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Menu bar shows").font(.callout)
                    Text(menuBarExample).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Picker("Menu bar shows", selection: $monitor.s.menuBar) {
                    Text("Icon").tag(Settings.MenuBar.icon)
                    Text("Percent").tag(Settings.MenuBar.percent)
                    Text("Compact").tag(Settings.MenuBar.compact)
                    Text("Words").tag(Settings.MenuBar.words)
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("Icon: the battery alone. Percent: Apple's look, “84%” and the battery. Compact: adds the time after it, “2:10” (“Full 45m” charging). Words: “2 Hours 10 Min Remaining” (“45 Min Until Full” charging). The hover card and VoiceOver always have the whole story.")
            }
            if monitor.s.menuBar != .icon {
                SwitchRow(title: "Show the power draw too", subtitle: "“−12 W” on battery, “+45 W” charging",
                          help: "Adds what is flowing out of (or into) the battery to the menu-bar item. Off keeps Apple's look exactly.",
                          isOn: $monitor.s.menuBarWatts)
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keyboard shortcut").font(.callout)
                    Text(monitor.s.hotKey.map { "\($0.label) opens the panel, from any app" } ?? "Opens the panel from any app")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                ShortcutRecorder(spec: Binding(get: { monitor.s.hotKey }, set: { monitor.setHotKey($0) })).fixedSize()
                    .help("Click, then press the keys: ⌘, ⌥ or ⌃ with a key, or a function key. Press it again anywhere to close the panel. Esc keeps what was there; Delete removes it. No permission needed.")
            }
            SwitchRow(title: "Replace the macOS battery icon", subtitle: "Apple's battery item is hidden while JuiceLeft runs and comes back when it quits",
                      help: "Off puts Apple's battery item back straight away and leaves it alone from then on. It lives in System Settings › Control Center › Battery.",
                      isOn: $monitor.s.replaceSystemIcon)
            if monitor.aiStatus == .available {
                SwitchRow(title: "Apple Intelligence wording", subtitle: "Phrases the summary line on this Mac; the numbers are always JuiceLeft's",
                          help: "Uses the on-device model to word the summary. Nothing leaves the Mac.", isOn: $monitor.s.insight)
            }
            HStack(spacing: 6) {
                Text("Shortcuts and scripts: juiceleft:// links.").font(.caption).foregroundStyle(.secondary)
                    .help("Open one of these from Shortcuts, a script or the Terminal:\njuiceleft://savebattery?on=1 (on=0 undoes)\njuiceleft://mode?set=low | automatic | high\njuiceleft://topup (charge to full once)\njuiceleft://monitoring?on=0\njuiceleft://snooze\nNothing else is accepted.")
                Spacer(minLength: 0)
                Button("Reinstall helper…") { monitor.setUpHelper() }
                    .buttonStyle(.link).font(.caption)
                    .help("If energy modes or the charging light ever stop working: reinstalls JuiceLeft's helper (one administrator prompt).")
            }
        }
    }
}

/// The MagSafe charging light: what it does while charging, when it goes green, and the fast blink when low.
struct LightRows: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var light: LightController

    private var status: String {
        if !light.onMagSafe { return monitor.reading?.onAC == true ? "Charging through USB-C: no light to drive" : "Shows while charging through MagSafe" }
        if light.needsSetup { return "Needs a one-time setup" }
        return light.holding.map { "MagSafe · now \($0.name)" } ?? "MagSafe · macOS's own colours"
    }

    var body: some View {
        Divider()
        SwitchRow(title: "Charging light", subtitle: status,
                  help: "The MagSafe light, driven by the hardware itself (no cost): orange patterns while charging, green when full or held at the charge limit. Off leaves it to macOS. Never touched while the lid is closed — SleepLess has it then.",
                  isOn: $monitor.s.light)
        if monitor.s.light {
            HStack(spacing: 8) {
                Text("While charging").font(.callout).frame(width: 110, alignment: .leading)
                Picker("While charging", selection: $monitor.s.lightBehaviour) {
                    ForEach(MagSafeLight.Behaviour.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("Blink, then steady: a slow orange blink for ten seconds after plugging in, then steady orange. Blink: the slow blink the whole time. Apple's default: orange as macOS does it.")
                Spacer()
            }
            SwitchRow(title: "Green when full or at the charge limit", subtitle: "macOS leaves it orange at a limit; this fixes that",
                      help: "Whenever the charger is in and the battery isn't taking charge.", isOn: $monitor.s.lightGreenAtLimit)
            SwitchRow(title: "Fast blink when charging from \(monitor.s.alertAt)% or below",
                      help: "A fast orange blink until the battery is above the tone level, then the pattern above.", isOn: $monitor.s.lightFastWhenLow)
            if light.needsSetup {
                HStack(spacing: 8) {
                    Text("Your password or Touch ID, once.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Set up…") { monitor.setUpHelper() }.controlSize(.small)
                        .help("Installs (or updates) the small root helper that also sets energy modes. macOS asks for your password or Touch ID, this once.")
                }
            }
        }
    }
}
