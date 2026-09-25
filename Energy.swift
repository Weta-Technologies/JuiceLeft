import AppKit

/// One app (helpers folded into it) and its share of the CPU time used over the last few seconds.
struct AppEnergy: Identifiable, Equatable {
    let id: String
    let name: String
    let bundle: String?      // the .app, if it is one
    let cpuPercent: Double   // CPU seconds per second × 100, so one busy core is 100
    let share: Double        // 0…1 against the top entry, for the bar
}

/// Which apps are using the most power right now. Samples every process's CPU time every 3 s — but only while the
/// panel is open — and folds helper processes into the app that owns them (every Chrome helper → Google Chrome).
/// Each row can quit its app: a graceful `terminate()` first (the app's own save prompts protect unsaved work), and
/// if it is still there 5 s later, a force quit behind one confirmation.
/// ponytail: CPU time is the proxy; GPU and networking aren't billed per process without root, and neither are
/// root-owned system processes (WindowServer, coreaudiod), so this ranks the user's own apps, which is what they can act on.
@MainActor final class EnergyMeter: ObservableObject {
    typealias Snapshot = [pid_t: (cpu: Double, path: String)]

    @Published private(set) var apps: [AppEnergy] = []
    @Published private(set) var measuring = false
    @Published private(set) var quitting: [String: Date] = [:]   // app id → when Quit was asked for
    static let interval: TimeInterval = 3
    nonisolated static let count = 5
    static let forceAfter: TimeInterval = 5
    private var timer: Timer?
    private var previous: Snapshot = [:]
    private var previousAt = Date()

    func start() {
        guard timer == nil else { return }
        measuring = true
        previous = Self.snapshot()
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

    private func sample() {
        let before = previous, beforeAt = previousAt
        for (id, _) in quitting where Self.runningApp(id) == nil { quitting[id] = nil }   // gone: the row goes with it
        let pinned = Set(quitting.keys)
        DispatchQueue.global(qos: .utility).async {
            let now = Self.snapshot(), at = Date()
            let ranked = Self.rank(before: before, after: now, seconds: at.timeIntervalSince(beforeAt), pinned: pinned)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.previous = now
                    self.previousAt = at
                    self.apps = ranked
                    self.measuring = false
                }
            }
        }
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

    /// Pure: CPU used between two snapshots, grouped by app, top `count` first; `pinned` apps stay listed at any level.
    nonisolated static func rank(before: Snapshot, after: Snapshot, seconds: TimeInterval, pinned: Set<String> = []) -> [AppEnergy] {
        guard seconds > 0 else { return [] }
        var used: [String: (name: String, bundle: String?, cpu: Double)] = [:]
        for (pid, now) in after {
            guard let then = before[pid], now.path == then.path else { continue }
            let app = app(for: now.path)
            guard now.cpu > then.cpu || pinned.contains(app.key) else { continue }
            used[app.key, default: (app.name, app.bundle, 0)].cpu += max(now.cpu - then.cpu, 0)
        }
        let sorted = used.sorted { $0.value.cpu > $1.value.cpu }
        let top = sorted.prefix(count) + sorted.dropFirst(count).filter { pinned.contains($0.key) }
        let most = max(top.first?.value.cpu ?? 0, 0.001)
        return top.map { AppEnergy(id: $0.key, name: $0.value.name, bundle: $0.value.bundle,
                                   cpuPercent: $0.value.cpu / seconds * 100, share: $0.value.cpu / most) }
    }

    /// The outermost .app on the path (so a helper inside a framework inside Chrome is Chrome), else the executable.
    nonisolated static func app(for path: String) -> (key: String, name: String, bundle: String?) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let bundle = parts[...i].joined(separator: "/")
            return (bundle, String(parts[i].dropLast(4)), bundle)
        }
        let name = String(parts.last ?? "")
        return (name, name, nil)
    }

    // MARK: Quitting

    /// Never offered a Quit button: the shell and the system's own agents.
    nonisolated static let untouchable: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.SystemUIServer",
                                           "com.apple.controlcenter", "com.apple.WindowManager", "com.apple.notificationcenterui",
                                           "com.apple.Spotlight", "com.apple.CoreServicesUIAgent"]

    /// Pure: a real, quittable user app — an ordinary or menu-bar app the user launched, not this one, not the system's.
    nonisolated static func mayQuit(bundle: String?, bundleID: String?, policy: NSApplication.ActivationPolicy, isSelf: Bool) -> Bool {
        guard let bundle, !isSelf, policy != .prohibited, !bundle.hasPrefix("/System/Library/") else { return false }
        return !(bundleID.map { untouchable.contains($0) } ?? false)
    }

    static func runningApp(_ id: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == id && !$0.isTerminated }
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
        if let cached = icons[app.id] { return cached }
        let image = app.bundle.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        image.size = NSSize(width: 20, height: 20)
        icons[app.id] = image
        return image
    }
}
