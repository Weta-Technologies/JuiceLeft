import AppKit
import Security
import SwiftUI

/// The one administrator prompt — shared by every CyborgFingers app that has a root helper. `Admin.run` asks macOS for
/// the `system.privilege.admin` right through Authorization Services: the system's own sheet ("<App> wants to make
/// changes"), which offers Touch ID on Macs that have it, with the password as the fallback. It then runs the app's
/// installer script as root through AuthorizationExecuteWithPrivileges, bound at run time. That call is deprecated
/// but is still the only public way to run a process as root with a right the app has just acquired: its
/// replacements (SMJobBless, SMAppService daemons) need a Developer ID team identity, which these ad-hoc-signed apps
/// don't have. What runs is `/bin/sh <installer> <args>`, once. From then on the installed helper only ever
/// changes itself from files signed with the publisher key (HelperUpdate), so this is the one moment the
/// user-writable app bundle is trusted — the same trust the old `do shell script` prompt had.
enum Admin {
    enum Outcome: Equatable { case done, cancelled, failed(String) }

    private typealias Execute = @convention(c) (AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags, UnsafePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?) -> OSStatus
    private static let execute = dlsym(dlopen(nil, RTLD_NOW), "AuthorizationExecuteWithPrivileges").map { unsafeBitCast($0, to: Execute.self) }

    /// Runs `/bin/sh script args…` as root after the system's authorization sheet, and waits for it to finish.
    static func run(_ script: String, _ args: [String], prompt: String) -> Outcome {
        guard let execute else { return .failed("This macOS can't run the installer.") }
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return .failed("Couldn't start the authorization.") }
        defer { AuthorizationFree(ref, [.destroyRights]) }

        let right = strdup(kAuthorizationRightExecute)!, promptKey = strdup(kAuthorizationEnvironmentPrompt)!, text = strdup(prompt)!
        defer { free(right); free(promptKey); free(text) }
        var item = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
        var promptItem = AuthorizationItem(name: promptKey, valueLength: strlen(text), value: UnsafeMutableRawPointer(text), flags: 0)
        let status = withUnsafeMutablePointer(to: &item) { item in
            withUnsafeMutablePointer(to: &promptItem) { promptItem in
                var rights = AuthorizationRights(count: 1, items: item)
                var environment = AuthorizationEnvironment(count: 1, items: promptItem)
                return AuthorizationCopyRights(ref, &rights, &environment, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        if status == errAuthorizationCanceled { return .cancelled }
        guard status == errAuthorizationSuccess else { return .failed("macOS refused the authorization (\(status)).") }

        let argv: [UnsafeMutablePointer<CChar>?] = ([script] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pipe: UnsafeMutablePointer<FILE>?
        let started = argv.withUnsafeBufferPointer { buffer in
            "/bin/sh".withCString { sh in execute(ref, sh, [], buffer.baseAddress!, &pipe) }
        }
        guard started == errAuthorizationSuccess else { return .failed("The installer couldn't be started (\(started)).") }
        if let pipe {   // the installer's output: EOF means it has finished
            while fgetc(pipe) != EOF {}
            fclose(pipe)
        }
        return .done
    }
}

/// When an app update changed the helper files, the installed root helper takes them from the app bundle by itself —
/// no prompt — as long as the bundle carries a manifest signed with the CyborgFingers publisher key (release builds
/// do; see release.sh). The app only writes its bundle path to a request file. The root side copies the files into a
/// root-owned stage first, verifies the manifest's signature and every file's hash with its own root-owned verifier
/// and key, refuses downgrades, and only then installs. Anything else is ignored, and the app offers the setup card.
enum HelperUpdate {
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
    static var requestPath: String { "/Library/Application Support/\(appName)/update" }

    /// The bundle carries a signed manifest, so an installed helper can take its files without a prompt.
    static var bundleIsSigned: Bool { Bundle.main.path(forResource: "helper-manifest", ofType: "sig") != nil }

    /// Asks the installed helper to update itself from this bundle, then reports whether `ready` came true within
    /// a few seconds (launchd throttles the helper to a run every couple of seconds).
    @MainActor static func request(ready: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard bundleIsSigned, FileManager.default.isWritableFile(atPath: requestPath),
              (try? (Bundle.main.bundleURL.path + "\n").write(toFile: requestPath, atomically: false, encoding: .utf8)) != nil else { return completion(false) }
        var tries = 0
        func poll() {
            tries += 1
            if ready() { return completion(true) }
            if tries >= 8 { return completion(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { poll() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { poll() } }
    }
}

/// First launch, or the helper missing or from another version: one friendly card, one prompt. Each app says in
/// `what` which of its features the helper enables.
struct SetupCard: View {
    let appName: String
    let what: String          // "Lid-closed mode and the charging light"
    let updating: Bool        // the helper is installed, but from another version
    let busy: Bool            // a signed self-update is in flight
    let setUp: () -> Void
    let later: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield.fill").font(.title3).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(updating ? "\(appName)'s helper needs updating" : "Welcome to \(appName)").font(.body.weight(.semibold))
                    Text("\(what) need a small helper that runs as an administrator. Set it up once — macOS asks for your password, or Touch ID — and nothing will ask again.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            if busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating the helper…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Later") { later() }.help("Skip for now. Features that need the helper stay off, each with its own Set up button.")
                    Button("Set up now") { setUp() }.buttonStyle(.borderedProminent)
                        .help("One administrator prompt installs everything \(appName) will ever need as root.")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(contrast == .increased ? 0.6 : 0)))
        .accessibilityElement(children: .contain)
    }
}
