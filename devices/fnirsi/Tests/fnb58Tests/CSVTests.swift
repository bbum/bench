import Foundation
import Testing
@testable import fnb58

@Suite struct CSVTests {
    private func record(_ samples: [Sample], marks: [(after: Int, note: String)] = [], label: String? = "test") throws -> (CaptureSummary, URL) {
        let directory = temporaryDirectory()
        let recorder = try CaptureRecorder(label: label, directory: directory)
        var written = 0
        for (after, note) in marks.sorted(by: { $0.after < $1.after }) {
            if after > written { try recorder.append(Array(samples[written..<after])); written = after }
            recorder.mark(note)
        }
        if written < samples.count { try recorder.append(Array(samples[written...])) }
        let summary = recorder.finish(ended: .completed, warnings: [])
        return (summary, URL(fileURLWithPath: summary.csv))
    }

    @Test func roundTripsSamplesAndMarks() throws {
        let samples = (0..<250).map { sample(5 + Double($0 % 7) / 1000, Double($0) / 1000) }
        let notes = ["print sent", "a, b", "she said \"hi\"", "line\nbreak", "two; three"]
        let (summary, url) = try record(samples, marks: [(0, notes[0]), (10, notes[1]), (10, notes[2]), (99, notes[3]), (250, notes[4])])
        #expect(try readCapture(url).marks.last?.note == "two; three")
        let saved = try readCapture(url)
        #expect(saved.times.count == 250)
        #expect(saved.times[0] == 0 && saved.times[249] == 2.49)
        #expect(zip(saved.current, samples.map(\.current)).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(saved.marks.map(\.note) == ["print sent", "a, b", "she said \"hi\"", "line break", "two; three"])
        #expect(summary.marks.map(\.note) == saved.marks.map(\.note))
        #expect(summary.marks.map(\.t) == [0, 0.1, 0.1, 0.99, 2.5])
        #expect(saved.marks.map(\.t) == [0, 0.1, 0.1, 0.99, 2.5])
        #expect(summary.stats?.samples == 250)
        // The summary sits beside the CSV.
        #expect(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("json").path))
    }

    @Test func markAfterTheLastSampleGetsItsOwnRow() throws {
        let (summary, url) = try record([sample(5, 1)], marks: [(1, "late")])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasSuffix("0.01,,,,,,,late\n"))
        let saved = try readCapture(url)
        #expect(saved.times.count == 1)
        #expect(saved.marks == [Mark(t: 0.01, note: "late")])
        #expect(summary.marks == [Mark(t: 0.01, note: "late")])
    }

    @Test func emptyCaptureWarns() throws {
        let (summary, url) = try record([])
        #expect(summary.stats == nil)
        #expect(summary.warnings.contains("No samples were recorded."))
        #expect(try readCapture(url).times.isEmpty)
    }

    @Test func fileNames() {
        let date = Date(timeIntervalSince1970: 0)
        let stem = captureStem(label: "Print: Test / #1", started: date)
        #expect(stem.hasSuffix("-print-test-1"))
        #expect(!captureStem(label: nil, started: date).contains("--"))
        #expect(captureStem(label: "///", started: date) == captureStem(label: nil, started: date))
        #expect(captureStem(label: String(repeating: "a", count: 200), started: date).count <= 15 + 1 + 48)
        let directory = temporaryDirectory()
        let first = uniqueURL(directory, stem: "x", ext: "csv")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        #expect(uniqueURL(directory, stem: "x", ext: "csv").lastPathComponent == "x-2.csv")
    }

    @Test func csvLineParsing() {
        #expect(parseCSVLine("a,b,c") == ["a", "b", "c"])
        #expect(parseCSVLine("") == [""])
        #expect(parseCSVLine(",") == ["", ""])
        #expect(parseCSVLine("\"a,b\",c") == ["a,b", "c"])
        #expect(parseCSVLine("\"say \"\"x\"\"\"") == ["say \"x\""])
        #expect(parseCSVLine("\"unterminated") == ["unterminated"])
        #expect(parseCSVLine(csvField("a,\"b\"") + ",z") == ["a,\"b\"", "z"])
    }

    @Test func windowBounds() throws {
        let samples = (0..<100).map { sample(5, Double($0)) }
        let (_, url) = try record(samples, marks: [(20, "in"), (50, "edge")])
        let saved = try readCapture(url)
        // From is inclusive, to exclusive: 0.20 up to but not 0.50.
        let window = try windowStats(saved, csv: url.path, from: 0.2, to: 0.5)
        #expect(window.stats?.samples == 30)
        #expect(window.stats?.currentA.min == 20)
        #expect(window.stats?.currentA.peak == 49)
        #expect(window.marks.map(\.note) == ["in"])
        let open = try windowStats(saved, csv: url.path, from: nil, to: nil)
        #expect(open.stats?.samples == 100)
        #expect(open.toSeconds == 1)
        #expect(try windowStats(saved, csv: url.path, from: 5, to: 6).stats == nil)
        #expect(throws: CSVError.self) { try windowStats(saved, csv: url.path, from: 1, to: 1) }
        #expect(throws: CSVError.self) { try windowStats(saved, csv: url.path, from: 2, to: 1) }
        #expect(throws: CSVError.self) { try windowStats(saved, csv: url.path, from: .nan, to: 1) }
        #expect(throws: CSVError.self) { try windowStats(saved, csv: url.path, from: 0, to: .nan) }
    }

    @Test func rejectsFilesThatAreNotCaptures() throws {
        let directory = temporaryDirectory()
        func file(_ text: String) -> URL {
            let url = directory.appendingPathComponent(UUID().uuidString + ".csv")
            try? Data(text.utf8).write(to: url)
            return url
        }
        #expect(throws: CSVError.self) { try readCapture(directory.appendingPathComponent("missing.csv")) }
        #expect(throws: CSVError.self) { try readCapture(file("")) }
        #expect(throws: CSVError.self) { try readCapture(file("a,b,c\n1,2,3\n")) }
        #expect(throws: CSVError.self) { try readCapture(file(csvHeader + "\nx,5,1,,,,,\n")) }
        #expect(throws: CSVError.self) { try readCapture(file(csvHeader + "\n0,5,,,,,,\n")) }
        #expect(throws: CSVError.self) { try readCapture(file(csvHeader + "\n0,inf,1,,,,,\n")) }
        #expect(try readCapture(file(csvHeader + "\r\n0,5,1,5,,,,\r\n")).times == [0])
    }

    /// Every truncation and seeded corruption of a real file: read or reject, never trap.
    @Test func corruptFilesNeverTrap() throws {
        let (_, url) = try record((0..<20).map { sample(5, Double($0) / 10) }, marks: [(3, "x,\"y\"")])
        let good = try Data(contentsOf: url)
        let directory = temporaryDirectory()
        let target = directory.appendingPathComponent("c.csv")
        for length in 0...good.count {
            try good.prefix(length).write(to: target)
            _ = try? readCapture(target)
        }
        var rng = SeededGenerator(seed: 99)
        let alphabet = Array("0123456789.,-\"\n\re+ nanif".utf8) + [0xFF, 0x00]
        for _ in 0..<3000 {
            var bytes = [UInt8](good)
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = alphabet.randomElement(using: &rng)!
            }
            try Data(bytes).write(to: target)
            if let saved = try? readCapture(target) {
                #expect(saved.times.count == saved.voltage.count && saved.voltage.count == saved.current.count)
                _ = try? windowStats(saved, csv: target.path, from: 0, to: 1)
                _ = Stats(times: saved.times, voltage: saved.voltage, current: saved.current)
            }
        }
    }
}
