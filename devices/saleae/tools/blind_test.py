#!/usr/bin/env python3
"""Puts random signals on all 8 testgen pins and scores what `sal identify` works out.

The scenario is generated here and the answer stays here. The board is only told what to
play, and sal only sees the wires. Runs are repeatable from --seed, and any scenario sal
does not get fully right keeps its .sal capture for debugging.

Run from devices/saleae: python3 -I tools/blind_test.py --runs 40
"""

import argparse
import json
import os
import pathlib
import random
import re
import select
import subprocess
import sys
import termios
import time
from collections import Counter, defaultdict

STANDARD_BAUDS = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400]
KINDS = ["uart", "spi", "i2c", "pwm", "pulse", "noise", "burst", "idle"]
WEIGHTS = [5, 3, 3, 2, 2, 2, 2, 1]
PINS_NEEDED = {"spi": 3, "i2c": 2}

# Timer interrupts from PWM cannot be masked and disturb fast bit-banging.
FAST_BAUD_LIMIT_WITH_PWM = 115200
# CH1 is GPIO16, which the ESP8266's waveform generator cannot drive.
CHANNEL_WITHOUT_PWM = 1


def choose_signal(kind, channels, rng, pwm_allowed):
    """Returns (firmware field text, answer) using channels taken from the list."""
    take = lambda: channels.pop()
    data = bytes(rng.randrange(256) for _ in range(rng.randint(6, 16)))

    if kind == "uart":
        channel = take()
        if rng.random() < 0.5:
            baud = rng.choice(STANDARD_BAUDS)
        else:
            baud = int(2400 * 2 ** rng.uniform(0, 6.5))
        if pwm_allowed:
            baud = min(baud, FAST_BAUD_LIMIT_WITH_PWM)
        parity, stop = rng.choice("NEO"), rng.choice([2, 4])
        inverted = rng.random() < 0.25
        field = f"u,{channel},{baud},{parity},{stop},{int(inverted)},{data.hex()}"
        return field, dict(kind="uart", channel=channel, baud=baud, parity=parity, inverted=inverted, stop=stop / 2)

    if kind == "spi":
        clock, mosi = take(), take()
        enable = take() if rng.random() < 0.75 else None
        cpol, cpha, active_high = rng.random() < 0.5, rng.random() < 0.5, rng.random() < 0.2
        half = rng.choice([1, 2, 5, 10, 50])
        cs_text = -1 if enable is None else enable
        field = f"s,{clock},{mosi},{cs_text},{int(cpol)},{int(cpha)},{half},{int(active_high)},{data.hex()}"
        return field, dict(kind="spi", clock=clock, mosi=mosi, enable=enable, cpol=cpol, cpha=cpha, active_high=active_high, half_us=half)

    if kind == "i2c":
        sda, scl = take(), take()
        half = rng.choice([2, 5, 20])
        address = rng.randrange(8, 0x78)
        field = f"i,{sda},{scl},{half},{address:02x},{data.hex()}"
        return field, dict(kind="i2c", sda=sda, scl=scl, half_us=half, address=address)

    if kind == "pwm":
        options = [c for c in channels if c != CHANNEL_WITHOUT_PWM]
        channel = options[-1]
        channels.remove(channel)
        hz, duty = int(100 * 2 ** rng.uniform(0, 5.6)), rng.choice([10, 25, 33, 50, 75])
        return f"w,{channel},{hz},{duty}", dict(kind="pwm", channel=channel, hz=hz, duty=duty)

    if kind == "pulse":
        channel = take()
        width, idle_high = rng.choice([5, 20, 100, 500]), rng.random() < 0.3
        return f"p,{channel},{width},{int(idle_high)}", dict(kind="pulse", channel=channel, width_us=width)

    if kind == "noise":
        channel = take()
        count, maximum = rng.randint(8, 80), rng.choice([20, 100, 500])
        return f"n,{channel},{count},{maximum},0", dict(kind="noise", channel=channel, count=count, max_us=maximum)

    if kind == "burst":
        channel = take()
        pulses = rng.choice([5, 7, 9, 12, 13, 20])
        half = rng.choice([2, 10, 50])
        return f"b,{channel},{pulses},{half}", dict(kind="burst", channel=channel, pulses=pulses, half_us=half)

    channel = take()
    level = rng.random() < 0.5
    return f"d,{channel},{int(level)}", dict(kind="idle", channel=channel, level=int(level))


def make_scenario(rng):
    channels = list(range(8))
    rng.shuffle(channels)
    kinds = []
    pins = 8
    while pins > 0:
        kind = rng.choices(KINDS, WEIGHTS)[0]
        needed = PINS_NEEDED.get(kind, 1)
        if needed <= pins:
            kinds.append(kind)
            pins -= needed
    pwm = "pwm" in kinds
    # Multi-pin signals go first, so a single PWM cannot be left with only CH1.
    kinds.sort(key=lambda k: (k != "spi", k != "i2c", k != "pwm"))

    fields, answers = [], []
    for kind in kinds:
        if kind == "pwm" and channels == [CHANNEL_WITHOUT_PWM]:
            kind = "pulse"
        field, answer = choose_signal(kind, channels, rng, pwm)
        fields.append(field)
        answers.append(answer)
    gap = rng.randint(10, 25)
    return f"{gap}|" + "|".join(fields), answers, gap


def cycle_seconds(answers, gap):
    total = gap / 1000
    for answer in answers:
        kind = answer["kind"]
        if kind == "uart":
            total += 16 * 12 / answer["baud"]
        elif kind == "spi":
            total += 16 * 16 * answer["half_us"] * 2e-6 * 1.3
        elif kind == "i2c":
            total += 17 * 9 * answer["half_us"] * 2e-6 * 1.3
        elif kind == "noise":
            total += answer["count"] * answer["max_us"] / 2 * 1e-6
    return total


class Board:
    def __init__(self):
        names = sorted(n for n in os.listdir("/dev") if n.startswith("cu.usbserial"))
        if not names:
            sys.exit("No testgen USB serial port found.")
        self.fd = os.open(f"/dev/{names[0]}", os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        attrs = termios.tcgetattr(self.fd)
        attrs[0] = attrs[1] = attrs[3] = 0
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[4] = attrs[5] = termios.B115200
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
        self.wait(b"running", 3)
        if b"mode c" not in self.command(b"c", b"mode c", 2):
            sys.exit("testgen did not answer. Is firmware v4 flashed?")

    def wait(self, token, seconds):
        received = b""
        deadline = time.time() + seconds
        while time.time() < deadline and token not in received:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                received += os.read(self.fd, 4096)
        return received

    def command(self, text, token, seconds):
        os.write(self.fd, text)
        return self.wait(token, seconds)

    def play(self, line):
        reply = self.command(b"x" + line.encode() + b"\n", b"scenario", 3)
        reply += self.wait(b"\n", 0.5)
        if b"scenario bad" in reply or b"scenario" not in reply:
            sys.exit(f"testgen refused a scenario: {line}: {reply!r}")

    def clean(self):
        self.command(b"c", b"mode c", 2)
        os.close(self.fd)


def score(answer, result):
    """Returns (grade, detail). Grades are right, partial or missed."""
    buses = result["buses"]
    kind = answer["kind"]

    def bus(wanted_kind, role, channel):
        for candidate in buses:
            if candidate["kind"] == wanted_kind and candidate["channels"].get(role) == channel:
                return candidate
        return None

    def claimed(channel):
        for candidate in buses:
            if channel in candidate["channels"].values():
                return candidate
        return None

    if kind == "uart":
        found = bus("uart", "signal", answer["channel"])
        if not found:
            return "missed", describe_channel(answer["channel"], result)
        command = found["command"]
        baud = int(re.search(r"--baud (\d+)", command)[1])
        parity = re.search(r"--parity (\w+)", command)
        problems = []
        if abs(baud - answer["baud"]) > answer["baud"] * 0.031:
            problems.append(f"baud {baud}")
        if (parity[1][0].upper() if parity else "N") != answer["parity"]:
            problems.append(f"parity {parity[1] if parity else 'none'}")
        if ("--inverted" in command) != answer["inverted"]:
            problems.append("polarity")
        if found["confidence"] != "confirmed":
            problems.append(found["confidence"])
        return ("partial", ", ".join(problems)) if problems else ("right", "")

    if kind == "spi":
        found = bus("spi", "clock", answer["clock"])
        if not found:
            return "missed", describe_channel(answer["clock"], result)
        command, roles = found["command"], found["channels"]
        problems = []
        if answer["mosi"] not in (roles.get("mosi"), roles.get("miso")):
            problems.append(f"data {roles.get('mosi')}")
        if roles.get("enable") != answer["enable"]:
            problems.append(f"enable {roles.get('enable')}")
        if ("--cpol 1" in command) != answer["cpol"]:
            problems.append("cpol")
        if ("--cpha 1" in command) != answer["cpha"]:
            problems.append("cpha")
        if answer["enable"] is not None and ("--enable-active-high" in command) != answer["active_high"]:
            problems.append("enable polarity")
        return ("partial", ", ".join(problems)) if problems else ("right", "")

    if kind == "i2c":
        found = bus("i2c", "scl", answer["scl"])
        if not found:
            return "missed", describe_channel(answer["scl"], result)
        if found["channels"].get("sda") != answer["sda"]:
            return "partial", f"sda {found['channels'].get('sda')}"
        return "right", ""

    channel = answer["channel"]
    other = claimed(channel)
    if kind == "pwm":
        if other:
            return "missed", f"called {other['kind']}"
        found = next((p for p in result["periodic"] if p["channel"] == channel), None)
        if not found:
            return "missed", describe_channel(channel, result)
        problems = []
        if abs(found["frequencyHz"] - answer["hz"]) > answer["hz"] * 0.03:
            problems.append(f"{found['frequencyHz']:.1f} Hz")
        if abs(found["dutyPercent"] - answer["duty"]) > 4:
            problems.append(f"{found['dutyPercent']:.1f}% duty")
        return ("partial", ", ".join(problems)) if problems else ("right", "")

    if kind == "idle":
        if other:
            return "missed", f"called {other['kind']}"
        found = next((i for i in result["idle"] if i["channel"] == channel), None)
        if found and found["level"] == answer["level"]:
            return "right", ""
        return "missed", describe_channel(channel, result)

    # Pulses, noise and bare clock bursts should not be mistaken for a bus.
    if other:
        return "missed", f"called {other['kind']}: {other['command']}"
    return "right", ""


def describe_channel(channel, result):
    for candidate in result["buses"]:
        if channel in candidate["channels"].values():
            return f"seen as {candidate['kind']}: {candidate['command']}"
    if any(p["channel"] == channel for p in result["periodic"]):
        return "seen as periodic"
    if any(i["channel"] == channel for i in result["idle"]):
        return "seen as idle"
    if channel in result["unknown"]:
        return "seen as unidentified"
    return "not reported"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--sal", default=".build/debug/sal")
    parser.add_argument("--out", default="/tmp/sal-blind")
    args = parser.parse_args()

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    board = Board()
    totals = defaultdict(Counter)
    misses = []
    perfect = 0

    try:
        for run in range(args.runs):
            rng = random.Random(args.seed * 1_000_003 + run)
            line, answers, gap = make_scenario(rng)
            board.play(line)
            time.sleep(0.15)
            seconds = min(3.0, max(0.25, 4 * cycle_seconds(answers, gap)))
            capture = out / f"run-{args.seed}-{run}.sal"
            done = subprocess.run(
                [args.sal, "identify", "--duration", f"{seconds:.3f}", "--save", str(capture), "--json"],
                capture_output=True, text=True, timeout=120)
            if done.returncode != 0:
                sys.exit(f"sal failed on run {run}: {done.stderr}")
            result = json.loads(done.stdout)

            graded = [(answer, *score(answer, result)) for answer in answers]
            for answer, grade, _ in graded:
                totals[answer["kind"]][grade] += 1
            if all(grade == "right" for _, grade, _ in graded):
                perfect += 1
                capture.unlink(missing_ok=True)
            else:
                for answer, grade, detail in graded:
                    if grade != "right":
                        misses.append((run, grade, answer, detail, capture))
            print(f"run {run:3}: {sum(g == 'right' for _, g, _ in graded)}/{len(graded)} signals", flush=True)
    finally:
        board.clean()

    print(f"\n{perfect}/{args.runs} scenarios fully right (seed {args.seed})\n")
    print(f"{'signal':8}{'right':>7}{'partial':>9}{'missed':>8}")
    for kind in KINDS:
        counts = totals[kind]
        if counts:
            print(f"{kind:8}{counts['right']:>7}{counts['partial']:>9}{counts['missed']:>8}")
    if misses:
        print("\nNot fully right:")
        for run, grade, answer, detail, capture in misses:
            fields = {k: v for k, v in answer.items() if k != "kind"}
            print(f"  run {run} {grade} {answer['kind']} {fields}: {detail}  [{capture.name}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
