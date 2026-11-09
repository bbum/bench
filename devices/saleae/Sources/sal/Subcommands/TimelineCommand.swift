import ArgumentParser
import Foundation

/// A moment in a capture, which may be zero or, before a trigger, negative.
struct TimePoint: ExpressibleByArgument, Equatable, Sendable {
    var seconds: Double

    init(seconds: Double) { self.seconds = seconds }

    init?(argument: String) {
        guard let value = parseScaledSeconds(argument), value.isFinite else { return nil }
        seconds = value
    }
}

/// Reads `TEXT` as a decoder, in the form `sal identify` prints.
func parseOverlay(_ text: String) throws -> ProtocolDecoder {
    var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
    if Array(tokens.prefix(2)) == ["sal", "decode"] { tokens.removeFirst(2) }
    guard let kind = tokens.first, let allowed = busOptionKeys[kind] else {
        throw ValidationError("An overlay must start with uart, spi or i2c: \(text)")
    }
    for token in tokens.dropFirst() where token.hasPrefix("--") {
        let name = token.dropFirst(2).prefix { $0 != "=" }.replacingOccurrences(of: "-", with: "_")
        guard allowed.contains(name) else { throw ValidationError("An overlay can only describe the bus, not --\(name).") }
    }
    let parsed: any ParsableCommand
    do {
        parsed = try Sal.parseAsRoot(["decode"] + tokens)
    } catch {
        throw ValidationError("Bad overlay \"\(text)\": \(Sal.message(for: error))")
    }
    guard let command = parsed as? any DecodeInvocation else { throw ValidationError("Bad overlay: \(text)") }
    return command.protocolDecoder
}

struct TimelineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timeline",
        abstract: "Show what each channel did over time, with decoded data lined up on top."
    )

    @OptionGroup var capture: CaptureOptions
    @OptionGroup var analogOptions: AnalogOptions

    @Option(help: "Digital channels, such as 0-7 or 0,2,4, or none with --analog. Defaults to 0-7, or all with --load.")
    var channels: String?

    // Unconditional parsing, so that a negative time is not mistaken for an option.
    @Option(parsing: .unconditional, help: "Start of the window, such as 12ms. Zero is the capture start, or the trigger.")
    var from: TimePoint?

    @Option(parsing: .unconditional, help: "End of the window.")
    var to: TimePoint?

    @Option(help: "Decoder to line up, as sal identify prints it, such as \"uart --channel 2 --baud 115200\". Repeatable.")
    var overlay: [String] = []

    @Option(help: "How to show overlay values: hex, dec, bin or ascii.")
    var radix = Radix.hex

    @Option(help: "Most segments per channel in the data. Drawn files always use full detail.")
    var maxSegments = 2000

    @Option(help: "Write the timeline to this HTML file.")
    var html: String?

    @Option(help: "Write the timeline to this SVG file.")
    var svg: String?

    @Option(help: "Title for the drawn timeline.")
    var title: String?

    @Flag(help: "Print JSON instead of a summary.")
    var json = false

    func validate() throws {
        guard (2...maximumTimelineSegments).contains(maxSegments) else {
            throw ValidationError("--max-segments must be from 2 to \(maximumTimelineSegments).")
        }
        if let from, let to {
            guard from.seconds < to.seconds else { throw ValidationError("--from must be before --to.") }
        }
        guard channels != "none" || analogOptions.analog != nil else {
            throw ValidationError("--channels none needs --analog.")
        }
        _ = try overlay.map(parseOverlay)
    }

    func execute(handlingSignals: Bool) async throws -> Timeline {
        let decoders = try overlay.map(parseOverlay)
        let loadingEverything = capture.load != nil && channels == nil
        let listed = try resolvedChannels(channels, loading: capture.load != nil)
        let digital = loadingEverything ? [] : Array(Set(listed + decoders.flatMap(\.channels))).sorted()
        let endpoint = capture.logic2.endpoint
        let (from, to, maxSegments, radix) = (from?.seconds, to?.seconds, maxSegments, radix)
        let (htmlPath, svgPath, title) = (html.map(absolutePath), svg.map(absolutePath), title)

        return try await capture.perform(channels: digital, analog: try analogOptions.analogCapture, handlingSignals: handlingSignals) { request in
            let result = try await runTimeline(
                TimelineRequest(capture: request, overlays: decoders, radix: radix, from: from, to: to, maxSegments: maxSegments),
                endpoint: endpoint)
            if let htmlPath {
                try renderTimelineHTML(result.detailed, title: title).write(toFile: htmlPath, atomically: true, encoding: .utf8)
            }
            if let svgPath {
                try renderTimelineSVG(result.detailed, title: title).write(toFile: svgPath, atomically: true, encoding: .utf8)
            }
            return result.timeline
        }
    }

    func run() async throws {
        let timeline = try await execute(handlingSignals: true)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(timeline), as: UTF8.self))
        } else {
            describe(timeline).forEach { print($0) }
            [html, svg].compactMap { $0 }.forEach { print("Wrote \($0)") }
        }
    }
}

let maximumTimelineSegments = 100_000

func describe(_ timeline: Timeline) -> [String] {
    var lines = ["\(formatTickTime(timeline.fromSeconds)) to \(formatTickTime(timeline.toSeconds))"]
    lines += timeline.digital.map { "D\($0.channel)  \($0.edges) edges, \($0.segments.count) segments" }
    lines += timeline.analog.map { "A\($0.channel)  \($0.minVolts.count) points" }
    lines += timeline.overlays.map { overlay in
        let problems = overlay.annotations.count { $0.problem != nil }
        return "\(overlay.label)  \(overlay.annotations.count) items, \(problems) problems"
            + (overlay.omitted > 0 ? ", \(overlay.omitted) more not shown" : "")
    }
    return lines
}
