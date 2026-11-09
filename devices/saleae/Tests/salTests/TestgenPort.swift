import Darwin
import Foundation

struct TestgenPortError: Error, CustomStringConvertible {
    var description: String
}

/// Selects a testgen traffic mode over USB serial, and leaves the board in clean mode.
func withTestgen<Result>(mode: Character, body: () async throws -> Result) async throws -> Result {
    try await withTestgenReply(mode: mode) { _ in try await body() }
}

/// As `withTestgen`, also passing `body` what the board replied when selecting the mode.
func withTestgenReply<Result>(mode: Character, body: (String) async throws -> Result) async throws -> Result {
    let names = try FileManager.default.contentsOfDirectory(atPath: "/dev")
    guard let name = names.filter({ $0.hasPrefix("cu.usbserial") }).sorted().first else {
        throw TestgenPortError(description: "No testgen USB serial port found")
    }
    let descriptor = open("/dev/" + name, O_RDWR | O_NOCTTY | O_NONBLOCK)
    guard descriptor >= 0 else { throw TestgenPortError(description: "Cannot open /dev/\(name)") }
    defer { close(descriptor) }

    var options = termios()
    tcgetattr(descriptor, &options)
    cfmakeraw(&options)
    cfsetspeed(&options, speed_t(B115200))
    options.c_cflag |= tcflag_t(CLOCAL | CREAD)
    tcsetattr(descriptor, TCSANOW, &options)

    @discardableResult
    func waitFor(_ token: String, seconds: Double) throws -> String {
        var received = Data()
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 512)
        while Date() < deadline {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { received.append(contentsOf: buffer[..<count]) }
            if received.range(of: Data(token.utf8)) != nil { return String(decoding: received, as: UTF8.self) }
        }
        throw TestgenPortError(description: "testgen did not send \(token)")
    }

    @discardableResult
    func select(_ key: Character) throws -> String {
        let byte = [key.asciiValue!]
        guard write(descriptor, byte, 1) == 1 else {
            throw TestgenPortError(description: "Cannot write to testgen")
        }
        return try waitFor("mode \(key)", seconds: 2)
    }

    // Opening the port usually resets the board, but not always, so the banner is
    // optional. Selecting a mode is what proves the board is listening.
    _ = try? waitFor("running", seconds: 3)
    let reply = try select(mode)
    // Lets any frame in flight from the previous mode finish.
    usleep(100_000)
    defer { try? select("c") }
    return try await body(reply)
}
