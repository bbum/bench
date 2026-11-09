import Foundation

/// One channel's edges, ready for identification.
struct IdentifiableChannel: Sendable {
    var summary: ChannelSummary
    var times: [Double]

    var channel: UInt32 { summary.channel }
    var isIdle: Bool { times.isEmpty }

    /// The level after `edges` transitions.
    func level(afterEdges edges: Int) -> Int {
        edges % 2 == 0 ? summary.initialLevel : 1 - summary.initialLevel
    }

    /// Index of the edge that starts the longest gap between edges.
    private var longestGapEdge: Int {
        var longest = 0
        for index in 0..<(times.count - 1) where times[index + 1] - times[index] > times[longest + 1] - times[longest] {
            longest = index
        }
        return longest
    }

    /// The level held during a clear idle gap, or otherwise the level the capture began at.
    var restingLevel: Int {
        guard times.count >= 2 else { return summary.initialLevel }
        let edge = longestGapEdge
        let average = (times[times.count - 1] - times[0]) / Double(times.count - 1)
        return times[edge + 1] - times[edge] > average * 3 ? level(afterEdges: edge + 1) : summary.initialLevel
    }

    /// As `restingLevel`, for a signal where only a gap of over `seconds` is really idle.
    func restingLevel(gapOver seconds: Double) -> Int {
        guard times.count >= 2 else { return summary.initialLevel }
        let edge = longestGapEdge
        return times[edge + 1] - times[edge] > seconds ? level(afterEdges: edge + 1) : summary.initialLevel
    }

    /// How many edges happen at or before `time`.
    func edgesThrough(_ time: Double) -> Int {
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
}

enum Confidence: String, Encodable, Sendable {
    /// Timing fits and Logic 2's analyzer decoded it cleanly.
    case confirmed
    /// Timing fits, and no decoder has checked it.
    case likely
    /// Thin evidence, or the decoder disagreed.
    case uncertain
}

struct IdentifiedBus: Equatable, Sendable {
    var decoder: ProtocolDecoder
    var confidence: Confidence
    var evidence: String
    var notes: [String] = []
}

struct PeriodicChannel: Encodable, Equatable, Sendable {
    var channel: UInt32
    var frequencyHz: Double
    var dutyPercent: Double
}

struct IdleChannel: Encodable, Equatable, Sendable {
    var channel: UInt32
    var level: Int
}

struct ChannelIdentification: Encodable, Equatable, Sendable {
    var buses: [IdentifiedBus]
    var periodic: [PeriodicChannel]
    var idle: [IdleChannel]
    /// Active channels that match nothing.
    var unknown: [UInt32]
    var notes: [String]
}

extension IdentifiedBus: Encodable {
    private enum CodingKeys: String, CodingKey {
        case kind, channels, confidence, evidence, notes, command
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decoder.kind, forKey: .kind)
        try container.encode(decoder.channelRoles, forKey: .channels)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(notes, forKey: .notes)
        try container.encode(decoder.command, forKey: .command)
    }
}

/// Fractions of events that must fit a protocol for it to count. They leave room for a
/// capture window cutting the first and last frames in half.
private let requiredI2CFraction = 0.8
private let requiredBurstFraction = 0.8
private let requiredEdgeFraction = 0.9

/// Works out what is on each channel from edge timing alone. Never picks silently: what
/// timing cannot settle is reported in `notes`.
func identifyChannels(_ channels: [IdentifiableChannel]) -> ChannelIdentification {
    let ordered = channels.sorted { $0.channel < $1.channel }
    var unclaimed = Set(ordered.filter { !$0.isIdle }.map(\.channel))
    let active = ordered.filter { !$0.isIdle }
    var buses: [IdentifiedBus] = []
    var notes: [String] = []

    func candidates(includingPeriodic: Bool = false) -> [IdentifiableChannel] {
        active.filter { unclaimed.contains($0.channel) && (includingPeriodic || $0.summary.periodic == nil) }
    }

    // A lone transaction has perfectly regular clocks, so periodic channels count here.
    let i2c = findI2C(candidates(includingPeriodic: true))
    for match in i2c {
        unclaimed.subtract([match.sda, match.scl])
        buses.append(
            IdentifiedBus(
                decoder: .i2c(I2CDecoder(sda: match.sda, scl: match.scl)),
                confidence: match.transactions >= 2 ? .likely : .uncertain,
                evidence: "\(match.transactions) transactions of whole 9-clock bytes"))
    }

    while let match = findSPI(candidates(), enableCandidates: candidates(includingPeriodic: true)) {
        unclaimed.subtract([match.decoder.clock] + match.data)
        if let enable = match.decoder.enable { unclaimed.remove(enable) }
        buses.append(
            IdentifiedBus(
                decoder: .spi(match.decoder),
                confidence: match.bursts >= 2 ? .likely : .uncertain,
                evidence: "\(match.bursts) clock bursts in multiples of 8, data in step",
                notes: match.notes))
    }

    for candidate in candidates() {
        guard let match = matchUART(candidate) else { continue }
        unclaimed.remove(candidate.channel)
        buses.append(
            IdentifiedBus(
                decoder: .uart(UARTDecoder(channel: candidate.channel, baud: match.baud, inverted: match.inverted)),
                confidence: match.edges >= minimumConfidentUARTEdges ? .likely : .uncertain,
                evidence: "pulse widths are multiples of \(formatSeconds(match.bitSeconds))",
                notes: uartNotes(edges: match.edges)))
    }

    if buses.count(where: { $0.decoder.kind == "uart" }) >= 2 {
        notes.append("Timing cannot tell UART TX from RX.")
    }
    if buses.count(where: { $0.decoder.kind == "i2c" }) >= 2 {
        notes.append("Several I2C buses were found, and nothing distinguishes one from another.")
    }

    let periodic = active.filter { unclaimed.contains($0.channel) }.compactMap { channel in
        channel.summary.periodic.map {
            PeriodicChannel(channel: channel.channel, frequencyHz: $0.frequencyHz, dutyPercent: $0.dutyPercent)
        }
    }
    unclaimed.subtract(periodic.map(\.channel))

    let idle = ordered.filter(\.isIdle).map { IdleChannel(channel: $0.channel, level: $0.summary.initialLevel) }
    if !idle.isEmpty { notes.append("Idle channels reveal nothing about what is wired to them.") }

    return ChannelIdentification(
        buses: buses.sorted { $0.decoder.channels[0] < $1.decoder.channels[0] },
        periodic: periodic, idle: idle, unknown: unclaimed.sorted(), notes: notes)
}

// MARK: I2C

private struct I2CMatch {
    var sda: UInt32
    var scl: UInt32
    var transactions: Int
}

private func findI2C(_ channels: [IdentifiableChannel]) -> [I2CMatch] {
    // One short transaction has no idle gap, so the starting level counts as well.
    let lines = channels.filter { $0.restingLevel == 1 || $0.summary.initialLevel == 1 }
    var matches: [I2CMatch] = []
    for sda in lines {
        for scl in lines where scl.channel != sda.channel {
            if let transactions = countI2CTransactions(sda: sda, scl: scl) {
                matches.append(I2CMatch(sda: sda.channel, scl: scl.channel, transactions: transactions))
            }
        }
    }

    var taken = Set<UInt32>()
    var chosen: [I2CMatch] = []
    for match in matches.sorted(by: { $0.transactions > $1.transactions })
    where !taken.contains(match.sda) && !taken.contains(match.scl) {
        taken.formUnion([match.sda, match.scl])
        chosen.append(match)
    }
    return chosen
}

/// Counts transactions if the pair behaves like I2C. SDA falling while SCL is high is a
/// start, SDA rising while SCL is high is a stop, and each byte takes 9 clocks. The stop
/// or repeated start that ends a transaction adds one more SCL rise of its own.
private func countI2CTransactions(sda: IdentifiableChannel, scl: IdentifiableChannel) -> Int? {
    var clockEdges = 0
    var clocks = 0
    var open = false
    var starts = 0
    var stops = 0
    var total = 0
    var whole = 0

    func close() {
        total += 1
        let byteClocks = clocks - 1
        if byteClocks > 0, byteClocks.isMultiple(of: 9) { whole += 1 }
    }

    for (index, time) in sda.times.enumerated() {
        while clockEdges < scl.times.count, scl.times[clockEdges] < time {
            clockEdges += 1
            if scl.level(afterEdges: clockEdges) == 1 { clocks += 1 }
        }
        guard scl.level(afterEdges: clockEdges) == 1 else { continue }

        if sda.level(afterEdges: index + 1) == 0 {
            if open { close() }
            open = true
            clocks = 0
            starts += 1
        } else {
            if open { close() }
            open = false
            stops += 1
        }
    }

    guard starts > 0, stops > 0, whole > 0, Double(whole) >= Double(total) * requiredI2CFraction else { return nil }
    return whole
}

// MARK: SPI

private struct ClockBurst {
    var first: Int
    var last: Int
}

private struct SPIMatch {
    var decoder: SPIDecoder
    var data: [UInt32]
    var bursts: Int
    var notes: [String]
}

private func findSPI(
    _ channels: [IdentifiableChannel],
    enableCandidates: [IdentifiableChannel]
) -> SPIMatch? {
    for clock in channels.sorted(by: { $0.times.count > $1.times.count }) {
        guard let (bursts, period) = clockBursts(clock) else { continue }
        let enable = enableCandidates.first {
            $0.channel != clock.channel && bracketsBursts($0, bursts: bursts, clock: clock)
        }
        let others = channels.filter { $0.channel != clock.channel && $0.channel != enable?.channel }
        var aligned: [(channel: UInt32, leading: Int, trailing: Int)] = []
        for data in others {
            if let phase = dataPhase(data, clock: clock, bursts: bursts, period: period) {
                aligned.append((data.channel, phase.leading, phase.trailing))
            }
        }
        guard let first = aligned.first else { continue }
        let second = aligned.dropFirst().first

        let leading = aligned.reduce(0) { $0 + $1.leading }
        let trailing = aligned.reduce(0) { $0 + $1.trailing }
        var notes: [String] = []
        if let second {
            notes.append("Timing cannot tell MOSI from MISO, so \(first.channel) and \(second.channel) may be swapped.")
        }
        notes.append("Word size and bit order are assumed, because timing cannot show them.")
        if Double(max(leading, trailing)) < Double(leading + trailing) * requiredEdgeFraction {
            notes.append("The clock phase is unclear, so CPHA is a guess.")
        }

        var decoder = SPIDecoder(
            clock: clock.channel, mosi: first.channel, miso: second?.channel, enable: enable?.channel,
            clockIdlesHigh: clock.restingLevel == 1, dataOnTrailingEdge: leading > trailing)
        if let enable, let level = enableLevel(enable, during: bursts[bursts.count / 2], clock: clock) {
            decoder.enableActiveHigh = level == 1
        }
        return SPIMatch(
            decoder: decoder, data: aligned.prefix(2).map(\.channel), bursts: bursts.count, notes: notes)
    }
    return nil
}

/// Splits a channel into bursts if it looks like a burst clock, returning the median
/// clock period too.
private func clockBursts(_ clock: IdentifiableChannel) -> ([ClockBurst], Double)? {
    let times = clock.times
    guard times.count >= 16 else { return nil }
    let intervals = zip(times, times.dropFirst()).map { $1 - $0 }
    let half = intervals.sorted()[(intervals.count - 1) / 2]
    guard half > 0 else { return nil }

    var bursts: [ClockBurst] = []
    var first = 0
    for (index, interval) in intervals.enumerated() where interval > half * 4 {
        bursts.append(ClockBurst(first: first, last: index))
        first = index + 1
    }
    bursts.append(ClockBurst(first: first, last: times.count - 1))

    let inside = intervals.filter { $0 <= half * 4 }
    let regular = inside.count { $0 >= half * 0.5 && $0 <= half * 1.6 }
    guard Double(regular) >= Double(inside.count) * requiredEdgeFraction else { return nil }

    let whole = bursts.count { burst in
        let edges = burst.last - burst.first + 1
        return edges >= 16 && edges % 2 == 0 && (edges / 2).isMultiple(of: 8)
    }
    guard whole > 0, Double(whole) >= Double(bursts.count) * requiredBurstFraction else { return nil }
    return (bursts, half * 2)
}

/// Whether a channel changes just before each burst, just after it, and never within it.
private func bracketsBursts(
    _ enable: IdentifiableChannel,
    bursts: [ClockBurst],
    clock: IdentifiableChannel
) -> Bool {
    let framed = bursts.count { burst in
        let start = clock.times[burst.first]
        let end = clock.times[burst.last]
        let reach = end - start
        let throughStart = enable.edgesThrough(start)
        let beforeEnd = enable.edgesThrough(end.nextDown)
        let inside = beforeEnd > throughStart
        let before = throughStart > enable.edgesThrough((start - reach).nextDown)
        let after = enable.edgesThrough(end + reach) > beforeEnd
        return before && after && !inside
    }
    return framed > 0 && Double(framed) >= Double(bursts.count) * requiredBurstFraction
}

private func enableLevel(_ enable: IdentifiableChannel, during burst: ClockBurst, clock: IdentifiableChannel) -> Int? {
    let time = clock.times[burst.first]
    return enable.level(afterEdges: enable.edgesThrough(time))
}

/// Counts data edges following leading and trailing clock edges, if the channel changes
/// in step with the clock. Leading means moving away from the clock's resting level.
private func dataPhase(
    _ data: IdentifiableChannel,
    clock: IdentifiableChannel,
    bursts: [ClockBurst],
    period: Double
) -> (leading: Int, trailing: Int)? {
    let resting = clock.restingLevel
    var clockEdges = 0
    var burstIndex = 0
    var inBursts = 0
    var inStep = 0
    var leading = 0
    var trailing = 0

    for time in data.times {
        while burstIndex < bursts.count - 1, clock.times[bursts[burstIndex].last] + period < time { burstIndex += 1 }
        let burst = bursts[burstIndex]
        guard time >= clock.times[burst.first] - period, time <= clock.times[burst.last] + period else { continue }
        inBursts += 1

        while clockEdges < clock.times.count, clock.times[clockEdges] <= time { clockEdges += 1 }
        guard clockEdges > burst.first else {
            // Set up before the first clock edge, which is normal when CPHA is 0.
            inStep += 1
            continue
        }
        guard time - clock.times[clockEdges - 1] <= period / 2 else { continue }
        inStep += 1
        if clock.level(afterEdges: clockEdges) != resting {
            leading += 1
        } else {
            trailing += 1
        }
    }

    let total = Double(data.times.count)
    guard Double(inBursts) >= total * requiredEdgeFraction, Double(inStep) >= total * requiredEdgeFraction else {
        return nil
    }
    return (leading, trailing)
}

// MARK: UART

private func uartNotes(edges: Int) -> [String] {
    var notes = ["Word size and stop bits are assumed, because timing cannot show them."]
    if edges < minimumConfidentUARTEdges {
        notes.append("Few edges, so a single-bit pulse may be missing and the baud rate may be low.")
    }
    return notes
}

private let minimumConfidentUARTEdges = 40

/// How far from a whole number of bits an edge may land. A receiver samples mid-bit, so
/// it tolerates a good deal more jitter than this.
private let bitTolerance = 0.35

/// Longest run away from idle that a frame allows: start bit plus 9 data bits.
private let longestActiveBits = 11.0

private let standardBaudRates: [Int64] = [
    300, 600, 1200, 2400, 4800, 9600, 14_400, 19_200, 28_800, 31_250, 38_400, 57_600, 74_880, 76_800, 115_200,
    230_400, 250_000, 460_800, 500_000, 576_000, 921_600, 1_000_000, 1_500_000, 2_000_000, 3_000_000,
]

private struct UARTMatch {
    var baud: Int64
    var bitSeconds: Double
    var inverted: Bool
    var edges: Int
}

/// Finds the shortest width that real traffic repeats, so a stray glitch cannot pose as
/// a bit, then checks every other width is a whole number of those.
private func matchUART(_ candidate: IdentifiableChannel) -> UARTMatch? {
    let times = candidate.times
    guard times.count >= 6 else { return nil }
    let widths = zip(times, times.dropFirst()).map { $1 - $0 }
    guard let rough = shortestRepeatedWidth(widths) else { return nil }

    let resting = candidate.restingLevel(gapOver: rough * longestActiveBits)
    let active = widths.indices.filter { candidate.level(afterEdges: $0 + 1) != resting }.map { widths[$0] }
    let estimate = refinedBitTime(rough, active: active)
    var fitting = 0
    var considered = 0
    var bits = 0.0
    var seconds = 0.0
    var longest = 0.0

    for (index, width) in widths.enumerated() {
        let run = width / estimate
        let whole = run.rounded()
        let isWholeBits = whole >= 1 && abs(run - whole) <= bitTolerance

        // Time at the idle level may be a pause between frames, and a pause can be any
        // length. Only time away from idle has to be a whole number of bits.
        if candidate.level(afterEdges: index + 1) == resting {
            if isWholeBits, run <= longestActiveBits { longest = max(longest, whole) }
            continue
        }

        guard whole <= longestActiveBits else { return nil }
        considered += 1
        longest = max(longest, whole)
        guard isWholeBits else { continue }
        fitting += 1
        bits += whole
        seconds += width
    }

    guard considered > 0, longest >= 2, Double(fitting) >= Double(considered) * requiredEdgeFraction, bits > 0 else { return nil }
    let bitSeconds = seconds / bits
    return UARTMatch(
        baud: snappedBaud(1 / bitSeconds), bitSeconds: bitSeconds, inverted: resting == 0, edges: times.count)
}

/// Moves a rough bit time toward the one that best explains every pulse, since the
/// shortest pulses alone come out short when edges jitter.
private func refinedBitTime(_ rough: Double, active: [Double]) -> Double {
    var estimate = rough
    for _ in 0..<3 {
        let bits = active.reduce(0.0) { $0 + max(1, ($1 / estimate).rounded()) }
        guard bits > 0 else { break }
        estimate = active.reduce(0, +) / bits
    }
    return estimate
}

private func shortestRepeatedWidth(_ widths: [Double]) -> Double? {
    let sorted = widths.sorted()
    let required = max(3, sorted.count / 50)
    var first = 0
    while first < sorted.count {
        var last = first
        // Wide enough that jitter cannot split one-bit pulses into separate clusters. Checked
        // on hardware at 921600 baud, where a narrow cluster misses about 1 run in 10.
        while last + 1 < sorted.count, sorted[last + 1] <= sorted[first] * 1.35 { last += 1 }
        if last - first + 1 >= required, sorted[first] > 0 {
            return sorted[first...last].reduce(0, +) / Double(last - first + 1)
        }
        first = last + 1
    }
    return nil
}

private func snappedBaud(_ measured: Double) -> Int64 {
    let nearest = standardBaudRates.min { abs(Double($0) - measured) < abs(Double($1) - measured) }!
    return abs(Double(nearest) - measured) <= Double(nearest) * 0.03 ? nearest : Int64(measured.rounded())
}
