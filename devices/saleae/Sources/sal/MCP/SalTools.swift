import ArgumentParser
import Foundation

struct ToolInputError: Error, CustomStringConvertible {
    var description: String
}

/// Turns tool arguments into a command line, so tools share the CLI's parsing and
/// validation. Only known keys pass, and each value is attached with `=`, so no value
/// can be read as another option.
func commandLine(from arguments: JSONValue, allowed: Set<String>, ignoring: Set<String> = []) throws -> [String] {
    guard case .object(let object) = arguments else { throw ToolInputError(description: "Arguments must be an object.") }
    var line: [String] = []
    for key in object.keys.sorted() where !ignoring.contains(key) {
        guard allowed.contains(key) else { throw ToolInputError(description: "Unknown argument: \(key)") }
        let flag = "--" + key.replacingOccurrences(of: "_", with: "-")
        switch object[key]! {
        case .bool(true): line.append(flag)
        case .bool(false): break
        case .array(let values): line += try values.map { "\(flag)=\(try scalarText($0, key: key))" }
        case let value: line.append("\(flag)=\(try scalarText(value, key: key))")
        }
    }
    return line
}

private func scalarText(_ value: JSONValue, key: String) throws -> String {
    switch value {
    case .string(let text): text
    case .int(let number): String(number)
    case .double(let number): String(number)
    default: throw ToolInputError(description: "Argument \(key) has the wrong type.")
    }
}

private func parsed(_ line: [String]) throws -> any ParsableCommand {
    do {
        return try Sal.parseAsRoot(line)
    } catch {
        throw ToolInputError(description: Sal.message(for: error))
    }
}

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// Keeps replies a sensible size. Callers page with `offset` for more.
private let defaultToolRowLimit = 200

/// There is no Ctrl-C through a tool call, so a manual capture has to have an end.
private func requireManualLimit(_ arguments: JSONValue) throws {
    if arguments["manual"] == .bool(true), arguments["duration"] == nil {
        throw ToolInputError(description: "A manual capture needs duration, because a tool call cannot be interrupted by hand.")
    }
}

/// Keeps inline timelines small. Drawn files are not affected.
private let defaultToolSegmentLimit = 100

func timelineCommandLine(_ arguments: JSONValue) throws -> [String] {
    var line = ["timeline"] + (try commandLine(from: arguments, allowed: captureKeys.union(timelineKeys)))
    if arguments["max_segments"] == nil { line.append("--max-segments=\(defaultToolSegmentLimit)") }
    return line
}

func analyzeCommandLine(_ arguments: JSONValue) throws -> [String] {
    guard let analysis = arguments["analysis"], let kind = analysis["kind"]?.stringValue else {
        throw ToolInputError(description: "analyze needs analysis, with kind latency, setup_hold or activity.")
    }
    guard let keys = analysisOptionKeys[kind] else { throw ToolInputError(description: "Unknown analysis: \(kind)") }
    return ["analyze", kind.replacingOccurrences(of: "_", with: "-")]
        + (try commandLine(from: analysis, allowed: keys, ignoring: ["kind"]))
        + (try commandLine(from: arguments, allowed: captureKeys, ignoring: ["analysis"]))
}

func decodeCommandLine(_ arguments: JSONValue) throws -> [String] {
    guard let bus = arguments["bus"], let kind = bus["protocol"]?.stringValue else {
        throw ToolInputError(description: "decode needs bus, with protocol uart, spi or i2c.")
    }
    guard let busKeys = busOptionKeys[kind] else { throw ToolInputError(description: "Unknown protocol: \(kind)") }

    var line = ["decode", kind]
    line += try commandLine(from: bus, allowed: busKeys, ignoring: ["protocol"])
    line += try commandLine(from: arguments, allowed: captureKeys.union(decodeKeys), ignoring: ["bus"])
    if arguments["limit"] == nil { line.append("--limit=\(defaultToolRowLimit)") }
    return line
}

struct SalTools: ToolCatalog {
    func hasTool(named name: String) -> Bool {
        toolDefinitions.contains { $0["name"]?.stringValue == name }
    }

    var definitions: [JSONValue] { toolDefinitions }

    func call(name: String, arguments: JSONValue) async throws -> String {
        switch name {
        case "status": return try await callStatus(arguments)
        case "capture": return try await callCapture(arguments)
        case "decode": return try await callDecode(arguments)
        case "identify": return try await callIdentify(arguments)
        case "analyze": return try await callAnalyze(arguments)
        case "timeline": return try await callTimeline(arguments)
        default: throw ToolInputError(description: "Unknown tool: \(name)")
        }
    }

    private func callStatus(_ arguments: JSONValue) async throws -> String {
        let line = ["status"] + (try commandLine(from: arguments, allowed: ["host", "port"]))
        guard let command = try parsed(line) as? Status else { throw ToolInputError(description: "Bad status command.") }
        return try json(try await command.information())
    }

    private func callCapture(_ arguments: JSONValue) async throws -> String {
        try requireManualLimit(arguments)
        let allowed = captureKeys.union(["channels", "analog", "analog_rate", "analog_downsample", "export_csv", "iso8601"])
        let line = ["capture"] + (try commandLine(from: arguments, allowed: allowed))
        guard let command = try parsed(line) as? CaptureCommand else { throw ToolInputError(description: "Bad capture command.") }
        return try json(try await command.execute(handlingSignals: false))
    }

    private func callIdentify(_ arguments: JSONValue) async throws -> String {
        try requireManualLimit(arguments)
        let line = ["identify"] + (try commandLine(from: arguments, allowed: captureKeys.union(["channels", "no_confirm"])))
        guard let command = try parsed(line) as? IdentifyCommand else { throw ToolInputError(description: "Bad identify command.") }
        return try json(try await command.execute(handlingSignals: false))
    }

    private func callTimeline(_ arguments: JSONValue) async throws -> String {
        try requireManualLimit(arguments)
        guard let command = try parsed(try timelineCommandLine(arguments)) as? TimelineCommand else {
            throw ToolInputError(description: "Bad timeline command.")
        }
        return try json(try await command.execute(handlingSignals: false))
    }

    private func callAnalyze(_ arguments: JSONValue) async throws -> String {
        try requireManualLimit(arguments)
        let parsedCommand = try parsed(try analyzeCommandLine(arguments))
        switch parsedCommand {
        case let command as LatencyCommand: return try json(try await command.execute(handlingSignals: false))
        case let command as SetupHoldCommand: return try json(try await command.execute(handlingSignals: false))
        case let command as ActivityCommand: return try json(try await command.execute(handlingSignals: false))
        default: throw ToolInputError(description: "Bad analyze command.")
        }
    }

    private func callDecode(_ arguments: JSONValue) async throws -> String {
        try requireManualLimit(arguments)
        guard let command = try parsed(try decodeCommandLine(arguments)) as? any DecodeInvocation else {
            throw ToolInputError(description: "Bad decode command.")
        }
        return try json(try await command.options.execute(command.protocolDecoder, handlingSignals: false))
    }
}

private let captureKeys: Set<String> = [
    "host", "port", "rate", "duration", "level", "device", "manual", "trim", "buffer_mb", "glitch", "trigger",
    "pulse_min", "pulse_max", "link", "trigger_timeout", "load", "save",
]

private let decodeKeys: Set<String> = [
    "radix", "offset", "limit", "hla", "hla_extension", "hla_setting", "export_table", "iso8601", "columns", "filter",
    "filter_columns", "export_legacy",
]

private let analysisOptionKeys: [String: Set<String>] = [
    "latency": ["from", "to", "max"],
    "setup_hold": ["clock", "data", "min_setup", "min_hold"],
    "activity": ["channels", "gap"],
]

private let timelineKeys: Set<String> = [
    "channels", "analog", "analog_rate", "analog_downsample", "from", "to", "overlay", "radix", "max_segments", "html",
    "svg", "title",
]

let busOptionKeys: [String: Set<String>] = [
    "uart": ["channel", "baud", "bits", "parity", "stop", "order", "inverted", "mode"],
    "spi": ["clock", "mosi", "miso", "enable", "bits", "order", "cpol", "cpha", "enable_active_high"],
    "i2c": ["sda", "scl"],
]

// MARK: Schemas

private func field(_ type: String, _ description: String) -> JSONValue {
    .object(["type": .string(type), "description": .string(description)])
}

private func choice(_ values: [String], _ description: String) -> JSONValue {
    .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string)), "description": .string(description)])
}

private func bounded(_ range: ClosedRange<Int>, _ description: String) -> JSONValue {
    .object([
        "type": .string("integer"), "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
        "description": .string(description),
    ])
}

private func strings(_ description: String) -> JSONValue {
    .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
}

private func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false),
    ]
    if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
    return .object(schema)
}

private func tool(_ name: String, _ description: String, _ schema: JSONValue) -> JSONValue {
    .object(["name": .string(name), "description": .string(description), "inputSchema": schema])
}

private let channel = bounded(0...15, "Channel index.")
private let wordBitsField = bounded(wordBits.lowerBound...wordBits.upperBound, "Bits per word.")

private let endpointFields: [String: JSONValue] = [
    "host": field("string", "Logic 2 address. Default 127.0.0.1."),
    "port": field("integer", "Logic 2 automation port. Default 10430."),
]

private let captureFields: [String: JSONValue] = endpointFields.merging([
    "rate": field("string", "Digital sample rate, such as 50M. Default 50M, or 6.25M alongside analog."),
    "duration": field("number", "Seconds to capture, default 0.5. With trigger, seconds after it. Required with manual."),
    "level": .object(["type": .string("number"), "enum": .array([.double(1.2), .double(1.8), .double(3.3)]), "description": .string("Logic level in volts.")]),
    "device": field("string", "Device serial number. Default: the first physical device."),
    "manual": field("boolean", "Run for duration, then stop and use what was captured."),
    "trim": field("string", "Keep only the last part, such as 200ms. Not with trigger."),
    "buffer_mb": field("integer", "Logic 2 memory limit in megabytes. Reaching it is an error."),
    "glitch": strings("Ignore pulses narrower than a width, each CH:WIDTH such as 2:5us."),
    "trigger": field("string", "CH:rising, CH:falling, CH:high or CH:low. Time zero is the trigger."),
    "pulse_min": field("string", "Narrowest pulse that triggers, such as 10us. For CH:high and CH:low."),
    "pulse_max": field("string", "Widest pulse that triggers. For CH:high and CH:low."),
    "link": strings("Levels other channels must hold at the trigger, each CH:high or CH:low."),
    "trigger_timeout": field("number", "Seconds to wait for the trigger. Default 10."),
    "load": field("string", "Use this saved .sal file instead of capturing. Takes no capture settings."),
    "save": field("string", "Save the capture to this .sal file."),
]) { first, _ in first }

private let uartBus = object([
    "protocol": .object(["const": .string("uart")]),
    "channel": channel,
    "baud": field("integer", "Bits per second. identify can work this out."),
    "bits": wordBitsField,
    "parity": choice(Parity.allCases.map(\.rawValue), "Default none."),
    "stop": choice(StopBits.allCases.map(\.rawValue), "Stop bits. Default 1."),
    "order": choice(BitOrder.allCases.map(\.rawValue), "Default lsb."),
    "inverted": field("boolean", "The line idles low."),
    "mode": choice(UARTMode.allCases.map(\.rawValue), "mp and mdb read one address bit after bits. Default normal."),
], required: ["protocol", "channel", "baud"])

private let spiBus = object([
    "protocol": .object(["const": .string("spi")]),
    "clock": channel,
    "mosi": channel,
    "miso": channel,
    "enable": channel,
    "bits": wordBitsField,
    "order": choice(BitOrder.allCases.map(\.rawValue), "Default msb."),
    "cpol": bounded(0...1, "Clock polarity. Default 0."),
    "cpha": bounded(0...1, "Clock phase. Default 0."),
    "enable_active_high": field("boolean", "The enable line is active high."),
], required: ["protocol", "clock"])

private let i2cBus = object([
    "protocol": .object(["const": .string("i2c")]),
    "sda": channel,
    "scl": channel,
], required: ["protocol", "sda", "scl"])

private let edgeDescription = "An edge: CH:rising, CH:falling or CH:either."

private let latencyAnalysis = object([
    "kind": .object(["const": .string("latency")]),
    "from": field("string", edgeDescription),
    "to": field("string", "The first such edge after from and before the next from. Same channel, opposite edge, gives pulse width."),
    "max": field("string", "Ignore delays longer than this, such as 5ms."),
], required: ["kind", "from", "to"])

private let setupHoldAnalysis = object([
    "kind": .object(["const": .string("setup_hold")]),
    "clock": field("string", "The sampling edge: CH:rising or CH:falling."),
    "data": .object(["type": .string("array"), "items": channel, "minItems": .int(1), "description": .string("Data channels.")]),
    "min_setup": field("string", "Count setup times shorter than this as violations, such as 20ns."),
    "min_hold": field("string", "Count hold times shorter than this as violations."),
], required: ["kind", "clock", "data"])

private let activityAnalysis = object([
    "kind": .object(["const": .string("activity")]),
    "channels": field("string", "Digital channels: 0-7 or 0,2,4. Default 0-7, or all with load."),
    "gap": field("string", "Edges further apart than this start a new burst. Default 1ms."),
], required: ["kind"])

let toolDefinitions: [JSONValue] = [
    tool(
        "status", "Show the Logic 2 version and the connected devices.", object(endpointFields)),
    tool(
        "capture",
        "Capture digital and optionally analog channels and return a summary of each: edges, frequency, duty, pulse widths, and analog levels.",
        object(captureFields.merging([
            "channels": field("string", "Digital channels: 0-7, 0,2,4, or none with analog. Default 0-7, or all with load."),
            "analog": field("string", "Analog channels to record too, such as 0 or 0-3."),
            "analog_rate": field("string", "Analog sample rate, default 1.5625M. Logic 2's error lists valid pairings with rate."),
            "analog_downsample": bounded(1...1_000_000, "Keep one analog sample in this many."),
            "export_csv": field("string", "Also write Logic 2's raw CSV files to this existing directory."),
            "iso8601": field("boolean", "Use ISO 8601 timestamps in export_csv."),
        ]) { first, _ in first })),
    tool(
        "decode",
        "Capture or load, decode one UART, SPI or I2C bus, and return the rows with counts of framing errors, parity errors and NACKs across all rows.",
        object(captureFields.merging([
            "bus": .object(["oneOf": .array([uartBus, spiBus, i2cBus])]),
            "radix": choice(Radix.allCases.map(\.rawValue), "How values are shown. Default hex."),
            "offset": field("integer", "Rows to skip."),
            "limit": field("integer", "Most rows to return. Default 200. Issue counts cover every row."),
            "hla": field("string", "High level analyzer to run on the decoded data, as named in extension.json."),
            "hla_extension": field("string", "Directory holding that analyzer's extension.json."),
            "hla_setting": strings("Settings for it, each key=value. Values that read as numbers are sent as numbers."),
            "export_table": field("string", "Also write Logic 2's data table CSV to this file."),
            "iso8601": field("boolean", "Use ISO 8601 timestamps in export_table."),
            "columns": field("string", "Columns for export_table, comma separated."),
            "filter": field("string", "Only rows matching this text in export_table."),
            "filter_columns": field("string", "Columns filter searches, comma separated."),
            "export_legacy": field("string", "Also write Logic 2's older text export to this file."),
        ]) { first, _ in first }, required: ["bus"])),
    tool(
        "identify",
        "Work out what is on each channel from timing: I2C, SPI and UART with baud rate, then confirm each by decoding. Use when the wiring is unknown or suspect. Notes say what timing cannot show.",
        object(captureFields.merging([
            "channels": field("string", "Digital channels: 0-7 or 0,2,4. Default 0-7, or all with load."),
            "no_confirm": field("boolean", "Trust timing alone, skipping the decoders."),
        ]) { first, _ in first })),
    tool(
        "analyze",
        "Measure timing across channels: delay between edges, setup and hold around a clock, or when each channel is busy.",
        object(captureFields.merging([
            "analysis": .object(["oneOf": .array([latencyAnalysis, setupHoldAnalysis, activityAnalysis])]),
        ]) { first, _ in first }, required: ["analysis"])),
    tool(
        "timeline",
        "Show what each channel did across a time window, as low, high and active segments, with analog min and max and decoded bytes lined up. Can also draw an HTML or SVG file straight from the data; do not draw waveforms by hand.",
        object(captureFields.merging([
            "channels": field("string", "Digital channels: 0-7, 0,2,4, or none with analog. Default 0-7, or all with load."),
            "analog": field("string", "Analog channels to record too, such as 0 or 0-3."),
            "analog_rate": field("string", "Analog sample rate, default 1.5625M."),
            "analog_downsample": bounded(1...1_000_000, "Keep one analog sample in this many."),
            "from": field("string", "Start of the window, such as 12ms. Zero is the capture start, or the trigger. May be negative."),
            "to": field("string", "End of the window."),
            "overlay": strings("Decoders to line up, as identify prints them, such as uart --channel 2 --baud 115200."),
            "radix": choice(Radix.allCases.map(\.rawValue), "How overlay values are shown. Default hex."),
            "max_segments": bounded(2...maximumTimelineSegments, "Most segments per channel in the reply. Default 100. Drawn files always use full detail."),
            "html": field("string", "Write the timeline to this HTML file."),
            "svg": field("string", "Write the timeline to this SVG file."),
            "title": field("string", "Title for the drawn timeline."),
        ]) { first, _ in first })),
]
