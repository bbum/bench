import GRPCCore
import GRPCNIOTransportHTTP2TransportServices

/// Where Logic 2's automation server is listening. It serves plaintext HTTP/2 on loopback.
struct Logic2Endpoint: Sendable {
    var host = "127.0.0.1"
    var port = 10430
}

typealias Logic2Manager = Saleae_Automation_Manager.Client<HTTP2ClientTransport.TransportServices>

/// Runs `body` with a connected client, tearing the connection down when it returns.
func withLogic2<Result: Sendable>(
    _ endpoint: Logic2Endpoint,
    body: (Logic2Manager) async throws -> Result
) async throws -> Result {
    let transport = try HTTP2ClientTransport.TransportServices(
        target: .ipv4(address: endpoint.host, port: endpoint.port),
        transportSecurity: .plaintext
    )
    return try await withGRPCClient(transport: transport) { client in
        try await body(Logic2Manager(wrapping: client))
    }
}
