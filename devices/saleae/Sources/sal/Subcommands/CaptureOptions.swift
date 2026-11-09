import ArgumentParser
import Foundation

/// How to run a capture. Shared by every command that captures.
struct CaptureOptions: ParsableArguments {
    @OptionGroup var logic2: Logic2Options

    @Option(help: "Digital sample rate, such as 50M or 500000. Defaults to 50M, or 6.25M alongside analog.")
    var rate: String?

    @Option(help: "Seconds to capture, 0.5 by default. With --trigger, seconds after it. With --manual, a limit.")
    var duration: Double?

    @Option(help: "Logic level in volts: 1.2, 1.8 or 3.3.")
    var level = 3.3

    @Option(help: "Device serial number. Defaults to the first physical device.")
    var device: String?

    @Flag(help: "Capture until Ctrl-C or --duration, then use what was captured.")
    var manual = false

    @Option(help: "Keep only the last part of the capture, such as 200ms. Not with --trigger.")
    var trim: Seconds?

    @Option(help: "Logic 2 memory limit in megabytes. Reaching it ends the capture with an error.")
    var bufferMb: UInt32?

    @Option(help: "Ignore pulses narrower than a width, as CH:WIDTH such as 2:5us. Repeatable.")
    var glitch: [GlitchFilter] = []

    @Option(help: "Start on CH:rising, CH:falling, CH:high or CH:low. Time zero is the trigger.")
    var trigger: TriggerPoint?

    @Option(help: "Narrowest pulse that triggers, for CH:high and CH:low.")
    var pulseMin: Seconds?

    @Option(help: "Widest pulse that triggers, for CH:high and CH:low.")
    var pulseMax: Seconds?

    @Option(help: "Level another channel must hold at the trigger, as CH:high or CH:low. Repeatable.")
    var link: [LinkedChannel] = []

    @Option(help: "Seconds to wait for the trigger.")
    var triggerTimeout = 10.0

    @Option(help: "Use a saved .sal file instead of capturing.")
    var load: String?

    @Option(help: "Save the capture to this .sal file.")
    var save: String?

    /// Paths are made absolute here, because Logic 2 runs in its own working directory.
    var loadPath: String? { load.map(absolutePath) }

    func validate() throws {
        if load != nil {
            let capturing =
                rate != nil || duration != nil || device != nil || manual || trim != nil || bufferMb != nil
                || !glitch.isEmpty || trigger != nil
            guard !capturing else {
                throw ValidationError("--load uses a saved capture, so it cannot take capture settings.")
            }
        }
        if let duration {
            guard duration.isFinite, duration > 0 else {
                throw ValidationError("Duration must be a positive number of seconds.")
            }
        }
        guard !(manual && trigger != nil) else { throw ValidationError("Use --manual or --trigger, not both.") }
        guard trigger == nil || trim == nil else {
            throw ValidationError("--trim does not apply to --trigger. Logic 2 ignores it.")
        }
        guard trigger != nil || (pulseMin == nil && pulseMax == nil && link.isEmpty) else {
            throw ValidationError("--pulse-min, --pulse-max and --link need --trigger.")
        }
        guard trigger?.kind.isPulse == true || (pulseMin == nil && pulseMax == nil) else {
            throw ValidationError("--pulse-min and --pulse-max need a CH:high or CH:low trigger.")
        }
        if let pulseMin, let pulseMax {
            guard pulseMin.value <= pulseMax.value else {
                throw ValidationError("--pulse-min cannot exceed --pulse-max.")
            }
        }
        guard triggerTimeout.isFinite, triggerTimeout > 0 else {
            throw ValidationError("--trigger-timeout must be a positive number of seconds.")
        }
        let named = glitch.map(\.channel) + link.map(\.channel) + [trigger?.channel].compactMap { $0 }
        guard named.allSatisfy({ $0 <= maximumChannel }) else {
            throw ValidationError("Channels must be at most \(maximumChannel).")
        }
        let linked = link.map(\.channel)
        guard Set(linked).count == linked.count, !linked.contains(where: { $0 == trigger?.channel }) else {
            throw ValidationError("A linked channel must be distinct from the others and from the trigger.")
        }
    }

    /// Builds the request. Trigger and linked channels are captured too, because Logic 2
    /// can only watch channels that are enabled.
    func request(
        channels: [UInt32],
        analog: AnalogCapture? = nil,
        stop: CaptureCancellation
    ) throws -> DigitalCaptureRequest {
        let extra = link.map(\.channel) + [trigger?.channel].compactMap { $0 }
        let captured = Array(Set(channels + extra)).sorted()
        guard glitch.allSatisfy({ captured.contains($0.channel) }) else {
            throw ValidationError("--glitch names a channel that is not being captured.")
        }

        let mode: CaptureMode
        if let loadPath {
            mode = .load(path: loadPath)
        } else if manual {
            mode = .manual(limitSeconds: duration, trimSeconds: trim?.value ?? 0, stop: stop)
        } else if let trigger {
            mode = .trigger(
                DigitalTrigger(
                    point: trigger, afterSeconds: duration ?? defaultDuration, minimumPulse: pulseMin,
                    maximumPulse: pulseMax, linked: link, timeoutSeconds: triggerTimeout))
        } else {
            mode = .timed(seconds: duration ?? defaultDuration, trimSeconds: trim?.value ?? 0)
        }
        return DigitalCaptureRequest(
            channels: captured, sampleRate: try parseSampleRate(rate ?? (analog == nil ? "50M" : "6.25M")), mode: mode,
            levelVolts: level, deviceID: device, glitchFilters: glitch, bufferMegabytes: bufferMb, analog: analog,
            savePath: save.map(absolutePath))
    }

    /// Runs `body` with the built request. Ctrl-C ends a manual capture and keeps its
    /// data, and cancels any other kind.
    func perform<Result: Sendable>(
        channels: [UInt32],
        analog: AnalogCapture? = nil,
        handlingSignals: Bool = true,
        body: @escaping @Sendable (DigitalCaptureRequest) async throws -> Result
    ) async throws -> Result {
        let stop = CaptureCancellation()
        let built = try request(channels: channels, analog: analog, stop: stop)
        guard handlingSignals else { return try await body(built) }
        if manual && duration == nil {
            FileHandle.standardError.write(Data("Capturing until Ctrl-C\n".utf8))
        }
        let stopManual: @Sendable () -> Void = { stop.cancel() }
        return try await exitingOnInterrupt(interrupt: manual ? stopManual : nil) {
            try await body(built)
        }
    }
}

private let defaultDuration = 0.5

func absolutePath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

/// The channel list to use. A loaded file without one exports whatever it holds.
func resolvedChannels(_ text: String?, loading: Bool) throws -> [UInt32] {
    switch text {
    case "none": []
    case let text?: try parseChannelList(text)
    case nil: loading ? [] : try parseChannelList("0-7")
    }
}
