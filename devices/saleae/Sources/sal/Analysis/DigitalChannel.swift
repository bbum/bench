import Foundation

enum DigitalFileError: Error, LocalizedError, Equatable {
    case tooShort(name: String)
    case badMagic(name: String)
    case unsupportedVersion(name: String, version: Int32)
    case notDigital(name: String, type: Int32)
    case invalidInitialLevel(name: String, level: Int32)
    case invalidTimeRange(name: String)
    case invalidEdgeCount(name: String, count: Int64)
    case sizeMismatch(name: String, expected: Int, actual: Int)
    case invalidEdgeTime(name: String, index: Int)

    var errorDescription: String? {
        switch self {
        case .tooShort(let name):
            "\(name): too short to be a Saleae binary export"
        case .badMagic(let name):
            "\(name): not a Saleae binary export"
        case .unsupportedVersion(let name, let version):
            "\(name): unsupported binary format version \(version)"
        case .notDigital(let name, let type):
            "\(name): expected digital data, found type \(type)"
        case .invalidInitialLevel(let name, let level):
            "\(name): invalid initial level \(level)"
        case .invalidTimeRange(let name):
            "\(name): invalid capture time range"
        case .invalidEdgeCount(let name, let count):
            "\(name): invalid edge count \(count)"
        case .sizeMismatch(let name, let expected, let actual):
            "\(name): expected \(expected) bytes, found \(actual)"
        case .invalidEdgeTime(let name, let index):
            "\(name): edge \(index) is out of order or out of range"
        }
    }
}

/// One channel of a Saleae version 0 digital binary export, memory-mapped.
///
/// Layout is little-endian: `<SALEAE>`, version (i32), type (i32), initial state (i32),
/// begin time (f64), end time (f64), transition count (i64), then one f64 per transition.
///
/// A successfully created value guarantees: the level is 0 or 1, the time range is finite,
/// and edge times strictly increase within that range.
struct DigitalChannel: Sendable {
    static let headerSize = 44

    let initialLevel: Int
    let beginTime: Double
    let endTime: Double
    let edgeCount: Int
    private let data: Data

    init(contentsOf url: URL) throws {
        try self.init(
            data: Data(contentsOf: url, options: .alwaysMapped),
            name: url.lastPathComponent
        )
    }

    init(data: Data, name: String) throws {
        guard data.count >= Self.headerSize else { throw DigitalFileError.tooShort(name: name) }
        guard data.prefix(8).elementsEqual("<SALEAE>".utf8) else {
            throw DigitalFileError.badMagic(name: name)
        }

        let (version, type, level, begin, end, count) = data.withUnsafeBytes { raw in
            (
                Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: Int32.self)),
                Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: Int32.self)),
                Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 16, as: Int32.self)),
                raw.loadUnaligned(fromByteOffset: 20, as: Double.self),
                raw.loadUnaligned(fromByteOffset: 28, as: Double.self),
                Int64(littleEndian: raw.loadUnaligned(fromByteOffset: 36, as: Int64.self))
            )
        }

        guard version == 0 else {
            throw DigitalFileError.unsupportedVersion(name: name, version: version)
        }
        guard type == 0 else { throw DigitalFileError.notDigital(name: name, type: type) }
        guard level == 0 || level == 1 else {
            throw DigitalFileError.invalidInitialLevel(name: name, level: level)
        }
        // These two comparisons also reject every NaN and infinity.
        guard end >= begin, (end - begin).isFinite else {
            throw DigitalFileError.invalidTimeRange(name: name)
        }

        // Bounding the count first keeps the size arithmetic below from overflowing.
        let payload = data.count - Self.headerSize
        guard count >= 0, count <= payload / MemoryLayout<Double>.size else {
            throw DigitalFileError.invalidEdgeCount(name: name, count: count)
        }
        let expected = Self.headerSize + Int(count) * MemoryLayout<Double>.size
        guard data.count == expected else {
            throw DigitalFileError.sizeMismatch(name: name, expected: expected, actual: data.count)
        }

        let invalidEdge = data.withUnsafeBytes { raw -> Int? in
            var previous = -Double.infinity
            for index in 0..<Int(count) {
                let time = raw.loadUnaligned(
                    fromByteOffset: Self.headerSize + index * MemoryLayout<Double>.size,
                    as: Double.self
                )
                guard time > previous, time >= begin, time <= end else { return index }
                previous = time
            }
            return nil
        }
        if let invalidEdge {
            throw DigitalFileError.invalidEdgeTime(name: name, index: invalidEdge)
        }

        self.initialLevel = Int(level)
        self.beginTime = begin
        self.endTime = end
        self.edgeCount = Int(count)
        self.data = data
    }

    /// Calls `body` with a view of the transition times. The view must not escape.
    func withEdgeTimes<Result>(_ body: (EdgeTimes) throws -> Result) rethrows -> Result {
        try data.withUnsafeBytes { try body(EdgeTimes(raw: $0, count: edgeCount)) }
    }
}

/// Transition times in seconds. They sit at a 4-byte offset, so reads are unaligned.
struct EdgeTimes {
    fileprivate let raw: UnsafeRawBufferPointer
    let count: Int

    subscript(index: Int) -> Double {
        raw.loadUnaligned(
            fromByteOffset: DigitalChannel.headerSize + index * MemoryLayout<Double>.size,
            as: Double.self
        )
    }
}
