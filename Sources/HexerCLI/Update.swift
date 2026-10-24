import Foundation
import HexerCore

/// `update keygen|public-key|sign|verify …`
///
/// Ed25519 signatures of update disk images (see `UpdateSignature`): the release workflow signs
/// each disk image, the app verifies it before installing.
func update(_ args: [String]) {
    let usage = """
        update keygen PRIVATE_KEY_FILE | update public-key [--key-file FILE] |
               update sign [--key-file FILE] DMG VERSION |
               update verify (--public-key KEY | --app APP) DMG VERSION SIGNATURE_FILE
        """
    let rest = Array(args.dropFirst())
    switch args.first {
    case "keygen":
        let path = Arguments(rest, command: "update keygen").expect(1, usage: usage)[0]
        let keys = UpdateSignature.makeKeyPair()
        // A new file only, readable by its owner alone.
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { fail("update keygen: cannot create \(path): \(String(cString: strerror(errno)))") }
        let line = Array((keys.privateKey + "\n").utf8)
        guard write(fd, line, line.count) == line.count, close(fd) == 0 else {
            fail("update keygen: cannot write \(path): \(String(cString: strerror(errno)))")
        }
        print(keys.publicKey)
    case "public-key":
        let a = Arguments(rest, command: "update public-key", options: ["--key-file"])
        _ = a.expect(0, usage: usage)
        print(attempt("update public-key") { try UpdateSignature.publicKey(forPrivateKey: privateKey(a)) })
    case "sign":
        let a = Arguments(rest, command: "update sign", options: ["--key-file"])
        let p = a.expect(2, usage: usage)
        print(attempt("update sign") {
            try UpdateSignature.sign(fileAt: URL(fileURLWithPath: p[0]), version: p[1], privateKey: privateKey(a))
        })
    case "verify":
        let a = Arguments(rest, command: "update verify", options: ["--public-key", "--app"])
        let p = a.expect(3, usage: usage)
        let publicKey: String
        switch (a.value("--public-key"), a.value("--app")) {
        case (let key?, nil): publicKey = key
        case (nil, let app?):
            let plist = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let key = info["HexerUpdatePublicKey"] as? String else {
                fail("update verify: \(plist.path) has no HexerUpdatePublicKey")
            }
            publicKey = key
        default: fail("usage: hexer-cli \(usage)")
        }
        let signature = attempt("update verify") { try String(contentsOfFile: p[2], encoding: .utf8) }
        attempt("update verify") {
            try UpdateSignature.verify(fileAt: URL(fileURLWithPath: p[0]), version: p[1], signature: signature, publicKey: publicKey)
        }
        print("valid")
    default:
        fail("usage: hexer-cli \(usage)")
    }
}

/// The private key from `--key-file`, else from the HEXER_UPDATE_KEY environment variable.
private func privateKey(_ a: Arguments) -> String {
    if let path = a.value("--key-file") {
        return attempt("update") { try String(contentsOfFile: path, encoding: .utf8) }
    }
    guard let key = ProcessInfo.processInfo.environment["HEXER_UPDATE_KEY"], !key.isEmpty else {
        fail("update: no private key; pass --key-file or set HEXER_UPDATE_KEY")
    }
    return key
}
