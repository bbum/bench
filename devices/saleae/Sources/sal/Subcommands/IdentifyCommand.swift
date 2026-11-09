import ArgumentParser
import Foundation

struct IdentifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identify",
        abstract: "Work out what is on each channel, including UART baud rates."
    )

    @OptionGroup var capture: CaptureOptions

    @Option(help: "Digital channels, such as 0-7 or 0,2,4. Defaults to 0-7, or all with --load.")
    var channels: String?

    @Flag(help: "Trust timing alone instead of confirming each bus with Logic 2's decoders.")
    var noConfirm = false

    @Flag(help: "Print JSON instead of a table.")
    var json = false

    func run() async throws {
        let confirm = !noConfirm
        let endpoint = capture.logic2.endpoint
        let digital = try resolvedChannels(channels, loading: capture.load != nil)
        let identification = try await capture.perform(channels: digital) { request in
            try await runIdentify(request, confirm: confirm, endpoint: endpoint)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(identification), as: UTF8.self))
        } else {
            describe(identification).forEach { print($0) }
        }
    }
}

func describe(_ identification: ChannelIdentification) -> [String] {
    var lines: [String] = []
    for bus in identification.buses {
        let roles = bus.decoder.channelRoles.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        lines.append("\(bus.decoder.kind.uppercased())  \(roles.joined(separator: " "))  \(bus.confidence.rawValue): \(bus.evidence)")
        lines.append("  \(bus.decoder.command)")
        lines += bus.notes.map { "  Note: \($0)" }
    }
    for periodic in identification.periodic {
        lines.append(String(format: "CH%d  %.2f Hz, %.2f%% duty", periodic.channel, periodic.frequencyHz, periodic.dutyPercent))
    }
    lines += identification.idle.map { "CH\($0.channel)  idle \($0.level == 1 ? "high" : "low")" }
    lines += identification.unknown.map { "CH\($0)  active, unidentified" }
    lines += identification.notes.map { "Note: \($0)" }
    return lines
}
