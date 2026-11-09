import Foundation

/// Analog channels to record alongside any digital ones.
struct AnalogCapture: Sendable {
    var channels: [UInt32]
    var sampleRate: UInt32
    /// Keeps one sample in this many when exporting. From 1 to 1,000,000.
    var downsample: UInt64 = 1
}

/// Logic 2's own CSV of the raw samples, written to a directory it does not create.
struct RawCSVExport: Sendable {
    var directory: String
    var iso8601: Bool
}

struct DigitalCaptureRequest: Sendable {
    var channels: [UInt32]
    var sampleRate: UInt32
    var mode: CaptureMode
    /// Logic level. The Logic Pro accepts 1.2, 1.8 or 3.3.
    var levelVolts: Double
    /// Device serial number. When nil, Logic 2 uses the first physical device.
    var deviceID: String?
    var glitchFilters: [GlitchFilter] = []
    /// Logic 2's memory limit for the capture. When nil, its own default applies.
    var bufferMegabytes: UInt32?
    var analog: AnalogCapture?
    /// Where to save a `.sal` file. Absolute, because Logic 2 resolves it in its own process.
    var savePath: String?
    var rawCSV: RawCSVExport?

    /// A loaded capture exports every channel it has unless told otherwise.
    var exportsEverything: Bool {
        if case .load = mode, channels.isEmpty, analog == nil { true } else { false }
    }

    var logicChannels: Saleae_Automation_LogicChannels {
        var logicChannels = Saleae_Automation_LogicChannels()
        logicChannels.digitalChannels = channels
        logicChannels.analogChannels = analog?.channels ?? []
        return logicChannels
    }
}

/// The Logic 2 calls a capture makes. Tests substitute a fake that fails on demand.
protocol CaptureBackend: Sendable {
    func startCapture(_ request: Saleae_Automation_StartCaptureRequest) async throws -> UInt64
    func stopCapture(_ captureID: UInt64) async throws
    func waitCapture(_ captureID: UInt64) async throws
    func exportBinary(_ request: Saleae_Automation_ExportRawDataBinaryRequest) async throws
    func addAnalyzer(_ request: Saleae_Automation_AddAnalyzerRequest) async throws -> UInt64
    func exportDataTable(_ request: Saleae_Automation_ExportDataTableCsvRequest) async throws
    func addHighLevelAnalyzer(_ request: Saleae_Automation_AddHighLevelAnalyzerRequest) async throws -> UInt64
    func exportRawCSV(_ request: Saleae_Automation_ExportRawDataCsvRequest) async throws
    func exportLegacy(_ request: Saleae_Automation_LegacyExportAnalyzerRequest) async throws
    func saveCapture(_ captureID: UInt64, to path: String) async throws
    func loadCapture(_ path: String) async throws -> UInt64
    func closeCapture(_ captureID: UInt64) async throws
}

struct GRPCCaptureBackend: CaptureBackend {
    let manager: Logic2Manager

    func startCapture(_ request: Saleae_Automation_StartCaptureRequest) async throws -> UInt64 {
        try await manager.startCapture(request).captureInfo.captureID
    }

    func stopCapture(_ captureID: UInt64) async throws {
        var stop = Saleae_Automation_StopCaptureRequest()
        stop.captureID = captureID
        _ = try await manager.stopCapture(stop)
    }

    func waitCapture(_ captureID: UInt64) async throws {
        var wait = Saleae_Automation_WaitCaptureRequest()
        wait.captureID = captureID
        _ = try await manager.waitCapture(wait)
    }

    func exportBinary(_ request: Saleae_Automation_ExportRawDataBinaryRequest) async throws {
        _ = try await manager.exportRawDataBinary(request)
    }

    func addAnalyzer(_ request: Saleae_Automation_AddAnalyzerRequest) async throws -> UInt64 {
        try await manager.addAnalyzer(request).analyzerID
    }

    func exportDataTable(_ request: Saleae_Automation_ExportDataTableCsvRequest) async throws {
        _ = try await manager.exportDataTableCsv(request)
    }

    func addHighLevelAnalyzer(_ request: Saleae_Automation_AddHighLevelAnalyzerRequest) async throws -> UInt64 {
        try await manager.addHighLevelAnalyzer(request).analyzerID
    }

    func exportRawCSV(_ request: Saleae_Automation_ExportRawDataCsvRequest) async throws {
        _ = try await manager.exportRawDataCsv(request)
    }

    func exportLegacy(_ request: Saleae_Automation_LegacyExportAnalyzerRequest) async throws {
        _ = try await manager.legacyExportAnalyzer(request)
    }

    func saveCapture(_ captureID: UInt64, to path: String) async throws {
        var save = Saleae_Automation_SaveCaptureRequest()
        save.captureID = captureID
        save.filepath = path
        _ = try await manager.saveCapture(save)
    }

    func loadCapture(_ path: String) async throws -> UInt64 {
        var load = Saleae_Automation_LoadCaptureRequest()
        load.filepath = path
        return try await manager.loadCapture(load).captureInfo.captureID
    }

    func closeCapture(_ captureID: UInt64) async throws {
        var close = Saleae_Automation_CloseCaptureRequest()
        close.captureID = captureID
        _ = try await manager.closeCapture(close)
    }
}

func runDigitalCapture(
    _ request: DigitalCaptureRequest,
    endpoint: Logic2Endpoint
) async throws -> CaptureSummary {
    try await withCaptureCancellation { cancellation in
        try await summarizedCapture(request) { directory in
            try await withLogic2(endpoint) { manager in
                try await exportDigitalCapture(
                    request, to: directory, using: GRPCCaptureBackend(manager: manager),
                    cancellation: cancellation)
            }
        }
    }
}

func runDecode(_ request: DecodeRequest, endpoint: Logic2Endpoint) async throws -> [DecodedRow] {
    try await withCaptureCancellation { cancellation in
        try await decodedCapture { file in
            try await withLogic2(endpoint) { manager in
                try await exportDecodedCapture(
                    request, to: file, using: GRPCCaptureBackend(manager: manager),
                    cancellation: cancellation)
            }
        }
    }
}

/// Exports into a temporary directory and summarizes.
func summarizedCapture(
    _ request: DigitalCaptureRequest,
    export: (URL) async throws -> Void
) async throws -> CaptureSummary {
    try await inTemporaryDirectory { directory in
        try await export(directory)
        let (digital, analog) =
            request.exportsEverything
            ? try exportedChannels(in: directory) : (request.channels, request.analog?.channels ?? [])
        return try summarizeCapture(directory: directory, channels: digital, analogChannels: analog)
    }
}

/// Exports a data table into a temporary directory and reads it back.
func decodedCapture(export: (URL) async throws -> Void) async throws -> [DecodedRow] {
    try await inTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("decoded.csv")
        try await export(file)
        return try decodedRows(fromCSV: Data(contentsOf: file))
    }
}

/// Exports never outlive this call.
func inTemporaryDirectory<Result>(_ body: (URL) async throws -> Result) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    return try await body(directory)
}

/// Runs a capture and writes binary exports to `directory`.
func exportDigitalCapture(
    _ request: DigitalCaptureRequest,
    to directory: URL,
    using backend: some CaptureBackend,
    cancellation: CaptureCancellation
) async throws {
    try await runCapture(request, using: backend, cancellation: cancellation) { captureID in
        try await exportBinary(request, captureID: captureID, to: directory, using: backend)
    }
}

private func exportBinary(
    _ request: DigitalCaptureRequest,
    captureID: UInt64,
    to directory: URL,
    using backend: some CaptureBackend
) async throws {
    var export = Saleae_Automation_ExportRawDataBinaryRequest()
    export.captureID = captureID
    export.directory = directory.path
    if !request.exportsEverything { export.logicChannels = request.logicChannels }
    // The server requires this even for digital-only exports.
    export.analogDownsampleRatio = request.analog?.downsample ?? 1
    try await backend.exportBinary(export)
}

/// Runs a capture, identifies what is on each channel from its timing, and optionally
/// confirms each bus by decoding the same capture.
func exportIdentifiedCapture(
    _ request: DigitalCaptureRequest,
    confirm: Bool,
    in directory: URL,
    using backend: some CaptureBackend,
    cancellation: CaptureCancellation
) async throws -> ChannelIdentification {
    var result: ChannelIdentification?
    try await runCapture(request, using: backend, cancellation: cancellation) { captureID in
        try await exportBinary(request, captureID: captureID, to: directory, using: backend)
        let digital = request.exportsEverything ? try exportedChannels(in: directory).digital : request.channels
        var identification = identifyChannels(try loadChannels(directory: directory, channels: digital))
        if confirm {
            for index in identification.buses.indices {
                try cancellation.checkCancelled()
                identification.buses[index] = try await confirmed(
                    identification.buses[index], captureID: captureID, in: directory, using: backend)
            }
        }
        result = identification
    }
    return result!
}

func runIdentify(
    _ request: DigitalCaptureRequest,
    confirm: Bool,
    endpoint: Logic2Endpoint
) async throws -> ChannelIdentification {
    try await withCaptureCancellation { cancellation in
        try await inTemporaryDirectory { directory in
            try await withLogic2(endpoint) { manager in
                try await exportIdentifiedCapture(
                    request, confirm: confirm, in: directory, using: GRPCCaptureBackend(manager: manager),
                    cancellation: cancellation)
            }
        }
    }
}

func loadChannels(directory: URL, channels: [UInt32]) throws -> [IdentifiableChannel] {
    try channels.map { channel in
        let digital = try DigitalChannel(
            contentsOf: directory.appendingPathComponent("digital_\(channel).bin"))
        let times = digital.withEdgeTimes { edges in (0..<edges.count).map { edges[$0] } }
        return IdentifiableChannel(summary: summarize(digital, channel: channel), times: times)
    }
}

/// Decodes a capture already held by Logic 2.
private func decodedRows(
    _ decoder: ProtocolDecoder,
    captureID: UInt64,
    in directory: URL,
    using backend: some CaptureBackend
) async throws -> [DecodedRow] {
    let file = directory.appendingPathComponent("confirm-\(UUID().uuidString).csv")
    try await exportDataTable(
        decoder, radix: .hex, captureID: captureID, to: file, using: backend)
    return try decodedRows(fromCSV: Data(contentsOf: file))
}

/// Tries the bus's decoder on the capture. UART timing cannot show parity, or polarity
/// on a line with no idle gap, so the alternatives are tried when decoding reports errors.
private func confirmed(
    _ bus: IdentifiedBus,
    captureID: UInt64,
    in directory: URL,
    using backend: some CaptureBackend
) async throws -> IdentifiedBus {
    var bus = bus
    switch bus.decoder {
    case .uart(let uart):
        var lastErrors = 0
        for inverted in [uart.inverted, !uart.inverted] {
            for parity in Parity.allCases {
                var attempt = uart
                attempt.parity = parity
                attempt.inverted = inverted
                let rows = try await decodedRows(.uart(attempt), captureID: captureID, in: directory, using: backend)
                let errors = decodeIssues(alignedFrames(rows, baud: uart.baud)).values.reduce(0, +)
                if !rows.isEmpty, errors == 0 {
                    bus.decoder = .uart(attempt)
                    bus.confidence = .confirmed
                    return bus
                }
                lastErrors = errors
            }
        }
        bus.confidence = .uncertain
        bus.notes.append("Decoding still reported \(lastErrors) errors with each parity and polarity. Check the frame format.")
    case .spi:
        let rows = try await decodedRows(bus.decoder, captureID: captureID, in: directory, using: backend)
        confirm(&bus, found: rows.contains { $0.type == "result" }, failure: "Logic 2 decoded no SPI words.")
    case .i2c:
        let rows = try await decodedRows(bus.decoder, captureID: captureID, in: directory, using: backend)
        confirm(&bus, found: rows.contains { $0.type == "address" }, failure: "Logic 2 decoded no I2C addresses.")
        if let nacks = decodeIssues(rows)["nack"] { bus.notes.append("\(nacks) NACKs were seen.") }
    }
    return bus
}

/// Leaves out frames a capture window can spoil. A capture that opens mid-frame stays
/// misaligned until a gap longer than any frame, so everything before the first such gap
/// is dropped, as is the last frame, which the window can cut short.
func alignedFrames(_ rows: [DecodedRow], baud: Int64) -> [DecodedRow] {
    let longestFrame = 13 / Double(baud)
    let firstGap = rows.indices.dropLast().first { rows[$0 + 1].start - (rows[$0].start + rows[$0].duration) > longestFrame }
    let start = firstGap.map { $0 + 1 } ?? 1
    let aligned = Array(rows.dropFirst(start).dropLast())
    return aligned.isEmpty ? Array(rows.dropFirst().dropLast()) : aligned
}

private func confirm(_ bus: inout IdentifiedBus, found: Bool, failure: String) {
    bus.confidence = found ? .confirmed : .uncertain
    if !found { bus.notes.append(failure) }
}

/// Runs a capture, decodes it, and writes the analyzer's data table to `file`.
func exportDecodedCapture(
    _ request: DecodeRequest,
    to file: URL,
    using backend: some CaptureBackend,
    cancellation: CaptureCancellation
) async throws {
    try await runCapture(request.capture, using: backend, cancellation: cancellation) { captureID in
        let analyzerID = try await addAnalyzer(request.decoder, captureID: captureID, using: backend)
        var shownID = analyzerID
        if let highLevel = request.highLevel {
            var add = Saleae_Automation_AddHighLevelAnalyzerRequest()
            add.captureID = captureID
            add.extensionDirectory = highLevel.extensionDirectory
            add.hlaName = highLevel.name
            add.hlaLabel = highLevel.name
            add.inputAnalyzerID = analyzerID
            add.settings = Dictionary(uniqueKeysWithValues: highLevel.settings.map { ($0.key, $0.wireValue) })
            shownID = try await backend.addHighLevelAnalyzer(add)
        }
        try await exportTable(shownID, radix: request.radix, captureID: captureID, to: file, using: backend)

        if let table = request.tableExport {
            try await exportTable(
                shownID, radix: request.radix, captureID: captureID, to: URL(fileURLWithPath: table.path),
                options: table, using: backend)
        }
        if let legacyPath = request.legacyPath {
            var legacy = Saleae_Automation_LegacyExportAnalyzerRequest()
            legacy.captureID = captureID
            legacy.filepath = legacyPath
            legacy.analyzerID = analyzerID
            legacy.radixType = request.radix.type
            try await backend.exportLegacy(legacy)
        }
    }
}

/// Reads which channels a directory of binary exports holds.
func exportedChannels(in directory: URL) throws -> (digital: [UInt32], analog: [UInt32]) {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    func numbers(_ prefix: String) -> [UInt32] {
        names.compactMap { name -> UInt32? in
            guard name.hasPrefix(prefix), name.hasSuffix(".bin") else { return nil }
            return UInt32(name.dropFirst(prefix.count).dropLast(4))
        }.sorted()
    }
    return (numbers("digital_"), numbers("analog_"))
}

private func exportDataTable(
    _ decoder: ProtocolDecoder,
    radix: Radix,
    captureID: UInt64,
    to file: URL,
    using backend: some CaptureBackend
) async throws {
    let analyzerID = try await addAnalyzer(decoder, captureID: captureID, using: backend)
    try await exportTable(analyzerID, radix: radix, captureID: captureID, to: file, using: backend)
}

private func addAnalyzer(
    _ decoder: ProtocolDecoder,
    captureID: UInt64,
    using backend: some CaptureBackend
) async throws -> UInt64 {
    var add = Saleae_Automation_AddAnalyzerRequest()
    add.captureID = captureID
    add.analyzerName = decoder.analyzerName
    add.analyzerLabel = decoder.analyzerName
    add.settings = decoder.settings
    return try await backend.addAnalyzer(add)
}

private func exportTable(
    _ analyzerID: UInt64,
    radix: Radix,
    captureID: UInt64,
    to file: URL,
    options: TableExport? = nil,
    using backend: some CaptureBackend
) async throws {
    var analyzer = Saleae_Automation_DataTableAnalyzerConfiguration()
    analyzer.analyzerID = analyzerID
    analyzer.radixType = radix.type

    var export = Saleae_Automation_ExportDataTableCsvRequest()
    export.captureID = captureID
    export.filepath = file.path
    export.analyzers = [analyzer]
    if let options {
        export.iso8601Timestamp = options.iso8601
        export.exportColumns = options.columns
        if let query = options.filterQuery {
            export.filter.query = query
            export.filter.columns = options.filterColumns
        }
    }
    try await backend.exportDataTable(export)
}

/// Runs a capture in its mode and hands it to `process`. Once a capture has
/// started it is closed on every path, because Logic 2 holds it in memory until then.
///
/// Cancellation interrupts only the wait. Start and export run to completion, so a
/// started capture is never lost and Logic 2 is never left writing into a removed directory.
func runCapture(
    _ request: DigitalCaptureRequest,
    using backend: some CaptureBackend,
    cancellation: CaptureCancellation,
    process: (UInt64) async throws -> Void
) async throws {
    try cancellation.checkCancelled()
    let captureID: UInt64
    if case .load(let path) = request.mode {
        captureID = try await backend.loadCapture(path)
    } else {
        captureID = try await backend.startCapture(request.startRequest)
    }

    do {
        switch request.mode {
        case .load:
            break
        case .timed:
            try await cancellation.interruptible { try await backend.waitCapture(captureID) }
        case .manual(let limitSeconds, _, let stop):
            try await holdManualCapture(limitSeconds: limitSeconds, stop: stop, cancellation: cancellation)
            try await backend.stopCapture(captureID)
        case .trigger(let trigger):
            try await waitForTrigger(trigger, captureID: captureID, using: backend, cancellation: cancellation)
        }
        if let savePath = request.savePath { try await backend.saveCapture(captureID, to: savePath) }
        if let rawCSV = request.rawCSV {
            var export = Saleae_Automation_ExportRawDataCsvRequest()
            export.captureID = captureID
            export.directory = rawCSV.directory
            if !request.exportsEverything { export.logicChannels = request.logicChannels }
            export.analogDownsampleRatio = request.analog?.downsample ?? 1
            export.iso8601Timestamp = rawCSV.iso8601
            try await backend.exportRawCSV(export)
        }
        try await process(captureID)
        try cancellation.checkCancelled()
    } catch {
        // Cleanup is best effort. The original failure is the one worth reporting.
        if cancellation.isCancelled { try? await backend.stopCapture(captureID) }
        try? await backend.closeCapture(captureID)
        throw error
    }
    try await backend.closeCapture(captureID)
}

/// Returns once `stop` is cancelled or the limit passes. Throws only if cancelled.
private func holdManualCapture(
    limitSeconds: Double?,
    stop: CaptureCancellation,
    cancellation: CaptureCancellation
) async throws {
    let oneYear = 31_536_000.0
    try await cancellation.interruptible {
        // Reaching the limit and being stopped both end the capture normally.
        try? await stop.interruptible { try await Task.sleep(for: .seconds(limitSeconds ?? oneYear)) }
    }
}

/// WaitCapture blocks until the trigger fires, which may be never.
private func waitForTrigger(
    _ trigger: DigitalTrigger,
    captureID: UInt64,
    using backend: some CaptureBackend,
    cancellation: CaptureCancellation
) async throws {
    let deadline = CaptureCancellation()
    let watchdog = Task {
        try await Task.sleep(for: .seconds(trigger.timeoutSeconds + trigger.afterSeconds))
        deadline.cancel()
    }
    defer { watchdog.cancel() }

    do {
        try await cancellation.interruptible {
            try await deadline.interruptible { try await backend.waitCapture(captureID) }
        }
    } catch where deadline.isCancelled && !cancellation.isCancelled {
        try? await backend.stopCapture(captureID)
        throw CaptureError.triggerTimeout(seconds: trigger.timeoutSeconds)
    }
}

