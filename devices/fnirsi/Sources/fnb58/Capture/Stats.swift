import Foundation

/// Rounds for output, so JSON shows 0.3 rather than 0.30000000000000004.
func rounded(_ value: Double, _ places: Int = 6) -> Double {
    let scale = pow(10, Double(places))
    return (value * scale).rounded() / scale
}

/// Statistics over evenly spaced samples, 1/100 s apart.
struct Stats: Encodable, Equatable, Sendable {
    struct Current: Encodable, Equatable, Sendable {
        var mean: Double
        var peak: Double
        var p99: Double
        var min: Double
        /// Time of the first sample at the peak.
        var peakAt: Double
    }

    struct Voltage: Encodable, Equatable, Sendable {
        var min: Double
        var max: Double
        var mean: Double
    }

    struct Power: Encodable, Equatable, Sendable {
        var mean: Double
        var peak: Double
    }

    var samples: Int
    var durationSeconds: Double
    var currentA: Current
    var voltageV: Voltage
    var powerW: Power
    var energyMWh: Double
    var chargeMAh: Double

    enum CodingKeys: String, CodingKey {
        case samples
        case durationSeconds = "duration_s"
        case currentA = "current_A"
        case voltageV = "voltage_V"
        case powerW = "power_W"
        case energyMWh = "energy_mWh"
        case chargeMAh = "charge_mAh"
    }

    /// `times` are the samples' own times, used only to report when the peak happened.
    /// Nil when there are no samples.
    init?(times: [Double], voltage: [Double], current: [Double]) {
        let count = min(times.count, voltage.count, current.count)
        guard count > 0 else { return nil }
        let interval = 1 / FNB58.sampleRate
        var currentSum = 0.0, voltageSum = 0.0, powerSum = 0.0
        var peak = -Double.infinity, peakIndex = 0, powerPeak = -Double.infinity
        var voltageMin = Double.infinity, voltageMax = -Double.infinity, currentMin = Double.infinity
        for index in 0..<count {
            let v = voltage[index], i = current[index], p = v * i
            currentSum += i
            voltageSum += v
            powerSum += p
            if i > peak { peak = i; peakIndex = index }
            currentMin = Swift.min(currentMin, i)
            voltageMin = Swift.min(voltageMin, v)
            voltageMax = Swift.max(voltageMax, v)
            powerPeak = Swift.max(powerPeak, p)
        }
        let n = Double(count)
        samples = count
        durationSeconds = rounded(n * interval, 2)
        currentA = Current(
            mean: rounded(currentSum / n), peak: rounded(peak),
            p99: rounded(percentile(Array(current[0..<count]), 0.99)), min: rounded(currentMin),
            peakAt: rounded(times[peakIndex], 2))
        voltageV = Voltage(min: rounded(voltageMin), max: rounded(voltageMax), mean: rounded(voltageSum / n))
        powerW = Power(mean: rounded(powerSum / n), peak: rounded(powerPeak))
        // Each sample stands for 10 ms. W·s / 3.6 = mWh; A·s / 3.6 = mAh.
        energyMWh = rounded(powerSum * interval / 3.6, 4)
        chargeMAh = rounded(currentSum * interval / 3.6, 4)
    }
}

extension Stats.Current {
    enum CodingKeys: String, CodingKey {
        case mean, peak, p99, min
        case peakAt = "peak_at_s"
    }
}

/// Nearest-rank percentile: the smallest value with at least `fraction` of values at or below it.
func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank - 1))]
}
