import SwiftUI

// The panel: a live status header with the forecast, one plain-English line, then cards for the alerts, the apps
// using the most power, battery health and charging care, and the general rows. Every control maps 1:1 onto
// `Settings` or a Monitor action; the layout only adds progressive disclosure.

/// One curve for every panel transition; callers pass nil (no animation) under Reduce Motion.
let panelEase = Animation.easeInOut(duration: 0.25)

/// The app icon's palette: deep teal, and a charge that runs from lime to amber.
enum Brand {
    static let teal = Color(red: 0.05, green: 0.45, blue: 0.43)
    static let lime = Color(red: 0.60, green: 0.89, blue: 0.34)
    static let amber = Color(red: 1.00, green: 0.75, blue: 0.28)
}

struct Panel: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("tapHintSeen") private var tapHintSeen = false

    init(monitor: Monitor) {
        self.monitor = monitor
        _tapHintSeen = AppStorage(wrappedValue: false, "tapHintSeen", store: monitor.defaults)
    }

    /// The panel never outgrows the screen: past this it scrolls.
    static var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 40 }

    var body: some View {
        ScrollView {
            content
        }
        .frame(width: 344)
        .frame(maxHeight: Self.maxHeight)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeader(monitor: monitor)
            InsightLine(monitor: monitor, insight: monitor.insight)
            if let note = monitor.note {
                Notice(text: note, kind: .warning) { monitor.note = nil }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if !tapHintSeen {
                Notice(text: "Tip: click the menu-bar item for this panel. Press and hold it to turn monitoring on or off without opening anything.", kind: .tip) {
                    withAnimation(reduceMotion ? nil : panelEase) { tapHintSeen = true }
                }
                .transition(.opacity)
            }
            AlertsCard(monitor: monitor)
            EnergyCard(meter: monitor.energy)
            BatteryCard(monitor: monitor)
            ChargingCard(monitor: monitor)
            GeneralRows(monitor: monitor)
            Divider()
            HStack {
                Toggle("Launch at login", isOn: Binding(get: { LoginItem.isOn }, set: { monitor.setLoginItem($0) }))
                    .toggleStyle(.checkbox)
                    .help("Start JuiceLeft automatically when you log in.")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .help("Quit JuiceLeft (⌘Q). No alerts until it runs again.")
            }
            .font(.callout)
            HStack(spacing: 4) {
                Text("JuiceLeft \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · by")
                Link("CyborgFingers", destination: URL(string: "https://github.com/CyborgFingers")!)
                    .help("github.com/CyborgFingers — source, releases and issues at github.com/CyborgFingers/JuiceLeft")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .animation(reduceMotion ? nil : panelEase, value: monitor.note)
    }
}

/// The big glyph, the forecast in words, and the main switch — the same on/off a press-and-hold on the menu-bar item does.
struct StatusHeader: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch monitor.phase {
        case .alert: return .red
        case .warning: return .orange
        case .clear: return monitor.reading?.onAC == true ? .green : .primary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            HeaderGlyph(icon: monitor.icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.headline).font(.headline).lineLimit(1)
                Text(monitor.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : panelEase, value: monitor.headline + monitor.detail)
            .layoutPriority(1)
            Spacer(minLength: 8)
            Toggle("Monitoring", isOn: Binding(get: { monitor.s.armed }, set: { _ in withAnimation(reduceMotion ? nil : panelEase) { monitor.toggleArmed() } }))
                .labelsHidden().toggleStyle(.switch)
                .help("Turn the low-battery monitoring on or off — the same as pressing and holding the menu-bar item.")
                .accessibilityLabel("Monitoring")
                .accessibilityHint("Turns the warning flash, the tone and the notifications on or off")
        }
    }
}

/// Whether the panel is on screen. The status item flips it, so the live glyph only follows the menu-bar pulse
/// while the popover is open (the hidden panel costs nothing).
private struct PanelVisibleKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var panelVisible: Bool {
        get { self[PanelVisibleKey.self] }
        set { self[PanelVisibleKey.self] = newValue }
    }
}

/// The menu-bar glyph drawn large, tinted for the state; it breathes with the menu bar's red pulse.
struct HeaderGlyph: View {
    let icon: MenuIcon
    let tint: Color
    @Environment(\.panelVisible) private var visible

    var body: some View {
        if visible {
            LiveGlyph(icon: icon, tint: tint)
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }
}

struct LiveGlyph: View {
    @ObservedObject var icon: MenuIcon
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        var frame = icon.frame
        frame.red = 0
        return Image(nsImage: MenuIcon.draw(frame, side: 44)).renderingMode(.template)
            .foregroundStyle(tint)
            .opacity(icon.frame.red > 0 ? icon.frame.red : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: tint)
            .accessibilityHidden(true)
    }
}

/// One plain sentence about what the battery is doing, and how far out forecasts like this one usually land.
struct InsightLine: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var insight: Insight

    private var accuracy: String? {
        guard let f = monitor.forecast, f.kind == .flat else { return nil }
        guard let miss = monitor.history.learner.typicalMiss(for: f.minutes) else {
            return "Accuracy shows after a couple of discharges — JuiceLeft is learning your usage."
        }
        return "Forecasts like this one have typically landed within ±\(miss) min."
    }

    var body: some View {
        if !insight.text.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: insight.fromAI ? "sparkles" : "text.bubble")
                        .foregroundStyle(.secondary).imageScale(.small).frame(width: 14).padding(.top, 3)
                    Text(insight.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .help(insight.fromAI ? "Phrased on this Mac by Apple Intelligence from JuiceLeft's own numbers — it never adds any."
                                     : "From JuiceLeft's own numbers. On macOS 26 with Apple Intelligence on, it phrases this line.")
                if let accuracy {
                    Text(accuracy).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Every forecast made during a discharge is scored, once the charger goes in, against when the level really arrived. This is the typical miss for a forecast this far out.")
                }
            }
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)
        }
    }
}

/// An inline, dismissible message: an error (warning) or the first-run tip.
struct Notice: View {
    enum Kind { case warning, tip }
    let text: String
    let kind: Kind
    let dismiss: () -> Void

    private var color: Color { kind == .warning ? .orange : .accentColor }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "lightbulb.fill").foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind == .warning ? "Warning" : "Tip"): \(text)")
    }
}

/// A card: icon tile, title, one-line status, something on the right (a switch, a button, nothing), and rows.
/// With `expanded` bound, the header is a disclosure button and the rows only show while open.
struct Card<Trailing: View, Rows: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let lit: Bool
    var expanded: Binding<Bool>? = nil
    var help = ""
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let rows: Rows
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: tint, lit: lit)
                if let expanded {
                    Button(action: { toggle(expanded) }) {
                        HStack(spacing: 6) {
                            titles
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(help)
                    .accessibilityLabel("\(title): \(subtitle)")
                    .accessibilityValue(expanded.wrappedValue ? "expanded" : "collapsed")
                    .accessibilityAddTraits(.isButton)
                    trailing
                    Button(action: { toggle(expanded) }) {   // the chevron stays on the right edge, past any button
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                            .frame(width: 16, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                } else {
                    titles
                    Spacer(minLength: 8)
                    trailing
                }
            }
            if expanded?.wrappedValue ?? true { rows }
        }
        .padding(12)
        .background(shape.fill(lit ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.045)))
        .overlay(shape.strokeBorder(lit ? Color.accentColor.opacity(contrast == .increased ? 0.6 : 0.25)
                                        : Color.primary.opacity(contrast == .increased ? 0.4 : 0.08)))
    }

    private func toggle(_ expanded: Binding<Bool>) {
        withAnimation(reduceMotion ? nil : panelEase) { expanded.wrappedValue.toggle() }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .contentTransition(.opacity)
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }
}

/// System Settings-style coloured square with a white symbol; grey while its card is off.
struct IconTile: View {
    let symbol: String
    let tint: Color
    let lit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if #available(macOS 14, *), !reduceMotion {
                Image(systemName: symbol).symbolEffect(.bounce, value: lit)
            } else {
                Image(systemName: symbol)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(lit ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.gray.gradient)))
        .accessibilityHidden(true)
    }
}

/// Title (+ optional subtitle) on the left, a small switch pinned to the right edge.
struct SwitchRow: View {
    let title: String
    var subtitle: String?
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).help(help)
        }
    }
}

/// Label on the left, value on the right.
struct StatRow: View {
    let label: String
    let value: String
    var help = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.callout).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .help(help)
        .accessibilityElement(children: .combine)
    }
}
