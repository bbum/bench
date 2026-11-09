import Foundation

struct DigitalCaptureRequest: Sendable {
    var channels: [UInt32]
    var sampleRate: UInt32
    var durationSeconds: Double
    /// Logic level. The Logic Pro accepts 1.2, 1.8 or 3.3.
    var levelVolts: Double
    /// Device serial number. When nil, Logic 2 uses the first physical device.
    var deviceID: String?
}

/// The Logic 2 calls a capture makes. Tests substitute a fake that fails on demand.
protocol CaptureBackend: Sendable {
    func startCapture(_ request: Saleae_Automation_StartCaptureRequest) async throws -> UInt64
    func stopCapture(_ captureID: UInt64) async throws
    func waitCapture(_ captureID: UInt64) async throws
    func exportBinary(_ request: Saleae_Automation_ExportRawDataBinaryRequest) async throws
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

/// Exports into a temporary directory and summarizes. Exports never outlive this call.
func summarizedCapture(
    _ request: DigitalCaptureRequest,
    export: (URL) async throws -> Void
) async throws -> CaptureSummary {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await export(directory)
    return try summarizeCapture(directory: directory, channels: request.channels)
}

/// Runs a timed capture and writes binary exports to `directory`. Once a capture has
/// started it is closed on every path, because Logic 2 holds it in memory until then.
///
/// Cancellation interrupts only the wait. Start and export run to completion, so a
/// started capture is never lost and Logic 2 is never left writing into a removed directory.
func exportDigitalCapture(
    _ request: DigitalCaptureRequest,
    to directory: URL,
    using backend: some CaptureBackend,
    cancellation: CaptureCancellation
) async throws {
    var logicChannels = Saleae_Automation_LogicChannels()
    logicChannels.digitalChannels = request.channels

    var device = Saleae_Automation_LogicDeviceConfiguration()
    device.logicChannels = logicChannels
    device.digitalSampleRate = request.sampleRate
    device.digitalThresholdVolts = request.levelVolts

    var timed = Saleae_Automation_TimedCaptureMode()
    timed.durationSeconds = request.durationSeconds

    var start = Saleae_Automation_StartCaptureRequest()
    start.deviceID = request.deviceID ?? ""
    start.logicDeviceConfiguration = device
    start.captureConfiguration.timedCaptureMode = timed

    try cancellation.checkCancelled()
    let captureID = try await backend.startCapture(start)

    do {
        try await cancellation.interruptible { try await backend.waitCapture(captureID) }

        var export = Saleae_Automation_ExportRawDataBinaryRequest()
        export.captureID = captureID
        export.directory = directory.path
        export.logicChannels = logicChannels
        // The server requires this even for digital-only exports.
        export.analogDownsampleRatio = 1
        try await backend.exportBinary(export)
        try cancellation.checkCancelled()
    } catch {
        // Cleanup is best effort. The original failure is the one worth reporting.
        if cancellation.isCancelled { try? await backend.stopCapture(captureID) }
        try? await backend.closeCapture(captureID)
        throw error
    }
    try await backend.closeCapture(captureID)
}
