import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        installPowerObservers()

        if CommandLine.arguments.contains("--debug-windows") {
            WindowWatcher.install()
        }

        // `--pane <name>` selects a pane at launch. Exists so the app can be
        // driven for testing through LaunchServices instead of synthetic clicks,
        // which land wherever the pointer happens to be and can hit other apps.
        if let index = CommandLine.arguments.firstIndex(of: "--pane"),
           index + 1 < CommandLine.arguments.count,
           let pane = Pane(rawValue: CommandLine.arguments[index + 1]) {
            let autoscan = CommandLine.arguments.contains("--autoscan")
            Task { @MainActor in
                Router.shared.pane = pane
                // Only ever starts a *preview*. Nothing that deletes is
                // reachable from a launch argument — that stays behind the
                // confirm sheet, which is the only gate `mo clean` has.
                Router.shared.autoscan = autoscan
            }
        }
    }

    /// Stops all sampling whenever nobody could be looking: the displays are
    /// off, the Mac is going to sleep, or the user has switched to another
    /// account. Resumes on the matching wake. Low Power Mode halves the rate.
    @MainActor
    private func installPowerObservers() {
        let monitor = StatusMonitor.shared
        let workspace = NSWorkspace.shared.notificationCenter
        let pause: [Notification.Name] = [NSWorkspace.willSleepNotification,
                                          NSWorkspace.screensDidSleepNotification,
                                          NSWorkspace.sessionDidResignActiveNotification]
        let resume: [Notification.Name] = [NSWorkspace.didWakeNotification,
                                           NSWorkspace.screensDidWakeNotification,
                                           NSWorkspace.sessionDidBecomeActiveNotification]
        for name in pause {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { monitor.setSuspended(true) }
            }
        }
        for name in resume {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { monitor.setSuspended(false) }
            }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { monitor.powerStateChanged() }
        }
        monitor.applyMenuBarPreference()
    }

    /// Clicking the Dock icon, or `open`ing the app while it is already running,
    /// must always get you a window back. Without this the app can sit running
    /// with none — a MenuBarExtra keeps it alive — and appear simply broken.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        restoreWindow()
        return true
    }

    @MainActor
    private func restoreWindow() {
        // With a single-instance `Window` scene the window object survives being
        // closed — it is ordered out, not destroyed — so ordering it back in is
        // all that is needed, and there is no way to end up with duplicates.
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
