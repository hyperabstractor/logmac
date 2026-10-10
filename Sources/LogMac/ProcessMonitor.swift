import AppKit
import Darwin
import Observation
import SensorsC

/// One row of a process list. Codable so a paired Mac can send its list over the network.
struct ProcessEntry: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    /// The process this row stands for: its icon, and what Quit acts on (the app, for grouped helpers).
    let pid: pid_t
    let path: String?
    /// When `pid` started, so Quit can tell if the pid now belongs to a different process.
    var startTime: UInt64 = 0
    /// For apps; lets another Mac show the right icon.
    var bundleID: String?
    /// Percent of one core, like Activity Monitor, so it can exceed 100.
    var cpu: Double
    /// Physical footprint in bytes, Activity Monitor's "Memory" column.
    var memory: UInt64
    /// Number of processes folded into this row.
    var count: Int

    /// The largest entries by CPU or memory.
    static func top(_ entries: [ProcessEntry], by metric: Metric, limit: Int) -> [ProcessEntry] {
        let sorted = metric == .cpu
            ? entries.sorted { $0.cpu > $1.cpu }
            : entries.sorted { $0.memory > $1.memory }
        return Array(sorted.prefix(limit))
    }
}

/// A running GUI app, captured on the main thread for the background sampler.
struct AppRecord {
    let name: String
    let bundlePath: String?
    let bundleID: String?

    @MainActor
    static func running() -> [pid_t: AppRecord] {
        var apps: [pid_t: AppRecord] = [:]
        for app in NSWorkspace.shared.runningApplications {
            apps[app.processIdentifier] = AppRecord(
                name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                bundlePath: app.bundleURL?.path,
                bundleID: app.bundleIdentifier)
        }
        return apps
    }
}

/// Reads per-process CPU time and memory. Only processes owned by this user are readable without root.
/// Not thread-safe: only ever used from ProcessMonitor's serial queue.
final class ProcessSampler: @unchecked Sendable {
    private struct Raw {
        let pid: pid_t
        let cpuNanos: UInt64
        let footprint: UInt64
        let startTime: UInt64
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
        var startTimes: [pid_t: UInt64] = [:]
        for raw in raws {
            nextCPU[raw.pid] = raw.cpuNanos
            startTimes[raw.pid] = raw.startTime
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
        let result = entries.values.map { entry in
            var entry = entry
            entry.startTime = startTimes[entry.pid] ?? 0
            entry.bundleID = apps[entry.pid]?.bundleID
            return entry
        }
        return (result, hasCPU)
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
            raws.append(Raw(
                pid: pid, cpuNanos: nanos, footprint: info.ri_phys_footprint,
                startTime: info.ri_proc_start_abstime, path: path(for: pid)))
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

/// What happened to a Quit or Force Quit request. Raw values go over the network.
enum QuitOutcome: String, Codable {
    case done
    /// The process had already exited, or its pid now belongs to a different process.
    case gone
    case protected
    case notAllowed = "not-allowed"
    case failed
}

/// Quits processes on this Mac, for the local list and for paired Macs that are allowed to.
@MainActor
enum ProcessControl {
    /// Killing these ends the login session.
    private static let protectedNames: Set<String> = ["loginwindow", "launchd"]

    static func isProtected(name: String, path: String?) -> Bool {
        let executable = path.map { ($0 as NSString).lastPathComponent }
        return protectedNames.contains(name) || executable.map(protectedNames.contains) == true
    }

    /// Decides from the pid alone, for requests from another Mac whose row data can't be trusted.
    static func isProtected(pid: pid_t) -> Bool {
        guard pid > 1 else { return true }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return isProtected(name: "", path: String(cString: buffer))
    }

    static func startTime(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_proc_start_abstime : nil
    }

    /// Apps get a normal quit request (so they can prompt to save); other processes get SIGTERM / SIGKILL.
    /// Refuses if `pid` no longer started at `startTime`, i.e. the process exited and the pid was reused.
    static func quit(pid: pid_t, startTime: UInt64, force: Bool) -> QuitOutcome {
        guard !isProtected(pid: pid) else { return .protected }
        guard let current = Self.startTime(of: pid), current == startTime else { return .gone }
        if let app = NSRunningApplication(processIdentifier: pid) {
            if force ? app.forceTerminate() : app.terminate() { return .done }
        }
        if kill(pid, force ? SIGKILL : SIGTERM) == 0 { return .done }
        return errno == ESRCH ? .gone : .failed
    }
}

/// Where a process list comes from: this Mac, or a paired Mac over the network.
@MainActor
protocol ProcessSource: AnyObject {
    var top: [ProcessEntry] { get }
    /// True until there's something meaningful to show (CPU needs two samples).
    var isMeasuring: Bool { get }
    var grouped: Bool { get set }
    /// Shown instead of the list, e.g. when the other Mac isn't connected.
    var statusMessage: String? { get }
    /// Why Quit isn't available, or nil when it is.
    var quitUnavailableReason: String? { get }
    /// The outcome of the last Quit, when it didn't simply work.
    var quitMessage: String? { get }
    /// Whether rows come from another Mac, so icons are looked up by bundle ID instead of pid.
    var isRemote: Bool { get }
    func quit(_ entry: ProcessEntry, force: Bool)
}

extension QuitOutcome {
    /// Feedback for an outcome other than `.done`.
    func message(for name: String, on host: String? = nil) -> String? {
        switch self {
        case .done: nil
        case .gone: "\(name) had already quit."
        case .protected: "\(name) can't be quit from here."
        case .notAllowed: "\(host ?? "That Mac") doesn't allow this Mac to quit apps. Turn it on in LogMac settings there."
        case .failed: "Couldn't quit \(name)."
        }
    }
}

/// Publishes the top processes for CPU or memory while the process list is open.
@MainActor
@Observable
final class ProcessMonitor: ProcessSource {
    static let limit = 12
    static let interval: TimeInterval = 2

    private(set) var entries: [ProcessEntry] = []
    private(set) var hasCPU = false
    private(set) var metric: Metric?
    private(set) var quitMessage: String?

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
        ProcessEntry.top(entries, by: metric ?? .cpu, limit: Self.limit)
    }

    var isMeasuring: Bool {
        entries.isEmpty || (metric == .cpu && !hasCPU)
    }

    var statusMessage: String? { nil }
    var quitUnavailableReason: String? { nil }
    var isRemote: Bool { false }

    func quit(_ entry: ProcessEntry, force: Bool) {
        quitMessage = ProcessControl.quit(pid: entry.pid, startTime: entry.startTime, force: force).message(for: entry.name)
        refreshSoon()
    }

    func start(_ metric: Metric) {
        stop()
        self.metric = metric
        hasCPU = false
        quitMessage = nil
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
        let apps = AppRecord.running()
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
