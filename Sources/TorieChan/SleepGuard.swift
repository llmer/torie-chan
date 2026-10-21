import Foundation
import GuardShared
import IOKit.pwr_mgt
import ServiceManagement

/// Keeps the Mac awake while armed.
/// - Idle sleep and display sleep: IOPM assertions (no privileges needed).
/// - Lid-close sleep: only `pmset disablesleep 1` stops that, which needs root, so it goes through
///   the bundled helper daemon on a lease (see GuardHelperProtocol).
final class SleepGuard {
    enum LidProtection: Equatable {
        case active
        case inactive
        case helperNotInstalled
        case needsApproval
        case failed(String)

        var label: String {
            switch self {
            case .active: "active"
            case .inactive: "off (disarmed)"
            case .helperNotInstalled: "helper not installed: closing the lid will sleep the Mac"
            case .needsApproval: "helper needs approval in System Settings › Login Items"
            case .failed(let msg): "failed: \(msg)"
            }
        }
    }

    private(set) var lidProtection: LidProtection = .inactive
    var onLidProtectionChange: ((LidProtection) -> Void)?

    private var assertions: [IOPMAssertionID] = []
    private var connection: NSXPCConnection?
    private var heartbeatTimer: Timer?
    private var engaged = false

    private var service: SMAppService { SMAppService.daemon(plistName: GuardIDs.helperPlistName) }

    var helperStatus: SMAppService.Status { service.status }

    func installHelper() throws {
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        default:
            try service.register()
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    func uninstallHelper() throws {
        try service.unregister()
    }

    /// After an app update the old helper binary may still be running. Re-register if it reports
    /// a different protocol version.
    func checkHelperVersion(log: @escaping (String) -> Void) {
        guard service.status == .enabled else { return }
        let conn = makeConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in conn.invalidate() } as? GuardHelperProtocol
        proxy?.version { [weak self] version in
            conn.invalidate()
            guard version != HelperInfo.version else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                log("Helper is version \(version), app expects \(HelperInfo.version); re-registering")
                try? self.service.unregister()
                try? self.service.register()
            }
        }
    }

    func engage() {
        engaged = true
        if assertions.isEmpty {
            for type in [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] {
                var id: IOPMAssertionID = 0
                if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "Torie-chan is armed" as CFString, &id) == kIOReturnSuccess {
                    assertions.append(id)
                }
            }
        }
        engageLidProtection()
    }

    func release() {
        engaged = false
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions.removeAll()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        let conn = connection
        connection = nil
        if let proxy = conn?.remoteObjectProxyWithErrorHandler({ _ in conn?.invalidate() }) as? GuardHelperProtocol {
            // Explicit disarm; only then drop the connection (a bare drop means "the app was killed").
            proxy.disarm { _, _ in conn?.invalidate() }
        } else {
            conn?.invalidate()
        }
        setLid(.inactive)
    }

    /// Let the Mac sleep with the lid closed again (thermal emergency) while staying otherwise armed.
    func dropLidProtection(reason: String) {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? GuardHelperProtocol else { return }
        proxy.disarm { _, _ in }
        setLid(.failed(reason))
    }

    private func makeConnection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: GuardIDs.helperLabel, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: GuardHelperProtocol.self)
        c.resume()
        return c
    }

    private func engageLidProtection() {
        switch service.status {
        case .enabled: break
        case .requiresApproval:
            setLid(.needsApproval)
            return
        default:
            setLid(.helperNotInstalled)
            return
        }

        let conn = connection ?? {
            let c = makeConnection()
            c.invalidationHandler = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.engaged, self.connection === c else { return }
                    self.connection = nil
                    self.setLid(.failed("helper connection lost"))
                }
            }
            connection = c
            return c
        }()

        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async { self?.setLid(.failed(error.localizedDescription)) }
        } as? GuardHelperProtocol
        proxy?.arm { [weak self] ok, err in
            DispatchQueue.main.async {
                guard let self else { return }
                // Trust but verify: the kernel reports whether closing the lid will cause sleep.
                let verified = !SystemMonitor.read().lidCausesSleep
                self.setLid(ok && verified ? .active : .failed(err ?? "pmset ran but lid-close sleep is still enabled"))
            }
        }

        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: HelperInfo.heartbeatSeconds, repeats: true) { [weak self] _ in
            (self?.connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? GuardHelperProtocol)?.heartbeat()
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    private func setLid(_ value: LidProtection) {
        guard value != lidProtection else { return }
        lidProtection = value
        onLidProtectionChange?(value)
    }
}
