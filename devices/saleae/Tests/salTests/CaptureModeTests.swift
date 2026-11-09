import ArgumentParser
import Testing
@testable import sal

private func request(_ mode: CaptureMode) -> DigitalCaptureRequest {
    DigitalCaptureRequest(channels: [1], sampleRate: 1000, mode: mode, levelVolts: 3.3, deviceID: nil)
}

private let point = TriggerPoint(channel: 1, kind: .rising)

@Suite("Capture mode arguments")
struct CaptureArgumentParsingTests {
    @Test("Seconds accept each unit", arguments: [
        ("2", 2.0), ("2s", 2.0), ("3ms", 3e-3), ("4us", 4e-6), ("5ns", 5e-9), ("1.5us", 1.5e-6),
    ])
    func seconds(text: String, expected: Double) throws {
        let value = try #require(Seconds(argument: text))
        #expect(abs(value.value - expected) < expected * 1e-9)
    }

    @Test("Bad seconds are refused", arguments: ["", "s", "0", "0us", "-1", "-1ms", "nan", "inf", "5xs", "us5"])
    func badSeconds(text: String) {
        #expect(Seconds(argument: text) == nil)
    }

    @Test("Glitch filters parse")
    func glitch() {
        #expect(GlitchFilter(argument: "2:5us") == GlitchFilter(channel: 2, width: Seconds(argument: "5us")!))
    }

    @Test("Bad channel specs are refused", arguments: ["", ":", "1", ":5us", "x:5us", "-1:5us", "1:2:3", "1:"])
    func badGlitch(text: String) {
        #expect(GlitchFilter(argument: text) == nil)
    }

    @Test("Triggers parse every kind", arguments: TriggerKind.allCases)
    func triggers(kind: TriggerKind) {
        #expect(TriggerPoint(argument: "3:\(kind.rawValue)") == TriggerPoint(channel: 3, kind: kind))
    }

    @Test("Bad triggers are refused", arguments: ["1:up", "x:rising", "rising", "1:rising:2"])
    func badTrigger(text: String) {
        #expect(TriggerPoint(argument: text) == nil)
    }

    @Test("Linked channels parse")
    func linked() {
        #expect(LinkedChannel(argument: "5:high") == LinkedChannel(channel: 5, isHigh: true))
        #expect(LinkedChannel(argument: "5:low") == LinkedChannel(channel: 5, isHigh: false))
        #expect(LinkedChannel(argument: "5:rising") == nil)
    }

    @Test("Trigger kinds map to wire values and know which are pulses")
    func kinds() {
        #expect(TriggerKind.allCases.map(\.type) == [.rising, .falling, .pulseHigh, .pulseLow])
        #expect(TriggerKind.allCases.map(\.isPulse) == [false, false, true, true])
    }

    @Test("A timeout message names the wait")
    func timeoutMessage() {
        #expect(CaptureError.triggerTimeout(seconds: 2).description == "The trigger did not fire within 2.0 seconds.")
    }
}

@Suite("Capture start requests")
struct CaptureStartRequestTests {
    @Test("Timed requests carry the duration and trim")
    func timed() {
        let timed = request(.timed(seconds: 2, trimSeconds: 0.5)).startRequest.captureConfiguration
        #expect(timed.timedCaptureMode.durationSeconds == 2)
        #expect(timed.timedCaptureMode.trimDataSeconds == 0.5)
    }

    @Test("Manual requests are manual and carry the trim")
    func manual() {
        let mode = CaptureMode.manual(limitSeconds: nil, trimSeconds: 0.25, stop: CaptureCancellation())
        let start = request(mode).startRequest.captureConfiguration
        guard case .manualCaptureMode(let manual)? = start.captureMode else {
            Issue.record("not manual")
            return
        }
        #expect(manual.trimDataSeconds == 0.25)
    }

    @Test("Trigger requests carry every field")
    func trigger() {
        let trigger = DigitalTrigger(
            point: TriggerPoint(channel: 3, kind: .high), afterSeconds: 0.1, minimumPulse: Seconds(1e-6),
            maximumPulse: Seconds(2e-6),
            linked: [LinkedChannel(channel: 5, isHigh: true), LinkedChannel(channel: 6, isHigh: false)],
            timeoutSeconds: 9)
        let digital = request(.trigger(trigger)).startRequest.captureConfiguration.digitalCaptureMode
        #expect(digital.triggerChannelIndex == 3)
        #expect(digital.triggerType == .pulseHigh)
        #expect(digital.afterTriggerSeconds == 0.1)
        #expect(digital.minPulseWidthSeconds == 1e-6)
        #expect(digital.maxPulseWidthSeconds == 2e-6)
        #expect(digital.linkedChannels.map(\.channelIndex) == [5, 6])
        #expect(digital.linkedChannels.map(\.state) == [.high, .low])
    }

    @Test("A pulse trigger without a maximum sends a large one, because zero never fires", arguments: [TriggerKind.high, .low])
    func openEndedPulse(kind: TriggerKind) {
        let trigger = DigitalTrigger(point: TriggerPoint(channel: 1, kind: kind), afterSeconds: 1, timeoutSeconds: 1)
        let digital = request(.trigger(trigger)).startRequest.captureConfiguration.digitalCaptureMode
        #expect(digital.minPulseWidthSeconds == 0)
        #expect(digital.maxPulseWidthSeconds == unboundedPulseSeconds)
    }

    @Test("Edge triggers send no pulse bounds")
    func omittedBounds() {
        let trigger = DigitalTrigger(point: point, afterSeconds: 1, timeoutSeconds: 1)
        let digital = request(.trigger(trigger)).startRequest.captureConfiguration.digitalCaptureMode
        #expect(digital.minPulseWidthSeconds == 0)
        #expect(digital.maxPulseWidthSeconds == 0)
    }

    @Test("Glitch filters and the buffer limit reach the device and capture config")
    func glitchAndBuffer() {
        var capture = request(.timed(seconds: 1))
        capture.glitchFilters = [GlitchFilter(channel: 1, width: Seconds(5e-6))]
        capture.bufferMegabytes = 64
        let start = capture.startRequest
        #expect(start.logicDeviceConfiguration.glitchFilters.map(\.channelIndex) == [1])
        #expect(start.logicDeviceConfiguration.glitchFilters.map(\.pulseWidthSeconds) == [5e-6])
        #expect(start.captureConfiguration.bufferSizeMegabytes == 64)
    }

    @Test("No limit leaves Logic 2's default in place")
    func defaultBuffer() {
        #expect(request(.timed(seconds: 1)).startRequest.captureConfiguration.bufferSizeMegabytes == 0)
    }
}

@Suite("Capture options")
struct CaptureOptionTests {
    private func options(_ arguments: [String]) throws -> CaptureCommand {
        try #require(try Sal.parseAsRoot(["capture"] + arguments) as? CaptureCommand)
    }

    private func built(_ arguments: [String], channels: [UInt32] = [2]) throws -> DigitalCaptureRequest {
        try options(arguments).capture.request(channels: channels, stop: CaptureCancellation())
    }

    @Test("Without options a capture is timed for half a second")
    func defaults() throws {
        guard case .timed(let seconds, let trim) = try built([]).mode else {
            Issue.record("not timed")
            return
        }
        #expect(seconds == 0.5)
        #expect(trim == 0)
    }

    @Test("Duration and trim reach a timed capture")
    func timed() throws {
        guard case .timed(let seconds, let trim) = try built(["--duration", "2", "--trim", "100ms"]).mode else {
            Issue.record("not timed")
            return
        }
        #expect(seconds == 2)
        #expect(trim == 0.1)
    }

    @Test("Manual has no limit unless a duration is given")
    func manual() throws {
        guard case .manual(let limit, let trim, _) = try built(["--manual", "--trim", "1"]).mode else {
            Issue.record("not manual")
            return
        }
        #expect(limit == nil)
        #expect(trim == 1)

        guard case .manual(let given, _, _) = try built(["--manual", "--duration", "3"]).mode else {
            Issue.record("not manual")
            return
        }
        #expect(given == 3)
    }

    @Test("A trigger captures its channels too and uses the duration after it")
    func trigger() throws {
        let capture = try built(
            ["--trigger", "1:high", "--duration", "0.2", "--pulse-min", "1us", "--pulse-max", "2us",
             "--link", "5:low", "--trigger-timeout", "3"])
        #expect(capture.channels == [1, 2, 5])
        guard case .trigger(let trigger) = capture.mode else {
            Issue.record("not a trigger")
            return
        }
        #expect(trigger == DigitalTrigger(
            point: TriggerPoint(channel: 1, kind: .high), afterSeconds: 0.2, minimumPulse: Seconds(argument: "1us"),
            maximumPulse: Seconds(argument: "2us"), linked: [LinkedChannel(channel: 5, isHigh: false)],
            timeoutSeconds: 3))
    }

    @Test("A trigger on a captured channel does not repeat it, and defaults its timing")
    func triggerDefaults() throws {
        let capture = try built(["--trigger", "2:rising"])
        #expect(capture.channels == [2])
        guard case .trigger(let trigger) = capture.mode else {
            Issue.record("not a trigger")
            return
        }
        #expect(trigger.afterSeconds == 0.5)
        #expect(trigger.timeoutSeconds == 10)
    }

    @Test("Glitch filters and buffer reach the request")
    func glitch() throws {
        let capture = try built(["--glitch", "2:5us", "--buffer-mb", "32"])
        #expect(capture.glitchFilters == [GlitchFilter(channel: 2, width: Seconds(argument: "5us")!)])
        #expect(capture.bufferMegabytes == 32)
    }

    @Test("A glitch filter on an uncaptured channel is refused")
    func glitchUncaptured() throws {
        #expect(throws: ValidationError.self) { try built(["--glitch", "3:5us"]) }
    }

    @Test("A filter on a trigger channel is allowed, since that channel is captured")
    func glitchOnTriggerChannel() throws {
        #expect(throws: Never.self) { try built(["--trigger", "3:rising", "--glitch", "3:5us"]) }
    }

    @Test("Equal pulse bounds and the highest channel are accepted", arguments: [
        ["--trigger", "1:high", "--pulse-min", "1us", "--pulse-max", "1us"],
        ["--trigger", "1:low", "--pulse-min", "1us"],
        ["--trigger", "15:rising", "--link", "14:high"],
    ])
    func accepted(arguments: [String]) {
        #expect(throws: Never.self) { try options(arguments) }
    }

    @Test("Conflicting options are refused", arguments: [
        ["--manual", "--trigger", "1:rising"],
        ["--trigger", "1:rising", "--trim", "1"],
        ["--pulse-min", "1us"],
        ["--pulse-max", "1us"],
        ["--link", "1:high"],
        ["--trigger", "1:rising", "--pulse-min", "1us"],
        ["--trigger", "1:falling", "--pulse-max", "1us"],
        ["--trigger", "1:high", "--pulse-min", "2us", "--pulse-max", "1us"],
        ["--trigger", "1:rising", "--trigger-timeout", "0"],
        ["--trigger", "1:rising", "--trigger-timeout", "nan"],
        ["--trigger", "16:rising"],
        ["--glitch", "16:5us"],
        ["--trigger", "1:rising", "--link", "16:high"],
        ["--trigger", "1:rising", "--link", "1:high"],
        ["--trigger", "1:rising", "--link", "2:high", "--link", "2:low"],
        ["--duration", "0"],
        ["--duration", "inf"],
    ])
    func refused(arguments: [String]) {
        #expect(throws: (any Error).self) { try options(arguments) }
    }
}
