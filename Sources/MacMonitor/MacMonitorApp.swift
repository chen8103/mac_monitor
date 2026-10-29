import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let store = MetricsStore()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.dockTile.badgeLabel = nil

        popover.contentSize = NSSize(width: 420, height: 500)
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MonitorView(store: store))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopover),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }

        button.image = NSImage(named: "AppIcon")
        button.image?.size = NSSize(width: 18, height: 18)
        button.image?.isTemplate = false
        button.toolTip = "Mac Monitor"
        button.target = self
        button.action = #selector(togglePopover)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startClickMonitors()
        }
    }

    @objc private func closePopover() {
        popover.performClose(nil)
    }

    private func startClickMonitors() {
        guard localClickMonitor == nil, globalClickMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            let windowNumber = event.windowNumber
            Task { @MainActor [weak self] in
                self?.closeIfOutside(windowNumber: windowNumber)
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            let windowNumber = event.windowNumber
            Task { @MainActor [weak self] in
                self?.closeIfOutside(windowNumber: windowNumber)
            }
        }
    }

    private func closeIfOutside(windowNumber: Int) {
        guard popover.isShown else { return }
        if windowNumber == popover.contentViewController?.view.window?.windowNumber ||
            windowNumber == statusItem?.button?.window?.windowNumber {
            return
        }
        popover.performClose(nil)
    }

    private func stopClickMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopClickMonitors()
    }
}

@main
struct MacMonitorApp: App {
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBarController

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
