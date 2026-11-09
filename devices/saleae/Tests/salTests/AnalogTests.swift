import ArgumentParser
import Foundation
import Testing
@testable import sal

private func analogFile(
    begin: Double = 0,
    rate: UInt64 = 1000,
    downsample: UInt64 = 1,
    samples: [Float] = [0, 1],
    count: UInt64? = nil,
    version: Int32 = 0,
    type: Int32 = 1
) -> Data {
    var data = Data("<SALEAE>".utf8)
    data.appendValue(version)
    data.appendValue(type)
    data.appendValue(begin)
    data.appendValue(rate)
    data.appendValue(downsample)
    data.appendValue(count ?? UInt64(samples.count))
    samples.forEach { data.appendValue($0) }
    return data
}

private func parseAnalog(_ data: Data) throws -> AnalogChannel {
    try AnalogChannel(data: data, name: "test")
}

private func summary(_ samples: [Float], rate: UInt64 = 1000, downsample: UInt64 = 1) throws -> AnalogSummary {
    summarize(try parseAnalog(analogFile(rate: rate, downsample: downsample, samples: samples)), channel: 3)
}

private func square(periods: Int, high: Int, low: Int, top: Float = 3.3, bottom: Float = 0) -> [Float] {
    (0..<periods).flatMap { _ in Array(repeating: top, count: high) + Array(repeating: bottom, count: low) }
}

@Suite("Analog binary parsing")
struct AnalogParsingTests {
    @Test("The header and samples read back")
    func header() throws {
        let analog = try parseAnalog(analogFile(begin: 0.5, rate: 1000, downsample: 4, samples: [1.5, -2]))
        #expect(analog.beginTime == 0.5)
        #expect(analog.sampleCount == 2)
        #expect(analog.effectiveSampleRate == 250)
        analog.withSamples { samples in
            #expect(samples.count == 2)
            #expect(samples[0] == 1.5)
            #expect(samples[1] == -2)
        }
    }

    @Test("Bad headers are rejected with the right error", arguments: [
        (Data("short".utf8), AnalogFileError.tooShort(name: "test")),
        (analogFile(version: 1), .unsupportedVersion(name: "test", version: 1)),
        (analogFile(type: 0), .notAnalog(name: "test", type: 0)),
        (analogFile(begin: .nan), .invalidBeginTime(name: "test")),
        (analogFile(begin: .infinity), .invalidBeginTime(name: "test")),
        (analogFile(rate: 0), .invalidRate(name: "test")),
        (analogFile(downsample: 0), .invalidRate(name: "test")),
        (analogFile(rate: 3, downsample: 4), .invalidRate(name: "test")),
        (analogFile(samples: []), .invalidSampleCount(name: "test", count: 0)),
        (analogFile(samples: [0], count: 2), .invalidSampleCount(name: "test", count: 2)),
        (analogFile(samples: [0], count: .max), .invalidSampleCount(name: "test", count: .max)),
        (analogFile(samples: [0, 1], count: 1), .sizeMismatch(name: "test", expected: 52, actual: 56)),
        (analogFile(samples: [0, .nan]), .invalidSample(name: "test", index: 1)),
        (analogFile(samples: [.infinity]), .invalidSample(name: "test", index: 0)),
    ] as [(Data, AnalogFileError)])
    func badHeaders(data: Data, expected: AnalogFileError) {
        #expect(throws: expected) { try parseAnalog(data) }
    }

    @Test("A wrong magic is rejected")
    func magic() {
        var data = analogFile()
        data[0] = 0
        #expect(throws: AnalogFileError.badMagic(name: "test")) { try parseAnalog(data) }
    }

    @Test("Equal rate and downsample is the valid boundary")
    func rateBoundary() throws {
        #expect(try parseAnalog(analogFile(rate: 4, downsample: 4)).effectiveSampleRate == 1)
    }

    @Test("Every truncation is rejected, and a tail byte is too")
    func truncations() {
        let bytes = analogFile(samples: [1, 2, 3])
        for length in 0..<bytes.count {
            #expect(throws: (any Error).self) { try parseAnalog(bytes.prefix(length)) }
        }
        #expect(throws: (any Error).self) { try parseAnalog(bytes + Data([0])) }
    }

    @Test("Every value of every header byte never traps")
    func headerBytes() {
        let bytes = analogFile(samples: [1, 2, 3])
        for position in 0..<AnalogChannel.headerSize {
            for value in UInt8.min...UInt8.max {
                var mutated = bytes
                mutated[position] = value
                if let channel = try? parseAnalog(mutated) { _ = summarize(channel, channel: 0) }
            }
        }
    }

    @Test("Seeded random corruption never traps")
    func random() {
        var generator = SplitMix64(state: 0xA6A)
        let bytes = analogFile(samples: square(periods: 20, high: 3, low: 5))
        for _ in 0..<20_000 {
            var mutated = bytes
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                mutated[Int.random(in: mutated.indices, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            if let channel = try? parseAnalog(mutated) { _ = summarize(channel, channel: 0) }
        }
    }

    @Test("A recorded PWM reads as expected")
    func recorded() throws {
        let url = fixtureDirectory.deletingLastPathComponent().appendingPathComponent("analog/pwm.bin")
        let analog = summarize(try AnalogChannel(contentsOf: url), channel: 0)
        #expect(analog.sampleRateHz == 156_250)
        #expect(abs(try #require(analog.levels).lowVolts) < 0.25)
        #expect(abs(try #require(analog.levels).highVolts - 3.3) < 0.3)
        #expect(abs(try #require(analog.periodic).frequencyHz - 1000) < 15)
        #expect(abs(try #require(analog.periodic).dutyPercent - 25) < 3)
    }
}

@Suite("Analog summaries")
struct AnalogSummaryTests {
    @Test("Basic statistics are computed")
    func statistics() throws {
        let result = try summary([1, 3, 3, 1], rate: 1000, downsample: 2)
        #expect(result.channel == 3)
        #expect(result.samples == 4)
        #expect(result.sampleRateHz == 500)
        #expect(result.minVolts == 1)
        #expect(result.maxVolts == 3)
        #expect(result.meanVolts == 2)
        #expect(abs(result.rmsVolts - 5.0.squareRoot()) < 1e-9)
    }

    @Test("A steady level has no levels or period")
    func steady() throws {
        let result = try summary(Array(repeating: 1.65, count: 100))
        #expect(result.levels == nil)
        #expect(result.periodic == nil)
    }

    @Test("A swing just under the minimum is steady, and at it is a signal")
    func swingBoundary() throws {
        let tiny: [Float] = square(periods: 10, high: 2, low: 2, top: 0.19, bottom: 0)
        #expect(try summary(tiny).levels == nil)
        let enough: [Float] = square(periods: 10, high: 2, low: 2, top: 0.25, bottom: 0)
        #expect(try summary(enough).levels != nil)
    }

    @Test("Levels, frequency and duty of a square wave", arguments: [(1, 3, 25.0), (2, 2, 50.0), (3, 1, 75.0)])
    func squareWave(high: Int, low: Int, duty: Double) throws {
        let result = try summary(square(periods: 40, high: high, low: low), rate: 4000)
        #expect(abs(try #require(result.levels).lowVolts) < 1e-6)
        #expect(abs(try #require(result.levels).highVolts - 3.3) < 1e-5)
        #expect(abs(try #require(result.periodic).frequencyHz - 1000) < 1e-6)
        #expect(abs(try #require(result.periodic).dutyPercent - duty) < 1e-6)
    }

    @Test("Three rising edges are too few, and four are enough", arguments: [(2, false), (3, false), (4, true)])
    func periodCount(periods: Int, found: Bool) throws {
        // Starts low so that every rise is seen.
        let samples: [Float] = [0, 0] + square(periods: periods, high: 2, low: 2)
        #expect((try summary(samples).periodic != nil) == found)
    }

    @Test("A period more than 5% off the median rules out periodic")
    func irregular() throws {
        var samples: [Float] = [0, 0]
        for low in [20, 20, 20, 20, 20, 24, 20, 20] {
            samples += Array(repeating: 3.3, count: 20) + Array(repeating: 0, count: low)
        }
        #expect(try summary(samples).periodic == nil)
    }

    @Test("A period exactly 5% off the median is still periodic")
    func regularEnough() throws {
        var samples: [Float] = [0, 0]
        for low in [20, 20, 20, 20, 20, 22, 20, 20, 20] {
            samples += Array(repeating: 3.3, count: 20) + Array(repeating: 0, count: low)
        }
        #expect(try summary(samples).periodic != nil)
    }

    @Test("Noise near the threshold does not count as extra edges")
    func hysteresis() throws {
        var samples: [Float] = [0]
        for _ in 0..<20 {
            samples += [0, 1.6, 1.7, 1.6, 1.7, 1.6, 3.3, 3.3, 1.7, 1.6, 1.7, 1.6, 0, 0]
        }
        let result = try #require(try summary(samples, rate: 14_000).periodic)
        #expect(abs(result.frequencyHz - 1000) < 1)
    }

    @Test("Summaries match an independent calculation")
    func oracle() throws {
        var generator = SplitMix64(state: 0x0AC1E)
        for _ in 0..<500 {
            let samples = (0..<Int.random(in: 1...200, using: &generator)).map { _ in Float.random(in: -5...5, using: &generator) }
            let result = try summary(samples)
            let values = samples.map(Double.init)
            #expect(result.minVolts == values.min()!)
            #expect(result.maxVolts == values.max()!)
            let mean = values.reduce(0, +) / Double(values.count)
            #expect(abs(result.meanVolts - mean) < 1e-9)
            let rms = (values.map { $0 * $0 }.reduce(0, +) / Double(values.count)).squareRoot()
            #expect(abs(result.rmsVolts - rms) < 1e-9)
            if let levels = result.levels {
                let middle = (values.min()! + values.max()!) / 2
                let low = values.filter { $0 < middle }
                let high = values.filter { $0 >= middle }
                #expect(abs(levels.lowVolts - low.reduce(0, +) / Double(low.count)) < 1e-9)
                #expect(abs(levels.highVolts - high.reduce(0, +) / Double(high.count)) < 1e-9)
            }
        }
    }

    @Test("A summary prints levels, period and range")
    func printing() throws {
        let line = describe(try summary(square(periods: 40, high: 1, low: 3), rate: 4000))
        #expect(line == "A3, low 0.000 V, high 3.300 V, 1000.00 Hz, 25.00% duty, range 0.000 to 3.300 V, rms 1.650 V")
    }

    @Test("A steady channel prints its level")
    func printingSteady() throws {
        #expect(describe(try summary([1, 1, 1])) == "A3, steady 1.000 V, range 1.000 to 1.000 V, rms 1.000 V")
    }
}

@Suite("Analog arguments")
struct AnalogArgumentTests {
    private func parse(_ arguments: [String]) throws -> CaptureCommand {
        try #require(try Sal.parseAsRoot(["capture"] + arguments) as? CaptureCommand)
    }

    @Test("Analog options reach the capture request")
    func options() throws {
        let command = try parse(["--analog", "0-1", "--analog-rate", "3.125M", "--analog-downsample", "10"])
        let analog = try #require(try command.analogCapture)
        #expect(analog.channels == [0, 1])
        #expect(analog.sampleRate == 3_125_000)
        #expect(analog.downsample == 10)
    }

    @Test("Without --analog there is no analog capture")
    func absent() throws {
        #expect(try parse([]).analogCapture == nil)
    }

    @Test("Digital defaults to 50M alone and to a safe pairing with analog")
    func defaultRates() throws {
        let command = try parse([])
        let stop = CaptureCancellation()
        #expect(try command.capture.request(channels: [0], stop: stop).sampleRate == 50_000_000)
        let analog = AnalogCapture(channels: [0], sampleRate: 1_562_500)
        #expect(try command.capture.request(channels: [0], analog: analog, stop: stop).sampleRate == 6_250_000)
    }

    @Test("An explicit digital rate wins even with analog")
    func explicitRate() throws {
        let analog = AnalogCapture(channels: [0], sampleRate: 3_125_000)
        let request = try parse(["--rate", "500M"]).capture.request(channels: [0], analog: analog, stop: CaptureCancellation())
        #expect(request.sampleRate == 500_000_000)
    }

    @Test("Valid boundaries are accepted", arguments: [
        ["--analog", "0", "--analog-downsample", "1"],
        ["--analog", "0", "--analog-downsample", "1000000"],
        ["--channels", "none", "--analog", "15"],
    ])
    func accepted(arguments: [String]) {
        #expect(throws: Never.self) { try parse(arguments) }
    }

    @Test("Invalid values are refused", arguments: [
        ["--analog", "0", "--analog-downsample", "0"],
        ["--analog", "0", "--analog-downsample", "1000001"],
        ["--channels", "none"],
    ])
    func refused(arguments: [String]) {
        #expect(throws: (any Error).self) { try parse(arguments) }
    }

    @Test("A bad analog channel list or rate is reported when building the request", arguments: [
        ["--analog", "16"], ["--analog", "x"], ["--analog", "0", "--analog-rate", "fast"],
    ])
    func badAnalog(arguments: [String]) throws {
        let command = try parse(arguments)
        #expect(throws: (any Error).self) { try command.analogCapture }
    }
}
