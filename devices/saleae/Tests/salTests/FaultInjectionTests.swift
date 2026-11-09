import Foundation
import Testing
@testable import sal

private enum Step: CaseIterable, Sendable { case start, wait, export, close }
private struct InjectedFault: Error, Equatable {}

private actor FakeBackend: CaptureBackend {
    let failing: Set<Step>
    let writeExport: @Sendable (URL) throws -> Void
    private(set) var calls: [Step] = []
    private(set) var closedIDs: [UInt64] = []
    private(set) var startRequest: Saleae_Automation_StartCaptureRequest?
    private(set) var exportRequest: Saleae_Automation_ExportRawDataBinaryRequest?

    init(
        failing: Set<Step> = [],
        writeExport: @escaping @Sendable (URL) throws -> Void = copyFixtures
    ) {
        self.failing = failing
        self.writeExport = writeExport
    }

    private func record(_ step: Step) throws {
        calls.append(step)
        if failing.contains(step) { throw InjectedFault() }
    }

    func startCapture(_ request: Saleae_Automation_StartCaptureRequest) async throws -> UInt64 {
        startRequest = request
        try record(.start)
        return 42
    }

    func waitCapture(_ captureID: UInt64) async throws {
        try record(.wait)
    }

    func exportBinary(_ request: Saleae_Automation_ExportRawDataBinaryRequest) async throws {
        exportRequest = request
        try record(.export)
        try writeExport(URL(fileURLWithPath: request.directory))
    }

    func closeCapture(_ captureID: UInt64) async throws {
        closedIDs.append(captureID)
        try record(.close)
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
    request: DigitalCaptureRequest = request
) async throws -> (summary: CaptureSummary, directory: URL) {
    final class Box: @unchecked Sendable { var directory: URL? }
    let box = Box()
    let summary = try await summarizedCapture(request) { directory in
        box.directory = directory
        try await exportDigitalCapture(request, to: directory, using: backend)
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
                try await exportDigitalCapture(request, to: directory, using: backend)
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
