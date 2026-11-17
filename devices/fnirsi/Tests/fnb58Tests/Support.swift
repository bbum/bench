import Foundation
@testable import fnb58

/// A data report holding `samples`, laid out as the meter does.
func dataReport(_ samples: [Sample], crc: Bool = true) -> [UInt8] {
    precondition(samples.count == 4)
    var bytes = [UInt8](repeating: 0, count: 64)
    bytes[0] = 0xAA
    bytes[1] = 0x04
    for (index, sample) in samples.enumerated() {
        let at = 2 + index * 15
        func put16(_ value: UInt32, _ offset: Int) {
            bytes[at + offset] = UInt8(value & 0xFF)
            bytes[at + offset + 1] = UInt8(value >> 8 & 0xFF)
        }
        func put32(_ value: UInt32, _ offset: Int) { put16(value & 0xFFFF, offset); put16(value >> 16, offset + 2) }
        put32(UInt32((sample.voltage * 100_000).rounded()), 0)
        put32(UInt32((sample.current * 100_000).rounded()), 4)
        put16(UInt32((sample.dPlus * 1000).rounded()), 8)
        put16(UInt32((sample.dMinus * 1000).rounded()), 10)
        bytes[at + 12] = sample.signByte
        put16(UInt32((abs(sample.temperature) * 10).rounded()), 13)
    }
    if crc { bytes[63] = FNB58.crc8(bytes[1..<63]) }
    return bytes
}

func sample(_ volts: Double, _ amps: Double) -> Sample {
    Sample(voltage: volts, current: amps, dPlus: 0.6, dMinus: 0.6, temperature: 25.3, signByte: 1)
}

/// A deterministic generator, so random tests repeat.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Stands in for the meter. Answers 0x81 with an 0x03 report, then streams after the
/// second 0x82, one report per `interval`.
final class FakeLink: MeterLink, @unchecked Sendable {
    struct Sent: Sendable {
        var at: ContinuousClock.Instant
        var code: UInt8
    }

    let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()
    private var _sent: [Sent] = []
    private var _closed = false
    private var feeder: Task<Void, Never>?
    let interval: Duration
    /// Reports to stream, cycled. Each report is 4 samples.
    let reports: [[UInt8]]
    /// Send numbers (0-based) that fail.
    let failingSends: Set<Int>
    /// Stop streaming after this many reports: as a stall, or an unplug.
    let stopAfter: (count: Int, unplug: Bool)?
    let replies: Bool
    /// Like the meter, stop streaming when no 0x82 or 0x83 has come for this long.
    let lapse: Duration
    /// Stop streaming once, after this many reports, as a stream that winds down.
    let dieOnceAfter: Int?
    private var died = false
    private var lastPoll = ContinuousClock.now

    init(interval: Duration = .milliseconds(2), reports: [[UInt8]] = [dataReport([sample(5, 0.1), sample(5, 0.2), sample(5, 0.3), sample(5, 0.4)])],
         failingSends: Set<Int> = [], stopAfter: (count: Int, unplug: Bool)? = nil, replies: Bool = true,
         lapse: Duration = .milliseconds(150), streaming: Bool = false, dieOnceAfter: Int? = nil) {
        self.dieOnceAfter = dieOnceAfter
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.interval = interval
        self.reports = reports
        self.failingSends = failingSends
        self.stopAfter = stopAfter
        self.replies = replies
        self.lapse = lapse
        if streaming { startFeeding() }
    }

    /// Reports yielded so far, and whether the meter is still sending.
    private(set) var fed = 0
    var feeding: Bool { lock.withLock { feeder != nil } }

    var sent: [Sent] { lock.withLock { _sent } }
    var closed: Bool { lock.withLock { _closed } }

    func inject(_ bytes: [UInt8]) { continuation.yield(.report(bytes)) }

    func send(_ report: [UInt8]) throws {
        let (number, closed): (Int, Bool) = lock.withLock {
            _sent.append(Sent(at: .now, code: report[1]))
            return (_sent.count - 1, _closed)
        }
        if closed { throw MeterError.closed }
        if failingSends.contains(number) { throw MeterError.sendFailed(-536_870_186) }
        if report[1] == 0x81, replies {
            var reply = [UInt8](repeating: 0, count: 64)
            reply[0] = 0xAA
            reply[1] = 0x03
            continuation.yield(.report(reply))
        }
        if report[1] == 0x82 || report[1] == 0x83 { lock.withLock { lastPoll = .now } }
        let starts = lock.withLock { _sent.filter { $0.code == 0x82 }.count }
        if report[1] == 0x82, starts >= 2, !feeding { startFeeding() }
    }

    private var polled: Bool { lock.withLock { ContinuousClock.now - lastPoll < lapse } }

    private func startFeeding() {
        let (continuation, reports, interval, stopAfter) = (continuation, reports, interval, stopAfter)
        lock.withLock { lastPoll = .now }
        let task = Task.detached { [weak self] in
            var count = 0
            while !Task.isCancelled {
                guard let self, self.polled else {
                    self?.lock.withLock { self?.feeder = nil }
                    return
                }
                if let dieOnceAfter = self.dieOnceAfter, count >= dieOnceAfter, !self.lock.withLock({ self.died }) {
                    self.lock.withLock { self.died = true; self.feeder = nil }
                    return
                }
                if let stopAfter, count >= stopAfter.count {
                    if stopAfter.unplug {
                        continuation.yield(.removed)
                        self.close()
                    }
                    return
                }
                continuation.yield(.report(reports[count % reports.count]))
                count += 1
                self.lock.withLock { self.fed = count }
                try? await Task.sleep(for: interval)
            }
        }
        lock.withLock { feeder = task }
    }

    func close() {
        let task: Task<Void, Never>? = lock.withLock {
            defer { _closed = true }
            return _closed ? nil : feeder
        }
        task?.cancel()
        continuation.finish()
    }
}

final class FakeTransport: MeterTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeLink] = []
    let serials: [String]
    let failOpen: Bool
    let makeLink: @Sendable () -> FakeLink

    init(serials: [String] = ["TEST0001"], failOpen: Bool = false, makeLink: @escaping @Sendable () -> FakeLink = { FakeLink() }) {
        self.serials = serials
        self.failOpen = failOpen
        self.makeLink = makeLink
    }

    var links: [FakeLink] { lock.withLock { made } }
    var allClosed: Bool { links.filter { !$0.closed }.isEmpty }

    func meters() -> [MeterInfo] { serials.map(MeterInfo.init) }

    func open(serial: String?) throws -> any MeterLink {
        _ = try chooseMeter(serials, serial: serial)
        if failOpen { throw MeterError.openFailed(-536_870_212) }
        let link = makeLink()
        lock.withLock { made.append(link) }
        return link
    }
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fnb58-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
