import Foundation
import Security

/// Code signature checks of app bundles (Security framework, like `codesign --verify --strict --deep`).
public enum CodeSignature {
    public enum Failure: Error, Equatable, LocalizedError {
        /// The bundle is unsigned, modified since signing, or doesn't meet the requirement.
        case invalid(path: String, status: Int32)

        public var errorDescription: String? {
            switch self {
            case .invalid(let path, let status):
                "The code signature of “\((path as NSString).lastPathComponent)” is not valid (\(status))."
            }
        }
    }

    /// Throws unless the bundle's signature is intact for every architecture and every nested
    /// piece of code, and the bundle meets `requirement` (code requirement language) if given.
    public static func verify(_ bundle: URL, requirement: String? = nil) throws {
        let fail = { (status: OSStatus) in Failure.invalid(path: bundle.path, status: status) }
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw fail(status) }
        var compiled: SecRequirement?
        if let requirement {
            status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
            guard status == errSecSuccess else { throw fail(status) }
        }
        let flags = SecCSFlags(rawValue: SecCSFlags.RawValue(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        status = SecStaticCodeCheckValidityWithErrors(code, flags, compiled, nil)
        guard status == errSecSuccess else { throw fail(status) }
    }

    /// What an update of the app at `running` must satisfy. With a signing identity (a Team ID),
    /// its designated requirement: the same developer signed it. Signed ad hoc, the designated
    /// requirement is the exact code hash, which no other build meets, so only the identifier is
    /// required (the update's own Ed25519 signature vouches for the rest). Nil when unsigned.
    public static func updateRequirement(for running: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(running as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any], let identifier = info[kSecCodeInfoIdentifier as String] as? String
        else { return nil }
        if info[kSecCodeInfoTeamIdentifier as String] is String {
            var designated: SecRequirement?
            var text: CFString?
            if SecCodeCopyDesignatedRequirement(code, [], &designated) == errSecSuccess, let designated,
               SecRequirementCopyString(designated, [], &text) == errSecSuccess, let text {
                return text as String
            }
        }
        return "identifier \"\(identifier)\""
    }
}
