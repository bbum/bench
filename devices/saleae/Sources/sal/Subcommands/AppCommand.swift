import ArgumentParser
import Foundation

/// Whether Logic 2 should be restarted before more work is given to it.
func restartIsNeeded(health: Logic2Health?, answering: Bool) -> Bool {
    !answering || health?.needsRestart == true
}

func stopMessage(_ result: StopResult) -> String {
    switch result {
    case .notRunning: "Logic 2 was not running"
    case .quit: "Logic 2 quit"
    case .killed: "Logic 2 would not quit and was killed"
    }
}

private func isAnswering(port: Int) async throws -> Bool {
    do {
        try await withLogic2(Logic2Endpoint(port: port)) { _ in }
        return true
    } catch is Logic2Error {
        return false
    }
}

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Start, stop or restart Logic 2 on this machine.",
        discussion: """
            Other commands start Logic 2 by themselves when it is not running. Restart is for when it \
            hangs or has grown too large, which long runs of captures bring on.
            """,
        subcommands: [Start.self, Stop.self, Restart.self]
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start Logic 2 with its automation server on, unless it is already answering.")

        @Option(help: "Automation server port.")
        var port = 10430

        func run() async throws {
            if try await !isAnswering(port: port) { try await startLogic2(port: port) }
            processLines(logic2Health()).forEach { print($0) }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Quit Logic 2, killing it if it will not go. Captures open in it are lost.")

        func run() async throws {
            print(stopMessage(await stopLogic2()))
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Quit Logic 2 and start it again. Captures open in it are lost.")

        @Option(help: "Automation server port.")
        var port = 10430

        @Flag(help: "Only if Logic 2 is not answering or has grown too large.")
        var ifNeeded = false

        func run() async throws {
            if ifNeeded {
                let answering = try await isAnswering(port: port)
                guard restartIsNeeded(health: logic2Health(), answering: answering) else {
                    print("Logic 2 is healthy")
                    return
                }
            }
            print(stopMessage(await stopLogic2()))
            try await startLogic2(port: port)
            processLines(logic2Health()).forEach { print($0) }
        }
    }
}
