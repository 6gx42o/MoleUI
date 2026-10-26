import SwiftUI

@main
enum Main {
    static func main() {
        // Writing to a pipe whose reader has exited raises SIGPIPE, whose
        // default action is to kill the process — `try?` cannot catch a signal,
        // because it is not a thrown error. The app feeds stdin to `mo
        // uninstall`, which can exit before reading it (bad app name, early
        // abort), so without this a routine mistake takes the whole GUI down
        // with exit 141. Ignoring it turns the same case into an EPIPE error
        // that the write actually can handle.
        signal(SIGPIPE, SIG_IGN)

        // Headless decoder check, so JSON drift in the CLI is caught without
        // launching a window. See fixtures/ and SelfTest.swift.
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        // Reports whether this signed binary holds Full Disk Access, without
        // launching a window. TCC matches the requesting process's signature,
        // so running this from a shell still tests *MoleUI's* grant — compare
        // against the same read from the shell itself, which will fail unless
        // the terminal has its own grant.
        if CommandLine.arguments.contains("--fdacheck") {
            exit(FDACheck.run() ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--upgrade-test"),
           index + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments[index + 1]
            MainActor.assumeIsolated { ActionTest.upgrade(name) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--maintenance"),
           index + 1 < CommandLine.arguments.count {
            let id = CommandLine.arguments[index + 1]
            MainActor.assumeIsolated { ActionTest.maintenance(id) }
        }
        // Exercises every action on disposable data the test creates itself.
        if CommandLine.arguments.contains("--actiontest") {
            MainActor.assumeIsolated { ActionTest.start() }
        }
        // Runs feature scanners without a window. Scans only — never acts.
        if let index = CommandLine.arguments.firstIndex(of: "--scan"),
           index + 1 < CommandLine.arguments.count {
            ScanProbe.start(CommandLine.arguments[index + 1])
        }
        // Draws the app icon; build.sh turns the PNG into an .icns.
        if let index = CommandLine.arguments.firstIndex(of: "--icon"),
           index + 1 < CommandLine.arguments.count {
            exit(IconRenderer.run(path: CommandLine.arguments[index + 1]) ? 0 : 1)
        }
        MoleUIApp.main()
    }
}

struct MoleUIApp: App {
    // Deliberately NOT @StateObject/@ObservedObject here.
    //
    // A property wrapper at App scope makes every @Published change invalidate
    // `body` — and `body` is the *Scene* graph. StatusMonitor publishes a new
    // snapshot every 2 seconds, so observing it here rebuilt WindowGroup and
    // MenuBarExtra twice a minute-ish forever, and the window would eventually
    // be torn down and not come back (process alive, zero windows).
    //
    // The objects are singletons, so nothing needs to own them at this level.
    // Observation belongs in the views that actually read the values: RootView
    // and StatusHUD take them from the environment, HUDLabel observes directly,
    // and only those subtrees re-render.
    private var monitor: StatusMonitor { .shared }
    private var router: Router { .shared }

    /// Identified so the menu bar can reopen it. A MenuBarExtra keeps the app
    /// alive with no windows, so without a way back — ⌘W, or the window closing
    /// on its own — the app is running but unreachable.
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // `Window`, not `WindowGroup`. A WindowGroup mints a new window on ⌘N
        // and macOS restores every one it saw last session, so copies pile up —
        // three at once here — which made "the window vanished" ambiguous: was
        // it gone, or was I looking at a different one? A single-instance Window
        // is what a utility like this wants anyway, and `openWindow(id:)`
        // reliably brings the one window back if it is closed.
        Window("Mole", id: Self.mainWindowID) {
            RootView()
                .environmentObject(monitor)
                .environmentObject(router)
                // maxHeight matters as much as minHeight: with only a minimum,
                // the view's ideal height is its content height, so a pane full
                // of long lists proposes a height taller than the window and
                // the split view gets laid out off the top edge.
                .frame(minWidth: 940, maxWidth: .infinity,
                       minHeight: 620, maxHeight: .infinity)
                .background(Mole.soil)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra {
            StatusHUD()
                .environmentObject(monitor)
                .environmentObject(router)
        } label: {
            HUDLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Shared navigation state so the menu bar can push the window to a pane.
/// A singleton for the same reason StatusMonitor is one — see the note in
/// MoleUIApp about why neither is owned by the App itself.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    private init() {}

    @Published var pane: Pane = .smartScan

    /// Set by `--autoscan`. Lets a pane kick off its own (non-destructive) scan
    /// on appear, so the app can be exercised through LaunchServices instead of
    /// synthetic clicks. Cleared once consumed so a pane revisit doesn't rescan.
    @Published var autoscan = false

    func consumeAutoscan() -> Bool {
        guard autoscan else { return false }
        autoscan = false
        return true
    }
}

enum Pane: String, CaseIterable, Identifiable {
    // Raw values of the original eight are unchanged — `--pane clean` and
    // friends, and every persisted sort key, depend on them.
    case smartScan
    case clean, leftovers, trashBins, history
    case malware, privacy, permissions, wifi
    case maintenance, dashboard
    case uninstall, extensions, updater
    case analyze, largeFiles, duplicates, shredder
    case settings

    var id: String { rawValue }

    enum Section: String, CaseIterable {
        case top = "", cleanup = "Cleanup", protection = "Protection",
             performance = "Performance", applications = "Applications", files = "Files"
    }

    var section: Section? {
        switch self {
        case .smartScan:                                              return .top
        case .clean, .leftovers, .trashBins, .history:                return .cleanup
        case .malware, .privacy, .permissions, .wifi:                 return .protection
        case .maintenance, .dashboard:                                return .performance
        case .uninstall, .extensions, .updater:                       return .applications
        case .analyze, .largeFiles, .duplicates, .shredder:           return .files
        case .settings:                                               return nil
        }
    }

    var title: String {
        switch self {
        case .smartScan:         return "Smart Scan"
        case .clean:             return "System Junk"
        case .leftovers:         return "Leftovers"
        case .trashBins:         return "Trash Bins"
        case .history:           return "Clean History"
        case .malware:           return "Malware Removal"
        case .privacy:           return "Privacy"
        case .wifi:              return "Saved Wi-Fi"
        case .permissions:       return "Permissions"
        case .maintenance:       return "Maintenance"
        case .dashboard:         return "System Monitor"
        case .uninstall:         return "Uninstaller"
        case .extensions:        return "Extensions"
        case .updater:           return "Updater"
        case .analyze:           return "Space Lens"
        case .largeFiles:        return "Large Files"
        case .duplicates:        return "Duplicates"
        case .shredder:          return "Shredder"
        case .settings:          return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .smartScan:         return "sparkle.magnifyingglass"
        case .clean:             return "trash.circle"
        case .leftovers:         return "shippingbox"
        case .trashBins:         return "trash"
        case .history:           return "clock.arrow.circlepath"
        case .malware:           return "shield.lefthalf.filled"
        case .privacy:           return "hand.raised"
        case .wifi:              return "wifi"
        case .permissions:       return "lock.shield"
        case .maintenance:       return "wrench.and.screwdriver"
        case .dashboard:         return "waveform.path.ecg"
        case .uninstall:         return "xmark.app"
        case .extensions:        return "puzzlepiece"
        case .updater:           return "arrow.triangle.2.circlepath"
        case .analyze:           return "circle.circle"
        case .largeFiles:        return "doc.text.magnifyingglass"
        case .duplicates:        return "plus.square.on.square"
        case .shredder:          return "scissors"
        case .settings:          return "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .smartScan:         return "Check everything at once"
        case .clean:             return "Caches, logs and temporary files"
        case .leftovers:         return "Installers, build folders, mail attachments"
        case .trashBins:         return "Empty the Trash on every drive"
        case .history:           return "Review past cleanups"
        case .malware:           return "Threats and everything that starts on its own"
        case .privacy:           return "Browsing traces and browser extensions"
        case .wifi:              return "Networks this Mac remembers"
        case .permissions:       return "What each app is allowed to access"
        case .maintenance:       return "Optimize and run routine fixes"
        case .dashboard:         return "Live system health"
        case .uninstall:         return "Remove apps completely — or just the unused ones"
        case .extensions:        return "Plug-ins and panes added to macOS"
        case .updater:           return "Updates for apps and packages"
        case .analyze:           return "Explore disk usage"
        case .largeFiles:        return "Big files and space-heavy folders"
        case .duplicates:        return "Identical files in your folders"
        case .shredder:          return "Delete files permanently"
        case .settings:          return "Preferences"
        }
    }

    /// The colour of the sidebar glyph, by section — the same grouping cue
    /// CleanMyMac uses, drawn from this app's own palette.
    var tint: Color {
        switch section {
        case .top:          return Mole.brand
        case .cleanup:      return Mole.moss
        // Rose rather than the destructive red: red stays reserved for
        // "this deletes", and a sidebar icon deletes nothing.
        case .protection:   return Color(red: 0.84, green: 0.47, blue: 0.58)
        case .performance:  return Mole.amber
        case .applications: return Mole.brand
        case .files:        return Color(red: 0.35, green: 0.62, blue: 0.85)
        case nil:           return Mole.textDim
        }
    }
}
extension Pane: Codable {}
