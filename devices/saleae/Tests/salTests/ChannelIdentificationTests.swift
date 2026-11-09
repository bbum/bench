import Foundation
import Synchronization
import Testing
@testable import sal

private func channel(_ number: UInt32, initial: Int32, _ times: [Double]) throws -> IdentifiableChannel {
    IdentifiableChannel(
        summary: summarize(try parse(digitalFile(initial: initial, times: times)), channel: number), times: times)
}

/// Serial frames at `bit` seconds, resting high unless inverted.
private func uartTimes(_ bytes: [UInt8], bit: Double, parity: Parity = .none, gap: Double = 0) -> [Double] {
    var levels: [Int] = []
    for byte in bytes {
        var frame = [0] + (0..<8).map { Int((byte >> $0) & 1) }
        if parity != .none { frame.append((frame.dropFirst().reduce(0, +) + (parity == .odd ? 1 : 0)) % 2) }
        levels += frame + [1, 1]
    }
    var times: [Double] = []
    var now = 1.0
    var level = 1
    for sample in levels {
        if sample != level {
            times.append(now)
            level = sample
        }
        now += bit
    }
    return times
}

private let text = Array("The quick brown fox!".utf8)

private struct SPIWaves {
    var clock: [Double] = []
    var data: [Double] = []
    var enable: [Double] = []
}

private func spiWaves(
    frames: Int, bytes: [UInt8] = [0xA5, 0x5A, 0x12, 0x34], half: Double = 1e-6, cpol: Bool = false,
    cpha: Bool = false
) -> SPIWaves {
    var waves = SPIWaves()
    var now = 1.0
    var dataLevel = 0
    func set(_ level: Int, at time: Double) {
        if level != dataLevel {
            waves.data.append(time)
            dataLevel = level
        }
    }
    for _ in 0..<frames {
        waves.enable.append(now)
        now += half
        for byte in bytes {
            for bit in (0..<8).reversed() {
                let level = Int((byte >> bit) & 1)
                if !cpha { set(level, at: now - half / 4) }
                waves.clock.append(now)
                if cpha { set(level, at: now + half / 10) }
                waves.clock.append(now + half)
                now += half * 2
            }
        }
        waves.enable.append(now)
        now += half * 200
    }
    _ = cpol
    return waves
}

private struct I2CWaves {
    var sda: [Double] = []
    var scl: [Double] = []
}

/// Each transaction is a start, `bytes` of 9 clocks, then a stop, or a repeated start.
private func i2cWaves(transactions: Int, bytes: [UInt8] = [0x84, 0xDE, 0xAD], repeated: Bool = false, half: Double = 5e-6) -> I2CWaves {
    var waves = I2CWaves()
    var now = 1.0
    var sda = 1
    func set(_ level: Int) {
        if level != sda {
            waves.sda.append(now)
            sda = level
        }
    }
    for transaction in 0..<transactions {
        let repeating = repeated && transaction != transactions - 1
        set(0)
        now += half
        for byte in bytes {
            for bit in Array((0..<8).reversed().map { Int((byte >> $0) & 1) }) + [0] {
                waves.scl.append(now)
                now += half / 2
                set(bit)
                now += half / 2
                waves.scl.append(now)
                now += half
            }
        }
        waves.scl.append(now)
        now += half / 2
        set(repeating ? 1 : 0)
        now += half / 2
        if !repeating {
            waves.scl.append(now)
            now += half
            set(1)
        } else {
            waves.scl.append(now)
            now += half
        }
        now += half * 40
    }
    return waves
}

private func fixture() throws -> [IdentifiableChannel] {
    try loadChannels(directory: fixtureDirectory, channels: Array(0...7))
}

private func permutations(of count: Int) -> [[Int]] {
    var results: [[Int]] = []
    var values = Array(0..<count)
    func generate(_ size: Int) {
        if size <= 1 {
            results.append(values)
            return
        }
        for index in 0..<size {
            generate(size - 1)
            values.swapAt(size.isMultiple(of: 2) ? index : 0, size - 1)
        }
    }
    generate(count)
    return results
}

private func expected(_ wiring: [UInt32]) -> [ProtocolDecoder] {
    [
        .uart(UARTDecoder(channel: wiring[2], baud: 115_200)),
        .spi(SPIDecoder(clock: wiring[3], mosi: wiring[4], enable: wiring[5])),
        .i2c(I2CDecoder(sda: wiring[6], scl: wiring[7])),
    ].sorted { $0.channels[0] < $1.channels[0] }
}

@Suite("Channel identification on recorded traffic")
struct RecordedIdentificationTests {
    @Test("The recorded testgen capture is fully identified")
    func recorded() throws {
        let result = identifyChannels(try fixture())
        #expect(result.buses.map(\.decoder) == expected(Array(0...7)))
        #expect(result.buses.allSatisfy { $0.confidence == .likely })
        #expect(result.periodic.map(\.channel) == [0, 1])
        #expect(result.idle.isEmpty)
        #expect(result.unknown.isEmpty)
    }

    @Test("All 40,320 ways of wiring the 8 channels are identified")
    func everyWiring() throws {
        // Five cycles of traffic: enough to judge, and quick enough for every wiring.
        let recorded = try fixture().map { channel -> IdentifiableChannel in
            let window = channel.times.filter { $0 < 0.12 }
            let timesData = digitalFile(initial: Int32(channel.summary.initialLevel), times: window)
            return IdentifiableChannel(summary: summarize(try parse(timesData), channel: channel.channel), times: window)
        }
        let wirings = permutations(of: 8)
        #expect(wirings.count == 40_320)
        #expect(Set(wirings).count == 40_320)

        let failures = Mutex<[[Int]]>([])
        DispatchQueue.concurrentPerform(iterations: wirings.count) { index in
            let wiring = wirings[index].map { UInt32($0) }
            let relabeled = recorded.enumerated().map { position, channel -> IdentifiableChannel in
                var copy = channel
                copy.summary.channel = wiring[position]
                return copy
            }
            let result = identifyChannels(relabeled)
            let correct =
                result.buses.map(\.decoder) == expected(wiring)
                && Set(result.periodic.map(\.channel)) == Set([wiring[0], wiring[1]])
                && result.unknown.isEmpty
            if !correct { failures.withLock { $0.append(wirings[index]) } }
        }
        #expect(failures.withLock { $0.isEmpty }, "first failures: \(failures.withLock { $0.prefix(3) })")
    }
}

@Suite("Frame alignment")
struct FrameAlignmentTests {
    private func row(_ start: Double, error: Bool = false) -> DecodedRow {
        DecodedRow(type: "data", start: start, duration: 1e-3, fields: error ? ["error": "framing"] : [:])
    }

    @Test("Frames before the first long gap and the last frame are dropped")
    func dropsMisaligned() {
        // 1 kBaud: a frame is at most 13 ms, so only the gap after 0.012 counts.
        let rows = [row(0, error: true), row(0.0102, error: true), row(0.012, error: true), row(0.030), row(0.0312), row(0.0324, error: true)]
        #expect(alignedFrames(rows, baud: 1000).map(\.start) == [0.030, 0.0312])
    }

    @Test("A gap just under the longest frame does not count, and just over does", arguments: [
        (0.0129, [0.0012, 0.0151, 0.0166]),
        (0.0131, [0.0153, 0.0168]),
    ])
    func boundary(gap: Double, expected: [Double]) {
        let third = 0.0022 + gap
        let rows = [row(0), row(0.0012), row(third), row(third + 0.0015), row(third + 0.003)]
        let starts = alignedFrames(rows, baud: 1000).map(\.start)
        #expect(starts.count == expected.count)
        #expect(zip(starts, expected).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test("With no gap only the ends are dropped")
    func noGap() {
        let rows = (0..<5).map { row(Double($0) * 1.2e-3) }
        #expect(alignedFrames(rows, baud: 1000).count == 3)
    }

    @Test("Short tables are safe", arguments: [0, 1, 2])
    func short(count: Int) {
        let rows = (0..<count).map { row(Double($0) * 1.2e-3) }
        #expect(alignedFrames(rows, baud: 1000).isEmpty)
    }

    @Test("A gap at the very end does not leave nothing to check")
    func gapAtEnd() {
        let rows = [row(0), row(0.0012), row(0.0024), row(0.1)]
        #expect(alignedFrames(rows, baud: 1000).map(\.start) == [0.0012, 0.0024])
    }
}

@Suite("Channel identification rules")
struct IdentificationRuleTests {
    private func uart(_ result: ChannelIdentification) throws -> UARTDecoder {
        guard case .uart(let uart)? = result.buses.first?.decoder else { throw TestgenPortError(description: "no uart") }
        return uart
    }

    private func spi(_ result: ChannelIdentification) throws -> SPIDecoder {
        guard case .spi(let spi)? = result.buses.first?.decoder else { throw TestgenPortError(description: "no spi") }
        return spi
    }

    @Test("Nothing to identify is handled")
    func nothing() {
        #expect(identifyChannels([]) == ChannelIdentification(buses: [], periodic: [], idle: [], unknown: [], notes: []))
    }

    @Test("Idle channels report their level and that they reveal nothing")
    func idle() throws {
        let result = identifyChannels([try channel(3, initial: 1, []), try channel(1, initial: 0, [])])
        #expect(result.idle == [IdleChannel(channel: 1, level: 0), IdleChannel(channel: 3, level: 1)])
        #expect(result.notes == ["Idle channels reveal nothing about what is wired to them."])
    }

    @Test("A periodic channel is reported, not mistaken for a bus")
    func periodic() throws {
        let result = identifyChannels([try channel(0, initial: 0, squareWave(periods: 50, high: 2.5e-4, low: 7.5e-4))])
        #expect(result.buses.isEmpty)
        #expect(result.periodic.map(\.channel) == [0])
        #expect(abs(result.periodic[0].frequencyHz - 1000) < 1)
        #expect(abs(result.periodic[0].dutyPercent - 25) < 1)
    }

    @Test("Active channels that match nothing are reported as unknown")
    func unknown() throws {
        var generator = SplitMix64(state: 7)
        var now = 1.0
        let times = (0..<300).map { _ -> Double in
            now += Double.random(in: 1e-7...1e-3, using: &generator)
            return now
        }
        let result = identifyChannels([try channel(4, initial: 1, times)])
        #expect(result.buses.isEmpty)
        #expect(result.unknown == [4])
    }

    @Test("Baud rates are measured and snapped to standard ones", arguments: [
        9600.0, 19_200, 57_600, 115_200, 230_400, 460_800, 921_600,
    ])
    func standardBaud(baud: Double) throws {
        let result = identifyChannels([try channel(2, initial: 1, uartTimes(text, bit: 1 / baud))])
        #expect(try uart(result).baud == Int64(baud))
        #expect(result.buses[0].confidence == .likely)
    }

    @Test("A rate no standard is near is reported as measured")
    func nonstandardBaud() throws {
        let result = identifyChannels([try channel(2, initial: 1, uartTimes(text, bit: 1 / 83_333.0))])
        #expect(abs(Double(try uart(result).baud) - 83_333) < 100)
    }

    @Test("A stray glitch cannot pose as a bit")
    func glitch() throws {
        var times = uartTimes(text, bit: 1 / 115_200.0)
        let position = times.count / 2
        let middle = times[position] + 2e-6
        times.insert(contentsOf: [middle, middle + 40e-9], at: position + 1)
        #expect(try uart(identifyChannels([try channel(2, initial: 1, times)])).baud == 115_200)
    }

    @Test("Baud survives edge jitter that a receiver would tolerate", arguments: [0.05, 0.15, 0.25])
    func jitter(amount: Double) throws {
        let bit = 1 / 921_600.0
        var generator = SplitMix64(state: 11)
        let times = uartTimes(text + text, bit: bit).map { $0 + Double.random(in: -amount...amount, using: &generator) * bit / 2 }
        let result = identifyChannels([try channel(2, initial: 1, times)])
        #expect(try uart(result).baud == 921_600)
    }

    @Test("Pauses between frames can be any length", arguments: [0.37, 1.5, 3.21, 50.8])
    func framePauses(pauseBits: Double) throws {
        let bit = 1 / 115_200.0
        var times: [Double] = []
        var offset = 0.0
        for byte in text {
            let frame = uartTimes([byte], bit: bit)
            times += frame.map { $0 + offset }
            offset += frame.last! - 1 + bit * (2 + pauseBits)
        }
        #expect(try uart(identifyChannels([try channel(2, initial: 1, times)])).baud == 115_200)
    }

    @Test("A line resting low is inverted")
    func inverted() throws {
        let times = uartTimes(text, bit: 1 / 9600.0)
        let result = identifyChannels([try channel(2, initial: 0, times)])
        #expect(try uart(result).inverted)
        #expect(result.buses[0].decoder.command == "sal decode uart --channel 2 --baud 9600 --inverted")
    }

    @Test("Too few edges are not called UART, and few are uncertain")
    func fewEdges() throws {
        let short = uartTimes([0x4D, 0x32], bit: 1e-4)
        #expect(short.count >= 6)
        let result = identifyChannels([try channel(2, initial: 1, short)])
        #expect(result.buses.first?.confidence == .uncertain)
        #expect(result.buses.first?.notes.contains { $0.contains("Few edges") } == true)

        #expect(identifyChannels([try channel(2, initial: 1, Array(short.prefix(5)))]).buses.isEmpty)
    }

    @Test("A pulse stuck active longer than any frame is not UART")
    func activeTooLong() throws {
        var times = uartTimes(text, bit: 1e-4)
        let last = times.last!
        times += [last + 1, last + 1 + 2e-3]
        #expect(identifyChannels([try channel(2, initial: 1, times)]).buses.isEmpty)
    }

    @Test("Two UARTs say TX and RX cannot be told apart")
    func twoUARTs() throws {
        let times = uartTimes(text, bit: 1e-4)
        let result = identifyChannels([try channel(1, initial: 1, times), try channel(2, initial: 1, times)])
        #expect(result.buses.count == 2)
        #expect(result.notes == ["Timing cannot tell UART TX from RX."])
    }

    @Test("SPI finds the clock, data and enable", arguments: [(false, false), (false, true)])
    func spiLines(cpol: Bool, cpha: Bool) throws {
        let waves = spiWaves(frames: 6, cpha: cpha)
        let result = identifyChannels([
            try channel(0, initial: 0, waves.clock), try channel(1, initial: 0, waves.data),
            try channel(2, initial: 1, waves.enable),
        ])
        let decoder = try spi(result)
        #expect(decoder == SPIDecoder(clock: 0, mosi: 1, enable: 2, dataOnTrailingEdge: cpha))
        #expect(result.buses[0].notes == ["Word size and bit order are assumed, because timing cannot show them."])
    }

    @Test("A clock resting high is CPOL 1")
    func spiIdlesHigh() throws {
        let waves = spiWaves(frames: 6)
        let decoder = try spi(identifyChannels([
            try channel(0, initial: 1, waves.clock), try channel(1, initial: 0, waves.data),
            try channel(2, initial: 1, waves.enable),
        ]))
        #expect(decoder.clockIdlesHigh)
    }

    @Test("An enable line that rises around the frame is active high")
    func spiEnableHigh() throws {
        let waves = spiWaves(frames: 6)
        let decoder = try spi(identifyChannels([
            try channel(0, initial: 0, waves.clock), try channel(1, initial: 0, waves.data),
            try channel(2, initial: 0, waves.enable),
        ]))
        #expect(decoder.enableActiveHigh)
    }

    @Test("SPI works without an enable line")
    func spiNoEnable() throws {
        let waves = spiWaves(frames: 6)
        let result = identifyChannels([try channel(0, initial: 0, waves.clock), try channel(1, initial: 0, waves.data)])
        #expect(try spi(result) == SPIDecoder(clock: 0, mosi: 1))
    }

    @Test("Two data lines are both kept, with the ambiguity stated")
    func spiTwoData() throws {
        let waves = spiWaves(frames: 6)
        let other = spiWaves(frames: 6, bytes: [0x33, 0xCC, 0x0F, 0xF1])
        let result = identifyChannels([
            try channel(0, initial: 0, waves.clock), try channel(1, initial: 0, waves.data),
            try channel(3, initial: 0, other.data),
        ])
        #expect(try spi(result) == SPIDecoder(clock: 0, mosi: 1, miso: 3))
        #expect(result.buses[0].notes[0] == "Timing cannot tell MOSI from MISO, so 1 and 3 may be swapped.")
    }

    @Test("A burst clock with no data in step is not SPI")
    func spiNoData() throws {
        let waves = spiWaves(frames: 6)
        let result = identifyChannels([try channel(0, initial: 0, waves.clock)])
        #expect(result.buses.isEmpty)
    }

    @Test("Bursts that are not multiples of 8 are not SPI")
    func spiWrongBurst() throws {
        var times: [Double] = []
        var now = 1.0
        for _ in 0..<6 {
            for _ in 0..<10 {
                times += [now, now + 1e-6]
                now += 2e-6
            }
            now += 1e-3
        }
        let waves = spiWaves(frames: 6)
        let result = identifyChannels([try channel(0, initial: 0, times), try channel(1, initial: 0, waves.data)])
        #expect(!result.buses.contains { $0.decoder.kind == "spi" })
    }

    @Test("I2C pairs SDA with SCL, in the right order", arguments: [(false, 0, 1), (true, 5, 2)])
    func i2c(repeated: Bool, sdaIndex: UInt32, sclIndex: UInt32) throws {
        let waves = i2cWaves(transactions: 8, repeated: repeated)
        let result = identifyChannels([
            try channel(sdaIndex, initial: 1, waves.sda), try channel(sclIndex, initial: 1, waves.scl),
        ])
        #expect(result.buses.map(\.decoder) == [.i2c(I2CDecoder(sda: sdaIndex, scl: sclIndex))])
    }

    @Test("One transaction is uncertain")
    func i2cThin() throws {
        let waves = i2cWaves(transactions: 1)
        let result = identifyChannels([try channel(0, initial: 1, waves.sda), try channel(1, initial: 1, waves.scl)])
        #expect(result.buses.first?.confidence == .uncertain)
    }

    @Test("Two I2C buses are reported with the ambiguity stated")
    func twoI2C() throws {
        let first = i2cWaves(transactions: 8)
        let second = i2cWaves(transactions: 6, bytes: [0x90, 0x11])
        let result = identifyChannels([
            try channel(0, initial: 1, first.sda), try channel(1, initial: 1, first.scl),
            try channel(2, initial: 1, second.sda), try channel(3, initial: 1, second.scl),
        ])
        #expect(result.buses.count == 2)
        #expect(result.notes.contains("Several I2C buses were found, and nothing distinguishes one from another."))
    }

    @Test("Commands carry each non-default setting")
    func commands() {
        #expect(ProtocolDecoder.spi(SPIDecoder(
            clock: 1, mosi: 2, miso: 3, enable: 4, bits: 16, order: .lsb, clockIdlesHigh: true,
            dataOnTrailingEdge: true, enableActiveHigh: true)).command
            == "sal decode spi --clock 1 --mosi 2 --miso 3 --enable 4 --bits 16 --order lsb --cpol 1 --cpha 1 --enable-active-high")
        #expect(ProtocolDecoder.uart(UARTDecoder(
            channel: 1, baud: 9600, bits: 7, parity: .even, stop: .two, order: .msb, inverted: true, mode: .mdb)).command
            == "sal decode uart --channel 1 --baud 9600 --bits 7 --parity even --stop 2 --order msb --inverted --mode mdb")
        #expect(ProtocolDecoder.i2c(I2CDecoder(sda: 1, scl: 2)).command == "sal decode i2c --sda 1 --scl 2")
    }

    @Test("Roles name each wired channel")
    func roles() {
        #expect(ProtocolDecoder.uart(UARTDecoder(channel: 1, baud: 1)).channelRoles == ["signal": 1])
        #expect(ProtocolDecoder.i2c(I2CDecoder(sda: 1, scl: 2)).channelRoles == ["sda": 1, "scl": 2])
        #expect(ProtocolDecoder.spi(SPIDecoder(clock: 1, mosi: 2)).channelRoles == ["clock": 1, "mosi": 2])
    }

    @Test("Random edge sets never trap")
    func randomEdges() throws {
        var generator = SplitMix64(state: 0xBEEF)
        for _ in 0..<2_000 {
            let channels = try (0..<UInt32.random(in: 1...8, using: &generator)).map { number -> IdentifiableChannel in
                var now = 0.0
                let times = (0..<Int.random(in: 0...64, using: &generator)).map { _ -> Double in
                    now += [1e-9, 1e-6, 1e-3, 1].randomElement(using: &generator)! * Double.random(in: 0.5...2, using: &generator)
                    return now
                }
                return try channel(number, initial: Int32.random(in: 0...1, using: &generator), times)
            }
            _ = identifyChannels(channels)
        }
    }

    @Test("Table output lists buses, channels and notes")
    func output() {
        let lines = describe(ChannelIdentification(
            buses: [IdentifiedBus(
                decoder: .i2c(I2CDecoder(sda: 6, scl: 7)), confidence: .confirmed, evidence: "e", notes: ["n"])],
            periodic: [PeriodicChannel(channel: 0, frequencyHz: 1000, dutyPercent: 25)],
            idle: [IdleChannel(channel: 1, level: 1)], unknown: [2], notes: ["x"]))
        #expect(lines == [
            "I2C  scl=7 sda=6  confirmed: e", "  sal decode i2c --sda 6 --scl 7", "  Note: n",
            "CH0  1000.00 Hz, 25.00% duty", "CH1  idle high", "CH2  active, unidentified", "Note: x",
        ])
    }
}
