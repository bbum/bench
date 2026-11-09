import Foundation
import Testing
@testable import sal

@Suite("Channel summaries")
struct ChannelSummaryTests {
    @Test("A recorded testgen capture matches the known answers")
    func recordedCapture() throws {
        let capture = try summarizeCapture(directory: fixtureDirectory, channels: Array(0...7))
        try Testgen.verify(capture)
        #expect(capture.channels.map(\.edges) == [1069, 48, 2256, 2304, 576, 48, 624, 2208])
        #expect(capture.channels[1...7].allSatisfy { $0.bursts == 24 })
        #expect(capture.channels[0].bursts == 1)
        #expect(capture.channels[3].periodic == nil)
    }

    @Test("A missing channel file throws")
    func missingChannel() {
        #expect(throws: (any Error).self) {
            try summarizeCapture(directory: fixtureDirectory, channels: [8])
        }
    }

    @Test("No channels gives an empty summary")
    func noChannels() throws {
        let capture = try summarizeCapture(directory: fixtureDirectory, channels: [])
        #expect(capture == CaptureSummary(durationSeconds: 0, channels: []))
    }

    // MARK: Few edges

    @Test("No edges", arguments: [Int32(0), 1])
    func noEdges(initial: Int32) throws {
        let result = try summary(initial: initial, times: [])
        #expect(result.initialLevel == Int(initial))
        #expect(result.edges == 0)
        #expect(result.risingEdges == 0)
        #expect(result.bursts == 0)
        #expect(result.minHighSeconds == nil)
        #expect(result.minLowSeconds == nil)
        #expect(result.periodic == nil)
    }

    @Test("One rising edge")
    func oneRising() throws {
        let result = try summary(initial: 0, times: [1])
        #expect(result.edges == 1)
        #expect(result.risingEdges == 1)
        #expect(result.bursts == 1)
        #expect(result.minHighSeconds == nil)
    }

    @Test("One falling edge")
    func oneFalling() throws {
        let result = try summary(initial: 1, times: [1])
        #expect(result.risingEdges == 0)
        #expect(result.bursts == 1)
    }

    @Test("Pulse widths use the level between the edges")
    func pulseWidths() throws {
        let low = try summary(initial: 1, times: [1, 3])
        #expect(low.minLowSeconds == 2)
        #expect(low.minHighSeconds == nil)
        let high = try summary(initial: 0, times: [1, 3])
        #expect(high.minHighSeconds == 2)
        #expect(high.minLowSeconds == nil)
    }

    // MARK: Periodic detection boundaries

    @Test("Needs at least three periods")
    func periodCountBoundary() throws {
        #expect(try summary(times: squareWave(periods: 3, high: 1, low: 3)).periodic == nil)
        #expect(try summary(times: squareWave(periods: 4, high: 1, low: 3)).periodic != nil)
    }

    @Test("Frequency, duty and period statistics")
    func periodicValues() throws {
        let periodic = try #require(summary(times: squareWave(periods: 5, high: 0.25, low: 0.75)).periodic)
        #expect(periodic.frequencyHz == 1)
        #expect(periodic.dutyPercent == 25)
        #expect(periodic.periodMinSeconds == 1)
        #expect(periodic.periodMaxSeconds == 1)
        #expect(periodic.periodJitterSeconds == 0)
    }

    /// Rising edges with spacings 100, 100, 100 and one final spacing under test.
    private func wave(lastPeriod: Double) -> [Double] {
        var rising = [100.0, 200, 300, 400]
        rising.append(400 + lastPeriod)
        return rising.flatMap { [$0, $0 + 1] }
    }

    @Test("A period exactly 5% from the median is still periodic")
    func toleranceInclusive() throws {
        #expect(try summary(times: wave(lastPeriod: 105)).periodic != nil)
        #expect(try summary(times: wave(lastPeriod: 95)).periodic != nil)
    }

    @Test("A period past 5% from the median is not periodic")
    func toleranceExclusive() throws {
        #expect(try summary(times: wave(lastPeriod: 105.5)).periodic == nil)
        #expect(try summary(times: wave(lastPeriod: 94.5)).periodic == nil)
    }

    @Test("Period spread is reported exactly")
    func periodSpread() throws {
        // Periods of 100, 102, 98 and 100: mean 100, variance 2.
        let times = [100.0, 200, 302, 400, 500].flatMap { [$0, $0 + 1] }
        let periodic = try #require(summary(times: times).periodic)
        #expect(periodic.periodMinSeconds == 98)
        #expect(periodic.periodMaxSeconds == 102)
        #expect(periodic.periodJitterSeconds == 2.0.squareRoot())
    }

    @Test("Capture duration is the longest channel, in any order", arguments: [[UInt32(0), 1], [1, 0]])
    func longestDuration(channels: [UInt32]) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sal-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try digitalFile(end: 5).write(to: directory.appendingPathComponent("digital_0.bin"))
        try digitalFile(end: 2).write(to: directory.appendingPathComponent("digital_1.bin"))
        #expect(try summarizeCapture(directory: directory, channels: channels).durationSeconds == 5)
    }

    // MARK: Regression: frequency overflowed to infinity, which JSON cannot encode

    @Test("Subnormal periods are not reported as periodic")
    func subnormalPeriods() throws {
        let step = Double.leastNonzeroMagnitude
        let times = (0..<10).map { Double($0) * step }
        let result = try summary(times: times)
        #expect(result.periodic == nil)
        _ = try JSONEncoder().encode(result)
    }

    // MARK: Burst boundaries

    /// Unit-spaced edges split by one gap under test.
    private func bursts(gap: Double) -> [Double] {
        let first = (0..<10).map { Double($0) }
        let second = first.map { $0 + 9 + gap }
        return first + second
    }

    @Test("A gap of exactly 20 times the spacing does not split a burst")
    func burstThresholdExclusive() throws {
        #expect(try summary(times: bursts(gap: 20)).bursts == 1)
    }

    @Test("A gap just over 20 times the spacing splits a burst")
    func burstThresholdSplits() throws {
        #expect(try summary(times: bursts(gap: 20.5)).bursts == 2)
    }

    @Test("A bimodal signal uses the shorter spacing")
    func bimodalSpacing() throws {
        // Alternating 1 and 1000: each long gap separates a burst of two edges.
        let times = (0..<8).flatMap { n -> [Double] in
            let start = Double(n) * 1001
            return [start, start + 1]
        }
        #expect(try summary(times: times).bursts == 8)
    }
}

@Suite("Output formatting")
struct FormattingTests {
    private func app() -> Saleae_Automation_AppInfo {
        var app = Saleae_Automation_AppInfo()
        app.applicationVersion = "2.4.48"
        app.apiVersion.major = 1
        app.apiVersion.minor = 2
        app.apiVersion.patch = 3
        return app
    }

    @Test("Status reports when nothing is connected")
    func statusNoDevices() {
        #expect(statusLines(app: app(), devices: []) == ["Logic 2.4.48, API 1.2.3", "No devices connected"])
    }

    @Test("Status lists every device")
    func statusDevices() {
        var first = Saleae_Automation_Device()
        first.deviceID = "A"
        first.deviceType = .logicPro8
        var second = Saleae_Automation_Device()
        second.deviceID = "B"
        second.deviceType = .logic8
        #expect(
            statusLines(app: app(), devices: [first, second])
                == ["Logic 2.4.48, API 1.2.3", "logicPro8 A", "logic8 B"])
    }

    @Test(
        "Seconds pick a readable unit",
        arguments: [
            (2.0, "2.000 s"), (1.0, "1.000 s"), (0.5, "500.000 ms"), (1e-3, "1.000 ms"),
            (2e-5, "20.000 us"), (2e-7, "200 ns"),
        ])
    func seconds(value: Double, expected: String) {
        #expect(formatSeconds(value) == expected)
    }

    @Test("Idle channels name their level")
    func idle() throws {
        #expect(describe(try summary(initial: 0, times: [])) == "CH0  idle low")
        #expect(describe(try summary(initial: 1, times: [])) == "CH0  idle high")
    }

    @Test("Periodic channels report frequency and duty")
    func periodic() throws {
        let text = describe(try summary(times: squareWave(periods: 5, high: 0.25, low: 0.75)))
        #expect(text == "CH0  1.00 Hz, 25.00% duty, jitter 0 ns, 10 edges")
    }

    @Test("Other channels report bursts and pulse widths")
    func bursty() throws {
        #expect(describe(try summary(times: [1, 2, 4])) == "CH0  3 edges in 1 bursts, min high 1.000 s, min low 2.000 s")
    }

    @Test("Missing pulse widths are marked")
    func missingWidths() throws {
        #expect(describe(try summary(times: [1])) == "CH0  1 edges in 1 bursts, min high n/a, min low n/a")
    }
}
