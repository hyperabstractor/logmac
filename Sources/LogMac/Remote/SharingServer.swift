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

    /// A Mac asking to pair, waiting for the user to compare codes.
    struct PendingPairing: Equatable {
        let code: String
        /// Name the other Mac claims; only the code comparison proves anything.
        let peerName: String
        var confirmedHere = false
    }

    /// How long "Pair new Mac" accepts new pairing requests.
    static let pairingWindow: TimeInterval = 5 * 60
    /// How long a request waits for both people to compare codes.
    static let confirmTimeout: TimeInterval = 2 * 60
    /// Cancelled or failed pairing sessions before the window closes (spam guard).
    static let maxFailedSessions = 5

    private(set) var status: Status = .off
    private(set) var isPairingOpen = false
    private(set) var pending: PendingPairing?
    private(set) var viewers: [PairedViewer]
    private(set) var connectedViewerIDs: Set<String> = []

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "sharingEnabled")
            isEnabled ? start() : stop()
        }
    }

    /// The port actually listened on, once sharing (differs from `port` only when that is `.any`).
    var boundPort: NWEndpoint.Port? { listener?.port }

    /// Called when a Mac starts pairing, so the app can bring the code on screen.
    @ObservationIgnored var onPairingRequest: (() -> Void)?

    @ObservationIgnored private let store: PairingStore
    @ObservationIgnored private let snapshot: () -> Snapshot
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let port: NWEndpoint.Port
    @ObservationIgnored private let advertises: Bool
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var sessions: [ObjectIdentifier: Session] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pairingExpires = Date.distantPast
    @ObservationIgnored private var failedSessions = 0
    @ObservationIgnored private var pendingSession: Session?

    private final class Session {
        let connection: LineConnection
        let challenge = PairingCrypto.randomBytes()
        let key = Curve25519.KeyAgreement.PrivateKey()
        /// Fixed and committed to in `hello`, before the client's nonce is seen.
        let nonce = PairingCrypto.randomBytes()
        var viewerID: String?
        var pairing: Pairing?

        struct Pairing {
            let peerID: String
            let info: DeviceInfo
            let token: Data
            var confirmedThere = false
        }

        init(connection: LineConnection) {
            self.connection = connection
        }

        var publicKey: Data { key.publicKey.rawRepresentation }
    }

    init(
        store: PairingStore,
        defaults: UserDefaults = .standard,
        port: NWEndpoint.Port = RemoteProtocol.port,
        advertises: Bool = true,
        snapshot: @escaping () -> Snapshot
    ) {
        self.store = store
        self.defaults = defaults
        self.port = port
        self.advertises = advertises
        self.snapshot = snapshot
        viewers = store.data.viewers
        isEnabled = defaults.bool(forKey: "sharingEnabled")
    }

    /// Starts listening if sharing was left on last time.
    func activate() {
        if isEnabled { start() }
    }

    // MARK: Pairing window

    func openPairing() {
        isPairingOpen = true
        pairingExpires = Date().addingTimeInterval(Self.pairingWindow)
        failedSessions = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pairingWindow + 0.5) { [weak self] in
            self?.closeIfExpired()
        }
    }

    func closePairing() {
        if let session = pendingSession {
            endPairing(session, notify: RejectReason.cancelled, countsAsFailure: false)
        }
        isPairingOpen = false
    }

    /// The user checked the codes match and clicked Pair.
    func confirmPairing() {
        guard let session = pendingSession, pending?.confirmedHere == false else { return }
        pending?.confirmedHere = true
        session.connection.send(Message(type: .confirm))
        finishPairingIfReady(session)
    }

    /// The user clicked Cancel on the code, e.g. because it didn't match.
    func cancelPendingPairing() {
        guard let session = pendingSession else { return }
        endPairing(session, notify: RejectReason.cancelled, countsAsFailure: true)
    }

    func removeViewer(_ id: String) {
        store.update { $0.viewers.removeAll { $0.id == id } }
        viewers = store.data.viewers
        for session in sessions.values where session.viewerID == id {
            session.connection.close()
        }
    }

    private var acceptsPairing: Bool {
        isPairingOpen && pairingExpires > Date()
    }

    private func closeIfExpired() {
        if isPairingOpen, pendingSession == nil, pairingExpires <= Date() { isPairingOpen = false }
    }

    // MARK: Listener

    private func start() {
        guard listener == nil else { return }
        status = .starting
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            if advertises {
                let id = store.data.deviceID
                // Advertise a random ID and the model only; the computer name is sent after authentication.
                listener.service = NWListener.Service(
                    name: "LogMac-\(id.prefix(8))",
                    type: RemoteProtocol.serviceType,
                    txtRecord: NWTXTRecord(["id": id, "product": DeviceInfo.product, "chip": DeviceInfo.chip])
                )
            }
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
        closePairing()
        listener?.cancel()
        listener = nil
        timer?.invalidate()
        timer = nil
        for session in sessions.values { session.connection.close() }
        sessions = [:]
        connectedViewerIDs = []
        status = .off
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            status = .sharing
        case let .failed(error):
            let message = if case .posix(.EADDRINUSE) = error {
                "Port \(port) is already in use."
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

    // MARK: Sessions

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
                publicKey: session.publicKey,
                commit: PairingCrypto.commit(serverKey: session.publicKey, serverNonce: session.nonce)
            ))
        }
        session.connection.onMessage = { [weak self, weak session] message in
            guard let self, let session else { return }
            self.handle(message, from: session)
        }
        session.connection.onClose = { [weak self, weak session] in
            guard let self else { return }
            if let session, session === self.pendingSession {
                self.endPairing(session, notify: nil, countsAsFailure: true)
            }
            self.sessions[key] = nil
            self.refreshConnected()
        }
        session.connection.start()

        // Drop connections that neither authenticate nor start pairing promptly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak session] in
            if let session, session.viewerID == nil, session.pairing == nil { session.connection.close() }
        }
    }

    private func handle(_ message: Message, from session: Session) {
        // Authenticated viewers only receive; anything they send is ignored.
        guard session.viewerID == nil else { return }

        switch message.type {
        case .auth where session.pairing == nil:
            guard let id = message.id, let proof = message.proof,
                  let viewer = store.data.viewers.first(where: { $0.id == id }),
                  PairingCrypto.isValidAuth(proof, token: viewer.token, challenge: session.challenge)
            else { return reject(session, RejectReason.unauthorized) }
            authenticate(session, viewerID: id)

        case .pair where session.pairing == nil:
            beginPairing(message, on: session)

        case .confirm where session.pairing != nil && session === pendingSession:
            session.pairing?.confirmedThere = true
            finishPairingIfReady(session)

        case .error where session === pendingSession:
            // The other Mac cancelled.
            endPairing(session, notify: nil, countsAsFailure: true)

        default:
            // Out of order or unknown: drop it.
            if session === pendingSession {
                endPairing(session, notify: RejectReason.invalid, countsAsFailure: true)
            } else {
                reject(session, RejectReason.invalid)
            }
        }
    }

    private func beginPairing(_ message: Message, on session: Session) {
        // Clients from before numeric comparison send a typed-code proof and no nonce.
        guard message.nonce != nil || message.proof == nil else { return reject(session, RejectReason.updateRequired) }
        guard acceptsPairing else { return reject(session, RejectReason.notPairing) }
        guard pendingSession == nil else { return reject(session, RejectReason.busy) }
        guard let id = message.id, !id.isEmpty, id != store.data.deviceID,
              let clientKey = message.publicKey, clientKey.count == PairingCrypto.length,
              let clientNonce = message.nonce, clientNonce.count == PairingCrypto.length,
              let info = message.info,
              let token = try? PairingCrypto.token(
                  privateKey: session.key, peerKey: clientKey, salt: session.challenge + clientNonce + session.nonce)
        else { return reject(session, RejectReason.invalid) }

        session.pairing = Session.Pairing(peerID: id, info: info, token: token)
        pendingSession = session
        pending = PendingPairing(
            code: PairingCrypto.code(
                clientKey: clientKey, serverKey: session.publicKey, clientNonce: clientNonce, serverNonce: session.nonce),
            peerName: info.displayName
        )
        // Only now, with the client's nonce in hand, reveal ours.
        session.connection.send(Message(type: .reveal, nonce: session.nonce))
        onPairingRequest?()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmTimeout) { [weak self, weak session] in
            guard let self, let session, session === self.pendingSession else { return }
            self.endPairing(session, notify: RejectReason.cancelled, countsAsFailure: true)
        }
    }

    /// Stores the viewer only once this Mac's user and the other Mac have both confirmed.
    private func finishPairingIfReady(_ session: Session) {
        guard let pairing = session.pairing, pairing.confirmedThere, pending?.confirmedHere == true else { return }
        store.update {
            $0.viewers.removeAll { $0.id == pairing.peerID }
            $0.viewers.append(PairedViewer(
                id: pairing.peerID, name: pairing.info.displayName, token: pairing.token, pairedAt: Date()))
        }
        viewers = store.data.viewers
        pendingSession = nil
        pending = nil
        session.pairing = nil
        isPairingOpen = false
        authenticate(session, viewerID: pairing.peerID)
    }

    private func endPairing(_ session: Session, notify reason: String?, countsAsFailure: Bool) {
        guard session === pendingSession else { return }
        pendingSession = nil
        pending = nil
        session.pairing = nil
        if let reason {
            reject(session, reason)
        } else {
            session.connection.close()
        }
        if countsAsFailure {
            failedSessions += 1
            if failedSessions >= Self.maxFailedSessions { isPairingOpen = false }
        }
        closeIfExpired()
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
