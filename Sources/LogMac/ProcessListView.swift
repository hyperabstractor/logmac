import AppKit
import SwiftUI

/// The top processes by CPU or memory, shown when a metric row is clicked.
struct ProcessListView: View {
    let model: StatsModel
    @Bindable var processes: ProcessMonitor
    let metric: Metric
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Text(metric.title).font(.system(size: 13, weight: .semibold))
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Text("Back")
                        }
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
            .font(.system(size: 12))

            HStack {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Group", isOn: $processes.grouped)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .help("Fold helper processes into the app they belong to")
            }

            Card {
                if isMeasuring {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else {
                    ForEach(processes.top) { entry in
                        ProcessRow(entry: entry, metric: metric)
                            .contextMenu {
                                // `entry` is captured when the menu opens, so re-sorting can't retarget it.
                                if ProcessActions.isProtected(entry) {
                                    Text("\(entry.name) can't be quit from here")
                                } else {
                                    Button("Quit \(entry.name)") {
                                        ProcessActions.quit(entry)
                                        processes.refreshSoon()
                                    }
                                    Button("Force Quit \(entry.name)", role: .destructive) {
                                        ProcessActions.forceQuit(entry)
                                        processes.refreshSoon()
                                    }
                                }
                            }
                    }
                }
            }

            Text("Right-click a process to quit it. Shows processes running as you; system processes need admin access.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isMeasuring: Bool {
        processes.entries.isEmpty || (metric == .cpu && !processes.hasCPU)
    }

    private var summary: String {
        let s = model.snapshot
        switch metric {
        case .cpu:
            let cores = ProcessInfo.processInfo.activeProcessorCount
            return "\(Int((s.values[.cpu] ?? 0).rounded()))% overall · \(cores) cores"
        default:
            return "\(usage(Int64(s.memUsed), of: Int64(s.memTotal), .memory)) used"
        }
    }
}

private struct ProcessRow: View {
    let entry: ProcessEntry
    let metric: Metric

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: ProcessIcons.icon(for: entry))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if entry.count > 1 {
                Text("\(entry.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .help("\(entry.count) processes")
            }
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.system(size: 12))
    }

    private var value: String {
        metric == .cpu
            ? String(format: "%.1f%%", entry.cpu)
            : bytes(Int64(entry.memory), .memory)
    }
}

/// Quit and Force Quit for a process row. Apps get a normal quit request (so they can prompt to save);
/// other processes get SIGTERM / SIGKILL. Only the user's own processes are listed, so no privileges are needed.
@MainActor
private enum ProcessActions {
    /// Killing these ends the login session.
    private static let protectedNames: Set<String> = ["loginwindow", "launchd"]

    static func isProtected(_ entry: ProcessEntry) -> Bool {
        let executable = entry.path.map { ($0 as NSString).lastPathComponent }
        return protectedNames.contains(entry.name) || executable.map(protectedNames.contains) == true
    }

    static func quit(_ entry: ProcessEntry) {
        guard !isProtected(entry) else { return }
        if let app = NSRunningApplication(processIdentifier: entry.pid) {
            app.terminate()
        } else {
            kill(entry.pid, SIGTERM)
        }
    }

    static func forceQuit(_ entry: ProcessEntry) {
        guard !isProtected(entry) else { return }
        if let app = NSRunningApplication(processIdentifier: entry.pid) {
            app.forceTerminate()
        } else {
            kill(entry.pid, SIGKILL)
        }
    }
}

/// App icons for GUI processes, the generic executable icon otherwise. Cached by pid.
@MainActor
private enum ProcessIcons {
    private static var cache: [pid_t: NSImage] = [:]

    static func icon(for entry: ProcessEntry) -> NSImage {
        if let cached = cache[entry.pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: entry.pid)?.icon
            ?? entry.path.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        if cache.count > 500 { cache.removeAll() }
        cache[entry.pid] = icon
        return icon
    }
}
