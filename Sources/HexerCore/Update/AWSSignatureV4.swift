import CryptoKit
import Foundation

/// AWS Signature Version 4, which S3-compatible object storage (Cloudflare R2, S3 itself, …)
/// authenticates requests with: enough for the release workflow to put and get the update files
/// (`hexer-cli update upload|download`, `Scripts/publish_update.sh`).
///
/// Every header the request carries is signed, plus `host`, `x-amz-date` and
/// `x-amz-content-sha256`, which signing adds; the URL's path and query are signed too.
public enum AWSSignatureV4 {
    public struct Credentials: Sendable {
        public var accessKeyID: String
        public var secretAccessKey: String

        public init(accessKeyID: String, secretAccessKey: String) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
        }
    }

    /// SHA-256 of an empty body, for requests without one.
    public static let emptyPayloadSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Signs `request` in place for `service` in `region` (R2 takes `auto`) at `date`.
    /// `payloadSHA256` is the body's SHA-256, lowercase hex (`emptyPayloadSHA256` for none).
    public static func sign(_ request: inout URLRequest, payloadSHA256: String, credentials: Credentials,
                            region: String, service: String = "s3", date: Date = .now) throws {
        guard let url = request.url, let host = url.host, url.scheme != nil else { throw URLError(.badURL) }
        let amzDate = timestamp(date)
        let dateStamp = String(amzDate.prefix(8))
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadSHA256, forHTTPHeaderField: "x-amz-content-sha256")

        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        headers["host"] = url.port.map { "\(host):\($0)" } ?? host
        let names = headers.keys.sorted()
        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalPath(url),
            canonicalQuery(url),
            names.map { "\($0):\(headers[$0]!)\n" }.joined(),
            names.joined(separator: ";"),
            payloadSHA256,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))]
            .joined(separator: "\n")
        var key = Data(("AWS4" + credentials.secretAccessKey).utf8)
        for part in [dateStamp, region, service, "aws4_request"] { key = hmac(key, part) }
        let signature = hex(hmac(key, stringToSign))
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(names.joined(separator: ";")), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
    }

    /// `20130524T000000Z`: the request's time in UTC, as `x-amz-date` wants it.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// The path with each segment URI-encoded once (S3 keys are not double-encoded); `/` for none.
    static func canonicalPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }

    /// The query's items encoded and sorted by name, then value: `a=1&b=`.
    static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var pairs: [(name: String, value: String)] = items.map { (encode($0.name), encode($0.value ?? "")) }
        pairs.sort { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// RFC 3986 percent-encoding with only the unreserved characters left as they are.
    private static func encode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
