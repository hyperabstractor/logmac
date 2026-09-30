import CryptoKit
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

    enum PairTarget {
        case discovered(Discovered)
        /// A Tailscale name, IP, or LAN address typed in by the user.
        case host(String)
    }

    enum PairingError: Error {
        case unreachable, timedOut, notPairing, wrongCode, isThisMac, unexpectedDevice

        var message: String {
            switch self {
            case .unreachable: "Couldn't reach that Mac. Check that LogMac is sharing there and the address is right."
            case .timedOut: "That Mac didn't respond in time. Try again."
            case .notPairing: "Pairing isn't open on that Mac. Choose Pair new Mac there first."
            case .wrongCode: "That code didn't match. Check the code on the other Mac."
            case .isThisMac: "That's this Mac."
            case .unexpectedDevice: "A different Mac answered at that address."
            }
        }
    }

    static let pairingTimeout: TimeInterval = 8

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

    func pair(with target: PairTarget, code: String, completion: @escaping (Result<RemoteHost, PairingError>) -> Void) {
        let endpoint: NWEndpoint
        var expectedID: String?
        var manualHost: String?
        switch target {
        case let .discovered(item):
            endpoint = item.endpoint
            expectedID = item.id
        case let .host(host):
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: RemoteProtocol.port)
            manualHost = host
        }

        let connection = LineConnection(to: endpoint)
        let key = Curve25519.KeyAgreement.PrivateKey()
        var token: Data?
        var finished = false

        func finish(_ result: Result<RemoteHost, PairingError>) {
            guard !finished else { return }
            finished = true
            connection.close()
            completion(result)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pairingTimeout) { finish(.failure(.timedOut)) }

        connection.onMessage = { [weak self] message in
            guard let self else { return }
            switch message.type {
            case .hello:
                guard let serverID = message.id, let challenge = message.challenge, let serverKey = message.publicKey
                else { return finish(.failure(.unexpectedDevice)) }
                if serverID == self.deviceID { return finish(.failure(.isThisMac)) }
                if let expectedID, expectedID != serverID { return finish(.failure(.unexpectedDevice)) }
                expectedID = serverID

                let clientKey = key.publicKey.rawRepresentation
                token = try? PairingCrypto.token(privateKey: key, peerKey: serverKey, challenge: challenge)
                connection.send(Message(
                    type: .pair,
                    id: self.deviceID,
                    publicKey: clientKey,
                    proof: PairingCrypto.pairingProof(code: code, challenge: challenge, serverKey: serverKey, clientKey: clientKey),
                    info: DeviceInfo.current(id: self.deviceID)
                ))

            case .welcome:
                guard let info = message.info, info.id == expectedID, let token else {
                    return finish(.failure(.unexpectedDevice))
                }
                finish(.success(self.add(PairedHost(info: info, token: token, manualHost: manualHost))))

            case .error:
                finish(.failure(message.reason == RejectReason.notPairing ? .notPairing : .wrongCode))

            default:
                break
            }
        }
        connection.onClose = { finish(.failure(.unreachable)) }
        connection.start()
    }

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
