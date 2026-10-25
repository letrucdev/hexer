import Foundation
import HexerCore

/// `update keygen|public-key|sign|verify|manifest|download|upload …`
///
/// Ed25519 signatures of update disk images (see `UpdateSignature`): the release workflow signs
/// each disk image, the app verifies it before installing. `manifest`, `download` and `upload`
/// publish a release to the update server, an S3-compatible bucket (`Scripts/publish_update.sh`).
func update(_ args: [String]) {
    let usage = """
        update keygen PRIVATE_KEY_FILE | update public-key [--key-file FILE] |
               update sign [--key-file FILE] DMG VERSION |
               update verify (--public-key KEY | --app APP) DMG VERSION SIGNATURE_FILE |
               update manifest --version V --dmg DMG --signature-file SIG --page URL --notes-file FILE
                               --url URL [--url URL …] [--prerelease] [--previous FILE] [-o OUT] |
               update download [--if-missing-ok] URL [-o OUT] |
               update upload [--content-type TYPE] [--cache-control VALUE] FILE URL
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
    case "manifest":
        let a = Arguments(rest, command: "update manifest", flags: ["--prerelease"],
                          options: ["--version", "--dmg", "--signature-file", "--page", "--notes-file", "--url", "--previous", "-o"])
        _ = a.expect(0, usage: usage)
        func required(_ name: String) -> String {
            guard let value = a.value(name) else { fail("update manifest: \(name) is required (usage: hexer-cli \(usage))") }
            return value
        }
        let version = required("--version")
        guard let parsed = AppVersion(version), parsed.description == version else {
            fail("update manifest: \(version) is not a version like 0.3.2 or 0.4.0-beta.1")
        }
        let urls = a.allValues("--url")
        guard !urls.isEmpty else { fail("update manifest: at least one --url is required") }
        let image = URL(fileURLWithPath: required("--dmg"))
        let sha256 = attempt("update manifest") { try UpdateSignature.sha256(ofFileAt: image) }
        let size = attempt("update manifest") { try FileManager.default.attributesOfItem(atPath: image.path)[.size] as? Int64 ?? 0 }
        let signature = attempt("update manifest") { try String(contentsOfFile: required("--signature-file"), encoding: .utf8) }
        let notes = attempt("update manifest") { try String(contentsOfFile: required("--notes-file"), encoding: .utf8) }
        // A missing --previous file is a first manifest; an unreadable one is not silently dropped.
        let previous = a.value("--previous").flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
            .map { url in attempt("update manifest") { try Data(contentsOf: url) } }
        let entry = UpdateManifest.Entry(
            version: version, prerelease: a.flag("--prerelease") || parsed.isPrerelease, page: required("--page"), notes: notes,
            size: size, sha256: sha256.map { String(format: "%02x", $0) }.joined(),
            signature: signature.trimmingCharacters(in: .whitespacesAndNewlines), urls: urls)
        let manifest = UpdateManifest.adding(entry, to: previous)
        // What the app will read, checked before anything is published.
        let data = attempt("update manifest") { try manifest.encoded() }
        attempt("update manifest") { _ = try UpdateManifest.releases(from: data) }
        if let out = a.value("-o") {
            attempt("update manifest") { try data.write(to: URL(fileURLWithPath: out), options: .atomic) }
        } else {
            FileHandle.standardOutput.write(data)
        }
    case "download":
        let a = Arguments(rest, command: "update download", flags: ["--if-missing-ok"], options: ["-o"])
        let p = a.expect(1, usage: usage)
        var request = URLRequest(url: objectURL(p[0], command: "update download"))
        signS3(&request, payloadSHA256: AWSSignatureV4.emptyPayloadSHA256, command: "update download")
        let (data, response) = send(request, command: "update download")
        switch response.statusCode {
        case 200:
            if let out = a.value("-o") {
                attempt("update download") { try data.write(to: URL(fileURLWithPath: out), options: .atomic) }
            } else {
                FileHandle.standardOutput.write(data)
            }
        case 404 where a.flag("--if-missing-ok"):
            FileHandle.standardError.write(Data("update download: \(p[0]) does not exist\n".utf8))
        case let status:
            fail("update download: \(p[0]) answered \(status)\n\(String(decoding: data.prefix(2000), as: UTF8.self))")
        }
    case "upload":
        let a = Arguments(rest, command: "update upload", options: ["--content-type", "--cache-control"])
        let p = a.expect(2, usage: usage)
        let file = URL(fileURLWithPath: p[0])
        let sha256 = attempt("update upload") { try UpdateSignature.sha256(ofFileAt: file) }
        let size = attempt("update upload") { try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 ?? 0 }
        var request = URLRequest(url: objectURL(p[1], command: "update upload"))
        request.httpMethod = "PUT"
        request.setValue(a.value("--content-type") ?? contentType(of: file), forHTTPHeaderField: "Content-Type")
        if let cacheControl = a.value("--cache-control") { request.setValue(cacheControl, forHTTPHeaderField: "Cache-Control") }
        signS3(&request, payloadSHA256: sha256.map { String(format: "%02x", $0) }.joined(), command: "update upload")
        let (data, response) = send(request, uploading: file, command: "update upload")
        guard response.statusCode == 200 else {
            fail("update upload: \(p[1]) answered \(response.statusCode)\n\(String(decoding: data.prefix(2000), as: UTF8.self))")
        }
        print("Uploaded \(p[1]) (\(size) bytes)")
    default:
        fail("usage: hexer-cli \(usage)")
    }
}

// MARK: The update server (S3 API)

/// An object's URL in the bucket, `https://ACCOUNT.r2.cloudflarestorage.com/BUCKET/KEY`.
private func objectURL(_ string: String, command: String) -> URL {
    guard let url = URL(string: string), url.scheme == "https", url.host != nil, url.path.count > 1 else {
        fail("\(command): \(string) is not an https URL of an object")
    }
    return url
}

/// Signs a request with the bucket's API token: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in
/// the environment (the names every S3 tool reads), region AWS_REGION or `auto` (R2's).
private func signS3(_ request: inout URLRequest, payloadSHA256: String, command: String) {
    let env = ProcessInfo.processInfo.environment
    guard let id = env["AWS_ACCESS_KEY_ID"], !id.isEmpty, let secret = env["AWS_SECRET_ACCESS_KEY"], !secret.isEmpty else {
        fail("\(command): set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY to the bucket's API token")
    }
    let region = env["AWS_REGION"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
    attempt(command) {
        try AWSSignatureV4.sign(&request, payloadSHA256: payloadSHA256,
                                credentials: .init(accessKeyID: id, secretAccessKey: secret), region: region)
    }
}

private func contentType(of file: URL) -> String {
    switch file.pathExtension.lowercased() {
    case "dmg": "application/x-apple-diskimage"
    case "json": "application/json"
    case "md", "txt": "text/plain; charset=utf-8"
    default: "application/octet-stream"
    }
}

/// Sends the request (the body from `file`, if any) and waits for the whole response.
private func send(_ request: URLRequest, uploading file: URL? = nil, command: String) -> (Data, HTTPURLResponse) {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: (data: Data?, response: URLResponse?, error: Error?) = (nil, nil, nil)
    let handler: @Sendable (Data?, URLResponse?, Error?) -> Void = {
        result = ($0, $1, $2)
        done.signal()
    }
    let task = file.map { URLSession.shared.uploadTask(with: request, fromFile: $0, completionHandler: handler) }
        ?? URLSession.shared.dataTask(with: request, completionHandler: handler)
    task.resume()
    done.wait()
    if let error = result.error { fail("\(command): \(error.localizedDescription)") }
    guard let response = result.response as? HTTPURLResponse else { fail("\(command): no HTTP response") }
    return (result.data ?? Data(), response)
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
