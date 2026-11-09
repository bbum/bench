import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices

/// Where Logic 2's automation server is listening. It serves plaintext HTTP/2 on loopback.
struct Logic2Endpoint: Sendable, Equatable {
    var host = "127.0.0.1"
    var port = 10430
    /// Start Logic 2 when nothing is listening. Commands ask for this, and it only ever
    /// happens on this machine.
    var launchIfNeeded = false

    var isLocal: Bool { host == "127.0.0.1" }

    var mayLaunch: Bool { launchIfNeeded && isLocal }
}

typealias Logic2Manager = Saleae_Automation_Manager.Client<HTTP2ClientTransport.TransportServices>

/// What is wrong with Logic 2 itself, as opposed to with a request. Each says what to do.
enum Logic2Error: Error, Equatable, CustomStringConvertible {
    /// Nothing accepts connections.
    case notRunning(host: String, port: Int)
    /// Connections are accepted and nothing answers, which is how a hung Logic 2 looks.
    case notAnswering(host: String, port: Int, seconds: Double)
    /// It answered, then the connection dropped partway through.
    case connectionLost(host: String, port: Int)
    /// It answered, then a later call outlived its limit.
    case stalled
    case notInstalled
    case runningWithoutAutomation(port: Int)
    case didNotStart(port: Int, seconds: Double)
    case notLocal(host: String)

    var description: String {
        switch self {
        case .notRunning(let host, let port):
            "Logic 2 is not running at \(host):\(port), or its automation server is off. Start it with `sal app start`."
        case .notAnswering(let host, let port, let seconds):
            "Logic 2 accepts connections at \(host):\(port) but did not answer within \(formatted(seconds)) seconds. "
                + "It has probably hung. Restart it with `sal app restart`."
        case .connectionLost(let host, let port):
            "Logic 2 at \(host):\(port) dropped the connection partway through. It probably quit or crashed."
        case .stalled:
            "Logic 2 stopped answering partway through. It has probably hung. Restart it with `sal app restart`."
        case .notInstalled:
            "Logic 2 is not installed. Get it from https://www.saleae.com/downloads/."
        case .runningWithoutAutomation(let port):
            "Logic 2 is running but nothing answers on port \(port). Turn on Settings > Automation, or run `sal app restart`."
        case .didNotStart(let port, let seconds):
            "Logic 2 was started but its automation server did not answer on port \(port) within \(formatted(seconds)) seconds."
        case .notLocal(let host):
            "Logic 2 can only be started or stopped on this machine, not at \(host)."
        }
    }

    private func formatted(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}

/// The longest a healthy Logic 2 takes to say which version it is. It answers in about
/// 30 ms, even in the middle of a capture.
let healthProbeSeconds = 5.0

extension CallOptions {
    /// For calls that only change state, which a healthy Logic 2 answers at once.
    static var control: CallOptions { limited(to: 30) }

    /// For calls that move data, which take longer the bigger the capture.
    static var data: CallOptions { limited(to: 300) }

    static func limited(to seconds: Double) -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = .seconds(seconds)
        return options
    }
}

/// Runs `body` with a connected client, tearing the connection down when it returns.
///
/// Logic 2 is asked a trivial question first, so a dead or hung one is reported at once
/// and by name instead of as a call that never returns. If nothing is listening and the
/// endpoint allows it, Logic 2 is started and the connection is made again.
func withLogic2<Result: Sendable>(
    _ endpoint: Logic2Endpoint,
    probeSeconds: Double = healthProbeSeconds,
    launch: (Int) async throws -> Void = { try await startLogic2IfAllowed(port: $0) },
    body: (Logic2Manager) async throws -> Result
) async throws -> Result {
    do {
        return try await connected(endpoint, probeSeconds: probeSeconds, body: body)
    } catch Logic2Error.notRunning where endpoint.mayLaunch {
        // Only the probe reports this, so `body` has not run yet.
        try await launch(endpoint.port)
        return try await connected(endpoint, probeSeconds: probeSeconds, body: body)
    }
}

/// Starts Logic 2 on a command's behalf. `SAL_NO_LAUNCH` in the environment forbids that,
/// for machines where only a person may start it, and for test runs.
func startLogic2IfAllowed(
    port: Int,
    environment: [String: String] = ProcessInfo.processInfo.environment
) async throws {
    guard environment["SAL_NO_LAUNCH"] == nil else { throw Logic2Error.notRunning(host: "127.0.0.1", port: port) }
    try await startLogic2(port: port)
}

private func connected<Result: Sendable>(
    _ endpoint: Logic2Endpoint,
    probeSeconds: Double,
    body: (Logic2Manager) async throws -> Result
) async throws -> Result {
    let transport = try HTTP2ClientTransport.TransportServices(
        target: .ipv4(address: endpoint.host, port: endpoint.port),
        transportSecurity: .plaintext
    )
    do {
        return try await withGRPCClient(transport: transport) { client in
            let manager = Logic2Manager(wrapping: client)
            try await requireAnswer(from: endpoint, within: probeSeconds) { options in
                _ = try await manager.getAppInfo(.init(), options: options)
            }
            warnIfBloated(endpoint)
            return try await body(manager)
        }
    } catch let error as RPCError {
        throw errorAfterAnswering(error, endpoint)
    }
}

/// Runs the first question put to Logic 2, limited to `seconds`, and names what a failure
/// means.
func requireAnswer(
    from endpoint: Logic2Endpoint,
    within seconds: Double,
    ask: (CallOptions) async throws -> Void
) async throws {
    do {
        try await ask(.limited(to: seconds))
    } catch let error as RPCError {
        switch error.code {
        case .unavailable: throw Logic2Error.notRunning(host: endpoint.host, port: endpoint.port)
        case .deadlineExceeded:
            throw Logic2Error.notAnswering(host: endpoint.host, port: endpoint.port, seconds: seconds)
        default: throw error
        }
    }
}

/// Names a failure that came after Logic 2 had already answered. Anything else is
/// Logic 2 refusing a request, and its own message says why.
func errorAfterAnswering(_ error: RPCError, _ endpoint: Logic2Endpoint) -> any Error {
    switch error.code {
    case .unavailable: Logic2Error.connectionLost(host: endpoint.host, port: endpoint.port)
    case .deadlineExceeded: Logic2Error.stalled
    default: error
    }
}

private func warnIfBloated(_ endpoint: Logic2Endpoint) {
    guard endpoint.isLocal, let health = logic2Health(), let warning = health.warning else { return }
    FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
}
