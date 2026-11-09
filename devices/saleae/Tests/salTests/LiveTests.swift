import Foundation
import Testing
@testable import sal

/// Needs Logic 2 running and the testgen board wired up. Run with `make verify`.
@Suite(
    "Live hardware",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["SAL_LIVE"] != nil)
)
struct LiveTests {
    @Test("A live capture of testgen matches the known answers")
    func liveCapture() async throws {
        let request = DigitalCaptureRequest(
            channels: Array(0...7), sampleRate: 50_000_000, durationSeconds: 0.5, levelVolts: 3.3,
            deviceID: nil)
        try Testgen.verify(try await runDigitalCapture(request, endpoint: Logic2Endpoint()))
    }

    @Test("The status command runs")
    func status() async throws {
        let command = try Status.parseAsRoot(["--port", "10430"]) as! Status
        try await command.run()
    }

    @Test("The capture command runs in both output modes", arguments: [[], ["--json"]])
    func capture(flags: [String]) async throws {
        let command = try CaptureCommand.parseAsRoot(["--duration", "0.05"] + flags) as! CaptureCommand
        try await command.run()
    }

    @Test("Logic 2 rejects an invalid sample rate and the error reaches the caller")
    func serverRejection() async {
        let request = DigitalCaptureRequest(
            channels: [0], sampleRate: 123, durationSeconds: 0.05, levelVolts: 3.3, deviceID: nil)
        await #expect(throws: (any Error).self) {
            try await runDigitalCapture(request, endpoint: Logic2Endpoint())
        }
    }
}
