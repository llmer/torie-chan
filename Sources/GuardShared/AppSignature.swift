import Foundation
import Security

public enum AppSignature {
    /// Whether the code at `path` is validly signed and meets `requirement` (a code-signing requirement
    /// string). The helper checks this right before relaunching the app, since the bundle could have been
    /// swapped since it connected.
    public static func isValid(at path: String, requirement: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }
}
