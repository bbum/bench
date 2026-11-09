#!/usr/bin/env python3
"""Injects bugs into sal one at a time. The offline tests must catch every one.

Run from devices/saleae with `make mutation`. Sources are restored after each mutant.
"""

import os
import pathlib
import signal
import subprocess
import sys

TEST_TIMEOUT_SECONDS = 300
ROOT = pathlib.Path("Sources/sal")
CHANNEL = ROOT / "Analysis/DigitalChannel.swift"
SUMMARY = ROOT / "Analysis/ChannelSummary.swift"
CAPTURE = ROOT / "Logic2/DigitalCapture.swift"
COMMAND = ROOT / "Subcommands/CaptureCommand.swift"
MAIN = ROOT / "sal.swift"
CANCEL = ROOT / "Logic2/Cancellation.swift"
TABLE = ROOT / "Analysis/DecodedTable.swift"
DECODERS = ROOT / "Logic2/Decoders.swift"
DECODE = ROOT / "Subcommands/DecodeCommand.swift"
MODE = ROOT / "Logic2/CaptureMode.swift"
OPTIONS = ROOT / "Subcommands/CaptureOptions.swift"
IDENTIFY = ROOT / "Analysis/ChannelIdentification.swift"
ANALOG = ROOT / "Analysis/AnalogChannel.swift"
SERVER = ROOT / "MCP/MCPServer.swift"
TOOLS = ROOT / "MCP/SalTools.swift"
TIMING = ROOT / "Analysis/Timing.swift"
ANALYZE = ROOT / "Subcommands/AnalyzeCommand.swift"
TIMELINE = ROOT / "Analysis/Timeline.swift"
RENDER = ROOT / "Rendering/TimelineRenderer.swift"
TIMELINE_CMD = ROOT / "Subcommands/TimelineCommand.swift"

MUTANTS = [
    (CHANNEL, "guard version == 0 else", "guard version >= 0 else"),
    (CHANNEL, "guard type == 0 else", "guard type >= 0 else"),
    (CHANNEL, "level == 0 || level == 1", "level >= 0"),
    (CHANNEL, "end >= begin, ", ""),
    (CHANNEL, ", (end - begin).isFinite else", " else"),
    (CHANNEL, "guard count >= 0, count <=", "guard count <="),
    (CHANNEL, "guard data.count == expected", "guard data.count >= expected"),
    (CHANNEL, "guard time > previous,", "guard time >= previous,"),
    (CHANNEL, "time >= begin, ", ""),
    (CHANNEL, ", time <= end else", " else"),
    (SUMMARY, "$0 > spacing * 20", "$0 >= spacing * 20"),
    (SUMMARY, "periods.count >= 3", "periods.count >= 2"),
    (SUMMARY, "median * 0.05", "median * 0.06"),
    (SUMMARY, "(values.count - 1) / 2", "values.count / 2"),
    (SUMMARY, "guard frequency.isFinite else { return nil }", ""),
    (SUMMARY, "100 * (totalHigh", "99 * (totalHigh"),
    (SUMMARY, "max(duration, digital.endTime - digital.beginTime)", "digital.endTime - digital.beginTime"),
    (SUMMARY, "minHigh = min(minHigh ?? width, width)", "minHigh = max(minHigh ?? width, width)"),
    (SUMMARY, "minLow = min(minLow ?? width, width)", "minLow = max(minLow ?? width, width)"),
    (SUMMARY, "periodJitterSeconds: variance.squareRoot()", "periodJitterSeconds: variance"),
    (SUMMARY, "periodMinSeconds: periods.min()!", "periodMinSeconds: periods.max()!"),
    (SUMMARY, "periodMaxSeconds: periods.max()!", "periodMaxSeconds: periods.min()!"),
    (CAPTURE, "        try? await backend.closeCapture(captureID)\n", ""),
    (CAPTURE, "export.analogDownsampleRatio = request.analog?.downsample ?? 1", "export.analogDownsampleRatio = 2"),
    (MODE, "device.analogSampleRate = analog?.sampleRate ?? 0", "device.analogSampleRate = 0"),
    (OPTIONS, 'analog == nil ? "50M" : "6.25M"', '"50M"'),
    (OPTIONS, "(1...maximumAnalogDownsample).contains", "(0...maximumAnalogDownsample).contains"),
    (ANALOG, "guard type == 1 else", "guard type >= 0 else"),
    (ANALOG, "guard begin.isFinite else", "guard true else"),
    (ANALOG, "downsample > 0, downsample <= rate else", "downsample > 0 else"),
    (ANALOG, "guard count > 0, count <=", "guard count <="),
    (ANALOG, "guard data.count == expected", "guard data.count >= expected"),
    (ANALOG, "if !sample.isFinite { return index }", ""),
    (ANALOG, "Double(rate) / Double(downsample)", "Double(rate)"),
    (ANALOG, "guard swing >= minimumSwingVolts", "guard swing > 0"),
    (ANALOG, "hysteresis: swing * 0.1", "hysteresis: 0"),
    (ANALOG, "guard rises.count >= 4", "guard rises.count >= 3"),
    (ANALOG, "abs($0 - median) <= median * 0.05", "abs($0 - median) <= median * 0.2"),
    (ANALOG, "highAtLastRise - highAtFirstRise", "highAtLastRise"),
    (MODE, "device.digitalThresholdVolts = levelVolts", "device.digitalThresholdVolts = 1.8"),
    (MODE, "value.isFinite, value > 0 else", "value.isFinite else"),
    (MODE, "trigger.maximumPulse?.value ?? (", "trigger.minimumPulse?.value ?? ("),
    (MODE, "trigger.point.kind.isPulse ? unboundedPulseSeconds : 0", "unboundedPulseSeconds"),
    (MODE, "trigger.point.kind.isPulse ? unboundedPulseSeconds : 0", "0"),
    (MODE, "linked.state = link.isHigh ? .high : .low", "linked.state = .high"),
    (MODE, "case .high: .pulseHigh", "case .high: .pulseLow"),
    (MODE, "timed.trimDataSeconds = trimSeconds", "timed.trimDataSeconds = 0"),
    (MODE, "manual.trimDataSeconds = trimSeconds", "manual.trimDataSeconds = 0"),
    (MODE, "entry.pulseWidthSeconds = filter.width.value", "entry.pulseWidthSeconds = 0"),
    (MODE, "bufferSizeMegabytes = bufferMegabytes ?? 0", "bufferSizeMegabytes = 0"),
    (CAPTURE, "            try await backend.stopCapture(captureID)\n        case .trigger", "        case .trigger"),
    (CAPTURE, "trigger.timeoutSeconds + trigger.afterSeconds", "trigger.timeoutSeconds"),
    (CAPTURE, "        try? await backend.stopCapture(captureID)\n        throw CaptureError", "        throw CaptureError"),
    (OPTIONS, "guard pulseMin.value <= pulseMax.value", "guard pulseMin.value < pulseMax.value"),
    (OPTIONS, "guard !(manual && trigger != nil) else", "guard true else"),
    (OPTIONS, "guard trigger == nil || trim == nil else", "guard true else"),
    (OPTIONS, "let captured = Array(Set(channels + extra)).sorted()", "let captured = channels"),
    (OPTIONS, "interrupt: manual ? stopManual : nil", "interrupt: nil"),
    (CAPTURE, "    try await backend.closeCapture(captureID)\n}", "    try? await backend.closeCapture(captureID)\n}"),
    (CAPTURE, "    defer { try? FileManager.default.removeItem(at: directory) }\n", ""),
    (CAPTURE, "    try cancellation.checkCancelled()\n    let captureID", "    let captureID"),
    (CAPTURE, "        try cancellation.checkCancelled()\n    } catch", "    } catch"),
    (CAPTURE, "if cancellation.isCancelled { try? await backend.stopCapture(captureID) }", ""),
    (CAPTURE, "if cancellation.isCancelled { try?", "try? await backend.stopCapture(captureID); if false { try?"),
    (CAPTURE, "try await cancellation.interruptible { try await backend.waitCapture(captureID) }", "try await backend.waitCapture(captureID)"),
    (CANCEL, "        task?.cancel()\n", ""),
    (CANCEL, "        try checkCancelled()\n        let task", "        let task"),
    (CANCEL, "            try checkCancelled()\n            throw error", "            throw error"),
    (CANCEL, "        }\n        try checkCancelled()\n    }", "        }\n    }"),
    (CANCEL, "        cancellation.cancel()\n", ""),
    (CANCEL, "            signal(number, previous)\n            if let interrupt", "            if let interrupt"),
    (CANCEL, "                work.cancel()\n", ""),
    (CANCEL, "                interrupt()\n", ""),
    (COMMAND, "interruptedExitCode: Int32 = 130", "interruptedExitCode: Int32 = 1"),
    (COMMAND, "maximumChannel: UInt32 = 15", "maximumChannel: UInt32 = 16"),
    (COMMAND, ",\n        rate > 0\n", "\n"),
    (OPTIONS, "guard duration.isFinite, duration > 0", "guard duration > 0"),
    (COMMAND, "Set(channels).count == channels.count", "true"),
    (COMMAND, "case 1...: String", "case 2...: String"),
    (TABLE, "guard record.isEmpty, field.isEmpty, !afterQuote else", "guard true else"),
    (TABLE, "guard !inQuotes else", "guard true else"),
    (TABLE, "guard field.isEmpty, !afterQuote else", "guard !afterQuote else"),
    (TABLE, "guard record.count == header.count else", "guard record.count >= header.count else"),
    (TABLE, "Set(header).count == header.count", "true"),
    (TABLE, "start.isFinite,", "true,"),
    (TABLE, "duration.isFinite, duration >= 0", "duration >= 0"),
    (TABLE, "duration.isFinite, duration >= 0", "duration.isFinite"),
    (TABLE, " where !record[column].isEmpty", ""),
    (TABLE, 'row.type == "address" || !reading', "!reading"),
    (TABLE, 'reading = read == "true"', "reading = false"),
    (TABLE, "rows.dropFirst(offset).prefix(limit)", "rows.prefix(limit)"),
    (DECODERS, 'case 1: "1 Bit per Transfer"', 'case 1: "1 Bits per Transfer"'),
    (DECODERS, "wordBits: ClosedRange<Int> = 1...64", "wordBits: ClosedRange<Int> = 1...65"),
    (DECODERS, "[i2c.sda, i2c.scl].sorted()", "[i2c.sda, i2c.scl]"),
    (CAPTURE, "analyzer.radixType = radix.type", "analyzer.radixType = .hexadecimal"),
    (DECODE, "guard baud > 0", "guard baud >= 0"),
    (DECODE, "guard limit > 0", "guard limit >= 0"),
    (DECODE, "guard offset >= 0", "guard offset > 0"),
    (IDENTIFY, "let byteClocks = clocks - 1", "let byteClocks = clocks"),
    (IDENTIFY, "byteClocks.isMultiple(of: 9)", "byteClocks.isMultiple(of: 8)"),
    (IDENTIFY, "(edges / 2).isMultiple(of: 8)", "(edges / 2).isMultiple(of: 7)"),
    (IDENTIFY, "dataOnTrailingEdge: leading > trailing", "dataOnTrailingEdge: leading < trailing"),
    (IDENTIFY, "clockIdlesHigh: clock.restingLevel == 1", "clockIdlesHigh: clock.restingLevel == 0"),
    (IDENTIFY, "decoder.enableActiveHigh = level == 1", "decoder.enableActiveHigh = level == 0"),
    (IDENTIFY, "inverted: resting == 0", "inverted: resting == 1"),
    (IDENTIFY, "guard whole <= longestActiveBits else { return nil }", ""),
    (IDENTIFY, "if candidate.level(afterEdges: index + 1) == resting {", "if false {"),
    (IDENTIFY, "for _ in 0..<3 {", "for _ in 0..<0 {"),
    (IDENTIFY, "$0.summary.initialLevel == 1 }", "false }"),
    (CAPTURE, "for inverted in [uart.inverted, !uart.inverted]", "for inverted in [uart.inverted]"),
    (CAPTURE, "for parity in Parity.allCases", "for parity in [Parity.none]"),
    (CAPTURE, "rows.dropFirst(start).dropLast()", "rows.dropFirst(start)"),
    (CAPTURE, "13 / Double(baud)", "1 / Double(baud)"),
    (CAPTURE, "    if !request.exportsEverything { export.logicChannels = request.logicChannels }\n    // The server", "    export.logicChannels = request.logicChannels\n    // The server"),
    (CAPTURE, "if let savePath = request.savePath { try await backend.saveCapture(captureID, to: savePath) }", ""),
    (CAPTURE, "add.inputAnalyzerID = analyzerID", "add.inputAnalyzerID = 0"),
    (CAPTURE, "shownID = try await backend.addHighLevelAnalyzer(add)", "_ = try await backend.addHighLevelAnalyzer(add)"),
    (CAPTURE, "legacy.analyzerID = analyzerID", "legacy.analyzerID = shownID"),
    (CAPTURE, "export.iso8601Timestamp = options.iso8601", "export.iso8601Timestamp = false"),
    (CAPTURE, "export.exportColumns = options.columns", ""),
    (CAPTURE, "export.filter.columns = options.filterColumns", ""),
    (CAPTURE, "export.iso8601Timestamp = rawCSV.iso8601", "export.iso8601Timestamp = false"),
    (CAPTURE, "if case .load = mode, channels.isEmpty, analog == nil { true }", "if case .load = mode { true }"),
    (OPTIONS, "guard !capturing else", "guard true else"),
    (OPTIONS, 'case nil: loading ? [] : try parseChannelList("0-7")', 'case nil: try parseChannelList("0-7")'),
    (DECODERS, "if let number = Double(text), number.isFinite {", "if let number = Double(text) {"),
    (DECODE, "guard (hla == nil) == (hlaExtension == nil) else", "guard true else"),
    (DECODE, "guard hla != nil || hlaSetting.isEmpty else", "guard true else"),
    (SERVER, 'if request.method == "notifications/cancelled" {', "if false {"),
    (SERVER, "running.values.forEach { $0.cancel() }", ""),
    (SERVER, "await previous?.value", ""),
    (SERVER, "Task.isCancelled ? nil : result", "result"),
    (SERVER, "guard !Task.isCancelled else { return nil }", ""),
    (SERVER, 'if isError { result["isError"] = .bool(true) }', ""),
    (SERVER, 'params?["protocolVersion"] ?? .string("2024-11-05")', '.string("2024-11-05")'),
    (SERVER, "if byte == 0x0A {", "if byte == 0x0A || byte == 0x0D {"),
    (TOOLS, "guard allowed.contains(key) else", "guard true else"),
    (TOOLS, 'line.append("\\(flag)=\\(try scalarText(value, key: key))")', 'line.append(flag); line.append(try scalarText(value, key: key))'),
    (TOOLS, 'if arguments["manual"] == .bool(true), arguments["duration"] == nil {', "if false {"),
    (TOOLS, 'if arguments["limit"] == nil { line.append("--limit=\\(defaultToolRowLimit)") }', ""),
    (TIMING, "medianSeconds = sorted[(sorted.count - 1) / 2]", "medianSeconds = sorted[sorted.count / 2]"),
    (TIMING, "let wanted = kind == .rising ? 1 : 0", "let wanted = kind == .rising ? 0 : 1"),
    (TIMING, "if index + 1 < from.count, end >= from[index + 1] { continue }", ""),
    (TIMING, "end - start > maximum", "end - start >= maximum"),
    (TIMING, "line.times[through - 1] == edge ? through - 2 : through - 1", "line.times[through - 1] == edge ? through - 1 : through - 1"),
    (TIMING, "window.map({ setup <= $0 }) ?? true", "true"),
    (TIMING, "window.map({ hold <= $0 }) ?? true", "true"),
    (TIMING, "setups.count { $0 < limit }", "setups.count { $0 <= limit }"),
    (TIMING, "holds.count { $0 < limit }", "holds.count { $0 <= limit }"),
    (TIMING, "where next - previous > gap", "where next - previous >= gap"),
    (TIMING, "max(first - channel.beginTime, channel.endTime - last)", "first - channel.beginTime"),
    (TIMING, "    busy += last - burstStart\n", ""),
    (ANALYZE, "guard from != to else", "guard true else"),
    (ANALYZE, "guard clock.kind != .either else", "guard true else"),
    (TOOLS, 'kind.replacingOccurrences(of: "_", with: "-")', "kind"),
    (TIMELINE, "channel.edgesThrough(to.nextDown)", "channel.edgesThrough(to)"),
    (TIMELINE, "channel.edgesThrough(from + windowStartTolerance)", "channel.edgesThrough(from)"),
    (TIMELINE, "windowStartTolerance = 1e-12", "windowStartTolerance = 1e-8"),
    (TIMELINE, "guard pieces.count > maxSegments else", "guard pieces.count >= maxSegments else"),
    (TIMELINE, "let resolution = 2 * (to - from)", "let resolution = 1 * (to - from)"),
    (TIMELINE, "run.count == 1 ? head : ", ""),
    (TIMELINE, "edges: run.count - 1", "edges: run.count"),
    (TIMELINE, "if piece.end - piece.start < resolution {", "if piece.end - piece.start <= 0 {"),
    (TIMELINE, "    flushRun()\n    return DigitalTrace", "    return DigitalTrace"),
    (TIMELINE, "low = min(low, samples[position])", "low = samples[position]"),
    (TIMELINE, "high = max(high, samples[position])", "high = samples[position]"),
    (TIMELINE, "(volts * 1000).rounded() / 1000", "volts"),
    (TIMELINE, "let lower = max(0, ((from - analog.beginTime) * rate - sampleEpsilon)", "let lower = max(0, ((from - analog.beginTime) * rate)"),
    (TIMELINE, 'where row.type != "enable" && row.type != "disable"', ""),
    (TIMELINE, "guard row.start < to, end >= from else { continue }", "guard row.start <= to, end >= from else { continue }"),
    (TIMELINE, "guard row.start < to, end >= from else { continue }", "guard row.start < to, end > from else { continue }"),
    (TIMELINE, "if annotations.count > maxAnnotations {", "if annotations.count > maxAnnotations + 1 {"),
    (TIMELINE, "leftProblem != rightProblem ? leftProblem : left < right", "left < right"),
    (TIMELINE, "max(maxAnnotations, annotations.count { $0.problem != nil })", "maxAnnotations"),
    (TIMELINE, "spi.miso.flatMap { _ in row.fields[\"miso\"] }", "row.fields[\"miso\"]"),
    (TIMELINE, "let start = max(from ?? earliest, earliest)", "let start = from ?? earliest"),
    (TIMELINE, "let end = min(to ?? latest, latest)", "let end = to ?? latest"),
    (TIMELINE, "guard end > start else { throw TimelineError.emptyWindow }", "guard end >= start else { throw TimelineError.emptyWindow }"),
    (RENDER, 'case "&": escaped += "&amp;"', 'case "&": escaped += "&"'),
    (RENDER, 'case "<": escaped += "&lt;"', 'case "<": escaped += "<"'),
    (RENDER, "case _ where scalar.value < 0x20", "case _ where scalar.value < 0x01"),
    (RENDER, "if boxWidth >= Double(annotation.text.count) * 7.4 {", "if true {"),
    (RENDER, "let range = max(high - low, 0.001)", "let range = high - low"),
    (RENDER, 'annotation.problem == nil ? "note" : "bad"', '"note"'),
    (RENDER, 'overlay.omitted > 0 ? " +\\(overlay.omitted)" : ""', '""'),
    (RENDER, "abs(seconds) < 1e-12", "seconds == 0"),
    (RENDER, "scaled <= 1 ? 1 : scaled <= 2 ? 2 : scaled <= 5 ? 5 : 10", "scaled <= 1 ? 1 : scaled <= 5 ? 5 : 10"),
    (TIMELINE_CMD, "guard allowed.contains(name) else", "guard true else"),
    (TIMELINE_CMD, 'if Array(tokens.prefix(2)) == ["sal", "decode"] { tokens.removeFirst(2) }', ""),
    (TIMELINE_CMD, "guard from.seconds < to.seconds else", "guard from.seconds <= to.seconds else"),
    (TIMELINE_CMD, "guard let value = parseScaledSeconds(argument), value.isFinite else", "guard let value = parseScaledSeconds(argument) else"),
    (TOOLS, 'if arguments["max_segments"] == nil { line.append("--max-segments=\\(defaultToolSegmentLimit)") }', ""),
    (MAIN, "guard !devices.isEmpty else", "guard devices.isEmpty else"),
]


def caught_by_tests() -> bool:
    """True when the mutant fails to compile, crashes, or fails a test."""
    # A separate process group, because killing swift test alone orphans its test helper.
    with subprocess.Popen(
        ["swift", "test"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    ) as process:
        try:
            return process.wait(timeout=TEST_TIMEOUT_SECONDS) != 0
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            # The test helper leaves the process group, so it is found by its bundle path.
            subprocess.run(["pkill", "-9", "-f", f"swiftpm-testing-helper.*{pathlib.Path.cwd()}/"])
            return True


def compiles() -> bool:
    return subprocess.run(["swift", "build"], capture_output=True).returncode == 0


def main() -> int:
    survivors = []
    uncompilable = []
    for index, (path, old, new) in enumerate(MUTANTS, 1):
        original = path.read_text()
        if old not in original:
            print(f"{index:2} STALE     {path.name}: {old!r}")
            survivors.append((path, old, new))
            continue
        try:
            path.write_text(original.replace(old, new, 1))
            if not compiles():
                status = "NOBUILD"
                uncompilable.append((path, old, new))
            elif caught_by_tests():
                status = "caught"
            else:
                status = "SURVIVED"
                survivors.append((path, old, new))
        finally:
            path.write_text(original)
        print(f"{index:2} {status:9} {path.name}: {old.strip()[:60]!r}", flush=True)

    print(f"\n{len(MUTANTS)} mutants, {len(survivors)} survived, {len(uncompilable)} did not compile")
    return 1 if survivors or uncompilable else 0


if __name__ == "__main__":
    sys.exit(main())
