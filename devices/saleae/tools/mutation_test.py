#!/usr/bin/env python3
"""Injects bugs into sal one at a time. The offline tests must catch every one.

Run from devices/saleae with `make mutation`. Mutants are made in a copy of the package,
never in the working tree. The tree can be edited, built and committed while a run is going,
and a run that is interrupted leaves nothing behind. The copy is brought up to date at the
start of each run and keeps its own build, so only the first run builds everything.

Words after the command pick mutants by file name or by the text they change:
`make mutation ARGS="Logic2App stalled"`.
"""

import os
import pathlib
import signal
import subprocess
import sys

TEST_TIMEOUT_SECONDS = 300
# Where mutants are made. Out of the repository, and out of Spotlight's sight.
COPY = pathlib.Path.home() / "Library/Caches/sal-mutation"
# Everything a build and an offline test run read.
COPIED = ["Package.swift", "Package.resolved", "Sources", "Tests"]
# A mutant must never be able to start Logic 2.
ENVIRONMENT = {**os.environ, "SAL_NO_LAUNCH": "1"}
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
LOGIC2 = ROOT / "Logic2/Logic2.swift"
APP = ROOT / "Logic2/Logic2App.swift"
APP_CMD = ROOT / "Subcommands/AppCommand.swift"

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
    (CAPTURE, "        try await cancellation.interruptible {\n            try await deadline.interruptible { try await backend.waitCapture(captureID) }\n        }\n    } catch where deadline.isCancelled && !cancellation.isCancelled {\n        throw Logic2Error.stalled", "        try await deadline.interruptible { try await backend.waitCapture(captureID) }\n    } catch where deadline.isCancelled && !cancellation.isCancelled {\n        throw Logic2Error.stalled"),
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
    (IDENTIFY, ", dataChanges > 0 { whole += 1 }", " { whole += 1 }"),
    (IDENTIFY, "<= Double(nearest) * 0.02", "<= Double(nearest) * 0.05"),
    (IDENTIFY, "dataOnTrailingEdge: leading > trailing", "dataOnTrailingEdge: leading < trailing"),
    (IDENTIFY, "clockIdlesHigh: clock.restingLevel == 1", "clockIdlesHigh: clock.restingLevel == 0"),
    (IDENTIFY, "inverted: resting == 0", "inverted: resting == 1"),
    (IDENTIFY, "guard whole <= longestActiveBits else { return nil }", ""),
    (IDENTIFY, "if candidate.level(afterEdges: index + 1) == resting {", "if false {"),
    (IDENTIFY, "for _ in 0..<12 {", "for _ in 0..<0 {"),
    (IDENTIFY, "for sda in lines where sda.summary.periodic == nil {", "for sda in lines {"),
    (IDENTIFY, "$0 >= period * 0.6 && $0 <= period * 1.4", "$0 >= period * 0.9 && $0 <= period * 1.1"),
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
    (TOOLS, 'if object["port"] == nil { object["port"] = .int(endpoint.port) }', ""),
    (TOOLS, 'if object["host"] == nil { object["host"] = .string(endpoint.host) }', 'object["host"] = .string(endpoint.host)'),
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
    (LOGIC2, "var mayLaunch: Bool { launchIfNeeded && isLocal }", "var mayLaunch: Bool { launchIfNeeded || isLocal }"),
    (LOGIC2, "} catch Logic2Error.notRunning where endpoint.mayLaunch {", "} catch Logic2Error.notRunning where true {"),
    (LOGIC2, "        try await launch(endpoint.port)\n", ""),
    (LOGIC2, 'guard environment["SAL_NO_LAUNCH"] == nil else', 'guard environment["SAL_NO_LAUNCHING"] == nil else'),
    (LOGIC2, "case .unavailable: throw Logic2Error.notRunning(host: endpoint.host, port: endpoint.port)", "case .unavailable: throw Logic2Error.notAnswering(host: endpoint.host, port: endpoint.port, seconds: seconds)"),
    (LOGIC2, "try await ask(.limited(to: seconds))", "try await ask(.defaults)"),
    (LOGIC2, "case .deadlineExceeded: Logic2Error.stalled", "case .deadlineExceeded: Logic2Error.connectionLost(host: endpoint.host, port: endpoint.port)"),
    (LOGIC2, "case .unavailable: Logic2Error.connectionLost(host: endpoint.host, port: endpoint.port)", "case .unavailable: Logic2Error.stalled"),
    (LOGIC2, "static var control: CallOptions { limited(to: 30) }", "static var control: CallOptions { .defaults }"),
    (LOGIC2, "static var data: CallOptions { limited(to: 300) }", "static var data: CallOptions { .defaults }"),
    (APP, "result = .killed", "result = .quit"),
    (APP, "for leftover in tree where isRunning(leftover) { kill(leftover, SIGKILL) }", ""),
    (APP, "guard isRunning(pid) else { return .notRunning }", ""),
    (APP, "if memoryBytes >= logic2RestartBytes {", "if memoryBytes > logic2RestartBytes {"),
    (APP, "let logic2RestartBytes: UInt64 = 3 << 30", "let logic2RestartBytes: UInt64 = 6 << 30"),
    (APP, 'minutes >= 120 ? "\\(minutes / 60) h"', 'minutes > 120 ? "\\(minutes / 60) h"'),
    (APP_CMD, "!answering || health?.needsRestart == true", "!answering && health?.needsRestart == true"),
    (CAPTURE, "throw Logic2Error.stalled", "throw CancellationError()"),
    (CAPTURE, "try await Task.sleep(for: .seconds(seconds + graceSeconds))", "try await Task.sleep(for: .seconds(seconds))"),
    (TOOLS, 'if !endpoint.launchIfNeeded { object["no_launch"] = .bool(true) }', ""),
    (MAIN, "var launch = true", "var launch = false"),
    (MAIN, "Logic2Endpoint(host: host, port: port, launchIfNeeded: launch)", "Logic2Endpoint(host: host, port: port)"),
    (IDENTIFY, "($0.edges / 2).isMultiple(of: 8)", "($0.edges / 2).isMultiple(of: 7)"),
    (IDENTIFY, "decoder.enableActiveHigh = enable.active == 1", "decoder.enableActiveHigh = enable.active == 0"),
    (IDENTIFY, "multiBitPulses >= 2, multiBitPulses * 20 >= considered,", "multiBitPulses >= 1, multiBitPulses * 20 >= considered,"),
    (IDENTIFY, "multiBitPulses >= 2, multiBitPulses * 20 >= considered,", "multiBitPulses >= 2, multiBitPulses * 50 >= considered,"),
    (IDENTIFY, "multiBitPulses >= 2, multiBitPulses * 20 >= considered,", "multiBitPulses >= 2, multiBitPulses * 20 > considered,"),
    (IDENTIFY, "var longest = (seconds: leadIn, level: summary.initialLevel)", "var longest = (seconds: 0.0, level: summary.initialLevel)"),
    (IDENTIFY, "if tailOut > longest.seconds { longest = (tailOut, level(afterEdges: times.count)) }", ""),
    (IDENTIFY, "longest = (tailOut, level(afterEdges: times.count))", "longest = (tailOut, summary.initialLevel)"),
    (IDENTIFY, "if clock.leadIn <= half * 4 { bursts[0].isCut = true }", ""),
    (IDENTIFY, "if clock.tailOut <= half * 4 { bursts[bursts.count - 1].isCut = true }", ""),
    (IDENTIFY, "return whole > 0 && Double(whole) >= Double(complete.count) * requiredBurstFraction", "return Double(whole) >= Double(complete.count) * requiredBurstFraction"),
    (IDENTIFY, "clocks: candidates(includingPeriodic: true), data: candidates(),", "clocks: candidates(), data: candidates(),"),
    (IDENTIFY, "if inside == 0 { held[line.level(afterEdges: before)] += 1 }", "held[line.level(afterEdges: before)] += 1"),
    (IDENTIFY, "guard Double(held[active]) >= Double(bursts.count) * requiredBurstFraction else { return nil }", ""),
    (IDENTIFY, "if moves == 0 || moves == 2 { orderly += 1 }", "orderly += 1"),
    (IDENTIFY, "guard reasserted > 0 || (before == 1 && after == 1) else { return nil }", ""),
    (IDENTIFY, "guard reasserted > 0 || (before == 1 && after == 1) else { return nil }", "guard reasserted > 0 else { return nil }"),
    (IDENTIFY, ".min { ($0.slack, $0.line.channel) < ($1.slack, $1.line.channel) }", ".min { ($1.slack, $0.line.channel) < ($0.slack, $1.line.channel) }"),
    (IDENTIFY, "guard spent[1 - active] > slack else { return nil }", ""),
    (IDENTIFY, "let slack = spent[active] - clocked", "let slack = spent[active]"),
    (IDENTIFY, "spent[line.summary.initialLevel] += line.leadIn", ""),
    (IDENTIFY, "private let requiredRegularFraction = 0.8", "private let requiredRegularFraction = 0.9"),
    (IDENTIFY, "let setsUp = !followsClock && clockEdges <= burst.last && clock.times[clockEdges] - time <= period", "let setsUp = !followsClock && clockEdges <= burst.first && clock.times[clockEdges] - time <= period"),
    (IDENTIFY, "if placed { setUp.append((clockEdges - burst.first) / 2) }", "if placed { setUp.append(1) }"),
    (IDENTIFY, "private let clockTieFraction = 0.025", "private let clockTieFraction = 0.0"),
    (IDENTIFY, "private let clockTieFraction = 0.025", "private let clockTieFraction = 0.25"),
    (IDENTIFY, "guard Double(max(fit.leading, fit.trailing)) >= Double(phased) * requiredEdgeFraction else { return nil }", ""),
    (IDENTIFY, "let midByte = edges.filter { !$0.bit.isMultiple(of: 8) }", "let midByte = edges"),
    (IDENTIFY, "guard clockEdge != lastClockEdge else { continue }", ""),
    (IDENTIFY, "if placed { afterTrailing.append((pulse + 1, delay)) }", "if placed { afterTrailing.append((pulse, delay)) }"),
    (IDENTIFY, "let placed = !burst.isCut || burstIndex > 0", "let placed = true"),
    (IDENTIFY, "guard let fit = dataFit(line, clock: clock, timing: timing, enable: enable) else { continue }", "guard let fit = dataFit(line, clock: clock, timing: timing) else { continue }"),
    (IDENTIFY, "guard delays[last * 9 / 10] - delays[last / 10] <= period * steadyDelayFraction else { return nil }", ""),
    (IDENTIFY, "abs(bit - timing.period) <= timing.period * 0.3,", ""),
    (IDENTIFY, "if let keeper = clockKeeping(candidate, among: active, regular: regular) {", "if let keeper = clockKeeping(candidate, among: [], regular: regular) {"),
    (IDENTIFY, "scl.times[clockEdges] < time || (scl.times[clockEdges] == time && scl.level(afterEdges: clockEdges + 1) == 0)", "scl.times[clockEdges] < time"),
    (IDENTIFY, "scl.times[clockEdges] < time || (scl.times[clockEdges] == time && scl.level(afterEdges: clockEdges + 1) == 0)", "scl.times[clockEdges] <= time"),
    (IDENTIFY, "let bitSeconds = fittedBitTime(pulses, roughly: seconds / bits)", "let bitSeconds = seconds / bits"),
    (IDENTIFY, "let stride = max(1, pulses.count / 100)", "let stride = max(1, pulses.count / 10)"),
    (IDENTIFY, "for second in sample[(index + 1)...] where second.bits != first.bits {", "for second in sample[(index + 1)...] where second.bits > first.bits {"),
    (IDENTIFY, "abs(slope - ratio) <= ratio * 0.25 ? slope : ratio", "abs(slope - ratio) <= ratio * 0.2 ? slope : ratio"),
    (IDENTIFY, "abs(slope - ratio) <= ratio * 0.25 ? slope : ratio", "abs(slope - ratio) <= ratio * 0.3 ? slope : ratio"),
    (IDENTIFY, 'match.bursts == 1 ? "burst" : "bursts"', 'match.bursts == 0 ? "burst" : "bursts"'),
    (IDENTIFY, "bursts: timing.complete.count, notes: notes)", "bursts: timing.bursts.count, notes: notes)"),
    (IDENTIFY, "for channel in control {", "for channel in [UInt32]() {"),
    (CAPTURE, "if Double(best.errors) <= Double(best.frames) * tolerableFrameErrors {", "if best.frames > 0 {"),
    (CAPTURE, "if Double(best.errors) <= Double(best.frames) * tolerableFrameErrors {", "if false {"),
    (CAPTURE, "guard frames.count >= minimumConfirmingRows else {", "guard frames.count >= 1 else {"),
    (CAPTURE, "let minimumConfirmingRows = 4", "let minimumConfirmingRows = 5"),
    (CAPTURE, "let minimumConfirmingRows = 4", "let minimumConfirmingRows = 3"),
    (CAPTURE, "guard !frames.isEmpty else { continue }", ""),
    (CAPTURE, "if decoded == 0 {", "if decoded >= 0 {"),
    (CAPTURE, "        if errors > 0 {\n", "        if errors > 99 {\n"),
    (CAPTURE, "} else if words < minimumConfirmingRows {", "} else if words < 1 {"),
    (CAPTURE, 'bus.evidence += ", \\(frames.count) frames decoded cleanly"', ""),
    (TABLE, 'if row.type == "error" { return "error" }', ""),
]


def copy_package() -> None:
    """Brings the copy up to date with the working tree. Its build directory is left alone."""
    COPY.mkdir(parents=True, exist_ok=True)
    subprocess.run(["rsync", "-a", "--delete", *COPIED, f"{COPY}/"], check=True)


def tests_fail() -> bool:
    """True when the tests in the copy crash, hang or fail."""
    # A separate process group, because killing swift test alone orphans its test helper.
    with subprocess.Popen(
        ["swift", "test"],
        cwd=COPY,
        env=ENVIRONMENT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    ) as process:
        try:
            return process.wait(timeout=TEST_TIMEOUT_SECONDS) != 0
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            # The test helper leaves the process group, so it is found by its bundle path.
            subprocess.run(["pkill", "-9", "-f", f"swiftpm-testing-helper.*{COPY}/"])
            return True


def compiles() -> bool:
    return subprocess.run(["swift", "build"], cwd=COPY, env=ENVIRONMENT, capture_output=True).returncode == 0


def chosen(words: list[str]) -> list[tuple[pathlib.Path, str, str]]:
    """Every mutant, or with words, those whose file name or changed text contains one."""
    if not words:
        return MUTANTS
    return [mutant for mutant in MUTANTS if any(word in mutant[0].name or word in mutant[1] for word in words)]


def main() -> int:
    if not ROOT.is_dir():
        sys.exit("Run from devices/saleae.")
    mutants = chosen(sys.argv[1:])
    if not mutants:
        sys.exit("No mutant matches.")

    copy_package()
    # If the copy fails on its own, every mutant would look caught.
    if not compiles() or tests_fail():
        sys.exit(f"The tests do not pass unmutated in {COPY}. Fix that first.")

    survivors = []
    uncompilable = []
    for index, (path, old, new) in enumerate(mutants, 1):
        target = COPY / path
        original = target.read_text()
        if old not in original:
            print(f"{index:2} STALE     {path.name}: {old!r}")
            survivors.append((path, old, new))
            continue
        try:
            target.write_text(original.replace(old, new, 1))
            if not compiles():
                status = "NOBUILD"
                uncompilable.append((path, old, new))
            elif tests_fail():
                status = "caught"
            else:
                status = "SURVIVED"
                survivors.append((path, old, new))
        finally:
            target.write_text(original)
        print(f"{index:2} {status:9} {path.name}: {old.strip()[:60]!r}", flush=True)

    print(f"\n{len(mutants)} mutants, {len(survivors)} survived, {len(uncompilable)} did not compile")
    return 1 if survivors or uncompilable else 0


if __name__ == "__main__":
    sys.exit(main())
