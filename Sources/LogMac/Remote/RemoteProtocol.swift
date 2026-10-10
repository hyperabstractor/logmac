import CryptoKit
import Foundation
import Network

/// Wire protocol: newline-delimited JSON `Message`s over TCP.
///
/// server → hello   { id, challenge, publicKey = kS, commit = SHA256(kS ‖ nS) }
/// client → auth    { id, proof = HMAC(token, challenge) }          a paired Mac reconnecting
/// server → welcome { info, features }, then stats { stats } every couple of seconds
///      or  error   { reason }, then closes
///
/// Once authenticated, the watching Mac can ask for more (when `features` lists it):
/// client → processes  { counter, metric, grouped }
/// server → processes  { counter, payload = JSON [ProcessEntry], proof, hasCPU, allowsQuit }
/// client → quit       { counter, pid, startTime, force, proof }
/// server → quitResult { counter, outcome }
/// Process lists and quit requests are signed with the pairing token, bound to this connection's
/// challenge and a counter (see `RequestSigning`). The connection itself isn't encrypted, so without
/// that someone on the LAN could inject a quit, or relabel rows so the wrong app gets quit.
///
/// Pairing is numeric comparison, like Bluetooth LE Secure Connections. Nobody types a code:
/// client → pair    { id, publicKey = kC, nonce = nC, info }
/// server → reveal  { nonce = nS }        the client checks it against `commit`
///          both show code = SHA256(kC ‖ kS ‖ nC ‖ nS) as 6 digits, and the user checks they match
/// each   → confirm {}                    sent only after that side's user clicks Pair
/// server → welcome { info }              once both sides confirmed; each stores the pairing only then
///
/// The server commits to nS before it sees nC, so a machine in the middle can't steer the two codes to
/// match: it gets one-in-a-million per attempt, and every attempt needs a person to click Pair.
/// The token is HKDF over the X25519 shared secret, so it never crosses the network.
enum RemoteProtocol {
    static let port: NWEndpoint.Port = 47474
    static let serviceType = "_logmac._tcp"
    static let statsInterval: TimeInterval = 2
    /// Requests this build answers after `welcome`; older builds send none.
    static let features: Set<String> = ["processes", "quit"]
}

struct Message: Codable {
    enum Kind: String, Codable {
        case hello, auth, pair, reveal, confirm, welcome, stats, error
        case processes, quit, quitResult
    }

    var type: Kind
    var id: String?
    var challenge: Data?
    var publicKey: Data?
    var commit: Data?
    var nonce: Data?
    /// Only sent by clients from before numeric comparison; used to tell them to update.
    var proof: Data?
    var info: DeviceInfo?
    var stats: RemoteStats?
    var reason: String?
    var features: [String]?
    /// Increases with every request on a connection; replies echo it.
    var counter: UInt64?
    var metric: String?
    var grouped: Bool?
    /// The signed bytes of a process list: JSON-encoded `[ProcessEntry]`.
    var payload: Data?
    var hasCPU: Bool?
    var allowsQuit: Bool?
    var pid: Int32?
    var startTime: UInt64?
    var force: Bool?
    var outcome: QuitOutcome?
}

enum RejectReason {
    static let unauthorized = "unauthorized"
    static let notPairing = "not-pairing"
    static let busy = "busy"
    static let cancelled = "cancelled"
    static let updateRequired = "update-required"
    static let invalid = "invalid"
}

struct RemoteStats: Codable {
    var values: [String: Double]
    var cpuTemp: Double?
    var memUsed: UInt64
    var memTotal: UInt64
    var diskUsed: Int64
    var diskTotal: Int64

    init(_ snapshot: Snapshot) {
        values = Dictionary(uniqueKeysWithValues: snapshot.values.map { ($0.key.rawValue, $0.value) })
        cpuTemp = snapshot.cpuTemp
        memUsed = snapshot.memUsed
        memTotal = snapshot.memTotal
        diskUsed = snapshot.diskUsed
        diskTotal = snapshot.diskTotal
    }

    var metricValues: [Metric: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in Metric(rawValue: key).map { ($0, value) } })
    }

    func value(_ metric: Metric) -> Double? { values[metric.rawValue] }
}

enum PairingCrypto {
    /// Length of X25519 public keys, nonces, challenges, and commits.
    static let length = 32

    static func randomBytes() -> Data {
        Data((0..<length).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func authProof(token: Data, challenge: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: challenge, using: SymmetricKey(data: token)))
    }

    static func isValidAuth(_ proof: Data, token: Data, challenge: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: challenge, using: SymmetricKey(data: token))
    }

    /// The server's commitment to its nonce, sent before it sees the client's.
    static func commit(serverKey: Data, serverNonce: Data) -> Data {
        Data(SHA256.hash(data: serverKey + serverNonce))
    }

    /// The 6-digit code both Macs show, formatted "123 456".
    static func code(clientKey: Data, serverKey: Data, clientNonce: Data, serverNonce: Data) -> String {
        let digest = SHA256.hash(data: clientKey + serverKey + clientNonce + serverNonce)
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        return String(format: "%03d %03d", value / 1000, value % 1000)
    }

    static func token(privateKey: Curve25519.KeyAgreement.PrivateKey, peerKey: Data, salt: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("logmac-pairing".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}

/// Signs process lists (server → client) and quit requests (client → server) with the pairing token.
/// Each signature covers the connection's challenge and a counter, so it can't be moved to another
/// connection or replayed, and a label that differs per message type so one can't pass for the other.
enum RequestSigning {
    static func processesProof(token: Data, challenge: Data, counter: UInt64, payload: Data) -> Data {
        mac(token, "logmac-processes", challenge + bigEndian(counter) + payload)
    }

    static func isValidProcesses(_ proof: Data, token: Data, challenge: Data, counter: UInt64, payload: Data) -> Bool {
        verify(proof, token, "logmac-processes", challenge + bigEndian(counter) + payload)
    }

    static func quitProof(token: Data, challenge: Data, counter: UInt64, pid: Int32, startTime: UInt64, force: Bool) -> Data {
        mac(token, "logmac-quit", quitData(challenge, counter, pid, startTime, force))
    }

    static func isValidQuit(
        _ proof: Data, token: Data, challenge: Data, counter: UInt64, pid: Int32, startTime: UInt64, force: Bool
    ) -> Bool {
        verify(proof, token, "logmac-quit", quitData(challenge, counter, pid, startTime, force))
    }

    private static func quitData(_ challenge: Data, _ counter: UInt64, _ pid: Int32, _ startTime: UInt64, _ force: Bool) -> Data {
        challenge + bigEndian(counter) + bigEndian(UInt64(UInt32(bitPattern: pid))) + bigEndian(startTime) + Data([force ? 1 : 0])
    }

    private static func mac(_ token: Data, _ label: String, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + data, using: SymmetricKey(data: token)))
    }

    private static func verify(_ proof: Data, _ token: Data, _ label: String, _ data: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data(label.utf8) + data, using: SymmetricKey(data: token))
    }

    private static func bigEndian(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
