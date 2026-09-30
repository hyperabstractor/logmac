import Foundation
import Observation
import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable {
    case auto, dots, bars
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .dots: "Dots"
        case .bars: "Bars"
        }
    }
}

enum Level {
    case normal, warm, alert

    /// Metrics within this many points of their threshold show as "warm".
    static let warmBand: Double = 15
    /// CPU temperature bands, in °C.
    static let tempWarm: Double = 80
    static let tempHot: Double = 95

    var dotColor: Color {
        switch self {
        case .normal: .green
        case .warm: .orange
        case .alert: .red
        }
    }

    var barColor: Color {
        switch self {
        case .normal: .blue
        case .warm: .orange
        case .alert: .red
        }
    }

    static func of(value: Double?, threshold: Double, alerting: Bool) -> Level {
        if alerting { return .alert }
        guard let value else { return .normal }
        return value >= threshold - warmBand ? .warm : .normal
    }

    static func ofTemperature(_ celsius: Double?) -> Level {
        guard let celsius else { return .normal }
        if celsius >= tempHot { return .alert }
        if celsius >= tempWarm { return .warm }
        return .normal
    }
}

/// Debounced threshold alerts: a metric must stay over its threshold before alerting,
/// and clearly below it before the alert clears, so the menu bar doesn't flicker.
struct AlertTracker {
    /// A metric must stay above its threshold this long before the menu bar expands.
    static let engageDelay: TimeInterval = 3
    /// And below (threshold - hysteresis) this long before it collapses again.
    static let releaseDelay: TimeInterval = 8
    static let hysteresis: Double = 5

    private(set) var alerting: Set<Metric> = []
    private var aboveSince: [Metric: Date] = [:]
    private var belowSince: [Metric: Date] = [:]

    mutating func update(values: [Metric: Double], threshold: (Metric) -> Double, now: Date) {
        for metric in Metric.allCases {
            guard let value = values[metric] else { continue }
            let limit = threshold(metric)

            if alerting.contains(metric) {
                if value < limit - Self.hysteresis {
                    let since = belowSince[metric] ?? now
                    belowSince[metric] = since
                    if now.timeIntervalSince(since) >= Self.releaseDelay {
                        alerting.remove(metric)
                        belowSince[metric] = nil
                    }
                } else {
                    belowSince[metric] = nil
                }
            } else if value >= limit {
                let since = aboveSince[metric] ?? now
                aboveSince[metric] = since
                // Disk usage moves slowly, so there's no point debouncing it.
                let delay = metric == .ssd ? 0 : Self.engageDelay
                if now.timeIntervalSince(since) >= delay {
                    alerting.insert(metric)
                    aboveSince[metric] = nil
                }
            } else {
                aboveSince[metric] = nil
            }
        }
    }
}

@MainActor
@Observable
final class StatsModel {
    private(set) var snapshot = Snapshot()
    private(set) var alerts = AlertTracker()
    var alerting: Set<Metric> { alerts.alerting }

    var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") }
    }

    var useFahrenheit: Bool {
        didSet { defaults.set(useFahrenheit, forKey: "useFahrenheit") }
    }

    private(set) var thresholds: [Metric: Double]

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private let queue = DispatchQueue(label: "logmac.sampler", qos: .utility)
    @ObservationIgnored private var timer: Timer?

    init() {
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .auto
        useFahrenheit = defaults.bool(forKey: "useFahrenheit")
        var thresholds: [Metric: Double] = [:]
        for metric in Metric.allCases {
            let stored = defaults.double(forKey: "threshold.\(metric.rawValue)")
            thresholds[metric] = stored > 0 ? stored : metric.defaultThreshold
        }
        self.thresholds = thresholds
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func threshold(for metric: Metric) -> Double {
        thresholds[metric] ?? metric.defaultThreshold
    }

    func setThreshold(_ value: Double, for metric: Metric) {
        thresholds[metric] = value
        defaults.set(value, forKey: "threshold.\(metric.rawValue)")
        updateAlerts(now: .now)
    }

    func value(_ metric: Metric) -> Double? {
        snapshot.values[metric]
    }

    func level(_ metric: Metric) -> Level {
        Level.of(value: value(metric), threshold: threshold(for: metric), alerting: alerting.contains(metric))
    }

    /// The alerting metric furthest over its threshold, shown as the menu bar label.
    var primaryAlert: Metric? {
        alerting.max { overshoot($0) < overshoot($1) }
    }

    var tempLevel: Level {
        Level.ofTemperature(snapshot.cpuTemp)
    }

    func formatTemp(_ celsius: Double?) -> String {
        guard let celsius else { return "--°" }
        let value = useFahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°"
    }

    private func overshoot(_ metric: Metric) -> Double {
        (value(metric) ?? 0) - threshold(for: metric)
    }

    private func refresh() {
        queue.async { [sampler] in
            let snapshot = sampler.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(snapshot) }
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        updateAlerts(now: .now)
    }

    private func updateAlerts(now: Date) {
        alerts.update(values: snapshot.values, threshold: threshold(for:), now: now)
    }
}
