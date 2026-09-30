import CryptoKit
import Foundation
import Network
import Observation

/// Shares this Mac's stats with paired Macs over the LAN and Tailscale.
@MainActor
@Observable
final class SharingServer {
    enum Status: Equatable {
        case off, starting, sharing
        case failed(String)
    }

    static let pairingWindow: TimeInterval = 5 * 60
    static let maxFailedAttempts = 5

    private(set) var status: Status = .off
    private(set) var pairingCode: String?
    private(set) var pairingExpires: Date?
    private(set) var viewers: [PairedViewer]
    private(set) var connectedViewerIDs: Set<String> = []

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "sharingEnabled")
            isEnabled ? start() : stop()
        }
    }

    @ObservationIgnored private let store: PairingStore
    @ObservationIgnored private let snapshot: () -> Snapshot
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var sessions: [ObjectIdentifier: Session] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var failedAttempts = 0

    private final class Session {
        let connection: LineConnection
        let challenge = PairingCrypto.randomChallenge()
        let key = Curve25519.KeyAgreement.PrivateKey()
        var viewerID: String?

        init(connection: LineConnection) {
            self.connection = connection
        }
    }

    init(store: PairingStore, snapshot: @escaping () -> Snapshot) {
        self.store = store
        self.snapshot = snapshot
        viewers = store.data.viewers
        isEnabled = UserDefaults.standard.bool(forKey: "sharingEnabled")
    }

    /// Starts listening if sharing was left on last time.
    func activate() {
        if isEnabled { start() }
    }

    func beginPairing() {
        pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
        pairingExpires = Date().addingTimeInterval(Self.pairingWindow)
        failedAttempts = 0
    }

    func cancelPairing() {
        pairingCode = nil
        pairingExpires = nil
    }

    func removeViewer(_ id: String) {
        store.update { $0.viewers.removeAll { $0.id == id } }
        viewers = store.data.viewers
        for session in sessions.values where session.viewerID == id {
            session.connection.close()
        }
    }

    private var activeCode: String? {
        guard let pairingCode, let pairingExpires, pairingExpires > Date() else {
            if pairingCode != nil { cancelPairing() }
            return nil
        }
        return pairingCode
    }

    private func start() {
        guard listener == nil else { return }
        status = .starting
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: RemoteProtocol.port)
            let id = store.data.deviceID
            // Advertise a random ID and the model only; the computer name is sent after authentication.
            listener.service = NWListener.Service(
                name: "LogMac-\(id.prefix(8))",
                type: RemoteProtocol.serviceType,
                txtRecord: NWTXTRecord(["id": id, "product": DeviceInfo.product, "chip": DeviceInfo.chip])
            )
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener

            let timer = Timer(timeInterval: RemoteProtocol.statsInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.broadcastStats() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        timer?.invalidate()
        timer = nil
        for session in sessions.values { session.connection.close() }
        sessions = [:]
        connectedViewerIDs = []
        cancelPairing()
        status = .off
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            status = .sharing
        case let .failed(error):
            let message = if case .posix(.EADDRINUSE) = error {
                "Port \(RemoteProtocol.port) is already in use."
            } else {
                error.localizedDescription
            }
            listener?.cancel()
            listener = nil
            timer?.invalidate()
            timer = nil
            status = .failed(message)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let session = Session(connection: LineConnection(connection))
        let key = ObjectIdentifier(session)
        sessions[key] = session

        session.connection.onReady = { [weak session] in
            guard let session else { return }
            session.connection.send(Message(
                type: .hello,
                id: self.store.data.deviceID,
                challenge: session.challenge,
                publicKey: session.key.publicKey.rawRepresentation
            ))
        }
        session.connection.onMessage = { [weak self, weak session] message in
            guard let self, let session else { return }
            self.handle(message, from: session)
        }
        session.connection.onClose = { [weak self] in
            self?.sessions[key] = nil
            self?.refreshConnected()
        }
        session.connection.start()

        // Drop connections that don't authenticate promptly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak session] in
            if let session, session.viewerID == nil { session.connection.close() }
        }
    }

    private func handle(_ message: Message, from session: Session) {
        guard session.viewerID == nil else { return }

        switch message.type {
        case .auth:
            guard let id = message.id, let proof = message.proof,
                  let viewer = store.data.viewers.first(where: { $0.id == id }),
                  PairingCrypto.isValidAuth(proof, token: viewer.token, challenge: session.challenge)
            else { return reject(session, RejectReason.unauthorized) }
            authenticate(session, viewerID: id)

        case .pair:
            guard let code = activeCode else { return reject(session, RejectReason.notPairing) }
            guard let id = message.id, let clientKey = message.publicKey, let proof = message.proof,
                  let info = message.info,
                  PairingCrypto.isValidPairing(
                      proof, code: code, challenge: session.challenge,
                      serverKey: session.key.publicKey.rawRepresentation, clientKey: clientKey),
                  let token = try? PairingCrypto.token(privateKey: session.key, peerKey: clientKey, challenge: session.challenge)
            else {
                failedAttempts += 1
                if failedAttempts >= Self.maxFailedAttempts { cancelPairing() }
                return reject(session, RejectReason.wrongCode)
            }
            store.update {
                $0.viewers.removeAll { $0.id == id }
                $0.viewers.append(PairedViewer(id: id, name: info.displayName, token: token, pairedAt: Date()))
            }
            viewers = store.data.viewers
            cancelPairing()
            authenticate(session, viewerID: id)

        default:
            reject(session, RejectReason.unauthorized)
        }
    }

    private func authenticate(_ session: Session, viewerID: String) {
        session.viewerID = viewerID
        session.connection.send(Message(type: .welcome, info: DeviceInfo.current(id: store.data.deviceID)))
        session.connection.send(Message(type: .stats, stats: RemoteStats(snapshot())))
        refreshConnected()
    }

    private func reject(_ session: Session, _ reason: String) {
        session.connection.send(Message(type: .error, reason: reason), thenClose: true)
    }

    private func broadcastStats() {
        let authenticated = sessions.values.filter { $0.viewerID != nil }
        guard !authenticated.isEmpty else { return }
        let message = Message(type: .stats, stats: RemoteStats(snapshot()))
        for session in authenticated { session.connection.send(message) }
    }

    private func refreshConnected() {
        connectedViewerIDs = Set(sessions.values.compactMap(\.viewerID))
    }
}
