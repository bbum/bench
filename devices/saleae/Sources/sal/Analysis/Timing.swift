import Foundation

struct TimingStatistics: Encodable, Equatable, Sendable {
    var count: Int
    var minSeconds: Double
    var maxSeconds: Double
    var meanSeconds: Double
    var medianSeconds: Double
    var stddevSeconds: Double

    init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        count = values.count
        minSeconds = sorted[0]
        maxSeconds = sorted[sorted.count - 1]
        meanSeconds = mean
        medianSeconds = sorted[(sorted.count - 1) / 2]
        stddevSeconds = variance.squareRoot()
    }
}

/// Edges of one kind, oldest first.
func selectedEdges(of channel: IdentifiableChannel, _ kind: EdgeKind) -> [Double] {
    guard kind != .either else { return channel.times }
    let wanted = kind == .rising ? 1 : 0
    return channel.times.indices.filter { channel.level(afterEdges: $0 + 1) == wanted }.map { channel.times[$0] }
}

/// How many of the sorted `times` are at or before `time`.
private func countThrough(_ times: [Double], _ time: Double) -> Int {
    var low = 0
    var high = times.count
    while low < high {
        let middle = (low + high) / 2
        if times[middle] <= time {
            low = middle + 1
        } else {
            high = middle
        }
    }
    return low
}

struct LatencyResult: Encodable, Equatable, Sendable {
    var fromEdges: Int
    var unmatched: Int
    var latency: TimingStatistics?
}

/// Pairs each `from` edge with the first `to` edge after it, before the next `from` edge.
/// A `from` edge with no such partner, or none within `maximum`, counts as unmatched.
func measureLatency(from: [Double], to: [Double], maximum: Double? = nil) -> LatencyResult {
    var values: [Double] = []
    for (index, start) in from.enumerated() {
        let position = countThrough(to, start)
        guard position < to.count else { continue }
        let end = to[position]
        if index + 1 < from.count, end >= from[index + 1] { continue }
        if let maximum, end - start > maximum { continue }
        values.append(end - start)
    }
    return LatencyResult(fromEdges: from.count, unmatched: from.count - values.count, latency: TimingStatistics(values))
}

struct DataTiming: Encodable, Equatable, Sendable {
    var channel: UInt32
    var setup: TimingStatistics?
    var hold: TimingStatistics?
    var setupViolations: Int
    var holdViolations: Int
}

struct SetupHoldResult: Encodable, Equatable, Sendable {
    var clockEdges: Int
    /// Data edges further than this from a clock edge are not related to it.
    var windowSeconds: Double?
    var data: [DataTiming]
}

/// Measures, around each clock edge, the time since the data last changed and until it next
/// changes. Only changes within one clock period count, so idle gaps do not skew the result.
func measureSetupHold(
    clock: [Double],
    data: [(channel: UInt32, times: [Double])],
    minimumSetup: Double? = nil,
    minimumHold: Double? = nil
) -> SetupHoldResult {
    let spacing = zip(clock, clock.dropFirst()).map { $1 - $0 }.sorted()
    let window = spacing.isEmpty ? nil : spacing[(spacing.count - 1) / 2]

    let timings = data.map { line -> DataTiming in
        var setups: [Double] = []
        var holds: [Double] = []
        for edge in clock {
            let through = countThrough(line.times, edge)
            // A change exactly at the clock edge holds for zero time, so it is not setup.
            let before = through > 0 && line.times[through - 1] == edge ? through - 2 : through - 1
            if before >= 0 {
                let setup = edge - line.times[before]
                if window.map({ setup <= $0 }) ?? true { setups.append(setup) }
            }
            let after = before + 1
            if after < line.times.count {
                let hold = line.times[after] - edge
                if window.map({ hold <= $0 }) ?? true { holds.append(hold) }
            }
        }
        return DataTiming(
            channel: line.channel, setup: TimingStatistics(setups), hold: TimingStatistics(holds),
            setupViolations: minimumSetup.map { limit in setups.count { $0 < limit } } ?? 0,
            holdViolations: minimumHold.map { limit in holds.count { $0 < limit } } ?? 0)
    }
    return SetupHoldResult(clockEdges: clock.count, windowSeconds: window, data: timings)
}

struct ChannelActivity: Encodable, Equatable, Sendable {
    var channel: UInt32
    var edges: Int
    var bursts: Int
    var busyPercent: Double
    var meanBurstSeconds: Double?
    var longestIdleSeconds: Double
}

/// Groups edges no more than `gap` apart into bursts. Idle time includes the stretches
/// before the first edge and after the last.
func measureActivity(_ channel: IdentifiableChannel, gap: Double) -> ChannelActivity {
    let times = channel.times
    let span = channel.endTime - channel.beginTime
    guard let first = times.first, let last = times.last else {
        return ChannelActivity(
            channel: channel.channel, edges: 0, bursts: 0, busyPercent: 0, meanBurstSeconds: nil, longestIdleSeconds: span)
    }

    var bursts = 1
    var busy = 0.0
    var burstStart = first
    var longestIdle = max(first - channel.beginTime, channel.endTime - last)
    for (previous, next) in zip(times, times.dropFirst()) where next - previous > gap {
        bursts += 1
        busy += previous - burstStart
        burstStart = next
        longestIdle = max(longestIdle, next - previous)
    }
    busy += last - burstStart

    return ChannelActivity(
        channel: channel.channel, edges: times.count, bursts: bursts, busyPercent: span > 0 ? 100 * busy / span : 0,
        meanBurstSeconds: busy / Double(bursts), longestIdleSeconds: longestIdle)
}
