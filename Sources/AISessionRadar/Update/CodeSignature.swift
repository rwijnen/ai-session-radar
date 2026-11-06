import Foundation
import Security

/// Code-signature checks for the updater.
///
/// The rule an update has to pass is "signed by the same Apple team as the copy that is
/// running". That is the only trust anchor available without a separate update-signing
/// key: HTTPS proves the archive came from GitHub, not that the person who uploaded it
/// holds the certificate this app was built with.
enum CodeSignature {
    /// The Team Identifier in the signature at `url`, or `nil` for ad-hoc and self-signed
    /// code, which have none.
    static func teamIdentifier(of url: URL) -> String? {
        guard let code = staticCode(at: url) else { return nil }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard status == errSecSuccess, let information = information as? [String: Any] else {
            return nil
        }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether the bundle at `url` is intact, carries `identifier`, and chains to an
    /// Apple-issued certificate belonging to `teamIdentifier`.
    static func isValid(_ url: URL, identifier: String, teamIdentifier: String) -> Bool {
        // Both values are interpolated into requirement language, so refuse anything that
        // could close the quotes. Team IDs are ten alphanumerics; bundle IDs are
        // alphanumerics, dots and hyphens.
        guard teamIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              let code = staticCode(at: url)
        else { return false }

        let text = "identifier \"\(identifier)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }

        let flags = SecCSFlags(rawValue:
            kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }
}
