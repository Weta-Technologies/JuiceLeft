// helper-verify — the root-owned gate on helper updates: `helper-verify <public-key-file> <stage-dir> [<installed-manifest>]`.
// Installed beside the helper at first setup and run by it as root, never from the app bundle. The stage holds the
// candidate files the helper already copied out of the app bundle (so nothing can change under it), including
// helper-manifest and helper-manifest.sig. It passes when: the manifest's Ed25519 signature checks out against the
// public key in <public-key-file> (base64); every "<sha256>  <name>" line matches the SHA-256 of <stage>/<name>;
// nothing else is in the stage; and the manifest's "version" line is not lower than the installed manifest's.
// Prints the version and exits 0, or the reason and exits 1.
//
// Manifest: "version 1.2.0" then one shasum -a 256 line per file. Build: swiftc -O tools/helper-verify.swift -o …
import CryptoKit
import Foundation

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("helper-verify: \(reason)\n".utf8))
    exit(1)
}

func version(of manifest: String) -> [Int]? {
    guard let line = manifest.split(separator: "\n").first, line.hasPrefix("version ") else { return nil }
    let parts = line.dropFirst("version ".count).split(separator: ".").map { Int($0) }
    return parts.allSatisfy { $0 != nil } && !parts.isEmpty ? parts.map { $0! } : nil
}

/// 1.10 > 1.9; missing trailing parts count as 0.
func isLower(_ a: [Int], than b: [Int]) -> Bool {
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x < y }
    }
    return false
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 || args.count == 3 else { fail("usage: helper-verify <public-key-file> <stage-dir> [<installed-manifest>]") }
let files = FileManager.default
guard let keyText = try? String(contentsOfFile: args[0], encoding: .utf8),
      let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { fail("no usable public key at \(args[0])") }
let stage = args[1]
guard let manifestData = files.contents(atPath: stage + "/helper-manifest"),
      let sigText = try? String(contentsOfFile: stage + "/helper-manifest.sig", encoding: .utf8),
      let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("no manifest or signature in the stage") }
guard key.isValidSignature(signature, for: manifestData) else { fail("BAD manifest signature") }

let manifest = String(decoding: manifestData, as: UTF8.self)
guard let newVersion = version(of: manifest) else { fail("no version line in the manifest") }
if args.count == 3, let installed = try? String(contentsOfFile: args[2], encoding: .utf8), let old = version(of: installed), isLower(newVersion, than: old) {
    fail("would downgrade the helper (\(newVersion.map(String.init).joined(separator: ".")) < \(old.map(String.init).joined(separator: ".")))")
}

var listed: Set<String> = []
for line in manifest.split(separator: "\n").dropFirst() {
    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count == 2, fields[0].count == 64 else { fail("malformed manifest line: \(line)") }
    let name = String(fields[1])
    guard !name.contains("/"), name != "helper-manifest", name != "helper-manifest.sig",
          let data = files.contents(atPath: stage + "/" + name) else { fail("listed file missing from the stage: \(name)") }
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == fields[0] else { fail("hash mismatch: \(name)") }
    listed.insert(name)
}
guard !listed.isEmpty else { fail("the manifest lists no files") }
let present = Set((try? files.contentsOfDirectory(atPath: stage)) ?? []).subtracting(["helper-manifest", "helper-manifest.sig"])
guard present == listed else { fail("stage holds files the manifest doesn't list: \(present.subtracting(listed).sorted())") }
print(newVersion.map(String.init).joined(separator: "."))
