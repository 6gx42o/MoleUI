import Foundation
import SQLite3

private let home = NSHomeDirectory()
private let appSupport = home + "/Library/Application Support"

private func shortPath(_ path: String) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

private func fileBytes(_ paths: [String]) -> Int64 {
    paths.reduce(0) { total, path in total + DiskUsage.size(of: path) }
}

extension Features {

    // MARK: - Malware Removal

    /// Substrings of launchd labels, program paths and app names used by adware
    /// and scareware families that have been widespread on the Mac. Matching
    /// one is a strong signal; not matching proves nothing, which the pane says.
    static let adwareMarkers = [
        "genieo", "vsearch", "conduit", "pirrit", "bundlore", "shlayer", "adload",
        "maxofferdeal", "mackeeper", "advancedmaccleaner", "mac auto fixer", "macautofixer",
        "searchbaron", "search baron", "spigot", "installmac", "operatorsearch",
        "chumsearch", "searchmine", "mughthesec", "crossrider", "yontoo", "safefinder",
        "elmedia-downloader", "mysearch", "smart mac booster", "mac tonic", "mactonic",
        "applicationdaemon", "trovi", "weknow", "launchpageplus",
    ]

    static func adwareMatch(_ text: String) -> String? {
        let lowered = text.lowercased()
        return adwareMarkers.first { lowered.contains($0) }
    }

    static let malware = Feature(
        pane: .malware,
        emptyTitle: "No background items",
        emptyMessage: "Nothing is registered to start automatically.",
        notice: "A heuristic check of everything set to launch automatically: code signatures, "
              + "where programs live, and names used by known adware families. It is not an "
              + "antivirus — macOS's own XProtect handles signature-based detection. Signed items "
              + "from identified developers are listed so you can see what runs, not because "
              + "they are a threat.",
        action: FindingAction(title: "Remove", icon: "shield.slash", destructive: true,
                              explanation: "Each job is unloaded so it stops now, then its launch "
                                         + "file — and for suspicious items, the program itself — "
                                         + "moves to the Trash. System-wide items ask for your "
                                         + "administrator password through macOS.",
                              perform: { await LaunchItem.remove($0) }),
        autoSelect: (title: "Select suspicious", pick: { rows in
            Set(rows.filter { $0.info["severity"] == "high" }.map(\.id))
        }),
        cacheable: false,
        scan: {
            async let status = protectionStatus()
            let items = LaunchItem.scanAll()
            var findings: [Finding] = []

            for item in items {
                try Task.checkCancellation()
                var reasons: [String] = []
                var severity = "none"
                let program = item.program ?? ""
                let haystack = item.label + " " + program + " " + item.arguments.joined(separator: " ")

                if let marker = adwareMatch(haystack) {
                    reasons.append("matches the \(marker) adware family"); severity = "high"
                }
                // Location only counts against code nobody vouches for. A
                // developer-signed helper in /Users/Shared (GOG does this) is
                // odd but legitimate; an unsigned one there is a classic
                // dropper pattern. Temp folders are suspicious either way.
                let signedByDeveloper: Bool = {
                    if case .developer = item.signature { return true }
                    return item.signature == .apple
                }()
                let inTemp = ["/tmp/", "/private/tmp/", "/private/var/tmp/"].contains { program.hasPrefix($0) }
                // Hidden folders inside ~/Library are where adware hides
                // (~/Library/Application Support/.xyz). Hidden folders at the top
                // of home — ~/.local, ~/.cargo, ~/.nvm — are ordinary dev tooling.
                let hiddenInLibrary = program.hasPrefix(home + "/Library/")
                    && program.split(separator: "/").dropLast().contains { $0.hasPrefix(".") }
                let shared = program.hasPrefix("/Users/Shared/")
                if inTemp || ((hiddenInLibrary || shared) && !signedByDeveloper) {
                    reasons.append(inTemp ? "runs from a temporary folder"
                                          : (shared ? "unsigned program in /Users/Shared"
                                                    : "runs from a hidden folder in Library"))
                    severity = "high"
                }
                let shellDownload = item.arguments.contains { $0.hasSuffix("sh") || $0 == "-c" }
                    && item.arguments.contains { $0.contains("curl ") || $0.contains("base64") }
                if shellDownload {
                    reasons.append("downloads or decodes code at launch"); severity = "high"
                }
                switch item.signature {
                case .unsigned:
                    reasons.append("program is unsigned"); if severity == "none" { severity = "medium" }
                case .invalid:
                    reasons.append("signature no longer matches the program"); severity = "high"
                case .adHoc:
                    reasons.append("signed by nobody identifiable"); if severity == "none" { severity = "medium" }
                case .missing:
                    reasons.append(item.isPlaceholder ? "empty placeholder — runs nothing"
                                                      : "left behind — its program no longer exists")
                    if severity == "none" { severity = "low" }
                default: break
                }

                let group: String
                let tone: Finding.Tone
                switch severity {
                case "high":   group = "Suspicious";        tone = .warning
                case "medium": group = "Worth a look";      tone = .warning
                case "low":    group = "Leftovers";         tone = .normal
                default:       group = "Identified developers"; tone = .good
                }
                var paths = [item.plist]
                let removeProgram = severity == "high" && !program.isEmpty
                    && !program.hasPrefix("/System/") && !program.hasPrefix("/usr/")
                    && !program.hasPrefix("/Applications/") && Trash.rejection(for: program) == nil
                    // Only a real executable: a hostile plist could name one of
                    // your documents as its "program".
                    && FileManager.default.isExecutableFile(atPath: program)
                if removeProgram { paths.append(program) }

                findings.append(Finding(
                    id: item.plist, title: item.label,
                    detail: (reasons.isEmpty ? item.signature.label : reasons.joined(separator: "; "))
                          + " · " + shortPath(program.isEmpty ? item.plist : program),
                    paths: paths, group: group,
                    badges: [item.domain == .userAgent ? "you" : (item.domain == .agent ? "all users" : "system")],
                    tone: tone,
                    info: ["severity": severity, "domain": item.domain.rawValue,
                           "removeProgram": removeProgram ? "1" : "0"]))
            }

            // Whole apps from the same families.
            for root in ["/Applications", home + "/Applications", appSupport] {
                for path in DiskUsage.children(of: root) {
                    let name = (path as NSString).lastPathComponent
                    guard let marker = adwareMatch(name) else { continue }
                    findings.append(Finding(id: path, title: name,
                                            detail: "matches the \(marker) family · \(shortPath(path))",
                                            paths: [path], bytes: DiskUsage.size(of: path),
                                            group: "Suspicious", badges: ["app"], tone: .warning,
                                            info: ["severity": "high", "domain": "file"]))
                }
            }
            // `LaunchItem.remove` would try to unload a plain file; route those
            // straight to the Trash instead by marking them as user agents with
            // nothing to unload — launchctl simply reports it is not loaded.
            findings = findings.map { finding in
                var copy = finding
                if copy.info["domain"] == "file" { copy.info["domain"] = LaunchItem.Domain.userAgent.rawValue }
                return copy
            }
            let suspicious = findings.filter { $0.info["severity"] == "high" }.count
            return FindingScan(findings: findings,
                               notes: [await status, suspicious == 0
                                       ? "No suspicious background items found."
                                       : "\(suspicious) item\(suspicious == 1 ? "" : "s") look suspicious."])
        }
    )

    /// One line summarising the Mac's built-in protections, each read from the
    /// tool that owns it. All five run concurrently; the slowest is ~100ms.
    static func protectionStatus() async -> String {
        @Sendable func read(_ tool: String, _ args: [String]) async -> String {
            let output = try? await MoleCLI.shared.tool(tool, args)
            return ((output?.stdout ?? "") + (output?.stderr ?? "")).lowercased()
        }
        async let gatekeeper = read("/usr/sbin/spctl", ["--status"])
        async let sip = read("/usr/bin/csrutil", ["status"])
        async let fileVault = read("/usr/bin/fdesetup", ["status"])
        async let firewall = read("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        let xprotect = NSDictionary(contentsOfFile:
            "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist")?[
                "CFBundleShortVersionString"] as? String

        func mark(_ on: Bool, _ name: String) -> String { (on ? "✓ " : "✗ ") + name }
        return [
            mark(await gatekeeper.contains("enabled"), "Gatekeeper"),
            mark(await sip.contains("enabled"), "System Integrity Protection"),
            mark(await fileVault.contains("is on"), "FileVault"),
            mark(await firewall.contains("enabled"), "Firewall"),
            xprotect.map { "XProtect \($0)" } ?? "XProtect version unknown",
        ].joined(separator: "   ")
    }

    // MARK: - Privacy

    private struct Browser {
        var name: String
        var bundleID: String
        var profilesRoot: String
        var cacheRoot: String?
        var kind: Kind
        enum Kind { case chromium, safari, firefox }
    }

    private static let browsers: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", profilesRoot: home + "/Library/Safari",
                cacheRoot: nil, kind: .safari),
        Browser(name: "Chrome", bundleID: "com.google.Chrome", profilesRoot: appSupport + "/Google/Chrome",
                cacheRoot: home + "/Library/Caches/Google/Chrome", kind: .chromium),
        Browser(name: "Brave", bundleID: "com.brave.Browser",
                profilesRoot: appSupport + "/BraveSoftware/Brave-Browser",
                cacheRoot: home + "/Library/Caches/BraveSoftware/Brave-Browser", kind: .chromium),
        Browser(name: "Edge", bundleID: "com.microsoft.edgemac", profilesRoot: appSupport + "/Microsoft Edge",
                cacheRoot: home + "/Library/Caches/Microsoft Edge", kind: .chromium),
        Browser(name: "Chromium", bundleID: "org.chromium.Chromium", profilesRoot: appSupport + "/Chromium",
                cacheRoot: home + "/Library/Caches/Chromium", kind: .chromium),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", profilesRoot: appSupport + "/Arc/User Data",
                cacheRoot: home + "/Library/Caches/Arc/User Data", kind: .chromium),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", profilesRoot: appSupport + "/Vivaldi",
                cacheRoot: home + "/Library/Caches/Vivaldi", kind: .chromium),
        Browser(name: "Opera", bundleID: "com.operasoftware.Opera",
                profilesRoot: appSupport + "/com.operasoftware.Opera",
                cacheRoot: home + "/Library/Caches/com.operasoftware.Opera", kind: .chromium),
        Browser(name: "Firefox", bundleID: "org.mozilla.firefox",
                profilesRoot: appSupport + "/Firefox/Profiles",
                cacheRoot: home + "/Library/Caches/Firefox/Profiles", kind: .firefox),
    ]

    /// Chromium profile folders: "Default", "Profile 1", "Profile 2"…
    private static func chromiumProfiles(_ root: String) -> [String] {
        DiskUsage.children(of: root).filter {
            let name = ($0 as NSString).lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ")
        }
    }

    private static func privacyRows(_ browser: Browser, running: Bool) -> [Finding] {
        let blocked = running ? "Quit \(browser.name) first — deleting a live database corrupts it" : nil
        var rows: [Finding] = []

        func add(_ title: String, _ profile: String?, _ candidates: [String], warning: Bool = false,
                 detail: String? = nil, blockedReason: String? = nil) {
            let existing = candidates.filter(DiskUsage.exists)
            guard !existing.isEmpty else { return }
            let label = profile.map { "\(title) — \($0)" } ?? title
            rows.append(Finding(id: browser.name + ":" + label + ":" + existing[0],
                                title: label, detail: detail ?? shortPath(existing[0]),
                                paths: existing, bytes: fileBytes(existing),
                                group: browser.name, tone: warning ? .warning : .normal,
                                blocked: blockedReason ?? blocked))
        }

        switch browser.kind {
        case .chromium:
            let profiles = chromiumProfiles(browser.profilesRoot)
            for profile in profiles {
                let name = (profile as NSString).lastPathComponent
                let label = profiles.count > 1 ? name : nil
                add("Browsing history", label, ["History", "History-journal", "Visited Links"].map { profile + "/" + $0 })
                add("Cookies", label, ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]
                        .map { profile + "/" + $0 }, detail: "Signs you out of websites")
                add("Autofill & form data", label, ["Web Data", "Web Data-journal"].map { profile + "/" + $0 },
                    warning: true, detail: "Saved addresses and card details. Saved passwords are not touched.")
                add("Top sites & shortcuts", label, ["Top Sites", "Top Sites-journal", "Shortcuts",
                                                     "Shortcuts-journal"].map { profile + "/" + $0 })
                add("Open tabs & sessions", label, ["Sessions", "Current Session", "Current Tabs",
                                                    "Last Session", "Last Tabs"].map { profile + "/" + $0 },
                    warning: true, detail: "Tabs will not be restored next launch")
                if let cache = browser.cacheRoot {
                    add("Cache", label, [cache + "/" + name])
                }
            }
        case .safari:
            let safari = browser.profilesRoot
            add("Browsing history", nil, ["History.db", "History.db-wal", "History.db-shm",
                                          "History.db-lock"].map { safari + "/" + $0 })
            add("Downloads list", nil, [safari + "/Downloads.plist"])
            add("Last session", nil, [safari + "/LastSession.plist"], warning: true,
                detail: "Tabs will not be restored next launch")
            add("Cookies", nil, [home + "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
                                 home + "/Library/Cookies/Cookies.binarycookies"],
                detail: "Signs you out of websites")
            add("Cache", nil, [home + "/Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari"])
        case .firefox:
            for profile in DiskUsage.children(of: browser.profilesRoot) {
                let name = (profile as NSString).lastPathComponent
                add("Cookies", name, ["cookies.sqlite", "cookies.sqlite-wal"].map { profile + "/" + $0 },
                    detail: "Signs you out of websites")
                add("Form history", name, ["formhistory.sqlite"].map { profile + "/" + $0 })
                add("Open tabs & sessions", name, ["sessionstore.jsonlz4", "sessionstore-backups"]
                        .map { profile + "/" + $0 }, warning: true)
                add("Cache", name, [(browser.cacheRoot ?? "") + "/" + name + "/cache2"])
                add("Browsing history", name, [profile + "/places.sqlite"],
                    blockedReason: "Firefox keeps history and bookmarks in one file — clear history "
                                 + "from Firefox › Settings › Privacy instead")
            }
        }
        return rows
    }

    static func browsingTraceScan() async throws -> FindingScan {
            let running = await Apps.runningBundleIDs()
            var findings: [Finding] = []
            for browser in browsers where DiskUsage.exists(browser.profilesRoot) {
                findings += privacyRows(browser, running: running.contains(browser.bundleID))
            }
            // macOS's own trails.
            let shared = appSupport + "/com.apple.sharedfilelist"
            let recent = DiskUsage.children(of: shared).filter {
                $0.contains("Recent") || $0.hasSuffix("ApplicationRecentDocuments")
            }
            if !recent.isEmpty {
                findings.append(Finding(id: "recent-items", title: "Recent documents, apps & servers",
                                        detail: "The lists behind  › Recent Items and each app's Open Recent",
                                        paths: recent, bytes: fileBytes(recent), group: "macOS"))
            }
            for shell in [".zsh_history", ".bash_history"] where DiskUsage.exists(home + "/" + shell) {
                findings.append(Finding(id: shell, title: "Terminal history (\(shell.dropFirst()))",
                                        detail: "Every command typed in the shell", paths: [home + "/" + shell],
                                        bytes: fileBytes([home + "/" + shell]), group: "macOS", tone: .warning))
            }
            return FindingScan(findings: findings)
        }

    // MARK: - Saved Wi-Fi

    static func wifiInterface() async -> String {
        let output = try? await MoleCLI.shared.tool("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = (output?.stdout ?? "").components(separatedBy: .newlines)
        if let port = lines.firstIndex(where: { $0.contains("Wi-Fi") || $0.contains("AirPort") }),
           port + 1 < lines.count, let range = lines[port + 1].range(of: "Device: ") {
            return String(lines[port + 1][range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return "en0"
    }

    /// Split out so the action self-test can run it against hostile names.
    static func forgetCommand(interface: String, ssids: [String]) -> String {
        ssids.map {
            "/usr/sbin/networksetup -removepreferredwirelessnetwork \(Shell.quote(interface)) \(Shell.quote($0))"
        }.joined(separator: " ; ")
    }

    static let savedWiFi = Feature(
        pane: .wifi,
        emptyTitle: "No saved networks",
        emptyMessage: "This Mac has no remembered Wi-Fi networks.",
        notice: "Forgetting a network stops this Mac joining it automatically. Its password stays "
              + "in your keychain, and iCloud Keychain can bring the network back from another device.",
        action: FindingAction(title: "Forget", icon: "wifi.slash", destructive: true,
                              explanation: "Removes the networks from the preferred list. macOS asks for "
                                         + "your administrator password.",
                              perform: { findings in
                                  let interface = await wifiInterface()
                                  let command = forgetCommand(interface: interface, ssids: findings.map(\.title))
                                  let result = await Admin.run(command)
                                  if result.cancelled { return FindingOutcome(message: "Cancelled.", cancelled: true) }
                                  // networksetup reports per network; trust only the ones it confirms.
                                  let removed = findings.filter { result.output.contains("Removed \($0.title)") }
                                  var outcome = FindingOutcome(succeeded: removed.map(\.id),
                                                               message: "Forgot \(removed.count) network\(removed.count == 1 ? "" : "s").")
                                  outcome.failures = findings.filter { !removed.contains($0) }
                                      .map { ($0.title, result.output.isEmpty ? "not removed" : result.output) }
                                  return outcome
                              }),
        cacheable: false,
        scan: {
            let interface = await wifiInterface()
            let output = try await MoleCLI.shared.tool("/usr/sbin/networksetup",
                                                       ["-listpreferredwirelessnetworks", interface])
            let summary = (try? await MoleCLI.shared.tool("/usr/sbin/ipconfig", ["getsummary", interface]))?.stdout ?? ""
            let current = summary.components(separatedBy: .newlines)
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("SSID :") }
                .map { $0.components(separatedBy: "SSID :").last?.trimmingCharacters(in: .whitespaces) ?? "" }
            let names = output.stdout.components(separatedBy: .newlines)
                .dropFirst()                                   // "Preferred networks on en0:"
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let findings = names.enumerated().map { index, name in
                Finding(id: "wifi:" + name, title: name,
                        detail: "Priority \(index + 1) on \(interface)",
                        group: name == current ? "Connected" : "Saved",
                        badges: name == current ? ["connected"] : [],
                        tone: name == current ? .good : .normal)
            }
            return FindingScan(findings: findings)
        }
    )

    // MARK: - Permissions

    private static let serviceNames: [String: String] = [
        "kTCCServiceSystemPolicyAllFiles": "Full Disk Access",
        "kTCCServiceAccessibility": "Accessibility",
        "kTCCServiceScreenCapture": "Screen Recording",
        "kTCCServiceListenEvent": "Input Monitoring",
        "kTCCServicePostEvent": "Keyboard & mouse control",
        "kTCCServiceCamera": "Camera",
        "kTCCServiceMicrophone": "Microphone",
        "kTCCServiceAddressBook": "Contacts",
        "kTCCServiceCalendar": "Calendars",
        "kTCCServiceReminders": "Reminders",
        "kTCCServicePhotos": "Photos",
        "kTCCServicePhotosAdd": "Photos (add only)",
        "kTCCServiceAppleEvents": "Automation",
        "kTCCServiceSystemPolicyDesktopFolder": "Desktop folder",
        "kTCCServiceSystemPolicyDocumentsFolder": "Documents folder",
        "kTCCServiceSystemPolicyDownloadsFolder": "Downloads folder",
        "kTCCServiceSystemPolicyRemovableVolumes": "Removable volumes",
        "kTCCServiceSystemPolicyNetworkVolumes": "Network volumes",
        "kTCCServiceSystemPolicyAppBundles": "App Management",
        "kTCCServiceMediaLibrary": "Media & Apple Music",
        "kTCCServiceSpeechRecognition": "Speech Recognition",
        "kTCCServiceBluetoothAlways": "Bluetooth",
        "kTCCServiceDeveloperTool": "Developer Tools",
        "kTCCServiceUserTracking": "Tracking",
        "kTCCServiceFileProviderDomain": "Files & folders (cloud)",
        "kTCCServiceLocation": "Location",
    ]

    /// Reads a TCC database in-process. Needs Full Disk Access, which this app
    /// already holds for scanning; without it the open fails and the pane says so.
    private static func readTCC(_ path: String) -> [(service: String, client: String, isPath: Bool,
                                                     allowed: Bool, modified: Date?)] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let query = "SELECT service, client, client_type, auth_value, last_modified FROM access"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [(String, String, Bool, Bool, Date?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let service = sqlite3_column_text(statement, 0),
                  let client = sqlite3_column_text(statement, 1) else { continue }
            let modified = sqlite3_column_int64(statement, 4)
            rows.append((String(cString: service), String(cString: client),
                         sqlite3_column_int(statement, 2) == 1,
                         sqlite3_column_int(statement, 3) >= 2,
                         modified > 0 ? Date(timeIntervalSince1970: TimeInterval(modified)) : nil))
        }
        return rows
    }

    static let permissions = Feature(
        pane: .permissions,
        emptyTitle: "Could not read permissions",
        emptyMessage: "Reading the permission database needs Full Disk Access for MoleUI.",
        notice: "What each app has been allowed (or refused). Resetting removes the decision, so the "
              + "app has to ask again the next time it needs access.",
        action: FindingAction(title: "Reset", icon: "arrow.uturn.backward", destructive: false,
                              explanation: "Each app loses this permission and will ask again next time. "
                                         + "Nothing is deleted.",
                              perform: { findings in
                                  var outcome = FindingOutcome(message: "")
                                  var needAdmin: [Finding] = []
                                  for finding in findings {
                                      let service = finding.info["service"] ?? ""
                                      let client = finding.info["client"] ?? ""
                                      let result = try? await MoleCLI.shared.tool("/usr/bin/tccutil",
                                                                                  ["reset", service, client])
                                      if result?.exitCode == 0 { outcome.succeeded.append(finding.id) }
                                      else { needAdmin.append(finding) }
                                  }
                                  // System-level grants (Accessibility, Screen Recording…)
                                  // live in the root-owned database.
                                  if !needAdmin.isEmpty {
                                      let command = needAdmin.map {
                                          "/usr/bin/tccutil reset \(Shell.quote($0.info["service"] ?? "")) "
                                              + Shell.quote($0.info["client"] ?? "")
                                      }.joined(separator: " ; ")
                                      let result = await Admin.run(command)
                                      if result.ok { outcome.succeeded += needAdmin.map(\.id) }
                                      else if !result.cancelled {
                                          outcome.failures = needAdmin.map { ($0.title, result.output) }
                                      }
                                  }
                                  outcome.message = "Reset \(outcome.succeeded.count) permission\(outcome.succeeded.count == 1 ? "" : "s")."
                                  return outcome
                              }),
        cacheable: false,
        scan: {
            let ownBundle = Bundle.main.bundleIdentifier ?? "dev.rushil.moleui"
            let rows = readTCC(appSupport + "/com.apple.TCC/TCC.db")
                     + readTCC("/Library/Application Support/com.apple.TCC/TCC.db")
            var seen = Set<String>()
            var findings: [Finding] = []
            for row in rows {
                let key = row.service + "|" + row.client
                guard seen.insert(key).inserted else { continue }
                let service = serviceNames[row.service]
                    ?? String(row.service.replacingOccurrences(of: "kTCCService", with: ""))
                let name = row.isPath ? (row.client as NSString).lastPathComponent
                                      : (Apps.name(forBundleID: row.client) ?? row.client)
                let blocked: String? = row.isPath
                    ? "Granted to a bare program path — reset it in System Settings › Privacy & Security"
                    : (row.client == ownBundle ? "This is MoleUI's own access" : nil)
                findings.append(Finding(id: key, title: name,
                                        detail: row.isPath ? row.client : row.client,
                                        date: row.modified, dateLabel: row.allowed ? "allowed" : "denied",
                                        group: service,
                                        badges: row.allowed ? [] : ["denied"],
                                        tone: row.allowed ? .normal : .good,
                                        blocked: blocked,
                                        info: ["service": row.service.replacingOccurrences(of: "kTCCService", with: ""),
                                               "client": row.client]))
            }
            // Most sensitive first.
            let order = ["Full Disk Access", "Accessibility", "Screen Recording", "Input Monitoring",
                         "Keyboard & mouse control", "Camera", "Microphone", "Automation"]
            findings.sort { lhs, rhs in
                let l = order.firstIndex(of: lhs.group ?? "") ?? order.count
                let r = order.firstIndex(of: rhs.group ?? "") ?? order.count
                return l != r ? l < r : (lhs.group ?? "") < (rhs.group ?? "")
            }
            return FindingScan(findings: findings)
        }
    )

    // MARK: - Browser Extensions

    /// Resolves Chrome's `__MSG_appName__` placeholders from the extension's
    /// own locale files.
    private static func localized(_ value: String, in folder: String, defaultLocale: String?) -> String {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__") else { return value }
        let key = String(value.dropFirst(6).dropLast(2)).lowercased()
        for locale in [defaultLocale, "en", "en_US"].compactMap({ $0 }) {
            let file = folder + "/_locales/\(locale)/messages.json"
            guard let data = FileManager.default.contents(atPath: file),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (name, entry) in messages where name.lowercased() == key {
                if let message = (entry as? [String: Any])?["message"] as? String { return message }
            }
        }
        return value
    }

    private static func riskBadges(_ manifest: [String: Any]) -> [String] {
        let permissions = (manifest["permissions"] as? [Any] ?? []) + (manifest["host_permissions"] as? [Any] ?? [])
        let strings = permissions.compactMap { $0 as? String }
        var badges: [String] = []
        if strings.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*") || $0 == "http://*/*" || $0 == "https://*/*" }) {
            badges.append("all sites")
        }
        if strings.contains("nativeMessaging") { badges.append("native app") }
        if strings.contains(where: { ["history", "cookies", "webRequest", "tabs"].contains($0) }) {
            badges.append("reads browsing")
        }
        return badges
    }

    static func browserExtensionScan() async throws -> FindingScan {
            let running = await Apps.runningBundleIDs()
            var findings: [Finding] = []
            for browser in browsers where browser.kind == .chromium {
                let blocked = running.contains(browser.bundleID) ? "Quit \(browser.name) first" : nil
                let profiles = chromiumProfiles(browser.profilesRoot)
                for profile in profiles {
                    for extensionDir in DiskUsage.children(of: profile + "/Extensions") {
                        guard let version = DiskUsage.children(of: extensionDir).sorted().last,
                              let data = FileManager.default.contents(atPath: version + "/manifest.json"),
                              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        let locale = manifest["default_locale"] as? String
                        let name = localized(manifest["name"] as? String ?? "?", in: version, defaultLocale: locale)
                        // Chrome's own internal components are not user extensions.
                        if name.hasPrefix("__MSG_") || name.isEmpty { continue }
                        let badges = riskBadges(manifest)
                        let profileName = profiles.count > 1 ? " (\((profile as NSString).lastPathComponent))" : ""
                        findings.append(Finding(
                            id: extensionDir, title: name,
                            detail: "v\(manifest["version"] as? String ?? "?") · \((extensionDir as NSString).lastPathComponent)",
                            paths: [extensionDir], bytes: DiskUsage.size(of: extensionDir),
                            group: browser.name + profileName, badges: badges,
                            tone: badges.contains("all sites") ? .warning : .normal, blocked: blocked))
                    }
                }
            }
            // Firefox add-ons, from its own registry.
            let firefoxBlocked = running.contains("org.mozilla.firefox") ? "Quit Firefox first" : nil
            for profile in DiskUsage.children(of: appSupport + "/Firefox/Profiles") {
                guard let data = FileManager.default.contents(atPath: profile + "/extensions.json"),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let addons = json["addons"] as? [[String: Any]] else { continue }
                for addon in addons where (addon["location"] as? String) == "app-profile" {
                    let locale = addon["defaultLocale"] as? [String: Any]
                    let name = locale?["name"] as? String ?? addon["id"] as? String ?? "?"
                    let path = addon["path"] as? String ?? ""
                    guard !path.isEmpty else { continue }
                    findings.append(Finding(id: path, title: name,
                                            detail: "v\(addon["version"] as? String ?? "?")"
                                                  + ((addon["active"] as? Bool) == false ? " · disabled" : ""),
                                            paths: [path], bytes: DiskUsage.size(of: path),
                                            group: "Firefox", blocked: firefoxBlocked))
                }
            }
            // Safari extensions ship inside apps, so they are listed, not removed.
            let plugins = (try? await MoleCLI.shared.tool("/usr/bin/pluginkit",
                                                          ["-mAvvv", "-p", "com.apple.Safari.web-extension"]))?.stdout ?? ""
            var currentID: String?
            for line in plugins.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let paren = trimmed.firstIndex(of: "("), !trimmed.hasPrefix("Path"), !trimmed.contains("=") {
                    currentID = String(trimmed[..<paren])
                }
                if trimmed.hasPrefix("Path = "), let id = currentID {
                    let path = String(trimmed.dropFirst(7))
                    let app = path.components(separatedBy: ".app/").first.map { ($0 as NSString).lastPathComponent } ?? id
                    findings.append(Finding(id: "safari:" + id, title: ((path as NSString).lastPathComponent as NSString)
                                                .deletingPathExtension,
                                            detail: "Part of \(app).app", paths: [], group: "Safari",
                                            blocked: "Turn it off in Safari › Settings › Extensions, or "
                                                   + "uninstall \(app) to remove it"))
                    currentID = nil
                }
            }
            return FindingScan(findings: findings)
        }
}

extension Features {
    /// Browsing traces and browser extensions are both "what your browsers
    /// keep", and both need the browser closed — one pane, grouped by browser.
    static let privacy = Feature(
        pane: .privacy,
        emptyTitle: "Nothing to clear",
        emptyMessage: "No browsing traces or browser extensions were found.",
        notice: "History, cookies, caches and extensions for every browser, plus macOS's recent-items "
              + "lists. Saved passwords and bookmarks are never listed. Quit a browser to make its "
              + "rows selectable; with browser sync on, removed extensions may come back.",
        action: FindingAction(title: "Remove", icon: "hand.raised", destructive: true,
                              explanation: "The selected files move to the Trash. Browsers recreate "
                                         + "empty ones on their next launch.",
                              perform: { await FindingOutcome.trash($0) }),
        cacheable: false,
        scan: {
            async let traces = browsingTraceScan()
            async let extensions = browserExtensionScan()
            let traceScan = try await traces
            let extensionScan = try await extensions
            return FindingScan(findings: traceScan.findings + extensionScan.findings.map {
                                   var row = $0; row.group = ($0.group ?? "") + " extensions"; return row
                               })
        }
    )
}
