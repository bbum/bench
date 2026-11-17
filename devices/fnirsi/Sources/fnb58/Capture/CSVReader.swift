import Foundation

/// A capture CSV read back: samples and marks.
struct SavedCapture: Sendable {
    var times: [Double] = []
    var voltage: [Double] = []
    var current: [Double] = []
    var marks: [Mark] = []
}

struct CSVError: Error, CustomStringConvertible {
    var description: String
}

/// Reads a CSV written by `CaptureRecorder`. Rows without a reading carry only a mark.
/// Never traps on hostile input: anything unreadable is an error naming the line.
func readCapture(_ url: URL) throws -> SavedCapture {
    let text: String
    do {
        text = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw CSVError(description: "Could not read \(url.path): \(error.localizedDescription)")
    }
    var lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).makeIterator()
    guard let header = lines.next() else { throw CSVError(description: "\(url.path) is empty.") }
    let columns = parseCSVLine(String(header))
    func column(_ name: String) throws -> Int {
        guard let index = columns.firstIndex(of: name) else {
            throw CSVError(description: "\(url.path) has no \(name) column; it is not an fnb58 capture.")
        }
        return index
    }
    let t = try column("t_s"), v = try column("voltage_V"), i = try column("current_A")
    let m = columns.firstIndex(of: "mark")

    var capture = SavedCapture()
    var lineNumber = 1
    while let line = lines.next() {
        lineNumber += 1
        let fields = parseCSVLine(String(line))
        func field(_ index: Int) -> String { index < fields.count ? fields[index] : "" }
        guard let time = Double(field(t)), time.isFinite else {
            throw CSVError(description: "\(url.lastPathComponent) line \(lineNumber): bad time \"\(field(t))\".")
        }
        if let m, !field(m).isEmpty {
            capture.marks.append(Mark(t: time, note: field(m)))
        }
        if field(v).isEmpty && field(i).isEmpty { continue }
        guard let volts = Double(field(v)), let amps = Double(field(i)), volts.isFinite, amps.isFinite else {
            throw CSVError(description: "\(url.lastPathComponent) line \(lineNumber): bad reading.")
        }
        capture.times.append(time)
        capture.voltage.append(volts)
        capture.current.append(amps)
    }
    return capture
}

/// Splits one CSV line, honouring double quotes.
func parseCSVLine(_ line: String) -> [String] {
    var fields: [String] = []
    var field = ""
    var quoted = false
    var characters = line.makeIterator()
    while let character = characters.next() {
        if quoted {
            if character == "\"" {
                if let next = characters.next() {
                    if next == "\"" { field.append("\"") } else {
                        quoted = false
                        if next == "," { fields.append(field); field = "" } else { field.append(next) }
                    }
                } else {
                    quoted = false
                }
            } else {
                field.append(character)
            }
        } else if character == "," {
            fields.append(field)
            field = ""
        } else if character == "\"" && field.isEmpty {
            quoted = true
        } else {
            field.append(character)
        }
    }
    fields.append(field)
    return fields
}

struct WindowStats: Encodable, Sendable {
    var csv: String
    var fromSeconds: Double
    var toSeconds: Double
    var stats: Stats?
    var marks: [Mark]

    enum CodingKeys: String, CodingKey {
        case csv, stats, marks
        case fromSeconds = "from_s"
        case toSeconds = "to_s"
    }
}

/// Samples with `from <= t < to`. Either bound may be left open.
func windowStats(_ capture: SavedCapture, csv: String, from: Double?, to: Double?) throws -> WindowStats {
    let lower = from ?? 0
    let upper = to ?? .infinity
    guard lower.isFinite, !upper.isNaN, lower < upper else {
        throw CSVError(description: "The window must have from < to.")
    }
    var times: [Double] = [], voltage: [Double] = [], current: [Double] = []
    for index in capture.times.indices where capture.times[index] >= lower && capture.times[index] < upper {
        times.append(capture.times[index])
        voltage.append(capture.voltage[index])
        current.append(capture.current[index])
    }
    let end = upper.isFinite ? upper : (capture.times.last.map { $0 + 1 / FNB58.sampleRate } ?? lower)
    return WindowStats(
        csv: csv, fromSeconds: lower, toSeconds: rounded(end, 2),
        stats: Stats(times: times, voltage: voltage, current: current),
        marks: capture.marks.filter { $0.t >= lower && $0.t < upper })
}
