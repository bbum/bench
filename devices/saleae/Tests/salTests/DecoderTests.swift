import ArgumentParser
import Testing
@testable import sal

private func strings(_ settings: [String: AnalyzerSetting]) -> [String: String] {
    settings.compactMapValues {
        if case .stringValue(let value)? = $0.value { value } else { nil }
    }
}

private func numbers(_ settings: [String: AnalyzerSetting]) -> [String: Int64] {
    settings.compactMapValues {
        if case .int64Value(let value)? = $0.value { value } else { nil }
    }
}

/// Exact menu text, recorded from Logic 2.4.48's validation errors.
@Suite("Decoder settings")
struct DecoderSettingsTests {
    @Test("UART defaults")
    func uartDefaults() {
        let settings = UARTDecoder(channel: 2, baud: 115_200).settings
        #expect(numbers(settings) == ["Input Channel": 2, "Bit Rate (Bits/s)": 115_200])
        #expect(strings(settings) == [
            "Bits per Frame": "8 Bits per Transfer (Standard)",
            "Stop Bits": "1 Stop Bit (Standard)",
            "Parity Bit": "No Parity Bit (Standard)",
            "Significant Bit": "Least Significant Bit Sent First (Standard)",
            "Signal inversion": "Non Inverted (Standard)",
            "Mode": "Normal",
        ])
    }

    @Test("UART alternatives")
    func uartAlternatives() {
        let settings = strings(UARTDecoder(
            channel: 0, baud: 9600, bits: 1, parity: .even, stop: .oneAndHalf, order: .msb, inverted: true,
            mode: .mp).settings)
        #expect(settings["Bits per Frame"] == "1 Bit per Transfer")
        #expect(settings["Parity Bit"] == "Even Parity Bit")
        #expect(settings["Stop Bits"] == "1.5 Stop Bits")
        #expect(settings["Significant Bit"] == "Most Significant Bit Sent First")
        #expect(settings["Signal inversion"] == "Inverted")
        #expect(settings["Mode"] == "MP - Address indicated by MSB=0")

        let other = strings(UARTDecoder(channel: 0, baud: 9600, bits: 9, parity: .odd, stop: .two, mode: .mdb).settings)
        #expect(other["Bits per Frame"] == "9 Bits per Transfer")
        #expect(other["Parity Bit"] == "Odd Parity Bit")
        #expect(other["Stop Bits"] == "2 Stop Bits")
        #expect(other["Mode"] == "MDB - Address indicated by MSB=1 (TX only)")
    }

    @Test("SPI defaults leave out lines that are not wired")
    func spiDefaults() {
        let settings = SPIDecoder(clock: 3, mosi: 4).settings
        #expect(numbers(settings) == ["Clock": 3, "MOSI": 4])
        #expect(strings(settings) == [
            "Significant Bit": "Most Significant Bit First (Standard)",
            "Bits per Transfer": "8 Bits per Transfer (Standard)",
            "Clock State": "Clock is Low when inactive (CPOL = 0)",
            "Clock Phase": "Data is Valid on Clock Leading Edge (CPHA = 0)",
            "Enable Line": "Enable line is Active Low (Standard)",
        ])
    }

    @Test("SPI alternatives, including its different singular for one bit")
    func spiAlternatives() {
        let settings = SPIDecoder(
            clock: 3, mosi: 4, miso: 6, enable: 5, bits: 1, order: .lsb, clockIdlesHigh: true,
            dataOnTrailingEdge: true, enableActiveHigh: true).settings
        #expect(numbers(settings) == ["Clock": 3, "MOSI": 4, "MISO": 6, "Enable": 5])
        let text = strings(settings)
        #expect(text["Bits per Transfer"] == "1 Bits per Transfer")
        #expect(text["Significant Bit"] == "Least Significant Bit First")
        #expect(text["Clock State"] == "Clock is High when inactive (CPOL = 1)")
        #expect(text["Clock Phase"] == "Data is Valid on Clock Trailing Edge (CPHA = 1)")
        #expect(text["Enable Line"] == "Enable line is Active High")
    }

    @Test("I2C settings, analyzer names and captured channels")
    func i2cAndNames() {
        let i2c = ProtocolDecoder.i2c(I2CDecoder(sda: 7, scl: 6))
        #expect(numbers(i2c.settings) == ["SDA": 7, "SCL": 6])
        #expect(i2c.analyzerName == "I2C")
        #expect(i2c.channels == [6, 7])

        let uart = ProtocolDecoder.uart(UARTDecoder(channel: 2, baud: 1))
        #expect(uart.analyzerName == "Async Serial")
        #expect(uart.channels == [2])

        let spi = ProtocolDecoder.spi(SPIDecoder(clock: 5, mosi: 3, miso: 4, enable: 1))
        #expect(spi.analyzerName == "SPI")
        #expect(spi.channels == [1, 3, 4, 5])
        #expect(spi.settings == SPIDecoder(clock: 5, mosi: 3, miso: 4, enable: 1).settings)
    }

    @Test("Radixes map to their wire values")
    func radixes() {
        #expect(Radix.allCases.map(\.type) == [.hexadecimal, .decimal, .binary, .ascii])
    }
}

@Suite("Decode arguments")
struct DecodeArgumentTests {
    private func parse(_ arguments: [String]) throws -> any ParsableCommand {
        try Sal.parseAsRoot(["decode"] + arguments)
    }

    @Test("A full UART command line reaches the decoder")
    func uart() throws {
        let command = try #require(try parse([
            "uart", "--channel", "2", "--baud", "9600", "--bits", "7", "--parity", "odd", "--stop", "1.5",
            "--order", "msb", "--inverted", "--mode", "mdb",
        ]) as? UARTCommand)
        #expect(command.decoder == UARTDecoder(
            channel: 2, baud: 9600, bits: 7, parity: .odd, stop: .oneAndHalf, order: .msb, inverted: true,
            mode: .mdb))
    }

    @Test("A full SPI command line reaches the decoder")
    func spi() throws {
        let command = try #require(try parse([
            "spi", "--clock", "3", "--mosi", "4", "--miso", "6", "--enable", "5", "--bits", "16", "--order", "lsb",
            "--cpol", "1", "--cpha", "1", "--enable-active-high",
        ]) as? SPICommand)
        #expect(command.decoder == SPIDecoder(
            clock: 3, mosi: 4, miso: 6, enable: 5, bits: 16, order: .lsb, clockIdlesHigh: true,
            dataOnTrailingEdge: true, enableActiveHigh: true))
    }

    @Test("SPI needs only a clock and one data line", arguments: [["--mosi", "4"], ["--miso", "4"]])
    func spiMinimal(line: [String]) throws {
        #expect(throws: Never.self) { try parse(["spi", "--clock", "3"] + line) }
    }

    @Test("Valid boundaries are accepted", arguments: [
        ["uart", "--channel", "15", "--baud", "1"],
        ["uart", "--channel", "0", "--baud", "1", "--bits", "1"],
        ["uart", "--channel", "0", "--baud", "1", "--bits", "64"],
        ["spi", "--clock", "0", "--mosi", "15", "--bits", "1"],
        ["spi", "--clock", "0", "--mosi", "1", "--bits", "64"],
        ["i2c", "--sda", "0", "--scl", "15"],
        ["i2c", "--sda", "0", "--scl", "1", "--offset", "0", "--limit", "1"],
    ])
    func accepted(arguments: [String]) {
        #expect(throws: Never.self) { try parse(arguments) }
    }

    @Test("Invalid values are refused", arguments: [
        ["uart", "--channel", "16", "--baud", "1"],
        ["uart", "--channel", "0", "--baud", "0"],
        ["uart", "--channel", "0", "--baud", "1", "--bits", "0"],
        ["uart", "--channel", "0", "--baud", "1", "--bits", "65"],
        ["uart", "--channel", "0", "--baud", "1", "--parity", "mark"],
        ["uart", "--channel", "0", "--baud", "1", "--stop", "3"],
        ["spi", "--clock", "0"],
        ["spi", "--clock", "16", "--mosi", "1"],
        ["spi", "--clock", "1", "--mosi", "1"],
        ["spi", "--clock", "0", "--mosi", "1", "--bits", "0"],
        ["spi", "--clock", "0", "--mosi", "1", "--bits", "65"],
        ["spi", "--clock", "0", "--mosi", "1", "--cpol", "2"],
        ["spi", "--clock", "0", "--mosi", "1", "--cpha", "-1"],
        ["i2c", "--sda", "1", "--scl", "1"],
        ["i2c", "--sda", "16", "--scl", "1"],
        ["i2c", "--sda", "0", "--scl", "1", "--duration", "0"],
        ["i2c", "--sda", "0", "--scl", "1", "--duration", "nan"],
        ["i2c", "--sda", "0", "--scl", "1", "--offset", "-1"],
        ["i2c", "--sda", "0", "--scl", "1", "--limit", "0"],
        ["i2c", "--sda", "0", "--scl", "1", "--radix", "octal"],
    ])
    func refused(arguments: [String]) {
        #expect(throws: (any Error).self) { try parse(arguments) }
    }
}
