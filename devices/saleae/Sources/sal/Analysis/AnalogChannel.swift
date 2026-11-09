import Foundation

enum AnalogFileError: Error, LocalizedError, Equatable {
    case tooShort(name: String)
    case badMagic(name: String)
    case unsupportedVersion(name: String, version: Int32)
    case notAnalog(name: String, type: Int32)
    case invalidBeginTime(name: String)
    case invalidRate(name: String)
    case invalidSampleCount(name: String, count: UInt64)
    case sizeMismatch(name: String, expected: Int, actual: Int)
    case invalidSample(name: String, index: Int)

    var errorDescription: String? {
        switch self {
        case .tooShort(let name): "\(name): too short to be a Saleae binary export"
        case .badMagic(let name): "\(name): not a Saleae binary export"
        case .unsupportedVersion(let name, let version): "\(name): unsupported binary format version \(version)"
        case .notAnalog(let name, let type): "\(name): expected analog data, found type \(type)"
        case .invalidBeginTime(let name): "\(name): invalid begin time"
        case .invalidRate(let name): "\(name): invalid sample rate or downsample ratio"
        case .invalidSampleCount(let name, let count): "\(name): invalid sample count \(count)"
        case .sizeMismatch(let name, let expected, let actual): "\(name): expected \(expected) bytes, found \(actual)"
        case .invalidSample(let name, let index): "\(name): sample \(index) is not a finite voltage"
        }
    }
}

/// One channel of a Saleae version 0 analog binary export, memory-mapped.
///
/// Layout is little-endian: `<SALEAE>`, version (i32), type (i32), begin time (f64), sample
/// rate (u64), downsample ratio (u64), sample count (u64), then one f32 per sample, in volts.
///
/// A successfully created value guarantees at least one sample, every one of them finite.
struct AnalogChannel: Sendable {
    static let headerSize = 48

    let beginTime: Double
    let sampleCount: Int
    /// Samples per second actually in the file, after downsampling.
    let effectiveSampleRate: Double
    private let data: Data

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped), name: url.lastPathComponent)
    }

    init(data: Data, name: String) throws {
        guard data.count >= Self.headerSize else { throw AnalogFileError.tooShort(name: name) }
        guard data.prefix(8).elementsEqual("<SALEAE>".utf8) else { throw AnalogFileError.badMagic(name: name) }

        let (version, type, begin, rate, downsample, count) = data.withUnsafeBytes { raw in
            (
                Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: Int32.self)),
                Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: Int32.self)),
                raw.loadUnaligned(fromByteOffset: 16, as: Double.self),
                UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self)),
                UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 32, as: UInt64.self)),
                UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 40, as: UInt64.self))
            )
        }

        guard version == 0 else { throw AnalogFileError.unsupportedVersion(name: name, version: version) }
        guard type == 1 else { throw AnalogFileError.notAnalog(name: name, type: type) }
        guard begin.isFinite else { throw AnalogFileError.invalidBeginTime(name: name) }
        guard rate > 0, downsample > 0, downsample <= rate else { throw AnalogFileError.invalidRate(name: name) }

        // Bounding the count first keeps the size arithmetic below from overflowing.
        let payload = data.count - Self.headerSize
        guard count > 0, count <= UInt64(payload / MemoryLayout<Float>.size) else {
            throw AnalogFileError.invalidSampleCount(name: name, count: count)
        }
        let expected = Self.headerSize + Int(count) * MemoryLayout<Float>.size
        guard data.count == expected else {
            throw AnalogFileError.sizeMismatch(name: name, expected: expected, actual: data.count)
        }

        let invalid = data.withUnsafeBytes { raw -> Int? in
            for index in 0..<Int(count) {
                let sample = raw.loadUnaligned(
                    fromByteOffset: Self.headerSize + index * MemoryLayout<Float>.size, as: Float.self)
                if !sample.isFinite { return index }
            }
            return nil
        }
        if let invalid { throw AnalogFileError.invalidSample(name: name, index: invalid) }

        self.beginTime = begin
        self.sampleCount = Int(count)
        self.effectiveSampleRate = Double(rate) / Double(downsample)
        self.data = data
    }

    /// Calls `body` with a view of the samples. The view must not escape.
    func withSamples<Result>(_ body: (AnalogSamples) throws -> Result) rethrows -> Result {
        try data.withUnsafeBytes { try body(AnalogSamples(raw: $0, count: sampleCount)) }
    }
}

struct AnalogSamples {
    fileprivate let raw: UnsafeRawBufferPointer
    let count: Int

    subscript(index: Int) -> Double {
        Double(raw.loadUnaligned(fromByteOffset: AnalogChannel.headerSize + index * MemoryLayout<Float>.size, as: Float.self))
    }
}

struct AnalogSummary: Codable, Sendable, Equatable {
    /// The two levels of a signal that swings, each the average of samples on its side.
    struct Levels: Codable, Sendable, Equatable {
        var lowVolts: Double
        var highVolts: Double
    }

    /// Present only when every period is within 5% of the median.
    struct Periodic: Codable, Sendable, Equatable {
        var frequencyHz: Double
        var dutyPercent: Double
    }

    var channel: UInt32
    var samples: Int
    var sampleRateHz: Double
    var minVolts: Double
    var maxVolts: Double
    var meanVolts: Double
    var rmsVolts: Double
    var levels: Levels?
    var periodic: Periodic?
}

/// Below this swing a channel is treated as a steady level plus noise.
let minimumSwingVolts = 0.2

func summarize(_ analog: AnalogChannel, channel: UInt32) -> AnalogSummary {
    analog.withSamples { samples in
        var minimum = samples[0]
        var maximum = samples[0]
        var sum = 0.0
        var squares = 0.0
        for index in 0..<samples.count {
            let value = samples[index]
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            sum += value
            squares += value * value
        }

        let count = Double(samples.count)
        var summary = AnalogSummary(
            channel: channel, samples: samples.count, sampleRateHz: analog.effectiveSampleRate, minVolts: minimum,
            maxVolts: maximum, meanVolts: sum / count, rmsVolts: (squares / count).squareRoot())

        let swing = maximum - minimum
        guard swing >= minimumSwingVolts else { return summary }

        let middle = (minimum + maximum) / 2
        var lowSum = 0.0
        var lowCount = 0.0
        var highSum = 0.0
        var highCount = 0.0
        for index in 0..<samples.count {
            let value = samples[index]
            if value < middle {
                lowSum += value
                lowCount += 1
            } else {
                highSum += value
                highCount += 1
            }
        }
        if lowCount > 0, highCount > 0 {
            summary.levels = AnalogSummary.Levels(lowVolts: lowSum / lowCount, highVolts: highSum / highCount)
        }

        summary.periodic = periodicAnalog(
            samples, middle: middle, hysteresis: swing * 0.1, sampleRate: analog.effectiveSampleRate)
        return summary
    }
}

/// Finds periods from threshold crossings. Hysteresis stops noise near the threshold from
/// counting as extra edges.
private func periodicAnalog(
    _ samples: AnalogSamples,
    middle: Double,
    hysteresis: Double,
    sampleRate: Double
) -> AnalogSummary.Periodic? {
    var isHigh = samples[0] >= middle
    var rises: [Int] = []
    var highSamples = 0
    var highAtFirstRise = 0
    var highAtLastRise = 0
    for index in 0..<samples.count {
        let value = samples[index]
        if !isHigh, value >= middle + hysteresis {
            isHigh = true
            rises.append(index)
            if rises.count == 1 { highAtFirstRise = highSamples }
            highAtLastRise = highSamples
        } else if isHigh, value <= middle - hysteresis {
            isHigh = false
        }
        if isHigh { highSamples += 1 }
    }

    guard rises.count >= 4 else { return nil }
    let periods = zip(rises, rises.dropFirst()).map { Double($1 - $0) }
    let median = periods.sorted()[(periods.count - 1) / 2]
    guard median > 0, periods.allSatisfy({ abs($0 - median) <= median * 0.05 }) else { return nil }

    let span = Double(rises[rises.count - 1] - rises[0])
    return AnalogSummary.Periodic(
        frequencyHz: sampleRate * Double(periods.count) / span, dutyPercent: 100 * Double(highAtLastRise - highAtFirstRise) / span)
}
