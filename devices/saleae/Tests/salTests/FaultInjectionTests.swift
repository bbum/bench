import Foundation
import Synchronization
import Testing
@testable import sal

private enum Step: CaseIterable, Sendable { case start, stop, wait, export, analyzer, table, close }
private struct InjectedFault: Error, Equatable {}

private actor FakeBackend: CaptureBackend {
    let failing: Set<Step>
    let hanging: Set<Step>
    let onEnter: @Sendable (Step) async -> Void
    let tableProvider: (@Sendable (Saleae_Automation_AddAnalyzerRequest) -> Data)?
    let writeExport: @Sendable (URL) throws -> Void
    private(set) var calls: [Step] = []
    private(set) var closedIDs: [UInt64] = []
    private(set) var closeSawCancellation = false
    private(set) var startRequest: Saleae_Automation_StartCaptureRequest?
    private(set) var exportRequest: Saleae_Automation_ExportRawDataBinaryRequest?
    private(set) var analyzerRequest: Saleae_Automation_AddAnalyzerRequest?
    private(set) var tableRequest: Saleae_Automation_ExportDataTableCsvRequest?
    var tableBytes = Data("name,type,start_time,duration,\"data\"\n\"a\",\"data\",1,0.5,0x41\n".utf8)

    init(
        failing: Set<Step> = [],
        hanging: Set<Step> = [],
        onEnter: @escaping @Sendable (Step) async -> Void = { _ in },
        tableProvider: (@Sendable (Saleae_Automation_AddAnalyzerRequest) -> Data)? = nil,
        writeExport: @escaping @Sendable (URL) throws -> Void = copyFixtures
    ) {
        self.failing = failing
        self.hanging = hanging
        self.onEnter = onEnter
        self.tableProvider = tableProvider
        self.writeExport = writeExport
    }

    private func record(_ step: Step) async throws {
        calls.append(step)
        await onEnter(step)
        if failing.contains(step) { throw InjectedFault() }
        if hanging.contains(step) { try await Task.sleep(for: .seconds(3600)) }
    }

    func startCapture(_ request: Saleae_Automation_StartCaptureRequest) async throws -> UInt64 {
        startRequest = request
        try await record(.start)
        return 42
    }

    func stopCapture(_ captureID: UInt64) async throws {
        try await record(.stop)
    }

    func waitCapture(_ captureID: UInt64) async throws {
        try await record(.wait)
    }

    func exportBinary(_ request: Saleae_Automation_ExportRawDataBinaryRequest) async throws {
        exportRequest = request
        try await record(.export)
        try writeExport(URL(fileURLWithPath: request.directory))
    }

    func addAnalyzer(_ request: Saleae_Automation_AddAnalyzerRequest) async throws -> UInt64 {
        analyzerRequest = request
        try await record(.analyzer)
        return 7
    }

    func exportDataTable(_ request: Saleae_Automation_ExportDataTableCsvRequest) async throws {
        tableRequest = request
        try await record(.table)
        let bytes = analyzerRequest.flatMap { tableProvider?($0) } ?? tableBytes
        try bytes.write(to: URL(fileURLWithPath: request.filepath))
    }

    func setTable(_ bytes: Data) {
        tableBytes = bytes
    }

    func closeCapture(_ captureID: UInt64) async throws {
        closedIDs.append(captureID)
        closeSawCancellation = Task.isCancelled
        try await record(.close)
    }
}

private func copyFixtures(to directory: URL) throws {
    for channel in 0...7 {
        let name = "digital_\(channel).bin"
        try FileManager.default.copyItem(
            at: fixtureDirectory.appendingPathComponent(name),
            to: directory.appendingPathComponent(name))
    }
}

private let request = DigitalCaptureRequest(
    channels: Array(0...7), sampleRate: 50_000_000, mode: .timed(seconds: 0.5), levelVolts: 3.3, deviceID: "ABC")

/// Runs a capture, reporting the directory it used so cleanup can be checked.
private func run(
    _ backend: FakeBackend,
    request: DigitalCaptureRequest = request,
    cancellation: CaptureCancellation = CaptureCancellation()
) async throws -> (summary: CaptureSummary, directory: URL) {
    final class Box: @unchecked Sendable { var directory: URL? }
    let box = Box()
    let summary = try await summarizedCapture(request) { directory in
        box.directory = directory
        try await exportDigitalCapture(request, to: directory, using: backend, cancellation: cancellation)
    }
    return (summary, box.directory!)
}

@Suite("Fault injection")
struct FaultInjectionTests {
    @Test("A clean run makes each call once, in order, and closes the capture")
    func cleanRun() async throws {
        let backend = FakeBackend()
        let (summary, directory) = try await run(backend)
        try Testgen.verify(summary)
        #expect(await backend.calls == [.start, .wait, .export, .close])
        #expect(await backend.closedIDs == [42])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("The start request carries every setting")
    func startRequest() async throws {
        let backend = FakeBackend()
        _ = try await run(backend)
        let start = try #require(await backend.startRequest)
        #expect(start.deviceID == "ABC")
        #expect(start.logicDeviceConfiguration.logicChannels.digitalChannels == Array(0...7))
        #expect(start.logicDeviceConfiguration.digitalSampleRate == 50_000_000)
        #expect(start.logicDeviceConfiguration.digitalThresholdVolts == 3.3)
        #expect(start.captureConfiguration.timedCaptureMode.durationSeconds == 0.5)
    }

    @Test("The export request carries every setting")
    func exportRequest() async throws {
        let backend = FakeBackend()
        _ = try await run(backend)
        let export = try #require(await backend.exportRequest)
        #expect(export.captureID == 42)
        #expect(export.logicChannels.digitalChannels == Array(0...7))
        #expect(export.analogDownsampleRatio == 1)
    }

    @Test("Omitting the device leaves it blank so Logic 2 chooses")
    func defaultDevice() async throws {
        var noDevice = request
        noDevice.deviceID = nil
        let backend = FakeBackend()
        _ = try await run(backend, request: noDevice)
        #expect(await backend.startRequest?.deviceID == "")
    }

    @Test("A failed start never tries to close")
    func startFails() async {
        let backend = FakeBackend(failing: [.start])
        await #expect(throws: InjectedFault.self) { try await run(backend) }
        #expect(await backend.calls == [.start])
    }

    @Test("A failed wait still closes the capture")
    func waitFails() async {
        let backend = FakeBackend(failing: [.wait])
        await #expect(throws: InjectedFault.self) { try await run(backend) }
        #expect(await backend.calls == [.start, .wait, .close])
        #expect(await backend.closedIDs == [42])
    }

    @Test("A failed export still closes the capture")
    func exportFails() async {
        let backend = FakeBackend(failing: [.export])
        await #expect(throws: InjectedFault.self) { try await run(backend) }
        #expect(await backend.calls == [.start, .wait, .export, .close])
    }

    @Test("A failed close after a clean run is reported")
    func closeFails() async {
        let backend = FakeBackend(failing: [.close])
        await #expect(throws: InjectedFault.self) { try await run(backend) }
        #expect(await backend.closedIDs == [42])
    }

    @Test("A failed close does not hide the original failure", arguments: [Step.wait, .export])
    private func closeFailureKeepsOriginal(step: Step) async {
        let backend = FakeBackend(failing: [step, .close])
        await #expect(throws: InjectedFault.self) { try await run(backend) }
        #expect(await backend.calls.last == .close)
    }

    @Test("Every combination of failing steps closes at most once and cleans up")
    func everyCombination() async throws {
        let steps = Step.allCases
        for mask in 0..<(1 << steps.count) {
            let failing = Set(steps.indices.filter { mask & (1 << $0) != 0 }.map { steps[$0] })
            let backend = FakeBackend(failing: failing)
            final class Box: @unchecked Sendable { var directory: URL? }
            let box = Box()
            _ = try? await summarizedCapture(request) { directory in
                box.directory = directory
                try await exportDigitalCapture(
                    request, to: directory, using: backend, cancellation: CaptureCancellation())
            }

            let closes = await backend.closedIDs.count
            #expect(closes == (failing.contains(.start) ? 0 : 1), "failing: \(failing)")
            #expect(!FileManager.default.fileExists(atPath: box.directory!.path), "failing: \(failing)")
        }
    }

    @Test("An export with missing files fails and cleans up")
    func missingExportFiles() async {
        let backend = FakeBackend(writeExport: { _ in })
        await #expect(throws: (any Error).self) { try await run(backend) }
        #expect(await backend.closedIDs == [42])
    }

    @Test("A corrupt export is reported, not summarized")
    func corruptExport() async {
        let backend = FakeBackend(writeExport: { directory in
            try copyFixtures(to: directory)
            try Data("garbage".utf8).write(to: directory.appendingPathComponent("digital_3.bin"))
        })
        await #expect(throws: DigitalFileError.tooShort(name: "digital_3.bin")) {
            try await run(backend)
        }
    }

    @Test("A future export format is refused")
    func futureFormat() async {
        let backend = FakeBackend(writeExport: { directory in
            try copyFixtures(to: directory)
            var bytes = try Data(contentsOf: directory.appendingPathComponent("digital_0.bin"))
            bytes.store(Int32(1), at: Header.version)
            try bytes.write(to: directory.appendingPathComponent("digital_0.bin"))
        })
        await #expect(throws: DigitalFileError.unsupportedVersion(name: "digital_0.bin", version: 1)) {
            try await run(backend)
        }
    }

    @Test("An unreachable server fails promptly")
    func unreachableServer() async {
        await #expect(throws: (any Error).self) {
            try await runDigitalCapture(request, endpoint: Logic2Endpoint(host: "127.0.0.1", port: 1))
        }
    }
}

private func installedHandler(_ number: Int32) -> Int {
    var current = sigaction()
    sigaction(number, nil, &current)
    return unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
}

@Suite("Cancellation", .serialized)
struct CancellationTests {
    /// Runs a capture that is cancelled on entering `step`, returning the temp directory.
    private func runCancelled(
        at step: Step,
        failing: Set<Step> = [],
        hanging: Set<Step> = []
    ) async throws -> (FakeBackend, URL) {
        let cancellation = CaptureCancellation()
        let backend = FakeBackend(failing: failing, hanging: hanging, onEnter: {
            if $0 == step { cancellation.cancel() }
        })
        final class Box: @unchecked Sendable { var directory: URL? }
        let box = Box()
        await #expect(throws: CancellationError.self) {
            try await summarizedCapture(request) { directory in
                box.directory = directory
                try await exportDigitalCapture(
                    request, to: directory, using: backend, cancellation: cancellation)
            }
        }
        return (backend, try #require(box.directory))
    }

    @Test("Cancelling during start finishes it, then stops and closes without waiting")
    func duringStart() async throws {
        let (backend, directory) = try await runCancelled(at: .start)
        #expect(await backend.calls == [.start, .stop, .close])
        #expect(await backend.closedIDs == [42])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Cancelling interrupts a wait that would otherwise never end")
    func duringHungWait() async throws {
        let (backend, directory) = try await runCancelled(at: .wait, hanging: [.wait])
        #expect(await backend.calls == [.start, .wait, .stop, .close])
        #expect(await backend.closedIDs == [42])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("A wait that ends normally after cancellation does not go on to export")
    func waitIgnoresCancellation() async throws {
        let (backend, _) = try await runCancelled(at: .wait)
        #expect(await backend.calls == [.start, .wait, .stop, .close])
    }

    @Test("A wait that fails after cancellation reports the cancellation")
    func waitFailsAfterCancellation() async throws {
        let (backend, _) = try await runCancelled(at: .wait, failing: [.wait])
        #expect(await backend.calls == [.start, .wait, .stop, .close])
    }

    @Test("Cancelling during export finishes it, then closes and reports the cancellation")
    func duringExport() async throws {
        let (backend, directory) = try await runCancelled(at: .export)
        #expect(await backend.calls == [.start, .wait, .export, .stop, .close])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Failing cleanup does not hide the cancellation or skip the close")
    func cleanupFails() async throws {
        let (backend, directory) = try await runCancelled(
            at: .wait, failing: [.stop, .close], hanging: [.wait])
        #expect(await backend.closedIDs == [42])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Cancelling before start never touches Logic 2")
    func beforeStart() async {
        let cancellation = CaptureCancellation()
        cancellation.cancel()
        let backend = FakeBackend()
        await #expect(throws: CancellationError.self) {
            try await run(backend, cancellation: cancellation)
        }
        #expect(await backend.calls.isEmpty)
    }

    @Test("Cancelling the task reaches the wait, and cleanup runs uncancelled")
    func taskCancellation() async throws {
        let (enteredStream, entered) = AsyncStream<Void>.makeStream()
        let backend = FakeBackend(hanging: [.wait], onEnter: {
            if $0 == .wait { entered.yield() }
        })
        let directory = Mutex<URL?>(nil)
        let task = Task {
            try await withCaptureCancellation { cancellation in
                try await summarizedCapture(request) { url in
                    directory.withLock { $0 = url }
                    try await exportDigitalCapture(
                        request, to: url, using: backend, cancellation: cancellation)
                }
            }
        }
        _ = await enteredStream.first { _ in true }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await backend.calls == [.start, .wait, .stop, .close])
        #expect(await backend.closeSawCancellation == false)
        let used = try #require(directory.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: used.path))
    }

    @Test("A signal cancels the work and restores the previous handler", .serialized, arguments: [SIGINT, SIGTERM])
    func signalCancels(number: Int32) async {
        let before = installedHandler(number)
        let handlerAfterSignal = Mutex(-1)
        await #expect(throws: CancellationError.self) {
            try await cancellingOnInterrupt {
                do {
                    kill(getpid(), number)
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    let handler = installedHandler(number)
                    handlerAfterSignal.withLock { $0 = handler }
                    throw error
                }
            }
        }
        #expect(handlerAfterSignal.withLock { $0 } == before)
    }

    @Test("An interrupt can stop instead of cancelling")
    func interruptCallsHandler() async throws {
        let stop = CaptureCancellation()
        let result = try await cancellingOnInterrupt(interrupt: { stop.cancel() }) {
            kill(getpid(), SIGINT)
            while !stop.isCancelled { try await Task.sleep(for: .milliseconds(1)) }
            return Task.isCancelled
        }
        #expect(result == false)
    }

    @Test("Interrupted captures use the shell's SIGINT exit code")
    func exitCode() {
        #expect(interruptedExitCode == 130)
    }
}

private let decodeRequest = DecodeRequest(
    capture: DigitalCaptureRequest(
        channels: [2], sampleRate: 50_000_000, mode: .timed(seconds: 0.5), levelVolts: 3.3, deviceID: nil),
    decoder: .uart(UARTDecoder(channel: 2, baud: 115_200)),
    radix: .dec)

@Suite("Decode fault injection")
struct DecodeFaultInjectionTests {
    private func decode(
        _ backend: FakeBackend,
        cancellation: CaptureCancellation = CaptureCancellation()
    ) async throws -> [DecodedRow] {
        try await decodedCapture { file in
            try await exportDecodedCapture(
                decodeRequest, to: file, using: backend, cancellation: cancellation)
        }
    }

    @Test("A clean decode adds the analyzer, exports it, closes, and reads the rows")
    func cleanRun() async throws {
        let backend = FakeBackend()
        let rows = try await decode(backend)
        #expect(rows == [DecodedRow(type: "data", start: 1, duration: 0.5, fields: ["data": "0x41"])])
        #expect(await backend.calls == [.start, .wait, .analyzer, .table, .close])
        #expect(await backend.closedIDs == [42])
    }

    @Test("The analyzer and table requests carry every setting")
    func requests() async throws {
        let backend = FakeBackend()
        _ = try await decode(backend)
        let add = try #require(await backend.analyzerRequest)
        #expect(add.captureID == 42)
        #expect(add.analyzerName == "Async Serial")
        #expect(add.settings == decodeRequest.decoder.settings)
        let table = try #require(await backend.tableRequest)
        #expect(table.captureID == 42)
        #expect(table.analyzers.map(\.analyzerID) == [7])
        #expect(table.analyzers.map(\.radixType) == [.decimal])
        #expect(await backend.startRequest?.logicDeviceConfiguration.logicChannels.digitalChannels == [2])
    }

    @Test("Every combination of failing steps closes at most once")
    func everyCombination() async {
        let steps = Step.allCases
        for mask in 0..<(1 << steps.count) {
            let failing = Set(steps.indices.filter { mask & (1 << $0) != 0 }.map { steps[$0] })
            let backend = FakeBackend(failing: failing)
            let rows = try? await decode(backend)
            let relevant = failing.subtracting([.stop, .export])
            #expect((rows != nil) == relevant.isEmpty, "failing: \(failing)")
            #expect(await backend.closedIDs.count == (failing.contains(.start) ? 0 : 1), "failing: \(failing)")
        }
    }

    @Test("Cancelling during an analyzer step finishes it, then stops and closes", arguments: [Step.analyzer, .table])
    private func cancelled(step: Step) async {
        let cancellation = CaptureCancellation()
        let backend = FakeBackend(onEnter: { if $0 == step { cancellation.cancel() } })
        await #expect(throws: CancellationError.self) {
            try await decode(backend, cancellation: cancellation)
        }
        #expect(await backend.calls == [.start, .wait, .analyzer, .table, .stop, .close])
    }

    @Test("A corrupt data table is reported")
    func corruptTable() async {
        let backend = FakeBackend()
        await backend.setTable(Data("garbage\n".utf8))
        await #expect(throws: DecodedTableError.invalidHeader) { try await decode(backend) }
        #expect(await backend.closedIDs == [42])
    }
}

private func captureRequest(_ mode: CaptureMode) -> DigitalCaptureRequest {
    DigitalCaptureRequest(channels: Array(0...7), sampleRate: 50_000_000, mode: mode, levelVolts: 3.3, deviceID: nil)
}

@Suite("Capture modes", .serialized)
struct CaptureModeFlowTests {
    private func capture(
        _ backend: FakeBackend,
        _ mode: CaptureMode,
        cancellation: CaptureCancellation = CaptureCancellation()
    ) async throws -> CaptureSummary {
        let capture = captureRequest(mode)
        return try await summarizedCapture(capture) { directory in
            try await exportDigitalCapture(capture, to: directory, using: backend, cancellation: cancellation)
        }
    }

    private let trigger = DigitalTrigger(
        point: TriggerPoint(channel: 1, kind: .rising), afterSeconds: 0.01, timeoutSeconds: 0.05)

    @Test("A manual capture stops at its limit, and is never waited on")
    func manualLimit() async throws {
        let backend = FakeBackend()
        let clock = ContinuousClock()
        let began = clock.now
        try Testgen.verify(try await capture(backend, .manual(limitSeconds: 0.05, stop: CaptureCancellation())))
        #expect(clock.now - began >= .milliseconds(50))
        #expect(await backend.calls == [.start, .stop, .export, .close])
    }

    @Test("Stopping a manual capture ends it early and keeps the data")
    func manualStop() async throws {
        let stop = CaptureCancellation()
        let backend = FakeBackend(onEnter: { if $0 == .start { stop.cancel() } })
        try Testgen.verify(try await capture(backend, .manual(limitSeconds: nil, stop: stop)))
        #expect(await backend.calls == [.start, .stop, .export, .close])
    }

    @Test("Cancelling a manual capture discards it")
    func manualCancelled() async {
        let cancellation = CaptureCancellation()
        let backend = FakeBackend(onEnter: { if $0 == .start { cancellation.cancel() } })
        await #expect(throws: CancellationError.self) {
            try await capture(backend, .manual(limitSeconds: nil, stop: CaptureCancellation()), cancellation: cancellation)
        }
        #expect(await backend.calls == [.start, .stop, .close])
    }

    @Test("Cancelling reaches a manual capture that is already holding")
    func manualCancelledWhileHolding() async {
        let cancellation = CaptureCancellation()
        let backend = FakeBackend()
        let task = Task {
            try await capture(backend, .manual(limitSeconds: nil, stop: CaptureCancellation()), cancellation: cancellation)
        }
        while await backend.calls.isEmpty { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        cancellation.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("A failed manual stop is reported and the capture closed")
    func manualStopFails() async {
        let backend = FakeBackend(failing: [.stop])
        await #expect(throws: InjectedFault.self) {
            try await capture(backend, .manual(limitSeconds: 0.001, stop: CaptureCancellation()))
        }
        #expect(await backend.calls == [.start, .stop, .close])
    }

    @Test("A trigger that fires is waited on, and not stopped")
    func triggerFires() async throws {
        let backend = FakeBackend()
        try Testgen.verify(try await capture(backend, .trigger(trigger)))
        #expect(await backend.calls == [.start, .wait, .export, .close])
    }

    @Test("A trigger that never fires times out, then stops and closes")
    func triggerTimesOut() async {
        let backend = FakeBackend(hanging: [.wait])
        await #expect(throws: CaptureError.triggerTimeout(seconds: 0.05)) {
            try await capture(backend, .trigger(trigger))
        }
        #expect(await backend.calls == [.start, .wait, .stop, .close])
    }

    @Test("A failing stop after a timeout still reports the timeout and closes")
    func timeoutStopFails() async {
        let backend = FakeBackend(failing: [.stop], hanging: [.wait])
        await #expect(throws: CaptureError.triggerTimeout(seconds: 0.05)) {
            try await capture(backend, .trigger(trigger))
        }
        #expect(await backend.closedIDs == [42])
    }

    @Test("The timeout allows for the capture after the trigger")
    func timeoutIncludesAfter() async throws {
        var long = trigger
        long.afterSeconds = 0.2
        let backend = FakeBackend(onEnter: {
            if $0 == .wait { try? await Task.sleep(for: .milliseconds(120)) }
        })
        try Testgen.verify(try await capture(backend, .trigger(long)))
    }

    @Test("Cancelling while waiting for a trigger reports the cancellation")
    func triggerCancelled() async {
        let cancellation = CaptureCancellation()
        let backend = FakeBackend(hanging: [.wait], onEnter: { if $0 == .wait { cancellation.cancel() } })
        var long = trigger
        long.timeoutSeconds = 3600
        await #expect(throws: CancellationError.self) {
            try await capture(backend, .trigger(long), cancellation: cancellation)
        }
        #expect(await backend.calls == [.start, .wait, .stop, .close])
    }

    @Test("A failed wait on a trigger is reported unchanged")
    func triggerWaitFails() async {
        let backend = FakeBackend(failing: [.wait])
        await #expect(throws: InjectedFault.self) { try await capture(backend, .trigger(trigger)) }
        #expect(await backend.calls == [.start, .wait, .close])
    }

    @Test("Every failing step in every mode closes at most once")
    func everyCombination() async {
        let steps = Step.allCases
        for mask in 0..<(1 << steps.count) {
            let failing = Set(steps.indices.filter { mask & (1 << $0) != 0 }.map { steps[$0] })
            for mode: CaptureMode in [.manual(limitSeconds: 0, stop: CaptureCancellation()), .trigger(trigger)] {
                let backend = FakeBackend(failing: failing)
                _ = try? await capture(backend, mode)
                #expect(await backend.closedIDs.count == (failing.contains(.start) ? 0 : 1), "failing: \(failing)")
            }
        }
    }
}

private let uartRow = "\"a\",\"data\",1,0.5,,0x41\n"
private let uartClean = "name,type,start_time,duration,\"error\",\"data\"\n" + String(repeating: uartRow, count: 3)
private let uartFraming = "name,type,start_time,duration,\"error\",\"data\"\n"
    + String(repeating: "\"a\",\"data\",1,0.5,\"framing\",0x41\n", count: 4)
private let spiWords = "name,type,start_time,duration,\"mosi\"\n\"a\",\"result\",1,0.5,0xA5\n"
private let i2cNack = "name,type,start_time,duration,\"address\",\"read\",\"ack\"\n\"a\",\"address\",1,0.5,0x42,false,false\n"
private let emptyTable = "name,type,start_time,duration\n"

@Suite("Identification confirmation")
struct IdentifyConfirmationTests {
    private func identify(
        _ backend: FakeBackend,
        confirm: Bool = true,
        cancellation: CaptureCancellation = CaptureCancellation()
    ) async throws -> ChannelIdentification {
        let capture = request
        return try await inTemporaryDirectory { directory in
            try await exportIdentifiedCapture(
                capture, confirm: confirm, in: directory, using: backend, cancellation: cancellation)
        }
    }

    private func table(_ provider: @escaping @Sendable (String, String?) -> String)
        -> @Sendable (Saleae_Automation_AddAnalyzerRequest) -> Data
    {
        { add in
            var parity: String?
            if case .stringValue(let value)? = add.settings["Parity Bit"]?.value { parity = value }
            return Data(provider(add.analyzerName, parity).utf8)
        }
    }

    private func standardTables(name: String, parity: String?) -> String {
        switch name {
        case "SPI": spiWords
        case "I2C": i2cNack
        default: uartClean
        }
    }

    @Test("Every bus that decodes is confirmed, and the capture closes")
    func allConfirmed() async throws {
        let backend = FakeBackend(tableProvider: table(standardTables))
        let result = try await identify(backend)
        #expect(result.buses.map(\.confidence) == [.confirmed, .confirmed, .confirmed])
        #expect(result.buses.map(\.decoder.kind) == ["uart", "spi", "i2c"])
        #expect(await backend.closedIDs == [42])
        #expect(await backend.calls.filter { $0 == .analyzer }.count == 3)
    }

    @Test("NACKs seen while confirming are reported")
    func nacksNoted() async throws {
        let backend = FakeBackend(tableProvider: table(standardTables))
        let result = try await identify(backend)
        #expect(result.buses[2].notes.contains("1 NACKs were seen."))
    }

    @Test("Without confirmation no decoder runs and buses stay likely")
    func unconfirmed() async throws {
        let backend = FakeBackend()
        let result = try await identify(backend, confirm: false)
        #expect(result.buses.map(\.confidence) == [.likely, .likely, .likely])
        #expect(await backend.calls == [.start, .wait, .export, .close])
    }

    @Test("A parity is found when no-parity decoding reports errors")
    func parityFound() async throws {
        let backend = FakeBackend(tableProvider: table { name, parity in
            guard name == "Async Serial" else { return self.standardTables(name: name, parity: parity) }
            return parity == "Odd Parity Bit" ? uartClean : uartFraming
        })
        let result = try await identify(backend)
        guard case .uart(let uart) = result.buses[0].decoder else {
            Issue.record("not uart")
            return
        }
        #expect(uart.parity == .odd)
        #expect(result.buses[0].confidence == .confirmed)
        #expect(result.buses[0].decoder.command.contains("--parity odd"))
    }

    @Test("The opposite polarity is tried when no parity decodes")
    func polarityFound() async throws {
        let backend = FakeBackend(tableProvider: { add in
            guard add.analyzerName == "Async Serial" else {
                return Data((add.analyzerName == "SPI" ? spiWords : i2cNack).utf8)
            }
            var inverted = false
            if case .stringValue(let value)? = add.settings["Signal inversion"]?.value { inverted = value == "Inverted" }
            return Data((inverted ? uartClean : uartFraming).utf8)
        })
        let result = try await identify(backend)
        guard case .uart(let uart) = result.buses[0].decoder else {
            Issue.record("not uart")
            return
        }
        #expect(uart.inverted)
        #expect(result.buses[0].confidence == .confirmed)
    }

    @Test("Errors at every parity leave the bus uncertain, with a note")
    func noParityWorks() async throws {
        let backend = FakeBackend(tableProvider: table { name, parity in
            name == "Async Serial" ? uartFraming : self.standardTables(name: name, parity: parity)
        })
        let result = try await identify(backend)
        #expect(result.buses[0].confidence == .uncertain)
        #expect(result.buses[0].notes.last == "Decoding still reported 2 errors with each parity and polarity. Check the frame format.")
        #expect(await backend.calls.filter { $0 == .analyzer }.count == 8)
    }

    @Test("A cut-off first and last frame do not count as errors")
    func windowEdges() async throws {
        let cut = "name,type,start_time,duration,\"error\",\"data\"\n"
            + "\"a\",\"data\",1,0.5,\"framing\",0x41\n" + uartRow + "\"a\",\"data\",1,0.5,\"framing\",0x41\n"
        let backend = FakeBackend(tableProvider: table { name, parity in
            name == "Async Serial" ? cut : self.standardTables(name: name, parity: parity)
        })
        #expect(try await identify(backend).buses[0].confidence == .confirmed)
    }

    @Test("A decoder that finds nothing leaves the bus uncertain, with a note", arguments: [
        ("Async Serial", 0, "Decoding still reported 0 errors with each parity and polarity. Check the frame format."),
        ("SPI", 1, "Logic 2 decoded no SPI words."),
        ("I2C", 2, "Logic 2 decoded no I2C addresses."),
    ])
    func decoderFindsNothing(analyzer: String, index: Int, note: String) async throws {
        let backend = FakeBackend(tableProvider: table { name, parity in
            name == analyzer ? emptyTable : self.standardTables(name: name, parity: parity)
        })
        let result = try await identify(backend)
        #expect(result.buses[index].confidence == .uncertain)
        #expect(result.buses[index].notes.last == note)
    }

    @Test("A failing analyzer fails the identification and still closes")
    func analyzerFails() async {
        let backend = FakeBackend(failing: [.analyzer])
        await #expect(throws: InjectedFault.self) { try await identify(backend) }
        #expect(await backend.closedIDs == [42])
    }

    @Test("Cancelling between buses stops confirming")
    func cancelled() async {
        let cancellation = CaptureCancellation()
        let backend = FakeBackend(
            onEnter: { if $0 == .table { cancellation.cancel() } }, tableProvider: table(standardTables))
        await #expect(throws: CancellationError.self) { try await identify(backend, cancellation: cancellation) }
        #expect(await backend.calls.filter { $0 == .analyzer }.count == 1)
        #expect(await backend.closedIDs == [42])
    }
}

