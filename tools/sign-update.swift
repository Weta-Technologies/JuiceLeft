// sign-update — the CyborgFingers release signature (Ed25519, CryptoKit). One publisher key signs every app's
// updates and helper manifests; only its public half is ever in a repo (cyborgfingers.pub, Updater.swift).
//
//   sign-update keygen                          once: make the key pair, private half → login Keychain, prints the public half
//   sign-update pubkey                          prints the public half of the Keychain key
//   sign-update sign <file> [--key-file <f>]    writes <file>.sig: the base64 Ed25519 signature of <file>'s bytes
//   sign-update verify <file> <public-key>      checks <file>.sig against a base64 public key (exit 1 if bad)
//   sign-update testkey <dir>                   a throwaway pair for tests: <dir>/private.key, prints the public half
//
// Build: swiftc -O tools/sign-update.swift -o build/sign-update
import CryptoKit
import Foundation

let account = "cyborgfingers-updates", service = "CyborgFingers update signing key"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sign-update: \(message)\n".utf8))
    exit(1)
}

/// /usr/bin/security, never a shell: the private key only ever travels as one argument or one line of output.
func security(_ args: [String]) -> (ok: Bool, out: String) {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = args
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return (false, "") }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    task.waitUntilExit()
    return (task.terminationStatus == 0, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

func keychainKey() -> Curve25519.Signing.PrivateKey {
    let found = security(["find-generic-password", "-a", account, "-s", service, "-w"])
    guard found.ok, let raw = Data(base64Encoded: found.out), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("no publisher key in the login Keychain (run `sign-update keygen` once, or restore it from your password manager)") }
    return key
}

func privateKey(from file: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("can't read a private key from \(file)") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    guard !security(["find-generic-password", "-a", account, "-s", service]).ok else { fail("a publisher key already exists in the Keychain; not replacing it") }
    let key = Curve25519.Signing.PrivateKey()
    let added = security(["add-generic-password", "-a", account, "-s", service, "-T", "/usr/bin/security", "-w", key.rawRepresentation.base64EncodedString()])
    guard added.ok else { fail("the Keychain refused the key") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "pubkey":
    print(keychainKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count >= 2, let data = FileManager.default.contents(atPath: args[1]) else { fail("usage: sign <file> [--key-file <f>]") }
    let key = args.count >= 4 && args[2] == "--key-file" ? privateKey(from: args[3]) : keychainKey()
    guard let signature = try? key.signature(for: data) else { fail("signing failed") }
    do { try (signature.base64EncodedString() + "\n").write(toFile: args[1] + ".sig", atomically: true, encoding: .utf8) }
    catch { fail("can't write \(args[1]).sig: \(error.localizedDescription)") }
    print("signed \(args[1]) → \(args[1]).sig")
case "verify":
    guard args.count == 3, let data = FileManager.default.contents(atPath: args[1]),
          let sigText = try? String(contentsOfFile: args[1] + ".sig", encoding: .utf8),
          let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let raw = Data(base64Encoded: args[2]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { fail("usage: verify <file> <public-key-base64> (needs <file>.sig)") }
    guard key.isValidSignature(signature, for: data) else { fail("BAD signature on \(args[1])") }
    print("good signature on \(args[1])")
case "testkey":
    guard args.count == 2 else { fail("usage: testkey <dir>") }
    let key = Curve25519.Signing.PrivateKey()
    do {
        try FileManager.default.createDirectory(atPath: args[1], withIntermediateDirectories: true)
        try (key.rawRepresentation.base64EncodedString() + "\n").write(toFile: args[1] + "/private.key", atomically: true, encoding: .utf8)
    } catch { fail("can't write the test key: \(error.localizedDescription)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
default:
    fail("usage: keygen | pubkey | sign <file> [--key-file <f>] | verify <file> <public-key> | testkey <dir>")
}
