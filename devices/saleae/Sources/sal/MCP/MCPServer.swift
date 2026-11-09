import Foundation

/// What the server needs from its tools. Tests substitute a fake.
protocol ToolCatalog: Sendable {
    var definitions: [JSONValue] { get }
    func hasTool(named name: String) -> Bool
    /// Returns text for the caller. Thrown errors are reported as failed tool calls.
    func call(name: String, arguments: JSONValue) async throws -> String
}

/// JSON-RPC over stdio, one message per line.
///
/// Requests keep being read while a tool runs, so a cancellation can reach a long capture.
/// Tool calls run one at a time, in order, because Logic 2 runs one capture at a time.
actor MCPServer {
    private let tools: any ToolCatalog
    private let output: @Sendable (Data) -> Void
    private var running: [RequestID: Task<Void, Never>] = [:]
    private var last: Task<Void, Never>?

    init(tools: any ToolCatalog, output: @escaping @Sendable (Data) -> Void) {
        self.tools = tools
        self.output = output
    }

    func receive(_ line: Data) {
        guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { return }
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: line) else {
            send(JSONRPCResponse(id: nil, error: JSONRPCError(code: JSONRPCError.parseError, message: "Unreadable request")))
            return
        }
        guard let id = request.id else {
            if request.method == "notifications/cancelled" {
                RequestID(request.params?["requestId"]).flatMap { running[$0] }?.cancel()
            }
            return
        }

        switch request.method {
        case "initialize":
            send(JSONRPCResponse(id: id, result: initializeResult(request.params)))
        case "ping":
            send(JSONRPCResponse(id: id, result: .object([:])))
        case "tools/list":
            send(JSONRPCResponse(id: id, result: .object(["tools": .array(tools.definitions)])))
        case "tools/call":
            startCall(id: id, params: request.params)
        default:
            send(JSONRPCResponse(
                id: id, error: JSONRPCError(code: JSONRPCError.methodNotFound, message: "Method not found: \(request.method)")))
        }
    }

    /// Cancels whatever is running and waits for its cleanup, so no capture outlives the client.
    func finish() async {
        running.values.forEach { $0.cancel() }
        await last?.value
    }

    private func initializeResult(_ params: JSONValue?) -> JSONValue {
        .object([
            "protocolVersion": params?["protocolVersion"] ?? .string("2024-11-05"),
            "serverInfo": .object(["name": .string("sal"), "version": .string("1.0.0")]),
            "capabilities": .object(["tools": .object([:])]),
        ])
    }

    private func startCall(id: RequestID, params: JSONValue?) {
        guard let name = params?["name"]?.stringValue, tools.hasTool(named: name) else {
            send(JSONRPCResponse(
                id: id,
                error: JSONRPCError(code: JSONRPCError.invalidParams, message: "Unknown tool: \(params?["name"]?.stringValue ?? "none")")))
            return
        }
        let arguments = params?["arguments"] ?? .object([:])
        let tools = tools
        let previous = last
        let task = Task {
            await previous?.value
            let result = await Self.perform(tools, name: name, arguments: arguments)
            self.complete(id: id, result: Task.isCancelled ? nil : result)
        }
        running[id] = task
        last = task
    }

    /// A failure in the tool is a result the caller can read, not a protocol error.
    private static func perform(_ tools: any ToolCatalog, name: String, arguments: JSONValue) async -> JSONValue? {
        guard !Task.isCancelled else { return nil }
        do {
            return content(try await tools.call(name: name, arguments: arguments), isError: false)
        } catch is CancellationError {
            return nil
        } catch {
            return content(String(describing: error), isError: true)
        }
    }

    private static func content(_ text: String, isError: Bool) -> JSONValue {
        var result: [String: JSONValue] = [
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]
        if isError { result["isError"] = .bool(true) }
        return .object(result)
    }

    /// A cancelled request gets no response, as the protocol asks.
    private func complete(id: RequestID, result: JSONValue?) {
        running[id] = nil
        if let result { send(JSONRPCResponse(id: id, result: result)) }
    }

    private func send(_ response: JSONRPCResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        output(data + Data([0x0A]))
    }
}

/// Reads newline-separated messages. Bytes are split by hand because the system line
/// reader also breaks on U+2028, which is legal inside a JSON string.
func splitLines(_ bytes: some AsyncSequence<UInt8, any Error>, onLine: (Data) async -> Void) async throws {
    var line = Data()
    for try await byte in bytes {
        if byte == 0x0A {
            await onLine(line)
            line.removeAll(keepingCapacity: true)
        } else {
            line.append(byte)
        }
    }
    if !line.isEmpty { await onLine(line) }
}
