import AppKit
import SwiftUI

/// Hosting view that lets clicks fall through to the status bar button underneath.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = StatsModel()
    private let store = PairingStore()
    private lazy var monitor = RemoteMonitor(store: store)
    private lazy var server = SharingServer(store: store) { [model] in model.snapshot }
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 60)
        guard let button = statusItem.button else { return }

        monitor.threshold = { [model] in model.threshold(for: $0) }

        let content = StatusItemView(model: model, monitor: monitor) { [weak self] width in
            self?.statusItem.length = ceil(width)
        }
        let host = PassthroughHostingView(rootView: content)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        button.setAccessibilityLabel("System stats")
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let controller = NSHostingController(rootView: PopoverView(model: model, monitor: monitor, server: server))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self

        // A Mac asking to pair needs the code on screen to be compared.
        server.onPairingRequest = { [weak self] in self?.showPopover() }

        model.start()
        server.activate()
        monitor.start()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }
}
