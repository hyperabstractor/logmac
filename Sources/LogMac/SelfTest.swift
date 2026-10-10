#if DEBUG
import CryptoKit
import Foundation
import Network

/// `swift run LogMac --selftest` (debug builds only): pairing checks over loopback, with no
/// Bonjour and no real settings touched. Exits non-zero if any check fails.
@MainActor
func runSelfTest() -> Never {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        print(ok ? "ok   " : "FAIL ", what)
        if !ok { failures += 1 }
    }

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("logmac-selftest-\(UUID().uuidString)")
    let suite = "logmac.selftest"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { try? FileManager.default.removeItem(at: dir) }

    func store(_ name: String) -> PairingStore {
        PairingStore(directory: dir.appendingPathComponent(name))
    }

    func makeServer(_ store: PairingStore) -> SharingServer {
        let server = SharingServer(store: store, defaults: defaults, port: .any, advertises: false) { Snapshot() }
        server.isEnabled = true
        waitUntil { server.status == .sharing && server.boundPort != nil }
        return server
    }

    func loopback(_ port: NWEndpoint.Port?) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: port ?? .any)
    }

    // 1. Happy path: same code on both sides, nothing stored until both confirm, same token.
    do {
        let serverStore = store("server")
        let clientStore = store("client")
        let server = makeServer(serverStore)
        server.openPairing()
        var serverCode: String?
        server.onPairingRequest = { serverCode = server.pending?.code }

        let monitor = RemoteMonitor(store: clientStore)
        let attempt = monitor.beginPairing(with: .endpoint(loopback(server.boundPort)))
        waitUntil { attempt.state.code != nil }
        check(attempt.state.code != nil && attempt.state.code == serverCode,
              "both Macs show the same code (\(attempt.state.code ?? "none") / \(serverCode ?? "none"))")

        attempt.confirm()
        wait(0.5)
        check(serverStore.data.viewers.isEmpty && clientStore.data.hosts.isEmpty && attempt.state != .paired,
              "nothing is stored until both sides confirm")

        server.confirmPairing()
        waitUntil { attempt.state == .paired && !serverStore.data.viewers.isEmpty }
        let serverToken = serverStore.data.viewers.first?.token
        let clientToken = clientStore.data.hosts.first?.token
        check(attempt.state == .paired, "client stores the pairing once both confirm")
        check(serverToken != nil && serverToken == clientToken && serverToken?.count == 32,
              "both Macs hold the same 32-byte token")
        check(!server.isPairingOpen, "pairing window closes after a successful pairing")

        // The unchanged auth flow works with the new token.
        let client = RawClient(loopback(server.boundPort))
        waitUntil { client.first(.hello) != nil }
        if let challenge = client.first(.hello)?.challenge, let clientToken {
            client.send(Message(
                type: .auth, id: clientStore.data.deviceID,
                proof: PairingCrypto.authProof(token: clientToken, challenge: challenge)))
        }
        waitUntil { client.first(.welcome) != nil }
        check(client.first(.welcome) != nil, "the paired Mac authenticates with its token")
        client.close()
        monitor.hosts.forEach { $0.stop() }
        server.isEnabled = false
    }

    // 2. A second Mac is told the server is busy; cancelling on the server reaches the client.
    do {
        let server = makeServer(store("busy-server"))
        server.openPairing()
        let first = RemoteMonitor(store: store("busy-a")).beginPairing(with: .endpoint(loopback(server.boundPort)))
        waitUntil { first.state.code != nil }
        let second = RemoteMonitor(store: store("busy-b")).beginPairing(with: .endpoint(loopback(server.boundPort)))
        waitUntil { second.state == .failed(.busy) }
        check(second.state == .failed(.busy), "a second Mac is rejected while one is pairing")
        server.cancelPendingPairing()
        waitUntil { first.state == .failed(.cancelledRemotely) }
        check(first.state == .failed(.cancelledRemotely), "cancelling on the server fails the client")
        server.isEnabled = false
    }

    // 3. An old client sending a typed-code proof is told to update.
    do {
        let server = makeServer(store("old-client-server"))
        server.openPairing()
        let client = RawClient(loopback(server.boundPort))
        waitUntil { client.first(.hello) != nil }
        client.send(Message(type: .pair, id: "old", publicKey: PairingCrypto.randomBytes(), proof: Data(repeating: 1, count: 32)))
        waitUntil { client.first(.error) != nil }
        check(client.first(.error)?.reason == RejectReason.updateRequired, "an old client is told to update")
        client.close()
        server.isEnabled = false
    }

    // 4. The client aborts when the server's reveal doesn't match its commitment, and flags old servers.
    for (mode, expected, what) in [
        (FakeServer.Mode.wrongNonce, PairingAttempt.State.failed(.verificationFailed), "revealing a different nonce aborts the client"),
        (.wrongCommit, .failed(.verificationFailed), "a tampered commit aborts the client"),
        (.noCommit, .failed(.otherMacOutdated), "a server without commitments is flagged as outdated"),
        (.earlyWelcome, .failed(.unexpectedResponse), "a welcome before this user confirms is refused"),
    ] {
        let fake = FakeServer(mode: mode)
        waitUntil { fake.port != nil }
        let attempt = RemoteMonitor(store: store("fake-\(mode)")).beginPairing(with: .endpoint(loopback(fake.port)))
        waitUntil { attempt.isFinished }
        check(attempt.state == expected, attempt.state == expected ? what : "\(what) (got \(attempt.state))")
        fake.stop()
    }

    // 5. A relay terminating both sides with its own keys can't make the two codes match.
    do {
        let realServer = makeServer(store("relay-real-server"))
        realServer.openPairing()

        // Client-facing half of the relay: poses as a server.
        let relayServer = makeServer(store("relay-mitm-server"))
        relayServer.openPairing()
        // Server-facing half: poses as a client, started when the real client reaches the relay.
        var relayClient: PairingAttempt?
        relayServer.onPairingRequest = {
            relayClient = RemoteMonitor(store: store("relay-mitm-client"))
                .beginPairing(with: .endpoint(loopback(realServer.boundPort)))
        }

        let realClientStore = store("relay-real-client")
        let realClient = RemoteMonitor(store: realClientStore).beginPairing(with: .endpoint(loopback(relayServer.boundPort)))
        waitUntil { realClient.state.code != nil && realServer.pending != nil }
        let clientCode = realClient.state.code
        let serverCode = realServer.pending?.code
        check(relayClient != nil && clientCode != nil && serverCode != nil && clientCode != serverCode,
              "a relay in the middle shows different codes on each side (\(clientCode ?? "none") vs \(serverCode ?? "none"))")
        check(realClientStore.data.hosts.isEmpty && realServer.viewers.isEmpty, "nothing is stored without confirmation")

        realClient.cancel()
        relayClient?.cancel()
        realServer.isEnabled = false
        relayServer.isEnabled = false
    }

    // 6. Remote process lists and signed quit requests.
    do {
        let clientStore = store("proc-client")
        let serverStore = store("proc-server")
        let token = PairingCrypto.randomBytes()
        let viewerID = clientStore.data.deviceID
        serverStore.update {
            $0.viewers.append(PairedViewer(id: viewerID, name: "Test viewer", token: token, pairedAt: Date()))
        }
        let server = makeServer(serverStore)

        func spawnSleep() -> (Process, ProcessEntry) {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["600"]
            try? child.run()
            let pid = child.processIdentifier
            let entry = ProcessEntry(
                id: "pid:\(pid)", name: "sleep", pid: pid, path: "/bin/sleep",
                startTime: ProcessControl.startTime(of: pid) ?? 0, cpu: 0, memory: 0, count: 1)
            return (child, entry)
        }

        // End to end through the real watching side.
        let monitor = RemoteMonitor(store: clientStore)
        let info = DeviceInfo(id: serverStore.data.deviceID, name: "Test server", product: "Mac", chip: "")
        let host = RemoteHost(
            PairedHost(info: info, token: token, manualHost: "127.0.0.1", port: server.boundPort?.rawValue), monitor: monitor)
        host.connect()
        waitUntil { host.isConnected }
        check(host.supportsProcesses && host.supportsQuit, "the other Mac announces process lists and quit")

        let source = RemoteProcessSource(host: host, metric: .ram)
        source.start()
        waitUntil { !source.isMeasuring }
        check(!source.top.isEmpty && source.top.allSatisfy { $0.startTime != 0 },
              "a signed process list arrives, with start times")
        check(source.quitUnavailableReason != nil, "quitting is off until the other Mac allows it")

        server.setAllowsQuit(true, for: viewerID)
        waitUntil { source.allowsQuit }
        let (first, firstEntry) = spawnSleep()
        source.quit(firstEntry, force: true)
        waitUntil { !first.isRunning }
        check(!first.isRunning && source.quitMessage == nil, "an allowed Mac force-quits a process remotely")
        source.stop()
        host.stop()

        // The sharing side's checks, from a bare client holding the same token.
        let client = RawClient(loopback(server.boundPort))
        waitUntil { client.first(.hello) != nil }
        let challenge = client.first(.hello)?.challenge ?? Data()
        client.send(Message(type: .auth, id: viewerID, proof: PairingCrypto.authProof(token: token, challenge: challenge)))
        waitUntil { client.first(.welcome) != nil }

        func quit(_ entry: ProcessEntry, counter: UInt64, startTime: UInt64? = nil, proof: Data? = nil) -> QuitOutcome? {
            let startTime = startTime ?? entry.startTime
            let before = client.received.count
            client.send(Message(
                type: .quit,
                proof: proof ?? RequestSigning.quitProof(
                    token: token, challenge: challenge, counter: counter, pid: entry.pid, startTime: startTime, force: true),
                counter: counter, pid: entry.pid, startTime: startTime, force: true))
            // Only a reply to this send counts; an earlier one may share the counter (the replay check).
            func reply() -> Message? { client.received[before...].first { $0.type == .quitResult && $0.counter == counter } }
            waitUntil(timeout: 1.5) { reply() != nil }
            return reply()?.outcome
        }

        let (second, secondEntry) = spawnSleep()
        server.setAllowsQuit(false, for: viewerID)
        check(quit(secondEntry, counter: 10) == .notAllowed && second.isRunning, "a Mac that isn't allowed can't quit anything")
        server.setAllowsQuit(true, for: viewerID)
        check(quit(secondEntry, counter: 11, proof: PairingCrypto.randomBytes()) == nil && second.isRunning,
              "a forged quit request is ignored")
        check(quit(secondEntry, counter: 12, startTime: secondEntry.startTime + 1) == .gone && second.isRunning,
              "a quit for a reused pid is refused")
        let launchd = ProcessEntry(id: "pid:1", name: "launchd", pid: 1, path: nil, cpu: 0, memory: 0, count: 1)
        check(quit(launchd, counter: 13) == .protected, "launchd can't be quit remotely")
        check(quit(secondEntry, counter: 14) == .done, "a signed quit works")
        waitUntil { !second.isRunning }
        check(!second.isRunning, "the process is gone")

        let (third, thirdEntry) = spawnSleep()
        check(quit(thirdEntry, counter: 14) == nil && third.isRunning, "a replayed counter is ignored")

        client.send(Message(type: .processes, counter: 20, metric: "ram", grouped: true))
        waitUntil { client.received.contains { $0.type == .processes && $0.counter == 20 } }
        if let reply = client.received.first(where: { $0.type == .processes && $0.counter == 20 }),
           let payload = reply.payload, let proof = reply.proof {
            check(RequestSigning.isValidProcesses(proof, token: token, challenge: challenge, counter: 20, payload: payload),
                  "process lists are signed")
            var tampered = payload
            tampered[tampered.startIndex] ^= 1
            check(!RequestSigning.isValidProcesses(proof, token: token, challenge: challenge, counter: 20, payload: tampered),
                  "an altered process list fails verification")
        } else {
            check(false, "process lists are signed")
        }

        for child in [first, second, third] where child.isRunning { child.terminate() }
        client.close()
        server.isEnabled = false
    }

    defaults.removePersistentDomain(forName: suite)
    print(failures == 0 ? "All pairing checks passed." : "\(failures) pairing check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

@MainActor
private func wait(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
@discardableResult
private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        wait(0.05)
    }
    return true
}

private extension PairingAttempt.State {
    var code: String? {
        switch self {
        case let .confirm(code), let .waiting(code): code
        default: nil
        }
    }
}

/// A bare protocol client that records what it receives.
@MainActor
private final class RawClient {
    private let connection: LineConnection
    private(set) var received: [Message] = []

    init(_ endpoint: NWEndpoint) {
        connection = LineConnection(to: endpoint)
        connection.onMessage = { [weak self] in self?.received.append($0) }
        connection.start()
    }

    func first(_ kind: Message.Kind) -> Message? { received.first { $0.type == kind } }
    func send(_ message: Message) { connection.send(message) }
    func close() { connection.close() }
}

/// A misbehaving server for the commitment checks.
@MainActor
private final class FakeServer {
    enum Mode: String {
        /// Commits honestly, then reveals a different nonce.
        case wrongNonce
        /// Sends a commit that doesn't match its key and nonce.
        case wrongCommit
        /// Speaks the protocol from before commitments.
        case noCommit
        /// Honest until the reveal, then confirms and welcomes before the client's user has confirmed.
        case earlyWelcome
    }

    private let listener: NWListener
    private var connections: [LineConnection] = []
    private var isReady = false

    /// Set once the listener accepts connections; the port alone can be known earlier.
    var port: NWEndpoint.Port? { isReady ? listener.port : nil }

    init(mode: Mode) {
        listener = try! NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] nw in
            MainActor.assumeIsolated {
                let connection = LineConnection(nw)
                self?.connections.append(connection)
                let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
                let nonce = PairingCrypto.randomBytes()
                connection.onReady = {
                    let commit: Data? = switch mode {
                    case .wrongNonce, .earlyWelcome: PairingCrypto.commit(serverKey: key, serverNonce: nonce)
                    case .wrongCommit: PairingCrypto.randomBytes()
                    case .noCommit: nil
                    }
                    connection.send(Message(
                        type: .hello, id: "fake-\(mode)", challenge: PairingCrypto.randomBytes(),
                        publicKey: key, commit: commit))
                }
                connection.onMessage = { message in
                    guard message.type == .pair else { return }
                    connection.send(Message(type: .reveal, nonce: mode == .wrongNonce ? PairingCrypto.randomBytes() : nonce))
                    if mode == .earlyWelcome {
                        connection.send(Message(type: .confirm))
                        connection.send(Message(type: .welcome, info: DeviceInfo.current(id: "fake-\(mode)")))
                    }
                }
                connection.start()
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .ready = state { self?.isReady = true }
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.close() }
    }
}
#endif
