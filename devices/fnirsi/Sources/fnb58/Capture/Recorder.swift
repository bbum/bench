import Foundation

struct Mark: Codable, Equatable, Sendable {
    var t: Double
    var note: String

    enum CodingKeys: String, CodingKey {
        case t = "t_s"
        case note
    }
}

enum CaptureEnd: String, Encodable, Sendable {
    /// Reached the requested length.
    case completed
    /// stop_capture, or the CLI's own stop.
    case stopped
    /// Cancelled, or Ctrl-C.
    case interrupted
    /// The meter went away. Samples up to then are kept.
    case disconnected
    /// The meter stopped sending.
    case stalled
    /// The CSV could not be written.
    case failed
}

func summaryFailed(_ ended: CaptureEnd) -> Bool { ended == .disconnected || ended == .stalled || ended == .failed }

struct CaptureSummary: Encodable, Sendable {
    var label: String?
    var csv: String
    var started: Date
    var ended: CaptureEnd
    /// Nil when no samples arrived.
    var stats: Stats?
    var marks: [Mark]
    var warnings: [String]

    var failed: Bool { summaryFailed(ended) }
}

/// The CSV columns, in order.
let csvHeader = "t_s,voltage_V,current_A,power_W,dplus_V,dminus_V,temp_C,mark"

/// Writes every sample to a CSV as it arrives, so a crash or unplug keeps what came before.
/// Times are sample index / 100, never wall clock.
final class CaptureRecorder {
    let label: String?
    let url: URL
    let started: Date
    private(set) var count = 0
    private(set) var marks: [Mark] = []
    private var pending: [String] = []
    private var times: [Double] = []
    private var voltage: [Double] = []
    private var current: [Double] = []
    private let handle: FileHandle

    init(label: String?, directory: URL, started: Date = Date()) throws {
        self.label = label
        self.started = started
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = uniqueURL(directory, stem: captureStem(label: label, started: started), ext: "csv")
        guard FileManager.default.createFile(atPath: url.path, contents: Data((csvHeader + "\n").utf8)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    var seconds: Double { Double(count) / FNB58.sampleRate }

    func append(_ samples: [Sample]) throws {
        var text = ""
        for sample in samples {
            let t = Double(count) / FNB58.sampleRate
            // One mark per row: extras on this sample get rows of their own, before it.
            for note in pending.dropLast() { text += markRow(t, note) }
            text += String(format: "%.2f,%.5f,%.5f,%.6f,%.3f,%.3f,%.1f,", t, sample.voltage, sample.current, sample.power,
                           sample.dPlus, sample.dMinus, sample.temperature)
            text += csvField(pending.last ?? "") + "\n"
            pending.removeAll()
            times.append(t)
            voltage.append(sample.voltage)
            current.append(sample.current)
            count += 1
        }
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Lands on the next sample written, at that sample's time.
    @discardableResult
    func mark(_ text: String) -> Mark {
        // Rows are lines, so a note is kept to one.
        let note = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let mark = Mark(t: rounded(seconds, 2), note: note)
        marks.append(mark)
        pending.append(note)
        return mark
    }

    func finish(ended: CaptureEnd, warnings: [String]) -> CaptureSummary {
        if !pending.isEmpty {
            // No sample followed the mark. Keep it in the file on a row of its own.
            let rows = pending.map { markRow(seconds, $0) }.joined()
            try? handle.write(contentsOf: Data(rows.utf8))
            pending.removeAll()
        }
        try? handle.close()
        var warnings = warnings
        if count == 0 { warnings.append("No samples were recorded.") }
        let summary = CaptureSummary(
            label: label, csv: url.path, started: started, ended: ended,
            stats: Stats(times: times, voltage: voltage, current: current), marks: marks, warnings: warnings)
        if let data = try? summaryJSON(summary) {
            try? data.write(to: url.deletingPathExtension().appendingPathExtension("json"))
        }
        return summary
    }
}

/// A row with no reading, only a mark.
private func markRow(_ t: Double, _ note: String) -> String {
    String(format: "%.2f,,,,,,,", t) + csvField(note) + "\n"
}

/// Quotes a CSV field when it needs it.
func csvField(_ text: String) -> String {
    guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
    return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// `20261116-142233-label`, with the label cut down to safe filename characters.
func captureStem(label: String?, started: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: started)
    let slug = String((label ?? "").lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-").prefix(48))
    return slug.isEmpty ? stamp : "\(stamp)-\(slug)"
}

func uniqueURL(_ directory: URL, stem: String, ext: String) -> URL {
    var url = directory.appendingPathComponent(stem).appendingPathExtension(ext)
    var suffix = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = directory.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension(ext)
        suffix += 1
    }
    return url
}

func summaryJSON(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return try encoder.encode(value)
}
