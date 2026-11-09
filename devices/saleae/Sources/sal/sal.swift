import ArgumentParser
import Foundation
import GRPCCore

struct Logic2Options: ParsableArguments {
    @Option(help: "Logic 2 automation server address.")
    var host = "127.0.0.1"

    @Option(help: "Logic 2 automation server port.")
    var port = 10430

    @Flag(inversion: .prefixedNo, help: "Start Logic 2 if it is not running. Only on this machine.")
    var launch = true

    var endpoint: Logic2Endpoint { Logic2Endpoint(host: host, port: port, launchIfNeeded: launch) }
}

@main
struct Sal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sal",
        abstract: "Drive Saleae logic analyzers through Logic 2's automation server.",
        subcommands: [Status.self, CaptureCommand.self, DecodeCommand.self, IdentifyCommand.self, AnalyzeCommand.self, TimelineCommand.self, AppCommand.self, MCPCommand.self]
    )
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the Logic 2 version and connected devices."
    )

    @OptionGroup var logic2: Logic2Options

    func run() async throws {
        let endpoint = logic2.endpoint
        let health = endpoint.isLocal ? logic2Health() : nil
        do {
            let lines = try await withLogic2(endpoint) { manager in
                let (app, devices) = try await query(manager)
                return statusLines(app: app, devices: devices)
            }
            // Read again, because Logic 2 may only just have been started.
            (lines + processLines(endpoint.isLocal ? logic2Health() : nil)).forEach { print($0) }
        } catch let error as Logic2Error {
            // A hung Logic 2 cannot say how it is, but its process can be weighed.
            processLines(health).forEach { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
            throw error
        }
    }

    func information() async throws -> StatusInformation {
        let endpoint = logic2.endpoint
        return try await withLogic2(endpoint) { manager in
            let (app, devices) = try await query(manager)
            let api = app.apiVersion
            return StatusInformation(
                logicVersion: app.applicationVersion, apiVersion: "\(api.major).\(api.minor).\(api.patch)",
                devices: devices.map { StatusInformation.Device(type: "\($0.deviceType)", id: $0.deviceID) },
                process: endpoint.isLocal ? logic2Health() : nil)
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
    /// Present when Logic 2 runs on this machine.
    var process: Logic2Health?
}

func processLines(_ health: Logic2Health?) -> [String] {
    guard let health else { return [] }
    return [health.line] + (health.warning.map { ["Warning: \($0)"] } ?? [])
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
