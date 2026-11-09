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
        writeExport: @escaping @Sendable (URL) throws -> Void = copyFixtures
    ) {
        self.failing = failing
        self.hanging = hanging
        self.onEnter = onEnter
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
        try tableBytes.write(to: URL(fileURLWithPath: request.filepath))
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
    channels: Array(0...7), sampleRate: 50_000_000, durationSeconds: 0.5, levelVolts: 3.3, deviceID: "ABC")

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

@Suite("Cancellation")
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

    @Test("Interrupted captures use the shell's SIGINT exit code")
    func exitCode() {
        #expect(interruptedExitCode == 130)
    }
}

private let decodeRequest = DecodeRequest(
    capture: DigitalCaptureRequest(
        channels: [2], sampleRate: 50_000_000, durationSeconds: 0.5, levelVolts: 3.3, deviceID: nil),
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

