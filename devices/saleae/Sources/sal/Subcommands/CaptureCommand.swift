import ArgumentParser
import Foundation

struct CaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Run a timed digital capture and summarize each channel."
    )

    @OptionGroup var capture: CaptureOptions

    @Option(help: "Digital channels, such as 0-7 or 0,2,4, or none with --analog. Defaults to 0-7, or all with --load.")
    var channels: String?

    @OptionGroup var analogOptions: AnalogOptions

    @Option(help: "Also write Logic 2's raw sample CSV files to this existing directory.")
    var exportCsv: String?

    @Flag(help: "Use ISO 8601 timestamps in --export-csv.")
    var iso8601 = false

    @Flag(help: "Print JSON instead of a table.")
    var json = false

    func validate() throws {
        guard channels != "none" || analogOptions.analog != nil else {
            throw ValidationError("--channels none needs --analog.")
        }
        guard !iso8601 || exportCsv != nil else { throw ValidationError("--iso8601 needs --export-csv.") }
    }

    var analogCapture: AnalogCapture? {
        get throws { try analogOptions.analogCapture }
    }

    func run() async throws {
        let summary = try await execute(handlingSignals: true)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(summary), as: UTF8.self))
        } else {
            print("\(formatSeconds(summary.durationSeconds)) captured")
            summary.channels.forEach { print(describe($0)) }
            summary.analog.forEach { print(describe($0)) }
        }
    }

    func execute(handlingSignals: Bool) async throws -> CaptureSummary {
        let endpoint = capture.logic2.endpoint
        let digital = try resolvedChannels(channels, loading: capture.load != nil)
        let rawCSV = exportCsv.map { RawCSVExport(directory: absolutePath($0), iso8601: iso8601) }
        return try await capture.perform(channels: digital, analog: try analogCapture, handlingSignals: handlingSignals) { request in
            var request = request
            request.rawCSV = rawCSV
            return try await runDigitalCapture(request, endpoint: endpoint)
        }
    }
}

/// The shell convention for a process ended by SIGINT.
let interruptedExitCode: Int32 = 130

/// Runs `body`, turning an interrupt into a message and the conventional exit code.
func exitingOnInterrupt<Result: Sendable>(
    interrupt: (@Sendable () -> Void)? = nil,
    _ body: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    do {
        return try await cancellingOnInterrupt(interrupt: interrupt, body)
    } catch is CancellationError {
        FileHandle.standardError.write(Data("Capture cancelled\n".utf8))
        throw ExitCode(interruptedExitCode)
    }
}

/// Highest channel index on any Saleae device. Bounds ranges before they are expanded.
let maximumChannel: UInt32 = 15

func parseChannelList(_ text: String) throws -> [UInt32] {
    var channels: [UInt32] = []
    for part in text.split(separator: ",") {
        let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { UInt32($0) }
        switch (bounds.count, bounds[0], bounds[bounds.count - 1]) {
        case (1, let single?, _) where single <= maximumChannel:
            channels.append(single)
        case (2, let low?, let high?) where low <= high && high <= maximumChannel:
            channels.append(contentsOf: low...high)
        default:
            throw ValidationError("Invalid channel list: \(text)")
        }
    }
    guard !channels.isEmpty, Set(channels).count == channels.count else {
        throw ValidationError("Invalid channel list: \(text)")
    }
    return channels
}

func parseSampleRate(_ text: String) throws -> UInt32 {
    let multipliers: [Character: Double] = ["k": 1e3, "K": 1e3, "M": 1e6]
    let multiplier = text.last.flatMap { multipliers[$0] }
    let digits = multiplier == nil ? Substring(text) : text.dropLast()
    guard let value = Double(digits), value > 0,
        let rate = UInt32(exactly: (value * (multiplier ?? 1)).rounded()),
        rate > 0
    else {
        throw ValidationError("Invalid sample rate: \(text)")
    }
    return rate
}

let maximumAnalogDownsample: UInt64 = 1_000_000

func describe(_ summary: AnalogSummary) -> String {
    var parts = ["A\(summary.channel)"]
    if let levels = summary.levels {
        parts.append(String(format: "low %.3f V, high %.3f V", levels.lowVolts, levels.highVolts))
    } else {
        parts.append(String(format: "steady %.3f V", summary.meanVolts))
    }
    if let periodic = summary.periodic {
        parts.append(String(format: "%.2f Hz, %.2f%% duty", periodic.frequencyHz, periodic.dutyPercent))
    }
    parts.append(String(format: "range %.3f to %.3f V, rms %.3f V", summary.minVolts, summary.maxVolts, summary.rmsVolts))
    return parts.joined(separator: ", ")
}

func describe(_ summary: ChannelSummary) -> String {
    let label = "CH\(summary.channel)"
    guard summary.edges > 0 else {
        return "\(label)  idle \(summary.initialLevel == 1 ? "high" : "low")"
    }
    if let periodic = summary.periodic {
        return String(
            format: "%@  %.2f Hz, %.2f%% duty, jitter %@, %d edges",
            label, periodic.frequencyHz, periodic.dutyPercent,
            formatSeconds(periodic.periodJitterSeconds), summary.edges)
    }
    let high = summary.minHighSeconds.map(formatSeconds) ?? "n/a"
    let low = summary.minLowSeconds.map(formatSeconds) ?? "n/a"
    return "\(label)  \(summary.edges) edges in \(summary.bursts) bursts, min high \(high), min low \(low)"
}

func formatSeconds(_ seconds: Double) -> String {
    switch seconds {
    case 1...: String(format: "%.3f s", seconds)
    case 1e-3...: String(format: "%.3f ms", seconds * 1e3)
    case 1e-6...: String(format: "%.3f us", seconds * 1e6)
    default: String(format: "%.0f ns", seconds * 1e9)
    }
}
