import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @Bindable var model: StatsModel
    let monitor: RemoteMonitor
    let server: SharingServer
    @State private var showsSettings = false
    @State private var detail: Metric?
    @State private var processes = ProcessMonitor()
    @State private var mainHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            if let detail {
                ProcessListView(model: model, processes: processes, metric: detail) { show(nil) }
                    .frame(minHeight: mainHeight, alignment: .top)
                    .transition(.move(edge: .trailing))
            } else {
                main
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { mainHeight = $0 }
                    .transition(.move(edge: .leading))
            }
        }
        .padding(14)
        .frame(width: 300)
        .clipped()
        .onDisappear { show(nil) }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if server.isPairingOpen {
                PairingPrompt(server: server)
            }

            Card {
                ForEach(Metric.allCases) { metric in
                    MetricRow(model: model, metric: metric, onOpen: metric.hasProcessList ? { show(metric) } : nil)
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

            RemoteSection(model: model, monitor: monitor)

            if showsSettings {
                SettingsSection(model: model)
                SharingSettings(server: server)
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
    }

    private func show(_ metric: Metric?) {
        if let metric { processes.start(metric) } else { processes.stop() }
        withAnimation(.snappy(duration: 0.3)) { detail = metric }
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

struct Card<Content: View>: View {
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
    /// Opens this metric's process list; nil for metrics without one.
    var onOpen: (() -> Void)?
    @State private var isHovered = false

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
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(value.map { "\(Int($0.rounded()))%" } ?? "--")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
                // Hidden rather than omitted so every row's value stays aligned.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(onOpen == nil ? 0 : 1)
            }
            .font(.system(size: 12))

            ThresholdBar(
                fraction: (value ?? 0) / 100,
                threshold: model.threshold(for: metric) / 100,
                color: model.level(metric).barColor
            )
        }
        .padding(4)
        .background(
            Color.primary.opacity(isHovered && onOpen != nil ? 0.06 : 0),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .padding(-4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onOpen?() }
    }

    private var detail: String? {
        let s = model.snapshot
        switch metric {
        case .ram where s.memTotal > 0:
            return usage(Int64(s.memUsed), of: Int64(s.memTotal), .memory)
        case .ssd where s.diskTotal > 0:
            return usage(s.diskUsed, of: s.diskTotal, .file)
        default:
            return nil
        }
    }
}

/// A progress bar with a tick marking the alert threshold.
struct ThresholdBar: View {
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
            Text(rate(bytesPerSecond))
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 62, alignment: .trailing)
        }
    }
}

/// "871 B/s", "5 KB/s", "1.2 MB/s": short units so the rate never wraps and resizes the row.
func rate(_ bytesPerSecond: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = max(bytesPerSecond, 0)
    var index = 0
    // Step up before 1000 rounds to "1000", so values stay at three digits or fewer.
    while value >= 999.5, index < units.count - 1 {
        value /= 1000
        index += 1
    }
    let digits = index > 0 && value < 9.95 ? 1 : 0
    return String(format: "%.\(digits)f \(units[index])", value)
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

func bytes(_ count: Int64, _ style: ByteCountFormatter.CountStyle) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = style
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: count)
}

/// "10.3 of 16 GB" or "200 of 494 GB": both values in the total's unit, so the text stays short.
func usage(_ used: Int64, of total: Int64, _ style: ByteCountFormatter.CountStyle) -> String {
    let base: Double = style == .memory ? 1024 : 1000
    let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
    var exponent = 0
    var scaledTotal = Double(total)
    while scaledTotal >= base, exponent < units.count - 1 {
        scaledTotal /= base
        exponent += 1
    }
    let scaledUsed = Double(used) / pow(base, Double(exponent))
    // One decimal for small totals (16 GB), none for large ones (494 GB).
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = scaledTotal < 100 ? 1 : 0
    func format(_ value: Double) -> String { formatter.string(from: NSNumber(value: value)) ?? "\(value)" }
    return "\(format(scaledUsed)) of \(format(scaledTotal)) \(units[exponent])"
}
