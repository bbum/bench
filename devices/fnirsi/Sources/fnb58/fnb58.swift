import ArgumentParser
import Foundation

struct MeterOptions: ParsableArguments {
    @Option(help: "Serial number of the meter to use, when more than one is connected.")
    var serial: String?

    @Option(help: "Directory for capture CSVs. Default $FNB58_CAPTURE_DIR or ~/.local/share/fnb58/captures.")
    var dir: String?

    var directory: URL { dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultCaptureDirectory() }

    func session() -> MeterSession { MeterSession(serial: serial, directory: directory) }
}

@main
struct FNB58Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fnb58",
        abstract: "Read the FNIRSI FNB58 USB power meter over USB HID.",
        subcommands: [StatusCommand.self, CaptureCommand.self, StatsCommand.self, RawCommand.self, MCPCommand.self]
    )
}

func printJSON(_ value: some Encodable) throws {
    print(String(decoding: try summaryJSON(value), as: UTF8.self))
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the meter and its latest reading.")

    @OptionGroup var meter: MeterOptions
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let info = await meter.session().status()
        if json { try printJSON(info) } else { Text.status(info).forEach { print($0) } }
        if !info.connected || info.error != nil { throw ExitCode.failure }
    }
}

struct CaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Record every sample for a number of seconds, then summarize.",
        discussion: "Ctrl-C stops early and still summarizes. Each line typed on standard input during the capture becomes a mark at that moment."
    )

    @Argument(help: "Seconds to record, by sample count at 100 samples a second.") var seconds: Double
    @Option(help: "Label, used in the file name and summary.") var label: String?
    @OptionGroup var meter: MeterOptions
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let session = meter.session()
        let capture = Task { try await session.capture(seconds: seconds, label: label) }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT)
        interrupt.setEventHandler { capture.cancel() }
        interrupt.resume()
        let marks = Task.detached {
            for try await line in FileHandle.standardInput.bytes.lines {
                let note = line.trimmingCharacters(in: .whitespaces)
                guard !note.isEmpty, let mark = try? await session.mark(note) else { continue }
                FileHandle.standardError.write(Data(String(format: "mark %.2f s  %@\n", mark.t, note).utf8))
            }
        }
        defer { marks.cancel(); interrupt.cancel() }
        let summary = try await capture.value
        if json { try printJSON(summary) } else { Text.summary(summary).forEach { print($0) } }
        if summary.failed { throw ExitCode.failure }
    }
}

struct StatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats", abstract: "Statistics over a window of a saved capture.")

    @Argument(help: "Capture CSV. Default: the newest in the capture directory.") var csv: String?
    @Option(help: "Window start in seconds, inclusive.") var from: Double?
    @Option(help: "Window end in seconds, exclusive.") var to: Double?
    @OptionGroup var meter: MeterOptions
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        guard let url = csv.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? newestCapture(in: meter.directory) else {
            throw ValidationError("No capture CSV given and none found in \(meter.directory.path).")
        }
        let window = try windowStats(try readCapture(url), csv: url.path, from: from, to: to)
        if json { try printJSON(window) } else { Text.window(window).forEach { print($0) } }
    }
}

struct RawCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "raw", abstract: "Dump every report the meter sends, as hex.")

    @Option(help: "Seconds to listen.") var seconds = 1.0
    @Option(help: "Most reports to print.") var limit = 1000
    @OptionGroup var meter: MeterOptions
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let dump = try await meter.session().rawDump(seconds: seconds, limit: limit)
        if json { try printJSON(dump) } else { Text.raw(dump).forEach { print($0) } }
    }
}

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as an MCP server over stdio.",
        discussion: "Tools: status, capture, start_capture, mark, stop_capture, window_stats and raw_dump."
    )

    @OptionGroup var meter: MeterOptions

    func run() async throws {
        let session = meter.session()
        let server = MCPServer(tools: FNB58Tools(session: session)) { data in
            FileHandle.standardOutput.write(data)
        }
        try await splitLines(FileHandle.standardInput.bytes) { line in
            await server.receive(line)
        }
        await server.finish()
        _ = await session.shutdown()
    }
}
