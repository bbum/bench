import ArgumentParser
import Testing
@testable import sal

@Suite("Argument parsing")
struct ArgumentTests {
    @Test(
        "Valid channel lists",
        arguments: [
            ("0", [UInt32(0)]), ("15", [15]), ("0-3", [0, 1, 2, 3]), ("0,2,4-5", [0, 2, 4, 5]),
            ("3-3", [3]), ("0-15", Array(0...15)), (",1,", [1]),
        ])
    func validChannels(text: String, expected: [UInt32]) throws {
        #expect(try parseChannelList(text) == expected)
    }

    // Regression: "0-4294967295" used to expand before any bound was checked.
    @Test(
        "Invalid channel lists",
        arguments: [
            "", ",", "x", "-", "-1", "1-", "3-1", "0,0", "0-3,2", "16", "0-16", "1-2-3",
            "0-4294967295", "4294967296",
        ])
    func invalidChannels(text: String) {
        #expect(throws: ValidationError.self, "\(text)") { try parseChannelList(text) }
    }

    @Test(
        "Valid sample rates",
        arguments: [
            ("50M", UInt32(50_000_000)), ("625k", 625_000), ("625K", 625_000), ("500000", 500_000),
            ("12.5M", 12_500_000), ("1", 1), ("4294M", 4_294_000_000),
        ])
    func validRates(text: String, expected: UInt32) throws {
        #expect(try parseSampleRate(text) == expected)
    }

    // Regression: "0.4" rounded down to a rate of zero.
    @Test(
        "Invalid sample rates",
        arguments: ["", "M", "fast", "0", "0.4", "-5M", "5000M", "nan", "inf", "infM", "5G", "5m"])
    func invalidRates(text: String) {
        #expect(throws: ValidationError.self, "\(text)") { try parseSampleRate(text) }
    }

    // Regression: "nan" and "inf" reached the server.
    @Test("Invalid durations", arguments: ["0", "-1", "nan", "inf"])
    func invalidDurations(text: String) {
        #expect(throws: (any Error).self, "\(text)") {
            try CaptureCommand.parse(["--duration=\(text)"])
        }
    }

    @Test("Defaults")
    func defaults() throws {
        let command = try CaptureCommand.parse([])
        #expect(command.channels == "0-7")
        #expect(command.capture.rate == nil)
        #expect(command.capture.duration == nil)
        #expect(command.capture.level == 3.3)
        #expect(command.capture.device == nil)
        #expect(!command.json)
    }

    @Test("Endpoint options")
    func endpoint() throws {
        let options = try Logic2Options.parse(["--host", "10.0.0.1", "--port", "99"])
        #expect(options.endpoint.host == "10.0.0.1")
        #expect(options.endpoint.port == 99)
    }
}
