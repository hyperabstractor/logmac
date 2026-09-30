import Foundation
import Network
import Observation

/// Discovers LogMac peers on the LAN, pairs with them, and owns the watched `RemoteHost`s.
@MainActor
@Observable
final class RemoteMonitor {
    /// An unpaired Mac seen on the LAN.
    struct Discovered: Identifiable, Equatable {
        let id: String
        let product: String
        let chip: String
        let endpoint: NWEndpoint

        var displayName: String { chip.isEmpty ? product : "\(product) (\(chip))" }
    }

    private(set) var hosts: [RemoteHost] = []
    private(set) var discovered: [Discovered] = []

    /// Alert thresholds, shared with this Mac's own settings.
    @ObservationIgnored var threshold: (Metric) -> Double = { $0.defaultThreshold }
    @ObservationIgnored private let store: PairingStore
    @ObservationIgnored private var bonjour: [String: NWEndpoint] = [:]
    @ObservationIgnored private var bonjourInfo: [String: Discovered] = [:]
    @ObservationIgnored private var browser: NWBrowser?

    init(store: PairingStore) {
        self.store = store
        hosts = store.data.hosts.map { RemoteHost($0, monitor: self) }
    }

    var deviceID: String { store.data.deviceID }

    func start() {
        startBrowser()
        for host in hosts { host.connect() }
    }

    func bonjourEndpoint(for id: String) -> NWEndpoint? {
        bonjour[id]
    }

    /// The connected host's metric furthest over its threshold, for the menu bar label.
    var primaryAlert: (host: RemoteHost, metric: Metric, value: Double)? {
        var best: (host: RemoteHost, metric: Metric, value: Double, overshoot: Double)?
        for host in hosts where host.isConnected {
            for metric in host.alerts.alerting {
                guard let value = host.value(metric) else { continue }
                let overshoot = value - threshold(metric)
                if best == nil || overshoot > best!.overshoot {
                    best = (host, metric, value, overshoot)
                }
            }
        }
        return best.map { ($0.host, $0.metric, $0.value) }
    }

    func remove(_ host: RemoteHost) {
        host.stop()
        hosts.removeAll { $0.id == host.id }
        store.update { $0.hosts.removeAll { $0.info.id == host.id } }
        refreshDiscovered()
    }

    func persist(_ host: RemoteHost) {
        store.update { data in
            data.hosts.removeAll { $0.info.id == host.id }
            data.hosts.append(host.paired)
        }
    }

    /// Starts pairing with a Mac. The returned attempt walks the UI through comparing codes.
    func beginPairing(with target: PairingAttempt.Target) -> PairingAttempt {
        let attempt = PairingAttempt(target: target, deviceID: deviceID) { [weak self] paired in
            self?.add(paired)
        }
        attempt.start()
        return attempt
    }

    @discardableResult
    private func add(_ paired: PairedHost) -> RemoteHost {
        if let existing = hosts.first(where: { $0.id == paired.info.id }) {
            existing.stop()
            hosts.removeAll { $0 === existing }
        }
        let host = RemoteHost(paired, monitor: self)
        hosts.append(host)
        persist(host)
        refreshDiscovered()
        host.connect()
        return host
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteProtocol.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var endpoints: [String: NWEndpoint] = [:]
        var info: [String: Discovered] = [:]
        for result in results {
            guard case let .bonjour(txt) = result.metadata, let id = txt["id"], id != deviceID else { continue }
            endpoints[id] = result.endpoint
            info[id] = Discovered(id: id, product: txt["product"] ?? "Mac", chip: txt["chip"] ?? "", endpoint: result.endpoint)
        }

        let appeared = Set(endpoints.keys).subtracting(bonjour.keys)
        bonjour = endpoints
        bonjourInfo = info
        refreshDiscovered()
        for host in hosts where appeared.contains(host.id) {
            host.networkChanged()
        }
    }

    private func refreshDiscovered() {
        let paired = Set(hosts.map(\.id))
        let next = bonjourInfo.values
            .filter { !paired.contains($0.id) }
            .sorted { $0.displayName < $1.displayName }
        if next != discovered { discovered = next }
    }
}
