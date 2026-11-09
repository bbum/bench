import ArgumentParser
import Foundation

struct AnalyzeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Measure timing across channels.",
        subcommands: [LatencyCommand.self, SetupHoldCommand.self, ActivityCommand.self]
    )
}

private func printResult(_ value: some Encodable, json: Bool, text: () -> [String]) throws {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    } else {
        text().forEach { print($0) }
    }
}

func describe(_ statistics: TimingStatistics?) -> String {
    guard let statistics else { return "no measurements" }
    return "min \(formatSeconds(statistics.minSeconds)), max \(formatSeconds(statistics.maxSeconds)), "
        + "mean \(formatSeconds(statistics.meanSeconds)), stddev \(formatSeconds(statistics.stddevSeconds)), "
        + "\(statistics.count) samples"
}

struct LatencyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "latency", abstract: "Measure the delay from an edge to the next edge on a channel.")

    @OptionGroup var capture: CaptureOptions

    @Option(help: "Starting edge: CH:rising, CH:falling or CH:either.")
    var from: EdgeSelector

    @Option(help: "Ending edge, after the start and before the next one.")
    var to: EdgeSelector

    @Option(help: "Ignore delays longer than this, such as 5ms.")
    var max: Seconds?

    @Flag(help: "Print JSON instead of text.")
    var json = false

    func validate() throws {
        try validateEdges([from, to])
        guard from != to else { throw ValidationError("--from and --to must differ.") }
    }

    func execute(handlingSignals: Bool) async throws -> LatencyResult {
        let (from, to, maximum) = (from, to, max?.value)
        return try await analyzedCapture(capture, channels: Array(Set([from.channel, to.channel])).sorted(), handlingSignals: handlingSignals) { channels in
            measureLatency(
                from: selectedEdges(of: channels.first { $0.channel == from.channel }!, from.kind),
                to: selectedEdges(of: channels.first { $0.channel == to.channel }!, to.kind),
                maximum: maximum)
        }
    }

    func run() async throws {
        let result = try await execute(handlingSignals: true)
        try printResult(result, json: json) {
            ["\(result.fromEdges) edges, \(result.unmatched) unmatched", describe(result.latency)]
        }
    }
}

struct SetupHoldCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup-hold", abstract: "Measure data setup and hold times around a clock edge.")

    @OptionGroup var capture: CaptureOptions

    @Option(help: "The sampling edge: CH:rising or CH:falling.")
    var clock: EdgeSelector

    @Option(help: "Data channel. Repeatable.")
    var data: [UInt32]

    @Option(help: "Count setup times shorter than this as violations, such as 20ns.")
    var minSetup: Seconds?

    @Option(help: "Count hold times shorter than this as violations.")
    var minHold: Seconds?

    @Flag(help: "Print JSON instead of text.")
    var json = false

    func validate() throws {
        guard clock.kind != .either else { throw ValidationError("--clock must be rising or falling.") }
        try validateChannels([clock.channel] + data)
    }

    func execute(handlingSignals: Bool) async throws -> SetupHoldResult {
        let (clock, data, minimumSetup, minimumHold) = (clock, data, minSetup?.value, minHold?.value)
        return try await analyzedCapture(capture, channels: ([clock.channel] + data).sorted(), handlingSignals: handlingSignals) { channels in
            measureSetupHold(
                clock: selectedEdges(of: channels.first { $0.channel == clock.channel }!, clock.kind),
                data: data.map { number in (number, channels.first { $0.channel == number }!.times) },
                minimumSetup: minimumSetup, minimumHold: minimumHold)
        }
    }

    func run() async throws {
        let result = try await execute(handlingSignals: true)
        try printResult(result, json: json) {
            ["\(result.clockEdges) clock edges"]
                + result.data.flatMap { line -> [String] in
                    var lines = ["CH\(line.channel) setup: \(describe(line.setup))", "CH\(line.channel) hold: \(describe(line.hold))"]
                    if line.setupViolations + line.holdViolations > 0 {
                        lines.append("CH\(line.channel) violations: setup \(line.setupViolations), hold \(line.holdViolations)")
                    }
                    return lines
                }
        }
    }
}

struct ActivityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activity", abstract: "Show when each channel is busy: bursts, duty and idle time.")

    @OptionGroup var capture: CaptureOptions

    @Option(help: "Digital channels, such as 0-7. Defaults to 0-7, or all with --load.")
    var channels: String?

    @Option(help: "Edges further apart than this start a new burst.")
    var gap = Seconds(1e-3)

    @Flag(help: "Print JSON instead of text.")
    var json = false

    func execute(handlingSignals: Bool) async throws -> [ChannelActivity] {
        let digital = try resolvedChannels(channels, loading: capture.load != nil)
        let gap = gap.value
        return try await analyzedCapture(capture, channels: digital, handlingSignals: handlingSignals) { channels in
            channels.map { measureActivity($0, gap: gap) }
        }
    }

    func run() async throws {
        let result = try await execute(handlingSignals: true)
        try printResult(result, json: json) {
            result.map {
                guard let burst = $0.meanBurstSeconds else { return "CH\($0.channel)  idle" }
                return String(format: "CH%d  %.2f%% busy, %d bursts of %@ on average, longest idle %@",
                    $0.channel, $0.busyPercent, $0.bursts, formatSeconds(burst), formatSeconds($0.longestIdleSeconds))
            }
        }
    }
}

private func validateEdges(_ edges: [EdgeSelector]) throws {
    guard edges.allSatisfy({ $0.channel <= maximumChannel }) else {
        throw ValidationError("Channels must be at most \(maximumChannel).")
    }
}

/// Captures or loads the channels, then runs a pure measurement over their edges.
private func analyzedCapture<Result: Sendable>(
    _ capture: CaptureOptions,
    channels: [UInt32],
    handlingSignals: Bool,
    measure: @escaping @Sendable ([IdentifiableChannel]) -> Result
) async throws -> Result {
    let endpoint = capture.logic2.endpoint
    return try await capture.perform(channels: channels, handlingSignals: handlingSignals) { request in
        measure(try await runEdgeCapture(request, endpoint: endpoint))
    }
}
