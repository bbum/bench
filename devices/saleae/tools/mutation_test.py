#!/usr/bin/env python3
"""Injects bugs into sal one at a time. The offline tests must catch every one.

Run from devices/saleae with `make mutation`. Sources are restored after each mutant.
"""

import os
import pathlib
import signal
import subprocess
import sys

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
    (CAPTURE, "export.analogDownsampleRatio = 1", "export.analogDownsampleRatio = 2"),
    (CAPTURE, "device.digitalThresholdVolts = request.levelVolts", "device.digitalThresholdVolts = 1.8"),
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
    (CANCEL, "            signal(number, previous)\n            work.cancel()", "            work.cancel()"),
    (CANCEL, "            signal(number, previous)\n            work.cancel()", "            signal(number, previous)"),
    (COMMAND, "interruptedExitCode: Int32 = 130", "interruptedExitCode: Int32 = 1"),
    (COMMAND, "maximumChannel: UInt32 = 15", "maximumChannel: UInt32 = 16"),
    (COMMAND, ",\n        rate > 0\n", "\n"),
    (COMMAND, "guard duration.isFinite, duration > 0", "guard duration > 0"),
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
    (CAPTURE, "analyzer.radixType = request.radix.type", "analyzer.radixType = .hexadecimal"),
    (DECODE, "guard baud > 0", "guard baud >= 0"),
    (DECODE, "guard limit > 0", "guard limit >= 0"),
    (DECODE, "guard offset >= 0", "guard offset > 0"),
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
            return process.wait(timeout=300) != 0
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
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
