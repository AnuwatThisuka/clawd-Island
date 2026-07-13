import AppKit
import SwiftUI

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let monitor = AppMonitor()
    var window: IslandWindow!
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ note: Notification) {
        model.start()
        Updater.shared.start()                          // Sparkle auto-updates
        window = IslandWindow(model: model)
        monitor.start { [weak self] in self?.sync() }   // fires on display / Claude changes
        observeExpansion()
        sync()
        window.show()
    }

    /// Push current notch geometry into the model and reposition the island to the notched
    /// screen. Runs on launch and on every display-configuration change.
    private func sync() {
        guard let window else { return }   // monitor.start() can fire before window exists
        model.notchWidth = monitor.notchWidth > 0 ? monitor.notchWidth : 190   // synthetic on non-notch
        model.topInset = monitor.notchHeight > 0 ? monitor.notchHeight : 32
        window.relayout()
        window.show()
    }

    /// withObservationTracking fires once, so re-arm after each change to keep tracking. Watches
    /// `isExpanded`, `activity`, and the measured drop heights: a tool starting/stopping auto-drops
    /// the activity band, and the monitor panel reports its laid-out height — both change the
    /// pill's footprint, so the invisible click-catcher must resize to match. Only the click-zone
    /// is resized here — the window and pill animation are untouched, so nothing jumps.
    private func observeExpansion() {
        withObservationTracking {
            _ = model.isExpanded
            _ = model.activity != nil
            _ = model.activityDropHeight
            _ = model.dropHeight
            _ = model.currentPermission != nil
            _ = model.permissionDropHeight
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.window.updateInteractiveZone()
                self.updateClickMonitor()
                self.observeExpansion()
            }
        }
    }

    /// While expanded, any click outside the island collapses it.
    private func updateClickMonitor() {
        if model.isExpanded, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    Task { @MainActor in self?.model.isExpanded = false }
                }
        } else if !model.isExpanded, let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }
}
