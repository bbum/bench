import Testing
@testable import sal

/// What one cycle of the testgen firmware produces on each channel. See testgen/README.md.
enum Testgen {
    static let edgesPerCycle: [UInt32: Int] = [2: 94, 3: 96, 4: 24, 5: 2, 6: 26, 7: 92]

    /// Checks a capture of all 8 channels. Captures can start and stop mid-cycle, so
    /// edge counts are allowed to be off by up to one cycle.
    static func verify(_ summary: CaptureSummary) throws {
        #expect(summary.channels.map(\.channel) == Array(0...7))

        let pwm = try #require(summary.channels[0].periodic)
        #expect(abs(pwm.frequencyHz - 1000) < 10)
        #expect(abs(pwm.dutyPercent - 25) < 1)

        let cycles = summary.channels[1].risingEdges
        #expect(cycles > 0)

        for (channel, perCycle) in edgesPerCycle {
            let edges = summary.channels[Int(channel)].edges
            #expect(abs(edges - cycles * perCycle) <= perCycle, "channel \(channel): \(edges) edges")
        }

        let uartBit = 1.0 / 115_200
        let uartMinimum = try #require(summary.channels[2].minHighSeconds)
        #expect(abs(uartMinimum - uartBit) < uartBit * 0.1)

        let spiHalfPeriod = try #require(summary.channels[3].minHighSeconds)
        #expect(abs(spiHalfPeriod - 0.5e-6) < 0.1e-6)
    }
}
