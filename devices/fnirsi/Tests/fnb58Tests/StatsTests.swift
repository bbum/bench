import Foundation
import Testing
@testable import fnb58

/// Written apart from `Stats`, the plain way, as an oracle.
private struct Oracle {
    var mean, peak, p99, low, peakAt, vMin, vMax, vMean, pMean, pPeak, mWh, mAh: Double

    init(_ t: [Double], _ v: [Double], _ i: [Double]) {
        let n = Double(i.count)
        mean = i.reduce(0, +) / n
        peak = i.max()!
        peakAt = t[i.firstIndex(of: peak)!]
        low = i.min()!
        // p99 by counting: smallest value with at least 99% of values at or below it.
        p99 = i.sorted().first { x in Double(i.filter { $0 <= x }.count) >= 0.99 * n }!
        vMin = v.min()!
        vMax = v.max()!
        vMean = v.reduce(0, +) / n
        let p = zip(v, i).map(*)
        pMean = p.reduce(0, +) / n
        pPeak = p.max()!
        // Joules over 10 ms samples, to watt-hours, to milliwatt-hours.
        mWh = p.map { $0 * 0.01 }.reduce(0, +) / 3600 * 1000
        mAh = i.map { $0 * 0.01 }.reduce(0, +) / 3600 * 1000
    }
}

private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool {
    abs(a - b) <= tolerance * max(1, abs(b))
}

@Suite struct StatsTests {
    @Test func emptyIsNil() {
        #expect(Stats(times: [], voltage: [], current: []) == nil)
    }

    @Test func singleSample() throws {
        let stats = try #require(Stats(times: [0], voltage: [5], current: [2]))
        #expect(stats.samples == 1)
        #expect(stats.durationSeconds == 0.01)
        #expect(stats.currentA.mean == 2 && stats.currentA.peak == 2 && stats.currentA.p99 == 2 && stats.currentA.min == 2)
        #expect(stats.powerW.peak == 10)
        // 10 W for 10 ms = 0.1 J = 0.02778 mWh.
        #expect(stats.energyMWh == 0.0278)
    }

    @Test func oneHourAtOneWattIsOneWattHour() throws {
        let n = 360_000
        let stats = try #require(Stats(
            times: (0..<n).map { Double($0) / 100 }, voltage: Array(repeating: 5, count: n), current: Array(repeating: 0.2, count: n)))
        #expect(stats.durationSeconds == 3600)
        #expect(close(stats.energyMWh, 1000, 1e-9))
        #expect(close(stats.chargeMAh, 200, 1e-9))
    }

    /// Nearest rank on both sides of where the 99th value changes.
    @Test func percentileBoundaries() {
        #expect(percentile([], 0.99).isNaN)
        #expect(percentile([3], 0.99) == 3)
        let hundred = (1...100).map(Double.init)
        #expect(percentile(hundred, 0.99) == 99)
        #expect(percentile(hundred + [101], 0.99) == 100)
        let two_hundred = (1...200).map(Double.init)
        #expect(percentile(two_hundred, 0.99) == 198)
        #expect(percentile(hundred.reversed(), 0.99) == 99)
        #expect(percentile(hundred, 1) == 100)
        #expect(percentile(hundred, 0) == 1)
    }

    @Test func peakTimeIsTheFirstPeak() throws {
        let stats = try #require(Stats(times: [0, 0.01, 0.02, 0.03], voltage: [5, 5, 5, 5], current: [1, 3, 3, 2]))
        #expect(stats.currentA.peakAt == 0.01)
    }

    @Test func matchesTheOracleOnRandomCaptures() throws {
        var rng = SeededGenerator(seed: 42)
        for round in 0..<300 {
            let n = round < 20 ? round + 1 : Int.random(in: 1...700, using: &rng)
            let start = Double(Int.random(in: 0...1000, using: &rng)) / 100
            let t = (0..<n).map { start + Double($0) / 100 }
            let v = (0..<n).map { _ in Double(Int.random(in: 0...2_400_000, using: &rng)) / 100_000 }
            // Spiky current, with ties, like a printer.
            let i = (0..<n).map { _ in Double(Int.random(in: 0...20, using: &rng) == 0 ? Int.random(in: 0...500_000, using: &rng) : Int.random(in: 0...5, using: &rng)) / 100_000 }
            let stats = try #require(Stats(times: t, voltage: v, current: i))
            let oracle = Oracle(t, v, i)
            #expect(stats.samples == n)
            #expect(close(stats.durationSeconds, Double(n) / 100))
            #expect(close(stats.currentA.mean, oracle.mean))
            #expect(stats.currentA.peak == oracle.peak)
            #expect(stats.currentA.p99 == oracle.p99, "round \(round)")
            #expect(stats.currentA.min == oracle.low)
            #expect(close(stats.currentA.peakAt, oracle.peakAt))
            #expect(stats.voltageV.min == oracle.vMin && stats.voltageV.max == oracle.vMax)
            #expect(close(stats.voltageV.mean, oracle.vMean))
            #expect(close(stats.powerW.mean, oracle.pMean))
            #expect(close(stats.powerW.peak, oracle.pPeak))
            #expect(abs(stats.energyMWh - oracle.mWh) <= 0.00005 + 1e-9 * oracle.mWh)
            #expect(abs(stats.chargeMAh - oracle.mAh) <= 0.00005 + 1e-9 * oracle.mAh)
        }
    }

    @Test func mismatchedArraysUseTheShortest() throws {
        let stats = try #require(Stats(times: [0, 0.01, 0.02], voltage: [5, 5], current: [1, 2, 3]))
        #expect(stats.samples == 2)
        #expect(stats.currentA.peak == 2)
    }

    @Test func roundingHelper() {
        #expect(rounded(0.1 + 0.2) == 0.3)
        #expect(rounded(1.23456789, 2) == 1.23)
        #expect(rounded(-0.000_000_4) == 0)
    }
}
