import AppKit

/// One app (helpers folded into it) and its share of the processor time used over the last few seconds.
struct AppEnergy: Identifiable, Equatable {
    let id: String
    let name: String
    let bundle: String?      // the .app, if it is one
    let cpuPercent: Double   // CPU seconds per second × 100, so one busy core is 100 (the tooltip's figure)
    let share: Double        // 0…1 of all the processor time measured, the number shown
    var icon: NSImage? = nil // only --shots sets one: a drawn sample icon, since its apps don't exist
}

/// What the panel lists: the user's apps using noticeable power, most first, and everything else rolled up.
struct Ranking: Equatable {
    var apps: [AppEnergy] = []          // at most `EnergyMeter.count`, each at least `noticeable`
    var background: [AppEnergy] = []    // the top few system and background processes, for the disclosure
    var backgroundShare = 0.0           // all of them together, 0…1
}

/// Which apps are using the most power right now. Samples every process's CPU time every 3 s — but only while the
/// panel is open — and folds helper processes into the app that owns them (a browser's helpers → the browser app).
/// Each row can quit its app: a graceful `terminate()` first (the app's own save prompts protect unsaved work), and
/// if it is still there 5 s later, a force quit behind one confirmation.
/// ponytail: CPU time is the proxy; GPU and networking aren't billed per process without root, and neither are
/// root-owned system processes (WindowServer, coreaudiod), so this ranks the user's own apps, which is what they can act on.
@MainActor final class EnergyMeter: ObservableObject {
    typealias Snapshot = [pid_t: (cpu: Double, path: String)]

    @Published private(set) var ranking = Ranking()
    @Published private(set) var measuring = false
    @Published private(set) var quitting: [String: Date] = [:]   // app id → when Quit was asked for
    var apps: [AppEnergy] { ranking.apps }
    static let interval: TimeInterval = 3
    nonisolated static let count = 5
    nonisolated static let noticeable = 1.0    // % of one core: below this an app isn't worth a row
    nonisolated static let backgroundShown = 3
    static let forceAfter: TimeInterval = 5
    private var timer: Timer?
    private var previous: Snapshot = [:]
    private var previousAt = Date()
    /// The process table and the running apps, as closures: --e2e measures and quits made-up apps, never real ones.
    nonisolated(unsafe) static var processes: () -> Snapshot = { snapshot() }
    static var running: () -> [NSRunningApplication] = { NSWorkspace.shared.runningApplications }

    func start() {
        guard timer == nil else { return }
        measuring = true
        previous = Self.processes()
        previousAt = Date()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in MainActor.assumeIsolated { self.sample() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        measuring = false
        previous = [:]
    }

    /// --shots: a sample ranking in place of a measurement.
    func show(sample: Ranking) { ranking = sample }

    private func sample() {
        let before = previous, beforeAt = previousAt
        for (id, _) in quitting where Self.runningApp(id) == nil { quitting[id] = nil }   // gone: the row goes with it
        let pinned = Set(quitting.keys), apps = Self.userApps()
        DispatchQueue.global(qos: .utility).async {
            let now = Self.processes(), at = Date()
            let ranked = Self.rank(before: before, after: now, seconds: at.timeIntervalSince(beforeAt), apps: apps, pinned: pinned)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.previous = now
                    self.previousAt = at
                    self.ranking = ranked
                    self.measuring = false
                }
            }
        }
    }

    /// The bundles of the user's own apps — ordinary and menu-bar apps, not the system's agents.
    static func userApps() -> Set<String> {
        Set(running().compactMap { app in
            guard let bundle = app.bundleURL?.path, isUserApp(bundle: bundle, bundleID: app.bundleIdentifier, policy: app.activationPolicy) else { return nil }
            return bundle
        })
    }

    nonisolated private static let timebase: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// CPU seconds so far for every process this user can see.
    nonisolated static func snapshot() -> Snapshot {
        var count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: Snapshot = [:]
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size),
                  proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            out[pid] = (Double(info.pti_total_user &+ info.pti_total_system) * timebase, String(cString: path))
        }
        return out
    }

    /// Pure: processor time used between two snapshots, grouped by app. Groups whose bundle is one of the user's
    /// `apps` make the list (top `count`, each at least `noticeable`, `pinned` ones regardless); everything else is
    /// rolled into the background share. Shares are of the total measured, so they never pass 100 and add up.
    nonisolated static func rank(before: Snapshot, after: Snapshot, seconds: TimeInterval, apps: Set<String>, pinned: Set<String> = []) -> Ranking {
        guard seconds > 0 else { return Ranking() }
        var used: [String: (name: String, bundle: String?, cpu: Double)] = [:]
        for (pid, now) in after {
            guard let then = before[pid], now.path == then.path else { continue }
            let app = app(for: now.path)
            guard now.cpu > then.cpu || pinned.contains(app.key) else { continue }
            used[app.key, default: (app.name, app.bundle, 0)].cpu += max(now.cpu - then.cpu, 0)
        }
        let total = used.values.reduce(0) { $0 + $1.cpu }
        guard total > 0 else { return Ranking() }
        let entry = { (key: String, value: (name: String, bundle: String?, cpu: Double)) in
            AppEnergy(id: key, name: value.name, bundle: value.bundle, cpuPercent: value.cpu / seconds * 100, share: value.cpu / total)
        }
        let sorted = used.sorted { $0.value.cpu > $1.value.cpu }
        let mine = sorted.filter { $0.value.bundle.map(apps.contains) ?? false }
        let shown = mine.prefix(count).filter { $0.value.cpu / seconds * 100 >= noticeable || pinned.contains($0.key) }
            + mine.dropFirst(count).filter { pinned.contains($0.key) }
        let mineKeys = Set(mine.map(\.key))
        let rest = sorted.filter { !mineKeys.contains($0.key) }
        return Ranking(apps: shown.map(entry),
                       background: rest.prefix(backgroundShown).filter { $0.value.cpu / seconds * 100 >= noticeable }.map(entry),
                       backgroundShare: rest.reduce(0) { $0 + $1.value.cpu } / total)
    }

    /// The outermost .app on the path (so a browser's helper inside its framework is the browser app), else the executable.
    nonisolated static func app(for path: String) -> (key: String, name: String, bundle: String?) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let bundle = parts[...i].joined(separator: "/")
            return (bundle, String(parts[i].dropLast(4)), bundle)
        }
        let executable = String(parts.last ?? "")
        // XPC services and the like are named like com.apple.MapKit.SnapshotService: keep the last part.
        let name = executable.hasPrefix("com.") && !executable.contains(" ") ? String(executable.split(separator: ".").last ?? "") : executable
        return (executable, name, nil)
    }

    // MARK: Quitting

    /// Never offered a Quit button: the shell and the system's own agents.
    nonisolated static let untouchable: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.SystemUIServer",
                                           "com.apple.controlcenter", "com.apple.WindowManager", "com.apple.notificationcenterui",
                                           "com.apple.Spotlight", "com.apple.CoreServicesUIAgent"]

    /// Pure: one of the user's apps — an ordinary or menu-bar app they launched, not one of the system's agents.
    nonisolated static func isUserApp(bundle: String?, bundleID: String?, policy: NSApplication.ActivationPolicy) -> Bool {
        guard let bundle, policy != .prohibited, !bundle.hasPrefix("/System/Library/") else { return false }
        return !(bundleID.map { untouchable.contains($0) } ?? false)
    }

    /// Pure: a user app that may be quit from here — any but this one.
    nonisolated static func mayQuit(bundle: String?, bundleID: String?, policy: NSApplication.ActivationPolicy, isSelf: Bool) -> Bool {
        !isSelf && isUserApp(bundle: bundle, bundleID: bundleID, policy: policy)
    }

    static func runningApp(_ id: String) -> NSRunningApplication? {
        running().first { $0.bundleURL?.path == id && !$0.isTerminated }
    }

    /// The running app behind a row, if it may be quit.
    func quittable(_ app: AppEnergy) -> NSRunningApplication? {
        guard let running = Self.runningApp(app.id),
              Self.mayQuit(bundle: app.bundle, bundleID: running.bundleIdentifier, policy: running.activationPolicy,
                           isSelf: running.processIdentifier == ProcessInfo.processInfo.processIdentifier) else { return nil }
        return running
    }

    func quit(_ app: AppEnergy) {
        guard let running = quittable(app) else { return }
        quitting[app.id] = Date()
        running.terminate()
    }

    func forceQuit(_ app: AppEnergy) {
        guard let running = quittable(app) else { return }
        running.forceTerminate()
    }

    /// Cached app icons, for the rows.
    private static var icons: [String: NSImage] = [:]
    static func icon(for app: AppEnergy) -> NSImage {
        if let icon = app.icon { return icon }
        if let cached = icons[app.id] { return cached }
        let image = app.bundle.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        image.size = NSSize(width: 20, height: 20)
        icons[app.id] = image
        return image
    }
}
