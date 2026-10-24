import CryptoKit
import Foundation

/// Ed25519 signatures of update disk images. The release workflow signs each image with the key
/// in its `HEXER_UPDATE_KEY` secret (`hexer-cli update sign`); the app checks the signature with
/// the public key in its Info.plist (`HexerUpdatePublicKey`) before installing.
///
/// The signed message names the version as well as the image's SHA-256, so a genuine image can't
/// be passed off as another version:
///
///     hexer-update-v1\n<version>\n<sha-256, lowercase hex>\n
///
/// Keys and signatures are Base64: a raw 32-byte key (the private key is the RFC 8032 seed) and a
/// 64-byte signature.
public enum UpdateSignature {
    public static func message(version: String, sha256: some Sequence<UInt8>) -> Data {
        let hex = sha256.map { String(format: "%02x", $0) }.joined()
        return Data("hexer-update-v1\n\(version)\n\(hex)\n".utf8)
    }

    /// SHA-256 of a file, read in 1 MiB blocks.
    public static func sha256(ofFileAt url: URL) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
        return Array(hasher.finalize())
    }

    /// A new key pair, Base64.
    public static func makeKeyPair() -> (privateKey: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
    }

    public static func publicKey(forPrivateKey privateKey: String) throws -> String {
        try signingKey(privateKey).publicKey.rawRepresentation.base64EncodedString()
    }

    /// The Base64 signature of the image at `url` as `version`.
    public static func sign(fileAt url: URL, version: String, privateKey: String) throws -> String {
        let message = message(version: version, sha256: try sha256(ofFileAt: url))
        return try signingKey(privateKey).signature(for: message).base64EncodedString()
    }

    /// Throws `UpdateError.badSignature` unless `signature` (Base64; surrounding whitespace is
    /// ignored) signs the image at `url` as `version` with `publicKey`.
    public static func verify(fileAt url: URL, version: String, signature: String, publicKey: String) throws {
        guard let keyData = decode(publicKey, count: 32),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { throw UpdateError.invalidPublicKey }
        guard let signatureData = decode(signature, count: 64) else { throw UpdateError.badSignature }
        let message = message(version: version, sha256: try sha256(ofFileAt: url))
        guard key.isValidSignature(signatureData, for: message) else { throw UpdateError.badSignature }
    }

    private static func signingKey(_ base64: String) throws -> Curve25519.Signing.PrivateKey {
        guard let data = decode(base64, count: 32), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw UpdateError.invalidPrivateKey
        }
        return key
    }

    private static func decode(_ base64: String, count: Int) -> Data? {
        let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines))
        return data?.count == count ? data : nil
    }
}
