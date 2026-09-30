import SwiftUI

/// The menu bar content: temperature, then dots (idle) or bars plus the alerting metric.
struct StatusItemView: View {
    let model: StatsModel
    var onWidthChange: (CGFloat) -> Void

    private var showsBars: Bool {
        switch model.displayMode {
        case .auto: !model.alerting.isEmpty
        case .dots: false
        case .bars: true
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(model.formatTemp(model.snapshot.cpuTemp))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(model.tempLevel == .normal ? Color.primary : model.tempLevel.barColor)

            if showsBars {
                MiniBars(model: model)
                if model.displayMode != .dots, let metric = model.primaryAlert {
                    AlertLabel(metric: metric, value: model.value(metric) ?? 0)
                }
            } else {
                Dots(model: model)
            }
        }
        .padding(.horizontal, 6)
        .fixedSize()
        .background(GeometryReader { Color.clear.preference(key: WidthKey.self, value: $0.size.width) })
        .onPreferenceChange(WidthKey.self) { if $0 > 0 { onWidthChange($0) } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.25), value: showsBars)
    }
}

private struct Dots: View {
    let model: StatsModel

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Metric.allCases) { metric in
                Circle()
                    .fill(model.level(metric).dotColor)
                    .frame(width: 5, height: 5)
            }
        }
        .transition(.opacity)
    }
}

private struct MiniBars: View {
    let model: StatsModel
    private let barHeight: CGFloat = 12

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Metric.allCases) { metric in
                VStack(spacing: 1) {
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(Color.primary.opacity(0.18))
                        Rectangle()
                            .fill(model.level(metric).barColor)
                            .frame(height: barHeight * fraction(metric))
                    }
                    .frame(width: 4, height: barHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))

                    Text(metric.letter)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .transition(.opacity)
    }

    private func fraction(_ metric: Metric) -> CGFloat {
        CGFloat(min(max((model.value(metric) ?? 0) / 100, 0), 1))
    }
}

private struct AlertLabel: View {
    let metric: Metric
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(metric.label)
                .font(.system(size: 7, weight: .semibold))
            Text("\(Int(value.rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.red)
        .transition(.opacity)
    }
}

private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
