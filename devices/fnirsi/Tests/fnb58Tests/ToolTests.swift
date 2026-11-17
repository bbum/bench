import Foundation
import Testing
@testable import fnb58

private func tools(_ transport: FakeTransport = FakeTransport()) -> FNB58Tools {
    FNB58Tools(session: MeterSession(
        transport: transport, directory: temporaryDirectory(), stallLimit: .milliseconds(300), keepaliveInterval: .milliseconds(50),
        quiet: .milliseconds(40), drainLimit: .milliseconds(600), restartAfter: .milliseconds(100)))
}

private func decode(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite struct ToolTests {
    @Test func everyToolHasASchemaWithoutTopLevelOneOf() {
        let names = toolDefinitions.compactMap { $0["name"]?.stringValue }
        #expect(names == ["status", "capture", "start_capture", "mark", "stop_capture", "window_stats", "raw_dump"])
        for definition in toolDefinitions {
            #expect(definition["inputSchema"]?["type"]?.stringValue == "object")
            #expect(definition["inputSchema"]?["oneOf"] == nil)
            let text = definition["description"]?.stringValue ?? ""
            #expect(text.count > 20, "\(definition)")
        }
        #expect(allowedKeys("capture") == ["seconds", "label"])
        #expect(allowedKeys("nope").isEmpty)
    }

    @Test func rejectsBadArguments() async {
        let t = tools()
        await #expect(throws: ToolInputError.self) { try await t.call(name: "status", arguments: .object(["x": .int(1)])) }
        await #expect(throws: ToolInputError.self) { try await t.call(name: "status", arguments: .array([])) }
        await #expect(throws: ToolInputError.self) { try await t.call(name: "capture", arguments: .object([:])) }
        await #expect(throws: ToolInputError.self) { try await t.call(name: "capture", arguments: .object(["seconds": .string("5")])) }
        await #expect(throws: ToolInputError.self) { try await t.call(name: "capture", arguments: .object(["seconds": .int(1), "label": .int(3)])) }
        await #expect(throws: ToolInputError.self) { try await t.call(name: "mark", arguments: .object(["note": .string("")])) }
        await #expect(throws: ToolInputError.self) { try await t.call(name: "raw_dump", arguments: .object(["limit": .double(1.5)])) }
        await #expect(throws: ToolInputError.self) { try await t.call(name: "raw_dump", arguments: .object(["limit": .int(-1)])) }
        await #expect(throws: ToolInputError.self) { try await t.call(name: "bogus", arguments: .object([:])) }
    }

    @Test func captureThenWindow() async throws {
        let t = tools()
        let summary = try decode(try await t.call(name: "capture", arguments: .object(["seconds": .double(0.4), "label": .string("burst")])))
        #expect(summary["ended"]?.stringValue == "completed")
        #expect(summary["stats"]?["energy_mWh"] != nil)
        #expect(summary["stats"]?["current_A"]?["p99"] != nil)
        let window = try decode(try await t.call(name: "window_stats", arguments: .object(["from_s": .double(0.1), "to_s": .double(0.2)])))
        #expect(window["stats"]?["samples"] == .int(10))
        #expect(window["csv"] == summary["csv"])
    }

    @Test func unplugIsAFailedCallCarryingTheSummary() async throws {
        let t = tools(FakeTransport(makeLink: { FakeLink(stopAfter: (2, true)) }))
        do {
            _ = try await t.call(name: "capture", arguments: .object(["seconds": .int(5)]))
            Issue.record("expected failure")
        } catch let failure as CaptureFailure {
            #expect(failure.description.contains("disconnected"))
            #expect(failure.description.contains("\"samples\":4"))
        }
    }

    @Test func startMarkStopThroughTools() async throws {
        let t = tools(FakeTransport(makeLink: { FakeLink(interval: .milliseconds(10)) }))
        _ = try await t.call(name: "start_capture", arguments: .object(["label": .string("p")]))
        try await Task.sleep(for: .milliseconds(80))
        _ = try await t.call(name: "mark", arguments: .object(["note": .string("print sent")]))
        try await Task.sleep(for: .milliseconds(80))
        let summary = try decode(try await t.call(name: "stop_capture", arguments: .object([:])))
        #expect(summary["marks"]?.arrayCount == 1)
    }

    @Test func windowStatsWithoutAnyCapture() async throws {
        await #expect(throws: (any Error).self) { try await tools().call(name: "window_stats", arguments: .object([:])) }
    }

    /// Through the server, as a client would see it.
    @Test func serverRoundTrip() async throws {
        let output = Output()
        let server = MCPServer(tools: tools()) { output.append($0) }
        await server.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        await server.receive(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"capture","arguments":{"seconds":0.2}}}"#.utf8))
        // finish() cancels what is running, and a cancelled call gets no reply, so wait.
        for _ in 0..<200 where output.lines.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        await server.finish()
        let lines = output.lines
        #expect(lines.count == 2)
        #expect(lines.first?.contains("start_capture") == true)
        #expect(lines.last?.contains("completed") == true)
    }
}

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.withLock { data.append(more) } }
    var lines: [String] { lock.withLock { String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) } }
}

extension JSONValue {
    var arrayCount: Int? { if case .array(let values) = self { values.count } else { nil } }
}
