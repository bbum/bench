import Foundation

enum LinkEvent: Equatable, Sendable {
    case report([UInt8])
    /// The meter was unplugged. No events follow.
    case removed
}

/// An open connection to one meter.
protocol MeterLink: AnyObject, Sendable {
    /// Finishes after `.removed` or `close()`.
    var events: AsyncStream<LinkEvent> { get }
    func send(_ report: [UInt8]) throws
    /// Safe to call more than once.
    func close()
}

struct MeterInfo: Encodable, Equatable, Sendable {
    var serial: String
}

/// Finds and opens meters. Tests substitute a fake.
protocol MeterTransport: Sendable {
    func meters() -> [MeterInfo]
    func open(serial: String?) throws -> any MeterLink
}

enum MeterError: Error, Equatable, CustomStringConvertible {
    case notFound(serial: String?)
    case ambiguous([String])
    case openFailed(Int32)
    case sendFailed(Int32)
    case closed
    case noData(seconds: Double)

    var description: String {
        switch self {
        case .notFound(nil): "No FNB58 found on USB."
        case .notFound(let serial?): "No FNB58 with serial \(serial) found on USB."
        case .ambiguous(let serials):
            "More than one FNB58 is connected (\(serials.joined(separator: ", "))). Pass a serial."
        case .openFailed(let code): String(format: "Could not open the FNB58 (IOReturn 0x%08X).", UInt32(bitPattern: code))
        case .sendFailed(let code): String(format: "Could not send to the FNB58 (IOReturn 0x%08X).", UInt32(bitPattern: code))
        case .closed: "The FNB58 connection is closed."
        case .noData(let seconds): "The FNB58 sent no data in \(seconds) s."
        }
    }
}

/// Picks the meter to open: the one with `serial`, or the only one there is.
func chooseMeter(_ serials: [String], serial: String?) throws -> String {
    if let serial {
        guard serials.contains(serial) else { throw MeterError.notFound(serial: serial) }
        return serial
    }
    switch serials.count {
    case 0: throw MeterError.notFound(serial: nil)
    case 1: return serials[0]
    default: throw MeterError.ambiguous(serials.sorted())
    }
}
