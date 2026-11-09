#!/usr/bin/env python3
"""Injects bugs into sal one at a time. The offline tests must catch every one.

Run from devices/saleae with `make mutation`. Sources are restored after each mutant.
"""

import pathlib
import subprocess
import sys

ROOT = pathlib.Path("Sources/sal")
CHANNEL = ROOT / "Analysis/DigitalChannel.swift"
SUMMARY = ROOT / "Analysis/ChannelSummary.swift"
CAPTURE = ROOT / "Logic2/DigitalCapture.swift"
COMMAND = ROOT / "Subcommands/CaptureCommand.swift"
MAIN = ROOT / "sal.swift"

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
    (COMMAND, "maximumChannel: UInt32 = 15", "maximumChannel: UInt32 = 16"),
    (COMMAND, ",\n        rate > 0\n", "\n"),
    (COMMAND, "guard duration.isFinite, duration > 0", "guard duration > 0"),
    (COMMAND, "Set(channels).count == channels.count", "true"),
    (COMMAND, "case 1...: String", "case 2...: String"),
    (MAIN, "guard !devices.isEmpty else", "guard devices.isEmpty else"),
]


def caught_by_tests() -> bool:
    """True when the mutant fails to compile, crashes, or fails a test."""
    try:
        result = subprocess.run(["swift", "test"], capture_output=True, timeout=300)
    except subprocess.TimeoutExpired:
        return True
    return result.returncode != 0


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
