import SwiftUI

/// Selection + delete state, shared by every pane that lists files.
///
/// The selection is keyed on the **path**, never on a row index or a synthetic
/// row id. Paths are what actually gets deleted, and they survive a re-sort or a
/// rescan — an index-keyed selection would silently point at different files the
/// moment the sort order changed, which is the worst possible bug in a control
/// that deletes.
@MainActor
final class TrashController: ObservableObject {
    @Published private(set) var selection: Set<String> = []
    @Published var confirming = false
    @Published private(set) var working = false
    @Published var result: Trash.Outcome?

    /// Successfully trashed this session, so a pane can drop rows from what it
    /// is showing instead of pretending files still exist.
    @Published private(set) var removed: Set<String> = []

    var count: Int { selection.count }

    func isSelected(_ path: String) -> Bool { selection.contains(path) }

    func toggle(_ path: String) {
        // A stale "moved 4 items" banner sitting above a fresh selection reads
        // as if those four were the ones just picked.
        result = nil
        if selection.contains(path) {
            selection.remove(path)
        } else if Trash.rejection(for: path) == nil {
            selection.insert(path)
        }
    }

    func replaceSelection(with paths: [String]) {
        result = nil
        selection = Set(paths.filter { Trash.rejection(for: $0) == nil })
    }

    func clear() {
        selection.removeAll()
        result = nil
    }

    /// Forget everything, including which paths were trashed. Called on rescan:
    /// `removed` exists to hide rows the scan still lists, and after a fresh
    /// scan it would instead hide a file the user had put back from the Trash.
    func reset() {
        selection.removeAll()
        removed.removeAll()
        result = nil
    }

    func bytes(_ weights: [String: Int64]) -> Int64 {
        selection.reduce(0) { $0 + (weights[$1] ?? 0) }
    }

    /// The three lines the confirmation shows, so the sheet names actual paths
    /// rather than only a count.
    func sample(limit: Int = 3) -> [String] {
        Array(selection.sorted().prefix(limit))
    }

    /// Runs the delete. Returns the paths that actually moved so the caller can
    /// prune its list and invalidate its cache.
    @discardableResult
    func run(weights: [String: Int64]) async -> [String] {
        guard !selection.isEmpty else { return [] }
        confirming = false
        working = true
        defer { working = false }

        let items = selection.sorted().map { Trash.Item(path: $0, bytes: weights[$0] ?? 0) }
        let outcome = await Trash.recycle(items)
        result = outcome
        removed.formUnion(outcome.trashed)
        // Anything that failed stays ticked: it is still there, and the reason
        // is in the notice, so a retry does not mean re-picking every row.
        selection.subtract(outcome.trashed)
        return outcome.trashed
    }
}

/// Row checkbox. Red when ticked — the app's rule is that red means it deletes,
/// and a ticked row is exactly that.
struct SelectBox: View {
    var selected: Bool
    var blocked: Bool = false

    var body: some View {
        Image(systemName: blocked ? "minus.square"
                                  : (selected ? "checkmark.square.fill" : "square"))
            .font(.system(size: 12))
            .foregroundStyle(blocked ? Mole.textFaint.opacity(0.45)
                                     : (selected ? Mole.danger : Mole.textFaint))
            .frame(width: 14)
    }
}

/// Header controls for a pane with a live selection: how much is picked, a way
/// out, and the one red button.
struct TrashBar: View {
    @ObservedObject var controller: TrashController
    var bytes: Int64

    var body: some View {
        if controller.count > 0 {
            Text("\(controller.count) selected · \(formatBytesDecimal(bytes))")
                .font(Mole.mono(10.5))
                .foregroundStyle(Mole.textDim)
            GhostButton(title: "Clear", systemImage: "xmark") { controller.clear() }
            ActionButton(title: "Move to Trash", systemImage: "trash",
                         destructive: true, loading: controller.working) {
                controller.confirming = true
            }
        }
    }
}

/// What happened, once something has been moved. Green when everything went,
/// amber when part of it did not — never red, because by this point nothing is
/// about to be deleted.
struct TrashResultNotice: View {
    var outcome: Trash.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Notice(icon: outcome.failed.isEmpty ? "checkmark.seal" : "exclamationmark.triangle",
                   text: outcome.summary
                       + (outcome.trashed.isEmpty ? "" : " Recover them from the Trash in Finder."),
                   tint: outcome.failed.isEmpty ? Mole.moss : Mole.amber)

            ForEach(outcome.failed.prefix(4), id: \.path) { failure in
                Text("\((failure.path as NSString).lastPathComponent) — \(failure.reason)")
                    .font(Mole.mono(10))
                    .foregroundStyle(Mole.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(failure.path)
            }
        }
    }
}

extension Trash.Failure: Identifiable {
    var id: String { path }
}

/// The confirmation every delete goes through. Names the count, the size and
/// the first few paths — a bare "Delete 12 items?" is not something anyone can
/// actually check before clicking.
struct TrashConfirmSheet: View {
    var count: Int
    var bytes: Int64
    var sample: [String]
    var what: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ConfirmSheet(
            title: "Move \(count) \(what)\(count == 1 ? "" : "s") to the Trash?",
            summary: formatBytesDecimal(bytes),
            detail: sampleLines
                  + "\n\nThese go to the Trash, so they can be put back from Finder "
                  + "until you empty it. Emptying the Trash is the permanent step, and "
                  + "MoleUI never does it for you.",
            confirmTitle: "Move to Trash",
            onConfirm: onConfirm,
            onCancel: onCancel
        )
    }

    private var sampleLines: String {
        let shortened = sample.map { path -> String in
            path.hasPrefix(NSHomeDirectory())
                ? "~" + path.dropFirst(NSHomeDirectory().count)
                : path
        }
        let remaining = count - shortened.count
        return shortened.joined(separator: "\n")
             + (remaining > 0 ? "\n…and \(remaining) more" : "")
    }
}
