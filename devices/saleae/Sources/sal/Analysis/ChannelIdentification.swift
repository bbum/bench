import Foundation

/// One channel's edges, ready for identification.
struct IdentifiableChannel: Sendable {
    var summary: ChannelSummary
    var times: [Double]
    /// When the capture began and ended. The quiet before the first edge and after the last
    /// is evidence too.
    var beginTime = 0.0
    var endTime = 0.0

    var channel: UInt32 { summary.channel }
    var isIdle: Bool { times.isEmpty }

    /// The level after `edges` transitions.
    func level(afterEdges edges: Int) -> Int {
        edges % 2 == 0 ? summary.initialLevel : 1 - summary.initialLevel
    }

    /// How long the capture ran before the first edge, and on after the last.
    var leadIn: Double { times.first.map { max(0, $0 - beginTime) } ?? 0 }
    var tailOut: Double { times.last.map { max(0, endTime - $0) } ?? 0 }

    /// The longest stretch with no edge, and the level held through it. The stretches the
    /// capture window cuts short, before the first edge and after the last, count as well.
    private var longestQuiet: (seconds: Double, level: Int) {
        var longest = (seconds: leadIn, level: summary.initialLevel)
        for index in 0..<max(0, times.count - 1) where times[index + 1] - times[index] > longest.seconds {
            longest = (times[index + 1] - times[index], level(afterEdges: index + 1))
        }
        if tailOut > longest.seconds { longest = (tailOut, level(afterEdges: times.count)) }
        return longest
    }

    /// The level held during a clear idle stretch, or otherwise the level the capture began at.
    var restingLevel: Int {
        guard times.count >= 2 else { return summary.initialLevel }
        let average = (times[times.count - 1] - times[0]) / Double(times.count - 1)
        let quiet = longestQuiet
        return quiet.seconds > average * 3 ? quiet.level : summary.initialLevel
    }

    /// As `restingLevel`, for a signal where only a stretch of over `seconds` is really idle.
    func restingLevel(gapOver seconds: Double) -> Int {
        guard times.count >= 2 else { return summary.initialLevel }
        let quiet = longestQuiet
        return quiet.seconds > seconds ? quiet.level : summary.initialLevel
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

/// Fractions of events that must fit a protocol for it to count. What the capture window
/// cuts in half is left out before these apply, so the slack is for glitches and for the
/// odd transfer that really was cut short.
private let requiredI2CFraction = 0.8
private let requiredBurstFraction = 0.8
private let requiredEdgeFraction = 0.9
/// A pause of a clock period or so between bytes is too short to part the clock into
/// bursts, and stretches one period in eight.
private let requiredRegularFraction = 0.8

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

    // Worked out once, because every channel is weighed as a clock more than once.
    let regular = Dictionary(
        uniqueKeysWithValues: active.compactMap { channel in regularClock(channel).map { (channel.channel, $0) } })

    // One transfer alone has a perfectly regular clock too, so periodic channels may be clocks.
    while let match = findSPI(
        clocks: candidates(includingPeriodic: true), data: candidates(), enables: candidates(includingPeriodic: true),
        regular: regular)
    {
        unclaimed.subtract([match.decoder.clock] + match.data)
        if let enable = match.decoder.enable { unclaimed.remove(enable) }
        buses.append(
            IdentifiedBus(
                decoder: .spi(match.decoder),
                confidence: match.bursts >= 2 ? .likely : .uncertain,
                evidence: "\(match.bursts) clock \(match.bursts == 1 ? "burst" : "bursts") in multiples of 8, data in step",
                notes: match.notes))
    }

    // A UART has no clock. A line that keeps step with one is clocked data, whatever its
    // pulse widths look like.
    for candidate in candidates() {
        if let keeper = clockKeeping(candidate, among: active, regular: regular) {
            notes.append("CH\(candidate.channel) changes in step with the clock on CH\(keeper), so it is clocked data, not UART.")
            continue
        }
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
    // Only SCL may look periodic: SDA carries data, and two PWMs must not pass as a bus.
    for sda in lines where sda.summary.periodic == nil {
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
    var dataChanges = 0

    func close() {
        total += 1
        let byteClocks = clocks - 1
        if byteClocks > 0, byteClocks.isMultiple(of: 9), dataChanges > 0 { whole += 1 }
    }

    for (index, time) in sda.times.enumerated() {
        // SDA is allowed to change the moment SCL falls, and at a low sample rate both land
        // in one sample. Starts and stops must keep clear of SCL edges, so a tie is data.
        while clockEdges < scl.times.count,
            scl.times[clockEdges] < time || (scl.times[clockEdges] == time && scl.level(afterEdges: clockEdges + 1) == 0)
        {
            clockEdges += 1
            if scl.level(afterEdges: clockEdges) == 1 { clocks += 1 }
        }
        // SDA moving while SCL is low is data. An SPI enable line around a clock that idles
        // high makes the same start and stop shapes, but never moves in between.
        guard scl.level(afterEdges: clockEdges) == 1 else {
            dataChanges += 1
            continue
        }

        if sda.level(afterEdges: index + 1) == 0 {
            if open { close() }
            open = true
            clocks = 0
            dataChanges = 0
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
    /// The capture began or ended too close to tell whether the burst did as well.
    var isCut = false

    var edges: Int { last - first + 1 }
}

private struct RegularClock {
    var bursts: [ClockBurst]
    /// Median time from one edge to the next edge the same way.
    var period: Double

    var complete: [ClockBurst] { bursts.filter { !$0.isCut } }
}

private struct SPIMatch {
    var decoder: SPIDecoder
    var data: [UInt32]
    var bursts: Int
    var notes: [String]
}

private func findSPI(
    clocks: [IdentifiableChannel],
    data: [IdentifiableChannel],
    enables: [IdentifiableChannel],
    regular: [UInt32: RegularClock]
) -> SPIMatch? {
    for clock in clocks.sorted(by: { $0.times.count > $1.times.count }) {
        guard let timing = regular[clock.channel], isByteClock(timing) else { continue }
        let enable = bestEnable(enables.filter { $0.channel != clock.channel }, clock: clock, timing: timing)
        let others = data.filter { $0.channel != clock.channel && $0.channel != enable?.line.channel }

        var aligned: [(channel: UInt32, leading: Int, trailing: Int)] = []
        var control: [UInt32] = []
        for line in others {
            guard let fit = dataFit(line, clock: clock, timing: timing, enable: enable) else { continue }
            if fit.midByte > 0 {
                aligned.append((line.channel, fit.leading, fit.trailing))
            } else {
                control.append(line.channel)
            }
        }
        guard let first = aligned.first else { continue }
        let second = aligned.dropFirst().first

        let leading = aligned.prefix(2).reduce(0) { $0 + $1.leading }
        let trailing = aligned.prefix(2).reduce(0) { $0 + $1.trailing }
        var notes: [String] = []
        if let second {
            notes.append("Timing cannot tell MOSI from MISO, so \(first.channel) and \(second.channel) may be swapped.")
        }
        notes.append("Word size and bit order are assumed, because timing cannot show them.")
        if Double(max(leading, trailing)) < Double(leading + trailing) * requiredEdgeFraction {
            notes.append("The clock phase is unclear, so CPHA is a guess.")
        }
        for channel in control {
            notes.append("CH\(channel) only changes between bytes, so it is probably a control line such as D/C, not data.")
        }

        var decoder = SPIDecoder(
            clock: clock.channel, mosi: first.channel, miso: second?.channel, enable: enable?.line.channel,
            clockIdlesHigh: clock.restingLevel == 1, dataOnTrailingEdge: leading > trailing)
        if let enable { decoder.enableActiveHigh = enable.active == 1 }
        return SPIMatch(
            decoder: decoder, data: aligned.prefix(2).map(\.channel), bursts: timing.complete.count, notes: notes)
    }
    return nil
}

/// Splits a channel into bursts if it ticks regularly. Bursts part wherever a gap exceeds
/// 4 times the median spacing.
private func regularClock(_ clock: IdentifiableChannel) -> RegularClock? {
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
    // Without that much quiet on the far side, the window may have cut the burst.
    if clock.leadIn <= half * 4 { bursts[0].isCut = true }
    if clock.tailOut <= half * 4 { bursts[bursts.count - 1].isCut = true }

    // Regular means the period, edge to matching edge. A clock's duty need not be 50%.
    let periods = bursts.flatMap { burst in
        burst.last - burst.first >= 2 ? (burst.first...(burst.last - 2)).map { times[$0 + 2] - times[$0] } : []
    }
    guard !periods.isEmpty else { return nil }
    let period = periods.sorted()[(periods.count - 1) / 2]
    let regular = periods.count { $0 >= period * 0.6 && $0 <= period * 1.4 }
    guard Double(regular) >= Double(periods.count) * requiredRegularFraction else { return nil }
    return RegularClock(bursts: bursts, period: period)
}

/// Whether a clock's bursts are whole bytes. Bursts the window cut say nothing either way.
private func isByteClock(_ timing: RegularClock) -> Bool {
    let complete = timing.complete
    let whole = complete.count { $0.edges >= 16 && $0.edges % 2 == 0 && ($0.edges / 2).isMultiple(of: 8) }
    return whole > 0 && Double(whole) >= Double(complete.count) * requiredBurstFraction
}

private struct EnableLine {
    var line: IdentifiableChannel
    var active: Int
    /// How long it is asserted with no clock running. The real enable wraps the bursts tightest.
    var slack: Double
}

/// The channel that frames the clock, if one does.
private func bestEnable(_ candidates: [IdentifiableChannel], clock: IdentifiableChannel, timing: RegularClock) -> EnableLine? {
    candidates.compactMap { enableLine($0, clock: clock, timing: timing) }
        .min { ($0.slack, $0.line.channel) < ($1.slack, $1.line.channel) }
}

/// An enable holds one level through every burst and never moves inside one. Between
/// bursts it either stays put, when one transfer has pauses in it, or lets go and is
/// asserted again. How far ahead of the clock it moves does not matter. A line that is
/// merely busy around the bursts, such as a UART logging each transfer, moves more often.
/// And an enable is asserted for the transfers, not at rest: a line that sits at the level
/// it holds through the bursts and blips away between them is something else, pulsing in
/// time with the traffic.
private func enableLine(_ line: IdentifiableChannel, clock: IdentifiableChannel, timing: RegularClock) -> EnableLine? {
    let bursts = timing.bursts
    var held = [0, 0]
    for burst in bursts {
        let before = line.edgesThrough(clock.times[burst.first])
        let inside = line.edgesThrough(clock.times[burst.last].nextDown) - before
        if inside == 0 { held[line.level(afterEdges: before)] += 1 }
    }
    let active = held[1] > held[0] ? 1 : 0
    guard Double(held[active]) >= Double(bursts.count) * requiredBurstFraction else { return nil }

    var orderly = 0
    var reasserted = 0
    for (earlier, later) in zip(bursts, bursts.dropFirst()) {
        let moves = line.edgesThrough(clock.times[later.first]) - line.edgesThrough(clock.times[earlier.last].nextDown)
        if moves == 0 || moves == 2 { orderly += 1 }
        if moves == 2 { reasserted += 1 }
    }
    guard Double(orderly) >= Double(bursts.count - 1) * requiredBurstFraction else { return nil }

    let before = line.edgesThrough(clock.times[bursts[0].first])
    let after = line.times.count - line.edgesThrough(clock.times[bursts[bursts.count - 1].last].nextDown)
    // It has to be seen framing something: let go between transfers, or around the only one.
    guard reasserted > 0 || (before == 1 && after == 1) else { return nil }

    var spent = [0.0, 0.0]
    spent[line.summary.initialLevel] += line.leadIn
    for index in 0..<(line.times.count - 1) {
        spent[line.level(afterEdges: index + 1)] += line.times[index + 1] - line.times[index]
    }
    spent[line.level(afterEdges: line.times.count)] += line.tailOut
    let clocked = bursts.reduce(0.0) { $0 + clock.times[$1.last] - clock.times[$1.first] }
    let slack = spent[active] - clocked
    guard spent[1 - active] > slack else { return nil }
    return EnableLine(line: line, active: active, slack: slack)
}

/// How far ahead of a clock edge a data edge may land and still be put down to it. A
/// peripheral moves data within nanoseconds of the clock, so sampling can order them
/// either way.
private let clockTieFraction = 0.025

private struct DataFit {
    /// Edges following a clock edge away from rest, and back to it.
    var leading = 0
    var trailing = 0
    /// Edges that change a bit inside a byte. Data has them. A line that only ever moves
    /// between bytes, as chip select and D/C do, has none.
    var midByte = 0
}

/// How much of a clock period the delay from clock edge to data edge may vary by, leaving
/// out the tenth at each extreme. The clock causes the data to move, so the delay is steady.
/// Chance can put unrelated edges on one side of a clock, but not at one delay. The first
/// bit of a byte is left out: after a pause between bytes it is set whenever the next byte
/// starts, which has nothing to do with the clock edge before it.
private let steadyDelayFraction = 0.25

/// Counts how a channel's edges sit against the clock, if it changes in step with it:
/// during bursts, after the same clock edge each time, by the same delay, and no more than
/// once per clock edge.
private func dataFit(
    _ data: IdentifiableChannel,
    clock: IdentifiableChannel,
    timing: RegularClock,
    enable: EnableLine? = nil
) -> DataFit? {
    let bursts = timing.bursts
    let period = timing.period
    let resting = clock.restingLevel
    var clockEdges = 0
    var burstIndex = 0
    var counted = 0
    var inStep = 0
    var fit = DataFit()
    // Which bit each edge sets up, by the pulse that will carry it, for each way round, and
    // how long after the clock edge it moved.
    var afterLeading: [(bit: Int, delay: Double)] = []
    var afterTrailing: [(bit: Int, delay: Double)] = []
    var setUp: [Int] = []
    var lastClockEdge = -1

    for time in data.times {
        while burstIndex < bursts.count - 1, clock.times[bursts[burstIndex].last] + period < time { burstIndex += 1 }
        let burst = bursts[burstIndex]

        while clockEdges < clock.times.count, clock.times[clockEdges] <= time + period * clockTieFraction { clockEdges += 1 }
        let followsClock = clockEdges > burst.first && time - clock.times[clockEdges - 1] <= period / 2
        // Ahead of the burst's first clock edge, or of the first after a pause between bytes.
        let setsUp = !followsClock && clockEdges <= burst.last && clock.times[clockEdges] - time <= period

        guard followsClock || setsUp else {
            // A line driven only while enabled moves when the enable does, and may rest
            // anywhere in between. That is the bus turning round, not a misfit.
            if let enable, enable.line.level(afterEdges: enable.line.edgesThrough(time)) == enable.active
                || enable.line.times.contains(where: { abs($0 - time) <= period })
            {
                continue
            }
            counted += 1
            continue
        }
        counted += 1
        // Data changes once per clock edge at most. A flurry of edges between two clock
        // edges is something else going on at the same time.
        let clockEdge = followsClock ? clockEdges - 1 : clockEdges
        guard clockEdge != lastClockEdge else { continue }
        lastClockEdge = clockEdge
        inStep += 1
        // A first burst the window cut has lost its place in the byte.
        let placed = !burst.isCut || burstIndex > 0
        guard followsClock else {
            if placed { setUp.append((clockEdges - burst.first) / 2) }
            continue
        }

        let pulse = (clockEdges - 1 - burst.first) / 2
        let delay = time - clock.times[clockEdges - 1]
        if clock.level(afterEdges: clockEdges) != resting {
            fit.leading += 1
            if placed { afterLeading.append((pulse, delay)) }
        } else {
            fit.trailing += 1
            if placed { afterTrailing.append((pulse + 1, delay)) }
        }
    }

    guard inStep > 0, Double(inStep) >= Double(counted) * requiredEdgeFraction else { return nil }
    let phased = fit.leading + fit.trailing
    guard Double(max(fit.leading, fit.trailing)) >= Double(phased) * requiredEdgeFraction else { return nil }
    let edges = fit.leading > fit.trailing ? afterLeading : afterTrailing
    let midByte = edges.filter { !$0.bit.isMultiple(of: 8) }
    fit.midByte = midByte.count + (fit.leading > fit.trailing ? 0 : setUp.count { !$0.isMultiple(of: 8) })
    let delays = midByte.map(\.delay).sorted()
    if let last = delays.indices.last {
        guard delays[last * 9 / 10] - delays[last / 10] <= period * steadyDelayFraction else { return nil }
    }
    return fit
}

/// The channel whose clock this line keeps step with, if any: one that ticks once per bit
/// of it, with the line's edges a steady delay behind its.
private func clockKeeping(
    _ line: IdentifiableChannel,
    among channels: [IdentifiableChannel],
    regular: [UInt32: RegularClock]
) -> UInt32? {
    let widths = zip(line.times, line.times.dropFirst()).map { $1 - $0 }
    guard let bit = shortestRepeatedWidth(widths) else { return nil }
    return channels.first { clock in
        guard clock.channel != line.channel, let timing = regular[clock.channel],
            abs(bit - timing.period) <= timing.period * 0.3,
            let fit = dataFit(line, clock: clock, timing: timing)
        else { return false }
        return fit.leading + fit.trailing >= 4
    }?.channel
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
    var multiBitPulses = 0
    var pulses: [(bits: Double, seconds: Double)] = []

    for (index, width) in widths.enumerated() {
        let run = width / estimate
        let whole = run.rounded()
        let isWholeBits = whole >= 1 && abs(run - whole) <= bitTolerance

        // Time at the idle level may be a pause between frames, and a pause can be any
        // length. Only time away from idle has to be a whole number of bits.
        if candidate.level(afterEdges: index + 1) == resting { continue }

        guard whole <= longestActiveBits else { return nil }
        considered += 1
        guard isWholeBits else { continue }
        if whole >= 2 { multiBitPulses += 1 }
        fitting += 1
        bits += whole
        seconds += width
        pulses.append((whole, width))
    }

    // Real data has plenty of runs of equal bits: nearly half its pulses. A bare clock has
    // none but the odd one an interrupt stretched, which was 1 in 65 on a recorded burst.
    guard multiBitPulses >= 2, multiBitPulses * 20 >= considered,
        Double(fitting) >= Double(considered) * requiredEdgeFraction
    else { return nil }
    let bitSeconds = fittedBitTime(pulses, roughly: seconds / bits)
    return UARTMatch(
        baud: snappedBaud(1 / bitSeconds), bitSeconds: bitSeconds, inverted: resting == 0, edges: times.count)
}

/// The bit time as the slope of pulse width against bit count: the median, over pairs of
/// pulses with different bit counts, of width difference over bit difference. Skew that an
/// edge slow one way adds to every pulse alike cancels in the difference: 36 ns on the
/// recorded bit-banged capture, where dividing total width by total bits read 921600 baud
/// as 903578. A median is not pulled far by the few pulses a cache miss or an interrupt
/// stretched, where a least squares line was. If the slope lands far from the plain ratio
/// the pulses do not lie on a line at all, and the ratio stands.
private func fittedBitTime(_ pulses: [(bits: Double, seconds: Double)], roughly ratio: Double) -> Double {
    // Pairs grow as the square, and 100 pulses settle the median to a sample or so.
    let stride = max(1, pulses.count / 100)
    let sample = Swift.stride(from: 0, to: pulses.count, by: stride).map { pulses[$0] }
    var slopes: [Double] = []
    slopes.reserveCapacity(sample.count * sample.count / 2)
    for (index, first) in sample.enumerated() {
        for second in sample[(index + 1)...] where second.bits != first.bits {
            slopes.append((second.seconds - first.seconds) / (second.bits - first.bits))
        }
    }
    guard !slopes.isEmpty else { return ratio }
    let slope = slopes.sorted()[(slopes.count - 1) / 2]
    return abs(slope - ratio) <= ratio * 0.25 ? slope : ratio
}

/// Moves a rough bit time toward the one that best explains every pulse, since the
/// shortest pulses alone come out short when edges jitter. Each round puts pulses that
/// were a bit short of a whole number back where they belong, which moves the estimate
/// on. A recorded inverted 921600 signal with a quarter bit of jitter needed five rounds.
private func refinedBitTime(_ rough: Double, active: [Double]) -> Double {
    var estimate = rough
    for _ in 0..<12 {
        let bits = active.reduce(0.0) { $0 + max(1, ($1 / estimate).rounded()) }
        guard bits > 0 else { break }
        let next = active.reduce(0, +) / bits
        defer { estimate = next }
        if abs(next - estimate) <= estimate * 0.001 { break }
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
    return abs(Double(nearest) - measured) <= Double(nearest) * 0.02 ? nearest : Int64(measured.rounded())
}
