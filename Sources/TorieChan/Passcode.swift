import CommonCrypto
import Foundation
import LocalAuthentication
import Security

/// Owner's disarm code, stored as a salted PBKDF2-SHA256 hash in the login keychain.
/// Loaded into memory at launch so a keychain prompt can never appear mid-alarm. The launch read
/// is non-interactive; if the keychain wants to ask (e.g. after re-signing), Settings offers an
/// explicit unlock instead of blocking launch behind a modal prompt.
///
/// Wrong guesses escalate: 3 free tries, then lockouts of 10s, 20s, 40s… (capped at 15 min),
/// persisted so relaunching the app doesn't reset them.
/// Where the hashed code lives. The app uses the keychain; tests use memory.
protocol PasscodeStore {
    /// `.success(nil)` means no code is stored; `.failure` means it couldn't be read (locked).
    func read(interactive: Bool) -> Result<Data?, PasscodeError>
    func write(_ data: Data) throws
}

final class Passcode {
    enum LoadState { case loaded, notSet, needsUnlock }

    static let defaultIterations: UInt32 = 200_000

    private struct Stored: Codable {
        var salt: Data
        var hash: Data
        var iterations: UInt32
    }

    private var stored: Stored?
    private(set) var loadState: LoadState = .notSet

    private let store: PasscodeStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private let iterations: UInt32

    var isSet: Bool { stored != nil }
    /// Codes set before the 6-digit minimum still work, but Settings nudges to upgrade.
    var isShort: Bool { (defaults.object(forKey: "passcodeLength") as? Int).map { $0 < Self.minLength } ?? false }

    static let minLength = 6
    static let freeAttempts = 3

    init(store: PasscodeStore = KeychainPasscodeStore(), defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init, iterations: UInt32 = Passcode.defaultIterations) {
        self.store = store
        self.defaults = defaults
        self.now = now
        self.iterations = iterations
        load(interactive: false)
    }

    func load(interactive: Bool) {
        switch store.read(interactive: interactive) {
        case .success(let data):
            let value = data.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
            stored = value
            loadState = value == nil ? .notSet : .loaded
        case .failure:
            stored = nil
            loadState = .needsUnlock
        }
    }

    static func isValidFormat(_ code: String) -> Bool {
        (minLength...12).contains(code.count) && code.allSatisfy(\.isNumber)
    }

    // MARK: - Lockout

    private var failures: Int {
        get { defaults.integer(forKey: "passcodeFailures") }
        set { defaults.set(newValue, forKey: "passcodeFailures") }
    }

    var lockedUntil: Date? {
        get { (defaults.object(forKey: "passcodeLockedUntil") as? Date).flatMap { $0 > now() ? $0 : nil } }
        set { defaults.set(newValue, forKey: "passcodeLockedUntil") }
    }

    enum Attempt: Equatable {
        case success
        case wrong(remainingFreeTries: Int)
        case lockedOut(until: Date)
    }

    /// Verify a code with lockout bookkeeping.
    func attempt(_ code: String) -> Attempt {
        if let until = lockedUntil { return .lockedOut(until: until) }
        if verify(code) {
            failures = 0
            lockedUntil = nil
            return .success
        }
        failures += 1
        if failures < Self.freeAttempts { return .wrong(remainingFreeTries: Self.freeAttempts - failures) }
        let seconds = min(900, 10 * pow(2, Double(failures - Self.freeAttempts)))
        let until = now().addingTimeInterval(seconds)
        lockedUntil = until
        return .lockedOut(until: until)
    }

    /// Successful Touch ID also clears the lockout.
    func resetFailures() {
        failures = 0
        lockedUntil = nil
    }

    func verify(_ code: String) -> Bool {
        guard let stored else { return false }
        let candidate = Self.derive(code, salt: stored.salt, iterations: stored.iterations)
        return Self.constantTimeEqual(candidate, stored.hash)
    }

    /// Set or change the code. If one exists, `current` must match it.
    func set(_ newCode: String, current: String?) throws {
        // Never treat "couldn't read the keychain" as "no code set".
        guard loadState != .needsUnlock else { throw PasscodeError.keychainLocked }
        if isSet {
            guard let current, verify(current) else { throw PasscodeError.wrongCurrentCode }
        }
        guard Self.isValidFormat(newCode) else { throw PasscodeError.invalidFormat }
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let value = Stored(salt: salt, hash: Self.derive(newCode, salt: salt, iterations: iterations), iterations: iterations)
        try store.write(try JSONEncoder().encode(value))
        stored = value
        loadState = .loaded
        defaults.set(newCode.count, forKey: "passcodeLength")
    }

    private static func derive(_ code: String, salt: Data, iterations: UInt32) -> Data {
        var out = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        let password = Array(code.utf8).map { Int8(bitPattern: $0) }
        _ = out.withUnsafeMutableBytes { outBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                                     saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     outBuf.bindMemory(to: UInt8.self).baseAddress, Int(CC_SHA256_DIGEST_LENGTH))
            }
        }
        return out
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The real store: a generic password in the login keychain.
struct KeychainPasscodeStore: PasscodeStore {
    private static let service = "com.mostperfectsip.toriechan.passcode"
    private static let account = "owner"

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func read(interactive: Bool) -> Result<Data?, PasscodeError> {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return .success(result as? Data)
        case errSecItemNotFound: return .success(nil)
        default: return .failure(.keychain(status))
        }
    }

    func write(_ data: Data) throws {
        let status = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Torie-chan disarm code"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw PasscodeError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw PasscodeError.keychain(status)
        }
    }
}

enum PasscodeError: LocalizedError {
    case wrongCurrentCode
    case invalidFormat
    case keychainLocked
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .wrongCurrentCode: "Current code is incorrect."
        case .invalidFormat: "Use \(Passcode.minLength)–12 digits."
        case .keychainLocked: "Unlock keychain access first."
        case .keychain(let status): "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "")"
        }
    }
}
