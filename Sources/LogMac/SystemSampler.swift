import Darwin
import Foundation
import IOKit
import SensorsC

enum Metric: String, CaseIterable, Identifiable {
    case cpu, gpu, ram, ssd

    var id: String { rawValue }

    /// Single letter under each menu bar bar.
    var letter: String {
        switch self {
        case .cpu: "C"
        case .gpu: "G"
        case .ram: "R"
        case .ssd: "S"
        }
    }

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "RAM"
        case .ssd: "SSD"
        }
    }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "Memory"
        case .ssd: "Disk"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "cube.transparent"
        case .ram: "memorychip"
        case .ssd: "internaldrive"
        }
    }

    var defaultThreshold: Double {
        switch self {
        case .cpu, .gpu, .ram: 85
        case .ssd: 90
        }
    }
}

struct Snapshot {
    /// Utilization per metric, 0–100.
    var values: [Metric: Double] = [:]
    /// Temperatures in °C.
    var cpuTemp: Double?
    var gpuTemp: Double?
    var hottestTemp: Double?
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 0
    var diskUsed: Int64 = 0
    var diskTotal: Int64 = 0
    /// Bytes per second.
    var netIn: Double = 0
    var netOut: Double = 0
}

/// Reads system stats. Not thread-safe: only ever used from StatsModel's serial queue.
final class SystemSampler: @unchecked Sendable {
    private let host = mach_host_self()
    private let pageSize: UInt64
    private var lastTicks: (UInt32, UInt32, UInt32, UInt32)?
    private var lastNet: [String: (UInt32, UInt32)] = [:]
    private var lastNetTime: TimeInterval?
    private var disk: (used: Int64, total: Int64)?
    private var lastDiskRead: TimeInterval = -.infinity

    init() {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageSize = UInt64(size)
    }

    func sample() -> Snapshot {
        var s = Snapshot()
        s.values[.cpu] = cpuUsage()
        s.values[.gpu] = gpuUsage()

        if let (used, total) = memory() {
            s.memUsed = used
            s.memTotal = total
            s.values[.ram] = Double(used) / Double(total) * 100
        }

        let now = ProcessInfo.processInfo.systemUptime
        if disk == nil || now - lastDiskRead > 30 {
            disk = diskUsage()
            lastDiskRead = now
        }
        if let disk, disk.total > 0 {
            s.diskUsed = disk.used
            s.diskTotal = disk.total
            s.values[.ssd] = Double(disk.used) / Double(disk.total) * 100
        }

        (s.netIn, s.netOut) = network(now: now)

        let temps = sensors_read_temperatures()
        s.cpuTemp = temps.cpu >= 0 ? temps.cpu : nil
        s.gpuTemp = temps.gpu >= 0 ? temps.gpu : nil
        s.hottestTemp = temps.hottest >= 0 ? temps.hottest : nil
        if s.cpuTemp == nil { s.cpuTemp = s.hottestTemp }
        return s
    }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let ticks = info.cpu_ticks
        defer { lastTicks = ticks }
        guard let prev = lastTicks else { return nil }

        let user = Double(ticks.0 &- prev.0)
        let system = Double(ticks.1 &- prev.1)
        let idle = Double(ticks.2 &- prev.2)
        let nice = Double(ticks.3 &- prev.3)
        let total = user + system + idle + nice
        return total > 0 ? (user + system + nice) / total * 100 : nil
    }

    private func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var result: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                let util = stats["Device Utilization %"] as? NSNumber
            else { continue }
            result = max(result ?? 0, util.doubleValue)
        }
        return result
    }

    /// Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
    private func memory() -> (UInt64, UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        return (min(used, total), total)
    }

    private func diskUsage() -> (Int64, Int64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (Int64(total) - available, Int64(total))
    }

    private func network(now: TimeInterval) -> (Double, Double) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }

        var current: [String: (UInt32, UInt32)] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  let data = ifa.ifa_data
            else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (d.ifi_ibytes, d.ifi_obytes)
        }

        defer {
            lastNet = current
            lastNetTime = now
        }
        guard let lastTime = lastNetTime, now > lastTime else { return (0, 0) }

        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        for (name, counters) in current {
            guard let prev = lastNet[name] else { continue }
            // 32-bit counters wrap; wrapping subtraction handles one rollover.
            bytesIn += UInt64(counters.0 &- prev.0)
            bytesOut += UInt64(counters.1 &- prev.1)
        }
        let elapsed = now - lastTime
        return (Double(bytesIn) / elapsed, Double(bytesOut) / elapsed)
    }
}
