import Foundation
import Testing
@testable import sal

@Suite("Binary export parsing")
struct DigitalChannelTests {
    @Test("Reads a real export from disk")
    func readsRealExport() throws {
        let channel = try DigitalChannel(
            contentsOf: fixtureDirectory.appendingPathComponent("digital_0.bin"))
        #expect(channel.initialLevel == 1)
        #expect(channel.edgeCount == 1069)
        #expect(channel.endTime > channel.beginTime)
    }

    @Test("Every real fixture passes validation", arguments: 0...7)
    func fixturesValidate(channel: Int) throws {
        _ = try parse(try fixtureBytes(channel))
    }

    @Test("A missing file throws")
    func missingFile() {
        #expect(throws: (any Error).self) {
            try DigitalChannel(contentsOf: URL(fileURLWithPath: "/nonexistent/digital_0.bin"))
        }
    }

    @Test("Accepts the smallest valid files")
    func smallestValid() throws {
        #expect(try parse(digitalFile()).edgeCount == 0)
        #expect(try parse(digitalFile(initial: 1, end: 2, times: [1])).initialLevel == 1)
        #expect(try parse(digitalFile(begin: -5, end: 5, times: [-5, 5])).edgeCount == 2)
    }

    @Test("Edge times can be read back")
    func readsEdgeTimes() throws {
        let channel = try parse(digitalFile(end: 4, times: [1, 2.5, 4]))
        let times = channel.withEdgeTimes { view in (0..<view.count).map { view[$0] } }
        #expect(times == [1, 2.5, 4])
    }

    // MARK: Malformed headers

    @Test("Rejects files shorter than the header", arguments: [0, 1, 8, 43])
    func tooShort(length: Int) {
        #expect(throws: DigitalFileError.tooShort(name: "test")) {
            try parse(digitalFile().prefix(length))
        }
    }

    @Test("Rejects a bad magic")
    func badMagic() {
        var data = digitalFile()
        data[0] = 0x00
        #expect(throws: DigitalFileError.badMagic(name: "test")) { try parse(data) }
    }

    @Test("Rejects unknown versions", arguments: [1, 2, -1, Int32.max, Int32.min])
    func unsupportedVersion(version: Int32) {
        #expect(throws: DigitalFileError.unsupportedVersion(name: "test", version: version)) {
            try parse(digitalFile(version: version))
        }
    }

    @Test("Rejects non-digital types", arguments: [1, 2, -1, Int32.max])
    func notDigital(type: Int32) {
        #expect(throws: DigitalFileError.notDigital(name: "test", type: type)) {
            try parse(digitalFile(type: type))
        }
    }

    @Test("Rejects initial levels other than 0 and 1", arguments: [2, -1, Int32.max, Int32.min])
    func invalidLevel(level: Int32) {
        #expect(throws: DigitalFileError.invalidInitialLevel(name: "test", level: level)) {
            try parse(digitalFile(initial: level))
        }
    }

    @Test(
        "Rejects invalid time ranges",
        arguments: [
            (Double.nan, 1.0), (0.0, Double.nan), (Double.infinity, 1.0), (0.0, Double.infinity),
            (-Double.infinity, 0.0), (2.0, 1.0),
            (-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude),
        ])
    func invalidTimeRange(begin: Double, end: Double) {
        #expect(throws: DigitalFileError.invalidTimeRange(name: "test")) {
            try parse(digitalFile(begin: begin, end: end))
        }
    }

    // MARK: Regression: counts that overflowed the size calculation and trapped

    @Test(
        "Rejects edge counts that do not fit the file",
        arguments: [Int64.max, Int64.min, -1, 1 << 61, 1 << 60, 1])
    func invalidEdgeCount(count: Int64) {
        #expect(throws: DigitalFileError.invalidEdgeCount(name: "test", count: count)) {
            try parse(digitalFile(count: count))
        }
    }

    @Test("Rejects trailing bytes")
    func trailingBytes() {
        var data = digitalFile(end: 1, times: [1])
        data.append(0)
        #expect(throws: DigitalFileError.sizeMismatch(name: "test", expected: 52, actual: 53)) {
            try parse(data)
        }
    }

    // MARK: Malformed edge times

    @Test("Rejects repeated edge times")
    func repeatedEdge() {
        #expect(throws: DigitalFileError.invalidEdgeTime(name: "test", index: 1)) {
            try parse(digitalFile(end: 2, times: [1, 1, 2]))
        }
    }

    @Test("Rejects decreasing edge times")
    func decreasingEdge() {
        #expect(throws: DigitalFileError.invalidEdgeTime(name: "test", index: 1)) {
            try parse(digitalFile(end: 3, times: [2, 1, 3]))
        }
    }

    @Test("Rejects edges before the capture")
    func edgeBeforeBegin() {
        #expect(throws: DigitalFileError.invalidEdgeTime(name: "test", index: 0)) {
            try parse(digitalFile(begin: 1, end: 3, times: [0.5]))
        }
    }

    @Test("Rejects edges after the capture")
    func edgeAfterEnd() {
        #expect(throws: DigitalFileError.invalidEdgeTime(name: "test", index: 1)) {
            try parse(digitalFile(end: 2, times: [1, 3]))
        }
    }

    @Test("Rejects non-finite edge times", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteEdge(time: Double) {
        #expect(throws: DigitalFileError.invalidEdgeTime(name: "test", index: 0)) {
            try parse(digitalFile(end: 1, times: [time]))
        }
    }

    @Test("Every error describes itself and names the file")
    func errorDescriptions() {
        let errors: [DigitalFileError] = [
            .tooShort(name: "f"), .badMagic(name: "f"), .unsupportedVersion(name: "f", version: 1),
            .notDigital(name: "f", type: 1), .invalidInitialLevel(name: "f", level: 2),
            .invalidTimeRange(name: "f"), .invalidEdgeCount(name: "f", count: -1),
            .sizeMismatch(name: "f", expected: 1, actual: 2), .invalidEdgeTime(name: "f", index: 3),
        ]
        for error in errors {
            #expect(error.errorDescription?.hasPrefix("f: ") == true)
        }
    }
}
