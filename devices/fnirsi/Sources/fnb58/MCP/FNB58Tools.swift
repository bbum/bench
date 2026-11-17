import Foundation

struct ToolInputError: Error, CustomStringConvertible {
    var description: String
}

/// A capture that ended badly is reported as a failed call, with its summary, so the
/// caller cannot mistake a cut-short capture for a whole one.
struct CaptureFailure: Error, CustomStringConvertible {
    var summary: CaptureSummary
    var description: String {
        let text = (try? summaryJSON(summary)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "Capture ended early (\(summary.ended.rawValue)). Samples so far are kept.\n\(text)"
    }
}

private func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array(required.map(JSONValue.string)),
        "additionalProperties": .bool(false),
    ])
}

private func property(_ type: String, _ description: String) -> JSONValue {
    .object(["type": .string(type), "description": .string(description)])
}

private func tool(_ name: String, _ description: String, _ schema: JSONValue) -> JSONValue {
    .object(["name": .string(name), "description": .string(description), "inputSchema": schema])
}

let toolDefinitions: [JSONValue] = [
    tool("status", "Whether an FNB58 USB power meter is connected, and its latest reading: volts, amps, watts, D+/D-, temperature. Also shows a running capture.", object([:])),
    tool("capture",
         "Record the meter for a number of seconds (100 samples/s), then return a summary: duration, current mean/peak/p99/min, voltage min/max, power, energy in mWh, charge in mAh, and the path of a CSV with every sample. Blocks for the whole capture.",
         object([
            "seconds": property("number", "How long to record, 0 to 86400."),
            "label": property("string", "Optional label for the file name and summary."),
         ], required: ["seconds"])),
    tool("start_capture",
         "Start recording in the background and return at once with the CSV path. Use mark to note events, and stop_capture to finish and get the summary.",
         object(["label": property("string", "Optional label for the file name and summary.")])),
    tool("mark",
         "Add a timestamped note (e.g. \"print sent\") to the running capture. It lands on the next sample, in the CSV's mark column and in the summary.",
         object(["note": property("string", "What happened.")], required: ["note"])),
    tool("stop_capture", "Stop the running capture and return its summary, as capture does.", object([:])),
    tool("window_stats",
         "Statistics over a time window of a saved capture: same fields as a capture summary, plus marks in the window. Times are seconds from capture start.",
         object([
            "csv": property("string", "Capture CSV path. Default: this server's last capture, else the newest saved one."),
            "from_s": property("number", "Window start, inclusive. Default 0."),
            "to_s": property("number", "Window end, exclusive. Default the end of the capture."),
         ])),
    tool("raw_dump",
         "Every report the meter sends for a while, as hex, with counts by report type and the values seen in byte 12 of each sample (the temperature sign, 1 = positive). For protocol work.",
         object([
            "seconds": property("number", "How long to listen, up to 60. Default 1."),
            "limit": property("integer", "Most reports to return in full. Default 50."),
         ])),
]

/// The argument names a tool's schema declares.
func allowedKeys(_ name: String) -> Set<String> {
    let schema = toolDefinitions.first { $0["name"]?.stringValue == name }?["inputSchema"]
    guard case .object(let properties)? = schema?["properties"] else { return [] }
    return Set(properties.keys)
}

struct FNB58Tools: ToolCatalog {
    let session: MeterSession

    var definitions: [JSONValue] { toolDefinitions }

    func hasTool(named name: String) -> Bool {
        toolDefinitions.contains { $0["name"]?.stringValue == name }
    }

    func call(name: String, arguments: JSONValue) async throws -> String {
        guard case .object(let args) = arguments else { throw ToolInputError(description: "Arguments must be an object.") }
        let allowed = allowedKeys(name)
        if let unknown = args.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ToolInputError(description: "Unknown argument: \(unknown)")
        }
        switch name {
        case "status":
            return try text(await session.status())
        case "capture":
            guard let seconds = try number(args, "seconds") else { throw ToolInputError(description: "capture needs seconds.") }
            return try finished(try await session.capture(seconds: seconds, label: try string(args, "label")))
        case "start_capture":
            return try text(try await session.startCapture(label: try string(args, "label")))
        case "mark":
            guard let note = try string(args, "note"), !note.isEmpty else { throw ToolInputError(description: "mark needs a note.") }
            return try text(try await session.mark(note))
        case "stop_capture":
            return try finished(try await session.stopCapture())
        case "window_stats":
            let url: URL
            if let path = try string(args, "csv") {
                url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            } else if let last = await session.lastCapture ?? newestCapture(in: session.directory) {
                url = last
            } else {
                throw ToolInputError(description: "No capture to read: pass csv.")
            }
            return try text(try windowStats(try readCapture(url), csv: url.path, from: try number(args, "from_s"), to: try number(args, "to_s")))
        case "raw_dump":
            let limit = try number(args, "limit").map { Int(exactly: $0) } ?? 50
            guard let limit, limit >= 0 else { throw ToolInputError(description: "limit must be a whole number, 0 or more.") }
            return try text(try await session.rawDump(seconds: try number(args, "seconds") ?? 1, limit: limit))
        default:
            throw ToolInputError(description: "Unknown tool: \(name)")
        }
    }

    private func finished(_ summary: CaptureSummary) throws -> String {
        if summary.failed { throw CaptureFailure(summary: summary) }
        return try text(summary)
    }

    private func text(_ value: some Encodable) throws -> String {
        String(decoding: try summaryJSON(value), as: UTF8.self)
    }

    private func number(_ args: [String: JSONValue], _ key: String) throws -> Double? {
        switch args[key] {
        case nil, .null?: nil
        case .int(let value)?: Double(value)
        case .double(let value)? where value.isFinite: value
        default: throw ToolInputError(description: "\(key) must be a number.")
        }
    }

    private func string(_ args: [String: JSONValue], _ key: String) throws -> String? {
        switch args[key] {
        case nil, .null?: nil
        case .string(let value)?: value
        default: throw ToolInputError(description: "\(key) must be a string.")
        }
    }
}
