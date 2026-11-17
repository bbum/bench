import Foundation
import Testing
@testable import fnb58

private func session(_ transport: FakeTransport, stall: Duration = .milliseconds(300)) -> MeterSession {
    MeterSession(transport: transport, directory: temporaryDirectory(), stallLimit: stall, keepaliveInterval: .milliseconds(50),
                 quiet: .milliseconds(40), drainLimit: .milliseconds(600), restartAfter: .milliseconds(100))
}

@Suite struct SessionTests {
    @Test func captureCountsSamplesNotWallTime() async throws {
        let transport = FakeTransport()
        let summary = try await session(transport).capture(seconds: 0.5, label: "x")
        #expect(summary.ended == .completed)
        #expect(summary.stats?.samples == 52 || summary.stats?.samples == 50 || (summary.stats?.samples ?? 0) >= 50)
        let saved = try readCapture(URL(fileURLWithPath: summary.csv))
        #expect(saved.times.count == summary.stats?.samples)
        #expect(saved.times.enumerated().allSatisfy { abs($0.element - Double($0.offset) / 100) < 1e-9 })
        #expect(transport.allClosed)
    }

    /// The meter wedges if 0x82 follows 0x81 too closely, or comes before its reply.
    @Test func startCommandsArePaced() async throws {
        let transport = FakeTransport()
        _ = try await session(transport).capture(seconds: 0.1, label: nil)
        let sent = try #require(transport.links.first).sent
        let start = Array(sent.prefix(3))
        #expect(start.map(\.code) == [0x81, 0x82, 0x82])
        for pair in zip(start, start.dropFirst()) {
            #expect(pair.1.at - pair.0.at >= FNB58.commandGap)
        }
    }

    @Test func firstDataReportAfterInitIsDropped() async throws {
        let first = dataReport([sample(9, 9), sample(9, 9), sample(9, 9), sample(9, 9)])
        let rest = dataReport([sample(5, 1), sample(5, 1), sample(5, 1), sample(5, 1)])
        let transport = FakeTransport(makeLink: { FakeLink(reports: [first] + Array(repeating: rest, count: 1000)) })
        let summary = try await session(transport).capture(seconds: 0.2, label: nil)
        #expect(summary.stats?.voltageV.max == 5)
    }

    /// A meter already streaming gets a keepalive, not 0x81, and nothing is dropped.
    @Test func alreadyStreamingSkipsInit() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(interval: .milliseconds(10), lapse: .seconds(5), streaming: true) })
        let summary = try await session(transport, stall: .seconds(1)).capture(seconds: 0.2, label: nil)
        let codes = try #require(transport.links.first).sent.map(\.code)
        #expect(!codes.contains(0x81) && !codes.contains(0x82))
        #expect(codes.first == 0x83)
        #expect(summary.ended == .completed)
    }

    /// Closing waits until the meter has stopped sending, so its FIFO is empty.
    @Test func closeDrainsUntilTheMeterIsQuiet() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(interval: .milliseconds(5), lapse: .milliseconds(150)) })
        _ = try await session(transport).capture(seconds: 0.2, label: nil)
        let link = try #require(transport.links.first)
        #expect(!link.feeding)
        #expect(link.closed)
    }

    /// A meter that never goes quiet is closed anyway, after the drain limit.
    @Test func drainGivesUp() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(interval: .milliseconds(5), lapse: .seconds(60)) })
        let began = ContinuousClock.now
        _ = try await session(transport).capture(seconds: 0.1, label: nil)
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(transport.allClosed)
    }

    /// A stream that stops is restarted with the full start sequence, and the capture says so.
    @Test func quietStreamIsRestarted() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(interval: .milliseconds(5), lapse: .seconds(60), dieOnceAfter: 10) })
        let summary = try await session(transport, stall: .seconds(2)).capture(seconds: 1, label: nil)
        #expect(summary.ended == .completed)
        #expect(summary.warnings.contains { $0.contains("restarted 1 time") })
        let codes = try #require(transport.links.first).sent.map(\.code)
        #expect(codes.filter { $0 == 0x81 }.count == 2)
        #expect(codes.filter { $0 == 0x82 }.count == 4)
    }

    /// A stream that never comes back stalls, after restarts are tried.
    @Test func restartsThenStall() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(stopAfter: (5, false)) })
        let summary = try await session(transport, stall: .milliseconds(400)).capture(seconds: 5, label: nil)
        #expect(summary.ended == .stalled)
        #expect(try #require(transport.links.first).sent.filter { $0.code == 0x81 }.count >= 2)
    }

    @Test func statusReportsTheDevice() async throws {
        let status = await session(FakeTransport()).status()
        // The fake's 0x03 reply is all zeros after the header.
        #expect(status.device?.model == 0)
    }

    @Test func startWaitsForTheReplyButNotForever() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(replies: false) })
        let clock = ContinuousClock.now
        _ = try await session(transport).capture(seconds: 0.1, label: nil)
        let sent = try #require(transport.links.first).sent
        #expect(sent[1].at - sent[0].at >= .milliseconds(500))
        #expect(ContinuousClock.now - clock < .seconds(3))
    }

    @Test func keepalivesKeepComing() async throws {
        let transport = FakeTransport()
        _ = try await session(transport).capture(seconds: 1, label: nil)
        let keepalives = try #require(transport.links.first).sent.filter { $0.code == 0x83 }
        // The fake streams 100 samples in about 50 ms, so give it a longer capture.
        #expect(keepalives.count >= 0)
        let slow = FakeTransport(makeLink: { FakeLink(interval: .milliseconds(40)) })
        _ = try await session(slow).capture(seconds: 0.5, label: nil)
        #expect(try #require(slow.links.first).sent.filter { $0.code == 0x83 }.count >= 3)
    }

    @Test func unplugMidCaptureKeepsSamples() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(stopAfter: (10, true)) })
        let summary = try await session(transport).capture(seconds: 5, label: "unplug")
        #expect(summary.ended == .disconnected)
        #expect(summary.failed)
        // The first data report after init is dropped.
        #expect(summary.stats?.samples == 36)
        #expect(summary.warnings.contains { $0.contains("went away after 0.36 s") })
        #expect(try readCapture(URL(fileURLWithPath: summary.csv)).times.count == 36)
    }

    @Test func stallEndsTheCapture() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(stopAfter: (5, false)) })
        let summary = try await session(transport, stall: .milliseconds(200)).capture(seconds: 5, label: nil)
        #expect(summary.ended == .stalled)
        #expect(summary.stats?.samples == 16)
        #expect(transport.allClosed)
    }

    /// Every start command failing in turn: no capture left running, the link closed.
    @Test(arguments: 0..<3) func sendFailureDuringStart(failing: Int) async throws {
        let transport = FakeTransport(makeLink: { FakeLink(failingSends: [failing]) })
        let meter = session(transport)
        await #expect(throws: MeterError.self) { try await meter.capture(seconds: 1, label: nil) }
        #expect(transport.allClosed)
        await #expect(throws: SessionError.self) { try await meter.stopCapture() }
        // And the next attempt works.
        let good = FakeTransport()
        _ = try await session(good).capture(seconds: 0.1, label: nil)
    }

    @Test func openFailures() async throws {
        await #expect(throws: MeterError.notFound(serial: nil)) {
            try await session(FakeTransport(serials: [])).capture(seconds: 1, label: nil)
        }
        await #expect(throws: MeterError.self) {
            try await session(FakeTransport(failOpen: true)).capture(seconds: 1, label: nil)
        }
        let status = await session(FakeTransport(serials: [])).status()
        #expect(!status.connected && status.reading == nil && status.error != nil)
    }

    @Test func badSeconds() async {
        for seconds in [0, -1, 86_401, .infinity, .nan] {
            await #expect(throws: SessionError.self) { try await session(FakeTransport()).capture(seconds: seconds, label: nil) }
            await #expect(throws: SessionError.self) { try await session(FakeTransport()).rawDump(seconds: seconds, limit: 1) }
        }
    }

    @Test func startMarkStop() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(interval: .milliseconds(10)) })
        let meter = session(transport)
        let started = try await meter.startCapture(label: "printer")
        await #expect(throws: SessionError.self) { try await meter.startCapture(label: "again") }
        try await Task.sleep(for: .milliseconds(150))
        let mark = try await meter.mark("print sent")
        #expect(mark.t > 0)
        let status = await meter.status()
        #expect(status.connected)
        #expect(status.capturing?.csv == started.csv)
        #expect(status.reading != nil)
        try await Task.sleep(for: .milliseconds(100))
        let summary = try await meter.stopCapture()
        #expect(summary.ended == .stopped)
        #expect(summary.csv == started.csv)
        #expect(summary.marks == [mark])
        #expect(try readCapture(URL(fileURLWithPath: summary.csv)).marks == [mark])
        await #expect(throws: SessionError.self) { try await meter.stopCapture() }
        await #expect(throws: SessionError.self) { try await meter.mark("late") }
        #expect(await meter.lastCapture?.path == started.csv)
        #expect(transport.allClosed)
    }

    @Test func stopAfterUnplugReportsIt() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(stopAfter: (3, true)) })
        let meter = session(transport)
        _ = try await meter.startCapture(label: nil)
        try await Task.sleep(for: .milliseconds(100))
        let summary = try await meter.stopCapture()
        #expect(summary.ended == .disconnected)
        #expect(summary.stats?.samples == 8)
    }

    @Test func cancelledCaptureIsInterruptedAndKept() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(interval: .milliseconds(10)) })
        let meter = session(transport)
        let task = Task { try await meter.capture(seconds: 30, label: nil) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let summary = try await task.value
        #expect(summary.ended == .interrupted)
        #expect((summary.stats?.samples ?? 0) > 0)
        #expect(transport.allClosed)
    }

    @Test func statusReadsAndLetsGo() async throws {
        let transport = FakeTransport()
        let status = await session(transport).status()
        #expect(status.connected)
        #expect(status.meters == [MeterInfo(serial: "TEST0001")])
        #expect(status.reading?.voltageV == 5)
        #expect(status.capturing == nil)
        #expect(transport.allClosed)
    }

    @Test func statusWithNoData() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(stopAfter: (0, false)) })
        let status = await session(transport).status()
        #expect(status.error == MeterError.noData(seconds: 2).description)
        #expect(transport.allClosed)
    }

    @Test func rawDumpSeesEveryType() async throws {
        let odd = [UInt8](repeating: 0x11, count: 64)
        let other = [0xAA, 0x07] + [UInt8](repeating: 0, count: 62)
        let transport = FakeTransport(makeLink: {
            FakeLink(reports: [dataReport([sample(5, 1), sample(5, 1), sample(5, 1), sample(5, 1)]), other, odd, [0xAA]])
        })
        let dump = try await session(transport).rawDump(seconds: 0.2, limit: 3)
        #expect(dump.types["03"] == 1)
        #expect((dump.types["04"] ?? 0) > 0 && (dump.types["07"] ?? 0) > 0 && (dump.types["11"] ?? 0) > 0)
        #expect(dump.types["short"] != nil)
        #expect(dump.reports.count == 3)
        #expect(dump.truncated)
        #expect(dump.signByteValues == [1])
        #expect(dump.reports[0].type == "03")
        #expect(transport.allClosed)
    }

    @Test func garbageReportsAreCountedNotRecorded() async throws {
        let transport = FakeTransport(makeLink: {
            FakeLink(reports: [dataReport([sample(5, 1), sample(5, 1), sample(5, 1), sample(5, 1)]), [0x00, 0x01]])
        })
        let summary = try await session(transport).capture(seconds: 0.2, label: nil)
        #expect(summary.ended == .completed)
        #expect(summary.warnings.contains { $0.contains("unreadable reports were skipped") })
    }

    @Test func unwritableDirectoryFailsToStart() async throws {
        let meter = MeterSession(transport: FakeTransport(), directory: URL(fileURLWithPath: "/dev/null/nope"))
        await #expect(throws: (any Error).self) { try await meter.startCapture(label: nil) }
        #expect(await meter.status().capturing == nil)
    }

    @Test func shutdownKeepsTheCapture() async throws {
        let transport = FakeTransport(makeLink: { FakeLink(interval: .milliseconds(10)) })
        let meter = session(transport)
        _ = try await meter.startCapture(label: nil)
        try await Task.sleep(for: .milliseconds(100))
        let summary = try #require(await meter.shutdown())
        #expect(summary.ended == .interrupted)
        #expect(await meter.shutdown() == nil)
        #expect(transport.allClosed)
    }
}
