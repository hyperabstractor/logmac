import Foundation
import Network

/// An NWConnection that exchanges newline-delimited JSON `Message`s. Runs on the main queue.
@MainActor
final class LineConnection {
    var onReady: (() -> Void)?
    var onMessage: ((Message) -> Void)?
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    convenience init(to endpoint: NWEndpoint) {
        self.init(NWConnection(to: endpoint, using: .tcp))
    }

    /// The peer's resolved IP address, once connected.
    var remoteAddress: String? {
        guard case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint else { return nil }
        switch host {
        case let .ipv4(address): return "\(address)"
        case let .ipv6(address): return "\(address)"
        case let .name(name, _): return name
        @unknown default: return nil
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
        receive()
    }

    func send(_ message: Message, thenClose: Bool = false) {
        guard !closed, var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard thenClose else { return }
            MainActor.assumeIsolated { self?.close() }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let onClose = onClose
        self.onReady = nil
        self.onMessage = nil
        self.onClose = nil
        onClose?()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onReady?()
        case .failed, .waiting, .cancelled:
            // `.waiting` means the route is unavailable right now; fail fast so callers can try another.
            close()
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data {
                    self.buffer.append(data)
                    self.drainLines()
                }
                if isComplete || error != nil {
                    self.close()
                } else if !self.closed {
                    self.receive()
                }
            }
        }
    }

    private func drainLines() {
        while !closed, let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = try? JSONDecoder().decode(Message.self, from: line) {
                onMessage?(message)
            }
        }
        if buffer.count > 256 * 1024 { close() }
    }
}
