import Foundation

struct TraceSegment: Encodable, Equatable, Sendable {
    enum State: String, Encodable, Sendable {
        case low, high
        /// Pulses too short to show one by one. `edges` says how many are inside.
        case active
    }

    var start: Double
    var end: Double
    var state: State
    var edges: Int
}

struct DigitalTrace: Encodable, Equatable, Sendable {
    var channel: UInt32
    var edges: Int
    var segments: [TraceSegment]
}

struct AnalogTrace: Encodable, Equatable, Sendable {
    var channel: UInt32
    var startSeconds: Double
    var stepSeconds: Double
    var minVolts: [Double]
    var maxVolts: [Double]
}

struct TimelineAnnotation: Encodable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var problem: String?
}

struct TimelineOverlay: Encodable, Equatable, Sendable {
    var label: String
    var channels: [UInt32]
    var annotations: [TimelineAnnotation]
    /// Annotations left out to stay under the limit. Problems are never left out.
    var omitted: Int
}

struct Timeline: Encodable, Equatable, Sendable {
    var fromSeconds: Double
    var toSeconds: Double
    var digital: [DigitalTrace]
    var analog: [AnalogTrace]
    var overlays: [TimelineOverlay]
}

enum TimelineError: Error, Equatable, CustomStringConvertible {
    case emptyWindow

    var description: String {
        switch self {
        case .emptyWindow: "The time window is empty or lies outside the capture."
        }
    }
}

/// Logic 2 places a trigger edge within about 1e-18 s of time zero, rather than on it.
/// Far below any sample period, this keeps such an edge from making a sliver of a segment.
private let windowStartTolerance = 1e-12

/// Describes a channel's levels across a window. If there are more edges than `maxSegments`
/// allows, runs of short pulses merge into active spans, while anything long enough to see
/// stays exact, so no activity disappears.
func digitalTrace(_ channel: IdentifiableChannel, from: Double, to: Double, maxSegments: Int) -> DigitalTrace {
    let first = channel.edgesThrough(from + windowStartTolerance)
    let last = channel.edgesThrough(to.nextDown)
    let boundaries = [from] + channel.times[first..<last] + [to]
    let edges = last - first

    var pieces: [TraceSegment] = []
    pieces.reserveCapacity(boundaries.count - 1)
    for index in 0..<(boundaries.count - 1) {
        let level = channel.level(afterEdges: first + index)
        pieces.append(TraceSegment(start: boundaries[index], end: boundaries[index + 1], state: level == 1 ? .high : .low, edges: 0))
    }
    guard pieces.count > maxSegments else {
        return DigitalTrace(channel: channel.channel, edges: edges, segments: pieces)
    }

    let resolution = 2 * (to - from) / Double(maxSegments)
    var merged: [TraceSegment] = []
    var run: [TraceSegment] = []

    func flushRun() {
        guard let head = run.first, let tail = run.last else { return }
        merged.append(run.count == 1 ? head : TraceSegment(start: head.start, end: tail.end, state: .active, edges: run.count - 1))
        run.removeAll(keepingCapacity: true)
    }

    for piece in pieces {
        if piece.end - piece.start < resolution {
            run.append(piece)
        } else {
            flushRun()
            merged.append(piece)
        }
    }
    flushRun()
    return DigitalTrace(channel: channel.channel, edges: edges, segments: merged)
}

/// Min and max per step across a window, or every sample if they fit in `maxPoints`.
func analogTrace(_ analog: AnalogChannel, channel: UInt32, from: Double, to: Double, maxPoints: Int) -> AnalogTrace {
    let rate = analog.effectiveSampleRate
    // A tiny allowance, so rounding error cannot skip a sample exactly at the window's edge.
    let lower = max(0, ((from - analog.beginTime) * rate - sampleEpsilon).rounded(.up))
    let upper = min(Double(analog.sampleCount), ((to - analog.beginTime) * rate - sampleEpsilon).rounded(.up))
    guard lower < upper else {
        return AnalogTrace(channel: channel, startSeconds: from, stepSeconds: 1 / rate, minVolts: [], maxVolts: [])
    }

    let start = Int(lower)
    let count = Int(upper) - start
    let step = max(1, Int((Double(count) / Double(maxPoints)).rounded(.up)))
    var minimums: [Double] = []
    var maximums: [Double] = []

    analog.withSamples { samples in
        var index = start
        while index < start + count {
            let stop = min(index + step, start + count)
            var low = samples[index]
            var high = low
            for position in index..<stop {
                low = min(low, samples[position])
                high = max(high, samples[position])
            }
            minimums.append(millivolts(low))
            maximums.append(millivolts(high))
            index = stop
        }
    }
    return AnalogTrace(
        channel: channel, startSeconds: analog.beginTime + Double(start) / rate, stepSeconds: Double(step) / rate,
        minVolts: minimums, maxVolts: maximums)
}

private let sampleEpsilon = 1e-6

/// Keeps JSON readable. Logic 2's own CSV reports the same precision.
private func millivolts(_ volts: Double) -> Double {
    (volts * 1000).rounded() / 1000
}

func timelineOverlay(
    _ decoder: ProtocolDecoder,
    rows: [DecodedRow],
    from: Double,
    to: Double,
    maxAnnotations: Int
) -> TimelineOverlay {
    let labels = decodeIssueLabels(rows)
    var annotations: [TimelineAnnotation] = []
    for (row, problem) in zip(rows, labels) where row.type != "enable" && row.type != "disable" {
        let end = row.start + row.duration
        guard row.start < to, end >= from else { continue }
        annotations.append(TimelineAnnotation(start: row.start, end: end, text: annotationText(row, decoder), problem: problem))
    }

    var omitted = 0
    if annotations.count > maxAnnotations {
        // Problems first, then the earliest rows, shown in time order.
        let kept = annotations.indices.sorted { left, right in
            let (leftProblem, rightProblem) = (annotations[left].problem != nil, annotations[right].problem != nil)
            return leftProblem != rightProblem ? leftProblem : left < right
        }.prefix(max(maxAnnotations, annotations.count { $0.problem != nil }))
        omitted = annotations.count - kept.count
        annotations = kept.sorted().map { annotations[$0] }
    }

    let channels = decoder.channels.map { String($0) }.joined(separator: ",")
    return TimelineOverlay(
        label: "\(decoder.kind.uppercased()) CH\(channels)", channels: decoder.channels, annotations: annotations, omitted: omitted)
}

private func annotationText(_ row: DecodedRow, _ decoder: ProtocolDecoder) -> String {
    switch row.type {
    case "start": return "S"
    case "stop": return "P"
    case "address":
        return "\(row.fields["address"] ?? "?") \(row.fields["read"] == "true" ? "R" : "W")"
    default:
        break
    }
    if case .spi(let spi) = decoder {
        let lines = [spi.mosi.flatMap { _ in row.fields["mosi"] }, spi.miso.flatMap { _ in row.fields["miso"] }].compactMap { $0 }
        if !lines.isEmpty { return lines.joined(separator: "/") }
    }
    return row.fields["data"] ?? row.fields.sorted { $0.key < $1.key }.map(\.value).joined(separator: " ")
}

struct TimelineInput {
    var digital: [IdentifiableChannel]
    var analog: [(channel: UInt32, samples: AnalogChannel)]
    var overlays: [(decoder: ProtocolDecoder, rows: [DecodedRow])]
}

func buildTimeline(_ input: TimelineInput, from: Double?, to: Double?, maxSegments: Int) throws -> Timeline {
    let begins = input.digital.map(\.beginTime) + input.analog.map(\.samples.beginTime)
    let ends = input.digital.map(\.endTime)
        + input.analog.map { $0.samples.beginTime + Double($0.samples.sampleCount) / $0.samples.effectiveSampleRate }
    guard let earliest = begins.min(), let latest = ends.max() else { throw TimelineError.emptyWindow }

    let start = max(from ?? earliest, earliest)
    let end = min(to ?? latest, latest)
    guard end > start else { throw TimelineError.emptyWindow }

    return Timeline(
        fromSeconds: start, toSeconds: end,
        digital: input.digital.map { digitalTrace($0, from: start, to: end, maxSegments: maxSegments) },
        analog: input.analog.map { analogTrace($0.samples, channel: $0.channel, from: start, to: end, maxPoints: maxSegments) },
        overlays: input.overlays.map {
            timelineOverlay($0.decoder, rows: $0.rows, from: start, to: end, maxAnnotations: maxSegments)
        })
}
