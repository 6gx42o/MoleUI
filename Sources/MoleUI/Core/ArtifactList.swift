import Foundation

/// Parsers for `mo purge --dry-run` and `mo installer --dry-run`.
///
/// Neither uses the sectioned `➤`/`→` layout `MolePreview` handles, and neither
/// has a non-interactive removal path — `mo installer`'s only flags are
/// `--dry-run`, `--debug` and `--help`, and `mo purge`'s real run drops into a
/// key-driven selector. So these panes are inventory and preview only; removal
/// is handed back to the terminal rather than shipping an execution path that
/// cannot be tested without deleting real project directories.
enum ArtifactList {

    struct Item: Identifiable {
        let id = UUID()
        var name: String        // display label
        var path: String?       // full path when the command gives one
        var size: String
        var bytes: Int64?
        var location: String?   // installer only: "Downloads", "Desktop"…
    }

    struct Result {
        var items: [Item] = []
        var headline: String?           // "Would free: 4.21GB | Items: 56 …"
        /// How many the command says exist, when it tells us. `mo installer`
        /// renders a paginated selector and only prints the first page, so the
        /// list can be short of the real total — surfaced rather than swallowed,
        /// because a truncated inventory that looks complete is worse than none.
        var declaredTotal: Int?
        var totalBytes: Int64? { headline.flatMap(MolePreview.parseBytes) }
        var sumBytes: Int64 { items.compactMap(\.bytes).reduce(0, +) }

        var isTruncated: Bool {
            guard let declaredTotal else { return false }
            return items.count < declaredTotal
        }
    }

    /// `✓ [DRY RUN] ~/my-project/venv, 1.63GB`
    /// footer: `Would free: 4.21GB | Items: 56 | Free: 77.67GB`
    static func parsePurge(_ rawText: String) -> Result {
        var result = Result()
        for rawLine in MoleCLI.stripANSI(rawText).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("Would free:") || line.hasPrefix("Freed:") {
                result.headline = line
                continue
            }
            guard let marker = line.range(of: "[DRY RUN] ") else { continue }
            let body = String(line[marker.upperBound...])

            // Split on the last ", " so a comma inside a path survives.
            guard let split = body.range(of: ", ", options: .backwards) else { continue }
            let path = String(body[..<split.lowerBound])
            let size = String(body[split.upperBound...])
            result.items.append(Item(name: (path as NSString).lastPathComponent,
                                     path: expand(path),
                                     size: size,
                                     bytes: MolePreview.parseBytes(size)))
        }
        result.items.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        return result
    }

    /// `mo installer --dry-run --debug` writes one line per installer to
    /// **stderr**, with the full untruncated path:
    ///
    ///     [DEBUG] Found installer:   * /Users/me/Downloads/Affinity.dmg
    ///
    /// This is the only place the command gives paths out. Its selector block on
    /// stdout clips names to the column width ("Invoke.Community.E...") and
    /// prints one page of them — 18 of 22 on this machine — so it can show an
    /// inventory but can never back a delete: you cannot safely remove a file
    /// whose name you only have three quarters of.
    ///
    /// Sizes come from the filesystem rather than the selector, since matching a
    /// clipped name back to a row is exactly the guessing this avoids.
    static func parseInstallerDebug(_ stderr: String) -> Result {
        var result = Result()
        let marker = "Found installer:"
        for rawLine in MoleCLI.stripANSI(stderr).components(separatedBy: .newlines) {
            guard let range = rawLine.range(of: marker) else { continue }
            let path = String(rawLine[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t*"))
            guard path.hasPrefix("/") else { continue }

            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value
            result.items.append(Item(name: (path as NSString).lastPathComponent,
                                     path: path,
                                     size: bytes.map { formatBytesDecimal($0) } ?? "—",
                                     bytes: bytes,
                                     location: sourceLabel(for: path)))
        }
        result.items.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        // `declaredTotal` stays nil: this list is the complete scan, so there is
        // nothing for the truncation notice to warn about.
        if !result.items.isEmpty {
            result.headline = "Found: \(formatBytesDecimal(result.sumBytes)) | "
                            + "Items: \(result.items.count)"
        }
        return result
    }

    /// Mirrors `get_source_display()` in bin/installer.sh, in its order — the
    /// Telegram case is last there because it has to lose to the more specific
    /// directory matches above it.
    private static func sourceLabel(for path: String) -> String {
        let home = NSHomeDirectory()
        let directory = (path as NSString).deletingLastPathComponent
        let rules: [(String, String)] = [
            (home + "/Downloads", "Downloads"),
            (home + "/Desktop", "Desktop"),
            (home + "/Documents", "Documents"),
            (home + "/Public", "Public"),
            (home + "/Library/Downloads", "Library"),
            ("/Users/Shared", "Shared"),
            (home + "/Library/Caches/Homebrew", "Homebrew"),
            (home + "/Library/Mobile Documents/com~apple~CloudDocs/Downloads", "iCloud"),
            (home + "/Library/Containers/com.apple.mail", "Mail"),
        ]
        for (prefix, label) in rules where directory.hasPrefix(prefix) { return label }
        if directory.contains("Telegram Desktop") { return "Telegram" }
        return (directory as NSString).lastPathComponent
    }

    /// `  ○ Affinity.dmg          1.01GB | Downloads`
    /// The leading glyph is a selection radio from the TUI, not a status.
    ///
    /// Kept as the fallback for when `--debug` yields nothing — a future mole
    /// could drop or rename that line. The pane can still show this list; it
    /// just cannot offer to delete from it, since there are no paths in it.
    static func parseInstaller(_ rawText: String) -> Result {
        var result = Result()
        for rawLine in MoleCLI.stripANSI(rawText).components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // "Select Installers to Remove [1/20] , 0B, 0 selected" — the second
            // number is how many the selector knows about in total.
            if line.contains("Select Installers"),
               let open = line.range(of: "["), let close = line.range(of: "]"),
               open.upperBound < close.lowerBound {
                let inside = line[open.upperBound..<close.lowerBound]
                if let slash = inside.range(of: "/") {
                    result.declaredTotal = Int(inside[slash.upperBound...])
                }
                continue
            }

            // Strip the cursor arrow and the radio glyph, if present.
            for glyph in ["\u{27A4}", "\u{25CF}", "\u{25CB}"] {   // ➤ ● ○
                if line.hasPrefix(glyph) {
                    line = String(line.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces)
                }
            }
            guard line.hasPrefix("\u{25CB}") == false else { continue }

            // Must look like "<name>   <size> | <location>".
            guard let bar = line.range(of: " | ") else { continue }
            let left = String(line[..<bar.lowerBound])
            let location = String(line[bar.upperBound...]).trimmingCharacters(in: .whitespaces)

            // Size is the last whitespace-separated token on the left.
            let parts = left.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let sizeToken = parts.last else { continue }
            let size = String(sizeToken)
            guard let bytes = MolePreview.parseBytes(size) else { continue }
            let name = parts.dropLast().joined(separator: " ")

            result.items.append(Item(name: name, path: nil, size: size,
                                     bytes: bytes, location: location))
        }
        result.items.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        return result
    }

    private static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? NSHomeDirectory() + String(path.dropFirst()) : path
    }
}
