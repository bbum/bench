#!/usr/bin/env python3
"""Puts random signals on all 8 testgen pins and scores what `sal identify` works out.

The scenario is generated here and the answer stays here. The board is only told what to
play, and sal only sees the wires. In three scenarios out of four the signals overlap in
time, as buses on a real board do.

Run from devices/saleae: python3 -I tools/blind_test.py --runs 40

Every scenario's capture is kept in .blind/seed-N with its answer key beside it. --replay
re-scores them with no board attached, which is repeatable, so it is the quick way to check
a change to the analysis. The key is a file, not worked out again from the seed, so old
captures stay scoreable when the scenarios made here change.

Logic 2 can run out of memory over a long run and stop answering. It is restarted every
few scenarios if it has grown too large, and once more if a scenario finds it hung.
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

# The scenario line this writes is understood by this testgen firmware.
FIRMWARE = 5
STANDARD_BAUDS = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400]
KINDS = ["uart", "spi", "i2c", "pwm", "pulse", "noise", "burst", "idle"]
WEIGHTS = [5, 3, 3, 2, 2, 2, 2, 1]

# The waveform interrupt cannot be masked and delays the odd edge by up to 8 us, which at
# 115200 baud is most of a bit and spoils frames.
FAST_BAUD_LIMIT_WITH_PWM = 57600
# CH1 is GPIO16, which the ESP8266's waveform generator cannot drive.
CHANNEL_WITHOUT_PWM = 1
# The firmware schedules at most 1800 edges a cycle.
EDGE_BUDGET = 1700
# Clock bursts with no data. 8, 16 and 24 are whole bytes, which is what an SPI clock sends.
DECOY_PULSES = [5, 7, 8, 9, 12, 13, 16, 20, 24]


def choose_signal(kind, channels, rng, pwm_present, shape):
    """Returns (answer, seconds it lasts, edges it makes, function from start offset to field)."""
    take = lambda: channels.pop()
    data = bytes(rng.randrange(256) for _ in range(rng.randint(6, 16)))

    if kind == "uart":
        channel = take()
        if rng.random() < 0.5:
            baud = rng.choice(STANDARD_BAUDS)
        else:
            baud = int(2400 * 2 ** rng.uniform(0, 6.5))
        if pwm_present:
            baud = min(baud, FAST_BAUD_LIMIT_WITH_PWM)
        parity, stop = rng.choice("NEO"), rng.choice([2, 4])
        inverted = rng.random() < 0.25
        seconds = len(data) * ((9 + (parity != "N") + stop / 2) / baud + 30e-6)
        answer = dict(kind="uart", channel=channel, baud=baud, parity=parity, inverted=inverted, stop=stop / 2)
        field = lambda at: f"u,{channel},{at},{baud},{parity},{stop},{int(inverted)},{data.hex()}"
        return answer, seconds, len(data) * 11, field

    if kind == "spi":
        clock, mosi = take(), take()
        miso = take() if shape["miso"] else None
        enable = take() if shape["enable"] else None
        cpol, cpha, active_high = rng.random() < 0.5, rng.random() < 0.5, rng.random() < 0.2
        half = rng.choice([1, 2, 5, 10, 50])
        # The waveform interrupt stretches the odd half period to 8 us, which at 1 us is a
        # burst split mid-byte. Real clocks do not do that, so keep clear of it.
        if pwm_present:
            half = max(half, 5)
        # How long before the clock the enable is asserted, and how long bytes are paused apart.
        # A pause of up to 3 half periods leaves one burst. A longer one makes a burst per byte.
        setup = rng.choice([half, half, 10 * half, 200])
        pause = rng.choice([0, 0, half, 2 * half, 6 * half, 40 * half])
        # A MISO that is only driven while enabled, and pulled high otherwise.
        released = miso is not None and enable is not None and rng.random() < 0.5
        reply = bytes(rng.randrange(256) for _ in data)
        seconds = (setup + len(data) * 16 * half + (len(data) - 1) * pause + half) * 1e-6
        edges = len(data) * 8 * (3 + (miso is not None)) + 4
        pin = lambda channel: -1 if channel is None else channel
        answer = dict(
            kind="spi", clock=clock, mosi=mosi, miso=miso, enable=enable, cpol=cpol, cpha=cpha,
            active_high=active_high, half_us=half, setup_us=setup, pause_us=pause, released=released)
        field = lambda at: (
            f"s,{clock},{mosi},{pin(miso)},{pin(enable)},{at},{int(cpol)},{int(cpha)},{half},{int(active_high)},"
            f"{setup},{pause},{int(released)},{data.hex()},{reply.hex()}")
        return answer, seconds, edges, field

    if kind == "i2c":
        sda, scl = take(), take()
        half = rng.choice([2, 5, 20])
        address = rng.randrange(8, 0x78)
        seconds = ((len(data) + 1) * 18 + 3) * half * 1e-6
        answer = dict(kind="i2c", sda=sda, scl=scl, half_us=half, address=address)
        return answer, seconds, (len(data) + 1) * 27 + 5, lambda at: f"i,{sda},{scl},{at},{half},{address:02x},{data.hex()}"

    if kind == "pwm":
        options = [c for c in channels if c != CHANNEL_WITHOUT_PWM]
        channel = options[-1]
        channels.remove(channel)
        hz, duty = int(100 * 2 ** rng.uniform(0, 5.6)), rng.choice([10, 25, 33, 50, 75])
        return dict(kind="pwm", channel=channel, hz=hz, duty=duty), 0, 0, lambda at: f"w,{channel},{hz},{duty}"

    if kind == "pulse":
        channel = take()
        width, idle_high = rng.choice([5, 20, 100, 500]), rng.random() < 0.3
        answer = dict(kind="pulse", channel=channel, width_us=width)
        return answer, width * 1e-6, 2, lambda at: f"p,{channel},{at},{width},{int(idle_high)}"

    if kind == "noise":
        channel = take()
        count, maximum = rng.randint(8, 80), rng.choice([20, 100, 500])
        answer = dict(kind="noise", channel=channel, count=count, max_us=maximum)
        return answer, count * maximum * 1e-6, count + 1, lambda at: f"n,{channel},{at},{count},{maximum},0"

    if kind == "burst":
        channel = take()
        pulses = rng.choice(DECOY_PULSES)
        half = rng.choice([2, 10, 50])
        answer = dict(kind="burst", channel=channel, pulses=pulses, half_us=half)
        return answer, pulses * 2 * half * 1e-6, pulses * 2, lambda at: f"b,{channel},{at},{pulses},{half}"

    channel = take()
    level = rng.random() < 0.5
    return dict(kind="idle", channel=channel, level=int(level)), 0, 0, lambda at: f"d,{channel},{int(level)}"


def make_scenario(rng):
    """Returns (scenario line, answers, seconds one cycle lasts)."""
    while True:
        channels = list(range(8))
        rng.shuffle(channels)
        chosen = []
        pins = 8
        while pins > 0:
            kind = rng.choices(KINDS, WEIGHTS)[0]
            shape = dict(miso=rng.random() < 0.4, enable=rng.random() < 0.75) if kind == "spi" else {}
            needed = {"spi": 2 + sum(shape.values()), "i2c": 2}.get(kind, 1)
            if needed <= pins:
                chosen.append((kind, shape))
                pins -= needed
        pwm = any(kind == "pwm" for kind, _ in chosen)
        # Multi-pin signals go first, so a single PWM cannot be left with only CH1.
        chosen.sort(key=lambda item: (item[0] != "spi", item[0] != "i2c", item[0] != "pwm"))

        signals = []
        for kind, shape in chosen:
            if kind == "pwm" and channels == [CHANNEL_WITHOUT_PWM]:
                kind = "pulse"
            signals.append(choose_signal(kind, channels, rng, pwm, shape))
        if sum(edges for _, _, edges, _ in signals) <= EDGE_BUDGET:
            break

    # Overlapping signals start anywhere within the longest. The rest play one after another.
    overlapping = rng.random() < 0.75
    longest = max(seconds for _, seconds, _, _ in signals)
    gap = rng.randint(10, 25)
    fields, answers = [], []
    cursor = 0.0
    busy = 0.0
    for answer, seconds, _, field in signals:
        start = rng.uniform(0, longest) if overlapping else cursor
        cursor += seconds + 100e-6
        busy = max(busy, start + seconds)
        fields.append(field(int(start * 1e6)))
        answers.append(answer)
    return f"{gap}|" + "|".join(fields), answers, busy + gap / 1000


# How sal words trouble with Logic 2 itself, as opposed to with a capture.
LOGIC2_TROUBLE = ("Restart it with", "quit or crashed", "is not running", "did not finish")
RUNS_BETWEEN_CHECKUPS = 10


def run_sal(sal, arguments):
    """Runs sal. If Logic 2 has hung or died, restarts it and tries once more."""
    for attempt in (1, 2):
        try:
            done = subprocess.run([sal, *arguments], capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            done = subprocess.CompletedProcess(arguments, 1, "", "sal did not finish in 120 seconds.")
        trouble = done.returncode != 0 and any(text in done.stderr for text in LOGIC2_TROUBLE)
        if not trouble or attempt == 2:
            return done
        print(f"Logic 2 is in trouble ({done.stderr.strip()}). Restarting it.", flush=True)
        subprocess.run([sal, "app", "restart"], capture_output=True, text=True, timeout=180)


def checkup(sal, run):
    """Restarts Logic 2 between scenarios if it has grown too large or gone quiet."""
    if run % RUNS_BETWEEN_CHECKUPS == 0:
        done = subprocess.run([sal, "app", "restart", "--if-needed"], capture_output=True, text=True, timeout=180)
        if "healthy" not in done.stdout:
            print(f"Logic 2 checkup: {(done.stdout + done.stderr).strip()}", flush=True)


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
            sys.exit("testgen did not answer.")

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
        # A cycle in progress has interrupts off, and the line is longer than the UART's own
        # buffer, so it is only sent once the board says it is listening.
        if b"ready" not in self.command(b"x", b"ready", 5):
            sys.exit(f"testgen did not get ready for a scenario. Is firmware v{FIRMWARE} flashed?")
        reply = self.command(line.encode() + b"\n", b"scenario", 5)
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
        # Timing cannot tell MOSI from MISO, so the pair counts either way round.
        found_data = {roles.get("mosi"), roles.get("miso")} - {None}
        if found_data != {answer["mosi"], answer.get("miso")} - {None}:
            problems.append(f"data {sorted(found_data)}")
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


def replay(directory, sal):
    """Scores every capture in a directory. Needs Logic 2, but not the board."""
    totals = defaultdict(Counter)
    captures = sorted(directory.glob("run-*.sal"), key=lambda p: [int(n) for n in re.findall(r"\d+", p.name)])
    if not captures:
        sys.exit(f"No captures in {directory}.")
    perfect = 0
    misses = []
    for position, capture in enumerate(captures):
        key = capture.with_suffix(".json")
        if not key.exists():
            sys.exit(f"{capture.name} has no answer key beside it.")
        answers = json.loads(key.read_text())["answers"]
        checkup(sal, position)
        done = run_sal(sal, ["identify", "--load", str(capture), "--json"])
        if done.returncode != 0:
            sys.exit(f"sal failed on {capture.name}: {done.stderr}")
        result = json.loads(done.stdout)
        graded = [(answer, *score(answer, result)) for answer in answers]
        for answer, grade, _ in graded:
            totals[answer["kind"]][grade] += 1
        wrong = [(answer, grade, detail) for answer, grade, detail in graded if grade != "right"]
        perfect += not wrong
        misses += [(capture.name, grade, answer, detail) for answer, grade, detail in wrong]
        print(f"{capture.name}: {len(graded) - len(wrong)}/{len(graded)} signals", flush=True)

    print(f"\n{perfect}/{len(captures)} scenarios fully right\n")
    print(f"{'signal':8}{'right':>7}{'partial':>9}{'missed':>8}")
    for kind in KINDS:
        counts = totals[kind]
        if counts:
            print(f"{kind:8}{counts['right']:>7}{counts['partial']:>9}{counts['missed']:>8}")
    if misses:
        print("\nNot fully right:")
        for name, grade, answer, detail in misses:
            fields = {k: v for k, v in answer.items() if k != "kind"}
            print(f"  {name} {grade} {answer['kind']} {fields}: {detail}")
    return 0


def record(args, out):
    """Plays each scenario and saves a capture of all 8 channels, with its answer key."""
    board = Board()
    try:
        for run in range(args.runs):
            line, answers, cycle = make_scenario(random.Random(args.seed * 1_000_003 + run))
            board.play(line)
            time.sleep(0.15)
            seconds = min(3.0, max(0.25, 4 * cycle))
            capture = out / f"run-{args.seed}-{run}.sal"
            checkup(args.sal, run)
            done = run_sal(args.sal, ["capture", "--duration", f"{seconds:.3f}", "--save", str(capture)])
            if done.returncode != 0:
                sys.exit(f"sal failed on run {run}: {done.stderr}")
            key = dict(firmware=FIRMWARE, scenario=line, cycleSeconds=cycle, answers=answers)
            capture.with_suffix(".json").write_text(json.dumps(key, indent=1) + "\n")
            print(f"recorded run {run}", flush=True)
    finally:
        board.clean()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--sal", default=".build/debug/sal")
    parser.add_argument("--out", default=".blind", help="Where captures live, in one folder per seed.")
    parser.add_argument("--record-only", action="store_true", help="Save captures without scoring them.")
    parser.add_argument("--replay", action="store_true", help="Re-score this seed's saved captures, without the board.")
    args = parser.parse_args()

    out = pathlib.Path(args.out).resolve() / f"seed-{args.seed}"
    if not args.replay:
        out.mkdir(parents=True, exist_ok=True)
        record(args, out)
    return 0 if args.record_only else replay(out, args.sal)


if __name__ == "__main__":
    sys.exit(main())
