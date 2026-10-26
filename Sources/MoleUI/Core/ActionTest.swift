import Foundation
import ServiceManagement

/// `MoleUI --actiontest` — exercises every action's real code path on
/// disposable data the test creates itself: probe files, a throwaway launch
/// agent, a bundle id that does not exist. It never touches the user's own
/// files, grants or networks, and anything it moves to the Trash it removes
/// again. Admin-only steps are exercised up to the privilege boundary (the same
/// quoting and command, run unprivileged), since only the user can type the
/// password.
///
/// Launch with `open -n -a MoleUI.app --args --actiontest`; the report lands in
/// ~/Library/Logs/MoleUI/actiontest.txt.
@MainActor
enum ActionTest {
    private static var report = ""
    private static var failures = 0
    private static let pid = ProcessInfo.processInfo.processIdentifier
    private static let home = NSHomeDirectory()
    private static let fm = FileManager.default

    private static func line(_ text: String) { print(text); report += text + "\n" }

    private static func check(_ name: String, _ ok: Bool, _ detail: String) {
        if !ok { failures += 1 }
        line("  \(ok ? "ok  " : "FAIL") \(name): \(detail)")
    }

    private static func probe(_ name: String, bytes: Int = 1_024) -> String {
        let path = NSTemporaryDirectory() + "moleui-actiontest-\(pid)-\(name)"
        fm.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes))
        return path
    }

    private static func trashed(_ path: String) -> String {
        home + "/.Trash/" + (path as NSString).lastPathComponent
    }

    /// Our own probes only, and only from inside the Trash — this goes through
    /// the Trash Bins action itself, so it doubles as that action's test.
    private static func purgeFromTrash(_ paths: [String]) async -> FindingOutcome {
        let rows = paths.map { Finding(id: $0, title: ($0 as NSString).lastPathComponent, paths: [$0]) }
        return await Features.trashBins.action!.perform(rows)
    }

    /// `--upgrade-test <formula>` — the Updater's real Update action on one
    /// Homebrew formula the user agreed to upgrade.
    static func upgrade(_ name: String) -> Never {
        Task { @MainActor in
            let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: fm.fileExists) ?? ""
            func version() async -> String {
                (try? await MoleCLI.shared.tool(brew, ["list", "--versions", name],
                                                env: ["HOMEBREW_NO_AUTO_UPDATE": "1"]))?.stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            }
            let before = await version()
            let started = Date()
            let outcome = await Features.updater.action!.perform([
                Finding(id: "brew:formula:\(name)", title: name, info: ["source": "brew", "kind": "formula"])])
            let after = await version()
            check("Updater: brew upgrade \(name)", outcome.succeeded.count == 1 && before != after,
                  "\(before) → \(after) in \(Int(Date().timeIntervalSince(started)))s · \(outcome.message)"
                  + (outcome.failures.first.map { " · \($0.reason)" } ?? ""))
            line(failures == 0 ? "RESULT: upgrade passed" : "RESULT: upgrade failed")
            try? report.write(toFile: DiagnosticsDir.file("upgradetest.txt"), atomically: true, encoding: .utf8)
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// `--maintenance <task id>` — runs one Maintenance task exactly as its Run
    /// button does, including the macOS password dialog for admin tasks.
    static func maintenance(_ id: String) -> Never {
        Task { @MainActor in
            guard let task = MaintenanceTask.all.first(where: { $0.id == id }) else {
                line("unknown task \(id)"); exit(2)
            }
            let model = MaintenanceModel()
            let started = Date()
            await model.run([task])
            let status = model.status[id]
            check("Maintenance: \(task.title)", status?.ok == true,
                  (status?.output ?? "no status") + " (\(Int(Date().timeIntervalSince(started)))s)")
            line(failures == 0 ? "RESULT: task passed" : "RESULT: task failed")
            try? report.write(toFile: DiagnosticsDir.file("maintenance.txt"), atomically: true, encoding: .utf8)
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    static func start() -> Never {
        Task { @MainActor in
            line("MoleUI action test (pid \(pid))")

            // 1. Move to Trash — the action behind Leftovers, Privacy, Large
            //    Files, Duplicates, Extensions and Malware.
            let a = probe("trash.txt")
            let moved = await FindingOutcome.trash([Finding(id: a, title: "a", paths: [a], bytes: 1_024)])
            check("Move to Trash", moved.succeeded == [a] && !fm.fileExists(atPath: a)
                                   && fm.fileExists(atPath: trashed(a)),
                  moved.message)

            // 2. Trash Bins — permanent, and only inside a Trash.
            let outside = probe("outside.txt")
            let refused = await purgeFromTrash([outside])
            check("Trash Bins refuses outside the Trash",
                  refused.succeeded.isEmpty && fm.fileExists(atPath: outside),
                  refused.failures.first?.reason ?? "not refused")
            try? fm.removeItem(atPath: outside)
            let emptied = await purgeFromTrash([trashed(a)])
            check("Trash Bins deletes permanently", emptied.succeeded.count == 1 && !fm.fileExists(atPath: trashed(a)),
                  emptied.message)

            // 3. Shredder — zero-fill, then permanent delete.
            let secret = probe("shred.bin", bytes: 3_000_000)
            ShredderModel.zeroFill(secret)
            let zeroed = fm.contents(atPath: secret).map { $0.allSatisfy { $0 == 0 } } ?? false
            check("Shredder zero-fill", zeroed, zeroed ? "3MB overwritten with zeros" : "contents survived")
            let shredder = ShredderModel()
            shredder.add([URL(fileURLWithPath: secret)])
            await shredder.shred()
            check("Shredder delete", !fm.fileExists(atPath: secret) && shredder.failures.isEmpty,
                  shredder.result ?? "no result")

            // 4. Duplicates — refuses a copy edited since the scan.
            let keep = probe("dup-keep.bin"), edited = probe("dup-edited.bin")
            func stamp(_ path: String) -> String {
                let date = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return String(Int(date.timeIntervalSince1970))
            }
            let rows = [keep, edited].map {
                Finding(id: $0, title: ($0 as NSString).lastPathComponent, paths: [$0], bytes: 1_024,
                        info: ["hash": "same", "mtime": stamp($0)])
            }
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: edited)
            let dupe = await Features.duplicates.action!.perform(rows)
            check("Duplicates re-checks before removing",
                  dupe.succeeded == [keep] && fm.fileExists(atPath: edited)
                  && dupe.failures.first?.reason.contains("changed") == true,
                  dupe.message + " / " + (dupe.failures.first?.reason ?? ""))
            try? fm.removeItem(atPath: edited)
            _ = await purgeFromTrash([trashed(keep)])

            // 5. Malware Removal — unload a live launch agent, then trash it.
            let label = "dev.rushil.moleui.actiontest"
            let plist = home + "/Library/LaunchAgents/\(label).plist"
            (["Label": label, "ProgramArguments": ["/usr/bin/true"]] as NSDictionary).write(toFile: plist, atomically: true)
            let uid = getuid()
            _ = try? await MoleCLI.shared.tool("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
            let loadedBefore = (try? await MoleCLI.shared.tool("/bin/launchctl", ["print", "gui/\(uid)/\(label)"]))?.exitCode == 0
            let removal = await LaunchItem.remove([Finding(id: plist, title: label, paths: [plist],
                                                           info: ["domain": LaunchItem.Domain.userAgent.rawValue])])
            let loadedAfter = (try? await MoleCLI.shared.tool("/bin/launchctl", ["print", "gui/\(uid)/\(label)"]))?.exitCode == 0
            check("Malware Removal unloads and trashes",
                  loadedBefore && !loadedAfter && !fm.fileExists(atPath: plist) && removal.succeeded.count == 1,
                  "loaded before=\(loadedBefore) after=\(loadedAfter); \(removal.message)")
            _ = await purgeFromTrash([trashed(plist)])

            // 6. Permissions — the real Reset action, on MoleUI's own Camera
            //    record. tccutil only accepts installed bundle ids, and MoleUI
            //    has never had camera access, so this changes nothing.
            let own = Bundle.main.bundleIdentifier ?? "dev.rushil.moleui"
            let reset = await Features.permissions.action!.perform([
                Finding(id: "Camera|" + own, title: "MoleUI", info: ["service": "Camera", "client": own])])
            check("Permissions reset", reset.succeeded.count == 1 && reset.failures.isEmpty, reset.message)

            // Everything this test moved to the Trash has been removed again.
            let probes = [a, keep, plist].map(trashed)
            check("Cleanup", probes.allSatisfy { !fm.fileExists(atPath: $0) },
                  probes.filter(fm.fileExists).isEmpty ? "no probes left in the Trash"
                      : "left: \(probes.filter(fm.fileExists).joined(separator: ", "))")

            // 7. Admin path quoting, end to end, unprivileged. A Wi-Fi name is
            //    chosen by whoever runs the network, so it is hostile input.
            let hostile = "x'; touch /tmp/moleui-pwned-\(pid) #\"$(touch /tmp/moleui-pwned2-\(pid))\\ `id`"
            let echoed = await Admin.run("/usr/bin/printf %s \(Shell.quote(hostile))", privileged: false)
            let pwned = fm.fileExists(atPath: "/tmp/moleui-pwned-\(pid)") || fm.fileExists(atPath: "/tmp/moleui-pwned2-\(pid)")
            check("Admin quoting survives a hostile name", echoed.ok && echoed.output == hostile && !pwned,
                  pwned ? "INJECTION RAN" : (echoed.output == hostile ? "printed verbatim, nothing executed" : echoed.output))
            let forget = Features.forgetCommand(interface: "en0", ssids: [hostile])
            check("Wi-Fi forget builds a quoted command",
                  forget == "/usr/sbin/networksetup -removepreferredwirelessnetwork 'en0' \(Shell.quote(hostile))",
                  "ssid passed as one quoted argument")

            // 8. Maintenance — the tasks that need no password.
            let maintenance = MaintenanceModel()
            let tasks = MaintenanceTask.all.filter { ["quicklook", "verify"].contains($0.id) }
            await maintenance.run(tasks)
            for task in tasks {
                let status = maintenance.status[task.id]
                check("Maintenance: \(task.title)", status?.ok == true, status?.output ?? "no status")
            }
            let adminTasks = MaintenanceTask.all.filter(\.needsAdmin).map(\.title)
            line("  info Maintenance admin tasks need your password: \(adminTasks.joined(separator: ", "))")

            // 8b. Speed up Mail — on a copy of the real index, never the original.
            let mailStore = home + "/Library/Mail"
            if let version = DiskUsage.children(of: mailStore)
                .filter({ ($0 as NSString).lastPathComponent.hasPrefix("V") }).sorted().last {
                let copy = NSTemporaryDirectory() + "moleui-actiontest-\(pid)-EnvelopeIndex"
                try? fm.copyItem(atPath: version + "/MailData/Envelope Index", toPath: copy)
                let (ok, text) = await MaintenanceTask.vacuum(copy)
                check("Maintenance: Speed up Mail (on a copy)", ok, text)
                try? fm.removeItem(atPath: copy)
            }

            // 8c. Optimize system — the real `mo optimize`. Non-destructive:
            //     refreshes caches and services, deletes nothing.
            if let optimize = MaintenanceTask.all.first(where: { $0.id == "optimize" }) {
                let started = Date()
                await maintenance.run([optimize])
                let status = maintenance.status["optimize"]
                check("Maintenance: Optimize system", status?.ok == true,
                      (status?.output ?? "no status") + String(format: " (%.0fs)", Date().timeIntervalSince(started)))
            }

            // 8d. Uninstaller — a real `mo uninstall` of a throwaway app this test
            //     builds, through the same arguments, input and env the pane uses.
            let dummyName = "MoleUIActionTestApp"
            let dummy = home + "/Applications/\(dummyName).app"
            try? fm.createDirectory(atPath: dummy + "/Contents/MacOS", withIntermediateDirectories: true)
            (["CFBundleIdentifier": "dev.rushil.moleui.actiontestapp", "CFBundleName": dummyName,
              "CFBundleExecutable": dummyName, "CFBundlePackageType": "APPL"] as NSDictionary)
                .write(toFile: dummy + "/Contents/Info.plist", atomically: true)
            fm.createFile(atPath: dummy + "/Contents/MacOS/\(dummyName)", contents: Data("#!/bin/sh\n".utf8),
                          attributes: [.posixPermissions: 0o755])
            // Exactly what the pane does: Mole's dry-run plan, then MoleUI's
            // removal of the paths in it.
            let preview = try? await MoleCLI.shared.run(["uninstall", "--dry-run", dummyName],
                                                        input: UninstallPlan.confirmationInput,
                                                        env: UninstallPlan.trashModeEnv)
            let plan = UninstallPlan.parse(preview?.stdout ?? "")
            let removed = await UninstallPlan.remove(plan)
            let uninstall = preview
            let gone = !fm.fileExists(atPath: dummy) && removed.moved > 0
            let inTrash = DiskUsage.children(of: home + "/.Trash").filter { $0.contains(dummyName) }
            check("Uninstaller: Mole plan → MoleUI removal (throwaway app)", gone && !inTrash.isEmpty,
                  gone ? "removed to the Trash (\(inTrash.count) item\(inTrash.count == 1 ? "" : "s"))"
                       : "still installed: " + (uninstall?.stdout.suffix(200).description ?? "no output"))
            if !gone { try? fm.removeItem(atPath: dummy) }
            if !inTrash.isEmpty { _ = await purgeFromTrash(inTrash) }

            // 8e. Open at login — registered, confirmed, then restored.
            let wasEnabled = SMAppService.mainApp.status == .enabled
            do {
                try SMAppService.mainApp.register()
                let enabled = SMAppService.mainApp.status
                if !wasEnabled { try await SMAppService.mainApp.unregister() }
                check("Settings: Open at login", enabled == .enabled || enabled == .requiresApproval,
                      "registered (status \(enabled.rawValue)), restored to \(wasEnabled ? "on" : "off")")
            } catch {
                check("Settings: Open at login", false, error.localizedDescription)
            }

            // 9. Updater — the upgrade command, dry run.
            if let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: fm.fileExists) {
                let outdated = try? await MoleCLI.shared.tool(brew, ["outdated", "--formula", "--quiet"],
                                                              env: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
                if let name = outdated?.stdout.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) {
                    let upgrade = try? await MoleCLI.shared.tool(brew, ["upgrade", "--dry-run", name],
                                                                 env: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
                    check("Updater: brew upgrade \(name) (dry run)", upgrade?.exitCode == 0,
                          upgrade?.stdout.components(separatedBy: .newlines).first { !$0.isEmpty } ?? "no output")
                }
            }

            // 10. Settings — preferences actually reach the collector.
            let monitor = StatusMonitor.shared
            monitor.setWindowVisible(false)
            UserDefaults.standard.set(true, forKey: Prefs.menuBarCPU)
            monitor.applyMenuBarPreference()
            let withLabel = monitor.targetInterval
            UserDefaults.standard.set(false, forKey: Prefs.menuBarCPU)
            monitor.applyMenuBarPreference()
            let withoutLabel = monitor.targetInterval
            // Low Power Mode halves the rate by design, so 10s becomes 20s.
            let expected = ProcessInfo.processInfo.isLowPowerModeEnabled ? 20 : 10
            check("Settings: menu bar CPU drives sampling", withLabel == expected && withoutLabel == nil,
                  "on → every \(withLabel.map(String.init) ?? "off")s, off → \(withoutLabel.map { "\($0)s" } ?? "stopped")")

            let previousHours = UserDefaults.standard.object(forKey: Prefs.cacheHours)
            UserDefaults.standard.set(1, forKey: Prefs.cacheHours)
            ScanCache.save("actiontest", "old")
            let cacheFile = home + "/Library/Caches/MoleUI/actiontest.txt"
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7_200)], ofItemAtPath: cacheFile)
            let expired = ScanCache.load("actiontest") == nil
            ScanCache.clear("actiontest")
            UserDefaults.standard.set(previousHours, forKey: Prefs.cacheHours)
            check("Settings: scan reuse window", expired, "a 2h-old scan is ignored with a 1h setting")

            line(failures == 0 ? "RESULT: all actions passed" : "RESULT: \(failures) failed")
            try? report.write(toFile: DiagnosticsDir.file("actiontest.txt"), atomically: true, encoding: .utf8)
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}
