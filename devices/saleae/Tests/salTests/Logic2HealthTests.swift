import ArgumentParser
import Darwin
import Foundation
import GRPCCore
import Synchronization
import Testing
@testable import sal

/// A port that accepts connections and never says a word, which is how a hung Logic 2 looks.
private final class SilentServer {
    let descriptor: Int32
    let port: Int

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(listener, generic, length) == 0 && listen(listener, 8) == 0
                    && getsockname(listener, generic, &length) == 0
            }
        }
        guard bound else {
            close(listener)
            throw TestgenPortError(description: "could not listen")
        }
        descriptor = listener
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit { close(descriptor) }
}

/// A port nothing listens on.
private func closedPort() throws -> Int {
    try SilentServer().port
}

private func spawn(_ script: String) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    try process.run()
    return process
}

private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite("Telling a dead Logic 2 from a hung one")
struct Logic2HealthTests {
    @Test("A port that accepts and never answers is reported as hung, promptly")
    func hung() async throws {
        let server = try SilentServer()
        await #expect(throws: Logic2Error.notAnswering(host: "127.0.0.1", port: server.port, seconds: 0.3)) {
            try await withLogic2(Logic2Endpoint(port: server.port), probeSeconds: 0.3) { _ in
                Issue.record("work was given to a Logic 2 that never answered")
            }
        }
    }

    @Test("The first question carries its own time limit")
    func firstQuestionIsLimited() async throws {
        try await requireAnswer(from: Logic2Endpoint(), within: 2) { options in
            #expect(options.timeout == .seconds(2))
        }
    }

    @Test("A closed port is reported as not running")
    func notRunning() async throws {
        let port = try closedPort()
        await #expect(throws: Logic2Error.notRunning(host: "127.0.0.1", port: port)) {
            try await withLogic2(Logic2Endpoint(port: port)) { _ in Issue.record("work ran with nothing listening") }
        }
    }

    @Test("Nothing is started unless the endpoint asks")
    func noLaunchByDefault() async throws {
        let port = try closedPort()
        let launches = Mutex(0)
        await #expect(throws: Logic2Error.notRunning(host: "127.0.0.1", port: port)) {
            try await withLogic2(Logic2Endpoint(port: port), launch: { _ in launches.withLock { $0 += 1 } }) { _ in }
        }
        #expect(launches.withLock { $0 } == 0)
    }

    @Test("An endpoint that asks is started once, on its own port, and connected to again")
    func launchesOnce() async throws {
        let port = try closedPort()
        let launched = Mutex<[Int]>([])
        await #expect(throws: Logic2Error.notRunning(host: "127.0.0.1", port: port)) {
            try await withLogic2(
                Logic2Endpoint(port: port, launchIfNeeded: true), launch: { port in launched.withLock { $0.append(port) } }
            ) { _ in }
        }
        #expect(launched.withLock { $0 } == [port])
    }

    @Test("A hung Logic 2 is reported, never started over")
    func hungIsNotRelaunched() async throws {
        let server = try SilentServer()
        let launches = Mutex(0)
        await #expect(throws: Logic2Error.notAnswering(host: "127.0.0.1", port: server.port, seconds: 0.3)) {
            try await withLogic2(
                Logic2Endpoint(port: server.port, launchIfNeeded: true), probeSeconds: 0.3,
                launch: { _ in launches.withLock { $0 += 1 } }
            ) { _ in }
        }
        #expect(launches.withLock { $0 } == 0)
    }

    @Test("A failed start is the error reported")
    func launchFails() async throws {
        let port = try closedPort()
        await #expect(throws: Logic2Error.notInstalled) {
            try await withLogic2(
                Logic2Endpoint(port: port, launchIfNeeded: true), launch: { _ in throw Logic2Error.notInstalled }
            ) { _ in }
        }
    }

    @Test("SAL_NO_LAUNCH keeps commands from starting Logic 2")
    func environmentForbids() async {
        await #expect(throws: Logic2Error.notRunning(host: "127.0.0.1", port: 9)) {
            try await startLogic2IfAllowed(port: 9, environment: ["SAL_NO_LAUNCH": "1"])
        }
    }

    @Test("Only this machine's Logic 2 may be started", arguments: [
        ("127.0.0.1", true, true), ("127.0.0.1", false, false), ("10.0.0.9", true, false), ("10.0.0.9", false, false),
    ])
    func mayLaunch(host: String, asked: Bool, expected: Bool) {
        #expect(Logic2Endpoint(host: host, launchIfNeeded: asked).mayLaunch == expected)
    }

    @Test("The first question names what its failure means")
    func firstQuestion() async {
        let endpoint = Logic2Endpoint(host: "h", port: 7)
        await #expect(throws: Logic2Error.notRunning(host: "h", port: 7)) {
            try await requireAnswer(from: endpoint, within: 2) { _ in throw RPCError(code: .unavailable, message: "") }
        }
        await #expect(throws: Logic2Error.notAnswering(host: "h", port: 7, seconds: 2)) {
            try await requireAnswer(from: endpoint, within: 2) { _ in throw RPCError(code: .deadlineExceeded, message: "") }
        }
        await #expect(throws: RPCError.self) {
            try await requireAnswer(from: endpoint, within: 2) { _ in throw RPCError(code: .unimplemented, message: "") }
        }
        await #expect(throws: CancellationError.self) {
            try await requireAnswer(from: endpoint, within: 2) { _ in throw CancellationError() }
        }
    }

    @Test("A failure after the first answer is named differently")
    func laterFailures() {
        let endpoint = Logic2Endpoint(host: "h", port: 7)
        #expect(errorAfterAnswering(RPCError(code: .unavailable, message: ""), endpoint) as? Logic2Error
            == .connectionLost(host: "h", port: 7))
        #expect(errorAfterAnswering(RPCError(code: .deadlineExceeded, message: ""), endpoint) as? Logic2Error == .stalled)
        let refused = errorAfterAnswering(RPCError(code: .invalidArgument, message: "bad rate"), endpoint)
        #expect((refused as? RPCError)?.message == "bad rate")
    }

    @Test("Every error says what to do next")
    func messages() {
        #expect(Logic2Error.notRunning(host: "h", port: 7).description.contains("h:7"))
        #expect(Logic2Error.notRunning(host: "h", port: 7).description.contains("`sal app start`"))
        let hung = Logic2Error.notAnswering(host: "h", port: 7, seconds: 5).description
        #expect(hung.contains("within 5 seconds") && hung.contains("`sal app restart`"))
        #expect(Logic2Error.notAnswering(host: "h", port: 7, seconds: 0.5).description.contains("within 0.5 seconds"))
        #expect(Logic2Error.stalled.description.contains("`sal app restart`"))
        #expect(Logic2Error.connectionLost(host: "h", port: 7).description.contains("quit or crashed"))
        #expect(Logic2Error.runningWithoutAutomation(port: 7).description.contains("Settings > Automation"))
        #expect(Logic2Error.didNotStart(port: 7, seconds: 40).description.contains("port 7 within 40 seconds"))
        #expect(Logic2Error.notInstalled.description.contains("saleae.com"))
    }

    @Test("Calls that change state get 30 seconds and calls that move data get 5 minutes")
    func callLimits() {
        #expect(CallOptions.control.timeout == .seconds(30))
        #expect(CallOptions.data.timeout == .seconds(300))
        #expect(CallOptions.limited(to: 0.5).timeout == .milliseconds(500))
    }
}

@Suite("Stopping processes")
struct ProcessControlTests {
    @Test("A process that quits when asked is not killed")
    func quits() async throws {
        let process = try spawn("exec sleep 60")
        let pid = process.processIdentifier
        #expect(isRunning(pid))
        #expect((footprintBytes(pid) ?? 0) > 0)
        #expect(await stopProcess(pid, graceSeconds: 5) == .quit)
        #expect(await eventually { !process.isRunning })
        #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM)
    }

    @Test("A process that ignores the request is killed after the grace period")
    func stubborn() async throws {
        let process = try spawn("trap '' TERM; while :; do sleep 1; done")
        let pid = process.processIdentifier
        // The trap has to be in place first, or the request to quit would simply work.
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        #expect(await stopProcess(pid, graceSeconds: 0.3) == .killed)
        #expect(ContinuousClock.now - started >= .milliseconds(300))
        #expect(await eventually { !process.isRunning })
        #expect(process.terminationStatus == SIGKILL)
    }

    @Test("Descendants left behind are killed too")
    func orphans() async throws {
        let process = try spawn("sleep 60 & sleep 60 & wait")
        let pid = process.processIdentifier
        #expect(await eventually { childProcesses(of: pid).count == 2 })
        let tree = processTree(pid)
        #expect(tree.first == pid && tree.count == 3)
        #expect(await stopProcess(pid, graceSeconds: 5) == .quit)
        #expect(await eventually { !tree.contains(where: isRunning) })
    }

    @Test("A process that is not there is reported as such")
    func absent() async throws {
        let process = try spawn("exit 0")
        process.waitUntilExit()
        #expect(await stopProcess(process.processIdentifier, graceSeconds: 1) == .notRunning)
        #expect(footprintBytes(process.processIdentifier) == nil)
    }
}

@Suite("Looking after Logic 2")
struct Logic2CareTests {
    @Test("Memory at the limit asks for a restart, and just under does not")
    func memoryLimit() {
        let over = Logic2Health(pid: 7, memoryBytes: logic2RestartBytes, uptimeSeconds: 0)
        #expect(over.needsRestart)
        #expect(over.warning?.contains("3.0 GB") == true && over.warning?.contains("`sal app restart`") == true)
        let under = Logic2Health(pid: 7, memoryBytes: logic2RestartBytes - 1, uptimeSeconds: 0)
        #expect(!under.needsRestart && under.warning == nil)
        #expect(logic2RestartBytes == 3 * 1_073_741_824)
    }

    @Test("The process line gives memory in megabytes and age in minutes, then hours", arguments: [
        (300, "Logic 2 process 7: 512 MB, up 5 min"), (7199, "Logic 2 process 7: 512 MB, up 119 min"),
        (7200, "Logic 2 process 7: 512 MB, up 2 h"), (0, "Logic 2 process 7: 512 MB, up 0 min"),
    ])
    func processLine(uptime: Int, expected: String) {
        #expect(Logic2Health(pid: 7, memoryBytes: 512 * 1_048_576, uptimeSeconds: uptime).line == expected)
    }

    @Test("Status adds the process, with its warning when there is one")
    func statusProcessLines() {
        #expect(processLines(nil).isEmpty)
        #expect(processLines(Logic2Health(pid: 7, memoryBytes: 1_048_576, uptimeSeconds: 60)) == ["Logic 2 process 7: 1 MB, up 1 min"])
        let bloated = processLines(Logic2Health(pid: 7, memoryBytes: 4 * 1_073_741_824, uptimeSeconds: 60))
        #expect(bloated.count == 2 && bloated[1].hasPrefix("Warning: Logic 2 has grown to 4.0 GB"))
    }

    @Test("A restart is needed when Logic 2 is silent or bloated, and not otherwise")
    func restartNeeded() {
        let healthy = Logic2Health(pid: 7, memoryBytes: 1, uptimeSeconds: 0)
        let bloated = Logic2Health(pid: 7, memoryBytes: logic2RestartBytes, uptimeSeconds: 0)
        #expect(!restartIsNeeded(health: healthy, answering: true))
        #expect(restartIsNeeded(health: bloated, answering: true))
        #expect(restartIsNeeded(health: healthy, answering: false))
        #expect(restartIsNeeded(health: nil, answering: false))
        #expect(!restartIsNeeded(health: nil, answering: true))
    }

    @Test("Stopping says what happened")
    func stopMessages() {
        #expect(stopMessage(.notRunning) == "Logic 2 was not running")
        #expect(stopMessage(.quit) == "Logic 2 quit")
        #expect(stopMessage(.killed) == "Logic 2 would not quit and was killed")
    }

    @Test("Commands start Logic 2 unless told not to, and the library never does unasked")
    func launchOption() throws {
        #expect(try Logic2Options.parse([]).endpoint.launchIfNeeded)
        #expect(try !Logic2Options.parse(["--no-launch"]).endpoint.launchIfNeeded)
        #expect(!Logic2Endpoint().launchIfNeeded)
    }

    @Test("The app commands parse")
    func appCommands() throws {
        let restart = try #require(try Sal.parseAsRoot(["app", "restart", "--if-needed", "--port", "10431"]) as? AppCommand.Restart)
        #expect(restart.ifNeeded && restart.port == 10431)
        let plain = try #require(try Sal.parseAsRoot(["app", "restart"]) as? AppCommand.Restart)
        #expect(!plain.ifNeeded && plain.port == 10430)
        #expect(try Sal.parseAsRoot(["app", "start"]) is AppCommand.Start)
        #expect(try Sal.parseAsRoot(["app", "stop"]) is AppCommand.Stop)
    }

    @Test("A tool server told not to start Logic 2 passes that on, and one that may says nothing")
    func toolsCarryLaunchSetting() {
        let quiet = SalTools(endpoint: Logic2Endpoint(host: "127.0.0.1", port: 9))
        #expect(quiet.withDefaultEndpoint(.object([:]))["no_launch"] == .bool(true))
        let managing = SalTools(endpoint: Logic2Endpoint(host: "127.0.0.1", port: 9, launchIfNeeded: true))
        #expect(managing.withDefaultEndpoint(.object([:]))["no_launch"] == nil)
    }
}
