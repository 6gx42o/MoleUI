import Foundation

private let home = NSHomeDirectory()

private func shortPath(_ path: String) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

/// Permanent deletion, used only by Trash Bins and Shredder — the two panes
/// whose whole purpose is to delete without a way back. Everything else in the
/// app trashes.
enum PermanentDelete {
    /// Trash Bins may only ever delete things that are already in a Trash.
    static func isInsideATrash(_ path: String) -> Bool {
        let standard = URL(fileURLWithPath: path).standardized.path
        if standard.hasPrefix(home + "/.Trash/") { return true }
        let parts = standard.split(separator: "/")
        // /Volumes/<name>/.Trashes/<uid>/<item>
        return parts.count >= 5 && parts[0] == "Volumes" && parts[2] == ".Trashes"
    }

    /// `removeItem`, then — the way Finder's Empty Trash does — unlock and retry.
    ///
    /// A plain `removeItem` gives up on the first read-only folder or locked
    /// file. The Trash is full of them: Homebrew installs Go's module cache and
    /// several toolchains read-only, and anything locked in Finder carries the
    /// `uchg` flag. Removing a folder's contents needs write permission on the
    /// folder itself, so the retry makes every folder writable for its owner and
    /// clears the user-settable lock flags first.
    static func forceRemove(_ path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            unlock(path)
            try FileManager.default.removeItem(atPath: path)
        }
    }

    /// Pre-order walk without following symlinks: each folder is made writable
    /// before its children are visited, so a 0555 parent cannot block the rest.
    private static func unlock(_ path: String) {
        path.withCString { cPath in
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
            defer { free(paths[0]) }
            guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
            defer { fts_close(stream) }
            while let entry = fts_read(stream) {
                let info = Int32(entry.pointee.fts_info)
                guard info != FTS_DP, let stat = entry.pointee.fts_statp else { continue }
                let name = entry.pointee.fts_path
                // User flags only (uchg, uappnd): the system ones need root,
                // which is the admin fallback's job.
                let userFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
                if stat.pointee.st_flags & userFlags != 0 {
                    lchflags(name, stat.pointee.st_flags & ~userFlags)
                }
                if info == FTS_D || info == FTS_DNR {
                    chmod(name, (stat.pointee.st_mode & 0o7777) | S_IRWXU)
                }
            }
        }
    }

    /// Trash Bins' action. Unlock-and-retry handles the user's own files; what
    /// is still refused after that is owned by another user or by root (an
    /// installer's leftovers, items moved in with administrator rights), and
    /// gets one macOS password prompt — strictly for paths inside a Trash.
    static func emptyTrash(_ findings: [Finding]) async -> FindingOutcome {
        let insideTrash: (String) -> String? = { isInsideATrash($0) ? nil : "not inside a Trash folder" }
        var outcome = await Task.detached { remove(findings, allowed: insideTrash) }.value
        let stuck = findings.filter { finding in
            outcome.failures.contains { $0.id == finding.title }
                && finding.paths.allSatisfy { isInsideATrash($0) && FileManager.default.fileExists(atPath: $0) }
        }
        guard !stuck.isEmpty else { return outcome }

        // `--` so no path can be read as an option; each path standardized and
        // single-quoted; the guard above already refused anything outside a Trash.
        let paths = stuck.flatMap(\.paths).map { URL(fileURLWithPath: $0).standardized.path }
        let quoted = paths.map(Shell.quote).joined(separator: " ")
        let result = await Admin.run("/usr/bin/chflags -R nouchg,noschg \(quoted) 2>/dev/null; /bin/rm -rf -- \(quoted)")
        let removed = stuck.filter { $0.paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) } }
        if !removed.isEmpty {
            let titles = Set(removed.map(\.title))
            outcome.failures.removeAll { titles.contains($0.id) }
            outcome.succeeded += removed.map(\.id)
        }
        let freed = findings.filter { outcome.succeeded.contains($0.id) }.compactMap(\.bytes).reduce(0, +)
        outcome.message = (result.cancelled ? "Some items need your password — cancelled. " : "")
            + "Permanently deleted \(outcome.succeeded.count)"
            + (freed > 0 ? " (\(formatBytesDecimal(freed)) freed)" : "")
            + (outcome.failures.isEmpty ? "." : " · \(outcome.failures.count) failed.")
        return outcome
    }

    static func remove(_ findings: [Finding],
                       allowed: (String) -> String?) -> FindingOutcome {
        var outcome = FindingOutcome(message: "")
        var bytes: Int64 = 0
        for finding in findings {
            var failure: String?
            for path in finding.paths {
                if let refusal = allowed(path) { failure = refusal; break }
                do { try forceRemove(path) }
                catch { failure = error.localizedDescription; break }
            }
            if let failure { outcome.failures.append((finding.title, failure)) }
            else { outcome.succeeded.append(finding.id); bytes += finding.bytes ?? 0 }
        }
        outcome.message = "Permanently deleted \(outcome.succeeded.count)"
            + (bytes > 0 ? " (\(formatBytesDecimal(bytes)) freed)" : "")
            + (outcome.failures.isEmpty ? "." : " · \(outcome.failures.count) failed.")
        return outcome
    }
}

extension Features {

    // MARK: Mail Attachments

    static func mailAttachmentScan() async throws -> FindingScan {
            let mailRunning = await Apps.runningBundleIDs().contains("com.apple.mail")
            let blocked = mailRunning ? "Quit Mail first — it holds these files open" : nil
            var findings: [Finding] = []

            // Attachments opened from Mail — always safe, these are copies.
            let downloads = home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
            let opened = DiskUsage.children(of: downloads)
            let openedSizes = await DiskUsage.sizes(of: opened)
            for path in opened {
                let name = DiskUsage.children(of: path).first.map { ($0 as NSString).lastPathComponent }
                findings.append(Finding(id: path,
                                        title: name ?? (path as NSString).lastPathComponent,
                                        detail: shortPath(path), paths: [path],
                                        bytes: openedSizes[path], group: "Opened from Mail",
                                        blocked: blocked))
            }

            // The mail store's extracted attachments. Walk only the
            // `Attachments` folders — skipping every `Messages` folder, which
            // holds the .emlx bodies and is most of the store by file count.
            let store = home + "/Library/Mail"
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey,
                                          .contentModificationDateKey]
            if let walker = fm.enumerator(at: URL(fileURLWithPath: store),
                                          includingPropertiesForKeys: keys,
                                          options: [.skipsPackageDescendants]) {
                while let url = walker.nextObject() as? URL {
                    try Task.checkCancellation()
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    if values?.isDirectory == true {
                        if url.lastPathComponent == "Messages" { walker.skipDescendants() }
                        continue
                    }
                    guard url.path.contains("/Attachments/"),
                          url.lastPathComponent != ".DS_Store" else { continue }
                    let bytes = Int64(values?.totalFileAllocatedSize ?? 0)
                    guard bytes >= 4_096 else { continue }
                    findings.append(Finding(id: url.path, title: url.lastPathComponent,
                                            detail: shortPath(url.deletingLastPathComponent().path),
                                            paths: [url.path], bytes: bytes,
                                            date: values?.contentModificationDate,
                                            dateLabel: "received", group: "Saved in mailboxes",
                                            blocked: blocked))
                }
            }
            var notes: [String] = []
            if mailRunning { notes.append("Mail is open. Quit it to remove attachments.") }
            return FindingScan(findings: findings, notes: notes)
        }

    // MARK: Trash Bins

    static let trashBins = Feature(
        pane: .trashBins,
        emptyTitle: "The Trash is empty",
        emptyMessage: "Nothing in your Trash or on any connected drive's Trash.",
        notice: "Deleting from here is permanent — it is the one step the rest of MoleUI never "
              + "takes for you. Review the list first.",
        action: FindingAction(title: "Delete Permanently", icon: "xmark.bin", destructive: true,
                              explanation: "This cannot be undone. The items are erased from the "
                                         + "Trash, not moved anywhere.",
                              perform: { await PermanentDelete.emptyTrash($0) }),
        autoSelect: (title: "Select everything", pick: { Set($0.map(\.id)) }),
        cacheable: false,
        scan: {
            var bins: [(name: String, directory: String)] = [("Your Trash", home + "/.Trash")]
            let uid = getuid()
            for volume in DiskUsage.children(of: "/Volumes") {
                let trash = volume + "/.Trashes/\(uid)"
                if DiskUsage.exists(trash) {
                    bins.append(("\((volume as NSString).lastPathComponent) Trash", trash))
                }
            }
            var findings: [Finding] = []
            for bin in bins {
                let items = DiskUsage.children(of: bin.directory)
                let sizes = await DiskUsage.sizes(of: items)
                for path in items {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                    findings.append(Finding(id: path, title: (path as NSString).lastPathComponent,
                                            detail: bin.name, paths: [path], bytes: sizes[path],
                                            date: attributes?[.modificationDate] as? Date,
                                            dateLabel: "trashed", group: bin.name))
                }
            }
            return FindingScan(findings: findings)
        }
    )

    // MARK: Disk Hogs

    private struct Hog {
        var group: String
        var title: String
        var path: String
        var why: String
        var blocked: String? = nil
        var warning = false
    }

    private static func hogs() -> [Hog] {
        let dev = home + "/Library/Developer"
        var list: [Hog] = [
            Hog(group: "Developer", title: "Xcode DerivedData", path: dev + "/Xcode/DerivedData",
                why: "Build products. Xcode rebuilds them the next time you build."),
            Hog(group: "Developer", title: "Xcode Archives", path: dev + "/Xcode/Archives",
                why: "Shipped builds. Needed to symbolicate crash reports for those versions.",
                warning: true),
            Hog(group: "Developer", title: "Simulator caches", path: dev + "/CoreSimulator/Caches",
                why: "Regenerated by the simulator on demand."),
            Hog(group: "Developer", title: "Simulator devices", path: dev + "/CoreSimulator/Devices",
                why: "Every simulator's data.",
                blocked: "Delete simulators in Xcode › Devices, or run `xcrun simctl delete unavailable`"),
            Hog(group: "Developer", title: "Android system images",
                path: home + "/Library/Android/sdk/system-images",
                why: "Emulator images. Reinstall from Android Studio's SDK Manager."),
            Hog(group: "Developer", title: "Android emulators", path: home + "/.android/avd",
                why: "Virtual devices and their data.", warning: true),
            Hog(group: "Developer", title: "Docker disk image",
                path: home + "/Library/Containers/com.docker.docker/Data/vms",
                why: "Every image, container and volume.",
                blocked: "Use Docker Desktop › Troubleshoot › Clean / Purge data"),

            Hog(group: "Package caches", title: "Homebrew downloads", path: home + "/Library/Caches/Homebrew",
                why: "Downloaded bottles and casks. Re-fetched if needed."),
            Hog(group: "Package caches", title: "npm cache", path: home + "/.npm/_cacache",
                why: "Re-downloaded on the next install."),
            Hog(group: "Package caches", title: "Yarn cache", path: home + "/Library/Caches/Yarn",
                why: "Re-downloaded on the next install."),
            Hog(group: "Package caches", title: "pnpm store", path: home + "/Library/pnpm/store",
                why: "Re-downloaded on the next install."),
            Hog(group: "Package caches", title: "pip cache", path: home + "/Library/Caches/pip",
                why: "Re-downloaded on the next install."),
            Hog(group: "Package caches", title: "Gradle caches", path: home + "/.gradle/caches",
                why: "Re-downloaded on the next build."),
            Hog(group: "Package caches", title: "Maven repository", path: home + "/.m2/repository",
                why: "Re-downloaded on the next build."),
            Hog(group: "Package caches", title: "Cargo registry", path: home + "/.cargo/registry",
                why: "Re-downloaded on the next build."),
            Hog(group: "Package caches", title: "Go module cache", path: home + "/go/pkg/mod",
                why: "Re-downloaded on the next build."),
            Hog(group: "Package caches", title: "CocoaPods cache", path: home + "/Library/Caches/CocoaPods",
                why: "Re-downloaded on the next pod install."),
            Hog(group: "Package caches", title: "SwiftPM cache",
                path: home + "/Library/Caches/org.swift.swiftpm",
                why: "Re-downloaded on the next resolve."),

            Hog(group: "AI models", title: "Hugging Face cache", path: home + "/.cache/huggingface",
                why: "Downloaded models. Anything removed is downloaded again when used.", warning: true),
            Hog(group: "AI models", title: "Ollama models", path: home + "/.ollama/models",
                why: "Pulled models. `ollama pull` fetches them again.", warning: true),
            Hog(group: "AI models", title: "LM Studio models", path: home + "/.lmstudio/models",
                why: "Downloaded models.", warning: true),

            Hog(group: "Virtual machines", title: "Parallels", path: home + "/Parallels",
                why: "Virtual machines — your data inside them goes too.", warning: true),
            Hog(group: "Virtual machines", title: "UTM",
                path: home + "/Library/Containers/com.utmapp.UTM/Data/Documents",
                why: "Virtual machines — your data inside them goes too.", warning: true),

            Hog(group: "Media libraries", title: "Photos library",
                path: home + "/Pictures/Photos Library.photoslibrary", why: "Your photos.",
                blocked: "Manage in Photos — removing files inside a library corrupts it"),
            Hog(group: "Media libraries", title: "Music media", path: home + "/Music/Music/Media",
                why: "Downloaded songs and videos.", blocked: "Remove downloads in the Music app"),
            Hog(group: "Media libraries", title: "Messages attachments",
                path: home + "/Library/Messages/Attachments", why: "Photos and files from chats.",
                blocked: "Use Messages › Settings › Keep messages, or System Settings › Storage"),
            Hog(group: "Media libraries", title: "GarageBand & Logic sounds",
                path: "/Library/Application Support/GarageBand", why: "Instrument and loop packs.",
                blocked: "Remove sound packs from GarageBand › Sound Library"),

            Hog(group: "Apps", title: "Steam games",
                path: home + "/Library/Application Support/Steam/steamapps",
                why: "Installed games.", blocked: "Uninstall games from Steam"),
        ]

        // One row per iPhone/iPad backup, named after the device.
        let backups = home + "/Library/Application Support/MobileSync/Backup"
        for path in DiskUsage.children(of: backups) {
            let info = NSDictionary(contentsOfFile: path + "/Info.plist")
            let device = info?["Device Name"] as? String ?? (path as NSString).lastPathComponent
            let when = (info?["Last Backup Date"] as? Date).map { " · backed up \(relative($0))" } ?? ""
            list.append(Hog(group: "Device backups", title: "\(device) backup", path: path,
                            why: "A local iPhone/iPad backup\(when). Remove only if it is in iCloud too.",
                            warning: true))
        }
        // Per-version device support files, re-copied when a device connects.
        for kind in ["iOS", "watchOS", "tvOS", "visionOS"] {
            for path in DiskUsage.children(of: dev + "/Xcode/\(kind) DeviceSupport") {
                list.append(Hog(group: "Developer",
                                title: "\(kind) DeviceSupport \((path as NSString).lastPathComponent)",
                                path: path,
                                why: "Debug symbols. Copied again when that device connects."))
            }
        }
        return list
    }

    static func diskHogScan() async throws -> FindingScan {
            let candidates = hogs().filter { DiskUsage.exists($0.path) }
            let sizes = await DiskUsage.sizes(of: candidates.map(\.path))
            let findings = candidates.compactMap { hog -> Finding? in
                let bytes = sizes[hog.path] ?? 0
                guard bytes >= 10_000_000 else { return nil }     // ignore anything under 10MB
                return Finding(id: hog.path, title: hog.title,
                               detail: hog.why + "  " + shortPath(hog.path),
                               paths: [hog.path], bytes: bytes, group: hog.group,
                               tone: hog.warning ? .warning : .normal,
                               blocked: hog.blocked ?? Trash.rejection(for: hog.path))
            }
            return FindingScan(findings: findings)
        }
}

/// Namespace for every list feature's definition.
enum Features {}

// MARK: - Combined features
//
// Several CleanMyMac sections are the same job — list things, move the picked
// ones to the Trash — over different sources. Each combined pane runs its
// sources concurrently and shows them as groups in one list, so there is one
// place to look and one button to press.

extension Features {

    /// `mo purge` / `mo installer` mapped into rows. Empty with a note when
    /// Mole is not installed, so the rest of the pane still works.
    private static func moleArtifacts(installers: Bool) async -> (rows: [Finding], note: String?) {
        guard MoleCLI.shared.isInstalled else {
            return ([], "Install Mole (`brew install mole`) to include "
                      + (installers ? "installers." : "project build folders."))
        }
        let args = installers ? ["installer", "--dry-run", "--debug"] : ["purge", "--dry-run"]
        guard let output = try? await MoleCLI.shared.run(args) else { return ([], nil) }
        let result = installers ? ArtifactList.parseInstallerDebug(output.stderr)
                                : ArtifactList.parsePurge(output.stdout)
        let rows = result.items.compactMap { item -> Finding? in
            guard let path = item.path else { return nil }
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return Finding(id: path,
                           title: installers ? item.name : "\(parent)/\(item.name)",
                           detail: shortPath((path as NSString).deletingLastPathComponent),
                           paths: [path], bytes: item.bytes,
                           group: installers ? "Installers" : "Project build folders",
                           badges: installers ? [item.location].compactMap { $0 } : [],
                           blocked: Trash.rejection(for: path))
        }
        return (rows, nil)
    }

    static let leftovers = Feature(
        pane: .leftovers,
        emptyTitle: "Nothing left behind",
        emptyMessage: "No leftover installers, old project build folders or saved mail attachments.",
        notice: "Installers you already used, build folders (node_modules, venv, .build…) from "
              + "projects, and local copies of mail attachments. Build folders are recreated the next "
              + "time you build; Mail re-downloads attachments from the server.",
        action: FindingAction(title: "Move to Trash", icon: "trash", destructive: true,
                              explanation: "Moved to the Trash, not deleted.",
                              perform: { await FindingOutcome.trash($0) }),
        scan: {
            async let installers = moleArtifacts(installers: true)
            async let projects = moleArtifacts(installers: false)
            async let mail = mailAttachmentScan()
            let mailScan = try await mail
            let (installerRows, installerNote) = await installers
            let (projectRows, projectNote) = await projects
            return FindingScan(findings: installerRows + projectRows + mailScan.findings.map {
                                   var row = $0; row.group = "Mail attachments"; return row
                               },
                               notes: [installerNote, projectNote].compactMap { $0 } + mailScan.notes)
        }
    )
}
