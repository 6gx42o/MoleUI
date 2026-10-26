import Foundation

/// Disk cache for scan output, so returning to a pane shows the last scan
/// instead of running a new one.
///
/// Two things made this necessary. Every pane's model is a `@StateObject` owned
/// by its view, so switching away in the sidebar destroys it and the next visit
/// starts from nothing — and `mo clean --dry-run` walks the whole disk, which
/// with Full Disk Access granted is the slowest thing the app does. Re-running
/// it to display numbers we already had is pure waiting.
///
/// What gets stored is the command's **raw output**, not a parsed model. The
/// parsers are the part most likely to change between builds, and re-parsing
/// text is instant, so a stored model would buy nothing and cost a version field
/// and a migration the first time a struct gained a property. It also means the
/// cache can be read with `cat` when a pane shows something odd.
enum ScanCache {

    /// One key per scan. Constants rather than free-form strings, so a key can
    /// never carry a path separator into `fileURL`.
    enum Key {
        static let cleanPreview  = "clean-dryrun"
        static let cleanFileList = "clean-list"
        // Leftovers (installers + build folders) caches as a Finding scan,
        // under Pane.leftovers.cacheKey, like every other list pane.
        static let apps          = "uninstall-list"
        static let analyze       = "analyze-overview"
    }

    struct Entry {
        var text: String
        var date: Date
    }

    /// Older than `Prefs.cacheMaxAge` (24h unless changed in Settings) and the
    /// cache is ignored. Disk contents move, and a day-old figure presented as
    /// current is worse than a slow rescan.

    /// Every cached scan, for Settings' "Clear cached scans".
    static func clearAll() {
        let directory = NSHomeDirectory() + "/Library/Caches/MoleUI"
        try? FileManager.default.removeItem(atPath: directory)
    }

    static func save(_ key: String, _ text: String) {
        guard let url = fileURL(key) else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func load(_ key: String) -> Entry? {
        guard let url = fileURL(key),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(date) < Prefs.cacheMaxAge,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return Entry(text: text, date: date)
    }

    /// Call this the moment something is actually deleted: a cached preview
    /// outlives the files it describes, and re-showing it after a run would put
    /// stale reclaimable figures — and paths that no longer exist — in front of
    /// a confirmation button.
    static func clear(_ keys: String...) {
        for key in keys {
            guard let url = fileURL(key) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// `~/Library/Caches` is the honest home for this: every byte here is
    /// regenerable, and if `mo clean` sweeps it away the next visit simply scans
    /// for real.
    private static func fileURL(_ key: String) -> URL? {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/MoleUI")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory.appendingPathComponent(key + ".txt")
    }

    /// "just now" / "12m ago" / "3h ago" — compact enough to sit in a pane
    /// header next to the Rescan button. A cached result must always say how old
    /// it is; silently showing yesterday's scan as if it were live is exactly
    /// the failure this cache could introduce.
    static func ageLabel(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<90:     return "just now"
        case ..<3_600:  return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default:        return "\(Int(seconds / 86_400))d ago"
        }
    }
}
