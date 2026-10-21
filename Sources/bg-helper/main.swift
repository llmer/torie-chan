import Darwin
import Foundation
import Security
import GuardShared

// Privileged helper, registered via SMAppService.daemon and started at boot (RunAtLoad) so
// a stale `disablesleep 1` from a forced shutdown never survives a reboot.
// See GuardHelperProtocol for the arm / heartbeat / disarm lease semantics.

func log(_ msg: String) {
    FileHandle.standardError.write(Data("[bg-helper \(Date())] \(msg)\n".utf8))
}

@discardableResult
func setDisableSleep(_ on: Bool) -> (Bool, String?) {
    if let err = run("/usr/bin/pmset", ["-a", "disablesleep", on ? "1" : "0"]) {
        log("pmset failed: \(err)")
        return (false, err)
    }
    log("disablesleep -> \(on ? 1 : 0)")
    return (true, nil)
}

/// Runs a tool, returning an error message on failure.
func run(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let err = Pipe()
    p.standardError = err
    p.standardOutput = Pipe()
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        return "\(path) failed to launch: \(error)"
    }
    guard p.terminationStatus == 0 else {
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return "\(path) exited \(p.terminationStatus): \(msg)"
    }
    return nil
}

/// Only accept connections from the Torie-chan app signed by the same team as this helper.
func clientRequirement() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any],
          let team = dict[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
    return "identifier \"\(GuardIDs.appBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
}

func executablePath(of pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
}

/// Owns the lease (HelperLease, in GuardShared) and the root-only side effects. Main queue only.
final class Guardian {
    private let requirement: String
    private var appBundlePath: String?
    private lazy var lease = HelperLease(actions: .init(
        setSleepDisabled: { setDisableSleep($0) },
        relaunchApp: { [weak self] in self?.relaunchApp() },
        log: log))

    init(requirement: String) {
        self.requirement = requirement
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.lease.check() }
        RunLoop.main.add(t, forMode: .common)
    }

    func arm(from service: HelperService) -> (Bool, String?) {
        let result = lease.arm(client: service.client, uid: service.uid)
        if result.0, let bundle = service.bundlePath { appBundlePath = bundle }
        return result
    }

    func heartbeat(from service: HelperService) { lease.heartbeat(client: service.client, uid: service.uid) }
    func disarm(from service: HelperService) -> (Bool, String?) { lease.disarm(client: service.client, uid: service.uid) }
    func disconnected(_ client: HelperLease.Client) { lease.disconnected(client: client) }

    private func relaunchApp() {
        guard let uid = lease.ownerUID, uid != 0 else { return }
        var target = ["-b", GuardIDs.appBundleID]
        if let appBundlePath {
            guard AppSignature.isValid(at: appBundlePath, requirement: requirement) else {
                log("not relaunching \(appBundlePath): it isn't a validly signed Torie-chan")
                return
            }
            target = [appBundlePath]
        }
        // `launchctl asuser` only switches the session, not the credentials, so drop to the user with sudo:
        // the app must never be started as root.
        let args = ["asuser", String(uid), "/usr/bin/sudo", "-n", "-u", "#\(uid)", "/usr/bin/open"] + target
        if let err = run("/bin/launchctl", args) { log("relaunch failed: \(err)") }
    }
}

final class HelperService: NSObject, GuardHelperProtocol {
    let guardian: Guardian
    let client: HelperLease.Client
    let uid: UInt32
    /// The connecting app's bundle, from its pid when the connection was accepted.
    let bundlePath: String?

    init(guardian: Guardian, client: HelperLease.Client, connection: NSXPCConnection) {
        self.guardian = guardian
        self.client = client
        uid = connection.effectiveUserIdentifier
        // .../Torie-chan.app/Contents/MacOS/TorieChan
        bundlePath = executablePath(of: connection.processIdentifier).map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        }
    }

    // Messages only arrive once the caller has passed the code-signing requirement, so the lease
    // counts a connection from its first message, never from merely connecting.
    func arm(reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.main.async {
            let (ok, err) = self.guardian.arm(from: self)
            reply(ok, err)
        }
    }

    func heartbeat() {
        DispatchQueue.main.async { self.guardian.heartbeat(from: self) }
    }

    func disarm(reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.main.async {
            let (ok, err) = self.guardian.disarm(from: self)
            reply(ok, err)
        }
    }

    func version(reply: @escaping (String) -> Void) {
        reply(HelperInfo.version)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement: String?
    let guardian: Guardian?
    private var nextClient: HelperLease.Client = 0

    init(requirement: String?) {
        self.requirement = requirement
        guardian = requirement.map { Guardian(requirement: $0) }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard let requirement, let guardian else {
            log("refusing connection: helper is not team-signed, cannot verify caller")
            return false
        }
        conn.setCodeSigningRequirement(requirement)
        nextClient += 1
        let client = nextClient
        conn.exportedInterface = NSXPCInterface(with: GuardHelperProtocol.self)
        conn.exportedObject = HelperService(guardian: guardian, client: client, connection: conn)
        conn.invalidationHandler = {
            DispatchQueue.main.async { guardian.disconnected(client) }
        }
        conn.resume()
        return true
    }
}

// Runs at boot (RunAtLoad) and on every relaunch: never leave the Mac in no-sleep mode.
setDisableSleep(false)

let delegate = ListenerDelegate(requirement: clientRequirement())
let listener = NSXPCListener(machServiceName: GuardIDs.helperLabel)
listener.delegate = delegate
listener.resume()
log("listening on \(GuardIDs.helperLabel), version \(HelperInfo.version)")
RunLoop.main.run()
