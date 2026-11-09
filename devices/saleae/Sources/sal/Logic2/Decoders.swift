import ArgumentParser

typealias AnalyzerSetting = Saleae_Automation_AnalyzerSettingValue

private func text(_ value: String) -> AnalyzerSetting {
    var setting = AnalyzerSetting()
    setting.stringValue = value
    return setting
}

private func number(_ value: Int64) -> AnalyzerSetting {
    var setting = AnalyzerSetting()
    setting.int64Value = value
    return setting
}

/// Logic 2 accepts 1 through 64 bits per word on both analyzers.
let wordBits: ClosedRange<Int> = 1...64

enum Parity: String, CaseIterable, ExpressibleByArgument, Sendable {
    case none, even, odd

    var setting: String {
        switch self {
        case .none: "No Parity Bit (Standard)"
        case .even: "Even Parity Bit"
        case .odd: "Odd Parity Bit"
        }
    }
}

enum StopBits: String, CaseIterable, ExpressibleByArgument, Sendable {
    case one = "1", oneAndHalf = "1.5", two = "2"

    var setting: String {
        switch self {
        case .one: "1 Stop Bit (Standard)"
        case .oneAndHalf: "1.5 Stop Bits"
        case .two: "2 Stop Bits"
        }
    }
}

enum BitOrder: String, CaseIterable, ExpressibleByArgument, Sendable {
    case lsb, msb
}

enum UARTMode: String, CaseIterable, ExpressibleByArgument, Sendable {
    case normal, mp, mdb

    var setting: String {
        switch self {
        case .normal: "Normal"
        case .mp: "MP - Address indicated by MSB=0"
        case .mdb: "MDB - Address indicated by MSB=1 (TX only)"
        }
    }
}

enum Radix: String, CaseIterable, ExpressibleByArgument, Sendable {
    case hex, dec, bin, ascii

    var type: Saleae_Automation_RadixType {
        switch self {
        case .hex: .hexadecimal
        case .dec: .decimal
        case .bin: .binary
        case .ascii: .ascii
        }
    }
}

struct UARTDecoder: Equatable, Sendable {
    var channel: UInt32
    var baud: Int64
    var bits = 8
    var parity = Parity.none
    var stop = StopBits.one
    var order = BitOrder.lsb
    var inverted = false
    var mode = UARTMode.normal

    var settings: [String: AnalyzerSetting] {
        let wordSize: String =
            switch bits {
            case 1: "1 Bit per Transfer"
            case 8: "8 Bits per Transfer (Standard)"
            default: "\(bits) Bits per Transfer"
            }
        return [
            "Input Channel": number(Int64(channel)),
            "Bit Rate (Bits/s)": number(baud),
            "Bits per Frame": text(wordSize),
            "Stop Bits": text(stop.setting),
            "Parity Bit": text(parity.setting),
            "Significant Bit": text(
                order == .lsb ? "Least Significant Bit Sent First (Standard)" : "Most Significant Bit Sent First"),
            "Signal inversion": text(inverted ? "Inverted" : "Non Inverted (Standard)"),
            "Mode": text(mode.setting),
        ]
    }
}

struct SPIDecoder: Equatable, Sendable {
    var clock: UInt32
    var mosi: UInt32?
    var miso: UInt32?
    var enable: UInt32?
    var bits = 8
    var order = BitOrder.msb
    var clockIdlesHigh = false
    var dataOnTrailingEdge = false
    var enableActiveHigh = false

    var settings: [String: AnalyzerSetting] {
        var settings: [String: AnalyzerSetting] = [
            "Clock": number(Int64(clock)),
            "Significant Bit": text(
                order == .msb ? "Most Significant Bit First (Standard)" : "Least Significant Bit First"),
            "Bits per Transfer": text(bits == 8 ? "8 Bits per Transfer (Standard)" : "\(bits) Bits per Transfer"),
            "Clock State": text(
                clockIdlesHigh ? "Clock is High when inactive (CPOL = 1)" : "Clock is Low when inactive (CPOL = 0)"),
            "Clock Phase": text(
                dataOnTrailingEdge
                    ? "Data is Valid on Clock Trailing Edge (CPHA = 1)"
                    : "Data is Valid on Clock Leading Edge (CPHA = 0)"),
            "Enable Line": text(
                enableActiveHigh ? "Enable line is Active High" : "Enable line is Active Low (Standard)"),
        ]
        if let mosi { settings["MOSI"] = number(Int64(mosi)) }
        if let miso { settings["MISO"] = number(Int64(miso)) }
        if let enable { settings["Enable"] = number(Int64(enable)) }
        return settings
    }
}

struct I2CDecoder: Equatable, Sendable {
    var sda: UInt32
    var scl: UInt32

    var settings: [String: AnalyzerSetting] {
        ["SDA": number(Int64(sda)), "SCL": number(Int64(scl))]
    }
}

enum ProtocolDecoder: Equatable, Sendable {
    case uart(UARTDecoder)
    case spi(SPIDecoder)
    case i2c(I2CDecoder)

    var analyzerName: String {
        switch self {
        case .uart: "Async Serial"
        case .spi: "SPI"
        case .i2c: "I2C"
        }
    }

    var settings: [String: AnalyzerSetting] {
        switch self {
        case .uart(let uart): uart.settings
        case .spi(let spi): spi.settings
        case .i2c(let i2c): i2c.settings
        }
    }

    /// Every channel the analyzer reads, which is what has to be captured.
    var channels: [UInt32] {
        switch self {
        case .uart(let uart): [uart.channel]
        case .spi(let spi): [spi.clock, spi.mosi, spi.miso, spi.enable].compactMap { $0 }.sorted()
        case .i2c(let i2c): [i2c.sda, i2c.scl].sorted()
        }
    }
}

/// A setting for a high level analyzer, written as `key=value`. Values that read as
/// numbers are sent as numbers, because that is what number settings require.
struct HighLevelSetting: ExpressibleByArgument, Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case text(String)
        case number(Double)
    }

    var key: String
    var value: Value

    init(key: String, value: Value) {
        self.key = key
        self.value = value
    }

    init?(argument: String) {
        guard let separator = argument.firstIndex(of: "="), separator != argument.startIndex else { return nil }
        let text = String(argument[argument.index(after: separator)...])
        key = String(argument[..<separator])
        if let number = Double(text), number.isFinite {
            value = .number(number)
        } else {
            value = .text(text)
        }
    }

    var wireValue: Saleae_Automation_HighLevelAnalyzerSettingValue {
        var setting = Saleae_Automation_HighLevelAnalyzerSettingValue()
        switch value {
        case .text(let text): setting.stringValue = text
        case .number(let number): setting.numberValue = number
        }
        return setting
    }
}

/// A high level analyzer fed by the protocol decoder. Its rows replace the decoder's.
struct HighLevelRequest: Equatable, Sendable {
    /// The directory holding `extension.json`. Absolute.
    var extensionDirectory: String
    var name: String
    var settings: [HighLevelSetting] = []
}

/// A data table written to a file for the user, with Logic 2's export options.
struct TableExport: Equatable, Sendable {
    var path: String
    var iso8601 = false
    var columns: [String] = []
    var filterQuery: String?
    var filterColumns: [String] = []
}

struct DecodeRequest: Sendable {
    var capture: DigitalCaptureRequest
    var decoder: ProtocolDecoder
    var radix = Radix.hex
    var highLevel: HighLevelRequest?
    var tableExport: TableExport?
    /// Absolute path for Logic 2's older analyzer text export.
    var legacyPath: String?
}

extension ProtocolDecoder {
    var kind: String {
        switch self {
        case .uart: "uart"
        case .spi: "spi"
        case .i2c: "i2c"
        }
    }

    var channelRoles: [String: UInt32] {
        switch self {
        case .uart(let uart): ["signal": uart.channel]
        case .spi(let spi):
            ["clock": spi.clock, "mosi": spi.mosi, "miso": spi.miso, "enable": spi.enable].compactMapValues { $0 }
        case .i2c(let i2c): ["sda": i2c.sda, "scl": i2c.scl]
        }
    }

    /// The `sal decode` command line for this decoder.
    var command: String {
        var parts = ["sal", "decode", kind]
        func add(_ flag: String, _ value: String) { parts += [flag, value] }

        switch self {
        case .uart(let uart):
            add("--channel", "\(uart.channel)")
            add("--baud", "\(uart.baud)")
            if uart.bits != 8 { add("--bits", "\(uart.bits)") }
            if uart.parity != .none { add("--parity", uart.parity.rawValue) }
            if uart.stop != .one { add("--stop", uart.stop.rawValue) }
            if uart.order != .lsb { add("--order", uart.order.rawValue) }
            if uart.inverted { parts.append("--inverted") }
            if uart.mode != .normal { add("--mode", uart.mode.rawValue) }
        case .spi(let spi):
            add("--clock", "\(spi.clock)")
            if let mosi = spi.mosi { add("--mosi", "\(mosi)") }
            if let miso = spi.miso { add("--miso", "\(miso)") }
            if let enable = spi.enable { add("--enable", "\(enable)") }
            if spi.bits != 8 { add("--bits", "\(spi.bits)") }
            if spi.order != .msb { add("--order", spi.order.rawValue) }
            if spi.clockIdlesHigh { add("--cpol", "1") }
            if spi.dataOnTrailingEdge { add("--cpha", "1") }
            if spi.enableActiveHigh { parts.append("--enable-active-high") }
        case .i2c(let i2c):
            add("--sda", "\(i2c.sda)")
            add("--scl", "\(i2c.scl)")
        }
        return parts.joined(separator: " ")
    }
}
