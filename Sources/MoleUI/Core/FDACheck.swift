import Foundation

/// `MoleUI --fdacheck` — does this binary actually hold Full Disk Access?
///
/// Worth having as a command rather than a thing you infer from the UI: without
/// FDA, `mo` does not fail loudly, it just quietly reports less. A scan that
/// silently under-reports looks identical to a scan that found little.
///
/// The canary is `~/Library/Application Support/com.apple.TCC/TCC.db`, readable
/// only with Full Disk Access. Note TCC hides protected paths by reporting
/// "no such file" rather than a permission error, so ENOENT here means *denied*,
/// not missing.
///
/// **Must be launched with `open`, not from a shell.** TCC attributes a request
/// to the *responsible* process: a binary started from a terminal inherits that
/// terminal's permissions, so running this directly measures the terminal, not
/// MoleUI. Results are written to a file precisely so LaunchServices can start
/// it with no stdout to read:
///
///     open -a MoleUI.app --args --fdacheck
///     cat ~/Library/Logs/MoleUI/fdacheck.txt
///
enum FDACheck {

    static var reportPath: String { DiagnosticsDir.file("fdacheck.txt") }

    private static var lines: [String] = []

    private static func emit(_ line: String) {
        print(line)
        lines.append(line)
    }

    static func run() -> Bool {
        let home = NSHomeDirectory()
        let canary = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        lines = []

        emit("MoleUI Full Disk Access check")
        emit("  binary: \(CommandLine.arguments[0])")
        emit("  responsible: \(launchedByShell() ? "shell (RESULT INVALID — use open)" : "LaunchServices")")
        emit("")

        var granted = true

        // The verdict rests on these: they are TCC-protected, and they are what
        // actually changes what `mo` reports. ~/.Trash matters most — it is the
        // one directory whose visibility materially moves the Clean total.
        for name in ["Downloads", "Documents", "Desktop", ".Trash"] {
            let path = home + "/" + name
            do {
                let entries = try FileManager.default.contentsOfDirectory(atPath: path)
                emit("  ok   ~/\(name) readable (\(entries.count) entries)")
            } catch {
                granted = false
                emit("  FAIL ~/\(name) unreadable")
            }
        }

        // Informational only. The classic FDA canary is unreliable here: on this
        // macOS the path does not exist even for a process that *does* hold Full
        // Disk Access, so a failure says nothing. Kept because when it does
        // succeed it is conclusive.
        if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: canary)) {
            let bytes = (try? handle.read(upToCount: 16)) ?? Data()
            try? handle.close()
            emit("  ok   TCC.db readable (\(bytes.count) bytes)")
        } else {
            emit("  --   TCC.db not present on this macOS — not a signal either way")
        }

        emit("")
        emit(granted
             ? "Full Disk Access confirmed — scans will see everything."
             : "Not fully granted. System Settings → Privacy & Security → Full Disk Access;"
             + " remove MoleUI with \u{2212} and re-add it with + so the record matches"
             + " this build's signature.")

        try? lines.joined(separator: "\n").write(toFile: reportPath,
                                                 atomically: true, encoding: .utf8)
        return granted
    }

    /// A process started by LaunchServices is reparented to launchd (ppid 1);
    /// one started from a terminal still has that shell as its parent, and TCC
    /// will attribute its requests to the shell.
    private static func launchedByShell() -> Bool {
        getppid() != 1
    }
}
