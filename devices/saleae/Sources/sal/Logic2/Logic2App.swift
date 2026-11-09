import AppKit
import Darwin

let logic2BundleIdentifier = "com.saleae.saleae"

// MARK: Processes

/// Whether a process is still going. One that has exited and not yet been collected by
/// its parent still has a process ID, and does not count.
func isRunning(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 || errno == EPERM else { return false }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return true }
    return info.pbi_status != UInt32(SZOMB)
}

func childProcesses(of pid: pid_t) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 4096)
    let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    return count > 0 ? Array(buffer.prefix(Int(count))) : []
}

/// The process and everything descended from it, the process itself first.
func processTree(_ root: pid_t) -> [pid_t] {
    var tree = [root]
    var next = 0
    while next < tree.count {
        tree += childProcesses(of: tree[next]).filter { !tree.contains($0) }
        next += 1
    }
    return tree
}

/// Memory the system charges to a process, which is what Activity Monitor shows.
func footprintBytes(_ pid: pid_t) -> UInt64? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? info.ri_phys_footprint : nil
}

private func allGone(_ pids: [pid_t], within seconds: Double) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while pids.contains(where: isRunning) {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

enum StopResult: Equatable, Sendable {
    case notRunning
    case quit
    /// It ignored the request to quit, as a hung process does.
    case killed
}

/// Asks a process to quit, kills it if it has not gone within `graceSeconds`, and then
/// kills any descendant it left behind.
func stopProcess(_ pid: pid_t, graceSeconds: Double) async -> StopResult {
    guard isRunning(pid) else { return .notRunning }
    let tree = processTree(pid)
    kill(pid, SIGTERM)
    var result = StopResult.quit
    if !(await allGone([pid], within: graceSeconds)) {
        kill(pid, SIGKILL)
        result = .killed
        _ = await allGone([pid], within: 5)
    }
    // Helpers follow the main process down on their own. These are the ones that did not.
    if !(await allGone(tree, within: 2)) {
        for leftover in tree where isRunning(leftover) { kill(leftover, SIGKILL) }
        _ = await allGone(tree, within: 5)
    }
    return result
}

// MARK: Logic 2

/// Total memory at which Logic 2 is due a restart. It stopped answering at 5.8 GB after
/// 518 captures, having started at 0.4. Ordinary work swells it to about 2 GB for a while.
let logic2RestartBytes: UInt64 = 3 << 30

struct Logic2Health: Encodable, Equatable, Sendable {
    var pid: Int32
    var memoryMegabytes: Int
    var uptimeSeconds: Int
    var warning: String?

    init(pid: Int32, memoryBytes: UInt64, uptimeSeconds: Int) {
        self.pid = pid
        self.memoryMegabytes = Int(memoryBytes / 1_048_576)
        self.uptimeSeconds = uptimeSeconds
        if memoryBytes >= logic2RestartBytes {
            warning = String(
                format: "Logic 2 has grown to %.1f GB and hangs somewhere past 5. Restart it with `sal app restart`.",
                Double(memoryBytes) / 1_073_741_824)
        }
    }

    var needsRestart: Bool { warning != nil }

    var line: String {
        let minutes = uptimeSeconds / 60
        let age = minutes >= 120 ? "\(minutes / 60) h" : "\(minutes) min"
        return "Logic 2 process \(pid): \(memoryMegabytes) MB, up \(age)"
    }
}

func runningLogic2() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: logic2BundleIdentifier)
}

/// How the Logic 2 on this machine is doing, or nil if it is not running.
func logic2Health() -> Logic2Health? {
    guard let app = runningLogic2().first else { return nil }
    let pid = app.processIdentifier
    let bytes = processTree(pid).reduce(UInt64(0)) { $0 + (footprintBytes($1) ?? 0) }
    let uptime = app.launchDate.map { Int(-$0.timeIntervalSinceNow) } ?? 0
    return Logic2Health(pid: pid, memoryBytes: bytes, uptimeSeconds: max(0, uptime))
}

/// Quits every running Logic 2, killing any that will not go.
func stopLogic2(graceSeconds: Double = 5) async -> StopResult {
    var result = StopResult.notRunning
    for app in runningLogic2() {
        let stopped = await stopProcess(app.processIdentifier, graceSeconds: graceSeconds)
        if stopped == .killed || result == .notRunning { result = stopped }
    }
    return result
}

/// How long Logic 2 gets to start answering, and then to find its device.
let logic2StartSeconds = 40.0
let logic2DeviceSeconds = 8.0

/// Starts Logic 2 with its automation server on, in the background, and returns once it
/// answers. Waits a little for a device as well, because a capture started before the
/// device is found fails.
func startLogic2(port: Int) async throws {
    guard runningLogic2().isEmpty else { throw Logic2Error.runningWithoutAutomation(port: port) }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: logic2BundleIdentifier) else {
        throw Logic2Error.notInstalled
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = ["--automation", "--automationPort", String(port)]
    configuration.activates = false
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    // Answering comes first. A device follows a few seconds later, if one is plugged in.
    let endpoint = Logic2Endpoint(port: port)
    let started = ContinuousClock.now
    var answeredAt: ContinuousClock.Instant?
    while true {
        do {
            let devices = try await withLogic2(endpoint, probeSeconds: 2) { manager in
                try await manager.getDevices(.init(), options: .limited(to: 5)).devices.count
            }
            let since = answeredAt ?? ContinuousClock.now
            answeredAt = since
            if devices > 0 || ContinuousClock.now - since >= .seconds(logic2DeviceSeconds) { return }
        } catch is Logic2Error {
            guard answeredAt == nil, ContinuousClock.now - started < .seconds(logic2StartSeconds) else {
                throw Logic2Error.didNotStart(port: port, seconds: logic2StartSeconds)
            }
        }
        try await Task.sleep(for: .milliseconds(250))
    }
}
