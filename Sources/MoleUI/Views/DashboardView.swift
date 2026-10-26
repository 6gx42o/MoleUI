import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var monitor: StatusMonitor

    var body: some View {
        PaneScaffold(title: "System Monitor",
                     subtitle: monitor.snapshot.map { "\($0.hardware.model) · \($0.hardware.osVersion) · up \($0.uptime)" }
                                ?? "Live system health") {
            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.isRunning ? Mole.moss : Mole.textFaint)
                    .frame(width: 6, height: 6)
                Text(monitor.isRunning ? "live" : "idle")
                    .font(Mole.mono(10))
                    .foregroundStyle(Mole.textFaint)
            }
        } content: {
            Group {
                if let snapshot = monitor.snapshot {
                    content(snapshot)
                } else if let error = monitor.error {
                    StateMessage(icon: "exclamationmark.triangle", title: "Monitoring failed",
                                 message: error, tint: Mole.amber)
                } else {
                    StateMessage(icon: "waveform.path.ecg", title: "Starting collector…",
                                 message: "Waiting for the first snapshot from mo status --watch.")
                }
            }
        }
        .task {
            // The fast rate is only paid for while the charts are on screen.
            monitor.demand(.dashboard, every: Prefs.int(Prefs.liveInterval, 2))
            // If the stream could not start, still show something useful.
            if !monitor.isRunning { await monitor.refreshOnce() }
        }
        .onDisappear { monitor.demand(.dashboard, every: nil) }
    }

    @ViewBuilder
    private func content(_ snapshot: StatusSnapshot) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                topRow(snapshot)

                HStack(alignment: .top, spacing: 12) {
                    cpuCard(snapshot)
                    memoryCard(snapshot)
                }

                HStack(alignment: .top, spacing: 12) {
                    disksCard(snapshot)
                    networkCard(snapshot)
                }

                HStack(alignment: .top, spacing: 12) {
                    processesCard(snapshot)
                    VStack(spacing: 12) {
                        powerCard(snapshot)
                        hardwareCard(snapshot)
                    }
                    .frame(width: 300)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }

    // MARK: - Cards

    private func topRow(_ snapshot: StatusSnapshot) -> some View {
        HStack(spacing: 12) {
            Card {
                HStack(spacing: 16) {
                    HealthRing(score: snapshot.healthScore, caption: snapshot.healthScoreMsg)
                        .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("System health")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Mole.textDim)
                        Text(snapshot.healthScoreMsg.isEmpty ? "—" : snapshot.healthScoreMsg)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Mole.text)
                        Text("\(snapshot.procs) processes")
                            .font(Mole.mono(10))
                            .foregroundStyle(Mole.textFaint)
                    }
                    Spacer()
                }
            }
            .frame(width: 300)

            Card {
                HStack(spacing: 20) {
                    Metric(label: "CPU", value: String(format: "%.1f%%", snapshot.cpu.usage),
                           detail: String(format: "load %.2f", snapshot.cpu.load1),
                           fraction: snapshot.cpu.usage / 100,
                           color: Mole.load(snapshot.cpu.usage))

                    Metric(label: "Memory",
                           value: String(format: "%.0f%%", snapshot.memory.usedPercent),
                           detail: "\(formatBytesBinary(snapshot.memory.used)) / \(formatBytesBinary(snapshot.memory.total))",
                           fraction: snapshot.memory.usedPercent / 100,
                           color: Mole.load(snapshot.memory.usedPercent))

                    if let disk = rootDisk(snapshot) {
                        Metric(label: "Disk",
                               value: String(format: "%.0f%%", disk.usedPercent),
                               detail: "\(formatBytesBinary(disk.total - disk.used)) free",
                               fraction: disk.usedPercent / 100,
                               color: Mole.load(disk.usedPercent))
                    }

                    Metric(label: "Trash", value: formatBytesBinary(snapshot.trashSize),
                           detail: snapshot.trashSize > 0 ? "recoverable" : "empty",
                           fraction: nil, color: Mole.amber)
                }
            }
        }
    }

    private func cpuCard(_ snapshot: StatusSnapshot) -> some View {
        let cores = snapshot.cpu.perCore ?? []
        let split = snapshot.cpu.eCoreCount > 0
            ? "\(snapshot.cpu.pCoreCount)P + \(snapshot.cpu.eCoreCount)E"
            : "\(snapshot.cpu.coreCount) cores"

        return Card(title: "Processor", trailing: split) {
            VStack(alignment: .leading, spacing: 10) {
                Sparkline(values: monitor.cpuHistory,
                          color: Mole.load(snapshot.cpu.usage),
                          ceiling: 100)
                    .frame(height: 40)

                // One stratum per core — the layered read is the point.
                VStack(spacing: 3) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { index, usage in
                        HStack(spacing: 7) {
                            Text("\(index)")
                                .font(Mole.mono(9))
                                .monospacedDigit()
                                .foregroundStyle(Mole.textFaint)
                                .frame(width: 14, alignment: .trailing)
                            StratumBar(fraction: usage / 100, color: Mole.load(usage), height: 4)
                            Text(String(format: "%3.0f%%", usage))
                                .font(Mole.mono(9))
                                .monospacedDigit()
                                .foregroundStyle(Mole.textFaint)
                        }
                    }
                }

                HStack(spacing: 14) {
                    loadStat("1m", snapshot.cpu.load1)
                    loadStat("5m", snapshot.cpu.load5)
                    loadStat("15m", snapshot.cpu.load15)
                }
            }
        }
    }

    private func loadStat(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Mole.textFaint)
            Text(String(format: "%.2f", value))
                .font(Mole.mono(10))
                .monospacedDigit()
                .foregroundStyle(Mole.textDim)
        }
    }

    private func memoryCard(_ snapshot: StatusSnapshot) -> some View {
        let memory = snapshot.memory
        return Card(title: "Memory",
                    trailing: memory.pressure.isEmpty ? nil : "pressure: \(memory.pressure)") {
            VStack(alignment: .leading, spacing: 10) {
                Sparkline(values: monitor.memoryHistory,
                          color: Mole.load(memory.usedPercent),
                          ceiling: 100)
                    .frame(height: 40)

                StratumRow(title: "Used", size: formatBytesBinary(memory.used),
                           fraction: Double(memory.used) / Double(max(memory.total, 1)),
                           color: Mole.load(memory.usedPercent), subtitle: nil)

                StratumRow(title: "Cached (reclaimable)", size: formatBytesBinary(memory.cached),
                           fraction: Double(memory.cached) / Double(max(memory.total, 1)),
                           color: Mole.amber, subtitle: nil)

                if memory.swapTotal > 0 {
                    StratumRow(title: "Swap", size: "\(formatBytesBinary(memory.swapUsed)) / \(formatBytesBinary(memory.swapTotal))",
                               fraction: Double(memory.swapUsed) / Double(max(memory.swapTotal, 1)),
                               color: Mole.brand, subtitle: nil)
                }

                Text("\(formatBytesBinary(memory.available)) available of \(formatBytesBinary(memory.total))")
                    .font(Mole.mono(10))
                    .foregroundStyle(Mole.textFaint)
            }
        }
    }

    private func disksCard(_ snapshot: StatusSnapshot) -> some View {
        Card(title: "Storage") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.disks ?? []) { disk in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            // Simulator volumes have very long mount paths;
                            // truncate in the middle so the tail stays readable.
                            Text(disk.mount)
                                .font(Mole.mono(11))
                                .foregroundStyle(Mole.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(disk.mount)
                            if disk.external {
                                Text("EXTERNAL")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(Mole.brand)
                            }
                            Spacer()
                            Text("\(formatBytesBinary(disk.used)) / \(formatBytesBinary(disk.total))")
                                .font(Mole.mono(10))
                                .monospacedDigit()
                                .foregroundStyle(Mole.textDim)
                        }

                        // Two strata: what is used, and what macOS considers
                        // purgeable inside that — the gap between them is the
                        // space people are surprised to find.
                        StratumStack(segments: [
                            .init(fraction: max(0, Double(disk.used - min(disk.used, disk.purgeable)) / Double(max(disk.total, 1))),
                                  color: Mole.load(disk.usedPercent)),
                            .init(fraction: Double(min(disk.used, disk.purgeable)) / Double(max(disk.total, 1)),
                                  color: Mole.amber.opacity(0.75)),
                        ], height: 7)

                        HStack(spacing: 10) {
                            Text("\(formatBytesBinary(disk.total - disk.used)) free")
                                .font(Mole.mono(9))
                                .foregroundStyle(Mole.textFaint)
                            if disk.purgeable > 0 {
                                Text("\(formatBytesBinary(disk.purgeable)) purgeable")
                                    .font(Mole.mono(9))
                                    .foregroundStyle(Mole.amber)
                            }
                            if !disk.smartStatus.isEmpty {
                                Text("SMART \(disk.smartStatus)")
                                    .font(Mole.mono(9))
                                    .foregroundStyle(Mole.textFaint)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func networkCard(_ snapshot: StatusSnapshot) -> some View {
        Card(title: "Network") {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Sparkline(values: monitor.rxHistory, color: Mole.moss)
                    Sparkline(values: monitor.txHistory, color: Mole.brand)
                }
                .frame(height: 46)

                ForEach(snapshot.network ?? []) { interface in
                    HStack(spacing: 8) {
                        Text(interface.name)
                            .font(Mole.mono(11))
                            .foregroundStyle(Mole.text)
                            .frame(width: 54, alignment: .leading)
                        Text(interface.ip)
                            .font(Mole.mono(10))
                            .foregroundStyle(Mole.textFaint)
                        Spacer()
                        Label(String(format: "%.2f", interface.rxRateMBs), systemImage: "arrow.down")
                            .font(Mole.mono(10))
                            .monospacedDigit()
                            .foregroundStyle(Mole.moss)
                        Label(String(format: "%.2f", interface.txRateMBs), systemImage: "arrow.up")
                            .font(Mole.mono(10))
                            .monospacedDigit()
                            .foregroundStyle(Mole.brand)
                    }
                }

                HStack(spacing: 12) {
                    Text("MB/s")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Mole.textFaint)
                    Spacer()
                    Text(String(format: "disk r %.1f · w %.1f MB/s",
                                snapshot.diskIO.readRate, snapshot.diskIO.writeRate))
                        .font(Mole.mono(9))
                        .foregroundStyle(Mole.textFaint)
                }
            }
        }
    }

    private func processesCard(_ snapshot: StatusSnapshot) -> some View {
        Card(title: "Top processes", trailing: "by CPU") {
            VStack(spacing: 5) {
                ForEach(snapshot.topProcesses ?? []) { process in
                    HStack(spacing: 8) {
                        Text("\(process.pid)")
                            .font(Mole.mono(9))
                            .monospacedDigit()
                            .foregroundStyle(Mole.textFaint)
                            .frame(width: 44, alignment: .trailing)

                        Text(process.name)
                            .font(.system(size: 11))
                            .foregroundStyle(Mole.text)
                            .lineLimit(1)
                            .frame(width: 150, alignment: .leading)

                        StratumBar(fraction: min(1, process.cpu / 100),
                                   color: Mole.load(process.cpu), height: 4)

                        Text(String(format: "%.1f%%", process.cpu))
                            .font(Mole.mono(10))
                            .monospacedDigit()
                            .foregroundStyle(Mole.textDim)
                            .frame(width: 46, alignment: .trailing)

                        Text(formatBytesBinary(process.memoryBytes))
                            .font(Mole.mono(10))
                            .monospacedDigit()
                            .foregroundStyle(Mole.textFaint)
                            .frame(width: 54, alignment: .trailing)
                    }
                }

                ForEach(snapshot.processAlerts ?? []) { alert in
                    Notice(icon: "flame", text: "\(alert.name): \(alert.message)")
                        .padding(.top, 4)
                }
            }
        }
    }

    private func powerCard(_ snapshot: StatusSnapshot) -> some View {
        Card(title: "Power & thermal") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((snapshot.batteries ?? []).enumerated()), id: \.offset) { _, battery in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Battery")
                                .font(.system(size: 11))
                                .foregroundStyle(Mole.text)
                            Spacer()
                            Text("\(battery.percent)% · \(battery.status)")
                                .font(Mole.mono(10))
                                .foregroundStyle(Mole.textDim)
                        }
                        StratumBar(fraction: Double(battery.percent) / 100,
                                   color: battery.status == "charging" ? Mole.moss : Mole.amber)
                        Text("\(battery.cycleCount) cycles")
                            .font(Mole.mono(9))
                            .foregroundStyle(Mole.textFaint)
                    }
                }

                if snapshot.thermal.systemPower > 0 {
                    HStack {
                        Text("System power")
                            .font(.system(size: 11))
                            .foregroundStyle(Mole.textDim)
                        Spacer()
                        Text(String(format: "%.1f W", snapshot.thermal.systemPower))
                            .font(Mole.mono(10))
                            .foregroundStyle(Mole.text)
                    }
                }
                if snapshot.thermal.fanSpeed > 0 {
                    HStack {
                        Text("Fan")
                            .font(.system(size: 11))
                            .foregroundStyle(Mole.textDim)
                        Spacer()
                        Text("\(snapshot.thermal.fanSpeed) rpm")
                            .font(Mole.mono(10))
                            .foregroundStyle(Mole.text)
                    }
                }
            }
        }
    }

    private func hardwareCard(_ snapshot: StatusSnapshot) -> some View {
        Card(title: "Hardware") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(hardwareRows(snapshot), id: \.0) { label, value in
                    HStack(alignment: .top) {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundStyle(Mole.textFaint)
                        Spacer()
                        Text(value)
                            .font(Mole.mono(10))
                            .foregroundStyle(Mole.textDim)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private func hardwareRows(_ snapshot: StatusSnapshot) -> [(String, String)] {
        var rows = [
            ("Model", snapshot.hardware.model),
            ("Memory", snapshot.hardware.totalRAM),
            ("Disk", snapshot.hardware.diskSize),
            ("System", snapshot.hardware.osVersion),
            ("Uptime", snapshot.uptime),
        ]
        if let gpu = (snapshot.gpu ?? []).first {
            rows.insert(("GPU", "\(gpu.name) · \(gpu.coreCount) cores"), at: 1)
        }
        return rows.filter { !$0.1.isEmpty }
    }

    private func rootDisk(_ snapshot: StatusSnapshot) -> StatusSnapshot.Disk? {
        (snapshot.disks ?? []).first { $0.mount == "/" } ?? (snapshot.disks ?? []).first
    }
}
