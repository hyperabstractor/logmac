import AppKit
import SwiftUI

/// The top processes by CPU or memory, shown when a metric row is clicked, for this Mac or a paired one.
struct ProcessListView: View {
    let source: any ProcessSource
    let metric: Metric
    /// e.g. "13% overall · 10 cores", or "Mac mini (M4) · 8.8 of 16 GB used".
    let summary: String
    let footnote: String
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
                    .lineLimit(1)
                Spacer()
                Toggle("Group", isOn: Binding(get: { source.grouped }, set: { source.grouped = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .help("Fold helper processes into the app they belong to")
            }

            Card {
                if let status = source.statusMessage {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else if source.isMeasuring {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else {
                    ForEach(source.top) { entry in
                        ProcessRow(entry: entry, metric: metric, isRemote: source.isRemote)
                            .contextMenu { menu(for: entry) }
                    }
                }
            }

            if let message = source.quitMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(footnote)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // `entry` is captured when the menu opens, so re-sorting can't retarget it.
    @ViewBuilder
    private func menu(for entry: ProcessEntry) -> some View {
        if ProcessControl.isProtected(name: entry.name, path: entry.path) {
            Text("\(entry.name) can't be quit from here")
        } else if let reason = source.quitUnavailableReason {
            Text(reason)
        } else {
            Button("Quit \(entry.name)") { source.quit(entry, force: false) }
            Button("Force Quit \(entry.name)", role: .destructive) { source.quit(entry, force: true) }
        }
    }
}

private struct ProcessRow: View {
    let entry: ProcessEntry
    let metric: Metric
    let isRemote: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: ProcessIcons.icon(for: entry, isRemote: isRemote))
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

/// App icons for GUI processes, the generic executable icon otherwise.
/// A remote row's pid means nothing here, so its icon comes from this Mac's copy of the app, if any.
@MainActor
private enum ProcessIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for entry: ProcessEntry, isRemote: Bool) -> NSImage {
        let key = isRemote ? "remote:\(entry.bundleID ?? entry.path ?? entry.name)" : "local:\(entry.pid)"
        if let cached = cache[key] { return cached }
        let icon = isRemote ? remoteIcon(for: entry) : localIcon(for: entry)
        if cache.count > 500 { cache.removeAll() }
        cache[key] = icon
        return icon
    }

    private static func localIcon(for entry: ProcessEntry) -> NSImage {
        NSRunningApplication(processIdentifier: entry.pid)?.icon
            ?? entry.path.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
    }

    private static func remoteIcon(for entry: ProcessEntry) -> NSImage {
        if let bundleID = entry.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let path = entry.path, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }
}
