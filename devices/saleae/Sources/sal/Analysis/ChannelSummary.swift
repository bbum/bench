import Foundation

struct CaptureSummary: Codable, Sendable, Equatable {
    var durationSeconds: Double
    var channels: [ChannelSummary]
    var analog: [AnalogSummary] = []
}

struct ChannelSummary: Codable, Sendable, Equatable {
    /// Present only when every rising-edge period is within 5% of the median.
    struct Periodic: Codable, Sendable, Equatable {
        var frequencyHz: Double
        var dutyPercent: Double
        var periodMinSeconds: Double
        var periodMaxSeconds: Double
        var periodJitterSeconds: Double
    }

    var channel: UInt32
    var initialLevel: Int
    var edges: Int
    var risingEdges: Int
    /// Groups of edges separated by a gap of more than 20 times the median edge spacing.
    var bursts: Int
    var minHighSeconds: Double?
    var minLowSeconds: Double?
    var periodic: Periodic?
}

func summarizeCapture(directory: URL, channels: [UInt32], analogChannels: [UInt32] = []) throws -> CaptureSummary {
    var duration = 0.0
    var summaries: [ChannelSummary] = []
    for channel in channels {
        let file = directory.appendingPathComponent("digital_\(channel).bin")
        let digital = try DigitalChannel(contentsOf: file)
        duration = max(duration, digital.endTime - digital.beginTime)
        summaries.append(summarize(digital, channel: channel))
    }
    let analog = try analogChannels.map { channel in
        let samples = try AnalogChannel(contentsOf: directory.appendingPathComponent("analog_\(channel).bin"))
        duration = max(duration, Double(samples.sampleCount) / samples.effectiveSampleRate)
        return summarize(samples, channel: channel)
    }
    return CaptureSummary(durationSeconds: duration, channels: summaries, analog: analog)
}

func summarize(_ digital: DigitalChannel, channel: UInt32) -> ChannelSummary {
    digital.withEdgeTimes { times in
        var risingTimes: [Double] = []
        var intervals: [Double] = []
        var minHigh: Double?
        var minLow: Double?
        var totalHigh = 0.0
        var highPulses = 0
        var level = digital.initialLevel

        for index in 0..<times.count {
            let time = times[index]
            if index > 0 {
                let width = time - times[index - 1]
                intervals.append(width)
                if level == 1 {
                    minHigh = min(minHigh ?? width, width)
                    totalHigh += width
                    highPulses += 1
                } else {
                    minLow = min(minLow ?? width, width)
                }
            }
            level = 1 - level
            if level == 1 {
                risingTimes.append(time)
            }
        }

        var bursts = times.count > 0 ? 1 : 0
        if !intervals.isEmpty {
            let spacing = lowerMedian(intervals)
            bursts += intervals.count { $0 > spacing * 20 }
        }

        return ChannelSummary(
            channel: channel,
            initialLevel: digital.initialLevel,
            edges: times.count,
            risingEdges: risingTimes.count,
            bursts: bursts,
            minHighSeconds: minHigh,
            minLowSeconds: minLow,
            periodic: periodicSummary(
                risingTimes: risingTimes,
                totalHigh: totalHigh,
                highPulses: highPulses
            )
        )
    }
}

private func periodicSummary(
    risingTimes: [Double],
    totalHigh: Double,
    highPulses: Int
) -> ChannelSummary.Periodic? {
    let periods = zip(risingTimes, risingTimes.dropFirst()).map { $1 - $0 }
    guard periods.count >= 3 else { return nil }

    let median = lowerMedian(periods)
    guard periods.allSatisfy({ abs($0 - median) <= median * 0.05 }) else { return nil }

    let mean = periods.reduce(0, +) / Double(periods.count)
    let frequency = 1 / mean
    // Subnormal periods overflow here, and JSON cannot represent infinity.
    guard frequency.isFinite else { return nil }

    let variance = periods.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(periods.count)
    return ChannelSummary.Periodic(
        frequencyHz: frequency,
        dutyPercent: 100 * (totalHigh / Double(highPulses)) / mean,
        periodMinSeconds: periods.min()!,
        periodMaxSeconds: periods.max()!,
        periodJitterSeconds: variance.squareRoot()
    )
}

/// The lower of the two middle values, so bimodal data resolves to the shorter mode.
/// `values` must not be empty.
private func lowerMedian(_ values: [Double]) -> Double {
    values.sorted()[(values.count - 1) / 2]
}
