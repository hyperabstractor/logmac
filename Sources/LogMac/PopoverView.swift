import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @Bindable var model: StatsModel
    @State private var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Card {
                ForEach(Metric.allCases) { metric in
                    MetricRow(model: model, metric: metric)
                    if metric != Metric.allCases.last { Divider() }
                }
            }

            Card {
                HStack {
                    Label("Network", systemImage: "network")
                    Spacer()
                    NetRate(symbol: "arrow.up", color: .red, bytesPerSecond: model.snapshot.netOut)
                    NetRate(symbol: "arrow.down", color: .blue, bytesPerSecond: model.snapshot.netIn)
                }
                .font(.system(size: 12))
            }

            if showsSettings {
                SettingsSection(model: model)
            }

            HStack {
                Button(showsSettings ? "Done" : "Settings") {
                    withAnimation(.snappy) { showsSettings.toggle() }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.formatTemp(model.snapshot.cpuTemp))
                .font(.system(size: 30, weight: .semibold).monospacedDigit())
                .foregroundStyle(model.tempLevel == .normal ? Color.primary : model.tempLevel.barColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("CPU temperature").font(.system(size: 12, weight: .medium))
                Text(tempSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var tempSubtitle: String {
        var parts: [String] = []
        if let gpu = model.snapshot.gpuTemp { parts.append("GPU \(model.formatTemp(gpu))") }
        parts.append("hottest \(model.formatTemp(model.snapshot.hottestTemp))")
        return parts.joined(separator: " · ")
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MetricRow: View {
    let model: StatsModel
    let metric: Metric

    var body: some View {
        let value = model.value(metric)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: metric.symbol)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(metric.title)
                Spacer()
                if let detail {
                    Text(detail).foregroundStyle(.secondary)
                }
                Text(value.map { "\(Int($0.rounded()))%" } ?? "--")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            }
            .font(.system(size: 12))

            ThresholdBar(
                fraction: (value ?? 0) / 100,
                threshold: model.threshold(for: metric) / 100,
                color: model.level(metric).barColor
            )
        }
    }

    private var detail: String? {
        let s = model.snapshot
        switch metric {
        case .ram where s.memTotal > 0:
            return "\(bytes(Int64(s.memUsed), .memory)) of \(bytes(Int64(s.memTotal), .memory))"
        case .ssd where s.diskTotal > 0:
            return "\(bytes(s.diskUsed, .file)) of \(bytes(s.diskTotal, .file))"
        default:
            return nil
        }
    }
}

/// A progress bar with a tick marking the alert threshold.
private struct ThresholdBar: View {
    let fraction: Double
    let threshold: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
                Rectangle()
                    .fill(Color.primary.opacity(0.45))
                    .frame(width: 1.5, height: 9)
                    .offset(x: geo.size.width * threshold - 0.75)
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

private struct NetRate: View {
    let symbol: String
    let color: Color
    let bytesPerSecond: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(bytes(Int64(bytesPerSecond), .file))/s")
                .monospacedDigit()
                .frame(minWidth: 62, alignment: .trailing)
        }
    }
}

private struct SettingsSection: View {
    @Bindable var model: StatsModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Card {
            Picker("Menu bar", selection: $model.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Text("Alert when above")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(Metric.allCases) { metric in
                Stepper(value: thresholdBinding(metric), in: 50...99, step: 5) {
                    HStack {
                        Text(metric.title)
                        Spacer()
                        Text("\(Int(model.threshold(for: metric)))%").monospacedDigit()
                    }
                }
            }

            Divider()
            Toggle("Show °F", isOn: $model.useFahrenheit)
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .font(.system(size: 12))
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func thresholdBinding(_ metric: Metric) -> Binding<Double> {
        Binding(
            get: { model.threshold(for: metric) },
            set: { model.setThreshold($0, for: metric) }
        )
    }
}

private func bytes(_ count: Int64, _ style: ByteCountFormatter.CountStyle) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = style
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: count)
}
