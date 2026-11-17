import Foundation
@preconcurrency import IOKit.hid

/// The real meter, through IOHIDManager. Needs no root and no driver detach.
struct HIDTransport: MeterTransport {
    func meters() -> [MeterInfo] {
        Self.matching().map { MeterInfo(serial: $0.serial) }
    }

    func open(serial: String?) throws -> any MeterLink {
        let found = Self.matching()
        let chosen = try chooseMeter(found.map(\.serial), serial: serial)
        return try HIDLink(device: found.first { $0.serial == chosen }!.device)
    }

    private static func matching() -> [(serial: String, device: IOHIDDevice)] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let criteria: [String: Any] = [
            kIOHIDVendorIDKey: FNB58.vendorID,
            kIOHIDProductIDKey: FNB58.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, criteria as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.map { device in
            let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
            return (serial ?? "unknown", device)
        }.sorted { $0.serial < $1.serial }
    }
}

/// IOKit delivers reports on a run loop owned by a dedicated thread. Scheduling the device
/// on a dispatch queue instead left the meter refusing output reports until it was
/// replugged, so the run loop is the proven path.
final class HIDLink: MeterLink, @unchecked Sendable {
    let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let device: IOHIDDevice
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: FNB58.reportSize)
    private let lock = NSLock()
    private var isClosed = false
    private var runLoop: CFRunLoop?
    /// One output report in flight at a time.
    private let sendLock = NSLock()

    init(device: IOHIDDevice) throws {
        self.device = device
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            buffer.deallocate()
            throw MeterError.openFailed(status)
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()!
            // Unretained: the thread holds self until the loop stops.
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(device, buffer, FNB58.reportSize, { context, result, _, _, _, report, length in
                guard let context, result == kIOReturnSuccess else { return }
                let link = Unmanaged<HIDLink>.fromOpaque(context).takeUnretainedValue()
                link.continuation.yield(.report(Array(UnsafeBufferPointer(start: report, count: length))))
            }, context)
            IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
                guard let context else { return }
                let link = Unmanaged<HIDLink>.fromOpaque(context).takeUnretainedValue()
                link.continuation.yield(.removed)
                link.close()
            }, context)
            IOHIDDeviceScheduleWithRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
            lock.withLock { runLoop = loop }
            ready.signal()
            while lock.withLock({ !isClosed }) {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
            IOHIDDeviceRegisterInputReportCallback(device, buffer, FNB58.reportSize, nil, nil)
            IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            buffer.deallocate()
            continuation.finish()
        }
        thread.name = "fnb58 HID"
        thread.start()
        ready.wait()
    }

    /// Blocks until the meter takes the report. IOKit gives up after about 5 s.
    func send(_ report: [UInt8]) throws {
        guard !lock.withLock({ isClosed }) else { throw MeterError.closed }
        let status = sendLock.withLock {
            report.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
            }
        }
        guard status == kIOReturnSuccess else { throw MeterError.sendFailed(status) }
    }

    func close() {
        let loop: CFRunLoop? = lock.withLock {
            defer { isClosed = true }
            return isClosed ? nil : runLoop
        }
        if let loop { CFRunLoopStop(loop) }
    }
}
