import CryptoKit
import Foundation
import Network

/// Wire protocol: newline-delimited JSON `Message`s over TCP.
///
/// server → hello   { id, challenge, publicKey = kS, commit = SHA256(kS ‖ nS) }
/// client → auth    { id, proof = HMAC(token, challenge) }          a paired Mac reconnecting
/// server → welcome { info }, then stats { stats } every couple of seconds
///      or  error   { reason }, then closes
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
}

struct Message: Codable {
    enum Kind: String, Codable {
        case hello, auth, pair, reveal, confirm, welcome, stats, error
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
