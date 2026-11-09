import ArgumentParser
import Foundation
import Testing
@testable import sal

private func line(initial: Int32 = 0, _ times: [Double], begin: Double = 0, end: Double = 10) throws -> IdentifiableChannel {
    try line(1, initial: initial, times, begin: begin, end: end)
}

private func line(_ number: UInt32, initial: Int32 = 0, _ times: [Double], begin: Double = 0, end: Double = 10) throws -> IdentifiableChannel {
    IdentifiableChannel(
        summary: summarize(try parse(digitalFile(initial: initial, begin: begin, end: end, times: times)), channel: number),
        times: times, beginTime: begin, endTime: end)
}

private func analog(begin: Double = 0, rate: UInt64 = 10, samples: [Float]) throws -> AnalogChannel {
    var data = Data("<SALEAE>".utf8)
    data.appendValue(Int32(0))
    data.appendValue(Int32(1))
    data.appendValue(begin)
    data.appendValue(rate)
    data.appendValue(UInt64(1))
    data.appendValue(UInt64(samples.count))
    samples.forEach { data.appendValue($0) }
    return try AnalogChannel(data: data, name: "test")
}

private func row(_ type: String, _ start: Double, _ fields: [String: String] = [:]) -> DecodedRow {
    DecodedRow(type: type, start: start, duration: 0.5, fields: fields)
}

private let uartDecoder = ProtocolDecoder.uart(UARTDecoder(channel: 2, baud: 9600))

@Suite("Digital traces")
struct DigitalTraceTests {
    @Test("Few edges give exact low and high segments")
    func exact() throws {
        let trace = digitalTrace(try line([2, 4]), from: 0, to: 6, maxSegments: 100)
        #expect(trace.edges == 2)
        #expect(trace.segments == [
            TraceSegment(start: 0, end: 2, state: .low, edges: 0),
            TraceSegment(start: 2, end: 4, state: .high, edges: 0),
            TraceSegment(start: 4, end: 6, state: .low, edges: 0),
        ])
    }

    @Test("The window starts at the level already held")
    func levelAtStart() throws {
        let trace = digitalTrace(try line([2, 4]), from: 3, to: 3.5, maxSegments: 100)
        #expect(trace.segments == [TraceSegment(start: 3, end: 3.5, state: .high, edges: 0)])
    }

    @Test("An edge at the window start counts as already happened, and one at the end does not")
    func boundaries() throws {
        let channel = try line([2, 4])
        #expect(digitalTrace(channel, from: 2, to: 3, maxSegments: 9).segments.map(\.state) == [.high])
        #expect(digitalTrace(channel, from: 3, to: 4, maxSegments: 9).segments.map(\.state) == [.high])
    }

    @Test("An edge a hair after the window start counts as already happened")
    func triggerEdge() throws {
        let channel = try line([1e-18, 4], begin: -1)
        #expect(digitalTrace(channel, from: 0, to: 3, maxSegments: 9).segments.map(\.state) == [.high])
    }

    @Test("An edge a nanosecond after the window start is real")
    func nearEdge() throws {
        let channel = try line([1e-9, 4], begin: -1)
        #expect(digitalTrace(channel, from: 0, to: 3, maxSegments: 9).segments.map(\.state) == [.low, .high])
    }

    @Test("A channel with no edges is one segment at its level")
    func idle() throws {
        let trace = digitalTrace(try line(initial: 1, []), from: 0, to: 1, maxSegments: 2)
        #expect(trace.segments == [TraceSegment(start: 0, end: 1, state: .high, edges: 0)])
    }

    @Test("Exactly the limit stays exact, and one more merges")
    func limitBoundary() throws {
        let channel = try line((1...9).map { Double($0) / 10 })
        #expect(digitalTrace(channel, from: 0, to: 1, maxSegments: 10).segments.allSatisfy { $0.state != .active })
        #expect(digitalTrace(channel, from: 0, to: 1, maxSegments: 9).segments.contains { $0.state == .active })
    }

    @Test("Bursts merge into active spans with exact ends, and long idle stays exact")
    func merged() throws {
        var times = (0..<100).map { 1 + Double($0) * 1e-4 }
        times += (0..<100).map { 8 + Double($0) * 1e-4 }
        let trace = digitalTrace(try line(times), from: 0, to: 10, maxSegments: 20)
        #expect(trace.edges == 200)
        #expect(trace.segments.map(\.state) == [.low, .active, .low, .active, .low])
        #expect(trace.segments[1].start == times[0])
        #expect(trace.segments[1].end == times[99])
        #expect(trace.segments[1].edges == 98)
    }

    @Test("The limit holds in the worst case, of medium stretches between short pulses")
    func worstCase() throws {
        var times: [Double] = []
        var now = 0.0
        while now < 9 {
            now += 1.1
            times.append(now)
            now += 0.01
            times.append(now)
        }
        let trace = digitalTrace(try line(times), from: 0, to: 10, maxSegments: 10)
        #expect(trace.segments.count <= 11, "\(trace.segments.count) segments")
    }

    @Test("A lone short pulse between long stretches stays exact")
    func lonePulse() throws {
        var times = (0..<100).map { 1 + Double($0) * 1e-4 }
        if times.count % 2 == 1 { times.removeLast() }
        times += [5, 5.0001]
        let trace = digitalTrace(try line(times), from: 0, to: 10, maxSegments: 20)
        #expect(trace.segments.contains { $0.start == 5 && $0.end == 5.0001 && $0.state == .high })
    }

    @Test("Random edges keep every promise a trace makes")
    func properties() throws {
        var generator = SplitMix64(state: 0x71E)
        for _ in 0..<3_000 {
            var now = 0.0
            let times = (0..<Int.random(in: 0...300, using: &generator)).map { _ -> Double in
                now += [1e-4, 1e-3, 1, 5].randomElement(using: &generator)! * Double.random(in: 0.5...1.5, using: &generator)
                return now
            }
            let channel = try line(initial: Int32.random(in: 0...1, using: &generator), times, end: now + 1)
            let from = Double.random(in: 0...max(now, 1), using: &generator)
            let to = Double.random(in: from...(now + 1), using: &generator).nextUp
            let limit = Int.random(in: 2...400, using: &generator)
            let trace = digitalTrace(channel, from: from, to: to, maxSegments: limit)

            #expect(trace.segments.first?.start == from)
            #expect(trace.segments.last?.end == to)
            #expect(zip(trace.segments, trace.segments.dropFirst()).allSatisfy { $0.end == $1.start }, "contiguous")
            #expect(trace.segments.count <= limit + 1, "limit \(limit), got \(trace.segments.count)")

            let inside = times.filter { $0 > from && $0 < to }
            #expect(trace.edges == inside.count)
            #expect(trace.segments.reduce(0) { $0 + $1.edges } + trace.segments.count - 1 == inside.count, "no edge lost")

            for segment in trace.segments where segment.state != .active {
                let middle = (segment.start + segment.end) / 2
                let level = (Int(channel.summary.initialLevel) + times.filter { $0 <= middle }.count) % 2
                #expect((segment.state == .high) == (level == 1))
                #expect(!times.contains { $0 > segment.start && $0 < segment.end }, "exact segments have no edges inside")
            }
        }
    }
}

@Suite("Analog traces")
struct AnalogTraceTests {
    @Test("Every sample is kept when they fit")
    func exact() throws {
        let trace = analogTrace(try analog(samples: [1, 2, 3, 4]), channel: 5, from: 0, to: 1, maxPoints: 10)
        #expect(trace.channel == 5)
        #expect(trace.startSeconds == 0)
        #expect(trace.stepSeconds == 0.1)
        #expect(trace.minVolts == [1, 2, 3, 4])
        #expect(trace.maxVolts == [1, 2, 3, 4])
    }

    @Test("The window selects samples, and starts at the first one inside it")
    func window() throws {
        let trace = analogTrace(try analog(begin: 1, samples: [1, 2, 3, 4, 5]), channel: 0, from: 1.1, to: 1.3, maxPoints: 10)
        #expect(trace.minVolts == [2, 3])
        #expect(abs(trace.startSeconds - 1.1) < 1e-9)
    }

    @Test("Thinning keeps the extremes of each step")
    func thinning() throws {
        let trace = analogTrace(try analog(samples: [0, 5, 1, 2, -3, 4]), channel: 0, from: 0, to: 1, maxPoints: 2)
        #expect(trace.minVolts == [0, -3])
        #expect(trace.maxVolts == [5, 4])
        #expect(abs(trace.stepSeconds - 0.3) < 1e-9)
    }

    @Test("A window outside the samples is empty, not a crash", arguments: [(5.0, 6.0), (-5.0, -1.0)])
    func outside(from: Double, to: Double) throws {
        let trace = analogTrace(try analog(samples: [1, 2]), channel: 0, from: from, to: to, maxPoints: 2)
        #expect(trace.minVolts.isEmpty)
        #expect(trace.maxVolts.isEmpty)
    }

    @Test("Volts are rounded to the millivolt")
    func rounding() throws {
        #expect(analogTrace(try analog(samples: [1.23456]), channel: 0, from: 0, to: 1, maxPoints: 2).minVolts == [1.235])
    }

    @Test("Thinned extremes match a brute force calculation")
    func oracle() throws {
        var generator = SplitMix64(state: 0xA7A)
        for _ in 0..<500 {
            let samples = (0..<Int.random(in: 1...300, using: &generator)).map { _ in Float.random(in: -5...5, using: &generator) }
            let limit = Int.random(in: 1...50, using: &generator)
            let trace = analogTrace(try analog(samples: samples), channel: 0, from: 0, to: Double(samples.count) / 10, maxPoints: limit)
            let step = max(1, Int((Double(samples.count) / Double(limit)).rounded(.up)))
            #expect(trace.minVolts.count <= limit)
            for (index, chunk) in stride(from: 0, to: samples.count, by: step).map({ samples[$0..<min($0 + step, samples.count)] }).enumerated() {
                #expect(abs(trace.minVolts[index] - Double(chunk.min()!)) < 0.0006)
                #expect(abs(trace.maxVolts[index] - Double(chunk.max()!)) < 0.0006)
            }
        }
    }
}

@Suite("Timeline overlays")
struct TimelineOverlayTests {
    @Test("Rows become labeled annotations", arguments: [
        (row("start", 1), "S"),
        (row("stop", 1), "P"),
        (row("address", 1, ["address": "0x42", "read": "false"]), "0x42 W"),
        (row("address", 1, ["address": "0x42", "read": "true"]), "0x42 R"),
        (row("data", 1, ["data": "0xDE"]), "0xDE"),
        (row("tagged", 1, ["text": ">t", "scaled": "168"]), "168 >t"),
    ])
    func text(row: DecodedRow, expected: String) {
        #expect(timelineOverlay(uartDecoder, rows: [row], from: 0, to: 2, maxAnnotations: 9).annotations[0].text == expected)
    }

    @Test("SPI shows only the wired data lines")
    func spi() {
        let result = row("result", 1, ["mosi": "0xA5", "miso": "0x00"])
        let oneLine = ProtocolDecoder.spi(SPIDecoder(clock: 1, mosi: 2))
        #expect(timelineOverlay(oneLine, rows: [result], from: 0, to: 2, maxAnnotations: 9).annotations[0].text == "0xA5")
        let both = ProtocolDecoder.spi(SPIDecoder(clock: 1, mosi: 2, miso: 3))
        #expect(timelineOverlay(both, rows: [result], from: 0, to: 2, maxAnnotations: 9).annotations[0].text == "0xA5/0x00")
    }

    @Test("Enable markers are not annotated")
    func enable() {
        let rows = [row("enable", 1), row("disable", 1.2)]
        #expect(timelineOverlay(uartDecoder, rows: rows, from: 0, to: 2, maxAnnotations: 9).annotations.isEmpty)
    }

    @Test("Only rows overlapping the window appear, including those crossing its edges")
    func window() {
        let rows = [row("data", 0), row("data", 1.8), row("data", 3), row("data", 5)]
        let overlay = timelineOverlay(uartDecoder, rows: rows, from: 2, to: 4, maxAnnotations: 9)
        #expect(overlay.annotations.map(\.start) == [1.8, 3])
    }

    @Test("A row ending exactly at the window start still shows, and one starting at its end does not")
    func windowBoundary() {
        #expect(timelineOverlay(uartDecoder, rows: [row("data", 1.5)], from: 2, to: 4, maxAnnotations: 9).annotations.count == 1)
        #expect(timelineOverlay(uartDecoder, rows: [row("data", 4)], from: 2, to: 4, maxAnnotations: 9).annotations.isEmpty)
    }

    @Test("Errors and NACKs are flagged, but the NACK ending a read is not")
    func problems() {
        let rows = [
            row("data", 1, ["error": "framing"]),
            row("address", 2, ["read": "false", "ack": "false"]),
            row("address", 3, ["read": "true", "ack": "true"]),
            row("data", 3.5, ["ack": "false"]),
        ]
        let overlay = timelineOverlay(uartDecoder, rows: rows, from: 0, to: 5, maxAnnotations: 9)
        #expect(overlay.annotations.map(\.problem) == ["framing", "nack", nil, nil])
    }

    @Test("Over the limit, every problem is kept, then the earliest rows, in time order")
    func limit() {
        let rows = [
            row("data", 1), row("data", 2), row("data", 3), row("data", 4, ["error": "framing"]),
            row("data", 5), row("data", 6, ["error": "parity"]),
        ]
        let overlay = timelineOverlay(uartDecoder, rows: rows, from: 0, to: 9, maxAnnotations: 3)
        #expect(overlay.annotations.map(\.start) == [1, 4, 6])
        #expect(overlay.omitted == 3)
    }

    @Test("More problems than the limit are all kept")
    func manyProblems() {
        let rows = (0..<5).map { row("data", Double($0), ["error": "framing"]) }
        let overlay = timelineOverlay(uartDecoder, rows: rows, from: -1, to: 9, maxAnnotations: 2)
        #expect(overlay.annotations.count == 5)
        #expect(overlay.omitted == 0)
    }

    @Test("One over the limit leaves one out")
    func oneOver() {
        let rows = (0..<4).map { row("data", Double($0)) }
        let overlay = timelineOverlay(uartDecoder, rows: rows, from: -1, to: 9, maxAnnotations: 3)
        #expect(overlay.omitted == 1)
        #expect(overlay.annotations.count == 3)
    }

    @Test("At the limit nothing is left out")
    func atLimit() {
        let rows = (0..<3).map { row("data", Double($0)) }
        #expect(timelineOverlay(uartDecoder, rows: rows, from: -1, to: 9, maxAnnotations: 3).omitted == 0)
    }

    @Test("The label names the protocol and channels")
    func label() {
        let overlay = timelineOverlay(.spi(SPIDecoder(clock: 3, mosi: 4, enable: 5)), rows: [], from: 0, to: 1, maxAnnotations: 2)
        #expect(overlay.label == "SPI CH3,4,5")
        #expect(overlay.channels == [3, 4, 5])
    }
}

@Suite("Timeline windows")
struct TimelineWindowTests {
    @Test("The default window covers every channel")
    func defaults() throws {
        let timeline = try buildTimeline(
            TimelineInput(
                digital: [try line(1, [], begin: 1, end: 2), try line(2, [], begin: -1, end: 3)],
                analog: [(0, try analog(begin: 0, rate: 1, samples: [1, 1, 1, 1, 1]))], overlays: []),
            from: nil, to: nil, maxSegments: 10)
        #expect(timeline.fromSeconds == -1)
        #expect(timeline.toSeconds == 5)
    }

    @Test("A window is clamped to the capture")
    func clamped() throws {
        let timeline = try buildTimeline(
            TimelineInput(digital: [try line(1, [], begin: 0, end: 2)], analog: [], overlays: []),
            from: -5, to: 50, maxSegments: 10)
        #expect(timeline.fromSeconds == 0)
        #expect(timeline.toSeconds == 2)
    }

    @Test("Negative times work, for captures with a trigger")
    func negative() throws {
        let timeline = try buildTimeline(
            TimelineInput(digital: [try line(1, [-1], begin: -2, end: 2)], analog: [], overlays: []),
            from: -1.5, to: 1, maxSegments: 10)
        #expect(timeline.digital[0].segments.map(\.state) == [.low, .high])
    }

    @Test("An empty or outside window is an error", arguments: [(5.0, 9.0), (-9.0, -5.0), (1.0, 1.0)])
    func emptyWindow(from: Double, to: Double) throws {
        let input = TimelineInput(digital: [try line(1, [], begin: 0, end: 2)], analog: [], overlays: [])
        #expect(throws: TimelineError.emptyWindow) { try buildTimeline(input, from: from, to: to, maxSegments: 10) }
    }

    @Test("Nothing captured is an error")
    func nothing() {
        #expect(throws: TimelineError.emptyWindow) {
            try buildTimeline(TimelineInput(digital: [], analog: [], overlays: []), from: nil, to: nil, maxSegments: 10)
        }
    }
}

private func sampleTimeline() -> Timeline {
    Timeline(
        fromSeconds: 0, toSeconds: 1,
        digital: [
            DigitalTrace(channel: 3, edges: 1, segments: [
                TraceSegment(start: 0, end: 0.5, state: .low, edges: 0), TraceSegment(start: 0.5, end: 1, state: .high, edges: 0),
            ]),
            DigitalTrace(channel: 6, edges: 9, segments: [TraceSegment(start: 0, end: 1, state: .active, edges: 9)]),
        ],
        analog: [AnalogTrace(channel: 0, startSeconds: 0, stepSeconds: 0.5, minVolts: [0, 1], maxVolts: [1, 3])],
        overlays: [
            TimelineOverlay(
                label: "UART CH3", channels: [3],
                annotations: [
                    TimelineAnnotation(start: 0.1, end: 0.4, text: "<A&B>", problem: nil),
                    TimelineAnnotation(start: 0.5, end: 0.8, text: "0x42", problem: "framing"),
                ], omitted: 0)
        ])
}

@Suite("Timeline drawing")
struct TimelineRenderTests {
    private func occurrences(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("Hostile text is escaped everywhere it can appear")
    func escaping() {
        var timeline = sampleTimeline()
        timeline.overlays[0].label = "</text><script>x</script>"
        let svg = renderTimelineSVG(timeline, title: "<img src=x onerror=y>")
        #expect(!svg.contains("<script"))
        #expect(!svg.contains("<img"))
        #expect(!svg.contains("<A&B>"))
        #expect(svg.contains("&lt;A&amp;B&gt;"))
    }

    @Test("Text escaping covers XML's special characters and control bytes", arguments: [
        ("a&b", "a&amp;b"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"), ("'", "&apos;"), ("\n", "\\n"), ("\r", "\\r"),
        ("\t", "\\t"), ("\u{01}", "?"), ("\u{1F}", "?"), ("\u{FFFF}", "?"), ("é", "é"),
    ])
    func escape(text: String, expected: String) {
        #expect(xmlEscaped(text) == expected)
    }

    @Test("The same data draws identically")
    func deterministic() {
        #expect(renderTimelineSVG(sampleTimeline(), title: "t") == renderTimelineSVG(sampleTimeline(), title: "t"))
    }

    @Test("It draws one trace per digital channel, and active spans as bands")
    func rows() {
        let svg = renderTimelineSVG(sampleTimeline(), title: nil)
        #expect(occurrences(#"class="trace""#, in: svg) == 2)
        #expect(occurrences("<title>9 edges</title>", in: svg) == 1)
        #expect(occurrences(#"class="analog""#, in: svg) == 1)
        #expect(svg.contains(">D3<") && svg.contains(">D6<") && svg.contains(">A0<"))
    }

    @Test("Problems look different and say what is wrong")
    func problems() {
        let svg = renderTimelineSVG(sampleTimeline(), title: nil)
        #expect(occurrences(#"class="bad""#, in: svg) == 1)
        #expect(svg.contains("<title>0x42: framing</title>"))
    }

    @Test("Text is only drawn where it fits")
    func fitting() {
        var timeline = sampleTimeline()
        timeline.overlays[0].annotations = [TimelineAnnotation(start: 0.1, end: 0.1001, text: "toolongtofit", problem: nil)]
        let svg = renderTimelineSVG(timeline, title: nil)
        #expect(svg.contains("<title>toolongtofit</title>"))
        #expect(!svg.contains(">toolongtofit</text>"))
    }

    @Test("An overlay sits under its channel's row")
    func placement() throws {
        let svg = renderTimelineSVG(sampleTimeline(), title: nil)
        let label = try #require(svg.range(of: "UART CH3"))
        let before = try #require(svg.range(of: ">D3<"))
        let after = try #require(svg.range(of: ">D6<"))
        #expect(before.lowerBound < label.lowerBound)
        #expect(label.lowerBound < after.lowerBound)
    }

    @Test("Omitted annotations are visible in the label")
    func omitted() {
        var timeline = sampleTimeline()
        timeline.overlays[0].omitted = 7
        #expect(renderTimelineSVG(timeline, title: nil).contains("UART CH3 +7"))
    }

    @Test("An overlay with no matching channel is still drawn")
    func orphanOverlay() {
        var timeline = sampleTimeline()
        timeline.overlays[0].channels = [15]
        #expect(renderTimelineSVG(timeline, title: nil).contains("UART CH3"))
    }

    @Test("An analog channel with no points draws only its label")
    func emptyAnalog() {
        var timeline = sampleTimeline()
        timeline.analog[0].minVolts = []
        timeline.analog[0].maxVolts = []
        let svg = renderTimelineSVG(timeline, title: nil)
        #expect(svg.contains(">A0<"))
        #expect(!svg.contains(#"class="analog""#))
    }

    @Test("A steady analog level does not divide by zero")
    func steadyAnalog() {
        var timeline = sampleTimeline()
        timeline.analog[0].minVolts = [1, 1]
        timeline.analog[0].maxVolts = [1, 1]
        let svg = renderTimelineSVG(timeline, title: nil)
        #expect(!svg.contains("nan") && !svg.contains("inf"))
    }

    @Test("A page stands alone, with its title, and fetches nothing")
    func page() {
        let html = renderTimelineHTML(sampleTimeline(), title: "a<b")
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<title>a&lt;b</title>"))
        #expect(html.contains("<svg"))
        #expect(html.contains("prefers-color-scheme"))
        #expect(!html.contains("http://") || !html.replacingOccurrences(of: "http://www.w3.org/2000/svg", with: "").contains("http"))
        #expect(!html.contains("<script"))
    }

    @Test("Without a title the page still has one, and the drawing has none")
    func noTitle() {
        #expect(renderTimelineHTML(sampleTimeline(), title: nil).contains("<title>sal timeline</title>"))
        #expect(!renderTimelineSVG(sampleTimeline(), title: nil).contains(#"class="title""#))
    }

    @Test("Tick spacing is 1, 2 or 5 times a power of ten", arguments: [
        (10.0, 10, 1.0), (1.2, 10, 0.2), (3.0, 10, 0.5), (0.0007, 10, 0.0001), (7.0, 10, 1.0), (20.0, 10, 2.0), (21.0, 10, 5.0),
    ])
    func ticks(span: Double, count: Int, expected: Double) {
        #expect(abs(niceTickStep(span: span, count: count) - expected) < expected * 1e-9)
    }

    @Test("A degenerate span gets a usable step", arguments: [0.0, -1.0, Double.infinity])
    func degenerate(span: Double) {
        #expect(niceTickStep(span: span, count: 10) == 1)
    }

    @Test("Tick labels show zero and negative times", arguments: [
        (0.0, "0"), (1e-15, "0"), (0.002, "2.000 ms"), (-0.002, "-2.000 ms"),
    ])
    func tickLabels(seconds: Double, expected: String) {
        #expect(formatTickTime(seconds) == expected)
    }

    @Test("Random timelines always draw well-formed XML")
    func wellFormed() throws {
        var generator = SplitMix64(state: 0x5D6)
        let alphabet = Array("<>&\"'ab \n\u{01}é")
        func words() -> String { String((0..<Int.random(in: 0...8, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }) }
        for _ in 0..<300 {
            let text = words()
            var timeline = sampleTimeline()
            timeline.overlays[0].label = words()
            timeline.overlays[0].annotations[0].text = text
            timeline.overlays[0].annotations[1].problem = words()
            let svg = renderTimelineSVG(timeline, title: words())
            let parser = XMLParser(data: Data(svg.utf8))
            #expect(parser.parse(), "\(parser.parserError.map(String.init(describing:)) ?? "")")
        }
    }

    @Test("The summary reports channels, overlays and what is missing")
    func summary() {
        var timeline = sampleTimeline()
        timeline.overlays[0].omitted = 2
        #expect(describe(timeline) == [
            "0 to 1.000 s", "D3  1 edges, 2 segments", "D6  9 edges, 1 segments", "A0  2 points",
            "UART CH3  2 items, 1 problems, 2 more not shown",
        ])
    }
}

@Suite("Timeline arguments")
struct TimelineArgumentTests {
    private func parse(_ arguments: [String]) throws -> TimelineCommand {
        try #require(try Sal.parseAsRoot(["timeline"] + arguments) as? TimelineCommand)
    }

    @Test("Time points take units, zero and negatives", arguments: [
        ("0", 0.0), ("12ms", 0.012), ("-3us", -3e-6), ("1.5", 1.5),
    ])
    func timePoints(text: String, expected: Double) throws {
        #expect(abs(try #require(TimePoint(argument: text)).seconds - expected) < 1e-12)
    }

    @Test("Bad time points are refused", arguments: ["", "x", "nan", "inf", "1xs"])
    func badTimePoints(text: String) {
        #expect(TimePoint(argument: text) == nil)
    }

    @Test("Overlays accept what identify prints", arguments: [
        ("uart --channel 2 --baud 115200", ProtocolDecoder.uart(UARTDecoder(channel: 2, baud: 115_200))),
        ("sal decode uart --channel 2 --baud 9600 --parity even", .uart(UARTDecoder(channel: 2, baud: 9600, parity: .even))),
        ("spi --clock 3 --mosi 4 --enable 5", .spi(SPIDecoder(clock: 3, mosi: 4, enable: 5))),
        ("  i2c   --sda 6 --scl=7 ", .i2c(I2CDecoder(sda: 6, scl: 7))),
    ])
    func overlays(text: String, expected: ProtocolDecoder) throws {
        #expect(try parseOverlay(text) == expected)
    }

    @Test("Identify's commands all work as overlays")
    func identifyRoundTrip() throws {
        let decoders: [ProtocolDecoder] = [
            .uart(UARTDecoder(channel: 1, baud: 9600, parity: .odd, inverted: true)),
            .spi(SPIDecoder(clock: 1, mosi: 2, miso: 3, enable: 4, clockIdlesHigh: true, dataOnTrailingEdge: true, enableActiveHigh: true)),
            .i2c(I2CDecoder(sda: 1, scl: 2)),
        ]
        for decoder in decoders {
            #expect(try parseOverlay(decoder.command) == decoder)
        }
    }

    @Test("Bad overlays are refused", arguments: [
        "", "can --channel 2", "uart --channel 2", "uart --channel 2 --baud 9600 --duration 5",
        "uart --channel 2 --baud 9600 --load=/x.sal", "i2c --sda 1 --scl 1", "--help", "uart --help",
    ])
    func badOverlays(text: String) {
        #expect(throws: (any Error).self) { try parseOverlay(text) }
    }

    @Test("Valid command lines are accepted", arguments: [
        [String](), ["--from", "0", "--to", "1ms"], ["--from", "-1ms", "--to", "0"], ["--max-segments", "2"],
        ["--max-segments", "100000"], ["--channels", "none", "--analog", "0"], ["--overlay", "uart --channel 2 --baud 9600"],
        ["--html", "/a.html", "--svg", "/a.svg", "--title", "x"], ["--radix", "ascii"],
    ])
    func accepted(arguments: [String]) {
        #expect(throws: Never.self) { try parse(arguments) }
    }

    @Test("Invalid command lines are refused", arguments: [
        ["--from", "2", "--to", "1"], ["--from", "1", "--to", "1"], ["--max-segments", "1"], ["--max-segments", "100001"],
        ["--channels", "none"], ["--overlay", "nope"], ["--radix", "octal"], ["--analog", "0", "--analog-downsample", "0"],
    ])
    func refused(arguments: [String]) {
        #expect(throws: (any Error).self) { try parse(arguments) }
    }

    @Test("MCP arguments become a command, thin by default")
    func toolLine() throws {
        #expect(try timelineCommandLine(.object(["from": .string("0")])) == ["timeline", "--from=0", "--max-segments=100"])
        let explicit = try timelineCommandLine(.object(["max_segments": .int(5)]))
        #expect(explicit == ["timeline", "--max-segments=5"])
        let overlays = try timelineCommandLine(.object(["overlay": .array([.string("i2c --sda 1 --scl 2")]), "max_segments": .int(5)]))
        #expect(overlays == ["timeline", "--max-segments=5", "--overlay=i2c --sda 1 --scl 2"])
    }

    @Test("MCP refuses arguments from other tools")
    func toolUnknown() {
        #expect(throws: ToolInputError.self) { try timelineCommandLine(.object(["bus": .string("x")])) }
    }

    @Test("A manual timeline through MCP must have an end")
    func toolManual() async {
        await #expect(throws: (any Error).self) { try await SalTools().call(name: "timeline", arguments: .object(["manual": .bool(true)])) }
    }

    @Test("Every schema field is a real flag")
    func parity() throws {
        let schema = try #require(toolDefinitions.first { $0["name"]?.stringValue == "timeline" }?["inputSchema"])
        guard case .object(let properties)? = schema["properties"] else {
            Issue.record("no properties")
            return
        }
        let help = Sal.helpMessage(for: TimelineCommand.self, columns: 400)
        for key in properties.keys {
            #expect(help.contains("--" + key.replacingOccurrences(of: "_", with: "-")), "\(key)")
        }
    }
}
