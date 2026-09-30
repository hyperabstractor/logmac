import Darwin
import Foundation
import IOKit
import SystemConfiguration

/// Describes a Mac to its paired peers. Only sent after authentication.
struct DeviceInfo: Codable, Equatable {
    var id: String
    /// Computer name, e.g. "Neil's Mac mini".
    var name: String
    /// Marketing model without the year, e.g. "Mac mini".
    var product: String
    /// e.g. "M4".
    var chip: String
    /// Bonjour host name, reachable as "<name>.local" on the LAN.
    var localHostName: String?
    var tailscaleIP: String?

    var displayName: String { chip.isEmpty ? product : "\(product) (\(chip))" }

    /// Tag for the menu bar alert label, e.g. "MINI" or "AIR".
    var shortName: String {
        (product.split(separator: " ").last.map(String.init) ?? product).uppercased()
    }

    static func current(id: String) -> DeviceInfo {
        DeviceInfo(
            id: id,
            name: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? Host.current().localizedName ?? "Mac",
            product: product,
            chip: chip,
            localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?,
            tailscaleIP: tailscaleIPv4()
        )
    }

    static let product: String = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { IOObjectRelease(entry) }
        guard entry != 0,
              let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? Data,
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        else { return "Mac" }
        // "Mac mini (2024)" -> "Mac mini"
        return raw.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
    }()

    static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        guard size > 0, sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer).replacingOccurrences(of: "Apple ", with: "")
    }()

    static func tailscaleIPv4() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            guard isTailscale(UInt32(bigEndian: sin.sin_addr.s_addr)) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buffer)
        }
        return nil
    }

    static func isTailscale(address: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, address, &addr) == 1 else { return false }
        return isTailscale(UInt32(bigEndian: addr.s_addr))
    }

    /// Tailscale assigns addresses from the CGNAT range 100.64.0.0/10.
    private static func isTailscale(_ ip: UInt32) -> Bool {
        ip & 0xFFC0_0000 == 0x6440_0000
    }
}
