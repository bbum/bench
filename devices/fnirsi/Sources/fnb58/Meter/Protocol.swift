import Foundation

/// The FNB58's USB HID protocol: 64-byte reports with no report ID.
enum FNB58 {
    static let vendorID = 0x2E3C
    static let productID = 0x5558
    static let reportSize = 64
    static let samplesPerReport = 4
    static let sampleSize = 15
    static let sampleRate = 100.0

    /// Least time between start commands. Sent back to back, they wedge the meter.
    static let commandGap = Duration.milliseconds(50)

    /// Keepalive period. Other tools use 0.9 to 1 s.
    static let keepaliveInterval = Duration.milliseconds(900)

    /// Sent once to start the stream, in this order.
    static let startCommands: [[UInt8]] = [command(0x81), command(0x82), command(0x82)]
    /// Sent about once a second, or the stream stops.
    static let keepalive = command(0x83)

    /// Two header bytes, 61 zeros, then the checksum.
    static func command(_ code: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportSize)
        report[0] = 0xAA
        report[1] = code
        report[63] = crc8(report[1..<63])
        return report
    }

    /// CRC-8, polynomial 0x39, initial value 0x42, no reflection, no final XOR.
    static func crc8(_ bytes: some Sequence<UInt8>) -> UInt8 {
        var crc: UInt8 = 0x42
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x39 : crc << 1
            }
        }
        return crc
    }
}

/// One reading. The meter takes 100 a second.
struct Sample: Equatable, Sendable {
    var voltage: Double
    var current: Double
    var dPlus: Double
    var dMinus: Double
    var temperature: Double
    /// Byte 12: the temperature's sign, 1 for positive, 0 for negative. Other tools agree;
    /// this unit has only shown 1. Kept raw for raw dumps.
    var signByte: UInt8

    var power: Double { voltage * current }
}

enum Report: Equatable, Sendable {
    case samples([Sample])
    /// Any other report type. Ignored, but raw dumps show it.
    case other(type: UInt8)
    case invalid(String)

    /// Never traps, whatever the bytes.
    init(_ bytes: [UInt8]) {
        guard bytes.count == FNB58.reportSize else {
            self = .invalid("\(bytes.count) bytes, expected \(FNB58.reportSize)")
            return
        }
        guard bytes[0] == 0xAA else {
            self = .invalid(String(format: "header 0x%02X, expected 0xAA", bytes[0]))
            return
        }
        guard bytes[1] == 0x04 else {
            self = .other(type: bytes[1])
            return
        }
        // The checksum is optional: the meter does not always fill it in.
        self = .samples((0..<FNB58.samplesPerReport).map { index in
            Sample(bytes: bytes, at: 2 + index * FNB58.sampleSize)
        })
    }

    /// Whether byte 63 holds the CRC of bytes 1 to 62. Only raw dumps look.
    static func checksumMatches(_ bytes: [UInt8]) -> Bool {
        bytes.count == FNB58.reportSize && FNB58.crc8(bytes[1..<63]) == bytes[63]
    }
}

extension Sample {
    init(bytes: [UInt8], at offset: Int) {
        func u16(_ at: Int) -> UInt32 { UInt32(bytes[offset + at]) | UInt32(bytes[offset + at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { u16(at) | u16(at + 2) << 16 }
        voltage = Double(u32(0)) / 100_000
        current = Double(u32(4)) / 100_000
        dPlus = Double(u16(8)) / 1000
        dMinus = Double(u16(10)) / 1000
        signByte = bytes[offset + 12]
        temperature = Double(u16(13)) / 10 * (signByte == 0 ? -1 : 1)
    }
}

/// What the meter says about itself in its reply to 0x81 (report type 0x03). Model and
/// firmware offsets come from other tools; firmware 1.18 matches this unit's screen.
struct DeviceInfo: Encodable, Equatable, Sendable {
    var model: Int
    var firmware: String
    var hex: String

    init?(_ bytes: [UInt8]) {
        guard bytes.count == FNB58.reportSize, bytes[0] == 0xAA, bytes[1] == 0x03 else { return nil }
        model = Int(bytes[6]) | Int(bytes[7]) << 8
        let version = Int(bytes[8]) | Int(bytes[9]) << 8
        firmware = "\(version / 100).\(String(format: "%02d", version % 100))"
        hex = fnb58.hex(bytes[2..<16])
    }
}

/// Lowercase hex, bytes separated by spaces.
func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}
