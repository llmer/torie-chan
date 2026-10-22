import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Alarm photos, encrypted at rest. Torie-chan has camera permission; other apps running as you don't,
/// so the photos shouldn't be a way around that.
///
/// Public-key encryption (HPKE): saving a photo during an alarm only needs the public key, which is
/// read without any keychain prompt, so nothing can pop up or stall mid-alarm. Viewing needs the
/// private key, which stays in the keychain; you're at the Mac then, so a prompt is fine.
///
/// The iMessage attachment (if you opted in) is written from the photo still in memory to a
/// short-lived file in Outgoing/, deleted after a few minutes.
final class PhotoVault {
    static let fileExtension = "enc"
    private static let magic = Data("TCP1".utf8)
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static let info = Data("Torie-chan alarm photo".utf8)
    static let outgoingLifetime: TimeInterval = 600

    private let keys: PhotoKeyStore
    let snapshots: URL
    let outgoing: URL
    private let now: () -> Date

    init(directory: URL, keys: PhotoKeyStore = KeychainPhotoKeyStore(), now: @escaping () -> Date = Date.init) {
        self.keys = keys
        snapshots = directory.appendingPathComponent("Snapshots", isDirectory: true)
        outgoing = directory.appendingPathComponent("Outgoing", isDirectory: true)
        self.now = now
    }

    enum VaultError: Error { case noKey, notAPhoto }

    /// Creates the key pair if there isn't one. Call at launch, not mid-alarm.
    @discardableResult
    func prepare() -> Bool {
        if publicKey() != nil { return true }
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (try? keys.create(privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)) != nil
    }

    private func publicKey() -> Curve25519.KeyAgreement.PublicKey? {
        keys.publicKey().flatMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
    }

    func seal(_ jpeg: Data) throws -> Data {
        guard let publicKey = publicKey() else { throw VaultError.noKey }
        var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: Self.suite, info: Self.info)
        return Self.magic + sender.encapsulatedKey + (try sender.seal(jpeg))
    }

    func open(_ sealed: Data) throws -> Data {
        guard sealed.starts(with: Self.magic), sealed.count > Self.magic.count + 32 else { throw VaultError.notAPhoto }
        guard let raw = try keys.privateKey() else { throw VaultError.noKey }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        let body = sealed.dropFirst(Self.magic.count)
        var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: Self.suite, info: Self.info,
                                           encapsulatedKey: Data(body.prefix(32)))
        return try recipient.open(Data(body.dropFirst(32)))
    }

    /// Saves an alarm photo, encrypted, and returns its path. If there's no key (it couldn't be read
    /// or created), the photo is saved unencrypted rather than lost: it's the evidence.
    func save(_ jpeg: Data, named name: String) -> String? {
        let sealed = try? seal(jpeg)
        let url = snapshots.appendingPathComponent(sealed == nil ? name : "\(name).\(Self.fileExtension)")
        guard Self.writePrivate(sealed ?? jpeg, to: url, in: snapshots) else { return nil }
        return url.path
    }

    /// The photo at `path` (encrypted, or a plain JPEG from before encryption), decrypted.
    /// May show a keychain prompt.
    func load(_ path: String) throws -> Data {
        let fm = FileManager.default
        let sealedPath = path.hasSuffix(".\(Self.fileExtension)") ? path : "\(path).\(Self.fileExtension)"
        if fm.fileExists(atPath: sealedPath) { return try open(Data(contentsOf: URL(fileURLWithPath: sealedPath))) }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// A plain copy to attach to an iMessage, removed by `cleanOutgoing()` after a few minutes.
    func outgoingCopy(of jpeg: Data, named name: String) -> URL? {
        let url = outgoing.appendingPathComponent(name)
        return Self.writePrivate(jpeg, to: url, in: outgoing) ? url : nil
    }

    func cleanOutgoing(all: Bool = false) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: outgoing, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = now().addingTimeInterval(-Self.outgoingLifetime)
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if all || created < cutoff { try? fm.removeItem(at: file) }
        }
    }

    /// Encrypts photos saved before encryption existed (or while the key was unavailable).
    func encryptPlainPhotos() {
        guard publicKey() != nil,
              let files = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "jpg" {
            guard let jpeg = try? Data(contentsOf: file), let sealed = try? seal(jpeg),
                  Self.writePrivate(sealed, to: file.appendingPathExtension(Self.fileExtension), in: snapshots) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Deleting all data also forgets the key, so any stray copy can't be opened.
    func deleteEverything() {
        try? FileManager.default.removeItem(at: snapshots)
        try? FileManager.default.removeItem(at: outgoing)
        keys.delete()
    }

    private static func writePrivate(_ data: Data, to url: URL, in directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            chmod(url.path, 0o600)
            return true
        } catch {
            return false
        }
    }
}

protocol PhotoKeyStore {
    /// Never prompts.
    func publicKey() -> Data?
    /// May prompt (macOS asks before letting a differently signed build read it).
    func privateKey() throws -> Data?
    func create(privateKey: Data, publicKey: Data) throws
    func delete()
}

/// The private key is the item's secret; the public key rides along in its attributes, which can be
/// read without unlocking the secret.
struct KeychainPhotoKeyStore: PhotoKeyStore {
    static let service = "com.mostperfectsip.toriechan.photo-key"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "alarm-photos"]
    }

    func publicKey() -> Data? {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrGeneric as String] as? Data
    }

    func privateKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw PasscodeError.keychain(status)
        }
    }

    func create(privateKey: Data, publicKey: Data) throws {
        var item = baseQuery
        item[kSecValueData as String] = privateKey
        item[kSecAttrGeneric as String] = publicKey
        item[kSecAttrLabel as String] = "Torie-chan alarm photo key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw PasscodeError.keychain(status) }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
