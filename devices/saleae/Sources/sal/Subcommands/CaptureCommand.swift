import ArgumentParser
import Foundation

struct CaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Run a timed digital capture and summarize each channel."
    )

    @OptionGroup var logic2: Logic2Options

    @Option(help: "Digital channels, such as 0-7 or 0,2,4.")
    var channels = "0-7"

    @Option(help: "Digital sample rate, such as 50M or 500000.")
    var rate = "50M"

    @Option(help: "Capture length in seconds.")
    var duration = 0.5

    @Option(help: "Logic level in volts: 1.2, 1.8 or 3.3.")
    var level = 3.3

    @Option(help: "Device serial number. Defaults to the first physical device.")
    var device: String?

    @Flag(help: "Print JSON instead of a table.")
    var json = false

    func validate() throws {
        guard duration.isFinite, duration > 0 else {
            throw ValidationError("Duration must be a positive number of seconds.")
        }
    }

    func run() async throws {
        let request = DigitalCaptureRequest(
            channels: try parseChannelList(channels),
            sampleRate: try parseSampleRate(rate),
            durationSeconds: duration,
            levelVolts: level,
            deviceID: device
        )
        let endpoint = logic2.endpoint
        let summary: CaptureSummary
        do {
            summary = try await cancellingOnInterrupt {
                try await runDigitalCapture(request, endpoint: endpoint)
            }
        } catch is CancellationError {
            FileHandle.standardError.write(Data("Capture cancelled\n".utf8))
            throw ExitCode(interruptedExitCode)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(summary), as: UTF8.self))
        } else {
            print("\(formatSeconds(summary.durationSeconds)) captured")
            summary.channels.forEach { print(describe($0)) }
        }
    }
}

/// The shell convention for a process ended by SIGINT.
let interruptedExitCode: Int32 = 130

/// Highest channel index on any Saleae device. Bounds ranges before they are expanded.
private let maximumChannel: UInt32 = 15

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
