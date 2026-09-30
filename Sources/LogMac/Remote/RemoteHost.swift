import AppKit
import Foundation
import Network
import Observation

/// A paired Mac this one watches. Keeps a connection open, preferring the LAN and falling back to Tailscale.
@MainActor
@Observable
final class RemoteHost: Identifiable {
    enum Route: String {
        case lan = "LAN"
        case tailscale = "Tailscale"
    }

    enum State: Equatable {
        case connecting
        case connected(Route)
        case offline
        /// The other Mac no longer accepts our token (it removed us).
        case unpaired
    }

    static let connectTimeout: TimeInterval = 5
    static let staleAfter: TimeInterval = 8
    static let maxRetryDelay: TimeInterval = 15

    let id: String
    private(set) var info: DeviceInfo
    private(set) var state: State = .connecting
    private(set) var stats: RemoteStats?
    private(set) var lastSeen: Date?
    private(set) var alerts = AlertTracker()
    private(set) var address: String?

    @ObservationIgnored weak var monitor: RemoteMonitor?
    @ObservationIgnored private let token: Data
    @ObservationIgnored let manualHost: String?
    @ObservationIgnored private var connection: LineConnection?
    @ObservationIgnored private var retry: DispatchWorkItem?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var stopped = false

    init(_ paired: PairedHost, monitor: RemoteMonitor) {
        id = paired.info.id
        info = paired.info
        token = paired.token
        manualHost = paired.manualHost
        self.monitor = monitor
    }

    var paired: PairedHost {
        PairedHost(info: info, token: token, manualHost: manualHost)
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    func value(_ metric: Metric) -> Double? {
        isConnected ? stats?.value(metric) : nil
    }

    /// Opens Screen Sharing to this Mac over whichever route is working.
    var screenSharingURL: URL? {
        let host: String? = switch state {
        case .connected(.tailscale): address ?? info.tailscaleIP
        default: info.localHostName.map { "\($0).local" } ?? info.tailscaleIP ?? manualHost
        }
        return host.flatMap { URL(string: "vnc://\($0)") }
    }

    func connect() {
        guard connection == nil, !stopped else { return }
        retry?.cancel()
        attempt(routes()[...])
    }

    /// Called when the LAN view changes, e.g. the Mac just appeared on Bonjour.
    func networkChanged() {
        guard !isConnected, connection == nil, state != .unpaired else { return }
        failures = 0
        connect()
    }

    func stop() {
        stopped = true
        retry?.cancel()
        watchdog?.invalidate()
        connection?.close()
    }

    private func routes() -> [NWEndpoint] {
        var endpoints: [NWEndpoint] = []
        if let bonjour = monitor?.bonjourEndpoint(for: id) {
            endpoints.append(bonjour)
        }
        var hosts: [String] = []
        if let ip = info.tailscaleIP { hosts.append(ip) }
        if let manualHost, !hosts.contains(manualHost) { hosts.append(manualHost) }
        endpoints += hosts.map { .hostPort(host: NWEndpoint.Host($0), port: RemoteProtocol.port) }
        return endpoints
    }

    private func attempt(_ remaining: ArraySlice<NWEndpoint>) {
        guard let endpoint = remaining.first else {
            if state != .unpaired { state = .offline }
            alerts = AlertTracker()
            scheduleRetry()
            return
        }

        let connection = LineConnection(to: endpoint)
        self.connection = connection
        var authenticated = false

        let timeout = DispatchWorkItem { [weak connection] in connection?.close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: timeout)

        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            switch message.type {
            case .hello:
                // A different Mac answering at this address (e.g. a reused IP) isn't ours to talk to.
                guard message.id == self.id, let challenge = message.challenge, let deviceID = self.monitor?.deviceID
                else { return connection.close() }
                connection.send(Message(
                    type: .auth, id: deviceID, proof: PairingCrypto.authProof(token: self.token, challenge: challenge)))

            case .welcome:
                authenticated = true
                timeout.cancel()
                self.failures = 0
                self.address = connection.remoteAddress
                let onTailscale = self.address.map(DeviceInfo.isTailscale(address:)) ?? false
                self.state = .connected(onTailscale ? .tailscale : .lan)
                self.lastSeen = Date()
                if let info = message.info, info != self.info {
                    self.info = info
                    self.monitor?.persist(self)
                }
                self.startWatchdog()

            case .stats:
                guard authenticated, let stats = message.stats else { return }
                self.stats = stats
                self.lastSeen = Date()
                if let monitor = self.monitor {
                    self.alerts.update(values: stats.metricValues, threshold: monitor.threshold, now: Date())
                }

            case .error where message.reason == RejectReason.unauthorized:
                self.state = .unpaired

            default:
                break
            }
        }

        connection.onClose = { [weak self] in
            guard let self else { return }
            timeout.cancel()
            self.connection = nil
            self.watchdog?.invalidate()
            guard !self.stopped else { return }

            if self.state == .unpaired {
                self.alerts = AlertTracker()
            } else if authenticated {
                // Dropped after working, e.g. left home: reconnect over whatever route is available now.
                self.state = .connecting
                self.alerts = AlertTracker()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
            } else {
                self.attempt(remaining.dropFirst())
            }
        }
        connection.start()
    }

    private func scheduleRetry() {
        let delay = min(Self.maxRetryDelay, 2 * pow(2, Double(failures)))
        failures += 1
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// TCP can take minutes to notice a vanished peer (sleep, Wi-Fi change); stats stopping is a faster signal.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let lastSeen = self.lastSeen else { return }
                if Date().timeIntervalSince(lastSeen) > Self.staleAfter { self.connection?.close() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}
