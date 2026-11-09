import Foundation
import Testing
@testable import sal

// Signals shaped the way real boards make them, which the recorded test source does not:
// transfers the capture window cuts, paused bytes, lines that share a bus, slow edges.
// Each of these was identified wrongly once.

/// A line built by setting levels in time order.
private struct Line {
    var initial: Int
    var level: Int
    var times: [Double] = []

    init(_ initial: Int) {
        self.initial = initial
        level = initial
    }

    mutating func set(_ value: Int, at time: Double) {
        guard value != level else { return }
        precondition(times.last.map { time > $0 } ?? true, "edges out of order at \(time)")
        times.append(time)
        level = value
    }

    mutating func toggle(at time: Double) { set(1 - level, at: time) }

    /// The same line seen through a capture window.
    func cut(from: Double, to: Double) -> Line {
        let before = times.count { $0 < from }
        var copy = Line(before % 2 == 0 ? initial : 1 - initial)
        copy.times = times.filter { $0 >= from && $0 <= to }
        return copy
    }
}

/// A channel in a capture that ran from `begin` to `end`. By default that is a tenth of a
/// second either side of the edges, which start at 1 s.
private func channel(_ number: UInt32, _ line: Line, begin: Double = 0.9, end: Double? = nil) throws -> IdentifiableChannel {
    let end = end ?? ((line.times.last ?? begin) + 0.1)
    let digital = try parse(digitalFile(initial: Int32(line.initial), begin: begin, end: end, times: line.times))
    return IdentifiableChannel(
        summary: summarize(digital, channel: number), times: line.times, beginTime: begin, endTime: end)
}

private struct SPI {
    var transactions = 6
    var bytes: [UInt8] = [0xA5, 0x5A, 0x12, 0x34]
    var misoBytes: [UInt8] = [0x3C, 0xA6, 0x71, 0x0F]
    var half = 1e-6
    var cpha = false
    /// From enable asserting to the first clock edge, and from the last to it releasing.
    var csSetup: Double?
    var csHold: Double?
    /// Extra idle time between bytes of one transfer.
    var byteGap = 0.0
    var idle = 400e-6
    var bits = 8
    /// For CPHA 0, when data changes relative to the coming leading edge.
    var dataAt: Double?
    /// MISO is driven only while enabled and pulled high otherwise.
    var misoReleased = false
    /// Varies the time between transfers, as real traffic does. Nothing then looks periodic.
    var jitterSeed: UInt64?

    struct Waves {
        var clock = Line(0)
        var mosi = Line(0)
        var miso: Line
        var cs = Line(1)
        /// First and last clock edge of each transfer.
        var spans: [(start: Double, end: Double)] = []
        var asserts: [(assert: Double, release: Double)] = []
    }

    func waves() -> Waves {
        var out = Waves(miso: Line(misoReleased ? 1 : 0))
        var generator = SplitMix64(state: jitterSeed ?? 0)
        var now = 1.0
        for _ in 0..<transactions {
            let asserted = now
            out.cs.set(0, at: now)
            if misoReleased { out.miso.set(0, at: now + 20e-9) }
            now += csSetup ?? half
            let first = now
            var lastEdge = now
            for index in bytes.indices {
                let word = UInt32(bytes[index]) << 8 | UInt32(bytes[index])
                let reply = UInt32(misoBytes[index % misoBytes.count]) << 8 | UInt32(misoBytes[index % misoBytes.count])
                for bit in (0..<bits).reversed() {
                    let level = Int((word >> UInt32(bit)) & 1)
                    let replyLevel = Int((reply >> UInt32(bit)) & 1)
                    if !cpha {
                        out.mosi.set(level, at: now + (dataAt ?? -half / 4))
                        out.miso.set(replyLevel, at: now + (dataAt ?? -half / 4))
                    }
                    out.clock.toggle(at: now)
                    if cpha {
                        out.mosi.set(level, at: now + half / 10)
                        out.miso.set(replyLevel, at: now + half / 10)
                    }
                    out.clock.toggle(at: now + half)
                    lastEdge = now + half
                    now += half * 2
                }
                if index < bytes.count - 1 { now += byteGap }
            }
            let release = lastEdge + (csHold ?? half)
            out.cs.set(1, at: release)
            if misoReleased { out.miso.set(1, at: release + 20e-9) }
            out.spans.append((first, lastEdge))
            out.asserts.append((asserted, release))
            now = release + idle * (jitterSeed == nil ? 1 : Double.random(in: 0.5...1.5, using: &generator))
        }
        return out
    }
}

private struct I2CBus {
    var sda = Line(1)
    var scl = Line(1)
    var spans: [(start: Double, end: Double)] = []
}

/// `hold` is how long after SCL falls SDA changes. Zero puts both edges in one sample.
private func i2c(transactions: Int, bytes: [UInt8] = [0x84, 0xDE, 0xAD], half: Double = 5e-6, hold: Double) -> I2CBus {
    var out = I2CBus()
    var now = 1.0
    for _ in 0..<transactions {
        let started = now
        out.sda.set(0, at: now)
        now += half
        out.scl.set(0, at: now)
        for byte in bytes {
            for bit in (0..<8).reversed().map({ Int((byte >> $0) & 1) }) + [0] {
                out.sda.set(bit, at: now + hold)
                out.scl.set(1, at: now + half)
                out.scl.set(0, at: now + 2 * half)
                now += 2 * half
            }
        }
        out.sda.set(0, at: now + hold)
        out.scl.set(1, at: now + half)
        out.sda.set(1, at: now + half + half / 2)
        out.spans.append((started, now + half + half / 2))
        now += half * 2 + 200e-6
    }
    return out
}

private func addUART(_ line: inout Line, _ bytes: [UInt8], bit: Double, gapBits: Double = 0, start: Double) {
    var now = start
    for byte in bytes {
        for level in [0] + (0..<8).map({ Int((byte >> $0) & 1) }) + [1] {
            line.set(level, at: now)
            now += bit
        }
        now += gapBits * bit
    }
}

private func uart(_ bytes: [UInt8], bit: Double, gapBits: Double = 0) -> Line {
    var line = Line(1)
    addUART(&line, bytes, bit: bit, gapBits: gapBits, start: 1.0)
    return line
}

private let text = Array("The quick brown fox!".utf8)

private func spiDecoders(_ result: ChannelIdentification) -> [SPIDecoder] {
    result.buses.compactMap { if case .spi(let spi) = $0.decoder { spi } else { nil } }
}

private func uartDecoders(_ result: ChannelIdentification) -> [UARTDecoder] {
    result.buses.compactMap { if case .uart(let uart) = $0.decoder { uart } else { nil } }
}

@Suite("Identification and the capture window")
struct IdentificationWindowTests {
    @Test("One SPI transfer in the capture is found, though its clock is perfectly regular")
    func oneTransfer() throws {
        let waves = SPI(transactions: 1).waves()
        let result = identifyChannels([try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, waves.cs)])
        #expect(result.buses.map(\.decoder) == [.spi(SPIDecoder(clock: 0, mosi: 1, enable: 2))])
        #expect(result.buses[0].confidence == .uncertain)
        #expect(result.buses[0].evidence == "1 clock burst in multiples of 8, data in step")
        #expect(result.periodic.isEmpty && result.unknown.isEmpty)
    }

    @Test("Transfers the window cuts at either end do not count against the rest", arguments: [(6, true), (4, false), (3, true)])
    func cutTransfers(transactions: Int, cutLast: Bool) throws {
        let waves = SPI(transactions: transactions).waves()
        let from = waves.spans[0].start + 0.3 * (waves.spans[0].end - waves.spans[0].start) + 1e-8
        let last = waves.spans[transactions - 1]
        let to = cutLast ? last.start + 0.3 * (last.end - last.start) + 1e-8 : last.end + 100e-6
        let result = identifyChannels([
            try channel(0, waves.clock.cut(from: from, to: to), begin: from, end: to),
            try channel(1, waves.mosi.cut(from: from, to: to), begin: from, end: to),
            try channel(2, waves.cs.cut(from: from, to: to), begin: from, end: to),
        ])
        #expect(result.buses.map(\.decoder) == [.spi(SPIDecoder(clock: 0, mosi: 1, enable: 2))])
        let whole = transactions - (cutLast ? 2 : 1)
        #expect(result.buses[0].evidence == "\(whole) clock \(whole == 1 ? "burst" : "bursts") in multiples of 8, data in step")
    }

    @Test("A capture inside one long transfer cannot be framed, and says its data is clocked")
    func insideOneTransfer() throws {
        let waves = SPI(transactions: 1, bytes: Array(repeating: text, count: 10).flatMap { $0 }).waves()
        let span = waves.spans[0]
        let from = span.start + 0.2 * (span.end - span.start) + 1e-8
        let to = span.start + 0.8 * (span.end - span.start) + 1e-8
        let result = identifyChannels([
            try channel(0, waves.clock.cut(from: from, to: to), begin: from, end: to),
            try channel(1, waves.mosi.cut(from: from, to: to), begin: from, end: to),
            try channel(2, waves.cs.cut(from: from, to: to), begin: from, end: to),
        ])
        #expect(result.buses.isEmpty)
        #expect(result.periodic.map(\.channel) == [0])
        #expect(result.unknown == [1])
        #expect(result.notes.contains("CH1 changes in step with the clock on CH0, so it is clocked data, not UART."))
    }

    @Test("A UART's idle level is read from the quiet after its last edge")
    func idleAfterLastEdge() throws {
        let bit = 1 / 115_200.0
        let stream = uart(text + text + text, bit: bit)
        // The capture opens inside a start bit, so the line begins low.
        let from = 1.0 + 50 * bit + 0.5 * bit
        let to = stream.times.last! + 0.05
        let cut = stream.cut(from: from, to: to)
        #expect(cut.initial == 0)
        let found = uartDecoders(identifyChannels([try channel(2, cut, begin: from, end: to)]))
        #expect(found == [UARTDecoder(channel: 2, baud: 115_200)])
    }

    @Test("And from the quiet before its first, when the capture ends inside a frame")
    func idleBeforeFirstEdge() throws {
        let bit = 1 / 115_200.0
        let stream = uart(text + text + text, bit: bit)
        // Ends inside the start bit of the last frame, so the line ends low.
        let to = 1.0 + 590 * bit + 0.5 * bit
        let cut = stream.cut(from: 0.9, to: to)
        #expect(cut.times.count % 2 == 1)
        let found = uartDecoders(identifyChannels([try channel(2, cut, begin: 0.9, end: to)]))
        #expect(found == [UARTDecoder(channel: 2, baud: 115_200)])
    }

    @Test("Quiet shorter than a frame says nothing about the idle level")
    func shortQuiet() throws {
        let bit = 1 / 115_200.0
        let stream = uart(text + text + text, bit: bit)
        let from = 1.0 + 50 * bit + 0.5 * bit
        let to = stream.times.last! + 5 * bit
        let found = uartDecoders(identifyChannels([try channel(2, stream.cut(from: from, to: to), begin: from, end: to)]))
        // Nothing shows which level is idle, so the level the capture began at stands.
        #expect(found.map(\.inverted) == [true])
    }

    @Test("Five I2C transactions with the first and last cut are three, not three of five")
    func cutI2C() throws {
        let bus = i2c(transactions: 5, hold: 1e-6)
        let from = (bus.spans[0].start + bus.spans[0].end) / 2 + 1e-8
        let to = (bus.spans[4].start + bus.spans[4].end) / 2 + 1e-8
        let result = identifyChannels([
            try channel(0, bus.sda.cut(from: from, to: to), begin: from, end: to),
            try channel(1, bus.scl.cut(from: from, to: to), begin: from, end: to),
        ])
        #expect(result.buses.map(\.decoder) == [.i2c(I2CDecoder(sda: 0, scl: 1))])
        #expect(result.buses[0].evidence == "3 transactions of whole 9-clock bytes")
    }
}

@Suite("SPI lines told apart")
struct SPILineTests {
    @Test("Enable is found when bytes of one transfer are paused apart")
    func pausedBytes() throws {
        let waves = SPI(byteGap: 10e-6, jitterSeed: 3).waves()
        let result = identifyChannels([try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, waves.cs)])
        #expect(result.buses.map(\.decoder) == [.spi(SPIDecoder(clock: 0, mosi: 1, enable: 2))])
        #expect(result.buses[0].evidence == "24 clock bursts in multiples of 8, data in step")
        #expect(result.unknown.isEmpty)
    }

    @Test("Bytes paused by a clock period or so are still one clock", arguments: [0.5e-6, 1.5e-6, 2.5e-6, 3.5e-6])
    func shortPauses(pause: Double) throws {
        // Up to three half periods of pause the clock stays in one burst, with one period in
        // eight stretched. Past that each byte is a burst of its own.
        let waves = SPI(byteGap: pause, jitterSeed: 3).waves()
        let result = identifyChannels([try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, waves.cs)])
        #expect(result.buses.map(\.decoder) == [.spi(SPIDecoder(clock: 0, mosi: 1, enable: 2))])
        let bursts = pause > 3e-6 ? 24 : 6
        #expect(result.buses[0].evidence == "\(bursts) clock bursts in multiples of 8, data in step")
        #expect(result.notes.isEmpty && result.unknown.isEmpty)
    }

    @Test("Data set up after a pause is not held to the delay of the other bits", arguments: [0.5e-6, 1.5e-6])
    func pausedDataDelay(pause: Double) throws {
        // Mode 0 data moves 50 ns after the trailing edge, except the first bit of each byte,
        // which waits out the pause. Both lines carry data.
        let waves = SPI(byteGap: pause, dataAt: -(1e-6 - 50e-9), jitterSeed: 3).waves()
        let result = identifyChannels([
            try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, waves.cs), try channel(3, waves.miso),
        ])
        #expect(result.buses.map(\.decoder) == [.spi(SPIDecoder(clock: 0, mosi: 1, miso: 3, enable: 2))])
    }

    @Test("A flurry of edges inside one clock cycle is not data")
    func flurryInsideTransfer() throws {
        let waves = SPI(half: 50e-6).waves()
        var decoy = Line(0)
        for span in waves.spans {
            // Ten edges in 20 us, all after the same clock edge.
            for index in 0..<10 { decoy.toggle(at: span.start + 300e-6 + Double(index) * 2e-6) }
        }
        let result = identifyChannels([
            try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, waves.cs), try channel(3, decoy),
        ])
        #expect(result.buses.map(\.decoder) == [.spi(SPIDecoder(clock: 0, mosi: 1, enable: 2))])
    }

    @Test("Clock periods up to 40% long are regular, and 45% long are not", arguments: [(1.6, true), (1.9, false)])
    func stretchedPeriods(stretch: Double, isClock: Bool) throws {
        // Every third low half period is stretched, which lengthens the two periods that
        // span it: a third of all periods, at 1.3 or 1.45 times the rest.
        let half = 1e-6
        var clock = Line(0), mosi = Line(0), cs = Line(1)
        var now = 1.0
        for transfer in 0..<6 {
            cs.set(0, at: now)
            now += half
            for bit in 0..<32 {
                clock.set(1, at: now)
                clock.set(0, at: now + half)
                mosi.set((bit * 7 + transfer) % 3 == 0 ? 1 : 0, at: now + half + 50e-9)
                now += half + half * (bit % 3 == 2 ? stretch : 1)
            }
            cs.set(1, at: now)
            now += 400e-6
        }
        let found = spiDecoders(identifyChannels([try channel(0, clock), try channel(1, mosi), try channel(2, cs)]))
        #expect(found.isEmpty != isClock)
    }

    @Test("Enable is found however long before the clock it is asserted")
    func earlyEnable() throws {
        let waves = SPI(bytes: [0xA5], csSetup: 40e-6, csHold: 40e-6, jitterSeed: 3).waves()
        let result = identifyChannels([try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, waves.cs)])
        #expect(result.buses.map(\.decoder) == [.spi(SPIDecoder(clock: 0, mosi: 1, enable: 2))])
    }

    @Test("A UART that logs before and after each transfer is not the enable", arguments: [
        (UInt32(0), UInt32(3)), (UInt32(3), UInt32(0)),
    ])
    func uartAroundTransfers(logChannel: UInt32, enableChannel: UInt32) throws {
        let waves = SPI(half: 50e-6, idle: 20e-3).waves()
        var log = Line(1)
        for pair in waves.asserts {
            addUART(&log, Array("rd\n".utf8), bit: 1 / 115_200.0, start: pair.assert - 600e-6)
            addUART(&log, Array("ok\n".utf8), bit: 1 / 115_200.0, start: pair.release + 200e-6)
        }
        let result = identifyChannels([
            try channel(logChannel, log), try channel(1, waves.clock), try channel(2, waves.mosi),
            try channel(enableChannel, waves.cs),
        ])
        #expect(spiDecoders(result) == [SPIDecoder(clock: 1, mosi: 2, enable: enableChannel)])
        #expect(uartDecoders(result) == [UARTDecoder(channel: logChannel, baud: 115_200)])
    }

    @Test("Of two lines that frame the only transfer, the tighter is the enable")
    func tighterEnable() throws {
        let waves = SPI(transactions: 1).waves()
        var power = Line(1)
        power.set(0, at: waves.asserts[0].assert - 5e-3)
        power.set(1, at: waves.asserts[0].release + 5e-3)
        let result = identifyChannels([
            try channel(0, power), try channel(1, waves.clock), try channel(2, waves.mosi), try channel(3, waves.cs),
        ])
        #expect(spiDecoders(result).map(\.enable) == [3])
    }

    @Test("With several transfers, the line that is let go between them is the enable")
    func mostEdgesWins() throws {
        let waves = SPI(jitterSeed: 3).waves()
        // Asserted once round everything, and nearer the first transfer than the real enable.
        var power = Line(1)
        power.set(0, at: waves.asserts[0].assert + 0.2e-6)
        power.set(1, at: waves.asserts[5].release + 5e-3)
        let result = identifyChannels([
            try channel(0, power), try channel(1, waves.clock), try channel(2, waves.mosi), try channel(3, waves.cs),
        ])
        #expect(spiDecoders(result).map(\.enable) == [3])
    }

    @Test("A line that moves inside every burst is not the enable, though it frames them too")
    func movesInsideBursts() throws {
        let waves = SPI(jitterSeed: 3).waves()
        var glitchy = Line(1)
        for (pair, span) in zip(waves.asserts, waves.spans) {
            glitchy.set(0, at: pair.assert)
            glitchy.set(1, at: span.start + 20.3e-6)
            glitchy.set(0, at: span.start + 20.6e-6)
            glitchy.set(1, at: pair.release)
        }
        let result = identifyChannels([try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, glitchy)])
        #expect(spiDecoders(result).map(\.enable) == [nil])
    }

    @Test("A line that frames only the first half of the transfers is not the enable")
    func framesHalf() throws {
        let waves = SPI(transactions: 10, jitterSeed: 3).waves()
        var partial = Line(1)
        for pair in waves.asserts.prefix(5) {
            partial.set(0, at: pair.assert)
            partial.set(1, at: pair.release)
        }
        let result = identifyChannels([try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, partial)])
        #expect(spiDecoders(result).map(\.enable) == [nil])
    }

    @Test("An enable that also moved before any clock is still the enable")
    func enableWithEarlierActivity() throws {
        let waves = SPI(jitterSeed: 3).waves()
        var cs = Line(1)
        cs.set(0, at: 0.95)
        cs.set(1, at: 0.96)
        for pair in waves.asserts {
            cs.set(0, at: pair.assert)
            cs.set(1, at: pair.release)
        }
        let result = identifyChannels([try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, cs)])
        #expect(spiDecoders(result).map(\.enable) == [2])
    }

    @Test("A line that pulses once between transfers is not the enable", arguments: [true, false])
    func pulseBetweenTransfers(withRealEnable: Bool) throws {
        let waves = SPI(jitterSeed: 3).waves()
        // Idle low, like the enable while asserted, with a blip high after each transfer.
        var pulse = Line(0)
        for pair in waves.asserts {
            pulse.set(1, at: pair.release + 100e-6)
            pulse.set(0, at: pair.release + 120e-6)
        }
        var channels = [try channel(0, pulse), try channel(1, waves.clock), try channel(2, waves.mosi)]
        if withRealEnable { channels.append(try channel(3, waves.cs)) }
        let result = identifyChannels(channels)
        #expect(spiDecoders(result).map(\.enable) == [withRealEnable ? 3 : nil])
    }

    @Test("A line with one edge is not an enable")
    func oneEdgeIsNotEnable() throws {
        let waves = SPI(jitterSeed: 3).waves()
        var slow = Line(1)
        slow.set(0, at: waves.asserts[0].assert - 1e-3)
        // The capture ends soon after the transfers, so the line is low for less time than it was
        // high. Only its never being released says it is not the enable.
        let end = waves.asserts[5].release + 1e-3
        let result = identifyChannels([
            try channel(0, waves.clock, end: end), try channel(1, waves.mosi, end: end), try channel(2, slow, end: end),
        ])
        #expect(spiDecoders(result) == [SPIDecoder(clock: 0, mosi: 1)])
    }

    @Test("A chip select that bounces between most transfers is not trusted as the enable")
    func bouncingEnable() throws {
        let waves = SPI(jitterSeed: 3).waves()
        var bouncy = Line(1)
        for (index, pair) in waves.asserts.enumerated() {
            bouncy.set(0, at: pair.assert)
            bouncy.set(1, at: pair.release)
            // Released and taken again in three of the five gaps.
            if index >= 2 && index < 5 {
                bouncy.set(0, at: pair.release + 100e-6)
                bouncy.set(1, at: pair.release + 110e-6)
            }
        }
        let result = identifyChannels([try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, bouncy)])
        #expect(spiDecoders(result).map(\.enable) == [nil])
    }

    @Test("Long transfers with short gaps still have their enable")
    func longTransfersShortGaps() throws {
        // 64 us of clock, 50 us of gap, and a window tight around them: the enable is asserted
        // for longer than it is released, but with the clock running almost all of that time.
        let waves = SPI(idle: 50e-6, jitterSeed: 3).waves()
        let begin = waves.asserts[0].assert - 10e-6
        let end = waves.asserts[5].release + 10e-6
        let result = identifyChannels([
            try channel(0, waves.clock, begin: begin, end: end), try channel(1, waves.mosi, begin: begin, end: end),
            try channel(2, waves.cs, begin: begin, end: end),
        ])
        #expect(spiDecoders(result).map(\.enable) == [2])
    }

    @Test("Quiet before the only transfer counts as time the enable was released")
    func quietBeforeOnlyTransfer() throws {
        // Asserted 40 us early and held 40 us after, in a capture that ends 10 us later. Only the
        // tenth of a second before it shows the enable spends most of its time released.
        let waves = SPI(transactions: 1, bytes: [0xA5], csSetup: 40e-6, csHold: 40e-6).waves()
        let end = waves.asserts[0].release + 10e-6
        let result = identifyChannels([
            try channel(0, waves.clock, end: end), try channel(1, waves.mosi, end: end), try channel(2, waves.cs, end: end),
        ])
        #expect(spiDecoders(result).map(\.enable) == [2])
    }

    @Test("A line that moves after every clock edge, both ways, is not data")
    func movesOnBothEdges() throws {
        let waves = SPI(jitterSeed: 3).waves()
        var both = Line(0)
        for time in waves.clock.times { both.toggle(at: time + 50e-9) }
        let result = identifyChannels([
            try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, waves.cs), try channel(3, both),
        ])
        #expect(spiDecoders(result) == [SPIDecoder(clock: 0, mosi: 1, enable: 2)])
    }

    @Test("A line that moves at random inside bursts is not data")
    func randomIsNotData() throws {
        var generator = SplitMix64(state: 99)
        let waves = SPI().waves()
        var random = Line(0)
        for span in waves.spans {
            for time in (0..<6).map({ _ in Double.random(in: span.start...span.end, using: &generator) }).sorted() {
                random.toggle(at: time)
            }
        }
        #expect(spiDecoders(identifyChannels([try channel(0, waves.clock), try channel(1, random)])).isEmpty)
        // Beside real data it is left out, not taken for MISO.
        let both = identifyChannels([try channel(0, waves.clock), try channel(1, random), try channel(2, waves.mosi)])
        #expect(spiDecoders(both) == [SPIDecoder(clock: 0, mosi: 2)])
    }

    @Test("A line that only changes between bytes is a control line, and is said to be")
    func controlLine() throws {
        let waves = SPI(jitterSeed: 3).waves()
        var dc = Line(0)
        for span in waves.spans {
            dc.set(1, at: span.start + 15.5e-6)
            dc.set(0, at: span.end + 0.5e-6)
        }
        let result = identifyChannels([
            try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, waves.cs), try channel(3, dc),
        ])
        #expect(result.buses.map(\.decoder) == [.spi(SPIDecoder(clock: 0, mosi: 1, enable: 2))])
        #expect(result.buses[0].notes.contains("CH3 only changes between bytes, so it is probably a control line such as D/C, not data."))
        #expect(result.unknown == [3])
    }

    @Test("A control line stays one when the window cuts the first transfer and its place in the byte is lost")
    func controlLineThroughCut() throws {
        let waves = SPI(jitterSeed: 3).waves()
        var dc = Line(0)
        for span in waves.spans {
            dc.set(1, at: span.start + 15.5e-6)
            dc.set(0, at: span.end + 0.5e-6)
        }
        // Opens 21 clocks into the first transfer, which is not a whole number of bytes.
        let from = waves.spans[0].start + 42.4e-6
        let to = waves.asserts[5].release + 100e-6
        let result = identifyChannels([
            try channel(0, waves.clock.cut(from: from, to: to), begin: from, end: to),
            try channel(1, waves.mosi.cut(from: from, to: to), begin: from, end: to),
            try channel(2, waves.cs.cut(from: from, to: to), begin: from, end: to),
            try channel(3, dc.cut(from: from, to: to), begin: from, end: to),
        ])
        #expect(spiDecoders(result) == [SPIDecoder(clock: 0, mosi: 1, enable: 2)])
    }

    @Test("Chip selects of two devices on one clock are control lines, not data")
    func twoChipSelects() throws {
        let waves = SPI(transactions: 8, jitterSeed: 3).waves()
        var first = Line(1), second = Line(1)
        for (index, pair) in waves.asserts.enumerated() {
            if index.isMultiple(of: 2) {
                first.set(0, at: pair.assert)
                first.set(1, at: pair.release)
            } else {
                second.set(0, at: pair.assert)
                second.set(1, at: pair.release)
            }
        }
        let result = identifyChannels([
            try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, first), try channel(3, second),
        ])
        // Neither frames every transfer, so neither is offered as the enable.
        #expect(spiDecoders(result) == [SPIDecoder(clock: 0, mosi: 1)])
        #expect(result.buses[0].notes.count { $0.contains("only changes between bytes") } == 2)
    }

    @Test("MISO that is let go between transfers is still data")
    func releasedMISO() throws {
        let waves = SPI(bytes: [0x5A, 0x3C], csSetup: 5e-6, csHold: 5e-6, misoReleased: true, jitterSeed: 3).waves()
        let result = identifyChannels([
            try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, waves.cs), try channel(3, waves.miso),
        ])
        #expect(result.buses.map(\.decoder) == [.spi(SPIDecoder(clock: 0, mosi: 1, miso: 3, enable: 2))])
    }

    @Test("Data landing a sample ahead of the clock edge that moved it keeps its phase", arguments: [20e-9, 0, -20e-9])
    func dataBesideClockEdge(early: Double) throws {
        // Mode 0. Data moves on the trailing edge, which is one half period before the next leading one.
        let waves = SPI(dataAt: -(1e-6 + early)).waves()
        let result = identifyChannels([try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, waves.cs)])
        #expect(spiDecoders(result) == [SPIDecoder(clock: 0, mosi: 1, enable: 2)])
        #expect(!result.buses[0].notes.contains { $0.contains("phase") })
    }

    @Test("Data that moves well ahead of the next clock edge is not put down to it")
    func dataAheadOfClock() throws {
        // Mode 0 with data set a quarter of a half period before the leading edge, as a
        // bit-banged master may. It still follows the trailing edge before it.
        let mode0 = SPI().waves()
        let found = spiDecoders(identifyChannels([try channel(0, mode0.clock), try channel(1, mode0.mosi), try channel(2, mode0.cs)]))
        #expect(found.map(\.dataOnTrailingEdge) == [false])
    }

    @Test("Data that moves just after the leading edge is mode 1")
    func dataAfterLeadingEdge() throws {
        let mode1 = SPI(cpha: true).waves()
        let found = spiDecoders(identifyChannels([try channel(0, mode1.clock), try channel(1, mode1.mosi), try channel(2, mode1.cs)]))
        #expect(found.map(\.dataOnTrailingEdge) == [true])
    }

    @Test("Words that are not whole bytes are not SPI here, but their data is not UART either")
    func twelveBitWords() throws {
        let waves = SPI(bytes: [0xA5, 0x5A, 0x12], bits: 12, jitterSeed: 3).waves()
        let result = identifyChannels([try channel(0, waves.clock), try channel(1, waves.mosi), try channel(2, waves.cs)])
        #expect(result.buses.isEmpty)
        #expect(result.notes.contains("CH1 changes in step with the clock on CH0, so it is clocked data, not UART."))
    }

    @Test("A UART beside the 4x clock it is made from is still a UART")
    func ownBaudClock() throws {
        let bit = 1 / 115_200.0
        let line = uart(text + text + text, bit: bit)
        // Every UART edge sits just behind a clock edge, but the clock ticks 4 times a bit.
        var clock = Line(0)
        var now = 1.0 - bit / 80
        while now < line.times.last! + bit {
            clock.toggle(at: now)
            now += bit / 8
        }
        let result = identifyChannels([try channel(0, clock), try channel(2, line)])
        #expect(uartDecoders(result) == [UARTDecoder(channel: 2, baud: 115_200)])
    }

    @Test("Frames that each land on one side of a clock, at different delays, are still a UART")
    func sameSideDifferentDelays() throws {
        // The clock ticks once a bit, and every frame starts in its low half, somewhere.
        let bit = 1 / 115_200.0
        var clock = Line(0)
        var now = 1.0
        while now < 1.02 {
            clock.toggle(at: now)
            now += bit / 2
        }
        var line = Line(1)
        var generator = SplitMix64(state: 21)
        for frame in 0..<60 {
            let tick = 1.0 + Double(frame * 16) * bit
            let delay = bit * (0.52 + Double.random(in: 0...0.42, using: &generator))
            addUART(&line, [text[frame % text.count]], bit: bit, start: tick + delay)
        }
        let result = identifyChannels([try channel(0, clock, end: 1.03), try channel(2, line, end: 1.03)])
        #expect(uartDecoders(result) == [UARTDecoder(channel: 2, baud: 115_200)])
    }

    @Test("A UART beside a clock it has nothing to do with is still a UART")
    func unrelatedClock() throws {
        // A clock ticking once per UART bit, as near as makes no difference, and not in step.
        let bit = 1 / 115_200.0
        let line = uart(text + text + text, bit: bit)
        var clock = Line(0)
        var now = 1.0 + bit * 0.37
        while now < line.times.last! {
            clock.toggle(at: now)
            now += bit * 1.03 / 2
        }
        let result = identifyChannels([try channel(0, clock), try channel(2, line)])
        #expect(uartDecoders(result) == [UARTDecoder(channel: 2, baud: 115_200)])
        #expect(result.notes.isEmpty)
    }
}

@Suite("I2C and UART details")
struct BusDetailTests {
    @Test("SDA changing in the same sample as SCL falls is data, not a start or stop")
    func i2cTie() throws {
        let bus = i2c(transactions: 8, hold: 0)
        let result = identifyChannels([try channel(0, bus.sda), try channel(1, bus.scl)])
        #expect(result.buses.map(\.decoder) == [.i2c(I2CDecoder(sda: 0, scl: 1))])
        #expect(result.buses[0].evidence == "8 transactions of whole 9-clock bytes")
    }

    @Test("SDA changing in the same sample as SCL rises is still read as data")
    func i2cTieOnRise() throws {
        // Half a period after SCL falls is exactly where it rises.
        let bus = i2c(transactions: 8, hold: 5e-6)
        let result = identifyChannels([try channel(0, bus.sda), try channel(1, bus.scl)])
        #expect(result.buses.map(\.decoder) == [.i2c(I2CDecoder(sda: 0, scl: 1))])
    }

    @Test("Edges that are slow one way do not change the baud rate", arguments: [0.2e-6, 0.5e-6, 1.0e-6, -0.5e-6])
    func skewedEdges(skew: Double) throws {
        let bit = 1 / 115_200.0
        var line = uart(text + text + text, bit: bit, gapBits: 3)
        for index in line.times.indices where index % 2 == 1 { line.times[index] += skew }
        let result = identifyChannels([try channel(2, line)])
        #expect(uartDecoders(result) == [UARTDecoder(channel: 2, baud: 115_200)])
        #expect(result.buses[0].evidence == "pulse widths are multiples of 8.681 us")
    }

    @Test("A recorded inverted 921600 UART whose bit time takes five rounds to settle is found")
    func recordedInvertedFast() throws {
        // Three rounds of refinement left the bit time at 1.027 us, where only 83% of pulses
        // were whole bits. It settles at 1.097 us, where 99% are. A least squares line through
        // these pulses read 891353 baud, because the long pulses run long; the median slope does not.
        let directory = fixtureDirectory.deletingLastPathComponent().appendingPathComponent("fast-inverted")
        let result = identifyChannels(try loadChannels(directory: directory, channels: [2]))
        #expect(describe(result).prefix(2) == [
            "UART  signal=2  likely: pulse widths are multiples of 1.100 us", "  sal decode uart --channel 2 --baud 921600 --inverted",
        ])
    }

    @Test("The recorded bit-banged UART reads as 921600 once its 36 ns of skew is fitted out")
    func recordedSkew() throws {
        let directory = fixtureDirectory.deletingLastPathComponent().appendingPathComponent("fast")
        let result = identifyChannels(try loadChannels(directory: directory, channels: [2]))
        #expect(uartDecoders(result) == [UARTDecoder(channel: 2, baud: 921_600)])
        // Total width over total bits gave 1.107 us, 2% slow and on the edge of not snapping.
        #expect(result.buses[0].evidence == "pulse widths are multiples of 1.090 us")
    }

    @Test("A fit more than a quarter away from the plain ratio is not believed", arguments: [
        // Two-bit pulses 2.45 times the one-bit ones: the line's slope is 26% above the ratio.
        (2.45, 1 / 1.15e-4),
        // At 2.4 times it is 23.5% above, and the slope stands.
        (2.4, 1 / 1.4e-4),
    ])
    func fitFarFromRatio(longer: Double, baud: Double) throws {
        let short = 1e-4
        var line = Line(1)
        var now = 1.0
        for _ in 0..<30 {
            for width in [short, short * longer] {
                line.set(0, at: now)
                line.set(1, at: now + width)
                now += 6 * short
            }
        }
        let found = uartDecoders(identifyChannels([try channel(2, line)]))
        #expect(found.count == 1)
        #expect(abs(Double(found.first?.baud ?? 0) - baud) <= 2)
    }

    @Test("A clock burst with pulses an interrupt stretched is not a UART", arguments: [1, 3])
    func stretchedClock(stretched: Int) throws {
        // 65 pulses, as recorded: 64 of 4.9 us and one of 10.
        var line = Line(0)
        var now = 1.0
        for burst in 0..<5 {
            for pulse in 0..<13 {
                let high = burst < stretched && pulse == 6 ? 10.0e-6 : 4.9e-6
                line.set(1, at: now)
                line.set(0, at: now + high)
                now += high + 4.9e-6
            }
            now += 69e-3
        }
        #expect(identifyChannels([try channel(2, line)]).buses.isEmpty)
    }

    @Test("Two pulses of two bits, and one in twenty, make data. Fewer do not", arguments: [
        (40, 2, true), (41, 2, false), (10, 2, true), (10, 1, false),
    ])
    func multiBitShare(pulses: Int, doubles: Int, isUART: Bool) throws {
        let bit = 1e-4
        var line = Line(1)
        var now = 1.0
        for pulse in 0..<pulses {
            let width = pulse % (pulses / doubles) == 3 ? 2.0 : 1.0
            line.set(0, at: now)
            line.set(1, at: now + width * bit)
            now += 5 * bit
        }
        #expect(!uartDecoders(identifyChannels([try channel(2, line)])).isEmpty == isUART)
    }
}
