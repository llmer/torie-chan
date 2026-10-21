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
    private var ownerUID: uid_t = 0
    private var appBundlePath: String?
    private lazy var lease = HelperLease(actions: .init(
        setSleepDisabled: { setDisableSleep($0) },
        relaunchApp: { [weak self] in self?.relaunchApp() },
        log: log))

    init() {
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.lease.check() }
        RunLoop.main.add(t, forMode: .common)
    }

    func arm(from conn: NSXPCConnection) -> (Bool, String?) {
        ownerUID = conn.effectiveUserIdentifier
        if let exe = executablePath(of: conn.processIdentifier) {
            // .../Torie-chan.app/Contents/MacOS/TorieChan
            appBundlePath = URL(fileURLWithPath: exe).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        }
        return lease.arm()
    }

    func heartbeat() { lease.heartbeat() }
    func disarm() -> (Bool, String?) { lease.disarm() }
    func connected(_ conn: NSXPCConnection) { lease.connected() }
    func disconnected(_ conn: NSXPCConnection) { lease.disconnected() }

    private func relaunchApp() {
        guard ownerUID != 0 else { return }
        var args = ["asuser", String(ownerUID), "/usr/bin/open"]
        if let appBundlePath { args.append(appBundlePath) } else { args += ["-b", GuardIDs.appBundleID] }
        if let err = run("/bin/launchctl", args) { log("relaunch failed: \(err)") }
    }
}

final class HelperService: NSObject, GuardHelperProtocol {
    let guardian: Guardian
    weak var connection: NSXPCConnection?

    init(guardian: Guardian) {
        self.guardian = guardian
    }

    func arm(reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.main.async {
            guard let conn = self.connection else { return reply(false, "no connection") }
            let (ok, err) = self.guardian.arm(from: conn)
            reply(ok, err)
        }
    }

    func heartbeat() {
        DispatchQueue.main.async { self.guardian.heartbeat() }
    }

    func disarm(reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.main.async {
            let (ok, err) = self.guardian.disarm()
            reply(ok, err)
        }
    }

    func version(reply: @escaping (String) -> Void) {
        reply(HelperInfo.version)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement: String?
    let guardian = Guardian()

    init(requirement: String?) {
        self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard let requirement else {
            log("refusing connection: helper is not team-signed, cannot verify caller")
            return false
        }
        conn.setCodeSigningRequirement(requirement)
        let service = HelperService(guardian: guardian)
        service.connection = conn
        conn.exportedInterface = NSXPCInterface(with: GuardHelperProtocol.self)
        conn.exportedObject = service
        conn.invalidationHandler = { [weak self, unowned conn] in
            DispatchQueue.main.async { self?.guardian.disconnected(conn) }
        }
        DispatchQueue.main.async { self.guardian.connected(conn) }
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
