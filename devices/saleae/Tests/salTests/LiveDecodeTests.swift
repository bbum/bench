import Foundation
import Testing
@testable import sal

private let message = Array("TESTGEN UART\n".utf8).map(UInt64.init)
private let spiFrame: [UInt64] = [0xA5, 0x5A, 0x00, 0xFF, 0x12, 0x34]
private let uart = UARTDecoder(channel: 2, baud: 115_200)
private let spi = SPIDecoder(clock: 3, mosi: 4, enable: 5)
private let i2c = I2CDecoder(sda: 6, scl: 7)

private func analogRequest(digital: [UInt32], digitalRate: UInt32 = 6_250_000) -> DigitalCaptureRequest {
    DigitalCaptureRequest(
        channels: digital, sampleRate: digitalRate, mode: .timed(seconds: 0.03), levelVolts: 3.3, deviceID: nil,
        analog: AnalogCapture(channels: [0], sampleRate: 1_562_500))
}

private func verifyAnalogPWM(_ analog: AnalogSummary) {
    #expect(abs((analog.levels?.lowVolts ?? 99) - 0) < 0.25, "\(analog)")
    #expect(abs((analog.levels?.highVolts ?? 99) - 3.3) < 0.3, "\(analog)")
    #expect(abs((analog.periodic?.frequencyHz ?? 0) - 1000) < 15, "\(analog)")
    #expect(abs((analog.periodic?.dutyPercent ?? 0) - 25) < 3, "\(analog)")
}

private let testExtensionDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("testgen/hla").path

private func loadRequest(_ path: String) -> DigitalCaptureRequest {
    DigitalCaptureRequest(channels: [], sampleRate: 1, mode: .load(path: path), levelVolts: 3.3, deviceID: nil)
}

private func analogFreeCapture(channels: [UInt32]) -> DigitalCaptureRequest {
    DigitalCaptureRequest(channels: channels, sampleRate: 50_000_000, mode: .timed(seconds: 0.12), levelVolts: 3.3, deviceID: nil)
}

/// A real directory for Logic 2 to write to. Its own process cannot see a sandboxed one.
private func inScratch<Result>(_ body: (URL) async throws -> Result) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sal-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// A real `sal mcp` subprocess, driven the way a client drives it.
private final class MCPProcess: @unchecked Sendable {
    struct Reply {
        var raw: Data
        var value: JSONValue
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    init() throws {
        // `make verify` and `make coverage` build this first, so it is never stale.
        process.executableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/sal")
        process.arguments = ["mcp"]
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [lock] handle in
            let chunk = handle.availableData
            lock.withLock { self.buffer.append(chunk) }
        }
        try process.run()
    }

    func send(_ line: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    private func lines() -> [Data] {
        lock.withLock { buffer.split(separator: 0x0A).map { Data($0) } }
    }

    func hasResponse(id: Int) -> Bool {
        lines().contains { (try? JSONDecoder().decode(JSONValue.self, from: $0))?["id"] == .int(id) }
    }

    func request(_ line: String, id: Int, timeout: Double = 20) throws -> Reply {
        try send(line)
        return try wait(id: id, timeout: timeout)
    }

    private func wait(id: Int, timeout: Double) throws -> Reply {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for line in lines() {
                if let value = try? JSONDecoder().decode(JSONValue.self, from: line), value["id"] == .int(id) {
                    return Reply(raw: line, value: value)
                }
            }
            usleep(10_000)
        }
        throw TestgenPortError(description: "no MCP response to request \(id)")
    }

    func tool(_ id: Int, _ name: String, _ arguments: String, timeout: Double = 30) throws -> JSONValue {
        let reply = try request(
            #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#,
            id: id, timeout: timeout)
        guard case .array(let content)? = reply.value["result"]?["content"], let text = content.first?["text"]?.stringValue,
            reply.value["result"]?["isError"] == nil
        else {
            throw TestgenPortError(description: "tool \(name) failed: \(String(decoding: reply.raw, as: UTF8.self))")
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func closeInputAndWait() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    func close() {
        closeInputAndWait()
    }
}

private extension JSONValue {
    var arrayCount: Int? {
        if case .array(let values) = self { values.count } else { nil }
    }

    /// Follows object keys and array indices to a number, or infinity if it is not there.
    func number(_ path: Any...) -> Double {
        var current: JSONValue? = self
        for step in path {
            if let key = step as? String {
                current = current?[key]
            } else if let index = step as? Int, case .array(let values)? = current, values.indices.contains(index) {
                current = values[index]
            } else {
                current = nil
            }
        }
        switch current {
        case .double(let value)?: return value
        case .int(let value)?: return Double(value)
        default: return .infinity
        }
    }

    /// Strings at `field` in each element of the array at `key`, also looking inside `fields`.
    func strings(_ key: String, _ field: String) -> [String] {
        guard case .array(let values)? = self[key] else { return [] }
        return values.compactMap { $0[field]?.stringValue ?? $0["fields"]?[field]?.stringValue }
    }
}

private struct RandomUART: CustomStringConvertible {
    var baud: Int
    var parity: Parity
    var inverted: Bool
    var payload: [UInt8]
    var description: String { "baud \(baud), \(parity), inverted \(inverted)" }

    /// Parses `random baud=57600 parity=E stop=2 inverted=1 data=<hex>`.
    init?(reply: String) {
        guard let line = reply.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("random ") }) else {
            return nil
        }
        var fields: [Substring: Substring] = [:]
        for field in line.split(separator: " ").dropFirst() {
            let parts = field.split(separator: "=")
            guard parts.count == 2 else { return nil }
            fields[parts[0]] = parts[1]
        }
        guard let baud = fields["baud"].flatMap({ Int($0) }), let inverted = fields["inverted"], let data = fields["data"]
        else {
            return nil
        }
        self.baud = baud
        parity = fields["parity"] == "E" ? .even : fields["parity"] == "O" ? .odd : .none
        self.inverted = inverted == "1"
        let digits = Array(data)
        payload = stride(from: 0, to: digits.count - 1, by: 2).compactMap { UInt8(String(digits[$0...($0 + 1)]), radix: 16) }
    }
}

private func identify(seconds: Double = 0.2) async throws -> ChannelIdentification {
    try await runIdentify(
        DigitalCaptureRequest(
            channels: Array(0...7), sampleRate: 50_000_000, mode: .timed(seconds: seconds), levelVolts: 3.3,
            deviceID: nil),
        confirm: true, endpoint: Logic2Endpoint())
}

private func decode(_ decoder: ProtocolDecoder, radix: Radix = .hex, seconds: Double = 0.12) async throws -> [DecodedRow] {
    try await runDecode(
        DecodeRequest(
            capture: DigitalCaptureRequest(
                channels: decoder.channels, sampleRate: 50_000_000, mode: .timed(seconds: seconds), levelVolts: 3.3,
                deviceID: nil),
            decoder: decoder, radix: radix),
        endpoint: Logic2Endpoint())
}

private func decodeTriggered(
    _ kind: TriggerKind,
    channel: UInt32 = 1,
    minimum: Double? = nil,
    maximum: Double? = nil,
    linked: [LinkedChannel] = [],
    timeout: Double = 5
) async throws -> [DecodedRow] {
    let trigger = DigitalTrigger(
        point: TriggerPoint(channel: channel, kind: kind), afterSeconds: 0.05, minimumPulse: minimum.map(Seconds.init),
        maximumPulse: maximum.map(Seconds.init), linked: linked, timeoutSeconds: timeout)
    let channels = Array(Set([2, channel] + linked.map(\.channel))).sorted()
    return try await runDecode(
        DecodeRequest(
            capture: DigitalCaptureRequest(
                channels: channels, sampleRate: 50_000_000, mode: .trigger(trigger), levelVolts: 3.3, deviceID: nil),
            decoder: .uart(uart)),
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
            channels: Array(0...7), sampleRate: 50_000_000, mode: .timed(seconds: 0.02), levelVolts: 3.3, deviceID: nil)
        try await withLogic2(Logic2Endpoint()) { manager in
            let backend = GRPCCaptureBackend(manager: manager)
            try await runCapture(request, using: backend, cancellation: CaptureCancellation()) { captureID in
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

    @Test("Traffic follows a rising trigger on the sync channel, at time zero")
    func triggerFollowsSync() async throws {
        try await withTestgen(mode: "c") {
            let rows = try await decodeTriggered(.rising)
            let after = rows.filter { $0.start >= 0 }
            let first = try #require(after.first)
            #expect(first.start < 150e-6, "first row at \(first.start)")
            #expect(contains(after.prefix(13).compactMap { word($0) }, message))
        }
    }

    @Test("A falling trigger works too")
    func triggerFalling() async throws {
        try await withTestgen(mode: "c") {
            let after = try await decodeTriggered(.falling).filter { $0.start >= 0 }
            #expect(contains(after.prefix(13).compactMap { word($0) }, message))
        }
    }

    @Test("A pulse trigger fires inside the sync pulse's width and not outside it")
    func triggerPulseWindow() async throws {
        try await withTestgen(mode: "c") {
            _ = try await decodeTriggered(.high, minimum: 10e-6, maximum: 25e-6)
            await #expect(throws: CaptureError.triggerTimeout(seconds: 1)) {
                try await decodeTriggered(.high, minimum: 100e-6, maximum: 200e-6, timeout: 1)
            }
        }
    }

    @Test("A pulse trigger works with no bounds and with only a minimum")
    func triggerOpenEnded() async throws {
        try await withTestgen(mode: "c") {
            _ = try await decodeTriggered(.high)
            _ = try await decodeTriggered(.high, minimum: 10e-6)
            await #expect(throws: CaptureError.triggerTimeout(seconds: 1)) {
                try await decodeTriggered(.high, minimum: 100e-6, timeout: 1)
            }
        }
    }

    @Test("A low pulse trigger matches the chip select frame")
    func triggerPulseLow() async throws {
        try await withTestgen(mode: "c") {
            _ = try await decodeTriggered(.low, channel: 5, minimum: 30e-6, maximum: 70e-6)
            await #expect(throws: CaptureError.triggerTimeout(seconds: 1)) {
                try await decodeTriggered(.low, channel: 5, minimum: 1e-6, maximum: 5e-6, timeout: 1)
            }
        }
    }

    @Test("A linked channel gates the trigger on its level")
    func triggerLinked() async throws {
        try await withTestgen(mode: "c") {
            _ = try await decodeTriggered(.rising, linked: [LinkedChannel(channel: 5, isHigh: true)])
            await #expect(throws: CaptureError.triggerTimeout(seconds: 1)) {
                try await decodeTriggered(.rising, linked: [LinkedChannel(channel: 5, isHigh: false)], timeout: 1)
            }
        }
    }

    @Test("Glitch filters keep pulses above their width and remove those below", arguments: [
        (5e-6, true), (25e-6, false),
    ])
    func glitchFilter(width: Double, keepsPulses: Bool) async throws {
        var capture = DigitalCaptureRequest(
            channels: [1], sampleRate: 50_000_000, mode: .timed(seconds: 0.2), levelVolts: 3.3, deviceID: nil)
        capture.glitchFilters = [GlitchFilter(channel: 1, width: Seconds(width))]
        let summary = try await runDigitalCapture(capture, endpoint: Logic2Endpoint())
        #expect((summary.channels[0].edges > 0) == keepsPulses)
    }

    @Test("A manual capture runs until its limit")
    func manualLimit() async throws {
        let capture = DigitalCaptureRequest(
            channels: Array(0...7), sampleRate: 50_000_000,
            mode: .manual(limitSeconds: 1, stop: CaptureCancellation()), levelVolts: 3.3, deviceID: nil)
        let summary = try await runDigitalCapture(capture, endpoint: Logic2Endpoint())
        try Testgen.verify(summary)
        #expect(abs(summary.durationSeconds - 1) < 0.3)
    }

    @Test("Stopping a manual capture ends it and keeps the data")
    func manualStop() async throws {
        let stop = CaptureCancellation()
        let capture = DigitalCaptureRequest(
            channels: Array(0...7), sampleRate: 50_000_000,
            mode: .manual(limitSeconds: nil, stop: stop), levelVolts: 3.3, deviceID: nil)
        let task = Task { try await runDigitalCapture(capture, endpoint: Logic2Endpoint()) }
        try await Task.sleep(for: .seconds(1))
        stop.cancel()
        let summary = try await task.value
        try Testgen.verify(summary)
        #expect(summary.durationSeconds < 2)
    }

    @Test("Trim keeps only the end of a capture", arguments: [true, false])
    func trim(manual: Bool) async throws {
        let mode: CaptureMode = manual
            ? .manual(limitSeconds: 0.6, trimSeconds: 0.1, stop: CaptureCancellation())
            : .timed(seconds: 0.6, trimSeconds: 0.1)
        let capture = DigitalCaptureRequest(
            channels: [1], sampleRate: 50_000_000, mode: mode, levelVolts: 3.3, deviceID: nil)
        let summary = try await runDigitalCapture(capture, endpoint: Logic2Endpoint())
        #expect(abs(summary.durationSeconds - 0.1) < 0.02)
    }

    @Test("Hitting the buffer limit is reported and the next capture is clean")
    func bufferLimit() async throws {
        var capture = DigitalCaptureRequest(
            channels: [1, 2, 5], sampleRate: 50_000_000, mode: .timed(seconds: 3), levelVolts: 3.3, deviceID: nil)
        capture.bufferMegabytes = 1
        let limited = capture
        await #expect(throws: (any Error).self) {
            try await runDigitalCapture(limited, endpoint: Logic2Endpoint())
        }
        capture.bufferMegabytes = nil
        capture.mode = .timed(seconds: 0.1)
        _ = try await runDigitalCapture(capture, endpoint: Logic2Endpoint())
    }

    @Test("The capture command takes trigger and glitch options")
    func triggerCommand() async throws {
        let command = try CaptureCommand.parseAsRoot([
            "--channels", "1,2", "--trigger", "1:rising", "--duration", "0.05", "--glitch", "2:1us",
        ]) as! CaptureCommand
        try await command.run()
    }

    @Test("The clean testgen traffic is identified and confirmed")
    func identifyClean() async throws {
        let result = try await withTestgen(mode: "c") { try await identify() }
        #expect(result.buses.map(\.decoder) == [
            .uart(uart), .spi(SPIDecoder(clock: 3, mosi: 4, enable: 5)), .i2c(i2c),
        ])
        #expect(result.buses.allSatisfy { $0.confidence == .confirmed })
        #expect(result.periodic.map(\.channel) == [0, 1])
        #expect(result.unknown.isEmpty)
    }

    @Test("Format and SPI mode are worked out from the wires", arguments: [
        ("a", false, true, false, Parity.none),
        ("b", true, false, false, .even),
        ("d", true, true, false, .odd),
        ("h", false, false, true, .none),
    ] as [(Character, Bool, Bool, Bool, Parity)])
    func identifyFormats(mode: Character, cpol: Bool, cpha: Bool, activeHigh: Bool, parity: Parity) async throws {
        try await withTestgen(mode: mode) {
            let result = try await identify()
            let spi = try #require(result.buses.compactMap { bus -> SPIDecoder? in
                if case .spi(let spi) = bus.decoder { spi } else { nil }
            }.first)
            #expect(spi == SPIDecoder(
                clock: 3, mosi: 4, enable: 5, clockIdlesHigh: cpol, dataOnTrailingEdge: cpha, enableActiveHigh: activeHigh))

            let serial = try #require(result.buses.compactMap { bus -> UARTDecoder? in
                if case .uart(let serial) = bus.decoder { serial } else { nil }
            }.first)
            #expect(serial.channel == 2)
            #expect(serial.baud == 115_200)
            #expect(serial.inverted == (mode == "h"))
            if mode != "a" { #expect(serial.parity == parity) }
        }
    }

    @Test("A random UART is worked out blind", arguments: Array(0..<12) + Array(100..<106))
    func randomUART(run: Int) async throws {
        // The later runs force the fastest rate, where the edges jitter most.
        try await withTestgenReply(mode: run < 100 ? "r" : "R") { reply in
            let truth = try #require(RandomUART(reply: reply), "\(reply)")
            // Enough for several complete messages at this baud rate.
            let seconds = max(0.2, 3 * Double(truth.payload.count) * 12 / Double(truth.baud))
            let result = try await identify(seconds: seconds)

            let bus = try #require(result.buses.first { $0.decoder.channels == [2] }, "\(truth)")
            guard case .uart(let serial) = bus.decoder else {
                Issue.record("not uart: \(truth)")
                return
            }
            // At the forced top rate the bit-banged signal itself runs a few percent slow.
            let tolerance = run < 100 ? 0.031 : 0.07
            #expect(abs(Double(serial.baud) - Double(truth.baud)) <= Double(truth.baud) * tolerance, "\(serial.baud) vs \(truth)")
            #expect(serial.inverted == truth.inverted, "\(truth)")
            #expect(serial.parity == truth.parity, "\(truth)")
            #expect(bus.confidence == .confirmed, "\(truth)")

            let rows = try await decode(.uart(serial), seconds: seconds)
            #expect(contains(rows.compactMap { word($0) }, truth.payload.map(UInt64.init)), "\(truth)")
        }
    }

    @Test("PWM on analog reads 0 V and 3.3 V at the expected duty")
    func analogPWM() async throws {
        let summary = try await runDigitalCapture(analogRequest(digital: []), endpoint: Logic2Endpoint())
        let analog = try #require(summary.analog.first)
        verifyAnalogPWM(analog)
    }

    @Test("Analog and digital on one channel agree with each other")
    func analogAndDigital() async throws {
        let summary = try await runDigitalCapture(
            analogRequest(digital: [0, 1], digitalRate: 6_250_000), endpoint: Logic2Endpoint())
        verifyAnalogPWM(try #require(summary.analog.first))
        let digital = try #require(summary.channels[0].periodic)
        #expect(abs(digital.frequencyHz - 1000) < 10)
        #expect(abs(digital.dutyPercent - 25) < 1)
        #expect(summary.channels[1].edges > 0)
    }

    @Test("Downsampling keeps the same answer with fewer samples")
    func analogDownsample() async throws {
        var capture = analogRequest(digital: [])
        capture.analog?.downsample = 10
        let summary = try await runDigitalCapture(capture, endpoint: Logic2Endpoint())
        let analog = try #require(summary.analog.first)
        #expect(analog.sampleRateHz == 156_250)
        verifyAnalogPWM(analog)
    }

    @Test("Eight analog channels capture at once")
    func analogEight() async throws {
        var capture = analogRequest(digital: [])
        capture.analog?.channels = Array(0...7)
        let summary = try await runDigitalCapture(capture, endpoint: Logic2Endpoint())
        #expect(summary.analog.map(\.channel) == Array(0...7))
        verifyAnalogPWM(summary.analog[0])
    }

    @Test("A sample rate pairing Logic 2 refuses is reported")
    func analogBadPairing() async {
        let capture = analogRequest(digital: [0], digitalRate: 500_000_000)
        await #expect(throws: (any Error).self) {
            try await runDigitalCapture(capture, endpoint: Logic2Endpoint())
        }
    }

    @Test("The capture command takes analog options", arguments: [
        ["--channels", "none", "--analog", "0"],
        ["--channels", "0-1", "--analog", "0", "--analog-downsample", "5", "--json"],
    ])
    func analogCommand(arguments: [String]) async throws {
        let command = try CaptureCommand.parseAsRoot(arguments + ["--duration", "0.02"]) as! CaptureCommand
        try await command.run()
    }

    @Test("Saving and reloading gives an identical summary")
    func saveAndReload() async throws {
        try await inScratch { directory in
            var original = analogRequest(digital: Array(0...7))
            original.savePath = directory.appendingPathComponent("saved.sal").path
            let first = try await runDigitalCapture(original, endpoint: Logic2Endpoint())

            let again = try await runDigitalCapture(loadRequest(original.savePath!), endpoint: Logic2Endpoint())
            #expect(again == first)
            #expect(again.channels.map(\.channel) == Array(0...7))
            #expect(again.analog.map(\.channel) == [0])
        }
    }

    @Test("A saved capture decodes and identifies like a live one")
    func decodeAndIdentifySaved() async throws {
        try await withTestgen(mode: "c") {
            try await inScratch { directory in
                let file = directory.appendingPathComponent("saved.sal").path
                var capture = DigitalCaptureRequest(
                    channels: Array(0...7), sampleRate: 50_000_000, mode: .timed(seconds: 0.2), levelVolts: 3.3, deviceID: nil)
                capture.savePath = file
                _ = try await runDigitalCapture(capture, endpoint: Logic2Endpoint())

                let rows = try await runDecode(
                    DecodeRequest(capture: loadRequest(file), decoder: .uart(uart)), endpoint: Logic2Endpoint())
                #expect(contains(rows.compactMap { word($0) }, message))

                let result = try await runIdentify(loadRequest(file), confirm: true, endpoint: Logic2Endpoint())
                #expect(result.buses.map(\.decoder) == [
                    .uart(uart), .spi(SPIDecoder(clock: 3, mosi: 4, enable: 5)), .i2c(i2c),
                ])
            }
        }
    }

    @Test("A missing file is reported")
    func loadMissing() async {
        await #expect(throws: (any Error).self) {
            try await runDigitalCapture(loadRequest("/nonexistent/none.sal"), endpoint: Logic2Endpoint())
        }
    }

    @Test("Logic 2's own CSV agrees with the binary parser, digital and analog")
    func csvOracle() async throws {
        try await inScratch { directory in
            var capture = DigitalCaptureRequest(
                channels: Array(0...7), sampleRate: 6_250_000, mode: .timed(seconds: 0.05), levelVolts: 3.3, deviceID: nil,
                analog: AnalogCapture(channels: [0, 1], sampleRate: 1_562_500, downsample: 100))
            let csvDirectory = directory.appendingPathComponent("csv")
            try FileManager.default.createDirectory(at: csvDirectory, withIntermediateDirectories: true)
            capture.rawCSV = RawCSVExport(directory: csvDirectory.path, iso8601: false)

            let binary = directory.appendingPathComponent("binary")
            try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
            try await withLogic2(Logic2Endpoint()) { manager in
                try await exportDigitalCapture(
                    capture, to: binary, using: GRPCCaptureBackend(manager: manager), cancellation: CaptureCancellation())
            }

            let table = try parseCSV(Data(contentsOf: csvDirectory.appendingPathComponent("digital.csv")))
            let channels = try loadChannels(directory: binary, channels: Array(0...7))
            #expect(table[0] == ["Time [s]"] + (0...7).map { "Channel \($0)" })
            for column in 1...8 {
                var previous = table[1][column]
                var edges: [Double] = []
                for row in table.dropFirst(2) where row[column] != previous {
                    edges.append(Double(row[0])!)
                    previous = row[column]
                }
                let parsed = channels[column - 1]
                #expect(edges.count == parsed.times.count, "channel \(column - 1)")
                #expect(zip(edges, parsed.times).allSatisfy { abs($0 - $1) < 2e-9 }, "channel \(column - 1)")
                #expect(Int(table[1][column]) == parsed.summary.initialLevel, "channel \(column - 1)")
            }

            let analogTable = try parseCSV(Data(contentsOf: csvDirectory.appendingPathComponent("analog.csv")))
            #expect(analogTable[0] == ["Time [s]", "Channel 0", "Channel 1"])
            for (column, channel) in [UInt32(0), 1].enumerated() {
                let parsed = try AnalogChannel(contentsOf: binary.appendingPathComponent("analog_\(channel).bin"))
                #expect(analogTable.count - 1 == parsed.sampleCount)
                parsed.withSamples { samples in
                    for index in 0..<samples.count {
                        let text = analogTable[index + 1][column + 1]
                        #expect(abs(Double(text)! - samples[index]) < 0.001, "channel \(channel) sample \(index)")
                    }
                }
            }
        }
    }

    @Test("Table exports honor time format, columns and filter")
    func tableExports() async throws {
        try await withTestgen(mode: "c") {
            try await inScratch { directory in
                func export(_ edit: (inout TableExport) -> Void) async throws -> [[String]] {
                    let file = directory.appendingPathComponent("t-\(UUID().uuidString).csv")
                    var table = TableExport(path: file.path)
                    edit(&table)
                    var request = DecodeRequest(capture: analogFreeCapture(channels: [2]), decoder: .uart(uart))
                    request.tableExport = table
                    _ = try await runDecode(request, endpoint: Logic2Endpoint())
                    return try parseCSV(Data(contentsOf: file))
                }

                let iso = try await export { $0.iso8601 = true }
                #expect(iso[1][2].contains("T") && iso[1][2].hasSuffix("+00:00"))

                let columns = try await export { $0.columns = ["data"] }
                #expect(columns[0] == ["name", "data"])
                #expect(columns.dropFirst().allSatisfy { $0.count == 2 })

                let filtered = try await export {
                    $0.filterQuery = "0x54"
                    $0.filterColumns = ["data"]
                }
                #expect(filtered.count > 1)
                #expect(filtered.dropFirst().allSatisfy { $0.last == "0x54" })
            }
        }
    }

    @Test("A legacy export holds the decoded bytes")
    func legacyExport() async throws {
        try await withTestgen(mode: "c") {
            try await inScratch { directory in
                let file = directory.appendingPathComponent("legacy.txt")
                var request = DecodeRequest(capture: analogFreeCapture(channels: [2]), decoder: .uart(uart))
                request.legacyPath = file.path
                _ = try await runDecode(request, endpoint: Logic2Endpoint())
                let table = try parseCSV(Data(contentsOf: file))
                #expect(table[0][0..<2] == ["Time [s]", "Value"])
                let values = table.dropFirst().compactMap { UInt64($0[1].dropFirst(2), radix: 16) }
                #expect(contains(values, message))
            }
        }
    }

    @Test("A high level analyzer's settings and rows come through")
    func highLevelAnalyzer() async throws {
        try await withTestgen(mode: "c") {
            var request = DecodeRequest(capture: analogFreeCapture(channels: [2]), decoder: .uart(uart))
            request.highLevel = HighLevelRequest(
                extensionDirectory: testExtensionDirectory, name: "Byte Tagger",
                settings: [
                    HighLevelSetting(key: "prefix", value: .text(">")),
                    HighLevelSetting(key: "scale", value: .number(2)),
                    HighLevelSetting(key: "case", value: .text("lower")),
                ])
            let rows = try await runDecode(request, endpoint: Logic2Endpoint())
            #expect(rows.allSatisfy { $0.type == "tagged" })
            let tags = rows.compactMap { $0.fields["text"] }
            #expect(contains(tags, ">testgen uart\n".dropFirst().map { ">\($0)" }))
            let scaled = rows.first { $0.fields["text"] == ">t" }?.fields["scaled"]
            #expect(scaled == "168")
        }
    }

    @Test("A bad high level analyzer is reported, and the next capture is clean", arguments: [
        ("Byte Tagger", "nonsense"), ("No Such Analyzer", "keep"),
    ])
    func highLevelErrors(name: String, choice: String) async throws {
        var request = DecodeRequest(capture: analogFreeCapture(channels: [2]), decoder: .uart(uart))
        request.highLevel = HighLevelRequest(
            extensionDirectory: testExtensionDirectory, name: name,
            settings: [
                HighLevelSetting(key: "prefix", value: .text("")),
                HighLevelSetting(key: "scale", value: .number(1)),
                HighLevelSetting(key: "case", value: .text(choice)),
            ])
        let attempt = request
        await #expect(throws: (any Error).self) { try await runDecode(attempt, endpoint: Logic2Endpoint()) }
        _ = try await runDecode(
            DecodeRequest(capture: analogFreeCapture(channels: [2]), decoder: .uart(uart)), endpoint: Logic2Endpoint())
    }

    @Test("The commands take file options")
    func fileCommands() async throws {
        try await inScratch { directory in
            let saved = directory.appendingPathComponent("c.sal").path
            let csv = directory.appendingPathComponent("csv")
            try FileManager.default.createDirectory(at: csv, withIntermediateDirectories: true)

            let capture = try CaptureCommand.parseAsRoot([
                "--channels", "0-2", "--duration", "0.05", "--save", saved, "--export-csv", csv.path, "--iso8601",
            ]) as! CaptureCommand
            try await capture.run()
            #expect(FileManager.default.fileExists(atPath: csv.appendingPathComponent("digital.csv").path))

            let load = try CaptureCommand.parseAsRoot(["--load", saved]) as! CaptureCommand
            try await load.run()

            let identify = try IdentifyCommand.parseAsRoot(["--load", saved, "--no-confirm"]) as! IdentifyCommand
            try await identify.run()

            let table = directory.appendingPathComponent("t.csv").path
            let legacy = directory.appendingPathComponent("l.txt").path
            let decode = try UARTCommand.parseAsRoot([
                "--channel", "2", "--baud", "115200", "--load", saved, "--export-table", table, "--export-legacy", legacy,
                "--hla", "Byte Tagger", "--hla-extension", testExtensionDirectory, "--hla-setting", "prefix=x",
                "--hla-setting", "scale=1", "--hla-setting", "case=keep", "--limit", "2",
            ]) as! UARTCommand
            try await decode.run()
            #expect(FileManager.default.fileExists(atPath: table))
            #expect(FileManager.default.fileExists(atPath: legacy))
        }
    }

    @Test("The tool list through a real server is small")
    func mcpList() async throws {
        let server = try MCPProcess()
        defer { server.close() }
        let reply = try server.request(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, id: 1)
        #expect(reply.raw.count < 20_000, "\(reply.raw.count) bytes")
    }

    @Test("Known answers come back through a real MCP server")
    func mcpKnownAnswers() async throws {
        let server = try MCPProcess()
        defer { server.close() }

        _ = try server.request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#, id: 1)
        try server.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        let status = try server.tool(2, "status", "{}")
        #expect(status["devices"]?.arrayCount == 1)

        let capture = try server.tool(3, "capture", #"{"channels":"0-1","analog":"0","duration":0.03}"#)
        #expect(abs(capture.number("channels", 0, "periodic", "frequencyHz") - 1000) < 15)
        #expect(abs(capture.number("analog", 0, "periodic", "dutyPercent") - 25) < 3)
        #expect(abs(capture.number("analog", 0, "levels", "highVolts") - 3.3) < 0.3)

        let uartRows = try server.tool(4, "decode", #"{"bus":{"protocol":"uart","channel":2,"baud":115200},"duration":0.1,"radix":"ascii"}"#)
        #expect(uartRows.strings("rows", "data").joined().contains("TESTGEN UART\n"))

        let spiRows = try server.tool(5, "decode", #"{"bus":{"protocol":"spi","clock":3,"mosi":4,"enable":5},"duration":0.1}"#)
        #expect(contains(spiRows.strings("rows", "mosi"), ["0xA5", "0x5A", "0x00", "0xFF", "0x12", "0x34"]))

        let i2cRows = try server.tool(6, "decode", #"{"bus":{"protocol":"i2c","sda":6,"scl":7},"duration":0.1}"#)
        #expect(contains(i2cRows.strings("rows", "data"), ["0xDE", "0xAD", "0xBE", "0xEF"]))
        #expect(i2cRows["issues"] == .object([:]))

        let paged = try server.tool(7, "decode", #"{"bus":{"protocol":"i2c","sda":6,"scl":7},"duration":0.1,"offset":2,"limit":3}"#)
        #expect(paged["rows"]?.arrayCount == 3)
        #expect(paged["offset"] == .int(2))

        let wiring = try server.tool(8, "identify", #"{"duration":0.2}"#)
        #expect(wiring["buses"]?.arrayCount == 3)
        #expect(wiring.strings("buses", "confidence") == ["confirmed", "confirmed", "confirmed"])
        #expect(wiring.strings("buses", "command").contains("sal decode i2c --sda 6 --scl 7"))
    }

    @Test("Bad input through a real server is a readable tool error")
    func mcpBadInput() async throws {
        let server = try MCPProcess()
        defer { server.close() }
        let reply = try server.request(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture","arguments":{"duration":0}}}"#, id: 1)
        #expect(reply.value["result"]?["isError"] == .bool(true))
    }

    @Test("Cancelling a long capture through a real server ends it, and the next call is clean")
    func mcpCancel() async throws {
        let server = try MCPProcess()
        defer { server.close() }
        try server.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture","arguments":{"duration":60,"channels":"0"}}}"#)
        try await Task.sleep(for: .seconds(2))
        try server.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#)

        let next = try server.tool(2, "capture", #"{"channels":"0","duration":0.05}"#, timeout: 15)
        #expect(abs(next.number("channels", 0, "periodic", "frequencyHz") - 1000) < 15)
        #expect(server.hasResponse(id: 1) == false)
    }

    @Test("Closing stdin during a capture ends the server, and the next capture is clean")
    func mcpDisconnect() async throws {
        let server = try MCPProcess()
        try server.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture","arguments":{"duration":60,"channels":"0"}}}"#)
        try await Task.sleep(for: .seconds(2))
        let clock = ContinuousClock()
        let closed = clock.now
        server.closeInputAndWait()
        #expect(clock.now - closed < .seconds(15))
        _ = try await runDigitalCapture(analogFreeCapture(channels: [0]), endpoint: Logic2Endpoint())
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
                channels: [2], sampleRate: 50_000_000, mode: .timed(seconds: 60), levelVolts: 3.3, deviceID: nil),
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
