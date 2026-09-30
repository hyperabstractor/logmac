import Foundation

/// A Mac allowed to watch this one.
struct PairedViewer: Codable, Identifiable {
    var id: String
    var name: String
    var token: Data
    var pairedAt: Date
}

/// A Mac this one watches.
struct PairedHost: Codable {
    var info: DeviceInfo
    var token: Data
    /// Tailscale name or IP typed in when pairing, if any.
    var manualHost: String?
}

struct PairingData: Codable {
    var deviceID: String
    var viewers: [PairedViewer] = []
    var hosts: [PairedHost] = []
}

/// Persists this Mac's ID and pairings to a user-only JSON file in Application Support.
@MainActor
final class PairingStore {
    private(set) var data: PairingData
    private let url: URL

    init(directory: URL? = nil) {
        let dir = directory
            ?? ProcessInfo.processInfo.environment["LOGMAC_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LogMac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("pairings.json")

        if let raw = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(PairingData.self, from: raw) {
            data = decoded
        } else {
            data = PairingData(deviceID: UUID().uuidString)
            save()
        }
    }

    func update(_ change: (inout PairingData) -> Void) {
        change(&data)
        save()
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        try? raw.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
