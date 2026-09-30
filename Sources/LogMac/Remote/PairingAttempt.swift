import CryptoKit
import Foundation
import Network
import Observation

/// The watching Mac's side of pairing: connect, check the server's commitment, show the code,
/// and store the pairing only after both this user and the other Mac confirm.
@MainActor
@Observable
final class PairingAttempt {
    enum Target {
        case discovered(RemoteMonitor.Discovered)
        /// A Tailscale name, IP, or LAN address typed in by the user.
        case host(String)
        /// A specific endpoint, e.g. a loopback port in the self-test.
        case endpoint(NWEndpoint)
    }

    enum State: Equatable {
        case connecting
        /// Show the code; the user compares it with the other Mac.
        case confirm(code: String)
        /// This user confirmed; waiting for the other Mac's user.
        case waiting(code: String)
        case paired
        case cancelled
        case failed(PairingError)
    }

    enum PairingError: Error, Equatable {
        case unreachable, timedOut, connectionLost, notPairing, busy, cancelledRemotely
        case verificationFailed, isThisMac, unexpectedDevice, unexpectedResponse
        case otherMacOutdated, thisMacOutdated

        var message: String {
            switch self {
            case .unreachable: "Couldn't reach that Mac. Check that LogMac is sharing there and the address is right."
            case .timedOut: "Pairing timed out. Try again."
            case .connectionLost: "The connection to the other Mac closed. Try again."
            case .notPairing: "Pairing isn't open on that Mac. Choose Pair new Mac there first."
            case .busy: "That Mac is pairing with another Mac right now. Try again in a moment."
            case .cancelledRemotely: "Pairing was cancelled on the other Mac. If the codes didn't match, try again."
            case .verificationFailed: "The other Mac's response didn't check out, so pairing stopped. Try again."
            case .isThisMac: "That's this Mac."
            case .unexpectedDevice: "A different Mac answered at that address."
            case .unexpectedResponse: "The other Mac sent something unexpected. Try again."
            case .otherMacOutdated: "Update LogMac on the other Mac to pair."
            case .thisMacOutdated: "Update LogMac on this Mac to pair."
            }
        }
    }

    /// Time to reach the other Mac and get its revealed nonce.
    static let connectTimeout: TimeInterval = 8
    /// Time for both people to compare codes and click Pair.
    static let confirmTimeout: TimeInterval = 2 * 60

    private(set) var state: State = .connecting
    /// The name to show while pairing; the Mac's real name is only known once paired.
    let targetName: String

    @ObservationIgnored private let connection: LineConnection
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private let manualHost: String?
    @ObservationIgnored private let onPaired: (PairedHost) -> Void
    @ObservationIgnored private let key = Curve25519.KeyAgreement.PrivateKey()
    @ObservationIgnored private let nonce = PairingCrypto.randomBytes()
    @ObservationIgnored private var expectedID: String?
    @ObservationIgnored private var step = Step.hello
    @ObservationIgnored private var challenge = Data()
    @ObservationIgnored private var serverKey = Data()
    @ObservationIgnored private var commit = Data()
    @ObservationIgnored private var token: Data?
    @ObservationIgnored private var confirmedHere = false
    @ObservationIgnored private var confirmedThere = false
    @ObservationIgnored private var connectTimeout: DispatchWorkItem?

    private enum Step {
        case hello, reveal, confirm, done
    }

    init(target: Target, deviceID: String, onPaired: @escaping (PairedHost) -> Void) {
        self.deviceID = deviceID
        self.onPaired = onPaired
        let endpoint: NWEndpoint
        switch target {
        case let .discovered(item):
            endpoint = item.endpoint
            expectedID = item.id
            manualHost = nil
            targetName = item.displayName
        case let .host(host):
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: RemoteProtocol.port)
            manualHost = host
            targetName = host
        case let .endpoint(value):
            endpoint = value
            manualHost = nil
            targetName = "\(value)"
        }
        connection = LineConnection(to: endpoint)
    }

    var isFinished: Bool { step == .done }

    func start() {
        connection.onMessage = { [weak self] in self?.handle($0) }
        connection.onClose = { [weak self] in
            guard let self, self.step != .done else { return }
            self.fail(self.step == .hello ? .unreachable : .connectionLost)
        }
        let timeout = DispatchWorkItem { [weak self] in self?.fail(.timedOut) }
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: timeout)
        connection.start()
    }

    /// The user checked the codes match and clicked Pair.
    func confirm() {
        guard step == .confirm, !confirmedHere, case let .confirm(code) = state else { return }
        confirmedHere = true
        state = .waiting(code: code)
        connection.send(Message(type: .confirm))
    }

    func cancel() {
        guard step != .done else { return }
        step = .done
        connectTimeout?.cancel()
        state = .cancelled
        connection.send(Message(type: .error, reason: RejectReason.cancelled), thenClose: true)
    }

    private func handle(_ message: Message) {
        switch (message.type, step) {
        case (.hello, .hello):
            guard let serverID = message.id, let challenge = message.challenge,
                  let serverKey = message.publicKey, serverKey.count == PairingCrypto.length
            else { return fail(.unexpectedResponse) }
            guard let commit = message.commit, commit.count == PairingCrypto.length else { return fail(.otherMacOutdated) }
            if serverID == deviceID { return fail(.isThisMac) }
            if let expectedID, expectedID != serverID { return fail(.unexpectedDevice) }
            expectedID = serverID
            self.challenge = challenge
            self.serverKey = serverKey
            self.commit = commit
            step = .reveal
            connection.send(Message(
                type: .pair,
                id: deviceID,
                publicKey: key.publicKey.rawRepresentation,
                nonce: nonce,
                info: DeviceInfo.current(id: deviceID)
            ))

        case (.reveal, .reveal):
            // The server's nonce must be the one it committed to before seeing ours.
            guard let serverNonce = message.nonce, serverNonce.count == PairingCrypto.length,
                  PairingCrypto.commit(serverKey: serverKey, serverNonce: serverNonce) == commit
            else { return fail(.verificationFailed) }
            let clientKey = key.publicKey.rawRepresentation
            guard let token = try? PairingCrypto.token(
                privateKey: key, peerKey: serverKey, salt: challenge + nonce + serverNonce)
            else { return fail(.verificationFailed) }
            self.token = token
            connectTimeout?.cancel()
            step = .confirm
            state = .confirm(code: PairingCrypto.code(
                clientKey: clientKey, serverKey: serverKey, clientNonce: nonce, serverNonce: serverNonce))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmTimeout) { [weak self] in
                if self?.step == .confirm { self?.fail(.timedOut) }
            }

        case (.confirm, .confirm):
            confirmedThere = true

        case (.welcome, .confirm):
            // Never store a pairing this user didn't confirm, or that the other Mac didn't confirm first.
            guard confirmedHere, confirmedThere, let token, let info = message.info, info.id == expectedID
            else { return fail(.unexpectedResponse) }
            step = .done
            state = .paired
            connection.close()
            onPaired(PairedHost(info: info, token: token, manualHost: manualHost))

        case (.error, _):
            let error: PairingError = switch message.reason {
            case RejectReason.notPairing: .notPairing
            case RejectReason.busy: .busy
            case RejectReason.cancelled: .cancelledRemotely
            case RejectReason.updateRequired: .thisMacOutdated
            default: .unexpectedResponse
            }
            fail(error)

        default:
            fail(.unexpectedResponse)
        }
    }

    private func fail(_ error: PairingError) {
        guard step != .done else { return }
        step = .done
        connectTimeout?.cancel()
        state = .failed(error)
        connection.close()
    }
}
