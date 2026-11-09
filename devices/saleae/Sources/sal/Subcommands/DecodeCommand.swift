import ArgumentParser
import Foundation

struct DecodeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode",
        abstract: "Run a timed capture and decode a protocol.",
        subcommands: [UARTCommand.self, SPICommand.self, I2CCommand.self]
    )
}

struct DecodeOptions: ParsableArguments {
    @OptionGroup var capture: CaptureOptions

    @Option(help: "How to show values: hex, dec, bin or ascii.")
    var radix = Radix.hex

    @Option(help: "Rows to skip.")
    var offset = 0

    @Option(help: "Most rows to return. Issue counts always cover every row.")
    var limit = 1000

    @Flag(help: "Print JSON instead of a table.")
    var json = false

    @Option(help: "High level analyzer to run on the decoded data, as named in extension.json.")
    var hla: String?

    @Option(help: "Directory holding the high level analyzer's extension.json.")
    var hlaExtension: String?

    @Option(help: "Setting for the high level analyzer, as key=value. Repeatable.")
    var hlaSetting: [HighLevelSetting] = []

    @Option(help: "Also write Logic 2's data table CSV to this file.")
    var exportTable: String?

    @Flag(help: "Use ISO 8601 timestamps in --export-table.")
    var iso8601 = false

    @Option(help: "Columns for --export-table, comma separated.")
    var columns: String?

    @Option(help: "Only rows matching this text in --export-table.")
    var filter: String?

    @Option(help: "Columns --filter searches, comma separated. Defaults to all.")
    var filterColumns: String?

    @Option(help: "Also write Logic 2's older text export for the decoder to this file.")
    var exportLegacy: String?

    func validate() throws {
        guard (hla == nil) == (hlaExtension == nil) else {
            throw ValidationError("--hla and --hla-extension go together.")
        }
        guard hla != nil || hlaSetting.isEmpty else { throw ValidationError("--hla-setting needs --hla.") }
        guard exportTable != nil || (!iso8601 && columns == nil && filter == nil) else {
            throw ValidationError("--iso8601, --columns and --filter need --export-table.")
        }
        guard filter != nil || filterColumns == nil else { throw ValidationError("--filter-columns needs --filter.") }
        guard offset >= 0 else { throw ValidationError("Offset cannot be negative.") }
        guard limit > 0 else { throw ValidationError("Limit must be positive.") }
    }

    var highLevelRequest: HighLevelRequest? {
        guard let hla, let hlaExtension else { return nil }
        return HighLevelRequest(extensionDirectory: absolutePath(hlaExtension), name: hla, settings: hlaSetting)
    }

    var tableExportRequest: TableExport? {
        exportTable.map {
            func list(_ text: String?) -> [String] { text?.split(separator: ",").map(String.init) ?? [] }
            return TableExport(
                path: absolutePath($0), iso8601: iso8601, columns: list(columns), filterQuery: filter,
                filterColumns: list(filterColumns))
        }
    }

    func run(_ decoder: ProtocolDecoder) async throws {
        let page = try await execute(decoder, handlingSignals: true)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(page), as: UTF8.self))
        } else {
            page.rows.forEach { print(describe($0)) }
            print(pageFooter(page))
        }
    }

    func execute(_ decoder: ProtocolDecoder, handlingSignals: Bool) async throws -> DecodePage {
        let radix = radix
        let highLevel = highLevelRequest
        let tableExport = tableExportRequest
        let legacyPath = exportLegacy.map(absolutePath)
        let endpoint = capture.logic2.endpoint
        let rows = try await capture.perform(channels: decoder.channels, handlingSignals: handlingSignals) { request in
            try await runDecode(
                DecodeRequest(
                    capture: request, decoder: decoder, radix: radix, highLevel: highLevel, tableExport: tableExport,
                    legacyPath: legacyPath),
                endpoint: endpoint)
        }
        return decodePage(rows, offset: offset, limit: limit)
    }
}

/// A decode subcommand, however its protocol is configured.
protocol DecodeInvocation {
    var options: DecodeOptions { get }
    var protocolDecoder: ProtocolDecoder { get }
}

func validateChannels(_ channels: [UInt32]) throws {
    guard channels.allSatisfy({ $0 <= maximumChannel }), Set(channels).count == channels.count else {
        throw ValidationError("Channels must be distinct and at most \(maximumChannel).")
    }
}

func validateWordBits(_ bits: Int) throws {
    guard wordBits.contains(bits) else {
        throw ValidationError("Bits must be from \(wordBits.lowerBound) to \(wordBits.upperBound).")
    }
}

struct UARTCommand: AsyncParsableCommand, DecodeInvocation {
    static let configuration = CommandConfiguration(
        commandName: "uart", abstract: "Decode asynchronous serial.")

    @OptionGroup var options: DecodeOptions

    @Option(help: "Digital channel carrying the signal.")
    var channel: UInt32

    @Option(help: "Bit rate in bits per second.")
    var baud: Int64

    @Option(help: "Data bits per frame, 1 to 64.")
    var bits = 8

    @Option(help: "Parity: none, even or odd.")
    var parity = Parity.none

    @Option(help: "Stop bits: 1, 1.5 or 2.")
    var stop = StopBits.one

    @Option(help: "Bit order: lsb or msb.")
    var order = BitOrder.lsb

    @Flag(help: "The signal idles low.")
    var inverted = false

    @Option(help: "Addressing: normal, mp or mdb. mp and mdb read one extra address bit after --bits.")
    var mode = UARTMode.normal

    func validate() throws {
        try validateChannels([channel])
        try validateWordBits(bits)
        guard baud > 0 else { throw ValidationError("Baud must be positive.") }
    }

    func run() async throws {
        try await options.run(.uart(decoder))
    }

    var protocolDecoder: ProtocolDecoder { .uart(decoder) }

    var decoder: UARTDecoder {
        UARTDecoder(
            channel: channel, baud: baud, bits: bits, parity: parity, stop: stop, order: order,
            inverted: inverted, mode: mode)
    }
}

struct SPICommand: AsyncParsableCommand, DecodeInvocation {
    static let configuration = CommandConfiguration(
        commandName: "spi", abstract: "Decode SPI. Needs a clock and at least one data line.")

    @OptionGroup var options: DecodeOptions

    @Option(help: "Clock channel.")
    var clock: UInt32

    @Option(help: "MOSI channel.")
    var mosi: UInt32?

    @Option(help: "MISO channel.")
    var miso: UInt32?

    @Option(help: "Enable (chip select) channel.")
    var enable: UInt32?

    @Option(help: "Bits per word, 1 to 64.")
    var bits = 8

    @Option(help: "Bit order: lsb or msb.")
    var order = BitOrder.msb

    @Option(help: "Clock polarity, 0 or 1.")
    var cpol = 0

    @Option(help: "Clock phase, 0 or 1.")
    var cpha = 0

    @Flag(help: "The enable line is active high.")
    var enableActiveHigh = false

    func validate() throws {
        guard mosi != nil || miso != nil else { throw ValidationError("Give --mosi, --miso or both.") }
        try validateChannels(ProtocolDecoder.spi(decoder).channels)
        try validateWordBits(bits)
        guard [0, 1].contains(cpol), [0, 1].contains(cpha) else {
            throw ValidationError("--cpol and --cpha must be 0 or 1.")
        }
    }

    func run() async throws {
        try await options.run(.spi(decoder))
    }

    var protocolDecoder: ProtocolDecoder { .spi(decoder) }

    var decoder: SPIDecoder {
        SPIDecoder(
            clock: clock, mosi: mosi, miso: miso, enable: enable, bits: bits, order: order,
            clockIdlesHigh: cpol == 1, dataOnTrailingEdge: cpha == 1, enableActiveHigh: enableActiveHigh)
    }
}

struct I2CCommand: AsyncParsableCommand, DecodeInvocation {
    static let configuration = CommandConfiguration(commandName: "i2c", abstract: "Decode I2C.")

    @OptionGroup var options: DecodeOptions

    @Option(help: "SDA channel.")
    var sda: UInt32

    @Option(help: "SCL channel.")
    var scl: UInt32

    func validate() throws {
        try validateChannels([sda, scl])
    }

    func run() async throws {
        try await options.run(.i2c(I2CDecoder(sda: sda, scl: scl)))
    }

    var protocolDecoder: ProtocolDecoder { .i2c(I2CDecoder(sda: sda, scl: scl)) }
}

func describe(_ row: DecodedRow) -> String {
    let fields = row.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.debugDescription)" }
    return ([String(format: "%.8f", row.start), row.type] + fields).joined(separator: "  ")
}

func pageFooter(_ page: DecodePage) -> String {
    let shown =
        page.rows.isEmpty
        ? "No rows shown of \(page.totalRows)"
        : "Rows \(page.offset + 1)-\(page.offset + page.rows.count) of \(page.totalRows)"
    guard !page.issues.isEmpty else { return "\(shown), no issues" }
    let issues = page.issues.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    return "\(shown), issues: \(issues.joined(separator: ", "))"
}
