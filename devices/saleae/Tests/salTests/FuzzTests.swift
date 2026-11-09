import Foundation
import Testing
@testable import sal

/// A corrupt file must be rejected or summarized. It must never trap, and anything that
/// parses must encode to JSON, since that is what agents receive.
private func checkSurvives(_ data: Data) throws {
    guard let channel = try? parse(data) else { return }
    let result = summarize(channel, channel: 0)
    #expect(result.edges == channel.edgeCount)
    #expect(result.bursts <= result.edges)
    #expect(abs(2 * result.risingEdges - result.edges) <= 1)
    _ = try JSONEncoder().encode(result)
}

@Suite("Corrupt input")
struct FuzzTests {
    @Test("Every truncation of a real export is rejected")
    func everyTruncation() throws {
        let bytes = try fixtureBytes(1)
        for length in 0..<bytes.count {
            #expect(throws: DigitalFileError.self, "length \(length)") {
                try parse(bytes.prefix(length))
            }
        }
    }

    @Test("Every value of every header byte survives")
    func everyHeaderByte() throws {
        let bytes = try fixtureBytes(1)
        for offset in 0..<DigitalChannel.headerSize {
            for value in UInt8.min...UInt8.max {
                var mutated = bytes
                mutated[offset] = value
                try checkSurvives(mutated)
            }
        }
    }

    @Test("Hostile values in every multi-byte header field survive")
    func hostileFields() throws {
        let bytes = try fixtureBytes(1)
        let doubles: [Double] = [
            .nan, .signalingNaN, .infinity, -.infinity, 0, -0.0, .leastNonzeroMagnitude,
            .leastNormalMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        ]
        let integers: [Int64] = [0, 1, -1, .max, .min, 1 << 61, 1 << 32, 47, 48, 49]

        for value in doubles {
            for offset in [Header.begin, Header.end] {
                var mutated = bytes
                mutated.store(value, at: offset)
                try checkSurvives(mutated)
            }
        }
        for value in integers {
            var count = bytes
            count.store(value, at: Header.count)
            try checkSurvives(count)
            for offset in [Header.version, Header.type, Header.level] {
                var mutated = bytes
                mutated.store(Int32(truncatingIfNeeded: value), at: offset)
                try checkSurvives(mutated)
            }
        }
    }

    @Test("Hostile values at every edge time survive")
    func hostileEdgeTimes() throws {
        let bytes = try fixtureBytes(1)
        let edges = (bytes.count - DigitalChannel.headerSize) / 8
        let values: [Double] = [.nan, .infinity, -.infinity, 0, .leastNonzeroMagnitude, .greatestFiniteMagnitude]
        for index in 0..<edges {
            for value in values {
                var mutated = bytes
                mutated.store(value, at: DigitalChannel.headerSize + index * 8)
                try checkSurvives(mutated)
            }
        }
    }

    @Test("Random corruption survives", arguments: [UInt64(1), 2, 3, 4, 5])
    func randomCorruption(seed: UInt64) throws {
        var random = SplitMix64(state: seed)
        let sources = try [fixtureBytes(1), fixtureBytes(5), fixtureBytes(4)]

        for _ in 0..<4000 {
            var bytes = sources.randomElement(using: &random)!
            for _ in 0..<Int.random(in: 1...8, using: &random) {
                bytes[Int.random(in: 0..<bytes.count, using: &random)] = UInt8.random(in: .min ... .max, using: &random)
            }
            if Bool.random(using: &random) {
                bytes = bytes.prefix(Int.random(in: 0...bytes.count, using: &random))
            }
            try checkSurvives(bytes)
        }
    }

    @Test("Random bytes after a valid magic survive", arguments: [UInt64(11), 12, 13])
    func randomBytes(seed: UInt64) throws {
        var random = SplitMix64(state: seed)
        for _ in 0..<4000 {
            var bytes = Data("<SALEAE>".utf8)
            for _ in 0..<Int.random(in: 0...120, using: &random) {
                bytes.append(UInt8.random(in: .min ... .max, using: &random))
            }
            try checkSurvives(bytes)
        }
    }
}

/// A second implementation written from the definitions, to catch mistakes the first
/// cannot see in itself.
private struct Oracle {
    let edges: Int
    let rising: Int
    let bursts: Int
    let minHigh: Double?
    let minLow: Double?
    let isPeriodic: Bool
    let frequency: Double?

    init(initial: Int, times: [Double]) {
        edges = times.count

        // Level after edge k is the initial level flipped k + 1 times.
        let levelAfter = times.indices.map { (initial + $0 + 1) % 2 }
        let risingTimes = times.indices.filter { levelAfter[$0] == 1 }.map { times[$0] }
        rising = risingTimes.count

        let widths = times.indices.dropLast().map { (level: levelAfter[$0], width: times[$0 + 1] - times[$0]) }
        minHigh = widths.filter { $0.level == 1 }.map(\.width).min()
        minLow = widths.filter { $0.level == 0 }.map(\.width).min()

        if widths.isEmpty {
            bursts = times.isEmpty ? 0 : 1
        } else {
            let ordered = widths.map(\.width).sorted()
            let median = ordered[(ordered.count - 1) / 2]
            bursts = 1 + widths.filter { $0.width > 20 * median }.count
        }

        if risingTimes.count >= 4 {
            let periods = (1..<risingTimes.count).map { risingTimes[$0] - risingTimes[$0 - 1] }
            let ordered = periods.sorted()
            let median = ordered[(ordered.count - 1) / 2]
            isPeriodic = ordered[0] >= median * 0.95 && ordered[ordered.count - 1] <= median * 1.05
            frequency = isPeriodic ? Double(periods.count) / (risingTimes.last! - risingTimes.first!) : nil
        } else {
            isPeriodic = false
            frequency = nil
        }
    }
}

@Suite("Differential")
struct DifferentialTests {
    private func compare(initial: Int, times: [Double]) throws {
        let actual = try summary(initial: Int32(initial), times: times)
        let oracle = Oracle(initial: initial, times: times)
        #expect(actual.edges == oracle.edges)
        #expect(actual.risingEdges == oracle.rising)
        #expect(actual.bursts == oracle.bursts)
        #expect(actual.minHighSeconds == oracle.minHigh)
        #expect(actual.minLowSeconds == oracle.minLow)
        if let periodic = actual.periodic, let frequency = oracle.frequency {
            #expect(abs(periodic.frequencyHz - frequency) <= frequency * 1e-9)
        }
    }

    @Test("Every edge pattern on a coarse time grid matches the oracle")
    func exhaustiveGrid() throws {
        // All subsets of 12 slots, in both starting levels.
        for pattern in 0..<(1 << 12) {
            let times = (0..<12).filter { pattern & (1 << $0) != 0 }.map { Double($0 + 1) }
            try compare(initial: 0, times: times)
            try compare(initial: 1, times: times)
        }
    }

    @Test("Generated signals match the oracle", arguments: [UInt64(101), 102, 103, 104])
    func generatedSignals(seed: UInt64) throws {
        var random = SplitMix64(state: seed)
        for _ in 0..<500 {
            let count = Int.random(in: 0...400, using: &random)
            let base = Double.random(in: 1e-7...1e-3, using: &random)
            let jitter = [0.0, 0.01, 0.04, 0.2].randomElement(using: &random)!
            let burstChance = [0.0, 0.05].randomElement(using: &random)!

            var now = 1.0
            let times = (0..<count).map { _ -> Double in
                now += base * (1 + Double.random(in: -jitter...jitter, using: &random))
                if Double.random(in: 0..<1, using: &random) < burstChance {
                    now += base * 100
                }
                return now
            }
            try compare(initial: Int.random(in: 0...1, using: &random), times: times)
        }
    }

    @Test("Real captures match the oracle", arguments: 0...7)
    func realCaptures(channel: Int) throws {
        let digital = try parse(try fixtureBytes(channel))
        let times = digital.withEdgeTimes { view in (0..<view.count).map { view[$0] } }
        try compare(initial: digital.initialLevel, times: times)
    }
}
