import ArgumentParser
import GRPCCore

struct Logic2Options: ParsableArguments {
    @Option(help: "Logic 2 automation server address.")
    var host = "127.0.0.1"

    @Option(help: "Logic 2 automation server port.")
    var port = 10430

    var endpoint: Logic2Endpoint { Logic2Endpoint(host: host, port: port) }
}

@main
struct Sal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sal",
        abstract: "Drive Saleae logic analyzers through Logic 2's automation server.",
        subcommands: [Status.self, CaptureCommand.self, DecodeCommand.self, IdentifyCommand.self, AnalyzeCommand.self, MCPCommand.self]
    )
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the Logic 2 version and connected devices."
    )

    @OptionGroup var logic2: Logic2Options

    func run() async throws {
        try await withLogic2(logic2.endpoint) { manager in
            let (app, devices) = try await query(manager)
            statusLines(app: app, devices: devices).forEach { print($0) }
        }
    }

    func information() async throws -> StatusInformation {
        try await withLogic2(logic2.endpoint) { manager in
            let (app, devices) = try await query(manager)
            let api = app.apiVersion
            return StatusInformation(
                logicVersion: app.applicationVersion, apiVersion: "\(api.major).\(api.minor).\(api.patch)",
                devices: devices.map { StatusInformation.Device(type: "\($0.deviceType)", id: $0.deviceID) })
        }
    }

    private func query(_ manager: Logic2Manager) async throws -> (Saleae_Automation_AppInfo, [Saleae_Automation_Device]) {
        var options = CallOptions.defaults
        options.timeout = .seconds(5)
        let app = try await manager.getAppInfo(.init(), options: options).appInfo
        return (app, try await manager.getDevices(.init(), options: options).devices)
    }
}

struct StatusInformation: Encodable, Sendable {
    struct Device: Encodable, Sendable {
        var type: String
        var id: String
    }

    var logicVersion: String
    var apiVersion: String
    var devices: [Device]
}

func statusLines(
    app: Saleae_Automation_AppInfo,
    devices: [Saleae_Automation_Device]
) -> [String] {
    let api = app.apiVersion
    let header = "Logic \(app.applicationVersion), API \(api.major).\(api.minor).\(api.patch)"
    guard !devices.isEmpty else { return [header, "No devices connected"] }
    return [header] + devices.map { "\($0.deviceType) \($0.deviceID)" }
}
