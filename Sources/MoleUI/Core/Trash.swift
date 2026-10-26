import Foundation

/// Moves files to the Trash. Never `rm`, never `unlink`, never a shelled-out
/// delete.
///
/// This is the only reason MoleUI is willing to delete anything on its own.
/// `mo clean` removes permanently, and the Purge and Installer panes could not
/// remove at all — their real runs are key-driven terminal selectors. Trashing
/// gives the panes a working delete whose worst outcome is "open the Trash and
/// put it back", which is the only kind of delete a single click in a GUI should
/// ever perform.
///
/// One consequence worth knowing: `mo history` records what mole itself deleted,
/// so it will not show anything trashed from here.
enum Trash {

    struct Item {
        var path: String
        var bytes: Int64
    }

    struct Failure {
        var path: String
        var reason: String
    }

    struct Outcome {
        var trashed: [String] = []
        var failed: [Failure] = []
        var bytes: Int64 = 0

        var summary: String {
            var parts: [String] = []
            if !trashed.isEmpty {
                parts.append("Moved \(trashed.count) item\(trashed.count == 1 ? "" : "s") "
                           + "(\(formatBytesDecimal(bytes))) to the Trash")
            }
            if !failed.isEmpty {
                parts.append("\(failed.count) could not be moved")
            }
            return parts.isEmpty ? "Nothing was moved." : parts.joined(separator: " · ") + "."
        }
    }

    /// Whole subtrees that must never be touched, whatever a parser produced.
    /// Nothing Mole reports lives under any of these; if a path here ever
    /// reaches this point, the parse is wrong and the right answer is to refuse.
    private static let forbiddenTrees = [
        "/System", "/bin", "/sbin", "/usr", "/etc", "/dev", "/cores",
        "/private/var/db", "/private/etc", "/Library/Application Support/com.apple.TCC",
    ]

    /// Containers, as opposed to their contents. `~/Downloads/Foo.dmg` is fair
    /// game; `~/Downloads` is not — and `mo analyze`'s overview lists exactly
    /// these directories as rows, so without this the top of that pane would be
    /// a set of one-click "delete my Documents folder" buttons.
    private static var forbiddenExact: Set<String> {
        let home = NSHomeDirectory()
        var paths: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin",
            "/sbin", "/etc", "/var", "/tmp", "/private", "/opt", "/Volumes",
            "/Users/Shared", home,
        ]
        for folder in ["Desktop", "Documents", "Downloads", "Library", "Movies",
                       "Music", "Pictures", "Public", "Applications", "Developer"] {
            paths.insert(home + "/" + folder)
        }
        return paths
    }

    /// Why this path may not be trashed, or nil when it may. Every caller runs
    /// this *before* offering the row as selectable, and `recycle` runs it again
    /// on the way past — a UI-only check is one refactor away from being no
    /// check at all.
    static func rejection(for path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            return "not an absolute path"
        }

        // Both the literal path and the symlink-resolved one: /tmp is a link to
        // /private/tmp, and a check that only saw one spelling would miss the
        // other.
        let url = URL(fileURLWithPath: trimmed).standardized
        let candidates = [url.path, url.resolvingSymlinksInPath().path]

        for candidate in candidates {
            if forbiddenExact.contains(candidate) {
                return "\(candidate) is a system or home folder, not something inside one"
            }
            for tree in forbiddenTrees where candidate == tree || candidate.hasPrefix(tree + "/") {
                return "\(tree) is part of macOS itself"
            }
            // A direct child of the root filesystem is a mount point or a
            // system directory in every case that matters here.
            if candidate.split(separator: "/").count < 2 {
                return "top-level directories are never removed from here"
            }
        }

        guard FileManager.default.fileExists(atPath: trimmed) else {
            return "no longer on disk"
        }
        return nil
    }

    /// `FileManager.trashItem` rather than `NSWorkspace.recycle`: it reports one
    /// error per file instead of a single error for the batch, so a run that
    /// half-succeeds can say exactly which paths did not move and why.
    static func recycle(_ items: [Item]) async -> Outcome {
        // Off the main actor: trashing is one synchronous call per file, and a
        // selection can run to thousands of cache entries.
        await Task.detached(priority: .userInitiated) { recycleSync(items) }.value
    }

    /// The synchronous core. Separate so `--selftest` can exercise the real
    /// delete without standing up a run loop — the one code path in this app
    /// that must not be verified by reading it.
    static func recycleSync(_ items: [Item]) -> Outcome {
        var outcome = Outcome()
        for item in items {
            if let reason = rejection(for: item.path) {
                outcome.failed.append(Failure(path: item.path, reason: reason))
                continue
            }
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                outcome.trashed.append(item.path)
                outcome.bytes += max(0, item.bytes)
            } catch {
                outcome.failed.append(Failure(path: item.path,
                                              reason: error.localizedDescription))
            }
        }
        return outcome
    }
}
