import ArgumentParser
import Foundation

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as an MCP server over stdio.",
        discussion: "Tools: status, capture, decode, identify, analyze and timeline. Logic 2 is started if it is not running. --host and --port set where tools connect, unless a call says otherwise."
    )

    @OptionGroup var logic2: Logic2Options

    func run() async throws {
        let server = MCPServer(tools: SalTools(endpoint: logic2.endpoint)) { data in
            FileHandle.standardOutput.write(data)
        }
        try await splitLines(FileHandle.standardInput.bytes) { line in
            await server.receive(line)
        }
        await server.finish()
    }
}
