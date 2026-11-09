import ArgumentParser
import Foundation
import Testing
@testable import sal

private func channel(_ number: UInt32, initial: Int32 = 0, _ times: [Double], begin: Double = 0, end: Double = 10) throws -> IdentifiableChannel {
    IdentifiableChannel(
        summary: summarize(try parse(digitalFile(initial: initial, begin: begin, end: end, times: times)), channel: number),
        times: times, beginTime: begin, endTime: end)
}

@Suite("Timing statistics")
struct TimingStatisticsTests {
    @Test("Statistics are computed")
    func values() throws {
        let statistics = try #require(TimingStatistics([4, 1, 3, 2]))
        #expect(statistics.count == 4)
        #expect(statistics.minSeconds == 1)
        #expect(statistics.maxSeconds == 4)
        #expect(statistics.meanSeconds == 2.5)
        #expect(statistics.medianSeconds == 2)
        #expect(abs(statistics.stddevSeconds - 1.25.squareRoot()) < 1e-12)
    }

    @Test("No values means no statistics")
    func empty() {
        #expect(TimingStatistics([]) == nil)
    }

    @Test("Edges are selected by kind")
    func selection() throws {
        let line = try channel(1, initial: 0, [1, 2, 3, 4])
        #expect(selectedEdges(of: line, .rising) == [1, 3])
        #expect(selectedEdges(of: line, .falling) == [2, 4])
        #expect(selectedEdges(of: line, .either) == [1, 2, 3, 4])
        let high = try channel(1, initial: 1, [1, 2])
        #expect(selectedEdges(of: high, .rising) == [2])
    }
}

@Suite("Latency")
struct LatencyTests {
    @Test("Each start pairs with the first end after it")
    func pairs() throws {
        let result = measureLatency(from: [1, 5], to: [1.5, 2, 5.25])
        #expect(result.fromEdges == 2)
        #expect(result.unmatched == 0)
        #expect(result.latency?.count == 2)
        #expect(result.latency?.minSeconds == 0.25)
        #expect(result.latency?.maxSeconds == 0.5)
    }

    @Test("An end at the same instant as the start does not count")
    func simultaneous() {
        #expect(measureLatency(from: [1], to: [1, 2]).latency?.minSeconds == 1)
    }

    @Test("An end after the next start belongs to that start")
    func afterNextStart() {
        let result = measureLatency(from: [1, 2], to: [2.5])
        #expect(result.unmatched == 1)
        #expect(result.latency?.count == 1)
        #expect(result.latency?.minSeconds == 0.5)
    }

    @Test("An end exactly at the next start belongs to neither")
    func atNextStart() {
        let result = measureLatency(from: [1, 2], to: [2])
        #expect(result.unmatched == 2)
        #expect(result.latency == nil)
    }

    @Test("A start with no end after it is unmatched")
    func noEnd() {
        let result = measureLatency(from: [1, 2], to: [0.5])
        #expect(result.unmatched == 2)
        #expect(result.latency == nil)
    }

    @Test("Maximum excludes longer delays and keeps equal ones")
    func maximum() {
        #expect(measureLatency(from: [1], to: [3], maximum: 2).unmatched == 0)
        #expect(measureLatency(from: [1], to: [3.5], maximum: 2).unmatched == 1)
    }

    @Test("Nothing to measure is handled")
    func empty() {
        #expect(measureLatency(from: [], to: [1]) == LatencyResult(fromEdges: 0, unmatched: 0, latency: nil))
    }

    @Test("Latency matches a brute force calculation")
    func oracle() {
        var generator = SplitMix64(state: 0x1A7)
        func sortedTimes() -> [Double] {
            Array(Set((0..<Int.random(in: 0...40, using: &generator)).map { _ in Double(Int.random(in: 0...60, using: &generator)) })).sorted()
        }
        for _ in 0..<3_000 {
            let from = sortedTimes()
            let to = sortedTimes()
            var expected: [Double] = []
            for (index, start) in from.enumerated() {
                let limit = index + 1 < from.count ? from[index + 1] : .infinity
                if let end = to.filter({ $0 > start }).min(), end < limit { expected.append(end - start) }
            }
            let result = measureLatency(from: from, to: to)
            #expect(result.latency == TimingStatistics(expected), "\(from) \(to)")
            #expect(result.unmatched == from.count - expected.count)
        }
    }
}

@Suite("Setup and hold")
struct SetupHoldTests {
    private func timing(clock: [Double], data: [Double], setup: Double? = nil, hold: Double? = nil) -> DataTiming {
        measureSetupHold(clock: clock, data: [(1, data)], minimumSetup: setup, minimumHold: hold).data[0]
    }

    @Test("Setup and hold are measured either side of the clock")
    func basic() {
        let result = timing(clock: [10, 20, 30], data: [9, 22, 28])
        #expect(result.setup?.minSeconds == 1)
        #expect(result.setup?.maxSeconds == 2)
        #expect(result.hold?.minSeconds == 2)
    }

    @Test("The window is the median clock spacing, and is reported")
    func window() {
        #expect(measureSetupHold(clock: [10, 20, 30, 100], data: []).windowSeconds == 10)
        #expect(measureSetupHold(clock: [10], data: []).windowSeconds == nil)
    }

    @Test("Changes further than one clock period away do not count")
    func distant() {
        let result = timing(clock: [10, 20, 30], data: [-5])
        #expect(result.setup == nil)
        #expect(result.hold == nil)
    }

    @Test("A change exactly one period away still counts")
    func windowBoundary() {
        let result = timing(clock: [10, 20], data: [0])
        #expect(result.setup?.count == 1)
        #expect(result.setup?.maxSeconds == 10)
    }

    @Test("A change at the clock edge is zero hold, not setup")
    func simultaneous() {
        let result = timing(clock: [10, 20], data: [10])
        #expect(result.hold?.minSeconds == 0)
        #expect(result.setup?.minSeconds == 10)
    }

    @Test("With one clock edge there is no window to limit by")
    func oneEdge() {
        let result = timing(clock: [10], data: [1, 50])
        #expect(result.setup?.minSeconds == 9)
        #expect(result.hold?.minSeconds == 40)
    }

    @Test("Violations count times under the limit, and equal times pass")
    func violations() {
        let result = timing(clock: [10, 20, 30], data: [9, 18, 31], setup: 2, hold: 1)
        #expect(result.setupViolations == 1)
        #expect(result.holdViolations == 0)
        #expect(timing(clock: [10, 20, 30], data: [9, 18, 30.5], setup: 2, hold: 1).holdViolations == 1)
    }

    @Test("Without limits nothing is a violation")
    func noLimits() {
        let result = timing(clock: [10, 20], data: [9.999])
        #expect(result.setupViolations == 0)
        #expect(result.holdViolations == 0)
    }

    @Test("Each data channel is reported separately")
    func several() {
        let result = measureSetupHold(clock: [10, 20], data: [(4, [9]), (5, [8])])
        #expect(result.data.map(\.channel) == [4, 5])
        #expect(result.data.map(\.setup?.minSeconds) == [1, 2])
    }

    @Test("Setup and hold match a brute force calculation")
    func oracle() {
        var generator = SplitMix64(state: 0x5E7)
        func sortedTimes(_ maximum: Int) -> [Double] {
            Array(Set((0..<Int.random(in: 0...maximum, using: &generator)).map { _ in Double(Int.random(in: 0...100, using: &generator)) })).sorted()
        }
        for _ in 0..<3_000 {
            let clock = sortedTimes(20)
            let data = sortedTimes(40)
            let spacing = zip(clock, clock.dropFirst()).map { $1 - $0 }.sorted()
            let window = spacing.isEmpty ? Double.infinity : spacing[(spacing.count - 1) / 2]
            let setups = clock.compactMap { edge in data.filter { $0 < edge }.max().map { edge - $0 } }.filter { $0 <= window }
            let holds = clock.compactMap { edge in data.filter { $0 >= edge }.min().map { $0 - edge } }.filter { $0 <= window }
            let result = measureSetupHold(clock: clock, data: [(0, data)]).data[0]
            #expect(result.setup == TimingStatistics(setups), "\(clock) \(data)")
            #expect(result.hold == TimingStatistics(holds), "\(clock) \(data)")
        }
    }
}

@Suite("Bus activity")
struct ActivityTests {
    @Test("Edges close together form one burst")
    func bursts() throws {
        let result = measureActivity(try channel(2, [1, 1.1, 1.2, 5, 5.1], begin: 0, end: 10), gap: 0.5)
        #expect(result.channel == 2)
        #expect(result.edges == 5)
        #expect(result.bursts == 2)
        #expect(abs(result.busyPercent - 3) < 1e-9)
        #expect(abs(try #require(result.meanBurstSeconds) - 0.15) < 1e-9)
        #expect(abs(result.longestIdleSeconds - 4.9) < 1e-9)
    }

    @Test("Idle includes the time before the first edge and after the last")
    func edgesOfCapture() throws {
        #expect(try measureActivity(channel(1, [8], begin: 0, end: 10), gap: 1).longestIdleSeconds == 8)
        #expect(try measureActivity(channel(1, [2], begin: 0, end: 10), gap: 1).longestIdleSeconds == 8)
    }

    @Test("A gap exactly the limit does not split a burst")
    func gapBoundary() throws {
        #expect(try measureActivity(channel(1, [1, 2], begin: 0, end: 3), gap: 1).bursts == 1)
        #expect(try measureActivity(channel(1, [1, 2.5], begin: 0, end: 3), gap: 1).bursts == 2)
    }

    @Test("An idle channel is reported as idle for the whole capture")
    func idle() throws {
        let result = measureActivity(try channel(1, [], begin: 2, end: 10), gap: 1)
        #expect(result == ChannelActivity(channel: 1, edges: 0, bursts: 0, busyPercent: 0, meanBurstSeconds: nil, longestIdleSeconds: 8))
    }

    @Test("A zero-length capture does not divide by zero")
    func zeroSpan() throws {
        let result = measureActivity(try channel(1, [1], begin: 1, end: 1), gap: 1)
        #expect(result.busyPercent == 0)
    }
}

@Suite("Analyze arguments")
struct AnalyzeArgumentTests {
    private func parse(_ arguments: [String]) throws -> any ParsableCommand {
        try Sal.parseAsRoot(["analyze"] + arguments)
    }

    @Test("Edges parse every kind", arguments: EdgeKind.allCases)
    func edges(kind: EdgeKind) {
        #expect(EdgeSelector(argument: "3:\(kind.rawValue)") == EdgeSelector(channel: 3, kind: kind))
    }

    @Test("Bad edges are refused", arguments: ["1", "x:rising", "1:high", "1:rising:2", ":rising"])
    func badEdges(text: String) {
        #expect(EdgeSelector(argument: text) == nil)
    }

    @Test("Valid command lines are accepted", arguments: [
        ["latency", "--from", "1:rising", "--to", "2:falling"],
        ["latency", "--from", "1:rising", "--to", "1:falling", "--max", "5ms"],
        ["latency", "--from", "15:either", "--to", "14:either"],
        ["setup-hold", "--clock", "3:rising", "--data", "4", "--data", "5", "--min-setup", "20ns", "--min-hold", "5ns"],
        ["activity"], ["activity", "--channels", "0-3", "--gap", "200us"],
    ])
    func accepted(arguments: [String]) {
        #expect(throws: Never.self) { try parse(arguments) }
    }

    @Test("Invalid command lines are refused", arguments: [
        ["latency", "--from", "1:rising"],
        ["latency", "--to", "1:rising"],
        ["latency", "--from", "1:rising", "--to", "1:rising"],
        ["latency", "--from", "16:rising", "--to", "1:rising"],
        ["latency", "--from", "1:rising", "--to", "16:rising"],
        ["latency", "--from", "1:rising", "--to", "2:rising", "--max", "0"],
        ["setup-hold", "--data", "4"],
        ["setup-hold", "--clock", "3:rising"],
        ["setup-hold", "--clock", "3:either", "--data", "4"],
        ["setup-hold", "--clock", "16:rising", "--data", "4"],
        ["setup-hold", "--clock", "3:rising", "--data", "16"],
        ["setup-hold", "--clock", "3:rising", "--data", "3"],
        ["setup-hold", "--clock", "3:rising", "--data", "4", "--data", "4"],
        ["activity", "--gap", "0"],
    ])
    func refused(arguments: [String]) {
        #expect(throws: (any Error).self) { try parse(arguments) }
    }

    @Test("Statistics print, and absence is stated")
    func printing() throws {
        #expect(describe(nil as TimingStatistics?) == "no measurements")
        #expect(describe(TimingStatistics([1e-6, 3e-6])) == "min 1.000 us, max 3.000 us, mean 2.000 us, stddev 1.000 us, 2 samples")
    }

    @Test("MCP analysis arguments become the matching command", arguments: [
        ("latency", ["from": JSONValue.string("1:rising"), "to": .string("2:rising")], ["analyze", "latency", "--from=1:rising", "--to=2:rising"]),
        ("setup_hold", ["clock": .string("3:rising"), "data": .array([.int(4)])], ["analyze", "setup-hold", "--clock=3:rising", "--data=4"]),
        ("activity", ["gap": .string("1ms")], ["analyze", "activity", "--gap=1ms"]),
    ])
    func toolLine(kind: String, fields: [String: JSONValue], expected: [String]) throws {
        let analysis = JSONValue.object(fields.merging(["kind": .string(kind)]) { first, _ in first })
        #expect(try analyzeCommandLine(.object(["analysis": analysis])) == expected)
    }

    @Test("MCP capture options follow the analysis")
    func toolCapture() throws {
        let analysis = JSONValue.object(["kind": .string("activity")])
        #expect(try analyzeCommandLine(.object(["analysis": analysis, "duration": .double(0.5)])) == ["analyze", "activity", "--duration=0.5"])
    }

    @Test("Bad MCP analysis is refused", arguments: [
        (JSONValue.object([:]), "needs analysis"),
        (.object(["analysis": .object(["kind": .string("fft")])]), "Unknown analysis"),
        (.object(["analysis": .object(["kind": .string("activity"), "to": .string("x")])]), "Unknown argument: to"),
    ])
    func badTool(arguments: JSONValue, expected: String) async {
        await #expect(throws: (any Error).self) { try await SalTools().call(name: "analyze", arguments: arguments) }
        #expect(throws: (any Error).self) { try analyzeCommandLine(arguments) }
        _ = expected
    }

    @Test("Every analysis schema field is a real flag")
    func parity() throws {
        let schema = try #require(toolDefinitions.first { $0["name"]?.stringValue == "analyze" }?["inputSchema"])
        guard case .array(let kinds)? = schema["properties"]?["analysis"]?["oneOf"] else {
            Issue.record("analysis is not a oneOf")
            return
        }
        let commands: [(String, any ParsableCommand.Type)] = [
            ("latency", LatencyCommand.self), ("setup_hold", SetupHoldCommand.self), ("activity", ActivityCommand.self),
        ]
        #expect(kinds.count == commands.count)
        for (index, (kind, command)) in commands.enumerated() {
            #expect(kinds[index]["properties"]?["kind"]?["const"] == .string(kind))
            guard case .object(let properties)? = kinds[index]["properties"] else { continue }
            let help = Sal.helpMessage(for: command, columns: 400)
            for key in properties.keys where key != "kind" {
                #expect(help.contains("--" + key.replacingOccurrences(of: "_", with: "-")), "\(kind) \(key)")
            }
        }
    }
}
