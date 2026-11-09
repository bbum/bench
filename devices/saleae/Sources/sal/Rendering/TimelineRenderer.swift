import Foundation

/// Draws a timeline as SVG. Everything drawn comes straight from the data, and the same
/// input always gives the same output.
func renderTimelineSVG(_ timeline: Timeline, title: String?) -> String {
    let layout = TimelineLayout(timeline)
    var body: [String] = []

    if let title {
        body.append(#"<text class="title" x="\#(layout.left)" y="20">\#(xmlEscaped(title))</text>"#)
    }
    body += layout.ticks()

    var y = layout.firstRowY
    let lastDigitalIndex = { (channels: [UInt32]) in
        channels.compactMap { channel in timeline.digital.firstIndex { $0.channel == channel } }.max()
    }
    for (index, trace) in timeline.digital.enumerated() {
        body += layout.digitalRow(trace, y: y)
        y += layout.digitalHeight
        for overlay in timeline.overlays where lastDigitalIndex(overlay.channels) == index {
            body += layout.overlayRow(overlay, y: y)
            y += layout.overlayHeight
        }
    }
    for overlay in timeline.overlays where lastDigitalIndex(overlay.channels) == nil {
        body += layout.overlayRow(overlay, y: y)
        y += layout.overlayHeight
    }
    for trace in timeline.analog {
        body += layout.analogRow(trace, y: y)
        y += layout.analogHeight
    }

    let height = y + 12
    return #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \#(layout.width) \#(format(height))" role="img">"#
        + "<style>\(timelineStyle)</style>"
        + #"<rect class="page" width="\#(layout.width)" height="\#(format(height))"/>"#
        + body.joined() + "</svg>"
}

func renderTimelineHTML(_ timeline: Timeline, title: String?) -> String {
    let name = xmlEscaped(title ?? "sal timeline")
    return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>\(name)</title>"
        + "<style>body{margin:0;background:#fff}@media(prefers-color-scheme:dark){body{background:#14171c}}svg{display:block;width:100%;height:auto}</style>"
        + "</head><body>\(renderTimelineSVG(timeline, title: title))</body></html>\n"
}

func xmlEscaped(_ text: String) -> String {
    var escaped = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": escaped += "&amp;"
        case "<": escaped += "&lt;"
        case ">": escaped += "&gt;"
        case "\"": escaped += "&quot;"
        case "'": escaped += "&apos;"
        case "\n": escaped += "\\n"
        case "\r": escaped += "\\r"
        case "\t": escaped += "\\t"
        // These cannot appear in XML at all, even escaped.
        case _ where scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF:
            escaped += "?"
        default: escaped.unicodeScalars.append(scalar)
        }
    }
    return escaped
}

/// A round spacing of 1, 2 or 5 times a power of ten, giving about `count` ticks.
func niceTickStep(span: Double, count: Int) -> Double {
    guard span > 0, span.isFinite else { return 1 }
    let rough = span / Double(count)
    let magnitude = pow(10, floor(log10(rough)))
    let scaled = rough / magnitude
    let nice: Double = scaled <= 1 ? 1 : scaled <= 2 ? 2 : scaled <= 5 ? 5 : 10
    return nice * magnitude
}

func formatTickTime(_ seconds: Double) -> String {
    if abs(seconds) < 1e-12 { return "0" }
    return (seconds < 0 ? "-" : "") + formatSeconds(abs(seconds))
}

private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private let timelineStyle = """
    :root{--ink:#1c2127;--muted:#6a7380;--grid:#e3e6ea;--page:#fff;--trace:#1769aa;--band:#1769aa;--note:#e6eef6;--bad:#fbe3e0;--bad-ink:#b3261e;--analog:#2e7d4f}\
    @media(prefers-color-scheme:dark){:root{--ink:#e7eaee;--muted:#98a2ae;--grid:#2b3038;--page:#14171c;--trace:#6ab7f5;--band:#6ab7f5;--note:#20303f;--bad:#4a2320;--bad-ink:#ffb4ab;--analog:#6fd19a}}\
    text{font:12px ui-monospace,Menlo,monospace;fill:var(--ink)}.title{font-size:15px;font-weight:600}.muted{fill:var(--muted)}.page{fill:var(--page)}\
    .grid{stroke:var(--grid);stroke-width:1}.trace{fill:none;stroke:var(--trace);stroke-width:1.5}.active{fill:var(--band);opacity:.45}\
    .note{fill:var(--note);stroke:var(--trace);stroke-width:.5}.bad{fill:var(--bad);stroke:var(--bad-ink);stroke-width:1}.bad-text{fill:var(--bad-ink)}\
    .analog{fill:var(--analog);stroke:var(--analog);stroke-width:1;opacity:.75}
    """

private struct TimelineLayout {
    let timeline: Timeline
    let width = 1600.0
    let left = 120.0
    let right = 16.0
    let digitalHeight = 34.0
    let overlayHeight = 26.0
    let analogHeight = 96.0
    let firstRowY = 54.0

    init(_ timeline: Timeline) { self.timeline = timeline }

    private var plotWidth: Double { width - left - right }
    private var span: Double { max(timeline.toSeconds - timeline.fromSeconds, .leastNonzeroMagnitude) }

    func x(_ time: Double) -> Double {
        let clamped = min(max(time, timeline.fromSeconds), timeline.toSeconds)
        return left + (clamped - timeline.fromSeconds) / span * plotWidth
    }

    func ticks() -> [String] {
        let step = niceTickStep(span: span, count: 10)
        var parts: [String] = []
        var multiple = (timeline.fromSeconds / step).rounded(.up)
        var time = multiple * step
        let bottom = totalRowsHeight() + firstRowY
        while time <= timeline.toSeconds {
            let position = format(x(time))
            parts.append(#"<line class="grid" x1="\#(position)" x2="\#(position)" y1="40" y2="\#(format(bottom))"/>"#)
            parts.append(#"<text class="muted" x="\#(position)" y="34" text-anchor="middle">\#(xmlEscaped(formatTickTime(time)))</text>"#)
            multiple += 1
            time = multiple * step
        }
        return parts
    }

    private func totalRowsHeight() -> Double {
        Double(timeline.digital.count) * digitalHeight + Double(timeline.overlays.count) * overlayHeight
            + Double(timeline.analog.count) * analogHeight
    }

    func digitalRow(_ trace: DigitalTrace, y: Double) -> [String] {
        let high = y + 6
        let low = y + digitalHeight - 8
        var parts = [#"<text x="8" y="\#(format((high + low) / 2 + 4))">D\#(trace.channel)</text>"#]
        var path = ""
        var active = ""
        for segment in trace.segments {
            let (from, to) = (x(segment.start), x(segment.end))
            if segment.state == .active {
                active += #"<rect class="active" x="\#(format(from))" y="\#(format(high))" width="\#(format(max(to - from, 1)))" height="\#(format(low - high))"><title>\#(segment.edges) edges</title></rect>"#
                path += "M\(format(to)) \(format(low))"
                continue
            }
            let level = segment.state == .high ? high : low
            path += path.isEmpty ? "M\(format(from)) \(format(level))" : "V\(format(level))"
            path += "H\(format(to))"
        }
        parts.append(active)
        parts.append(#"<path class="trace" d="\#(path)"/>"#)
        return parts
    }

    func overlayRow(_ overlay: TimelineOverlay, y: Double) -> [String] {
        let suffix = overlay.omitted > 0 ? " +\(overlay.omitted)" : ""
        var parts = [#"<text class="muted" x="8" y="\#(format(y + 16))">\#(xmlEscaped(overlay.label + suffix))</text>"#]
        for annotation in overlay.annotations {
            let (from, to) = (x(annotation.start), x(annotation.end))
            let boxWidth = max(to - from, 1)
            let tooltip = annotation.problem.map { "\(annotation.text): \($0)" } ?? annotation.text
            parts.append(
                #"<rect class="\#(annotation.problem == nil ? "note" : "bad")" x="\#(format(from))" y="\#(format(y + 3))" width="\#(format(boxWidth))" height="19" rx="2"><title>\#(xmlEscaped(tooltip))</title></rect>"#)
            if boxWidth >= Double(annotation.text.count) * 7.4 {
                let cls = annotation.problem == nil ? "" : #" class="bad-text""#
                parts.append(#"<text\#(cls) x="\#(format(from + boxWidth / 2))" y="\#(format(y + 16))" text-anchor="middle">\#(xmlEscaped(annotation.text))</text>"#)
            }
        }
        return parts
    }

    func analogRow(_ trace: AnalogTrace, y: Double) -> [String] {
        var parts = [#"<text x="8" y="\#(format(y + 50))">A\#(trace.channel)</text>"#]
        guard let low = trace.minVolts.min(), let high = trace.maxVolts.max() else { return parts }
        let (top, bottom) = (y + 8, y + analogHeight - 10)
        let range = max(high - low, 0.001)
        func vertical(_ volts: Double) -> Double { bottom - (volts - low) / range * (bottom - top) }

        parts.append(#"<text class="muted" x="60" y="\#(format(top + 9))">\#(String(format: "%.2f V", high))</text>"#)
        parts.append(#"<text class="muted" x="60" y="\#(format(bottom))">\#(String(format: "%.2f V", low))</text>"#)

        var upper: [String] = []
        var lower: [String] = []
        for index in trace.minVolts.indices {
            let time = x(trace.startSeconds + Double(index) * trace.stepSeconds)
            upper.append("\(format(time)),\(format(vertical(trace.maxVolts[index])))")
            lower.append("\(format(time)),\(format(vertical(trace.minVolts[index])))")
        }
        parts.append(#"<polygon class="analog" points="\#((upper + lower.reversed()).joined(separator: " "))"/>"#)
        return parts
    }
}
