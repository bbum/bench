import Foundation

/// Human-readable forms of tool results, for the CLI.
enum Text {
    static func status(_ info: StatusInfo) -> [String] {
        var lines: [String] = []
        if info.meters.isEmpty {
            lines.append("No FNB58 on USB")
        } else {
            lines.append("FNB58 " + info.meters.map(\.serial).joined(separator: ", "))
        }
        if let reading = info.reading {
            lines.append(String(format: "%.5f V  %.5f A  %.4f W", reading.voltageV, reading.currentA, reading.powerW))
            lines.append(String(format: "D+ %.3f V  D- %.3f V  %.1f °C", reading.dPlusV, reading.dMinusV, reading.temperatureC))
        }
        if let device = info.device { lines.append("Model \(device.model), firmware \(device.firmware)") }
        if let capture = info.capturing {
            lines.append(String(format: "Capturing %@: %.2f s, %@", capture.label ?? "(no label)", capture.seconds, capture.csv))
        }
        if let error = info.error { lines.append(error) }
        return lines
    }

    static func summary(_ summary: CaptureSummary) -> [String] {
        var lines = ["\(summary.label.map { "\($0): " } ?? "")\(summary.ended.rawValue)"]
        if let stats = summary.stats { lines += self.stats(stats) }
        lines += summary.marks.map { String(format: "  mark %8.2f s  %@", $0.t, $0.note) }
        lines += summary.warnings.map { "Warning: \($0)" }
        lines.append(summary.csv)
        return lines
    }

    static func window(_ window: WindowStats) -> [String] {
        var lines = [String(format: "%@  %.2f–%.2f s", (window.csv as NSString).lastPathComponent, window.fromSeconds, window.toSeconds)]
        if let stats = window.stats { lines += self.stats(stats) } else { lines.append("No samples in this window.") }
        lines += window.marks.map { String(format: "  mark %8.2f s  %@", $0.t, $0.note) }
        return lines
    }

    static func stats(_ stats: Stats) -> [String] {
        [
            String(format: "  %d samples, %.2f s", stats.samples, stats.durationSeconds),
            String(format: "  current  mean %.5f A  peak %.5f A at %.2f s  p99 %.5f A  min %.5f A",
                   stats.currentA.mean, stats.currentA.peak, stats.currentA.peakAt, stats.currentA.p99, stats.currentA.min),
            String(format: "  voltage  min %.5f V  max %.5f V  mean %.5f V", stats.voltageV.min, stats.voltageV.max, stats.voltageV.mean),
            String(format: "  power    mean %.4f W  peak %.4f W", stats.powerW.mean, stats.powerW.peak),
            String(format: "  energy   %.4f mWh  charge %.4f mAh", stats.energyMWh, stats.chargeMAh),
        ]
    }

    static func raw(_ dump: RawDump) -> [String] {
        var lines = dump.reports.map { String(format: "%7.3f  %@%@", $0.t, $0.hex, $0.crcOK ? "" : "  (crc mismatch)") }
        if dump.truncated { lines.append("… \(dump.total - dump.reports.count) more") }
        let types = dump.types.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        lines.append("\(dump.total) reports in \(dump.seconds) s; types \(types); sign byte values \(dump.signByteValues)")
        return lines
    }
}
