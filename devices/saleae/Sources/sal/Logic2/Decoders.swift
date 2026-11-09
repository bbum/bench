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

struct DecodeRequest: Sendable {
    var capture: DigitalCaptureRequest
    var decoder: ProtocolDecoder
    var radix = Radix.hex
}
