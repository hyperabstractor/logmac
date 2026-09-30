import CryptoKit
import Foundation
import Network

/// Wire protocol: newline-delimited JSON `Message`s over TCP.
///
/// server → hello   { id, challenge, publicKey }
/// client → auth    { id, proof = HMAC(token, challenge) }
///      or  pair    { id, publicKey, proof = HMAC(code, challenge ‖ serverKey ‖ clientKey), info }
/// server → welcome { info }, then stats { stats } every couple of seconds
///      or  error   { reason }, then closes
///
/// Pairing derives the token from an X25519 key agreement, so it never crosses the network.
enum RemoteProtocol {
    static let port: NWEndpoint.Port = 47474
    static let serviceType = "_logmac._tcp"
    static let statsInterval: TimeInterval = 2
}

struct Message: Codable {
    enum Kind: String, Codable {
        case hello, auth, pair, welcome, stats, error
    }

    var type: Kind
    var id: String?
    var challenge: Data?
    var publicKey: Data?
    var proof: Data?
    var info: DeviceInfo?
    var stats: RemoteStats?
    var reason: String?
}

enum RejectReason {
    static let unauthorized = "unauthorized"
    static let notPairing = "not-pairing"
    static let wrongCode = "wrong-code"
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
    static func randomChallenge() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func authProof(token: Data, challenge: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: challenge, using: SymmetricKey(data: token)))
    }

    static func isValidAuth(_ proof: Data, token: Data, challenge: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: challenge, using: SymmetricKey(data: token))
    }

    static func pairingProof(code: String, challenge: Data, serverKey: Data, clientKey: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: challenge + serverKey + clientKey, using: SymmetricKey(data: Data(code.utf8))))
    }

    static func isValidPairing(_ proof: Data, code: String, challenge: Data, serverKey: Data, clientKey: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof, authenticating: challenge + serverKey + clientKey, using: SymmetricKey(data: Data(code.utf8)))
    }

    static func token(privateKey: Curve25519.KeyAgreement.PrivateKey, peerKey: Data, challenge: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: challenge, sharedInfo: Data("logmac-pairing".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}
