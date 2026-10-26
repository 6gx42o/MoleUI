import Foundation

/// One row in any of the list-style panes: Mail Attachments, Trash Bins,
/// Disk Hogs, Malware, Privacy, Wi-Fi, Permissions, Browser Extensions, Unused
/// Apps, Extensions, Updater, Large & Old Files, Duplicates.
///
/// Every one of those is "scan, show a list, let the user pick rows, do one
/// thing to the picked rows". Sharing the row type and the pane keeps each
/// feature down to the part that is actually different — what it finds and
/// what it does — instead of fifteen near-identical views.
struct Finding: Identifiable, Codable, Hashable {
    enum Tone: String, Codable { case normal, warning, good }

    /// Unique within a scan. A path when the row is a file, otherwise whatever
    /// the scanner can key it on (an SSID, a TCC service + bundle id…).
    var id: String
    var title: String
    var detail: String? = nil
    /// What the action operates on. Usually one path; a browser's "History"
    /// row is the database plus its journal files.
    var paths: [String] = []
    var bytes: Int64? = nil
    var date: Date? = nil
    var dateLabel: String? = nil        // "opened", "modified", "granted"
    var group: String? = nil
    var badges: [String] = []
    var tone: Tone = .normal
    /// Why this row cannot be acted on. Shown in place of a checkbox.
    var blocked: String? = nil
    /// Scanner-specific fields its action needs (a launchd label, a bundle id).
    var info: [String: String] = [:]

    var revealPath: String? { paths.first }
}

struct FindingScan: Codable {
    var findings: [Finding]
    /// Pane-level lines shown above the list — the protection status summary,
    /// "Homebrew catalog refreshed 20m ago", and so on.
    var notes: [String] = []
}

/// What a pane does to the selected rows.
struct FindingAction {
    var title: String
    var icon: String
    /// Red button and red confirmation. Only for actions that delete or remove.
    var destructive: Bool
    /// The confirmation's explanatory paragraph.
    var explanation: String
    /// True when the action removes rows from the list on success.
    var removesRows = true
    var perform: ([Finding]) async -> FindingOutcome
}

struct FindingOutcome {
    var succeeded: [String] = []        // Finding ids
    var failures: [(id: String, reason: String)] = []
    var message: String
    var cancelled = false

    /// The standard outcome for actions that move each row's paths to the Trash.
    static func trash(_ findings: [Finding]) async -> FindingOutcome {
        var outcome = FindingOutcome(message: "")
        var bytes: Int64 = 0
        for finding in findings {
            let result = await Trash.recycle(finding.paths.map { Trash.Item(path: $0, bytes: 0) })
            if result.failed.isEmpty {
                outcome.succeeded.append(finding.id)
                bytes += finding.bytes ?? 0
            } else {
                outcome.failures.append((finding.id, result.failed[0].reason))
            }
        }
        outcome.message = "Moved \(outcome.succeeded.count) to the Trash"
            + (bytes > 0 ? " (\(formatBytesDecimal(bytes)))" : "")
            + (outcome.failures.isEmpty ? "." : " · \(outcome.failures.count) failed.")
        return outcome
    }
}

/// A list pane's definition. Each feature is one of these.
struct Feature {
    var pane: Pane
    var emptyTitle: String
    var emptyMessage: String
    /// Shown above the list once scanned. Explains what the rows are and what
    /// the action really does — honesty about limits lives here.
    var notice: String?
    var action: FindingAction?
    /// Optional "select the obvious ones" helper (Duplicates: all but one per
    /// group; Trash Bins: everything).
    var autoSelect: (title: String, pick: ([Finding]) -> Set<String>)? = nil
    /// Last-chance validation of a selection before the confirm sheet opens.
    /// Duplicates uses it to refuse deleting every copy of a file.
    var validate: (([Finding], Set<String>) -> String?)? = nil
    /// Set false for scans that are cheap and must be live (Wi-Fi, Permissions).
    var cacheable = true
    var scan: () async throws -> FindingScan
}

extension Pane {
    var cacheKey: String { "finding-" + rawValue }
}
