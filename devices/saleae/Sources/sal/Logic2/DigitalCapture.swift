import Foundation

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

    var logicChannels: Saleae_Automation_LogicChannels {
        var logicChannels = Saleae_Automation_LogicChannels()
        logicChannels.digitalChannels = channels
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
        return try summarizeCapture(directory: directory, channels: request.channels)
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
private func inTemporaryDirectory<Result>(_ body: (URL) async throws -> Result) async throws -> Result {
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
        var export = Saleae_Automation_ExportRawDataBinaryRequest()
        export.captureID = captureID
        export.directory = directory.path
        export.logicChannels = request.logicChannels
        // The server requires this even for digital-only exports.
        export.analogDownsampleRatio = 1
        try await backend.exportBinary(export)
    }
}

/// Runs a capture, decodes it, and writes the analyzer's data table to `file`.
func exportDecodedCapture(
    _ request: DecodeRequest,
    to file: URL,
    using backend: some CaptureBackend,
    cancellation: CaptureCancellation
) async throws {
    try await runCapture(request.capture, using: backend, cancellation: cancellation) { captureID in
        var add = Saleae_Automation_AddAnalyzerRequest()
        add.captureID = captureID
        add.analyzerName = request.decoder.analyzerName
        add.analyzerLabel = request.decoder.analyzerName
        add.settings = request.decoder.settings
        let analyzerID = try await backend.addAnalyzer(add)

        var analyzer = Saleae_Automation_DataTableAnalyzerConfiguration()
        analyzer.analyzerID = analyzerID
        analyzer.radixType = request.radix.type

        var export = Saleae_Automation_ExportDataTableCsvRequest()
        export.captureID = captureID
        export.filepath = file.path
        export.analyzers = [analyzer]
        try await backend.exportDataTable(export)
    }
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
    let captureID = try await backend.startCapture(request.startRequest)

    do {
        switch request.mode {
        case .timed:
            try await cancellation.interruptible { try await backend.waitCapture(captureID) }
        case .manual(let limitSeconds, _, let stop):
            try await holdManualCapture(limitSeconds: limitSeconds, stop: stop, cancellation: cancellation)
            try await backend.stopCapture(captureID)
        case .trigger(let trigger):
            try await waitForTrigger(trigger, captureID: captureID, using: backend, cancellation: cancellation)
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

