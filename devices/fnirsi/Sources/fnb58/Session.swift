import Foundation

struct Reading: Encodable, Equatable, Sendable {
    var voltageV: Double
    var currentA: Double
    var powerW: Double
    var dPlusV: Double
    var dMinusV: Double
    var temperatureC: Double

    init(_ sample: Sample) {
        voltageV = rounded(sample.voltage, 5)
        currentA = rounded(sample.current, 5)
        powerW = rounded(sample.power, 6)
        dPlusV = rounded(sample.dPlus, 3)
        dMinusV = rounded(sample.dMinus, 3)
        temperatureC = rounded(sample.temperature, 1)
    }

    enum CodingKeys: String, CodingKey {
        case voltageV = "voltage_V", currentA = "current_A", powerW = "power_W"
        case dPlusV = "dplus_V", dMinusV = "dminus_V", temperatureC = "temp_C"
    }
}

struct StatusInfo: Encodable, Sendable {
    struct Capturing: Encodable, Sendable {
        var label: String?
        var csv: String
        var seconds: Double
        var samples: Int
    }

    var connected: Bool
    var meters: [MeterInfo]
    var reading: Reading?
    var capturing: Capturing?
    /// From the meter's reply to the start command, once this process has sent one.
    var device: DeviceInfo?
    var error: String?
}

struct CaptureStarted: Encodable, Sendable {
    var label: String?
    var csv: String
}

struct RawReport: Encodable, Sendable {
    var t: Double
    var type: String
    var crcOK: Bool
    var hex: String

    enum CodingKeys: String, CodingKey {
        case t = "t_s", type, crcOK = "crc_ok", hex
    }
}

struct RawDump: Encodable, Sendable {
    var seconds: Double
    var total: Int
    /// Count of reports by type byte, as hex.
    var types: [String: Int]
    /// Every value byte 12, the temperature sign, took in data reports.
    var signByteValues: [Int]
    var reports: [RawReport]
    var truncated: Bool

    enum CodingKeys: String, CodingKey {
        case seconds, total, types, reports, truncated
        case signByteValues = "sign_byte_values"
    }
}

struct SessionError: Error, CustomStringConvertible {
    var description: String
}

/// Owns the one stream from the meter. The CLI makes one per command; the MCP server keeps
/// one for its lifetime, so a capture can run between tool calls.
actor MeterSession {
    let transport: any MeterTransport
    let serial: String?
    let directory: URL
    /// How long a running stream may go without a report before it counts as stalled.
    let stallLimit: Duration
    let keepaliveInterval: Duration
    /// Closing with reports queued fills the meter's small FIFO and freezes it, so before
    /// closing, read until it has been quiet this long, for at most `drainLimit`.
    let quiet: Duration
    let drainLimit: Duration
    /// Silence after which the stream is restarted. Reports come every 40 ms.
    let restartAfter: Duration
    /// Stream restarts since the capture began.
    private var restarts = 0

    private var link: (any MeterLink)?
    private var pump: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var latest: Sample?
    private var lastReport = ContinuousClock.now
    /// Only data reports count for stalls and restarts: a stopped meter still answers 0x81.
    private var lastData = ContinuousClock.now
    private var recorder: CaptureRecorder?
    private var captureStarted = ContinuousClock.now
    private var lostLink = false
    private var writeError: String?
    /// Reports seen on the current link.
    private var reports = 0
    /// The meter's reply to 0x81, when this session sent one.
    private var device: DeviceInfo?
    private var deviceReplied = false
    /// The first data report after starting can be garbage (seen on the FNB48), so it is dropped.
    private var dropNextData = false
    private var invalidReports = 0
    private var otherReports: [UInt8: Int] = [:]
    private var raw: ((ContinuousClock.Instant, [UInt8]) -> Void)?
    private(set) var lastCapture: URL?

    init(
        transport: any MeterTransport = HIDTransport(), serial: String? = nil, directory: URL = defaultCaptureDirectory(),
        stallLimit: Duration = .seconds(3), keepaliveInterval: Duration = FNB58.keepaliveInterval,
        quiet: Duration = .milliseconds(300), drainLimit: Duration = .milliseconds(2500),
        restartAfter: Duration = .milliseconds(500)
    ) {
        self.restartAfter = restartAfter
        self.quiet = quiet
        self.drainLimit = drainLimit
        self.transport = transport
        self.serial = serial
        self.directory = directory
        self.stallLimit = stallLimit
        self.keepaliveInterval = keepaliveInterval
    }

    // MARK: Tools

    func status() async -> StatusInfo {
        var info = StatusInfo(connected: false, meters: transport.meters())
        if recorder == nil, link == nil {
            do {
                try await connect()
                try await waitForSample()
            } catch {
                info.error = String(describing: error)
            }
        }
        info.connected = link != nil
        info.reading = latest.map(Reading.init)
        if let recorder {
            info.capturing = .init(label: recorder.label, csv: recorder.url.path, seconds: recorder.seconds, samples: recorder.count)
        }
        info.device = device
        if recorder == nil { await disconnect() }
        return info
    }

    func startCapture(label: String?) async throws -> CaptureStarted {
        if let recorder {
            throw SessionError(description: "A capture is already running (\(recorder.url.lastPathComponent)). Stop it first.")
        }
        try await connect()
        let recorder = try CaptureRecorder(label: label, directory: directory)
        self.recorder = recorder
        captureStarted = .now
        lostLink = false
        writeError = nil
        restarts = 0
        invalidReports = 0
        otherReports = [:]
        lastCapture = recorder.url
        return CaptureStarted(label: label, csv: recorder.url.path)
    }

    func stopCapture() async throws -> CaptureSummary {
        guard recorder != nil else { throw SessionError(description: "No capture is running.") }
        return await finish(lostLink ? .disconnected : writeError != nil ? .failed : stalled ? .stalled : .stopped)
    }

    /// Records `seconds` of samples, counted by sample index. Returns early, with what it has,
    /// if the meter goes away or stalls, or the task is cancelled.
    func capture(seconds: Double, label: String?) async throws -> CaptureSummary {
        guard seconds > 0, seconds <= 24 * 3600 else { throw SessionError(description: "seconds must be above 0 and at most 86400.") }
        _ = try await startCapture(label: label)
        let target = Int((seconds * FNB58.sampleRate).rounded())
        while let recorder, recorder.count < target {
            if lostLink { return await finish(.disconnected) }
            if writeError != nil { return await finish(.failed) }
            if stalled { return await finish(.stalled) }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return await finish(.interrupted)
            }
        }
        guard recorder != nil else { throw SessionError(description: "The capture was stopped by another call.") }
        return await finish(.completed)
    }

    func mark(_ note: String) throws -> Mark {
        guard let recorder else { throw SessionError(description: "No capture is running, so there is nothing to mark.") }
        return recorder.mark(note)
    }

    /// Every report for `seconds`, as hex. Captures and marks are unaffected.
    func rawDump(seconds: Double, limit: Int) async throws -> RawDump {
        guard seconds > 0, seconds <= 60 else { throw SessionError(description: "seconds must be above 0 and at most 60.") }
        var reports: [RawReport] = []
        var types: [String: Int] = [:]
        var signs = Set<Int>()
        var total = 0
        let start = ContinuousClock.now
        raw = { at, bytes in
            total += 1
            let type = bytes.count > 1 ? String(format: "%02x", bytes[1]) : "short"
            types[type, default: 0] += 1
            if case .samples(let samples) = Report(bytes) { samples.forEach { signs.insert(Int($0.signByte)) } }
            if reports.count < limit {
                let t = Double((at - start).components.attoseconds) / 1e18 + Double((at - start).components.seconds)
                reports.append(RawReport(t: rounded(t, 3), type: type, crcOK: Report.checksumMatches(bytes), hex: hex(bytes)))
            }
        }
        defer { raw = nil }
        do {
            try await connect()
            try await Task.sleep(for: .seconds(seconds))
        } catch is CancellationError {
        }
        raw = nil
        if recorder == nil { await disconnect() }
        return RawDump(
            seconds: seconds, total: total, types: types, signByteValues: signs.sorted(), reports: reports,
            truncated: total > reports.count)
    }

    /// Stops any capture, keeping its file, and lets go of the meter.
    func shutdown() async -> CaptureSummary? {
        let summary = recorder == nil ? nil : await finish(.interrupted)
        await disconnect()
        return summary
    }

    // MARK: Stream

    private var stalled: Bool { link != nil && ContinuousClock.now - lastData > stallLimit }

    private func connect() async throws {
        if link != nil { return }
        debug("connect")
        let link = try transport.open(serial: serial)
        self.link = link
        lastReport = .now
        lastData = .now
        lostLink = false
        pump = Task { [weak self] in
            for await event in link.events {
                await self?.handle(event)
            }
            await self?.linkEnded(link)
        }
        do {
            try await start(link)
        } catch {
            await disconnect()
            throw error
        }
        let interval = keepaliveInterval
        // The only sender once started, so one output report is in flight at a time.
        keepalive = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                await self?.tick(link)
            }
        }
    }

    /// Starts the stream without wedging the meter. Back-to-back start commands hang its
    /// firmware until it is replugged, as does closing with reports still queued.
    private func start(_ link: any MeterLink) async throws {
        // Drain what is queued: listen until 20 ms pass with nothing new.
        let began = ContinuousClock.now
        var seen = -1
        while seen != reports {
            seen = reports
            try await Task.sleep(for: .milliseconds(20))
            if ContinuousClock.now - began > .milliseconds(300) {
                // Still sending, probably another client's stream. Keep it alive instead of
                // sending 0x81 again, which other tools say can reboot the meter. If it was
                // a stream winding down, the watchdog in tick() restarts it.
                debug("already streaming")
                try await send(FNB58.keepalive, on: link)
                return
            }
        }
        try await initialize(link)
    }

    /// 0x81, wait for its reply, then 0x82 twice, with gaps.
    private func initialize(_ link: any MeterLink) async throws {
        deviceReplied = false
        try await send(FNB58.startCommands[0], on: link)
        // The meter answers 0x81 with a type 0x03 report in about 10 ms.
        let deadline = ContinuousClock.now + .milliseconds(500)
        while !deviceReplied, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        for command in FNB58.startCommands.dropFirst() {
            try await Task.sleep(for: FNB58.commandGap)
            try await send(command, on: link)
        }
        dropNextData = true
    }

    /// Each keepalive period: a keepalive, or a restart if the stream has gone quiet. The
    /// meter streams for about 1.5 s after its last keepalive, and a keepalive alone does
    /// not restart a stream that has stopped.
    private func tick(_ link: any MeterLink) async {
        guard self.link === link, !lostLink else { return }
        if ContinuousClock.now - lastData > restartAfter {
            restarts += 1
            debug("restart \(restarts)")
            try? await initialize(link)
        } else {
            try? await send(FNB58.keepalive, on: link)
        }
    }

    /// Sends off the actor, because a wedged meter holds a send for seconds.
    private func send(_ report: [UInt8], on link: any MeterLink) async throws {
        debug(String(format: "send %02x", report[1]))
        do {
            try await Task.detached { try link.send(report) }.value
        } catch {
            debug("send failed: \(error)")
            throw error
        }
    }

    private func waitForSample(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        latest = nil
        while latest == nil {
            guard link != nil else { throw MeterError.notFound(serial: serial) }
            guard ContinuousClock.now < deadline else {
                throw MeterError.noData(seconds: Double(timeout.components.seconds))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func handle(_ event: LinkEvent) {
        switch event {
        case .report(let bytes):
            if debugging, ContinuousClock.now - lastReport > .milliseconds(200) || reports == 0 {
                debug(String(format: "report %02x after %@ quiet", bytes.count > 1 ? bytes[1] : 0, "\(ContinuousClock.now - lastReport)"))
            }
            lastReport = .now
            reports += 1
            raw?(.now, bytes)
            switch Report(bytes) {
            case .samples where dropNextData:
                lastData = .now
                dropNextData = false
            case .samples(let samples):
                lastData = .now
                latest = samples.last
                do {
                    try recorder?.append(samples)
                } catch {
                    // Disk trouble: end the capture rather than silently drop samples.
                    writeError = writeError ?? error.localizedDescription
                }
            case .other(let type):
                otherReports[type, default: 0] += 1
                if let info = DeviceInfo(bytes) {
                    device = info
                    deviceReplied = true
                }
            case .invalid: invalidReports += 1
            }
        case .removed:
            lostLink = true
        }
    }

    private func linkEnded(_ ended: any MeterLink) {
        guard link === ended else { return }
        lostLink = true
        keepalive?.cancel()
        keepalive = nil
        link = nil
    }

    private func disconnect() async {
        debug("disconnect")
        let keepalive = self.keepalive
        self.keepalive = nil
        keepalive?.cancel()
        // No send may be in flight while the link closes.
        await keepalive?.value
        if link != nil, !lostLink { await drain() }
        let link = self.link
        self.link = nil
        link?.close()
        await pump?.value
        pump = nil
        reports = 0
        dropNextData = false
        latest = nil
    }

    /// Reads until the meter has been quiet for `quiet`, or `drainLimit` passes.
    private func drain() async {
        let began = ContinuousClock.now
        defer { debug("drained in \(ContinuousClock.now - began)") }
        while link != nil, ContinuousClock.now - lastReport < quiet, ContinuousClock.now - began < drainLimit {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func finish(_ ended: CaptureEnd) async -> CaptureSummary {
        guard let recorder else { preconditionFailure("finish without a capture") }
        self.recorder = nil
        var warnings: [String] = []
        let wall = ContinuousClock.now - captureStarted
        let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
        let expected = wallSeconds * FNB58.sampleRate
        if !summaryFailed(ended), recorder.count > 0,
           abs(Double(recorder.count) - expected) > max(25, expected * 0.05) {
            warnings.append(String(format: "Got %d samples in %.1f s of wall time, expected about %.0f. Reports may have been lost, so sample times may drift.", recorder.count, wallSeconds, expected))
        }
        if ended == .disconnected {
            warnings.append(String(format: "The meter went away after %.2f s of samples. Samples up to then are kept.", recorder.seconds))
        }
        if ended == .stalled {
            warnings.append(String(format: "The meter stopped sending after %.2f s of samples. Samples up to then are kept.", recorder.seconds))
        }
        if let writeError {
            warnings.append("Writing the CSV failed (\(writeError)), so the capture ended. Samples written before then are kept.")
        }
        if restarts > 0 {
            warnings.append("The meter's stream stopped and was restarted \(restarts) time(s). Samples were lost in each gap, so later sample times run early.")
        }
        if invalidReports > 0 { warnings.append("\(invalidReports) unreadable reports were skipped.") }
        let summary = recorder.finish(ended: ended, warnings: warnings)
        await disconnect()
        return summary
    }
}

private let debugStart = ContinuousClock.now
private let debugging = ProcessInfo.processInfo.environment["FNB58_DEBUG"] == "1"

/// With FNB58_DEBUG=1, traces sends and stream changes to standard error.
func debug(_ message: @autoclosure () -> String) {
    guard debugging else { return }
    let elapsed = ContinuousClock.now - debugStart
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    FileHandle.standardError.write(Data(String(format: "%8.3f %@\n", seconds, message()).utf8))
}

/// `$FNB58_CAPTURE_DIR`, or ~/.local/share/fnb58/captures.
func defaultCaptureDirectory() -> URL {
    if let path = ProcessInfo.processInfo.environment["FNB58_CAPTURE_DIR"], !path.isEmpty {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/fnb58/captures")
}

/// The newest CSV in `directory`.
func newestCapture(in directory: URL) -> URL? {
    let files = (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return files.filter { $0.pathExtension == "csv" }.max { a, b in
        let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return da < db
    }
}
