import Foundation
import IOKit
import IOKit.hid
import IOKit.ps

/// Polls lid (clamshell) state, hinge angle and power source. Cheap enough to do 4x a second.
final class SystemMonitor {
    struct Snapshot: Equatable {
        var lidClosed: Bool
        var lidCausesSleep: Bool
        var onACPower: Bool
        /// Hinge angle in degrees, if this Mac has the lid angle sensor.
        var lidAngle: Int?
    }

    var onChange: ((Snapshot, Snapshot) -> Void)?
    private(set) var current: Snapshot
    private var timer: Timer?

    init() {
        current = Self.read()
    }

    func start() {
        guard timer == nil else { return }
        current = Self.read()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() -> Snapshot {
        current = Self.read()
        return current
    }

    private func poll() {
        let next = Self.read()
        guard next != current else { return }
        let old = current
        current = next
        onChange?(old, next)
    }

    static func read() -> Snapshot {
        Snapshot(
            lidClosed: rootDomainBool("AppleClamshellState") ?? false,
            lidCausesSleep: rootDomainBool("AppleClamshellCausesSleep") ?? true,
            onACPower: isOnAC(),
            lidAngle: LidAngleSensor.shared.angle()
        )
    }

    private static func rootDomainBool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    private static func isOnAC() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMACPowerKey
    }
}

/// The hinge sensor on recent MacBooks: SPU HID device, usage page 0x20 (sensors), usage 0x8A
/// (orientation). Feature report 1 carries the angle in degrees as a little-endian UInt16.
/// Undocumented; returns nil on Macs without it.
final class LidAngleSensor {
    static let shared = LidAngleSensor()
    /// The manager owns the device handle; it must outlive every report read.
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var looked = false

    func angle() -> Int? {
        if !looked {
            looked = true
            find()
        }
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess, length >= 3 else { return nil }
        let value = Int(report[1]) | Int(report[2]) << 8
        return (0...360).contains(value) ? value : nil
    }

    private func find() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A,
                                                kIOHIDTransportKey: "SPU"] as CFDictionary)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) // may report an error for other devices; harmless
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        self.manager = manager
        device = devices.first
    }
}

/// Streams the hinge angle at animation-friendly rates (the system monitor's 4 Hz poll is for
/// security decisions; the eyes want something smoother to spring toward).
@MainActor
final class LidAngleFeed {
    private var timer: Timer?

    var isAvailable: Bool { LidAngleSensor.shared.angle() != nil }

    func start(hz: Double = 30, _ handler: @escaping (Double?) -> Void) {
        stop()
        let t = Timer(timeInterval: 1 / hz, repeats: true) { _ in
            MainActor.assumeIsolated { handler(LidAngleSensor.shared.angle().map(Double.init)) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
