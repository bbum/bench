import ArgumentParser
import Foundation

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as an MCP server over stdio.",
        discussion: "Tools: status, capture, decode, identify. Logic 2 must be running with its automation server on."
    )

    func run() async throws {
        let server = MCPServer(tools: SalTools()) { data in
            FileHandle.standardOutput.write(data)
        }
        try await splitLines(FileHandle.standardInput.bytes) { line in
            await server.receive(line)
        }
        await server.finish()
    }
}
