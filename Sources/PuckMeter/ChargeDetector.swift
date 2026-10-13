import Foundation

/// Turns noisy port power readings into a stable state. Thresholds come from
/// measurements: idle 8 s averages peaked at 0.47 W, charging never fell below 1.25 W.
/// A full iPhone keeps drawing about 2 W from a Mac port, so "full" is not detectable.
struct ChargeDetector {
    private static let presenceWindow: TimeInterval = 8
    private static let presentAboveWatts = 1.0
    private static let absentBelowWatts = 0.7

    private var samples: [(date: Date, watts: Double)] = []
    private var phonePresent = false

    mutating func add(_ power: PortPower) -> ChargingState {
        let now = power.measuredAt
        samples.append((now, power.watts))
        samples.removeAll { now.timeIntervalSince($0.date) > Self.presenceWindow }

        let recent = average(since: now.addingTimeInterval(-Self.presenceWindow))
        if !phonePresent, recent >= Self.presentAboveWatts {
            phonePresent = true
        } else if phonePresent, recent < Self.absentBelowWatts {
            phonePresent = false
        }
        return phonePresent ? .charging : .noPhone
    }

    func smoothedWatts(at date: Date) -> Double {
        average(since: date.addingTimeInterval(-5))
    }

    private func average(since start: Date) -> Double {
        let window = samples.filter { $0.date >= start }
        guard !window.isEmpty else { return samples.last?.watts ?? 0 }
        return window.map(\.watts).reduce(0, +) / Double(window.count)
    }
}
