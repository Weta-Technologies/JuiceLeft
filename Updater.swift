import AppKit
import CryptoKit
import Security
import SwiftUI
import UserNotifications

/// Automatic updates from the app's GitHub releases — one file, the same in every Weta Technologies app. Everything
/// per-app comes from the bundle: name, version and bundle id (the repo is Weta-Technologies/<name>).
///
/// Checking: GET api.github.com/repos/<repo>/releases/latest (ETag-cached, 15 s timeout), first about 10 s after
/// launch and then once a day while "Check for updates automatically" is on, or from the Check Now button.
/// A background check that fails stays silent. A release counts when its tag is a higher semantic version than
/// CFBundleShortVersionString (pre-releases never do) and it carries `<App>.app.zip` and `<App>.app.zip.sig`.
///
/// Update Now: download the zip, check its Ed25519 signature against the publisher key below, unzip it with ditto
/// into a hidden folder beside the app, sanity-check the new bundle (same bundle id, the advertised newer version,
/// `codesign --verify`, and — when this app is Developer ID signed — the same developer's signature, checked against
/// this app's own designated requirement), then hand over to a small detached script that waits for this process to exit, swaps the
/// bundles with two renames (the old one goes back if anything fails) and relaunches. The app quits normally, so
/// its own clean-ups run; settings live outside the bundle, so they survive. Anything that fails shows a message
/// and the download page. Nothing from the download ever runs except the verified, checked app.
///
/// `--update-test <feed URL> <public key> [log file]`: the same flow against a local server and a test key, on a
/// copy of the app (test-update.sh) — its own settings domain, nothing else of the app running, each step logged.
@MainActor final class Updater: ObservableObject {
    /// The publisher key (Ed25519, base64). Its private half lives only in the publisher's Keychain.
    static let publisherKey = "s2ZRMsc27le7fBWfKvoXlSg1eTRjl1jFnB2Va+vVuv4="
    static let shared = Updater()
    static let firstCheckDelay: TimeInterval = 10
    static let checkInterval: TimeInterval = 24 * 3600

    struct Version: Comparable, CustomStringConvertible {
        let parts: [Int]

        /// "1.2.0" or "v1.2.0". Anything else — "1.2.0-beta.1", "nightly" — is not a release version.
        init?(_ text: String) {
            var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
            if s.hasPrefix("v") || s.hasPrefix("V") { s = s.dropFirst() }
            let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            self.parts = parts.map { $0! }
        }

        /// 1.10 > 1.9; a missing trailing part counts as 0, so 1.2 == 1.2.0.
        static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.parts.count, b.parts.count) {
                let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
                if x != y { return x < y }
            }
            return false
        }

        static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
        var description: String { parts.map(String.init).joined(separator: ".") }
    }

    struct Release: Equatable {
        var version: Version
        var tag: String
        var notes: String
        var page: URL        // the release on GitHub ("What's new…")
        var zip: URL
        var signature: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Release, Double)
        case installing(Release)
        case failed(Release?, String)   // a check (no release) or an install (that release) failed
    }

    @Published private(set) var state = State.idle
    @Published private(set) var lastChecked: Date?
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: "updates.automatic") } }

    /// The update on offer (or in progress), for the panel card, a badge or the hover card.
    var available: Release? {
        switch state {
        case .available(let r), .downloading(let r, _), .installing(let r): return r
        case .failed(let r, _): return r
        default: return nil
        }
    }

    let appName: String
    let bundleID: String
    let currentVersion: Version
    let feed: URL
    let pageURL: URL       // the releases page: the manual way, offered when self-update can't work
    let licenceURL: URL
    let testRun: Bool
    private let key: Data
    private let testLog: URL?
    private let defaults: UserDefaults
    private var timer: Timer?
    private var download: Download?
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        appName = info["CFBundleName"] as? String ?? "App"
        bundleID = Bundle.main.bundleIdentifier ?? "io.github.cyborgfingers.\(appName.lowercased())"
        currentVersion = Version(info["CFBundleShortVersionString"] as? String ?? "") ?? Version("0")!
        pageURL = URL(string: "https://github.com/Weta-Technologies/\(appName)/releases/latest")!
        licenceURL = URL(string: "https://github.com/Weta-Technologies/\(appName)/blob/main/LICENSE")!
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--update-test"), i + 2 < args.count, let url = URL(string: args[i + 1]), let key = Data(base64Encoded: args[i + 2]) {
            testRun = true
            feed = url
            self.key = key
            testLog = i + 3 < args.count ? URL(fileURLWithPath: args[i + 3]) : nil
            defaults = UserDefaults(suiteName: bundleID + ".update-test")!
        } else {
            testRun = false
            feed = URL(string: "https://api.github.com/repos/Weta-Technologies/\(appName)/releases/latest")!
            key = Data(base64Encoded: Self.publisherKey)!
            testLog = nil
            defaults = .standard
        }
        automatic = defaults.object(forKey: "updates.automatic") as? Bool ?? true
        lastChecked = defaults.object(forKey: "updates.lastChecked") as? Date
    }

    /// Once, from applicationDidFinishLaunching. One timer: it first fires 10 s after launch or when the daily check
    /// is due, whichever is later, then every 24 h. In a test run it drives the whole flow instead and exits.
    func start() {
        if testRun {
            log("running \(currentVersion) from \(Bundle.main.bundleURL.path)")
            check(manual: true)
            return
        }
        let due = max(Date().addingTimeInterval(Self.firstCheckDelay), (lastChecked ?? .distantPast).addingTimeInterval(Self.checkInterval))
        let timer = Timer(fire: due, interval: Self.checkInterval, repeats: true) { _ in MainActor.assumeIsolated { Updater.shared.checkIfDue() } }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// --shots: a sample release on offer, so the update card can be rendered without a network or a release.
    func offerSample() {
        let next = Version("\(currentVersion.parts.first ?? 1).\((currentVersion.parts.dropFirst().first ?? 0) + 1).0")!
        let page = URL(string: "https://github.com/Weta-Technologies/\(appName)/releases/tag/v\(next)")!
        state = .available(Release(version: next, tag: "v\(next)", notes: "Sample release notes: what changed, in a line or two.", page: page, zip: page, signature: page))
    }

    private func checkIfDue() {
        guard automatic, lastChecked.map({ Date().timeIntervalSince($0) >= Self.checkInterval }) ?? true else { return }
        check(manual: false)
    }

    // MARK: Checking

    func check(manual: Bool) {
        switch state {
        case .checking, .downloading, .installing: return
        case .available where !manual: return   // an offer is on the table; leave it
        default: break
        }
        state = .checking
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(appName)/\(currentVersion) (updater)", forHTTPHeaderField: "User-Agent")
        if let etag = defaults.string(forKey: "updates.etag") { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.checked(data, response as? HTTPURLResponse, error, manual: manual) } }
        }.resume()
    }

    private func checked(_ data: Data?, _ response: HTTPURLResponse?, _ error: Error?, manual: Bool) {
        var body: Data?
        if let response, response.statusCode == 304 {
            body = defaults.data(forKey: "updates.feed")
        } else if let response, response.statusCode == 200, let data {
            body = data
            defaults.set(data, forKey: "updates.feed")
            defaults.set(response.value(forHTTPHeaderField: "ETag"), forKey: "updates.etag")
        }
        guard let body else {
            let why = error?.localizedDescription ?? response.map { "GitHub answered \($0.statusCode)" } ?? "no answer"
            log("check failed: \(why)")
            state = manual ? .failed(nil, "Couldn't check for updates: \(why)") : .idle
            if testRun { exit(1) }
            return
        }
        lastChecked = Date()
        defaults.set(lastChecked, forKey: "updates.lastChecked")
        // A release without the zip + signature (a DMG-only one) is nothing this app can update to.
        guard let release = Self.parse(feed: body, appName: appName), release.version > currentVersion,
              manual || release.tag != defaults.string(forKey: "updates.skipped") else {
            log("up to date at \(currentVersion)")
            state = .upToDate
            if testRun { exit(0) }
            return
        }
        log("update available: \(release.version) (\(release.tag))")
        state = .available(release)
        notify(release)
        if testRun { install() }
    }

    /// The release in GitHub's JSON, if it is a proper release with this app's two update assets. Pure, for --selftest.
    nonisolated static func parse(feed: Data, appName: String) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: feed) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String, let version = Version(tag),
              let page = (json["html_url"] as? String).flatMap({ URL(string: $0) }),
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        func asset(_ name: String) -> URL? {
            assets.first { $0["name"] as? String == name }.flatMap { ($0["browser_download_url"] as? String).flatMap { URL(string: $0) } }
        }
        guard let zip = asset("\(appName).app.zip"), let signature = asset("\(appName).app.zip.sig") else { return nil }
        return Release(version: version, tag: tag, notes: json["body"] as? String ?? "", page: page, zip: zip, signature: signature)
    }

    // MARK: Installing

    func later() { state = .idle }

    func skip() {
        if let release = available { defaults.set(release.tag, forKey: "updates.skipped") }
        state = .idle
    }

    func install() {
        guard let release = available else { return }
        if let why = Self.installBlocker(Bundle.main.bundleURL) { return fail(release, why) }
        state = .downloading(release, 0)
        log("downloading \(release.zip.absoluteString)")
        session.dataTask(with: release.signature) { data, _, error in   // the signature first (small), then the zip with progress
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let data, let signature = Data(base64Encoded: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), signature.count == 64 else {
                    return self.fail(release, "Couldn't download the update's signature\(error.map { ": \($0.localizedDescription)" } ?? "").")
                }
                let download = Download()
                download.progress = { p in MainActor.assumeIsolated { if case .downloading = self.state { self.state = .downloading(release, p) } } }
                download.finished = { zip, error in MainActor.assumeIsolated { self.downloaded(release, zip: zip, signature: signature, error: error) } }
                self.download = download
                let c = URLSessionConfiguration.ephemeral
                c.timeoutIntervalForRequest = 30
                c.timeoutIntervalForResource = 600
                URLSession(configuration: c, delegate: download, delegateQueue: .main).downloadTask(with: release.zip).resume()
            } }
        }.resume()
    }

    private func downloaded(_ release: Release, zip: URL?, signature: Data, error: Error?) {
        download = nil
        guard let zip, let data = FileManager.default.contents(atPath: zip.path) else {
            return fail(release, "Couldn't download the update\(error.map { ": \($0.localizedDescription)" } ?? "").")
        }
        defer { try? FileManager.default.removeItem(at: zip) }
        guard Self.verify(data, signature: signature, key: key) else {
            return fail(release, "The download's signature doesn't match Weta Technologies' signing key, so it was not installed.")
        }
        log("signature OK (\(data.count) bytes)")
        state = .installing(release)
        let stage = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".\(appName).update-\(getpid())", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: stage)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            let new = try Self.unzip(zip, into: stage, expecting: "\(appName).app")
            if let why = Self.sanityCheck(new, bundleID: bundleID, version: release.version, current: currentVersion, requirement: Self.ownRequirement) { throw Failure(why) }
            log("staged \(new.path)")
            try handOff(new)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            fail(release, "The update couldn't be installed: \(error.localizedDescription)")
        }
    }

    /// Why this copy can't replace itself where it is (nil = it can).
    nonisolated static func installBlocker(_ bundle: URL) -> String? {
        let name = bundle.lastPathComponent, parent = bundle.deletingLastPathComponent().path
        if bundle.path.contains("/AppTranslocation/") {
            return "macOS is running \(name) from a temporary place. Move it into Applications, open it from there and update again."
        }
        guard FileManager.default.isWritableFile(atPath: parent), FileManager.default.isWritableFile(atPath: bundle.path) else {
            return "\(name) can't be replaced where it is (\(parent)). Move it into Applications, or download the new version."
        }
        return nil
    }

    nonisolated static func verify(_ data: Data, signature: Data, key: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    nonisolated static func unzip(_ zip: URL, into dir: URL, expecting name: String) throws -> URL {
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) else { throw Failure("the archive didn't unpack") }
        let app = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else { throw Failure("the archive doesn't contain \(name)") }
        return app
    }

    /// nil when the unpacked bundle is what it claims to be: this bundle id, the advertised (newer) version, a
    /// signature that verifies, and — given a requirement — one made by the same developer as this app.
    nonisolated static func sanityCheck(_ app: URL, bundleID: String, version: Version, current: Version, requirement: SecRequirement?) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { return "the new app has no Info.plist" }
        guard info["CFBundleIdentifier"] as? String == bundleID else { return "the new app has a different bundle identifier" }
        let found = info["CFBundleShortVersionString"] as? String ?? "?"
        guard let v = Version(found), v == version, v > current else { return "the new app is version \(found), not the advertised \(version)" }
        guard let exe = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(exe)").path) else { return "the new app has no executable" }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { return "the new app's code signature doesn't verify" }
        if let requirement, !satisfies(app, requirement) { return "the new app isn't signed by the same developer as this one" }
        return nil
    }

    /// This app's designated requirement when it carries a team identity (Developer ID), so an update must be signed by
    /// the same developer as well as by the publisher key. nil for ad-hoc builds, whose requirement only ever matches
    /// themselves.
    nonisolated static var ownRequirement: SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// The bundle's signature is valid and meets `requirement`.
    nonisolated static func satisfies(_ app: URL, _ requirement: SecRequirement) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// Starts the swap script detached and quits. It relaunches the app with this launch's arguments.
    private func handOff(_ new: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(appName)-update-swap-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("swap.sh")
        try Self.swapScript.write(to: script, atomically: true, encoding: .utf8)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [script.path, String(getpid()), Bundle.main.bundleURL.path, new.path, "open -n"] + CommandLine.arguments.dropFirst()
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        log("handing off to \(script.path); quitting")
        NSApp.terminate(nil)
    }

    /// Waits for the app to exit, swaps the bundles with two renames and relaunches. Detaches from the app first
    /// (the nohup line), so the app's exit can't take it down. The old bundle is only removed after the new one
    /// is in place, and put back if that rename fails.
    nonisolated static let swapScript = """
    #!/bin/sh
    # swap.sh <pid> <old.app> <new.app> <relaunch command> [args for the app] — written and started by Updater.swift
    set -u
    if [ -z "${UPDATE_SWAP_DETACHED:-}" ]; then UPDATE_SWAP_DETACHED=1 nohup /bin/sh "$0" "$@" >/dev/null 2>&1 & exit 0; fi
    pid=$1 old=$2 new=$3 relaunch=$4
    shift 4
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1)); [ $i -lt 600 ] || { rm -rf "$(dirname "$new")"; exit 1; }   # two minutes, then give up
      sleep 0.2
    done
    ok=1
    aside="$(dirname "$old")/.$(basename "$old").old.$$"
    if mv "$old" "$aside"; then
      if mv "$new" "$old"; then rm -rf "$aside"; ok=0; else mv "$aside" "$old"; fi
    fi
    rm -rf "$(dirname "$new")"
    $relaunch "$old" --args "$@"
    rm -rf "$(dirname "$0")"
    exit $ok
    """

    private func fail(_ release: Release, _ message: String) {
        log("FAILED: \(message)")
        if !testRun { NSLog("\(appName) updater: \(message)") }
        state = .failed(release, message)
        if testRun { exit(1) }
    }

    private func notify(_ release: Release) {
        guard !testRun, Bundle.main.bundleURL.pathExtension == "app", defaults.string(forKey: "updates.notified") != release.tag else { return }
        defaults.set(release.tag, forKey: "updates.notified")
        let title = "\(appName) \(release.version) is available", id = "update-\(release.tag)"
        UNUserNotificationCenter.current().getNotificationSettings { settings in   // only if the user already allowed notifications; never asks
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = "Open the panel and click Update Now."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    private func log(_ line: String) {
        guard testRun else { return }
        let text = "UPDATE-TEST: \(line)\n"
        print(text, terminator: "")
        fflush(stdout)
        guard let testLog, let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: testLog) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: testLog)
        }
    }

    /// A menu-bar template image with a small dot at its top-right corner, for apps that badge their glyph.
    nonisolated static func badged(_ image: NSImage) -> NSImage {
        let size = image.size, r: CGFloat = 2.25
        let dot = NSRect(x: size.width - 2 * r, y: size.height - 2 * r, width: 2 * r, height: 2 * r)
        let out = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.black.setFill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut   // a clear ring, so the dot reads on the glyph
            NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        out.isTemplate = true
        return out
    }

    // MARK: Self-test

    /// The pure parts, for --selftest: versions, the feed parser, signatures (a throwaway key pair) and the swap
    /// script on a fake bundle in a temp folder — a success, and a failure that must put the old bundle back.
    nonisolated static func selfTest() {
        func check(_ ok: Bool, _ what: String) { if !ok { fatalError("FAIL: updater: \(what)") } }
        check(Version("1.10.0")! > Version("1.9.0")! && Version("2.0.0")! > Version("1.99.99")!, "1.10.0 > 1.9.0")
        check(Version("v1.2.0") == Version("1.2.0") && Version("1.2") == Version("1.2.0") && !(Version("1.1.0")! > Version("1.1.0")!), "tags with and without v")
        check(Version("1.2.0-beta.1") == nil && Version("nightly") == nil && Version("") == nil && Version("1..2") == nil, "pre-releases and junk don't parse")

        let feed = """
        {"tag_name":"v1.2.0","draft":false,"prerelease":false,"html_url":"https://github.com/Weta-Technologies/App/releases/tag/v1.2.0","body":"## New\\n- a thing",
         "assets":[{"name":"App.dmg","browser_download_url":"https://x/App.dmg"},{"name":"App.app.zip","browser_download_url":"https://x/App.app.zip"},
                   {"name":"App.app.zip.sig","browser_download_url":"https://x/App.app.zip.sig"}]}
        """
        let release = parse(feed: Data(feed.utf8), appName: "App")
        check(release?.version == Version("1.2.0") && release?.tag == "v1.2.0" && release?.zip.absoluteString == "https://x/App.app.zip"
              && release?.signature.lastPathComponent == "App.app.zip.sig" && release?.notes.hasPrefix("## New") == true
              && release?.page.absoluteString.hasSuffix("/tag/v1.2.0") == true, "feed parses")
        check(parse(feed: Data(feed.utf8), appName: "Other") == nil, "no assets for another app")
        check(parse(feed: Data(feed.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true").utf8), appName: "App") == nil, "pre-release ignored")
        check(parse(feed: Data("not json".utf8), appName: "App") == nil, "junk feed")

        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
        let blob = Data((0..<5000).map { UInt8($0 & 255) }), signature = try! key.signature(for: blob)
        check(verify(blob, signature: signature, key: key.publicKey.rawRepresentation), "good signature")
        check(!verify(blob + [1], signature: signature, key: key.publicKey.rawRepresentation), "tampered data")
        check(!verify(blob, signature: signature, key: other.publicKey.rawRepresentation), "wrong key")
        check(!verify(blob, signature: Data(repeating: 0, count: 64), key: key.publicKey.rawRepresentation) && !verify(blob, signature: signature, key: Data(repeating: 1, count: 31)), "junk signature and key")

        let files = FileManager.default
        let dir = files.temporaryDirectory.appendingPathComponent("updater-selftest-\(getpid())", isDirectory: true)
        try? files.removeItem(at: dir)
        let apps = dir.appendingPathComponent("Apps"), old = apps.appendingPathComponent("Fake.app"), stage = dir.appendingPathComponent(".Fake.update")
        for (app, version) in [(old, "1"), (stage.appendingPathComponent("Fake.app"), "2")] {
            try! files.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try! version.write(to: app.appendingPathComponent("Contents/v"), atomically: true, encoding: .utf8)
        }
        func swap(new: String) -> Int32 {
            let script = dir.appendingPathComponent("swap-\(new.hashValue)/swap.sh")   // the script removes its own folder
            try! files.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! swapScript.write(to: script, atomically: true, encoding: .utf8)
            let app = Process()   // stands in for the running app: the script has to wait for it
            app.executableURL = URL(fileURLWithPath: "/bin/sleep")
            app.arguments = ["0.4"]
            try! app.run()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.environment = ["UPDATE_SWAP_DETACHED": "1"]   // in the foreground, so we can wait for it
            task.arguments = [script.path, String(app.processIdentifier), old.path, new, "/usr/bin/true"]
            task.standardError = FileHandle.nullDevice   // the failure case complains, as it should
            try! task.run()
            task.waitUntilExit()
            app.waitUntilExit()
            return task.terminationStatus
        }
        let installed = { try? String(contentsOf: old.appendingPathComponent("Contents/v"), encoding: .utf8) }
        let tidy = { (try? files.contentsOfDirectory(atPath: apps.path)) == ["Fake.app"] }
        check(swap(new: stage.appendingPathComponent("Fake.app").path) == 0 && installed() == "2" && !files.fileExists(atPath: stage.path) && tidy(), "swap installs the new bundle and cleans up")
        check(swap(new: dir.appendingPathComponent("missing/Fake.app").path) == 1 && installed() == "2" && tidy(), "a failed swap puts the old bundle back")
        // Signature requirements on a fake ad-hoc-signed bundle: it meets a requirement naming its own identifier, not
        // another's, and never a Developer ID shape; this app meets its own requirement whenever it has one.
        let signed = dir.appendingPathComponent("Signed.app")
        try! files.createDirectory(at: signed.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try! files.copyItem(atPath: "/bin/ls", toPath: signed.appendingPathComponent("Contents/MacOS/Signed").path)
        try! (["CFBundleIdentifier": "io.github.cyborgfingers.fake", "CFBundleExecutable": "Signed", "CFBundlePackageType": "APPL"] as NSDictionary)
            .write(to: signed.appendingPathComponent("Contents/Info.plist"))
        check(run("/usr/bin/codesign", ["--force", "--sign", "-", signed.path]), "a fake bundle signs")
        func requirement(_ text: String) -> SecRequirement {
            var r: SecRequirement?
            SecRequirementCreateWithString(text as CFString, [], &r)
            return r!
        }
        check(satisfies(signed, requirement("identifier \"io.github.cyborgfingers.fake\"")), "a bundle meets its own identifier requirement")
        check(!satisfies(signed, requirement("identifier \"io.github.cyborgfingers.other\"")), "…and not another's")
        check(!satisfies(signed, requirement("anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")), "an ad-hoc bundle never passes for a Developer ID one")
        check(sanityCheck(signed, bundleID: "io.github.cyborgfingers.fake", version: Version("0")!, current: Version("0")!, requirement: nil)?.contains("version") == true, "sanity check reads the fake bundle")
        if let own = ownRequirement { check(satisfies(Bundle.main.bundleURL, own), "this app meets its own designated requirement") }
        try? files.removeItem(at: dir)
        check(installBlocker(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/Fake.app"))?.contains("Move it into Applications") == true
              && installBlocker(URL(fileURLWithPath: "/System/Library/CoreServices/Fake.app")) != nil, "unwritable places are refused")
    }
}

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// The zip download: progress while it comes, the file when it is done. Delegate calls land on the main queue.
private final class Download: NSObject, URLSessionDownloadDelegate {
    var progress: ((Double) -> Void)?
    var finished: ((URL?, Error?) -> Void)?
    private var saved: URL?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(getpid()).zip")
        try? FileManager.default.removeItem(at: dest)
        saved = (try? FileManager.default.moveItem(at: location, to: dest)) == nil ? nil : dest
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let failure = error ?? (status == 200 ? nil : Failure("the server answered \(status)"))
        finished?(failure == nil ? saved : nil, failure)
        session.finishTasksAndInvalidate()
    }
}

// MARK: - Panel views

/// The card while an update is on offer, downloading, installing or failed. Goes near the top of the panel.
struct UpdateCard: View {
    @ObservedObject var updater: Updater
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let release = updater.available {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(updater.appName) \(release.version.description) is available").font(.body.weight(.semibold))
                        Text("You have \(updater.currentVersion.description).").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if !Self.summary(release.notes).isEmpty {
                    Text(Self.summary(release.notes)).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                switch updater.state {
                case .downloading(_, let progress):
                    ProgressView(value: progress) { Text("Downloading…").font(.caption) }.progressViewStyle(.linear).controlSize(.small)
                case .installing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking and installing… \(updater.appName) will quit and reopen.").font(.caption)
                    }
                case .failed(_, let message):
                    Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open download page") { openURL(updater.pageURL) }
                        Spacer()
                        Button("Dismiss") { updater.later() }
                    }
                    .controlSize(.small)
                default:
                    HStack(spacing: 8) {
                        Button("What's new…") { openURL(release.page) }.buttonStyle(.link).font(.caption)
                            .help("The release notes on GitHub.")
                        Spacer()
                        Button("Skip") { updater.skip() }.help("Skip this version: no more reminders about \(release.version.description).")
                        Button("Later") { updater.later() }.help("Hide this until the next check.")
                        Button("Update Now") { updater.install() }.buttonStyle(.borderedProminent)
                            .help("Downloads \(updater.appName) \(release.version.description), checks Weta Technologies' signature on it, then quits and reopens as the new version. Your settings are kept.")
                    }
                    .controlSize(.small)
                    Text((try? AttributedString(markdown: "By updating you accept the \(updater.appName) [licence](\(updater.licenceURL.absoluteString)). Your settings are kept."))
                         ?? AttributedString("By updating you accept the \(updater.appName) licence. Your settings are kept."))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
            .accessibilityElement(children: .contain)
        }
    }

    /// The first few lines of the notes as plain text (no Markdown headings, bullets or bold).
    static func summary(_ notes: String) -> String {
        notes.split(separator: "\n").map { line in
            line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
                .drop { "#-*• ".contains($0) }.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }.prefix(3).joined(separator: " ")
    }
}

/// The settings rows: automatic checks, Check for Updates, and what the last check found.
struct UpdateRows: View {
    @ObservedObject var updater: Updater

    private var checking: Bool { if case .checking = updater.state { return true }; return false }

    /// Always one line, so the row (and the popover around it) never changes height while a check runs.
    private var status: String {
        let ago = updater.lastChecked.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }
        switch updater.state {
        case .checking: return "Checking for updates…"
        case .upToDate: return "\(updater.appName) \(updater.currentVersion.description) is up to date\(ago.map { " · checked \($0)" } ?? "")."
        case .failed(.none, let message): return message
        default: return ago.map { "Last checked \($0)." } ?? "Not checked yet."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Check for updates automatically", isOn: $updater.automatic)
                    .toggleStyle(.checkbox)
                    .help("About once a day, \(updater.appName) asks GitHub whether a newer release exists — a plain web request, nothing about you or your Mac. Updates are only installed when you click Update Now.")
                Spacer()
                Button("Check Now") { updater.check(manual: true) }   // one label: a width change would reflow the row
                    .disabled(checking)
                    .help("Ask GitHub now whether a newer \(updater.appName) exists.")
            }
            .font(.callout)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(status)
        }
    }
}
