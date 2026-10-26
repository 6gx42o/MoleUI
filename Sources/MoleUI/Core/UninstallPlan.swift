import Foundation

/// Parser for `mo uninstall --dry-run <name>…`.
///
/// Unlike `mo clean`, this command prompts even in dry-run mode and treats EOF
/// on stdin as "abort" — so the preview only appears if confirmation is fed in.
/// See `UninstallPlan.confirmationInput`.
///
/// Shape of the output:
///
///     ◎ Moonlight , 163.8MB
///       ✓ /Applications/Moonlight.app , 163.8MB
///       ✓ ~/Library/Preferences/com.moonlight-stream.Moonlight.plist , 7KB
///     ==========
///     Would remove 1 app, would free 163.8MB: Moonlight
///
enum UninstallPlan {

    struct File: Identifiable {
        let id = UUID()
        var path: String
        var size: String?
        var bytes: Int64?
    }

    struct App: Identifiable {
        let id = UUID()
        var name: String
        var size: String?
        var files: [File]
    }

    struct Result {
        var apps: [App] = []
        var summary: String?          // "Would remove 1 app, would free 163.8MB: …"
        var aborted = false           // the prompt was declined or hit EOF
        var totalFiles: Int { apps.map(\.files.count).reduce(0, +) }
        var totalBytes: Int64? { summary.flatMap(MolePreview.parseBytes) }
    }

    /// Answers both prompts the command asks: "Proceed with uninstallation?
    /// [y/N]" and then "Enter confirm, ESC cancel".
    static let confirmationInput = "y\n\n"

    /// Removes exactly the files a reviewed `--dry-run` plan listed, to the Trash.
    ///
    /// Mole 1.62 stopped accepting a confirmation from anything but a real
    /// terminal — on purpose, so "a script or agent could [not] confirm an
    /// uninstall nobody reviewed" (lib/uninstall/batch.sh). MoleUI does not
    /// fake a terminal to get past that. The human review still happens: the
    /// plan is shown in the pane and confirmed in a sheet. MoleUI then moves
    /// those paths to the Trash itself, the same way Leftovers and Large Files
    /// do — user-owned files directly, root-owned ones (App Store apps,
    /// /Library items) behind one macOS password prompt.
    static func remove(_ plan: Result) async -> (moved: Int, failed: [String], cancelled: Bool) {
        let home = NSHomeDirectory()
        let paths = plan.apps.flatMap(\.files).map { file -> String in
            file.path.hasPrefix("~") ? home + file.path.dropFirst() : file.path
        }
        let result = await Trash.recycle(paths.map { Trash.Item(path: $0, bytes: 0) })
        var moved = result.trashed.count
        var failed: [String] = []
        // Permission failures on root-owned items get one admin attempt;
        // anything Trash.rejection refuses stays refused.
        let needAdmin = result.failed.filter { Trash.rejection(for: $0.path) == nil }.map(\.path)
        failed += result.failed.filter { Trash.rejection(for: $0.path) != nil }
            .map { "\(($0.path as NSString).lastPathComponent): \($0.reason)" }
        var cancelled = false
        if !needAdmin.isEmpty {
            let admin = await Admin.moveToTrash(needAdmin)
            if admin.ok { moved += needAdmin.count }
            else if admin.cancelled { cancelled = true; failed += needAdmin.map { ($0 as NSString).lastPathComponent + ": cancelled" } }
            else { failed += needAdmin.map { ($0 as NSString).lastPathComponent + ": " + admin.output } }
        }
        return (moved, failed, cancelled)
    }

    /// The confirm sheet promises removed apps go to the Trash and stay
    /// recoverable. `mo uninstall` does default to that
    /// (`MOLE_DELETE_MODE="${MOLE_DELETE_MODE:-trash}"` in bin/uninstall.sh) —
    /// but it reads the variable from the environment, which the app inherits
    /// from whatever launched it. A stray `MOLE_DELETE_MODE=permanent` in the
    /// user's shell profile would turn that promise into an unrecoverable
    /// `rm -rf` with the UI still saying "Trash". Pin it instead of trusting it.
    static let trashModeEnv = ["MOLE_DELETE_MODE": "trash"]

    /// App names become positional arguments to `mo uninstall`. A bundle whose
    /// name begins with `-` would be read as a flag instead — `--permanent`
    /// being the dangerous one, since it bypasses the Trash and deletes
    /// outright. Arguments are passed as an array (never through a shell), so
    /// this is the one injection route that remains; refuse it rather than
    /// hoping the CLI rejects it.
    static func isSafeName(_ name: String) -> Bool {
        !name.hasPrefix("-") && !name.isEmpty
    }

    private static let appGlyph: Character = "\u{25CE}"   // ◎
    private static let fileGlyph: Character = "\u{2713}"  // ✓

    static func parse(_ rawText: String) -> Result {
        let text = MoleCLI.stripANSI(rawText)
        var result = Result()
        var current: App?
        var inFileList = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("Files to be removed") { inFileList = true; continue }
            if line.hasPrefix("Would remove") || line.hasPrefix("Removed ")
                || line.hasPrefix("Uninstalled") {
                result.summary = line
                continue
            }
            if line.contains("Cancelled") || line.contains("cancelled")
                || line.contains("Aborted") {
                result.aborted = true
                continue
            }
            guard inFileList, let glyph = line.first else { continue }

            let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            let (label, size) = splitSize(body)

            if glyph == appGlyph {
                if let current { result.apps.append(current) }
                current = App(name: label, size: size, files: [])
            } else if glyph == fileGlyph {
                current?.files.append(File(path: label,
                                           size: size,
                                           bytes: size.flatMap(MolePreview.parseBytes)))
            }
        }
        if let current { result.apps.append(current) }
        return result
    }

    /// Splits "path , 163.8MB" into its two halves. The separator is " , " —
    /// matched from the right so a comma inside an app name survives.
    private static func splitSize(_ body: String) -> (String, String?) {
        guard let range = body.range(of: " , ", options: .backwards) else {
            return (body, nil)
        }
        return (String(body[..<range.lowerBound]),
                String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
}
