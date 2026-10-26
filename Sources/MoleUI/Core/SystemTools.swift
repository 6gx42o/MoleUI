import AppKit
import Darwin

/// Small system helpers the newer panes share.
enum Shell {
    /// POSIX single-quoting. Everything that reaches a shell from here passes
    /// through this — Wi-Fi names in particular are chosen by whoever runs the
    /// access point, so an SSID like `x'; rm -rf ~ #` is a real input, not a
    /// hypothetical one.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes for the inside of an AppleScript string literal.
    static func appleScriptLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Runs a shell command as root through macOS's own authorization dialog.
///
/// `osascript … with administrator privileges` is the system password prompt:
/// the user types their password into macOS, never into this app, and the app
/// never sees it. Spawned as a subprocess rather than NSAppleScript so the wait
/// for the user is an `await`, not a blocked main thread.
enum Admin {
    struct Result {
        var ok: Bool
        var output: String
        /// The user dismissed the password dialog — not a failure to report.
        var cancelled: Bool
    }

    /// `privileged: false` exists only for the action self-test: it runs the
    /// identical two-layer quoting (AppleScript literal around a shell command)
    /// without a password prompt, so the escaping can be proven end to end.
    static func run(_ command: String, privileged: Bool = true) async -> Result {
        let script = "do shell script \"\(Shell.appleScriptLiteral(command))\""
                   + (privileged ? " with administrator privileges" : "")
        do {
            let output = try await MoleCLI.shared.tool("/usr/bin/osascript", ["-e", script])
            let text = (output.stdout + output.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // -128 is AppleScript's "User canceled."
            return Result(ok: output.exitCode == 0, output: text,
                          cancelled: output.stderr.contains("-128"))
        } catch {
            return Result(ok: false, output: error.localizedDescription, cancelled: false)
        }
    }

    /// Moves root-owned items into the user's Trash. `FileManager.trashItem`
    /// cannot touch /Library/LaunchDaemons and friends, and a plain `rm` would
    /// make removal permanent — so this is `mv`, into a uniquely named slot so a
    /// same-named item already in the Trash is never overwritten.
    static func moveToTrash(_ paths: [String]) async -> Result {
        let trash = NSHomeDirectory() + "/.Trash/"
        let stamp = Int(Date().timeIntervalSince1970)
        let user = Shell.quote(NSUserName())
        let commands = paths.map { path -> String in
            let name = (path as NSString).lastPathComponent
            let destination = trash + "\(name) \(stamp)"
            return "/bin/mv -n \(Shell.quote(path)) \(Shell.quote(destination)) && "
                 + "/usr/sbin/chown -R \(user) \(Shell.quote(destination))"
        }
        return await run(commands.joined(separator: " ; "))
    }
}

enum DiskUsage {
    /// Allocated size of a file or a whole directory tree.
    ///
    /// fts(3) rather than FileManager's enumerator: it walks with one stat per
    /// entry and no Foundation object per path, which is several times faster on
    /// trees like ~/Library/Developer with hundreds of thousands of files. Counts
    /// allocated blocks, so sparse VM images report what they actually occupy.
    static func size(of path: String) -> Int64 {
        var total: Int64 = 0
        path.withCString { cPath in
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
            defer { free(paths[0]) }
            guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
                return
            }
            defer { fts_close(stream) }
            while let entry = fts_read(stream) {
                let info = Int32(entry.pointee.fts_info)
                guard info == FTS_F || info == FTS_SL || info == FTS_DEFAULT,
                      let stat = entry.pointee.fts_statp else { continue }
                total += Int64(stat.pointee.st_blocks) * 512
            }
        }
        return total
    }

    /// Sizes many paths at once, bounded to the core count — a dozen
    /// concurrent tree walks on one disk is slower than eight, not faster.
    static func sizes(of paths: [String]) async -> [String: Int64] {
        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount)
        return await withTaskGroup(of: (String, Int64).self) { group in
            var result: [String: Int64] = [:]
            var next = 0
            for path in paths.prefix(limit) {
                group.addTask(priority: .userInitiated) { (path, size(of: path)) }
                next += 1
            }
            while let (path, bytes) = await group.next() {
                result[path] = bytes
                if next < paths.count {
                    let path = paths[next]
                    next += 1
                    group.addTask(priority: .userInitiated) { (path, size(of: path)) }
                }
            }
            return result
        }
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Immediate children of a directory, as absolute paths. Hidden entries are
    /// included on purpose — `.Trash` contents and dot-folders are exactly what
    /// several panes are looking for.
    static func children(of directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0 != ".DS_Store" && $0 != ".localized" }
            .map { directory + "/" + $0 }
    }
}

enum Apps {
    /// Bundle IDs of apps running now. Several panes refuse to touch an app's
    /// data while it is open: deleting a live browser's History database
    /// corrupts it rather than clearing it.
    @MainActor
    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    static func name(forBundleID id: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

/// Every preference, in one place, with its default. Read through
/// `UserDefaults` so models can use them without a View's `@AppStorage`.
enum Prefs {
    static let menuBarCPU      = "pref.menuBarCPU"        // Bool, default false
    static let liveInterval    = "pref.liveInterval"      // Int seconds, default 2
    static let largeFileMB     = "pref.largeFileMB"       // Int, default 100
    static let unusedDays      = "pref.unusedDays"        // Int, default 90
    static let duplicateMinMB  = "pref.duplicateMinMB"    // Int, default 1
    static let cacheHours      = "pref.cacheHours"        // Int, default 24

    static func int(_ key: String, _ fallback: Int) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : fallback
    }

    static var cacheMaxAge: TimeInterval { TimeInterval(int(cacheHours, 24)) * 3600 }
}
