import Foundation
import Testing
@testable import sal

private let message = Array("TESTGEN UART\n".utf8).map(UInt64.init)
private let spiFrame: [UInt64] = [0xA5, 0x5A, 0x00, 0xFF, 0x12, 0x34]
private let uart = UARTDecoder(channel: 2, baud: 115_200)
private let spi = SPIDecoder(clock: 3, mosi: 4, enable: 5)
private let i2c = I2CDecoder(sda: 6, scl: 7)

private func decode(_ decoder: ProtocolDecoder, radix: Radix = .hex) async throws -> [DecodedRow] {
    try await runDecode(
        DecodeRequest(
            capture: DigitalCaptureRequest(
                channels: decoder.channels, sampleRate: 50_000_000, durationSeconds: 0.12, levelVolts: 3.3,
                deviceID: nil),
            decoder: decoder, radix: radix),
        endpoint: Logic2Endpoint())
}

private func word(_ row: DecodedRow, _ field: String = "data") -> UInt64? {
    row.fields[field].flatMap { UInt64($0.dropFirst(2), radix: 16) }
}

private func contains<Element: Equatable>(_ values: [Element], _ sequence: [Element]) -> Bool {
    values.count >= sequence.count
        && (0...(values.count - sequence.count)).contains { Array(values[$0..<($0 + sequence.count)]) == sequence }
}

/// Removes rows a capture window can cut in half at either end.
private func whole(_ rows: [DecodedRow], margin: Int) -> [DecodedRow] {
    Array(rows.dropFirst(margin).dropLast(margin))
}

private struct UARTCase: Sendable, CustomTestStringConvertible {
    var mode: Character
    var decoder: UARTDecoder
    var testDescription: String { "mode \(mode)" }
}

private struct SPICase: Sendable, CustomTestStringConvertible {
    var mode: Character
    var decoder: SPIDecoder
    var expected = spiFrame
    var testDescription: String { "mode \(mode)" }
}

private func variant(_ change: (inout UARTDecoder) -> Void) -> UARTDecoder {
    var decoder = uart
    change(&decoder)
    return decoder
}

private func variant(_ change: (inout SPIDecoder) -> Void) -> SPIDecoder {
    var decoder = spi
    change(&decoder)
    return decoder
}

private let uartCases = [
    UARTCase(mode: "c", decoder: uart),
    UARTCase(mode: "a", decoder: variant { $0.bits = 7; $0.stop = .two }),
    UARTCase(mode: "b", decoder: variant { $0.parity = .even }),
    UARTCase(mode: "d", decoder: variant { $0.parity = .odd }),
    UARTCase(mode: "e", decoder: variant { $0.stop = .oneAndHalf }),
    UARTCase(mode: "g", decoder: variant { $0.order = .msb }),
    UARTCase(mode: "h", decoder: variant { $0.inverted = true }),
]

private let spiCases = [
    SPICase(mode: "c", decoder: spi),
    SPICase(mode: "a", decoder: variant { $0.dataOnTrailingEdge = true }),
    SPICase(mode: "b", decoder: variant { $0.clockIdlesHigh = true }),
    SPICase(mode: "d", decoder: variant { $0.clockIdlesHigh = true; $0.dataOnTrailingEdge = true }),
    SPICase(mode: "e", decoder: variant { $0.order = .lsb }),
    SPICase(mode: "g", decoder: variant { $0.bits = 16 }, expected: [0xA55A, 0x00FF, 0x1234]),
    SPICase(mode: "h", decoder: variant { $0.enableActiveHigh = true }),
]

extension LiveTests {
    @Test("UART decodes every testgen format to the bytes sent", arguments: uartCases)
    fileprivate func uartFormats(test: UARTCase) async throws {
        try await withTestgen(mode: test.mode) {
            let rows = whole(try await decode(.uart(test.decoder)), margin: 13)
            #expect(contains(rows.compactMap { word($0) }, message))
            #expect(decodeIssues(rows).isEmpty)
        }
    }

    @Test("A ninth data bit is decoded")
    func uartNineBits() async throws {
        try await withTestgen(mode: "i") {
            let rows = try await decode(.uart(variant { $0.bits = 9 }))
            #expect(contains(rows.compactMap { word($0) }, [0x154] + message.dropFirst()))
        }
    }

    @Test("Address modes report the extra bit, with opposite senses", arguments: [
        (UARTMode.mdb, true), (.mp, false),
    ])
    func uartAddressModes(mode: UARTMode, firstIsAddress: Bool) async throws {
        try await withTestgen(mode: "i") {
            let rows = try await decode(.uart(variant { $0.mode = mode }))
            let observed = rows.map { "\(word($0) ?? 0):\($0.fields["address"] ?? "?")" }
            let expected = message.enumerated().map { "\($1):\(($0 == 0) == firstIsAddress)" }
            #expect(contains(observed, expected))
        }
    }

    @Test("SPI decodes every testgen format to the bytes sent", arguments: spiCases)
    fileprivate func spiFormats(test: SPICase) async throws {
        try await withTestgen(mode: test.mode) {
            let rows = try await decode(.spi(test.decoder))
            let frames = rows.filter { $0.type == "result" }.compactMap { word($0, "mosi") }
            #expect(contains(frames, test.expected))
            #expect(rows.contains { $0.type == "enable" })
            #expect(decodeIssues(rows).isEmpty)
        }
    }

    @Test("SPI works without an enable line and with only MISO")
    func spiPartialWiring() async throws {
        try await withTestgen(mode: "c") {
            let noEnable = try await decode(.spi(SPIDecoder(clock: 3, mosi: 4)))
            #expect(contains(noEnable.compactMap { word($0, "mosi") }, spiFrame))
            #expect(!noEnable.contains { $0.type == "enable" })

            let misoOnly = try await decode(.spi(SPIDecoder(clock: 3, miso: 4, enable: 5)))
            #expect(contains(misoOnly.compactMap { word($0, "miso") }, spiFrame))
        }
    }

    @Test("I2C decodes the address, bytes and ACKs sent")
    func i2cClean() async throws {
        try await withTestgen(mode: "c") {
            let rows = whole(try await decode(.i2c(i2c)), margin: 8)
            #expect(contains(rows.map(\.type), ["start", "address", "data", "data", "data", "data", "stop"]))
            #expect(contains(rows.compactMap { word($0) }, [0xDE, 0xAD, 0xBE, 0xEF]))
            let addresses = rows.filter { $0.type == "address" }
            #expect(!addresses.isEmpty)
            #expect(addresses.allSatisfy { word($0, "address") == 0x42 && $0.fields["read"] == "false" })
            #expect(decodeIssues(rows).isEmpty)
        }
    }

    @Test("A framing error is flagged on exactly the byte that had one")
    func framingFault() async throws {
        try await withTestgen(mode: "f") {
            let rows = whole(try await decode(.uart(uart)), margin: 3)
            #expect(contains(rows.compactMap { word($0) }, [0x41, 0x42, 0x43]))
            for row in rows {
                #expect((row.fields["error"] == "framing") == (word(row) == 0x42))
            }
            #expect(decodeIssues(rows)["framing"] == rows.count { word($0) == 0x42 })
        }
    }

    @Test("A parity error is flagged on exactly the byte that had one")
    func parityFault() async throws {
        try await withTestgen(mode: "p") {
            let rows = whole(try await decode(.uart(variant { $0.parity = .even })), margin: 2)
            #expect(contains(rows.compactMap { word($0) }, [0x44, 0x45]))
            for row in rows {
                #expect((row.fields["error"] == "parity") == (word(row) == 0x45))
            }
        }
    }

    @Test("Data and address NACKs are flagged and counted")
    func nackFaults() async throws {
        try await withTestgen(mode: "f") {
            let rows = whole(try await decode(.i2c(i2c)), margin: 6)
            let acknowledged = rows.filter { $0.type != "start" && $0.type != "stop" }
            for row in acknowledged {
                let value = row.type == "address" ? word(row, "address") : word(row)
                #expect((row.fields["ack"] == "false") == (value == 0xAD || value == 0x43))
            }
            #expect(decodeIssues(rows)["nack"] == acknowledged.count { $0.fields["ack"] == "false" })
            #expect(decodeIssues(rows)["nack"] ?? 0 > 0)
        }
    }

    @Test("The wrong baud rate does not produce the message")
    func wrongBaud() async throws {
        try await withTestgen(mode: "c") {
            let rows = try await decode(.uart(variant { $0.baud = 57_600 }))
            #expect(!contains(rows.compactMap { word($0) }, message))
        }
    }

    @Test("Radix changes how values are written", arguments: [
        (Radix.dec, ["84", "69", "83"]),
        (.bin, ["0b01010100", "0b01000101", "0b01010011"]),
        (.ascii, ["T", "E", "S"]),
    ])
    func radix(radix: Radix, expected: [String]) async throws {
        try await withTestgen(mode: "c") {
            let rows = try await decode(.uart(uart), radix: radix)
            #expect(contains(rows.compactMap { $0.fields["data"] }, expected))
        }
    }

    @Test("ASCII radix keeps the newline in the message")
    func asciiNewline() async throws {
        try await withTestgen(mode: "c") {
            let rows = try await decode(.uart(uart), radix: .ascii)
            #expect(rows.compactMap { $0.fields["data"] }.joined().contains("TESTGEN UART\n"))
        }
    }

    @Test("Logic 2 accepts every setting value we can send")
    func everySettingValue() async throws {
        var decoders: [ProtocolDecoder] = []
        // The menu text is generated, and every width's text is checked offline.
        for bits in [wordBits.lowerBound, 2, 8, 9, 16, 32, 63, wordBits.upperBound] {
            decoders.append(.uart(variant { $0.bits = bits }))
            decoders.append(.spi(variant { $0.bits = bits }))
        }
        for parity in Parity.allCases { decoders.append(.uart(variant { $0.parity = parity })) }
        for stop in StopBits.allCases { decoders.append(.uart(variant { $0.stop = stop })) }
        for order in BitOrder.allCases {
            decoders.append(.uart(variant { $0.order = order }))
            decoders.append(.spi(variant { $0.order = order }))
        }
        for mode in UARTMode.allCases { decoders.append(.uart(variant { $0.mode = mode })) }
        decoders.append(.uart(variant { $0.inverted = true }))
        decoders.append(.spi(variant { $0.clockIdlesHigh = true }))
        decoders.append(.spi(variant { $0.dataOnTrailingEdge = true }))
        decoders.append(.spi(variant { $0.enableActiveHigh = true }))
        decoders.append(.i2c(i2c))

        let request = DigitalCaptureRequest(
            channels: Array(0...7), sampleRate: 50_000_000, durationSeconds: 0.02, levelVolts: 3.3, deviceID: nil)
        try await withLogic2(Logic2Endpoint()) { manager in
            let backend = GRPCCaptureBackend(manager: manager)
            try await runTimedCapture(request, using: backend, cancellation: CaptureCancellation()) { captureID in
                for decoder in decoders {
                    var add = Saleae_Automation_AddAnalyzerRequest()
                    add.captureID = captureID
                    add.analyzerName = decoder.analyzerName
                    add.analyzerLabel = decoder.analyzerName
                    add.settings = decoder.settings
                    let analyzerID = try await backend.addAnalyzer(add)

                    var remove = Saleae_Automation_RemoveAnalyzerRequest()
                    remove.captureID = captureID
                    remove.analyzerID = analyzerID
                    _ = try await manager.removeAnalyzer(remove)
                }
            }
        }
    }

    @Test("The decode commands run in both output modes", arguments: [
        ["uart", "--channel", "2", "--baud", "115200"],
        ["spi", "--clock", "3", "--mosi", "4", "--enable", "5"],
        ["i2c", "--sda", "6", "--scl", "7"],
    ])
    func commands(arguments: [String]) async throws {
        for flags in [["--limit", "3"], ["--json", "--limit", "3"]] {
            let parsed = try Sal.parseAsRoot(["decode"] + arguments + ["--duration", "0.05"] + flags)
            let command = try #require(parsed as? any AsyncParsableCommandShim)
            try await command.runShim()
        }
    }

    @Test("Cancelling a long decode ends promptly and the next decode is clean")
    func cancelledDecode() async throws {
        let long = DecodeRequest(
            capture: DigitalCaptureRequest(
                channels: [2], sampleRate: 50_000_000, durationSeconds: 60, levelVolts: 3.3, deviceID: nil),
            decoder: .uart(uart))
        let task = Task { try await runDecode(long, endpoint: Logic2Endpoint()) }
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        try await withTestgen(mode: "c") {
            let rows = try await decode(.uart(uart))
            #expect(contains(rows.compactMap { word($0) }, message))
        }
    }
}

private protocol AsyncParsableCommandShim {
    func runShim() async throws
}

extension UARTCommand: AsyncParsableCommandShim {
    fileprivate func runShim() async throws { try await run() }
}
extension SPICommand: AsyncParsableCommandShim {
    fileprivate func runShim() async throws { try await run() }
}
extension I2CCommand: AsyncParsableCommandShim {
    fileprivate func runShim() async throws { try await run() }
}
