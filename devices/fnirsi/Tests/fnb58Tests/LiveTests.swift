import Foundation
import Testing
@testable import fnb58

/// Against the FNB58 on USB. `make verify` runs these; they are skipped otherwise.
/// Serialized: the meter has one stream, and two clients at once can wedge it.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FNB58_LIVE"] == "1"))
struct LiveTests {
    private func session() -> MeterSession {
        MeterSession(directory: temporaryDirectory())
    }

    /// Repeated open, start and close is what wedged the meter before init was paced
    /// and closing drained.
    @Test func statusRepeatedly() async throws {
        for round in 0..<5 {
            let status = await session().status()
            #expect(status.error == nil, "round \(round)")
            #expect(status.connected)
            let reading = try #require(status.reading)
            #expect(reading.voltageV > 3 && reading.voltageV < 25, "VBUS should be present")
            #expect(reading.temperatureC > 0 && reading.temperatureC < 80)
        }
    }

    @Test func captureIsWholeAndTimedBySample() async throws {
        let summary = try await session().capture(seconds: 3, label: "live")
        #expect(summary.ended == .completed)
        #expect(summary.stats?.samples == 300)
        #expect(summary.warnings.isEmpty, "\(summary.warnings)")
        let saved = try readCapture(URL(fileURLWithPath: summary.csv))
        #expect(saved.times.count == 300)
        #expect(saved.times.last == 2.99)
    }

    /// Back to back, as an agent calling tools does.
    @Test func capturesBackToBack() async throws {
        let meter = session()
        for _ in 0..<3 {
            let summary = try await meter.capture(seconds: 1, label: nil)
            #expect(summary.ended == .completed && summary.stats?.samples == 100)
            #expect(summary.warnings.isEmpty, "\(summary.warnings)")
        }
        _ = try await meter.startCapture(label: nil)
        try await Task.sleep(for: .seconds(1))
        let mark = try await meter.mark("live mark")
        try await Task.sleep(for: .seconds(1))
        let summary = try await meter.stopCapture()
        #expect(summary.ended == .stopped)
        #expect(mark.t > 0.5 && mark.t < 1.5)
        #expect((summary.stats?.samples ?? 0) >= 150)
    }

    @Test func rawDumpShowsTheReplyAndData() async throws {
        let dump = try await session().rawDump(seconds: 1, limit: 5)
        #expect(dump.types["03"] == 1)
        #expect((dump.types["04"] ?? 0) >= 20 && (dump.types["04"] ?? 0) <= 30)
        #expect(dump.signByteValues == [1])
        #expect(dump.reports.first.map { $0.type } == "03")
    }

    @Test func deviceIdentifiesItself() async throws {
        let status = await session().status()
        #expect(status.device?.model == 58)
        #expect(status.meters.map(\.serial).contains("0B45760B74F1"))
    }
}
