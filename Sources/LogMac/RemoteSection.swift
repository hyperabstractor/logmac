import SwiftUI

/// The popover's list of watched Macs, plus the "Add Mac" flow.
struct RemoteSection: View {
    let model: StatsModel
    let monitor: RemoteMonitor
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Remote").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(isAdding ? "Cancel" : "Add Mac") {
                    withAnimation(.snappy) { isAdding.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }

            if isAdding {
                AddMacView(monitor: monitor) {
                    withAnimation(.snappy) { isAdding = false }
                }
            } else if monitor.hosts.isEmpty {
                Text("Turn on sharing in LogMac on your other Mac, then add it here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !monitor.hosts.isEmpty {
                Card {
                    ForEach(monitor.hosts) { host in
                        RemoteHostRow(model: model, monitor: monitor, host: host)
                        if host.id != monitor.hosts.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private struct RemoteHostRow: View {
    let model: StatsModel
    let monitor: RemoteMonitor
    let host: RemoteHost
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(host.info.displayName)
                    .fontWeight(.semibold)
                    .foregroundStyle(host.isConnected ? .primary : .secondary)
                    .lineLimit(1)
                if case let .connected(route) = host.state {
                    Text(route.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                if host.isConnected {
                    Text(model.formatTemp(host.stats?.cpuTemp))
                        .monospacedDigit()
                        .foregroundStyle(tempColor)
                }
                if let url = host.screenSharingURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Open Screen Sharing")
                }
            }

            if host.isConnected {
                bar(.cpu)
                bar(.ram)
                if isExpanded {
                    bar(.gpu)
                    bar(.ssd)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(statusText(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if isExpanded {
                HStack {
                    Text(host.info.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Remove") { monitor.remove(host) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
        }
        .font(.system(size: 12))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
        .contextMenu {
            Button("Remove \(host.info.displayName)", role: .destructive) { monitor.remove(host) }
        }
    }

    private func bar(_ metric: Metric) -> some View {
        let value = host.value(metric)
        let threshold = model.threshold(for: metric)
        return HStack(spacing: 6) {
            Text(metric.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            ThresholdBar(
                fraction: (value ?? 0) / 100,
                threshold: threshold / 100,
                color: Level.of(value: value, threshold: threshold, alerting: host.alerts.alerting.contains(metric)).barColor
            )
            Text(value.map { "\(Int($0.rounded()))%" } ?? "--")
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var statusColor: Color {
        switch host.state {
        case .connected: host.alerts.alerting.isEmpty ? .green : .red
        case .connecting: .orange
        case .offline, .unpaired: .gray
        }
    }

    private var tempColor: Color {
        let level = Level.ofTemperature(host.stats?.cpuTemp)
        return level == .normal ? .secondary : level.barColor
    }

    private func statusText(now: Date) -> String {
        switch host.state {
        case .connecting:
            return "Connecting…"
        case .unpaired:
            return "This Mac was removed on the other side. Remove it and pair again."
        case .offline, .connected:
            guard let lastSeen = host.lastSeen else { return "Offline" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Offline · last seen \(formatter.localizedString(for: lastSeen, relativeTo: now))"
        }
    }
}

/// Pick a Mac found on the LAN or type a Tailscale name / IP, then compare codes with it.
private struct AddMacView: View {
    let monitor: RemoteMonitor
    var onDone: () -> Void

    @State private var selectedID: String?
    @State private var address = ""
    @State private var error: String?
    @State private var attempt: PairingAttempt?

    var body: some View {
        Card {
            if let attempt, !isEnded(attempt.state) {
                progress(attempt)
            } else {
                form
            }
        }
        .font(.system(size: 12))
        .onChange(of: attempt?.state) { _, state in
            switch state {
            case .paired?:
                onDone()
            case let .failed(failure)?:
                error = failure.message
            default:
                break
            }
        }
        .onDisappear { attempt?.cancel() }
    }

    @ViewBuilder
    private var form: some View {
        Text("On the other Mac, open LogMac settings, turn on sharing, and choose Pair new Mac.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if monitor.discovered.isEmpty {
            Text("No Macs found on this network.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        ForEach(monitor.discovered) { item in
            Button {
                selectedID = item.id
                address = ""
                error = nil
            } label: {
                HStack {
                    Image(systemName: selectedID == item.id ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selectedID == item.id ? Color.accentColor : .secondary)
                    Text(item.displayName)
                    Spacer()
                    Text("LAN").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        TextField("Tailscale name or IP", text: $address)
            .textFieldStyle(.roundedBorder)
            .onChange(of: address) { _, value in
                if !value.isEmpty { selectedID = nil }
                error = nil
            }
            .onSubmit(pair)

        if let error {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Spacer()
            Button("Pair", action: pair)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func progress(_ attempt: PairingAttempt) -> some View {
        switch attempt.state {
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(attempt.targetName)…")
                Spacer()
                Button("Cancel") { attempt.cancel() }.buttonStyle(.borderless)
            }
        case let .confirm(code):
            PairingCodeView(
                title: "Pairing with \(attempt.targetName)",
                code: code,
                isWaiting: false,
                onConfirm: attempt.confirm,
                onCancel: attempt.cancel
            )
        case let .waiting(code):
            PairingCodeView(
                title: "Pairing with \(attempt.targetName)",
                code: code,
                isWaiting: true,
                onConfirm: {},
                onCancel: attempt.cancel
            )
        case .paired, .cancelled, .failed:
            EmptyView()
        }
    }

    private func isEnded(_ state: PairingAttempt.State) -> Bool {
        switch state {
        case .paired, .cancelled, .failed: true
        default: false
        }
    }

    private func pair() {
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        let target: PairingAttempt.Target
        if let selectedID, let item = monitor.discovered.first(where: { $0.id == selectedID }) {
            target = .discovered(item)
        } else if !trimmedAddress.isEmpty {
            target = .host(trimmedAddress)
        } else {
            error = "Choose a Mac above, or enter its Tailscale name or IP."
            return
        }
        error = nil
        attempt = monitor.beginPairing(with: target)
    }
}

/// The 6-digit code both Macs show during pairing, with Pair / Cancel.
struct PairingCodeView: View {
    let title: String
    let code: String
    let isWaiting: Bool
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(code)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
            Text("Check that the other Mac shows the same code.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                if isWaiting {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the other Mac…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Button("Codes match: Pair", action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .font(.system(size: 12))
    }
}

/// Shown at the top of the popover while this Mac accepts pairing requests.
struct PairingPrompt: View {
    let server: SharingServer

    var body: some View {
        Card {
            if let pending = server.pending {
                PairingCodeView(
                    title: "\(pending.peerName) wants to watch this Mac",
                    code: pending.code,
                    isWaiting: pending.confirmedHere,
                    onConfirm: server.confirmPairing,
                    onCancel: server.cancelPendingPairing
                )
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the other Mac…").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("Stop") { server.closePairing() }.buttonStyle(.borderless)
                }
                Text("On the other Mac, choose Add Mac and pick this one. Pairing stays open for 5 minutes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Settings for letting other Macs watch this one.
struct SharingSettings: View {
    @Bindable var server: SharingServer

    var body: some View {
        Card {
            Toggle("Share this Mac's stats", isOn: $server.isEnabled)

            if server.isEnabled {
                switch server.status {
                case let .failed(message):
                    Text(message).font(.system(size: 11)).foregroundStyle(.red)
                case .starting:
                    Text("Starting…").font(.system(size: 11)).foregroundStyle(.secondary)
                default:
                    Text("Paired Macs can watch this one over your network or Tailscale.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if server.isPairingOpen {
                    Text("Pairing is open. The code appears at the top of this panel.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Pair new Mac") { server.openPairing() }
                }

                ForEach(server.viewers) { viewer in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(server.connectedViewerIDs.contains(viewer.id) ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(viewer.name)
                        Spacer()
                        Button("Remove") { server.removeViewer(viewer.id) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                    }
                }
            }
        }
        .font(.system(size: 12))
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
