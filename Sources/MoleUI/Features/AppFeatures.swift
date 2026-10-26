import AppKit
import CoreServices

private let home = NSHomeDirectory()

private func shortPath(_ path: String) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

private func appBundles() -> [String] {
    ["/Applications", home + "/Applications"].flatMap { root in
        DiskUsage.children(of: root).filter { $0.hasSuffix(".app") }
    }
}

/// Removes plain files and bundles: the user's own go through FileManager to
/// the Trash, root-owned ones through one administrator prompt.
private func trashMixed(_ files: [Finding]) async -> FindingOutcome {
    var outcome = FindingOutcome(message: "")

    let userOwned = files.filter { $0.paths.allSatisfy { $0.hasPrefix(home + "/") } }
    let systemOwned = files.filter { !userOwned.contains($0) }
    if !userOwned.isEmpty {
        let trashed = await FindingOutcome.trash(userOwned)
        outcome.succeeded += trashed.succeeded
        outcome.failures += trashed.failures
    }
    if !systemOwned.isEmpty {
        let safe = systemOwned.filter { $0.paths.allSatisfy { Trash.rejection(for: $0) == nil } }
        let moved = await Admin.moveToTrash(safe.flatMap(\.paths))
        if moved.ok { outcome.succeeded += safe.map(\.id) }
        else if moved.cancelled { outcome.cancelled = true }
        else { outcome.failures += safe.map { ($0.title, moved.output) } }
    }
    outcome.message = outcome.cancelled && outcome.succeeded.isEmpty
        ? "Cancelled — nothing was removed."
        : "Removed \(outcome.succeeded.count) to the Trash"
            + (outcome.failures.isEmpty ? "." : " · \(outcome.failures.count) failed.")
    return outcome
}

extension Features {

    // MARK: - Unused Apps

    /// Modification times of the places an app writes to whenever it runs.
    private static func activityDates(bundleID id: String) -> [Date?] {
        guard !id.isEmpty else { return [] }
        let library = home + "/Library"
        return [library + "/Preferences/\(id).plist",
                library + "/Containers/\(id)/Data/Library/Preferences/\(id).plist",
                library + "/Application Support/\(id)",
                library + "/Caches/\(id)",
                library + "/HTTPStorages/\(id)",
                library + "/Saved Application State/\(id).savedState"]
            .map { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
    }

    /// When an app was last used, and whether that makes it "unused" under the
    /// threshold in Settings. Powers the Uninstaller's Unused filter.
    static func usage(ofAppAt path: String, cutoff: Date) -> (unused: Bool, lastUsed: Date?) {
        // No bundle identifier means a shortcut, not an app — Steam's per-game
        // launcher shims are 16KB bundles with no identity — or a broken
        // install. Apple's own apps cannot be uninstalled.
        guard let id = Bundle(path: path)?.bundleIdentifier, !id.hasPrefix("com.apple.") else {
            return (false, nil)
        }
        let item = MDItemCreate(kCFAllocatorDefault, path as CFString)
        // Spotlight's "last opened" alone is not enough: an OS upgrade or a
        // re-index wipes it (on this Mac every app read "never opened, added
        // Oct 3"). An app that runs writes its preferences and its container,
        // so their modification times are evidence of use that survives a
        // Spotlight reset. The newest signal wins.
        let used = ([item.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }]
                    + activityDates(bundleID: id)).compactMap { $0 }.max()
        if let used { return (used < cutoff, used) }
        // No evidence of use at all: only unused once it has been installed long
        // enough to have been used. The bundle's Contents folder dates the
        // install; Spotlight's "date added" is reset along with everything else.
        let installed = (try? FileManager.default.attributesOfItem(atPath: path + "/Contents"))?[.modificationDate] as? Date
        return (installed.map { $0 < cutoff } ?? true, nil)
    }

    // MARK: - Extensions

    private static let addOnFolders: [(group: String, folder: String, suffix: String?)] = [
        ("Preference panes", "Library/PreferencePanes", ".prefPane"),
        ("Quick Look plug-ins", "Library/QuickLook", ".qlgenerator"),
        ("Spotlight importers", "Library/Spotlight", ".mdimporter"),
        ("Internet plug-ins", "Library/Internet Plug-Ins", nil),
        ("Screen savers", "Library/Screen Savers", nil),
        ("Audio plug-ins", "Library/Audio/Plug-Ins/Components", nil),
        ("Audio drivers", "Library/Audio/Plug-Ins/HAL", nil),
        ("Input methods", "Library/Input Methods", nil),
        ("Color pickers", "Library/ColorPickers", nil),
    ]

    static let extensions = Feature(
        pane: .extensions,
        emptyTitle: "No add-ons installed",
        emptyMessage: "No plug-ins or panes beyond what macOS ships with.",
        notice: "Third-party plug-ins and panes that hook into macOS. Startup and background items "
              + "are in Malware Removal, so nothing is listed twice. Items installed for all users ask "
              + "for your administrator password to remove.",
        action: FindingAction(title: "Remove", icon: "trash", destructive: true,
                              explanation: "Everything selected moves to the Trash.",
                              perform: { await trashMixed($0) }),
        scan: {
            var findings: [Finding] = []
            for entry in addOnFolders {
                for root in [home + "/", "/"] {
                    for path in DiskUsage.children(of: root + entry.folder)
                    where entry.suffix.map(path.hasSuffix) ?? true {
                        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                        findings.append(Finding(id: path, title: name, detail: shortPath(path),
                                                paths: [path], bytes: DiskUsage.size(of: path),
                                                group: entry.group,
                                                badges: root == "/" ? ["all users"] : ["you"],
                                                blocked: Trash.rejection(for: path)))
                    }
                }
            }
            // System extensions are managed by macOS itself; list them only.
            if let output = try? await MoleCLI.shared.tool("/usr/bin/systemextensionsctl", ["list"]) {
                for line in output.stdout.components(separatedBy: .newlines) where line.contains("\t") {
                    let columns = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard columns.count >= 5, columns[3].contains(".") else { continue }
                    findings.append(Finding(id: "sysext:" + columns[3], title: columns[4],
                                            detail: columns[3], group: "System extensions",
                                            badges: columns.last.map { [$0.replacingOccurrences(of: "[", with: "")
                                                .replacingOccurrences(of: "]", with: "")] } ?? [],
                                            blocked: "Remove the app that installed it, or manage it in "
                                                   + "System Settings › General › Login Items & Extensions"))
                }
            }
            return FindingScan(findings: findings)
        }
    )

    // MARK: - Updater

    private static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: DiskUsage.exists)
    }

    /// Homebrew refreshes its catalog before `outdated` — 53 seconds here. At
    /// most once an hour is plenty for an update check, and makes every other
    /// rescan near-instant.
    private static let brewEnv = ["HOMEBREW_AUTO_UPDATE_SECS": "3600", "HOMEBREW_NO_ENV_HINTS": "1"]

    private static func brewOutdated() async -> [Finding] {
        guard let brew = brewPath,
              let output = try? await MoleCLI.shared.tool(brew, ["outdated", "--json=v2", "--greedy"], env: brewEnv),
              let json = try? JSONSerialization.jsonObject(with: output.stdoutData) as? [String: Any]
        else { return [] }
        var findings: [Finding] = []
        for (key, kind) in [("casks", "cask"), ("formulae", "formula")] {
            for entry in json[key] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String else { continue }
                let installed = (entry["installed_versions"] as? [String])?.last
                    ?? entry["installed_versions"] as? String ?? "?"
                let current = entry["current_version"] as? String ?? "?"
                findings.append(Finding(id: "brew:\(kind):\(name)", title: name,
                                        detail: "\(installed) → \(current)",
                                        group: kind == "cask" ? "Homebrew apps" : "Homebrew packages",
                                        badges: [current], info: ["source": "brew", "kind": kind]))
            }
        }
        return findings
    }

    /// Apps that update themselves through Sparkle publish an appcast. Reading
    /// it directly finds updates for apps nothing else tracks.
    private static func sparkleUpdates() async -> [Finding] {
        let apps = appBundles().compactMap { path -> (String, String, String, URL)? in
            guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
                  let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
                  url.scheme == "https" else { return nil }
            let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "0"
            let build = info["CFBundleVersion"] as? String ?? version
            return (path, version, build, url)
        }
        // A request's timeoutInterval is only an *idle* timeout: a server that
        // trickles bytes can hold a fetch open indefinitely, and with it the
        // whole Updater scan. The resource timeout is the hard ceiling.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        return await withTaskGroup(of: Finding?.self) { group in
            for (path, version, build, url) in apps {
                group.addTask {
                    var request = URLRequest(url: url, timeoutInterval: 8)
                    request.setValue("MoleUI update check", forHTTPHeaderField: "User-Agent")
                    guard let (data, _) = try? await session.data(for: request) else { return nil }
                    let latest = AppcastParser.latest(data)
                    guard let newest = latest.short ?? latest.build else { return nil }
                    let installed = latest.short != nil ? version : build
                    guard newest.compare(installed, options: .numeric) == .orderedDescending else { return nil }
                    let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    return Finding(id: "sparkle:" + path, title: name, detail: "\(version) → \(newest)",
                                   paths: [path], group: "Apps that update themselves",
                                   badges: [newest], info: ["source": "sparkle"])
                }
            }
            var results: [Finding] = []
            for await finding in group { if let finding { results.append(finding) } }
            return results
        }
    }

    private static func macOSUpdates() async -> [Finding] {
        // `softwareupdate -l` asks Apple's servers and can take half a minute;
        // it runs alongside the other checks, not after them.
        // Capped: it asks Apple's servers and has no deadline of its own.
        // Cancelling the task terminates the child (see MoleCLI.execute).
        let check = Task { try await MoleCLI.shared.tool("/usr/sbin/softwareupdate", ["-l"]) }
        let watchdog = Task { try await Task.sleep(nanoseconds: 60_000_000_000); check.cancel() }
        defer { watchdog.cancel() }
        guard let output = try? await check.value else { return [] }
        return output.stdout.components(separatedBy: .newlines)
            .filter { $0.contains("* Label:") }
            .map { line in
                let label = line.components(separatedBy: "Label:").last?.trimmingCharacters(in: .whitespaces) ?? line
                return Finding(id: "macos:" + label, title: label, group: "macOS",
                               blocked: "Install from System Settings › General › Software Update",
                               info: ["source": "macos"])
            }
    }

    static let updater = Feature(
        pane: .updater,
        emptyTitle: "Everything is up to date",
        emptyMessage: "No updates for Homebrew packages, self-updating apps or macOS.",
        notice: "Homebrew items update in place. Apps that update themselves open so their own "
              + "updater can take over. App Store apps update from the App Store.",
        action: FindingAction(title: "Update", icon: "arrow.down.circle", destructive: false,
                              explanation: "Homebrew upgrades the selected packages; self-updating apps "
                                         + "are opened so they can install their update.",
                              perform: { findings in
                                  var outcome = FindingOutcome(message: "")
                                  let casks = findings.filter { $0.info["kind"] == "cask" }.map(\.title)
                                  let formulae = findings.filter { $0.info["kind"] == "formula" }.map(\.title)
                                  if let brew = brewPath {
                                      for (names, args) in [(casks, ["upgrade", "--cask"]), (formulae, ["upgrade"])]
                                      where !names.isEmpty {
                                          let result = try? await MoleCLI.shared.tool(brew, args + names,
                                                                                      env: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
                                          let ids = findings.filter { names.contains($0.title) && $0.info["source"] == "brew" }
                                          if result?.exitCode == 0 { outcome.succeeded += ids.map(\.id) }
                                          else {
                                              // Homebrew ends its output with boilerplate
                                              // ("Read the above document…"), so the last
                                              // lines say nothing. The `Error:` lines are
                                              // the cause; "cannot create executables" is
                                              // the usual underlying one on a broken toolchain.
                                              let lines = ((result?.stderr ?? "") + "\n" + (result?.stdout ?? ""))
                                                  .components(separatedBy: .newlines)
                                                  .map { $0.trimmingCharacters(in: .whitespaces) }
                                              let cause = lines.first { $0.contains("cannot create executables") }
                                              let error = lines.first { $0.hasPrefix("Error:") }
                                              let intel = lines.contains { $0.contains("macOS on Intel x86_64") }
                                              let tail = [error, cause].compactMap { $0 }.joined(separator: " — ")
                                                  + (intel ? " (this Homebrew is the Intel build, which has no "
                                                           + "packages for macOS 27 — reinstall Homebrew for Apple silicon)" : "")
                                              outcome.failures += ids.map { ($0.title, tail.isEmpty ? "brew upgrade failed" : tail) }
                                          }
                                      }
                                  }
                                  for finding in findings where finding.info["source"] == "sparkle" {
                                      if let path = finding.paths.first {
                                          await MainActor.run { _ = NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                                          outcome.succeeded.append(finding.id)
                                      }
                                  }
                                  outcome.message = "Updated or opened \(outcome.succeeded.count)"
                                      + (outcome.failures.isEmpty ? "." : " · \(outcome.failures.count) failed.")
                                  return outcome
                              }),
        scan: {
            async let brew = brewOutdated()
            async let sparkle = sparkleUpdates()
            async let system = macOSUpdates()
            let findings = await brew + sparkle + system
            var notes: [String] = []
            if brewPath == nil { notes.append("Homebrew is not installed, so packages are not checked.") }
            // An Intel Homebrew under Rosetta on Apple silicon has no packages for
            // macOS 27, so every upgrade compiles from source — and fails without
            // a working compiler. Say so before the user clicks, not after.
            var arm64: Int32 = 0
            var size = MemoryLayout<Int32>.size
            sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
            if arm64 == 1, brewPath == "/usr/local/bin/brew",
               ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                notes.append("This Homebrew is the Intel build running under Rosetta. Homebrew no longer "
                           + "ships packages for it on macOS 27, so Homebrew upgrades here will likely fail. "
                           + "Reinstalling Homebrew for Apple silicon (in /opt/homebrew) fixes it.")
            }
            if !DiskUsage.exists("/usr/local/bin/mas") && !DiskUsage.exists("/opt/homebrew/bin/mas") {
                notes.append("App Store apps are not checked — `brew install mas` adds them.")
            }
            return FindingScan(findings: findings, notes: notes)
        }
    )
}

/// Pulls the newest version out of a Sparkle appcast. Versions appear either
/// as `<sparkle:shortVersionString>` elements or as attributes on
/// `<enclosure>`, depending on the feed's age; both are handled.
final class AppcastParser: NSObject, XMLParserDelegate {
    private var shorts: [String] = []
    private var builds: [String] = []
    private var element = ""
    private var text = ""

    static func latest(_ data: Data) -> (short: String?, build: String?) {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        func newest(_ list: [String]) -> String? {
            list.max { $0.compare($1, options: .numeric) == .orderedAscending }
        }
        return (newest(delegate.shorts), newest(delegate.builds))
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        element = qualifiedName ?? name
        text = ""
        if element == "enclosure" {
            if let short = attributes["sparkle:shortVersionString"] { shorts.append(short) }
            if let build = attributes["sparkle:version"] { builds.append(build) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch qualifiedName ?? name {
        case "sparkle:shortVersionString": if !value.isEmpty { shorts.append(value) }
        case "sparkle:version":            if !value.isEmpty { builds.append(value) }
        default: break
        }
        text = ""
    }
}
