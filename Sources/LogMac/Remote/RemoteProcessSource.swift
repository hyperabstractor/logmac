import Foundation
import Observation

/// A paired Mac's top processes, polled while its process list is open.
@MainActor
@Observable
final class RemoteProcessSource: ProcessSource {
    let metric: Metric
    private(set) var top: [ProcessEntry] = []
    private(set) var hasCPU = false
    private(set) var hasReply = false
    /// Whether the other Mac lets this one quit its processes (sent with every list).
    private(set) var allowsQuit = false
    private(set) var quitMessage: String?

    var grouped: Bool {
        didSet {
            UserDefaults.standard.set(grouped, forKey: "groupProcesses")
            request()
        }
    }

    @ObservationIgnored private weak var host: RemoteHost?
    @ObservationIgnored private var latestRequest: UInt64 = 0
    @ObservationIgnored private var latestAccepted: UInt64 = 0
    @ObservationIgnored private var pendingQuits: [UInt64: String] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var stopped = false

    init(host: RemoteHost, metric: Metric) {
        self.host = host
        self.metric = metric
        grouped = UserDefaults.standard.object(forKey: "groupProcesses") as? Bool ?? true
    }

    var isMeasuring: Bool {
        !hasReply || (metric == .cpu && !hasCPU)
    }

    var statusMessage: String? {
        guard let host else { return "This Mac was removed." }
        if !host.isConnected { return "\(host.info.displayName) isn't connected." }
        if !host.supportsProcesses { return "Update LogMac on \(host.info.displayName) to see its processes." }
        return nil
    }

    var quitUnavailableReason: String? {
        guard let host, host.supportsQuit else { return "Update LogMac on the other Mac to quit its processes." }
        return allowsQuit
            ? nil
            : "To quit apps here, turn on \"Can quit apps\" for this Mac in LogMac settings on \(host.info.displayName)."
    }

    var isRemote: Bool { true }

    func start() {
        host?.processSource = self
        request()
        // The other Mac's first sample has no CPU baseline; ask again quickly so the list doesn't sit empty.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.stopped else { return }
            self.request()
            let timer = Timer(timeInterval: ProcessMonitor.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.request() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        if host?.processSource === self { host?.processSource = nil }
    }

    func quit(_ entry: ProcessEntry, force: Bool) {
        guard quitUnavailableReason == nil, let counter = host?.requestQuit(entry, force: force) else {
            quitMessage = quitUnavailableReason ?? "\(entry.name) couldn't be quit: the other Mac isn't connected."
            return
        }
        pendingQuits[counter] = entry.name
    }

    /// A verified list from the other Mac. Older or unrequested replies are ignored.
    func receive(counter: UInt64, entries: [ProcessEntry], hasCPU: Bool, allowsQuit: Bool) {
        guard counter > latestAccepted, counter <= latestRequest else { return }
        latestAccepted = counter
        top = entries
        self.hasCPU = hasCPU
        self.allowsQuit = allowsQuit
        hasReply = true
    }

    func receiveQuitResult(counter: UInt64, outcome: QuitOutcome) {
        guard let name = pendingQuits.removeValue(forKey: counter) else { return }
        quitMessage = outcome.message(for: name, on: host?.info.displayName)
        if outcome == .done {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.request() }
        }
    }

    private func request() {
        guard !stopped, let host, let counter = host.requestProcesses(metric: metric, grouped: grouped) else { return }
        latestRequest = counter
    }
}
