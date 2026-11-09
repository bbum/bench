import ArgumentParser
import Foundation
import Synchronization
import Testing
@testable import sal

private enum FakeTool: String {
    case echo, fail, hang, record, stubborn
}

private final class FakeTools: ToolCatalog {
    let order = Mutex<[String]>([])
    let (started, startedContinuation) = AsyncStream<String>.makeStream()
    let cancelled = Mutex<[String]>([])
    let (release, releaseContinuation) = AsyncStream<Void>.makeStream()

    var definitions: [JSONValue] { [.object(["name": .string("echo")])] }

    func hasTool(named name: String) -> Bool { FakeTool(rawValue: name) != nil }

    func call(name: String, arguments: JSONValue) async throws -> String {
        let tag = arguments["tag"]?.stringValue ?? name
        startedContinuation.yield(tag)
        switch FakeTool(rawValue: name)! {
        case .echo:
            return "echo \(tag)"
        case .fail:
            throw ToolInputError(description: "broke")
        case .hang:
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                cancelled.withLock { $0.append(tag) }
                throw error
            }
            return "never"
        case .stubborn:
            // Finishes normally however long ago it was cancelled.
            for await _ in release {}
            return "finished anyway"
        case .record:
            order.withLock { $0.append(tag) }
            return tag
        }
    }
}

extension FakeTools: @unchecked Sendable {}

private final class Lines: @unchecked Sendable {
    private let lines = Mutex<[Data]>([])

    func append(_ data: Data) { lines.withLock { $0.append(data) } }

    var values: [JSONValue] {
        lines.withLock { $0 }.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    func waitForCount(_ count: Int) async {
        for _ in 0..<2000 where values.count < count { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

private struct Harness {
    let tools = FakeTools()
    let lines = Lines()
    let server: MCPServer

    init() {
        let lines = lines
        server = MCPServer(tools: tools) { lines.append($0) }
    }

    func send(_ text: String) async { await server.receive(Data(text.utf8)) }

    func call(_ id: Int, _ tool: String, tag: String? = nil) async {
        let arguments = tag.map { #","arguments":{"tag":"\#($0)"}"# } ?? ""
        await send(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)"\#(arguments)}}"#)
    }

    func cancel(_ id: Int) async {
        await send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(id)}}"#)
    }

    func nextStart() async -> String? {
        var iterator = tools.started.makeAsyncIterator()
        return await iterator.next()
    }
}

private func text(_ response: JSONValue) -> String? {
    if case .array(let content)? = response["result"]?["content"] { content.first?["text"]?.stringValue } else { nil }
}

@Suite("MCP protocol")
struct MCPProtocolTests {
    @Test("Initialize agrees on the client's version")
    func initialize() async {
        let harness = Harness()
        await harness.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2030-01-01"}}"#)
        let reply = harness.lines.values[0]
        #expect(reply["id"] == .int(1))
        #expect(reply["jsonrpc"] == .string("2.0"))
        #expect(reply["result"]?["protocolVersion"] == .string("2030-01-01"))
        #expect(reply["result"]?["serverInfo"]?["name"] == .string("sal"))
        #expect(reply["result"]?["capabilities"]?["tools"] == .object([:]))
    }

    @Test("Initialize without a version offers a default")
    func initializeDefault() async {
        let harness = Harness()
        await harness.send(#"{"id":1,"method":"initialize"}"#)
        #expect(harness.lines.values[0]["result"]?["protocolVersion"] == .string("2024-11-05"))
    }

    @Test("Ping answers")
    func ping() async {
        let harness = Harness()
        await harness.send(#"{"id":"p","method":"ping"}"#)
        #expect(harness.lines.values[0]["id"] == .string("p"))
        #expect(harness.lines.values[0]["result"] == .object([:]))
    }

    @Test("Tools are listed")
    func list() async {
        let harness = Harness()
        await harness.send(#"{"id":1,"method":"tools/list"}"#)
        #expect(harness.lines.values[0]["result"]?["tools"] == .array(harness.tools.definitions))
    }

    @Test("Notifications and blank lines get no reply", arguments: [
        #"{"method":"notifications/initialized"}"#, #"{"method":"tools/list"}"#, "", "   ", "\r", "\t",
    ])
    func silent(line: String) async {
        let harness = Harness()
        await harness.send(line)
        #expect(harness.lines.values.isEmpty)
    }

    @Test("An unknown method is reported")
    func unknownMethod() async {
        let harness = Harness()
        await harness.send(#"{"id":4,"method":"nope"}"#)
        #expect(harness.lines.values[0]["error"]?["code"] == .int(JSONRPCError.methodNotFound))
    }

    @Test("Unreadable requests get a null-id parse error", arguments: [
        "garbage", "[1,2]", "{", #"{"id":1}"#, #"{"id":{},"method":"x"}"#, #"{"id":1.5,"method":"x"}"#, "42",
    ])
    func parseError(line: String) async {
        let harness = Harness()
        await harness.send(line)
        let reply = harness.lines.values[0]
        #expect(reply["error"]?["code"] == .int(JSONRPCError.parseError))
        #expect(reply["id"] == .null)
    }

    @Test("A bad tool call is reported as invalid params", arguments: [
        #"{"id":1,"method":"tools/call"}"#,
        #"{"id":1,"method":"tools/call","params":{}}"#,
        #"{"id":1,"method":"tools/call","params":{"name":"missing"}}"#,
        #"{"id":1,"method":"tools/call","params":{"name":7}}"#,
    ])
    func badToolCall(line: String) async {
        let harness = Harness()
        await harness.send(line)
        #expect(harness.lines.values[0]["error"]?["code"] == .int(JSONRPCError.invalidParams))
    }

    @Test("A tool's result comes back as text content")
    func result() async {
        let harness = Harness()
        await harness.call(1, "echo", tag: "hello")
        await harness.lines.waitForCount(1)
        let reply = harness.lines.values[0]
        #expect(text(reply) == "echo hello")
        #expect(reply["result"]?["isError"] == nil)
        #expect(reply["id"] == .int(1))
    }

    @Test("A failing tool is a readable result, not a protocol error")
    func failure() async {
        let harness = Harness()
        await harness.call(1, "fail")
        await harness.lines.waitForCount(1)
        let reply = harness.lines.values[0]
        #expect(text(reply) == "broke")
        #expect(reply["result"]?["isError"] == .bool(true))
        #expect(reply["error"] == nil)
    }

    @Test("Each response is one line")
    func oneLine() async {
        let collected = Mutex<Data>(Data())
        let server = MCPServer(tools: FakeTools()) { data in collected.withLock { $0.append(data) } }
        await server.receive(Data(#"{"id":1,"method":"ping"}"#.utf8))
        await server.receive(Data(#"{"id":2,"method":"ping"}"#.utf8))
        let bytes = collected.withLock { $0 }
        #expect(bytes.count { $0 == 0x0A } == 2)
        #expect(bytes.last == 0x0A)
    }

    @Test("Random bytes never trap and always leave the server working")
    func fuzz() async {
        var generator = SplitMix64(state: 0xFEED)
        let harness = Harness()
        let seeds = [
            #"{"id":1,"method":"tools/call","params":{"name":"echo"}}"#, #"{"id":1e308,"method":"ping"}"#,
            #"{"id":1,"method":"notifications/cancelled","params":{"requestId":1e400}}"#,
        ]
        for _ in 0..<3_000 {
            var bytes = Array(seeds.randomElement(using: &generator)!.utf8)
            for _ in 0..<Int.random(in: 0...6, using: &generator) {
                bytes[Int.random(in: bytes.indices, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            await harness.server.receive(Data(bytes))
        }
        await harness.server.finish()
        let before = harness.lines.values.count
        await harness.send(#"{"id":"last","method":"ping"}"#)
        #expect(harness.lines.values.count == before + 1)
    }
}

@Suite("MCP tool ordering and cancellation")
struct MCPConcurrencyTests {
    @Test("Calls run one at a time, in the order received")
    func serial() async {
        let harness = Harness()
        for index in 0..<50 { await harness.call(index, "record", tag: "\(index)") }
        await harness.lines.waitForCount(50)
        #expect(harness.tools.order.withLock { $0 } == (0..<50).map(String.init))
        #expect(harness.lines.values.compactMap { $0["id"] } == (0..<50).map { .int($0) })
    }

    @Test("Requests keep being answered while a tool runs")
    func staysResponsive() async {
        let harness = Harness()
        await harness.call(1, "hang")
        _ = await harness.nextStart()
        await harness.send(#"{"id":2,"method":"ping"}"#)
        #expect(harness.lines.values.map { $0["id"] } == [.int(2)])
        await harness.cancel(1)
        await harness.server.finish()
    }

    @Test("Cancelling a running tool stops it and sends no response")
    func cancelRunning() async {
        let harness = Harness()
        await harness.call(1, "hang", tag: "a")
        _ = await harness.nextStart()
        await harness.cancel(1)
        await harness.server.finish()
        #expect(harness.tools.cancelled.withLock { $0 } == ["a"])
        #expect(harness.lines.values.isEmpty)
    }

    @Test("A tool that finishes despite being cancelled still sends no response")
    func cancelledButFinished() async {
        let harness = Harness()
        await harness.call(1, "stubborn", tag: "a")
        _ = await harness.nextStart()
        await harness.cancel(1)
        harness.tools.releaseContinuation.finish()
        await harness.server.finish()
        #expect(harness.lines.values.isEmpty)
    }

    @Test("The next tool runs after a cancellation")
    func nextAfterCancel() async {
        let harness = Harness()
        await harness.call(1, "hang", tag: "a")
        _ = await harness.nextStart()
        await harness.call(2, "echo", tag: "b")
        await harness.cancel(1)
        await harness.lines.waitForCount(1)
        #expect(text(harness.lines.values[0]) == "echo b")
        #expect(harness.lines.values[0]["id"] == .int(2))
    }

    @Test("Cancelling a queued call means it never starts")
    func cancelQueued() async {
        let harness = Harness()
        await harness.call(1, "hang", tag: "a")
        _ = await harness.nextStart()
        await harness.call(2, "record", tag: "queued")
        await harness.cancel(2)
        await harness.cancel(1)
        await harness.server.finish()
        #expect(harness.tools.order.withLock { $0 }.isEmpty)
        #expect(harness.lines.values.isEmpty)
    }

    @Test("Cancelling something unknown is harmless", arguments: [
        #"{"method":"notifications/cancelled","params":{"requestId":99}}"#,
        #"{"method":"notifications/cancelled","params":{"requestId":"x"}}"#,
        #"{"method":"notifications/cancelled","params":{}}"#,
        #"{"method":"notifications/cancelled"}"#,
    ])
    func cancelUnknown(line: String) async {
        let harness = Harness()
        await harness.send(line)
        await harness.send(#"{"id":1,"method":"ping"}"#)
        #expect(harness.lines.values.count == 1)
    }

    @Test("A string request id can be cancelled")
    func stringID() async {
        let harness = Harness()
        await harness.send(#"{"id":"abc","method":"tools/call","params":{"name":"hang","arguments":{"tag":"s"}}}"#)
        _ = await harness.nextStart()
        await harness.send(#"{"method":"notifications/cancelled","params":{"requestId":"abc"}}"#)
        await harness.server.finish()
        #expect(harness.tools.cancelled.withLock { $0 } == ["s"])
    }

    @Test("Finishing cancels the running tool and waits for it")
    func finish() async {
        let harness = Harness()
        await harness.call(1, "hang", tag: "a")
        _ = await harness.nextStart()
        await harness.server.finish()
        #expect(harness.tools.cancelled.withLock { $0 } == ["a"])
    }

    @Test("A finished call's id can be reused")
    func reuse() async {
        let harness = Harness()
        await harness.call(1, "echo", tag: "a")
        await harness.lines.waitForCount(1)
        await harness.call(1, "echo", tag: "b")
        await harness.lines.waitForCount(2)
        #expect(harness.lines.values.map(text) == ["echo a", "echo b"])
    }
}

private func bytes(_ values: [UInt8]) -> AsyncThrowingStream<UInt8, any Error> {
    AsyncThrowingStream { continuation in
        values.forEach { continuation.yield($0) }
        continuation.finish()
    }
}

@Suite("MCP line splitting")
struct LineSplittingTests {
    private func split(_ text: String) async throws -> [String] {
        final class Box: @unchecked Sendable { var lines: [String] = [] }
        let box = Box()
        try await splitLines(bytes(Array(text.utf8))) { box.lines.append(String(decoding: $0, as: UTF8.self)) }
        return box.lines
    }

    @Test("Lines split on newlines only, and a final partial line is kept", arguments: [
        ("a\nb\n", ["a", "b"]), ("a\nb", ["a", "b"]), ("", []), ("\n", [""]), ("a\u{2028}b\n", ["a\u{2028}b"]),
        ("a\u{85}b\n", ["a\u{85}b"]), ("a\r\n", ["a\r"]),
    ])
    func split(text: String, expected: [String]) async throws {
        #expect(try await split(text) == expected)
    }
}

@Suite("MCP arguments")
struct MCPArgumentTests {
    private let allowed: Set<String> = ["a", "b_c", "d", "e", "f"]

    @Test("Scalars become flags with attached values, sorted")
    func scalars() throws {
        let line = try commandLine(
            from: .object(["e": .string("x"), "a": .int(1), "b_c": .double(1.5)]), allowed: allowed)
        #expect(line == ["--a=1", "--b-c=1.5", "--e=x"])
    }

    @Test("Booleans are bare flags, or left out")
    func booleans() throws {
        #expect(try commandLine(from: .object(["a": .bool(true), "d": .bool(false)]), allowed: allowed) == ["--a"])
    }

    @Test("Arrays repeat the flag")
    func arrays() throws {
        #expect(try commandLine(from: .object(["a": .array([.string("x"), .int(2)])]), allowed: allowed) == ["--a=x", "--a=2"])
    }

    @Test("A value starting with dashes stays a value")
    func hostileValue() throws {
        #expect(try commandLine(from: .object(["a": .string("--help")]), allowed: allowed) == ["--a=--help"])
    }

    @Test("Unknown keys, including ones that would be real flags, are refused", arguments: ["help", "version", "zzz", "--a"])
    func unknown(key: String) {
        #expect(throws: ToolInputError.self) { try commandLine(from: .object([key: .int(1)]), allowed: allowed) }
    }

    @Test("Ignored keys are skipped")
    func ignored() throws {
        #expect(try commandLine(from: .object(["a": .int(1), "zzz": .int(1)]), allowed: allowed, ignoring: ["zzz"]) == ["--a=1"])
    }

    @Test("Wrong value types are refused", arguments: [
        JSONValue.null, .object([:]), .array([.null]), .array([.object([:])]), .array([.array([])]),
    ])
    func wrongType(value: JSONValue) {
        #expect(throws: ToolInputError.self) { try commandLine(from: .object(["a": value]), allowed: allowed) }
    }

    @Test("Arguments must be an object", arguments: [JSONValue.null, .int(1), .array([])])
    func notObject(value: JSONValue) {
        #expect(throws: ToolInputError.self) { try commandLine(from: value, allowed: allowed) }
    }
}

private func toolSchema(_ name: String) throws -> JSONValue {
    try #require(toolDefinitions.first { $0["name"]?.stringValue == name }?["inputSchema"])
}

private func keys(_ schema: JSONValue?) -> Set<String> {
    if case .object(let properties)? = schema?["properties"] { Set(properties.keys) } else { [] }
}

private func flag(_ key: String) -> String { "--" + key.replacingOccurrences(of: "_", with: "-") }

@Suite("MCP tool definitions")
struct MCPToolDefinitionTests {
    private let tools = SalTools()

    @Test("The tool list is small")
    func size() throws {
        let data = try JSONEncoder().encode(JSONValue.array(toolDefinitions))
        #expect(data.count < 20_000, "\(data.count) bytes, against 168 KB for Saleae's server")
    }

    @Test("There are exactly four tools, each described, with no top-level oneOf", arguments: ["status", "capture", "decode", "identify"])
    func shape(name: String) throws {
        let schema = try toolSchema(name)
        #expect(tools.hasTool(named: name))
        #expect(schema["type"] == .string("object"))
        #expect(schema["additionalProperties"] == .bool(false))
        // Claude's API rejects these at the top level of a tool schema.
        #expect(schema["oneOf"] == nil && schema["anyOf"] == nil && schema["allOf"] == nil)
    }

    @Test("Tool names are exact")
    func names() {
        #expect(toolDefinitions.compactMap { $0["name"]?.stringValue } == ["status", "capture", "decode", "identify"])
        #expect(!tools.hasTool(named: "other"))
    }

    @Test("Every capture and identify property is a real flag", arguments: [("capture", ["capture"]), ("identify", ["identify"])])
    func parity(tool: String, command: [String]) throws {
        let help = Sal.helpMessage(for: tool == "capture" ? CaptureCommand.self : IdentifyCommand.self, columns: 400)
        for key in keys(try toolSchema(tool)) {
            #expect(help.contains(flag(key)), "\(key)")
        }
    }

    @Test("Every decode and bus property is a real flag")
    func decodeParity() throws {
        let schema = try toolSchema("decode")
        let help = Sal.helpMessage(for: UARTCommand.self, columns: 400)
        for key in keys(schema).subtracting(["bus"]) {
            #expect(help.contains(flag(key)), "\(key)")
        }

        guard case .array(let buses)? = schema["properties"]?["bus"]?["oneOf"] else {
            Issue.record("bus is not a oneOf")
            return
        }
        #expect(buses.count == 3)
        let commands: [(String, any ParsableCommand.Type)] = [("uart", UARTCommand.self), ("spi", SPICommand.self), ("i2c", I2CCommand.self)]
        for (index, (kind, command)) in commands.enumerated() {
            #expect(buses[index]["properties"]?["protocol"]?["const"] == .string(kind))
            let help = Sal.helpMessage(for: command, columns: 400)
            for key in keys(buses[index]).subtracting(["protocol"]) {
                #expect(help.contains(flag(key)), "\(kind) \(key)")
            }
        }
    }

    @Test("Enums match what the command line accepts")
    func enums() throws {
        guard case .array(let buses)? = try toolSchema("decode")["properties"]?["bus"]?["oneOf"] else {
            Issue.record("bus is not a oneOf")
            return
        }
        func values(_ field: String) -> JSONValue? { buses[0]["properties"]?[field]?["enum"] }
        #expect(values("parity") == .array(Parity.allCases.map { .string($0.rawValue) }))
        #expect(values("stop") == .array(StopBits.allCases.map { .string($0.rawValue) }))
        #expect(values("order") == .array(BitOrder.allCases.map { .string($0.rawValue) }))
        #expect(values("mode") == .array(UARTMode.allCases.map { .string($0.rawValue) }))
        #expect(try toolSchema("decode")["properties"]?["radix"]?["enum"] == .array(Radix.allCases.map { .string($0.rawValue) }))
    }

    @Test("Required fields are declared", arguments: [
        (0, ["protocol", "channel", "baud"]), (1, ["protocol", "clock"]), (2, ["protocol", "sda", "scl"]),
    ])
    func required(index: Int, expected: [String]) throws {
        guard case .array(let buses)? = try toolSchema("decode")["properties"]?["bus"]?["oneOf"] else {
            Issue.record("bus is not a oneOf")
            return
        }
        #expect(buses[index]["required"] == .array(expected.map(JSONValue.string)))
        #expect(try toolSchema("decode")["required"] == .array([.string("bus")]))
    }
}

@Suite("MCP tool input errors")
struct MCPToolInputTests {
    private let tools = SalTools()

    private func message(_ name: String, _ arguments: JSONValue) async -> String {
        do {
            return "no error: \(try await tools.call(name: name, arguments: arguments))"
        } catch {
            return String(describing: error)
        }
    }

    private let i2cBus: JSONValue = .object(["protocol": .string("i2c"), "sda": .int(6), "scl": .int(7)])

    @Test("Decoded rows default to a limit that keeps replies small, and an explicit one wins")
    func rowLimit() throws {
        let line = try decodeCommandLine(.object(["bus": i2cBus]))
        #expect(line == ["decode", "i2c", "--scl=7", "--sda=6", "--limit=200"])
        let explicit = try decodeCommandLine(.object(["bus": i2cBus, "limit": .int(5)]))
        #expect(explicit.filter { $0.hasPrefix("--limit") } == ["--limit=5"])
    }

    @Test("A manual capture must have an end, on every capturing tool", arguments: ["capture", "identify", "decode"])
    func manual(name: String) async {
        var arguments: [String: JSONValue] = ["manual": .bool(true)]
        if name == "decode" { arguments["bus"] = i2cBus }
        #expect(await message(name, .object(arguments)).contains("needs duration"))
    }

    @Test("decode requires a bus with a known protocol", arguments: [
        (JSONValue.object([:]), "needs bus"),
        (.object(["bus": .object([:])]), "needs bus"),
        (.object(["bus": .object(["protocol": .string("can")])]), "Unknown protocol"),
        (.object(["bus": .object(["protocol": .int(1)])]), "needs bus"),
    ])
    func bus(arguments: JSONValue, expected: String) async {
        #expect(await message("decode", arguments).contains(expected))
    }

    @Test("A bus field for another protocol is refused")
    func wrongBusField() async {
        let bus: JSONValue = .object(["protocol": .string("i2c"), "sda": .int(1), "scl": .int(2), "baud": .int(9600)])
        #expect(await message("decode", .object(["bus": bus])).contains("Unknown argument: baud"))
    }

    @Test("A missing bus field reports what is missing")
    func missing() async {
        let bus: JSONValue = .object(["protocol": .string("uart"), "channel": .int(1)])
        #expect(await message("decode", .object(["bus": bus])).contains("--baud"))
    }

    @Test("Command line validation reaches the caller")
    func validation() async {
        let bus: JSONValue = .object(["protocol": .string("i2c"), "sda": .int(1), "scl": .int(1)])
        #expect(await message("decode", .object(["bus": bus])).contains("distinct"))
        #expect(await message("capture", .object(["duration": .int(0)])).contains("positive"))
        #expect(await message("capture", .object(["channels": .string("none")])).contains("needs --analog"))
    }

    @Test("Arguments of another tool are refused", arguments: [
        ("status", "duration"), ("capture", "radix"), ("identify", "analog"), ("decode", "analog"), ("decode", "no_confirm"),
    ])
    func wrongTool(name: String, key: String) async {
        var arguments: [String: JSONValue] = [key: .string("x")]
        if name == "decode" { arguments["bus"] = i2cBus }
        #expect(await message(name, .object(arguments)).contains("Unknown argument: \(key)"))
    }

    @Test("An unreachable server fails the tool promptly", arguments: ["status", "capture", "identify"])
    func unreachable(name: String) async {
        let result = await message(name, .object(["host": .string("127.0.0.1"), "port": .int(1)]))
        #expect(!result.hasPrefix("no error"))
    }

    @Test("Unknown tools are refused")
    func unknownTool() async {
        #expect(await message("other", .object([:])).contains("Unknown tool"))
    }
}
