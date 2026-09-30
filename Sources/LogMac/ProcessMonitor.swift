import AppKit
import Darwin
import Observation
import SensorsC

struct ProcessEntry: Identifiable, Equatable {
    let id: String
    let name: String
    /// The process this row stands for: its icon, and what Quit acts on (the app, for grouped helpers).
    let pid: pid_t
    let path: String?
    /// Percent of one core, like Activity Monitor, so it can exceed 100.
    var cpu: Double
    /// Physical footprint in bytes, Activity Monitor's "Memory" column.
    var memory: UInt64
    /// Number of processes folded into this row.
    var count: Int
}

/// A running GUI app, captured on the main thread for the background sampler.
struct AppRecord {
    let name: String
    let bundlePath: String?
}

/// Reads per-process CPU time and memory. Only processes owned by this user are readable without root.
/// Not thread-safe: only ever used from ProcessMonitor's serial queue.
final class ProcessSampler: @unchecked Sendable {
    private struct Raw {
        let pid: pid_t
        let cpuNanos: UInt64
        let footprint: UInt64
        let path: String?
    }

    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastTime: UInt64?
    private var paths: [pid_t: String] = [:]
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Forgets the previous sample so the next CPU reading isn't averaged over a long gap.
    func reset() {
        lastCPU = [:]
        lastTime = nil
    }

    /// Returns entries, and whether CPU values are meaningful yet (they need two samples).
    func sample(apps: [pid_t: AppRecord], grouped: Bool) -> (entries: [ProcessEntry], hasCPU: Bool) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let raws = readAll()
        let elapsed = lastTime.map { Double(now - $0) } ?? 0

        var entries: [String: ProcessEntry] = [:]
        var nextCPU: [pid_t: UInt64] = [:]
        for raw in raws {
            nextCPU[raw.pid] = raw.cpuNanos
            let cpu: Double = if elapsed > 0, let prev = lastCPU[raw.pid], raw.cpuNanos >= prev {
                Double(raw.cpuNanos - prev) / elapsed * 100
            } else {
                0
            }

            let (key, name, pid) = grouped ? groupKey(raw, apps: apps) : ("pid:\(raw.pid)", displayName(raw, apps: apps), raw.pid)
            if var existing = entries[key] {
                existing.cpu += cpu
                existing.memory += raw.footprint
                existing.count += 1
                entries[key] = existing
            } else {
                entries[key] = ProcessEntry(
                    id: key, name: name, pid: pid, path: raw.path,
                    cpu: cpu, memory: raw.footprint, count: 1)
            }
        }

        let hasCPU = lastTime != nil
        lastCPU = nextCPU
        lastTime = now
        paths = paths.filter { nextCPU[$0.key] != nil }
        return (Array(entries.values), hasCPU)
    }

    private func readAll() -> [Raw] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }

        var raws: [Raw] = []
        raws.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            // Fails with EPERM for other users' processes.
            guard result == 0 else { continue }
            // rusage times are mach ticks on Apple Silicon.
            let ticks = info.ri_user_time + info.ri_system_time
            let nanos = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
            raws.append(Raw(pid: pid, cpuNanos: nanos, footprint: info.ri_phys_footprint, path: path(for: pid)))
        }
        return raws
    }

    private func path(for pid: pid_t) -> String? {
        if let cached = paths[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        paths[pid] = path
        return path
    }

    private func displayName(_ raw: Raw, apps: [pid_t: AppRecord]) -> String {
        if let app = apps[raw.pid] { return app.name }
        if let path = raw.path { return (path as NSString).lastPathComponent }
        var buffer = [CChar](repeating: 0, count: 64)
        proc_name(raw.pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "pid \(raw.pid)" : name
    }

    /// Folds helpers into their app: processes inside the app's bundle, plus XPC services running for it
    /// (WebKit content, networking, and GPU processes, the Open and Save panel, ...).
    /// Command-line tools launched from a terminal stay separate.
    private func groupKey(_ raw: Raw, apps: [pid_t: AppRecord]) -> (String, String, pid_t) {
        // Check the owner before the process itself: helpers such as "Safari Web Content" and
        // "Claude Helper" register as apps of their own and would otherwise get a row each.
        let responsible = logmac_responsible_pid(raw.pid)
        if responsible != raw.pid, let app = apps[responsible], let path = raw.path {
            let inBundle = app.bundlePath.map { path.hasPrefix($0 + "/") } ?? false
            if inBundle || path.contains("/XPCServices/") {
                return ("app:\(responsible)", app.name, responsible)
            }
        }
        if let app = apps[raw.pid] {
            return ("app:\(raw.pid)", app.name, raw.pid)
        }
        return ("pid:\(raw.pid)", displayName(raw, apps: apps), raw.pid)
    }
}

/// Publishes the top processes for CPU or memory while the process list is open.
@MainActor
@Observable
final class ProcessMonitor {
    static let limit = 12
    static let interval: TimeInterval = 2

    private(set) var entries: [ProcessEntry] = []
    private(set) var hasCPU = false
    private(set) var metric: Metric?

    var grouped: Bool {
        didSet {
            UserDefaults.standard.set(grouped, forKey: "groupProcesses")
            refresh()
        }
    }

    @ObservationIgnored private let sampler = ProcessSampler()
    @ObservationIgnored private let queue = DispatchQueue(label: "logmac.processes", qos: .utility)
    @ObservationIgnored private var timer: Timer?

    init() {
        grouped = UserDefaults.standard.object(forKey: "groupProcesses") as? Bool ?? true
    }

    /// Entries sorted by the open metric, largest first.
    var top: [ProcessEntry] {
        let sorted = metric == .cpu
            ? entries.sorted { $0.cpu > $1.cpu }
            : entries.sorted { $0.memory > $1.memory }
        return Array(sorted.prefix(Self.limit))
    }

    func start(_ metric: Metric) {
        stop()
        self.metric = metric
        hasCPU = false
        queue.async { [sampler] in sampler.reset() }
        refresh()
        // CPU needs a second sample; take it quickly so the list doesn't sit empty.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.metric == metric else { return }
            self.refresh()
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        metric = nil
    }

    /// Re-samples shortly, e.g. so a quit process drops off the list without waiting for the timer.
    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard metric != nil else { return }
        var apps: [pid_t: AppRecord] = [:]
        for app in NSWorkspace.shared.runningApplications {
            apps[app.processIdentifier] = AppRecord(
                name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                bundlePath: app.bundleURL?.path)
        }
        let grouped = grouped
        queue.async { [sampler] in
            let result = sampler.sample(apps: apps, grouped: grouped)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.metric != nil else { return }
                    self.entries = result.entries
                    self.hasCPU = result.hasCPU
                }
            }
        }
    }
}
