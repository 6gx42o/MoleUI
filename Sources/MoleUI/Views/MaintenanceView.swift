import SwiftUI
import SQLite3

/// Routine fixes. Each is a real command with a known effect — no "speed boost"
/// placebo — and the ones that need root are batched behind a single macOS
/// password prompt when run together.
struct MaintenanceTask: Identifiable {
    enum Work {
        case admin(String)                       // one shell command, as root
        case tool(String, [String])              // executable + arguments, as you
        case native(() async -> (Bool, String))
    }

    var id: String
    var title: String
    var detail: String
    var icon: String
    var caution: String? = nil
    var work: Work

    var needsAdmin: Bool { if case .admin = work { return true } else { return false } }
}

extension MaintenanceTask {
    static let all: [MaintenanceTask] = [
        // Was its own Optimization section. It is one more "run a fix" — so it
        // sits here, first, with the others.
        MaintenanceTask(id: "optimize", title: "Optimize system",
                        detail: "Mole's tune-up: refreshes system caches and services and repairs "
                              + "common problems. Nothing is deleted.",
                        icon: "gauge.with.needle",
                        caution: "Some steps need a sudo session and are skipped without one.",
                        work: .native({
                            guard MoleCLI.shared.isInstalled else {
                                return (false, "Needs Mole — `brew install mole`.")
                            }
                            // Non-zero when a task "needs attention", which is a
                            // report, not a failure.
                            guard let output = try? await MoleCLI.shared.run(["optimize"]) else {
                                return (false, "mo optimize could not run.")
                            }
                            let parsed = MolePreview.parse(output.stdout)
                            return (true, parsed.headline ?? parsed.summary.last ?? "Done.")
                        })),
        MaintenanceTask(id: "ram", title: "Free up RAM",
                        detail: "Flushes inactive memory and disk caches back to the system.",
                        icon: "memorychip", work: .admin("/usr/sbin/purge")),
        MaintenanceTask(id: "dns", title: "Flush DNS cache",
                        detail: "Fixes sites that fail to load after a network or DNS change.",
                        icon: "network",
                        work: .admin("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")),
        MaintenanceTask(id: "launchservices", title: "Rebuild Launch Services",
                        detail: "Fixes duplicate entries in Open With and apps opening the wrong file types.",
                        icon: "arrow.up.forward.app",
                        work: .tool("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                                    ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])),
        MaintenanceTask(id: "quicklook", title: "Reset Quick Look",
                        detail: "Clears thumbnail and preview caches when previews show stale or blank images.",
                        icon: "eye", work: .native({
                            let first = try? await MoleCLI.shared.tool("/usr/bin/qlmanage", ["-r", "cache"])
                            let second = try? await MoleCLI.shared.tool("/usr/bin/qlmanage", ["-r"])
                            let ok = first?.exitCode == 0 && second?.exitCode == 0
                            return (ok, ok ? "Quick Look caches reset." : (second?.stderr ?? "qlmanage failed"))
                        })),
        MaintenanceTask(id: "mail", title: "Speed up Mail",
                        detail: "Compacts Mail's message index, which grows slow over years of email.",
                        icon: "envelope", caution: "Mail must be closed.",
                        work: .native({ await vacuumMailIndex() })),
        MaintenanceTask(id: "snapshots", title: "Thin Time Machine snapshots",
                        detail: "Removes local Time Machine snapshots that hold on to deleted files' space.",
                        icon: "clock.arrow.2.circlepath",
                        caution: "Backups on your Time Machine drive are not affected.",
                        work: .admin("/usr/bin/tmutil thinlocalsnapshots / 999999999999 4")),
        MaintenanceTask(id: "spotlight", title: "Reindex Spotlight",
                        detail: "Rebuilds the search index when search misses files you know exist.",
                        icon: "magnifyingglass",
                        caution: "Indexing runs in the background for a while and uses some battery.",
                        work: .admin("/usr/bin/mdutil -E /")),
        MaintenanceTask(id: "verify", title: "Verify startup disk",
                        detail: "Checks the file system for errors without changing anything.",
                        icon: "internaldrive",
                        work: .tool("/usr/sbin/diskutil", ["verifyVolume", "/"])),
    ]

    @MainActor
    static func vacuumMailIndex() async -> (Bool, String) {
        if Apps.runningBundleIDs().contains("com.apple.mail") { return (false, "Quit Mail first.") }
        let mail = NSHomeDirectory() + "/Library/Mail"
        guard let version = DiskUsage.children(of: mail)
            .filter({ ($0 as NSString).lastPathComponent.hasPrefix("V") }).sorted().last else {
            return (false, "Mail has no message store on this Mac.")
        }
        return await vacuum(version + "/MailData/Envelope Index")
    }

    /// Split out so the action test can run it on a *copy* of the index.
    static func vacuum(_ index: String) async -> (Bool, String) {
        guard DiskUsage.exists(index) else { return (false, "No Mail index found.") }
        let before = DiskUsage.size(of: index)
        let ok = await Task.detached { () -> Bool in
            var db: OpaquePointer?
            guard sqlite3_open(index, &db) == SQLITE_OK else { sqlite3_close(db); return false }
            defer { sqlite3_close(db) }
            return sqlite3_exec(db, "VACUUM;", nil, nil, nil) == SQLITE_OK
        }.value
        let after = DiskUsage.size(of: index)
        return ok ? (true, "Index compacted: \(formatBytesDecimal(before)) → \(formatBytesDecimal(after)).")
                  : (false, "Could not compact the index.")
    }
}

@MainActor
final class MaintenanceModel: ObservableObject {
    struct Status { var ok: Bool; var output: String; var date: Date }

    @Published var selection: Set<String> = []
    @Published var running: Set<String> = []
    @Published var status: [String: Status] = [:]
    @Published var snapshotCount: Int?

    func loadInfo() async {
        let output = try? await MoleCLI.shared.tool("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        snapshotCount = output?.stdout.components(separatedBy: .newlines)
            .filter { $0.contains("com.apple.TimeMachine") }.count
    }

    func lastRun(_ id: String) -> Date? {
        UserDefaults.standard.object(forKey: "maintenance.\(id)") as? Date
    }

    func run(_ tasks: [MaintenanceTask]) async {
        running.formUnion(tasks.map(\.id))
        defer { running.subtract(tasks.map(\.id)) }

        // Every root task in one prompt, each bracketed with markers so its own
        // output and exit status can be read back out of the combined result.
        let rootTasks = tasks.filter(\.needsAdmin)
        if !rootTasks.isEmpty {
            let script = rootTasks.compactMap { task -> String? in
                guard case let .admin(command) = task.work else { return nil }
                return "echo '@@begin \(task.id)'; ( \(command) ) 2>&1; echo \"@@end \(task.id) $?\""
            }.joined(separator: "; ")
            let result = await Admin.run(script)
            for task in rootTasks {
                if result.cancelled {
                    record(task.id, false, "Cancelled at the password prompt.")
                    continue
                }
                let output = section(of: result.output, for: task.id)
                record(task.id, output.code == 0,
                       output.text.isEmpty ? (output.code == 0 ? "Done." : result.output) : output.text)
            }
        }

        for task in tasks where !task.needsAdmin {
            switch task.work {
            case let .tool(executable, args):
                let output = try? await MoleCLI.shared.tool(executable, args)
                let text = ((output?.stdout ?? "") + (output?.stderr ?? ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                record(task.id, output?.exitCode == 0,
                       text.components(separatedBy: .newlines).suffix(2).joined(separator: " ")
                           .ifEmpty(output?.exitCode == 0 ? "Done." : "Failed."))
            case let .native(work):
                let (ok, text) = await work()
                record(task.id, ok, text)
            case .admin:
                break
            }
        }
        if tasks.contains(where: { $0.id == "snapshots" }) { await loadInfo() }
    }

    private func record(_ id: String, _ ok: Bool, _ output: String) {
        status[id] = Status(ok: ok, output: output, date: Date())
        if ok { UserDefaults.standard.set(Date(), forKey: "maintenance.\(id)") }
    }

    private func section(of output: String, for id: String) -> (code: Int, text: String) {
        guard let begin = output.range(of: "@@begin \(id)"),
              let end = output.range(of: "@@end \(id) ", range: begin.upperBound..<output.endIndex)
        else { return (1, "") }
        let text = output[begin.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let code = Int(output[end.upperBound...].prefix { $0.isNumber }) ?? 1
        return (code, text.components(separatedBy: .newlines).suffix(2).joined(separator: " "))
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

struct MaintenanceView: View {
    @StateObject private var model = MaintenanceModel()

    var body: some View {
        PaneScaffold(title: Pane.maintenance.title, subtitle: Pane.maintenance.subtitle) {
            if !model.selection.isEmpty {
                GhostButton(title: "Clear", systemImage: "xmark") { model.selection = [] }
                ActionButton(title: "Run \(model.selection.count) task\(model.selection.count == 1 ? "" : "s")",
                             systemImage: "play.fill", loading: !model.running.isEmpty) {
                    let tasks = MaintenanceTask.all.filter { model.selection.contains($0.id) }
                    Task { await model.run(tasks); model.selection = [] }
                }
            }
        } content: {
            ScrollView {
                VStack(spacing: 8) {
                    Notice(icon: "lock",
                           text: "Tasks marked “admin” ask for your password through macOS's own dialog — "
                               + "MoleUI never sees it. Selecting several runs them all behind one prompt.",
                           tint: Mole.textFaint)
                    ForEach(MaintenanceTask.all) { row($0) }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        .task { await model.loadInfo() }
    }

    private func row(_ task: MaintenanceTask) -> some View {
        let selected = model.selection.contains(task.id)
        let busy = model.running.contains(task.id)
        return HStack(alignment: .top, spacing: 12) {
            Button {
                if selected { model.selection.remove(task.id) } else { model.selection.insert(task.id) }
            } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Mole.brand : Mole.textFaint)
            }
            .buttonStyle(.plain)

            Image(systemName: task.icon)
                .font(.system(size: 14))
                .foregroundStyle(Mole.amber)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Mole.text)
                    if task.needsAdmin {
                        Text("ADMIN").font(.system(size: 8, weight: .semibold)).foregroundStyle(Mole.brand)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Mole.brand.opacity(0.13), in: RoundedRectangle(cornerRadius: 3))
                    }
                    if task.id == "snapshots", let count = model.snapshotCount {
                        Text("\(count) on this Mac").font(Mole.mono(9.5)).foregroundStyle(Mole.textFaint)
                    }
                }
                Text(task.detail).font(.system(size: 11)).foregroundStyle(Mole.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let caution = task.caution {
                    Text(caution).font(.system(size: 10.5)).foregroundStyle(Mole.amber)
                }
                if let status = model.status[task.id] {
                    Label(status.output, systemImage: status.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(Mole.mono(10))
                        .foregroundStyle(status.ok ? Mole.moss : Mole.amber)
                        .lineLimit(3)
                } else if let last = model.lastRun(task.id) {
                    Text("Last run \(relative(last))").font(Mole.mono(9.5)).foregroundStyle(Mole.textFaint)
                }
            }
            Spacer()
            GhostButton(title: busy ? "Running…" : "Run", systemImage: busy ? nil : "play") {
                Task { await model.run([task]) }
            }
            .disabled(busy)
        }
        .padding(12)
        .background(Mole.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Mole.brand.opacity(0.4) : Mole.border,
                                                          lineWidth: 1))
    }
}
