import AppKit
import Carbon.HIToolbox
import SwiftUI

/// `JuiceLeft --e2e <dir>`: every user-facing function, reached the way a user reaches it — the status item's own
/// handlers, each panel control's binding or action (the panel is rendered after every step, so each state draws),
/// readings through the battery source, links through the URL handler — on a copy with its own bundle id, settings
/// domain and history file, and the Mac behind stand-ins: FakeMac (helper, pmset, charge limit, charging light,
/// the battery item's preferences), FakeHardware (screen, keyboard), and here the notifications, the login item,
/// the accessories, the process table, the settings panes, the language model and the update feed. Every step
/// asserts what came of it. Prints a table (one row per function, also <dir>/report.txt) and exits 0 only when every
/// row passed. Run it from test-e2e.sh.
/// ponytail: SwiftUI shows an off-screen panel's buttons and switches to no accessibility client, so the controls
/// are driven through the same bindings and Monitor actions they call; the few AppKit-backed ones would be the odd
/// ones out.
@MainActor enum E2E {
    struct Row { var function: String; var how: String; var result: String }
    static var rows: [Row] = []
    static var out = URL(fileURLWithPath: "/tmp")

    /// One row: `ok` decides pass/fail; `why` is the detail on a failure.
    private static var checks = 0
    static func check(_ function: String, _ how: String, _ ok: Bool, _ why: @autoclosure () -> String = "") {
        checks += 1
        // Laid out after every check (every body runs); drawn now and then and on a failure. Drawing the whole panel
        // after every check made one run take about 45 minutes at full CPU.
        render(draw: !ok || checks % 12 == 0)
        rows.append(Row(function: function, how: how, result: ok ? "pass" : "FAIL: \(why())"))
        print("\(ok ? "pass" : "FAIL")  \(function)\(ok ? "" : " — \(why())")"); fflush(stdout)
    }
    static func skip(_ function: String, _ why: String) { rows.append(Row(function: function, how: "—", result: "not exercised: \(why)")) }

    /// Settles until `condition` holds (a popover's close animation, a background read), for at most `timeout`.
    static func waitFor(_ timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let until = Date().addingTimeInterval(timeout)
        while !condition(), Date() < until { settle(0.05) }
    }

    /// Lets timers, main-queue blocks and SwiftUI's re-render run for a moment, and hands queued events to the app.
    static func settle(_ seconds: TimeInterval = 0.15) {
        let until = Date().addingTimeInterval(seconds)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.main.run(until: min(until, Date().addingTimeInterval(0.02)))
        } while Date() < until
    }

    // MARK: - Stand-ins

    static let mac = FakeMac(), hardware = FakeHardware()
    static var posted: [(id: String, title: String, body: String)] = []
    static var asked = 0, allowNotifications = true
    static var loginOn = false, loginRefusal: String?
    static var accessories: [AccessoryBattery.Device] = []
    static var played: [(name: String, volume: Double)] = []
    static var opened: [URL] = []
    static var aiStatus = AppleIntelligence.Status.available
    static var quitAsks = 0

    /// A made-up app for the power list: it records Quit and Force Quit instead of being one.
    final class FakeApp: NSRunningApplication, @unchecked Sendable {
        let path: String, id: String, pid: pid_t
        var quits = 0, forced = 0, gone = false
        init(path: String, id: String, pid: pid_t) { self.path = path; self.id = id; self.pid = pid; super.init() }
        override var bundleURL: URL? { URL(fileURLWithPath: path) }
        override var bundleIdentifier: String? { id }
        override var activationPolicy: NSApplication.ActivationPolicy { .regular }
        override var processIdentifier: pid_t { pid }
        override var isTerminated: Bool { gone }
        override func terminate() -> Bool { quits += 1; return true }
        override func forceTerminate() -> Bool { forced += 1; return true }
    }
    static let hog = FakeApp(path: "/Applications/Example Editor.app", id: "com.example.editor", pid: 90001)
    static let player = FakeApp(path: "/Applications/Sample Player.app", id: "com.example.player", pid: 90002)
    /// CPU seconds so far per process, and what each burns between two looks (the meter looks every 3 s).
    nonisolated(unsafe) static var table: [pid_t: (cpu: Double, path: String)] = [:]
    nonisolated(unsafe) static var burn: [pid_t: Double] = [:]

    /// The update feed: whatever it is set to answer, from memory. Nothing reaches the network, and nothing but the
    /// feed is ever asked for (a download would show up in `requests`).
    final class Feed: URLProtocol {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var requests: [URL] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!, feed = url.path.hasSuffix("/releases/latest")
            Feed.requests.append(url)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: feed ? Feed.status : 404, httpVersion: "HTTP/1.1", headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            if feed { client?.urlProtocol(self, didLoad: Feed.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// Points every seam at the stand-ins. Nothing after this touches the Mac.
    static func installFakes() {
        mac.magSafe = false   // on battery at launch; a MagSafe charger goes in later
        mac.install()
        Lid.read = { false }
        Notifier.authorize = { report in asked += 1; let allowed = allowNotifications; DispatchQueue.main.async { report(allowed) } }
        Notifier.deliver = { id, title, body in posted.append((id, title, body)) }
        LoginItem.status = { loginOn }
        LoginItem.apply = { on in
            if let why = loginRefusal { throw NSError(domain: "e2e", code: 1, userInfo: [NSLocalizedDescriptionKey: why]) }
            loginOn = on
        }
        AccessoryBattery.scan = { accessories }
        EnergyMeter.running = { [hog, player].filter { !$0.gone } }
        EnergyMeter.processes = {
            for (pid, cpu) in burn { table[pid]?.cpu += cpu }
            return table
        }
        Opener.open = { opened.append($0); return true }
        AppleIntelligence.statusNow = { aiStatus }
        AppleIntelligence.phraser = { f in "Your Mac is at \(f.percent)% and doing fine." }
        // The updater's session comes from URLSessionConfiguration.ephemeral: that configuration now carries the feed
        // above as its only protocol, so no request of the updater's can leave the process.
        if let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.ephemeral)),
           let stub = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.e2eEphemeral)) {
            method_exchangeImplementations(original, stub)
        }
        UserDefaults.standard.set("v9.9.9", forKey: "updates.notified")   // the updater's own notification for the test release: already "sent"
    }

    /// A battery that reports only what the harness hands it.
    private final class Scripted: BatterySource {
        var onReading: ((Reading?) -> Void)?
        let interval: TimeInterval = 30
        func start() {}
        func refresh() {}
    }

    static var clock = Date()
    static var level = 100.0
    private static let source = Scripted()
    static let rawMax = 5895.0

    /// The next reading, `seconds` after the last (never a gap that reads as sleep), with the level moved by `rate`
    /// (%/h: − draining, + charging; the gauge's current says the same — and above 80 % a charge tapers, falling
    /// linearly to a fifth of `rate` at 100 %). Low Power Mode follows the fake helper.
    @discardableResult
    static func feed(onAC: Bool, rate: Double, charging: Bool? = nil, full: Bool = false, celsius: Double = 30, adapterWatts: Int = 70,
                             magSafe: Bool = true, seconds: TimeInterval = 30) -> Reading {
        clock = clock.addingTimeInterval(seconds)
        let k = (1 - Learner.taperFloor) / (100 - Learner.taperFrom)
        let rate = rate > 0 && level > Learner.taperFrom ? rate * (1 - k * (level - Learner.taperFrom)) : rate
        level = max(0, min(100, level + rate * seconds / 3600))
        mac.magSafe = onAC && magSafe
        var r = Reading(at: clock, percent: Int(level.rounded()), onAC: onAC, charging: charging ?? (onAC && rate > 0), full: full)
        r.lowPowerMode = !onAC && mac.power.battery == .low
        r.rawMax = rawMax
        r.rawCurrent = level / 100 * rawMax
        r.maxCapacity = 96
        r.cellCapacity = 6460
        r.designCapacity = 6249
        r.cycles = 132
        r.designCycles = 1000
        r.volts = 12
        r.amps = rate * rawMax / 100_000
        r.celsius = celsius
        r.systemWatts = 17
        r.osMinutesLeft = onAC ? (100 - r.percent) * 2 : r.percent * 3
        if onAC { r.adapterWatts = adapterWatts; r.adapterName = "\(adapterWatts)W USB-C Power Adapter" }
        source.onReading?(r)
        return r
    }

    /// Readings every `step` seconds for `hours`, at `rate`.
    static func run(hours: Double, onAC: Bool, rate: Double, charging: Bool? = nil, full: Bool = false, step: TimeInterval = 60) {
        for _ in 0..<Int(hours * 3600 / step) { feed(onAC: onAC, rate: rate, charging: charging, full: full, seconds: step) }
    }

    /// Readings until the level passes `target` (from either side), at `rate`.
    static func run(to target: Double, onAC: Bool, rate: Double, step: TimeInterval = 30) {
        while rate < 0 ? level > target : level < target { feed(onAC: onAC, rate: rate, seconds: step) }
    }

    // MARK: - The panel, as it would be on screen

    static var host: NSHostingView<AnyView>?
    static var window: NSWindow?

    /// Lays the whole panel out and draws it — every card expanded — so each state is rendered, not just computed.
    static func render(_ name: String? = nil, draw: Bool = true) {
        guard let host, let window else { return }
        if name != nil { settle(0.4) }   // a picture to look at: let the panel's transitions finish first
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        guard draw || name != nil else { return }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        NSGraphicsContext.saveGraphicsState()   // on the window's background, as the popover shows it
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        host.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill(); host.bounds.fill() }
        NSGraphicsContext.restoreGraphicsState()
        host.cacheDisplay(in: host.bounds, to: rep)
        if let name { try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png")) }
    }

    static func showPanel(_ monitor: Monitor) {
        for key in ["alertsExpanded", "healthExpanded", "stretchExpanded", "chargingExpanded", "historyExpanded", "devicesExpanded", "moreExpanded"] {
            monitor.defaults.set(true, forKey: key)
        }
        let view = Whole(monitor: monitor).environment(\.openURL, OpenURLAction { url in opened.append(url); return .handled })
        let host = NSHostingView(rootView: AnyView(view))
        // Borderless, so it can never be key: nothing typed on the Mac while this runs can reach the panel's controls.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 344, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        self.host = host
        self.window = window
        for hours in [12, 24, 72] { monitor.defaults.set(hours, forKey: "historyHours"); render("panel-history-\(hours)h") }   // for a look by eye
        monitor.defaults.set(24, forKey: "historyHours")
    }

    /// The panel's content at full height (the popover scrolls it), rebuilt whenever the monitor changes — so the
    /// notices and cards `content` shows or hides by itself follow along, as they do inside the real Panel.
    private struct Whole: View {
        @ObservedObject var monitor: Monitor
        var body: some View { Panel(monitor: monitor).content.frame(width: 344) }
    }

    // MARK: - The run

    static func run(dir: String, delegate: AppDelegate) -> Never {
        out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard Bundle.main.bundleIdentifier == "io.github.cyborgfingers.juiceleft.e2e", !Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            print("E2E: run this from a copy with the e2e bundle id, outside /Applications (test-e2e.sh)"); exit(2)
        }
        installFakes()
        let suite = "io.github.cyborgfingers.juiceleft.e2e.settings"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let historyURL = out.appendingPathComponent("history.json")
        try? FileManager.default.removeItem(at: historyURL)

        // An older settings blob, as an upgrade would find it: the values it has are kept, the fields it lacks default,
        // a style this version no longer offers falls back, junk is dropped, and the sound stays off.
        defaults.set(#"{"warnAt":25,"alertAt":7,"tone":"Glass","volume":0,"insight":false,"bogus":1,"menuBar":"time"}"#.data(using: .utf8), forKey: Settings.key)
        clock = Date().addingTimeInterval(-72 * 3600)
        let monitor = Monitor(source: source, defaults: defaults, historyURL: historyURL, hardware: hardware)
        monitor.tone.recorder = { played.append(($0, $1)) }
        delegate.monitor = monitor
        let statusItem = StatusItemController(monitor: monitor)
        statusItem.fakeRoom = (true, [], nil)
        delegate.statusItem = statusItem
        delegate.quitIntercept = { quitAsks += 1; return true }
        monitor.start()
        settle()
        launch(monitor, defaults)
        history(monitor, historyURL)
        showPanel(monitor)
        forecasts(monitor)
        statusItemGestures(monitor, statusItem)
        monitor.panelOpened()   // what opening the popover does: tips, the power list and the modes go live
        panelBasics(monitor)
        menuBarStyles(monitor)
        powerList(monitor)
        saveBattery(monitor)
        energyModes(monitor)
        smartLowPower(monitor)
        alerts(monitor)
        devices(monitor)
        stretch(monitor)
        charging(monitor)
        more(monitor, statusItem)
        links(monitor, delegate)
        notch(monitor, statusItem)
        foot(monitor)
        ending(monitor, defaults)
        finish(monitor, defaults: defaults, suite: suite)
    }

    // MARK: - Keyboard shortcut

    static let probe = HotKey.Spec(keyCode: 38, key: "J", modifiers: NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue)

    /// Whether this process holds `spec` with Carbon: registering it a second time is refused while it does.
    static func registered(_ spec: HotKey.Spec) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(spec.keyCode), spec.carbonModifiers, EventHotKeyID(signature: 0x4532_4531, id: 9), GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == eventHotKeyExistsErr
    }

    // MARK: - The end

    static func finish(_ monitor: Monitor, defaults: UserDefaults, suite: String) -> Never {
        monitor.panelClosed()
        HotKey.set(nil)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: out.appendingPathComponent("history.json"))
        let width = rows.map(\.function.count).max() ?? 0, howWidth = rows.map(\.how.count).max() ?? 0
        var table = "| \("Function".padding(toLength: width, withPad: " ", startingAt: 0)) | \("Reached by".padding(toLength: howWidth, withPad: " ", startingAt: 0)) | Result |\n"
        table += "|\(String(repeating: "-", count: width + 2))|\(String(repeating: "-", count: howWidth + 2))|--------|\n"
        for r in rows { table += "| \(r.function.padding(toLength: width, withPad: " ", startingAt: 0)) | \(r.how.padding(toLength: howWidth, withPad: " ", startingAt: 0)) | \(r.result) |\n" }
        let failed = rows.filter { $0.result.hasPrefix("FAIL") }.count, skipped = rows.filter { $0.result.hasPrefix("not") }.count
        table += "\n\(rows.count - failed - skipped) passed, \(failed) failed, \(skipped) not exercised\n"
        print(table)
        try? table.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        exit(failed == 0 ? 0 : 1)
    }
}

extension URLSessionConfiguration {
    /// --e2e: exchanged with `ephemeral`, so this calls the original and hands back a configuration that only knows the fake feed.
    @objc class var e2eEphemeral: URLSessionConfiguration {
        let configuration = self.e2eEphemeral
        configuration.protocolClasses = [E2E.Feed.self]
        return configuration
    }
}
