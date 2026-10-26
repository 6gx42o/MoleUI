import Foundation
import Combine

/// Owns the single `mo status --watch` process and fans its snapshots out to
/// whoever is watching. Reference-counted so the Dashboard and the menu bar HUD
/// share one collector: two independent streams would double the sampling cost
/// and report slightly different numbers in two places at once.
@MainActor
final class StatusMonitor: ObservableObject {
    static let shared = StatusMonitor()

    @Published private(set) var snapshot: StatusSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false

    /// Rolling series we keep ourselves. `network_history` only carries a
    /// single sample on a cold start, and nothing upstream tracks CPU or memory
    /// over time, so the sparklines are built here.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var rxHistory: [Double] = []
    @Published private(set) var txHistory: [Double] = []

    private var stream: MoleCLI.Stream?
    private let historyLimit = 60
    /// Reset only once a collector has proven it can stay up, so a collector
    /// that runs fine for hours and then dies still gets its full quota of
    /// restarts. Resetting on the *first* snapshot defeated the cap entirely:
    /// anything that emitted one line before dying cleared the counter every
    /// cycle, turning a bounded retry into an unbounded process-spawn loop.
    private var restartAttempts = 0
    private var streamStartedAt = Date.distantPast
    /// Bumped on every start(). Callbacks capture the value current when their
    /// stream was created, so a snapshot or error from a superseded collector
    /// can be told apart from one belonging to the live one — `stream != nil`
    /// alone cannot, since a replacement makes it non-nil again.
    private var generation = 0
    private let healthyStreamThreshold: TimeInterval = 60

    // MARK: - Demand
    //
    // The collector is the app's one continuous cost: `status-go` sampling
    // every 2s measured 1.7s of CPU per minute, and it used to run for as long
    // as the window *existed* — hidden behind other windows, minimised, on a
    // locked screen, overnight. Now each consumer states how often it needs
    // fresh numbers, the collector runs at the fastest rate anyone currently
    // needs, and when nobody does it is not running at all.

    enum Consumer: Hashable {
        case window        // sidebar footer — coarse is fine
        case dashboard     // the live charts
        case popover       // menu bar panel, while open
        case menuBarLabel  // CPU % in the menu bar, if enabled in Settings
    }

    private var demands: [Consumer: Int] = [:]
    private var runningInterval: Int?

    /// Window demands only count while the window can actually be seen.
    @Published private(set) var windowVisible = true
    /// Display asleep, system sleeping, or the user switched away.
    private var suspended = false

    func demand(_ consumer: Consumer, every seconds: Int?) {
        if let seconds { demands[consumer] = max(1, seconds) } else { demands[consumer] = nil }
        if seconds != nil, runningInterval == nil { restartAttempts = 0 }
        reconcile()
    }

    func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        reconcile()
    }

    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        reconcile()
    }

    /// Re-evaluates after Low Power Mode toggles.
    func powerStateChanged() {
        runningInterval = runningInterval.map { _ in -1 }   // force a restart at the new rate
        reconcile()
    }

    /// The menu bar CPU readout is opt-in. Off, the menu bar costs nothing
    /// until its panel is opened.
    func applyMenuBarPreference() {
        demand(.menuBarLabel,
               every: UserDefaults.standard.bool(forKey: Prefs.menuBarCPU) ? 10 : nil)
    }

    /// Kept for the one-line callers that just want "on while I'm here".
    func subscribe() { demand(.window, every: 5) }
    func unsubscribe() { demand(.window, every: nil) }

    /// The interval the collector should be running at right now, or nil.
    var targetInterval: Int? {
        guard !suspended else { return nil }
        let active = demands.filter { consumer, _ in
            switch consumer {
            case .window, .dashboard: return windowVisible
            case .popover, .menuBarLabel: return true
            }
        }
        guard var interval = active.values.min() else { return nil }
        // Low Power Mode: sample half as often. Nobody on a dying battery needs
        // a 2-second CPU readout.
        if ProcessInfo.processInfo.isLowPowerModeEnabled { interval = max(interval * 2, 4) }
        return interval
    }

    /// One line per decision, to ~/Library/Logs/MoleUI/monitor.log. Only
    /// written when something changes, so it costs nothing while idle — and it
    /// is the only way to see why the collector is or isn't running.
    private func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        let path = DiagnosticsDir.file("monitor.log")
        // Every app switch can change occlusion, so cap it rather than let a
        // months-long session grow it without bound.
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
           size > 256_000 {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func reconcile() {
        let target = targetInterval
        log("reconcile target=\(target.map(String.init) ?? "off") running=\(runningInterval.map(String.init) ?? "off") "
          + "visible=\(windowVisible) suspended=\(suspended) demands=\(demands.map { "\($0.key):\($0.value)" }.sorted())")
        guard target != runningInterval || (target != nil && stream == nil) else { return }
        stop()
        guard let target else { return }
        start(interval: target)
    }

    private func start(interval: Int) {
        // Defensive: start() is reachable from the error path as well as
        // reconcile(), and leaving a previous collector running would leak one
        // `mo status --watch` per restart.
        stream?.stop()
        stream = nil
        error = nil
        streamStartedAt = Date()
        runningInterval = interval
        generation += 1
        let generation = self.generation
        stream = MoleCLI.shared.streamStatus(intervalSeconds: interval) { [weak self] snapshot in
            Task { @MainActor in self?.ingest(snapshot, generation: generation) }
        } onError: { [weak self] error in
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                // stop() rather than `stream = nil`: a Stream is kept alive by
                // its own readabilityHandler closure, so merely dropping the
                // reference does not run deinit. stop() is idempotent.
                self.stop()
                self.error = error.localizedDescription

                // Restart if anything still wants numbers — a collector that
                // dies on laptop wake should not leave the dashboard dead.
                // Bounded, because one that fails instantly (missing binary,
                // bad flag) would otherwise respawn forever.
                guard self.restartAttempts < 3 else { return }
                self.restartAttempts += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.stream == nil else { return }
                self.reconcile()
            }
        }
        isRunning = stream != nil
    }

    func stop() {
        stream?.stop()
        stream = nil
        runningInterval = nil
        isRunning = false
    }

    /// One-shot refresh for when the stream cannot start (e.g. `mo` missing at
    /// launch, then installed).
    func refreshOnce() async {
        do {
            // Bypasses the stream guard deliberately: this is a one-shot fetch
            // with no collector behind it, so there is no generation to match.
            apply(try await MoleCLI.shared.status())
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func ingest(_ snapshot: StatusSnapshot, generation: Int) {
        // Snapshots and the error notification arrive as separate MainActor
        // Tasks with no ordering guarantee, so a snapshot queued just before the
        // collector died can land *after* the error was handled. Ingesting it
        // would set isRunning = true and clear the error on a collector that is
        // already gone — the green "live" dot back over frozen data, the exact
        // failure the error path exists to prevent. Matching on generation also
        // rejects a stale snapshot that arrives after a *replacement* stream has
        // started, which a plain `stream != nil` check would let through.
        guard generation == self.generation, stream != nil else { return }
        apply(snapshot)
    }

    private func apply(_ snapshot: StatusSnapshot) {
        self.snapshot = snapshot
        self.isRunning = true
        self.error = nil
        if Date().timeIntervalSince(streamStartedAt) > healthyStreamThreshold {
            self.restartAttempts = 0
        }

        append(&cpuHistory, snapshot.cpu.usage)
        append(&memoryHistory, snapshot.memory.usedPercent)

        let interfaces = snapshot.network ?? []
        append(&rxHistory, interfaces.map(\.rxRateMBs).reduce(0, +))
        append(&txHistory, interfaces.map(\.txRateMBs).reduce(0, +))
    }

    private func append(_ series: inout [Double], _ value: Double) {
        series.append(value)
        if series.count > historyLimit { series.removeFirst(series.count - historyLimit) }
    }
}
