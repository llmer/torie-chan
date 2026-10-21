import Foundation
import IOKit
import IOKit.hid
import simd

/// Reads the built-in accelerometer and gyroscope on Apple Silicon MacBooks.
///
/// These sit behind the SPU (sensor processing unit) as vendor HID devices
/// (usage page 0xFF00; usage 3 = accel, 9 = gyro). This is undocumented: the drivers idle
/// with ReportInterval = 0 until we set the reporting/power properties on them.
/// Reports are 22 bytes with little-endian Int32 x/y/z at offsets 6/10/14, in 1/65536 units
/// (g for the accelerometer).
final class MotionSensor {
    private static let usagePage = 0xFF00
    private static let accelUsage = 3
    private static let gyroUsage = 9
    private static let reportIntervalMicros = 10_000 // 100 Hz

    var onAccel: ((SIMD3<Double>) -> Void)?
    var onGyro: ((SIMD3<Double>) -> Void)?

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var lastSampleAt: Date?

    private var manager: IOHIDManager?
    private var buffers: [UnsafeMutablePointer<UInt8>] = []

    static var isAvailable: Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let usage = IORegistryEntryCreateCFProperty(service, kIOHIDPrimaryUsageKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            if usage == accelUsage { return true }
        }
        return false
    }

    /// True if a sample arrived recently; used to detect a sensor that silently stopped.
    var isHealthy: Bool {
        guard isRunning, let last = lastSampleAt else { return false }
        return Date().timeIntervalSince(last) < 1.0
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        wakeDrivers()

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(mgr, [
            [kIOHIDPrimaryUsagePageKey: Self.usagePage, kIOHIDPrimaryUsageKey: Self.accelUsage],
            [kIOHIDPrimaryUsagePageKey: Self.usagePage, kIOHIDPrimaryUsageKey: Self.gyroUsage],
        ] as CFArray)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let rc = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else {
            lastError = String(format: "IOHIDManagerOpen failed (0x%x)", rc)
            return false
        }
        let devices = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
        guard !devices.isEmpty else {
            lastError = "No motion sensor found (needs an Apple Silicon MacBook)"
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        for device in devices {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            buffers.append(buffer)
            let callback: IOHIDReportCallback = { ctx, _, sender, _, _, report, length in
                guard let ctx, length >= 18 else { return }
                let sensor = Unmanaged<MotionSensor>.fromOpaque(ctx).takeUnretainedValue()
                let usage = sender.map { IOHIDDeviceGetProperty(Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue(), kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1 } ?? -1
                sensor.handle(report: report, usage: usage)
            }
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, callback, context)
        }

        manager = mgr
        isRunning = true
        lastError = nil
        return true
    }

    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        isRunning = false
        // Buffers may still be referenced by an in-flight callback on this runloop turn; free on the next one.
        let old = buffers
        buffers = []
        DispatchQueue.main.async { old.forEach { $0.deallocate() } }
    }

    private func handle(report: UnsafeMutablePointer<UInt8>, usage: Int) {
        func axis(_ offset: Int) -> Double {
            Double(Int32(littleEndian: UnsafeRawPointer(report + offset).loadUnaligned(as: Int32.self))) / 65536
        }
        let v = SIMD3(axis(6), axis(10), axis(14))
        lastSampleAt = Date()
        switch usage {
        case Self.accelUsage: onAccel?(v)
        case Self.gyroUsage: onGyro?(v)
        default: break
        }
    }

    /// Ask the SPU drivers to start streaming.
    private func wakeDrivers() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let usage = IORegistryEntryCreateCFProperty(service, kIOHIDPrimaryUsageKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            guard usage == Self.accelUsage || usage == Self.gyroUsage else { continue }
            IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, Self.reportIntervalMicros as CFNumber)
        }
    }
}
