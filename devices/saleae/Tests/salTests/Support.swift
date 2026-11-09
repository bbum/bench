import Foundation
@testable import sal

let fixtureDirectory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/testgen")

func fixtureBytes(_ channel: Int) throws -> Data {
    try Data(contentsOf: fixtureDirectory.appendingPathComponent("digital_\(channel).bin"))
}

/// Deterministic, so a fuzz failure reproduces from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Byte offsets of the header fields in a version 0 digital export.
enum Header {
    static let version = 8
    static let type = 12
    static let level = 16
    static let begin = 20
    static let end = 28
    static let count = 36
}

extension Data {
    mutating func appendValue<T>(_ value: T) {
        Swift.withUnsafeBytes(of: value) { append(contentsOf: $0) }
    }

    mutating func store<T>(_ value: T, at offset: Int) {
        Swift.withUnsafeBytes(of: value) { bytes in
            replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
    }
}

/// Builds a well-formed export unless a field is deliberately overridden.
func digitalFile(
    initial: Int32 = 0,
    begin: Double = 0,
    end: Double? = nil,
    times: [Double] = [],
    version: Int32 = 0,
    type: Int32 = 0,
    count: Int64? = nil
) -> Data {
    var data = Data("<SALEAE>".utf8)
    data.appendValue(version)
    data.appendValue(type)
    data.appendValue(initial)
    data.appendValue(begin)
    data.appendValue(end ?? (times.last ?? begin))
    data.appendValue(count ?? Int64(times.count))
    times.forEach { data.appendValue($0) }
    return data
}

func parse(_ data: Data) throws -> DigitalChannel {
    try DigitalChannel(data: data, name: "test")
}

func summary(initial: Int32 = 0, times: [Double]) throws -> ChannelSummary {
    summarize(try parse(digitalFile(initial: initial, times: times)), channel: 0)
}

/// Rising-edge square wave: `count` periods, each high for `high` then low for `low`.
func squareWave(periods count: Int, high: Double, low: Double) -> [Double] {
    var times: [Double] = []
    var now = 1.0
    for _ in 0..<count {
        times.append(now)
        times.append(now + high)
        now += high + low
    }
    return times
}
