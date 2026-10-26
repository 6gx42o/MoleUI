import SwiftUI

/// The menu bar title. Deliberately just a glyph plus CPU — a menu bar is not a
/// dashboard, and a number that changes every 2 seconds is already at the limit
/// of what belongs up there.
struct HUDLabel: View {
    @ObservedObject var monitor: StatusMonitor
    @AppStorage(Prefs.menuBarCPU) private var showCPU = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "mountain.2.fill")
            // Only while it is genuinely being kept fresh: with the readout off
            // the collector is stopped, and a frozen number in the menu bar
            // would look live.
            if showCPU, let snapshot = monitor.snapshot, monitor.isRunning {
                Text(String(format: "%.0f%%", snapshot.cpu.usage))
                    .font(.system(size: 11).monospacedDigit())
            }
        }
    }
}

struct StatusHUD: View {
    @EnvironmentObject private var monitor: StatusMonitor
    @EnvironmentObject private var router: Router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = monitor.snapshot {
                HStack(spacing: 12) {
                    HealthRing(score: snapshot.healthScore, caption: snapshot.healthScoreMsg)
                        .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.hardware.model.isEmpty ? "Mac" : snapshot.hardware.model)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Mole.text)
                        Text("up \(snapshot.uptime) · \(snapshot.procs) procs")
                            .font(Mole.mono(10))
                            .foregroundStyle(Mole.textFaint)
                    }
                    Spacer()
                }

                stat("CPU", String(format: "%.1f%%", snapshot.cpu.usage),
                     snapshot.cpu.usage / 100)
                stat("Memory", String(format: "%.0f%%", snapshot.memory.usedPercent),
                     snapshot.memory.usedPercent / 100)

                if let disk = (snapshot.disks ?? []).first(where: { $0.mount == "/" }) {
                    stat("Disk", "\(formatBytesBinary(disk.total - disk.used)) free",
                         disk.usedPercent / 100)
                }

                if let top = (snapshot.topProcesses ?? []).first {
                    HStack {
                        Text("Busiest")
                            .font(.system(size: 10))
                            .foregroundStyle(Mole.textFaint)
                        Spacer()
                        Text("\(top.name) \(String(format: "%.0f%%", top.cpu))")
                            .font(Mole.mono(10))
                            .foregroundStyle(Mole.textDim)
                    }
                }
            } else {
                Text(monitor.error ?? "Waiting for mo status…")
                    .font(.system(size: 11))
                    .foregroundStyle(Mole.textDim)
            }

            Divider().overlay(Mole.border)

            // Opens the pane; never runs a destructive command from the menu bar.
            HStack(spacing: 6) {
                GhostButton(title: "Open", systemImage: "macwindow") { open(.smartScan) }
                GhostButton(title: "Monitor", systemImage: "waveform.path.ecg") { open(.dashboard) }
                GhostButton(title: "Junk", systemImage: "trash.circle") { open(.clean) }
                Spacer()
                GhostButton(title: "Quit", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 268)
        .background(Mole.soil)
        // Paired with unsubscribe. Without the pairing the refcount only ever
        // climbed, so it never returned to zero and `mo status --watch` kept
        // running for the life of the app — opening the popover once was enough
        // to make the Dashboard's own unsubscribe permanently ineffective.
        .task { monitor.demand(.popover, every: 2) }
        .onDisappear { monitor.demand(.popover, every: nil) }
    }

    private func stat(_ label: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Mole.textFaint)
                Spacer()
                Text(value)
                    .font(Mole.mono(10))
                    .monospacedDigit()
                    .foregroundStyle(Mole.textDim)
            }
            StratumBar(fraction: fraction, color: Mole.load(fraction * 100), height: 4)
        }
    }

    private func open(_ pane: Pane) {
        router.pane = pane
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Bring the existing window forward, and genuinely re-create it when
        // there isn't one. `makeKeyAndOrderFront` alone was a no-op in exactly
        // the case that matters — no window left to order front — which left
        // the app running with no way to reach it.
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: MoleUIApp.mainWindowID)
        }
    }
}
