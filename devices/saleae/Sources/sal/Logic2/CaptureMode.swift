import ArgumentParser
import Foundation

/// Accepts seconds, or a value with an ns, us, ms or s suffix.
struct Seconds: ExpressibleByArgument, Equatable, Sendable {
    var value: Double

    init(_ value: Double) { self.value = value }

    init?(argument: String) {
        let units: [(suffix: String, scale: Double)] = [("ns", 1e-9), ("us", 1e-6), ("ms", 1e-3), ("s", 1)]
        let unit = units.first { argument.hasSuffix($0.suffix) }
        guard let number = Double(argument.dropLast(unit?.suffix.count ?? 0)) else { return nil }
        let value = number * (unit?.scale ?? 1)
        guard value.isFinite, value > 0 else { return nil }
        self.value = value
    }
}

private func channelAndName(_ argument: String) -> (channel: UInt32, name: Substring)? {
    let parts = argument.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let channel = UInt32(parts[0]) else { return nil }
    return (channel, parts[1])
}

/// Ignores pulses narrower than a width on one channel. Written as `CH:WIDTH`.
struct GlitchFilter: ExpressibleByArgument, Equatable, Sendable {
    var channel: UInt32
    var width: Seconds

    init(channel: UInt32, width: Seconds) {
        self.channel = channel
        self.width = width
    }

    init?(argument: String) {
        guard let (channel, name) = channelAndName(argument), let width = Seconds(argument: String(name)) else {
            return nil
        }
        self.init(channel: channel, width: width)
    }
}

enum TriggerKind: String, CaseIterable, Sendable {
    case rising, falling, high, low

    var type: Saleae_Automation_DigitalTriggerType {
        switch self {
        case .rising: .rising
        case .falling: .falling
        case .high: .pulseHigh
        case .low: .pulseLow
        }
    }

    var isPulse: Bool { self == .high || self == .low }
}

/// Where and what to trigger on. Written as `CH:rising`, `CH:falling`, `CH:high` or `CH:low`.
struct TriggerPoint: ExpressibleByArgument, Equatable, Sendable {
    var channel: UInt32
    var kind: TriggerKind

    init(channel: UInt32, kind: TriggerKind) {
        self.channel = channel
        self.kind = kind
    }

    init?(argument: String) {
        guard let (channel, name) = channelAndName(argument), let kind = TriggerKind(rawValue: String(name)) else {
            return nil
        }
        self.init(channel: channel, kind: kind)
    }
}

/// A level another channel must hold when the trigger fires. Written as `CH:high` or `CH:low`.
struct LinkedChannel: ExpressibleByArgument, Equatable, Sendable {
    var channel: UInt32
    var isHigh: Bool

    init(channel: UInt32, isHigh: Bool) {
        self.channel = channel
        self.isHigh = isHigh
    }

    init?(argument: String) {
        guard let (channel, name) = channelAndName(argument), name == "high" || name == "low" else { return nil }
        self.init(channel: channel, isHigh: name == "high")
    }
}

struct DigitalTrigger: Equatable, Sendable {
    var point: TriggerPoint
    var afterSeconds: Double
    var minimumPulse: Seconds?
    var maximumPulse: Seconds?
    var linked: [LinkedChannel] = []
    /// How long to wait for the trigger. Logic 2 would otherwise wait forever.
    var timeoutSeconds: Double
}

enum CaptureMode: Sendable {
    case timed(seconds: Double, trimSeconds: Double = 0)
    /// Runs until `stop` is cancelled or `limitSeconds` passes.
    case manual(limitSeconds: Double?, trimSeconds: Double = 0, stop: CaptureCancellation)
    case trigger(DigitalTrigger)
    /// Opens a saved `.sal` file instead of capturing. The path must be absolute.
    case load(path: String)
}

enum CaptureError: Error, Equatable, CustomStringConvertible {
    case triggerTimeout(seconds: Double)

    var description: String {
        switch self {
        case .triggerTimeout(let seconds): "The trigger did not fire within \(seconds) seconds."
        }
    }
}

/// Stands in for "no maximum", since the protocol has no way to say that.
let unboundedPulseSeconds = 3600.0

extension DigitalCaptureRequest {
    var startRequest: Saleae_Automation_StartCaptureRequest {
        var device = Saleae_Automation_LogicDeviceConfiguration()
        device.logicChannels = logicChannels
        device.digitalSampleRate = sampleRate
        device.digitalThresholdVolts = levelVolts
        device.analogSampleRate = analog?.sampleRate ?? 0
        device.glitchFilters = glitchFilters.map { filter in
            var entry = Saleae_Automation_GlitchFilterEntry()
            entry.channelIndex = filter.channel
            entry.pulseWidthSeconds = filter.width.value
            return entry
        }

        var start = Saleae_Automation_StartCaptureRequest()
        start.deviceID = deviceID ?? ""
        start.logicDeviceConfiguration = device
        start.captureConfiguration.bufferSizeMegabytes = bufferMegabytes ?? 0

        switch mode {
        case .load:
            break
        case .timed(let seconds, let trimSeconds):
            var timed = Saleae_Automation_TimedCaptureMode()
            timed.durationSeconds = seconds
            timed.trimDataSeconds = trimSeconds
            start.captureConfiguration.timedCaptureMode = timed
        case .manual(_, let trimSeconds, _):
            var manual = Saleae_Automation_ManualCaptureMode()
            manual.trimDataSeconds = trimSeconds
            start.captureConfiguration.manualCaptureMode = manual
        case .trigger(let trigger):
            var digital = Saleae_Automation_DigitalTriggerCaptureMode()
            digital.triggerChannelIndex = trigger.point.channel
            digital.triggerType = trigger.point.kind.type
            digital.afterTriggerSeconds = trigger.afterSeconds
            digital.minPulseWidthSeconds = trigger.minimumPulse?.value ?? 0
            // Logic 2 reads a maximum of zero literally, and such a trigger never fires.
            digital.maxPulseWidthSeconds =
                trigger.maximumPulse?.value ?? (trigger.point.kind.isPulse ? unboundedPulseSeconds : 0)
            digital.linkedChannels = trigger.linked.map { link in
                var linked = Saleae_Automation_DigitalTriggerLinkedChannel()
                linked.channelIndex = link.channel
                linked.state = link.isHigh ? .high : .low
                return linked
            }
            start.captureConfiguration.digitalCaptureMode = digital
        }
        return start
    }
}
